import XCTest
@testable import KeysCore

/// Grant renewal: an active or expired grant is re-approved in place — same id, token, key,
/// host, scope and caps — for another window of its ORIGINAL lifetime, behind exactly one
/// presence prompt that names the full effective scope. Every refusal precedes that prompt
/// (a refused renewal consumes no Touch ID), a denied prompt renews nothing, and a revoked
/// grant is never renewable: `revoke` deletes the token hash, so a hashless row can never
/// authorize again and must never be revived. Nothing auto-renews; nothing widens.
final class RenewalTests: XCTestCase {
    /// A refusal's whole contract: its own named error, its wire code, and a presence gate
    /// that never saw the ask.
    private func assertRenewalRefusal(
        _ expected: RenewalError,
        gate: RecordingPresenceGate,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        let promptsBefore = gate.reasons.count
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let e = error as? RenewalError else {
                return XCTFail("expected \(expected), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(e, expected, "\(e)", file: file, line: line)
            XCTAssertEqual(e.code, expected.code, "the wire code is part of the refusal", file: file, line: line)
        }
        XCTAssertEqual(gate.reasons.count, promptsBefore, "a refused renewal consumed no prompt", file: file, line: line)
    }

    /// A service with one vault key and a recording gate, the base for the service-level tests.
    private func renewableService() throws -> (KeysService, RecordingPresenceGate, CatalogDB, URL) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        return (service, gate, db, dir)
    }

    // MARK: - Store semantics

    /// Renewal moves only the clock and the counters: id, key, provider, host, task, methods,
    /// paths, caps, createdAt and the token hash are byte-identical, expiry is
    /// `now + windowMinutes`, usage counters reset, and the renewals count climbs. A renew of
    /// a renew opens the ORIGINAL window again, never a compounded one.
    func testStoreRenewKeepsIdentityAndScopeAndOpensAFreshIdenticalWindow() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let issued = store.issue(
            key: "k", provider: "openai", host: "h",
            request: try GrantRequest(
                task: "x", minutes: 10, methods: ["GET"], paths: ["/models"],
                maxRequests: 5, maxUsd: 1
            ).validated(),
            now: t0
        )
        XCTAssertEqual(issued.grant.windowMinutes, 10, "issue records the window it opened")
        XCTAssertEqual(issued.grant.renewals, 0)
        XCTAssertNil(issued.grant.renewedAt)
        XCTAssertEqual(issued.grant.jsonObject()["window_minutes"] as? Int, 10)
        XCTAssertEqual(issued.grant.jsonObject()["renewals"] as? Int, 0)
        XCTAssertTrue(issued.grant.jsonObject()["renewed_at"] is NSNull)

        // Burn the counters so the reset is observable.
        XCTAssertNoThrow(try store.authorize(
            token: issued.token, key: "k", host: "h", method: "GET",
            rest: "models", providerPrefix: "/v1", now: t0
        ).get())
        store.charge(id: issued.grant.id, usd: 0.25)
        store.charge(id: issued.grant.id, usd: nil)
        XCTAssertEqual(store.grant(id: issued.grant.id)?.requests, 1)
        XCTAssertEqual(store.grant(id: issued.grant.id)?.unpricedCalls, 1)

        // Past the first window: expired, but the row and its hash are still there.
        let t1 = t0.addingTimeInterval(3600)
        let renewed = try store.renew(id: issued.grant.id, now: t1)
        XCTAssertEqual(renewed.id, issued.grant.id)
        XCTAssertEqual(renewed.key, issued.grant.key)
        XCTAssertEqual(renewed.provider, issued.grant.provider)
        XCTAssertEqual(renewed.host, issued.grant.host)
        XCTAssertEqual(renewed.task, issued.grant.task)
        XCTAssertEqual(renewed.methods, issued.grant.methods)
        XCTAssertEqual(renewed.paths, issued.grant.paths)
        XCTAssertEqual(renewed.maxRequests, issued.grant.maxRequests)
        XCTAssertEqual(renewed.maxUsd, issued.grant.maxUsd)
        XCTAssertEqual(renewed.createdAt, issued.grant.createdAt)
        XCTAssertEqual(renewed.expiresAt, t1.addingTimeInterval(10 * 60), "expiry is now + the original window")
        XCTAssertEqual(renewed.requests, 0)
        XCTAssertEqual(renewed.usd, 0)
        XCTAssertEqual(renewed.unpricedCalls, 0)
        XCTAssertNil(renewed.lastUsedAt)
        XCTAssertEqual(renewed.renewals, 1)
        XCTAssertEqual(renewed.renewedAt, t1)
        XCTAssertEqual(renewed.jsonObject()["renewed_at"] as? String, UTC.iso(t1))

        // The SAME token authorizes again: the stored hash never changed.
        XCTAssertNoThrow(try store.authorize(
            token: issued.token, key: "k", host: "h", method: "GET",
            rest: "models", providerPrefix: "/v1", now: t1
        ).get(), "the token survives renewal; only the clock moved")

        // A renew of a renew opens the ORIGINAL window and counts again.
        let t2 = t1.addingTimeInterval(120)
        let again = try store.renew(id: issued.grant.id, now: t2)
        XCTAssertEqual(again.expiresAt, t2.addingTimeInterval(10 * 60), "the original window, not a compounded one")
        XCTAssertEqual(again.renewals, 2)
        XCTAssertEqual(again.renewedAt, t2)
        XCTAssertEqual(again.createdAt, issued.grant.createdAt)
    }

    /// Unknown, revoked and pruned rows all refuse. Revoke deletes the token hash, so a
    /// revoked row is hashless and must never be revived; expiry keeps the hash, which is
    /// what makes an expired grant renewable at all — until prune drops the row a day later.
    func testStoreRenewRefusesUnknownRevokedAndPrunedRowsAndNeverRevivesAHashlessRow() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)

        XCTAssertThrowsError(try store.renew(id: "deadbeef", now: t0)) { error in
            XCTAssertEqual(error as? RenewalError, .notFound("deadbeef"))
            XCTAssertEqual((error as? RenewalError)?.code, "renew_not_found")
        }

        let revoked = store.issue(
            key: "k", provider: "openai", host: "h",
            request: try GrantRequest(task: "x", minutes: 10).validated(),
            now: t0
        )
        _ = store.revoke(id: revoked.grant.id, reason: "screen_lock", now: t0)
        XCTAssertThrowsError(try store.renew(id: revoked.grant.id, now: t0.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? RenewalError, .revoked(id: revoked.grant.id, reason: "screen_lock"))
            XCTAssertEqual((error as? RenewalError)?.code, "renew_revoked")
        }
        // The refusal revived nothing: the token stays dead.
        XCTAssertEqual(
            store.authorize(
                token: revoked.token, key: "k", host: "h", method: "GET",
                rest: "", providerPrefix: "", now: t0.addingTimeInterval(60)
            ),
            .failure(.revoked)
        )
        XCTAssertEqual(store.grant(id: revoked.grant.id)?.renewals, 0)
        XCTAssertTrue(store.grant(id: revoked.grant.id)?.isRevoked ?? false)

        // An expired row pruned after its day is gone entirely: renewal is a plain not-found.
        let old = store.issue(
            key: "k", provider: "openai", host: "h",
            request: try GrantRequest(task: "old", minutes: 1).validated(),
            now: t0
        )
        store.prune(olderThan: 0, now: t0.addingTimeInterval(2 * 3600))
        XCTAssertThrowsError(try store.renew(id: old.grant.id, now: t0.addingTimeInterval(2 * 3600))) { error in
            XCTAssertEqual(error as? RenewalError, .notFound(old.grant.id))
        }
    }

    // MARK: - Service happy path and the pinned prompt

    /// One renewal costs exactly one prompt, pinned byte-for-byte for a plain grant, a capped
    /// grant and a profile+unattended grant; the returned grant keeps its whole identity,
    /// opens a fresh identical window, resets its counters, and audits `grant_renew` with the
    /// id, task, new expiry, host, scope, caps and renewal number — never the token.
    func testRenewalKeepsIdentityAndScopeBehindExactlyOnePromptAndAuditsIt() throws {
        let (service, gate, _, dir) = try renewableService()
        let issued = try service.issueGrant(
            name: "demo",
            request: GrantRequest(task: "list models", minutes: 15, methods: ["GET"], paths: ["/models"]),
            caller: "cli"
        )
        var prompts = gate.reasons.count

        // Burn the counters so the reset is observable at service level too.
        XCTAssertNoThrow(try service.grants.authorize(
            token: issued.token, key: "demo", host: "api.openai.com", method: "GET",
            rest: "models", providerPrefix: "/v1"
        ).get())

        let t1 = Date()
        let renewed = try service.renewGrant(id: issued.grant.id, caller: "cli", now: t1)
        XCTAssertEqual(gate.reasons.count, prompts + 1, "exactly one prompt per renewal")
        XCTAssertEqual(
            gate.reasons.last,
            "renew \"list models\" the key demo for OpenAI at api.openai.com, 15 min, GET, /models"
        )
        prompts = gate.reasons.count

        XCTAssertEqual(renewed.id, issued.grant.id)
        XCTAssertEqual(renewed.key, "demo")
        XCTAssertEqual(renewed.provider, "openai")
        XCTAssertEqual(renewed.host, "api.openai.com")
        XCTAssertEqual(renewed.task, "list models")
        XCTAssertEqual(renewed.methods, ["GET"])
        XCTAssertEqual(renewed.paths, ["/models"])
        XCTAssertEqual(renewed.createdAt, issued.grant.createdAt)
        XCTAssertEqual(renewed.expiresAt, t1.addingTimeInterval(15 * 60))
        XCTAssertEqual(renewed.requests, 0)
        XCTAssertEqual(renewed.usd, 0)
        XCTAssertEqual(renewed.unpricedCalls, 0)
        XCTAssertNil(renewed.lastUsedAt)
        XCTAssertEqual(renewed.renewals, 1)
        XCTAssertEqual(renewed.renewedAt, t1)
        XCTAssertNil(renewed.profile)
        XCTAssertFalse(renewed.unattended)
        XCTAssertEqual(renewed.jsonObject()["window_minutes"] as? Int, 15)
        XCTAssertEqual(renewed.jsonObject()["renewals"] as? Int, 1)
        XCTAssertEqual(renewed.jsonObject()["renewed_at"] as? String, UTC.iso(t1))
        XCTAssertNil(renewed.jsonObject()["token"], "the renew response never carries a token")

        // A capped grant: the prompt names both caps in the issuance formatting.
        let capped = try service.issueGrant(
            name: "demo",
            request: GrantRequest(
                task: "bench", minutes: 120, methods: ["POST"],
                paths: ["/chat/completions"], maxRequests: 500, maxUsd: 2
            ),
            caller: "cli"
        )
        _ = try service.renewGrant(id: capped.grant.id, caller: "cli")
        XCTAssertEqual(gate.reasons.count, prompts + 2, "one issuance prompt and one renewal prompt")
        XCTAssertEqual(
            gate.reasons.last,
            "renew \"bench\" the key demo for OpenAI at api.openai.com, 2 h, POST, /chat/completions, max 500 req, max $2.00"
        )
        prompts = gate.reasons.count

        // A profile+unattended grant: the prompt names the labels after the caps.
        _ = try service.addProfile(ProfileRequest(
            name: "evals", keys: ["demo"], methods: ["GET", "POST"], paths: ["/v1/messages"],
            minutes: 480, maxRequests: 500, maxUsd: 2.5, unattended: true
        ))
        let profiled = try service.issueGrant(
            name: "demo", request: GrantRequest(task: "night evals"), profile: "evals", caller: "cli"
        )
        let profiledRenewal = try service.renewGrant(id: profiled.grant.id, caller: "cli")
        XCTAssertEqual(gate.reasons.count, prompts + 2)
        XCTAssertEqual(
            gate.reasons.last,
            "renew \"night evals\" the key demo for OpenAI at api.openai.com, 8 h, GET,POST, /v1/messages, max 500 req, max $2.50, unattended, profile evals"
        )
        XCTAssertEqual(profiledRenewal.profile, "evals")
        XCTAssertTrue(profiledRenewal.unattended)

        // The audit rows name the grant and the renewal number, never the token.
        let events = try service.keyEvents(name: "demo").filter { $0.action == "grant_renew" }
        XCTAssertEqual(events.count, 3)
        let detail = try XCTUnwrap(events.first { ($0.detail ?? "").contains(issued.grant.id) }?.detail)
        XCTAssertTrue(detail.contains(issued.grant.id), detail)
        XCTAssertTrue(detail.contains("list models"), detail)
        XCTAssertTrue(detail.contains("until \(UTC.iso(t1.addingTimeInterval(15 * 60)))"), detail)
        XCTAssertTrue(detail.contains("api.openai.com"), detail)
        XCTAssertTrue(detail.contains("GET"), detail)
        XCTAssertTrue(detail.contains("/models"), detail)
        XCTAssertTrue(detail.contains("renewal 1"), detail)
        let cappedDetail = try XCTUnwrap(events.first { ($0.detail ?? "").contains(capped.grant.id) }?.detail)
        XCTAssertTrue(cappedDetail.contains("max 500 req"), cappedDetail)
        XCTAssertTrue(cappedDetail.contains("max $2.00"), cappedDetail)
        let profiledDetail = try XCTUnwrap(events.first { ($0.detail ?? "").contains(profiled.grant.id) }?.detail)
        XCTAssertTrue(profiledDetail.contains("profile evals"), profiledDetail)
        XCTAssertTrue(profiledDetail.contains("unattended"), profiledDetail)
        for e in events {
            XCTAssertFalse((e.detail ?? "").contains(issued.token), "audit keeps the id, never the token")
            XCTAssertFalse((e.detail ?? "").contains(fixtureSecret))
        }
        assertNoSentinel(fixtureSecret, in: dir)
    }

    /// An expired-but-present grant renews at service level exactly like an active one.
    func testAnExpiredButPresentGrantRenews() throws {
        let (service, gate, _, _) = try renewableService()
        let past = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "old", minutes: 10, methods: ["GET"]).validated(),
            now: Date().addingTimeInterval(-3600)
        )
        XCTAssertTrue(past.grant.isExpired(at: Date()))
        let t1 = Date()
        let renewed = try service.renewGrant(id: past.grant.id, caller: "cli", now: t1)
        XCTAssertEqual(renewed.expiresAt, t1.addingTimeInterval(10 * 60))
        XCTAssertFalse(renewed.isExpired(at: t1))
        XCTAssertEqual(renewed.renewals, 1)
        XCTAssertEqual(gate.reasons.count, 1, "an expired grant still costs exactly one prompt")
        XCTAssertEqual(
            gate.reasons.last,
            "renew \"old\" the key demo for OpenAI at api.openai.com, 10 min, GET, any path"
        )
    }

    // MARK: - Refusals precede the prompt

    /// Every refused renewal names its error and consumes no prompt: unknown id, revoked
    /// (naming the stored revoke reason), key deleted, and host changed behind the service's
    /// back. `gate.reasons` stays literally empty through the whole matrix.
    func testEveryRenewalRefusalPrecedesThePromptWithItsNamedError() throws {
        let (service, gate, db, _) = try renewableService()

        assertRenewalRefusal(.notFound("deadbeef"), gate: gate) {
            try service.renewGrant(id: "deadbeef")
        }

        // A revoked grant (issued straight into the store, so no prompt has happened yet).
        let revoked = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x").validated()
        )
        _ = try service.revokeGrant(id: revoked.grant.id)
        assertRenewalRefusal(.revoked(id: revoked.grant.id, reason: "revoked"), gate: gate) {
            try service.renewGrant(id: revoked.grant.id)
        }

        // The host moved behind the service's back: the kill path that would have revoked
        // first was bypassed, and renewal still fails closed as target-changed.
        let moved = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x").validated()
        )
        _ = try db.updateGatewayHost(name: "demo", host: "127.0.0.1:9")
        assertRenewalRefusal(.targetChanged, gate: gate) {
            try service.renewGrant(id: moved.grant.id)
        }

        // The key row is gone entirely.
        let orphaned = service.grants.issue(
            key: "demo", provider: "openai", host: "127.0.0.1:9",
            request: try GrantRequest(task: "x").validated()
        )
        try db.deleteCatalog(name: "demo")
        assertRenewalRefusal(.targetChanged, gate: gate) {
            try service.renewGrant(id: orphaned.grant.id)
        }

        XCTAssertEqual(gate.reasons, [], "through the whole matrix, no prompt was consumed")
    }

    /// The refusal messages point at `keys grant`, the only way to different bounds.
    func testRenewalRefusalMessagesPointAtKeysGrant() {
        XCTAssertTrue(RenewalError.notFound("deadbeef").message.contains("keys grant"))
        XCTAssertTrue(RenewalError.revoked(id: "a1b2c3d4", reason: "screen_lock").message.contains("screen_lock"))
        XCTAssertTrue(RenewalError.revoked(id: "a1b2c3d4", reason: "screen_lock").message.contains("keys grant"))
        XCTAssertTrue(RenewalError.targetChanged.message.contains("keys grant"))
        XCTAssertTrue(RenewalError.scopeImmutable.message.contains("keys grant"))
        XCTAssertEqual(RenewalError.notFound("x").status, 404)
        XCTAssertEqual(RenewalError.revoked(id: "x", reason: "revoked").status, 409)
        XCTAssertEqual(RenewalError.targetChanged.status, 409)
        XCTAssertEqual(RenewalError.scopeImmutable.status, 400)
        XCTAssertEqual(RenewalError.targetChanged.code, "renew_target_changed")
        XCTAssertEqual(RenewalError.scopeImmutable.code, "renew_scope_immutable")
    }

    // MARK: - A denied prompt renews nothing

    /// With the gate throwing (as a denied Touch ID does), the grant stays byte-identical —
    /// still expired if it was — and no `grant_renew` audit row is written.
    func testADeniedPromptRenewsNothingAndAuditsNothing() throws {
        let (db, dir) = try makeDB()
        let gate = RecordingPresenceGate(error: AppError.authCancelled)
        let (service, _) = makeGatedService(db: db, gate: gate)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let past = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "old", minutes: 10).validated(),
            now: Date().addingTimeInterval(-3600)
        )

        XCTAssertThrowsError(try service.renewGrant(id: past.grant.id)) { error in
            guard case AppError.authCancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(gate.reasons.count, 1, "the prompt was asked and denied, not skipped")

        let still = try XCTUnwrap(service.grants.grant(id: past.grant.id))
        XCTAssertEqual(still, past.grant, "a denied prompt changed nothing about the grant")
        XCTAssertTrue(still.isExpired(at: Date()), "still expired")
        XCTAssertEqual(still.renewals, 0)
        XCTAssertEqual(
            try service.keyEvents(name: "demo").filter { $0.action == "grant_renew" }.count, 0,
            "a denied prompt audits nothing"
        )
        assertNoSentinel(fixtureSecret, in: dir)
    }
    // MARK: - `keys renew` on the CLI

    /// `keys renew` takes the grant id and --json and nothing else: renewal has no scope
    /// knobs by design, so every scope flag fails parsing, and a missing id is a usage error
    /// before any connection is attempted.
    func testRenewCommandParsesWithHouseStyleFlags() throws {
        let renew = try XCTUnwrap(try KeysCLI.parseAsRoot(["renew", "a1b2c3d4"]) as? RenewCommand)
        XCTAssertEqual(renew.id, "a1b2c3d4")
        XCTAssertFalse(renew.json)

        let asJSON = try XCTUnwrap(try KeysCLI.parseAsRoot(["renew", "a1b2c3d4", "--json"]) as? RenewCommand)
        XCTAssertEqual(asJSON.id, "a1b2c3d4")
        XCTAssertTrue(asJSON.json)

        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["renew"]), "the id is required")
        let scopeKnobs = [
            ["--minutes", "30"], ["--task", "x"], ["--methods", "GET"], ["--paths", "/v1"],
            ["--max-requests", "5"], ["--max-usd", "2"], ["--profile", "evals"], ["--unattended"],
            ["--nonsense"],
        ]
        for flag in scopeKnobs {
            XCTAssertThrowsError(
                try KeysCLI.parseAsRoot(["renew", "a1b2c3d4"] + flag),
                "renewal has no scope knob \(flag)")
        }
    }

    /// A renew refusal over the wire reads back as its message with the house usage exit
    /// code — the same mapping the profile refusals take — so `keys renew` prints exactly
    /// what a local RenewalError would say.
    func testRenewalWireCodesSurviveTheControlClientMapping() {
        let cases: [RenewalError] = [
            .notFound("deadbeef"), .revoked(id: "a1b2c3d4", reason: "screen_lock"),
            .targetChanged, .scopeImmutable,
        ]
        for error in cases {
            let mapped = AppError(
                wireCode: error.code, status: error.status,
                body: ["error": error.code, "message": error.message])
            guard case AppError.usage(let m) = mapped else {
                XCTFail("\(error.code) mapped to \(mapped)")
                continue
            }
            XCTAssertEqual(m, error.message, "\(error.code): the wire message is what the CLI prints")
            XCTAssertEqual(mapped.exitCode, 1, "\(error.code)")
        }
    }

    /// Through the control file (the CLI's real path): renew on a live in-process site
    /// returns the renewed grant — same id, renewals 1, no token anywhere — and the refusals
    /// read back as their messages without consuming a prompt.
    func testRenewalRoundTripsThroughTheControlFile() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let client = try ControlClient.connect(control: control)
        let issued = try client.call(
            method: "POST", path: "/api/keys/demo/grants",
            body: ["task": "cli", "minutes": 5, "methods": ["GET"], "caller": "cli"], expect: 201)
        let id = try XCTUnwrap(issued["id"] as? String)
        let token = try XCTUnwrap(issued["token"] as? String)

        let renewed = try client.call(method: "POST", path: "/api/grants/\(id)/renew", body: [:], expect: 200)
        XCTAssertEqual(renewed["id"] as? String, id, "renewal is in place: same id")
        XCTAssertEqual(renewed["renewals"] as? Int, 1)
        XCTAssertNil(renewed["token"], "the renew response never carries a token")
        XCTAssertFalse(try String(decoding: JSONValue.data(renewed), as: UTF8.self).contains(token))
        XCTAssertEqual(gate.reasons.count, 2, "one prompt at issuance, one at renewal")

        // Refusals over the wire read back as their messages with the house exit code.
        XCTAssertThrowsError(try client.call(method: "POST", path: "/api/grants/deadbeef/renew", body: [:], expect: 200)) { error in
            guard case AppError.usage(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("deadbeef"), m)
            XCTAssertTrue(m.contains("keys grant"), m)
            XCTAssertEqual((error as? AppError)?.exitCode, 1)
        }
        XCTAssertThrowsError(try client.call(
            method: "POST", path: "/api/grants/\(id)/renew", body: ["minutes": 30], expect: 200)
        ) { error in
            guard case AppError.usage(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("takes no scope fields"), m)
        }
        XCTAssertEqual(gate.reasons.count, 2, "the refusals consumed no prompt")
        assertNoSentinel(fixtureSecret, in: dir)
    }
}
