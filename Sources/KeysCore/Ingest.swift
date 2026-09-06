import CryptoKit
import Darwin
import Foundation

enum Ingest {
    enum Source: String {
        case all, grok, claude, openai
    }

    static func run(
        source: Source,
        grokHome: URL,
        claudeHome: URL,
        codexHome: URL,
        db: CatalogDB
    ) throws -> [(name: String, report: IngestReport)] {
        var out: [(name: String, report: IngestReport)] = []
        if source == .all || source == .grok {
            out.append(("grok", try GrokIngest.run(home: grokHome, db: db)))
        }
        if source == .all || source == .claude {
            out.append(("claude", try ClaudeIngest.run(home: claudeHome, db: db)))
        }
        if source == .all || source == .openai {
            out.append(("openai", try CodexIngest.run(home: codexHome, db: db)))
        }
        return out
    }
}

enum IngestScheduler {
    static let repeatingInterval: TimeInterval = 5 * 60
    static let staleInterval: TimeInterval = 60

    /// Ingest work never runs on the run loop that owns the menu bar. The timer only enqueues;
    /// a serial utility queue does the reading, and a tick that finds the previous pass still
    /// running is skipped rather than queued behind it.
    static let queue = DispatchQueue(label: "keysreallysafe.ingest", qos: .utility)
    private static let inFlight = NSLock()
    nonisolated(unsafe) private static var running = false

    static func scheduleRepeating(service: KeysService, interval: TimeInterval = repeatingInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            enqueue(service: service)
        }
        RunLoop.current.add(timer, forMode: .common)
    }

    /// Returns false when a pass is already running.
    @discardableResult
    static func enqueue(service: KeysService, completion: (() -> Void)? = nil) -> Bool {
        inFlight.lock()
        if running {
            inFlight.unlock()
            return false
        }
        running = true
        inFlight.unlock()
        queue.async {
            _ = try? service.ingest(.all)
            inFlight.lock()
            running = false
            inFlight.unlock()
            completion?()
        }
        return true
    }
}

struct JsonlCursor {
    var size: Int64
    var mtimeMs: Int64
    var byteOffset: Int64
    var tailSig: String? = nil
    var parserJSON: String? = nil
    var replayed: Bool = false
}

enum IngestFiles {
    /// Bytes read per syscall. A multi-gigabyte rollout is never held in memory at once.
    static let defaultChunkBytes = 1 << 20
    /// Kept lines delivered between `flush` calls. Each flush is one transaction with its cursor.
    static let defaultBatchLines = 2_000

    /// Streams complete new jsonl lines. `nil` means size and mtime are unchanged.
    /// Does not write `ingest_files`; commit the returned cursor after the rows are inserted.
    /// When `flush` is given it is called every `batchLines` kept lines with a cursor that is
    /// valid at that byte offset, so the caller can insert what it has and commit the cursor in
    /// one transaction. A crash between batches costs at most one batch of re-reading.
    /// Cursor metadata is the fstat of the snapshot actually read, not a later path stat.
    static func processNewBytes(
        url: URL,
        db: CatalogDB,
        keepLine: ((UnsafeBufferPointer<UInt8>) -> Bool)? = nil,
        prepare: ((Bool) -> Void)? = nil,
        chunkBytes: Int = defaultChunkBytes,
        batchLines: Int = defaultBatchLines,
        flush: ((JsonlCursor) throws -> Void)? = nil,
        each: (String) throws -> Void
    ) throws -> JsonlCursor? {
        let path = url.standardizedFileURL.path
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attrs = try fstatHandle(handle)
        let prev = try db.ingestFile(path: path)
        if let prev, prev.size == attrs.size, prev.mtimeMs == attrs.mtimeMs {
            return nil
        }
        var from: Int64 = 0
        var replayed = true
        if let prev {
            let shrank = attrs.size < prev.size || prev.byteOffset > attrs.size
            let rewritten = attrs.size == prev.size && prev.mtimeMs != attrs.mtimeMs
            if shrank || rewritten {
                from = 0
            } else if prev.byteOffset > 0,
                      try tailMatches(handle: handle, offset: prev.byteOffset, sig: prev.tailSig),
                      try isLineBoundary(handle: handle, offset: prev.byteOffset, fileSize: attrs.size)
            {
                from = prev.byteOffset
                replayed = false
            } else {
                from = 0
            }
        }
        prepare?(replayed)
        let snapshotBytes = max(0, attrs.size - from)
        // A batch cursor records only the bytes consumed as its size. Recording the snapshot's
        // full size mid-file would make the next pass call the file unchanged and skip the rest.
        func cursor(at offset: Int64, final: Bool) throws -> JsonlCursor {
            JsonlCursor(
                size: final ? attrs.size : offset,
                mtimeMs: attrs.mtimeMs,
                byteOffset: offset,
                tailSig: try readTailSig(handle: handle, offset: offset),
                replayed: replayed
            )
        }
        let newOffset = try forEachCompleteLine(
            handle: handle,
            from: from,
            limit: snapshotBytes,
            chunkBytes: chunkBytes,
            keepLine: keepLine,
            batchLines: flush == nil ? Int.max : max(1, batchLines),
            onBatch: { offset in
                if let flush { try flush(try cursor(at: offset, final: false)) }
            },
            each: each
        )
        return try cursor(at: newOffset, final: true)
    }

    static func commit(_ cursor: JsonlCursor, url: URL, db: CatalogDB) throws {
        try db.upsertIngestFile(
            path: url.standardizedFileURL.path,
            size: cursor.size,
            mtimeMs: cursor.mtimeMs,
            byteOffset: cursor.byteOffset,
            tailSig: cursor.tailSig,
            parserJSON: cursor.parserJSON
        )
    }

    private static func fstatHandle(_ handle: FileHandle) throws -> (size: Int64, mtimeMs: Int64) {
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else {
            throw AppError.ingestIO("fstat failed")
        }
        let size = Int64(st.st_size)
        let mtimeMs = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
        return (size, mtimeMs)
    }

    private static func isLineBoundary(handle: FileHandle, offset: Int64, fileSize: Int64) throws -> Bool {
        if offset <= 0 { return true }
        if offset > fileSize { return false }
        try handle.seek(toOffset: UInt64(offset - 1))
        let prev = try handle.read(upToCount: 1) ?? Data()
        return prev.first == 0x0A
    }

    /// Versioned one-way digest of the 32 bytes before `offset`. The bytes themselves never
    /// reach the catalog: a cursor row must not let anyone reconstruct message text.
    static let tailDigestPrefix = "v2:"
    static let tailDigestWindow: Int64 = 32

    static func readTailSig(handle: FileHandle, offset: Int64) throws -> String? {
        if offset <= 0 { return "" }
        let n = Int(min(offset, tailDigestWindow))
        try handle.seek(toOffset: UInt64(offset) - UInt64(n))
        let data = try handle.read(upToCount: n) ?? Data()
        return tailDigest(data)
    }

    static func tailDigest(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return tailDigestPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isCurrentTailSig(_ sig: String?) -> Bool {
        guard let sig else { return false }
        return sig.isEmpty || sig.hasPrefix(tailDigestPrefix)
    }

    private static func tailMatches(handle: FileHandle, offset: Int64, sig: String?) throws -> Bool {
        guard let sig, !sig.isEmpty else { return offset == 0 }
        // A legacy reversible signature is never trusted; the file replays from zero.
        guard isCurrentTailSig(sig) else { return false }
        let expected = try readTailSig(handle: handle, offset: offset)
        return expected == sig
    }

    /// Reads `limit` bytes from `offset` in `chunkBytes` pieces and delivers each complete line.
    /// Only the unfinished tail of the current line is carried between chunks. Returns the offset
    /// just after the last complete line. `onBatch` fires after every `batchLines` kept lines with
    /// that same kind of offset; the handle position is restored afterwards, so callers may seek.
    private static func forEachCompleteLine(
        handle: FileHandle,
        from offset: Int64,
        limit: Int64,
        chunkBytes: Int,
        keepLine: ((UnsafeBufferPointer<UInt8>) -> Bool)?,
        batchLines: Int,
        onBatch: (Int64) throws -> Void,
        each: (String) throws -> Void
    ) throws -> Int64 {
        let chunk = max(1, chunkBytes)
        var remaining = max(0, limit)
        var readPos = max(0, offset)
        var carry = Data()               // bytes of that unfinished line seen so far
        var sinceBatch = 0
        var lastComplete = readPos

        func deliver(_ line: Data) throws {
            var bytes = line
            if bytes.last == 0x0D { bytes.removeLast() }
            guard !bytes.isEmpty else { return }
            let keep = try bytes.withUnsafeBytes { raw -> Bool in
                let buf = raw.bindMemory(to: UInt8.self)
                return keepLine == nil || keepLine!(buf)
            }
            guard keep else { return }
            if let s = String(data: bytes, encoding: .utf8), !s.isEmpty {
                try each(s)
                sinceBatch += 1
            }
        }

        while remaining > 0 {
            try handle.seek(toOffset: UInt64(readPos))
            let want = Int(min(Int64(chunk), remaining))
            let data = try handle.read(upToCount: want) ?? Data()
            if data.isEmpty { break }
            remaining -= Int64(data.count)
            var scanFrom = data.startIndex
            while let nl = data[scanFrom...].firstIndex(of: 0x0A) {
                var line = carry
                line.append(data[scanFrom..<nl])
                carry.removeAll(keepingCapacity: true)
                try deliver(line)
                lastComplete = readPos + Int64(nl - data.startIndex) + 1
                scanFrom = data.index(after: nl)
                if sinceBatch >= batchLines {
                    try onBatch(lastComplete)
                    sinceBatch = 0
                }
            }
            if scanFrom < data.endIndex {
                carry.append(data[scanFrom...])
            }
            readPos += Int64(data.count)
        }
        return lastComplete
    }
}
