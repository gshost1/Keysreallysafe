import XCTest
@testable import KeysCore

final class PriceTableTests: XCTestCase {
    override func setUp() {
        ModelPrices.cache.testURL = nil
    }

    override func tearDown() {
        ModelPrices.cache.testURL = nil
    }

    func testFixturePricesAModelAndHandRowWinsOnExactId() throws {
        let dir = try TempDir.make()
        let url = dir.appendingPathComponent("models.json")
        let fixture: [String: Any] = [
            "fetched_at": "2026-09-04T00:00:00Z",
            "models": [
                [
                    "id": "test/priced-only",
                    "input_per_mtok": 4,
                    "output_per_mtok": 8,
                    "cache_read_per_mtok": 0.5,
                ],
                [
                    "id": "anthropic/claude-sonnet-5",
                    "input_per_mtok": 999,
                    "output_per_mtok": 999,
                    "cache_read_per_mtok": 999,
                ],
            ],
        ]
        try JSONValue.data(fixture).write(to: url)
        ModelPrices.cache.testURL = url

        let only = try XCTUnwrap(ModelPrices.lookup("priced-only"))
        XCTAssertEqual(only.inputPerMTok, 4, accuracy: 1e-12)
        XCTAssertEqual(only.outputPerMTok, 8, accuracy: 1e-12)
        XCTAssertEqual(only.cacheReadPerMTok, 0.5, accuracy: 1e-12)
        XCTAssertNotNil(ModelPrices.lookup("test/priced-only"))

        let hand = try XCTUnwrap(ModelPrices.lookup("claude-sonnet-5"))
        XCTAssertEqual(hand.inputPerMTok, 2, accuracy: 1e-12)
        XCTAssertEqual(hand.outputPerMTok, 10, accuracy: 1e-12)

        let (db, _) = try makeDB()
        _ = try db.insertUsage(.fixture(
            source: "claude-local", session: "price", prompt: "only", model: "priced-only",
            input: 1_000_000, output: 0
        ))
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

    func testPrefixMatchesOnlyAtTheStartOfTheId() {
        // A fine-tune and an unrelated model that merely contain a hand-row id are not priced.
        XCTAssertNil(ModelPrices.lookup("ft:gpt-4o:acme::1"))
        XCTAssertNil(ModelPrices.lookup("solar-pro3"))
        XCTAssertEqual(ModelPrices.lookup("gpt-4o-2024-08-06")?.inputPerMTok, 2.5)
    }

    func testMissingFixtureFallsBackToHandRows() throws {
        ModelPrices.cache.testURL = URL(fileURLWithPath: "/no/such/models.json")
        let price = try XCTUnwrap(ModelPrices.lookup("claude-opus-5"))
        XCTAssertEqual(price.inputPerMTok, 5, accuracy: 1e-12)
    }
}
