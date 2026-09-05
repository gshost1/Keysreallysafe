import XCTest
@testable import KeysCore

final class SpendQueryTests: XCTestCase {
    func testOpenAISourceUsesCodexLocalEstimateNotGrokTicks() throws {
        let (db, _) = try makeDB()
        _ = try CodexIngest.run(home: Fixtures.codexHome, db: db)
        let now = UTC.parse("2026-09-03T18:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .openai,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.grokUsd, 0, accuracy: 1e-12)
        XCTAssertEqual(report.totals.openaiTokens, 250)
        XCTAssertNotNil(report.totals.openaiUsdEstimate)
        XCTAssertEqual(report.rows.first?.model, "gpt-5.4")
        XCTAssertNotNil(report.rows.first?.usdEstimate)
        XCTAssertNil(report.rows.first?.usd)
    }

    func testMonthRollupByModelMatchesFixtureMath() throws {
        let (db, _) = try makeDB()
        _ = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .all,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let grok46 = try XCTUnwrap(report.rows.first { $0.model == "grok-4.6-build" })
        XCTAssertEqual(grok46.usd ?? 0, 14.1, accuracy: 1e-9)
        XCTAssertEqual(grok46.inputTokens, 180)
        XCTAssertFalse(report.rows.contains { $0.model == "unknown" })
        XCTAssertEqual(report.totals.grokUsd, 16.2, accuracy: 1e-9)
        XCTAssertEqual(report.caption, SpendReport.captionText)
    }

    func testDailyByModelTwoSeriesFromTwoModelFixture() throws {
        let (db, _) = try makeDB()
        let line = try String(contentsOf: Fixtures.twoModels, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .joined()
        let events = try GrokIngest.parseLine(line, sessionDirName: "sess-2", summary: nil)
        for event in events { _ = try db.insertUsage(event) }
        let now = UTC.parse("2026-01-16T18:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .grok,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let models = Set(report.daily.map(\.model))
        XCTAssertEqual(models, ["grok-4.6-build", "grok-4-fast"])
        XCTAssertEqual(report.daily.count, 2)
        let stacked = report.daily.compactMap(\.usd).reduce(0, +)
        XCTAssertEqual(stacked, report.totals.grokUsd, accuracy: 1e-9)
        XCTAssertEqual(stacked, 8.1, accuracy: 1e-9)
    }

    func testClaudeUsdIsEstimateNotMixedIntoGrokTotal() throws {
        let (db, _) = try makeDB()
        _ = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        _ = try ClaudeIngest.run(home: Fixtures.claudeHome, db: db)
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .all,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.grokUsd, 16.2, accuracy: 1e-9)
        XCTAssertGreaterThan(report.totals.claudeTokens, 0)
        XCTAssertNotNil(report.totals.claudeUsdEstimate)
        let claude = try XCTUnwrap(report.rows.first { $0.model == "claude-sonnet-5" })
        XCTAssertNil(claude.usd)
        XCTAssertNotNil(claude.usdEstimate)
        let json = String(data: try JSONValue.data(report.jsonObject()), encoding: .utf8)!
        XCTAssertTrue(json.contains("estimate, not invoice"))
        XCTAssertFalse(json.contains(sentinelClaude))
        XCTAssertFalse(json.contains(sentinelMessage))
    }

    func testBySessionIncludesCwdTitleWithoutMessageText() throws {
        let (db, _) = try makeDB()
        _ = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .session,
            source: .grok,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(report.rows.contains { $0.cwd == "/tmp/keysreallysafe-fixture" })
        XCTAssertTrue(report.rows.contains { $0.title == "Synthetic fixture session" })
        let json = String(data: try JSONValue.data(report.jsonObject()), encoding: .utf8)!
        XCTAssertFalse(json.contains(sentinelMessage))
        XCTAssertFalse(json.contains(sentinelRaw))
    }

    func testIngestTwiceDoesNotDoubleMonthTotal() throws {
        let (db, _) = try makeDB()
        _ = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        _ = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .grok,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.grokUsd, 16.2, accuracy: 1e-9)
    }

    func testMonthIntervalIsCalendarMonthInclusiveStartExclusiveEnd() {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (start, end) = SpendRange.month.interval(now: now, timeZone: tz)
        XCTAssertEqual(SpendRange.localDay(start, timeZone: tz), "2026-09-01")
        XCTAssertEqual(SpendRange.localDay(end, timeZone: tz), "2026-10-01")
        XCTAssertEqual(SpendRange.inclusiveEndDay(end: end, timeZone: tz), "2026-09-30")
        XCTAssertEqual(start, localDate(2026, 9, 1, 0, 0, timeZone: tz))
        XCTAssertEqual(end, localDate(2026, 10, 1, 0, 0, timeZone: tz))
    }

    func testWeekIntervalCanCrossIntoPreviousMonth() {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (start, end) = SpendRange.week.interval(now: now, timeZone: tz)
        let (monthStart, monthEnd) = SpendRange.month.interval(now: now, timeZone: tz)
        XCTAssertLessThan(start, now)
        XCTAssertGreaterThan(end, now)
        XCTAssertLessThan(start, monthStart, "calendar week of Sep 3 2026 starts in August")
        XCTAssertLessThan(monthStart, end)
        XCTAssertEqual(SpendRange.localDay(start, timeZone: tz).prefix(7), "2026-08")
        XCTAssertEqual(SpendRange.localDay(end, timeZone: tz).prefix(7), "2026-09")
        XCTAssertLessThan(start, end)
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 24 * 60 * 60, accuracy: 1)
        XCTAssertGreaterThanOrEqual(monthEnd.timeIntervalSince(monthStart), 28 * 24 * 60 * 60)
    }

    func testWeekSpendCanExceedMonthWhenWeekCrossesMonth() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 8, 31, 12, 0, timeZone: tz)), usd: 10, prompt: "aug"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 2, 12, 0, timeZone: tz)), usd: 3, prompt: "sep"))
        let queries = SpendQueries(db: db)
        let week = try queries.report(range: .week, by: .model, source: .grok, now: now, timeZone: tz)
        let month = try queries.report(range: .month, by: .model, source: .grok, now: now, timeZone: tz)
        XCTAssertEqual(week.totals.grokUsd, 13, accuracy: 1e-9)
        XCTAssertEqual(month.totals.grokUsd, 3, accuracy: 1e-9)
        XCTAssertGreaterThan(week.totals.grokUsd, month.totals.grokUsd)
        XCTAssertEqual(week.startDay.prefix(7), "2026-08")
        XCTAssertEqual(month.startDay, "2026-09-01")
        XCTAssertEqual(month.endDay, "2026-09-30")
        let json = week.jsonObject()
        XCTAssertEqual(json["start_day"] as? String, week.startDay)
        XCTAssertEqual(json["end_day"] as? String, week.endDay)
        XCTAssertEqual(json["start"] as? String, UTC.iso(week.start))
        XCTAssertEqual(json["end"] as? String, UTC.iso(week.end))
    }

    func testWeekDoesNotExceedMonthWhenWeekLiesInsideMonth() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 16, 12, 0, timeZone: tz)
        let (weekStart, weekEnd) = SpendRange.week.interval(now: now, timeZone: tz)
        XCTAssertEqual(SpendRange.localDay(weekStart, timeZone: tz).prefix(7), "2026-09")
        XCTAssertEqual(SpendRange.inclusiveEndDay(end: weekEnd, timeZone: tz).prefix(7), "2026-09")
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 8, 31, 12, 0, timeZone: tz)), usd: 10, prompt: "aug"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 15, 12, 0, timeZone: tz)), usd: 2, prompt: "in-week"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 22, 12, 0, timeZone: tz)), usd: 8, prompt: "later-week"))
        let queries = SpendQueries(db: db)
        let week = try queries.report(range: .week, by: .model, source: .grok, now: now, timeZone: tz)
        let month = try queries.report(range: .month, by: .model, source: .grok, now: now, timeZone: tz)
        XCTAssertEqual(week.totals.grokUsd, 2, accuracy: 1e-9)
        XCTAssertEqual(month.totals.grokUsd, 10, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(week.totals.grokUsd, month.totals.grokUsd)
    }

    func testInclusiveStartExclusiveEndOnUsageQuery() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (start, end) = SpendRange.month.interval(now: now, timeZone: tz)
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: UTC.iso(start.addingTimeInterval(-1)), usd: 4, prompt: "before"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(start), usd: 5, prompt: "on-start"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(end.addingTimeInterval(-1)), usd: 6, prompt: "before-end"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(end), usd: 7, prompt: "on-end"))
        let month = try SpendQueries(db: db).report(range: .month, by: .model, source: .grok, now: now, timeZone: tz)
        XCTAssertEqual(month.totals.grokUsd, 11, accuracy: 1e-9)
    }

    func testClaudePriceTableLongestPrefixAndCoverage() throws {
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-fable-5-1")?.inputPerMTok, 10)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-fable-5-1")?.cachedPerMTok, 0.25)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-fable-5")?.cachedPerMTok, 1.00)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-mythos-5")?.inputPerMTok, 10)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-opus-5")?.inputPerMTok, 5)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-opus-5")?.outputPerMTok, 25)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-opus-4-5")?.inputPerMTok, 5)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-opus-4")?.inputPerMTok, 15)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-sonnet-5")?.inputPerMTok, 2)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-sonnet-5")?.outputPerMTok, 10)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-sonnet-4-6")?.inputPerMTok, 3)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-haiku-4-5")?.inputPerMTok, 1)

        let million = 1_000_000
        let opus5 = try XCTUnwrap(ClaudeEstimate.usd(
            model: "claude-opus-5", input: million, output: million, cacheCreate: 0, cacheRead: 0
        ))
        let opusGeneric = try XCTUnwrap(ClaudeEstimate.usd(
            model: "claude-opus", input: million, output: million, cacheCreate: 0, cacheRead: 0
        ))
        XCTAssertEqual(opus5, 30, accuracy: 1e-9)
        XCTAssertEqual(opusGeneric, 90, accuracy: 1e-9)
        XCTAssertEqual(opus5, opusGeneric / 3, accuracy: 1e-9)

        let (db, _) = try makeDB()
        _ = try db.insertUsage(claudeEvent(model: "claude-fable-5-1", input: 1000, output: 200, prompt: "fable"))
        _ = try db.insertUsage(claudeEvent(model: "claude-mystery", input: 50, output: 10, prompt: "mystery"))
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .claude, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let fable = try XCTUnwrap(report.rows.first { $0.model == "claude-fable-5-1" })
        XCTAssertNotNil(fable.usdEstimate)
        let mystery = try XCTUnwrap(report.rows.first { $0.model == "claude-mystery" })
        XCTAssertNil(mystery.usdEstimate)
        XCTAssertEqual(report.totals.claudeUnpricedModels, ["claude-mystery"])
        XCTAssertEqual(report.totals.claudeUnpricedTokens, 60)
        XCTAssertEqual(report.totals.claudePricedTokens, 1200)
        let json = report.jsonObject()["totals"] as! [String: Any]
        XCTAssertEqual(json["claude_usd_estimate_label"] as? String, "estimate, not invoice; 1 model unpriced")
    }

    func testEmptySpendJSONIncludesIntervalKeys() throws {
        let (db, _) = try makeDB()
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let report = try SpendQueries(db: db).report(
            range: .week, by: .model, source: .all, now: now, timeZone: tz
        )
        XCTAssertTrue(report.rows.isEmpty)
        XCTAssertTrue(report.daily.isEmpty)
        let json = report.jsonObject()
        XCTAssertEqual(json["start_day"] as? String, report.startDay)
        XCTAssertEqual(json["end_day"] as? String, report.endDay)
        XCTAssertFalse((json["start_day"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["end_day"] as? String ?? "").isEmpty)
        XCTAssertNotNil(json["start"] as? String)
        XCTAssertNotNil(json["end"] as? String)
        XCTAssertEqual(json["catalog_version"] as? Int, 0)
    }

    func testDailyPointsCarryTokenBucketsAndUsdEstimate() throws {
        let (db, _) = try makeDB()
        _ = try ClaudeIngest.run(home: Fixtures.claudeHome, db: db)
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .claude,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.daily.count, 1)
        let point = try XCTUnwrap(report.daily.first)
        XCTAssertEqual(point.model, "claude-sonnet-5")
        XCTAssertEqual(point.inputTokens, 200)
        XCTAssertEqual(point.outputTokens, 80)
        XCTAssertEqual(point.cachedReadTokens, 40)
        XCTAssertEqual(point.cacheCreationTokens, 0)
        XCTAssertEqual(point.tokens, 320)
        let expected = ClaudeEstimate.usd(
            model: "claude-sonnet-5", input: 200, output: 80, cacheCreate: 0, cacheRead: 40
        )
        XCTAssertEqual(point.usdEstimate ?? 0, expected ?? 0, accuracy: 1e-12)
        let obj = report.jsonObject()["daily"] as! [[String: Any]]
        XCTAssertNotNil(obj[0]["input_tokens"])
        XCTAssertNotNil(obj[0]["usd_estimate"])
        XCTAssertEqual(obj[0]["cache_creation_tokens"] as? Int, 0)
    }

    func testTodayByHourEmitsElapsedHoursOnly() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 4, 14, 30, timeZone: tz)
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 4, 10, 0, timeZone: tz)), usd: 1.5, prompt: "ten"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 4, 14, 10, timeZone: tz)), usd: 0.5, prompt: "two"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 4, 16, 0, timeZone: tz)), usd: 9, prompt: "future"))
        _ = try db.insertUsage(grokEvent(at: UTC.iso(localDate(2026, 9, 3, 23, 0, timeZone: tz)), usd: 3, prompt: "yesterday"))
        let hourly = try SpendQueries(db: db).report(
            range: .today, by: .hour, source: .grok, now: now, timeZone: tz
        )
        XCTAssertEqual(hourly.points.map(\.hour), ["2026-09-04T10:00", "2026-09-04T14:00"])
        XCTAssertEqual(hourly.points[0].usd ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(hourly.points[1].usd ?? 0, 0.5, accuracy: 1e-9)
        let json = hourly.jsonObject()
        let points = json["points"] as! [[String: Any]]
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["hour"] as? String, "2026-09-04T10:00")
        XCTAssertNotNil(points[0]["input_tokens"])
        XCTAssertNotNil(points[0]["usd_estimate"])

        let today = try SpendQueries(db: db).report(
            range: .today, by: .model, source: .grok, now: now, timeZone: tz
        )
        XCTAssertEqual(today.daily.map(\.day), ["2026-09-04"])
        XCTAssertTrue(today.points.isEmpty)
        XCTAssertEqual(today.totals.grokUsd, 11, accuracy: 1e-9)
    }

    func testDailyBucketsUseLocalTimezoneNotUTC() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (db, _) = try makeDB()
        // 05:00 UTC on Sep 2 is 23:00 MDT on Sep 1.
        _ = try db.insertUsage(grokEvent(at: "2026-09-02T05:00:00Z", usd: 1.5, prompt: "late-local"))
        let month = try SpendQueries(db: db).report(range: .month, by: .model, source: .grok, now: now, timeZone: tz)
        XCTAssertEqual(month.daily.map(\.day), ["2026-09-01"])
        XCTAssertEqual(month.daily.first?.usd ?? 0, 1.5, accuracy: 1e-9)
    }

    private static let denver = TimeZone(identifier: "America/Denver")!

    private func localDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func claudeEvent(model: String, input: Int, output: Int, prompt: String) -> UsageEvent {
        UsageEvent(
            source: "claude-local",
            sessionId: "price",
            promptId: prompt,
            model: model,
            occurredAt: "2026-01-15T12:00:00Z",
            provider: "anthropic",
            cwd: nil,
            sessionTitle: nil,
            agentName: nil,
            stopReason: nil,
            modelCalls: 1,
            apiDurationMs: nil,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            costUsdTicks: nil
        )
    }

    private func grokEvent(at iso: String, usd: Double, prompt: String) -> UsageEvent {
        UsageEvent(
            source: "grok-local",
            sessionId: "boundary",
            promptId: prompt,
            model: "grok-4.6-build",
            occurredAt: iso,
            provider: "xai",
            cwd: nil,
            sessionTitle: nil,
            agentName: nil,
            stopReason: nil,
            modelCalls: 1,
            apiDurationMs: 1,
            inputTokens: 10,
            outputTokens: 5,
            cachedReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            costUsdTicks: Int64((usd * Ticks.perUSD).rounded())
        )
    }
}
