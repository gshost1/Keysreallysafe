import XCTest
@testable import KeysCore

final class IngestIncrementalTests: XCTestCase {
    func testUnchangedFileIsSkippedAndAppendIsIngested() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try (assistantLine(uuid: "a1", model: "claude-sonnet-5", input: 10, output: 4) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let (db, _) = try makeDB()
        let first = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(first.filesScanned, 1)
        XCTAssertEqual(first.rowsInserted, 1)

        let second = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(second.filesScanned, 1)
        XCTAssertEqual(second.rowsInserted, 0)
        XCTAssertEqual(second.skippedDupes, 0)

        let existing = try String(contentsOf: file, encoding: .utf8)
        let extra = assistantLine(uuid: "a2", model: "claude-opus-5", input: 20, output: 8)
        try (existing + extra + "\n").write(to: file, atomically: true, encoding: .utf8)

        let third = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(third.rowsInserted, 1)
        XCTAssertEqual(try db.allUsageEvents().count, 2)
        XCTAssertEqual(Set(try db.allUsageEvents().map(\.model)), ["claude-sonnet-5", "claude-opus-5"])
    }

    func testMidLineOffsetFallsBackToFullRead() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let line = assistantLine(uuid: "mid", model: "claude-sonnet-5", input: 11, output: 5)
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let (db, _) = try makeDB()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 1)

        let path = file.standardizedFileURL.path
        let prev = try XCTUnwrap(db.ingestFile(path: path))
        try db.upsertIngestFile(path: path, size: prev.size + 1, mtimeMs: prev.mtimeMs + 1, byteOffset: 3)
        let again = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.rowsUpdated, 1)
        XCTAssertEqual(try db.allUsageEvents().count, 1)
    }

    func testShrunkenFileFallsBackToFullRead() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let first = assistantLine(uuid: "s1", model: "claude-sonnet-5", input: 8, output: 2)
        let second = assistantLine(uuid: "s2", model: "claude-sonnet-5", input: 9, output: 3)
        try (first + "\n" + second + "\n").write(to: file, atomically: true, encoding: .utf8)

        let (db, _) = try makeDB()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 2)

        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let again = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.rowsUpdated, 1)
        XCTAssertEqual(try db.allUsageEvents().count, 2)
    }

    func testServiceIngestRecordsLastIngestAndVersion() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        XCTAssertNil(try db.lastIngestAt())
        XCTAssertEqual(try db.catalogVersion(), 0)
        let reports = try service.ingest(.all)
        let inserted = reports.reduce(0) { $0 + $1.report.rowsInserted }
        XCTAssertGreaterThan(inserted, 0)
        XCTAssertNotNil(try db.lastIngestAt())
        XCTAssertGreaterThan(try db.catalogVersion(), 0)
        let again = try service.ingest(.all)
        XCTAssertEqual(again.reduce(0) { $0 + $1.report.rowsInserted }, 0)
        let spend = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertEqual(spend.catalogVersion, try db.catalogVersion())
        XCTAssertEqual(spend.lastIngestAt, try db.lastIngestAt())
    }

    func testIngestIfStaleSkipsFreshRun() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        _ = try service.ingest(.all)
        let version = try db.catalogVersion()
        let stamp = try db.lastIngestAt()
        try service.ingestIfStale(olderThan: 60)
        XCTAssertEqual(try db.catalogVersion(), version)
        XCTAssertEqual(try db.lastIngestAt(), stamp)
    }

    private func assistantLine(uuid: String, model: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"requestId\":\"\(uuid)\",\"sessionId\":\"inc-sess\",\"timestamp\":\"2026-01-15T12:00:00.000Z\",\"cwd\":\"/tmp/keysreallysafe-fixture\",\"message\":{\"id\":\"msg-\(uuid)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }
}
