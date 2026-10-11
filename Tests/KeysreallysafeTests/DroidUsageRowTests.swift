import XCTest
@testable import KeysCore

/// The Droid Usage row: catalog-backed 5-hour, weekly and monthly token windows, the optional
/// per-window limits that turn a window into a percent meter, and the token-protected routes
/// that set and clear them. Every event here is invented and written straight into a temp
/// catalog; no Droid home is read.
final class DroidUsageRowTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// Wednesday 2026-10-07, so the calendar week contains 10-01 and 10-05 under either
    /// first-weekday convention and the month boundary is a real exclusion, not an accident.
    private var now: Date { UTC.parse("2026-10-07T21:30:00Z")! }

    private func event(
        at iso: String, prompt: String, model: String = "claude-opus-5-5",
        input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0
    ) -> UsageEvent {
        UsageEvent(
            source: "droid-local", sessionId: "sess-\(prompt)", promptId: prompt, model: model,
            occurredAt: iso, provider: "anthropic",
            inputTokens: input, outputTokens: output, cachedReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite, reasoningTokens: reasoning
        )
    }

    // 2026-10-07 21:30 UTC: 5-hour window starts 16:30, week covers 10-01..10-07 either way,
    // month is October. The 09-30 row sits before every window edge.
    private func seedWindows(_ db: CatalogDB) throws {
        _ = try db.insertUsage(event(at: "2026-10-07T20:00:00Z", prompt: "a", input: 100, output: 10))
        _ = try db.insertUsage(event(at: "2026-10-05T12:00:00Z", prompt: "b", input: 200, output: 20))
        _ = try db.insertUsage(event(at: "2026-10-01T00:10:00Z", prompt: "c", input: 400, output: 40))
        _ = try db.insertUsage(event(at: "2026-09-30T23:00:00Z", prompt: "d", input: 8_000, output: 800))
    }

    func testWindowsSeparateFiveHourWeekAndMonthFromTheCatalog() throws {
        let (db, _) = try makeDB()
        try seedWindows(db)
        // Another tool's rows never count toward the Droid windows, even in range.
        _ = try db.insertUsage(.fixture(
            source: "claude-local", session: "cx", prompt: "cx", model: "claude-sonnet-5",
            at: "2026-10-07T21:00:00Z", input: 999_999, output: 1
        ))
        let row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(row.source, "droid")
        XCTAssertEqual(row.title, "Droid")
        XCTAssertEqual(row.fiveHourTokens, 110)
        XCTAssertEqual(row.weeklyTokens, 330)
        XCTAssertEqual(row.monthlyTokens, 770)
        XCTAssertNil(row.fiveHourPct)
        XCTAssertNil(row.weeklyPct)
        XCTAssertNil(row.monthlyPct)
    }

    func testWindowsCountEveryBucketDroidsLogReports() throws {
        let (db, _) = try makeDB()
        _ = try db.insertUsage(event(
            at: "2026-10-07T20:00:00Z", prompt: "all",
            input: 100, cacheRead: 1_000, cacheWrite: 10, output: 50, reasoning: 25
        ))
        let row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        // One rule, the engine's `TokenTotals.normalized` for droid-local: every bucket counts.
        XCTAssertEqual(row.fiveHourTokens, 1_185)
        XCTAssertEqual(row.weeklyTokens, 1_185)
        XCTAssertEqual(row.monthlyTokens, 1_185)
    }

    func testALimitDrivesAPercentOnItsWindowOnlyAndMayPass100() throws {
        let (db, _) = try makeDB()
        try seedWindows(db)
        try db.setUsageLimit(source: "droid", window: "weekly", tokens: 1_000)
        var row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(row.weeklyTokens, 330)
        XCTAssertEqual(row.weeklyLimit, 1_000)
        XCTAssertEqual(row.weeklyPct, 33, "330 of 1000 is 33%, not a share of another window")
        XCTAssertNil(row.fiveHourLimit)
        XCTAssertNil(row.fiveHourPct)
        XCTAssertNil(row.monthlyLimit)
        XCTAssertNil(row.monthlyPct)

        // A blown limit stays honest: the number is allowed past 100, the meter caps visually.
        try db.setUsageLimit(source: "droid", window: "weekly", tokens: 200)
        row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(row.weeklyPct, 165)
        try db.setUsageLimit(source: "droid", window: "five_hour", tokens: 110)
        row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(row.fiveHourPct, 100)
        XCTAssertEqual(row.weeklyPct, 165)
        XCTAssertNil(row.monthlyPct)
    }

    func testRowJSONCarriesTheWindowFieldsInSnakeCase() throws {
        let (db, _) = try makeDB()
        try seedWindows(db)
        try db.setUsageLimit(source: "droid", window: "weekly", tokens: 1_000)
        let obj = try DroidUsage.row(catalog: db, now: now, timeZone: utc).jsonObject()
        XCTAssertEqual(obj["source"] as? String, "droid")
        XCTAssertEqual(obj["five_hour_tokens"] as? Int, 110)
        XCTAssertEqual(obj["weekly_tokens"] as? Int, 330)
        XCTAssertEqual(obj["monthly_tokens"] as? Int, 770)
        XCTAssertEqual(obj["weekly_limit"] as? Int, 1_000)
        XCTAssertEqual(obj["weekly_pct"] as? Int, 33)
        XCTAssertTrue(obj["five_hour_limit"] is NSNull)
        XCTAssertTrue(obj["monthly_limit"] is NSNull)
        XCTAssertTrue(obj["monthly_pct"] is NSNull)
    }

    func testAnEmptyCatalogSaysSoAndInventsNoNumbers() throws {
        let (db, _) = try makeDB()
        let row = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(row.fiveHourTokens, 0)
        XCTAssertEqual(row.weeklyTokens, 0)
        XCTAssertEqual(row.monthlyTokens, 0)
        XCTAssertNil(row.fiveHourPct)
        XCTAssertNil(row.weeklyPct)
        XCTAssertNil(row.monthlyPct)
        XCTAssertEqual(row.usageNote, "No Droid usage recorded yet. The windows fill from the per-request records in Droid's local logs.")

        // Records that all fell outside the windows are still records: zeros are real zeros,
        // not an empty disk, so the note stops claiming there is nothing recorded.
        _ = try db.insertUsage(event(at: "2026-09-30T23:00:00Z", prompt: "old", input: 1, output: 1))
        let counted = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(counted.weeklyTokens, 0)
        XCTAssertFalse(counted.usageNote!.contains("No Droid usage recorded yet"))

        // A limit on an empty window shows a real 0%, never a fabricated one.
        try db.setUsageLimit(source: "droid", window: "monthly", tokens: 500)
        let limited = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        XCTAssertEqual(limited.monthlyTokens, 0)
        XCTAssertEqual(limited.monthlyLimit, 500)
        XCTAssertEqual(limited.monthlyPct, 0)
    }

    func testServiceAndRouteSetClearAndRefuseBadLimits() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let handler = APIHandler(service: service, webRoot: dir)
        let catalogPath = dir.appendingPathComponent("catalog.db")

        // The service refuses a limit for a row it does not track, and shapes it cannot parse.
        XCTAssertThrowsError(try service.setUsageLimit(source: "claude", window: "weekly", tokens: 100))
        XCTAssertThrowsError(try service.setUsageLimit(source: "droid", window: "yearly", tokens: 100))
        XCTAssertThrowsError(try service.setUsageLimit(source: "droid", window: "weekly", tokens: 0))
        XCTAssertThrowsError(try service.setUsageLimit(source: "droid", window: "weekly", tokens: -5))

        func body(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tokens": value])
        }
        func send(_ method: String, _ path: String, payload: Data = Data(), token: Bool = true) throws -> HTTPResponse {
            handle(handler, method: method, path: path, body: payload, token: token)
        }

        // A write without the per-launch token never reaches the service.
        let unguarded = try send("PUT", "/api/limits/droid/weekly", payload: try body(1_000), token: false)
        XCTAssertEqual(unguarded.status, 403)

        let set = try send("PUT", "/api/limits/droid/weekly", payload: try body(1_000))
        XCTAssertEqual(set.status, 200)
        let setObj = try JSONSerialization.jsonObject(with: set.body) as! [String: Any]
        XCTAssertEqual(setObj["source"] as? String, "droid")
        XCTAssertEqual(setObj["window"] as? String, "weekly")
        XCTAssertEqual(setObj["tokens"] as? Int, 1_000)

        // Values that are not a positive whole number are refused, not coerced.
        for bad in [0, -1, 12.5, "1000", true, NSNull()] {
            let response = try send("PUT", "/api/limits/droid/monthly", payload: try body(bad))
            XCTAssertEqual(response.status, 400, "tokens \(bad) must be refused")
        }
        let noTokens = try send("PUT", "/api/limits/droid/monthly", payload: Data("{}".utf8))
        XCTAssertEqual(noTokens.status, 400)

        // Unknown sources and windows, and a path with a missing segment, are usage errors.
        XCTAssertEqual(try send("PUT", "/api/limits/claude/weekly", payload: try body(1)).status, 400)
        XCTAssertEqual(try send("PUT", "/api/limits/droid/yearly", payload: try body(1)).status, 400)
        XCTAssertEqual(try send("PUT", "/api/limits/droid", payload: try body(1)).status, 400)

        let list = try send("GET", "/api/limits")
        XCTAssertEqual(list.status, 200)
        let listObj = try JSONSerialization.jsonObject(with: list.body) as! [String: Any]
        let rows = try XCTUnwrap(listObj["limits"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["window"] as? String, "weekly")

        // The status row the dashboard renders carries the saved limit, and it survives a
        // restart because it is a catalog row, not a preference.
        var status = try service.liveStatus()
        var droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertEqual(droid.weeklyLimit, 1_000)
        XCTAssertNotNil(droid.weeklyPct)
        let reopened = try CatalogDB(path: catalogPath)
        droid = try DroidUsage.row(catalog: reopened, now: now, timeZone: utc)
        XCTAssertEqual(droid.weeklyLimit, 1_000)

        // Clearing returns the window to tokens only; clearing twice is the same state.
        let clear = try send("DELETE", "/api/limits/droid/weekly")
        XCTAssertEqual(clear.status, 200)
        XCTAssertEqual(try send("DELETE", "/api/limits/droid/weekly").status, 200)
        status = try service.liveStatus()
        droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertNil(droid.weeklyLimit)
        XCTAssertNil(droid.weeklyPct)
        let cleared = try JSONSerialization.jsonObject(
            with: try send("GET", "/api/limits").body
        ) as! [String: Any]
        XCTAssertEqual((cleared["limits"] as? [[String: Any]])?.count, 0)
    }

    func testScanPlacesTheCatalogBackedDroidRowAfterTheOpenAIRow() throws {
        let (db, _) = try makeDB()
        try seedWindows(db)
        let droidRow = try DroidUsage.row(catalog: db, now: now, timeZone: utc)
        let status = LiveStatus.scan(
            grokHome: try TempDir.make(),
            claudeHome: try TempDir.make(),
            grokWeekUsd: 0,
            claudePlan: try TempDir.make().appendingPathComponent("missing-plan.json"),
            codexHome: try TempDir.make(),
            droidRow: droidRow
        )
        let sources = status.plans.map(\.source)
        XCTAssertEqual(sources.firstIndex(of: "droid"), sources.firstIndex(of: "openai").map { $0 + 1 })
    }
}
