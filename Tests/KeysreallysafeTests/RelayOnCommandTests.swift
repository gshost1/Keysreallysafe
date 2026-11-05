import Foundation
import XCTest
@testable import KeysCore

/// `keys relay on` watches the first dial for ten seconds, then prints the state it
/// read. The sentence after it has to agree with that state: it used to promise the
/// relay "stays on" even when the printout said `off`, and a dial still connecting at
/// the deadline printed nothing about timing out.
final class RelayOnCommandTests: XCTestCase {

    /// A site stub that answers the POST, then scripts the GET bodies in order (the last
    /// one repeats), recording every request so the poll is visible.
    private func site(_ states: [[String: Any]]) throws -> (server: LoopbackHTTPServer, log: RequestLog) {
        let log = RequestLog()
        let script = ScriptedStates(states)
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            if request.method == "POST" { return HTTPResponse.json(200, script.first) }
            return HTTPResponse.json(200, script.next())
        }
        server.start()
        addTeardownBlock { server.stop() }
        return (server, log)
    }

    private func drive(
        states: [[String: Any]], budget: TimeInterval = 10
    ) throws -> (printed: [String], log: RequestLog) {
        let (server, log) = try site(states)
        let dir = try TempDir.make()
        let control = ControlFile.url(beside: dir.appendingPathComponent("catalog.db"))
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        try ControlFile.write(port: server.boundPort, token: "app-token", to: control)

        let command = try XCTUnwrap(try KeysCLI.parseAsRoot(["relay", "on"]) as? RelayOnCommand)
        var printed: [String] = []
        // A clock that only advances when the command sleeps, so the budget is spent by
        // the poll steps and the test never waits on wall time.
        let clock = SteppingClock()
        try command.run(
            launch: .neverLaunching, control: control, budget: budget,
            sleep: { clock.advance($0) }, now: { clock.now },
            out: { printed.append($0) }
        )
        return (printed, log)
    }

    /// Wall-free time: `sleep` is the only thing that moves it.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ interval: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    /// A status that says the relay is off gets a sentence about it being off. Before
    /// the fix the line read "relay off; it stays on until keys relay off …".
    func testAStatusThatSaysOffNeverPromisesItStaysOn() throws {
        let (printed, _) = try drive(states: [
            ["on": false, "state": "off"],
        ])
        XCTAssertEqual(printed.count, 1)
        let line = try XCTUnwrap(printed.first)
        XCTAssertTrue(line.hasPrefix("relay off"), line)
        XCTAssertFalse(line.contains("it stays on"), "the promise contradicted the state: \(line)")
        XCTAssertTrue(line.contains("nothing is relaying"), line)
    }

    /// A connected dial keeps the original sentence.
    func testAConnectedRelayKeepsTheStaysOnSentence() throws {
        let (printed, log) = try drive(states: [
            ["on": true, "state": "connected", "connected_since": "2026-11-04T12:00:00Z", "url": "https://w.me.workers.dev"],
        ])
        let line = try XCTUnwrap(printed.first)
        XCTAssertTrue(line.hasPrefix("relay on, connected to w.me.workers.dev"), line)
        XCTAssertTrue(line.contains("it stays on until keys relay off"), line)
        XCTAssertEqual(log.all.map(\.method), ["POST"], "a connected first answer needs no poll")
    }

    /// Still connecting when the budget runs out: the loop stops, and the sentence says
    /// the first dial did not finish rather than leaving the reader to guess.
    func testADialThatOutlastsTheBudgetSaysSo() throws {
        let (printed, log) = try drive(states: [
            ["on": true, "state": "connecting", "url": "https://w.me.workers.dev"],
        ])
        let line = try XCTUnwrap(printed.first)
        XCTAssertTrue(line.hasPrefix("relay on, connecting to w.me.workers.dev"), line)
        XCTAssertTrue(line.contains("has not finished"), "the timeout is named: \(line)")
        XCTAssertTrue(line.contains("it stays on until keys relay off"), "a relay mid-dial is still on: \(line)")
        XCTAssertGreaterThanOrEqual(log.all.count, 2, "it polled before giving up")
    }

    /// A waiting phase (a failed dial, then backoff) ends the poll immediately, because
    /// only "connecting" means the first dial is unresolved.
    func testAWaitingPhaseEndsThePollAndReportsTheBackoff() throws {
        let (printed, log) = try drive(states: [
            ["on": true, "state": "waiting", "last_error": "the Worker refused the relay secret (401)",
             "url": "https://w.me.workers.dev"],
        ])
        let line = try XCTUnwrap(printed.first)
        XCTAssertTrue(line.contains("not connected; retrying"), line)
        XCTAssertTrue(line.contains("refused the relay secret"), line)
        XCTAssertFalse(line.contains("has not finished"), "waiting is resolved, not a timeout: \(line)")
        XCTAssertEqual(log.all.map(\.method), ["POST"])
    }
}

/// Hands out the scripted bodies in order, repeating the last; guarded because the site
/// answers on the listener's threads.
private final class ScriptedStates: @unchecked Sendable {
    private let lock = NSLock()
    private let states: [[String: Any]]
    private var index = 0

    init(_ states: [[String: Any]]) { self.states = states }

    var first: [String: Any] { states.first ?? [:] }

    func next() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let state = states[min(index, states.count - 1)]
        index += 1
        return state
    }
}
