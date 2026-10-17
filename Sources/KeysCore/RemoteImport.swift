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

    /// The highest token count one bucket of one remote line may carry. An export is made from
    /// real usage, and a trillion tokens in a single request is not that; a larger or negative
    /// figure is a corrupt or hostile file, and one such row would otherwise sit in the catalog
    /// and poison every total that adds it.
    static let maxBucketTokens: Int64 = 1_000_000_000_000
    /// Session and prompt ids come from the file, so their length is capped like any input.
    static let maxIdLength = 128
    /// A file written this recently may still be growing; the drop folder leaves it for the next pass.
    static let settleSeconds: TimeInterval = 10

    private static let badLine = AppError.ingestIO("bad remote usage line")

    /// `followSymlinks` is true for a path the user typed, false for the drop folder, where a
    /// link could point anywhere. Either way only a regular file within the cap is read, and the
    /// size is taken from the opened descriptor, so a link cannot report its own size instead.
    static func importFile(_ url: URL, db: CatalogDB, followSymlinks: Bool = true) throws -> IngestReport {
        let data = try readBounded(url, followSymlinks: followSymlinks)
        var report = IngestReport()
        report.filesScanned = 1
        var requests: [UsageEvent] = []
        var totals: [String: UsageEvent] = [:]
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.allSatisfy(\.isWhitespace) { continue }
            do {
                switch try parseLine(line) {
                case .request(let event)?: requests.append(event)
                case .sessionTotal(let event)?:
                    // Two totals for one session: the later one is the session's final figure.
                    if totals.updateValue(event, forKey: event.sessionId) != nil { report.rowsSkipped += 1 }
                case nil: continue
                }
            } catch {
                report.parseErrors += 1
            }
        }

        try db.withTransaction {
            // A line this Mac's own logs already hold is the same call; importing this Mac's
            // export would otherwise count every request twice, once local and once cloud.
            let known = try localDuplicates(of: requests, db: db)
            let fresh = requests.filter { !known.contains(duplicateKey($0)) }
            report.rowsSkipped += requests.count - fresh.count

            // A session's per-request rows are the better record, so its total only covers
            // what they do not: the residual, per bucket, kept as one `unattributed` row and
            // dropped once the rows account for the whole total.
            let sessions = Set(fresh.filter { $0.source == droidSource }.map(\.sessionId)).union(totals.keys)
            var before: [String: SessionState] = [:]
            for session in sessions { before[session] = try sessionState(session, db: db) }
            for event in fresh {
                if try db.insertUsage(event) { report.rowsInserted += 1 } else { report.rowsUpdated += 1 }
            }
            for session in sessions.sorted() {
                guard let old = before[session] else { continue }
                let now = try sessionState(session, db: db)
                let total = totals[session]
                if total == nil && now.rows == old.rows { continue }
                let target: Buckets
                if let total {
                    target = Buckets(total).minus(now.rows)
                } else if let stored = old.total {
                    target = Buckets(stored).minus(now.rows.minus(old.rows, clamp: false), clamp: true)
                } else {
                    continue
                }
                if target.isZero {
                    try db.deleteUsage(source: droidSource, sessionId: session,
                                       promptId: completionPrefix + session, model: unattributedModel)
                    if total != nil { report.rowsSkipped += 1 }
                    continue
                }
                guard var row = total ?? old.total else { continue }
                target.apply(to: &row)
                let inserted = try db.insertUsage(row)
                if total != nil {
                    if inserted { report.rowsInserted += 1 } else { report.rowsUpdated += 1 }
                }
            }
        }
        return report
    }

    /// What a session holds under droid-remote: the per-request rows' buckets and the
    /// `unattributed` total or residual row, if any.
    private struct SessionState {
        var rows = Buckets()
        var total: UsageEvent?
    }

    private static func sessionState(_ session: String, db: CatalogDB) throws -> SessionState {
        var state = SessionState()
        for event in try db.usageRows(source: droidSource, sessionId: session) {
            if event.promptId == completionPrefix + session && event.model == unattributedModel {
                state.total = event
            } else {
                state.rows = state.rows.plus(Buckets(event))
            }
        }
        return state
    }

    /// The five token buckets, added with saturation and subtracted without going below zero.
    private struct Buckets: Equatable {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0

        init() {}
        init(_ e: UsageEvent) {
            input = e.inputTokens; output = e.outputTokens; cacheRead = e.cachedReadTokens
            cacheWrite = e.cacheCreationTokens; reasoning = e.reasoningTokens
        }

        var isZero: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && reasoning == 0 }

        func plus(_ o: Buckets) -> Buckets {
            var r = Buckets()
            r.input = input.saturatingAdding(o.input); r.output = output.saturatingAdding(o.output)
            r.cacheRead = cacheRead.saturatingAdding(o.cacheRead); r.cacheWrite = cacheWrite.saturatingAdding(o.cacheWrite)
            r.reasoning = reasoning.saturatingAdding(o.reasoning)
            return r
        }

        /// `self - o` per bucket. A bucket the rows over-cover is zero, not negative; with
        /// `clamp` false the raw difference is kept (a delta between two sums).
        func minus(_ o: Buckets, clamp: Bool = true) -> Buckets {
            func sub(_ a: Int, _ b: Int) -> Int {
                let (r, overflow) = a.subtractingReportingOverflow(b)
                let value = overflow ? (b > 0 ? Int.min : Int.max) : r
                return clamp ? max(0, value) : value
            }
            var r = Buckets()
            r.input = sub(input, o.input); r.output = sub(output, o.output)
            r.cacheRead = sub(cacheRead, o.cacheRead); r.cacheWrite = sub(cacheWrite, o.cacheWrite)
            r.reasoning = sub(reasoning, o.reasoning)
            return r
        }

        func apply(to e: inout UsageEvent) {
            e.inputTokens = input; e.outputTokens = output; e.cachedReadTokens = cacheRead
            e.cacheCreationTokens = cacheWrite; e.reasoningTokens = reasoning
        }
    }

    private static func duplicateKey(_ event: UsageEvent) -> String {
        "\(event.source)\u{1f}\(event.promptId)\u{1f}\(event.model)"
    }

    private static func localSource(for remote: String) -> String? {
        switch remote {
        case droidSource: return "droid-local"
        case claudeSource: return "claude-local"
        default: return nil
        }
    }

    /// `duplicateKey`s of the requests whose (prompt id, model) the matching local source holds.
    private static func localDuplicates(of requests: [UsageEvent], db: CatalogDB) throws -> Set<String> {
        var wanted: [String: [String]] = [:]
        for event in requests {
            if let local = localSource(for: event.source) { wanted[local, default: []].append(event.promptId) }
        }
        var found = Set<String>()
        for (local, ids) in wanted {
            let unique = Array(Set(ids))
            for start in stride(from: 0, to: unique.count, by: 400) {
                let chunk = Array(unique[start..<min(start + 400, unique.count)])
                for (prompt, model) in try db.usagePromptModels(source: local, promptIds: chunk) {
                    let remote = local == "droid-local" ? droidSource : claudeSource
                    found.insert("\(remote)\u{1f}\(prompt)\u{1f}\(model)")
                }
            }
        }
        return found
    }

    /// Opens first, then asks the descriptor: the kind and size cannot change between the check
    /// and the read, a FIFO or device is refused without blocking, and the read itself stops at
    /// the cap whatever the file claims.
    private static func readBounded(_ url: URL, followSymlinks: Bool) throws -> Data {
        let name = url.lastPathComponent
        var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        if !followSymlinks { flags |= O_NOFOLLOW }
        let fd = open(url.path, flags)
        if fd < 0 {
            switch errno {
            case ENOENT: throw AppError.ingestIO("no such file")
            case EACCES, EPERM: throw AppError.ingestIO("permission denied")
            case ELOOP: throw AppError.usage("a symbolic link, not a regular file")
            default: throw AppError.ingestIO("cannot read \(name)")
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AppError.usage("not a regular file")
        }
        if info.st_size > Int64(maxFileBytes) {
            throw AppError.usage("larger than an export should be (\(info.st_size) bytes)")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AppError.ingestIO("cannot read \(name)")
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maxFileBytes {
                throw AppError.usage("larger than an export should be (over \(maxFileBytes) bytes)")
            }
        }
        return data
    }

    /// Each line is recognised by its own shape; anything else (a stream-json message, a
    /// tool call, a log record that is not usage) is skipped without being read further.
    /// A usage line must be well formed to count: whole-number buckets within `maxBucketTokens`,
    /// a timestamp that is an instant, ids within `maxIdLength`. Anything else is a parse error.
    static func parseLine(_ line: String) throws -> Line? {
        let marker = String(decoding: DroidIngest.marker, as: UTF8.self)
        if let markerRange = line.range(of: marker) {
            guard let root = try JSONValue.line(String(line[markerRange.upperBound...])) else { return nil }
            for key in ["inputTokens", "cacheReadInputTokens", "cachedTokensWritten", "outputTokens", "reasoningTokens"] {
                _ = try count(root[key])
            }
            guard var event = try DroidIngest.parseLine(line) else { return nil }
            guard line.first == "[",
                  let stamp = UTC.parse(String(line[line.index(after: line.startIndex)..<markerRange.lowerBound]))
            else { throw badLine }
            event.occurredAt = UTC.iso(stamp)
            event.source = droidSource
            try checkIds(event)
            return .request(event)
        }
        guard line.first == "{", let root = try JSONValue.line(line) else { return nil }
        switch JSONValue.string(root["type"]) {
        case "assistant":
            if let usage = JSONValue.object(JSONValue.object(root["message"])?["usage"]) {
                for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                    _ = try count(usage[key])
                }
            }
            guard var event = try ClaudeIngest.parseLine(line) else { return nil }
            guard let text = root["timestamp"] as? String, let stamp = UTC.parse(text) else { throw badLine }
            event.occurredAt = UTC.iso(stamp)
            event.source = claudeSource
            // A container's working folder says nothing about a project on this Mac.
            event.cwd = nil
            try checkIds(event)
            return .request(event)
        case "completion":
            return try completion(root).map(Line.sessionTotal)
        default:
            return nil
        }
    }

    /// `promptId` is the line's own id; a session total's is derived from the session id, so
    /// the cap on the session id already covers it.
    private static func checkIds(_ event: UsageEvent, checkPrompt: Bool = true) throws {
        if event.sessionId.count > maxIdLength || (checkPrompt && event.promptId.count > maxIdLength) { throw badLine }
    }

    /// A bucket that is absent or null is zero; one that is present must be a whole number in
    /// 0...maxBucketTokens. Booleans, floats, strings and anything past the cap are refused
    /// rather than coerced, because the reader behind them clamps a huge float to Int.max.
    private static func count(_ any: Any?) throws -> Int {
        guard let any, !(any is NSNull) else { return 0 }
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw badLine }
        switch String(cString: number.objCType) {
        case "q", "i", "s", "l":
            let value = number.int64Value
            guard value >= 0, value <= maxBucketTokens else { throw badLine }
            return Int(value)
        case "Q", "I", "S", "L":
            guard number.uint64Value <= UInt64(maxBucketTokens) else { throw badLine }
            return Int(number.uint64Value)
        default:
            throw badLine
        }
    }

    private static func completion(_ root: [String: Any]) throws -> UsageEvent? {
        guard let usage = JSONValue.object(root["usage"]),
              let session = JSONValue.string(root["session_id"]), !session.isEmpty
        else { return nil }
        let input = try count(usage["input_tokens"])
        let output = try count(usage["output_tokens"])
        let cacheRead = try count(usage["cache_read_input_tokens"])
        let cacheWrite = try count(usage["cache_creation_input_tokens"])
        let thinking = try count(usage["thinking_tokens"])
        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && thinking == 0 { return nil }
        // `factory_credits` is Factory's own unit, not tokens and not dollars, so it is not stored.
        let event = UsageEvent(
            source: droidSource,
            sessionId: session,
            promptId: completionPrefix + session,
            model: unattributedModel,
            occurredAt: try completionInstant(root["timestamp"]),
            provider: "other",
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            reasoningTokens: thinking
        )
        try checkIds(event, checkPrompt: false)
        return event
    }

    /// The stream-json completion event stamps epoch milliseconds; an ISO instant is accepted
    /// too. Anything else, or nothing, is a parse error: a row without a real time would land
    /// on 1970 and fall out of every window.
    private static func completionInstant(_ any: Any?) throws -> String {
        if let text = any as? String, let date = UTC.parse(text) { return UTC.iso(date) }
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["q", "i", "s", "l"].contains(String(cString: number.objCType))
        else { throw badLine }
        let ms = number.int64Value
        guard ms > 0, ms <= 4_102_444_800_000 else { throw badLine }
        return UTC.iso(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// Imports every regular file in `dir` that has stopped changing and moves it to
    /// `dir/imported/`, so a file is read once and the folder shows what is still waiting.
    /// Only a file that stored rows with no parse errors moves; any other stays where it is and
    /// is named in the report's `held`. Links, directories, FIFOs and devices are never read.
    static func drain(_ dir: URL, db: CatalogDB, now: Date = Date()) -> IngestReport {
        var report = IngestReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return report }
        let done = dir.appendingPathComponent("imported", isDirectory: true)
        for name in names.sorted() where !name.hasPrefix(".") {
            let file = dir.appendingPathComponent(name)
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if now.timeIntervalSince1970 - modified < settleSeconds { continue }
            do {
                let imported = try importFile(file, db: db, followSymlinks: false)
                report.add(imported)
                guard imported.parseErrors == 0, imported.handledRows > 0 else {
                    report.held.append(name)
                    continue
                }
                try fm.createDirectory(at: done, withIntermediateDirectories: true)
                var target = done.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    target = done.appendingPathComponent("\(UTC.iso(Date()).replacingOccurrences(of: ":", with: "-"))-\(name)")
                }
                try fm.moveItem(at: file, to: target)
            } catch {
                report.parseErrors += 1
                report.held.append(name)
            }
        }
        return report
    }
}
