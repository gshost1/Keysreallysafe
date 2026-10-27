import XCTest
@testable import KeysCore

/// Temporary, narrowly scoped access: one prompt per task, fail closed on expiry, revoke,
/// screen lock, gateway off, restart. Scope is key + host + methods + paths + limits.
final class GrantTests: XCTestCase {
    private func gatedService() throws -> (KeysService, RecordingPresenceGate, CatalogDB) {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        return (service, gate, db)
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

    /// The relay test with Anthropic (prefix /v1) was refused for `--paths /v1/messages`
    /// with "path /v1/messages is outside this grant (allows /v1/messages)".
    func testGrantPathThatRepeatsTheProviderPrefixMeansTheSameScope() {
        XCTAssertTrue(GrantPath.matches(rest: "v1/messages", prefix: "/v1", allowed: ["/v1/messages"]))
        XCTAssertTrue(GrantPath.matches(rest: "messages", prefix: "/v1", allowed: ["/v1/messages"]))
        XCTAssertTrue(GrantPath.matches(rest: "v1/messages/count_tokens", prefix: "/v1", allowed: ["/v1/messages"]))
        XCTAssertFalse(GrantPath.matches(rest: "v1/models", prefix: "/v1", allowed: ["/v1/messages"]))
        XCTAssertFalse(GrantPath.matches(rest: "v1/messagesx", prefix: "/v1", allowed: ["/v1/messages"]))
        XCTAssertTrue(GrantPath.matches(rest: "v1/models", prefix: "/v1", allowed: ["/v1"]), "the prefix itself is the whole provider")
        XCTAssertFalse(GrantPath.matches(rest: "v1/messages/../models", prefix: "/v1", allowed: ["/v1"]))
        XCTAssertFalse(GrantPath.matches(rest: "v2/messages", prefix: "", allowed: ["/v1/messages"]), "no prefix, nothing stripped")
    }

    // `/models/../responses` passes a prefix check and is forwarded as-is; an upstream that
    // collapses dot segments would then serve a scope the grant never named.
    func testPathScopeRejectsDotSegments() {
        for rest in [
            "models/../responses", "v1/models/../responses", "models/./x", "models/..",
            "models/%2e%2e/responses", "models/%2E%2E/responses", "models/.%2e/responses",
        ] {
            XCTAssertFalse(GrantPath.matches(rest: rest, prefix: "/v1", allowed: ["/models"]), rest)
            XCTAssertFalse(GrantPath.matches(rest: rest, prefix: "/v1", allowed: []), "unscoped: \(rest)")
            XCTAssertNil(GrantPath.suggestion(rest: "api/" + rest, prefix: "", allowed: ["/models"]), rest)
        }
        // Dots inside a segment are ordinary path text.
        XCTAssertTrue(GrantPath.matches(rest: "models/gpt-4.1", prefix: "/v1", allowed: ["/models"]))
        XCTAssertTrue(GrantPath.matches(rest: "models/..x", prefix: "/v1", allowed: ["/models"]))

        let store = GrantStore()
        let issued = store.issue(
            key: "k", provider: "openai", host: "h",
            request: try! GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]).validated()
        )
        guard case .failure(.path) = store.authorize(
            token: issued.token, key: "k", host: "h", method: "GET",
            rest: "v1/models/../responses", providerPrefix: "/v1"
        ) else { return XCTFail("dot-segment path was authorized") }
    }

    // Seen live: a provider with an empty catalog prefix serves /v1/models, the agent
    // scoped the grant to /models, and the denial gave it nothing to correct.
    func testPathDenialSuggestsTheScopeTheCallerMeant() {
        XCTAssertEqual(GrantPath.suggestion(rest: "v1/models", prefix: "", allowed: ["/models"]), "/v1/models")
        XCTAssertEqual(GrantPath.suggestion(rest: "v1/models/jev-latest", prefix: "", allowed: ["/models"]), "/v1/models")
        XCTAssertEqual(GrantPath.suggestion(rest: "api/v2/models", prefix: "", allowed: ["/models"]), "/api/v2/models")
        // Unrelated paths and already-allowed shapes get no suggestion.
        XCTAssertNil(GrantPath.suggestion(rest: "v1/chat/completions", prefix: "/v1", allowed: ["/models"]))
        XCTAssertNil(GrantPath.suggestion(rest: "modelsx", prefix: "", allowed: ["/models"]))
        XCTAssertNil(GrantPath.suggestion(rest: "v1/models", prefix: "", allowed: []))

        let denial = GrantDenial.path("/v1/models", allowed: ["/models"], suggestion: "/v1/models")
        XCTAssertEqual(denial.code, "grant_path_not_allowed")
        XCTAssertTrue(denial.message.contains("allows /models"), denial.message)
        XCTAssertTrue(denial.message.contains("--paths /v1/models"), denial.message)
        XCTAssertEqual(denial.details["allowed_paths"] as? [String], ["/models"])
        XCTAssertEqual(denial.details["suggested_paths"] as? String, "/v1/models")
        XCTAssertTrue(GrantDenial.expired.details.isEmpty)

        let store = GrantStore()
        let issued = store.issue(
            key: "k", provider: "typesafe", host: "h",
            request: try! GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]).validated()
        )
        XCTAssertEqual(
            store.authorize(token: issued.token, key: "k", host: "h", method: "GET", rest: "v1/models", providerPrefix: ""),
            .failure(.path("/v1/models", allowed: ["/models"], suggestion: "/v1/models"))
        )
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
        XCTAssertEqual(store.authorize(token: issued.token, key: "k", host: "h", method: "GET", rest: "v1/chat/completions", providerPrefix: "/v1", now: t0), .failure(.path("/v1/chat/completions", allowed: ["/models"])))
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
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["data": [["id": "gpt-4.1"]]])
        }
        defer { rig.stop() }
        let (service, gate, stub, gateway) = (rig.service, rig.gate, rig.stub, rig.gateway)
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
        XCTAssertEqual(gate.reasons[0], "grant \"list models\" the key demo for OpenAI at 127.0.0.1:\(stub.boundPort), 15 min")
        XCTAssertTrue(service.isGatewayEnabled("demo"))

        for header in ["Authorization", "x-api-key", "x-goog-api-key", "api-key"] {
            let (status, _) = try await call(gateway, "/demo/v1/models", token: issued.token, header: header)
            XCTAssertEqual(status, 200, header)
        }
        XCTAssertEqual(gate.reasons.count, 1, "no further prompts inside the approved scope")
        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(hits.last?.headers["authorization"], "Bearer sk-real")

        // Gemini style: ?key=<grant> is accepted and stripped before forwarding.
        let (qStatus, _) = try await call(gateway, "/demo/v1/models", token: nil, query: "?key=\(issued.token)&pageSize=5")
        XCTAssertEqual(qStatus, 200)
        XCTAssertEqual(hits.last?.query, ["pageSize": "5"])

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
        XCTAssertEqual(pathBody["allowed_paths"] as? [String], ["/models"], "\(pathBody)")
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
    }

    func testRevokeGatewayOffScreenLockAndRestartFailClosed() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        let (service, gate, gateway) = (rig.service, rig.gate, rig.gateway)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-real")
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:\(rig.stub.boundPort)", updateHost: true)

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

        let denied = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(["task": "t"]), token: false)
        XCTAssertEqual(denied.status, 403)

        let created = handle(
            handler, method: "POST", path: "/api/keys/demo/grants",
            body: try JSONValue.data(["task": "t", "minutes": 5, "methods": ["GET"], "paths": ["/models"], "max_requests": 3])
        )
        XCTAssertEqual(created.status, 201, String(data: created.body, encoding: .utf8)!)
        let obj = try JSONSerialization.jsonObject(with: created.body) as! [String: Any]
        let token = obj["token"] as! String
        XCTAssertTrue(GrantToken.looksLikeToken(token))
        XCTAssertEqual(obj["base_url"] as? String, "http://127.0.0.1:12767/demo/v1")
        XCTAssertEqual(obj["host"] as? String, "api.openai.com")
        XCTAssertEqual(obj["max_requests"] as? Int, 3)

        let list = handle(handler, method: "GET", path: "/api/grants")
        let listObj = try JSONSerialization.jsonObject(with: list.body) as! [String: Any]
        let grants = listObj["grants"] as! [[String: Any]]
        XCTAssertEqual(grants.count, 1)
        XCTAssertFalse(String(data: list.body, encoding: .utf8)!.contains(token), "list never carries tokens")

        let keys = handle(handler, method: "GET", path: "/api/keys")
        let keysObj = try JSONSerialization.jsonObject(with: keys.body) as! [String: Any]
        let row = (keysObj["keys"] as! [[String: Any]])[0]
        XCTAssertEqual(row["active_grants"] as? Int, 1)
        XCTAssertEqual(row["host"] as? String, "api.openai.com")
        XCTAssertEqual(row["checkable"] as? Bool, true)

        let bad = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(["task": "t", "minutes": 0]))
        XCTAssertEqual(bad.status, 400)

        let id = obj["id"] as! String
        let revoked = handle(handler, method: "DELETE", path: "/api/grants/\(id)")
        XCTAssertEqual(revoked.status, 200)
        XCTAssertEqual(service.listGrants().count, 0)
        let twice = handle(handler, method: "DELETE", path: "/api/grants/\(id)")
        XCTAssertEqual(twice.status, 200, "revoke is idempotent")
        let gone = handle(handler, method: "DELETE", path: "/api/grants/deadbeef")
        XCTAssertEqual(gone.status, 404)
        _ = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(["task": "again"]))
        let all = handle(handler, method: "DELETE", path: "/api/grants", query: ["key": "demo"])
        XCTAssertEqual(all.status, 200)
        XCTAssertEqual(service.listGrants().count, 0)
        let missing = handle(handler, method: "DELETE", path: "/api/grants/0badc0de")
        XCTAssertEqual(missing.status, 404)
        let missingObj = try JSONSerialization.jsonObject(with: missing.body) as! [String: Any]
        XCTAssertEqual(missingObj["error"] as? String, "not_found", "the code the dashboard matches on is unchanged")
        XCTAssertEqual(missingObj["detail"] as? String, "0badc0de")

        // Control file: 0600, pid-checked, removed only by its owner.
        let control = ControlFile.url(beside: service.catalog.path)
        XCTAssertEqual(control, dir.appendingPathComponent("control.json"))
        try ControlFile.write(port: 12765, token: handler.originToken, to: control)
        let attrs = try FileManager.default.attributesOfItem(atPath: control.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(ControlFile.live(at: control)?.token, handler.originToken)
        XCTAssertNoThrow(try service.rotate(name: "demo", secret: "rotated-synthetic"), "our own control file does not block us")
        try ControlFile.write(port: 1, token: "stale", pid: 2_147_483_000, to: control)
        XCTAssertNil(ControlFile.live(at: control))
        ControlFile.remove(at: control)
        XCTAssertTrue(FileManager.default.fileExists(atPath: control.path), "another pid's file is left alone")
        for pid in [0, -1] {
            try ControlFile.write(port: 1, token: "group", pid: pid_t(pid), to: control)
            XCTAssertNil(ControlFile.live(at: control), "pid \(pid) would signal a process group")
        }
    }

    // MARK: - Profile-bounded issuance

    /// A service with one vault key, the base for the profile issuance tests.
    private func profiledService() throws -> (KeysService, RecordingPresenceGate, CatalogDB) {
        let (service, gate, db) = try gatedService()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        return (service, gate, db)
    }

    /// The saved profile the issuance tests use: every bound set, unattended.
    @discardableResult
    private func saveProfile(
        _ service: KeysService,
        name: String = "evals",
        keys: [String] = ["demo"],
        methods: Set<String> = ["GET", "POST"],
        paths: [String] = ["/v1/messages"],
        minutes: Int = 480,
        maxRequests: Int? = 500,
        maxUsd: Double? = 2.5,
        unattended: Bool = true
    ) throws -> Profile {
        try service.addProfile(ProfileRequest(
            name: name, keys: keys, methods: methods, paths: paths, minutes: minutes,
            maxRequests: maxRequests, maxUsd: maxUsd, unattended: unattended
        ))
    }

    /// A refusal's whole contract: its own named error, its wire code, and a presence gate
    /// that never saw the ask.
    private func assertPrePromptRefusal(
        _ expected: ProfileError,
        gate: RecordingPresenceGate,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let e = error as? ProfileError else {
                return XCTFail("expected \(expected), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(e, expected, "\(e)", file: file, line: line)
            XCTAssertEqual(e.code, expected.code, "the wire code is part of the refusal", file: file, line: line)
        }
        XCTAssertEqual(gate.reasons, [], "a refused ask consumed no prompt", file: file, line: line)
    }

    /// A profile's values are defaults for whatever the ask left out and ceilings for the
    /// rest: tightening is honored, nothing is silently widened, and the grant records the
    /// profile and its unattended flag for display and audit.
    func testProfileGrantTakesTheProfileAsDefaultsAndHonorsTightening() throws {
        let (service, gate, _) = try profiledService()
        _ = try saveProfile(service)

        let defaulted = try service.issueGrant(
            name: "demo", request: GrantRequest(task: "night evals"), profile: "evals", caller: "cli"
        )
        XCTAssertEqual(
            Int(defaulted.grant.expiresAt.timeIntervalSince(defaulted.grant.createdAt) / 60), 480,
            "an unset lifetime takes the profile's"
        )
        XCTAssertEqual(defaulted.grant.methods, ["GET", "POST"])
        XCTAssertEqual(defaulted.grant.paths, ["/v1/messages"])
        XCTAssertEqual(defaulted.grant.maxRequests, 500)
        XCTAssertEqual(defaulted.grant.maxUsd, 2.5)
        XCTAssertEqual(defaulted.grant.profile, "evals")
        XCTAssertEqual(defaulted.grant.unattended, true)
        XCTAssertEqual(defaulted.grant.jsonObject()["profile"] as? String, "evals")
        XCTAssertEqual(defaulted.grant.jsonObject()["unattended"] as? Bool, true)
        XCTAssertEqual(gate.reasons.count, 1)

        // Tightening: every named bound lands as asked, inside the profile.
        let tightened = try service.issueGrant(
            name: "demo",
            request: GrantRequest(
                task: "quick evals", minutes: 60, methods: ["GET"],
                paths: ["/v1/messages/count_tokens"], maxRequests: 10, maxUsd: 1
            ),
            profile: "evals",
            specified: GrantSpecified(minutes: true, methods: true, paths: true, maxRequests: true, maxUsd: true),
            caller: "cli"
        )
        XCTAssertEqual(
            Int(tightened.grant.expiresAt.timeIntervalSince(tightened.grant.createdAt) / 60), 60
        )
        XCTAssertEqual(tightened.grant.methods, ["GET"])
        XCTAssertEqual(tightened.grant.paths, ["/v1/messages/count_tokens"])
        XCTAssertEqual(tightened.grant.maxRequests, 10)
        XCTAssertEqual(tightened.grant.maxUsd, 1)
        XCTAssertEqual(tightened.grant.profile, "evals", "the profile rides along even when tightened")
        XCTAssertEqual(tightened.grant.unattended, true, "unattended comes from the profile, never the ask")

        // A profile without a cap lets the ask pick its own (still only a tightening), and a
        // non-unattended profile issues a plain watched grant.
        _ = try saveProfile(
            service, name: "reads", methods: Grant.allMethods, paths: [], minutes: 1440,
            maxRequests: nil, maxUsd: nil, unattended: false
        )
        let picky = try service.issueGrant(
            name: "demo",
            request: GrantRequest(task: "reads", minutes: 1440, maxRequests: 5, maxUsd: 1),
            profile: "reads",
            specified: GrantSpecified(minutes: true, maxRequests: true, maxUsd: true),
            caller: "cli"
        )
        XCTAssertEqual(picky.grant.methods, Grant.allMethods)
        XCTAssertEqual(picky.grant.paths, [])
        XCTAssertEqual(picky.grant.maxRequests, 5)
        XCTAssertEqual(picky.grant.maxUsd, 1)
        XCTAssertEqual(picky.grant.profile, "reads")
        XCTAssertEqual(picky.grant.unattended, false)
        let uncapped = try service.issueGrant(name: "demo", request: GrantRequest(task: "uncapped"), profile: "reads")
        XCTAssertNil(uncapped.grant.maxRequests)
        XCTAssertNil(uncapped.grant.maxUsd)

        // The audit row names the profile; the token and the secret stay out of it.
        let events = try service.keyEvents(name: "demo").filter { $0.action == "grant" }
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("profile evals") })
        for e in events {
            XCTAssertFalse((e.detail ?? "").contains(defaulted.token), "audit keeps the id, never the token")
            XCTAssertFalse((e.detail ?? "").contains(fixtureSecret))
        }
    }

    /// Every way an ask can sit outside a profile is refused with its own named error, and the
    /// Touch ID prompt is never consumed for a refused ask. The codes are the wire the CLI
    /// control path and the dashboard read.
    func testOutOfProfileBoundsIsRefusedBeforeThePromptWithItsOwnNamedError() throws {
        let (service, gate, db) = try profiledService()
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret + "2")
        _ = try saveProfile(service)

        assertPrePromptRefusal(.notFound("nope"), gate: gate) {
            try service.issueGrant(name: "demo", request: GrantRequest(task: "x"), profile: "nope")
        }
        assertPrePromptRefusal(.keyNotAllowed(key: "other", profile: "evals", keys: ["demo"]), gate: gate) {
            try service.issueGrant(name: "other", request: GrantRequest(task: "x"), profile: "evals")
        }
        assertPrePromptRefusal(
            .methodNotAllowed(method: "DELETE", profile: "evals", methods: ["GET", "POST"]), gate: gate
        ) {
            try service.issueGrant(
                name: "demo",
                request: GrantRequest(task: "x", methods: ["GET", "DELETE"]),
                profile: "evals",
                specified: GrantSpecified(methods: true)
            )
        }
        assertPrePromptRefusal(
            .pathNotAllowed(path: "/v1/models", profile: "evals", paths: ["/v1/messages"]), gate: gate
        ) {
            try service.issueGrant(
                name: "demo",
                request: GrantRequest(task: "x", paths: ["/v1/models"]),
                profile: "evals",
                specified: GrantSpecified(paths: true)
            )
        }
        // An explicitly empty path list asks for any path: wider than a scoped profile, so it
        // is refused instead of passing as a vacuous subset. `/` was already refused by name.
        for (paths, named) in [([String](), "any path"), (["/"], "/")] {
            assertPrePromptRefusal(
                .pathNotAllowed(path: named, profile: "evals", paths: ["/v1/messages"]), gate: gate
            ) {
                try service.issueGrant(
                    name: "demo",
                    request: GrantRequest(task: "x", paths: paths),
                    profile: "evals",
                    specified: GrantSpecified(paths: true)
                )
            }
        }
        assertPrePromptRefusal(.minutesOver(requested: 481, profile: "evals", ceiling: 480), gate: gate) {
            try service.issueGrant(
                name: "demo",
                request: GrantRequest(task: "x", minutes: 481),
                profile: "evals",
                specified: GrantSpecified(minutes: true)
            )
        }
        assertPrePromptRefusal(.requestCapOver(requested: 501, profile: "evals", ceiling: 500), gate: gate) {
            try service.issueGrant(
                name: "demo",
                request: GrantRequest(task: "x", maxRequests: 501),
                profile: "evals",
                specified: GrantSpecified(maxRequests: true)
            )
        }
        assertPrePromptRefusal(.usdCapOver(requested: 3, profile: "evals", ceiling: 2.5), gate: gate) {
            try service.issueGrant(
                name: "demo",
                request: GrantRequest(task: "x", maxUsd: 3),
                profile: "evals",
                specified: GrantSpecified(maxUsd: true)
            )
        }
        XCTAssertEqual(service.listGrants(includeInactive: true).count, 0, "no refused ask left a grant behind")

        // Fail closed on a row that bypassed save-time validation: an unattended profile
        // with no hard cap issues nothing, even though `addProfile` would have refused it.
        try db.insertProfile(Profile(
            id: "deadbee1", name: "raw", keys: ["demo"], methods: Grant.allMethods, paths: [],
            minutes: 60, maxRequests: nil, maxUsd: nil, unattended: true,
            createdAt: Date(), updatedAt: Date()
        ))
        assertPrePromptRefusal(.requiresCap, gate: gate) {
            try service.issueGrant(name: "demo", request: GrantRequest(task: "x"), profile: "raw")
        }
        XCTAssertEqual(gate.reasons, [], "through the whole matrix, no prompt was consumed")
    }

    /// The prompt is the one line a local process that rewrote a profile cannot cross, so a
    /// profile grant names the profile AND the effective scope — the tightened one, not the
    /// saved one. Plain grants keep the pinned format, byte-identical.
    func testThePromptNamesTheProfileAndTheEffectiveScopeAndPlainGrantsStayPinned() throws {
        let (service, gate, _) = try profiledService()
        _ = try saveProfile(service)
        _ = try saveProfile(
            service, name: "reads", methods: Grant.allMethods, paths: [], minutes: 30,
            maxRequests: nil, maxUsd: nil, unattended: false
        )

        // The plain format, pinned as before, and the additive JSON fields stay null/false.
        let plain = try service.issueGrant(name: "demo", request: GrantRequest(task: "list models", minutes: 15), caller: "cli")
        XCTAssertEqual(
            gate.reasons.last,
            "grant \"list models\" the key demo for OpenAI at api.openai.com, 15 min"
        )
        XCTAssertTrue(plain.grant.jsonObject()["profile"] is NSNull)
        XCTAssertEqual(plain.grant.jsonObject()["unattended"] as? Bool, false)

        // The profile format: task, key, provider, host, span, then the profile name and the
        // effective methods, paths, caps, and the word unattended — in that order.
        _ = try service.issueGrant(name: "demo", request: GrantRequest(task: "night evals"), profile: "evals", caller: "cli")
        XCTAssertEqual(
            gate.reasons.last,
            "grant \"night evals\" the key demo for OpenAI at api.openai.com, 8 h, "
                + "profile evals: GET,POST, /v1/messages, max 500 req, max $2.50, unattended"
        )

        // All methods are spelled out, no paths reads "any path", and a watched profile
        // never says unattended.
        _ = try service.issueGrant(name: "demo", request: GrantRequest(task: "reading"), profile: "reads", caller: "cli")
        XCTAssertEqual(
            gate.reasons.last,
            "grant \"reading\" the key demo for OpenAI at api.openai.com, 30 min, "
                + "profile reads: DELETE,GET,HEAD,OPTIONS,PATCH,POST,PUT, any path"
        )

        // A tightened ask is shown with its tightened values, not the profile's.
        _ = try service.issueGrant(
            name: "demo",
            request: GrantRequest(
                task: "tight", minutes: 60, methods: ["GET"], paths: ["/v1/messages/count_tokens"],
                maxRequests: 10, maxUsd: 1
            ),
            profile: "evals",
            specified: GrantSpecified(minutes: true, methods: true, paths: true, maxRequests: true, maxUsd: true),
            caller: "cli"
        )
        XCTAssertEqual(
            gate.reasons.last,
            "grant \"tight\" the key demo for OpenAI at api.openai.com, 1 h, "
                + "profile evals: GET, /v1/messages/count_tokens, max 10 req, max $1.00, unattended"
        )
        XCTAssertEqual(gate.reasons.count, 4, "exactly one prompt per grant, profile or not")
    }

    /// A profile mints nothing by itself: presence is still the only gate that issues. With
    /// the gate throwing (as a denied Touch ID does), no grant exists; with it recording, the
    /// same ask issues — and keeps exactly the scope it was tightened to.
    func testAProfileAloneMintsNothingWhenThePresenceGateThrows() throws {
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate(error: AppError.authCancelled)
        let (service, _) = makeGatedService(db: db, gate: gate)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.addProfile(ProfileRequest(
            name: "evals", keys: ["demo"], methods: ["GET"], paths: ["/v1/messages"],
            minutes: 60, maxRequests: 5, maxUsd: nil, unattended: false
        ))
        XCTAssertThrowsError(
            try service.issueGrant(name: "demo", request: GrantRequest(task: "night evals"), profile: "evals")
        ) { error in
            guard case AppError.authCancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(service.listGrants(includeInactive: true).count, 0, "no grant exists after a denied prompt")
        XCTAssertEqual(gate.reasons.count, 1, "the prompt was asked and denied, not skipped")

        // The same ask with the gate accepting issues and stays tight.
        gate.error = nil
        let issued = try service.issueGrant(
            name: "demo",
            request: GrantRequest(task: "night evals", minutes: 30, methods: ["GET"]),
            profile: "evals",
            specified: GrantSpecified(minutes: true, methods: true)
        )
        XCTAssertEqual(gate.reasons.count, 2)
        XCTAssertNoThrow(try service.grants.authorize(
            token: issued.token, key: "demo", host: "api.openai.com", method: "GET",
            rest: "v1/messages", providerPrefix: "/v1"
        ).get())
        XCTAssertEqual(
            service.grants.authorize(
                token: issued.token, key: "demo", host: "api.openai.com", method: "POST",
                rest: "v1/messages", providerPrefix: "/v1"
            ),
            .failure(.method("POST")),
            "the tightened scope is what the grant carries"
        )
    }

    /// A grant is self-contained: the profile is consulted at issuance only, so deleting it —
    /// or re-adding the same name with wider bounds — changes nothing about a live grant.
    func testEditingOrDeletingTheProfileAfterIssuanceLeavesTheGrantSelfContained() throws {
        let (service, gate, _) = try profiledService()
        _ = try saveProfile(
            service, methods: ["GET"], paths: ["/v1/messages"], minutes: 60,
            maxRequests: 3, maxUsd: nil, unattended: false
        )
        let issued = try service.issueGrant(name: "demo", request: GrantRequest(task: "sweep"), profile: "evals")
        let token = issued.token

        func authorize(_ method: String, _ rest: String) -> Result<Grant, GrantDenial> {
            service.grants.authorize(
                token: token, key: "demo", host: "api.openai.com",
                method: method, rest: rest, providerPrefix: "/v1"
            )
        }
        XCTAssertNoThrow(try authorize("GET", "v1/messages").get())

        // "Edit" is remove + re-add: the same name, wider bounds.
        _ = try service.removeProfile(name: "evals")
        XCTAssertNoThrow(try authorize("GET", "v1/messages").get(), "delete changed nothing about the live grant")
        XCTAssertEqual(authorize("POST", "v1/messages"), .failure(.method("POST")))
        XCTAssertEqual(authorize("GET", "v1/models"), .failure(.path("/v1/models", allowed: ["/v1/messages"])))

        _ = try saveProfile(
            service, methods: Grant.allMethods, paths: [], minutes: 1440,
            maxRequests: nil, maxUsd: nil, unattended: false
        )
        XCTAssertEqual(authorize("POST", "v1/messages"), .failure(.method("POST")), "a wider profile does not widen a live grant")
        XCTAssertEqual(authorize("GET", "v1/models"), .failure(.path("/v1/models", allowed: ["/v1/messages"])))
        let live = service.listGrants().filter { $0.id == issued.grant.id }
        XCTAssertEqual(live.map(\.methods), [["GET"]], "the grant keeps its recorded scope")
        XCTAssertEqual(live.map(\.paths), [["/v1/messages"]])
        XCTAssertEqual(live.map(\.profile), ["evals" as String?], "the profile name stays for display and audit")
        XCTAssertEqual(live.compactMap(\.maxRequests), [3])
        XCTAssertEqual(gate.reasons.count, 1, "profile edits never prompt")
    }

    /// The dashboard API and the CLI control-file path ask the same service, so a profile
    /// grant is bounded identically on both, and the refusals keep their names on the wire.
    func testTheAPIAndControlFilePathsIssueUnderTheProfileWithNamedRefusals() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try saveProfile(service)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)

        // The dashboard API path: a profile field in the body, no scope fields, and the
        // profile's bounds land on the grant.
        let ask: [String: Any] = ["task": "api sweep", "profile": "evals"]
        let created = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(ask))
        XCTAssertEqual(created.status, 201, String(data: created.body, encoding: .utf8)!)
        let obj = try JSONSerialization.jsonObject(with: created.body) as! [String: Any]
        XCTAssertEqual(obj["profile"] as? String, "evals")
        XCTAssertEqual(obj["unattended"] as? Bool, true)
        XCTAssertEqual(obj["methods"] as? [String], ["GET", "POST"])
        XCTAssertEqual(obj["paths"] as? [String], ["/v1/messages"])
        XCTAssertEqual(obj["max_requests"] as? Int, 500)
        XCTAssertEqual(obj["max_usd"] as? Double, 2.5)

        // The refusals surface as named JSON errors, with the missing profile a 404.
        let unknownAsk: [String: Any] = ["task": "x", "profile": "nope"]
        let unknown = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(unknownAsk))
        XCTAssertEqual(unknown.status, 404)
        let unknownObj = try JSONSerialization.jsonObject(with: unknown.body) as! [String: Any]
        XCTAssertEqual(unknownObj["error"] as? String, "profile_not_found")

        // Minutes are a ceiling: an ask above the profile's is refused before the prompt.
        let overAsk: [String: Any] = ["task": "x", "profile": "evals", "minutes": 500]
        let over = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(overAsk))
        XCTAssertEqual(over.status, 400)
        let overObj = try JSONSerialization.jsonObject(with: over.body) as! [String: Any]
        XCTAssertEqual(overObj["error"] as? String, "profile_minutes_over")
        let overMessage = overObj["message"] as? String ?? ""
        XCTAssertTrue(overMessage.contains("480"), overMessage)

        // The CLI path rides the same handler through the control file, so it is the same
        // bounded grant, and a refusal over the wire reads back as its message.
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        let client = try ControlClient.connect(control: control)
        let cliAsk: [String: Any] = ["task": "cli sweep", "profile": "evals", "caller": "cli"]
        let cliObj = try client.call(method: "POST", path: "/api/keys/demo/grants", body: cliAsk, expect: 201)
        XCTAssertEqual(cliObj["profile"] as? String, "evals")
        XCTAssertEqual(cliObj["unattended"] as? Bool, true)
        XCTAssertEqual(cliObj["methods"] as? [String], ["GET", "POST"])
        XCTAssertEqual(cliObj["paths"] as? [String], ["/v1/messages"])
        XCTAssertEqual(cliObj["max_requests"] as? Int, 500)
        XCTAssertEqual(cliObj["max_usd"] as? Double, 2.5)

        let tightAsk: [String: Any] = ["task": "x", "profile": "evals", "minutes": 481]
        XCTAssertThrowsError(try client.call(method: "POST", path: "/api/keys/demo/grants", body: tightAsk, expect: 201)) { error in
            guard case AppError.usage(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("481"), m)
            XCTAssertTrue(m.contains("480"), m)
        }
    }

    /// `keys grants` names the profile and the unattended badge on profile-issued grants and
    /// keeps plain rows readable without them.
    func testTheGrantsTableNamesTheProfileAndTheUnattendedBadge() {
        XCTAssertEqual(
            GrantsCommand.header,
            "ID\tKEY\tHOST\tTASK\tSTATUS\tEXPIRES\tREQUESTS\tUSD\tPROFILE\tUNATTENDED"
        )
        let profiled: [String: Any] = [
            "id": "0000aaaa", "key": "demo", "host": "api.openai.com", "task": "night evals",
            "status": "active", "expires_at": "2026-10-27T00:00:00Z", "requests": 3, "usd": 0.5,
            "unpriced_calls": 0, "profile": "evals", "unattended": true,
        ]
        XCTAssertEqual(
            GrantsCommand.row(profiled),
            "0000aaaa\tdemo\tapi.openai.com\tnight evals\tactive\t2026-10-27T00:00:00Z\t3\t0.5000\tevals\tunattended"
        )
        let plain: [String: Any] = [
            "id": "0000bbbb", "key": "demo", "host": "api.openai.com", "task": "list models",
            "status": "active", "expires_at": "2026-10-27T00:00:00Z", "requests": 1, "usd": 0,
            "unpriced_calls": 1, "profile": NSNull(), "unattended": false,
        ]
        XCTAssertEqual(
            GrantsCommand.row(plain),
            "0000bbbb\tdemo\tapi.openai.com\tlist models\tactive\t2026-10-27T00:00:00Z\t1\tunpriced (1 call)\t-\t-"
        )
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

/// `keys grant` in a Terminal talks to the running site through the control file.
final class ControlClientTests: XCTestCase {
    func testCLIPathIssuesListsAndRevokesThroughTheSite() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }

        let control = ControlFile.url(beside: db.path)
        XCTAssertThrowsError(try ControlClient.connect(control: control), "no control file: clear error, no hang")
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let client = try ControlClient.connect(control: control)
        let obj = try client.call(
            method: "POST", path: "/api/keys/demo/grants",
            body: ["task": "cli", "minutes": 5, "methods": ["GET"], "paths": ["/models"], "caller": "cli"], expect: 201
        )
        let token = try XCTUnwrap(obj["token"] as? String)
        XCTAssertTrue(GrantToken.looksLikeToken(token))
        let id = try XCTUnwrap(obj["id"] as? String)
        XCTAssertEqual(try service.keyEvents(name: "demo").first?.caller, "cli")

        let lobj = try client.call(method: "GET", path: "/api/grants", expect: 200)
        XCTAssertEqual((lobj["grants"] as? [Any])?.count, 1)

        _ = try client.call(method: "DELETE", path: "/api/grants/\(id)", expect: 200)
        XCTAssertEqual(service.listGrants().count, 0)

        // An error answer comes back as the AppError it carries, read from `detail`.
        XCTAssertThrowsError(try client.call(method: "DELETE", path: "/api/grants/0badc0de", expect: 200)) { error in
            guard case AppError.notFound("0badc0de") = error else { return XCTFail("\(error)") }
            XCTAssertEqual("\(error)", "not found: 0badc0de")
        }

        // A stale token from an older launch maps to a clear error, not a hang or a crash.
        try ControlFile.write(port: server.boundPort, token: "stale", to: control)
        let stale = try ControlClient.connect(control: control)
        XCTAssertThrowsError(try stale.call(method: "POST", path: "/api/keys/demo/grants", body: ["task": "x"], expect: 201)) { error in
            guard case AppError.usage(let m) = error else { return XCTFail("expected usage error, got \(error)") }
            XCTAssertTrue(m.contains("restart the site"), m)
        }
        if case .authCancelled = AppError(wireCode: "auth_cancelled", status: 403, body: [:]) {} else { XCTFail("auth_cancelled") }
        if case .authUnavailable("sandbox") = AppError(
            wireCode: "auth_unavailable", status: 503,
            body: ["message": AppError.authUnavailable("sandbox").description, "detail": "sandbox"]
        ) {} else { XCTFail("auth_unavailable reads detail, not the prefixed message") }
    }
}
