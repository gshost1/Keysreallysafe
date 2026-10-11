import Foundation

enum DroidIngest {
    /// The exact record marker. Droid writes ~333 record types into one log, and the ones that
    /// are not this one carry message content. Matching the marker byte-for-byte is the privacy
    /// boundary: nothing else in the file is ever parsed, only counted past.
    static let marker = Array(#"] INFO: [Agent] Streaming result | Context: "#.utf8)

    static let activeLogName = "droid-log-single.log"
    static let rotatedPrefix = "droid-log-single.log."

    static func run(home: URL, db: CatalogDB) throws -> IngestReport {
        var report = IngestReport()
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logs.path) else { return report }
        for name in names.filter(isUsageLog).sorted() {
            report.filesScanned += 1
            do {
                report.add(try IngestFiles.ingest(
                    logs.appendingPathComponent(name),
                    db: db,
                    keepLine: { $0.firstRange(of: marker) != nil }
                ) { line in
                    try parseLine(line).map { [$0] } ?? []
                })
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    /// The active log plus its date-rotated copies, and nothing else in the folder: a rotation
    /// can happen mid-day, but the suffix is always a local date, so partial writes and editor
    /// temporaries that share the prefix are skipped rather than parsed.
    static func isUsageLog(_ name: String) -> Bool {
        if name == activeLogName { return true }
        guard name.hasPrefix(rotatedPrefix) else { return false }
        let suffix = String(name.dropFirst(rotatedPrefix.count))
        return suffix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func parseLine(_ line: String) throws -> UsageEvent? {
        guard let markerRange = line.range(of: String(decoding: marker, as: UTF8.self)),
              let root = try JSONValue.line(String(line[markerRange.upperBound...]))
        else { return nil }

        // `totalInputTokens` repeats input plus the cache buckets and `count` only numbers the
        // records; neither is a token of its own, so neither is read.
        let input = JSONValue.int(root["inputTokens"]) ?? 0
        let cacheRead = JSONValue.int(root["cacheReadInputTokens"]) ?? 0
        let cacheWrite = JSONValue.int(root["cachedTokensWritten"]) ?? 0
        let output = JSONValue.int(root["outputTokens"]) ?? 0
        let reasoning = JSONValue.int(root["reasoningTokens"]) ?? 0
        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && reasoning == 0 {
            return nil
        }

        let tags = JSONValue.object(root["tags"]) ?? [:]
        let model = JSONValue.string(tags["modelId"]) ?? "unknown"
        let sessionId = JSONValue.string(tags["sessionId"]) ?? "unknown"
        let occurredAt = lineTimestamp(line) ?? UTC.iso(Date(timeIntervalSince1970: 0))
        let promptId = JSONValue.string(root["upstreamResponseId"])
            ?? JSONValue.string(root["upstreamRequestId"])
            ?? PromptHash.syntheticPromptId(
                sessionId: sessionId,
                timestamp: occurredAt,
                model: model,
                inputTokens: input,
                outputTokens: output
            )
        return UsageEvent(
            source: "droid-local",
            sessionId: sessionId,
            promptId: promptId,
            model: model,
            occurredAt: occurredAt,
            provider: provider(forModel: model),
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            reasoningTokens: reasoning
        )
    }

    /// The timestamp is the bracketed UTC instant in front of the marker; a line without one
    /// still ingests (the epoch sentinel) because the token counts are what the row is for.
    private static func lineTimestamp(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"), close > open
        else { return nil }
        return UTC.normalize(String(line[line.index(after: open)..<close]))
    }

    /// The log names only the model, so the vendor comes from the id's public prefix — the
    /// same split the analytics vocabulary and the chart's family colours use.
    static func provider(forModel model: String) -> String {
        let lower = model.lowercased()
        if lower.hasPrefix("claude-") { return "anthropic" }
        if lower.hasPrefix("gpt-") || lower.hasPrefix("codex")
            || lower.range(of: #"^o[1-9]"#, options: .regularExpression) != nil { return "openai" }
        if lower.hasPrefix("gemini-") { return "google" }
        if lower.hasPrefix("grok-") { return "xai" }
        if lower.hasPrefix("glm-") { return "zhipu" }
        if lower.hasPrefix("kimi-") { return "moonshot" }
        if lower.hasPrefix("deepseek-") { return "deepseek" }
        return "other"
    }
}
