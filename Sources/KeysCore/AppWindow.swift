import AppKit
import Foundation
import ServiceManagement
import WebKit

@MainActor
final class AppWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSMenuDelegate {
    private let url: URL
    private let preferences: AppPreferences
    private let activation: AppActivation
    private let window: any DashboardWindow
    private var loginItem: NSMenuItem?
    private var meterItem: NSMenuItem?
    private var menubarToggleItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var relayAppItem: NSMenuItem?
    private var relayAppStatusItem: NSMenuItem?
    private var relayAppAwakeItem: NSMenuItem?
    private var updateTimer: Timer?
    private var checking = false
    private weak var menubar: MenubarExtra?
    private var installer: UpdateInstaller?
    private var updateWindow: UpdateProgressWindow?
    private var updating = false
    /// App-owned alerts raised before a window existed (a failed login
    /// registration). Headless launch must present nothing, so they wait for the
    /// first window show instead of popping over a Dock-less app.
    private var deferredAlerts: [(title: String, text: String)] = []
    /// The modal presenter and login registration, injected so the headless
    /// launch contract is testable without a real NSAlert or SMAppService call.
    private let presentAlert: (String, String) -> Void
    private let registerLoginItem: () throws -> Void
    /// The release lookup, injected so a launch test never reaches the network.
    private let latestRelease: () async throws -> ReleaseInfo

    init(
        url: URL,
        preferences: AppPreferences,
        activation: AppActivation = AppActivation(),
        window: (any DashboardWindow)? = nil,
        presentAlert: ((String, String) -> Void)? = nil,
        registerLoginItem: (() throws -> Void)? = nil,
        latestRelease: (() async throws -> ReleaseInfo)? = nil
    ) {
        self.url = url
        self.preferences = preferences
        self.activation = activation
        self.window = window ?? AppKitDashboardWindow(url: url)
        self.presentAlert = presentAlert ?? { title, text in
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
        }
        self.registerLoginItem = registerLoginItem ?? { try SMAppService.mainApp.register() }
        self.latestRelease = latestRelease ?? { try await UpdateCheck.latestRelease() }
        super.init()
        if let real = self.window as? AppKitDashboardWindow {
            real.configure = { [weak self] web in
                web.navigationDelegate = self
                web.uiDelegate = self
            }
        }
        // Closing the window is not Quit: activation returns to accessory and
        // the app's services keep running until an explicit Quit.
        self.window.onClosed = { [weak self] in self?.activation.windowHidden() }
    }

    func show() {
        activation.windowShown()
        window.orderFront()
        // The deferred welcome and any launch-time error wait for a visible
        // window; both run after the show returns, so a remote caller
        // (MCP open_app) is not blocked behind a modal answer.
        let present = menubar?.presentWelcome
        let deferred = deferredAlerts
        deferredAlerts = []
        DispatchQueue.main.async { [weak self] in
            present?()
            for note in deferred { self?.presentAlert(note.title, note.text) }
        }
    }

    /// Hide (⌘H) also leaves no visible window: same accessory return as close.
    func noteWindowHidden() {
        activation.windowHidden()
    }

    func didLaunch() {
        // Headless launch: no window is shown here. The app registers its login
        // item and starts the daily update check as background work; the window
        // appears only when a show path asks for it.
        if !preferences.loginRegistrationAttempted {
            do {
                try registerLoginItem()
                try preferences.recordLoginRegistration()
            } catch { deferAlert("Start at Login", "Registration could not finish. Try Start at Login from the Keysrs menu. \(error.localizedDescription)") }
        }
        scheduleUpdates()
    }

    /// A launch-time app-owned alert: shown at once only when a window is
    /// already visible, otherwise held until the first show. A headless launch
    /// never raises a modal.
    private func deferAlert(_ title: String, _ text: String) {
        if activation.current == .regular { presentAlert(title, text) }
        else { deferredAlerts.append((title, text)) }
    }

    func installMenu(extra: MenubarExtra) {
        menubar = extra
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Keysrs")
        appMenu.delegate = self
        func add(_ title: String, _ action: Selector, _ target: AnyObject, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            appMenu.addItem(item)
            return item
        }
        _ = add("About Keysrs", #selector(MenubarExtra.showAbout), extra)
        _ = add("Open Keysrs", #selector(MenubarExtra.openDashboard), extra, "0")
        appMenu.addItem(.separator())
        loginItem = add("Start at Login", #selector(toggleLogin), self)
        _ = add("Install Command Line Tool…", #selector(installCLI), self)
        appMenu.addItem(.separator())
        meterItem = add("Show Usage Meter", #selector(toggleShowUsageMeter), self)
        menubarToggleItem = add("Show Menu Bar Item", #selector(toggleMenubarItem), self)
        appMenu.addItem(.separator())
        _ = add("Check for Updates…", #selector(checkForUpdates), self)
        updateItem = add("Install Updates Automatically", #selector(toggleUpdates), self)
        appMenu.addItem(.separator())
        // The same relay controls the menu bar item carries; the app menu is
        // what is visible while the window is shown and the item may be off.
        relayAppItem = add("Relay for Cloud Agents", #selector(MenubarExtra.toggleRelay), extra)
        let relayStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        relayStatus.indentationLevel = 1
        relayStatus.isHidden = true
        appMenu.addItem(relayStatus)
        relayAppStatusItem = relayStatus
        relayAppAwakeItem = add("Keep Mac Awake for Relay Calls", #selector(MenubarExtra.toggleRelayAwake), extra)
        appMenu.addItem(.separator())
        _ = add("Hide Keysrs", #selector(NSApplication.hide(_:)), NSApp, "h")
        _ = add("Quit Keysrs", #selector(MenubarExtra.quit), extra, "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = startsAtLogin ? .on : .off
        meterItem?.state = preferences.showUsageMeter ? .on : .off
        menubarToggleItem?.state = preferences.menubarItem ? .on : .off
        updateItem?.state = preferences.updateChecks ? .on : .off
        if let relay = menubar?.relayMenuState() {
            relayAppItem?.state = relay.on ? .on : .off
            relayAppStatusItem?.title = relay.line
            relayAppStatusItem?.isHidden = relay.line.isEmpty
            relayAppStatusItem?.toolTip = relay.lastError
            relayAppAwakeItem?.state = relay.awake ? .on : .off
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
            try preferences.recordLoginRegistration()
        } catch { alert("Start at Login", error.localizedDescription) }
    }

    @objc func toggleShowUsageMeter() {
        do { try preferences.setShowUsageMeter(!preferences.showUsageMeter) }
        catch { alert("Show Usage Meter", error.localizedDescription) }
    }

    @objc func toggleMenubarItem() {
        let on = !preferences.menubarItem
        do {
            try preferences.setMenubarItem(on)
            menubar?.setMenubarItemShown(on)
        } catch { alert("Menu Bar Item", error.localizedDescription) }
    }

    @objc func installCLI() {
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/keys")
        let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        let prompt = NSAlert()
        prompt.messageText = "Install Command Line Tool"
        prompt.informativeText = "Create \(destination.path) pointing to this app. Add ~/.local/bin to your shell PATH if needed. Moving Keysrs.app afterwards requires reinstalling this link."
        if let existing, existing != Bundle.main.executableURL!.path {
            prompt.informativeText += "\n\nReplace the existing symbolic link to \(existing)? Regular files are never replaced."
        }
        prompt.addButton(withTitle: "Install"); prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        do {
            try CommandLineLink.install(binary: Bundle.main.executableURL!, destination: destination, replacingSymbolicLink: existing)
            alert("Command Line Tool Installed", "Run keys --help from your terminal. Ensure ~/.local/bin is on PATH.")
        } catch { alert("Command Line Tool", "\(error.localizedDescription) Choose a writable ~/.local/bin directory; Keysrs does not request administrator access or replace an existing tool.") }
    }

    @objc private func toggleUpdates() {
        applyUpdateChecks(!preferences.updateChecks)
    }

    /// The one setter behind both the app menu and the dashboard Settings
    /// switch: the persisted choice plus the scheduler that follows it.
    func applyUpdateChecks(_ on: Bool) {
        do { try preferences.setUpdateChecks(on); scheduleUpdates() }
        catch { alert("Updates", error.localizedDescription) }
    }

    private func scheduleUpdates() {
        updateTimer?.invalidate()
        guard preferences.updateChecks else { return }
        checkUpdates(manual: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkUpdates(manual: false) }
        }
    }

    @objc private func checkForUpdates() { checkUpdates(manual: true) }

    private func checkUpdates(manual: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                let release = try await latestRelease()
                if UpdateCheck.isNewer(release.version, than: ProductAnalyticsConfiguration.appVersion) {
                    // Only the person's Check for Updates offers the modal. The
                    // scheduled check runs at headless launch, so it never raises
                    // an app-owned dialog over a Dock-less app; its install path
                    // is the background updater.
                    if manual { offerUpdate(release) }
                } else if manual {
                    alert("Keysrs Is Up to Date", "Keysrs \(ProductAnalyticsConfiguration.appVersion) is the newest release.")
                }
            } catch { if manual { alert("Could Not Check for Updates", error.localizedDescription) } }
        }
    }

    /// The one-click update. Update Now does the whole install from GitHub inside the app.
    private func offerUpdate(_ release: ReleaseInfo) {
        let prompt = NSAlert()
        prompt.messageText = "Keysrs \(release.version) is available"
        prompt.informativeText = "You have \(ProductAnalyticsConfiguration.appVersion). Update Now downloads the new version from GitHub, checks its checksum and Apple signature, replaces this copy and restarts. Keys and history are untouched."
        prompt.addButton(withTitle: "Update Now")
        prompt.addButton(withTitle: "Release Notes")
        prompt.addButton(withTitle: "Later")
        while true {
            switch prompt.runModal() {
            case .alertFirstButtonReturn:
                startUpdate(release)
                return
            case .alertSecondButtonReturn:
                if let notes = release.notes { NSWorkspace.shared.open(notes) }
            default:
                return
            }
        }
    }

    private func startUpdate(_ release: ReleaseInfo) {
        guard !updating else { return }
        updating = true
        let pending = UpdateInstaller(release: release, app: Bundle.main.bundleURL)
        pending.report = { [weak self] phase in self?.updateWindow?.update(phase) }
        pending.quit = { [weak self] in
            if let extra = self?.menubar { extra.quit() } else { NSApp.terminate(nil) }
        }
        installer = pending
        updateWindow = UpdateProgressWindow { [weak self] in self?.installer?.cancel() }
        updateWindow?.show()
        Task {
            do { try await pending.run() }
            catch {
                updateWindow?.close()
                updateWindow = nil
                installer = nil
                updating = false
                if error is CancellationError { return }
                alert("Could Not Update", error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        presentAlert(title, text)
    }

    // Keep API-origin privileges inside our loopback page. External links use the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        if DashboardNavigation.isLocal(target, origin: url) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        } else {
            if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(target.scheme ?? "") {
                NSWorkspace.shared.open(target)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = navigationAction.request.url, ["https", "http"].contains(target.scheme ?? "") {
            NSWorkspace.shared.open(target)
        }
        return nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        guard let window = window.nsWindow else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        alert("Download Failed", error.localizedDescription)
    }

}


enum DashboardNavigation {
    static func isLocal(_ target: URL, origin: URL) -> Bool {
        let target = target.scheme == "blob" ? URL(string: String(target.absoluteString.dropFirst(5))) : target
        return target?.scheme == origin.scheme && target?.host == origin.host && target?.port == origin.port
            && target?.user == nil && target?.password == nil
    }
}
