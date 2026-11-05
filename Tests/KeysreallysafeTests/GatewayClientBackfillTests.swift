import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// The host backfill for client tokens issued before `gateway_clients.host` existed ran
/// off a `pending` flag the migration wrote. Two things made the catalog lose it: a crash
/// between the ALTER and the flag left the column with no flag, so the backfill never ran;
/// and a bind that failed was swallowed by `try?` while the flag was cleared anyway. Either
/// way every old client kept a NULL host, which the authorizer refuses as `target_changed`
/// for good, and nothing retried.
final class GatewayClientBackfillTests: XCTestCase {

    /// A catalog whose `gateway_clients` is the 0.11 shape, plus the one client token it
    /// held and the host its key now has.
    private func legacyCatalog() throws -> (path: URL, token: String) {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let token = GatewayClientToken.generate()
        do {
            let (service, _) = makeGatedService(db: try CatalogDB(path: path))
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "kimi.example.test", updateHost: true)
        }
        try exec(path, """
            DROP TABLE gateway_clients;
            CREATE TABLE gateway_clients (
              id INTEGER PRIMARY KEY AUTOINCREMENT, key_name TEXT NOT NULL, label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE, hint TEXT NOT NULL DEFAULT '', methods TEXT NOT NULL,
              path_prefix TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at)
              VALUES ('demo', '\(GatewayClientToken.hash(token))', 'POST', '2026-10-01T00:00:00Z', '2999-01-01T00:00:00Z');
            DELETE FROM meta WHERE key IN ('\(CatalogDB.clientHostBackfillKey)',
              '\(CatalogDB.clientHostBackfillCandidatesKey)', '\(CatalogDB.clientHostBackfillAttemptsKey)');
            """)
        return (path, token)
    }

    @discardableResult
    private func exec(_ path: URL, _ sql: String) throws -> Int32 {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let rc = sqlite3_exec(raw, sql, nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK, String(cString: sqlite3_errmsg(raw)))
        return rc
    }

    /// A catalog another build already migrated: the host column is there, the backfill
    /// flag was written and deleted, and the candidate record this build keeps was never
    /// written. Its NULL-host clients are not all leftovers — one issued after that
    /// migration carries NULL on purpose — so claiming them here would bind a token to a
    /// host nobody approved. The catalog is recorded as claimed by nobody instead.
    func testACatalogMigratedElsewhereSettlesInsteadOfClaimingItsClients() throws {
        let (path, legacyToken) = try legacyCatalog()
        let laterToken = GatewayClientToken.generate()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            DELETE FROM meta WHERE key = '\(CatalogDB.clientHostBackfillKey)';
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at, host)
              VALUES ('demo', '\(GatewayClientToken.hash(laterToken))', 'POST', '2026-10-02T00:00:00Z', '2999-01-01T00:00:00Z', NULL);
            """)

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)

        XCTAssertEqual(try db.backfillCandidateIDs(), [], "a settled catalog claims nobody")
        XCTAssertTrue(try db.gatewayClients(keyName: "demo").allSatisfy { $0.host == nil },
                      "no NULL-host client is bound to the key's current host")
        for token in [legacyToken, laterToken] {
            XCTAssertEqual(
                service.authorizeGatewayClient(
                    name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
                ),
                .denied("target_changed"),
                "a client migrated with no host, or issued with none, is never retargeted"
            )
        }
    }

    /// The crash mid-pass: the run decided its candidates and the process died before a
    /// bind. The decision is the host the key had at that first look, and the next open
    /// binds exactly that host.
    func testACandidateThePassNeverReachedIsBoundOnTheNextOpen() throws {
        let (path, token) = try legacyCatalog()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            """)
        do {
            let db = try CatalogDB(path: path)
            XCTAssertEqual(try db.backfillCandidateIDs(), [1], "the run claimed the client")
            XCTAssertEqual(try db.unboundGatewayClients().count, 1, "and offered it to the pass")
            XCTAssertEqual(try db.backfillAttempts(), [1: "kimi.example.test"],
                           "the first look freezes the host the bind must use")
        }

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        XCTAssertEqual(try db.gatewayClients(keyName: "demo").first?.host, "kimi.example.test",
                       "the next open binds the client the pass never reached")
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
        ) else {
            return XCTFail("the retried client works on its host")
        }
    }

    /// A key retargeted between the first look and the bind (a crash in between, then a
    /// host change) does not move the client: it is bound to the host decided first.
    func testARetargetAfterTheFirstLookDoesNotMoveTheClient() throws {
        let (path, _) = try legacyCatalog()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            """)
        do {
            let db = try CatalogDB(path: path)
            XCTAssertEqual(try db.unboundGatewayClients().map(\.host), ["kimi.example.test"])
        }
        try exec(path, "UPDATE catalog SET gateway_host = 'elsewhere.example.test' WHERE name = 'demo';")

        let db = try CatalogDB(path: path)
        _ = makeGatedService(db: db)
        XCTAssertEqual(try db.gatewayClients(keyName: "demo").first?.host, "kimi.example.test",
                       "bound to the host its first look decided, not the newer one")
    }

    /// A candidate whose host this process cannot name (its provider is not loaded) is
    /// refused for good, not left for a later open: once the provider appears, binding
    /// it then would give a token a target nobody approved.
    func testACandidateWithAnUnknownProviderIsRefusedForGood() throws {
        let (path, token) = try legacyCatalog()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            UPDATE catalog SET gateway_host = NULL, provider = 'not-a-provider' WHERE name = 'demo';
            """)
        do {
            let db = try CatalogDB(path: path)
            XCTAssertTrue(try db.unboundGatewayClients().isEmpty, "nothing to bind")
            XCTAssertEqual(try db.backfillAttempts(), [1: ""], "settled as refused")
        }
        try exec(path, "UPDATE catalog SET gateway_host = 'kimi.example.test' WHERE name = 'demo';")

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        XCTAssertNil(try db.gatewayClients(keyName: "demo").first?.host, "a host gained later is not adopted")
        XCTAssertEqual(
            service.authorizeGatewayClient(
                name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
            ),
            .denied("target_changed")
        )
    }

    /// The candidate set is the clients that existed when the column was added. One issued
    /// afterwards carries NULL on purpose — its key had no host — and a host added later
    /// must not adopt it, or a token would silently gain a target the user never approved.
    func testAClientIssuedAfterTheUpgradeIsNeverAdopted() throws {
        let (path, _) = try legacyCatalog()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            """)
        _ = makeGatedService(db: try CatalogDB(path: path))
        let token = GatewayClientToken.generate()
        try exec(path, """
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at, host)
              VALUES ('demo', '\(GatewayClientToken.hash(token))', 'POST', '2026-10-02T00:00:00Z', '2999-01-01T00:00:00Z', NULL);
            """)

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        let hosts = try db.gatewayClients(keyName: "demo").map { $0.host }
        XCTAssertEqual(hosts.first, "kimi.example.test", "the recorded candidate is bound")
        XCTAssertEqual(hosts.count, 2)
        XCTAssertTrue(hosts.last.map { $0 == nil } ?? false, "the later, deliberately unbound client stays unbound")
        XCTAssertEqual(
            service.authorizeGatewayClient(
                name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
            ),
            .denied("target_changed"),
            "a token issued with no host is never retargeted by a later host"
        )
    }

    /// A bind that fails must not strand the client. The service's write is `try?`-ed and
    /// the flag cleared anyway, so the catalog itself has to notice that a client is still
    /// unbound the next time it is opened.
    func testAFailedBindIsRetriedOnTheNextOpen() throws {
        let (path, token) = try legacyCatalog()
        try exec(path, """
            ALTER TABLE gateway_clients ADD COLUMN host TEXT;
            INSERT OR REPLACE INTO meta (key, value) VALUES ('\(CatalogDB.clientHostBackfillKey)', 'pending');
            CREATE TRIGGER refuse_bind BEFORE UPDATE ON gateway_clients
            BEGIN SELECT RAISE(ABORT, 'database is locked'); END;
            """)

        do {
            let db = try CatalogDB(path: path)
            _ = makeGatedService(db: db)
            XCTAssertNil(try db.gatewayClients(keyName: "demo").first?.host, "the bind could not land")
        }

        // Once the write works again, the next launch binds the client and it works.
        try exec(path, "DROP TRIGGER refuse_bind;")
        let retry = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: retry)
        XCTAssertEqual(try retry.gatewayClients(keyName: "demo").first?.host, "kimi.example.test",
                       "the next open retried the bind nobody flagged")
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
        ) else {
            return XCTFail("the retried client works on its host")
        }
    }

    /// A key with no host leaves its client unbound on purpose, and the run still finishes.
    func testAKeyWithNoHostIsLeftUnbound() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let token = GatewayClientToken.generate()
        do {
            let (service, _) = makeGatedService(db: try CatalogDB(path: path))
            // A provider with one host per account has no default host to bind to.
            try service.add(name: "azure", provider: "azure-openai", kind: "runtime", notes: "", secret: fixtureSecret)
        }
        // The 0.11 shape: a client row for that key, no host column, no record.
        try exec(path, """
            DROP TABLE gateway_clients;
            CREATE TABLE gateway_clients (
              id INTEGER PRIMARY KEY AUTOINCREMENT, key_name TEXT NOT NULL, label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE, hint TEXT NOT NULL DEFAULT '', methods TEXT NOT NULL,
              path_prefix TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at)
              VALUES ('azure', '\(GatewayClientToken.hash(token))', 'POST', '2026-10-01T00:00:00Z', '2999-01-01T00:00:00Z');
            DELETE FROM meta WHERE key IN ('\(CatalogDB.clientHostBackfillKey)',
              '\(CatalogDB.clientHostBackfillCandidatesKey)', '\(CatalogDB.clientHostBackfillAttemptsKey)');
            """)
        let db = try CatalogDB(path: path)
        _ = makeGatedService(db: db)
        XCTAssertNil(try db.gatewayClients(keyName: "azure").first?.host, "no host to bind to, so none is invented")
        XCTAssertNil(try db.metaValue(CatalogDB.clientHostBackfillKey), "and the run does not retry forever")
    }
}
