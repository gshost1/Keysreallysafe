import XCTest
import AppKit
@testable import KeysCore

final class MenubarTests: XCTestCase {
    func testParseMenubarCommand() throws {
        let parsed = try KeysCLI.parseAsRoot(["menubar"])
        XCTAssertTrue(parsed is MenubarCommand)
    }

    func testParseAutostartCommand() throws {
        XCTAssertTrue(try KeysCLI.parseAsRoot(["autostart"]) is AutostartCommand)
        let off = try KeysCLI.parseAsRoot(["autostart", "--uninstall"])
        XCTAssertTrue(off is AutostartCommand)
    }

    func testLoginItemPlistIsLoopbackMenubar() throws {
        // An ampersand and angle brackets in the path must survive serialization intact.
        let root = try TempDir.make().appendingPathComponent("a&b<c>", isDirectory: true)
        let installer = Installer(
            root: root, agentPlist: root.appendingPathComponent("agent.plist"), label: LoginItem.label,
            run: { _, _ in (0, "", "") }
        )
        let data = try installer.agentPlistData()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.keysreallysafe.menubar")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [root.appendingPathComponent("bin/keys").path, "menubar"])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["KEYS_WEB_ROOT"],
                       root.appendingPathComponent("Web").path)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["Crashed"], true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, root.appendingPathComponent("menubar.log").path)
        XCTAssertEqual(LoginItem.bookmarkURL.absoluteString, "http://127.0.0.1:12766/")
    }
}

/// The explicit legacy `keys menubar` command still creates the status item it
/// was asked for, even though the app-mode menu-bar preference is now off by
/// default. Real AppKit status items with isolated centers and defaults, like
/// the recovery suite, so nothing touches the real menu-bar domains.
@MainActor
final class MenubarCommandItemTests: XCTestCase {
    func testExplicitCommandCreatesItsItemWhileAppModeDefaultIsOff() throws {
        _ = NSApplication.shared
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        XCTAssertFalse(service.preferences.menubarItem, "the app-mode menu-bar item is off by default")
        let server = try LoopbackHTTPServer(port: 0) { _ in HTTPResponse.text(200, "x") }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/")!
        let center = NotificationCenter()
        let defaults = MemoryDefaults()
        let makeItem = {
            MenubarItemController(workspaceCenter: center, appCenter: center,
                                  recoveryDelay: .seconds(5), defaults: defaults)
        }

        // The app-mode default: the preference is off, so no status item exists.
        let appMode = MenubarExtra(service: service, server: server, url: url, makeItemController: makeItem)
        XCTAssertNil(appMode.item, "app mode with the item preference off creates no status item")
        appMode.applicationWillTerminate(Notification(name: Notification.Name("test terminate")))

        // The explicit command: it always creates the status item it requested.
        let cli = MenubarExtra(service: service, server: server, url: url,
                               makeItemController: makeItem, itemVisible: true)
        XCTAssertNotNil(cli.item, "keys menubar creates its requested status item regardless of the app-mode default")
        XCTAssertNotNil(cli.item?.menu, "the explicit command's item carries its menu")
        // Plan windows were removed: the item has a fixed face and its menu no longer offers
        // plan usage or the Claude /usage refresh.
        XCTAssertEqual(cli.item?.button?.title, MenubarFace.title)
        let titles = cli.item?.menu?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains("Plan Usage"))
        XCTAssertFalse(titles.contains("Keep Claude Limits Fresh"))
        XCTAssertTrue(titles.contains("Relay for Cloud Agents"))
        XCTAssertNil(cli.item?.menu?.items.first?.view, "no plan-window panel heads the menu")
        cli.applicationWillTerminate(Notification(name: Notification.Name("test terminate")))
    }
}
