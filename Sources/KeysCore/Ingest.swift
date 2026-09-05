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

    static func scheduleRepeating(service: KeysService, interval: TimeInterval = repeatingInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            _ = try? service.ingest(.all)
        }
        RunLoop.current.add(timer, forMode: .common)
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
    /// Streams complete new jsonl lines. `nil` means size and mtime are unchanged.
    /// Does not write `ingest_files`; commit the cursor after the rows are inserted.
    /// Cursor metadata is the fstat of the snapshot actually read, not a later path stat.
    static func processNewBytes(
        url: URL,
        db: CatalogDB,
        keepLine: ((UnsafeBufferPointer<UInt8>) -> Bool)? = nil,
        prepare: ((Bool) -> Void)? = nil,
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
        let newOffset = try forEachCompleteLine(
            handle: handle,
            from: from,
            limit: snapshotBytes,
            keepLine: keepLine,
            each: each
        )
        let tailSig = try readTailSig(handle: handle, offset: newOffset)
        return JsonlCursor(
            size: attrs.size,
            mtimeMs: attrs.mtimeMs,
            byteOffset: newOffset,
            tailSig: tailSig,
            replayed: replayed
        )
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

    private static func readTailSig(handle: FileHandle, offset: Int64) throws -> String? {
        if offset <= 0 { return "" }
        let n = Int(min(offset, 32))
        try handle.seek(toOffset: UInt64(offset) - UInt64(n))
        let data = try handle.read(upToCount: n) ?? Data()
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func tailMatches(handle: FileHandle, offset: Int64, sig: String?) throws -> Bool {
        guard let sig, !sig.isEmpty else { return offset == 0 }
        let expected = try readTailSig(handle: handle, offset: offset)
        return expected == sig
    }

    private static func forEachCompleteLine(
        handle: FileHandle,
        from offset: Int64,
        limit: Int64,
        keepLine: ((UnsafeBufferPointer<UInt8>) -> Bool)?,
        each: (String) throws -> Void
    ) throws -> Int64 {
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = try handle.read(upToCount: Int(max(0, limit))) ?? Data()
        if data.isEmpty { return offset }
        var newOffset = offset
        var error: Error?
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for i in 0..<bytes.count {
                if bytes[i] != 0x0A { continue }
                var count = i - start
                if count > 0, bytes[start + count - 1] == 0x0D { count -= 1 }
                if count > 0, let base = bytes.baseAddress {
                    let buf = UnsafeBufferPointer(start: base + start, count: count)
                    if keepLine == nil || keepLine!(buf) {
                        if let s = String(bytes: buf, encoding: .utf8), !s.isEmpty {
                            do {
                                try each(s)
                            } catch let e {
                                error = e
                                return
                            }
                        }
                    }
                }
                start = i + 1
            }
            newOffset = offset + Int64(start)
        }
        if let error { throw error }
        return newOffset
    }
}
