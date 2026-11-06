import Darwin
import Foundation
import XCTest
@testable import KeysCore

/// A control.json left behind by a crash, SIGKILL or power loss keeps the dead
/// app's port and pid. Its pid can be recycled — by a process of another account,
/// by any process of this one — and its port can be bound by anyone while Keysrs
/// is down. `keys wrap` sends every candidate's raw value to that port, so the
/// client may treat the file as live only when its pid is a Keysrs binary of this
/// user AND that process holds the recorded loopback listener. A listener that
/// proves neither must receive nothing: no body, no token, no probe.
final class StaleControlFileTests: XCTestCase {

    /// A dummy provider-shaped value: never a real key.
    private static let dummyValue = "sk-proj-" + String(repeating: "x", count: 48)

    /// A live Keysrs-shaped process that is not this one and listens on nothing: a
    /// copy of `/bin/sleep` named `keys`, which `proc_pidpath` reports as a `keys`
    /// binary — what a stale file's pid looks like when it is recycled into a
    /// same-user `keys mcp` or `keys grant`.
    private func keysNamedSleeper() throws -> Process {
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
        return process
    }

    /// A same-user process that is not Keysrs at all.
    private func plainSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        return process
    }

    /// The squatter: a loopback listener that records every request and refuses it.
    private func squatter() throws -> (server: LoopbackHTTPServer, log: RequestLog) {
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return .json(403, ["error": "forbidden"])
        }
        server.start()
        addTeardownBlock { server.stop() }
        return (server, log)
    }

    private func world() throws -> (dir: URL, control: URL) {
        let world = try AppConnectionIsolationGuard.makeWorld()
        try AppConnectionIsolationGuard.assertIsolated(control: world.control)
        return (world.dir, world.control)
    }

    /// Runs `keys wrap`'s runner over a temp env file holding one dummy value,
    /// connected through the one app seam with a recording launcher that opens
    /// nothing and a clock that never sleeps.
    private func runWrap(control: URL, dir: URL) throws -> (error: Error?, launch: RecordingAppLaunch) {
        let launch = RecordingAppLaunch()
        let seam = launch.seam
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: seam)
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(".env")
        try Data("OPENAI_API_KEY=\(Self.dummyValue)\n".utf8).write(to: file)
        let runner = WrapRunner(
            backend: ControlWrapBackend(connect: { try AppConnection.connect(control: control, launch: seam).controlClient }),
            out: { _ in },
            confirm: { true }
        )
        var options = WrapRunner.Options(file: file)
        options.yes = true
        options.backupRoot = EnvFileWriter.backupsRoot(beside: dir.appendingPathComponent("catalog.db"))
        do {
            _ = try runner.run(options)
            return (nil, launch)
        } catch {
            return (error, launch)
        }
    }

    private func assertSentNothing(_ log: RequestLog, file: StaticString = #filePath, line: UInt = #line) {
        let paths = log.all.map(\.path)
        XCTAssertEqual(paths, [], "the unproven listener received requests", file: file, line: line)
        for request in log.all {
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(Self.dummyValue),
                           "the dummy value reached the unproven listener", file: file, line: line)
        }
    }

    // MARK: - Liveness

    /// pid 1 is launchd, owned by root: kill(1, 0) answers EPERM, which the old
    /// check counted as alive.
    func testAnotherUsersPidIsNotALiveSite() throws {
        let (_, control) = try world()
        try ControlFile.write(port: 12_766, token: "dummy", pid: 1, to: control)
        XCTAssertNil(ControlFile.live(at: control), "a pid of another user is not this user's Keysrs")
    }

    /// A same-user process that is not a Keysrs binary: the recycled-pid case.
    func testALiveNonKeysrsPidIsNotALiveSite() throws {
        let (_, control) = try world()
        let stranger = try plainSleeper().processIdentifier
        try ControlFile.write(port: 12_766, token: "dummy", pid: stranger, to: control)
        XCTAssertNil(ControlFile.live(at: control), "a live pid running something else leaves the file stale")
    }

    /// The positive half: a same-user Keysrs binary still counts, so the
    /// ownership and relay checks that lean on `live` keep their meaning.
    func testASameUserKeysrsBinaryIsALiveSite() throws {
        let (_, control) = try world()
        let site = try keysNamedSleeper().processIdentifier
        try ControlFile.write(port: 12_766, token: "dummy", pid: site, to: control)
        XCTAssertEqual(ControlFile.live(at: control)?.pid, site)
    }

    // MARK: - keys wrap over a stale file

    /// The lead's local check: a stale file whose pid is another user's process,
    /// pointing at a squatted port. Before the fix the seam took its fast path and
    /// POSTed /api/wrap with the dummy value to the squatter.
    func testWrapSendsNothingToAStaleFileWithAForeignPid() throws {
        let (dir, control) = try world()
        let (server, log) = try squatter()
        try ControlFile.write(port: server.boundPort, token: "dummy", pid: 1, to: control)

        let (error, launch) = try runWrap(control: control, dir: dir)

        assertSentNothing(log)
        XCTAssertFalse(launch.launchTargets.isEmpty, "the stale file is not a running app, so the seam launches")
        guard case .siteUnavailable? = error as? AppError else {
            return XCTFail("expected the not-running exit, got \(String(describing: error))")
        }
    }

    /// The pid is a same-user Keysrs binary (a recycled `keys mcp`, say), but it
    /// holds no listener on the recorded port: whatever answers there is someone
    /// else, and it must not receive the values.
    func testWrapSendsNothingToAPortTheKeysrsPidDoesNotHold() throws {
        let (dir, control) = try world()
        let (server, log) = try squatter()
        let recycled = try keysNamedSleeper().processIdentifier
        try ControlFile.write(port: server.boundPort, token: "dummy", pid: recycled, to: control)

        let (error, launch) = try runWrap(control: control, dir: dir)

        assertSentNothing(log)
        XCTAssertFalse(launch.launchTargets.isEmpty, "an unproven site is not a running app, so the seam launches")
        guard case .siteUnavailable? = error as? AppError else {
            return XCTFail("expected the not-running exit, got \(String(describing: error))")
        }
    }
}
