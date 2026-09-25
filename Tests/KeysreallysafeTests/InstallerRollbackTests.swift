import Foundation
import XCTest
@testable import KeysCore

/// A failed install must leave the previous version installed and running.
final class InstallerRollbackTests: XCTestCase {
    private final class FakeLaunch: @unchecked Sendable {
        var calls: [[String]] = []
        var failVerb: String?          // "codesign", "verify", "bootstrap"
        var failOnce = false
        func run(_ path: String, _ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            calls.append([path] + args)
            let verb: String
            if path.hasSuffix("codesign") {
                verb = args.first == "--verify" ? "verify" : "codesign"
            } else {
                verb = args.first ?? ""
            }
            if verb == failVerb {
                if failOnce { failVerb = nil }
                return (1, "", "synthetic \(verb) failure")
            }
            return (0, "", "")
        }
        func count(_ verb: String) -> Int {
            calls.filter { $0.contains(verb) && !( verb == "codesign" && $0.contains("--verify")) }.count
        }
    }

    /// Deterministic file-move faults. With no predicate set it is the real file system.
    private final class FaultyFiles: @unchecked Sendable {
        var failMove: ((URL, URL) -> Bool)?
        func move(_ from: URL, _ to: URL) throws {
            if failMove?(from, to) == true {
                throw AppError.http("synthetic move failure: \(from.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    private struct World {
        let root: URL
        let plist: URL
        let source: URL
        let webRoot: URL
        let launch: FakeLaunch
        let files: FaultyFiles
        var installer: Installer {
            Installer(root: root, agentPlist: plist, label: "com.keysreallysafe.test", run: launch.run,
                      validateSigning: { candidate, _ in
                          let result = try launch.run("validate-signing", ["validate", candidate.path])
                          if result.status != 0 { throw AppError.http(result.stderr) }
                      },
                      moveItem: files.move)
        }
    }

    private func makeWorld(binaryText: String = "v1") throws -> World {
        let dir = try TempDir.make()
        let checkout = dir.appendingPathComponent("checkout", isDirectory: true)
        let web = checkout.appendingPathComponent("Web", isDirectory: true)
        let fixtures = checkout.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: fixtures.appendingPathComponent("models.json"))
        try Data("{}".utf8).write(to: fixtures.appendingPathComponent("providers.json"))
        let source = checkout.appendingPathComponent("keys")
        try Data(binaryText.utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return World(
            root: dir.appendingPathComponent("AppSupport", isDirectory: true),
            plist: dir.appendingPathComponent("LaunchAgents/com.keysreallysafe.test.plist"),
            source: source, webRoot: web, launch: FakeLaunch(), files: FaultyFiles()
        )
    }

    private func liveBinary(_ w: World) -> String? {
        (try? Data(contentsOf: w.installer.binary)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testFreshInstallValidatesBeforeStoppingAnythingAndLaysOutEveryPart() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        XCTAssertEqual(liveBinary(w), "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.installer.web.appendingPathComponent("index.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.installer.fixtures.appendingPathComponent("models.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.installer.sourceHash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.plist.path))
        let verbs = w.launch.calls.map { $0.contains("--verify") ? "verify" : ($0[0].hasSuffix("codesign") ? "codesign" : $0[1]) }
        XCTAssertEqual(verbs, ["validate", "bootout", "bootstrap"], "signature validation happens before the agent is stopped; installation never re-signs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.installer.previous.path), "nothing to keep on a first install")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.root.path).filter { $0.hasPrefix(".staging") || $0.hasPrefix(".previous-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testUpgradeKeepsOnePreviousVersion() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        try Data("v2".utf8).write(to: w.source)
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        XCTAssertEqual(liveBinary(w), "v2")
        let kept = try Data(contentsOf: w.installer.previous.appendingPathComponent("bin/keys"))
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "v1")
        try Data("v3".utf8).write(to: w.source)
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        let keptNow = try Data(contentsOf: w.installer.previous.appendingPathComponent("bin/keys"))
        XCTAssertEqual(String(decoding: keptNow, as: UTF8.self), "v2", "exactly one version back")
    }

    func testSigningFailureLeavesTheRunningInstallUntouched() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        let plistBefore = try Data(contentsOf: w.plist)
        w.launch.calls.removeAll()
        w.launch.failVerb = "validate"
        try Data("v2".utf8).write(to: w.source)
        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)) { error in
            let f = error as? Installer.Failure
            XCTAssertEqual(f?.stage, "staging")
            XCTAssertEqual(f?.rolledBack, false)
        }
        XCTAssertEqual(liveBinary(w), "v1")
        XCTAssertEqual(try Data(contentsOf: w.plist), plistBefore)
        XCTAssertEqual(w.launch.count("bootout"), 0, "the agent was never stopped")
        XCTAssertEqual(w.launch.count("bootstrap"), 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.root.path).filter { $0.hasPrefix(".staging") }
        XCTAssertTrue(leftovers.isEmpty, "staging is cleaned up")
    }

    func testBootstrapFailureRestoresAndRestartsThePreviousVersion() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        let plistBefore = try Data(contentsOf: w.plist)
        w.launch.calls.removeAll()
        w.launch.failVerb = "bootstrap"
        w.launch.failOnce = true
        try Data("v2".utf8).write(to: w.source)
        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)) { error in
            let f = error as? Installer.Failure
            XCTAssertEqual(f?.stage, "activation")
            XCTAssertEqual(f?.rolledBack, true)
            XCTAssertTrue(String(describing: error).contains("previous version restored"))
        }
        XCTAssertEqual(liveBinary(w), "v1", "the old binary is back")
        XCTAssertEqual(try Data(contentsOf: w.plist), plistBefore, "the old plist is back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.installer.web.appendingPathComponent("index.html").path))
        XCTAssertEqual(w.launch.count("bootstrap"), 2, "one failed start of v2, one successful restart of v1")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.root.path).filter { $0.hasPrefix(".staging") || $0.hasPrefix(".previous-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testFailureWhileMovingLivePartsStillRollsBack() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        // Make the Web directory immovable: a file at the backup destination path cannot exist
        // yet, so instead deny the move by making the live Web dir a mount-like obstacle: rename
        // protection via an unremovable child is not portable, so simulate with a read-only root.
        let plistBefore = try Data(contentsOf: w.plist)
        try Data("v2".utf8).write(to: w.source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: w.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: w.root.path) }
        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)) { error in
            let f = error as? Installer.Failure
            XCTAssertNotNil(f)
            if f?.stage == "activation" {
                XCTAssertEqual(f?.rolledBack, true)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: w.root.path)
        XCTAssertEqual(liveBinary(w), "v1")
        XCTAssertEqual(try Data(contentsOf: w.plist), plistBefore)
    }

    func testBootstrapFailureOnFreshInstallLeavesNoHalfInstall() throws {
        let w = try makeWorld()
        w.launch.failVerb = "bootstrap"
        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot))
        XCTAssertNil(liveBinary(w))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.plist.path))
        XCTAssertEqual(w.launch.count("bootstrap"), 1, "nothing older to restart")
    }

    /// A move that fails partway through setting the live parts aside must not delete the parts
    /// that were never moved and have therefore no backup copy.
    func testPartialMoveOfLivePartsKeepsUntouchedOriginals() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        // Parts 0.9.0 and 0.9.1 installed and nothing stages any more.
        let legacy = [
            w.root.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js"),
            w.root.appendingPathComponent("scripts/optimizer-mcp.py"),
        ]
        for url in legacy {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("0.9.1".utf8).write(to: url)
        }
        let plistBefore = try Data(contentsOf: w.plist)
        let untouched = [
            w.installer.web.appendingPathComponent("index.html"),
            w.installer.fixtures.appendingPathComponent("models.json"),
        ] + legacy
        for url in untouched {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition: \(url.lastPathComponent)")
        }
        w.launch.calls.removeAll()
        // Fail while moving the live Web aside: bin is already in the backup, the rest is not.
        let liveWeb = w.installer.web.standardizedFileURL
        w.files.failMove = { from, _ in from.standardizedFileURL == liveWeb }
        try Data("v2".utf8).write(to: w.source)

        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)) { error in
            let f = error as? Installer.Failure
            XCTAssertEqual(f?.stage, "activation")
            XCTAssertEqual(f?.rolledBack, true)
        }

        w.files.failMove = nil
        XCTAssertEqual(liveBinary(w), "v1", "the moved-aside binary came back")
        for url in untouched {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was never moved and must survive")
        }
        XCTAssertEqual(try Data(contentsOf: w.plist), plistBefore)
        XCTAssertEqual(w.launch.count("bootstrap"), 1, "the previous version was restarted")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: w.root.path)
            .filter { $0.hasPrefix(".staging") || $0.hasPrefix(".previous-") }
        XCTAssertTrue(leftovers.isEmpty, "a complete rollback keeps no recovery copies")
    }

    /// If putting the old parts back fails, say so and keep everything needed to recover by hand.
    func testFailedRestorationKeepsBackupAndReportsNotRolledBack() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        let plistBefore = try Data(contentsOf: w.plist)
        w.launch.calls.removeAll()
        w.launch.failVerb = "bootstrap"
        // Every move back out of the backup fails.
        w.files.failMove = { from, _ in from.deletingLastPathComponent().lastPathComponent.hasPrefix(".previous-") }
        try Data("v2".utf8).write(to: w.source)

        XCTAssertThrowsError(try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)) { error in
            let f = error as? Installer.Failure
            XCTAssertEqual(f?.stage, "activation")
            XCTAssertEqual(f?.rolledBack, false, "the previous version is not back; do not claim it is")
            XCTAssertFalse(String(describing: error).contains("previous version restored"))
        }

        w.files.failMove = nil
        let kept = try FileManager.default.contentsOfDirectory(atPath: w.root.path).filter { $0.hasPrefix(".previous-") }
        XCTAssertEqual(kept.count, 1, "the backup is retained as the only copy of the previous version")
        let backup = try w.root.appendingPathComponent(XCTUnwrap(kept.first), isDirectory: true)
        let savedBinary = try Data(contentsOf: backup.appendingPathComponent("bin/keys"))
        XCTAssertEqual(String(decoding: savedBinary, as: UTF8.self), "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Web/index.html").path))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("agent.plist")), plistBefore,
                       "the original plist stays recoverable")
        XCTAssertEqual(w.launch.count("bootstrap"), 1, "no restart is attempted on a half-restored install")
    }

    func testUninstallRemovesLivePreviousAndStrays() throws {
        let w = try makeWorld()
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        try Data("v2".utf8).write(to: w.source)
        try w.installer.install(fromBinary: w.source, webRoot: w.webRoot)
        try FileManager.default.createDirectory(at: w.root.appendingPathComponent(".staging-stray"), withIntermediateDirectories: true)
        try w.installer.uninstall()
        XCTAssertNil(liveBinary(w))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.installer.previous.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.root.appendingPathComponent(".staging-stray").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.plist.path))
    }
}
