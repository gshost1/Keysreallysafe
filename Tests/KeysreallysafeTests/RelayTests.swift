import Foundation
import XCTest
@testable import KeysCore

/// A WebSocket the test drives: frames pushed in are what the Worker would send, frames
/// recorded are what the Mac sent back. No network.
final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RelayFrame] = []
    private var texts: [String] = []
    private var iterator: AsyncStream<RelayMessage>.Iterator
    private let feed: AsyncStream<RelayMessage>.Continuation
    private(set) var closed = false
    /// When set, every keepalive text send fails as a dead transport would.
    var failPings = false

    init() {
        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
        iterator = stream.makeAsyncIterator()
        feed = continuation
    }

    func push(_ frame: RelayFrame) { feed.yield(.binary(frame.encoded())) }
    func pushText(_ text: String) { feed.yield(.text(text)) }
    /// The Worker went away: the next receive fails.
    func drop() { feed.finish() }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        if let frame = RelayFrame.decode(data) {
            lock.lock()
            sent.append(frame)
            lock.unlock()
        }
        completion(nil)
    }

    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        texts.append(text)
        let fail = failPings
        lock.unlock()
        completion(fail ? RelayDialError(status: nil, message: "send failed") : nil)
    }

    func receive() async throws -> RelayMessage {
        guard let message = await iterator.next() else { throw RelayDialError(status: nil, message: "socket dropped") }
        return message
    }

    /// Like URLSession's cancel: a pending receive fails once the socket is closed.
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        feed.finish()
    }

    var frames: [RelayFrame] { lock.lock(); defer { lock.unlock() }; return sent }
    var pings: [String] { lock.lock(); defer { lock.unlock() }; return texts }

    /// Waits (boundedly) until a frame of `type` for `id` has been sent.
    func frame(_ type: RelayFrameType, id: UInt32, timeout: TimeInterval = 5) async throws -> RelayFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = frames.first(where: { $0.type == type && $0.id == id }) { return hit }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RelayDialError(status: nil, message: "no \(type) frame for \(id) within \(timeout)s; got \(frames.map { "\($0.type)#\($0.id)" })")
    }

    func json(_ frame: RelayFrame) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
    }
}

final class FakeRelayDialer: RelayDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<FakeRelaySocket, Error>]
    private(set) var attempts: [(URL, [String: String])] = []

    init(_ outcomes: [Result<FakeRelaySocket, Error>]) {
        self.outcomes = outcomes
    }

    func connect(url: URL, headers: [String: String]) async throws -> any RelaySocket {
        let next: Result<FakeRelaySocket, Error>? = lock.withLock {
            attempts.append((url, headers))
            return outcomes.isEmpty ? nil : outcomes.removeFirst()
        }
        guard let next else { throw CancellationError() }
        return try next.get()
    }
}

/// Records the sleeps a client asks for; `stopAfter` turns the next one into a cancellation
/// so a reconnect loop ends on its own.
final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [TimeInterval] = []
    var stopAfter: Int = .max

    func sleep(_ seconds: TimeInterval) async throws {
        let stop: Bool = lock.withLock {
            delays.append(seconds)
            return delays.count >= stopAfter
        }
        if stop { throw CancellationError() }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// A clock the test moves; the client's `now` reads it.
final class RelayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

final class RelayTests: XCTestCase {
    private let token = "ksfc_0123456789abcdef0123456789abcdef0123456789abcdef"

    private func requestHead(_ method: String, _ target: String, headers: [[String]]) -> Data {
        try! JSONValue.data(["method": method, "target": target, "headers": headers])
    }

    private func makeClient(
        port: UInt16, dialer: FakeRelayDialer, sleeper: RecordingSleeper = RecordingSleeper(),
        logs: LogSink = LogSink(), clock: RelayClock = RelayClock(),
        configure: (inout RelayClient.Options) -> Void = { _ in }
    ) -> RelayClient {
        var options = RelayClient.Options(
            url: URL(string: "https://keysrs-relay.example.workers.dev")!,
            secret: "ksfr_" + String(repeating: "a", count: 48),
            gatewayPort: port, pingInterval: 3600
        )
        configure(&options)
        return RelayClient(
            options: options,
            dialer: dialer,
            log: { logs.add($0) },
            sleep: { try await sleeper.sleep($0) },
            jitter: { 1.0 },
            now: { clock.now }
        )
    }

    /// Polls (boundedly) until the client has no request open.
    private func waitUntilIdle(_ client: RelayClient, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while client.inflightCount > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(client.inflightCount, 0)
    }

    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: framing and configuration

    func testFrameRoundTripAndRejection() {
        let frame = RelayFrame(type: .body, id: 0xFEED_BEEF, payload: Data([1, 2, 3]))
        let bytes = frame.encoded()
        XCTAssertEqual(Array(bytes.prefix(5)), [2, 0xFE, 0xED, 0xBE, 0xEF])
        XCTAssertEqual(RelayFrame.decode(bytes), frame)
        XCTAssertEqual(RelayFrame.decode(RelayFrame(type: .end, id: 7).encoded()), RelayFrame(type: .end, id: 7))
        XCTAssertNil(RelayFrame.decode(Data([1, 2, 3])))
        XCTAssertNil(RelayFrame.decode(Data([9, 0, 0, 0, 1])), "unknown type")
    }

    func testRelayURLValidation() throws {
        let origin = try RelayURL.validate(" https://keysrs-relay.me.workers.dev/ ")
        XCTAssertEqual(origin.absoluteString, "https://keysrs-relay.me.workers.dev")
        XCTAssertEqual(RelayURL.connectURL(origin).absoluteString, "wss://keysrs-relay.me.workers.dev/connect")
        XCTAssertEqual(RelayURL.baseURL(origin, key: "router"), "https://keysrs-relay.me.workers.dev/router")
        let dev = try RelayURL.validate("http://127.0.0.1:8787")
        XCTAssertEqual(RelayURL.connectURL(dev).absoluteString, "ws://127.0.0.1:8787/connect")
        for bad in ["", "ftp://x.example", "http://relay.example.com", "https://x.example/path", "https://u:p@x.example", "https://x.example?q=1", "not a url"] {
            XCTAssertThrowsError(try RelayURL.validate(bad), bad)
        }
    }

    func testRelaySecretShape() {
        let secret = RelaySecret.generate()
        XCTAssertTrue(secret.hasPrefix("ksfr_"))
        XCTAssertEqual(secret.count, 5 + 48)
        XCTAssertTrue(RelaySecret.looksLikeSecret(secret))
        XCTAssertFalse(RelaySecret.looksLikeSecret("ksfc_" + String(repeating: "0", count: 48)))
        XCTAssertEqual(RelaySecret.hint(secret), String(secret.suffix(4)))
        XCTAssertNotEqual(RelaySecret.generate(), secret)
    }

    func testRequestHeadValidationDropsRelayAndCloudflareHeaders() throws {
        let head = requestHead("post", "/demo/v1/messages?x=1", headers: [
            ["Authorization", "Bearer t"], ["CF-Connecting-IP", "1.2.3.4"], ["x-forwarded-for", "1.2.3.4"],
            ["Host", "evil"], ["X-KSF-Via", "forged"], ["content-type", "application/json"],
        ])
        let request = try XCTUnwrap(RelayRequest(id: 1, head: head))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers.map(\.0), ["authorization", "content-type"])
        let bytes = String(decoding: request.requestBytes(port: 12767), as: UTF8.self)
        XCTAssertTrue(bytes.hasPrefix("POST /demo/v1/messages?x=1 HTTP/1.1\r\nHost: 127.0.0.1:12767\r\nConnection: close\r\nContent-Length: 0\r\nX-KSF-Via: relay\r\n"))
        XCTAssertFalse(bytes.contains("evil"))
        XCTAssertFalse(bytes.contains("forged"))

        XCTAssertNil(RelayRequest(id: 1, head: Data("nope".utf8)))
        XCTAssertNil(RelayRequest(id: 1, head: requestHead("GET", "v1/no-leading-slash", headers: [])))
        XCTAssertNil(RelayRequest(id: 1, head: requestHead("GET", "/a b", headers: [])))
        XCTAssertNil(RelayRequest(id: 1, head: requestHead("GET", "/ok", headers: [["bad name", "v"]])))
        XCTAssertNil(RelayRequest(id: 1, head: requestHead("GET", "/ok", headers: [["x", "v\r\ninjected: 1"]])))
        XCTAssertNil(RelayRequest(id: 1, head: requestHead("G E T", "/ok", headers: [])))
    }

    func testResponseHeadParsing() throws {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 12\r\nConnection: close\r\nrequest-id: r1\r\n".utf8)
        let parsed = try XCTUnwrap(RelayRequest.parseHead(head))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.headers.map(\.0), ["Content-Type", "request-id"])
        XCTAssertNil(RelayRequest.parseHead(Data("garbage".utf8)))
        XCTAssertNil(RelayRequest.parseHead(Data("HTTP/1.1 999 Nope\r\n".utf8)))
    }

    // MARK: replaying against the real gateway on loopback

    func testRelayedCallGoesThroughTheGatewayAndIsMarkedAsRelayed() async throws {
        let captured = RequestLog()
        let stubBody = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let rig = try GatewayRig { request in
            captured.record(request)
            return HTTPResponse.data(200, stubBody, type: "application/json")
        }
        defer { rig.stop() }
        try rig.key(secret: "sk-test-secret")
        let grant = try grantFor(rig.service, "demo", task: "relay round trip")

        let socket = FakeRelaySocket()
        let dialer = FakeRelayDialer([.success(socket)])
        let sleeper = RecordingSleeper()
        sleeper.stopAfter = 1
        let logs = LogSink()
        let client = makeClient(port: rig.gateway.boundPort, dialer: dialer, sleeper: sleeper, logs: logs)
        let run = Task { await client.run() }
        defer { run.cancel() }

        let id: UInt32 = 42
        socket.push(RelayFrame(type: .request, id: id, payload: requestHead("POST", "/demo/v1/chat/completions", headers: [
            ["authorization", "Bearer \(grant)"], ["content-type", "application/json"],
            ["cf-connecting-ip", "203.0.113.9"], ["x-ksf-via", "forged"], ["host", "keysrs-relay.example.workers.dev"],
        ])))
        let body = Data("{\"model\":\"gpt-4.1\",\"messages\":[]}".utf8)
        socket.push(RelayFrame(type: .body, id: id, payload: body.prefix(10)))
        socket.push(RelayFrame(type: .body, id: id, payload: body.dropFirst(10)))
        socket.push(RelayFrame(type: .end, id: id))

        let head = try await socket.frame(.response, id: id)
        let headObj = try socket.json(head)
        XCTAssertEqual(headObj["status"] as? Int, 200)
        let headers = try XCTUnwrap(headObj["headers"] as? [[String]])
        XCTAssertTrue(headers.contains { $0[0].lowercased() == "content-type" && $0[1] == "application/json" }, "\(headers)")
        XCTAssertFalse(headers.contains { $0[0].lowercased() == "content-length" })
        XCTAssertFalse(headers.contains { $0[0].lowercased() == "connection" })
        _ = try await socket.frame(.end, id: id)
        let streamed = socket.frames.filter { $0.type == .body && $0.id == id }.reduce(Data()) { $0 + $1.payload }
        XCTAssertEqual(streamed, stubBody)

        let upstream = try XCTUnwrap(captured.last)
        XCTAssertEqual(upstream.headers["authorization"], "Bearer sk-test-secret")
        XCTAssertNil(upstream.headers["cf-connecting-ip"])
        XCTAssertNil(upstream.headers["x-ksf-via"])
        XCTAssertFalse(upstream.headers.values.contains { $0.contains(grant) })
        XCTAssertEqual(upstream.body, body)

        let usage = try await rig.usageRows()
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.sessionId, "gw-relay:demo")
        XCTAssertEqual(usage.first?.model, "gpt-4.1")
        let events = try rig.service.keyEvents(name: "demo")
        let call = try XCTUnwrap(events.first { $0.action == "gateway_call" })
        XCTAssertEqual(call.caller, "relay")
        XCTAssertEqual(client.inflightCount, 0)

        XCTAssertEqual(dialer.attempts.first?.0.absoluteString, "wss://keysrs-relay.example.workers.dev/connect")
        XCTAssertEqual(dialer.attempts.first?.1["X-Keysrs-Relay-Protocol"], "1")
        XCTAssertEqual(dialer.attempts.first?.1["Authorization"], "Bearer " + client.options.secret)
        XCTAssertFalse(logs.all.contains { $0.contains(client.options.secret) }, "the relay secret is never logged")
        XCTAssertFalse(logs.all.contains { $0.contains(grant) }, "the grant token is never logged")
    }

    func testRelayedCallWithoutATokenIsRefusedByTheGatewayNotTheRelay() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: requestHead("POST", "/demo/v1/chat/completions", headers: [["content-type", "application/json"]])))
        socket.push(RelayFrame(type: .end, id: 1))
        let head = try socket.json(try await socket.frame(.response, id: 1))
        XCTAssertEqual(head["status"] as? Int, 401)
        _ = try await socket.frame(.end, id: 1)
        let body = socket.frames.filter { $0.type == .body && $0.id == 1 }.reduce(Data()) { $0 + $1.payload }
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("client_required"))
        XCTAssertEqual(hits.count, 0)
    }

    func testStreamingResponseIsForwardedWithItsContentType() async throws {
        let sse = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.sse"))
        let rig = try GatewayRig { _ in HTTPResponse.data(200, sse, type: "text/event-stream") }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 9, payload: requestHead("POST", "/demo/v1/chat/completions", headers: [["x-api-key", grant], ["content-type", "application/json"]])))
        socket.push(RelayFrame(type: .body, id: 9, payload: Data("{\"model\":\"gpt-4.1\",\"stream\":true}".utf8)))
        socket.push(RelayFrame(type: .end, id: 9))
        let head = try socket.json(try await socket.frame(.response, id: 9))
        XCTAssertEqual(head["status"] as? Int, 200)
        let headers = try XCTUnwrap(head["headers"] as? [[String]])
        XCTAssertTrue(headers.contains { $0[0].lowercased() == "content-type" && $0[1].contains("event-stream") })
        _ = try await socket.frame(.end, id: 9)
        let streamed = socket.frames.filter { $0.type == .body && $0.id == 9 }.reduce(Data()) { $0 + $1.payload }
        XCTAssertEqual(streamed, sse)
    }

    func testGatewayDownBecomesAnErrorFrame() async throws {
        // A port nothing listens on: bind, read the number, close.
        let probe = try LoopbackListener(port: 0, acceptLabel: "t.accept", workLabel: "t.work")
        let port = probe.port
        probe.stop()
        let socket = FakeRelaySocket()
        let client = makeClient(port: port, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 3, payload: requestHead("GET", "/demo/v1/models", headers: [])))
        socket.push(RelayFrame(type: .end, id: 3))
        let error = try socket.json(try await socket.frame(.error, id: 3))
        XCTAssertEqual(error["code"] as? String, "gateway_unreachable")
        XCTAssertTrue((error["message"] as? String ?? "").contains("\(port)"))
        XCTAssertTrue(socket.frames.filter { $0.type == .response }.isEmpty)
    }

    func testOversizedBodyIsRefusedBeforeTheGateway() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 5, payload: requestHead("POST", "/demo/v1/chat/completions", headers: [])))
        let chunk = Data(repeating: UInt8(ascii: "x"), count: RelayProtocol.chunk)
        var sent = 0
        while sent <= RelayProtocol.bodyCap {
            socket.push(RelayFrame(type: .body, id: 5, payload: chunk))
            sent += chunk.count
        }
        socket.push(RelayFrame(type: .end, id: 5))
        let error = try socket.json(try await socket.frame(.error, id: 5))
        XCTAssertEqual(error["code"] as? String, "payload_too_large")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(hits.count, 0)
        XCTAssertEqual(client.inflightCount, 0)
    }

    func testCancelBeforeEndDropsTheRequestAndStrayFramesAreIgnored() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .body, id: 77, payload: Data("stray".utf8)))
        socket.push(RelayFrame(type: .end, id: 77))
        socket.push(RelayFrame(type: .request, id: 6, payload: requestHead("POST", "/demo/v1/chat/completions", headers: [])))
        socket.push(RelayFrame(type: .cancel, id: 6, payload: Data("{\"reason\":\"client_gone\"}".utf8)))
        socket.push(RelayFrame(type: .end, id: 6))
        socket.push(RelayFrame(type: .request, id: 8, payload: Data("not json".utf8)))
        let bad = try socket.json(try await socket.frame(.error, id: 8))
        XCTAssertEqual(bad["code"] as? String, "bad_request_frame")
        XCTAssertTrue(socket.frames.filter { $0.id == 6 || $0.id == 77 }.isEmpty)
        XCTAssertEqual(hits.count, 0)
        XCTAssertEqual(client.inflightCount, 0)
    }

    func testReconnectsWithBackoffAndExplainsARefusedSecretWithoutPrintingIt() async throws {
        let dialer = FakeRelayDialer([
            .failure(RelayDialError(status: 401, message: "handshake failed")),
            .failure(RelayDialError(status: nil, message: "network down")),
            .failure(RelayDialError(status: 400, message: "bad request")),
        ])
        let sleeper = RecordingSleeper()
        sleeper.stopAfter = 3
        let logs = LogSink()
        let client = makeClient(port: 1, dialer: dialer, sleeper: sleeper, logs: logs)
        await client.run()
        XCTAssertEqual(sleeper.delays, [1, 2, 4])
        XCTAssertEqual(dialer.attempts.count, 3)
        XCTAssertTrue(logs.all.contains { $0.contains("refused the relay secret (401)") }, "\(logs.all)")
        XCTAssertTrue(logs.all.contains { $0.contains("another relay protocol (400)") }, "\(logs.all)")
        XCTAssertTrue(logs.all.contains { $0.contains("reconnecting in 1s") })
        XCTAssertFalse(logs.all.contains { $0.contains(client.options.secret) })
        XCTAssertEqual(client.backoff(failures: 20), 60, "capped")
    }

    func testSocketDropCancelsOpenRequestsAndReconnects() async throws {
        let first = FakeRelaySocket()
        let second = FakeRelaySocket()
        let dialer = FakeRelayDialer([.success(first), .success(second)])
        let sleeper = RecordingSleeper()
        let client = makeClient(port: 1, dialer: dialer, sleeper: sleeper)
        let run = Task { await client.run() }
        defer { run.cancel() }
        first.push(RelayFrame(type: .request, id: 2, payload: requestHead("POST", "/demo/v1/x", headers: [])))
        first.pushText("pong")
        first.drop()
        second.push(RelayFrame(type: .request, id: 4, payload: Data("x".utf8)))
        _ = try await second.frame(.error, id: 4)
        XCTAssertTrue(first.closed)
        XCTAssertEqual(dialer.attempts.count, 2)
        XCTAssertEqual(sleeper.delays.filter { $0 != 3600 }, [1], "one backoff; the rest are the keepalive timer")
        XCTAssertEqual(client.inflightCount, 0, "the half-received request died with its socket")
    }

    // MARK: liveness and bounds

    func testSilentSocketIsClosedAfterTwoPingIntervalsAndReconnected() async throws {
        // Each keepalive tick moves the clock 2.5 intervals: the first tick already finds the
        // socket silent, and the same happens to the replacement, after which the dialer runs
        // out and the loop ends.
        let first = FakeRelaySocket()
        let second = FakeRelaySocket()
        let dialer = FakeRelayDialer([.success(first), .success(second)])
        let clock = RelayClock()
        let logs = LogSink()
        let client = RelayClient(
            options: RelayClient.Options(
                url: URL(string: "https://keysrs-relay.example.workers.dev")!,
                secret: "ksfr_" + String(repeating: "a", count: 48), gatewayPort: 1, pingInterval: 10
            ),
            dialer: dialer, log: { logs.add($0) },
            sleep: { seconds in
                clock.advance(seconds * 2.5)
                try await Task.sleep(nanoseconds: 1_000_000)
            },
            jitter: { 1.0 }, now: { clock.now }
        )
        await client.run()
        XCTAssertTrue(first.closed)
        XCTAssertTrue(second.closed)
        XCTAssertEqual(dialer.attempts.count, 3)
        XCTAssertEqual(first.pings, [], "a socket already silent for two intervals is not pinged, it is dropped")
        XCTAssertEqual(logs.all.filter { $0.contains("nothing heard from the Worker for 25s") }.count, 2, "\(logs.all)")
    }

    func testFailedKeepalivePingClosesTheSocketAndReconnects() async throws {
        let first = FakeRelaySocket()
        first.failPings = true
        let second = FakeRelaySocket()
        second.failPings = true
        let dialer = FakeRelayDialer([.success(first), .success(second)])
        let logs = LogSink()
        let clock = RelayClock()
        let client = RelayClient(
            options: RelayClient.Options(
                url: URL(string: "https://keysrs-relay.example.workers.dev")!,
                secret: "ksfr_" + String(repeating: "a", count: 48), gatewayPort: 1, pingInterval: 10
            ),
            dialer: dialer, log: { logs.add($0) },
            // Real time stands still, so the only way out of a socket is the refused ping.
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            jitter: { 1.0 }, now: { clock.now }
        )
        await client.run()
        XCTAssertEqual(first.pings, ["ping"])
        XCTAssertTrue(first.closed)
        XCTAssertTrue(second.closed)
        XCTAssertEqual(dialer.attempts.count, 3)
        XCTAssertEqual(logs.all.filter { $0.contains("keepalive ping failed") }.count, 2, "\(logs.all)")
    }

    func testRepeatedRequestIdCancelsTheEarlierReplayWithoutLosingTheNewOne() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            Thread.sleep(forTimeInterval: 0.6)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "repeated id")
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]))
        let run = Task { await client.run() }
        defer { run.cancel() }

        let head = requestHead("POST", "/demo/v1/chat/completions", headers: [["authorization", "Bearer \(grant)"], ["content-type", "application/json"]])
        socket.push(RelayFrame(type: .request, id: 11, payload: head))
        socket.push(RelayFrame(type: .end, id: 11))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(client.inflightCount, 1)
        // The Worker reuses the id: the first replay is cancelled, the second owns the id.
        socket.push(RelayFrame(type: .request, id: 11, payload: head))
        socket.push(RelayFrame(type: .end, id: 11))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.inflightCount, 1, "the cancelled replay finishing must not remove the newer request")

        _ = try await socket.frame(.response, id: 11)
        _ = try await socket.frame(.end, id: 11)
        try await waitUntilIdle(client)
        XCTAssertEqual(socket.frames.filter { $0.type == .response }.count, 1, "only the second replay answers")
        XCTAssertEqual(socket.frames.filter { $0.type == .error }.count, 0, "a cancelled replay stays quiet")
        XCTAssertEqual(hits.count, 2)
    }

    func testUnfinishedUploadsAreBoundedInCountBytesAndTime() async throws {
        let clock = RelayClock()
        let socket = FakeRelaySocket()
        let client = makeClient(port: 1, dialer: FakeRelayDialer([.success(socket)]), clock: clock) {
            $0.maxBufferedRequests = 2
            $0.maxBufferedBytes = 150
            $0.bufferTimeout = 10
        }
        let run = Task { await client.run() }
        defer { run.cancel() }
        let head = requestHead("POST", "/demo/v1/x", headers: [])

        // Count: a third unfinished upload evicts the oldest.
        for id: UInt32 in [1, 2, 3] { socket.push(RelayFrame(type: .request, id: id, payload: head)) }
        let full = try socket.json(try await socket.frame(.error, id: 1))
        XCTAssertEqual(full["code"] as? String, "relay_buffer_full")
        XCTAssertEqual(client.inflightCount, 2)

        // Bytes: 100 for the newest fits; 100 more for the older one tips the total over.
        socket.push(RelayFrame(type: .body, id: 3, payload: Data(repeating: 0x61, count: 100)))
        socket.push(RelayFrame(type: .body, id: 2, payload: Data(repeating: 0x62, count: 100)))
        let overflow = try socket.json(try await socket.frame(.error, id: 2))
        XCTAssertEqual(overflow["code"] as? String, "relay_buffer_full")
        XCTAssertEqual(client.inflightCount, 1)

        // Time: uploads older than the buffer timeout are dropped when the next frame comes.
        socket.push(RelayFrame(type: .request, id: 4, payload: head))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.inflightCount, 2)
        clock.advance(11)
        socket.push(RelayFrame(type: .request, id: 5, payload: head))
        for id: UInt32 in [3, 4] {
            let expired = try socket.json(try await socket.frame(.error, id: id))
            XCTAssertEqual(expired["code"] as? String, "upload_timeout")
        }
        XCTAssertEqual(client.inflightCount, 1, "only the fresh request survives")
        XCTAssertTrue(socket.frames.filter { $0.id == 5 }.isEmpty)
    }

    // MARK: settings

    func testSetupStoresSecretAndURLBehindPresenceAndResetForgetsThem() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        XCTAssertEqual(service.relayStatus(), KeysService.RelayStatus(url: nil, secretHint: nil))
        XCTAssertThrowsError(try service.relayCredentials())
        XCTAssertThrowsError(try service.relayCredentials(urlOverride: "https://x.workers.dev"))
        XCTAssertEqual(gate.reasons, [], "an unconfigured relay is refused before any presence prompt")

        let (url, secret) = try service.setupRelay(url: "https://keysrs-relay.me.workers.dev/")
        XCTAssertEqual(url.absoluteString, "https://keysrs-relay.me.workers.dev")
        XCTAssertTrue(RelaySecret.looksLikeSecret(secret))
        XCTAssertEqual(gate.reasons, ["set up the relay to keysrs-relay.me.workers.dev"])
        let status = service.relayStatus()
        XCTAssertEqual(status.url, url)
        XCTAssertEqual(status.secretHint, RelaySecret.hint(secret))
        XCTAssertTrue(status.configured)
        XCTAssertFalse(try db.metaRows(prefix: "").contains { $0.value.contains(secret) }, "only the hint is in the catalog")

        let creds = try service.relayCredentials()
        XCTAssertEqual(creds.secret, secret)
        XCTAssertEqual(creds.url, url)
        XCTAssertEqual(gate.reasons.last, "connect the relay to keysrs-relay.me.workers.dev")

        // Setting up again rotates the secret in place.
        let (_, rotated) = try service.setupRelay(url: "https://keysrs-relay.me.workers.dev")
        XCTAssertNotEqual(rotated, secret)
        XCTAssertEqual(try service.relayCredentials().secret, rotated)

        try service.resetRelay()
        XCTAssertFalse(service.relayStatus().configured)
        XCTAssertThrowsError(try service.relayCredentials())
        XCTAssertThrowsError(try service.setupRelay(url: "http://relay.example.com"))
    }

    func testServiceWithoutRelayStorageSaysSo() throws {
        let (db, _) = try makeDB()
        let service = KeysService(catalog: db, secrets: MemorySecretStore(), presence: RecordingPresenceGate(), clipboard: FakeClipboard())
        XCTAssertThrowsError(try service.setupRelay(url: "https://x.workers.dev")) { error in
            XCTAssertTrue(String(describing: error).contains("relay storage"))
        }
        XCTAssertNoThrow(try service.resetRelay())
    }
}
