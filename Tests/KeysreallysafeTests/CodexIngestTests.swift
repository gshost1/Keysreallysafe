import XCTest
@testable import KeysCore

final class CodexIngestTests: XCTestCase {
    func testTokenCountLastUsageTwoRowsSkipsContentAndCumulative() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Fixtures.codexHome.appendingPathComponent("sessions/2026/09/03"),
            includingPropertiesForKeys: nil
        )
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("rollout-") })
        let events = try CodexIngest.parseFile(file)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.source)), ["codex-local"])
        XCTAssertEqual(Set(events.map(\.provider)), ["openai"])
        XCTAssertEqual(Set(events.map(\.model)), ["gpt-5.4"])
        XCTAssertEqual(events.map(\.inputTokens).reduce(0, +), 180)
        XCTAssertEqual(events.map(\.outputTokens).reduce(0, +), 60)
        XCTAssertEqual(events.map(\.cachedReadTokens).reduce(0, +), 30)
        XCTAssertFalse(events.contains { $0.inputTokens == 9999 })
        let names = fieldNames(events[0])
        XCTAssertFalse(names.contains("content"))
        XCTAssertFalse(names.contains("rawInput"))
    }

    func testDoesNotIngestResponseItemText() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Fixtures.codexHome.appendingPathComponent("sessions/2026/09/03"),
            includingPropertiesForKeys: nil
        )
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("rollout-") })
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("SECRET_SHOULD_NOT_BE_INGESTED"))
        let events = try CodexIngest.parseFile(file)
        let blob = try JSONValue.data(events.map { $0.sessionId + $0.promptId + $0.model })
        XCTAssertFalse(String(data: blob, encoding: .utf8)!.contains("SECRET"))
    }

    func testSecondIngestInsertsZero() throws {
        let (db, _) = try makeDB()
        let first = try CodexIngest.run(home: Fixtures.codexHome, db: db)
        XCTAssertEqual(first.filesScanned, 1)
        XCTAssertEqual(first.rowsInserted, 2)
        let second = try CodexIngest.run(home: Fixtures.codexHome, db: db)
        XCTAssertEqual(second.rowsInserted, 0)
        XCTAssertEqual(second.skippedDupes, 0)
    }

    func testStartupDeletesUnknownCodexRows() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        var db: CatalogDB? = try CatalogDB(path: path)
        _ = try db!.insertUsage(
            UsageEvent(
                source: "codex-local",
                sessionId: "s",
                promptId: "p-unk",
                model: "unknown",
                occurredAt: "2026-01-15T12:00:00Z",
                provider: "openai",
                cwd: nil,
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: nil,
                inputTokens: 11,
                outputTokens: 7,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: nil
            )
        )
        XCTAssertEqual(try db!.allUsageEvents().map(\.model), ["unknown"])
        db = nil
        let reopened = try CatalogDB(path: path)
        XCTAssertEqual(try reopened.allUsageEvents().count, 0)
        XCTAssertGreaterThan(try reopened.catalogVersion(), 0)
    }

    func testQuotaFixtureTokenCountWithoutModelUsesSessionMeta() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Fixtures.codexQuotaHome.appendingPathComponent("sessions/2026/09/04"),
            includingPropertiesForKeys: nil
        )
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("rollout-") })
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"last_token_usage\""))
        XCTAssertFalse(
            text.split(separator: "\n").contains { line in
                line.contains("last_token_usage") && line.contains("\"model\"")
            }
        )
        let events = try CodexIngest.parseFile(file)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-5.4")
        XCTAssertFalse(events.contains { $0.model == "unknown" })
        XCTAssertEqual(events[0].inputTokens, 11)
        XCTAssertEqual(events[0].outputTokens, 7)
    }

    func testMissingSessionsSucceedsWithZeroFiles() throws {
        let home = try TempDir.make()
        let report = try CodexIngest.run(home: home, db: try makeDB().0)
        XCTAssertEqual(report.filesScanned, 0)
        XCTAssertEqual(report.rowsInserted, 0)
    }
}
