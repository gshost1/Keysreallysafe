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
/// Everything else about the relay is covered without it (RelayTests, Relay/test).
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
}
