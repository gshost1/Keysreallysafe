import XCTest
@testable import KeysCore

final class GrokIngestTests: XCTestCase {
    func testTurnCompletedPerModelBucketsAndTicks() throws {
        let line = try String(contentsOf: Fixtures.turnCompleted, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .joined()
        let events = try GrokIngest.parseLine(line, sessionDirName: "sess-1", summary: nil)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.model, "grok-4.6-build")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cachedReadTokens, 10)
        XCTAssertEqual(event.cacheCreationTokens, 5)
        XCTAssertEqual(event.reasoningTokens, 20)
        XCTAssertEqual(event.modelCalls, 2)
        XCTAssertEqual(event.costUsdTicks, 81_000_000_000)
        XCTAssertEqual(event.source, "grok-local")
        XCTAssertEqual(event.promptId, "prompt-1")
        XCTAssertEqual(Ticks.usd(event.costUsdTicks!), 8.1, accuracy: 1e-12)
    }

    func testTwoModelsTwoRowsNoDoubleCountOfTopLevel() throws {
        let line = try String(contentsOf: Fixtures.twoModels, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .joined()
        let events = try GrokIngest.parseLine(line, sessionDirName: "sess-2", summary: nil)
        XCTAssertEqual(events.count, 2)
        let models = Set(events.map(\.model))
        XCTAssertEqual(models, ["grok-4.6-build", "grok-4-fast"])
        let inputSum = events.map(\.inputTokens).reduce(0, +)
        let tickSum = events.compactMap(\.costUsdTicks).reduce(0, +)
        XCTAssertEqual(inputSum, 100)
        XCTAssertEqual(tickSum, 81_000_000_000)
        XCTAssertFalse(events.contains(where: { $0.inputTokens == 100 && $0.model != "grok-4.6-build" && $0.model != "grok-4-fast" }))
        XCTAssertFalse(events.contains(where: { $0.costUsdTicks == 81_000_000_000 }))
    }

    func testIngestStructHasNoContentOrRawInput() throws {
        let event = UsageEvent(
            source: "grok-local",
            sessionId: "s",
            promptId: "p",
            model: "grok-4.6-build",
            occurredAt: "2026-01-15T12:00:00Z",
            provider: "xai",
            cwd: nil,
            sessionTitle: nil,
            agentName: nil,
            stopReason: "end_turn",
            modelCalls: 1,
            apiDurationMs: 1,
            inputTokens: 1,
            outputTokens: 1,
            cachedReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            costUsdTicks: 1
        )
        let names = fieldNames(event)
        XCTAssertFalse(names.contains("content"))
        XCTAssertFalse(names.contains("rawInput"))
        XCTAssertFalse(names.contains("secret"))
    }

    func testSkipsNonTurnCompletedLines() throws {
        let line = #"{"timestamp":1,"params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":"DO-NOT-INGEST-MESSAGE-TEXT"}}}"#
        let events = try GrokIngest.parseLine(line, sessionDirName: "s", summary: nil)
        XCTAssertTrue(events.isEmpty)
    }

    func testSecondIngestInsertsZero() throws {
        let (db, _) = try makeDB()
        let first = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        XCTAssertGreaterThan(first.rowsInserted, 0)
        let second = try GrokIngest.run(home: Fixtures.grokHome, db: db)
        XCTAssertEqual(second.rowsInserted, 0)
        XCTAssertEqual(second.skippedDupes, 0)
        let all = try db.allUsageEvents()
        XCTAssertEqual(all.count, first.rowsInserted)
        let blob = all.map { "\($0.sessionTitle ?? "") \($0.cwd ?? "") \($0.promptId)" }.joined()
        XCTAssertFalse(blob.contains(sentinelMessage))
        XCTAssertFalse(blob.contains(sentinelRaw))
    }

    func testMissingPromptIdIsStableAcrossRescan() throws {
        let line = #"{"timestamp":1768478400,"params":{"sessionId":"sess-x","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":3,"outputTokens":4,"modelUsage":{"m":{"inputTokens":3,"outputTokens":4,"costUsdTicks":10}}}}}}"#
        let a = try GrokIngest.parseLine(line, sessionDirName: "sess-x", summary: nil)
        let b = try GrokIngest.parseLine(line, sessionDirName: "sess-x", summary: nil)
        XCTAssertEqual(a.first?.promptId, b.first?.promptId)
        XCTAssertEqual(a.first?.promptId.count, 64)
    }

    func testCancelledTurnStillCounts() throws {
        let line = try String(contentsOf: Fixtures.twoModels, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .joined()
        let events = try GrokIngest.parseLine(line, sessionDirName: "sess-2", summary: nil)
        XCTAssertEqual(events.first?.stopReason, "cancelled")
        XCTAssertFalse(events.isEmpty)
    }
}
