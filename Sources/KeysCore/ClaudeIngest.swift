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
            // Subagent transcripts live under <session>/subagents/agent-*.jsonl.
            // Keep the same request identity as top-level logs so copied context
            // and repeated scans update existing rows rather than add usage twice.
            guard let files = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    report.parseErrors += 1
                    return true
                }
            ) else {
                report.parseErrors += 1
                continue
            }
            while let file = files.nextObject() as? URL {
                guard file.pathExtension == "jsonl" else { continue }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                report.filesScanned += 1
                do {
                    report.add(try IngestFiles.ingest(file, db: db, keepLine: { $0.firstRange(of: assistantType) != nil }) {
                        try parseLine($0).map { [$0] } ?? []
                    })
                } catch {
                    report.parseErrors += 1
                }
            }
        }
        return report
    }

    static func parseLine(_ line: String) throws -> UsageEvent? {
        guard let root = try JSONValue.line(line),
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
                timestamp: UTC.normalize(root["timestamp"]) ?? "",
                model: model,
                inputTokens: input,
                outputTokens: output
            )
        let occurredAt = UTC.normalize(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))

        return UsageEvent(
            source: "claude-local",
            sessionId: sessionId,
            promptId: promptId,
            model: model,
            occurredAt: occurredAt,
            provider: "anthropic",
            cwd: JSONValue.string(root["cwd"]),
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate
        )
    }

}
