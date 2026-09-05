import XCTest
@testable import KeysCore

final class PriceTableTests: XCTestCase {
    override func setUp() {
        ModelPrices.testFixtureURL = nil
        ModelPrices.resetCache()
    }

    override func tearDown() {
        ModelPrices.testFixtureURL = nil
        ModelPrices.resetCache()
    }

    func testFixturePricesAModelAndHandRowWinsOnExactId() throws {
        let dir = try TempDir.make()
        let url = dir.appendingPathComponent("models.json")
        let fixture: [String: Any] = [
            "fetched_at": "2026-09-04T00:00:00Z",
            "models": [
                [
                    "id": "test/priced-only",
                    "name": "Priced Only",
                    "provider": "test",
                    "input_per_mtok": 4,
                    "output_per_mtok": 8,
                    "cache_read_per_mtok": 0.5,
                ],
                [
                    "id": "anthropic/claude-sonnet-5",
                    "name": "Claude Sonnet 5",
                    "provider": "anthropic",
                    "input_per_mtok": 999,
                    "output_per_mtok": 999,
                    "cache_read_per_mtok": 999,
                ],
            ],
        ]
        try JSONValue.data(fixture).write(to: url)
        ModelPrices.testFixtureURL = url
        ModelPrices.resetCache()

        let only = try XCTUnwrap(ModelPrices.lookup("priced-only"))
        XCTAssertEqual(only.inputPerMTok, 4, accuracy: 1e-12)
        XCTAssertEqual(only.outputPerMTok, 8, accuracy: 1e-12)
        XCTAssertEqual(only.cacheReadPerMTok, 0.5, accuracy: 1e-12)
        XCTAssertEqual(only.source, .fixture)
        XCTAssertNotNil(ModelPrices.lookup("test/priced-only"))
        XCTAssertNotNil(ModelPrices.lookup("Priced Only"))

        let hand = try XCTUnwrap(ModelPrices.lookup("claude-sonnet-5"))
        XCTAssertEqual(hand.inputPerMTok, 2, accuracy: 1e-12)
        XCTAssertEqual(hand.outputPerMTok, 10, accuracy: 1e-12)
        XCTAssertEqual(hand.source, .hand)

        let (db, _) = try makeDB()
        _ = try db.insertUsage(
            UsageEvent(
                source: "claude-local",
                sessionId: "price",
                promptId: "only",
                model: "priced-only",
                occurredAt: "2026-01-15T12:00:00Z",
                provider: "anthropic",
                cwd: nil,
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: nil,
                inputTokens: 1_000_000,
                outputTokens: 0,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: nil
            )
        )
        let report = try SpendQueries(db: db).report(
            range: .month,
            by: .model,
            source: .claude,
            now: UTC.parse("2026-01-20T00:00:00Z")!,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.claudeUsdEstimate ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(report.rows.first?.usdEstimate ?? 0, 4, accuracy: 1e-9)
        XCTAssertTrue(report.totals.claudeUnpricedModels.isEmpty)
    }

    func testMissingFixtureFallsBackToHandRows() throws {
        ModelPrices.testFixtureURL = URL(fileURLWithPath: "/no/such/models.json")
        ModelPrices.resetCache()
        let price = try XCTUnwrap(ModelPrices.lookup("claude-opus-5"))
        XCTAssertEqual(price.inputPerMTok, 5, accuracy: 1e-12)
        XCTAssertEqual(price.source, .hand)
        XCTAssertEqual(ClaudeEstimate.price(for: "claude-opus-5")?.inputPerMTok, 5)
    }
}
