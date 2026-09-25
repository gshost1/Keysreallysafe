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
            let fresh = LineParser(sessionId: sessionIdFromFilename(name))
            var parser = fresh
            do {
                // The parser state is committed with every batch cursor, so a resume mid-file
                // restores exactly the state that produced that offset.
                report.add(try IngestFiles.ingest(
                    item, db: db,
                    restore: { json in
                        parser = json.flatMap { try? JSONDecoder().decode(LineParser.self, from: Data($0.utf8)) } ?? fresh
                    },
                    state: { (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
                ) { line in parser.consume(line).map { [$0] } ?? [] })
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    struct LineParser: Codable {
        var sessionId: String
        var cwd: String?
        var model: String?
        var lastUsageFingerprint: String?
        var lastTurnId: String?
        var turnIndex: Int = 0

        mutating func consume(_ line: String) -> UsageEvent? {
            guard let root = try? JSONValue.line(line) else { return nil }
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
        let occurredAt = UTC.normalize(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))
        let resolvedModel: String? = {
            if let m = JSONValue.string(info["model"]), isRealModel(m) { return m }
            if let m = JSONValue.string(payload["model"]), isRealModel(m) { return m }
            if let model, isRealModel(model) { return model }
            return nil
        }()
        guard let resolvedModel else { return nil }
        // LineParser.consume sets the prompt id from the turn.
        return UsageEvent(
            source: "codex-local",
            sessionId: sessionId,
            promptId: "",
            model: resolvedModel,
            occurredAt: occurredAt,
            provider: "openai",
            cwd: cwd,
            modelCalls: 1,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cached,
            reasoningTokens: reasoning
        )
    }

    static func sessionIdFromFilename(_ name: String) -> String {
        let stem = name.replacingOccurrences(of: ".jsonl", with: "")
        if let range = stem.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(stem[range])
        }
        return stem
    }
}
