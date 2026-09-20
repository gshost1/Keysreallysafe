import Foundation
import XCTest

/// A child process the test owns outright: its own process group, bounded waits,
/// and a teardown that escalates instead of trusting a single signal.
///
/// Foundation's `Process` is not enough for a browser suite. It leaves the child
/// in the *test runner's* process group, so there is no group to sweep that does
/// not also contain the runner; it offers only `terminate()`, a plain SIGTERM;
/// and `waitUntilExit()` has no deadline. A child that is stopped — SIGSTOP
/// leaves a SIGTERM pending and undeliverable — or that simply ignores SIGTERM
/// therefore hangs the suite forever, and any browser it started outlives it.
///
/// This launcher closes both holes. `posix_spawn` with `POSIX_SPAWN_SETPGROUP`
/// makes the child the leader of a brand-new group; every wait carries a
/// deadline; and teardown escalates SIGTERM → SIGCONT → SIGKILL over that group
/// and over any further group the child names in its guard file, because
/// Playwright launches its browser detached into a group of its own.
///
/// Nothing outside those groups is ever signalled. There is no `pkill`, no name
/// match and no wildcard: `ownedGroup(_:)` is the only door, and it refuses the
/// runner's own group, pid 0 and pid 1.
enum BoundedChild {
    struct Report {
        /// The child's exit code, once it was reaped and exited normally.
        var exitCode: Int32?
        /// The signal that ended the child, if a signal did.
        var terminatingSignal: Int32?
        /// The child outran its timeout and was torn down rather than awaited.
        var timedOut = false
        /// What teardown had to do, in order. Empty after a clean, prompt exit.
        var escalations: [String] = []
        /// Groups still alive when the bounded teardown ran out of patience.
        var leakedGroups: [pid_t] = []
        /// Wall-clock seconds spent signalling and reaping, after the deadline.
        var teardownSeconds: TimeInterval = 0

        var isClean: Bool { leakedGroups.isEmpty }
        var succeeded: Bool { !timedOut && exitCode == 0 && isClean }
    }

    enum LaunchError: Error, CustomStringConvertible {
        case spawn(Int32)
        var description: String {
            switch self {
            case .spawn(let code): return "posix_spawn failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Runs `command` to completion or to `timeout`, then guarantees teardown.
    ///
    /// - Parameters:
    ///   - command: argv; `command[0]` is resolved through `PATH` by the shell
    ///     that `exec`s it, so the pid stays the group leader.
    ///   - guardFile: a JSON object of process *group* ids the child declares it
    ///     owns, written by the child itself before it does anything else. Each
    ///     is swept after the child goes, which is how a detached browser gets
    ///     reaped by name rather than by guesswork. See `declaredGroups(_:from:)`
    ///     for why these are group ids and not pids.
    ///   - grace: the bound on each individual escalation step.
    static func run(
        _ command: [String],
        directory: URL? = nil,
        environment: [String: String],
        timeout: TimeInterval,
        grace: TimeInterval = 5,
        guardFile: URL? = nil
    ) throws -> Report {
        if let guardFile { try? FileManager.default.removeItem(at: guardFile) }
        let pid = try spawnInOwnGroup(command: command, directory: directory, environment: environment)
        var report = Report()

        if let raw = reap(pid, within: timeout) {
            decode(raw, into: &report)
        } else {
            report.timedOut = true
            let started = Date()
            // A stopped child holds a pending SIGTERM it can never act on, so the
            // group is woken as well as asked to leave.
            signal(group: pid, SIGTERM, "SIGTERM to group \(pid)", into: &report)
            signal(group: pid, SIGCONT, "SIGCONT to group \(pid)", into: &report)
            if let raw = reap(pid, within: grace) {
                decode(raw, into: &report)
            } else {
                signal(group: pid, SIGKILL, "SIGKILL to group \(pid)", into: &report)
                if let raw = reap(pid, within: grace) {
                    decode(raw, into: &report)
                } else {
                    report.escalations.append("group \(pid) outlived SIGKILL")
                }
            }
            report.teardownSeconds = Date().timeIntervalSince(started)
        }

        // Whether it timed out or exited on its own, nothing it started may
        // outlive it: sweep its group and every group it declared it owns.
        let sweepStarted = Date()
        var swept: [pid_t] = []
        for group in [pid] + declaredGroups(guardFile, from: pid) where !swept.contains(group) {
            swept.append(group)
            sweep(group, grace: grace, into: &report)
        }
        report.teardownSeconds += Date().timeIntervalSince(sweepStarted)
        return report
    }

    /// True while `pid` exists. Exposed so a test can prove teardown reaped what
    /// it signalled, rather than only that teardown returned.
    static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - launching

    private static func spawnInOwnGroup(
        command: [String],
        directory: URL?,
        environment: [String: String]
    ) throws -> pid_t {
        // `exec` keeps the pid posix_spawn handed back, so the command itself —
        // not a shell wrapping it — stays the leader of the new group. The path
        // and argv travel as positional parameters, so nothing is re-parsed.
        let script = directory == nil
            ? #"exec "$@""#
            : #"cd -- "$1" || exit 127; shift; exec "$@""#
        var argv = ["sh", "-c", script, "sh"]
        if let directory { argv.append(directory.path) }
        argv.append(contentsOf: command)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw LaunchError.spawn(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        // pgroup 0 means "a new group led by the child", which is the whole point.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var cArgv = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer {
            for pointer in cArgv { free(pointer) }
            for pointer in cEnvironment { free(pointer) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/sh", nil, &attributes, &cArgv, &cEnvironment)
        guard code == 0 else { throw LaunchError.spawn(code) }
        return pid
    }

    // MARK: - bounded waiting

    /// Reaps `pid` if it finishes within `seconds`; nil means it is still running.
    private static func reap(_ pid: pid_t, within seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        var raw: Int32 = 0
        while true {
            let done = waitpid(pid, &raw, WNOHANG)
            if done == pid { return raw }
            if done < 0 { return errno == ECHILD ? 0 : nil }
            if Date() >= deadline { return nil }
            usleep(20_000)
        }
    }

    private static func decode(_ raw: Int32, into report: inout Report) {
        let low = raw & 0x7f
        if low == 0 {
            report.exitCode = (raw >> 8) & 0xff
        } else if low != 0x7f {
            report.terminatingSignal = low
        }
    }

    private static func waitForGroupToEmpty(_ group: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !groupIsAlive(group) { return true }
            usleep(20_000)
        }
        return !groupIsAlive(group)
    }

    // MARK: - signalling, group by owned group

    private static func sweep(_ group: pid_t, grace: TimeInterval, into report: inout Report) {
        guard ownedGroup(group), groupIsAlive(group) else { return }
        signal(group: group, SIGTERM, "SIGTERM to leftover group \(group)", into: &report)
        signal(group: group, SIGCONT, "SIGCONT to leftover group \(group)", into: &report)
        if waitForGroupToEmpty(group, within: grace) { return }
        signal(group: group, SIGKILL, "SIGKILL to leftover group \(group)", into: &report)
        if waitForGroupToEmpty(group, within: grace) { return }
        report.leakedGroups.append(group)
    }

    private static func signal(group: pid_t, _ number: Int32, _ note: String, into report: inout Report) {
        guard ownedGroup(group) else { return }
        if kill(-group, number) == 0 { report.escalations.append(note) }
    }

    /// The one safety rail that matters: only a group this launcher created may
    /// be signalled — never the test runner's own group, never 0, never init.
    private static func ownedGroup(_ group: pid_t) -> Bool {
        group > 1 && group != getpgrp() && group != getpid()
    }

    private static func groupIsAlive(_ group: pid_t) -> Bool {
        if kill(-group, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The groups the child declared it owns.
    ///
    /// These are process *group* ids, taken at face value and never resolved
    /// from a pid. Resolving would fail exactly when it matters: a detached
    /// browser can exit while descendants stay behind in its group, and by the
    /// time teardown looks, `getpgid(deadLeader)` is `ESRCH` — so the survivors
    /// would be dropped from the sweep and the run would report itself clean. A
    /// value only means anything here because the process that wrote it leads a
    /// group of its own, which Playwright's detached launch guarantees for
    /// Chromium and `POSIX_SPAWN_SETPGROUP` guarantees for the driver.
    ///
    /// Taking a number from a file and signalling the group it names deserves
    /// provenance, so the file must first name the group this launcher itself
    /// just created. A stale or foreign file names something else and is ignored
    /// outright; `ownedGroup(_:)` then still refuses the runner's own group.
    private static func declaredGroups(_ guardFile: URL?, from child: pid_t) -> [pid_t] {
        guard let guardFile,
              let data = try? Data(contentsOf: guardFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let own = (object["node_group"] as? NSNumber).map({ pid_t($0.int32Value) }),
              own == child
        else { return [] }
        var groups: [pid_t] = []
        for (name, value) in object where name != "node_group" {
            guard let number = value as? NSNumber else { continue }
            let group = pid_t(number.int32Value)
            if group > 1, !groups.contains(group) { groups.append(group) }
        }
        return groups
    }
}

/// The watchdog's own regression test.
///
/// The browser contract harness only reaches this code when something has
/// already gone wrong, so the failure path is exercised here against a fixture
/// that is wedged on purpose. It ignores SIGTERM and stops itself, and it leaves
/// behind three kinds of survivor: a descendant in its own group, a detached
/// group whose leader is still alive — how Playwright leaves Chromium — and a
/// detached group whose leader has already exited and been reaped, which is the
/// case a launcher that resolves groups from pids cannot see. No browser, no
/// network and no product code are involved, so this runs in the ordinary suite
/// rather than behind the harness's environment gate.
final class BoundedChildProcessTests: XCTestCase {
    /// Ignores SIGTERM and never leaves on its own.
    private static let lingerFixture = """
    #!/bin/sh
    trap '' TERM
    while :; do sleep 1; done
    """

    /// Leads a group, puts a lingerer in it, and exits straight away — so by
    /// teardown the group has a survivor but no leader left to resolve it from.
    private static let orphanFixture = """
    #!/bin/sh
    sh "$KEYS_FIXTURE_LINGER" &
    printf '%s\\n' "$!" > "$KEYS_FIXTURE_ORPHAN"
    """

    /// The review's reproduction, made into a test: SIGSTOP leaves the pending
    /// SIGTERM undeliverable, so a launcher that only sends SIGTERM and waits
    /// never returns.
    private static let wedgedFixture = """
    #!/bin/sh
    # Wedged on purpose: SIGTERM is ignored and the shell then stops itself, so a
    # lone SIGTERM can neither be handled nor delivered.
    trap '' TERM INT HUP

    # A descendant inside this process group, the way a helper would be.
    sh "$KEYS_FIXTURE_LINGER" &
    printf '%s\\n' "$!" > "$KEYS_FIXTURE_DESCENDANT"

    # Two descendants in groups of their own, the way Playwright launches
    # Chromium. Job control in a non-interactive shell is what puts them there.
    set -m
    sh "$KEYS_FIXTURE_LINGER" &
    browser=$!
    sh "$KEYS_FIXTURE_ORPHAN_MAKER" &
    orphan=$!
    set +m
    # The second leader exits at once and is reaped here, so its group outlives
    # it: getpgid(orphan) is ESRCH from now on, but the group is not empty.
    wait "$orphan"

    printf '{"node_group": %s, "browser_group": %s, "orphan_group": %s}\\n' \\
        "$$" "$browser" "$orphan" > "$KEYS_FIXTURE_GUARD"
    printf '%s\\n' "$$" > "$KEYS_FIXTURE_LEADER"
    : > "$KEYS_FIXTURE_READY"
    kill -STOP $$
    while :; do sleep 1; done
    """

    func testAStoppedChildIgnoringSIGTERMIsTornDownWithinItsBound() throws {
        let directory = try TempDir.make()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("wedged.sh")
        let linger = directory.appendingPathComponent("linger.sh")
        let orphanMaker = directory.appendingPathComponent("orphan.sh")
        try Self.wedgedFixture.write(to: fixture, atomically: true, encoding: .utf8)
        try Self.lingerFixture.write(to: linger, atomically: true, encoding: .utf8)
        try Self.orphanFixture.write(to: orphanMaker, atomically: true, encoding: .utf8)
        let ready = directory.appendingPathComponent("ready")
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let descendantFile = directory.appendingPathComponent("descendant.pid")
        let orphanFile = directory.appendingPathComponent("orphan.pid")
        let guardFile = directory.appendingPathComponent("guard.json")

        // An unrelated `sh` sitting in the test runner's own group. A teardown
        // that reached for `pkill sh`, or for the whole session, would take this
        // with it; a teardown that only touches groups it created cannot.
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sh")
        unrelated.arguments = ["-c", "while :; do sleep 1; done"]
        try unrelated.run()
        addTeardownBlock { if unrelated.isRunning { unrelated.terminate() } }

        var environment = ProcessInfo.processInfo.environment
        environment["KEYS_FIXTURE_READY"] = ready.path
        environment["KEYS_FIXTURE_LEADER"] = leaderFile.path
        environment["KEYS_FIXTURE_DESCENDANT"] = descendantFile.path
        environment["KEYS_FIXTURE_ORPHAN"] = orphanFile.path
        environment["KEYS_FIXTURE_LINGER"] = linger.path
        environment["KEYS_FIXTURE_ORPHAN_MAKER"] = orphanMaker.path
        environment["KEYS_FIXTURE_GUARD"] = guardFile.path

        let timeout = 1.5
        let grace = 0.75
        let started = Date()
        let report = try BoundedChild.run(
            ["sh", fixture.path],
            environment: environment,
            timeout: timeout,
            grace: grace,
            guardFile: guardFile
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path),
                      "the fixture never got as far as wedging itself")
        XCTAssertTrue(report.timedOut, "a wedged child must be reported as a timeout, never as a pass")
        XCTAssertEqual(report.terminatingSignal, SIGKILL,
                       "a stopped child that ignores SIGTERM can only be ended by SIGKILL")
        XCTAssertTrue(report.escalations.contains { $0.hasPrefix("SIGCONT to group") },
                      "a stopped child must be woken before its SIGTERM can mean anything: \(report.escalations)")
        XCTAssertTrue(report.isClean, "teardown gave up with groups still alive: \(report.leakedGroups)")

        // Bounded, and demonstrably so: timeout, then at most a handful of
        // grace windows, never the unbounded wait the old watchdog used.
        XCTAssertLessThan(elapsed, timeout + grace * 10 + 5,
                          "teardown was not bounded: \(elapsed) s, escalations \(report.escalations)")

        let leader = try Self.pid(in: leaderFile)
        let descendant = try Self.pid(in: descendantFile)
        let declared = try Self.declaredGroups(in: guardFile)
        let browser = try XCTUnwrap(declared["browser_group"])
        let orphanGroup = try XCTUnwrap(declared["orphan_group"])
        let orphan = try Self.pid(in: orphanFile)
        XCTAssertNotEqual(orphan, orphanGroup, "the orphan must be a member of the group, not its leader")
        XCTAssertFalse(BoundedChild.processExists(orphanGroup),
                       "the fixture must have let the orphaned group's leader exit and be reaped")

        XCTAssertFalse(BoundedChild.processExists(leader), "the wedged leader survived teardown")
        XCTAssertFalse(BoundedChild.processExists(descendant),
                       "a descendant in the child's own group survived teardown")
        XCTAssertFalse(BoundedChild.processExists(browser),
                       "the detached descendant the child declared survived teardown")
        // The regression: this group's leader was gone before teardown started,
        // so a sweep that asked the system which group the leader was in would
        // have been told nothing and called the run clean anyway.
        XCTAssertFalse(BoundedChild.processExists(orphan),
                       "a survivor in a declared group whose leader had already exited was missed")
        XCTAssertTrue(unrelated.isRunning, "teardown signalled a process it did not start")
    }

    func testAWellBehavedChildIsReportedVerbatimAndNeedsNoEscalation() throws {
        let report = try BoundedChild.run(
            ["sh", "-c", "exit 3"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 30
        )
        XCTAssertFalse(report.timedOut)
        XCTAssertEqual(report.exitCode, 3, "the child's own status must reach the test unchanged")
        XCTAssertEqual(report.escalations, [], "a child that leaves on its own must not be signalled")
        XCTAssertTrue(report.isClean)
    }

    private static func pid(in file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text) ?? 0
    }

    private static func declaredGroups(in file: URL) throws -> [String: pid_t] {
        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber).map { pid_t($0.int32Value) } }
    }
}
