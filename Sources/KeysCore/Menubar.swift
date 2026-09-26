import AppKit
import Foundation

struct MenubarSnapshot: Equatable {
    var title: String
    var tooltip: String
    /// One card per subscription with a plan window, in menubar order. Feeds the dropdown panel.
    var cards: [ToolCard] = []
    var spendLine: String = ""

    struct Window: Equatable {
        var label: String
        var pctUsed: Int
        var resetsAt: String?
    }

    struct ToolCard: Equatable {
        var id: String
        var name: String
        var plan: String?
        var windows: [Window]
        var note: String?
        var usdLine: String?

        var overviewWindow: Window? {
            if id == "claude" { return windows.first { $0.label == "Claude Fable" } }
            return windows.last { $0.label.hasSuffix("weekly") } ?? windows.first
        }
    }

    /// Title: Claude's Fable percentage, other tools' weekly percentages.
    /// Percentages are used quota, directly from local snapshots. Grok's dollars are the
    /// week's local spend the Grok status row already carries.
    static func from(_ status: LiveStatus?, now: Date = Date()) -> MenubarSnapshot {
        let grok = status?.grok ?? status?.plans.first { $0.source == "grok" }
        let spendLine = "Grok \(formatUsd(grok?.weeklyUsd ?? 0)) this week"
        var parts: [String] = []
        var tooltip: [String] = [spendLine]
        var cards: [ToolCard] = []
        if let status {
            let claude = status.claude ?? status.plans.first { $0.source == "claude" }
            let codex = status.plans.first { $0.source == "openai" }
            for (letter, name, tool) in [("C", "Claude", claude), ("X", "Codex", codex), ("G", "Grok", grok)] {
                guard let tool else { continue }
                if tool.source == "claude" {
                    parts.append(tool.fablePct.map { "\(letter) \($0)%" } ?? "\(letter) —")
                } else if let week = tool.weeklyPct {
                    parts.append("\(letter) \(week)%")
                }
                var windows: [Window] = []
                if let five = tool.fiveHourPct {
                    windows.append(Window(label: "\(name) 5-hour", pctUsed: five, resetsAt: tool.fiveHourResetsAt))
                }
                if let fable = tool.fablePct, tool.source == "claude" {
                    windows.append(Window(label: "Claude Fable", pctUsed: fable, resetsAt: tool.fableResetsAt))
                }
                if let week = tool.weeklyPct {
                    windows.append(Window(label: "\(name) weekly", pctUsed: week, resetsAt: tool.weeklyResetsAt))
                }
                tooltip += windows.map { "\($0.label) \($0.pctUsed)% used" }
                if tool.source == "claude", tool.fablePct == nil { tooltip.append("Claude Fable unavailable") }
                cards.append(ToolCard(
                    id: tool.source,
                    name: name,
                    plan: tool.plan,
                    windows: windows,
                    note: tool.usageNote,
                    usdLine: letter == "G" ? spendLine : nil
                ))
            }
        }
        tooltip.append("plan windows · usage used · click for resets and spend")
        return MenubarSnapshot(
            title: parts.isEmpty ? "—" : parts.joined(separator: "  "),
            tooltip: tooltip.joined(separator: " · "),
            cards: cards,
            spendLine: spendLine
        )
    }

    /// `Resets today, 14:05` · `Resets tomorrow, 02:01` · `Resets 11 Sep at 09:45`. Local time.
    static func resetsLabel(_ iso: String?, now: Date, calendar: Calendar = .current) -> String {
        guard let iso, let date = UTC.parse(iso) else { return "" }
        if date <= now { return "Reset due" }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: now) { return "Resets today, \(time.string(from: date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Resets tomorrow, \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "d MMM"
        return "Resets \(day.string(from: date)) at \(time.string(from: date))"
    }

    static func formatUsd(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
}

enum MenubarRuntime {
    @MainActor static var extra: MenubarExtra?
}

enum LoopbackSite {
    static func bind(service: KeysService, preferredPort: UInt16 = LoginItem.dashboardPort) throws -> LoopbackHTTPServer {
        let web = try WebRoot.find()
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: preferredPort) { request in
            handler.handle(request)
        }
        server.start()
        do {
            _ = try service.startGateway()
            try ControlFile.write(
                port: server.boundPort, token: handler.originToken, to: ControlFile.url(beside: service.catalog.path)
            )
            atexit { ControlFile.remove() }
        } catch {
            let line = "gateway not started: \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return server
    }
}

@MainActor
final class MenubarExtra: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let service: KeysService
    private let server: LoopbackHTTPServer
    private let url: URL
    private let itemController: MenubarItemController
    private var item: NSStatusItem { itemController.item }
    private var timer: Timer?
    private var lastSnapshot: MenubarSnapshot?
    private var updatedAt: Date?
    private let panel = MenubarPanel()
    private var claudeRefreshItem: NSMenuItem?
    private static let tabKey = "menubar.tab"

    init(service: KeysService, server: LoopbackHTTPServer, url: URL) {
        self.service = service
        self.server = server
        self.url = url
        self.itemController = MenubarItemController()
        super.init()
        panel.selectedTab = UserDefaults.standard.string(forKey: Self.tabKey) ?? "overview"
        panel.onSelect = { [weak self] id in
            UserDefaults.standard.set(id, forKey: Self.tabKey)
            self?.renderPanel()
        }
        item.menu = buildMenu()
        item.menu?.delegate = self
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
        // There is no app bundle to carry an icon, so the About panel
        // would show the generic executable one; borrow the dashboard's copy.
        if let web = try? WebRoot.find(), let icon = NSImage(contentsOf: web.appendingPathComponent("icon.png")) {
            NSApp.applicationIconImage = icon
        }
        // After the run loop starts, so the status item is already in the menu bar.
        DispatchQueue.main.async { [weak self] in self?.showWelcomeIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        itemController.stop()
        service.stopGateway()
        server.stop()
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(url)
    }

    @objc func ingestNow() {
        // An explicit Refresh also asks Claude Code for its limits once, whether or
        // not the background refresh is on: the person asked for it.
        ClaudeUsageRefresh.enqueue(home: service.claudeHome) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        // Never on the main thread: a pass over a large log tree would freeze the menu bar.
        let queued = IngestScheduler.enqueue(service: service) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        if !queued { refresh() }   // a pass is already running and will refresh when it lands
    }

    @objc func quit() {
        service.stopGateway()
        server.stop()
        NSApp.terminate(nil)
    }

    /// Refresh right before the menu drops down, so the rows are never a minute stale.
    func menuWillOpen(_ menu: NSMenu) {
        itemController.menuIsOpen = true
        claudeRefreshItem?.state = service.preferences.claudeUsageRefresh ? .on : .off
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        itemController.menuDidClose()
    }

    @objc func refresh() {
        itemController.checkVisibility()
        if service.preferences.claudeUsageRefresh {
            ClaudeUsageRefresh.enqueue(home: service.claudeHome) { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        let snap = MenubarSnapshot.from(try? service.liveStatus())
        item.button?.title = snap.title
        item.button?.toolTip = snap.tooltip
        lastSnapshot = snap
        updatedAt = Date()
        renderPanel()
        if item.menu == nil {
            item.menu = buildMenu()
            item.menu?.delegate = self
        }
    }

    private func renderPanel() {
        guard let snap = lastSnapshot else { return }
        panel.render(snapshot: snap, updatedAt: updatedAt ?? Date())
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
            .applicationVersion: ProductAnalyticsConfiguration.appVersion,
            .version: "local vault + usage · loopback only",
            .credits: NSAttributedString(string: "Reads the usage files Claude Code, Codex and Grok already write. Secrets live in the Keychain and leave only through a Touch ID grant. MIT licensed."),
        ])
    }

    @objc func toggleClaudeRefresh() {
        let on = !service.preferences.claudeUsageRefresh
        try? service.preferences.setClaudeUsageRefresh(on)
        claudeRefreshItem?.state = on ? .on : .off
        if on { refresh() }
    }

    /// First launch, and once per new analytics consent version: one window, every
    /// box unticked, one Continue button. Continuing with nothing ticked is a full
    /// answer and is never asked again.
    private func showWelcomeIfNeeded() {
        // Without an analytics service there is nothing to ask about.
        let plan = service.preferences.welcomePlan(analyticsEnabled: service.analytics?.isEnabled ?? true)
        guard !plan.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = plan.firstRun ? "Welcome to Keysrs" : "A quick question from Keysrs"
        alert.informativeText = plan.firstRun
            ? "Keysrs lives in your menu bar. It reads the usage files your AI tools already keep on this Mac, and your API keys stay in the Keychain. Nothing is ticked below; choose what you are comfortable with. You can change it later."
            : "This version can compare your usage with other Keysrs users who share theirs. It is off unless you tick the box."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 320
            return label
        }
        var claudeBox: NSButton?
        if plan.firstRun {
            let box = NSButton(checkboxWithTitle: "Keep Claude plan limits fresh", target: nil, action: nil)
            box.state = .off
            stack.addArrangedSubview(box)
            stack.addArrangedSubview(note("Every 5 minutes, Keysrs runs Claude Code's own /usage command in the background with your existing login. No model request is made. If this is off, Claude limits appear when Claude Code has refreshed them recently, or when you choose Refresh."))
            claudeBox = box
        }
        var analyticsBox: NSButton?
        if plan.askAnalytics {
            if plan.firstRun { stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!) }
            let box = NSButton(checkboxWithTitle: "Share daily usage totals and compare", target: nil, action: nil)
            box.state = .off
            stack.addArrangedSubview(box)
            stack.addArrangedSubview(note("Once a day: token totals per tool and public model name, how high your plan limits got, and which features you used. In return, the dashboard shows how your usage compares. Never your keys, prompts, projects, file names, spend or anything from before you tick this. See exactly what would be sent, or turn it off, under Privacy in the dashboard."))
            analyticsBox = box
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: stack.fittingSize.height))
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        if plan.firstRun { alert.addButton(withTitle: "Continue and Open Keysrs") }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let claudeOn = claudeBox?.state == .on
        try? service.preferences.recordWelcome(plan, claudeRefresh: claudeOn)
        if analyticsBox?.state == .on {
            try? service.analytics?.setEnabled(true, consentVersion: ProductAnalytics.consentVersion)
        }
        claudeRefreshItem?.state = service.preferences.claudeUsageRefresh ? .on : .off
        if claudeOn { refresh() }
        if response == .alertSecondButtonReturn { openDashboard() }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let host = NSMenuItem()
        host.view = panel
        menu.addItem(host)
        menu.addItem(.separator())
        let plan = NSMenuItem(title: "Plan Usage", action: #selector(openDashboard), keyEquivalent: "")
        plan.target = self
        plan.toolTip = "Open the Usage pane on the local site"
        menu.addItem(plan)
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
        let ingest = NSMenuItem(title: "Refresh", action: #selector(ingestNow), keyEquivalent: "r")
        ingest.keyEquivalentModifierMask = [.command]
        ingest.target = self
        ingest.toolTip = "Ingest the local session logs now"
        menu.addItem(ingest)
        let claude = NSMenuItem(title: "Keep Claude Limits Fresh", action: #selector(toggleClaudeRefresh), keyEquivalent: "")
        claude.target = self
        claude.toolTip = "Every 5 minutes, run Claude Code's own /usage in the background (no model request)"
        claude.state = service.preferences.claudeUsageRefresh ? .on : .off
        claudeRefreshItem = claude
        menu.addItem(claude)
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
