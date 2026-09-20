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

        var installedPlugin: URL {
            installer.root.appendingPathComponent("Plugins/jev-optimizer")
        }

        var installedScripts: URL {
            installer.root.appendingPathComponent("scripts")
        }
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func makeWorld(binary: String = "binary-v1", pluginVersion: String = "plugin-v1") throws -> World {
        let workspace = try TempDir.make()
        let sourceRoot = workspace.appendingPathComponent("checkout", isDirectory: true)
        let web = sourceRoot.appendingPathComponent("Web", isDirectory: true)
        let binaryURL = sourceRoot.appendingPathComponent("keys")
        try write("<html>", to: web.appendingPathComponent("index.html"))
        try write("{}", to: web.appendingPathComponent("providers.json"))
        try write("{}", to: sourceRoot.appendingPathComponent("Fixtures/models.json"))
        try write("{}", to: sourceRoot.appendingPathComponent("Fixtures/providers.json"))
        try write(binary, to: binaryURL, executable: true)

        try write(pluginVersion, to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js"))
        try write("source", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/src/index.js"))
        try write("hook", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/hooks/after.js"))
        try write("{}", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/.claude-plugin/plugin.json"))
        try write("package", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/package.json"))
        try write("readme", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/README.md"))
        try write("license", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/LICENSE"))
        try write("provider-secret", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/.env"))
        try write("node-secret", to: sourceRoot.appendingPathComponent("Plugins/jev-optimizer/node_modules/private.txt"))
        try write("optimizer-mcp-v1", to: sourceRoot.appendingPathComponent("scripts/optimizer-mcp.py"))
        try write("launcher-v1", to: sourceRoot.appendingPathComponent("scripts/claude-with-jev.py"))
        try write("do-not-copy", to: sourceRoot.appendingPathComponent("scripts/private.secret"))

        return World(
            root: workspace.appendingPathComponent("AppSupport", isDirectory: true),
            sourceRoot: sourceRoot,
            sourceBinary: binaryURL,
            webRoot: web,
            plist: workspace.appendingPathComponent("LaunchAgents/test.plist"),
            launch: FakeLaunch()
        )
    }

    func testStageCopiesPluginDistAndScriptsButExcludesSecretsAndDependencies() throws {
        let world = try makeWorld()
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)

        XCTAssertEqual(
            try String(contentsOf: world.installedPlugin.appendingPathComponent("dist/optimizer-cli.js")),
            "plugin-v1"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.installedPlugin.appendingPathComponent("src/index.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.installedPlugin.appendingPathComponent("hooks/after.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.installedPlugin.appendingPathComponent(".claude-plugin/plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.installedScripts.appendingPathComponent("optimizer-mcp.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.installedScripts.appendingPathComponent("claude-with-jev.py").path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: world.installedPlugin.appendingPathComponent("node_modules").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.installedPlugin.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.installedScripts.appendingPathComponent("private.secret").path))
    }

    func testPackagingRollbackRestoresPreviousPluginAndScripts() throws {
        let world = try makeWorld()
        try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)
        try write("binary-v2", to: world.sourceBinary, executable: true)
        try write("plugin-v2", to: world.sourceRoot.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js"))
        try write("optimizer-mcp-v2", to: world.sourceRoot.appendingPathComponent("scripts/optimizer-mcp.py"))
        world.launch.failBootstrapOnce = true

        XCTAssertThrowsError(try world.installer.install(fromBinary: world.sourceBinary, webRoot: world.webRoot)) { error in
            let failure = error as? Installer.Failure
            XCTAssertEqual(failure?.stage, "activation")
            XCTAssertEqual(failure?.rolledBack, true)
        }
        XCTAssertEqual(try String(contentsOf: world.installer.binary), "binary-v1")
        XCTAssertEqual(try String(contentsOf: world.installedPlugin.appendingPathComponent("dist/optimizer-cli.js")), "plugin-v1")
        XCTAssertEqual(try String(contentsOf: world.installedScripts.appendingPathComponent("optimizer-mcp.py")), "optimizer-mcp-v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.installer.previous.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.root.path)
            .filter { $0.hasPrefix(".staging-") || $0.hasPrefix(".previous-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
