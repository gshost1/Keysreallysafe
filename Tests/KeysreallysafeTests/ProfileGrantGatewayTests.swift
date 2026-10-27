import Foundation
import XCTest
@testable import KeysCore

/// Profile-issued grants at the gateway: the mission's named offline tests for scope
/// boundaries, denial, expiry, caps and the kill paths, all through the real in-process
/// loopback gateway (`GatewayRig` + real `URLSession` calls).
///
/// The gateway's request path is profile-blind — `GrantStore.authorize` and
/// `GatewayListener.handle` never read the profile table — so a grant issued under a
/// profile must behave at request time exactly like any other grant: the profile only
/// bounded what could be asked for at issuance. These tests prove that equivalence for
/// methods, paths (dot segments never matching, with `allowed_paths`/`suggested_paths`
/// details), key and host binding, expiry, request/USD caps (including the unpriced
/// fail-closed rule), screen lock and restart. Non-profile grants keep their own pinned
/// suite (`GrantTests`, `VercelCostCheapestTests`, `GatewayRetargetTests`) unchanged.
final class ProfileGrantGatewayTests: XCTestCase {
    /// One dashboard-style request through the real gateway, reading the JSON denial.
    private func call(
        _ gateway: GatewayListener, _ path: String, method: String = "GET",
        token: String?, header: String = "Authorization"
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)\(path)")!)
        req.httpMethod = method
        if let token {
            req.setValue(header == "Authorization" ? "Bearer \(token)" : token, forHTTPHeaderField: header)
        }
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> (Int, [String: Any]) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }

    /// A saved profile, defaults taken from the model so only the bounds under test vary.
    @discardableResult
    private func saveProfile(
        _ service: KeysService,
        name: String = "evals",
        keys: [String],
        methods: Set<String> = Grant.allMethods,
        paths: [String] = [],
        minutes: Int = 60,
        maxRequests: Int? = nil,
        maxUsd: Double? = nil,
        unattended: Bool = false
    ) throws -> Profile {
        try service.addProfile(ProfileRequest(
            name: name, keys: keys, methods: methods, paths: paths, minutes: minutes,
            maxRequests: maxRequests, maxUsd: maxUsd, unattended: unattended
        ))
    }

    /// A Vercel-shaped POST that returns a cost receipt, the provider the USD-cap tests price
    /// against (the same shape `VercelCostCheapestTests` uses).
    private func post(_ rig: GatewayRig, _ token: String, path: String = "v4/ai/language-model") -> URLRequest {
        var r = URLRequest(url: rig.url(path, key: "jev"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("anthropic/claude-haiku-5.5", forHTTPHeaderField: "ai-language-model-id")
        r.httpBody = Data(#"{"prompt":[]}"#.utf8)
        return r
    }

    /// The gateway answers the client before it records usage, so wait (boundedly) for the rows.
    private func waitForRows(_ rig: GatewayRig, _ n: Int) async throws {
        for _ in 0..<200 where try rig.db.gatewayEvents().count < n {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(try rig.db.gatewayEvents().count, n)
    }

    // MARK: VAL-SCOPE-001 — method denial

    /// A method inside the profile-issued grant's methods passes; one outside is refused 403
    /// `grant_method_not_allowed`, and the profile's methods became the grant's scope.
    func testProfileGrantMethodOutsideItsScopeIsDeniedAndInsidePasses() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        _ = try saveProfile(rig.service, keys: ["demo"], methods: ["GET"], paths: ["/models"], minutes: 60)
        let promptsBefore = rig.gate.reasons.count
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )
        XCTAssertEqual(issued.grant.methods, ["GET"], "the profile's methods are the grant's")
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore + 1, "one prompt per profile grant")

        let (inside, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(inside, 200, "a method inside the scope passes")
        let (outside, body) = try await call(rig.gateway, "/demo/v1/models", method: "POST", token: issued.token)
        XCTAssertEqual(outside, 403)
        XCTAssertEqual(body["error"] as? String, "grant_method_not_allowed")
        XCTAssertEqual(body["message"] as? String, GrantDenial.method("POST").message)
    }

    // MARK: VAL-SCOPE-002 — path denial, details, dot segments

    /// A path outside the profile-issued grant's scopes is refused 403 `grant_path_not_allowed`
    /// with `allowed_paths`/`suggested_paths` details as before; a path inside passes; and a
    /// dot-segment path never matches any scope, even an any-path grant.
    func testProfileGrantPathOutsideItsScopesIsDeniedWithAllowedAndSuggestedDetails() async throws {
        // A provider whose catalog prefix is empty, so a denied path can suggest the longer
        // scope the caller meant — the live refusal that motivated `suggested_paths`.
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("typed", provider: "typesafe")
        _ = try saveProfile(rig.service, keys: ["typed"], methods: ["GET"], paths: ["/models"], minutes: 60)
        let issued = try rig.service.issueGrant(
            name: "typed", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )

        let (inside, _) = try await call(rig.gateway, "/typed/models", token: issued.token)
        XCTAssertEqual(inside, 200, "a path inside the scope passes")
        let (outside, body) = try await call(rig.gateway, "/typed/v1/models", token: issued.token)
        XCTAssertEqual(outside, 403)
        XCTAssertEqual(body["error"] as? String, "grant_path_not_allowed")
        XCTAssertEqual(body["allowed_paths"] as? [String], ["/models"])
        XCTAssertEqual(body["suggested_paths"] as? String, "/v1/models", "the denial names the scope the caller meant")
        XCTAssertTrue((body["message"] as? String ?? "").contains("allows /models"), "\(body)")
    }

    /// A dot-segment path is refused even on a grant scoped to any path: an upstream that
    /// collapses `..` would serve a scope the grant never named.
    func testProfileGrantPathWithADotSegmentNeverMatchesAnyScope() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        _ = try saveProfile(rig.service, keys: ["demo"], methods: ["GET"], paths: [], minutes: 60)
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "any path"), profile: "evals", caller: "cli"
        )

        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(ok, 200, "an any-path grant serves an ordinary path")
        // Both spellings: a literal `..` and a percent-encoded `%2e%2e` (which URLSession
        // sends as written). An any-path grant denies only on the dot-segment rule, so a 403
        // here proves the rule fired rather than the scope.
        for path in ["/demo/v1/models/../responses", "/demo/v1/models/%2e%2e/responses"] {
            let (denied, body) = try await call(rig.gateway, path, token: issued.token)
            XCTAssertEqual(denied, 403, path)
            XCTAssertEqual(body["error"] as? String, "grant_path_not_allowed", path)
            XCTAssertEqual(body["allowed_paths"] as? [String], [], "an any-path grant still never matches a dot segment")
        }
    }

    // MARK: VAL-SCOPE-003 — key and host binding

    /// The same token against another key is refused 403 `grant_key_mismatch`; editing the
    /// key's provider/host is the target-change kill path: the grant is revoked and the key
    /// is no longer served through the gateway.
    func testProfileGrantTokenIsBoundToItsKeyAndAHostEditKillsIt() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        try rig.key("other", provider: "openai", secret: fixtureSecret + "2")
        _ = try saveProfile(rig.service, keys: ["demo"], methods: ["GET"], paths: ["/models"], minutes: 60)
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )
        let (served, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(served, 200)

        let (mismatch, mismatchBody) = try await call(rig.gateway, "/other/v1/models", token: issued.token)
        XCTAssertEqual(mismatch, 403)
        XCTAssertEqual(mismatchBody["error"] as? String, "grant_key_mismatch")

        // The target-change kill path: the grant is revoked, and the retarget drops the key's
        // unlocked secret, so the gateway no longer serves it at all (same shape as gateway-off).
        _ = try rig.service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:1", updateHost: true)
        XCTAssertEqual(
            rig.service.listGrants(includeInactive: true).first { $0.id == issued.grant.id }?.revokeReason,
            "target_changed"
        )
        let (dead, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(dead, 404, "the retarget turned the key's gateway off")

        // The code a host mismatch maps to, pinned: `grant_target_changed`.
        XCTAssertEqual(GrantDenial.targetChanged.code, "grant_target_changed")
        let bound = rig.service.grants.issue(
            key: "demo", provider: "openai", host: "host-a",
            request: try GrantRequest(task: "t").validated(), profile: "evals"
        )
        XCTAssertEqual(
            rig.service.grants.authorize(
                token: bound.token, key: "demo", host: "host-b", method: "GET",
                rest: "v1/models", providerPrefix: "/v1"
            ),
            .failure(.targetChanged)
        )
    }

    // MARK: VAL-SCOPE-004 — expiry and the minutes ceiling

    /// The profile's minutes become the grant's default lifetime; an ask above the ceiling is
    /// refused before any prompt; and a profile-issued grant past its expiry is refused 403
    /// `grant_expired` through the real gateway.
    func testProfileGrantPastExpiryIsDeniedAndMinutesAboveTheCeilingAreRefusedBeforeThePrompt() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        _ = try saveProfile(rig.service, keys: ["demo"], methods: ["GET"], paths: ["/models"], minutes: 1)

        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )
        XCTAssertEqual(
            Int(issued.grant.expiresAt.timeIntervalSince(issued.grant.createdAt) / 60), 1,
            "the profile's minutes are the grant's default expiry"
        )

        let promptsBefore = rig.gate.reasons.count
        XCTAssertThrowsError(try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "too long", minutes: 2),
            profile: "evals", specified: GrantSpecified(minutes: true), caller: "cli"
        )) { error in
            XCTAssertEqual(error as? ProfileError, .minutesOver(requested: 2, profile: "evals", ceiling: 1))
        }
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "the refused ask consumed no prompt")

        // The store's clock is the gateway's clock (`authorize` defaults to `Date()`), so a
        // profile grant issued into it with a past `now` is a grant that has already expired —
        // the one way to reach the gateway's expiry check without waiting a minute.
        let past = rig.service.grants.issue(
            key: "demo", provider: "openai", host: "127.0.0.1:\(rig.stub.boundPort)",
            request: try GrantRequest(task: "old", minutes: 1, methods: ["GET"], paths: ["/models"]).validated(),
            profile: "evals", unattended: false, now: Date().addingTimeInterval(-120)
        )
        let (expired, body) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(expired, 403)
        XCTAssertEqual(body["error"] as? String, "grant_expired")
    }

    // MARK: VAL-SCOPE-005 — caps and the unpriced fail-closed rule

    /// A profile-issued grant with a request cap refuses further calls 429 `grant_request_limit`.
    func testProfileGrantRequestCapRefusesFurtherCalls() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        _ = try saveProfile(
            rig.service, keys: ["demo"], methods: ["GET"], paths: ["/models"],
            minutes: 60, maxRequests: 2, unattended: true
        )
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )
        XCTAssertEqual(issued.grant.maxRequests, 2, "the profile's cap is the grant's")
        XCTAssertEqual(issued.grant.unattended, true)

        let (first, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(first, 200)
        let (second, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(second, 200)
        let (limited, body) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(limited, 429)
        XCTAssertEqual(body["error"] as? String, "grant_request_limit")
    }

    /// A profile-issued grant with a USD cap refuses further calls 429 `grant_usd_limit` once
    /// the priced spend reaches it.
    func testProfileGrantUsdCapRefusesFurtherCalls() async throws {
        let rig = try GatewayRig { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(
                #"{"content":[],"usage":{"inputTokens":{"total":100},"outputTokens":{"total":10}},"providerMetadata":{"gateway":{"cost":"0.6"}}}"#.utf8
            ))
        }
        defer { rig.stop() }
        try rig.key("jev", provider: "vercel-ai-gateway", secret: "synthetic-vck")
        _ = try saveProfile(
            rig.service, name: "paid", keys: ["jev"], methods: ["POST"], paths: ["/v4/ai"],
            minutes: 60, maxUsd: 1, unattended: true
        )
        let issued = try rig.service.issueGrant(
            name: "jev", request: GrantRequest(task: "bench"), profile: "paid", caller: "cli"
        )
        XCTAssertEqual(issued.grant.maxUsd, 1)

        let (first, _) = try await send(post(rig, issued.token))
        XCTAssertEqual(first, 200)
        try await waitForRows(rig, 1)
        let (second, _) = try await send(post(rig, issued.token))
        XCTAssertEqual(second, 200)
        try await waitForRows(rig, 2)
        let (limited, body) = try await send(post(rig, issued.token))
        XCTAssertEqual(limited, 429)
        XCTAssertEqual(body["error"] as? String, "grant_usd_limit")
    }

    /// A billable call that returns no price on a USD-capped profile grant refuses the next
    /// call 429 `grant_usd_unpriced` — the fail-closed rule is inherited unchanged.
    func testProfileGrantUnpricedBillableCallFailsClosed() async throws {
        let rig = try GatewayRig { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"content":[]}"#.utf8))
        }
        defer { rig.stop() }
        try rig.key("jev", provider: "vercel-ai-gateway", secret: "synthetic-vck")
        _ = try saveProfile(
            rig.service, name: "paid", keys: ["jev"], methods: ["POST", "GET"], paths: ["/v4/ai"],
            minutes: 60, maxUsd: 5, unattended: true
        )
        let issued = try rig.service.issueGrant(
            name: "jev", request: GrantRequest(task: "bench"), profile: "paid", caller: "cli"
        )

        // A read is not billable, so it does not end the grant.
        var read = URLRequest(url: rig.url("v4/ai/config", key: "jev"))
        read.setValue("Bearer \(issued.token)", forHTTPHeaderField: "Authorization")
        let (readStatus, _) = try await send(read)
        XCTAssertEqual(readStatus, 200)
        try await waitForRows(rig, 1)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).unpricedCalls, 0)

        let (first, _) = try await send(post(rig, issued.token))
        XCTAssertEqual(first, 200)
        try await waitForRows(rig, 2)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).unpricedCalls, 1)

        let (unpriced, body) = try await send(post(rig, issued.token))
        XCTAssertEqual(unpriced, 429)
        XCTAssertEqual(body["error"] as? String, "grant_usd_unpriced")
    }

    // MARK: VAL-SCOPE-006 — screen lock and restart

    /// The screen-lock notification revokes profile-issued grants (reason `screen_lock`, token
    /// dead, further calls 403 `grant_revoked`); a fresh service (restart) does not know the
    /// token (401 `grant_invalid`) — memory-only storage is unchanged.
    func testScreenLockAndRestartStillKillProfileGrants() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        _ = try saveProfile(rig.service, keys: ["demo"], methods: ["GET"], paths: ["/models"], minutes: 60)
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "list models"), profile: "evals", caller: "cli"
        )
        let (served, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(served, 200)

        rig.service.handleScreenLock()
        let (revoked, body) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(revoked, 403)
        XCTAssertEqual(body["error"] as? String, "grant_revoked")
        XCTAssertEqual(
            rig.service.listGrants(includeInactive: true).first { $0.id == issued.grant.id }?.revokeReason,
            "screen_lock"
        )

        // A restart is a fresh process with an empty grant table: the same token is unknown.
        let restarted = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { restarted.stop() }
        try restarted.key("demo", provider: "openai")
        let (unknown, unknownBody) = try await call(restarted.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(unknown, 401)
        XCTAssertEqual(unknownBody["error"] as? String, "grant_invalid")
    }
}
