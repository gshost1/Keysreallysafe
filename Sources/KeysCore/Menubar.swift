import AppKit
import CoreGraphics
import Foundation

struct MenubarSnapshot: Equatable {
    var title: String
    var tooltip: String
    var sparkline: [Double]
    /// One line per plan window, for the dropdown. Empty when no tool has reported a window.
    var lines: [String] = []
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
    }

    /// Title: each tool's weekly window only, `C 2%  X 63%  G 10%`. Dollars and the 5-hour
    /// windows live in the dropdown. Never a Claude or Codex estimate.
    static func from(_ report: SpendReport, status: LiveStatus? = nil, now: Date = Date()) -> MenubarSnapshot {
        let usd = formatUsd(report.totals.grokUsd)
        var parts: [String] = []
        var tooltip: [String] = ["Grok \(usd) this \(report.range == .week ? "week" : "month")"]
        var lines: [String] = []
        var cards: [ToolCard] = []
        if let status {
            let claude = status.claude ?? status.plans.first { $0.source == "claude" }
            let codex = status.plans.first { $0.source == "openai" }
            let grok = status.grok ?? status.plans.first { $0.source == "grok" }
            for (letter, name, tool) in [("C", "Claude", claude), ("X", "Codex", codex), ("G", "Grok", grok)] {
                guard let tool, tool.fiveHourPct != nil || tool.weeklyPct != nil else { continue }
                if let week = tool.weeklyPct {
                    parts.append("\(letter) \(week)%")
                    tooltip.append("\(name) weekly \(week)%")
                } else if let five = tool.fiveHourPct {
                    tooltip.append("\(name) 5h \(five)%")
                }
                if let five = tool.fiveHourPct {
                    lines.append("\(name) · 5 hour \(five)%" + resetsSuffix(tool.fiveHourResetsAt, now: now))
                }
                if let week = tool.weeklyPct {
                    lines.append("\(name) · weekly \(week)%" + resetsSuffix(tool.weeklyResetsAt, now: now))
                }
                var windows: [Window] = []
                if let five = tool.fiveHourPct {
                    windows.append(Window(label: "\(name) 5-hour", pctUsed: five, resetsAt: tool.fiveHourResetsAt))
                }
                if let week = tool.weeklyPct {
                    windows.append(Window(label: "\(name) weekly", pctUsed: week, resetsAt: tool.weeklyResetsAt))
                }
                cards.append(ToolCard(
                    id: tool.source,
                    name: name,
                    plan: tool.plan,
                    windows: windows,
                    note: tool.usageNote,
                    usdLine: letter == "G" ? "Grok \(usd) this \(report.range == .week ? "week" : "month")" : nil
                ))
            }
        }
        tooltip.append("weekly plan windows · click for 5-hour windows and spend")
        let title = parts.isEmpty ? usd : parts.joined(separator: "  ")
        return MenubarSnapshot(
            title: title,
            tooltip: tooltip.joined(separator: " · "),
            sparkline: Sparkline.values(from: report.daily),
            lines: lines,
            cards: cards,
            spendLine: tooltip.first ?? ""
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

    static func resetsSuffix(_ iso: String?, now: Date) -> String {
        guard let iso, let date = UTC.parse(iso) else { return "" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return " · reset due" }
        let m = s / 60
        if m < 60 { return " · resets in \(m)m" }
        let h = m / 60
        if h < 48 { return " · resets in \(h)h \(m % 60)m" }
        return " · resets in \(h / 24)d \(h % 24)h"
    }

    static func formatUsd(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }

    static func formatTokens(_ n: Int) -> String {
        let x = Double(n)
        if x >= 1_000_000_000 { return String(format: "%.0fB", x / 1_000_000_000) }
        if x >= 1_000_000 { return String(format: "%.0fM", x / 1_000_000) }
        if x >= 1_000 { return String(format: "%.0fK", x / 1_000) }
        return String(n)
    }
}

enum Sparkline {
    static func values(from daily: [DailyPoint]) -> [Double] {
        var byDay: [String: Double] = [:]
        for point in daily {
            byDay[point.day, default: 0] += point.usd ?? 0
        }
        return byDay.keys.sorted().map { byDay[$0]! }
    }

    static func points(values: [Double], size: CGSize) -> [CGPoint] {
        guard !values.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let pad: CGFloat = 1
        let w = max(size.width - pad * 2, 1)
        let h = max(size.height - pad * 2, 1)
        let maxV = values.max() ?? 0
        let span = max(maxV, 1e-12)
        let last = CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            let x = pad + w * CGFloat(index) / last
            let y = pad + h * CGFloat(value / span)
            return CGPoint(x: x, y: y)
        }
    }

    static func image(values: [Double], size: CGSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            let pts = points(values: values.isEmpty ? [0, 0] : values, size: size)
            if let first = pts.first {
                path.move(to: first)
                for p in pts.dropFirst() { path.line(to: p) }
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum MenubarRuntime {
    @MainActor static var extra: MenubarExtra?
}

enum LoopbackSite {
    static func bind(service: KeysService, preferredPort: UInt16 = LoginItem.dashboardPort) throws -> LoopbackHTTPServer {
        let web = try WebRoot.find()
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer.startOnAvailablePort(preferred: preferredPort) { request in
            handler.handle(request)
        }
        guard server.isBoundToLoopback, server.boundHost == "127.0.0.1" else {
            server.stop()
            throw AppError.refusedBind(server.boundHost)
        }
        server.start()
        do {
            _ = try service.startGateway()
            try ControlFile.write(port: server.boundPort, token: handler.originToken)
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
    private let item: NSStatusItem
    private var timer: Timer?
    private var lastSnapshot: MenubarSnapshot?
    private var updatedAt: Date?
    private let panel = MenubarPanel()
    private static let tabKey = "menubar.tab"

    init(service: KeysService, server: LoopbackHTTPServer, url: URL) {
        self.service = service
        self.server = server
        self.url = url
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.imagePosition = .noImage
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

    func applicationWillTerminate(_ notification: Notification) {
        service.stopGateway()
        server.stop()
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(url)
    }

    @objc func ingestNow() {
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
        refresh()
    }

    @objc func refresh() {
        let report = (try? service.spend(range: .week, by: .model, source: .all)) ?? SpendReport(
            range: .week,
            by: .model,
            source: .all,
            caption: SpendReport.captionText,
            totals: SpendTotals(),
            rows: [],
            daily: []
        )
        let status = try? service.liveStatus()
        let snap = MenubarSnapshot.from(report, status: status)
        item.button?.title = snap.title
        item.button?.toolTip = snap.tooltip
        item.button?.image = nil
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

    @objc func openPlanUsage() {
        NSWorkspace.shared.open(url)
    }

    @objc func openStatusPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = URL(string: raw) else { return }
        NSWorkspace.shared.open(target)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Keysreallysafe",
            .applicationVersion: "0.2",
            .version: "local vault + usage · loopback only",
            .credits: NSAttributedString(string: "Reads the usage files Claude Code, Codex and Grok already write. Secrets live in the Keychain and leave only through a Touch ID grant. MIT."),
        ])
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let host = NSMenuItem()
        host.view = panel
        menu.addItem(host)
        menu.addItem(.separator())
        let plan = NSMenuItem(title: "Plan Usage", action: #selector(openPlanUsage), keyEquivalent: "")
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
        let open = NSMenuItem(title: "Open Keysreallysafe", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let ingest = NSMenuItem(title: "Refresh", action: #selector(ingestNow), keyEquivalent: "r")
        ingest.keyEquivalentModifierMask = [.command]
        ingest.target = self
        ingest.toolTip = "Ingest the local session logs now"
        menu.addItem(ingest)
        let about = NSMenuItem(title: "About Keysreallysafe", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }
}
