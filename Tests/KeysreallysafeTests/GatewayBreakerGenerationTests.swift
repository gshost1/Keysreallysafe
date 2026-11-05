import Foundation
import XCTest
@testable import KeysCore

/// A paused key stays paused for its whole cool-down and, once the cool-down ends, exactly one
/// call may probe. Both promises used to be broken by the gateway's own concurrency: a call
/// that passed `check` before a sibling tripped the breaker erased the pause when it finished
/// with any non-401 status, and every caller whose `check` ran inside the new cool-down window
/// was let through as a "probe".
final class GatewayBreakerGenerationTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    /// Upstream calls counted in arrival order, so one slow call can be held while its
    /// siblings trip the breaker.
    final class CallOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
        var total: Int { lock.withLock { count } }
    }

    private func trips(_ breaker: GatewayBreaker, key: String = "k") {
        for _ in 0..<(GatewayBreaker.threshold - 1) { breaker.record(key: key, status: 401) }
    }

    private func assertClosed(
        _ verdict: GatewayBreaker.Verdict, probe: Bool = false, comment: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let admission = verdict.granted else {
            return XCTFail("expected a closed breaker, got \(verdict) \(comment)", file: file, line: line)
        }
        XCTAssertEqual(admission.probe, probe, "probe flag \(comment)", file: file, line: line)
    }

    /// The 200 belongs to a call admitted before the trip: it says nothing about the key as
    /// the provider sees it now, so it must not reopen the gate.
    func testAnInFlightCompletionDoesNotClearThePause() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        trips(breaker)
        let inflight = breaker.check(key: "k")
        assertClosed(inflight, comment: "this call passes check while counting")
        XCTAssertTrue(breaker.record(key: "k", status: 401), "a sibling trips the breaker")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 60))

        // The completion of the call admitted before the trip, tagged with what it was admitted under.
        XCTAssertFalse(breaker.record(key: "k", status: 200, admitting: inflight.granted), "an in-flight call does not trip")
        XCTAssertEqual(
            breaker.check(key: "k"), .open(retryAfterSeconds: 60),
            "a non-auth status from a call admitted before the trip must not erase the pause"
        )
        XCTAssertFalse(breaker.record(key: "k", status: 502, admitting: inflight.granted), "a synthesized gateway 502 neither")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 60))
    }

    /// After the cool-down the first caller is the probe; the rest of the burst is answered
    /// locally instead of going upstream.
    func testOnlyOneCallerProbesAfterTheCooldown() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        trips(breaker)
        breaker.record(key: "k", status: 401)
        clock.advance(GatewayBreaker.cooldown + 1)

        let probe = breaker.check(key: "k")
        assertClosed(probe, probe: true, comment: "the first caller is the probe")
        XCTAssertEqual(
            breaker.check(key: "k"), .open(retryAfterSeconds: 1),
            "a burst while the probe is out is answered locally"
        )
    }

    /// A probe whose caller never reported back (client gone, or the upstream call outlived
    /// the cool-down) must not wedge the key: after another cool-down a new probe is admitted,
    /// and the abandoned probe's late answer is ignored.
    func testAnAbandonedProbeDoesNotWedgeTheKey() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        trips(breaker)
        breaker.record(key: "k", status: 401)
        clock.advance(GatewayBreaker.cooldown + 1)

        let abandoned = breaker.check(key: "k")
        assertClosed(abandoned, probe: true, comment: "the first probe")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 1), "the burst waits")

        clock.advance(GatewayBreaker.cooldown + 1)
        let next = breaker.check(key: "k")
        assertClosed(next, probe: true, comment: "a new probe is admitted")
        XCTAssertFalse(
            breaker.record(key: "k", status: 200, admitting: abandoned.granted),
            "the abandoned probe's answer is history"
        )
        XCTAssertFalse(
            breaker.record(key: "k", status: 401, admitting: abandoned.granted),
            "and so is its rejection"
        )
        XCTAssertEqual(
            breaker.check(key: "k"), .open(retryAfterSeconds: 1),
            "the ghost's 401 did not re-open a full pause; the live probe is still out"
        )
        clock.advance(GatewayBreaker.cooldown + 1)
        assertClosed(breaker.check(key: "k"), probe: true, comment: "the key is not wedged by a ghost")
    }

    /// A reset (rotate, gateway on again) invalidates completions that were already in flight:
    /// they were admitted against a value that no longer exists.
    func testResetInvalidatesCompletionsAdmittedBeforeIt() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        for _ in 0..<4 { breaker.record(key: "k", status: 401) }
        let admitted = breaker.check(key: "k")
        breaker.reset(key: "k")
        XCTAssertFalse(
            breaker.record(key: "k", status: 401, admitting: admitted.granted),
            "the old streak is gone"
        )
        assertClosed(breaker.check(key: "k"))
    }

    /// A locally generated failure — the gateway's own 502 because no provider status ever
    /// arrived — is not evidence about the key. `record` must not be asked for it, and an
    /// admitted probe it belongs to is released so the next caller tries at once instead of
    /// waiting out the deadline or closing a pause nobody disproved.
    func testAnAbandonedProbeReleasesTheSlotInsteadOfClosingOrWedging() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        trips(breaker)
        breaker.record(key: "k", status: 401)
        clock.advance(GatewayBreaker.cooldown + 1)

        let probe = breaker.check(key: "k")
        assertClosed(probe, probe: true, comment: "the probe is admitted")
        XCTAssertEqual(breaker.check(key: "k"), .open(retryAfterSeconds: 1), "the burst waits")

        breaker.abandon(key: "k", admitting: probe.granted)
        let next = breaker.check(key: "k")
        assertClosed(next, probe: true, comment: "the released slot admits the next caller at once")
        XCTAssertNotEqual(
            next.granted?.generation, probe.granted?.generation,
            "and the abandoned attempt's late answer can never be applied"
        )
    }

    /// Only a probe holds a slot: abandoning a non-probe call must change nothing, and an
    /// abandoned probe must not be able to reopen a pause by arriving late as a 401.
    func testAbandonOnlyAffectsTheOutstandingProbe() {
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        let ordinary = breaker.check(key: "k")
        breaker.abandon(key: "k", admitting: ordinary.granted)
        assertClosed(breaker.check(key: "k"), probe: false, comment: "a non-probe abandon is a no-op")

        trips(breaker)
        breaker.record(key: "k", status: 401)
        clock.advance(GatewayBreaker.cooldown + 1)
        let probe = breaker.check(key: "k")
        assertClosed(probe, probe: true)
        breaker.abandon(key: "k", admitting: probe.granted)
        let next = breaker.check(key: "k")
        assertClosed(next, probe: true, comment: "the next caller probes")
        XCTAssertFalse(
            breaker.record(key: "k", status: 401, admitting: probe.granted),
            "the abandoned probe's late 401 is history"
        )
        XCTAssertEqual(
            breaker.check(key: "k"), .open(retryAfterSeconds: 1),
            "and it did not re-open a pause; the live probe is still out"
        )
    }

    /// One POST through the gateway with the grant as the API key.
    private static func status(of url: URL, token: String) async throws -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"model\":\"gpt-4.1\"}".utf8)
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// Through the real loopback gateway: one call is held upstream while five siblings get
    /// 401 and trip the breaker. Releasing the held call with a 200 must leave the pause up,
    /// so the next call is answered 503 without reaching the provider.
    func testAnInFlightCallDoesNotUnpauseTheRealGateway() async throws {
        let order = CallOrder()
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let rig = try GatewayRig { _ in
            if order.next() == 1 {
                arrived.signal()
                release.wait()
                return HTTPResponse.json(200, ["ok": true])
            }
            return HTTPResponse.json(401, ["error": ["message": "invalid api key"]])
        }
        defer {
            release.signal()
            rig.stop()
        }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "breaker")
        let url = rig.url("v1/chat/completions")
        let call: @Sendable () async throws -> Int = { try await Self.status(of: url, token: grant) }

        let slow = Task { try await call() }
        XCTAssertEqual(arrived.wait(timeout: .now() + 10), .success, "the call reached upstream")
        for _ in 0..<GatewayBreaker.threshold {
            let status = try await call()
            XCTAssertEqual(status, 401)
        }
        let paused = try await call()
        XCTAssertEqual(paused, 503, "the breaker is open")

        release.signal()
        let slowStatus = try await slow.value
        XCTAssertEqual(slowStatus, 200, "the held call finishes with the provider's 200")
        // The gateway records usage after it answers; six rows means the 200's `record` ran.
        var rows: [UsageEvent] = []
        for _ in 0..<200 {
            rows = try rig.db.gatewayEvents()
            if rows.count >= GatewayBreaker.threshold + 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(rows.count, GatewayBreaker.threshold + 1)

        let after = try await call()
        XCTAssertEqual(after, 503, "the in-flight 200 must not erase the pause")
        XCTAssertEqual(order.total, GatewayBreaker.threshold + 1, "no paused call reached the provider")
    }

    /// A provider's HEAD is the answer, and the gateway must tell the breaker then. Recording
    /// only when the stream ended let a slow generation hold the state back for minutes: the
    /// Item 2's real case: a probe that the provider answers 200 for, then keeps streaming past
    /// the cool-down. Recording only at stream end judged it abandoned, admitted a sibling, and
    /// discarded this 200 as history — the key stayed paused while the provider was answering.
    /// Here the head closes the pause immediately, with the cool-down walked forward through the
    /// scripted clock, so a second caller after the body is released finds it open with no probe.
    func testAProbeThatAnswers200AtTheHeadClosesThePauseWhileStillStreaming() async throws {
        let upstream = try HeldHeadServer(status: 200)
        defer { upstream.stop() }
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _) = try makeGatedService(db: db)
        let clock = Clock()
        let breaker = GatewayBreaker(now: { clock.now })
        service.replaceBreaker(breaker)
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(upstream.port)")
        let grant = try grantFor(service, "demo", task: "breaker")

        for _ in 0..<GatewayBreaker.threshold { breaker.record(key: "demo", status: 401) }
        XCTAssertNil(breaker.check(key: "demo").granted, "paused")
        clock.advance(GatewayBreaker.cooldown + 1)

        let port = gateway.boundPort
        // A raw client, so the test can see the relayed head arrive: reading it is proof the
        // gateway got that far, and with the record placed before the relay it is proof the
        // breaker has the status. URLSession would hide that behind its own buffering.
        let fd = try Self.connect(port: port)
        defer { Darwin.close(fd) }
        let body = Data("{\"model\":\"gpt-4.1\"}".utf8)
        let request = "POST /demo/v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Authorization: Bearer \(grant)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        _ = HTTPFrame.writeAll(fd: fd, Data(request.utf8) + body)

        XCTAssertEqual(upstream.sentHead.wait(timeout: .now() + 10), .success, "the probe reached upstream")
        let head = try XCTUnwrap(Self.readHead(fd: fd), "the gateway relayed the provider's head")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), "the probe's own 200 came through: \(head)")

        // The body is still held, and the head has been relayed to the caller — which the
        // gateway does only after telling the breaker. So the pause must already be closed, and
        // it must stay closed however far the clock walks; an ignored head-time 200 would have
        // left the state half-open, whose next `check` hands out another probe.
        clock.advance(GatewayBreaker.cooldown * 10)
        let after = breaker.check(key: "demo")
        XCTAssertEqual(after.granted?.probe, false, "the head's 200 closed the pause for good")
        upstream.release.signal()
    }

    private static func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw AppError.http("socket") }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw AppError.http("connect")
        }
        return fd
    }

    /// Reads up to the blank line that ends a response head.
    private static func readHead(fd: Int32, seconds: Int = 10) -> String? {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// A request the gateway cannot even build is answered 400 here and never reaches the
    /// provider, so it must not spend the probe a cool-down allows. The admission is taken at
    /// `check`, and taking it before the request existed meant an unbuildable call consumed the
    /// one probe and left the key paused for a full deadline with nothing tried.
    func testAnUnbuildableRequestDoesNotConsumeTheProbe() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _) = try makeGatedService(db: db)
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }
        try service.add(name: "demo", provider: "acme", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.test", api: "openai")
        // A provider record whose host `URL(string:)` refuses, installed behind the key: the
        // request cannot be built, so the gateway answers 400 without ever going upstream.
        var broken = try XCTUnwrap(Providers.provider(id: "acme"))
        broken.host = "bad%zz.test"
        Providers.setOverlay(["acme": broken])
        defer { Providers.setOverlay([:]) }
        _ = try service.setGateway(name: "demo", enabled: true, host: "bad%zz.test")
        XCTAssertNotNil(service.lookupGateway(name: "demo"), "the target is armed; only the request is unbuildable")

        // The breaker has already tripped, so the next call is the cool-down's probe.
        for _ in 0..<GatewayBreaker.threshold { service.breaker.record(key: "demo", status: 401) }
        let status = try await Self.status(of: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/chat")!,
                                          token: try grantFor(service, "demo", task: "breaker"))
        XCTAssertEqual(status, 400, "the unbuildable request is refused before the breaker is consulted")
        XCTAssertNil(
            service.breaker.check(key: "demo").granted,
            "and it did not spend the probe: the key is still paused for the next caller"
        )
    }
}

/// An upstream that sends the response HEAD plus one body byte and then holds the rest until
/// released, so a test can see what the gateway did with the head alone. (URLSession hands a
/// response to its delegate together with the first bytes, so a head with no body at all would
/// arrive late for reasons that have nothing to do with the gateway.)
final class HeldHeadServer: @unchecked Sendable {
    let listener: LoopbackListener
    let sentHead = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var port: UInt16 { listener.port }

    init(status: Int = 401) throws {
        let body = Data((status == 200 ? "{\"ok\":true}" : "{\"error\":\"invalid key\"}").utf8)
        listener = try LoopbackListener(port: 0, acceptLabel: "t.head.accept", workLabel: "t.head.work")
        listener.start { [sentHead, release] client in
            _ = HTTPFrame.read(fd: client, bodyCap: 1_000_000)
            let head = "HTTP/1.1 \(status) \(HTTPFrame.reason(status))\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = HTTPFrame.writeAll(fd: client, Data(head.utf8) + body.prefix(1))
            sentHead.signal()
            release.wait()
            _ = HTTPFrame.writeAll(fd: client, Data(body.dropFirst()))
            Darwin.close(client)
        }
    }

    func stop() { listener.stop() }
}
