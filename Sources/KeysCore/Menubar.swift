import AppKit
import CoreGraphics
import Foundation

struct MenubarSnapshot: Equatable {
    var title: String
    var tooltip: String
    var sparkline: [Double]
    /// One line per plan window, for the dropdown. Empty when no tool has reported a window.
    var lines: [String] = []

    /// Title: each tool's weekly window only, `C 2%  X 63%  G 10%`. Dollars and the 5-hour
    /// windows live in the dropdown. Never a Claude or Codex estimate.
    static func from(_ report: SpendReport, status: LiveStatus? = nil, now: Date = Date()) -> MenubarSnapshot {
        let usd = formatUsd(report.totals.grokUsd)
        var parts: [String] = []
        var tooltip: [String] = ["Grok \(usd) this \(report.range == .week ? "week" : "month")"]
        var lines: [String] = []
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
            }
        }
        tooltip.append("weekly plan windows · click for 5-hour windows and spend")
        let title = parts.isEmpty ? usd : parts.joined(separator: "  ")
        return MenubarSnapshot(
            title: title,
            tooltip: tooltip.joined(separator: " · "),
            sparkline: Sparkline.values(from: report.daily),
            lines: lines
        )
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

    init(service: KeysService, server: LoopbackHTTPServer, url: URL) {
        self.service = service
        self.server = server
        self.url = url
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.imagePosition = .noImage
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
        item.menu = buildMenu()
        item.menu?.delegate = self
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let snap = lastSnapshot {
            for line in snap.lines {
                let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
            if !snap.lines.isEmpty { menu.addItem(.separator()) }
            let spend = NSMenuItem(title: snap.tooltip.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "", action: nil, keyEquivalent: "")
            spend.isEnabled = false
            menu.addItem(spend)
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            let when = NSMenuItem(title: "Updated \(f.string(from: updatedAt ?? Date())) · refreshes every minute", action: nil, keyEquivalent: "")
            when.isEnabled = false
            menu.addItem(when)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "Open Keysreallysafe", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let ingest = NSMenuItem(title: "Ingest", action: #selector(ingestNow), keyEquivalent: "r")
        ingest.keyEquivalentModifierMask = [.command]
        ingest.target = self
        menu.addItem(ingest)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }
}
