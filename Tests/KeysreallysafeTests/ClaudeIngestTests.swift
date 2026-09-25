import XCTest
@testable import KeysCore

final class ClaudeIngestTests: XCTestCase {
    func testSubagentBackfillAppendAndCopiedContextCountOnceInSpend() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let parent = project.appendingPathComponent("parent.jsonl")
        let parentLine = usageLine(request: "parent-request", input: 10, output: 4)
        try (parentLine + "\n").write(to: parent, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 1)

        let subagents = project.appendingPathComponent("parent/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let worker = subagents.appendingPathComponent("agent-worker.jsonl")
        let workerLine = usageLine(request: "worker-request", input: 20, output: 8)
        // A copied parent message is context, not another model call.
        try (parentLine + "\n" + workerLine + "\n")
            .write(to: worker, atomically: true, encoding: .utf8)
        let backfill = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(backfill.filesScanned, 2)
        XCTAssertEqual(backfill.rowsInserted, 1)
        XCTAssertEqual(backfill.parseErrors, 0)
        XCTAssertEqual(try db.allUsageEvents().count, 2)
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 0)

        let handle = try FileHandle(forWritingTo: worker)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usageLine(request: "worker-next", input: 30, output: 12) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 1)
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 0)

        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .claude,
            now: UTC.parse("2026-01-20T00:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.claudeTokens, 84)
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertEqual(report.rows[0].inputTokens, 60)
        XCTAssertEqual(report.rows[0].outputTokens, 24)
        let expected = try XCTUnwrap(ClaudeEstimate.usd(
            model: "claude-sonnet-5", input: 60, output: 24, cacheCreate: 0, cacheRead: 0
        ))
        XCTAssertEqual(try XCTUnwrap(report.totals.claudeUsdEstimate), expected, accuracy: 1e-12)
    }

    private func usageLine(request: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"sessionId\":\"parent\",\"requestId\":\"\(request)\",\"cwd\":\"/tmp/subagent-project\",\"timestamp\":\"2026-01-15T12:00:00Z\",\"message\":{\"id\":\"msg-\(request)\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}"
    }

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
            inputTokens: 1,
            outputTokens: 1
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

    func testMissingProjectsSucceedsWithZeroFiles() throws {
        let (db, dir) = try makeDB()
        let home = dir.appendingPathComponent("empty-claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let report = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(report.filesScanned, 0)
        XCTAssertEqual(report.rowsInserted, 0)
    }
}
