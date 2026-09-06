import XCTest
@testable import KeysCore

/// Temporary, narrowly scoped access: one prompt per task, fail closed on expiry, revoke,
/// screen lock, gateway off, restart. Scope is key + host + methods + paths + limits.
final class GrantTests: XCTestCase {
    private func gatedService() throws -> (KeysService, RecordingPresenceGate, CatalogDB) {
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
        return (service, gate, db)
    }

    private func stub(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws -> LoopbackHTTPServer {
        let s = try LoopbackHTTPServer(host: "127.0.0.1", port: 0, handler: handler)
        s.start()
        return s
    }

    private func call(
        _ gateway: GatewayListener, _ path: String, method: String = "GET",
        token: String?, header: String = "Authorization", query: String = ""
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)\(path)\(query)")!)
        req.httpMethod = method
        if let token {
            req.setValue(header == "Authorization" ? "Bearer \(token)" : token, forHTTPHeaderField: header)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }

    func testTokenShapeAndRequestValidation() throws {
        let store = GrantStore()
        let issued = store.issue(key: "k", provider: "openai", host: "h", request: try GrantRequest(task: "x").validated())
        XCTAssertTrue(issued.token.hasPrefix("ksf_\(issued.grant.id)_"))
        XCTAssertEqual(GrantToken.idOf(issued.token), issued.grant.id)
        XCTAssertNil(GrantToken.idOf("sk-not-a-grant"))
        XCTAssertEqual(issued.grant.task, "x")
        XCTAssertEqual(try GrantRequest(task: "  ").validated().task, "agent task")
        XCTAssertThrowsError(try GrantRequest(task: "x", minutes: 0).validated())
        XCTAssertThrowsError(try GrantRequest(task: "x", minutes: Grant.maxMinutes + 1).validated())
        XCTAssertThrowsError(try GrantRequest(task: "x", methods: ["FETCH"]).validated())
        XCTAssertThrowsError(try GrantRequest(task: "x", paths: ["/a?b"]).validated())
        XCTAssertThrowsError(try GrantRequest(task: "x", maxRequests: 0).validated())
        XCTAssertThrowsError(try GrantRequest(task: "x", maxUsd: -1).validated())
        let r = try GrantRequest(task: "x", methods: ["get", "post "], paths: ["models/", "chat/completions"]).validated()
        XCTAssertEqual(r.methods, ["GET", "POST"])
        XCTAssertEqual(r.paths, ["/models", "/chat/completions"])
    }

    func testPathScopeIgnoresRepeatedProviderPrefix() {
        XCTAssertTrue(GrantPath.matches(rest: "v1/models", prefix: "/v1", allowed: ["/models"]))
        XCTAssertTrue(GrantPath.matches(rest: "models", prefix: "/v1", allowed: ["/models"]))
        XCTAssertTrue(GrantPath.matches(rest: "models/gpt-4.1", prefix: "/v1", allowed: ["/models"]))
        XCTAssertFalse(GrantPath.matches(rest: "modelsx", prefix: "/v1", allowed: ["/models"]))
        XCTAssertFalse(GrantPath.matches(rest: "chat/completions", prefix: "/v1", allowed: ["/models"]))
        XCTAssertTrue(GrantPath.matches(rest: "anything", prefix: "/v1", allowed: []))
    }

    func testStoreAuthorizeExpiryRevokeLimitsAndConstantTimeHash() throws {
        let store = GrantStore()
        let t0 = Date()
        let issued = store.issue(
            key: "k", provider: "openai", host: "h",
            request: try GrantRequest(task: "x", minutes: 10, methods: ["GET"], paths: ["/models"], maxRequests: 2).validated(),
            now: t0
        )
        let ok = store.authorize(token: issued.token, key: "k", host: "h", method: "get", rest: "v1/models", providerPrefix: "/v1", now: t0)
        XCTAssertEqual(try ok.get().id, issued.grant.id)
        XCTAssertEqual(store.authorize(token: nil, key: "k", host: "h", method: "GET", rest: "v1/models", providerPrefix: "/v1", now: t0), .failure(.required))
        XCTAssertEqual(store.authorize(token: "ksf_" + issued.grant.id + "_wrong", key: "k", host: "h", method: "GET", rest: "v1/models", providerPrefix: "/v1", now: t0), .failure(.invalid))
        XCTAssertEqual(store.authorize(token: issued.token, key: "other", host: "h", method: "GET", rest: "v1/models", providerPrefix: "/v1", now: t0), .failure(.keyMismatch))
        XCTAssertEqual(store.authorize(token: issued.token, key: "k", host: "elsewhere", method: "GET", rest: "v1/models", providerPrefix: "/v1", now: t0), .failure(.targetChanged))
        XCTAssertEqual(store.authorize(token: issued.token, key: "k", host: "h", method: "POST", rest: "v1/models", providerPrefix: "/v1", now: t0), .failure(.method("POST")))
        XCTAssertEqual(store.authorize(token: issued.token, key: "k", host: "h", method: "GET", rest: "v1/chat/completions", providerPrefix: "/v1", now: t0), .failure(.path("/v1/chat/completions")))
        // second allowed request, then the cap
        XCTAssertNoThrow(try store.authorize(token: issued.token, key: "k", host: "h", method: "GET", rest: "models", providerPrefix: "/v1", now: t0).get())
        XCTAssertEqual(store.authorize(token: issued.token, key: "k", host: "h", method: "GET", rest: "models", providerPrefix: "/v1", now: t0), .failure(.requestLimit))
        XCTAssertEqual(store.grant(id: issued.grant.id)?.requests, 2)
        // expiry
        let later = t0.addingTimeInterval(10 * 60 + 1)
        let fresh = store.issue(key: "k", provider: "openai", host: "h", request: try GrantRequest(task: "y", minutes: 5).validated(), now: t0)
        XCTAssertEqual(store.authorize(token: fresh.token, key: "k", host: "h", method: "GET", rest: "", providerPrefix: "", now: later), .failure(.expired))
        XCTAssertEqual(store.list(now: later).count, 0)
        XCTAssertEqual(store.list(includeInactive: true, now: later).count, 2)
        // revoke
        let third = store.issue(key: "k", provider: "openai", host: "h", request: try GrantRequest(task: "z").validated(), now: t0)
        XCTAssertNotNil(store.revoke(id: third.grant.id, reason: "revoked", now: t0))
        XCTAssertEqual(store.authorize(token: third.token, key: "k", host: "h", method: "GET", rest: "", providerPrefix: "", now: t0), .failure(.revoked))
        XCTAssertEqual(store.grant(id: third.grant.id)?.revokeReason, "revoked")
        // usd budget, enforced post-hoc
        let paid = store.issue(key: "k", provider: "openai", host: "h", request: try GrantRequest(task: "p", maxUsd: 0.01).validated(), now: t0)
        XCTAssertNoThrow(try store.authorize(token: paid.token, key: "k", host: "h", method: "POST", rest: "", providerPrefix: "", now: t0).get())
        store.charge(id: paid.grant.id, usd: 0.02)
        XCTAssertEqual(store.authorize(token: paid.token, key: "k", host: "h", method: "POST", rest: "", providerPrefix: "", now: t0), .failure(.usdLimit))
        // prune drops old inactive rows only
        store.prune(olderThan: 0, now: later.addingTimeInterval(1))
        XCTAssertNil(store.grant(id: issued.grant.id))
    }

    func testOneApprovalServesManyReadsAndUnrelatedCallsStayBlocked() async throws {
        let hits = HitBox()
        let stub = try stub { request in
            hits.record(request)
            return HTTPResponse.json(200, ["data": [["id": "gpt-4.1"]]])
        }
        defer { stub.stop() }
        let (service, gate, db) = try gatedService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-real")
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:\(stub.boundPort)", updateHost: true)
        XCTAssertEqual(gate.reasons, [])

        // Gateway was off: the grant turns it on with the SAME single prompt.
        let issued = try service.issueGrant(
            name: "demo",
            request: GrantRequest(task: "list models", minutes: 15, methods: ["GET"], paths: ["/models"]),
            caller: "cli"
        )
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertEqual(gate.reasons[0], "Grant \"list models\" the key demo for OpenAI at 127.0.0.1:\(stub.boundPort), 15 min")
        XCTAssertTrue(service.isGatewayEnabled("demo"))

        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        for header in ["Authorization", "x-api-key", "x-goog-api-key", "api-key"] {
            let (status, _) = try await call(gateway, "/demo/v1/models", token: issued.token, header: header)
            XCTAssertEqual(status, 200, header)
        }
        XCTAssertEqual(gate.reasons.count, 1, "no further prompts inside the approved scope")
        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(hits.lastAuth, "Bearer sk-real")

        // Gemini style: ?key=<grant> is accepted and stripped before forwarding.
        let (qStatus, _) = try await call(gateway, "/demo/v1/models", token: nil, query: "?key=\(issued.token)&pageSize=5")
        XCTAssertEqual(qStatus, 200)
        XCTAssertEqual(hits.lastQuery, ["pageSize": "5"])

        // Outside the scope: no upstream call.
        let before = hits.count
        let (noTok, noTokBody) = try await call(gateway, "/demo/v1/models", token: nil)
        XCTAssertEqual(noTok, 401)
        XCTAssertEqual(noTokBody["error"] as? String, "client_required", "no grant and no client: the unified 401")
        XCTAssertTrue((noTokBody["hint"] as? String ?? "").contains("keys grant demo"), "\(noTokBody)")
        let (post, postBody) = try await call(gateway, "/demo/v1/models", method: "POST", token: issued.token)
        XCTAssertEqual(post, 403)
        XCTAssertEqual(postBody["error"] as? String, "grant_method_not_allowed")
        let (path, pathBody) = try await call(gateway, "/demo/v1/chat/completions", token: issued.token)
        XCTAssertEqual(path, 403)
        XCTAssertEqual(pathBody["error"] as? String, "grant_path_not_allowed")
        let (bad, badBody) = try await call(gateway, "/demo/v1/models", token: "ksf_00000000_nope")
        XCTAssertEqual(bad, 401)
        XCTAssertEqual(badBody["error"] as? String, "grant_invalid")
        XCTAssertEqual(hits.count, before)

        // Audit trail names the grant, never the token.
        let events = try service.keyEvents(name: "demo")
        XCTAssertTrue(events.contains { $0.action == "grant" && ($0.detail ?? "").contains(issued.grant.id) })
        for e in events { XCTAssertFalse((e.detail ?? "").contains(issued.token)) }
        let listed = service.listGrants()
        XCTAssertEqual(listed.count, 1)
        XCTAssertGreaterThanOrEqual(listed[0].requests, 5)
        XCTAssertNil(listed[0].jsonObject()["token"])
        _ = db
    }

    func testRevokeGatewayOffScreenLockAndRestartFailClosed() async throws {
        let stub = try stub { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { stub.stop() }
        let (service, gate, _) = try gatedService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-real")
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:\(stub.boundPort)", updateHost: true)
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        let a = try service.issueGrant(name: "demo", request: GrantRequest(task: "a"), caller: "cli")
        let okA = try await call(gateway, "/demo/v1/models", token: a.token).0
        XCTAssertEqual(okA, 200)
        try service.revokeGrant(id: a.grant.id)
        let (rs, rb) = try await call(gateway, "/demo/v1/models", token: a.token)
        XCTAssertEqual(rs, 403)
        XCTAssertEqual(rb["error"] as? String, "grant_revoked")
        XCTAssertThrowsError(try service.revokeGrant(id: "deadbeef"))

        let b = try service.issueGrant(name: "demo", request: GrantRequest(task: "b"), caller: "cli")
        service.handleScreenLock()
        let lockedBody = try await call(gateway, "/demo/v1/models", token: b.token).1
        XCTAssertEqual(lockedBody["error"] as? String, "grant_revoked")
        XCTAssertEqual(service.listGrants(includeInactive: true).first { $0.id == b.grant.id }?.revokeReason, "screen_lock")

        let c = try service.issueGrant(name: "demo", request: GrantRequest(task: "c"), caller: "cli")
        _ = try service.setGateway(name: "demo", enabled: false, host: nil)
        let offStatus = try await call(gateway, "/demo/v1/models", token: c.token).0
        XCTAssertEqual(offStatus, 404, "gateway off: key not served at all")
        XCTAssertEqual(service.listGrants(includeInactive: true).first { $0.id == c.grant.id }?.revokeReason, "gateway_off")

        // A provider/host edit invalidates the grant target.
        let d = try service.issueGrant(name: "demo", request: GrantRequest(task: "d"), caller: "cli")
        let okD = try await call(gateway, "/demo/v1/models", token: d.token).0
        XCTAssertEqual(okD, 200)
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:1", updateHost: true)
        XCTAssertEqual(service.listGrants(includeInactive: true).first { $0.id == d.grant.id }?.revokeReason, "target_changed")

        // Restart: a new process has an empty table, so the same token is unknown.
        let (service2, _, _) = try gatedService()
        XCTAssertEqual(service2.listGrants(includeInactive: true).count, 0)
        XCTAssertEqual(
            service2.grants.authorize(token: d.token, key: "demo", host: "x", method: "GET", rest: "", providerPrefix: ""),
            .failure(.invalid)
        )
        XCTAssertGreaterThanOrEqual(gate.reasons.count, 4)
    }

    func testGrantRoutesAndControlFile() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let host = ["host": "127.0.0.1:12765"]
        let authed = ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken]

        let denied = handler.handle(HTTPRequest(
            method: "POST", path: "/api/keys/demo/grants", query: [:], headers: host,
            body: try JSONValue.data(["task": "t"]), serverPort: 12765
        ))
        XCTAssertEqual(denied.status, 403)

        let created = handler.handle(HTTPRequest(
            method: "POST", path: "/api/keys/demo/grants", query: [:], headers: authed,
            body: try JSONValue.data(["task": "t", "minutes": 5, "methods": ["GET"], "paths": ["/models"], "max_requests": 3]),
            serverPort: 12765
        ))
        XCTAssertEqual(created.status, 201, String(data: created.body, encoding: .utf8)!)
        let obj = try JSONSerialization.jsonObject(with: created.body) as! [String: Any]
        let token = obj["token"] as! String
        XCTAssertTrue(GrantToken.looksLikeToken(token))
        XCTAssertEqual(obj["base_url"] as? String, "http://127.0.0.1:12767/demo/v1")
        XCTAssertEqual(obj["host"] as? String, "api.openai.com")
        XCTAssertEqual(obj["max_requests"] as? Int, 3)

        let list = handler.handle(HTTPRequest(method: "GET", path: "/api/grants", query: [:], headers: host, body: Data(), serverPort: 12765))
        let listObj = try JSONSerialization.jsonObject(with: list.body) as! [String: Any]
        let grants = listObj["grants"] as! [[String: Any]]
        XCTAssertEqual(grants.count, 1)
        XCTAssertFalse(String(data: list.body, encoding: .utf8)!.contains(token), "list never carries tokens")

        let keys = handler.handle(HTTPRequest(method: "GET", path: "/api/keys", query: [:], headers: host, body: Data(), serverPort: 12765))
        let keysObj = try JSONSerialization.jsonObject(with: keys.body) as! [String: Any]
        let row = (keysObj["keys"] as! [[String: Any]])[0]
        XCTAssertEqual(row["active_grants"] as? Int, 1)
        XCTAssertEqual(row["host"] as? String, "api.openai.com")
        XCTAssertEqual(row["provider_name"] as? String, "OpenAI")
        XCTAssertEqual(row["checkable"] as? Bool, true)

        let bad = handler.handle(HTTPRequest(
            method: "POST", path: "/api/keys/demo/grants", query: [:], headers: authed,
            body: try JSONValue.data(["task": "t", "minutes": 0]), serverPort: 12765
        ))
        XCTAssertEqual(bad.status, 400)

        let id = obj["id"] as! String
        let revoked = handler.handle(HTTPRequest(method: "DELETE", path: "/api/grants/\(id)", query: [:], headers: authed, body: Data(), serverPort: 12765))
        XCTAssertEqual(revoked.status, 200)
        XCTAssertEqual(service.listGrants().count, 0)
        let twice = handler.handle(HTTPRequest(method: "DELETE", path: "/api/grants/\(id)", query: [:], headers: authed, body: Data(), serverPort: 12765))
        XCTAssertEqual(twice.status, 200, "revoke is idempotent")
        let gone = handler.handle(HTTPRequest(method: "DELETE", path: "/api/grants/deadbeef", query: [:], headers: authed, body: Data(), serverPort: 12765))
        XCTAssertEqual(gone.status, 404)
        _ = handler.handle(HTTPRequest(
            method: "POST", path: "/api/keys/demo/grants", query: [:], headers: authed,
            body: try JSONValue.data(["task": "again"]), serverPort: 12765
        ))
        let all = handler.handle(HTTPRequest(method: "DELETE", path: "/api/grants", query: ["key": "demo"], headers: authed, body: Data(), serverPort: 12765))
        XCTAssertEqual(all.status, 200)
        XCTAssertEqual(service.listGrants().count, 0)

        // Control file: 0600, pid-checked, removed only by its owner.
        setenv("KEYS_CONTROL", dir.appendingPathComponent("control.json").path, 1)
        defer { unsetenv("KEYS_CONTROL") }
        try ControlFile.write(port: 12765, token: handler.originToken)
        let attrs = try FileManager.default.attributesOfItem(atPath: ControlFile.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(ControlFile.live()?.token, handler.originToken)
        try ControlFile.write(port: 1, token: "stale", pid: 2_147_483_000)
        XCTAssertNil(ControlFile.live())
        ControlFile.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ControlFile.url.path), "another pid's file is left alone")
    }

    func testRedactScrubsSecretsBearerAndGrantTokens() {
        let s = Redact.scrub(
            "key sk-live-abcdef failed; Authorization: Bearer sk-live-abcdef; grant ksf_0a1b2c3d_QUJD; x-api-key: zzz-1234",
            secrets: ["sk-live-abcdef"]
        )
        XCTAssertFalse(s.contains("sk-live-abcdef"))
        XCTAssertFalse(s.contains("ksf_0a1b2c3d_QUJD"))
        XCTAssertFalse(s.contains("zzz-1234"))
        XCTAssertTrue(s.contains("[redacted]"))
    }
}

private final class HitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private(set) var lastAuth: String?
    private(set) var lastQuery: [String: String] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func record(_ r: HTTPRequest) {
        lock.lock()
        n += 1
        lastAuth = r.headers["authorization"]
        lastQuery = r.query
        lock.unlock()
    }
}

/// `keys grant` in a Terminal talks to the running site through the control file.
final class ControlClientTests: XCTestCase {
    func testCLIPathIssuesListsAndRevokesThroughTheSite() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }

        setenv("KEYS_CONTROL", dir.appendingPathComponent("control.json").path, 1)
        defer { unsetenv("KEYS_CONTROL") }
        XCTAssertThrowsError(try ControlClient.connect(), "no control file: clear error, no hang")
        try ControlFile.write(port: server.boundPort, token: handler.originToken)

        let client = try ControlClient.connect()
        let (status, obj) = try client.call(
            method: "POST", path: "/api/keys/demo/grants",
            body: ["task": "cli", "minutes": 5, "methods": ["GET"], "paths": ["/models"], "caller": "cli"]
        )
        XCTAssertEqual(status, 201, "\(obj)")
        let token = try XCTUnwrap(obj["token"] as? String)
        XCTAssertTrue(GrantToken.looksLikeToken(token))
        let id = try XCTUnwrap(obj["id"] as? String)
        XCTAssertEqual(try service.keyEvents(name: "demo").first?.caller, "cli")

        let (ls, lobj) = try client.call(method: "GET", path: "/api/grants")
        XCTAssertEqual(ls, 200)
        XCTAssertEqual((lobj["grants"] as? [Any])?.count, 1)

        let (rs, _) = try client.call(method: "DELETE", path: "/api/grants/\(id)")
        XCTAssertEqual(rs, 200)
        XCTAssertEqual(service.listGrants().count, 0)

        // A stale token from an older launch maps to a clear error, not a hang or a crash.
        try ControlFile.write(port: server.boundPort, token: "stale")
        let stale = try ControlClient.connect()
        let (ss, sobj) = try stale.call(method: "POST", path: "/api/keys/demo/grants", body: ["task": "x"])
        XCTAssertEqual(ss, 403)
        if case .usage(let m) = ControlClient.raise(status: ss, body: sobj) {
            XCTAssertTrue(m.contains("restart the site"), m)
        } else {
            XCTFail("expected usage error")
        }
        if case .authCancelled = ControlClient.raise(status: 403, body: ["error": "auth_cancelled"]) {} else { XCTFail("auth_cancelled") }
    }
}
