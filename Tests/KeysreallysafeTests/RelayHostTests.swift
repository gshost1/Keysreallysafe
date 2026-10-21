import Foundation
import XCTest
@testable import KeysCore

/// A socket whose receive ignores task cancellation, as URLSession's does: only close() ends it.
final class StubbornRelaySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<RelayMessage, Error>?
    private var isClosed = false

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }

    func receive() async throws -> RelayMessage {
        try await withCheckedThrowingContinuation { continuation in
            let closed: Bool = lock.withLock {
                if isClosed { return true }
                waiting = continuation
                return false
            }
            if closed { continuation.resume(throwing: RelayDialError(status: nil, message: "closed")) }
        }
    }

    func close() {
        let pending: CheckedContinuation<RelayMessage, Error>? = lock.withLock {
            isClosed = true
            defer { waiting = nil }
            return waiting
        }
        pending?.resume(throwing: RelayDialError(status: nil, message: "closed"))
    }

    var closed: Bool { lock.withLock { isClosed } }
}

/// Records the idle-sleep assertion instead of taking one.
final class FakeSleepBlocker: IdleSleepBlocker, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var reasons: [String] = []

    func begin(reason: String) -> Bool {
        lock.withLock {
            if !held { begins += 1; reasons.append(reason) }
            held = true
            return true
        }
    }

    func end() {
        lock.withLock {
            if held { ends += 1 }
            held = false
        }
    }

    var isHeld: Bool { lock.withLock { held } }
}

/// A backoff sleep the test lets go of.
final class GateSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private(set) var delays: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { delays.append(seconds) }
        while !(lock.withLock { open }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func release() { lock.withLock { open = true } }
}

final class RelayHostTests: XCTestCase {
    private let origin = URL(string: "https://keysrs-relay.me.workers.dev")!
    private let secret = "ksfr_" + String(repeating: "b", count: 48)

    /// Polls (boundedly) until `check` holds.
    private func until(_ what: String, timeout: TimeInterval = 5, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { throw RelayDialError(status: nil, message: "timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func isConnected(_ state: RelayClient.State) -> Bool {
        if case .connected = state.phase { return true }
        return false
    }

    private func head() -> Data {
        try! JSONValue.data(["method": "POST", "target": "/demo/v1/x", "headers": []])
    }

    // MARK: lock

    func testOneRelayLockPerMacAndTheRefusalNamesTheHolder() throws {
        let dir = try TempDir.make()
        let url = RelayLock.url(beside: dir.appendingPathComponent("catalog.db"))
        XCTAssertEqual(url.lastPathComponent, "relay.lock")
        XCTAssertNil(RelayLock.holder(at: url), "nobody holds a lock that was never taken")

        let first = try RelayLock(at: url)
        XCTAssertThrowsError(try RelayLock(at: url)) { error in
            XCTAssertEqual(error as? RelayLock.Held, RelayLock.Held(pid: getpid()))
        }
        let held = try XCTUnwrap(RelayLock.holder(at: url))
        XCTAssertEqual(held.pid, getpid())
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Without a control file naming this process, the holder is a Terminal relay.
        let control = ControlFile.url(beside: dir.appendingPathComponent("catalog.db"))
        XCTAssertFalse(held.isApp(control: control))
        XCTAssertTrue(held.terminalRefusal(control: control).contains("another keys relay is already running"))
        XCTAssertTrue(held.terminalRefusal(control: control).contains("(process \(getpid()))"))
        XCTAssertTrue(held.appRefusal.contains("stop it with Ctrl-C"))
        // The app writes the control file, so a holder with its pid is the app's relay.
        try ControlFile.write(port: 12766, token: "t", to: control)
        XCTAssertTrue(held.isApp(control: control))
        XCTAssertTrue(held.terminalRefusal(control: control).contains("the Keysrs app's relay is on"))
        XCTAssertTrue(held.terminalRefusal(control: control).contains("keys relay off"))

        first.release()
        XCTAssertNil(RelayLock.holder(at: url))
        XCTAssertNoThrow(try RelayLock(at: url).release())
    }

    func testDroppingTheLockObjectReleasesIt() throws {
        let url = try TempDir.make().appendingPathComponent("relay.lock")
        do { _ = try RelayLock(at: url) }
        XCTAssertNil(RelayLock.holder(at: url))
    }

    // MARK: client

    /// Hands out the same socket on every dial.
    private struct SameSocketDialer: RelayDialer {
        let socket: any RelaySocket
        func connect(url: URL, headers: [String: String]) async throws -> any RelaySocket { socket }
    }

    func testCancellingTheRunEndsAReceiveThatIgnoresCancellation() async throws {
        let socket = StubbornRelaySocket()
        let logs = RelayTests.LogSink()
        let client = RelayClient(
            options: RelayClient.Options(url: origin, secret: secret, gatewayPort: 1, pingInterval: 3600),
            dialer: SameSocketDialer(socket: socket),
            log: { logs.add($0) }
        )
        let done = LockedValue(false)
        let run = Task {
            await client.run()
            done.set(true)
        }
        try await until("connected") { isConnected(client.state) }
        run.cancel()
        try await until("the loop to end", timeout: 2) { done.get() }
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(client.state.phase, .stopped)
        XCTAssertFalse(logs.all.contains { $0.contains("lost") || $0.contains("reconnecting") }, "turning off is not a lost connection: \(logs.all)")
    }

    func testStateShowsTheWaitAndTheReasonUntilAConnectionClearsIt() async throws {
        let socket = FakeRelaySocket()
        let dialer = FakeRelayDialer([.failure(RelayDialError(status: 401, message: "handshake failed")), .success(socket)])
        let sleeper = GateSleeper()
        let clock = RelayClock()
        let client = RelayClient(
            options: RelayClient.Options(url: origin, secret: secret, gatewayPort: 1, pingInterval: 3600),
            dialer: dialer, log: { _ in },
            sleep: { try await sleeper.sleep($0) },
            jitter: { 1.0 }, now: { clock.now }
        )
        XCTAssertEqual(client.state, RelayClient.State())
        let run = Task { await client.run() }
        defer { run.cancel() }
        try await until("the backoff") { client.state.phase == .waiting(until: clock.now.addingTimeInterval(1)) }
        let waiting = client.state
        XCTAssertTrue(waiting.lastError?.contains("refused the relay secret (401)") == true, "\(waiting)")
        XCTAssertFalse(waiting.lastError?.contains(secret) == true)

        sleeper.release()
        try await until("connected") { isConnected(client.state) }
        XCTAssertNil(client.state.lastError, "a connection clears the last failure")
        socket.push(RelayFrame(type: .request, id: 3, payload: head()))
        try await until("one request open") { client.state.inflight == 1 }
    }

    // MARK: host

    func testHostStartsAndStopsTheLoopAndGivesTheLockBack() async throws {
        let dir = try TempDir.make()
        let lockURL = dir.appendingPathComponent("relay.lock")
        let socket = FakeRelaySocket()
        let logs = RelayTests.LogSink()
        let host = RelayHost(log: { logs.add($0) }, dialer: FakeRelayDialer([.success(socket)]), blocker: FakeSleepBlocker())
        XCTAssertFalse(host.status.on)

        host.start(origin: origin, secret: secret, gatewayPort: 1, relayLock: try RelayLock(at: lockURL))
        XCTAssertTrue(host.isOn)
        try await until("connected") { isConnected(host.status.state) }
        XCTAssertEqual(host.status.origin, origin)
        XCTAssertEqual(RelayLock.holder(at: lockURL)?.pid, getpid())

        // A second start while on keeps the running loop and gives its own lock back.
        let spare = dir.appendingPathComponent("spare.lock")
        host.start(origin: origin, secret: secret, gatewayPort: 1, relayLock: try RelayLock(at: spare))
        XCTAssertNil(RelayLock.holder(at: spare))

        host.stop()
        XCTAssertFalse(host.isOn)
        XCTAssertTrue(socket.closed)
        XCTAssertNil(RelayLock.holder(at: lockURL), "off gives the one relay slot back")
        XCTAssertEqual(host.status, RelayHost.Status(on: false, origin: nil, state: RelayClient.State(), awake: false))
        XCTAssertTrue(logs.all.contains("on; agents reach the gateway at https://keysrs-relay.me.workers.dev/<key name> with a client token"), "\(logs.all)")
        XCTAssertEqual(logs.all.last, "off")
        XCTAssertFalse(logs.all.contains { $0.contains(secret) })
        host.stop()   // a second stop is a no-op
        XCTAssertEqual(logs.all.filter { $0 == "off" }.count, 1)
    }

    func testStayAwakeHoldsTheAssertionWhileCallsAreOpenAndForTheLingerAfter() async throws {
        let socket = FakeRelaySocket()
        let blocker = FakeSleepBlocker()
        let logs = RelayTests.LogSink()
        let host = RelayHost(log: { logs.add($0) }, dialer: FakeRelayDialer([.success(socket)]), blocker: blocker, linger: 0.5)
        host.start(origin: origin, secret: secret, gatewayPort: 1, relayLock: try RelayLock(at: try TempDir.make().appendingPathComponent("relay.lock")))
        defer { host.stop() }
        try await until("connected") { isConnected(host.status.state) }

        // Off by default: an open call takes no assertion.
        socket.push(RelayFrame(type: .request, id: 1, payload: head()))
        try await until("one call open") { host.status.state.inflight == 1 }
        host.settle()
        XCTAssertEqual(blocker.begins, 0)

        // Turning it on while a call is open takes it at once, and says so.
        host.setStayAwake(true)
        host.settle()
        XCTAssertTrue(blocker.isHeld)
        XCTAssertTrue(host.status.awake)
        XCTAssertEqual(blocker.reasons, ["Keysrs is relaying a call from a cloud agent"])
        XCTAssertTrue(logs.all.contains("keeping the Mac awake while relayed calls are open"))

        // The call ends: the assertion outlives it by the linger, then goes.
        socket.push(RelayFrame(type: .cancel, id: 1))
        try await until("no call open") { host.status.state.inflight == 0 }
        host.settle()
        XCTAssertTrue(blocker.isHeld, "held through the quiet period")
        // A call within the linger keeps the same assertion.
        socket.push(RelayFrame(type: .request, id: 2, payload: head()))
        try await until("a new call open") { host.status.state.inflight == 1 }
        socket.push(RelayFrame(type: .cancel, id: 2))
        try await until("no call open again") { host.status.state.inflight == 0 }
        try await until("the linger to run out", timeout: 3) { !blocker.isHeld }
        XCTAssertEqual(blocker.begins, 1, "one assertion across both calls")
        XCTAssertEqual(blocker.ends, 1)
        XCTAssertFalse(host.status.awake)
        XCTAssertTrue(logs.all.contains("letting the Mac sleep again: no relayed call for 1 s"), "\(logs.all)")

        // Turning it off, or the relay, lets go at once.
        socket.push(RelayFrame(type: .request, id: 4, payload: head()))
        try await until("held again") { blocker.isHeld }
        host.setStayAwake(false)
        host.settle()
        XCTAssertFalse(blocker.isHeld)
        host.setStayAwake(true)
        host.settle()
        XCTAssertTrue(blocker.isHeld)
        host.stop()
        host.settle()
        XCTAssertFalse(blocker.isHeld, "a relay that is off keeps nothing awake")
    }

    // MARK: service and API

    private func gatedService() throws -> (KeysService, RecordingPresenceGate) {
        let (db, _) = try makeDB()
        return makeGatedService(db: db)
    }

    func testTurningTheRelayOnRefusesWhatItCanBeforeTouchID() throws {
        let (service, gate) = try gatedService()
        let socket = FakeRelaySocket()
        service.relayHost = RelayHost(log: { _ in }, dialer: FakeRelayDialer([.success(socket)]), blocker: FakeSleepBlocker())

        XCTAssertThrowsError(try service.setRelay(enabled: true)) { error in
            XCTAssertTrue("\(error)".contains("no relay is set up"), "\(error)")
        }
        XCTAssertEqual(gate.reasons, [])
        _ = try service.setupRelay(url: origin.absoluteString)
        let afterSetup = gate.reasons.count

        XCTAssertThrowsError(try service.setRelay(enabled: true)) { error in
            XCTAssertTrue("\(error)".contains("gateway is not running"), "\(error)")
        }
        _ = try service.startGateway(port: 0)
        defer { service.stopGateway() }

        // keys relay in a Terminal holds the one relay this Mac may run.
        let terminal = try RelayLock(at: service.relayLockURL)
        XCTAssertEqual(service.relayReport().elsewhere, RelayLock.Held(pid: getpid()))
        XCTAssertThrowsError(try service.setRelay(enabled: true)) { error in
            XCTAssertTrue("\(error)".contains("keys relay is already running on this Mac"), "\(error)")
        }
        XCTAssertEqual(gate.reasons.count, afterSetup, "nothing above asked for Touch ID")
        terminal.release()

        let report = try service.setRelay(enabled: true)
        XCTAssertEqual(gate.reasons.last, "connect the relay to keysrs-relay.me.workers.dev")
        XCTAssertEqual(gate.reasons.count, afterSetup + 1)
        XCTAssertTrue(report.host.on)
        XCTAssertNil(report.elsewhere)
        XCTAssertEqual(report.url, origin)
        XCTAssertEqual(RelayLock.holder(at: service.relayLockURL)?.pid, getpid())

        _ = try service.setRelay(enabled: true)
        XCTAssertEqual(gate.reasons.count, afterSetup + 1, "already on asks for nothing")

        let off = try service.setRelay(enabled: false)
        XCTAssertFalse(off.host.on)
        XCTAssertTrue(socket.closed)
        XCTAssertNil(RelayLock.holder(at: service.relayLockURL))
    }

    func testCancelledTouchIDLeavesTheRelayOffAndTheLockFree() throws {
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let (service, _) = makeGatedService(db: db, gate: gate)
        service.relayHost = RelayHost(log: { _ in }, dialer: FakeRelayDialer([]), blocker: FakeSleepBlocker())
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer { service.stopGateway() }
        gate.error = .authCancelled
        XCTAssertThrowsError(try service.setRelay(enabled: true)) { error in
            guard case AppError.authCancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(service.relayHost.isOn)
        XCTAssertNil(RelayLock.holder(at: service.relayLockURL))
    }

    private func call(_ handler: APIHandler, _ method: String, body: [String: Any]? = nil, token: String? = nil) throws -> (Int, [String: Any]) {
        var headers = ["host": "127.0.0.1:12765"]
        if let token { headers["x-ksf-token"] = token }
        let response = handler.handle(HTTPRequest(
            method: method, path: "/api/relay", query: [:], headers: headers,
            body: try body.map(JSONValue.data) ?? Data(), serverPort: 12765
        ))
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return (response.status, object)
    }

    func testRelayRoutesReportStateAndTakeOnlyTheTwoSwitchesWithTheToken() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let socket = FakeRelaySocket()
        service.relayHost = RelayHost(log: { _ in }, dialer: FakeRelayDialer([.success(socket)]), blocker: FakeSleepBlocker())
        let handler = APIHandler(service: service, webRoot: dir)
        let token = handler.originToken

        var (status, obj) = try call(handler, "GET")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(obj["configured"] as? Bool, false)
        XCTAssertEqual(obj["on"] as? Bool, false)
        XCTAssertEqual(obj["state"] as? String, "off")
        XCTAssertEqual(obj["stay_awake"] as? Bool, false, "off by default")
        XCTAssertTrue(obj["url"] is NSNull)
        XCTAssertEqual(obj["elsewhere"] as? Bool, false)

        (status, _) = try call(handler, "POST", body: ["enabled": true])
        XCTAssertEqual(status, 403, "the page token gates it like every other change")
        for bad: [String: Any] in [[:], ["enabled": "yes"], ["enabled": true, "url": "https://evil.example"], ["stay_awake": NSNull()]] {
            (status, _) = try call(handler, "POST", body: bad, token: token)
            XCTAssertEqual(status, 400, "\(bad)")
        }
        (status, obj) = try call(handler, "POST", body: ["enabled": true], token: token)
        XCTAssertEqual(status, 400)
        XCTAssertTrue((obj["error"] as? String)?.contains("no relay is set up") == true, "\(obj)")

        (status, obj) = try call(handler, "POST", body: ["stay_awake": true], token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(obj["stay_awake"] as? Bool, true)
        XCTAssertTrue(service.preferences.relayStayAwake, "stored for the next time it is on")

        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer { service.stopGateway() }
        (status, obj) = try call(handler, "POST", body: ["enabled": true], token: token)
        XCTAssertEqual(status, 200, "\(obj)")
        XCTAssertEqual(obj["on"] as? Bool, true)
        XCTAssertEqual(obj["url"] as? String, origin.absoluteString)
        XCTAssertEqual(gate.reasons.last, "connect the relay to keysrs-relay.me.workers.dev")
        let deadline = Date().addingTimeInterval(5)
        while (try call(handler, "GET").1["state"] as? String) != "connected", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        (_, obj) = try call(handler, "GET")
        XCTAssertEqual(obj["state"] as? String, "connected")
        XCTAssertNotNil(UTC.parse(obj["connected_since"] as? String ?? ""))
        XCTAssertEqual(obj["inflight"] as? Int, 0)
        let text = String(data: try JSONValue.data(obj), encoding: .utf8)!
        XCTAssertFalse(text.contains("ksfr_"), "no secret and no hint on the wire")

        (status, obj) = try call(handler, "POST", body: ["enabled": false], token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(obj["on"] as? Bool, false)
        XCTAssertTrue(socket.closed)
    }

    func testMenuLineSaysWhereTheRelayStands() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        func report(on: Bool, phase: RelayClient.Phase = .stopped, inflight: Int = 0, awake: Bool = false, elsewhere: RelayLock.Held? = nil) -> KeysService.RelayReport {
            KeysService.RelayReport(
                configured: true, url: origin,
                host: RelayHost.Status(on: on, origin: on ? origin : nil, state: RelayClient.State(phase: phase, inflight: inflight), awake: awake),
                elsewhere: elsewhere, stayAwake: awake
            )
        }
        XCTAssertEqual(MenubarExtra.relayLine(report(on: false)), "")
        XCTAssertEqual(MenubarExtra.relayLine(report(on: false, elsewhere: .init(pid: 4242))), "keys relay is running in a Terminal (process 4242)")
        XCTAssertEqual(MenubarExtra.relayLine(report(on: true, phase: .connecting)), "Connecting to keysrs-relay.me.workers.dev…")
        XCTAssertEqual(MenubarExtra.relayLine(report(on: true, phase: .connected(since: since))), "Connected to keysrs-relay.me.workers.dev")
        XCTAssertEqual(
            MenubarExtra.relayLine(report(on: true, phase: .connected(since: since), inflight: 2, awake: true)),
            "Connected to keysrs-relay.me.workers.dev · 2 calls open · keeping the Mac awake"
        )
        XCTAssertEqual(MenubarExtra.relayLine(report(on: true, phase: .waiting(until: since))), "Not connected; retrying")
    }
}
