import Foundation
import XCTest
@testable import KeysCore

final class GatewayBreakerTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    func testTripsAfterFiveConsecutiveAuthFailuresAndRecoversAfterTheCooldown() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        for _ in 0..<4 {
            XCTAssertFalse(breaker.record(key: "k", status: 401))
            XCTAssertEqual(breaker.check(key: "k"), .closed)
        }
        XCTAssertTrue(breaker.record(key: "k", status: 403), "the fifth failure trips")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 60))
        XCTAssertEqual(breaker.check(key: "other"), .closed, "per key")
        XCTAssertFalse(breaker.record(key: "k", status: 401), "already open: no second trip")

        clock.advance(30)
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 30))
        clock.advance(31)
        XCTAssertEqual(breaker.check(key: "k"), .closed, "the probe call is let through")
        XCTAssertTrue(breaker.record(key: "k", status: 401), "one more failure re-opens at once")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 60))

        breaker.record(key: "k", status: 200)
        XCTAssertEqual(breaker.check(key: "k"), .closed)
        for _ in 0..<4 { breaker.record(key: "k", status: 401) }
        breaker.record(key: "k", status: 429)
        XCTAssertFalse(breaker.record(key: "k", status: 401), "any other status resets the count")
        for _ in 0..<3 { breaker.record(key: "k", status: 401) }
        XCTAssertTrue(breaker.record(key: "k", status: 401))
        breaker.reset(key: "k")
        XCTAssertEqual(breaker.check(key: "k"), .closed)
    }

    func testGatewayStopsForwardingAfterRepeatedUpstreamDenialsAndLogsTheTripOnce() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(401, ["error": ["message": "invalid api key"]])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "breaker")

        func call() async throws -> (Int, HTTPURLResponse, Data) {
            var req = URLRequest(url: rig.url("v1/chat/completions"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(grant)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{\"model\":\"gpt-4.1\"}".utf8)
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            return (http.statusCode, http, data)
        }

        for _ in 0..<GatewayBreaker.threshold {
            let (status, _, _) = try await call()
            XCTAssertEqual(status, 401, "upstream's own answer is passed through")
        }
        XCTAssertEqual(hits.count, GatewayBreaker.threshold)

        let (status, http, data) = try await call()
        XCTAssertEqual(status, 503)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Retry-After"), "60")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["error"] as? String, "upstream_auth_blocked")
        XCTAssertEqual(body["retry_after_s"] as? Int, 60)
        XCTAssertTrue((body["message"] as? String ?? "").contains("keys test demo"))
        _ = try await call()
        XCTAssertEqual(hits.count, GatewayBreaker.threshold, "paused calls never reach the provider")

        // The usage rows are written after the response; wait for the five that went upstream.
        var rows: [UsageEvent] = []
        for _ in 0..<200 where rows.count < GatewayBreaker.threshold {
            rows = try rig.db.gatewayEvents()
            if rows.count < GatewayBreaker.threshold { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        XCTAssertEqual(rows.count, GatewayBreaker.threshold, "blocked calls are not usage")
        let trips = try rig.service.keyEvents(name: "demo").filter { $0.action == "gateway_denied" && $0.detail == "upstream_auth_blocked" }
        XCTAssertEqual(trips.count, 1)

        // Turning the gateway on again (a rotated key coming back) clears the pause.
        _ = try rig.service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(rig.stub.boundPort)")
        let (again, _, _) = try await call()
        XCTAssertEqual(again, 401)
        XCTAssertEqual(hits.count, GatewayBreaker.threshold + 1)
    }
}
