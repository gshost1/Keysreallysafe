import Foundation
import XCTest
@testable import KeysCore

/// `keys relay reset` forgets the Worker URL and the Keychain secret. The relay that
/// is already running keeps its secret in memory for the life of its process, so a
/// reset has to account for it: refuse while a Terminal `keys relay` holds the lock,
/// and turn the app's relay off first — including when the status read fails, which
/// used to read as "not on".
final class RelayResetTests: XCTestCase {
    private let origin = "https://keysrs-relay.me.workers.dev"

    /// A service with a relay configured, over a temp catalog, and the control URL
    /// beside it (guarded before anything is written).
    private func rig() throws -> (service: KeysService, db: CatalogDB, dir: URL, control: URL) {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        try AppConnectionIsolationGuard.assertIsolated(control: ControlFile.url(beside: db.path))
        _ = try service.setupRelay(url: origin)
        return (service, db, dir, ControlFile.url(beside: db.path))
    }

    /// A live process that this process is not: a copy of `sleep` named `keys`, so a
    /// control file naming it reads as a running site.
    private func liveSite() throws -> pid_t {
        let dir = try TempDir.make()
        let binary = dir.appendingPathComponent("keys")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        return process.processIdentifier
    }

    /// A site stub answering GET /api/relay with the given body, and recording a POST.
    private func stub(on: Bool) throws -> (server: LoopbackHTTPServer, log: RequestLog) {
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            if request.method == "POST" { return HTTPResponse.json(200, ["on": false]) }
            return HTTPResponse.json(200, ["on": on, "state": on ? "connected" : "off", "configured": true])
        }
        server.start()
        addTeardownBlock { server.stop() }
        return (server, log)
    }

    /// A relay started in a Terminal holds the secret it dials with; deleting the
    /// Keychain item under it would leave that process running with a credential the
    /// Mac no longer has. Reset refuses and names the process instead.
    func testResetRefusesWhileATerminalRelayHoldsTheLock() throws {
        let rig = try rig()
        let app = try liveSite()
        try ControlFile.write(port: 12_766, token: "app", pid: app, to: rig.control)
        // The lock held by this process while the control file names another one is a
        // Terminal relay as `RelayLock.Held.isApp` defines it.
        let lock = try RelayLock(at: rig.service.relayLockURL)
        defer { lock.release() }

        var printed: [String] = []
        XCTAssertThrowsError(try RelayResetCommand.run(service: rig.service, out: { printed.append($0) })) { error in
            guard let appError = error as? AppError, case .usage(let message) = appError else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("keys relay is running"), message)
            XCTAssertTrue(message.contains("Ctrl-C"), message)
            XCTAssertFalse(message.contains("app"), "the control token never reaches the message: \(message)")
        }
        XCTAssertEqual(printed, [], "a refused reset prints nothing and changes nothing")
        XCTAssertEqual(rig.service.relayStatus().url?.absoluteString, origin, "the relay stays configured")
        XCTAssertNotNil(rig.service.relayStatus().secretHint)
    }

    /// The same Terminal relay, with no site reachable. The lock is the only evidence of
    /// that relay, and gating the check on a live site skipped it: reset deleted the
    /// secret while the Terminal's `keys relay` kept dialing with the copy in memory.
    func testResetRefusesATerminalRelayEvenWithNoSiteReachable() throws {
        let rig = try rig()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.control.path), "no site answers")
        let lock = try RelayLock(at: rig.service.relayLockURL)
        defer { lock.release() }

        var printed: [String] = []
        XCTAssertThrowsError(try RelayResetCommand.run(service: rig.service, out: { printed.append($0) })) { error in
            guard let appError = error as? AppError, case .usage(let message) = appError else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("Ctrl-C"), message)
        }
        XCTAssertEqual(printed, [])
        XCTAssertEqual(rig.service.relayStatus().url?.absoluteString, origin, "the relay stays configured")
        XCTAssertNotNil(rig.service.relayStatus().secretHint, "the running relay keeps the secret it dials with")
    }

    /// The app's relay is on: reset turns it off before forgetting the secret, or the
    /// app would keep dialing with a secret that no longer exists.
    func testResetTurnsTheAppsRelayOffFirst() throws {
        let rig = try rig()
        let (server, log) = try stub(on: true)
        try ControlFile.write(port: server.boundPort, token: "app-token", to: rig.control)
        // The app's relay holds the lock under the pid the control file names.
        let lock = try RelayLock(at: rig.service.relayLockURL)
        defer { lock.release() }

        var printed: [String] = []
        try RelayResetCommand.run(service: rig.service, out: { printed.append($0) })

        XCTAssertEqual(log.all.filter { $0.path == "/api/relay" }.map(\.method), ["GET", "POST"],
                       "the off POST follows the status read")
        XCTAssertEqual(printed.first, "turned off the relay in Keysrs")
        XCTAssertEqual(printed.count, 2, "then the Cloudflare-side reminder")
        XCTAssertNil(rig.service.relayStatus().url)
        XCTAssertNil(rig.service.relayStatus().secretHint)
    }

    /// The status read fails against a live site. Before the fix that read as "not on",
    /// the secret was deleted and the app kept running with it; now the reset fails and
    /// changes nothing, so the relay and the stored secret stay consistent.
    func testAFailedStatusReadFailsTheResetInsteadOfSkippingTheOff() throws {
        let rig = try rig()
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            if request.path == "/api/relay" { return HTTPResponse.json(500, ["error": "wedged"]) }
            return HTTPResponse.json(200, [:])
        }
        server.start()
        addTeardownBlock { server.stop() }
        try ControlFile.write(port: server.boundPort, token: "app-token", to: rig.control)

        XCTAssertThrowsError(try RelayResetCommand.run(service: rig.service, out: { _ in })) { error in
            XCTAssertTrue("\(error)".contains("wedged") || (error as? AppError) != nil, "\(error)")
        }
        XCTAssertEqual(log.all.filter { $0.path == "/api/relay" }.map(\.method), ["GET"],
                       "no off was posted, and nothing was forgotten")
        XCTAssertEqual(rig.service.relayStatus().url?.absoluteString, origin)
        XCTAssertNotNil(rig.service.relayStatus().secretHint, "the secret is still there for the running relay")
    }

    /// A Keysrs process that does not answer at all is still a site that may be running
    /// the relay: reset refuses rather than delete the secret under it. The stand-in
    /// holds the file's listener, as a hung app does; a `keys` pid that does not is a
    /// recycled one, and its port belongs to someone else.
    func testAKeysrsProcessThatDoesNotAnswerRefusesTheReset() throws {
        let rig = try rig()
        let silent = try KeysrsStandIn.startListening(self)
        try ControlFile.write(port: silent.port, token: "app-token", pid: silent.process.processIdentifier, to: rig.control)

        XCTAssertThrowsError(try RelayResetCommand.run(service: rig.service, out: { _ in })) { error in
            XCTAssertTrue("\(error)".contains("did not answer"), "\(error)")
        }
        XCTAssertNotNil(rig.service.relayStatus().secretHint, "the secret stays")
    }

    /// The app crashed and its pid now belongs to some other program: the control file
    /// is stale, there is no site, and the reset goes ahead instead of failing forever.
    func testAStaleControlFileFromARecycledPidDoesNotBlockTheReset() throws {
        let rig = try rig()
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        addTeardownBlock { if other.isRunning { other.terminate() }; other.waitUntilExit() }
        let closed = try LoopbackHTTPServer(port: 0) { _ in HTTPResponse.json(200, [:]) }
        let port = closed.boundPort
        closed.stop()
        try ControlFile.write(port: port, token: "app-token", pid: other.processIdentifier, to: rig.control)

        try RelayResetCommand.run(service: rig.service, out: { _ in })
        XCTAssertNil(rig.service.relayStatus().url, "forgotten")
        XCTAssertNil(rig.service.relayStatus().secretHint)
    }

    /// With no site up at all there is no in-memory relay to stop: the reset proceeds
    /// and forgets both the URL and the hint.
    func testResetWithNoSiteForgetsTheConfiguration() throws {
        let rig = try rig()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.control.path))
        var printed: [String] = []
        try RelayResetCommand.run(service: rig.service, out: { printed.append($0) })
        XCTAssertNil(rig.service.relayStatus().url)
        XCTAssertNil(rig.service.relayStatus().secretHint)
        XCTAssertEqual(printed.count, 1, "the Cloudflare-side reminder")
    }
}
