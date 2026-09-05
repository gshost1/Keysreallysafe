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
        XCTAssertEqual(snap.title, "$2.81")
        XCTAssertFalse(snap.title.contains("1.00"))
        XCTAssertFalse(snap.tooltip.contains(fixtureSecret))
        XCTAssertTrue(snap.tooltip.contains("Claude"))
        XCTAssertTrue(snap.tooltip.lowercased().contains("not a subscription"))
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
