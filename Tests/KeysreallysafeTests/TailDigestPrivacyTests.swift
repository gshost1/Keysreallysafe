import Foundation
import XCTest
@testable import KeysCore

/// The ingest cursor must not let anyone reconstruct message text from the catalog.
final class TailDigestPrivacyTests: XCTestCase {
    private let sentinel = "PRIVATE-MESSAGE-SENTINEL"

    func testCursorStoresOneWayDigestNotMessageBytes() throws {
        let (db, dir) = try makeDB()
        let file = dir.appendingPathComponent("sample.jsonl")
        try Data("{\"type\":\"user\",\"text\":\"\(sentinel)\"}\n".utf8).write(to: file)
        let cursor = try XCTUnwrap(
            IngestFiles.processNewBytes(url: file, db: db, keepLine: { _ in false }, each: { _ in })
        )
        try IngestFiles.commit(cursor, url: file, db: db)
        let stored = try XCTUnwrap(db.ingestFile(path: file.path)?.tailSig)
        XCTAssertTrue(stored.hasPrefix(IngestFiles.tailDigestPrefix))
        XCTAssertEqual(stored.count, IngestFiles.tailDigestPrefix.count + 64)
        // Decode the stored value both as raw text and as hex; neither may contain the message.
        XCTAssertFalse(stored.contains(sentinel))
        let hexPart = String(stored.dropFirst(IngestFiles.tailDigestPrefix.count))
        let decoded = Self.hexDecode(hexPart)
        XCTAssertFalse(String(decoding: decoded, as: UTF8.self).contains(sentinel))
        XCTAssertFalse(decoded.range(of: Data(sentinel.utf8)) != nil)
        // The whole catalog file, WAL included, must not carry the bytes either.
        for name in ["catalog.db", "catalog.db-wal"] {
            let url = dir.appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(bytes.range(of: Data(sentinel.utf8)), "\(name) holds message bytes")
            XCTAssertNil(bytes.range(of: Data(Self.hexEncode(Data(sentinel.utf8)).utf8)), "\(name) holds hex message bytes")
        }
    }

    func testDigestCursorStillResumesIncrementally() throws {
        let (db, dir) = try makeDB()
        let file = dir.appendingPathComponent("grow.jsonl")
        try Data("{\"n\":1}\n{\"n\":2}\n".utf8).write(to: file)
        var seen: [String] = []
        let first = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: db, each: { seen.append($0) }))
        try IngestFiles.commit(first, url: file, db: db)
        XCTAssertEqual(seen.count, 2)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"n\":3}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        seen.removeAll()
        let second = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: db, each: { seen.append($0) }))
        XCTAssertEqual(seen, ["{\"n\":3}"])
        XCTAssertFalse(second.replayed)
    }

    func testLegacyRawSignatureIsClearedOnOpenAndForcesReplay() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let file = dir.appendingPathComponent("legacy.jsonl")
        let line = "{\"type\":\"user\",\"text\":\"\(sentinel)\"}\n"
        try Data(line.utf8).write(to: file)
        let legacyHex = Self.hexEncode(Data(line.utf8).suffix(32))
        do {
            let db = try CatalogDB(path: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000)
            try db.upsertIngestFile(path: file.path, size: size, mtimeMs: mtime, byteOffset: size, tailSig: legacyHex)
            XCTAssertEqual(try db.ingestFile(path: file.path)?.tailSig, legacyHex)
            // A catalog written by 0.1.0 has no format marker; a marked catalog is never rescanned.
            try db.clearMeta("tail_sig_format")
        }
        let reopened = try CatalogDB(path: path)
        XCTAssertNil(try reopened.ingestFile(path: file.path)?.tailSig)
        XCTAssertEqual(try reopened.metaValue("tail_sig_format"), "v2")
        XCTAssertEqual(try reopened.metaValue("tail_sig_purged_rows"), "1")
        // A fresh catalog carries the marker too, so the purge runs at most once per file.
        let (fresh, _) = try makeDB()
        XCTAssertEqual(try fresh.metaValue("tail_sig_format"), "v2")
        for name in ["catalog.db", "catalog.db-wal"] {
            guard let bytes = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            XCTAssertNil(bytes.range(of: Data(legacyHex.utf8)), "\(name) still holds the legacy signature")
        }
        // Same size and mtime: nothing new to read. Once the file grows, the whole file replays.
        XCTAssertNil(try IngestFiles.processNewBytes(url: file, db: reopened, each: { _ in }))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"n\":2}\n".utf8))
        try handle.close()
        var count = 0
        let cursor = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: reopened, each: { _ in count += 1 }))
        XCTAssertTrue(cursor.replayed)
        XCTAssertEqual(count, 2)
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDecode(_ hex: String) -> Data {
        let chars = Array(hex)
        var out = Data()
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...(i + 1)]), radix: 16) { out.append(b) }
            i += 2
        }
        return out
    }
}
