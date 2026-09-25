import Foundation
import XCTest
@testable import KeysCore

/// Installer packaging tests use a temporary app-support root and a fake launchctl runner.
/// They exercise the staged layout without installing a login item or touching Keychain.
final class InstallerPackagingTests: XCTestCase {
    private final class FakeLaunch: @unchecked Sendable {
        var calls: [[String]] = []
        var failBootstrapOnce = false

        func run(_ path: String, _ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            calls.append([path] + args)
            if args.first == "bootstrap", failBootstrapOnce {
                failBootstrapOnce = false
                return (1, "", "synthetic bootstrap failure")
            }
            return (0, "", "")
        }
    }

    private struct World {
        let root: URL
        let sourceRoot: URL
        let sourceBinary: URL
        let webRoot: URL
        let plist: URL
        let launch: FakeLaunch

        var installer: Installer {
            Installer(
                root: root,
                agentPlist: plist,
                label: "com.keysreallysafe.packaging-test",
                run: launch.run,
                validateSigning: { _, _ in }
            )
        }

        var legacyPlugin: URL {
            installer.root.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js")
        }

        var legacyScript: URL {
            installer.root.appendingPathComponent("scripts/optimizer-mcp.py")
        }
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func makeWorld(binary: String = "binary-v1") throws -> World {
        let workspace = try TempDir.make()
        let sourceRoot = workspace.appendingPathComponent("checkout", isDirectory: true)
        let web = sourceRoot.appendingPathComponent("Web", isDirectory: true)
        let binaryURL = sourceRoot.appendingPathComponent("keys")
        try write("<html>", to: web.appendingPathComponent("index.html"))
        try write("{}", to: web.appendingPathComponent("providers.json"))
        try write("{}", to: sourceRoot.appendingPathComponent("Fixtures/models.json"))
        try write(binary, to: binaryURL, executable: true)
        // A checkout that still has optimizer build output or scripts must not ship them.
        try write("plugin", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js"))
        try write("script", to: sourceRoot.appendingPathComponent("scripts/optimizer-mcp.py"))

        return World(
            root: workspace.appendingPathComponent("AppSupport", isDirectory: true),
            sourceRoot: sourceRoot,
            sourceBinary: binaryURL,
            webRoot: web,
            plist: workspace.appendingPathComponent("LaunchAgents/test.plist"),
            launch: FakeLaunch()
        )
    }

    /// What 0.9.0 and 0.9.1 left in the live root next to bin, Web and Fixtures.
    private func seedLegacyOptimizer(_ world: World, version: String) throws {
        try write(version, to: world.legacyPlugin)
        try write(version, to: world.legacyScript)
    }

    func testStageInstallsOnlyBinaryWebAndFixtures() throws {
        let world = try makeWorld()
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)

        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: world.installer.binary), "binary-v1")
        XCTAssertTrue(fm.fileExists(atPath: world.installer.web.appendingPathComponent("index.html").path))
        XCTAssertTrue(fm.fileExists(atPath: world.installer.fixtures.appendingPathComponent("models.json").path))
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("Plugins").path))
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("scripts").path))
    }

    func testUpgradeMovesLegacyOptimizerAsideAndUninstallDeletesIt() throws {
        let world = try makeWorld()
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)
        try seedLegacyOptimizer(world, version: "0.9.1")
        try write("binary-v2", to: world.sourceBinary, executable: true)
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)

        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: world.installer.binary), "binary-v2")
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("Plugins").path))
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("scripts").path))
        XCTAssertTrue(fm.fileExists(atPath: world.installer.previous.appendingPathComponent("Plugins").path),
                      "the one kept prior version includes what it had installed")

        try seedLegacyOptimizer(world, version: "0.9.1")
        try world.installer.uninstall()
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("Plugins").path))
        XCTAssertFalse(fm.fileExists(atPath: world.root.appendingPathComponent("scripts").path))
        XCTAssertFalse(fm.fileExists(atPath: world.installer.previous.path))
    }

    func testFailedUpgradeRestoresLegacyOptimizerParts() throws {
        let world = try makeWorld()
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)
        try seedLegacyOptimizer(world, version: "0.9.1")
        try write("binary-v2", to: world.sourceBinary, executable: true)
        world.launch.failBootstrapOnce = true

        XCTAssertThrowsError(try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)) { error in
            let failure = error as? Installer.Failure
            XCTAssertEqual(failure?.stage, "activation")
            XCTAssertEqual(failure?.rolledBack, true)
        }
        XCTAssertEqual(try String(contentsOf: world.installer.binary), "binary-v1")
        XCTAssertEqual(try String(contentsOf: world.legacyPlugin), "0.9.1")
        XCTAssertEqual(try String(contentsOf: world.legacyScript), "0.9.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.installer.previous.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.root.path)
            .filter { $0.hasPrefix(".staging-") || $0.hasPrefix(".previous-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
