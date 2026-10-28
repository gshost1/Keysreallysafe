import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// One project client token serving several keys: the `gateway_client_keys` membership
/// table, the multi-key authorize branch, per-member host revalidation and
/// revoke-by-project. The per-key path is proven unchanged by EnvWrapTests and
/// GatewayRetargetTests; this file pins the new path and the guarded migration.
final class ProjectClientTokenTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    // MARK: - helpers

    /// A real project folder for `resolveProject`; its path stays in the catalog.
    private func makeProject(_ service: KeysService, _ dir: URL, _ name: String = "proj") throws -> CatalogDB.ProjectRow {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try service.resolveProject(folder: folder.path)
    }

    private func bearer(_ token: String) -> [String: String] { ["authorization": "Bearer " + token] }

    private func addOpenAI(_ service: KeysService, _ name: String, secret: String = fixtureSecret) throws {
        try service.add(name: name, provider: "openai", kind: "runtime", notes: "", secret: secret)
    }

    private func send(_ url: URL, token: String) async throws -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{\"model\":\"gpt-4.1\"}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// The stub's headers are lowercased by the frame parser; look up case-insensitively
    /// anyway so the assertion does not depend on that.
    private func header(_ request: HTTPRequest?, _ name: String) -> String? {
        request?.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    @discardableResult
    private func rawExec(_ dbPath: URL, _ sql: String) -> Int32 {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(raw, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc
    }

    private func rawRows(_ dbPath: URL, _ sql: String) throws -> [[String]] {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<Int(sqlite3_column_count(stmt))).map {
                sqlite3_column_text(stmt, Int32($0)).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    // MARK: - VAL-TOK-001: one token serves each member key

    /// One prompt mints the token; each member key's base-URL path authorizes with the
    /// SAME token, and the gateway forwards each member's own secret.
    func testProjectTokenAuthorizesEachMemberWithItsOwnSecret() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        let secretA = "unit-test-secret-alpha-0001"
        let secretB = "unit-test-secret-beta-0002"
        try rig.key("alpha", provider: "openai", secret: secretA)
        try rig.key("beta", provider: "openai", secret: secretB)
        let project = try makeProject(rig.service, rig.dir)
        let promptsBeforeMint = rig.gate.reasons.count
        let issued = try rig.service.issueProjectGatewayClient(
            keys: ["alpha", "beta"], label: "proj", project: project.id
        )
        XCTAssertEqual(rig.gate.reasons.count, promptsBeforeMint + 1, "one prompt mints the whole project token")

        let statusA = try await send(rig.url("v1/chat/completions", key: "alpha"), token: issued.token)
        XCTAssertEqual(statusA, 200)
        let statusB = try await send(rig.url("v1/chat/completions", key: "beta"), token: issued.token)
        XCTAssertEqual(statusB, 200)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(header(hits.all.first, "authorization"), "Bearer " + secretA, "alpha's own secret went upstream")
        XCTAssertEqual(header(hits.all.last, "authorization"), "Bearer " + secretB, "beta's own secret went upstream")
    }

    /// The token's method scope bounds every member, and the token itself is accepted for
    /// each member's path (not just the first).
    func testProjectTokenMethodScopeAppliesToEveryMember() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        let project = try makeProject(service, dir)
        let issued = try service.issueProjectGatewayClient(
            keys: ["alpha", "beta"], label: "proj", methods: ["POST"], project: project.id
        )
        let auth = bearer(issued.token)
        guard case .allowed = service.authorizeGatewayClient(name: "alpha", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("alpha is in scope for POST")
        }
        guard case .allowed = service.authorizeGatewayClient(name: "beta", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("beta is in scope for POST")
        }
        XCTAssertEqual(service.authorizeGatewayClient(name: "alpha", headers: auth, method: "GET", rest: "v1/x"),
                       .denied("out_of_scope"))
        XCTAssertEqual(service.authorizeGatewayClient(name: "beta", headers: auth, method: "GET", rest: "v1/x"),
                       .denied("out_of_scope"))
    }

    // MARK: - VAL-TOK-002: non-members stay denied; per-key tokens never widened

    func testProjectTokenDeniesNonMembers() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        try addOpenAI(service, "gamma")
        let project = try makeProject(service, dir)
        let issued = try service.issueProjectGatewayClient(keys: ["alpha", "beta"], label: "proj", project: project.id)
        XCTAssertEqual(
            service.authorizeGatewayClient(name: "gamma", headers: bearer(issued.token), method: "POST", rest: "v1/x"),
            .denied("wrong_key")
        )
    }

    func testPerKeyTokenIsNeverWidened() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        _ = try makeProject(service, dir)
        let issued = try service.issueGatewayClient(name: "alpha", label: "agent")
        XCTAssertEqual(
            service.authorizeGatewayClient(name: "beta", headers: bearer(issued.token), method: "POST", rest: "v1/x"),
            .denied("wrong_key")
        )
        guard case .allowed = service.authorizeGatewayClient(
            name: "alpha", headers: bearer(issued.token), method: "POST", rest: "v1/x"
        ) else { return XCTFail("the per-key token still authorizes its own key") }
    }

    // MARK: - VAL-TOK-003: one row, one expiry, one hint; memberships carry name + host

    func testProjectTokenIsOneRowWithOneExpiryHintAndPerMemberMemberships() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try service.add(name: "beta", provider: "anthropic", kind: "runtime", notes: "", secret: "unit-test-secret-beta")
        let project = try makeProject(service, dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let issued = try service.issueProjectGatewayClient(
            keys: ["alpha", "beta"], label: "proj", project: project.id, now: now
        )

        // Exactly one gateway_clients row, keyed on the first member, with one expiry
        // (30-day default), one hint (last 4) and the project id.
        let alphaClients = try service.gatewayClients(name: "alpha")
        XCTAssertEqual(alphaClients.count, 1)
        XCTAssertEqual(alphaClients[0].id, issued.client.id)
        XCTAssertEqual(alphaClients[0].keyName, "alpha")
        XCTAssertEqual(alphaClients[0].hint, String(issued.token.suffix(4)))
        XCTAssertEqual(alphaClients[0].hint.count, 4)
        XCTAssertEqual(alphaClients[0].expiresAt, UTC.iso(now.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(alphaClients[0].project, project.id)
        // The other member carries no token row of its own.
        XCTAssertEqual(try service.gatewayClients(name: "beta").count, 0)

        // Memberships carry only the key name and the host the user approved.
        XCTAssertEqual(
            try db.gatewayClientKeys(clientID: issued.client.id),
            [
                CatalogDB.GatewayClientKey(clientID: issued.client.id, keyName: "alpha", host: "api.openai.com"),
                CatalogDB.GatewayClientKey(clientID: issued.client.id, keyName: "beta", host: "api.anthropic.com"),
            ]
        )
    }

    /// The membership table's shape: `(client_id, key_name, host)` and nothing else.
    func testMembershipSchemaIsKeyNameAndHostOnly() throws {
        let (db, _) = try makeDB()
        let columns = try rawRows(db.path, "SELECT name FROM pragma_table_info('gateway_client_keys') ORDER BY cid;")
            .map { $0[0] }
        XCTAssertEqual(columns, ["client_id", "key_name", "host"])
        let pk = try rawRows(db.path, "SELECT name FROM pragma_table_info('gateway_client_keys') WHERE pk > 0 ORDER BY pk;")
            .map { $0[0] }
        XCTAssertEqual(pk, ["client_id", "key_name"], "the primary key is the pair")
    }

    // MARK: - VAL-TOK-004: one revoke ends every member

    func testRevokeByProjectEndsEveryMemberAndSparesOtherProjects() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        try addOpenAI(service, "gamma")
        let one = try makeProject(service, dir, "one")
        let two = try makeProject(service, dir, "two")
        let project = try service.issueProjectGatewayClient(keys: ["alpha", "beta"], label: "one", project: one.id)
        let other = try service.issueProjectGatewayClient(keys: ["gamma"], label: "two", project: two.id)
        let auth = bearer(project.token)
        guard case .allowed = service.authorizeGatewayClient(name: "beta", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("beta works before the revoke")
        }

        XCTAssertEqual(try service.revokeGatewayClients(project: one.id), 1, "one statement revokes the one project token")
        XCTAssertEqual(service.authorizeGatewayClient(name: "alpha", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("revoked"))
        XCTAssertEqual(service.authorizeGatewayClient(name: "beta", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("revoked"))
        guard case .allowed = service.authorizeGatewayClient(
            name: "gamma", headers: bearer(other.token), method: "POST", rest: "v1/x"
        ) else { return XCTFail("another project's token is untouched") }
    }

    func testRevokingTheClientRowEndsEveryMember() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        let project = try makeProject(service, dir)
        let issued = try service.issueProjectGatewayClient(keys: ["alpha", "beta"], label: "proj", project: project.id)
        _ = try service.revokeGatewayClient(name: "alpha", id: issued.client.id)
        for member in ["alpha", "beta"] {
            XCTAssertEqual(
                service.authorizeGatewayClient(name: member, headers: bearer(issued.token), method: "POST", rest: "v1/x"),
                .denied("revoked"), member
            )
        }
    }

    // MARK: - VAL-TOK-005: per-member host revalidation (target_changed)

    func testRetargetedMemberDeniesWhileOthersKeepWorking() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try addOpenAI(service, "beta")
        let project = try makeProject(service, dir)
        let issued = try service.issueProjectGatewayClient(keys: ["alpha", "beta"], label: "proj", project: project.id)
        let auth = bearer(issued.token)

        // The second member is retargeted; only it is refused.
        _ = try service.patch(name: "beta", provider: nil, kind: nil, notes: nil,
                              host: "keys.attacker.example", updateHost: true)
        XCTAssertEqual(service.authorizeGatewayClient(name: "beta", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("target_changed"))
        guard case .allowed = service.authorizeGatewayClient(name: "alpha", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("alpha is untouched by beta's retarget")
        }

        // The first member (the row's own key) is revalidated the same way.
        _ = try service.patch(name: "alpha", provider: nil, kind: nil, notes: nil,
                              host: "keys.attacker2.example", updateHost: true)
        XCTAssertEqual(service.authorizeGatewayClient(name: "alpha", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("target_changed"))
    }

    // MARK: - VAL-TOK-006: guarded migration in place

    func testOldCatalogMigratesInPlaceAndKeepsWorking() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let legacy: String
        do {
            let (service, _) = makeGatedService(db: try CatalogDB(path: path))
            try addOpenAI(service, "demo")
            legacy = try service.issueGatewayClient(name: "demo", label: "agent").token
        }
        // Rebuild the catalog the way it looked before memberships existed: the table is
        // gone, an ordinary per-key token remains.
        XCTAssertEqual(rawExec(path, "DROP TABLE gateway_client_keys;"), SQLITE_OK)
        XCTAssertEqual(
            try rawRows(path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'gateway_client_keys';").count,
            0, "the pre-membership catalog has no table"
        )

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        XCTAssertEqual(
            try rawRows(path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'gateway_client_keys';").count,
            1, "the guarded create adds the table in place"
        )
        // The pre-existing per-key row still decodes and authorizes unchanged.
        XCTAssertEqual(try service.gatewayClients(name: "demo").count, 1)
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: bearer(legacy), method: "POST", rest: "v1/x"
        ) else { return XCTFail("the old token still authorizes after the migration") }

        // And a new project token can be minted against the upgraded table.
        let project = try makeProject(service, dir)
        let issued = try service.issueProjectGatewayClient(keys: ["demo"], label: "proj", project: project.id)
        guard case .allowed = service.authorizeGatewayClient(
            name: "demo", headers: bearer(issued.token), method: "POST", rest: "v1/x"
        ) else { return XCTFail("a fresh project token works after the migration") }
        XCTAssertEqual(try db.gatewayClientKeys(clientID: issued.client.id).map(\.keyName), ["demo"])
    }

    // MARK: - mint input validation

    func testProjectMintRefusesAnEmptyOrHostlessKeySet() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try addOpenAI(service, "alpha")
        try service.add(name: "azure", provider: "azure-openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let project = try makeProject(service, dir)
        XCTAssertThrowsError(try service.issueProjectGatewayClient(keys: [], label: "proj", project: project.id))
        // azure-openai has no default host and none set: the same refusal per-key issuance gives.
        XCTAssertThrowsError(try service.issueProjectGatewayClient(keys: ["azure"], label: "proj", project: project.id))
    }
}
