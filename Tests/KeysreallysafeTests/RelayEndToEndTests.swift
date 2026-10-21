import Foundation
import XCTest
@testable import KeysCore

/// The real transport against a real Worker runtime, opt-in because it needs `wrangler dev`
/// running locally (still offline: workerd on this machine, no Cloudflare account):
///
///     cd Relay && printf 'RELAY_SECRET=ksfr_%s\n' "$(openssl rand -hex 24)" > .dev.vars
///     npx wrangler dev --port 8787        # in another terminal
///     KEYS_RELAY_E2E_URL=http://127.0.0.1:8787 KEYS_RELAY_E2E_SECRET=<that secret> \
///         swift test --filter RelayEndToEndTests
///
/// The outage case also wants a short Worker window, which wrangler dev takes as a variable:
///
///     npx wrangler dev --port 8787 --var RELAY_OFFLINE_GRACE_MS:3000
///     KEYS_RELAY_E2E_GRACE_MS=3000 KEYS_RELAY_E2E_URL=… KEYS_RELAY_E2E_SECRET=… \
///         swift test --filter RelayEndToEndTests
///
/// Everything else about the relay is covered without it (RelayTests, RelayHostTests, Relay/test).
final class RelayEndToEndTests: XCTestCase {
    func testRealWebSocketRoundTripThroughWranglerDev() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["KEYS_RELAY_E2E_URL"], let secret = env["KEYS_RELAY_E2E_SECRET"] else {
            throw XCTSkip("set KEYS_RELAY_E2E_URL and KEYS_RELAY_E2E_SECRET with wrangler dev running")
        }
        let origin = try RelayURL.validate(rawURL)
        let sse = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.sse"))
        let rig = try GatewayRig { _ in HTTPResponse.data(200, sse, type: "text/event-stream") }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "relay e2e")

        let connected = expectation(description: "connected")
        connected.assertForOverFulfill = false
        let client = RelayClient(
            options: RelayClient.Options(url: origin, secret: secret, gatewayPort: rig.gateway.boundPort),
            log: { line in
                XCTAssertFalse(line.contains(secret))
                if line.hasPrefix("connected") { connected.fulfill() }
            }
        )
        let run = Task { await client.run() }
        defer { run.cancel() }
        await fulfillment(of: [connected], timeout: 20)

        var request = URLRequest(url: URL(string: RelayURL.baseURL(origin, key: "demo") + "/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(grant)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"model\":\"gpt-4.1\",\"stream\":true}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, String(decoding: data, as: UTF8.self))
        XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Type")?.contains("event-stream") == true)
        XCTAssertEqual(data, sse)

        // No token: the gateway on the Mac refuses, the Worker only carries the answer.
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (denied, deniedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((deniedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(String(decoding: denied, as: UTF8.self).contains("client_required"))

        let usage = try await rig.usageRows()
        XCTAssertEqual(usage.first?.sessionId, "gw-relay:demo")
    }

    /// A refused upgrade still names its status, now that the dial waits for the handshake
    /// instead of a pong.
    func testAWrongSecretIsReportedAsTheWorkersRefusal() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["KEYS_RELAY_E2E_URL"], env["KEYS_RELAY_E2E_SECRET"] != nil else {
            throw XCTSkip("set KEYS_RELAY_E2E_URL and KEYS_RELAY_E2E_SECRET with wrangler dev running")
        }
        let wrong = RelaySecret.generate()
        do {
            _ = try await URLSessionRelayDialer().connect(
                url: RelayURL.connectURL(try RelayURL.validate(rawURL)),
                headers: ["Authorization": "Bearer \(wrong)", RelayProtocol.protocolHeader: RelayProtocol.version]
            )
            XCTFail("the Worker took a secret it was never given")
        } catch let error as RelayDialError {
            XCTAssertEqual(error.status, 401, "\(error)")
            XCTAssertTrue("\(error)".contains("refused the relay secret (401)"))
            XCTAssertFalse("\(error)".contains(wrong))
        }
    }

    /// The app's relay (RelayHost, as the menu runs it) across an outage: a call made while it
    /// is off waits in the Worker and is answered once it is on again, and with the relay off
    /// for longer than the Worker's window the agent gets the JSON 503 that says to retry.
    func testACallDuringAShortOutageWaitsForTheAppRelayAndALongOneGetsA503() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["KEYS_RELAY_E2E_URL"], let secret = env["KEYS_RELAY_E2E_SECRET"] else {
            throw XCTSkip("set KEYS_RELAY_E2E_URL and KEYS_RELAY_E2E_SECRET with wrangler dev running")
        }
        let graceMs = Int(env["KEYS_RELAY_E2E_GRACE_MS"] ?? "") ?? 60_000
        let origin = try RelayURL.validate(rawURL)
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "relay outage e2e")
        let lockURL = try TempDir.make().appendingPathComponent("relay.lock")
        let host = RelayHost(log: { line in XCTAssertFalse(line.contains(secret)) }, blocker: FakeSleepBlocker())
        defer { host.stop() }

        func connect() async throws {
            host.start(origin: origin, secret: secret, gatewayPort: rig.gateway.boundPort, relayLock: try RelayLock(at: lockURL))
            let deadline = Date().addingTimeInterval(20)
            while true {
                if case .connected = host.status.state.phase { return }
                guard Date() < deadline else { return XCTFail("the relay did not connect: \(host.status)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        /// Status, body and Retry-After of one agent call through the Worker.
        func call() async throws -> (Int, Data, String?) {
            var request = URLRequest(url: URL(string: RelayURL.baseURL(origin, key: "demo") + "/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(grant)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"model\":\"gpt-4.1\"}".utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            return (http.statusCode, data, http.value(forHTTPHeaderField: "Retry-After"))
        }

        try await connect()
        let (first, _, _) = try await call()
        XCTAssertEqual(first, 200)

        // Off, as when the Mac drops; the Worker learns of the close, then a call arrives.
        host.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let started = Date()
        let waiting = Task { try await call() }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await connect()
        let (held, heldBody, _) = try await waiting.value
        XCTAssertEqual(held, 200, String(decoding: heldBody, as: UTF8.self))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.4, "it waited for the relay")

        guard graceMs <= 10_000 else { return }
        host.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let refusedAt = Date()
        let (refused, data, retryAfter) = try await call()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(refused, 503)
        XCTAssertEqual(body["error"] as? String, "mac_offline")
        XCTAssertEqual(body["retryable"] as? Bool, true)
        XCTAssertEqual(retryAfter, "30")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(refusedAt), Double(graceMs) / 1000 - 0.2, "after the window, not at once")
    }
}
