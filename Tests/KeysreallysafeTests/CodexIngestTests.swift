import XCTest
@testable import KeysCore

final class CodexIngestTests: XCTestCase {
    func testParentAndSubagentRolloutsBothCountAndResumeIndependently() throws {
        let home = try TempDir.make()
        let sessions = home.appendingPathComponent("sessions/2026/09/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let usage = #"{"timestamp":"2026-09-03T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"turn_id":"turn-1","last_token_usage":{"input_tokens":10,"output_tokens":4}}}}"#
        let parent = #"{"type":"session_meta","payload":{"id":"parent","config":{"model":"gpt-5.4"},"source":"cli"}}"#
        let child = #"{"type":"session_meta","payload":{"id":"child","config":{"model":"gpt-5.4"},"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}"#
        try (parent + "\n" + usage + "\n").write(
            to: sessions.appendingPathComponent("rollout-parent.jsonl"), atomically: true, encoding: .utf8
        )
        let childFile = sessions.appendingPathComponent("rollout-child.jsonl")
        try (child + "\n" + usage + "\n").write(to: childFile, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 2)
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 0)
        XCTAssertEqual(Set(try db.allUsageEvents().map(\.sessionId)), ["parent", "child"])

        let handle = try FileHandle(forWritingTo: childFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usage.replacingOccurrences(of: "turn-1", with: "turn-2") + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 1)
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 0)
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .openai,
            now: UTC.parse("2026-09-03T18:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.openaiTokens, 42)
        XCTAssertNotNil(report.totals.openaiUsdEstimate)
    }

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

    func testDistinctCallsWithIdenticalPerCallCountsCountAndCollapseRepeats() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("sessions/2026/09/03", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(
            "rollout-2026-09-03T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        func tokenCount(ts: String, totalIn: Int, totalOut: Int) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":\#(totalIn),"output_tokens":\#(totalOut),"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
        }
        let lines = [
            #"{"timestamp":"2026-09-03T12:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/x","config":{"model":"gpt-5.4"}}}"#,
            tokenCount(ts: "2026-09-03T12:00:01.000Z", totalIn: 10, totalOut: 4),
            tokenCount(ts: "2026-09-03T12:00:02.000Z", totalIn: 20, totalOut: 8),
            tokenCount(ts: "2026-09-03T12:00:03.000Z", totalIn: 30, totalOut: 12),
            // A verbatim repeat of the third line's info at a later timestamp: the cumulative
            // totals have not advanced, so it is a repeat emission, not a new call.
            tokenCount(ts: "2026-09-03T12:00:04.000Z", totalIn: 30, totalOut: 12),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let events = try CodexIngest.parseFile(file)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.promptId), ["turn-1", "turn-2", "turn-3"])
        XCTAssertEqual(events.map(\.inputTokens), [10, 10, 10])
        XCTAssertEqual(events.map(\.outputTokens), [4, 4, 4])

        let (db, _) = try makeDB()
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 3)
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 0)
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .openai,
            now: UTC.parse("2026-09-03T18:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.openaiTokens, 42)
    }

    func testWithoutTotalsRepeatsCollapseWhateverTheirTimestamp() throws {
        func parse(_ secondTimestamp: String) throws -> [UsageEvent] {
            let home = try TempDir.make()
            let dir = home.appendingPathComponent("sessions/2026/09/05", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(
                "rollout-2026-09-05T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
            )
            func tokenCount(_ ts: String) -> String {
                #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
            }
            let lines = [
                #"{"timestamp":"2026-09-05T12:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/x","config":{"model":"gpt-5.4"}}}"#,
                tokenCount("2026-09-05T12:00:01.000Z"),
                tokenCount(secondTimestamp),
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return try CodexIngest.parseFile(file)
        }
        // A repeat emission is logged after the call, so its timestamp differs; without
        // totals it must still collapse rather than double the call.
        XCTAssertEqual(try parse("2026-09-05T12:00:02.000Z").count, 1)
        XCTAssertEqual(try parse("2026-09-05T12:00:01.000Z").count, 1)
    }

    func testStateFromBeforeTotalsDropsTheReemittedCallOnce() throws {
        let legacy = #"{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","model":"gpt-5.4","lastUsageFingerprint":"gpt-5.4|10|4|0|0","lastTurnId":"turn-2","turnIndex":2}"#
        var parser = try JSONDecoder().decode(CodexIngest.LineParser.self, from: Data(legacy.utf8))
        func tokenCount(ts: String, totalIn: Int, totalOut: Int) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":\#(totalIn),"output_tokens":\#(totalOut),"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
        }
        // Re-emission of the call the old build already ingested as turn-2.
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:05.000Z", totalIn: 20, totalOut: 8)))
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:06.000Z", totalIn: 20, totalOut: 8)))
        // A genuinely new call with the same per-call counts advances the totals.
        let next = parser.consume(tokenCount(ts: "2026-09-05T12:00:07.000Z", totalIn: 30, totalOut: 12))
        XCTAssertEqual(next?.promptId, "turn-3")
        XCTAssertEqual(next?.inputTokens, 10)
    }

    func testLegacyParserJSONDecodes() throws {
        let json = #"{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","lastUsageFingerprint":"gpt-5.4|10|4|0|0","lastTurnId":"turn-1","turnIndex":2}"#
        let parser = try JSONDecoder().decode(CodexIngest.LineParser.self, from: Data(json.utf8))
        XCTAssertEqual(parser.turnIndex, 2)
        XCTAssertEqual(parser.lastTurnId, "turn-1")
        XCTAssertNil(parser.lastTotalsFingerprint)
    }

    func testMissingSessionsSucceedsWithZeroFiles() throws {
        let home = try TempDir.make()
        let report = try CodexIngest.run(home: home, db: try makeDB().0)
        XCTAssertEqual(report.filesScanned, 0)
        XCTAssertEqual(report.rowsInserted, 0)
    }
}
