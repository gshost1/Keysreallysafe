import Foundation
import XCTest
@testable import KeysCore

/// Loopback headers are not authentication. Every gateway call needs a client capability
/// issued for that key; the dashboard's CSRF token is never accepted.
final class GatewayClientTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    private struct Rig {
        let db: CatalogDB
        let service: KeysService
        let gate: RecordingPresenceGate
        let stub: LoopbackHTTPServer
        let hits: Counter
        let gateway: GatewayListener
        func url(_ rest: String, key: String = "demo") -> URL {
            URL(string: "http://127.0.0.1:\(gateway.boundPort)/\(key)/\(rest)")!
        }
    }

    private func makeRig() throws -> Rig {
        let hits = Counter()
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            hits.bump()
            return HTTPResponse.json(200, ["ok": true])
        }
        stub.start()
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: MemorySecretStore(), presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        return Rig(db: db, service: service, gate: gate, stub: stub, hits: hits, gateway: gateway)
    }

    private func send(_ url: URL, method: String = "POST", headers: [String: String] = [:]) async throws -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = method == "GET" ? nil : Data("{\"model\":\"gpt-4.1\"}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    func testIssueRequiresPresenceAndStoresOnlyAHash() throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        rig.gate.error = .authFailed
        XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: "cli"))
        rig.gate.error = nil
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "cli", days: 7)
        XCTAssertTrue(rig.gate.reasons.contains("Issue gateway client for demo"))
        XCTAssertTrue(GatewayClientToken.looksLikeToken(issued.token))
        XCTAssertEqual(issued.client.methods, ["POST"])
        let listed = try rig.service.gatewayClients(name: "demo")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].hint, String(issued.token.suffix(4)))
        // Neither the catalog file nor the client list carries the token.
        let bytes = try Data(contentsOf: rig.db.path)
        XCTAssertNil(bytes.range(of: Data(issued.token.utf8)))
        let json = try JSONSerialization.data(withJSONObject: listed[0].jsonObject())
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(issued.token))
        let events = try rig.service.keyEvents(name: "demo")
        XCTAssertEqual(events.first?.action, "client_issue")
        XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: "", days: 0))
        XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: "", methods: ["TRACE"]))
        XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: "", pathPrefix: "../x"))
    }

    func testNativeCallerWithoutClientIs401AndNeverReachesUpstream() async throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        // Valid Host, no browser headers: exactly what a local process can send.
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions")), 401)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer sk-anything"]), 401)
        // The dashboard token is a CSRF defense, not a gateway capability.
        let web = try TempDir.make()
        let handler = APIHandler(service: rig.service, webRoot: web)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["X-KSF-Token": handler.originToken]), 401)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer " + handler.originToken]), 401)
        XCTAssertEqual(rig.hits.count, 0)
        let denied = try rig.service.keyEvents(name: "demo").filter { $0.action == "gateway_denied" }
        XCTAssertEqual(denied.count, 4)
        XCTAssertEqual(denied.first?.detail, "no_client_token")
    }

    func testClientTokenIsAcceptedWhereTheSDKPutsTheProviderKey() async throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "sdk")
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer " + issued.token]), 200)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["x-api-key": issued.token]), 200)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["X-KSF-Client": issued.token]), 200)
        XCTAssertEqual(rig.hits.count, 3)
        let after = try XCTUnwrap(rig.service.gatewayClients(name: "demo").first)
        XCTAssertNotNil(after.lastUsedAt)
    }

    func testScopeExpiryRevocationAndKeyBinding() async throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        try rig.service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: "other-secret")
        _ = try rig.service.setGateway(name: "other", enabled: true, host: "127.0.0.1:\(rig.stub.boundPort)")

        let scoped = try rig.service.issueGatewayClient(name: "demo", label: "scoped", methods: ["POST"], pathPrefix: "v1/chat")
        let auth = ["Authorization": "Bearer " + scoped.token]
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: auth), 200)
        await AsyncAssert.equal(try await send(rig.url("v1/chatter"), headers: auth), 401, "prefix is segment-aware")
        await AsyncAssert.equal(try await send(rig.url("v1/chat/../models"), headers: auth), 401, "dot segments never pass a scope")
        await AsyncAssert.equal(try await send(rig.url("v1/chat/%2e%2e/models"), headers: auth), 401)
        await AsyncAssert.equal(try await send(rig.url("v1/models"), headers: auth), 401)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), method: "GET", headers: auth), 401)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions", key: "other"), headers: auth), 401, "a client is bound to one key")
        XCTAssertEqual(rig.hits.count, 1)

        let expired = try rig.service.issueGatewayClient(name: "demo", label: "old", days: 1, now: Date().addingTimeInterval(-3 * 86_400))
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer " + expired.token]), 401)

        let revoked = try rig.service.issueGatewayClient(name: "demo", label: "gone")
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer " + revoked.token]), 200)
        let row = try rig.service.revokeGatewayClient(name: "demo", id: revoked.client.id)
        XCTAssertNotNil(row.revokedAt)
        await AsyncAssert.equal(try await send(rig.url("v1/chat/completions"), headers: ["Authorization": "Bearer " + revoked.token]), 401)
        XCTAssertThrowsError(try rig.service.revokeGatewayClient(name: "demo", id: revoked.client.id), "revoking twice is not found")
        XCTAssertThrowsError(try rig.service.revokeGatewayClient(name: "other", id: scoped.client.id), "cannot revoke through another key")
        XCTAssertEqual(rig.hits.count, 2)

        let reasons = try rig.service.keyEvents(name: "demo").filter { $0.action == "gateway_denied" }.compactMap(\.detail)
        XCTAssertTrue(reasons.contains("out_of_scope"))
        XCTAssertTrue(reasons.contains("expired"))
        XCTAssertTrue(reasons.contains("revoked"))
    }

    func testTrailingSlashPrefixMatchesTheEndpointItNames() throws {
        XCTAssertEqual(try GatewayClientToken.validatePathPrefix("/v1/messages/"), "v1/messages")
        XCTAssertNil(try GatewayClientToken.validatePathPrefix("///"))
        XCTAssertThrowsError(try GatewayClientToken.validatePathPrefix("v1/%2e%2e/x"))
        let c = GatewayClient(id: 1, keyName: "k", label: "", methods: ["POST"], pathPrefix: "v1/messages",
                              createdAt: "", expiresAt: "2999-01-01T00:00:00Z", revokedAt: nil, lastUsedAt: nil, hint: "")
        XCTAssertTrue(c.allows(method: "POST", rest: "v1/messages"))
        XCTAssertTrue(c.allows(method: "post", rest: "v1/messages/count_tokens"))
        XCTAssertFalse(c.allows(method: "POST", rest: "v1/messages2"))
        XCTAssertFalse(c.allows(method: "POST", rest: "v1/messages/../models"))
        XCTAssertFalse(c.allows(method: "POST", rest: "./v1/messages"))
    }

    func testUnknownKeyNamesDoNotGrowTheAuditLogAndUseIsStampedOnlyOnForward() async throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        for i in 0..<5 {
            await AsyncAssert.equal(try await send(rig.url("v1/x", key: "junk\(i)")), 401)
        }
        let allEvents = try rig.db.keyEvents(name: "junk0", limit: 50)
        XCTAssertTrue(allEvents.isEmpty, "no audit row for a name that is not a key")
        // A valid client on a key whose gateway is off gets 404 and no last_used_at.
        try rig.service.add(name: "off", provider: "openai", kind: "runtime", notes: "", secret: "s")
        let issued = try rig.service.issueGatewayClient(name: "off", label: "t")
        await AsyncAssert.equal(try await send(rig.url("v1/x", key: "off"), headers: ["Authorization": "Bearer " + issued.token]), 404)
        XCTAssertNil(try rig.service.gatewayClients(name: "off").first?.lastUsedAt)
        XCTAssertEqual(rig.hits.count, 0)
    }

    func testDeletingTheKeyDeletesItsClients() throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "x")
        try rig.service.remove(name: "demo")
        XCTAssertNil(try rig.db.gatewayClient(tokenHash: GatewayClientToken.hash(issued.token)))
        try rig.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "new")
        XCTAssertEqual(try rig.service.gatewayClients(name: "demo").count, 0, "a re-created key starts with no clients")
    }

    func testDashboardRoutesNeedTheCSRFTokenAndNeverEchoTokensInLists() throws {
        let rig = try makeRig()
        defer { rig.gateway.stop(); rig.stub.stop() }
        let web = try TempDir.make()
        let handler = APIHandler(service: rig.service, webRoot: web)
        func call(_ method: String, _ path: String, token: Bool, body: [String: Any] = [:]) -> HTTPResponse {
            var headers = ["host": "127.0.0.1:12765"]
            if token { headers["x-ksf-token"] = handler.originToken }
            return handler.handle(HTTPRequest(
                method: method, path: path, query: [:], headers: headers,
                body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), serverPort: 12765
            ))
        }
        XCTAssertEqual(call("POST", "/api/keys/demo/clients", token: false).status, 403)
        let issued = call("POST", "/api/keys/demo/clients", token: true, body: ["label": "web", "days": 2, "path_prefix": "/v1/chat"])
        XCTAssertEqual(issued.status, 201)
        let obj = try JSONSerialization.jsonObject(with: issued.body) as! [String: Any]
        let token = try XCTUnwrap(obj["token"] as? String)
        let client = try XCTUnwrap(obj["client"] as? [String: Any])
        XCTAssertEqual(client["path_prefix"] as? String, "v1/chat")
        let id = try XCTUnwrap(client["id"] as? Int)
        XCTAssertEqual(call("POST", "/api/keys/demo/clients", token: true, body: ["days": "soon"]).status, 400)

        let listed = call("GET", "/api/keys/demo/clients", token: false)
        XCTAssertEqual(listed.status, 200)
        XCTAssertFalse(String(decoding: listed.body, as: UTF8.self).contains(token))
        XCTAssertTrue(String(decoding: listed.body, as: UTF8.self).contains("\"hint\""))

        XCTAssertEqual(call("DELETE", "/api/keys/demo/clients/\(id)", token: false).status, 403)
        XCTAssertEqual(call("DELETE", "/api/keys/demo/clients/\(id)", token: true).status, 200)
        XCTAssertEqual(call("DELETE", "/api/keys/demo/clients/\(id)", token: true).status, 404)
        XCTAssertEqual(call("DELETE", "/api/keys/demo/clients/abc", token: true).status, 404)
        // The key itself survived; only the client route was hit.
        XCTAssertTrue(try rig.db.catalogExists(name: "demo"))
    }
}

private enum AsyncAssert {
    static func equal(_ actual: Int, _ expected: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
}
