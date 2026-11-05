import Foundation
import XCTest
@testable import KeysCore

/// Codex rollouts carry no turn id, so the parser dedupes on the per-call counts plus the
/// session-cumulative totals. The "state from before totals were stored" bridge dropped
/// any line whose per-call counts matched the last ingested call — which was right for a
/// re-emission and wrong for a later call that happened to spend the same tokens, so
/// those calls never reached the catalog. The totals decide: they cover more calls than
/// were ingested, or they do not.
final class CodexBridgeTests: XCTestCase {

    private func tokenCount(ts: String, totalIn: Int, totalOut: Int) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":\#(totalIn),"output_tokens":\#(totalOut),"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
    }

    /// The same event with no `total_token_usage`, the shape older builds wrote.
    private func totalless(ts: String, input: Int = 10, output: Int = 4) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
    }

    /// The upgrade bridge, unchanged: two calls ingested without totals, then the second
    /// one re-emitted with totals, then a real third call. The re-emission is dropped once
    /// and the third call is counted.
    func testTheUpgradeBridgeStillDropsTheReemittedCallOnce() throws {
        let legacy = #"{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","model":"gpt-5.4","lastUsageFingerprint":"gpt-5.4|10|4|0|0","lastTurnId":"turn-2","turnIndex":2}"#
        var parser = try JSONDecoder().decode(CodexIngest.LineParser.self, from: Data(legacy.utf8))

        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:05.000Z", totalIn: 20, totalOut: 8)))
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:06.000Z", totalIn: 20, totalOut: 8)))
        let next = parser.consume(tokenCount(ts: "2026-09-05T12:00:07.000Z", totalIn: 30, totalOut: 12))
        XCTAssertEqual(next?.promptId, "turn-3")
    }

    /// The same upgrade state, where the calls before it did not all spend what the line
    /// being read spent. Comparing the totals against `turnIndex x` this call's counts saw
    /// 32 as more than 3 x 10, so the re-emission was stored a second time.
    func testAReemissionAfterUnevenEarlierCallsIsNotStoredTwice() throws {
        let legacy = #"{"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","model":"gpt-5.4","lastUsageFingerprint":"gpt-5.4|10|4|0|0","lastTurnId":"turn-3","turnIndex":3}"#
        var parser = try JSONDecoder().decode(CodexIngest.LineParser.self, from: Data(legacy.utf8))

        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:05.000Z", totalIn: 32, totalOut: 16)),
                     "the bridge drops the first line it sees")
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:06.000Z", totalIn: 32, totalOut: 16)),
                     "totals that did not advance cover no new call")
        XCTAssertEqual(parser.turnIndex, 3, "no call was counted")
        let next = parser.consume(tokenCount(ts: "2026-09-05T12:00:07.000Z", totalIn: 42, totalOut: 20))
        XCTAssertEqual(next?.promptId, "turn-4")
    }

    /// A brand-new session whose last call spent more than the ones before it: A and B are
    /// totalless, then B is logged again with totals covering both. Comparing against
    /// 2 x B's own spend (40/16) called that re-emission a new call and stored it twice.
    func testATotalsLineCoveringTheStoredCallsIsNotCountedAgain() throws {
        var parser = CodexIngest.LineParser(sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        parser.model = "gpt-5.4"

        XCTAssertEqual(parser.consume(totalless(ts: "2026-09-05T12:00:01.000Z", input: 10, output: 4))?.promptId,
                       "turn-1", "a line with no totals at all is counted")
        XCTAssertEqual(parser.consume(totalless(ts: "2026-09-05T12:00:02.000Z", input: 20, output: 8))?.promptId,
                       "turn-2", "different counts, so this is a second call")
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:03.000Z", totalIn: 30, totalOut: 12)),
                     "30/12 is exactly what the two stored calls spent, so this is B logged again")
        XCTAssertEqual(parser.consume(tokenCount(ts: "2026-09-05T12:00:04.000Z", totalIn: 40, totalOut: 16))?.promptId,
                       "turn-3", "an advancing reading is a third call")
    }

    /// Totalless calls that spent different amounts, then a re-emission carrying totals for
    /// both: the totals do not exceed the stored sum, so nothing is stored twice.
    func testUnevenTotallessCallsAreNotDoubleCountedByAReemission() throws {
        var parser = CodexIngest.LineParser(sessionId: "s")
        parser.model = "gpt-5.4"
        XCTAssertNotNil(parser.consume(totalless(ts: "2026-09-05T12:00:01.000Z", input: 10, output: 4)))
        XCTAssertNotNil(parser.consume(totalless(ts: "2026-09-05T12:00:02.000Z", input: 7, output: 3)))
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:03.000Z", totalIn: 17, totalOut: 7)),
                     "17/7 is exactly what the two stored calls spent")
        XCTAssertEqual(parser.consume(tokenCount(ts: "2026-09-05T12:00:04.000Z", totalIn: 27, totalOut: 11))?.promptId,
                       "turn-3")
    }

    /// The bug: inside one file, a line with no totals is ingested, then a genuinely new
    /// call arrives whose counts match and which carries totals covering two calls. The
    /// bridge dropped it, so the session under-counted by one call for good.
    func testALaterCallAfterATotallessLineIsCountedNotDropped() throws {
        var parser = CodexIngest.LineParser(sessionId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        parser.model = "gpt-5.4"

        let first = parser.consume(#"{"timestamp":"2026-09-05T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#)
        XCTAssertEqual(first?.promptId, "turn-1", "no totals at all: the line is counted")

        let second = parser.consume(tokenCount(ts: "2026-09-05T12:00:02.000Z", totalIn: 20, totalOut: 8))
        XCTAssertEqual(second?.promptId, "turn-2",
                       "the totals cover two calls and only one was ingested, so this is a new call")
        XCTAssertEqual(second?.inputTokens, 10)

        // And the totals now vouch for the following re-emission being a repeat.
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:03.000Z", totalIn: 20, totalOut: 8)))
        XCTAssertEqual(parser.consume(tokenCount(ts: "2026-09-05T12:00:04.000Z", totalIn: 30, totalOut: 12))?.promptId,
                       "turn-3")
    }

    /// A re-emission right after a totalless line whose totals cover exactly the one call
    /// already ingested is still a repeat, and is still dropped.
    func testATotallessLineFollowedByItsOwnReemissionStillDrops() throws {
        var parser = CodexIngest.LineParser(sessionId: "s")
        parser.model = "gpt-5.4"
        XCTAssertNotNil(parser.consume(#"{"timestamp":"2026-09-05T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#))
        XCTAssertNil(parser.consume(tokenCount(ts: "2026-09-05T12:00:02.000Z", totalIn: 10, totalOut: 4)),
                     "totals cover one call and one was ingested: the same call logged again")
    }

    /// The whole file through the real ingest path: three calls, one totalless, and the
    /// catalog holds all three.
    func testTheIngestPathStoresEveryCall() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("sessions/2026/09/06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-09-06T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-06T12:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/x","config":{"model":"gpt-5.4"}}}"#,
            #"{"timestamp":"2026-09-06T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#,
            tokenCount(ts: "2026-09-06T12:00:02.000Z", totalIn: 20, totalOut: 8),
            tokenCount(ts: "2026-09-06T12:00:03.000Z", totalIn: 30, totalOut: 12),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let (db, _) = try makeDB()
        let report = try CodexIngest.run(home: home, db: db)
        XCTAssertEqual(report.rowsInserted, 3, "three calls, three rows")
        XCTAssertEqual(try db.allUsageEvents().map(\.promptId).sorted(), ["turn-1", "turn-2", "turn-3"])

        // Re-reading the file from zero (a replay) must not add or double-count.
        let again = try CodexIngest.run(home: home, db: try CatalogDB(path: db.path))
        XCTAssertEqual(again.rowsInserted, 0, "the cursor is at EOF, so nothing is re-read")
        XCTAssertEqual(try db.allUsageEvents().count, 3)
    }
}
