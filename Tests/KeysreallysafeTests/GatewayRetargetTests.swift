import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// A local process holds the dashboard token and can rewrite routing metadata without a
/// prompt. These are the two ways that used to turn into a leaked key or an unprompted
/// authenticated call (SECURITY-REVIEW-multimodel.md, findings 1 and 2).
final class GatewayRetargetTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    private func makeRig() throws -> (GatewayRig, RequestLog) {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        try rig.key()
        return (rig, hits)
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

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: finding 1: host retarget

    func testGatewayPromptNamesProviderAndHost() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "keys.attacker.example")
        let reason = try XCTUnwrap(gate.reasons.last)
        XCTAssertTrue(reason.contains("OpenAI"), reason)
        XCTAssertTrue(reason.contains("keys.attacker.example"), reason)
    }

    /// PATCH host, then the user's routine re-enable: the prompt names the new host, and a
    /// client token issued for the old host does not follow the key there.
    func testHostPatchNeedsAPromptNamingTheNewHostAndOldClientsStayBehind() async throws {
        let (rig, hits) = try makeRig()
        defer { rig.stop() }
        let original = "127.0.0.1:\(rig.stub.boundPort)"
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "agent")
        XCTAssertEqual(issued.client.host, original)
        do { let status = try await send(rig.url("v1/chat/completions"), token: issued.token); XCTAssertEqual(status, 200) }

        let handler = APIHandler(service: rig.service, webRoot: try TempDir.make())
        let patched = handle(handler, method: "PATCH", path: "/api/keys/demo", body: try json(["host": "keys.attacker.example"]))
        XCTAssertEqual(patched.status, 200)
        XCTAssertFalse(rig.service.isGatewayEnabled("demo"), "a retarget drops the unlocked secret")

        let before = rig.gate.reasons.count
        let enabled = handle(handler, method: "POST", path: "/api/keys/demo/gateway", body: try json(["enabled": true]))
        XCTAssertEqual(enabled.status, 200)
        XCTAssertEqual(rig.gate.reasons.count, before + 1)
        XCTAssertTrue(rig.gate.reasons.last?.contains("keys.attacker.example") == true, rig.gate.reasons.last ?? "")

        do { let status = try await send(rig.url("v1/chat/completions"), token: issued.token); XCTAssertEqual(status, 401) }
        XCTAssertEqual(hits.count, 1, "nothing reached any upstream after the retarget")
        let denied = try rig.service.keyEvents(name: "demo").filter { $0.action == "gateway_denied" }
        XCTAssertEqual(denied.first?.detail, "target_changed")

        // Back on the host it was issued for, the client works again.
        _ = try rig.service.setGateway(name: "demo", enabled: true, host: original)
        do { let status = try await send(rig.url("v1/chat/completions"), token: issued.token); XCTAssertEqual(status, 200) }
    }

    /// The variant that skips PATCH: enable with a caller-chosen host in one request.
    func testEnableWithANewHostNamesItAndRefusesOldClients() async throws {
        let (rig, hits) = try makeRig()
        defer { rig.stop() }
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "agent")
        let handler = APIHandler(service: rig.service, webRoot: try TempDir.make())
        let res = handle(handler, method: "POST", path: "/api/keys/demo/gateway",
                         body: try json(["enabled": true, "host": "keys.attacker.example"]))
        XCTAssertEqual(res.status, 200)
        XCTAssertTrue(rig.gate.reasons.last?.contains("keys.attacker.example") == true, rig.gate.reasons.last ?? "")
        do { let status = try await send(rig.url("v1/chat/completions"), token: issued.token); XCTAssertEqual(status, 401) }
        XCTAssertEqual(hits.count, 0)
    }

    /// A provider override (no prompt) can move a key that uses the provider's default host.
    func testProviderHostOverrideRefusesClientsIssuedForTheOldHost() throws {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let issued = try service.issueGatewayClient(name: "demo", label: "agent")
        XCTAssertEqual(issued.client.host, "api.openai.com")
        let auth = ["authorization": "Bearer " + issued.token]
        guard case .allowed = service.authorizeGatewayClient(name: "demo", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("fresh client is allowed")
        }
        try service.addProvider(id: "openai", name: "OpenAI", host: "keys.attacker.example", api: "openai", pathPrefix: "v1")
        XCTAssertEqual(service.authorizeGatewayClient(name: "demo", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("target_changed"))
    }

    /// Clients from before host binding are bound to the key's host at the upgrade, so they
    /// keep working there and nowhere else.
    func testLegacyClientsAreBoundToTheHostTheyHadAtUpgrade() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        let token = GatewayClientToken.generate()
        let hostless = GatewayClientToken.generate()
        do {
            let (service, _) = makeGatedService(db: try CatalogDB(path: path))
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "kimi.example.test", updateHost: true)
            try service.add(name: "azure", provider: "azure-openai", kind: "runtime", notes: "", secret: fixtureSecret)
        }
        // Rebuild gateway_clients the way 0.11 had it: no host column.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            DROP TABLE gateway_clients;
            CREATE TABLE gateway_clients (
              id INTEGER PRIMARY KEY AUTOINCREMENT, key_name TEXT NOT NULL, label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE, hint TEXT NOT NULL DEFAULT '', methods TEXT NOT NULL,
              path_prefix TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at)
              VALUES ('demo', '\(GatewayClientToken.hash(token))', 'POST', '2026-10-01T00:00:00Z', '2999-01-01T00:00:00Z');
            INSERT INTO gateway_clients (key_name, token_hash, methods, created_at, expires_at)
              VALUES ('azure', '\(GatewayClientToken.hash(hostless))', 'POST', '2026-10-01T00:00:00Z', '2999-01-01T00:00:00Z');
            DELETE FROM meta WHERE key = '\(CatalogDB.clientHostBackfillKey)';
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = try CatalogDB(path: path)
        let (service, _) = makeGatedService(db: db)
        XCTAssertEqual(try db.gatewayClients(keyName: "demo").first?.host, "kimi.example.test")
        XCTAssertNil(try db.metaValue(CatalogDB.clientHostBackfillKey), "the backfill runs once")
        let auth = ["authorization": "Bearer " + token]
        guard case .allowed = service.authorizeGatewayClient(name: "demo", headers: auth, method: "POST", rest: "v1/x") else {
            return XCTFail("a legacy client keeps working on its host")
        }
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "keys.attacker.example", updateHost: true)
        XCTAssertEqual(service.authorizeGatewayClient(name: "demo", headers: auth, method: "POST", rest: "v1/x"),
                       .denied("target_changed"))

        // A key with no host at the upgrade leaves its client unbound, and a host set later
        // does not adopt it.
        _ = try service.patch(name: "azure", provider: nil, kind: nil, notes: nil, host: "res.openai.azure.com", updateHost: true)
        _ = makeGatedService(db: try CatalogDB(path: path))
        XCTAssertNil(try db.gatewayClients(keyName: "azure").first?.host)
        XCTAssertEqual(service.authorizeGatewayClient(name: "azure", headers: ["authorization": "Bearer " + hostless],
                                                      method: "POST", rest: "v1/x"),
                       .denied("target_changed"))
    }

    // MARK: finding 2: provider override plus the cached secret

    func testPathPrefixesRefuseQueryFragmentAndEscapes() throws {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        for bad in ["v1/files#", "v1/files?x=1", "v1/%66iles", "v1 files", "v1/\u{00e9}"] {
            XCTAssertThrowsError(try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", pathPrefix: bad), bad)
            XCTAssertThrowsError(try GatewayClientToken.validatePathPrefix(bad), bad)
        }
        XCTAssertNoThrow(try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", pathPrefix: "openai/v1"))
        XCTAssertEqual(try GatewayClientToken.validatePathPrefix("v1beta/models/gemini:generateContent"),
                       "v1beta/models/gemini:generateContent")
    }

    /// The exploit kept id and host and changed the rest of the record, so the cached secret
    /// went out on a request the user never approved.
    func testCheckReusesTheCachedSecretOnlyForTheSameProviderRecord() throws {
        final class Fetcher: ProviderCheckFetching, @unchecked Sendable {
            private(set) var requests: [URLRequest] = []
            func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                requests.append(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (Data(#"{"data":[]}"#.utf8), http)
            }
        }
        for (index, change) in ["path prefix", "auth header", "auth prefix"].enumerated() {
            Providers.setOverlay([:])
            let fetcher = Fetcher()
            let (db, _) = try makeDB()
            let (service, gate) = makeGatedService(db: db)
            service.checker = fetcher
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.setGateway(name: "demo", enabled: true, host: nil)
            _ = try service.checkProvider(name: "demo")
            XCTAssertEqual(gate.reasons.count, 1, "an unchanged record reuses the unlock")

            switch index {
            case 0: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai", pathPrefix: "v1/files")
            case 1: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai",
                                            authHeader: "x-forward-to", pathPrefix: "v1")
            default: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai",
                                             authPrefix: "Token ", pathPrefix: "v1")
            }
            gate.error = .authCancelled
            XCTAssertThrowsError(try service.checkProvider(name: "demo"), change)
            XCTAssertEqual(gate.reasons.count, 2, change)
            XCTAssertEqual(fetcher.requests.count, 1, "no request without a fresh approval: \(change)")
        }
    }
}
