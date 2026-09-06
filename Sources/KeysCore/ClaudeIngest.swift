import Foundation

enum ClaudeIngest {
    private static let assistantType = Array(#""type":"assistant""#.utf8)

    static func run(home: URL, db: CatalogDB) throws -> IngestReport {
        var report = IngestReport()
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: projects.path) else { return report }

        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            throw AppError.ingestIO("cannot read \(projects.path)")
        }

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if dir.lastPathComponent == "subagents" { continue }
            let files: [URL]
            do {
                files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            } catch {
                report.parseErrors += 1
                continue
            }
            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                if file.path.contains("/subagents/") { continue }
                report.filesScanned += 1
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
                            try IngestFiles.commit(cursor, url: file, db: db)
                        }
                        pending.removeAll(keepingCapacity: true)
                    }
                    guard let cursor = try IngestFiles.processNewBytes(
                        url: file,
                        db: db,
                        keepLine: { $0.firstRange(of: assistantType) != nil },
                        flush: flush,
                        each: { line in
                            do {
                                if let event = try parseLine(line) { pending.append(event) }
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
        }
        return report
    }

    static func parseLine(_ line: String) throws -> UsageEvent? {
        guard let data = line.data(using: .utf8) else { throw AppError.ingestIO("utf8") }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.ingestIO("json")
        }
        guard let root = JSONValue.object(obj),
              JSONValue.string(root["type"]) == "assistant",
              let message = JSONValue.object(root["message"]),
              let usage = JSONValue.object(message["usage"])
        else {
            return nil
        }
        guard let input = JSONValue.int(usage["input_tokens"]),
              let output = JSONValue.int(usage["output_tokens"])
        else {
            return nil
        }

        let model = JSONValue.string(message["model"]).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        if model == "<synthetic>" { return nil }

        let cacheRead = JSONValue.int(usage["cache_read_input_tokens"]) ?? 0
        let cacheCreate = JSONValue.int(usage["cache_creation_input_tokens"]) ?? 0
        if input == 0 && output == 0 && cacheRead == 0 && cacheCreate == 0 {
            return nil
        }

        let sessionId = JSONValue.string(root["sessionId"])
            ?? JSONValue.string(root["session_id"])
            ?? "unknown"
        let promptId = JSONValue.string(root["requestId"])
            ?? JSONValue.string(root["request_id"])
            ?? JSONValue.string(message["id"])
            ?? PromptHash.syntheticPromptId(
                sessionId: sessionId,
                timestamp: parseTimestamp(root["timestamp"]) ?? "",
                model: model,
                inputTokens: input,
                outputTokens: output
            )
        let occurredAt = parseTimestamp(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))

        return UsageEvent(
            source: "claude-local",
            sessionId: sessionId,
            promptId: promptId,
            model: model,
            occurredAt: occurredAt,
            provider: "anthropic",
            cwd: JSONValue.string(root["cwd"]),
            sessionTitle: nil,
            agentName: nil,
            stopReason: JSONValue.string(message["stop_reason"]),
            modelCalls: nil,
            apiDurationMs: nil,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            reasoningTokens: 0,
            costUsdTicks: nil
        )
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
