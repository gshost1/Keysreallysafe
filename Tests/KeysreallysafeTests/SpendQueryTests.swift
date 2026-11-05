import XCTest
@testable import KeysCore

final class SpendQueryTests: XCTestCase {
    func testDailyByModelStacksOneSeriesPerModel() throws {
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: "2026-01-16T10:00:00Z", usd: 5, prompt: "a", model: "grok-4.6-build"))
        _ = try db.insertUsage(grokEvent(at: "2026-01-16T11:00:00Z", usd: 3.1, prompt: "b", model: "grok-4-fast"))
        let now = UTC.parse("2026-01-16T18:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(Set(report.daily.map(\.model)), ["grok-4.6-build", "grok-4-fast"])
        XCTAssertEqual(report.daily.count, 2)
        let stacked = report.daily.compactMap(\.usdEstimate).reduce(0, +)
        XCTAssertEqual(stacked, try XCTUnwrap(report.totals.gatewayUsdEstimate), accuracy: 1e-9)
        XCTAssertEqual(stacked, 8.1, accuracy: 1e-9)
        XCTAssertEqual(report.caption, SpendReport.captionText)
    }

    /// The report is the gateway ledger and nothing else: rows another tool's log reader stored
    /// before 0.16 (still in a catalog until the launch cleanup runs) are never counted.
    func testReportCountsOnlyGatewayRows() throws {
        let (db, _) = try makeDB()
        _ = try db.insertUsage(grokEvent(at: "2026-01-16T10:00:00Z", usd: 2, prompt: "gw"))
        _ = try db.insertUsage(.fixture(source: "claude-local", prompt: "old", model: "claude-sonnet-5",
                                        at: "2026-01-16T11:00:00Z", provider: "anthropic", key: nil,
                                        input: 1_000, output: 1_000))
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, now: UTC.parse("2026-01-20T00:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.rows.map(\.model), ["grok-4.6-build"])
        XCTAssertEqual(report.totals.gatewayCalls, 1)
        XCTAssertEqual(report.totals.tokens, 15)
        let totals = try XCTUnwrap(report.jsonObject()["totals"] as? [String: Any])
        for gone in ["grok_usd", "claude_tokens", "openai_tokens", "remote_tokens", "usd_estimate", "gateway_correlated_calls"] {
            XCTAssertNil(totals[gone], "\(gone) belonged to the subscription ledger")
        }
        XCTAssertNil(report.jsonObject()["source"])
        XCTAssertNil(report.jsonObject()["last_ingest_at"])
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
        let week = try queries.report(range: .week, by: .model, now: now, timeZone: tz)
        let month = try queries.report(range: .month, by: .model, now: now, timeZone: tz)
        XCTAssertEqual((week.totals.gatewayUsdEstimate ?? 0), 13, accuracy: 1e-9)
        XCTAssertEqual((month.totals.gatewayUsdEstimate ?? 0), 3, accuracy: 1e-9)
        XCTAssertGreaterThan((week.totals.gatewayUsdEstimate ?? 0), (month.totals.gatewayUsdEstimate ?? 0))
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
        let week = try queries.report(range: .week, by: .model, now: now, timeZone: tz)
        let month = try queries.report(range: .month, by: .model, now: now, timeZone: tz)
        XCTAssertEqual((week.totals.gatewayUsdEstimate ?? 0), 2, accuracy: 1e-9)
        XCTAssertEqual((month.totals.gatewayUsdEstimate ?? 0), 10, accuracy: 1e-9)
        XCTAssertLessThanOrEqual((week.totals.gatewayUsdEstimate ?? 0), (month.totals.gatewayUsdEstimate ?? 0))
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
        let month = try SpendQueries(db: db).report(range: .month, by: .model, now: now, timeZone: tz)
        XCTAssertEqual((month.totals.gatewayUsdEstimate ?? 0), 11, accuracy: 1e-9)
    }

    func testClaudePriceTableLongestPrefixAndCoverage() throws {
        XCTAssertEqual(ModelPrices.lookup("claude-fable-5-1")?.inputPerMTok, 10)
        XCTAssertEqual(ModelPrices.lookup("claude-fable-5-1")?.cacheReadPerMTok, 0.25)
        XCTAssertEqual(ModelPrices.lookup("claude-fable-5")?.cacheReadPerMTok, 1.00)
        XCTAssertEqual(ModelPrices.lookup("claude-mythos-5")?.inputPerMTok, 10)
        XCTAssertEqual(ModelPrices.lookup("claude-opus-5")?.inputPerMTok, 5)
        XCTAssertEqual(ModelPrices.lookup("claude-opus-5")?.outputPerMTok, 25)
        XCTAssertEqual(ModelPrices.lookup("claude-opus-4-5")?.inputPerMTok, 5)
        XCTAssertEqual(ModelPrices.lookup("claude-opus-4")?.inputPerMTok, 15)
        XCTAssertEqual(ModelPrices.lookup("claude-sonnet-5")?.inputPerMTok, 2)
        XCTAssertEqual(ModelPrices.lookup("claude-sonnet-5")?.outputPerMTok, 10)
        XCTAssertEqual(ModelPrices.lookup("claude-sonnet-4-6")?.inputPerMTok, 3)
        XCTAssertEqual(ModelPrices.lookup("claude-haiku-4-5")?.inputPerMTok, 1)

        let million = 1_000_000
        let opus5 = try XCTUnwrap(GatewayEstimate.usd(
            model: "claude-opus-5", input: million, output: million, cacheRead: 0, cacheWrite: 0, api: "anthropic"
        ))
        let opusGeneric = try XCTUnwrap(GatewayEstimate.usd(
            model: "claude-opus", input: million, output: million, cacheRead: 0, cacheWrite: 0, api: "anthropic"
        ))
        XCTAssertEqual(opus5, 30, accuracy: 1e-9)
        XCTAssertEqual(opusGeneric, 90, accuracy: 1e-9)

        let (db, _) = try makeDB()
        _ = try db.insertUsage(.fixture(prompt: "fable", model: "claude-fable-5-1", provider: "anthropic", input: 1000, output: 200))
        _ = try db.insertUsage(.fixture(prompt: "mystery", model: "claude-mystery", provider: "anthropic", input: 50, output: 10))
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let fable = try XCTUnwrap(report.rows.first { $0.model == "claude-fable-5-1" })
        XCTAssertNotNil(fable.usdEstimate)
        let mystery = try XCTUnwrap(report.rows.first { $0.model == "claude-mystery" })
        XCTAssertNil(mystery.usdEstimate)
        XCTAssertEqual(report.totals.gatewayUnpricedModels, ["claude-mystery"])
        XCTAssertEqual(report.totals.gatewayUnpricedTokens, 60)
        XCTAssertEqual(report.totals.gatewayPricedTokens, 1200)
    }

    func testEmptySpendJSONIncludesIntervalKeys() throws {
        let (db, _) = try makeDB()
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let report = try SpendQueries(db: db).report(
            range: .week, by: .model, now: now, timeZone: tz
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
        _ = try db.insertUsage(UsageEvent(
            source: "gateway", sessionId: "gw:claude", promptId: "req-1", model: "claude-sonnet-5",
            occurredAt: "2026-01-15T12:00:00Z", provider: "anthropic", modelCalls: 1,
            inputTokens: 200, outputTokens: 80, cachedReadTokens: 40, keyName: "claude"
        ))
        let now = UTC.parse("2026-01-20T00:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.daily.count, 1)
        let point = try XCTUnwrap(report.daily.first)
        XCTAssertEqual(point.model, "claude-sonnet-5")
        XCTAssertEqual(point.inputTokens, 200)
        XCTAssertEqual(point.outputTokens, 80)
        XCTAssertEqual(point.cachedReadTokens, 40)
        XCTAssertEqual(point.cacheCreationTokens, 0)
        XCTAssertEqual(point.tokens, 320, "Anthropic's cache reads sit beside input and count")
        let expected = GatewayEstimate.usd(
            model: "claude-sonnet-5", input: 200, output: 80, cacheRead: 40, cacheWrite: 0, api: "anthropic"
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
            range: .today, by: .hour, now: now, timeZone: tz
        )
        XCTAssertEqual(hourly.points.map(\.hour), ["2026-09-04T10:00", "2026-09-04T14:00"])
        XCTAssertEqual(hourly.points[0].usdEstimate ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(hourly.points[1].usdEstimate ?? 0, 0.5, accuracy: 1e-9)
        let json = hourly.jsonObject()
        let points = json["points"] as! [[String: Any]]
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["hour"] as? String, "2026-09-04T10:00")
        XCTAssertNotNil(points[0]["input_tokens"])
        XCTAssertNotNil(points[0]["usd_estimate"])

        let today = try SpendQueries(db: db).report(
            range: .today, by: .model, now: now, timeZone: tz
        )
        XCTAssertEqual(today.daily.map(\.day), ["2026-09-04"])
        XCTAssertTrue(today.points.isEmpty)
        XCTAssertEqual((today.totals.gatewayUsdEstimate ?? 0), 11, accuracy: 1e-9)
    }

    func testDailyBucketsUseLocalTimezoneNotUTC() throws {
        let tz = Self.denver
        let now = localDate(2026, 9, 3, 12, 0, timeZone: tz)
        let (db, _) = try makeDB()
        // 05:00 UTC on Sep 2 is 23:00 MDT on Sep 1.
        _ = try db.insertUsage(grokEvent(at: "2026-09-02T05:00:00Z", usd: 1.5, prompt: "late-local"))
        let month = try SpendQueries(db: db).report(range: .month, by: .model, now: now, timeZone: tz)
        XCTAssertEqual(month.daily.map(\.day), ["2026-09-01"])
        XCTAssertEqual(month.daily.first?.usdEstimate ?? 0, 1.5, accuracy: 1e-9)
    }

    // A by=model row groups by the model id, so one row can mix providers, and each provider's
    // API counts tokens its own way: Anthropic's cache buckets sit beside input, OpenAI-style
    // input already holds cached reads and reasoning is billed apart. The chart reads the
    // engine's per-row total instead of re-deriving a rule from the model name.
    func testModelRowMixingProvidersCountsEachCallByItsOwnRule() throws {
        let (db, _) = try makeDB()
        // Anthropic: 1,000 + 200 + 400 + 100.
        _ = try db.insertUsage(UsageEvent(
            source: "gateway", sessionId: "gw:a", promptId: "a-1", model: "claude-sonnet-5",
            occurredAt: "2026-10-10T20:00:00Z", provider: "anthropic",
            inputTokens: 1_000, outputTokens: 200, cachedReadTokens: 400, cacheCreationTokens: 100, keyName: "a"
        ))
        // An OpenAI-compatible router for the same model: 100 + 50 + 25.
        _ = try db.insertUsage(UsageEvent(
            source: "gateway", sessionId: "gw:r", promptId: "r-1", model: "claude-sonnet-5",
            occurredAt: "2026-10-10T21:00:00Z", provider: "openrouter",
            inputTokens: 100, outputTokens: 50, cachedReadTokens: 30, reasoningTokens: 25, keyName: "r"
        ))
        let now = UTC.parse("2026-10-10T22:00:00Z")!
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let rows = report.rows.filter { $0.model == "claude-sonnet-5" }
        XCTAssertEqual(rows.reduce(0) { $0 + $1.countedTokens }, 1_700 + 175)
        XCTAssertEqual(report.totals.tokens, 1_875)
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
}
