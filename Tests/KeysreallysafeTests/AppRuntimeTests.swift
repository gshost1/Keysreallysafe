import Foundation
import XCTest
@testable import KeysCore

final class AppRuntimeTests: XCTestCase {
    private let fm = FileManager.default

    func testMigrationRemovesOnlyLegacyRuntimeAndIsRepeatable() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let plist = root.appendingPathComponent("agent.plist")
        try Data("legacy".utf8).write(to: plist)
        let parts = ["bin", "Web", "Fixtures", "Plugins", "scripts"]
        for part in parts { try fm.createDirectory(at: root.appendingPathComponent(part), withIntermediateDirectories: true) }
        for file in ["catalog.db", "catalog.db-wal", "preferences.json", "menubar.log"] {
            try Data(file.utf8).write(to: root.appendingPathComponent(file))
        }
        try fm.createDirectory(at: root.appendingPathComponent(".previous"), withIntermediateDirectories: true)
        var loaded = true
        var bootouts = 0
        var logs: [String] = []
        let migration = LegacyAppMigration(root: root, plist: plist, run: { path, args in
            XCTAssertEqual(path, "/bin/launchctl")
            XCTAssertTrue(args[1].hasSuffix("/com.keysreallysafe.menubar"))
            if args[0] == "bootout" { bootouts += 1; loaded = false; return (0, "", "") }
            return (loaded ? 0 : 113, "", "")
        }, log: { logs.append($0) })
        try migration.migrate()
        try migration.migrate()
        XCTAssertEqual(bootouts, 1)
        XCTAssertEqual(logs.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: plist.path))
        for part in parts { XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(part).path)) }
        for file in ["catalog.db", "catalog.db-wal", "preferences.json", "menubar.log"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file)), Data(file.utf8))
        }
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".previous").path))
    }

    func testFailedReplacementActivationRestoresAgentAndKeepsRuntime() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let plist = root.appendingPathComponent("agent.plist")
        try Data("legacy".utf8).write(to: plist)
        let binary = root.appendingPathComponent("bin/keys")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old binary".utf8).write(to: binary)
        var loaded = true
        var operations: [String] = []
        let migration = LegacyAppMigration(root: root, plist: plist, run: { _, args in
            operations.append(args[0])
            if args[0] == "bootout" { loaded = false; return (0, "", "") }
            if args[0] == "bootstrap" { loaded = true; return (0, "", "") }
            return (loaded ? 0 : 113, "", "")
        }, log: { _ in })
        XCTAssertThrowsError(try migration.migrate {
            XCTAssertFalse(loaded)
            XCTAssertTrue(self.fm.fileExists(atPath: binary.path))
            throw AppError.http("fixture port unavailable")
        })
        XCTAssertTrue(loaded)
        XCTAssertEqual(operations, ["print", "bootout", "print", "bootstrap"])
        XCTAssertTrue(fm.fileExists(atPath: plist.path))
        XCTAssertEqual(try Data(contentsOf: binary), Data("old binary".utf8))
    }

    func testRetirementCleanupFailureKeepsReplacementRunningAndRetries() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let plist = root.appendingPathComponent("agent.plist")
        let web = root.appendingPathComponent("Web")
        try Data("legacy".utf8).write(to: plist)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        var activated = false
        var logs: [String] = []
        let migration = LegacyAppMigration(root: root, plist: plist, run: { _, _ in (113, "", "") },
                                          log: { logs.append($0) }, removeItem: { url in
            if url.path == web.path { throw AppError.http("fixture locked file") }
            try self.fm.removeItem(at: url)
        })
        XCTAssertNoThrow(try migration.migrate { activated = true })
        XCTAssertTrue(activated)
        XCTAssertFalse(fm.fileExists(atPath: plist.path))
        XCTAssertTrue(fm.fileExists(atPath: web.path))
        XCTAssertTrue(logs.contains { $0.contains("cleanup pending: Web") })
        try LegacyAppMigration(root: root, plist: plist, run: { _, _ in (113, "", "") }, log: { _ in }).migrate()
        XCTAssertFalse(fm.fileExists(atPath: web.path))
    }

    func testFreshInstallActivatesWithoutLegacyFiles() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        var activated = false
        try LegacyAppMigration(root: root, plist: root.appendingPathComponent("missing"), run: { _, _ in (113, "", "") }, log: { _ in }).migrate {
            activated = true
        }
        XCTAssertTrue(activated)
    }

    func testFailedBootoutOrInspectionPreservesOldInstall() throws {
        for mode in ["inspection", "bootout", "still-running"] {
            let root = try TempDir.make()
            defer { try? fm.removeItem(at: root) }
            let plist = root.appendingPathComponent("agent.plist")
            try Data("legacy".utf8).write(to: plist)
            let binary = root.appendingPathComponent("bin/keys")
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old binary".utf8).write(to: binary)
            let migration = LegacyAppMigration(root: root, plist: plist, run: { _, args in
                if mode == "inspection" { return (1, "", "") }
                return (args[0] == "bootout" && mode == "bootout" ? 1 : 0, "", "")
            }, log: { _ in })
            XCTAssertThrowsError(try migration.migrate(), mode)
            XCTAssertTrue(fm.fileExists(atPath: plist.path), mode)
            XCTAssertEqual(try Data(contentsOf: binary), Data("old binary".utf8), mode)
        }
    }

    func testMigrationHandlesUnloadedAndPartialLegacyRuntime() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Web"), withIntermediateDirectories: true)
        let migration = LegacyAppMigration(root: root, plist: root.appendingPathComponent("missing.plist"), run: { _, args in
            XCTAssertEqual(args[0], "print", "an unloaded job needs no bootout")
            return (113, "", "")
        }, log: { _ in })
        try migration.migrate()
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Web").path))
    }

    func testMigrationDoesNotFollowRuntimeSymlinks() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let data = root.appendingPathComponent("user-data")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: data.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Web"), withDestinationURL: data)
        try LegacyAppMigration(root: root, plist: root.appendingPathComponent("missing"), run: { _, _ in (113, "", "") }, log: { _ in }).migrate()
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("keep")), Data("keep".utf8))
    }

    func testOnlyOneAppInstanceCanOwnMigrationAndListeners() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let first = try AppInstanceLock(root: root)
        XCTAssertThrowsError(try AppInstanceLock(root: root))
        first.close()
        let second = try AppInstanceLock(root: root)
        second.close()
    }

    func testCLILinkIsIdempotentAndNeverReplacesAnotherTool() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let binary = root.appendingPathComponent("Keysrs.app/Contents/MacOS/keys")
        let link = root.appendingPathComponent(".local/bin/keys")
        try CommandLineLink.install(binary: binary, destination: link)
        try CommandLineLink.install(binary: binary, destination: link)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), binary.path)
        XCTAssertThrowsError(try CommandLineLink.install(binary: root.appendingPathComponent("other"), destination: link))
        let moved = root.appendingPathComponent("Moved/Keysrs.app/Contents/MacOS/keys")
        try CommandLineLink.install(binary: moved, destination: link, replacingSymbolicLink: binary.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), moved.path)
        XCTAssertThrowsError(try CommandLineLink.install(binary: binary, destination: link, replacingSymbolicLink: binary.path))
        try fm.removeItem(at: link)
        try Data("existing tool".utf8).write(to: link)
        XCTAssertThrowsError(try CommandLineLink.install(binary: binary, destination: link, replacingSymbolicLink: moved.path))
        XCTAssertThrowsError(try CommandLineLink.install(binary: binary, destination: link))
        XCTAssertEqual(try Data(contentsOf: link), Data("existing tool".utf8))
    }

    func testBundleResourcesOverrideCheckoutAndEnvironment() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Keysrs.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let web = resources.appendingPathComponent("Web")
        let fixtures = resources.appendingPathComponent("Fixtures")
        for directory in [web, fixtures] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.keysreallysafe.keysrs", "CFBundleExecutable": "keys", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("dashboard".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: web.appendingPathComponent("providers.json"))
        try Data("[]".utf8).write(to: fixtures.appendingPathComponent("models.json"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(try WebRoot.find(bundle: bundle, override: root).path, web.path)
        XCTAssertEqual(FixturePath.resolve(fileName: "models.json", envKey: "PATH", testURL: nil, bundle: bundle)?.path, fixtures.appendingPathComponent("models.json").path)
        XCTAssertEqual(FixturePath.resolve(fileName: "providers.json", envKey: "PATH", testURL: nil, bundle: bundle)?.path, web.appendingPathComponent("providers.json").path)
        try fm.removeItem(at: fixtures.appendingPathComponent("models.json"))
        XCTAssertNil(FixturePath.resolve(fileName: "models.json", envKey: "PATH", testURL: nil, bundle: bundle))
        try fm.removeItem(at: web.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try WebRoot.find(bundle: bundle, override: root), "a broken bundle must not silently serve a checkout")
    }

    func testResourcesResolveRealBundleWhenInvokedThroughCLISymlink() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Keysrs.app")
        let contents = app.appendingPathComponent("Contents")
        let binary = contents.appendingPathComponent("MacOS/keys")
        let resources = contents.appendingPathComponent("Resources")
        for directory in [binary.deletingLastPathComponent(), resources] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let plist = ["CFBundleIdentifier": "com.keysreallysafe.keysrs", "CFBundleExecutable": "keys", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("main.swift")
        try "import Foundation\nprint(AppResources.root()!.path)\n".write(to: source, atomically: true, encoding: .utf8)
        // Exercise Foundation's real process/bundle resolution without starting Keysrs,
        // creating a service, registering a login item, or accessing the Keychain.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolver = repo.appendingPathComponent("Sources/KeysCore/AppResources.swift")
        let compiled = try LoginItem.run("/usr/bin/xcrun", ["swiftc", source.path, resolver.path, "-o", binary.path,
                                                          "-module-cache-path", root.appendingPathComponent("modules").path])
        XCTAssertEqual(compiled.status, 0, compiled.stderr)
        guard compiled.status == 0 else { return }
        let link = root.appendingPathComponent("bin/keys")
        try CommandLineLink.install(binary: binary, destination: link)
        let result = try LoginItem.run(link.path, ["--fixture-cli-probe"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), resources.path)
    }

    func testNavigationOnlyTrustsExactLoopbackOriginIncludingBlobs() {
        let origin = URL(string: "http://127.0.0.1:12766/")!
        for path in ["http://127.0.0.1:12766/", "http://127.0.0.1:12766/?range=month", "blob:http://127.0.0.1:12766/example"] {
            XCTAssertTrue(DashboardNavigation.isLocal(URL(string: path)!, origin: origin))
        }
        for path in ["https://example.com", "http://127.0.0.1:12767/", "http://localhost:12766/", "file:///tmp/secret", "blob:https://example.com/id", "http://user@127.0.0.1:12766/"] {
            XCTAssertFalse(DashboardNavigation.isLocal(URL(string: path)!, origin: origin), path)
        }
    }

    func testUpdateResponseUsesOnlyValidVersionTagAndComparesNumerically() throws {
        XCTAssertEqual(try UpdateCheck.parseVersion(Data(#"{"tag_name":"v0.10.0","body":"ignored","assets":[]}"#.utf8)), "0.10.0")
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.2"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.2", than: "0.10.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.10.0", than: "0.10.0"))
        for value in [#"{"tag_name":"not a version"}"#, #"{"tag_name":"v0.11.0-beta"}"#, #"{"body":"0.11.0"}"#] {
            XCTAssertThrowsError(try UpdateCheck.parseVersion(Data(value.utf8)))
        }
    }

    func testRetiredCommandLineLinkMovesToTheAppAndOthersAreLeftAlone() throws {
        let root = try TempDir.make()
        defer { try? fm.removeItem(at: root) }
        let retired = root.appendingPathComponent("support/bin/keys")
        let binary = root.appendingPathComponent("Keysrs.app/Contents/MacOS/keys")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: binary)
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        let link = bin.appendingPathComponent("keys")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: retired.path)
        XCTAssertTrue(CommandLineLink.repairRetired(link: link, retired: retired, binary: binary))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), binary.path)
        XCTAssertFalse(CommandLineLink.repairRetired(link: link, retired: retired, binary: binary))

        let own = bin.appendingPathComponent("own")
        try fm.createSymbolicLink(atPath: own.path, withDestinationPath: "/opt/somewhere/keys")
        XCTAssertFalse(CommandLineLink.repairRetired(link: own, retired: retired, binary: binary))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: own.path), "/opt/somewhere/keys")

        // The old runtime still exists (cleanup pending): leave the link working as it is.
        try fm.createDirectory(at: retired.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: retired)
        let pending = bin.appendingPathComponent("pending")
        try fm.createSymbolicLink(atPath: pending.path, withDestinationPath: retired.path)
        XCTAssertFalse(CommandLineLink.repairRetired(link: pending, retired: retired, binary: binary))
    }
}
