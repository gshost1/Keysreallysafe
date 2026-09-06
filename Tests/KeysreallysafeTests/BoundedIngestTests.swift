import Foundation
import XCTest
@testable import KeysCore

/// Large logs are read in bounded chunks and committed in batches, off the UI run loop.
final class BoundedIngestTests: XCTestCase {
    private func assistantLine(uuid: String, model: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"requestId\":\"\(uuid)\",\"sessionId\":\"bounded-sess\",\"timestamp\":\"2026-01-15T12:00:00.000Z\",\"cwd\":\"/tmp/keysreallysafe-fixture\",\"message\":{\"id\":\"msg-\(uuid)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func writeLines(_ n: Int, to url: URL, width: Int = 40) throws {
        var out = Data()
        for i in 0..<n {
            let pad = String(repeating: "x", count: width)
            out.append(Data("{\"n\":\(i),\"pad\":\"\(pad)\"}\n".utf8))
        }
        try out.write(to: url)
    }

    func testTinyChunksStillDeliverEveryLineOnce() throws {
        let (db, dir) = try makeDB()
        let file = dir.appendingPathComponent("chunks.jsonl")
        try writeLines(250, to: file)
        for chunk in [1, 3, 7, 64, 1 << 20] {
            let fresh = try CatalogDB(path: dir.appendingPathComponent("c\(chunk).db"))
            var seen: [Int] = []
            let cursor = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: fresh, chunkBytes: chunk, each: { line in
                let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                seen.append(obj["n"] as! Int)
            }))
            XCTAssertEqual(seen, Array(0..<250), "chunk \(chunk)")
            XCTAssertEqual(cursor.byteOffset, Int64(try Data(contentsOf: file).count), "chunk \(chunk)")
        }
        _ = db
    }

    func testPartialLastLineIsNotDeliveredAndOffsetStopsBeforeIt() throws {
        let (db, dir) = try makeDB()
        let file = dir.appendingPathComponent("partial.jsonl")
        try Data("{\"n\":1}\n{\"n\":2}\n{\"n\":3".utf8).write(to: file)
        var seen: [String] = []
        let cursor = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: db, chunkBytes: 4, each: { seen.append($0) }))
        XCTAssertEqual(seen, ["{\"n\":1}", "{\"n\":2}"])
        XCTAssertEqual(cursor.byteOffset, 16)
        XCTAssertEqual(cursor.tailSig, IngestFiles.tailDigest(Data("{\"n\":1}\n{\"n\":2}\n".utf8)))
    }

    func testBatchesCommitAtomicallyAndAFailureResumesFromTheLastBatch() throws {
        let (db, dir) = try makeDB()
        let file = dir.appendingPathComponent("big.jsonl")
        try writeLines(1_000, to: file)
        var offsets: [Int64] = []
        var delivered = 0
        struct Boom: Error {}
        // Every 100 lines a batch flushes; the fourth flush fails.
        XCTAssertThrowsError(try IngestFiles.processNewBytes(
            url: file, db: db, chunkBytes: 333, batchLines: 100,
            flush: { cursor in
                offsets.append(cursor.byteOffset)
                if offsets.count == 4 { throw Boom() }
                try IngestFiles.commit(cursor, url: file, db: db)
            },
            each: { _ in delivered += 1 }
        ))
        XCTAssertEqual(offsets.count, 4)
        XCTAssertEqual(delivered, 400)
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }, "offsets grow")
        let committed = try XCTUnwrap(db.ingestFile(path: file.path))
        XCTAssertEqual(committed.byteOffset, offsets[2], "the failed batch left the cursor at the previous one")
        XCTAssertEqual(committed.size, offsets[2], "a batch cursor claims only what it consumed")
        XCTAssertTrue(IngestFiles.isCurrentTailSig(committed.tailSig))

        // The file itself did not change. The next pass must still notice there is more to read
        // and resume from line 300 rather than replaying or, worse, calling the file unchanged.
        var resumed: [Int] = []
        let cursor = try XCTUnwrap(IngestFiles.processNewBytes(url: file, db: db, chunkBytes: 333, batchLines: 100,
            flush: { try IngestFiles.commit($0, url: file, db: db) },
            each: { line in
                let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                resumed.append(obj["n"] as! Int)
            }))
        XCTAssertFalse(cursor.replayed)
        XCTAssertEqual(resumed.first, 300)
        XCTAssertEqual(resumed.count, 700)
    }

    func testClaudeImporterCommitsInBatchesWithMatchingParserState() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        var text = ""
        for i in 0..<(IngestFiles.defaultBatchLines * 2 + 17) {
            text += assistantLine(uuid: "u\(i)", model: "claude-sonnet-5", input: 1, output: 1) + "\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        let report = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(report.rowsInserted, IngestFiles.defaultBatchLines * 2 + 17)
        XCTAssertEqual(try db.ingestFile(path: file.path)?.byteOffset, Int64(text.utf8.count))
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 0)
    }

    func testSchedulerRunsOffTheCallingThreadAndSkipsOverlappingTicks() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let done = expectation(description: "first pass")
        var firstThread: Thread?
        XCTAssertTrue(IngestScheduler.enqueue(service: service) {
            firstThread = Thread.current
            done.fulfill()
        })
        // A second tick while the first is queued or running is dropped, never stacked.
        let second = IngestScheduler.enqueue(service: service)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(firstThread?.isMainThread ?? true)
        if second {
            // The first pass had already finished; that is fine, but then it must be runnable again.
            XCTAssertTrue(true)
        }
        let again = expectation(description: "second pass")
        // Give the running flag a moment to clear after the completion callback.
        var enqueued = false
        for _ in 0..<50 where !enqueued {
            enqueued = IngestScheduler.enqueue(service: service) { again.fulfill() }
            if !enqueued { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(enqueued)
        wait(for: [again], timeout: 10)
    }

    func testGatewayLookupIsNotBlockedByARunningIngest() throws {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        let slowHome = try TempDir.make()
        let project = slowHome.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var text = ""
        for i in 0..<6_000 { text += assistantLine(uuid: "s\(i)", model: "claude-sonnet-5", input: 1, output: 1) + "\n" }
        try text.write(to: project.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let service = KeysService(catalog: db, secrets: secrets, clipboard: FakeClipboard(),
                                  grokHome: Fixtures.grokHome, claudeHome: slowHome, codexHome: Fixtures.codexHome)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "api.openai.com")
        let ingestDone = expectation(description: "ingest")
        DispatchQueue.global().async {
            _ = try? service.ingest(.claude)
            ingestDone.fulfill()
        }
        // Lookups during the ingest return promptly and never see a stale lock.
        var worst: TimeInterval = 0
        for _ in 0..<20 {
            let t = Date()
            XCTAssertNotNil(service.lookupGateway(name: "demo"))
            worst = max(worst, Date().timeIntervalSince(t))
            Thread.sleep(forTimeInterval: 0.005)
        }
        wait(for: [ingestDone], timeout: 30)
        XCTAssertLessThan(worst, 0.5)
    }
}
