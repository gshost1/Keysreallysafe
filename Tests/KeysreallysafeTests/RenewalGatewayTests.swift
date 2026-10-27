import Foundation
import XCTest
@testable import KeysCore

/// Renewal through the real loopback gateway (`GatewayRig` + real `URLSession` calls): the
/// request path is never touched by renewal — a renewed grant is the same row with a later
/// `expiresAt` — so every denial class keeps its exact behavior, every kill path keeps its
/// exact meaning, and the token issued at grant time is the token that passes after renewal.
final class RenewalGatewayTests: XCTestCase {
    /// One dashboard-style request through the real gateway, reading the JSON denial.
    private func call(
        _ gateway: GatewayListener, _ path: String, method: String = "GET",
        token: String?
    ) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)\(path)")!)
        req.httpMethod = method
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }

    /// A grant issued straight into the store with a past clock: the store's clock is the
    /// gateway's clock, so this reaches the gateway's expiry check without waiting a minute
    /// (the established back-dating pattern).
    @discardableResult
    private func backDatedGrant(
        _ rig: GatewayRig, key: String = "demo", task: String = "old", minutes: Int = 10,
        methods: Set<String> = ["GET"], paths: [String] = ["/models"], maxRequests: Int? = nil
    ) throws -> (grant: Grant, token: String) {
        try rig.service.grants.issue(
            key: key, provider: "openai", host: "127.0.0.1:\(rig.stub.boundPort)",
            request: try GrantRequest(
                task: task, minutes: minutes, methods: methods, paths: paths, maxRequests: maxRequests
            ).validated(),
            now: Date().addingTimeInterval(-3600)
        )
    }

    /// An expired grant denies 403 `grant_expired`; after renewal the SAME token passes, with
    /// exactly one prompt spent on the renewal.
    func testAnExpiredGrantRenewsAndTheSameTokenPassesTheGateway() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let past = try backDatedGrant(rig)

        let (expired, expiredBody) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(expired, 403)
        XCTAssertEqual(expiredBody["error"] as? String, "grant_expired")

        let promptsBefore = rig.gate.reasons.count
        let renewed = try rig.service.renewGrant(id: past.grant.id, caller: "cli")
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore + 1, "exactly one prompt per renewal")
        XCTAssertEqual(renewed.id, past.grant.id)
        XCTAssertEqual(renewed.renewals, 1)
        XCTAssertGreaterThan(renewed.expiresAt, Date())

        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(ok, 200, "the token issued at grant time passes after renewal")
    }

    /// Method, path, key and host denials are byte-identical after renewal: renewal moved
    /// the clock and nothing else.
    func testEveryDenialClassIsUnchangedAfterRenewal() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        try rig.key("other", provider: "openai", secret: fixtureSecret + "2")
        let past = try backDatedGrant(rig)
        let (expired, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(expired, 403)

        _ = try rig.service.renewGrant(id: past.grant.id, caller: "cli")
        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(ok, 200)

        let (method, methodBody) = try await call(rig.gateway, "/demo/v1/models", method: "POST", token: past.token)
        XCTAssertEqual(method, 403)
        XCTAssertEqual(methodBody["error"] as? String, "grant_method_not_allowed")
        XCTAssertEqual(methodBody["message"] as? String, GrantDenial.method("POST").message)

        let (path, pathBody) = try await call(rig.gateway, "/demo/v1/chat/completions", token: past.token)
        XCTAssertEqual(path, 403)
        XCTAssertEqual(pathBody["error"] as? String, "grant_path_not_allowed")
        XCTAssertEqual(pathBody["allowed_paths"] as? [String], ["/models"], "\(pathBody)")

        let (mismatch, mismatchBody) = try await call(rig.gateway, "/other/v1/models", token: past.token)
        XCTAssertEqual(mismatch, 403)
        XCTAssertEqual(mismatchBody["error"] as? String, "grant_key_mismatch")

        XCTAssertEqual(
            rig.service.grants.authorize(
                token: past.token, key: "demo", host: "elsewhere", method: "GET",
                rest: "v1/models", providerPrefix: "/v1"
            ),
            .failure(.targetChanged),
            "a host mismatch still fails closed after renewal"
        )
    }

    /// A request-capped grant admits a fresh window of requests after renewal, then refuses
    /// at the cap again — the counter reset is real and the cap is unchanged.
    func testARequestCapResetsOnRenewalAndReEnforcesAtTheCap() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let past = try backDatedGrant(rig, maxRequests: 2)
        // Expired first, so the cap can only be reached after renewal.
        let (expired, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(expired, 403)

        _ = try rig.service.renewGrant(id: past.grant.id, caller: "cli")
        for i in 1...2 {
            let (status, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
            XCTAssertEqual(status, 200, "call \(i) of the fresh window")
        }
        let (limited, limitedBody) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(limited, 429)
        XCTAssertEqual(limitedBody["error"] as? String, "grant_request_limit")

        // Renewing again resets the counter again, and the cap re-enforces again.
        _ = try rig.service.renewGrant(id: past.grant.id, caller: "cli")
        let (first, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(first, 200, "the second renewal opened another fresh window")
        XCTAssertEqual(rig.service.grants.grant(id: past.grant.id)?.renewals, 2)
    }

    /// The new window's end is enforced: renew with the clock far enough back that the
    /// original window has already run out again, and the token is 403 `grant_expired` once
    /// more. (The `now:` seam stands in for waiting out the window.)
    func testARenewedGrantExpiresAgainAtTheEndOfItsNewWindow() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let past = try backDatedGrant(rig, minutes: 1)

        // Renewal 30 seconds "ago" with a 1-minute window: 30 seconds of new window left.
        let renewed = try rig.service.renewGrant(id: past.grant.id, caller: "cli", now: Date().addingTimeInterval(-30))
        XCTAssertEqual(renewed.expiresAt.timeIntervalSinceNow, 30, accuracy: 5)
        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(ok, 200, "inside the new window the token passes")

        // Renewal 2 minutes "ago" with the same 1-minute window: the new window is already over.
        let expiredAgain = try rig.service.renewGrant(id: past.grant.id, caller: "cli", now: Date().addingTimeInterval(-120))
        XCTAssertLessThan(expiredAgain.expiresAt, Date())
        let (dead, body) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
        XCTAssertEqual(dead, 403)
        XCTAssertEqual(body["error"] as? String, "grant_expired")
    }

    /// A revoked grant refuses renewal `renew_revoked` and its token stays denied
    /// `grant_revoked`: a kill is a kill.
    func testARevokedGrantRefusesRenewalAndStaysDenied() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]), caller: "cli"
        )
        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(ok, 200)

        try rig.service.revokeGrant(id: issued.grant.id)
        let promptsBefore = rig.gate.reasons.count
        XCTAssertThrowsError(try rig.service.renewGrant(id: issued.grant.id, caller: "cli")) { error in
            XCTAssertEqual(error as? RenewalError, .revoked(id: issued.grant.id, reason: "revoked"))
            XCTAssertEqual((error as? RenewalError)?.code, "renew_revoked")
        }
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "the refusal consumed no prompt")
        let (dead, body) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(dead, 403)
        XCTAssertEqual(body["error"] as? String, "grant_revoked")
    }

    /// Screen lock revokes with reason `screen_lock`; renewal is then refused `renew_revoked`
    /// naming that reason, and the token is 403 `grant_revoked` — an unattended-style job
    /// still dies on lock.
    func testAScreenLockedGrantIsUnrenewableAndStaysDenied() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]), caller: "cli"
        )
        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(ok, 200)

        rig.service.handleScreenLock()
        let promptsBefore = rig.gate.reasons.count
        XCTAssertThrowsError(try rig.service.renewGrant(id: issued.grant.id, caller: "cli")) { error in
            XCTAssertEqual(error as? RenewalError, .revoked(id: issued.grant.id, reason: "screen_lock"))
        }
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "the refusal consumed no prompt")
        let (dead, body) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(dead, 403)
        XCTAssertEqual(body["error"] as? String, "grant_revoked")
    }

    /// The kill switches reach a grant that had already expired when they fired. It kept its
    /// hash so it could be renewed, so a switch that skipped it would let a later renewal
    /// revive the old token across the lock, the gateway going off or the key being replaced.
    func testAKillSwitchAlsoKillsAnExpiredGrantSoRenewalCannotReviveIt() async throws {
        let kills: [(String, (GatewayRig) throws -> Void)] = [
            ("screen_lock", { $0.service.handleScreenLock() }),
            ("gateway_off", { _ = try $0.service.setGateway(name: "demo", enabled: false, host: nil) }),
            ("key_deleted", { rig in
                try rig.service.remove(name: "demo")
                try rig.key("demo", provider: "openai")
            }),
        ]
        for (reason, kill) in kills {
            let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
            defer { rig.stop() }
            try rig.key("demo", provider: "openai")
            let past = try backDatedGrant(rig)
            XCTAssertTrue(past.grant.isExpired(at: Date()))

            try kill(rig)
            let promptsBefore = rig.gate.reasons.count
            XCTAssertThrowsError(try rig.service.renewGrant(id: past.grant.id, caller: "cli"), reason) { error in
                XCTAssertEqual(error as? RenewalError, .revoked(id: past.grant.id, reason: reason))
            }
            XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "\(reason): the refusal consumed no prompt")
            XCTAssertTrue(
                try rig.service.keyEvents(name: "demo").filter { $0.action == "grant_revoke" }.isEmpty,
                "\(reason): an already-expired grant adds no revoke row to the audit log"
            )
            let (dead, body) = try await call(rig.gateway, "/demo/v1/models", token: past.token)
            if reason == "gateway_off" {
                XCTAssertNotEqual(dead, 200, "\(reason): the old token stays denied")
            } else {
                XCTAssertEqual(dead, 403, reason)
                XCTAssertEqual(body["error"] as? String, "grant_revoked", reason)
            }
        }
    }

    /// A restart is a fresh process with an empty grant table: the old token is 401
    /// `grant_invalid`, and renewing the old id is `renew_not_found`.
    func testARestartForgetsTheGrantAndRenewalIsNotFound() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let issued = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]), caller: "cli"
        )
        let (ok, _) = try await call(rig.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(ok, 200)

        let restarted = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { restarted.stop() }
        try restarted.key("demo", provider: "openai")
        let (unknown, unknownBody) = try await call(restarted.gateway, "/demo/v1/models", token: issued.token)
        XCTAssertEqual(unknown, 401)
        XCTAssertEqual(unknownBody["error"] as? String, "grant_invalid")

        let promptsBefore = restarted.gate.reasons.count
        XCTAssertThrowsError(try restarted.service.renewGrant(id: issued.grant.id, caller: "cli")) { error in
            XCTAssertEqual(error as? RenewalError, .notFound(issued.grant.id))
            XCTAssertEqual((error as? RenewalError)?.code, "renew_not_found")
        }
        XCTAssertEqual(restarted.gate.reasons.count, promptsBefore, "the refusal consumed no prompt")
    }
}
