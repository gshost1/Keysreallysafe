import Foundation

struct SessionSummary {
    var cwd: String?
    var title: String?
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

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "updates.jsonl" else { continue }
            report.filesScanned += 1
            let dir = url.deletingLastPathComponent()
            let summary = loadSummary(dir: dir)
            do {
                report.add(try IngestFiles.ingest(url, db: db, keepLine: { $0.firstRange(of: turnCompleted) != nil }) {
                    try parseLine($0, sessionDirName: dir.lastPathComponent, summary: summary)
                })
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    static func parseLine(_ line: String, sessionDirName: String, summary: SessionSummary?) throws -> [UsageEvent] {
        guard let root = try JSONValue.line(line),
              let params = JSONValue.object(root["params"]),
              let update = JSONValue.object(params["update"]),
              JSONValue.string(update["sessionUpdate"]) == "turn_completed"
        else {
            return []
        }

        let sessionId = JSONValue.string(params["sessionId"]) ?? sessionDirName
        let occurredAt = UTC.normalize(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))
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
                modelCalls: JSONValue.int(b["modelCalls"]),
                inputTokens: input,
                outputTokens: output,
                cachedReadTokens: cachedRead,
                cacheCreationTokens: cacheCreate,
                reasoningTokens: reasoning,
                costUsdTicks: ticks
            )
        }
    }

    /// The session's summary.json, read once per updates.jsonl; an empty summary if absent.
    private static func loadSummary(dir: URL) -> SessionSummary {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("summary.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object)
        else { return SessionSummary() }
        let info = JSONValue.object(root["info"])
        return SessionSummary(
            cwd: JSONValue.string(info?["cwd"]),
            title: JSONValue.string(root["generated_title"]),
            currentModelId: JSONValue.string(root["current_model_id"])
        )
    }
}
