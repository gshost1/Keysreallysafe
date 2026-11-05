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
    private var menubarToggleItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var relayAppItem: NSMenuItem?
    private var relayAppStatusItem: NSMenuItem?
    private var relayAppAwakeItem: NSMenuItem?
    private var relayAppSharedAwakeItem: NSMenuItem?
    private var updateTimer: Timer?
    /// A short retry for a scheduled check the shared machine refused, so a
    /// clash with the person's own check costs minutes, not the daily window.
    private var updateRetryPending = false
    /// Bumped whenever the schedule is rebuilt (the setting toggled, the
    /// daily timer replaced): a retry armed under an older schedule does
    /// nothing when it fires.
    private var updateRetryGeneration = 0
    /// Retries left in this daily window. A machine that stays claimed — a
    /// manual install the person left open — must not turn into a check
    /// every five minutes for the rest of the day.
    private var updateRetriesLeft = AppWindowController.updateRetryLimit
    /// How soon a refused scheduled check tries again.
    static let updateRetryInterval: TimeInterval = 5 * 60
    /// How many refused scheduled checks are retried per daily window.
    static let updateRetryLimit = 3
    /// The one update state machine, shared with `BackgroundUpdater`: which path
    /// is checking or installing, and the phase the progress window renders.
    private let coordinator: UpdateCoordinator
    private weak var menubar: MenubarExtra?
    private var installer: UpdateInstaller?
    private var updateWindow: UpdateProgressWindow?
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
    /// The manual offer's answer, injected so a test can choose without a real
    /// dialog; production shows the same three-button alert.
    private let offerChoice: (ReleaseInfo) -> UpdateChoice
    /// The manual Update Now execution, injected so a test observes the choice's
    /// effect without a progress window; production runs the real installer. A
    /// var with a no-op default because the production closure captures self,
    /// which only exists once initialization is done.
    private var runManualInstall: (ReleaseInfo) -> Void = { _ in }
    /// The scheduled check's install half: the quiet wait, the installer, the
    /// notification and the relaunch. Absent only where a rig injects its own;
    /// the manual Check for Updates never touches it.
    private let background: BackgroundUpdater?
    private let log: (String) -> Void
    /// How soon a refused scheduled check tries again. Injected so a test can
    /// observe the retry without waiting minutes.
    private let scheduleRetry: (@escaping @MainActor () -> Void) -> Void

    init(
        url: URL,
        preferences: AppPreferences,
        activation: AppActivation = AppActivation(),
        window: (any DashboardWindow)? = nil,
        presentAlert: ((String, String) -> Void)? = nil,
        registerLoginItem: (() throws -> Void)? = nil,
        latestRelease: (() async throws -> ReleaseInfo)? = nil,
        offerChoice: ((ReleaseInfo) -> UpdateChoice)? = nil,
        startManualUpdate: ((ReleaseInfo) -> Void)? = nil,
        background: BackgroundUpdater? = nil,
        log: ((String) -> Void)? = nil,
        scheduleRetry: ((@escaping @MainActor () -> Void) -> Void)? = nil
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
        self.offerChoice = offerChoice ?? AppWindowController.askUpdateChoice
        self.background = background
        self.log = log ?? { _ in }
        self.scheduleRetry = scheduleRetry ?? AppWindowController.afterRetryInterval
        // The background updater carries the shared machine when one is
        // assembled; a rig without it gets a fresh one, and the two paths still
        // cannot install at once.
        self.coordinator = background?.coordinator ?? UpdateCoordinator()
        super.init()
        // The scheduled path reads the person's setting at every pre-swap
        // boundary, not just when the check began.
        self.coordinator.backgroundAllowed = { [weak self] in self?.preferences.updateChecks ?? false }
        // The production manual install is a weak-self closure so the stored
        // closure does not retain the controller it lives on.
        self.runManualInstall = startManualUpdate ?? { [weak self] release in self?.startUpdate(release) }
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
        // Named explicitly: `NSApp` is only set once something has created the shared
        // application, and nothing else on this path is guaranteed to have.
        let app = NSApplication.shared
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
        relayAppSharedAwakeItem = add(MenubarExtra.sharedAwakeTitle, #selector(MenubarExtra.toggleRelayAwakeWhileShared), extra)
        relayAppSharedAwakeItem?.toolTip = MenubarExtra.sharedAwakeToolTip
        appMenu.addItem(.separator())
        _ = add("Hide Keysrs", #selector(NSApplication.hide(_:)), app, "h")
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
        app.windowsMenu = windowMenu
        app.mainMenu = main
    }

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// The shared update phase, for the menu and for tests: `.idle` means
    /// neither path is checking or installing.
    var updatePhase: UpdateCoordinator.Phase { coordinator.phase }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = startsAtLogin ? .on : .off
        menubarToggleItem?.state = preferences.menubarItem ? .on : .off
        updateItem?.state = preferences.updateChecks ? .on : .off
        if let relay = menubar?.relayMenuState() {
            relayAppItem?.state = relay.on ? .on : .off
            relayAppStatusItem?.title = relay.line
            relayAppStatusItem?.isHidden = relay.line.isEmpty
            relayAppStatusItem?.toolTip = relay.lastError
            relayAppAwakeItem?.state = relay.awake ? .on : .off
            relayAppSharedAwakeItem?.state = relay.awakeWhileShared ? .on : .off
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
        updateRetryPending = false
        updateRetryGeneration += 1
        updateRetriesLeft = Self.updateRetryLimit
        guard preferences.updateChecks else { return }
        checkUpdates(manual: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateRetriesLeft = Self.updateRetryLimit
                self.checkUpdates(manual: false)
            }
        }
    }

    @objc func checkForUpdates() { checkUpdates(manual: true) }

    private func checkUpdates(manual: Bool) {
        let origin: UpdateOrigin = manual ? .manual : .background
        // The bundle was already replaced and only the restart is left: the
        // person's check finishes that update instead of being told the
        // machine is busy, and the scheduled one leaves it alone.
        if case .installedPendingRelaunch = coordinator.phase {
            if manual { finishPendingRestart() }
            else { log("scheduled update check skipped: an installed update is waiting for a restart") }
            return
        }
        // One lookup and one install across both paths: the daily timer, the
        // menu and the dashboard switch all come through here. A refused manual
        // check is not a silent no-op — the person is told — and a refused
        // scheduled one is retried in a few minutes rather than a day later,
        // because it was refused by a run someone else started, not by the
        // person's setting.
        guard let claim = coordinator.beginCheck(origin) else {
            if manual { alert("Update Already in Progress", UpdateCoordinator.busyMessage) }
            else { scheduleUpdateRetry(reason: UpdateCoordinator.busyMessage) }
            return
        }
        Task {
            defer { coordinator.finishCheck(claim) }
            do {
                let release = try await latestRelease()
                if UpdateCheck.isNewer(release.version, than: AppVersion.current) {
                    // Only the person's Check for Updates offers the modal. The
                    // scheduled check runs over a Dock-less app, so it installs
                    // through the background path and raises no dialog; a failed
                    // check on that path is logged, never shown. The check may
                    // have taken seconds, so the person's setting is re-read
                    // here: turning automatic updates off during the lookup
                    // means this release is not installed after all.
                    if manual { offerUpdate(release) }
                    else if preferences.updateChecks {
                        // A check the person's own run took over is not ours to
                        // act on: they are looking at the offer for the same
                        // release, and installing underneath it would race them.
                        guard coordinator.isCurrent(claim) else { return }
                        background?.install(release)
                    }
                } else if manual {
                    alert("Keysrs Is Up to Date", "Keysrs \(AppVersion.current) is the newest release.")
                }
            } catch {
                if manual { alert("Could Not Check for Updates", error.localizedDescription) }
                else { log("scheduled update check failed: \(error.localizedDescription)") }
            }
        }
    }

    /// The scheduled check was refused, so the daily timer's next call is a day
    /// away; a refused lookup is retried in a few minutes, within the same
    /// daily window, because it was refused by a run someone else started rather
    /// than by the person's setting. One retry is pending at a time.
    private func scheduleUpdateRetry(reason: String) {
        log("scheduled update check skipped: \(reason)")
        guard !updateRetryPending, updateRetriesLeft > 0 else { return }
        updateRetryPending = true
        updateRetriesLeft -= 1
        let generation = updateRetryGeneration
        scheduleRetry { [weak self] in
            // A retry armed before the schedule was rebuilt, or one that fires
            // after the person turned automatic updates off, does nothing: the
            // setting is the person's, and the rebuilt schedule owns its own
            // check.
            guard let self, generation == self.updateRetryGeneration else { return }
            self.updateRetryPending = false
            guard self.preferences.updateChecks else { return }
            self.checkUpdates(manual: false)
        }
    }

    /// The production retry: a one-shot timer a few minutes out.
    private static func afterRetryInterval(_ action: @escaping @MainActor () -> Void) {
        Timer.scheduledTimer(withTimeInterval: updateRetryInterval, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    /// The one-click update. Update Now does the whole install from GitHub inside
    /// the app; Release Notes re-offers, Later leaves the app as it is. The
    /// person's answer comes through the injected seam, so the choice is
    /// testable without a real dialog.
    private func offerUpdate(_ release: ReleaseInfo) {
        while true {
            switch offerChoice(release) {
            case .updateNow:
                runManualInstall(release)
                return
            case .releaseNotes:
                if let notes = release.notes { NSWorkspace.shared.open(notes) }
            case .later:
                return
            }
        }
    }

    /// Production's manual offer: the same three buttons the menu always had.
    private static func askUpdateChoice(_ release: ReleaseInfo) -> UpdateChoice {
        let prompt = NSAlert()
        prompt.messageText = "Keysrs \(release.version) is available"
        prompt.informativeText = "You have \(AppVersion.current). Update Now downloads the new version from GitHub, checks its checksum and Apple signature, replaces this copy and restarts. Keys and history are untouched."
        prompt.addButton(withTitle: "Update Now")
        prompt.addButton(withTitle: "Release Notes")
        prompt.addButton(withTitle: "Later")
        switch prompt.runModal() {
        case .alertFirstButtonReturn: return .updateNow
        case .alertSecondButtonReturn: return .releaseNotes
        default: return .later
        }
    }

    private func startUpdate(_ release: ReleaseInfo) {
        // One install at a time across both paths: the scheduled install and
        // Update Now stage beside the same bundle names, so the claim is taken
        // before anything is built. Losing it means the scheduled path got
        // there first, and the person is told rather than left with a click
        // that did nothing. A claim held in `installedPendingRelaunch` is
        // refused the same way: the bundle in place is already the new one.
        guard let claim = coordinator.beginInstall(.manual) else {
            alert("Update Already in Progress", UpdateCoordinator.busyMessage)
            return
        }
        let pending = UpdateInstaller(release: release, app: Bundle.main.bundleURL,
                                      coordinator: coordinator, origin: .manual)
        pending.quit = { [weak self] in
            if let extra = self?.menubar { extra.quit() } else { NSApp.terminate(nil) }
        }
        installer = pending
        let progress = UpdateProgressWindow { [weak self] in self?.installer?.cancel() }
        updateWindow = progress
        coordinator.onChange = { [weak progress] phase in progress?.update(phase) }
        progress.show()
        Task {
            do {
                try await pending.run()
                // The hand-off quits the app, so this is only reached if the
                // quit did not happen. The machine deliberately stays claimed:
                // the new bundle is already in place and a relaunch helper is
                // pending, so a second install must not start beside it.
            } catch {
                updateWindow?.close()
                updateWindow = nil
                installer = nil
                coordinator.onChange = nil
                // Past the swap the claim is never released: the bundle in
                // place is the new one, and the only retry that makes sense is
                // another relaunch. Saying "Could Not Update" there was wrong —
                // it was updated, it did not restart — and releasing the claim
                // let the next check try to set the replaced bundle aside.
                // Not retried here: the spawn just failed, and an immediate
                // second try would hide its error. The next Check for Updates
                // retries the restart.
                if coordinator.phase == .installedPendingRelaunch(.manual) {
                    alert("Keysrs Was Updated", "It could not restart (\(error.localizedDescription)). Choose Check for Updates to try again, or quit and open Keysrs.")
                    return
                }
                coordinator.finish(claim)
                if error is CancellationError || error is UpdateStopped { return }
                alert("Could Not Update", error.localizedDescription)
            }
        }
    }

    /// The bundle was replaced but the restart did not happen. The claim stays
    /// held and the coordinator keeps the restart helper, so the one thing to
    /// retry is the restart — never the install — and a later Check for
    /// Updates comes back here. A person who just quits gets the new version
    /// on the next launch anyway, so the failure is reported as what it is
    /// rather than as a failed update.
    private func finishPendingRestart() {
        do {
            if try coordinator.restartPending() { return }
            alert("Keysrs Was Updated", "Quit and open Keysrs again to finish.")
        } catch {
            alert("Keysrs Was Updated", "\(error.localizedDescription) Quit and open Keysrs again to finish.")
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

/// The person's answer to the manual update offer. The scheduled path never
/// asks: it installs in the background.
enum UpdateChoice: Sendable {
    case updateNow
    case releaseNotes
    case later
}


enum DashboardNavigation {
    static func isLocal(_ target: URL, origin: URL) -> Bool {
        let target = target.scheme == "blob" ? URL(string: String(target.absoluteString.dropFirst(5))) : target
        return target?.scheme == origin.scheme && target?.host == origin.host && target?.port == origin.port
            && target?.user == nil && target?.password == nil
    }
}
