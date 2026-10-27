import XCTest
@testable import KeysCore

/// `keys status --json` is the machine-readable form of the plan-window read, the one an
/// agent consumes. Every entry states whether Keysrs tracks the tool, and an untracked
/// tool carries no usage numbers at all, so a script can never mistake absence for a
/// measured zero. The human prose is pinned here too: `--json` grows beside it, not into it.
final class StatusCommandTests: XCTestCase {
    /// The instant the synthetic fixtures were written around; both quota homes are pinned
    /// to it by LiveStatusTests, so the scan results are deterministic.
    private let now = UTC.parse("2026-09-04T18:50:00Z")!

    // MARK: parsing

    func testParseStatusCommandWithJSONFlag() throws {
        let command = try XCTUnwrap(try KeysCLI.parseAsRoot(["status", "--json"]) as? StatusCommand)
        XCTAssertTrue(command.json)
        let human = try XCTUnwrap(try KeysCLI.parseAsRoot(["status"]) as? StatusCommand)
        XCTAssertFalse(human.json, "the human path is the default")
    }

    // MARK: JSON shape against the fixture usage data (some tools tracked)

    func testJSONCarriesATrackedStateOnEveryToolAgainstFixtureUsage() throws {
        let line = try jsonLine(try fixtureScan())
        XCTAssertFalse(line.contains("\n"), "one line, the shape every --json flag prints")
        // Sorted keys: re-serializing the parsed line must reproduce it byte for byte.
        let object = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(try JSONValue.data(object), Data(line.utf8))
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { ($0["source"] as? String) ?? "" }, [
            "claude", "grok", "grok-bot", "openai", "droid",
            "chatgpt", "cursor", "gemini", "copilot", "perplexity", "openrouter", "xai-api",
        ])
        for tool in tools {
            XCTAssertNotNil(tool["tracked"], "every entry states its tracked state explicitly")
            XCTAssertNotNil(tool["source"])
            XCTAssertNotNil(tool["title"])
            XCTAssertNotNil(tool["kind"])
        }

        // Grok: a quota line from the fixture log, plus measured local spend.
        let grok = try entry("grok", in: tools)
        XCTAssertEqual(grok["tracked"] as? Bool, true)
        XCTAssertEqual(grok["weekly_pct"] as? Int, 2)
        XCTAssertEqual(grok["weekly_usd"] as? Double ?? 0, 2.81, accuracy: 1e-9)
        XCTAssertEqual(grok["plan"] as? String, "SuperGrok Plus")
        XCTAssertNotNil(grok["weekly_resets_at"], "the period is live, so its reset belongs here")

        // OpenAI · Codex: the fixture rollout's rate limits, plus counted local tokens.
        let openai = try entry("openai", in: tools)
        XCTAssertEqual(openai["tracked"] as? Bool, true)
        XCTAssertEqual(openai["five_hour_pct"] as? Int, 99)
        XCTAssertEqual(openai["weekly_pct"] as? Int, 31)
        XCTAssertEqual(openai["weekly_tokens"] as? Int, 1234)
        XCTAssertEqual(openai["weekly_usd"] as? Double ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(openai["plan"] as? String, "ChatGPT Plus")
        let period = try XCTUnwrap(openai["period"] as? [String: Any])
        XCTAssertEqual(period["start_day"] as? String, "2026-08-30")

        // Nothing was read for Claude in this scan, and the entry says so without numbers.
        let claude = try entry("claude", in: tools)
        XCTAssertEqual(claude["tracked"] as? Bool, false)
        XCTAssertEqual(claude["usage_note"] as? String, "5-hour and weekly bars are not in local files")
        XCTAssertEqual(Set(claude.keys), ["source", "title", "kind", "tracked", "usage_note"])

        let droid = try entry("droid", in: tools)
        XCTAssertEqual(droid["tracked"] as? Bool, false)
        XCTAssertTrue((droid["usage_note"] as? String ?? "").contains("No Droid usage recorded yet"))

        let grokBot = try entry("grok-bot", in: tools)
        XCTAssertEqual(grokBot["tracked"] as? Bool, false, "an idle week is an absence, not a measurement")
        XCTAssertTrue((grokBot["usage_note"] as? String ?? "").contains("No Grok Bot data on this Mac"))

        let cursor = try entry("cursor", in: tools)
        XCTAssertEqual(cursor["tracked"] as? Bool, false)
        XCTAssertTrue((cursor["usage_note"] as? String ?? "").contains("not in local files"))
    }

    // MARK: JSON shape against an empty home (all untracked)

    func testJSONReportsEveryToolUntrackedInAnEmptyHome() throws {
        let line = try jsonLine(try emptyScan())
        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(try JSONValue.data(object), Data(line.utf8))
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 12, "an entry per tool, tracked or not")
        for tool in tools {
            XCTAssertEqual(tool["tracked"] as? Bool, false, "tool \(tool["source"] ?? "?") is untracked in an empty home")
            for key in tool.keys {
                XCTAssertFalse(usageKeys.contains(key), "an untracked tool carries no usage numbers: \(key) on \(tool["source"] ?? "?")")
            }
        }
    }

    /// A claude-hud plan snapshot whose windows already closed. The bars were real once, but
    /// they describe windows that have since reset, so the entry reports not tracked instead
    /// of letting a script read a stale percent as if it described now.
    func testJSONDropsPlanWindowsThatAlreadyReset() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("plugins/claude-hud", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snap: [String: Any] = [
            "updated_at": "2026-09-03T18:00:00Z",
            "five_hour": ["used_percentage": 4, "resets_at": "2026-09-03T18:42:00Z"],
            "seven_day": ["used_percentage": 13, "resets_at": "2026-09-04T10:00:00Z"],
        ]
        try JSONValue.data(snap).write(to: dir.appendingPathComponent("usage.json"))
        let status = try scan(
            grokHome: try TempDir.make(),
            claudeHome: home,
            grokWeekUsd: 0,
            openaiWeekTokens: 0,
            openaiWeekUsdEstimate: nil,
            codexHome: try TempDir.make()
        )
        let tools = try XCTUnwrap(try JSONValue.line(try jsonLine(status))?["tools"] as? [[String: Any]])
        let claude = try entry("claude", in: tools)
        XCTAssertEqual(claude["tracked"] as? Bool, false)
        XCTAssertEqual(Set(claude.keys), ["source", "title", "kind", "tracked"])
    }

    // MARK: what a tracked entry carries

    func testTrackedEntriesCarryOnlyTheirMeasuredWindows() throws {
        // Droid's windows are counted per window from the catalog, so a zero beside a
        // measured figure is a real zero and stays; an all-zero row is the untracked one.
        let droid = ToolStatus(
            source: "droid", title: "Droid", kind: "subscription",
            fiveHourPct: 60, weeklyTokens: 0,
            fiveHourTokens: 120, monthlyTokens: 1500, fiveHourLimit: 200
        )
        let grokBot = ToolStatus(
            source: "grok-bot", title: "Grok Bot", kind: "subscription",
            usageNote: "Grok Bot's plan is separate from SuperGrok; its credits and limits are not in local files.",
            weeklyPrompts: 12
        )
        let grok = ToolStatus(
            source: "grok", title: "Grok", kind: "local",
            weeklyPct: 2, weeklyResetsAt: "2026-09-11T18:04:26Z", weeklyUsd: 2.81
        )
        let idle = ToolStatus(source: "grok", title: "Grok", kind: "local", weeklyUsd: 0)
        let object = try XCTUnwrap(try JSONValue.line(try jsonText(
            StatusCommand.jsonObject(plans: [droid, grokBot, grok, idle], now: now)
        )))
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])

        let droidEntry = try entry("droid", in: tools)
        XCTAssertEqual(droidEntry["tracked"] as? Bool, true)
        XCTAssertEqual(droidEntry["five_hour_tokens"] as? Int, 120)
        XCTAssertEqual(droidEntry["weekly_tokens"] as? Int, 0, "a counted zero stays a zero")
        XCTAssertEqual(droidEntry["monthly_tokens"] as? Int, 1500)
        XCTAssertEqual(droidEntry["five_hour_limit"] as? Int, 200)
        XCTAssertEqual(droidEntry["five_hour_pct"] as? Int, 60)
        XCTAssertNil(droidEntry["monthly_pct"], "no monthly limit was set, so no percent exists")

        let botEntry = try entry("grok-bot", in: tools)
        XCTAssertEqual(botEntry["tracked"] as? Bool, true)
        XCTAssertEqual(botEntry["weekly_prompts"] as? Int, 12)

        let grokEntry = try entry("grok", in: [tools[2]])
        XCTAssertEqual(grokEntry["tracked"] as? Bool, true)
        XCTAssertEqual(grokEntry["weekly_pct"] as? Int, 2)
        XCTAssertEqual(grokEntry["weekly_resets_at"] as? String, "2026-09-11T18:04:26Z")
        XCTAssertNil(grokEntry["five_hour_pct"], "no 5-hour window was measured")

        let idleEntry = try entry("grok", in: [tools[3]])
        XCTAssertEqual(idleEntry["tracked"] as? Bool, false, "a $0 week with no quota line is an idle week")
        XCTAssertEqual(Set(idleEntry.keys), ["source", "title", "kind", "tracked"])
    }

    // MARK: the human path is pinned

    func testHumanLinesPinTheProseBlocks() throws {
        let fixture = try fixtureScan()
        XCTAssertEqual(StatusCommand.humanLines(try XCTUnwrap(fixture.plans.first { $0.source == "grok" }), now: now), [
            "Grok",
            "  weekly  $2.81  local spend",
            "  weekly  2%  (resets in 6d 23h)",
        ])
        XCTAssertEqual(StatusCommand.humanLines(try XCTUnwrap(fixture.plans.first { $0.source == "claude" }), now: now), [
            "Claude",
            "  5 hour  —",
            "  Fable   —",
            "  5-hour and weekly bars are not in local files",
        ])
        XCTAssertEqual(StatusCommand.humanLines(try XCTUnwrap(fixture.plans.first { $0.source == "cursor" }), now: now), [
            "Cursor",
            "  Plan remaining is not in local files. We do not read Cursor cookies.",
        ])
        XCTAssertEqual(StatusCommand.humanLines(ToolStatus(
            source: "droid", title: "Droid", kind: "subscription",
            weeklyTokens: 0, usageNote: "Tokens per window, from the per-request records in Droid's local logs.",
            fiveHourTokens: 120, monthlyTokens: 1500,
            fiveHourLimit: 200, monthlyLimit: 1000
        ), now: now), [
            "Droid",
            "  5 hour  120 tokens  (60% of 200 limit)",
            "  weekly  0 tokens",
            "  month   1500 tokens  (150% of 1000 limit)",
            "  Tokens per window, from the per-request records in Droid's local logs.",
        ])
        XCTAssertEqual(StatusCommand.humanLines(ToolStatus(
            source: "grok-bot", title: "Grok Bot", kind: "subscription",
            usageNote: "12 prompts in 2 chats this week, counted from the chats Grok Bot keeps on this Mac.",
            weeklyPrompts: 12
        ), now: now), [
            "Grok Bot",
            "  weekly  12 prompts sent · limit not tracked",
            "  12 prompts in 2 chats this week, counted from the chats Grok Bot keeps on this Mac.",
        ])
    }

    /// The stale-snapshot row of testJSONDropsPlanWindowsThatAlreadyReset, in prose: the
    /// human path keeps the expired bars and says "(reset due)" on each, which is exactly
    /// the hedge the JSON entry refuses to guess from, so its percent is dropped there.
    func testHumanLinesKeepExpiredBarsWithResetDue() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("plugins/claude-hud", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snap: [String: Any] = [
            "updated_at": "2026-09-03T18:00:00Z",
            "five_hour": ["used_percentage": 4, "resets_at": "2026-09-03T18:42:00Z"],
            "seven_day": ["used_percentage": 13, "resets_at": "2026-09-04T10:00:00Z"],
        ]
        try JSONValue.data(snap).write(to: dir.appendingPathComponent("usage.json"))
        let status = try scan(
            grokHome: try TempDir.make(),
            claudeHome: home,
            grokWeekUsd: 0,
            openaiWeekTokens: 0,
            openaiWeekUsdEstimate: nil,
            codexHome: try TempDir.make()
        )
        XCTAssertEqual(StatusCommand.humanLines(try XCTUnwrap(status.plans.first { $0.source == "claude" }), now: now), [
            "Claude",
            "  5 hour  4%  (reset due)",
            "  weekly  13%  (reset due)",
            "  Fable   —",
        ])
    }

    // MARK: helpers

    /// The keys a tracked tool may carry; an untracked one carries none of them.
    private let usageKeys: Set<String> = [
        "five_hour_pct", "five_hour_resets_at", "weekly_pct", "weekly_resets_at",
        "fable_pct", "fable_resets_at", "monthly_pct", "weekly_usd", "weekly_tokens",
        "weekly_prompts", "five_hour_tokens", "monthly_tokens", "five_hour_limit",
        "weekly_limit", "monthly_limit", "limit", "limit_remaining", "usage_weekly",
        "plan", "snapshot_at", "period",
    ]

    private func fixtureScan() throws -> LiveStatus {
        try scan(
            grokHome: Fixtures.grokQuotaHome,
            claudeHome: try TempDir.make(),
            grokWeekUsd: 2.81,
            openaiWeekTokens: 1234,
            openaiWeekUsdEstimate: 0.75,
            codexHome: Fixtures.codexQuotaHome
        )
    }

    private func emptyScan() throws -> LiveStatus {
        try scan(
            grokHome: try TempDir.make(),
            claudeHome: try TempDir.make(),
            grokWeekUsd: 0,
            openaiWeekTokens: 0,
            openaiWeekUsdEstimate: nil,
            codexHome: try TempDir.make()
        )
    }

    /// A scan at the fixtures' pinned instant, with every home overridable and the Droid row
    /// counted from an empty catalog, the way an empty machine's status reads.
    private func scan(
        grokHome: URL,
        claudeHome: URL,
        grokWeekUsd: Double,
        openaiWeekTokens: Int,
        openaiWeekUsdEstimate: Double?,
        codexHome: URL
    ) throws -> LiveStatus {
        LiveStatus.scan(
            grokHome: grokHome,
            claudeHome: claudeHome,
            grokWeekUsd: grokWeekUsd,
            claudePlan: try TempDir.make().appendingPathComponent("missing-plan.json"),
            openaiWeekTokens: openaiWeekTokens,
            openaiWeekUsdEstimate: openaiWeekUsdEstimate,
            codexHome: codexHome,
            weekPeriod: SpendPeriod.calendarWeek(now: now, timeZone: TimeZone(identifier: "America/Denver")!),
            grokBotHome: try TempDir.make(),
            droidRow: try DroidUsage.row(catalog: try makeDB().0, now: now),
            now: now
        )
    }

    private func jsonLine(_ status: LiveStatus) throws -> String {
        try jsonText(StatusCommand.jsonObject(plans: status.plans, now: now))
    }

    private func jsonText(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONValue.data(object), as: UTF8.self)
    }

    private func entry(_ source: String, in tools: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(tools.first { ($0["source"] as? String) == source })
    }
}
