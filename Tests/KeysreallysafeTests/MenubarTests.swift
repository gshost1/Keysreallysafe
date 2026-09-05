import XCTest
@testable import KeysCore

final class MenubarTests: XCTestCase {
    func testTitleIsGrokUsdNeverClaudeEstimate() {
        var totals = SpendTotals()
        totals.grokUsd = 2.80965794
        totals.claudeTokens = 227_633_244
        totals.claudeUsdEstimate = 1.00554495
        let snap = MenubarSnapshot.from(
            SpendReport(
                range: .month,
                by: .model,
                source: .all,
                caption: SpendReport.captionText,
                totals: totals,
                rows: [],
                daily: []
            )
        )
        XCTAssertEqual(snap.title, "$2.81") // no windows reported: fall back to Grok dollars
        XCTAssertFalse(snap.title.contains("1.00"))
        XCTAssertFalse(snap.tooltip.contains(fixtureSecret))
        XCTAssertFalse(snap.tooltip.contains("1.00"))
        XCTAssertTrue(snap.tooltip.lowercased().contains("plan windows"))
    }

    func testZeroSpendTitle() {
        let snap = MenubarSnapshot.from(emptyReport())
        XCTAssertEqual(snap.title, "$0")
        XCTAssertEqual(snap.sparkline, [])
    }

    func testSparklineSumsUsdByDayChronologically() {
        let report = SpendReport(
            range: .month,
            by: .model,
            source: .all,
            caption: SpendReport.captionText,
            totals: SpendTotals(),
            rows: [],
            daily: [
                DailyPoint(day: "2026-09-02", model: "grok-4.6-build", usd: 1.0, tokens: 10),
                DailyPoint(day: "2026-09-01", model: "grok-4.6-build", usd: 0.5, tokens: 5),
                DailyPoint(day: "2026-09-01", model: "claude-sonnet-5", usd: nil, tokens: 100),
                DailyPoint(day: "2026-09-02", model: "grok-4-fast", usd: 0.25, tokens: 2),
            ]
        )
        XCTAssertEqual(MenubarSnapshot.from(report).sparkline, [0.5, 1.25])
    }

    func testSparklinePointsIncreaseInXAndStayInBounds() {
        let size = CGSize(width: 22, height: 16)
        let pts = Sparkline.points(values: [0, 1, 0.5], size: size)
        XCTAssertEqual(pts.count, 3)
        XCTAssertLessThan(pts[0].x, pts[1].x)
        XCTAssertLessThan(pts[1].x, pts[2].x)
        for p in pts {
            XCTAssertGreaterThanOrEqual(p.x, 0)
            XCTAssertLessThanOrEqual(p.x, size.width)
            XCTAssertGreaterThanOrEqual(p.y, 0)
            XCTAssertLessThanOrEqual(p.y, size.height)
        }
        XCTAssertGreaterThan(pts[1].y, pts[0].y)
    }

    func testParseMenubarCommand() throws {
        let parsed = try KeysCLI.parseAsRoot(["menubar"])
        XCTAssertTrue(parsed is MenubarCommand)
    }

    func testParseAutostartCommand() throws {
        XCTAssertTrue(try KeysCLI.parseAsRoot(["autostart"]) is AutostartCommand)
        let off = try KeysCLI.parseAsRoot(["autostart", "--uninstall"])
        XCTAssertTrue(off is AutostartCommand)
    }

    func testLoginItemPlistIsLoopbackMenubar() {
        let xml = LoginItem.plistXML(
            binary: URL(fileURLWithPath: "/tmp/keysreallysafe/bin/keys"),
            webRoot: URL(fileURLWithPath: "/tmp/keysreallysafe/Web"),
            logFile: URL(fileURLWithPath: "/tmp/keysreallysafe/menubar.log")
        )
        XCTAssertTrue(xml.contains("<string>com.keysreallysafe.menubar</string>"))
        XCTAssertTrue(xml.contains("<string>/tmp/keysreallysafe/bin/keys</string>"))
        XCTAssertTrue(xml.contains("<string>menubar</string>"))
        XCTAssertTrue(xml.contains("<string>/tmp/keysreallysafe/Web</string>"))
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(xml.contains("<string>Aqua</string>"))
        XCTAssertFalse(xml.contains("0.0.0.0"))
        XCTAssertFalse(xml.contains("vercel"))
        XCTAssertEqual(LoginItem.bookmarkURL.absoluteString, "http://127.0.0.1:12766/")
        XCTAssertEqual(LoginItem.xml("a&b<c>"), "a&amp;b&lt;c&gt;")
    }

    private func emptyReport() -> SpendReport {
        SpendReport(
            range: .month,
            by: .model,
            source: .all,
            caption: SpendReport.captionText,
            totals: SpendTotals(),
            rows: [],
            daily: []
        )
    }
}

final class MenubarWindowsTests: XCTestCase {
    func testTitleShowsFiveHourAndWeeklyForEveryToolAndLinesCarryResets() {
        var totals = SpendTotals()
        totals.grokUsd = 36.93
        let report = SpendReport(range: .week, by: .model, source: .all, caption: SpendReport.captionText, totals: totals, rows: [], daily: [])
        let now = UTC.parse("2026-09-05T00:00:00Z")!
        var claude = ToolStatus(source: "claude", title: "Claude")
        claude.fiveHourPct = 12; claude.fiveHourResetsAt = "2026-09-05T00:55:00Z"
        claude.weeklyPct = 2; claude.weeklyResetsAt = "2026-09-06T08:00:00Z"
        var codex = ToolStatus(source: "openai", title: "OpenAI · Codex")
        codex.fiveHourPct = 22; codex.weeklyPct = 46; codex.weeklyResetsAt = "2026-09-10T23:42:00Z"
        var grok = ToolStatus(source: "grok", title: "Grok")
        grok.weeklyPct = 8; grok.weeklyResetsAt = "2026-09-11T18:04:00Z"
        let status = LiveStatus(grok: grok, claude: claude, plans: [grok, claude, codex])
        let snap = MenubarSnapshot.from(report, status: status, now: now)
        XCTAssertEqual(snap.title, "C 2%  X 46%  G 8%")
        XCTAssertTrue(snap.tooltip.hasPrefix("Grok $36.93 this week"))
        XCTAssertEqual(snap.lines, [
            "Claude · 5 hour 12% · resets in 55m",
            "Claude · weekly 2% · resets in 32h 0m",
            "Codex · 5 hour 22%",
            "Codex · weekly 46% · resets in 5d 23h",
            "Grok · weekly 8% · resets in 6d 18h",
        ])
        XCTAssertTrue(snap.tooltip.contains("this week"))
        XCTAssertFalse(snap.tooltip.contains("estimate"))
    }

    func testToolWithoutWindowsIsOmitted() {
        let status = LiveStatus(grok: nil, claude: nil, plans: [ToolStatus(source: "cursor", title: "Cursor")])
        let snap = MenubarSnapshot.from(SpendReport(range: .week, by: .model, source: .all, caption: SpendReport.captionText, totals: SpendTotals(), rows: [], daily: []), status: status)
        XCTAssertEqual(snap.title, "$0")
        XCTAssertEqual(snap.lines, [])
    }
}
