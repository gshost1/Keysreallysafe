import XCTest
@testable import KeysCore

final class ClaudeIngestTests: XCTestCase {
    func testAssistantLineOneClaudeLocalRow() throws {
        let file = Fixtures.claudeHome.appendingPathComponent("projects/synth/session.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        var events: [UsageEvent] = []
        for line in text.split(separator: "\n") {
            if let event = try ClaudeIngest.parseLine(String(line)) {
                events.append(event)
            }
        }
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.source, "claude-local")
        XCTAssertEqual(event.provider, "anthropic")
        XCTAssertEqual(event.model, "claude-sonnet-5")
        XCTAssertEqual(event.promptId, "u-asst-1")
        XCTAssertEqual(event.inputTokens, 200)
        XCTAssertEqual(event.outputTokens, 80)
        XCTAssertEqual(event.cachedReadTokens, 40)
        XCTAssertNil(event.costUsdTicks)
        XCTAssertEqual(event.cwd, "/tmp/keysreallysafe-fixture")
    }

    func testContentAbsentFromIngestStruct() {
        let event = UsageEvent(
            source: "claude-local",
            sessionId: "s",
            promptId: "p",
            model: "claude-sonnet-5",
            occurredAt: "2026-01-15T12:00:01Z",
            provider: "anthropic",
            cwd: nil,
            sessionTitle: nil,
            agentName: nil,
            stopReason: nil,
            modelCalls: nil,
            apiDurationMs: nil,
            inputTokens: 1,
            outputTokens: 1,
            cachedReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            costUsdTicks: nil
        )
        let names = fieldNames(event)
        XCTAssertFalse(names.contains("content"))
        XCTAssertFalse(names.contains("rawInput"))
    }

    func testCostUsdTicksNullAndSentinelNotStored() throws {
        let (db, _) = try makeDB()
        let report = try ClaudeIngest.run(home: Fixtures.claudeHome, db: db)
        XCTAssertEqual(report.rowsInserted, 1)
        let events = try db.allUsageEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].costUsdTicks)
        let blob = String(describing: events)
        XCTAssertFalse(blob.contains(sentinelClaude))
    }

    func testSkipsSyntheticAndZeroUsageFixtureLines() throws {
        let file = Fixtures.claudeHome.appendingPathComponent("projects/synth/session.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"<synthetic>\""))
        var events: [UsageEvent] = []
        for line in text.split(separator: "\n") {
            if let event = try ClaudeIngest.parseLine(String(line)) {
                events.append(event)
            }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "claude-sonnet-5")
        XCTAssertFalse(events.contains { $0.model == "<synthetic>" })
        XCTAssertFalse(events.contains { $0.inputTokens == 0 && $0.outputTokens == 0 })
    }

    func testStartupDeletesSyntheticRows() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        var db: CatalogDB? = try CatalogDB(path: path)
        _ = try db!.insertUsage(
            UsageEvent(
                source: "claude-local",
                sessionId: "s",
                promptId: "p-syn",
                model: "<synthetic>",
                occurredAt: "2026-01-15T12:00:00Z",
                provider: "anthropic",
                cwd: nil,
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: nil,
                apiDurationMs: nil,
                inputTokens: 0,
                outputTokens: 0,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: nil
            )
        )
        XCTAssertEqual(try db!.allUsageEvents().count, 1)
        db = nil
        let reopened = try CatalogDB(path: path)
        XCTAssertEqual(try reopened.allUsageEvents().count, 0)
        XCTAssertGreaterThan(try reopened.catalogVersion(), 0)
    }

    func testMissingProjectsSucceedsWithZeroFiles() throws {
        let (db, dir) = try makeDB()
        let home = dir.appendingPathComponent("empty-claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let report = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(report.filesScanned, 0)
        XCTAssertEqual(report.rowsInserted, 0)
    }
}
