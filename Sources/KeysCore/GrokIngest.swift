import Foundation

struct SessionSummary {
    var cwd: String?
    var title: String?
    var agentName: String?
    var currentModelId: String?
}

enum GrokIngest {
    private static let turnCompleted = Array(#""sessionUpdate":"turn_completed""#.utf8)

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
        guard let enumerator else {
            throw AppError.ingestIO("cannot enumerate \(sessions.path)")
        }

        var summaryCache: [String: SessionSummary] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "updates.jsonl" else { continue }
            report.filesScanned += 1
            let summary = loadSummary(dir: url.deletingLastPathComponent(), cache: &summaryCache)
            let sessionFallback = url.deletingLastPathComponent().lastPathComponent
            do {
                var pending: [UsageEvent] = []
                func flush(_ cursor: JsonlCursor) throws {
                    try db.withTransaction {
                        for event in pending {
                            switch try db.insertUsage(event) {
                            case .inserted: report.rowsInserted += 1
                            case .updated: report.rowsUpdated += 1
                            case .duplicate: report.skippedDupes += 1
                            }
                        }
                        try IngestFiles.commit(cursor, url: url, db: db)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
                guard let cursor = try IngestFiles.processNewBytes(
                    url: url,
                    db: db,
                    keepLine: { $0.firstRange(of: turnCompleted) != nil },
                    flush: flush,
                    each: { line in
                        do {
                            pending.append(contentsOf: try parseLine(line, sessionDirName: sessionFallback, summary: summary))
                        } catch {
                            report.parseErrors += 1
                        }
                    }
                ) else { continue }
                try flush(cursor)
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    static func parseLine(_ line: String, sessionDirName: String, summary: SessionSummary?) throws -> [UsageEvent] {
        guard let data = line.data(using: .utf8) else { throw AppError.ingestIO("utf8") }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.ingestIO("json")
        }
        guard let root = JSONValue.object(obj),
              let params = JSONValue.object(root["params"]),
              let update = JSONValue.object(params["update"]),
              JSONValue.string(update["sessionUpdate"]) == "turn_completed"
        else {
            return []
        }

        let sessionId = JSONValue.string(params["sessionId"]) ?? sessionDirName
        let occurredAt = parseTimestamp(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))
        let stopReason = JSONValue.string(update["stop_reason"])
        let usage = JSONValue.object(update["usage"]) ?? [:]
        let promptFromUpdate = JSONValue.string(update["prompt_id"])

        let modelUsage = JSONValue.object(usage["modelUsage"]) ?? [:]
        var buckets: [(model: String, usage: [String: Any])] = []
        if !modelUsage.isEmpty {
            for (model, raw) in modelUsage {
                let name = model.isEmpty ? "unknown" : model
                buckets.append((name, JSONValue.object(raw) ?? [:]))
            }
        } else {
            let fallback = summary?.currentModelId?.isEmpty == false ? summary!.currentModelId! : "unknown"
            buckets.append((fallback, usage))
        }

        return buckets.compactMap { pair in
            let b = pair.usage
            let input = JSONValue.int(b["inputTokens"]) ?? 0
            let output = JSONValue.int(b["outputTokens"]) ?? 0
            let cachedRead = JSONValue.int(b["cachedReadTokens"]) ?? 0
            let cacheCreate = JSONValue.int(b["cacheCreationTokens"]) ?? 0
            let reasoning = JSONValue.int(b["reasoningTokens"]) ?? 0
            let ticks = JSONValue.int64(b["costUsdTicks"])
            if input == 0 && output == 0 && cachedRead == 0 && cacheCreate == 0
                && reasoning == 0 && (ticks ?? 0) == 0
            {
                return nil
            }
            let model = pair.model.isEmpty ? "unknown" : pair.model
            let promptId = promptFromUpdate ?? PromptHash.syntheticPromptId(
                sessionId: sessionId,
                timestamp: occurredAt,
                model: model,
                inputTokens: input,
                outputTokens: output
            )
            return UsageEvent(
                source: "grok-local",
                sessionId: sessionId,
                promptId: promptId,
                model: model,
                occurredAt: occurredAt,
                provider: "xai",
                cwd: summary?.cwd,
                sessionTitle: summary?.title,
                agentName: summary?.agentName,
                stopReason: stopReason,
                modelCalls: JSONValue.int(b["modelCalls"]),
                apiDurationMs: JSONValue.int(b["apiDurationMs"]),
                inputTokens: input,
                outputTokens: output,
                cachedReadTokens: cachedRead,
                cacheCreationTokens: cacheCreate,
                reasoningTokens: reasoning,
                costUsdTicks: ticks
            )
        }
    }

    static func loadSummary(dir: URL) -> SessionSummary? {
        var cache: [String: SessionSummary] = [:]
        return loadSummary(dir: dir, cache: &cache)
    }

    private static func loadSummary(dir: URL, cache: inout [String: SessionSummary]) -> SessionSummary? {
        let key = dir.path
        if let cached = cache[key] { return cached }
        let url = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = JSONValue.object(obj)
        else {
            cache[key] = SessionSummary()
            return cache[key]
        }
        let info = JSONValue.object(root["info"])
        let summary = SessionSummary(
            cwd: JSONValue.string(info?["cwd"]),
            title: JSONValue.string(root["generated_title"]),
            agentName: JSONValue.string(root["agent_name"]),
            currentModelId: JSONValue.string(root["current_model_id"])
        )
        cache[key] = summary
        return summary
    }

    private static func parseTimestamp(_ any: Any?) -> String? {
        if let i = JSONValue.int64(any) {
            return UTC.iso(Date(timeIntervalSince1970: TimeInterval(i)))
        }
        if let d = any as? Double {
            return UTC.iso(Date(timeIntervalSince1970: d))
        }
        if let s = JSONValue.string(any) {
            if let date = UTC.parse(s) { return UTC.iso(date) }
            return s
        }
        return nil
    }
}
