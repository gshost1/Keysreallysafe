import Foundation
import XCTest
@testable import KeysCore

/// One control file, two dashboard owners. The app's site (12766) writes it, and a
/// checkout `keys dashboard` (12765) used to write over it and then delete it on
/// exit, leaving the running app unreachable to every CLI command. These pin the
/// ownership rule: a writer may not displace a live file owned by another process
/// unless it is the app itself, and a process removes only the file whose boot id
/// it wrote — never a newer owner's.
final class ControlFileOwnershipTests: XCTestCase {

    /// A control URL beside a temp catalog, fail-closed-checked before anything is
    /// written (owner directive 2026-10-28: never the installed app's file).
    private func world() throws -> (dir: URL, catalog: URL, control: URL) {
        let world = try AppConnectionIsolationGuard.makeWorld()
        try AppConnectionIsolationGuard.assertIsolated(control: world.control)
        return world
    }

    /// A live Keysrs-shaped process that is not this one: a copy of `/bin/sleep` named
    /// `keys`, which `proc_pidpath` reports as a `keys` binary. The real app's
    /// `Contents/MacOS/keys` is what a test must never start.
    private func liveSiteStandIn() throws -> Process {
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

    /// The checkout dev copy may not take a control file a live app owns. Before the
    /// fix it wrote unconditionally, so the app's port and token were replaced and the
    /// dev copy's exit removed the file for good.
    func testACheckoutSiteLeavesALiveAppsControlFileAlone() throws {
        let world = try world()
        let app = try liveSiteStandIn().processIdentifier
        try ControlFile.write(port: 12_766, token: "app-token", pid: app, to: world.control)

        XCTAssertThrowsError(
            try ControlFile.write(port: 12_765, token: "dev-token", to: world.control)
        ) { error in
            guard let held = error as? ControlFile.OwnerHeld else {
                return XCTFail("expected OwnerHeld, got \(error)")
            }
            XCTAssertEqual(held.pid, app)
            XCTAssertEqual(held.port, 12_766)
            XCTAssertFalse("\(held)".contains("app-token"), "the owner's token never reaches a message")
        }
        XCTAssertEqual(ControlFile.live(at: world.control)?.port, 12_766, "the app keeps its port")
        XCTAssertEqual(ControlFile.live(at: world.control)?.token, "app-token", "and its token")
    }

    /// A live process that is not a Keysrs binary is a recycled pid or a stand-in, so
    /// its file is stale: a site binds over it rather than being locked out of its own
    /// catalog by a stranger's pid.
    func testARecycledPidDoesNotHoldTheFileHostage() throws {
        let world = try world()
        try ControlFile.write(port: 12_766, token: "stale", pid: getppid(), to: world.control)
        try ControlFile.write(port: 12_765, token: "dev", to: world.control)
        XCTAssertEqual(ControlFile.live(at: world.control)?.token, "dev")
    }

    /// A file written by another Keysrs process is removed by that process only: this
    /// process's exit cleanup leaves a live site's file where it is.
    func testRemoveLeavesAnotherLiveSitesFileAlone() throws {
        let world = try world()
        let app = try liveSiteStandIn().processIdentifier
        try ControlFile.write(port: 12_766, token: "app", pid: app, to: world.control)
        ControlFile.remove(at: world.control)
        XCTAssertNotNil(ControlFile.live(at: world.control), "another live site still owns it")
    }

    /// A checkout dev copy that does bind (a dead owner, no app up) removes only its
    /// own file: its boot id no longer matches a newer owner's, so that file stays.
    func testAStaleExitDoesNotDeleteANewerOwnersFile() throws {
        let world = try world()
        try ControlFile.write(port: 12_765, token: "mine", to: world.control)
        // A newer owner replaces it, in another process with its own boot id.
        try ControlFile.write(port: 12_766, token: "newer", pid: getppid(), bootID: "other-boot", to: world.control)
        ControlFile.remove(at: world.control)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.control.path))
        XCTAssertEqual(ControlFile.live(at: world.control)?.token, "newer")
    }

    /// The app itself may replace a live file: that is a relaunch or a restart on
    /// purpose, and refusing would strand the app without a file while it serves.
    func testTheAppMayReplaceALiveFile() throws {
        let world = try world()
        let app = try liveSiteStandIn().processIdentifier
        try ControlFile.write(port: 12_765, token: "old", pid: app, to: world.control)
        try ControlFile.write(port: 12_766, token: "new", takeover: true, to: world.control)
        XCTAssertEqual(ControlFile.live(at: world.control)?.port, 12_766)
        XCTAssertEqual(ControlFile.live(at: world.control)?.pid, getpid())
    }

    /// A dead owner's file is not a live owner: the next bind replaces it freely.
    func testADeadOwnersFileIsReplacedWithoutTakeover() throws {
        let world = try world()
        try ControlFile.write(port: 12_766, token: "dead", pid: 2_147_483_000, to: world.control)
        try ControlFile.write(port: 12_765, token: "dev", to: world.control)
        XCTAssertEqual(ControlFile.live(at: world.control)?.token, "dev")
    }

    /// Two writers in one process share a boot id, so the second write does not orphan
    /// the first: exit cleanup still recognises the file it left behind.
    func testRemoveDeletesTheFileThisProcessWrote() throws {
        let world = try world()
        try ControlFile.write(port: 12_765, token: "dev", to: world.control)
        ControlFile.remove(at: world.control)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.control.path))
    }

    /// The pid alone is not the identity. A file written by another process that
    /// happens to share this pid (a recycled pid) keeps its own boot id, and this
    /// process's exit cleanup must leave it alone — the check-then-unlink that only
    /// compared pids deleted a newer owner's file.
    func testRemoveLeavesAFileARecycledPidNowOwns() throws {
        let world = try world()
        try ControlFile.write(port: 12_766, token: "newer", pid: getpid(), bootID: "another-boot", to: world.control)
        ControlFile.remove(at: world.control)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.control.path),
                      "the boot id, not just the pid, decides ownership")
        XCTAssertEqual(ControlFile.live(at: world.control)?.token, "newer")
    }

    /// Written 0600 from creation, not chmod'ed afterwards: a umask that strips
    /// everything must not leave the token world-readable for even one syscall.
    func testTheFileIsOwnerOnlyWhateverTheUmask() throws {
        let world = try world()
        let previous = umask(0o777)
        defer { umask(previous) }
        try ControlFile.write(port: 12_765, token: "dev", to: world.control)
        let attrs = try FileManager.default.attributesOfItem(atPath: world.control.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.dir.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "the temp file is renamed, never left behind")
    }
}
