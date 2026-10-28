import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// Project identity: a project is one folder's canonical, symlink-resolved path, one
/// row in `projects`, and a display label. These tests pin the one resolution function,
/// the fresh and migrated schema, the label rules, the client-token round trip, the
/// readers' tolerance of a dangling reference, and the line the path never crosses:
/// no result, no log file and no analytics report carries it (labels only).
final class ProjectIdentityTests: XCTestCase {
    private let fm = FileManager.default

    /// A real folder under the temp dir, which itself sits behind macOS's
    /// `/var` → `/private/var` symlink, so every resolution also exercises that spelling.
    private func makeFolder(_ dir: URL, _ subpath: String) throws -> URL {
        let url = dir.appendingPathComponent(subpath, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService() throws -> (KeysService, CatalogDB, URL) {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        return (service, db, dir)
    }

    /// The POSIX canonical form, computed here independently of the code under test.
    private func canonical(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw AppError.usage("unresolvable") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Raw sqlite rows for schema-level assertions, the rig GatewayRetargetTests uses.
    private func rawRows(
        _ dbPath: URL, _ sql: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String]] {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK, file: file, line: line)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK, file: file, line: line)
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<Int(sqlite3_column_count(stmt))).map {
                sqlite3_column_text(stmt, Int32($0)).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    @discardableResult
    private func rawExec(
        _ dbPath: URL, _ sql: String, file: StaticString = #filePath, line: UInt = #line
    ) -> Int32 {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK, file: file, line: line)
        defer { sqlite3_close(raw) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(raw, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc
    }

    // MARK: VAL-PROJ-001 — one project per folder, across spellings

    func testCanonicalIdentity() throws {
        let (service, db, dir) = try makeService()
        let proj = try makeFolder(dir, "proj")
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: proj.path)
        let expected = try canonical(proj.path)
        XCTAssertTrue(expected.hasPrefix("/private/var/"), "the temp dir sits behind the /var symlink")

        // One folder, many spellings: the /var form, a symlink, a trailing slash, and a
        // same-directory relative spelling all resolve to the SAME project and one row.
        let viaVar = try service.resolveProject(folder: proj.path)
        XCTAssertEqual(viaVar.path, expected, "the stored path is the fully resolved real path")
        XCTAssertEqual(try service.resolveProject(folder: link.path).id, viaVar.id)
        XCTAssertEqual(try service.resolveProject(folder: proj.path + "/").id, viaVar.id)
        let originalCwd = fm.currentDirectoryPath
        guard fm.changeCurrentDirectoryPath(dir.path) else { return XCTFail("could not change cwd") }
        defer { fm.changeCurrentDirectoryPath(originalCwd) }
        XCTAssertEqual(try service.resolveProject(folder: "proj").id, viaVar.id)
        XCTAssertEqual(try service.resolveProject(folder: "./proj").id, viaVar.id)
        XCTAssertEqual(try db.projects().count, 1)

        // Resolution is stateless: repoint the symlink and the same input follows it.
        let proj2 = try makeFolder(dir, "proj2")
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: proj2.path)
        let repointed = try service.resolveProject(folder: link.path)
        XCTAssertNotEqual(repointed.id, viaVar.id)
        XCTAssertEqual(repointed.path, try canonical(proj2.path))
        XCTAssertEqual(try db.projects().count, 2)

        // Two handles over one file (the app and the MCP process) agree on every id.
        let db2 = try CatalogDB(path: db.path)
        let (service2, _) = makeGatedService(db: db2)
        XCTAssertEqual(try service2.resolveProject(folder: proj.path).id, viaVar.id)
        XCTAssertEqual(try service2.resolveProject(folder: proj2.path).id, repointed.id)
        XCTAssertEqual(try db2.projects().count, 2)

        // A folder that does not exist — or exists but is not a folder — is a plain
        // usage error, and nothing is stored for it.
        let fileURL = dir.appendingPathComponent("afile")
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)
        for bad in [dir.appendingPathComponent("nope").path, fileURL.path] {
            XCTAssertThrowsError(try service.resolveProject(folder: bad), bad) { error in
                XCTAssertEqual((error as? AppError)?.exitCode, 1, "a usage error, not a crash")
            }
        }
        XCTAssertEqual(try db.projects().count, 2, "no row for a refused folder")
    }

    // MARK: VAL-PROJ-002 — the default project is the cwd, canonicalized

    func testDefaultProjectCwd() throws {
        let (service, db, dir) = try makeService()
        let realcwd = try makeFolder(dir, "realcwd")
        let linkcwd = dir.appendingPathComponent("linkcwd")
        try fm.createSymbolicLink(atPath: linkcwd.path, withDestinationPath: realcwd.path)
        let originalCwd = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(originalCwd) }
        guard fm.changeCurrentDirectoryPath(linkcwd.path) else { return XCTFail("could not chdir into the symlinked cwd") }

        // No explicit folder: the process working directory, canonicalized.
        let viaDefault = try service.resolveProject(folder: nil)
        XCTAssertEqual(viaDefault.path, try canonical(realcwd.path))
        XCTAssertTrue(viaDefault.path.hasPrefix("/private/var/"))
        XCTAssertFalse(viaDefault.path.contains("linkcwd"), "the resolved form, not the symlink spelling")

        // The same folder given explicitly is the same project, with no new row.
        let viaExplicit = try service.resolveProject(folder: viaDefault.path)
        XCTAssertEqual(viaExplicit.id, viaDefault.id)
        XCTAssertEqual(try db.projects().count, 1)
    }

    // MARK: VAL-PROJ-003 — the fresh schema

    func testFreshDBSchema() throws {
        let (service, db, dir) = try makeService()
        let dbPath = dir.appendingPathComponent("catalog.db")

        // The projects table: a text primary key, a UNIQUE canonical path, a label, timestamps.
        let columns = try rawRows(
            dbPath, "SELECT name, type, \"notnull\", pk FROM pragma_table_info('projects');"
        )
        XCTAssertEqual(columns.map { $0[0] }, ["id", "path", "label", "created_at", "updated_at"])
        XCTAssertEqual(columns.map { $0[1] }, ["TEXT", "TEXT", "TEXT", "TEXT", "TEXT"])
        XCTAssertEqual(columns.map { $0[3] }, ["1", "0", "0", "0", "0"], "id is the text primary key")
        let create = try rawRows(
            dbPath, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'projects';"
        )
        XCTAssertTrue(create[0][0].contains("path TEXT NOT NULL UNIQUE"), create[0][0])

        // gateway_clients carries the project column from creation: no migration ran.
        let clientCols = try rawRows(
            dbPath, "SELECT name, \"notnull\" FROM pragma_table_info('gateway_clients');"
        )
        XCTAssertTrue(clientCols.contains { $0[0] == "project" && $0[1] == "0" }, "nullable from creation")
        let clientCreate = try rawRows(
            dbPath, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'gateway_clients';"
        )
        XCTAssertTrue(clientCreate[0][0].contains("project TEXT"), "the CREATE body has the column")

        // A minted id is 8 lowercase hex — the text-keyed-row convention.
        let row = try service.resolveProject(folder: try makeFolder(dir, "schemafolder").path)
        XCTAssertNotNil(row.id.wholeMatch(of: /^[0-9a-f]{8}$/), row.id)
        XCTAssertFalse(row.createdAt.isEmpty)
        XCTAssertFalse(row.updatedAt.isEmpty)
    }

    // MARK: VAL-PROJ-004 — the old DB migrated in place

    func testOldDBMigration() throws {
        let dir = try TempDir.make()
        let dbPath = dir.appendingPathComponent("catalog.db")
        let token = GatewayClientToken.generate()
        do {
            let (service, _) = makeGatedService(db: try CatalogDB(path: dbPath))
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        }
        // Rebuild gateway_clients the way the version before projects had it (the `host`
        // era, no `project` column) and drop the projects table, then reopen.
        XCTAssertEqual(rawExec(dbPath, """
            DROP TABLE gateway_clients;
            CREATE TABLE gateway_clients (
              id INTEGER PRIMARY KEY AUTOINCREMENT, key_name TEXT NOT NULL, label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE, hint TEXT NOT NULL DEFAULT '', methods TEXT NOT NULL,
              path_prefix TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT,
              host TEXT);
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at, host)
              VALUES ('demo', '\(GatewayClientToken.hash(token))', 'POST',
                      '2026-10-01T00:00:00Z', '2999-01-01T00:00:00Z', 'api.openai.com');
            DROP TABLE IF EXISTS projects;
            """), SQLITE_OK)

        let db = try CatalogDB(path: dbPath)
        let (service, _) = makeGatedService(db: db)
        let clientCols = try rawRows(dbPath, "SELECT name FROM pragma_table_info('gateway_clients');")
        XCTAssertTrue(clientCols.contains { $0[0] == "project" }, "the guarded ALTER added the column")
        XCTAssertEqual(
            try rawRows(dbPath, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'projects';").count, 1
        )

        // Every pre-existing row decodes with a null project and still authorizes unchanged.
        let clients = try db.gatewayClients(keyName: "demo")
        XCTAssertEqual(clients.count, 1)
        XCTAssertNil(clients[0].project)
        XCTAssertNil(clients[0].projectLabel)
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
        ) else { return XCTFail("the old token still authorizes") }

        let object = clients[0].jsonObject()
        XCTAssertTrue(object["project"] is NSNull, "a null project renders as null, not a placeholder")
        XCTAssertTrue(object["project_label"] is NSNull)
        XCTAssertEqual(try service.projectLabelsInUse(name: "demo"), [], "in use by no project")
    }

    // MARK: VAL-PROJ-005 — labels

    func testLabelRules() throws {
        let (service, db, dir) = try makeService()
        let dbPath = dir.appendingPathComponent("catalog.db")

        // A lone project is exactly its folder name.
        let lone = try service.resolveProject(folder: try makeFolder(dir, "work/proj").path)
        XCTAssertEqual(lone.label, "proj")

        // A colliding folder name disambiguates BOTH projects in "<folder> (<parent>)".
        let side = try service.resolveProject(folder: try makeFolder(dir, "side/proj").path)
        XCTAssertEqual(side.label, "proj (side)")
        XCTAssertEqual(try db.projects().first { $0.id == lone.id }?.label, "proj (work)")

        // A third project whose parent name also collides extends to more parent components.
        let deep = try service.resolveProject(folder: try makeFolder(dir, "c/work/proj").path)
        XCTAssertEqual(deep.label, "proj (c/work)")

        // A project whose folder name does not collide keeps the bare name.
        let other = try service.resolveProject(folder: try makeFolder(dir, "elsewhere/other").path)
        XCTAssertEqual(other.label, "other")

        // Labels are recomputed on insert, so no stored label can go stale: remove the other
        // `proj` rows by hand (only raw SQL can) and insert anything — the lone survivor's
        // label is exactly what the live collision set says.
        XCTAssertEqual(rawExec(dbPath, "DELETE FROM projects WHERE id IN ('\(side.id)', '\(deep.id)');"), SQLITE_OK)
        let later = try service.resolveProject(folder: try makeFolder(dir, "later").path)
        XCTAssertEqual(later.label, "later")
        let labels = try Dictionary(uniqueKeysWithValues: db.projects().map { ($0.id, $0.label) })
        XCTAssertEqual(labels[lone.id], "proj", "the qualifier is gone with the collision")
        XCTAssertEqual(labels[other.id], "other")
        XCTAssertEqual(labels[later.id], "later")
    }

    // MARK: VAL-PROJ-006 — path uniqueness at the storage layer

    func testPathUniqueAtStorageLayer() throws {
        let (service, db, dir) = try makeService()
        let folder = try makeFolder(dir, "unique-proj")
        let row = try service.resolveProject(folder: folder.path)
        let canonicalPath = try canonical(folder.path)
        XCTAssertEqual(row.path, canonicalPath)

        // The resolver upserts: another handle resolving the same folder gets the same id.
        let db2 = try CatalogDB(path: db.path)
        let (service2, _) = makeGatedService(db: db2)
        XCTAssertEqual(try service2.resolveProject(folder: folder.path).id, row.id)
        XCTAssertEqual(try db.projects().count, 1)

        // A duplicate insert that bypasses the resolver fails on the constraints and
        // never manufactures a second row for one folder.
        let dbPath = dir.appendingPathComponent("catalog.db")
        XCTAssertEqual(
            rawExec(
                dbPath,
                "INSERT INTO projects (id, path, label, created_at, updated_at) VALUES ('deadbeef', '\(canonicalPath)', 'x', 't', 't');"
            ), SQLITE_CONSTRAINT, "the UNIQUE path refuses a second id"
        )
        XCTAssertEqual(
            rawExec(
                dbPath,
                "INSERT INTO projects (id, path, label, created_at, updated_at) VALUES ('\(row.id)', '\(canonicalPath)-moved', 'x', 't', 't');"
            ), SQLITE_CONSTRAINT, "the primary key refuses a reused id"
        )
        XCTAssertNil(try db.project(id: "deadbeef"))
        XCTAssertEqual(try db.projects().count, 1)

        // A row caught in the gap between another process's insert and its label recompute
        // (blank label, e.g. after a crash mid-upsert) is healed by the next resolver of
        // the same folder: the winner's id, a settled label, still one row.
        let blankFolder = try makeFolder(dir, "blank-proj")
        XCTAssertEqual(
            rawExec(
                dbPath,
                "INSERT INTO projects (id, path, label, created_at, updated_at) VALUES ('cafe1234', '\(try canonical(blankFolder.path))', '', 't', 't');"
            ), SQLITE_OK
        )
        let healed = try service.resolveProject(folder: blankFolder.path)
        XCTAssertEqual(healed.id, "cafe1234", "the existing row is adopted, not duplicated")
        XCTAssertEqual(healed.label, "blank-proj", "the blank label is settled before returning")
        XCTAssertEqual(try db.projects().count, 2)
    }

    // MARK: VAL-PROJ-007 — the token's project round-trips by id and label

    func testTokenProjectRoundTrip() throws {
        let (service, db, dir) = try makeService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let folder = try makeFolder(dir, "roundtrip-proj")
        let project = try service.resolveProject(folder: folder.path)
        XCTAssertEqual(project.label, "roundtrip-proj")

        let issued = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)
        XCTAssertEqual(issued.client.project, project.id)
        XCTAssertEqual(issued.client.projectLabel, project.label)

        // Decode reads the reference back.
        let decoded = try XCTUnwrap(try db.gatewayClients(keyName: "demo").first)
        XCTAssertEqual(decoded.project, project.id)
        XCTAssertEqual(decoded.projectLabel, project.label)

        // jsonObject gains project (the id) and project_label — never the path — and
        // every pre-existing field keeps its shape, so the dashboard listing still works.
        let object = decoded.jsonObject()
        XCTAssertEqual(object.keys.sorted(), [
            "active", "created_at", "expires_at", "hint", "id", "key", "label", "last_used_at",
            "methods", "path_prefix", "project", "project_label", "revoked_at",
        ])
        XCTAssertEqual(object["project"] as? String, project.id)
        XCTAssertEqual(object["project_label"] as? String, project.label)
        let json = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(json.range(of: Data(folder.path.utf8)), "the supplied spelling never appears")
        XCTAssertNil(json.range(of: Data(project.path.utf8)), "the canonical path never appears")

        // A token with no project reports null for both.
        _ = try service.issueGatewayClient(name: "demo", label: "plain")
        let plain = try XCTUnwrap(try db.gatewayClients(keyName: "demo").last)
        XCTAssertTrue(plain.jsonObject()["project"] is NSNull)
        XCTAssertTrue(plain.jsonObject()["project_label"] is NSNull)
        XCTAssertEqual(try service.projectLabelsInUse(name: "demo"), [project.label])
    }

    // MARK: VAL-PROJ-008 — dangling references tolerated; no delete surface

    func testDanglingTolerated() throws {
        let (service, db, dir) = try makeService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let project = try service.resolveProject(folder: try makeFolder(dir, "dangle-proj").path)
        let issued = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)

        // No delete surface ships, so only raw SQL can produce a dangling reference.
        XCTAssertEqual(rawExec(dir.appendingPathComponent("catalog.db"), "DELETE FROM projects;"), SQLITE_OK)

        // Every reader returns normally and the dangling reference contributes nothing.
        let clients = try db.gatewayClients(keyName: "demo")
        XCTAssertEqual(clients.map(\.project), [project.id])
        XCTAssertEqual(clients.map(\.projectLabel), [nil])
        let object = clients[0].jsonObject()
        XCTAssertEqual(object["project"] as? String, project.id)
        XCTAssertTrue(object["project_label"] is NSNull)

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html></html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        let handler = APIHandler(service: service, webRoot: web)
        let listing = handle(handler, method: "GET", path: "/api/keys/demo/clients")
        XCTAssertEqual(listing.status, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: listing.body) as? [String: Any])
        let rows = try XCTUnwrap(body["clients"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["project"] as? String, project.id)
        XCTAssertTrue(rows[0]["project_label"] is NSNull)
        let keys = handle(handler, method: "GET", path: "/api/keys")
        XCTAssertEqual(keys.status, 200)
        XCTAssertTrue(String(decoding: keys.body, as: UTF8.self).contains("demo"), "the key still lists")

        XCTAssertEqual(try service.projectLabelsInUse(name: "demo"), [])
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: ["authorization": "Bearer " + issued.token], method: "POST", rest: "v1/x"
        ) else { return XCTFail("the reference is bookkeeping, not part of the capability") }
    }

    // MARK: VAL-PROJ-009 — key deletion cascades; the project survives; purge clears

    func testKeyDeletionAndPurge() throws {
        let (service, db, dir) = try makeService()
        try service.add(name: "one", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "two", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let shared = try service.resolveProject(folder: try makeFolder(dir, "shared-proj").path)
        _ = try service.issueGatewayClient(name: "one", label: "agent one", project: shared.id)
        _ = try service.issueGatewayClient(name: "two", label: "agent two", project: shared.id)
        XCTAssertEqual(try service.projectLabelsInUse(name: "one"), [shared.label])
        XCTAssertEqual(try service.projectLabelsInUse(name: "two"), [shared.label])

        // Deleting a key cascades its client tokens; the project row survives for the
        // key that still uses it.
        try service.remove(name: "one")
        XCTAssertEqual(try db.gatewayClients(keyName: "one"), [], "the key's tokens are gone")
        XCTAssertEqual(try db.projects().count, 1, "the project row survives")
        let survivor = try XCTUnwrap(try db.gatewayClients(keyName: "two").first)
        XCTAssertEqual(survivor.project, shared.id)
        XCTAssertEqual(survivor.projectLabel, shared.label)
        XCTAssertEqual(try service.projectLabelsInUse(name: "two"), [shared.label])

        // Purge walks sqlite_master, so projects and project-bound clients go too.
        try db.wipeData()
        XCTAssertEqual(try db.projects(), [])
        XCTAssertEqual(try db.gatewayClients(keyName: "two"), [])
        XCTAssertEqual(
            try rawRows(dir.appendingPathComponent("catalog.db"), "SELECT COUNT(*) FROM gateway_clients WHERE project IS NOT NULL;"),
            [["0"]]
        )

        // A post-purge resolution of the same folder starts fresh, no duplicate-path conflict.
        let fresh = try service.resolveProject(folder: try makeFolder(dir, "shared-proj").path)
        XCTAssertEqual(fresh.path, shared.path)
        XCTAssertEqual(try db.projects().count, 1)
        XCTAssertEqual(fresh.label, "shared-proj")
    }

    // MARK: VAL-PROJ-010 — the path never leaves

    func testPathNeverLeaves() throws {
        let (service, db, dir) = try makeService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let clock = ProductAnalyticsTests.Clock(), transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(
            catalog: db, endpoint: URL(string: "https://analytics.example/v1/reports")!,
            transport: transport, now: { clock.date() }
        )
        try analytics.setEnabled(true, consentVersion: ProductAnalytics.consentVersion)

        // A sentinel-named folder, resolved and bound to a client token, then read.
        let sentinel = "sentinel-proj-dir-\(UUID().uuidString)"
        let folder = try makeFolder(dir, sentinel)
        let project = try service.resolveProject(folder: folder.path)
        XCTAssertEqual(project.label, sentinel)
        _ = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)
        analytics.record(.clientCreate)
        analytics.record(.viewKeys)

        // The payloads the read surfaces serialize: the clients listing and the
        // in-use labels a key listing shows.
        var scanned: [Data] = []
        scanned.append(try JSONSerialization.data(
            withJSONObject: try db.gatewayClients(keyName: "demo").map { $0.jsonObject() }
        ))
        scanned.append(try JSONSerialization.data(
            withJSONObject: ["projects": try service.projectLabelsInUse(name: "demo")]
        ))

        // The analytics report, sealed and handed to the transport: aggregate counters
        // from the closed vocabulary only — no path, and no project_* counter key.
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let report = try XCTUnwrap(transport.calls.first?.data)
        scanned.append(report)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any])
        let vocabulary = Set(ProductAnalyticsEvent.allCases.map(\.rawValue))
        let counts = try XCTUnwrap(sent["counts"] as? [String: Any])
        XCTAssertTrue(counts.keys.allSatisfy { vocabulary.contains($0) }, "\(counts.keys)")
        XCTAssertFalse(counts.keys.contains { $0.hasPrefix("project") }, "no project_* counter key")
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains(sentinel), "not even the label enters")

        // Every file under the support directory except the catalog DB family — the one
        // sanctioned holder of the path — so no log or side file carries it either.
        let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == "catalog.db" || url.lastPathComponent.hasPrefix("catalog.db-") { continue }
            if let data = try? Data(contentsOf: url) { scanned.append(data) }
        }

        for data in scanned {
            XCTAssertNil(data.range(of: Data(folder.path.utf8)), "the supplied spelling leaked")
            XCTAssertNil(data.range(of: Data(project.path.utf8)), "the canonical path leaked")
            XCTAssertNil(data.range(of: Data(dir.path.utf8)), "the support dir's path leaked")
        }
    }

    // MARK: the real surface — the clients listing over the loopback control channel

    /// The bytes the app actually serves: the per-key clients listing over the loopback
    /// control channel (`control.json` + `X-KSF-Token`, the ListCommandTests rig), the
    /// path an MCP tool reading clients through the app takes. The project shows up as
    /// id and label only — the payload a tool would return never carries the path.
    func testClientsListingOverControlChannel() throws {
        let (service, db, dir) = try makeService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let folder = try makeFolder(dir, "control-proj")
        let project = try service.resolveProject(folder: folder.path)
        _ = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html></html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let client = try ControlClient.connect(control: control)
        let listing = try client.call(method: "GET", path: "/api/keys/demo/clients", expect: 200)
        let clients = try XCTUnwrap(listing["clients"] as? [[String: Any]])
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients[0]["project"] as? String, project.id)
        XCTAssertEqual(clients[0]["project_label"] as? String, project.label)
        let served = String(decoding: try JSONSerialization.data(withJSONObject: listing), as: UTF8.self)
        XCTAssertFalse(served.contains(folder.path), "the path is not in the payload a tool would return")
    }
}
