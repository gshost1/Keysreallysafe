import AppKit
import Foundation

/// The status item's fixed face. Plan windows and the per-tool cards it used to carry were
/// removed on 2026-11-03; the item stays for its menu (relay, login, CLI, quit).
enum MenubarFace {
    static let title = "Keysrs"
    static let tooltip = "Keysrs · click for the relay, login and Quit"
}

enum MenubarRuntime {
    @MainActor static var extra: MenubarExtra?
}

enum LoopbackSite {
    static func bind(
        service: KeysService,
        preferredPort: UInt16 = LoginItem.dashboardPort,
        requireGateway: Bool = false,
        gatewayPort: UInt16 = GatewayListener.port
    ) throws -> LoopbackHTTPServer {
        let control = ControlFile.url(beside: service.catalog.path)
        // The ownership check comes before anything is started. Publishing the file is
        // what raised this before, and by then the gateway was already listening with no
        // file that could point at it. A site that needs the gateway refuses outright; a
        // checkout dashboard beside the running app still serves its pages, without the
        // gateway (the app owns that port) and without publishing or removing the app's
        // control file.
        var held: ControlFile.OwnerHeld?
        do {
            try ControlFile.assertPublishable(at: control, takeover: isAppBundle)
        } catch let owner as ControlFile.OwnerHeld {
            if requireGateway { throw owner }
            held = owner
        }
        let web = try WebRoot.find()
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: preferredPort) { request in
            handler.handle(request)
        }
        server.start()
        if let held {
            FileHandle.standardError.write(Data("\(held.description). Serving this dashboard without the gateway.\n".utf8))
            return server
        }
        do {
            _ = try service.startGateway(port: gatewayPort)
            // The installed app is the owner of record: a relaunch or an explicit start
            // replaces the file. A checkout process (the 12765 dev copy) does not, so it
            // cannot point the CLIs at itself and then delete their file on exit.
            try ControlFile.write(
                port: server.boundPort, token: handler.originToken, controlSecret: handler.controlSecret,
                takeover: isAppBundle, to: control
            )
            atexit { ControlFile.remove() }
        } catch {
            // Another site may have published between the check and the write: then no
            // control file points at this gateway, so it must not keep listening.
            if requireGateway || error is ControlFile.OwnerHeld { service.stopGateway() }
            if requireGateway {
                server.stop()
                throw error
            }
            let line = "gateway not started: \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return server
    }

    /// Whether this binary is the installed app, and so the file's owner of record.
    static var isAppBundle: Bool { AppResources.applicationBundle() != nil }
}

@MainActor
final class MenubarExtra: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var appWindow: AppWindowController?
    private let service: KeysService
    private let server: LoopbackHTTPServer
    private let url: URL
    /// Present only while the menu-bar item preference is on. An intentional off
    /// leaves no controller, so no recovery observer exists that could read the
    /// missing item as an accident and re-show it (docs/menubar-recovery.md).
    private var itemController: MenubarItemController?
    var item: NSStatusItem? { itemController?.item }
    private let makeItemController: () -> MenubarItemController
    private var timer: Timer?
    private var appOnlyItems: [NSMenuItem] = []
    private var loginMenuItem: NSMenuItem?
    private var relayItem: NSMenuItem?
    private var relayStatusItem: NSMenuItem?
    private var relayAwakeItem: NSMenuItem?
    private var relaySharedAwakeItem: NSMenuItem?
    /// What a toggle in progress is waiting for (Touch ID, the loop to stop); clicks meanwhile
    /// are ignored.
    private var relayPending: String?
    /// The deferred welcome: headless launch presents nothing, the first window
    /// show runs this. Injectable so the launch tests can prove a headless
    /// launch raises no dialog.
    var presentWelcome: () -> Void = {}

    init(service: KeysService, server: LoopbackHTTPServer, url: URL,
         makeItemController: @escaping () -> MenubarItemController = { MenubarItemController() },
         itemVisible: Bool? = nil) {
        self.service = service
        self.server = server
        self.url = url
        self.makeItemController = makeItemController
        super.init()
        // The app-mode default comes from the persisted preference; the explicit
        // legacy `keys menubar` command passes true so its requested status item
        // is created even while the app-mode item preference is off.
        if itemVisible ?? service.preferences.menubarItem {
            itemController = makeItemController()
        }
        presentWelcome = { [weak self] in self?.showWelcomeIfNeeded() }
        if let item {
            item.menu = buildMenu()
            item.menu?.delegate = self
        }
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The legacy menubar CLI also borrows the dashboard icon.
        if let web = try? WebRoot.find(), let icon = NSImage(contentsOf: web.appendingPathComponent("icon.png")) {
            NSApp.applicationIconImage = icon
        }
        // Headless launch: no window and no welcome here; didLaunch registers the
        // login item and starts the daily update check, and the welcome waits for
        // the first window show.
        appWindow?.didLaunch()
    }

    func applicationDidHide(_ notification: Notification) {
        // ⌘H leaves no visible window either: back to accessory like a close.
        appWindow?.noteWindowHidden()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        itemController?.stop()
        service.stopRelay()
        service.stopGateway()
        server.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    @objc func openDashboard() {
        if let appWindow { appWindow.show() } else { NSWorkspace.shared.open(url) }
    }

    /// The menu-bar item preference, applied live. Creating the controller is the
    /// whole on path (it seeds the item's position and registers its recovery
    /// observers); off stops and releases it, so nothing exists that recovery
    /// could repair — an intentional off is never an accidental disappearance.
    func setMenubarItemShown(_ shown: Bool) {
        if shown {
            guard itemController == nil else { return }
            let controller = makeItemController()
            itemController = controller
            controller.item.menu = buildMenu()
            controller.item.menu?.delegate = self
            refresh()
        } else {
            itemController?.stop()
            itemController = nil
        }
    }

    /// The deferred welcome, as the window show path drives it.
    func presentWelcomeIfNeeded() {
        presentWelcome()
    }

    @objc func quit() {
        service.stopRelay()
        service.stopGateway()
        server.stop()
        NSApp.terminate(nil)
    }

    /// Refresh right before the menu drops down, so the toggles are never a minute stale.
    func menuWillOpen(_ menu: NSMenu) {
        itemController?.menuIsOpen = true
        // The legacy menubar CLI has no app window, login item or bundle to link to.
        appOnlyItems.forEach { $0.isHidden = appWindow == nil }
        loginMenuItem?.state = appWindow?.startsAtLogin == true ? .on : .off
        updateRelayItems()
        refresh()
    }

    @objc func toggleLogin() { appWindow?.toggleLogin() }
    @objc func installCLI() {
        // The confirmation alert would otherwise open behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.installCLI()
    }

    func menuDidClose(_ menu: NSMenu) {
        itemController?.menuDidClose()
    }

    @objc func refresh() {
        itemController?.checkVisibility()
        item?.button?.title = MenubarFace.title
        item?.button?.toolTip = MenubarFace.tooltip
        if let item, item.menu == nil {
            item.menu = buildMenu()
            item.menu?.delegate = self
        }
    }

    /// Status pages for the tracked tools. Public pages, no auth.
    static let statusPages: [(id: String, name: String, url: String)] = [
        ("claude", "Claude", "https://status.anthropic.com"),
        ("openai", "OpenAI / Codex", "https://status.openai.com"),
        ("grok", "Grok", "https://status.x.ai"),
    ]

    @objc func openStatusPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = URL(string: raw) else { return }
        NSWorkspace.shared.open(target)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Keysrs",
            .applicationVersion: AppVersion.current,
            .version: "local key vault · loopback only",
            .credits: NSAttributedString(string: "Secrets live in the Keychain and leave only through a Touch ID grant. The gateway counts the calls made with them. MIT licensed."),
        ])
    }

    // MARK: relay

    /// Turning it on asks for Touch ID in the service, so it runs off the main thread and the
    /// menu bar keeps drawing meanwhile.
    @objc func toggleRelay() {
        guard relayPending == nil else { return }
        let report = service.relayReport()
        if !report.host.on && !report.configured {
            showRelaySetup()
            return
        }
        let enable = !report.host.on
        relayPending = enable ? "Waiting for Touch ID…" : "Turning off…"
        let service = self.service
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { _ = try service.setRelay(enabled: enable) } catch { failure = error }
            let error = failure
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relayPending = nil
                self.updateRelayItems()
                if let error { self.relayAlert(error) }
            }
        }
    }

    @objc func toggleRelayAwake() {
        let on = !service.preferences.relayStayAwake
        do { try service.setRelayStayAwake(on) } catch { relayAlert(error) }
        updateRelayItems()
    }

    @objc func toggleRelayAwakeWhileShared() {
        let on = !service.preferences.relayAwakeWhileShared
        do { try service.setRelayAwakeWhileShared(on) } catch { relayAlert(error) }
        updateRelayItems()
    }

    /// One relay snapshot both surfaces read — the status item's menu and the
    /// app menu while the window is shown — so the two can never diverge.
    struct RelayMenuState {
        var on: Bool
        var line: String
        var awake: Bool
        var awakeWhileShared = false
        var lastError: String?
    }

    func relayMenuState() -> RelayMenuState {
        let report = service.relayReport()
        return RelayMenuState(on: report.host.on,
                              line: relayPending ?? Self.relayLine(report),
                              awake: report.stayAwake,
                              awakeWhileShared: report.awakeWhileShared,
                              lastError: report.host.state.lastError)
    }

    private func updateRelayItems() {
        let state = relayMenuState()
        relayItem?.state = state.on ? .on : .off
        relayStatusItem?.title = state.line
        relayStatusItem?.isHidden = state.line.isEmpty
        relayStatusItem?.toolTip = state.lastError
        relayAwakeItem?.state = state.awake ? .on : .off
        relaySharedAwakeItem?.state = state.awakeWhileShared ? .on : .off
    }

    nonisolated static let sharedAwakeTitle = "Keep Mac Awake While Sharing Keys"
    nonisolated static let sharedAwakeToolTip = "While a share from keys share is live and the relay is on, the Mac does not sleep when idle, but only on its power adapter. The display can still sleep, and closing the lid still sleeps the Mac."

    /// The disabled line under the toggle; empty hides it.
    nonisolated static func relayLine(_ report: KeysService.RelayReport) -> String {
        guard report.host.on else {
            guard let held = report.elsewhere else { return "" }
            return "keys relay is running in a Terminal" + (held.pid.map { " (process \($0))" } ?? "")
        }
        let host = report.url?.host ?? "the Worker"
        var line: String
        switch report.host.state.phase {
        case .connected:
            line = "Connected to \(host)"
            let open = report.host.state.inflight
            if open > 0 { line += " · \(open) call\(open == 1 ? "" : "s") open" }
        case .connecting:
            line = "Connecting to \(host)…"
        case .waiting, .stopped:
            line = "Not connected; retrying"
        }
        if report.host.awake {
            line += report.host.awakeReason == .shared ? " · awake for shared keys" : " · keeping the Mac awake"
        }
        return line
    }

    private func showRelaySetup() {
        let alert = NSAlert()
        alert.messageText = "Set up the relay first"
        alert.informativeText = "The relay connects this Mac to a small Worker you deploy in your own Cloudflare account (Relay/ in the Keysrs repository, docs/relay.md), so cloud agents can reach the gateway. Once it is deployed, run in Terminal:\n\nkeys relay setup --url https://keysrs-relay.<you>.workers.dev\n\nGive the Worker the printed secret with npx wrangler secret put RELAY_SECRET, then turn the relay on here."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func relayAlert(_ error: Error) {
        // Cancelling Touch ID is an answer, not a failure.
        if case AppError.authCancelled = error { return }
        let alert = NSAlert()
        alert.messageText = "Relay for Cloud Agents"
        alert.informativeText = (error as? AppError)?.description ?? error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// First launch only: one window, every box unticked, one Continue button.
    /// Continuing with nothing ticked is a full answer and is never asked again.
    private func showWelcomeIfNeeded() {
        let plan = service.preferences.welcomePlan()
        guard !plan.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Welcome to Keysrs"
        alert.informativeText = "Keysrs keeps running when you close its window. Your API keys stay in the Keychain, and agents reach them only through a Touch ID grant."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Continue and Open Keysrs")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        try? service.preferences.recordWelcome(plan)
        if response == .alertSecondButtonReturn { openDashboard() }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Status Page", action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        for page in Self.statusPages {
            let row = NSMenuItem(title: page.name, action: #selector(openStatusPage(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = page.url
            statusMenu.addItem(row)
        }
        status.submenu = statusMenu
        menu.addItem(status)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Keysrs", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let relay = NSMenuItem(title: "Relay for Cloud Agents", action: #selector(toggleRelay), keyEquivalent: "")
        relay.target = self
        relay.toolTip = "Hold one outbound connection to your relay Worker so cloud agents reach this gateway (docs/relay.md). One Touch ID to turn on; it stays on until you turn it off or quit."
        relayItem = relay
        menu.addItem(relay)
        let relayStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        relayStatus.indentationLevel = 1
        relayStatus.isHidden = true
        relayStatusItem = relayStatus
        menu.addItem(relayStatus)
        let awake = NSMenuItem(title: "Keep Mac Awake for Relay Calls", action: #selector(toggleRelayAwake), keyEquivalent: "")
        awake.target = self
        awake.toolTip = "While a relayed call is open, and for 5 minutes after the last one, the Mac does not sleep when idle. The display can still sleep, and closing the lid still sleeps the Mac."
        relayAwakeItem = awake
        menu.addItem(awake)
        let shared = NSMenuItem(title: Self.sharedAwakeTitle, action: #selector(toggleRelayAwakeWhileShared), keyEquivalent: "")
        shared.target = self
        shared.toolTip = Self.sharedAwakeToolTip
        relaySharedAwakeItem = shared
        menu.addItem(shared)
        menu.addItem(.separator())
        // Also in the app menu, which is only visible while the window is frontmost.
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        loginMenuItem = login
        let cli = NSMenuItem(title: "Install Command Line Tool…", action: #selector(installCLI), keyEquivalent: "")
        cli.target = self
        appOnlyItems = [login, cli]
        appOnlyItems.forEach { menu.addItem($0) }
        let about = NSMenuItem(title: "About Keysrs", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }
}
