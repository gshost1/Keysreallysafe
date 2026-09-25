import XCTest
@testable import KeysCore

final class ClaudeUsageTests: XCTestCase {
    let now = UTC.parse("2026-09-09T20:00:00Z")!

    private func writeCache(home: URL, percent: Any = 72, account: String = "account-a", age: TimeInterval = 60, reset: String = "2026-09-13T07:59:59.685033+00:00") throws {
        let obj: [String: Any] = [
            "oauthAccount": ["accountUuid": "account-a"],
            "cachedUsageUtilization": [
                "accountUuid": account,
                "fetchedAtMs": now.addingTimeInterval(-age).timeIntervalSince1970 * 1000,
                "utilization": [
                    "five_hour": ["utilization": 4, "resets_at": "2026-09-10T00:00:00Z"],
                    "seven_day": ["utilization": 40, "resets_at": reset],
                    "limits": [
                        ["kind": "weekly_scoped", "percent": 9, "scope": ["model": ["display_name": "Sonnet"]]],
                        ["kind": "weekly_scoped", "percent": percent, "resets_at": reset, "scope": ["model": ["display_name": "Fable"]]],
                    ],
                ],
            ],
        ]
        try JSONValue.data(obj).write(to: ClaudeUsageCache.configURL(home: home))
    }

    func testRealUsageCacheShapeFeedsAllThreeWindowsAndAPI() throws {
        let home = try TempDir.make()
        try writeCache(home: home)
        let status = LiveStatus.scan(grokHome: home, claudeHome: home, grokWeekUsd: 0, claudePlan: home.appendingPathComponent("missing.json"), codexHome: home, now: now)
        let row = try XCTUnwrap(status.claude)
        XCTAssertEqual(row.fiveHourPct, 4)
        XCTAssertEqual(row.weeklyPct, 40)
        XCTAssertEqual(row.fablePct, 72)
        XCTAssertEqual(row.jsonObject()["fable_pct"] as? Int, 72)
        XCTAssertEqual(row.snapshotAt, "2026-09-09T19:59:00Z")
        XCTAssertNotNil(row.fableResetsAt.flatMap(UTC.parse))
    }

    func testExplicitDefaultDirectoryOverrideUsesItsOwnGlobalConfig() {
        let user = FileManager.default.homeDirectoryForCurrentUser
        let home = user.appendingPathComponent(".claude")
        XCTAssertEqual(ClaudeUsageCache.configURL(home: home, hasConfigOverride: false), user.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeUsageCache.configURL(home: home, hasConfigOverride: true), home.appendingPathComponent(".claude.json"))
    }

    func testExpiredUnscopedHudFableCannotReplaceRejectedAccountCache() throws {
        let home = try TempDir.make()
        try writeCache(home: home, account: "account-b")
        let hud = home.appendingPathComponent("hud.json")
        try JSONValue.data([
            "updated_at": "2026-09-01T00:00:00Z",
            "five_hour": ["used_percentage": 4],
            "model_scoped": [["display_name": "Fable", "utilization": 72, "resets_at": "2026-09-08T00:00:00Z"]],
        ]).write(to: hud)
        let status = LiveStatus.scan(grokHome: home, claudeHome: home, grokWeekUsd: 0, claudePlan: hud, codexHome: home, now: now)
        XCTAssertNil(status.claude?.fablePct)
        XCTAssertEqual(status.claude?.fiveHourPct, 4)
    }

    func testRejectsDifferentAccountStaleAndFutureCaches() throws {
        let home = try TempDir.make()
        try writeCache(home: home, account: "account-b")
        XCTAssertNil(ClaudeUsageCache.read(home: home, now: now))
        try writeCache(home: home, age: ClaudeUsageCache.maxAge + 1)
        XCTAssertNil(ClaudeUsageCache.read(home: home, now: now))
        try writeCache(home: home, age: -60)
        XCTAssertNil(ClaudeUsageCache.read(home: home, now: now))
    }

    func testRejectsInvalidFablePercentAndExpiredResetWithoutLosingSession() throws {
        let home = try TempDir.make()
        for value: Any in [true, "72", -1, 101, NSNull()] {
            try writeCache(home: home, percent: value)
            let row = try XCTUnwrap(ClaudeUsageCache.read(home: home, now: now))
            XCTAssertNil(row.fablePct)
            XCTAssertEqual(row.fiveHourPct, 4)
        }
        try writeCache(home: home, reset: "2026-09-09T19:59:00Z")
        XCTAssertNil(ClaudeUsageCache.read(home: home, now: now)?.fablePct)
        try writeCache(home: home, percent: 0)
        XCTAssertEqual(ClaudeUsageCache.read(home: home, now: now)?.fablePct, 0)
    }

    func testNewerHudGenericWindowsDoNotEraseFableOrMisdateIt() throws {
        let home = try TempDir.make()
        try writeCache(home: home)
        let cache = try XCTUnwrap(ClaudeUsageCache.read(home: home, now: now))
        let hud = ToolStatus(source: "claude", title: "Claude", fiveHourPct: 8, weeklyPct: 41, snapshotAt: UTC.iso(now))
        let row = ClaudeUsageCache.merge(cache, into: hud)
        XCTAssertEqual(row.fiveHourPct, 8)
        XCTAssertEqual(row.weeklyPct, 41)
        XCTAssertEqual(row.fablePct, 72)
        XCTAssertEqual(row.snapshotAt, cache.snapshotAt)
        var newerFable = hud
        newerFable.fablePct = 73
        XCTAssertEqual(ClaudeUsageCache.merge(cache, into: newerFable).fablePct, 73)
    }
}
