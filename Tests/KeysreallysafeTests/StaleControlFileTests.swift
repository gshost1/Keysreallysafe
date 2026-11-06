import Darwin
import Foundation
import XCTest
@testable import KeysCore

/// A live Keysrs-shaped process that is not this one and listens on nothing: a
/// copy of `/bin/sleep` named `keys`, which `proc_pidpath` reports as a `keys`
/// binary. It stands in for a site `ControlFile.live` counts (or a stale pid
/// recycled into a same-user `keys mcp`), never for one a client may talk to: it
/// holds no listener. Stopped when the test ends.
enum KeysrsStandIn {
    static func start(_ test: XCTestCase) throws -> Process {
        let dir = try TempDir.make()
        let binary = dir.appendingPathComponent("keys")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        test.addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        return process
    }

    /// A `keys` process that holds a listener on 127.0.0.1 and never answers: a copy
    /// of perl named `keys` that binds an ephemeral port, prints it, and sleeps with
    /// the connections left in its backlog. It is what a hung Keysrs looks like from
    /// outside, a site that `ControlFile.serving` proves and that answers nothing.
    static func startListening(_ test: XCTestCase) throws -> (process: Process, port: UInt16) {
        let dir = try TempDir.make()
        let binary = dir.appendingPathComponent("keys")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/perl"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-e", """
            use Socket; socket(S, PF_INET, SOCK_STREAM, 0) or die; \
            bind(S, sockaddr_in(0, inet_aton("127.0.0.1"))) or die; listen(S, 16) or die; \
            my ($p) = sockaddr_in(getsockname(S)); $| = 1; print "$p\\n"; sleep 60
            """]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        test.addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw AppError.http("the listening stand-in exited") }
            line.append(chunk)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(text) else { throw AppError.http("the listening stand-in printed \(text)") }
        return (process, port)
    }
}

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
        let site = try KeysrsStandIn.start(self).processIdentifier
        try ControlFile.write(port: 12_766, token: "dummy", pid: site, to: control)
        XCTAssertEqual(ControlFile.live(at: control)?.pid, site)
    }

    /// The plain control client every other command uses (keys unwrap, share,
    /// edit, quit): a live same-user Keysrs pid that does not hold the recorded
    /// port is not a site to send the token to.
    func testThePlainClientRefusesAPortTheKeysrsPidDoesNotHold() throws {
        let (_, control) = try world()
        let (server, log) = try squatter()
        let recycled = try KeysrsStandIn.start(self).processIdentifier
        try ControlFile.write(port: server.boundPort, token: "dummy", pid: recycled, to: control)

        XCTAssertNotNil(ControlFile.live(at: control), "a Keysrs process is up")
        XCTAssertNil(ControlFile.serving(at: control), "but it does not serve the file's port")
        XCTAssertThrowsError(try ControlClient.connect(control: control)) { error in
            guard case .siteUnavailable? = error as? AppError else { return XCTFail("got \(error)") }
        }
        assertSentNothing(log)
    }

    /// The positive half: the process holding the listener is the site.
    func testTheProcessHoldingTheListenerIsTheSite() throws {
        let (_, control) = try world()
        let (server, _) = try squatter()
        try ControlFile.write(port: server.boundPort, token: "dummy", to: control)
        XCTAssertEqual(ControlFile.serving(at: control)?.port, server.boundPort)
        server.stop()
        XCTAssertNil(ControlFile.serving(at: control), "a closed listener is no site")
    }

    /// The production shape: another `keys` process of this user holding the
    /// file's listener is the site.
    func testAKeysrsProcessHoldingTheListenerIsTheSite() throws {
        let (_, control) = try world()
        let site = try KeysrsStandIn.startListening(self)
        try ControlFile.write(port: site.port, token: "dummy", pid: site.process.processIdentifier, to: control)
        XCTAssertEqual(ControlFile.serving(at: control)?.pid, site.process.processIdentifier)
        XCTAssertNoThrow(try ControlClient.connect(control: control))
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
        let recycled = try KeysrsStandIn.start(self).processIdentifier
        try ControlFile.write(port: server.boundPort, token: "dummy", pid: recycled, to: control)

        let (error, launch) = try runWrap(control: control, dir: dir)

        assertSentNothing(log)
        XCTAssertFalse(launch.launchTargets.isEmpty, "an unproven site is not a running app, so the seam launches")
        guard case .siteUnavailable? = error as? AppError else {
            return XCTFail("expected the not-running exit, got \(String(describing: error))")
        }
    }
}
