import AppKit
import CoreGraphics
import Foundation

struct MenubarSnapshot: Equatable {
    var title: String
    var tooltip: String
    var sparkline: [Double]

    static func from(_ report: SpendReport, status: LiveStatus? = nil) -> MenubarSnapshot {
        let usd = formatUsd(report.totals.grokUsd)
        var title = usd
        let tooltip: String
        if let status {
            var parts = ["Grok \(usd)"]
            if let pct = status.grok?.weeklyPct {
                title += "  G\(pct)%"
                parts.append("Grok \(pct)%")
            }
            if let pct = status.claude?.fiveHourPct {
                title += "  C\(pct)%"
                parts.append("Claude 5h \(pct)%")
            }
            let openai = status.plans.first { $0.source == "openai" }
            if let pct = openai?.weeklyPct {
                title += "  X\(pct)%"
                parts.append("Codex \(pct)%")
            }
            parts.append("local tool spend, not a subscription bar")
            tooltip = parts.joined(separator: " · ")
        } else {
            let claude = formatTokens(report.totals.claudeTokens)
            tooltip = "Grok \(usd) · Claude \(claude) tokens · local tool spend, not a subscription bar"
        }
        return MenubarSnapshot(
            title: title,
            tooltip: tooltip,
            sparkline: Sparkline.values(from: report.daily)
        )
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
final class MenubarExtra: NSObject, NSApplicationDelegate {
    private let service: KeysService
    private let server: LoopbackHTTPServer
    private let url: URL
    private let item: NSStatusItem
    private var timer: Timer?

    init(service: KeysService, server: LoopbackHTTPServer, url: URL) {
        self.service = service
        self.server = server
        self.url = url
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
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
        _ = try? service.ingest(.all)
        refresh()
    }

    @objc func quit() {
        service.stopGateway()
        server.stop()
        NSApp.terminate(nil)
    }

    @objc func refresh() {
        let report = (try? service.spend(range: .month, by: .model, source: .all)) ?? SpendReport(
            range: .month,
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
        item.button?.image = Sparkline.image(values: snap.sparkline, size: CGSize(width: 22, height: 16))
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
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
