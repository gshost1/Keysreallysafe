import Foundation

/// Usage that happened off this Mac — a Claude Code cloud session, a Factory droid run inside
/// one — brought in as a file. Nothing here reaches out for it: the file is made where the
/// usage happened (`scripts/export-remote-usage.py` keeps only usage fields) and handed over
/// with `keys usage import` or dropped into the `imports/` folder beside the catalog.
///
/// Rows land under their own sources, `droid-remote` and `claude-remote`, so remote usage is
/// never mistaken for what this Mac's logs measured and never moves the local plan windows.
enum RemoteImport {
    static let droidSource = "droid-remote"
    static let claudeSource = "claude-remote"
    /// The model of a session total that cannot be split by model. Droid's stream-json
    /// completion event sums the whole session, and a run that fell back from Claude to
    /// kimi-k3 mid-way would otherwise put every token on the model it started with.
    static let unattributedModel = "unattributed"
    static let completionPrefix = "completion:"
    /// An export is usage lines only; anything near this size is not one.
    static let maxFileBytes = 256 << 20

    enum Line: Equatable {
        /// One request, with its model: Droid's Streaming-result record or a Claude transcript line.
        case request(UsageEvent)
        /// A whole droid session's total, from the stream-json completion event.
        case sessionTotal(UsageEvent)
    }

    static func importFile(_ url: URL, db: CatalogDB) throws -> IngestReport {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxFileBytes {
            throw AppError.usage("\(url.lastPathComponent) is larger than an export should be (\(size) bytes)")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw AppError.ingestIO("cannot read \(url.path)")
        }
        var report = IngestReport()
        report.filesScanned = 1
        var requests: [UsageEvent] = []
        var totals: [UsageEvent] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.allSatisfy(\.isWhitespace) { continue }
            do {
                switch try parseLine(line) {
                case .request(let event)?: requests.append(event)
                case .sessionTotal(let event)?: totals.append(event)
                case nil: continue
                }
            } catch {
                report.parseErrors += 1
            }
        }

        // A session's per-request rows are the better record, so a total never sits beside
        // them: it is dropped when they arrive in the same file or are already stored, and an
        // earlier-imported total is deleted when they turn up later. Either way the session's
        // tokens are counted once.
        let detailed = Set(requests.filter { $0.source == droidSource }.map(\.sessionId))
        try db.withTransaction {
            for event in requests {
                if try db.insertUsage(event) { report.rowsInserted += 1 } else { report.rowsUpdated += 1 }
            }
            for session in detailed {
                try db.deleteUsage(source: droidSource, sessionId: session,
                                   promptId: completionPrefix + session, model: unattributedModel)
            }
            for total in totals where !detailed.contains(total.sessionId) {
                if try db.usageSessionHasRows(source: droidSource, sessionId: total.sessionId,
                                              excludingPromptId: total.promptId) { continue }
                if try db.insertUsage(total) { report.rowsInserted += 1 } else { report.rowsUpdated += 1 }
            }
        }
        return report
    }

    /// Each line is recognised by its own shape; anything else (a stream-json message, a
    /// tool call, a log record that is not usage) is skipped without being read further.
    static func parseLine(_ line: String) throws -> Line? {
        if line.contains(String(decoding: DroidIngest.marker, as: UTF8.self)) {
            guard var event = try DroidIngest.parseLine(line) else { return nil }
            event.source = droidSource
            return .request(event)
        }
        guard line.first == "{", let root = try JSONValue.line(line) else { return nil }
        switch JSONValue.string(root["type"]) {
        case "assistant":
            guard var event = try ClaudeIngest.parseLine(line) else { return nil }
            event.source = claudeSource
            // A container's working folder says nothing about a project on this Mac.
            event.cwd = nil
            return .request(event)
        case "completion":
            return try completion(root).map(Line.sessionTotal)
        default:
            return nil
        }
    }

    private static func completion(_ root: [String: Any]) throws -> UsageEvent? {
        guard let usage = JSONValue.object(root["usage"]),
              let session = JSONValue.string(root["session_id"]), !session.isEmpty
        else { return nil }
        let input = JSONValue.int(usage["input_tokens"]) ?? 0
        let output = JSONValue.int(usage["output_tokens"]) ?? 0
        let cacheRead = JSONValue.int(usage["cache_read_input_tokens"]) ?? 0
        let cacheWrite = JSONValue.int(usage["cache_creation_input_tokens"]) ?? 0
        let thinking = JSONValue.int(usage["thinking_tokens"]) ?? 0
        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && thinking == 0 { return nil }
        // `factory_credits` is Factory's own unit, not tokens and not dollars, so it is not stored.
        let occurredAt = JSONValue.int(root["timestamp"]).map {
            UTC.iso(Date(timeIntervalSince1970: TimeInterval($0) / 1000))
        } ?? UTC.iso(Date(timeIntervalSince1970: 0))
        return UsageEvent(
            source: droidSource,
            sessionId: session,
            promptId: completionPrefix + session,
            model: unattributedModel,
            occurredAt: occurredAt,
            provider: "other",
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            reasoningTokens: thinking
        )
    }

    /// Imports every regular file in `dir` and moves it to `dir/imported/`, so a file is read
    /// once and the folder shows what is still waiting. A file that fails stays where it is.
    static func drain(_ dir: URL, db: CatalogDB) -> IngestReport {
        var report = IngestReport()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return report }
        let done = dir.appendingPathComponent("imported", isDirectory: true)
        for name in names.sorted() where !name.hasPrefix(".") {
            let file = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            do {
                report.add(try importFile(file, db: db))
                try fm.createDirectory(at: done, withIntermediateDirectories: true)
                var target = done.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    target = done.appendingPathComponent("\(UTC.iso(Date()).replacingOccurrences(of: ":", with: "-"))-\(name)")
                }
                try fm.moveItem(at: file, to: target)
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }
}
