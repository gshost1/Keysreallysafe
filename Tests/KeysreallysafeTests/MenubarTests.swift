import XCTest
import AppKit
@testable import KeysCore

final class MenubarTests: XCTestCase {
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
}

final class MenubarWindowsTests: XCTestCase {
    func testTitleShowsWeeklyPercentagesAndDropdownIncludesFiveHourUsage() {
        let now = UTC.parse("2026-09-05T00:00:00Z")!
        var claude = ToolStatus(source: "claude", title: "Claude")
        claude.fiveHourPct = 12; claude.fiveHourResetsAt = "2026-09-05T00:55:00Z"
        claude.weeklyPct = 2; claude.weeklyResetsAt = "2026-09-06T08:00:00Z"
        claude.fablePct = 38
        var codex = ToolStatus(source: "openai", title: "OpenAI · Codex")
        codex.fiveHourPct = 22; codex.weeklyPct = 46; codex.weeklyResetsAt = "2026-09-10T23:42:00Z"
        var grok = ToolStatus(source: "grok", title: "Grok")
        grok.weeklyPct = 8; grok.weeklyResetsAt = "2026-09-11T18:04:00Z"
        grok.weeklyUsd = 36.93
        let status = LiveStatus(grok: grok, claude: claude, plans: [grok, claude, codex])
        let snap = MenubarSnapshot.from(status, now: now)
        XCTAssertEqual(snap.title, "C 38%  X 46%  G 8%")
        XCTAssertTrue(snap.tooltip.hasPrefix("Grok $36.93 this week"))
        XCTAssertEqual(snap.cards.flatMap { $0.windows.map(\.label) }, [
            "Claude 5-hour", "Claude Fable", "Claude weekly", "Codex 5-hour", "Codex weekly", "Grok weekly",
        ])
        XCTAssertTrue(snap.tooltip.contains("Codex 5-hour 22% used"))
        XCTAssertTrue(snap.tooltip.contains("this week"))
        XCTAssertFalse(snap.tooltip.contains("estimate"))
    }

    func testToolWithoutWindowsIsOmitted() {
        let status = LiveStatus(grok: nil, claude: nil, plans: [ToolStatus(source: "cursor", title: "Cursor")])
        let snap = MenubarSnapshot.from(status)
        XCTAssertEqual(snap.title, "—")
        XCTAssertTrue(snap.cards.isEmpty)
    }
}

final class MenubarPanelDataTests: XCTestCase {
    @MainActor func testClaudePanelKeepsMissingFableVisibleAndShowsUsedQuota() {
        let panel = MenubarPanel()
        panel.selectedTab = "claude"
        let card = MenubarSnapshot.ToolCard(id: "claude", name: "Claude", windows: [
            .init(label: "Claude 5-hour", pctUsed: 4),
            .init(label: "Claude weekly", pctUsed: 40),
        ])
        panel.render(snapshot: MenubarSnapshot(title: "C —", tooltip: "", cards: [card]), updatedAt: Date())
        func texts(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
        }
        let labels = texts(panel)
        XCTAssertTrue(labels.contains("Claude Fable"))
        XCTAssertTrue(labels.contains("Unavailable"))
        XCTAssertTrue(labels.contains("4% used"))
        XCTAssertTrue(labels.contains("40% used"))
        XCTAssertFalse(labels.contains { $0.contains("% left") })
    }

    func testCardsCarryPlanWindowsAndResetLabels() {
        var claude = ToolStatus(source: "claude", title: "Claude")
        claude.plan = "Max"
        claude.fiveHourPct = 53
        claude.fiveHourResetsAt = "2026-09-06T20:00:00Z"
        claude.weeklyPct = 1
        claude.fablePct = 72
        claude.weeklyResetsAt = "2026-09-12T09:00:00Z"
        var grok = ToolStatus(source: "grok", title: "Grok")
        grok.weeklyPct = 10
        grok.weeklyResetsAt = "2026-09-07T05:00:00Z"
        var status = LiveStatus()
        status.plans = [claude, grok]
        let now = UTC.parse("2026-09-06T17:00:00Z")!
        let snap = MenubarSnapshot.from(status, now: now)
        XCTAssertEqual(snap.cards.map(\.id), ["claude", "grok"])
        XCTAssertEqual(snap.cards[0].plan, "Max")
        XCTAssertEqual(snap.cards[0].windows.map(\.label), ["Claude 5-hour", "Claude Fable", "Claude weekly"])
        XCTAssertEqual(snap.cards[0].windows.map(\.pctUsed), [53, 72, 1])
        XCTAssertEqual(snap.cards[0].overviewWindow?.pctUsed, 72)
        var noFable = snap.cards[0]
        noFable.windows.removeAll { $0.label == "Claude Fable" }
        XCTAssertNil(noFable.overviewWindow)
        XCTAssertEqual(snap.cards[1].usdLine, "Grok $0 this week")
        XCTAssertEqual(snap.spendLine, "Grok $0 this week")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(MenubarSnapshot.resetsLabel("2026-09-06T20:00:00Z", now: now, calendar: utc), "Resets today, 20:00")
        XCTAssertEqual(MenubarSnapshot.resetsLabel("2026-09-07T02:01:00Z", now: now, calendar: utc), "Resets tomorrow, 02:01")
        XCTAssertEqual(MenubarSnapshot.resetsLabel("2026-09-11T09:45:00Z", now: now, calendar: utc), "Resets 11 Sep at 09:45")
        XCTAssertEqual(MenubarSnapshot.resetsLabel("2026-09-06T16:00:00Z", now: now, calendar: utc), "Reset due")
        XCTAssertEqual(MenubarSnapshot.resetsLabel(nil, now: now, calendar: utc), "")
    }
}
