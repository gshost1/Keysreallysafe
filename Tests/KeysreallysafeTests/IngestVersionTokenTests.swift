import Foundation
import XCTest
@testable import KeysCore

/// The dashboard polls `catalog_version` and reloads the chart when it moves. The bump
/// used to happen after `Ingest.run` had already committed its batches, so a crash or a
/// kill in that window left the new rows and cursors durable with the old version: the
/// next pass saw idle files, changed nothing, and never bumped. The rows themselves were
/// fine — only the open chart stopped moving.
final class IngestVersionTokenTests: XCTestCase {

    private func claudeWorld() throws -> (home: URL, file: URL) {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/-tmp-versioned", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try (assistantLine(uuid: "v1", output: 2) + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (home, file)
    }

    /// The bump belongs to the transaction that stored the rows: a pass that goes through
    /// `ClaudeIngest.run` alone — the shape of a crash before the service's own bump —
    /// must already have moved the version.
    func testTheVersionMovesWithTheRowsNotAfterThePass() throws {
        let (home, _) = try claudeWorld()
        let (db, _) = try makeDB()
        XCTAssertEqual(try db.catalogVersion(), 0)
        let report = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(report.rowsInserted, 1)
        XCTAssertGreaterThan(try db.catalogVersion(), 0, "the rows are durable and the version moved with them")
    }

    /// A pass that finds nothing new must not bump: an idle poll would reload the chart on
    /// every tick.
    func testAnIdlePassLeavesTheVersionAlone() throws {
        let (home, _) = try claudeWorld()
        let (db, _) = try makeDB()
        _ = try ClaudeIngest.run(home: home, db: db)
        let version = try db.catalogVersion()
        let again = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(again.handledRows, 0)
        XCTAssertEqual(try db.catalogVersion(), version, "nothing changed, nothing to reload")
    }

    /// Every batch that stores rows moves the version in its own transaction. A pass
    /// killed after a mid-file batch has then already moved it for the rows that batch
    /// made durable; bumping only once per file left those rows invisible to an open
    /// dashboard when the rest of the file held nothing new. The dashboard polls, so
    /// several bumps between two polls are still one reload.
    func testEveryBatchThatStoresRowsMovesTheVersion() throws {
        let (db, _) = try makeDB()
        assertBumps(lines: IngestFiles.defaultBatchLines * 2 + 17, expected: 3, db: db)
        let (exact, _) = try makeDB()
        assertBumps(lines: IngestFiles.defaultBatchLines * 2, expected: 2, db: exact)
    }

    private func assertBumps(lines count: Int, expected: Int, db: CatalogDB, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let home = try TempDir.make()
            let project = home.appendingPathComponent("projects/-tmp-batched", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var text = ""
            for i in 0..<count { text += assistantLine(uuid: "b\(i)", output: 1) + "\n" }
            try text.write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

            let report = try ClaudeIngest.run(home: home, db: db)
            XCTAssertEqual(report.rowsInserted, count, "every batch landed", file: file, line: line)
            XCTAssertEqual(try db.catalogVersion(), expected, "one bump per batch that stored rows, none for an empty one",
                           file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
