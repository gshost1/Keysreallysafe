import XCTest
@testable import KeysCore

final class LiveStatusTests: XCTestCase {
    func testGrokWeeklyUsdNoContextNoFiveHour() throws {
        let status = try LiveStatus.scan(
            grokHome: try TempDir.make(),
            claudeHome: try TempDir.make(),
            grokWeekUsd: 2.81
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertEqual(grok.source, "grok")
        XCTAssertEqual(grok.title, "Grok")
        XCTAssertNil(grok.contextPct)
        XCTAssertNil(grok.fiveHourPct)
        XCTAssertEqual(grok.weeklyUsd ?? 0, 2.81, accuracy: 1e-9)
        XCTAssertNil(grok.weeklyPct)
    }

    func testClaudeFiveHourAndWeeklyFromSnapshot() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("plugins/claude-hud", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snap: [String: Any] = [
            "updated_at": "2026-09-03T18:00:00Z",
            "five_hour": [
                "used_percentage": 22,
                "resets_at": "2026-09-03T18:42:00Z",
            ],
            "seven_day": [
                "used_percentage": 91,
                "resets_at": "2026-09-08T00:00:00Z",
            ],
        ]
        try JSONValue.data(snap).write(to: dir.appendingPathComponent("usage.json"))
        let status = try LiveStatus.scan(
            grokHome: try TempDir.make(),
            claudeHome: home,
            grokWeekUsd: 0
        )
        let claude = try XCTUnwrap(status.claude)
        XCTAssertEqual(claude.fiveHourPct, 22)
        XCTAssertEqual(claude.fiveHourResetsAt, "2026-09-03T18:42:00Z")
        XCTAssertEqual(claude.weeklyPct, 91)
        XCTAssertEqual(claude.weeklyResetsAt, "2026-09-08T00:00:00Z")
        XCTAssertEqual(claude.snapshotAt, "2026-09-03T18:00:00Z")
        XCTAssertNil(claude.contextPct)
        XCTAssertEqual(claude.jsonObject()["snapshot_at"] as? String, "2026-09-03T18:00:00Z")
    }

    func testClaudeMissingSnapshotLeavesPercentsNil() throws {
        let home = try TempDir.make()
        let status = try LiveStatus.scan(
            grokHome: try TempDir.make(),
            claudeHome: home,
            grokWeekUsd: 0,
            claudePlan: home.appendingPathComponent("missing-plan.json")
        )
        XCTAssertEqual(status.claude?.fiveHourPct, nil)
        XCTAssertEqual(status.claude?.weeklyPct, nil)
        XCTAssertEqual(status.claude?.usageNote, "5-hour and weekly bars are not in local files")
    }

    func testResetsInFormat() {
        let now = UTC.parse("2026-09-03T18:00:00Z")!
        XCTAssertEqual(
            LiveStatus.formatResets(at: "2026-09-03T18:42:00Z", now: now),
            "resets in 42m"
        )
        XCTAssertEqual(
            LiveStatus.formatResets(at: "2026-09-03T20:10:00Z", now: now),
            "resets in 2h 10m"
        )
        XCTAssertEqual(
            LiveStatus.formatResets(at: "2026-09-10T12:00:00Z", now: now),
            "resets in 6d 18h"
        )
    }

    func testParseStatusCommand() throws {
        let parsed = try KeysCLI.parseAsRoot(["status"])
        XCTAssertTrue(parsed is StatusCommand)
    }

    func testWeekPeriodLabelForCrossingMonth() {
        let tz = TimeZone(identifier: "America/Denver")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        let period = SpendPeriod.calendarWeek(now: now, timeZone: tz)
        XCTAssertEqual(period.startDay, "2026-08-30")
        XCTAssertEqual(period.endDay, "2026-09-05")
        XCTAssertEqual(period.label, "Sun Aug 30 – Sat Sep 5")
    }

    func testPlansIncludeOpenAIChatGPTAndCursor() throws {
        let home = try TempDir.make()
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 1,
            claudePlan: home.appendingPathComponent("missing.json"),
            openaiWeekTokens: 0,
            openaiWeekUsdEstimate: nil,
            codexHome: home
        )
        let sources = status.plans.map(\.source)
        XCTAssertTrue(sources.contains("openai"))
        XCTAssertTrue(sources.contains("chatgpt"))
        XCTAssertTrue(sources.contains("codex"))
        XCTAssertTrue(sources.contains("cursor"))
        XCTAssertTrue(sources.contains("gemini"))
        let chatgpt = try XCTUnwrap(status.plans.first { $0.source == "chatgpt" })
        XCTAssertNil(chatgpt.fiveHourPct)
        XCTAssertEqual(
            chatgpt.usageNote,
            "Covered by the OpenAI · Codex row above; chat message caps are not in local files."
        )
        let openai = try XCTUnwrap(status.plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.title, "OpenAI · Codex")
        XCTAssertNil(openai.fiveHourPct)
        XCTAssertNil(openai.plan)
        XCTAssertNil(openai.snapshotAt)
    }

    func testWeeklyPlanEntriesCarryPeriod() throws {
        let home = try TempDir.make()
        let period = SpendPeriod(
            startDay: "2026-08-30",
            endDay: "2026-09-05",
            label: "Sun Aug 30 – Sat Sep 5"
        )
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 2.5,
            claudePlan: home.appendingPathComponent("missing.json"),
            openaiWeekTokens: 100,
            openaiWeekUsdEstimate: 0.01,
            codexHome: home,
            weekPeriod: period
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertEqual(grok.period?.label, period.label)
        let grokJSON = grok.jsonObject()["period"] as? [String: Any]
        XCTAssertEqual(grokJSON?["start_day"] as? String, "2026-08-30")
        XCTAssertEqual(grokJSON?["end_day"] as? String, "2026-09-05")
        XCTAssertEqual(grokJSON?["label"] as? String, "Sun Aug 30 – Sat Sep 5")
        let openai = try XCTUnwrap(status.plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.period?.label, period.label)
        let chatgpt = try XCTUnwrap(status.plans.first { $0.source == "chatgpt" })
        XCTAssertNil(chatgpt.period)
        XCTAssertNil(chatgpt.jsonObject()["period"])
        let claude = try XCTUnwrap(status.claude)
        XCTAssertNil(claude.period)
    }

    func testGrokLastBillingLineWins() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T19:00:00Z")!
        try writeGrokLog(home, lines: [
            try grokBilling(
                ts: "2026-09-04T17:51:00.000Z",
                pct: 62,
                end: "2026-09-11T18:04:26.160272+00:00"
            ),
            #"{"ts":"2026-09-04T18:00:00.000Z","msg":"some other event"}"#,
            try grokBilling(
                ts: "2026-09-04T18:43:52.216Z",
                pct: 2,
                end: "2026-09-11T18:04:26.160272+00:00"
            ),
        ])
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 1.5,
            claudePlan: home.appendingPathComponent("missing.json"),
            now: now
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertEqual(grok.weeklyPct, 2)
        XCTAssertEqual(grok.weeklyUsd ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(grok.plan, "SuperGrok Plus")
        XCTAssertEqual(grok.snapshotAt, "2026-09-04T18:43:52.216Z")
        XCTAssertEqual(grok.weeklyResetsAt, "2026-09-11T18:04:26Z")
        XCTAssertNil(grok.usageNote)
        XCTAssertNil(grok.jsonObject()["on_demand_cap"])
        XCTAssertEqual(grok.jsonObject()["plan"] as? String, "SuperGrok Plus")
        XCTAssertEqual(grok.jsonObject()["snapshot_at"] as? String, "2026-09-04T18:43:52.216Z")
    }

    func testGrokPreResetLineYieldsNullPercent() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:30:00Z")!
        try writeGrokLog(home, lines: [
            try grokBilling(
                ts: "2026-09-04T17:51:00.000Z",
                pct: 62,
                end: "2026-09-04T18:04:26.160272+00:00"
            ),
        ])
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            now: now
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertNil(grok.weeklyPct)
        XCTAssertEqual(grok.plan, "SuperGrok Plus")
        XCTAssertEqual(grok.snapshotAt, "2026-09-04T17:51:00.000Z")
        XCTAssertEqual(
            grok.usageNote,
            "Quota resets happened since the last Grok prompt; run a Grok prompt to refresh."
        )
        XCTAssertTrue(grok.jsonObject()["weekly_pct"] is NSNull)
    }

    func testGrokNonWeeklyPeriodYieldsNote() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T19:00:00Z")!
        try writeGrokLog(home, lines: [
            try grokBilling(
                ts: "2026-09-04T18:43:52.216Z",
                pct: 40,
                periodType: "USAGE_PERIOD_TYPE_MONTHLY",
                end: "2026-10-04T18:04:26.160272+00:00"
            ),
        ])
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            now: now
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertNil(grok.weeklyPct)
        XCTAssertEqual(grok.usageNote, "USAGE_PERIOD_TYPE_MONTHLY")
        XCTAssertEqual(grok.plan, "SuperGrok Plus")
        XCTAssertEqual(grok.snapshotAt, "2026-09-04T18:43:52.216Z")
    }

    func testGrokOnDemandWhenCapPositive() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T19:00:00Z")!
        try writeGrokLog(home, lines: [
            try grokBilling(
                ts: "2026-09-04T18:43:52.216Z",
                pct: 8,
                end: "2026-09-11T18:04:26Z",
                onDemandCap: 20,
                onDemandUsed: 3
            ),
        ])
        let grok = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            now: now
        ).grok)
        XCTAssertEqual(grok.onDemandCap, 20)
        XCTAssertEqual(grok.onDemandUsed, 3)
        XCTAssertEqual(grok.jsonObject()["on_demand_cap"] as? Int, 20)
        XCTAssertEqual(grok.jsonObject()["on_demand_used"] as? Int, 3)
    }

    func testGrokTailDoesNotReadWholeFile() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T19:00:00Z")!
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var data = Data()
        data.append(contentsOf: try grokBilling(
            ts: "2026-09-04T17:00:00.000Z",
            pct: 7,
            end: "2026-09-11T18:04:26Z"
        ).utf8)
        data.append(0x0A)
        let noise = Data(#"{"msg":"n"}"#.utf8) + Data([0x0A])
        while data.count < LiveStatus.tailMaxBytes + 2048 {
            data.append(noise)
        }
        try data.write(to: logs.appendingPathComponent("unified.jsonl"))
        let grok = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            now: now
        ).grok)
        XCTAssertNil(grok.weeklyPct)
        XCTAssertNil(grok.snapshotAt)
    }

    func testCodexNewestFileAndLastLineWin() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let oldReset5h = Int64(now.addingTimeInterval(300).timeIntervalSince1970)
        let oldResetWeek = Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)
        let newReset5h = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let newResetWeek = Int64(now.addingTimeInterval(604_800).timeIntervalSince1970)
        let older = try writeRollout(
            home,
            day: "2026/09/03",
            name: "rollout-2026-09-03T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            lines: [
                try codexLimits(
                    timestamp: "2026-09-03T12:00:00.000Z",
                    planType: "plus",
                    primaryPct: 10,
                    primaryMinutes: 300,
                    primaryResets: oldReset5h,
                    secondaryPct: 5,
                    secondaryMinutes: 10080,
                    secondaryResets: oldResetWeek
                ),
            ],
            mtime: now.addingTimeInterval(-3600)
        )
        let newer = try writeRollout(
            home,
            day: "2026/09/04",
            name: "rollout-2026-09-04T18-48-00-ffffffff-1111-2222-3333-444444444444.jsonl",
            lines: [
                try codexLimits(
                    timestamp: "2026-09-04T18:40:00.000Z",
                    planType: "plus",
                    primaryPct: 50,
                    primaryMinutes: 300,
                    primaryResets: oldReset5h,
                    secondaryPct: 20,
                    secondaryMinutes: 10080,
                    secondaryResets: oldResetWeek,
                    message: sentinelMessage
                ),
                #"{"timestamp":"2026-09-04T18:41:00.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,
                try codexLimits(
                    timestamp: "2026-09-04T18:48:59.248Z",
                    planType: "plus",
                    primaryPct: 99,
                    primaryMinutes: 300,
                    primaryResets: newReset5h,
                    secondaryPct: 31,
                    secondaryMinutes: 10080,
                    secondaryResets: newResetWeek,
                    message: sentinelMessage
                ),
            ],
            mtime: now
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        let status = try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            openaiWeekTokens: 42,
            openaiWeekUsdEstimate: 0.02,
            codexHome: home,
            now: now
        )
        let openai = try XCTUnwrap(status.plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.title, "OpenAI · Codex")
        XCTAssertEqual(openai.fiveHourPct, 99)
        XCTAssertEqual(openai.weeklyPct, 31)
        XCTAssertEqual(openai.plan, "ChatGPT Plus")
        XCTAssertEqual(openai.snapshotAt, "2026-09-04T18:48:59.248Z")
        XCTAssertEqual(openai.fiveHourResetsAt, UTC.iso(Date(timeIntervalSince1970: TimeInterval(newReset5h))))
        XCTAssertEqual(openai.weeklyResetsAt, UTC.iso(Date(timeIntervalSince1970: TimeInterval(newResetWeek))))
        XCTAssertEqual(openai.weeklyTokens, 42)
        XCTAssertEqual(openai.weeklyUsd ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(
            openai.usageNote,
            "Codex limits on the ChatGPT Plus plan. Chat message caps are not in local files."
        )
        let blob = try JSONValue.data(openai.jsonObject())
        XCTAssertFalse(String(data: blob, encoding: .utf8)!.contains("DO-NOT-INGEST"))
        let chatgpt = try XCTUnwrap(status.plans.first { $0.source == "chatgpt" })
        XCTAssertEqual(
            chatgpt.usageNote,
            "Covered by the OpenAI · Codex row above; chat message caps are not in local files."
        )
    }

    func testCodexPastResetNullsThatWindow() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let past5h = Int64(now.addingTimeInterval(-60).timeIntervalSince1970)
        let futureWeek = Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)
        _ = try writeRollout(
            home,
            day: "2026/09/04",
            name: "rollout-2026-09-04T18-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            lines: [
                try codexLimits(
                    timestamp: "2026-09-04T18:48:59.248Z",
                    planType: "plus",
                    primaryPct: 99,
                    primaryMinutes: 300,
                    primaryResets: past5h,
                    secondaryPct: 31,
                    secondaryMinutes: 10080,
                    secondaryResets: futureWeek
                ),
            ],
            mtime: now
        )
        let openai = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            codexHome: home,
            now: now
        ).plans.first { $0.source == "openai" })
        XCTAssertNil(openai.fiveHourPct)
        XCTAssertNil(openai.fiveHourResetsAt)
        XCTAssertEqual(openai.weeklyPct, 31)
        XCTAssertEqual(openai.plan, "ChatGPT Plus")
        XCTAssertTrue(openai.jsonObject()["five_hour_pct"] is NSNull)
    }

    func testCodexMapsWindowsByMinutesNotNames() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let reset5h = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let resetWeek = Int64(now.addingTimeInterval(604_800).timeIntervalSince1970)
        _ = try writeRollout(
            home,
            day: "2026/09/04",
            name: "rollout-2026-09-04T18-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            lines: [
                try jsonLine([
                    "timestamp": "2026-09-04T18:48:59.248Z",
                    "type": "event_msg",
                    "payload": [
                        "type": "token_count",
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "plus",
                            "primary": [
                                "used_percent": 31.0,
                                "window_minutes": 10080,
                                "resets_at": resetWeek,
                            ],
                            "secondary": [
                                "used_percent": 12.0,
                                "window_minutes": 300,
                                "resets_at": reset5h,
                            ],
                            "rate_limit_reached_type": "primary",
                        ],
                    ],
                ] as [String: Any]),
            ],
            mtime: now
        )
        let openai = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            codexHome: home,
            now: now
        ).plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.fiveHourPct, 12)
        XCTAssertEqual(openai.weeklyPct, 31)
        XCTAssertEqual(openai.limitReached, "primary")
        XCTAssertEqual(openai.jsonObject()["limit_reached"] as? String, "primary")
    }

    func testCodexSkipsTrailingEmptyPremiumLimits() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let reset5h = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let resetWeek = Int64(now.addingTimeInterval(604_800).timeIntervalSince1970)
        _ = try writeRollout(
            home,
            day: "2026/09/04",
            name: "rollout-2026-09-04T18-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            lines: [
                try codexLimits(
                    timestamp: "2026-09-04T18:49:11.883Z",
                    planType: "plus",
                    primaryPct: 100,
                    primaryMinutes: 300,
                    primaryResets: reset5h,
                    secondaryPct: 32,
                    secondaryMinutes: 10080,
                    secondaryResets: resetWeek
                ),
                try jsonLine([
                    "timestamp": "2026-09-04T18:49:12.135Z",
                    "type": "event_msg",
                    "payload": [
                        "type": "token_count",
                        "rate_limits": [
                            "limit_id": "premium",
                            "plan_type": "plus",
                            "primary": NSNull(),
                            "secondary": NSNull(),
                            "rate_limit_reached_type": NSNull(),
                        ],
                    ],
                ] as [String: Any]),
            ],
            mtime: now
        )
        let openai = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            codexHome: home,
            now: now
        ).plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.fiveHourPct, 100)
        XCTAssertEqual(openai.weeklyPct, 32)
        XCTAssertEqual(openai.snapshotAt, "2026-09-04T18:49:11.883Z")
        XCTAssertEqual(openai.plan, "ChatGPT Plus")
    }

    func testCodexIgnoresArchivedSessions() throws {
        let home = try TempDir.make()
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let reset5h = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let resetWeek = Int64(now.addingTimeInterval(604_800).timeIntervalSince1970)
        _ = try writeRollout(
            home,
            day: "archived_sessions/2026/09/04",
            name: "rollout-2026-09-04T18-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            lines: [
                try codexLimits(
                    timestamp: "2026-09-04T18:48:59.248Z",
                    planType: "plus",
                    primaryPct: 1,
                    primaryMinutes: 300,
                    primaryResets: reset5h,
                    secondaryPct: 2,
                    secondaryMinutes: 10080,
                    secondaryResets: resetWeek
                ),
            ],
            mtime: now.addingTimeInterval(10)
        )
        let openai = try XCTUnwrap(try LiveStatus.scan(
            grokHome: home,
            claudeHome: home,
            grokWeekUsd: 0,
            codexHome: home,
            now: now
        ).plans.first { $0.source == "openai" })
        XCTAssertNil(openai.fiveHourPct)
        XCTAssertNil(openai.weeklyPct)
        XCTAssertNil(openai.snapshotAt)
    }

    func testFixtureGrokQuotaLastLine() throws {
        let now = UTC.parse("2026-09-04T19:00:00Z")!
        let status = try LiveStatus.scan(
            grokHome: Fixtures.grokQuotaHome,
            claudeHome: try TempDir.make(),
            grokWeekUsd: 0,
            now: now
        )
        let grok = try XCTUnwrap(status.grok)
        XCTAssertEqual(grok.weeklyPct, 2)
        XCTAssertEqual(grok.plan, "SuperGrok Plus")
        XCTAssertEqual(grok.snapshotAt, "2026-09-04T18:43:52.216Z")
    }

    func testFixtureCodexQuota() throws {
        let now = UTC.parse("2026-09-04T18:50:00Z")!
        let status = try LiveStatus.scan(
            grokHome: try TempDir.make(),
            claudeHome: try TempDir.make(),
            grokWeekUsd: 0,
            codexHome: Fixtures.codexQuotaHome,
            now: now
        )
        let openai = try XCTUnwrap(status.plans.first { $0.source == "openai" })
        XCTAssertEqual(openai.fiveHourPct, 99)
        XCTAssertEqual(openai.weeklyPct, 31)
        XCTAssertEqual(openai.plan, "ChatGPT Plus")
        XCTAssertEqual(openai.snapshotAt, "2026-09-04T18:48:59.248Z")
    }
}

private func jsonLine(_ obj: [String: Any]) throws -> String {
    String(decoding: try JSONValue.data(obj), as: UTF8.self)
}

private func grokBilling(
    ts: String,
    pct: Int,
    periodType: String = "USAGE_PERIOD_TYPE_WEEKLY",
    end: String,
    tier: String = "SuperGrok Plus",
    onDemandCap: Int = 0,
    onDemandUsed: Int = 0
) throws -> String {
    try jsonLine([
        "ts": ts,
        "msg": "billing: fetched credits config",
        "ctx": [
            "config": [
                "creditUsagePercent": Double(pct),
                "currentPeriod": [
                    "type": periodType,
                    "start": "2026-09-04T18:04:26.160272+00:00",
                    "end": end,
                ],
                "onDemandCap": ["val": onDemandCap],
                "onDemandUsed": ["val": onDemandUsed],
            ],
            "subscriptionTier": tier,
        ],
    ] as [String: Any])
}

private func writeGrokLog(_ home: URL, lines: [String]) throws {
    let dir = home.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = lines.joined(separator: "\n") + "\n"
    try Data(body.utf8).write(to: dir.appendingPathComponent("unified.jsonl"))
}

private func codexLimits(
    timestamp: String,
    planType: String,
    primaryPct: Int,
    primaryMinutes: Int,
    primaryResets: Int64,
    secondaryPct: Int,
    secondaryMinutes: Int,
    secondaryResets: Int64,
    message: String? = nil,
    reached: String? = nil
) throws -> String {
    var limits: [String: Any] = [
        "limit_id": "codex",
        "plan_type": planType,
        "primary": [
            "used_percent": Double(primaryPct),
            "window_minutes": primaryMinutes,
            "resets_at": primaryResets,
        ],
        "secondary": [
            "used_percent": Double(secondaryPct),
            "window_minutes": secondaryMinutes,
            "resets_at": secondaryResets,
        ],
        "credits": ["has_credits": false, "unlimited": false, "balance": "0"],
    ]
    if let reached {
        limits["rate_limit_reached_type"] = reached
    } else {
        limits["rate_limit_reached_type"] = NSNull()
    }
    var payload: [String: Any] = [
        "type": "event_msg",
        "rate_limits": limits,
    ]
    if let message {
        payload["message"] = message
    }
    return try jsonLine([
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": payload,
    ] as [String: Any])
}

private func writeRollout(
    _ home: URL,
    day: String,
    name: String,
    lines: [String],
    mtime: Date
) throws -> URL {
    let dir = home.appendingPathComponent("sessions/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    return url
}
