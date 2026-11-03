import Foundation
import XCTest
@testable import KeysCore

/// `keys share` (docs/relay.md, "Sharing keys with another machine"): one pairing plus one
/// multi-key client token under one presence prompt, revoked together, and the env lines the
/// other machine pastes. Offline: a memory secret store, a recording presence gate, and a relay
/// "configured" through the catalog meta rows alone, so no Keychain is touched.
final class ShareTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    private let origin = URL(string: "https://keysrs-relay.me.workers.dev")!

    private func bearer(_ token: String) -> [String: String] { ["authorization": "Bearer " + token] }

    /// A gated service with two keys on different wires and a relay that reads as set up.
    private func makeService(relay: Bool = true) throws -> (KeysService, RecordingPresenceGate, CatalogDB, URL) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "claude", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "router", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        if relay {
            try db.setMeta(KeysService.relayURLMetaKey, origin.absoluteString)
            try db.setMeta(KeysService.relayURLMetaKey + "_secret_hint", "bbbb")
        }
        return (service, gate, db, dir)
    }

    // MARK: env lines

    func testEnvLinesGiveEachKeyABaseURLAndTheSDKVariablesToTheFirstOfEachWire() {
        let lines = ShareEnv.lines(
            origin: origin,
            members: [
                .init(name: "claude", api: "anthropic"), .init(name: "router", api: "openai"),
                .init(name: "deep-seek", api: "openai"), .init(name: "gem", api: "gemini"),
            ],
            token: "ksfc_TOKEN", pairing: "ksfp_PAIR"
        )
        XCTAssertEqual(lines, [
            "export KEYSRS_TOKEN=ksfc_TOKEN",
            "export KEYSRS_PAIR=ksfp_PAIR",
            "export KEYSRS_CLAUDE_BASE_URL=https://keysrs-relay.me.workers.dev/claude",
            "export KEYSRS_ROUTER_BASE_URL=https://keysrs-relay.me.workers.dev/router",
            "export KEYSRS_DEEP_SEEK_BASE_URL=https://keysrs-relay.me.workers.dev/deep-seek",
            "export KEYSRS_GEM_BASE_URL=https://keysrs-relay.me.workers.dev/gem",
            "export ANTHROPIC_BASE_URL=https://keysrs-relay.me.workers.dev/claude",
            "export ANTHROPIC_AUTH_TOKEN=\"$KEYSRS_TOKEN\"",
            "export ANTHROPIC_CUSTOM_HEADERS=\"X-KSF-Pair: $KEYSRS_PAIR\"",
            "export OPENAI_BASE_URL=https://keysrs-relay.me.workers.dev/router",
            "export OPENAI_API_KEY=\"$KEYSRS_TOKEN\"",
        ])
        XCTAssertTrue(ShareEnv.needsHeaderInCode([.init(name: "router", api: "openai")]))
        XCTAssertFalse(ShareEnv.needsHeaderInCode([.init(name: "claude", api: "anthropic")]))
    }

    // MARK: issue

    func testIssueMintsOneTokenAndOnePairingUnderOnePrompt() throws {
        let (service, gate, db, dir) = try makeService()
        let issued = try service.issueShare(label: "hetzner box", keys: ["claude", "router"], days: 7)

        XCTAssertEqual(gate.reasons, ["share claude, router with hetzner box for 7 days"], "one prompt for the whole share")
        XCTAssertTrue(GatewayClientToken.looksLikeToken(issued.token))
        XCTAssertTrue(RelayPairing.looksLikeCredential(issued.credential))
        XCTAssertEqual(issued.share.label, "hetzner box")
        XCTAssertEqual(issued.share.keys, ["claude", "router"])
        XCTAssertEqual(issued.share.pairing.label, "share: hetzner box")
        XCTAssertEqual(issued.share.pairing.keys, ["claude", "router"], "the pairing reaches only the shared keys")
        XCTAssertEqual(issued.share.client?.methods, ["GET", "POST"])
        XCTAssertTrue(service.isGatewayEnabled("claude"), "the same prompt turns the gateway on")
        XCTAssertTrue(service.isGatewayEnabled("router"))

        // The one token serves every shared key, GET included, and nothing else.
        for key in ["claude", "router"] {
            for method in ["GET", "POST"] {
                guard case .allowed = service.authorizeGatewayClient(name: key, headers: bearer(issued.token), method: method, rest: "v1/models") else {
                    return XCTFail("\(method) \(key) is in the share")
                }
            }
        }
        XCTAssertEqual(service.authorizeGatewayClient(name: "router", headers: bearer(issued.token), method: "DELETE", rest: "v1/x"),
                       .denied("out_of_scope"))

        // The pairing verifies for the shared keys once pairing is required, and only those.
        try service.setRelayPairingRequired(true)
        XCTAssertEqual(service.verifyRelayPairing(credential: issued.credential, keyName: "router"), .ok)
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(service.verifyRelayPairing(credential: issued.credential, keyName: "other"), .outOfScope)

        // Only hashes are stored.
        assertNoSentinel(issued.token, in: dir)
        assertNoSentinel(issued.credential, in: dir)
        XCTAssertTrue(KeysService.hasLiveShare(catalog: db))
        XCTAssertEqual(try service.shares().map(\.label), ["hetzner box"])
    }

    func testIssueRefusesBeforePrompting() throws {
        let (bare, bareGate, _, _) = try makeService(relay: false)
        XCTAssertThrowsError(try bare.issueShare(label: "box", keys: ["claude"])) { error in
            XCTAssertTrue("\(error)".contains("keys relay setup"), "\(error)")
        }
        XCTAssertEqual(bareGate.reasons, [], "no relay: refused before the prompt")

        let (service, gate, _, _) = try makeService()
        XCTAssertThrowsError(try service.issueShare(label: "  ", keys: ["claude"]))
        XCTAssertThrowsError(try service.issueShare(label: "box", keys: []))
        XCTAssertThrowsError(try service.issueShare(label: "box", keys: ["missing"]))
        XCTAssertThrowsError(try service.issueShare(label: "box", keys: ["claude"], days: 0))
        XCTAssertThrowsError(try service.issueShare(label: "box\nnext", keys: ["claude"]))
        XCTAssertEqual(gate.reasons, [], "every refusal comes before the prompt")

        _ = try service.issueShare(label: "box", keys: ["claude"])
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertThrowsError(try service.issueShare(label: "box", keys: ["router"])) { error in
            XCTAssertTrue("\(error)".contains("revoke it first"), "\(error)")
        }
        XCTAssertEqual(gate.reasons.count, 1, "a duplicate live label is refused before the prompt")
    }

    // MARK: revoke and liveness

    func testRevokeEndsTheTokenAndThePairingTogether() throws {
        let (service, gate, db, _) = try makeService()
        let issued = try service.issueShare(label: "hetzner box", keys: ["claude", "router"])
        try service.setRelayPairingRequired(true)
        let prompts = gate.reasons.count

        let revoked = try service.revokeShare("hetzner box")
        XCTAssertEqual(gate.reasons.count, prompts, "ending access never prompts")
        XCTAssertFalse(revoked.isActive(now: Date()))
        XCTAssertEqual(service.authorizeGatewayClient(name: "router", headers: bearer(issued.token), method: "POST", rest: "v1/x"),
                       .denied("revoked"))
        XCTAssertEqual(service.authorizeGatewayClient(name: "claude", headers: bearer(issued.token), method: "POST", rest: "v1/x"),
                       .denied("revoked"))
        XCTAssertEqual(service.verifyRelayPairing(credential: issued.credential, keyName: "router"), .revoked)
        XCTAssertFalse(KeysService.hasLiveShare(catalog: db))
        XCTAssertThrowsError(try service.revokeShare("hetzner box")) { error in
            XCTAssertTrue("\(error)".contains("already revoked"), "\(error)")
        }
        XCTAssertThrowsError(try service.revokeShare("never shared"))

        // Revoking frees the label for a new share.
        _ = try service.issueShare(label: "hetzner box", keys: ["router"])
        XCTAssertEqual(try service.shares().filter { $0.isActive(now: Date()) }.map(\.keys), [["router"]])
    }

    func testLivenessIgnoresExpiredSharesAndPlainPairings() throws {
        let (service, _, db, _) = try makeService()
        let start = Date()
        _ = try service.issueShare(label: "box", keys: ["claude"], days: 1, now: start)
        XCTAssertTrue(KeysService.hasLiveShare(catalog: db, now: start.addingTimeInterval(3600)))
        XCTAssertFalse(KeysService.hasLiveShare(catalog: db, now: start.addingTimeInterval(2 * 86_400)), "an expired share is not live")

        // A pairing someone labelled like a share, without the share's token, is no share.
        let (other, _, otherDB, _) = try makeService()
        _ = try other.issueRelayPairing(label: "share: fake", keys: ["claude"])
        XCTAssertEqual(try other.shares(), [])
        XCTAssertFalse(KeysService.hasLiveShare(catalog: otherDB))
    }

    // MARK: API

    private func call(_ handler: APIHandler, _ method: String, body: [String: Any]? = nil) throws -> (Int, [String: Any], String) {
        let response = handler.handle(HTTPRequest(
            method: method, path: "/api/shares", query: [:],
            headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken],
            body: try body.map(JSONValue.data) ?? Data(), serverPort: 12765
        ))
        let text = String(decoding: response.body, as: UTF8.self)
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:], text)
    }

    func testRoutesMintOnceListHintsOnlyAndRevoke() throws {
        let (service, gate, _, dir) = try makeService()
        let handler = APIHandler(service: service, webRoot: dir)

        let (bad, _, _) = try call(handler, "POST", body: ["label": "box"])
        XCTAssertEqual(bad, 400, "keys are required")
        XCTAssertEqual(gate.reasons, [])

        let (status, obj, text) = try call(handler, "POST", body: ["label": "box", "keys": ["claude", "router"], "days": 3])
        XCTAssertEqual(status, 201, text)
        let token = try XCTUnwrap(JSONValue.string(obj["token"]))
        let credential = try XCTUnwrap(JSONValue.string(obj["credential"]))
        XCTAssertEqual(text.components(separatedBy: token).count - 1, 1, "the token is returned exactly once")
        XCTAssertEqual(text.components(separatedBy: credential).count - 1, 1, "the credential is returned exactly once")
        XCTAssertEqual(JSONValue.string(obj["relay_url"]), origin.absoluteString)
        let members = (obj["members"] as? [[String: Any]]) ?? []
        XCTAssertEqual(members.compactMap { $0["api"] as? String }, ["anthropic", "openai"])
        XCTAssertEqual(gate.reasons.count, 1)

        let (listed, list, listText) = try call(handler, "GET")
        XCTAssertEqual(listed, 200)
        XCTAssertFalse(listText.contains(token))
        XCTAssertFalse(listText.contains(credential))
        let first = try XCTUnwrap((list["shares"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["label"] as? String, "box")
        XCTAssertEqual(first["active"] as? Bool, true)
        XCTAssertEqual(first["token_hint"] as? String, GatewayClientToken.hint(token))

        let (gone, revoked, _) = try call(handler, "DELETE", body: ["label": "box"])
        XCTAssertEqual(gone, 200)
        XCTAssertEqual(JSONValue.object(revoked["share"])?["active"] as? Bool, false)
    }

    func testRelayRouteStoresTheSharedAwakeChoice() throws {
        let (service, _, _, dir) = try makeService()
        let handler = APIHandler(service: service, webRoot: dir)
        XCTAssertFalse(service.preferences.relayAwakeWhileShared, "off by default")
        let response = handler.handle(HTTPRequest(
            method: "POST", path: "/api/relay", query: [:],
            headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken],
            body: try JSONValue.data(["awake_while_shared": true]), serverPort: 12765
        ))
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let obj = (try JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        XCTAssertEqual(obj["awake_while_shared"] as? Bool, true)
        XCTAssertTrue(service.preferences.relayAwakeWhileShared)
    }
}
