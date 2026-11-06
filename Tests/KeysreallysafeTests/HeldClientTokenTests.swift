import Foundation
import XCTest
@testable import KeysCore

/// `keys client issue --hold` and `keys client token`: one Touch ID at issue, then the app
/// hands the same scoped token back to a control-channel caller with no prompt, until it
/// expires or is revoked. The held copy must die with its row on every revoke path.
final class HeldClientTokenTests: XCTestCase {
    private func makeRig() throws -> (GatewayRig, MemorySecretStore) {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        try rig.key()
        return (rig, try XCTUnwrap(rig.service.heldTokens as? MemorySecretStore))
    }

    private func held(_ store: MemorySecretStore, _ id: Int64) -> String? {
        try? store.get(name: KeysService.heldAccount(id))
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

    func testHoldPromptsOnceNamesTheHoldAndHandsTheTokenBackWithoutAnotherPrompt() async throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let before = rig.gate.reasons.count
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "hermes", days: 7, hold: true)
        XCTAssertEqual(Array(rig.gate.reasons.dropFirst(before)), ["issue gateway client for demo at 127.0.0.1:\(rig.stub.boundPort), held for hermes for 7 days"])
        XCTAssertTrue(issued.client.held)
        XCTAssertEqual(held(store, issued.client.id), issued.token)
        // The catalog still holds a hash only.
        XCTAssertNil(try Data(contentsOf: rig.db.path).range(of: Data(issued.token.utf8)))

        guard case .active(let token, let client) = try rig.service.heldClientToken(label: "hermes") else {
            return XCTFail("expected the held token")
        }
        XCTAssertEqual(token, issued.token)
        XCTAssertEqual(client.id, issued.client.id)
        XCTAssertEqual(rig.gate.reasons.count, before + 1, "the read asks for nothing")
        let status = try await send(rig.url("v1/chat/completions"), token: token)
        XCTAssertEqual(status, 200)
        let actions = try rig.service.keyEvents(name: "demo").map(\.action)
        XCTAssertTrue(actions.contains("client_held_read"))
        // No audit row or listing carries the token.
        for e in try rig.service.keyEvents(name: "demo") { XCTAssertFalse((e.detail ?? "").contains(token)) }
    }

    func testReissuingUnderTheSameLabelReplacesTheEarlierToken() async throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let first = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        let second = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        XCTAssertNil(held(store, first.client.id), "the replaced copy is gone")
        XCTAssertNotNil(try rig.service.gatewayClients(name: "demo").first { $0.id == first.client.id }?.revokedAt)
        let status = try await send(rig.url("v1/chat/completions"), token: first.token)
        XCTAssertEqual(status, 401)
        guard case .active(let token, _) = try rig.service.heldClientToken(label: "hermes") else { return XCTFail("expected active") }
        XCTAssertEqual(token, second.token)
        // A different label is untouched.
        let other = try rig.service.issueGatewayClient(name: "demo", label: "nightly", hold: true)
        XCTAssertEqual(held(store, other.client.id), other.token)
        XCTAssertEqual(held(store, second.client.id), second.token)
    }

    func testRevokedAndExpiredAnswerWhyAndDropTheCopy() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        XCTAssertEqual(try rig.service.heldClientToken(label: "hermes"), .unavailable("not_found"))
        let a = try rig.service.issueGatewayClient(name: "demo", label: "hermes", days: 1, hold: true)
        XCTAssertEqual(try rig.service.heldClientToken(label: "hermes", now: Date().addingTimeInterval(2 * 86_400)), .unavailable("expired"))
        XCTAssertNil(held(store, a.client.id))
        let b = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        _ = try rig.service.revokeGatewayClient(name: "demo", id: b.client.id, caller: "cli")
        XCTAssertNil(held(store, b.client.id), "single revoke drops the copy")
        XCTAssertEqual(try rig.service.heldClientToken(label: "hermes"), .unavailable("revoked"))
    }

    func testKillSwitchKeyRemovalAndProjectRevokeDropCopies() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let a = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        XCTAssertEqual(try rig.service.revokeGatewayClients(key: nil, caller: "cli"), 1)
        XCTAssertNil(held(store, a.client.id))
        let b = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        try rig.service.remove(name: "demo", caller: "cli")
        XCTAssertNil(held(store, b.client.id), "deleting the key drops its held copies")
        XCTAssertEqual(try rig.service.heldClientToken(label: "hermes"), .unavailable("not_found"))
    }

    func testSweepDropsCopiesOfDeadClients() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let a = try rig.service.issueGatewayClient(name: "demo", label: "hermes", days: 1, hold: true)
        rig.service.sweepHeldTokens()
        XCTAssertNotNil(held(store, a.client.id), "a live copy stays")
        rig.service.sweepHeldTokens(now: Date().addingTimeInterval(2 * 86_400))
        XCTAssertNil(held(store, a.client.id))
    }

    func testACopyThatDoesNotMatchItsRowIsNeverHandedOut() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let a = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        try store.delete(name: KeysService.heldAccount(a.client.id))
        try store.add(name: KeysService.heldAccount(a.client.id), secret: GatewayClientToken.generate())
        XCTAssertEqual(try rig.service.heldClientToken(label: "hermes"), .unavailable("not_found"))
        XCTAssertNil(held(store, a.client.id))
    }

    func testBadLabelsAndProcessesWithoutAStoreAreRefusedBeforeAnyPrompt() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        let before = rig.gate.reasons.count
        for label in ["", "Hermes", "a b", "../x", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: label, hold: true), label)
            XCTAssertThrowsError(try rig.service.heldClientToken(label: label), label)
        }
        XCTAssertEqual(rig.gate.reasons.count, before)

        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let bare = KeysService(catalog: db, secrets: MemorySecretStore(), presence: gate, clipboard: FakeClipboard())
        XCTAssertThrowsError(try bare.heldClientToken(label: "hermes"))
        XCTAssertTrue(gate.reasons.isEmpty)
    }

    func testAKeychainRefusalRevokesTheJustMintedToken() throws {
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db, secrets: MemorySecretStore(), presence: gate, clipboard: FakeClipboard(),
            heldTokens: RefusingSecretStore()
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.issueGatewayClient(name: "demo", label: "hermes", hold: true))
        let rows = try service.gatewayClients(name: "demo")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].revokedAt, "a token nobody can read back must not stay live")
    }

    func testALeftoverKeychainItemUnderTheSameIDDoesNotFailTheIssue() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        // The next client id in a fresh catalog is 1; an old Keychain still holds client-1.
        try store.add(name: KeysService.heldAccount(1), secret: GatewayClientToken.generate())
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        XCTAssertEqual(issued.client.id, 1)
        XCTAssertEqual(held(store, 1), issued.token)
        XCTAssertNil(try rig.service.gatewayClients(name: "demo").first?.revokedAt)
    }

    func testAnOlderIssueFinishingLateNeverRevokesTheNewerOne() throws {
        let (rig, store) = try makeRig()
        defer { rig.stop() }
        let older = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        let newer = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        // The older racer's replace step runs last.
        try rig.service.storeHeldToken(older, caller: "cli")
        XCTAssertNil(try rig.service.gatewayClients(name: "demo").first { $0.id == newer.client.id }?.revokedAt)
        XCTAssertEqual(held(store, newer.client.id), newer.token)
        guard case .active(let token, _) = try rig.service.heldClientToken(label: "hermes") else { return XCTFail("expected active") }
        XCTAssertEqual(token, newer.token)
    }

    func testLabelsLongerThanTheStoredLabelAreRefused() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        XCTAssertNoThrow(try rig.service.issueGatewayClient(name: "demo", label: String(repeating: "a", count: 80), hold: true))
        XCTAssertThrowsError(try rig.service.issueGatewayClient(name: "demo", label: String(repeating: "a", count: 81), hold: true))
    }

    func testReadsAreAuditedAtMostOncePerHourPerToken() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        _ = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        let t0 = Date()
        for i in 0..<5 { _ = try rig.service.heldClientToken(label: "hermes", now: t0.addingTimeInterval(Double(i))) }
        _ = try rig.service.heldClientToken(label: "hermes", now: t0.addingTimeInterval(3601))
        let reads = try rig.service.keyEvents(name: "demo").filter { $0.action == "client_held_read" }
        XCTAssertEqual(reads.count, 2)
    }

    // MARK: - The control route

    func testRouteIsTokenGatedAndAnswersWhyNot() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        let web = try TempDir.make()
        let handler = APIHandler(service: rig.service, webRoot: web)
        let body = try JSONSerialization.data(withJSONObject: ["label": "hermes"])
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/clients/held/token", body: body, token: false).status, 403)
        let missing = handle(handler, method: "POST", path: "/api/clients/held/token", body: body)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(try json(missing)["detail"] as? String, "not_found")

        // The issue route with hold never puts the token on the wire.
        let issueBody = try JSONSerialization.data(withJSONObject: ["label": "hermes", "hold": true, "days": 3])
        let issued = handle(handler, method: "POST", path: "/api/keys/demo/clients", body: issueBody)
        XCTAssertEqual(issued.status, 201)
        XCTAssertNil(try json(issued)["token"])

        let found = handle(handler, method: "POST", path: "/api/clients/held/token", body: body)
        XCTAssertEqual(found.status, 200)
        let obj = try json(found)
        XCTAssertTrue(GatewayClientToken.looksLikeToken(obj["token"] as? String ?? ""))
        XCTAssertEqual(obj["base_url"] as? String, "http://127.0.0.1:\(GatewayListener.port)/demo")
        XCTAssertNotNil(obj["gateway_on"] as? Bool)
        XCTAssertEqual((obj["client"] as? [String: Any])?["held"] as? Bool, true)
    }

    /// Audit lead 5: the origin token is in every GET / answer, and loopback is shared by
    /// every macOS account, so that token alone must never hand back a held client token.
    /// Every request here is raw, as another account's curl would send it.
    func testThePageTokenAloneNeverReadsAHeldToken() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "cron", days: 7, hold: true)
        let web = try TempDir.make()
        try "<html><head></head><body></body></html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        let handler = APIHandler(service: rig.service, webRoot: web)
        let promptsAfterIssue = rig.gate.reasons.count
        func raw(_ method: String, _ path: String, _ headers: [String: String] = [:], _ body: Data = Data()) -> HTTPResponse {
            var headers = headers
            headers["host"] = "127.0.0.1:12765"
            return handler.handle(HTTPRequest(method: method, path: path, query: [:], headers: headers, body: body, serverPort: 12765))
        }

        let page = String(decoding: raw("GET", "/").body, as: UTF8.self)
        let token = try XCTUnwrap(
            page.firstMatch(of: /<meta name="ksf-token" content="([0-9a-f]+)">/).map { String($0.1) }
        )
        let clients = try XCTUnwrap(JSONSerialization.jsonObject(with: raw("GET", "/api/keys/demo/clients").body) as? [String: Any])
        let rows = try XCTUnwrap(clients["clients"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["label"] as? String == "cron" && $0["held"] as? Bool == true })

        let body = try JSONSerialization.data(withJSONObject: ["label": "cron"])
        let stolen = raw("POST", "/api/clients/held/token", ["x-ksf-token": token, "content-type": "application/json"], body)
        XCTAssertEqual(stolen.status, 403, "the page token alone must not read a held token")
        XCTAssertNil(String(decoding: stolen.body, as: UTF8.self).range(of: issued.token))
        XCTAssertEqual(rig.gate.reasons.count, promptsAfterIssue)
    }

    /// The secret-gated routes answer the control secret, and nothing else stands in for it:
    /// not its absence, not a wrong value, not the page token in its header.
    func testSecretGatedRoutesNeedTheControlSecret() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        _ = try rig.service.issueGatewayClient(name: "demo", label: "cron", hold: true)
        let handler = APIHandler(
            service: rig.service, webRoot: try TempDir.make(), openFeedbackURL: { _ in XCTFail("nothing opens") }
        )
        XCTAssertNotEqual(handler.controlSecret, handler.originToken)
        let routes: [(String, [String: Any])] = [
            ("/api/clients/held/token", ["label": "cron"]),
            ("/api/mcp/vault_lookup", ["hashes": [String(repeating: "0", count: 64)]]),
            ("/api/mcp/feedback", ["draft": "hello", "channel": "email"]),
        ]
        for (path, payload) in routes {
            let body = try JSONSerialization.data(withJSONObject: payload)
            for wrong in [nil, "", "nope", handler.originToken, handler.controlSecret + "0"] as [String?] {
                var headers: [String: String] = [:]
                if let wrong { headers["x-ksf-control"] = wrong }
                let refused = handle(handler, method: "POST", path: path, headers: headers, body: body, control: false)
                XCTAssertEqual(refused.status, 403, "\(path) with \(wrong ?? "no header")")
                XCTAssertEqual(try json(refused)["error"] as? String, "control_secret_required")
            }
            XCTAssertEqual(handle(handler, method: "POST", path: path + "/", body: body, control: false).status, 403,
                           "\(path) with a trailing slash is the same route")
        }
        XCTAssertTrue(ControlFile.requiresSecret(method: "post", path: "/api/clients/held/token"))
        let ok = handle(handler, method: "POST", path: "/api/clients/held/token",
                        body: try JSONSerialization.data(withJSONObject: ["label": "cron"]))
        XCTAssertEqual(ok.status, 200)
        // The dashboard's own routes stay on the page token alone.
        let list = handle(handler, method: "POST", path: "/api/mcp/grants/status", body: Data("{}".utf8), control: false)
        XCTAssertEqual(list.status, 200)
    }

    /// The site publishes the secret in control.json beside the token, and the page it
    /// serves carries the token only.
    func testTheSitePublishesTheSecretInTheControlFileOnly() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        let web = try TempDir.make()
        try Data("<html><head></head></html>".utf8).write(to: web.appendingPathComponent("index.html"))
        setenv("KEYS_WEB_ROOT", web.path, 1)
        defer { unsetenv("KEYS_WEB_ROOT") }
        let server = try LoopbackSite.bind(service: service, preferredPort: 0, gatewayPort: 0)
        defer { server.stop(); service.stopGateway(); try? FileManager.default.removeItem(at: control) }

        let info = try XCTUnwrap(try ControlFile.read(at: control))
        XCTAssertEqual(info.controlSecret.count, 64)
        XCTAssertNotEqual(info.controlSecret, info.token)
        let mode = try FileManager.default.attributesOfItem(atPath: control.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort)/")!)
        req.setValue("127.0.0.1:\(server.boundPort)", forHTTPHeaderField: "Host")
        let (data, _) = try BlockingHTTP.send(req, timeout: 5)
        let page = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(page.contains(info.token), "the page still carries its CSRF token")
        XCTAssertFalse(page.contains(info.controlSecret), "the page never carries the control secret")
    }

    /// `keys client token` end to end over a control file: the current file's secret reads
    /// the held token; a file from a site that predates the secret fails closed in the
    /// client, with a sentence, and the request never leaves this process.
    func testTheCLIReadsWithTheSecretAndFailsClosedOnAnOlderControlFile() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        let issued = try rig.service.issueGatewayClient(name: "demo", label: "cron", hold: true)
        let handler = APIHandler(service: rig.service, webRoot: try TempDir.make())
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: rig.db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: .neverLaunching)
        defer { try? FileManager.default.removeItem(at: control) }

        try ControlFile.write(
            port: server.boundPort, token: handler.originToken, controlSecret: handler.controlSecret, to: control
        )
        let client = try ControlClient.connect(control: control)
        let answer = try client.call(method: "POST", path: "/api/clients/held/token", body: ["label": "cron"], expect: 200)
        XCTAssertEqual(answer["token"] as? String, issued.token)
        XCTAssertEqual(log.last?.headers["x-ksf-control"], handler.controlSecret)

        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        XCTAssertEqual(try ControlFile.read(at: control)?.controlSecret, "")
        let before = log.count
        let command = try ClientTokenCommand.parse(["--label", "cron"])
        XCTAssertThrowsError(try command.run(launch: .neverLaunching, control: control)) { error in
            XCTAssertTrue("\(error)".contains("older than this keys command"), "\(error)")
        }
        XCTAssertEqual(log.count, before, "nothing was sent to a site that cannot check the secret")
    }

    func testGetNeverServesAHeldToken() throws {
        let (rig, _) = try makeRig()
        defer { rig.stop() }
        _ = try rig.service.issueGatewayClient(name: "demo", label: "hermes", hold: true)
        let handler = APIHandler(service: rig.service, webRoot: try TempDir.make())
        let got = handle(handler, method: "GET", path: "/api/clients/held/token", token: false)
        XCTAssertNotEqual(got.status, 200)
        XCTAssertFalse(String(decoding: got.body, as: UTF8.self).contains("ksfc_"))
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
}

/// A Keychain that refuses every write, for the revoke-on-refusal path.
final class RefusingSecretStore: SecretStore, @unchecked Sendable {
    func add(name: String, secret: String) throws { throw AppError.keychain("refused") }
    func get(name: String) throws -> String { throw AppError.notFound(name) }
    func delete(name: String) throws {}
    func replace(name: String, secret: String) throws { throw AppError.keychain("refused") }
    func deleteAll() throws {}
}
