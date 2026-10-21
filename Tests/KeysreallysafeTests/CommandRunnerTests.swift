import Darwin
import XCTest
@testable import KeysCore

/// The launcher behind `keys env`, `keys agent` and `keys tunnel`. These run real children
/// (/bin/sh) and signal this test process; the runner puts its handlers back after each run.
final class CommandRunnerTests: XCTestCase {
    private let runner = SpawnCommandRunner(restoresHandlers: true)

    func testChildStaysInTheCallersProcessGroup() throws {
        let out = try TempDir.make().appendingPathComponent("pgid")
        let ended = try runner.run(argv: ["/bin/sh", "-c", #"ps -o pgid= -p $$ > "$1""#, "sh", out.path], extraEnv: [:])
        XCTAssertEqual(ended, .exited(0))
        let pgid = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // The terminal sends Ctrl-C to its foreground group; a child in a group of its own
        // never got it, and a coding agent was stopped by SIGTTOU when it set up the terminal.
        XCTAssertEqual(pgid, String(getpgrp()))
    }

    func testSignalsSentToKeysAlonePassOnToTheChild() throws {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // From the default, as in a terminal: an ignore inherited by this test process
            // (nohup) would rightly reach the child and keep its trap from firing.
            try with(sig, at: SIG_DFL) {
                let out = try TempDir.make().appendingPathComponent("got")
                // The child is the shell itself (env execs it), so $PPID is this test process.
                let script = """
                    trap 'echo got > "$1"; exit 0' \(sig)
                    kill -\(sig) $PPID
                    i=0; while [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
                    exit 3
                    """
                let ended = try runner.run(argv: ["/bin/sh", "-c", script, "sh", out.path], extraEnv: [:])
                XCTAssertEqual(ended, .exited(0), "signal \(sig)")
                XCTAssertEqual(try? String(contentsOf: out, encoding: .utf8), "got\n", "signal \(sig)")
            }
        }
    }

    func testChildStartsWithTheSignalsKeysCatchesAtTheirDefault() throws {
        // keys holds handlers for these while the child runs; the child must still die of them.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            try with(sig, at: SIG_DFL) {
                let ended = try runner.run(argv: ["/bin/sh", "-c", "kill -\(sig) $$; sleep 5; exit 0"], extraEnv: [:])
                XCTAssertEqual(ended, .signaled(sig), "signal \(sig)")
                XCTAssertEqual(ended.status, 128 + sig)
            }
        }
    }

    func testAnInheritedIgnoreReachesTheChild() throws {
        // nohup keys env …: the command must outlive the terminal as it would without keys.
        try with(SIGHUP, at: SIG_IGN) {
            let ended = try runner.run(argv: ["/bin/sh", "-c", "kill -HUP $$; exit 0"], extraEnv: [:])
            XCTAssertEqual(ended, .exited(0))
        }
    }

    func testOnlyTheStandardDescriptorsReachTheChild() throws {
        let file = try TempDir.make().appendingPathComponent("held")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let fd = open(file.path, O_RDONLY)
        XCTAssertGreaterThan(fd, STDERR_FILENO)
        defer { close(fd) }
        let ended = try runner.run(argv: ["/bin/sh", "-c", #"[ -e /dev/fd/$1 ] && exit 1; [ -e /dev/fd/2 ] || exit 2; exit 0"#, "sh", String(fd)], extraEnv: [:])
        XCTAssertEqual(ended, .exited(0))
    }

    func testHandlersArePutBackWhenAsked() throws {
        func handlers() -> [Int] {
            ChildSignals.caught.map { sig in
                var current = sigaction()
                sigaction(sig, nil, &current)
                return current.__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: Int.self) } ?? 0
            }
        }
        let before = handlers()
        _ = try runner.run(argv: ["/usr/bin/true"], extraEnv: [:])
        XCTAssertEqual(handlers(), before)
    }

    func testMissingCommandIsTheChildsExit127() throws {
        XCTAssertEqual(try runner.run(argv: ["krs-no-such-command"], extraEnv: [:]), .exited(127))
        XCTAssertThrowsError(try runner.run(argv: [], extraEnv: [:]))
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(ChildExit(waitStatus: 0), .exited(0))
        XCTAssertEqual(ChildExit(waitStatus: 7 << 8), .exited(7))
        XCTAssertEqual(ChildExit(waitStatus: SIGINT), .signaled(SIGINT))
        XCTAssertEqual(ChildExit(waitStatus: SIGKILL | 0x80), .signaled(SIGKILL))
        XCTAssertEqual(ChildExit.exited(7).status, 7)
        XCTAssertEqual(ChildExit.signaled(SIGINT).status, 130)
        XCTAssertEqual(ChildExit.signaled(SIGTERM).status, 143)
    }

    func testKeyboardSignalsAreNotSentTwice() {
        // The terminal delivered Ctrl-C to the whole foreground group, child included.
        XCTAssertTrue(ChildSignals.childAlreadyHasIt(SIGINT, childInForeground: true, sender: .otherSession))
        XCTAssertTrue(ChildSignals.childAlreadyHasIt(SIGQUIT, childInForeground: true, sender: .kernel))
        // A process in this session (a batch runner) or a kill(1) that already exited meant keys alone.
        XCTAssertFalse(ChildSignals.childAlreadyHasIt(SIGINT, childInForeground: true, sender: .sameSession))
        XCTAssertFalse(ChildSignals.childAlreadyHasIt(SIGINT, childInForeground: true, sender: .gone))
        // keys is not the terminal's foreground group, or the child made a group of its own:
        // no keystroke can have reached the child.
        XCTAssertFalse(ChildSignals.childAlreadyHasIt(SIGINT, childInForeground: false, sender: .otherSession))
        // The terminal never sends TERM; a hangup's HUP sent twice does no harm.
        XCTAssertFalse(ChildSignals.childAlreadyHasIt(SIGTERM, childInForeground: true, sender: .otherSession))
        XCTAssertFalse(ChildSignals.childAlreadyHasIt(SIGHUP, childInForeground: true, sender: .kernel))
    }

    func testAgentGrantIsRevokedWhenTheAgentDiesOfASignal() throws {
        let fake = FakeCommandRunner()
        fake.exit = .signaled(SIGINT)
        var revoked = 0
        let ended = try AgentCommand.launch(runner: fake, argv: ["claude"], env: ["ANTHROPIC_API_KEY": "ksf_x"]) {
            revoked += 1
        }
        XCTAssertEqual(ended, .signaled(SIGINT))
        XCTAssertEqual(revoked, 1)
        XCTAssertEqual(fake.lastArgv, ["claude"])
    }

    func testAgentGrantIsRevokedWhenTheAgentCannotStart() {
        let fake = FakeCommandRunner()
        fake.error = AppError.usage("could not run command")
        var revoked = 0
        XCTAssertThrowsError(try AgentCommand.launch(runner: fake, argv: ["codex"], env: [:]) { revoked += 1 })
        XCTAssertEqual(revoked, 1)
    }

    /// Runs `body` with `sig` at `handler` whatever this test process inherited, then puts the
    /// whole previous action back, which `signal` would not.
    private func with(_ sig: Int32, at handler: sig_t?, _ body: () throws -> Void) rethrows {
        var action = sigaction(), previous = sigaction()
        action.__sigaction_u.__sa_handler = handler
        sigemptyset(&action.sa_mask)
        sigaction(sig, &action, &previous)
        defer { sigaction(sig, &previous, nil) }
        try body()
    }
}
