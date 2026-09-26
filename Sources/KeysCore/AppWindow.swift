import AppKit
import Foundation
import ServiceManagement
import WebKit

@MainActor
final class AppWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSMenuDelegate {
    private let url: URL
    private let preferences: AppPreferences
    private var window: NSWindow?
    private var loginItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var updateTimer: Timer?
    private var checking = false

    init(url: URL, preferences: AppPreferences) {
        self.url = url
        self.preferences = preferences
    }

    func show() {
        if window == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.navigationDelegate = self
            web.uiDelegate = self
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Keysrs"
            created.minSize = NSSize(width: 760, height: 560)
            created.isReleasedWhenClosed = false
            created.contentView = web
            created.center()
            window = created
            web.load(URLRequest(url: url))
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func didLaunch() {
        show()
        if !preferences.loginRegistrationAttempted {
            do {
                try SMAppService.mainApp.register()
                try preferences.recordLoginRegistration()
            } catch { alert("Start at Login", "Registration could not finish. Try Start at Login from the Keysrs menu. \(error.localizedDescription)") }
        }
        scheduleUpdates()
    }

    func installMenu(extra: MenubarExtra) {
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
        _ = add("Check for Updates…", #selector(checkForUpdates), self)
        updateItem = add("Automatically Check for Updates", #selector(toggleUpdates), self)
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

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateItem?.state = preferences.updateChecks ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
            try preferences.recordLoginRegistration()
        } catch { alert("Start at Login", error.localizedDescription) }
    }

    @objc private func installCLI() {
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
        do { try preferences.setUpdateChecks(!preferences.updateChecks); scheduleUpdates() }
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
                let latest = try await UpdateCheck.latestVersion()
                if manual || UpdateCheck.isNewer(latest, than: ProductAnalyticsConfiguration.appVersion) {
                    alert("Keysrs Updates", "Installed: \(ProductAnalyticsConfiguration.appVersion)\nLatest release: \(latest)\nDownloads are available at github.com/gshost1/Keysreallysafe/releases. Keysrs does not download or install updates.")
                }
            } catch { if manual { alert("Could Not Check for Updates", error.localizedDescription) } }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
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
        guard let window else { completionHandler(nil); return }
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
