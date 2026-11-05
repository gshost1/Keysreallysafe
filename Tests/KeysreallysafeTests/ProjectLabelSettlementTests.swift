import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// A project's label is derived from the whole table (the folder name alone, or qualified
/// when two folders share it). `upsertProject` inserted with a blank label and then
/// relabelled in separate autocommits, so a crash between them left a row whose label is
/// `""`, and a second process's relabel could overwrite the first's with a label that
/// ignored the row it had not seen. A blank label is not a display name: `revokeProjectClients`
/// looks a project up by label and cannot find `""`.
final class ProjectLabelSettlementTests: XCTestCase {

    private func exec(_ path: URL, _ sql: String) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(raw)))
    }

    /// A row left blank by a crash between the insert and the relabel is healed when the
    /// table is read, not only when that same path is upserted again.
    func testAStrandedBlankLabelIsHealedOnRead() throws {
        let (db, _) = try makeDB()
        _ = try db.upsertProject(canonicalPath: "/Users/x/work/api", now: "2026-11-04T00:00:00Z")
        // The crash window: a row inserted with the placeholder label and nothing after it.
        try exec(db.path, "UPDATE projects SET label = '';")

        let listed = try db.projects()
        XCTAssertEqual(listed.map(\.label), ["api"], "reading the table settles the label")

        let byID = try db.project(id: listed[0].id)
        XCTAssertEqual(byID?.label, "api")
    }

    /// The same heal through the single-row read `revokeProjectClients` uses.
    func testBlankLabelSettlesOnTheSingleRowRead() throws {
        let (db, _) = try makeDB()
        let row = try db.upsertProject(canonicalPath: "/Users/x/work/billing", now: "2026-11-04T00:00:00Z")
        try exec(db.path, "UPDATE projects SET label = '';")
        XCTAssertEqual(try db.project(id: row.id)?.label, "billing")
    }

    /// Two folders that share a name are qualified, and a row inserted while the table held
    /// only one of them has to be relabelled — not left as the bare name that is now
    /// ambiguous.
    func testTheFirstRowIsQualifiedWhenASecondFolderCollides() throws {
        let (db, _) = try makeDB()
        let first = try db.upsertProject(canonicalPath: "/Users/x/alpha/api", now: "2026-11-04T00:00:00Z")
        XCTAssertEqual(first.label, "api")
        _ = try db.upsertProject(canonicalPath: "/Users/x/beta/api", now: "2026-11-04T00:00:05Z")

        let labels = try db.projects().map(\.label)
        XCTAssertEqual(labels, ["api (alpha)", "api (beta)"], "both rows carry a qualifier, in insertion order")
    }

    /// The insert and the relabel are one transaction: a catalog read from another
    /// connection never sees a blank label for a row that exists.
    func testARowIsNeverVisibleWithABlankLabel() throws {
        let (db, _) = try makeDB()
        sqlite3_busy_timeout(nil, 0)
        let row = try db.upsertProject(canonicalPath: "/Users/x/one/tools", now: "2026-11-04T00:00:00Z")
        XCTAssertFalse(row.label.isEmpty, "the returned row is already settled")

        // A second connection over the same file, opened after the write committed: the row
        // is complete, with a label and an updated_at that moved with it.
        let other = try CatalogDB(path: db.path)
        let seen = try other.projects().first
        XCTAssertEqual(seen?.label, "tools")
        XCTAssertEqual(seen?.updatedAt, "2026-11-04T00:00:00Z")
    }
}
