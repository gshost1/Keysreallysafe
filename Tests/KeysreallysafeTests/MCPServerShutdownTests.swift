import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-LIFECYCLE-008..009, the seam half: stdin EOF is the end of the run with
/// every response written and nothing after it, and no message-level failure can end
/// the loop early. The process half — exit codes, timing, SIGINT/SIGTERM — is
/// `scripts/tests/test_keys_mcp_stdio.py`, which spawns the built binary.
final class MCPServerShutdownTests: XCTestCase {

    /// LIFECYCLE-008 (seam): all responses are written before EOF, an empty input
    /// writes zero bytes, and the loop returns instead of hanging.
    func testShutdownDiscipline() throws {
        // N requests, then the input ends: every response is written, nothing more.
        var lines = [MCPSession.initialize(id: "open")]
        for index in 0..<5 {
            lines.append(#"{"jsonrpc":"2.0","id":"e\#(index)","method":"ping"}"#)
        }
        let (frames, stderr) = try MCPSession.run(lines)
        XCTAssertEqual(frames.last, "", "the stream ends on the terminator")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 6, "all responses are written before EOF")
        try MCPSession.assertResult(responses[5], id: "e4")
        XCTAssertTrue(stderr.isEmpty, "a clean shutdown writes no diagnostics")

        // Immediate EOF on an empty pipe: zero stdout bytes.
        let (empty, emptyStderr) = try MCPSession.run([])
        XCTAssertEqual(empty, [])
        XCTAssertTrue(emptyStderr.isEmpty)
    }

    /// LIFECYCLE-009 (seam): a session exercising every failure path ends only at EOF
    /// — no self-termination, no uncaught AppError, no crash — and the app-not-running
    /// condition is a tool result carrying the exact sentence.
    func testErrorPathsNeverExit() throws {
        let notRunning = "Keysrs isn't running. Open Keysrs from Applications, then try again."
        let registry = MCPToolRegistry(groups: [
            TestToolGroup(name: "needs_app") { _, _ in throw AppError.siteUnavailable(notRunning) },
        ])
        let (frames, stderr) = try MCPSession.run([
            #"not json at all"#,
            #"[]"#,
            #"{"jsonrpc":"2.0","id":1,"method":"server/discover"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/anything"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"definitely_not_a_tool"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"needs_app"}}"#,
            MCPSession.initialize(id: "late"),
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"definitely_not_a_tool"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"needs_app"}}"#,
        ], registry: registry)
        // run() returning is the seam's "still only ends at EOF": no message above
        // exited the loop early, and the uncaught-AppError path never fired.
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 8, "every failure answered, once, and the loop reached EOF")
        try MCPSession.assertError(responses[0], code: -32700, id: NSNull())
        try MCPSession.assertError(responses[1], code: -32600, id: NSNull())
        try MCPSession.assertError(responses[2], code: -32600, id: 1, "pre-initialize requests are refused")
        try MCPSession.assertError(responses[3], code: -32600, id: 2,
                                   "an unknown tool is still a pre-initialize request first")
        try MCPSession.assertError(responses[4], code: -32600, id: 3, "app tools before initialize too")
        try MCPSession.assertResult(responses[5], id: "late")
        try MCPSession.assertError(responses[6], code: -32602, id: 4)
        // The not-running condition is a tool result with the exact sentence, and the
        // scrubbing formatter leaves that sentence byte-identical.
        let appResult = try MCPSession.assertResult(responses[7], id: 5)
        XCTAssertEqual(appResult["isError"] as? Bool, true)
        let text = ((appResult["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, notRunning)
        XCTAssertTrue(stderr.isEmpty)
    }
}
