import Foundation

enum CodexIngest {
    static func run(home: URL, db: CatalogDB) throws -> IngestReport {
        var report = IngestReport()
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessions.path) else { return report }

        let enumerator = fm.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.path.contains("/archived_sessions/") { continue }
            let name = item.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), !name.hasSuffix(".jsonl.zst") else {
                continue
            }
            report.filesScanned += 1
            var parser = LineParser(sessionId: sessionIdFromFilename(name))
            do {
                var pending: [UsageEvent] = []
                let prev = try db.ingestFile(path: item.standardizedFileURL.path)
                // The parser state is committed with every batch cursor, so a resume mid-file
                // restores exactly the state that produced that offset.
                func flush(_ partial: JsonlCursor) throws {
                    var cursor = partial
                    cursor.parserJSON = parser.serialize()
                    try db.withTransaction {
                        for event in pending {
                            switch try db.insertUsage(event) {
                            case .inserted: report.rowsInserted += 1
                            case .updated: report.rowsUpdated += 1
                            case .duplicate: report.skippedDupes += 1
                            }
                        }
                        try IngestFiles.commit(cursor, url: item, db: db)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
                guard let cursor = try IngestFiles.processNewBytes(
                    url: item,
                    db: db,
                    prepare: { replayed in
                        if replayed {
                            parser = LineParser(sessionId: sessionIdFromFilename(name))
                        } else if let json = prev?.parserJSON {
                            parser.restore(json)
                        }
                    },
                    flush: flush,
                    each: { line in
                        if let event = parser.consume(line) { pending.append(event) }
                    }
                ) else { continue }
                try flush(cursor)
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    static func parseFile(_ url: URL) throws -> [UsageEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var parser = LineParser(sessionId: sessionIdFromFilename(url.lastPathComponent))
        var events: [UsageEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if let event = parser.consume(String(line)) {
                events.append(event)
            }
        }
        return events
    }

    struct LineParser {
        var sessionId: String
        var cwd: String?
        var model: String?
        var lastUsageFingerprint: String?
        var lastTurnId: String?
        var turnIndex: Int = 0

        mutating func consume(_ line: String) -> UsageEvent? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let root = JSONValue.object(obj)
            else {
                return nil
            }
            let type = JSONValue.string(root["type"]) ?? ""
            let payload = JSONValue.object(root["payload"]) ?? [:]
            if type == "session_meta" {
                if let id = JSONValue.string(payload["id"]), !id.isEmpty { sessionId = id }
                cwd = JSONValue.string(payload["cwd"])
                if let m = CodexIngest.configuredModel(payload) { model = m }
                return nil
            }
            if type == "turn_context" {
                if let m = CodexIngest.configuredModel(payload) { model = m }
                return nil
            }
            if type == "event_msg", JSONValue.string(payload["type"]) == "token_count" {
                let turnId = CodexIngest.turnIdentity(root: root, payload: payload)
                guard var event = CodexIngest.eventFromTokenCount(
                    root: root,
                    payload: payload,
                    sessionId: sessionId,
                    cwd: cwd,
                    model: model
                ) else { return nil }
                let fingerprint =
                    "\(event.model)|\(event.inputTokens)|\(event.outputTokens)|\(event.cachedReadTokens)|\(event.reasoningTokens)"
                if let turnId, turnId == lastTurnId { return nil }
                if turnId == nil, fingerprint == lastUsageFingerprint { return nil }
                if turnId == nil { turnIndex += 1 }
                event.promptId = turnId ?? "turn-\(turnIndex)"
                lastTurnId = turnId ?? event.promptId
                lastUsageFingerprint = fingerprint
                return event
            }
            return nil
        }

        func serialize() -> String {
            let obj: [String: Any] = [
                "sessionId": sessionId,
                "cwd": cwd as Any? ?? NSNull(),
                "model": model as Any? ?? NSNull(),
                "lastUsageFingerprint": lastUsageFingerprint as Any? ?? NSNull(),
                "lastTurnId": lastTurnId as Any? ?? NSNull(),
                "turnIndex": turnIndex,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        }

        mutating func restore(_ json: String) {
            guard let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object)
            else { return }
            if let id = JSONValue.string(obj["sessionId"]), !id.isEmpty { sessionId = id }
            cwd = JSONValue.string(obj["cwd"])
            model = JSONValue.string(obj["model"])
            lastUsageFingerprint = JSONValue.string(obj["lastUsageFingerprint"])
            lastTurnId = JSONValue.string(obj["lastTurnId"])
            turnIndex = JSONValue.int(obj["turnIndex"]) ?? turnIndex
        }
    }

    static func turnIdentity(root: [String: Any], payload: [String: Any]) -> String? {
        let info = JSONValue.object(payload["info"]) ?? [:]
        if let id = JSONValue.string(info["turn_id"]), !id.isEmpty { return id }
        if let id = JSONValue.string(payload["turn_id"]), !id.isEmpty { return id }
        if let id = JSONValue.string(root["id"]), !id.isEmpty { return id }
        return nil
    }

    /// Session header / first turn_context model. Never `"unknown"`.
    static func configuredModel(_ payload: [String: Any]) -> String? {
        if let m = JSONValue.string(payload["model"]), isRealModel(m) { return m }
        if let m = JSONValue.string(payload["current_model"]), isRealModel(m) { return m }
        if let config = JSONValue.object(payload["config"]),
           let m = JSONValue.string(config["model"]), isRealModel(m)
        {
            return m
        }
        return nil
    }

    private static func isRealModel(_ model: String) -> Bool {
        !model.isEmpty && model.lowercased() != "unknown"
    }

    /// Per-turn buckets only (`last_token_usage`). Cumulative `total_token_usage` would double-count.
    static func eventFromTokenCount(
        root: [String: Any],
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        model: String?
    ) -> UsageEvent? {
        let info = JSONValue.object(payload["info"]) ?? [:]
        guard let last = JSONValue.object(info["last_token_usage"]) else { return nil }
        let input = JSONValue.int(last["input_tokens"]) ?? 0
        let output = JSONValue.int(last["output_tokens"]) ?? 0
        let cached = JSONValue.int(last["cached_input_tokens"]) ?? 0
        let reasoning = JSONValue.int(last["reasoning_output_tokens"]) ?? 0
        if input == 0 && output == 0 && cached == 0 && reasoning == 0 { return nil }
        let occurredAt = parseTimestamp(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))
        let resolvedModel: String? = {
            if let m = JSONValue.string(info["model"]), isRealModel(m) { return m }
            if let m = JSONValue.string(payload["model"]), isRealModel(m) { return m }
            if let model, isRealModel(model) { return model }
            return nil
        }()
        guard let resolvedModel else { return nil }
        let promptId = PromptHash.syntheticPromptId(
            sessionId: sessionId,
            timestamp: occurredAt,
            model: resolvedModel,
            inputTokens: input,
            outputTokens: output
        )
        return UsageEvent(
            source: "codex-local",
            sessionId: sessionId,
            promptId: promptId,
            model: resolvedModel,
            occurredAt: occurredAt,
            provider: "openai",
            cwd: cwd,
            sessionTitle: nil,
            agentName: nil,
            stopReason: nil,
            modelCalls: 1,
            apiDurationMs: nil,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cached,
            cacheCreationTokens: 0,
            reasoningTokens: reasoning,
            costUsdTicks: nil
        )
    }

    private static func sessionIdFromFilename(_ name: String) -> String {
        let stem = name.replacingOccurrences(of: ".jsonl", with: "")
        if let range = stem.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(stem[range])
        }
        return stem
    }

    private static func parseTimestamp(_ any: Any?) -> String? {
        if let s = JSONValue.string(any) {
            if let date = UTC.parse(s) { return UTC.iso(date) }
            return s
        }
        if let i = JSONValue.int64(any) {
            return UTC.iso(Date(timeIntervalSince1970: TimeInterval(i)))
        }
        return nil
    }
}
