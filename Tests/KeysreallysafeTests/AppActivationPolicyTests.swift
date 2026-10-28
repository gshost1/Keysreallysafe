import AppKit
import XCTest
@testable import KeysCore

/// The headless launch contract: the app starts `.accessory` with no window and
/// no welcome, becomes `.regular` only while the dashboard window is visible,
/// and returns to `.accessory` on close or hide — its services running
/// throughout. Everything drives the injected seams (activation recorder, fake
/// window, fake welcome, isolated item centers) against a real handler on a
/// temp catalog; no AppKit window is created, shown or focused.
@MainActor
final class AppActivationPolicyTests: XCTestCase {
    private var rig: HeadlessAppRig?

    override func tearDown() async throws {
        rig?.stop()
        rig = nil
        try await super.tearDown()
    }

    func testActivationFollowsWindowVisibilityInOrder() {
        var applied: [AppActivation.Policy] = []
        let activation = AppActivation(apply: { applied.append($0) })
        XCTAssertEqual(applied, [.accessory], "a launch applies its resting policy for real: NSApp defaults to regular")
        XCTAssertEqual(activation.current, .accessory)
        activation.windowShown()
        XCTAssertEqual(applied, [.accessory, .regular])
        activation.windowShown()
        XCTAssertEqual(applied, [.accessory, .regular], "a repeated show does not re-apply the policy")
        activation.windowHidden()
        XCTAssertEqual(applied, [.accessory, .regular, .accessory])
        activation.windowHidden()
        XCTAssertEqual(applied, [.accessory, .regular, .accessory], "a repeated hide is a no-op too")
        activation.windowShown()
        XCTAssertEqual(applied, [.accessory, .regular, .accessory, .regular])
    }

    func testHeadlessLaunchIsAccessoryWithNoWindowOrWelcomeAndServicesStart() throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        XCTAssertEqual(rig.appliedPolicies, [.accessory], "launch applies accessory, nothing more")
        XCTAssertFalse(rig.window.orderedFront, "no dashboard window is shown at launch")
        XCTAssertFalse(rig.welcomeShown, "the first-run welcome is deferred, not raised over the headless launch")
        XCTAssertTrue(rig.ingestScheduled, "the ingest scheduler starts although the meter and the window are hidden")
        XCTAssertTrue(rig.openRouterScheduled)
        XCTAssertTrue(rig.initialIngestQueued)
        // The headless defaults are in force after the launch migration.
        XCTAssertFalse(rig.preferences.showUsageMeter)
        XCTAssertFalse(rig.preferences.menubarItem)
        XCTAssertTrue(rig.preferences.updateChecks, "Install updates automatically is on by default")
        // A headless app is a running site: its status answer works with no window.
        XCTAssertTrue(rig.siteAnswers())
    }

    func testReopenShowsTheWindowBecomesRegularAndRunsTheDeferredWelcome() async throws {
        let rig = try HeadlessAppRig(freshWelcome: true)
        self.rig = rig
        rig.launch()
        XCTAssertFalse(rig.welcomeShown, "launch defers the welcome")
        XCTAssertTrue(rig.extra.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular])
        XCTAssertEqual(rig.window.orderedFrontCount, 1, "Spotlight or Applications reopen shows the app's own window")
        // The welcome runs after the show returns, so a remote caller is not
        // blocked behind its modal answer.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(rig.welcomeShown, "the deferred welcome appears when the window is first shown")
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular])
    }

    func testClosingHidesToAccessoryAndKeepsAppAndServicesAlive() throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        XCTAssertTrue(rig.extra.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular])
        // The person closes the window: the real window's delegate path fires onClosed.
        rig.window.close()
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular, .accessory], "closing returns to accessory")
        XCTAssertEqual(rig.quitCalls, 0, "closing the window is not Quit")
        XCTAssertTrue(rig.siteAnswers(), "the site still answers with no window")
        // And the same window can be shown again.
        XCTAssertTrue(rig.extra.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular, .accessory, .regular])
        XCTAssertEqual(rig.window.orderedFrontCount, 2)
    }

    func testHidingTheAppAlsoReturnsToAccessory() throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        XCTAssertTrue(rig.extra.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        rig.extra.applicationDidHide(Notification(name: Notification.Name("test hide")))
        XCTAssertEqual(rig.appliedPolicies, [.accessory, .regular, .accessory], "⌘H hides to accessory like a close")
        XCTAssertTrue(rig.siteAnswers(), "hiding the app stops no service")
    }

    func testHeadlessLaunchDefersTheLoginErrorUntilTheWindowIsShown() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = AppPreferences(catalog: db)
        let window = FakeDashboardWindow()
        var alerts: [String] = []
        let checks = CallCounter()
        let controller = AppWindowController(
            url: URL(string: "http://127.0.0.1:1/")!,
            preferences: prefs,
            activation: AppActivation(apply: { _ in }),
            window: window,
            presentAlert: { title, _ in alerts.append(title) },
            registerLoginItem: { throw AppError.http("registration refused") },
            latestRelease: {
                checks.record()
                return ReleaseInfo(version: "99.0.0",
                                   dmg: URL(string: "https://example.com/Keysrs-arm64.dmg")!,
                                   checksum: nil, expectedBytes: nil, notes: nil)
            }
        )
        controller.didLaunch()
        XCTAssertTrue(alerts.isEmpty, "a headless launch raises no app-owned alert")
        XCTAssertFalse(prefs.loginRegistrationAttempted, "a failed registration is retried next launch, not recorded")
        // The daily check runs by default and finds an update, but the manual
        // offer never opens over a Dock-less app.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(checks.calls, 1, "the default-on daily check still ran")
        XCTAssertTrue(alerts.isEmpty, "the scheduled update check raises no dialog")

        controller.show()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(alerts, ["Start at Login"], "the deferred login error appears with the first window")
        XCTAssertEqual(window.orderedFrontCount, 1)
    }

    func testMenuBarPreferenceOffMeansNoItemAndNoRecoveryResurrection() async throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        XCTAssertNil(rig.extra.item, "the menu-bar item is off by default: no status item is created")
        // A wake or a refresh tick must not read the intentional off as an
        // accidental disappearance and recreate the item.
        rig.extra.refresh()
        rig.postItemTransition(NSWorkspace.screensDidWakeNotification)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(rig.extra.item)
        XCTAssertTrue(rig.siteAnswers(), "hiding the item does not stop app services")

        // Turning it on restores the existing status-item behavior, with its menu.
        rig.extra.setMenubarItemShown(true)
        let item = try XCTUnwrap(rig.extra.item)
        XCTAssertTrue(item.isVisible)
        XCTAssertNotNil(item.menu)
        let original = item
        // With the preference on, the recovery behavior stays available: a wake
        // transition replaces the item (docs/menubar-recovery.md).
        rig.postItemTransition(NSWorkspace.didWakeNotification)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(rig.extra.item === original, "recovery still works while the preference is on")
        XCTAssertTrue(try XCTUnwrap(rig.extra.item).isVisible)

        // Turning it off again removes the item, and recovery stays quiet after it.
        rig.extra.setMenubarItemShown(false)
        XCTAssertNil(rig.extra.item)
        rig.postItemTransition(NSWorkspace.screensDidWakeNotification)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(rig.extra.item, "recovery never re-shows an item the person turned off")
    }

    func testAppMenuExposesTheSettingsTogglesRelayAndQuit() throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(menu.item(at: 0)?.submenu)
        func item(_ title: String) -> NSMenuItem? {
            (0..<appMenu.numberOfItems).compactMap { appMenu.item(at: $0) }.first { $0.title == title }
        }
        XCTAssertEqual(item("About Keysrs")?.action, #selector(MenubarExtra.showAbout))
        XCTAssertEqual(item("Quit Keysrs")?.action, #selector(MenubarExtra.quit), "Quit stays in the app menu while the window is shown")
        XCTAssertEqual(item("Relay for Cloud Agents")?.action, #selector(MenubarExtra.toggleRelay))
        XCTAssertEqual(item("Keep Mac Awake for Relay Calls")?.action, #selector(MenubarExtra.toggleRelayAwake))
        XCTAssertNotNil(item("Show Usage Meter"))
        XCTAssertNotNil(item("Show Menu Bar Item"))
        XCTAssertNotNil(item("Install Updates Automatically"), "the old label is now the install setting")

        // The same persisted values the dashboard reads drive the menu states.
        rig.extra.appWindow?.menuWillOpen(appMenu)
        XCTAssertEqual(item("Show Usage Meter")?.state, rig.preferences.showUsageMeter ? .on : .off)
        XCTAssertEqual(item("Show Menu Bar Item")?.state, rig.preferences.menubarItem ? .on : .off)
        XCTAssertEqual(item("Install Updates Automatically")?.state, rig.preferences.updateChecks ? .on : .off)
        // The app menu carries the same relay state the status item's menu does.
        XCTAssertEqual(item("Relay for Cloud Agents")?.state, .off)
        XCTAssertNotNil(item("Keep Mac Awake for Relay Calls"))
        // A toggle through the menu writes the shared store the dashboard reads.
        rig.extra.appWindow?.toggleMenubarItem()
        XCTAssertTrue(rig.preferences.menubarItem)
        XCTAssertNotNil(rig.extra.item, "the menu toggle drives the same live path as Settings")
    }

    func testDashboardQuitAnswersBeforeTerminationIsDispatched() throws {
        let rig = try HeadlessAppRig()
        self.rig = rig
        rig.launch()
        let response = handle(rig.handler, method: "POST", path: "/api/app/quit")
        XCTAssertEqual(response.status, 200, "the dashboard Quit answers success before termination")
        XCTAssertEqual(rig.quitCalls, 0, "no shutdown runs inside the request handler")
        XCTAssertEqual(rig.quitScheduler.actions.count, 1, "the shutdown is dispatched for after the response")
        rig.quitScheduler.actions.forEach { $0() }
        XCTAssertEqual(rig.quitCalls, 1, "the scheduled action is the app's own shutdown")
    }
}

/// One assembled headless app over a temp catalog, with every presentation side
/// effect recorded instead of performed.
@MainActor
final class HeadlessAppRig {
    let handler: APIHandler
    let service: KeysService
    let server: LoopbackHTTPServer
    let window: FakeDashboardWindow
    let itemCenter = NotificationCenter()
    private let quitCounter: CallCounter
    var extra: MenubarExtra!
    var appliedPolicies: [AppActivation.Policy] = []
    var ingestScheduled = false
    var openRouterScheduled = false
    var initialIngestQueued = false
    var welcomeShown = false
    /// Shutdown actions the Quit route dispatched, in order: the route must
    /// return its 200 before any of these run.
    let quitScheduler: QuitScheduler
    private var launched = false

    init(freshWelcome: Bool = false) throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        self.service = service
        let quitCounter = CallCounter()
        self.quitCounter = quitCounter
        let quitScheduler = QuitScheduler()
        self.quitScheduler = quitScheduler
        if !freshWelcome {
            // A store that already answered the welcome: the deferred welcome has
            // nothing to ask, so only a fresh store can prove the deferral.
            try service.preferences.recordWelcome(service.preferences.welcomePlan(analyticsEnabled: true), claudeRefresh: false)
        }
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><head></head><title>Keysrs</title></html>".write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let handler = APIHandler(
            service: service, webRoot: web,
            quitApp: { { quitCounter.record() } },
            scheduleQuit: { [quitScheduler] in quitScheduler.schedule($0) }
        )
        self.handler = handler
        server = try LoopbackHTTPServer(port: 0) { [handler] request in handler.handle(request) }
        server.start()
        window = FakeDashboardWindow()
        _ = db
    }

    var quitCalls: Int { quitCounter.calls }

    var preferences: AppPreferences { service.preferences }

    func launch() {
        guard !launched else { return }
        launched = true
        extra = AppRuntime.assembleApp(
            service: service,
            server: server,
            url: URL(string: "http://127.0.0.1:\(server.boundPort)/")!,
            activationApplier: { [weak self] policy in self?.appliedPolicies.append(policy) },
            window: window,
            makeItemController: { [itemCenter] in
                // Isolated centers and defaults, so the suite never touches the
                // real menu-bar domains and recovery runs at test speed.
                MenubarItemController(workspaceCenter: itemCenter, appCenter: itemCenter,
                                      recoveryDelay: .milliseconds(20), defaults: MemoryDefaults())
            },
            scheduleIngest: { [weak self] _ in self?.ingestScheduled = true },
            scheduleOpenRouter: { [weak self] _ in self?.openRouterScheduled = true },
            ingestInitially: { [weak self] _ in self?.initialIngestQueued = true }
        )
        extra.presentWelcome = { [weak self] in self?.welcomeShown = true }
    }

    func postItemTransition(_ name: Notification.Name) {
        itemCenter.post(name: name, object: nil)
    }

    /// The site still serves its status answer, i.e. no background service stopped.
    func siteAnswers() -> Bool {
        handle(handler, method: "GET", path: "/api/status").status == 200
    }

    func stop() {
        if let extra, launched {
            // The app's own shutdown path, so no timer, item or delegate leaks.
            extra.applicationWillTerminate(Notification(name: Notification.Name("test terminate")))
        }
        server.stop()
        MenubarRuntime.extra = nil
        NSApp.delegate = nil
        NSApp.mainMenu = nil
    }
}

/// The window fake: records ordering, and close fires the same callback the real
/// NSWindow delegate path uses.
@MainActor
final class FakeDashboardWindow: DashboardWindow {
    var orderedFront = false
    var orderedFrontCount = 0
    var onClosed: (() -> Void)?
    var nsWindow: NSWindow? { nil }

    func orderFront() {
        orderedFront = true
        orderedFrontCount += 1
    }

    func close() {
        onClosed?()
    }
}

/// A shareable counter an injected seam can bump before the rig exists as a whole.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var calls: Int { lock.withLock { stored } }
    func record() { lock.withLock { stored += 1 } }
}

/// Records the shutdown actions a Quit route scheduled, so a test can prove the
/// route answered before running any of them.
final class QuitScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [() -> Void] = []
    var actions: [() -> Void] { lock.withLock { stored } }
    func schedule(_ action: @escaping () -> Void) { lock.withLock { stored.append(action) } }
}
