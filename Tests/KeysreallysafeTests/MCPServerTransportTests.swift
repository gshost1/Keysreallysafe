import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-TRANSPORT-001..008: what the server puts on stdout, byte for byte, and
/// how the frame reader survives malformed, mis-terminated and hostile input.
final class MCPServerTransportTests: XCTestCase {

    /// TRANSPORT-001: stdout carries only complete compact JSON-RPC frames, one per
    /// line, sorted keys, re-serializing byte-identically; diagnostics never appear.
    func testStdoutFramingHygiene() throws {
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"server/discover"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"ping","meth"#,
            #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#,
        ])
        // One trailing empty chunk: the stream ends on the frame terminator.
        XCTAssertEqual(frames.last, "")
        let messages = frames.dropLast()
        // Initialize, ping, tools/list, tools/call, unknown method, parse error: six.
        XCTAssertEqual(messages.count, 6)
        for frame in messages {
            let object = try MCPSession.object(frame)
            XCTAssertNil(object["method"], "only responses, never requests or notifications")
            XCTAssertNotNil(object["id"])
            // Compact and sorted: the repo's own encoder reproduces the bytes exactly.
            let reencoded = try JSONValue.data(object)
            XCTAssertEqual(Data(frame.utf8), reencoded, "frames must be compact sorted-key JSON")
            XCTAssertFalse(frame.contains("\n") || frame.contains("\r"), "no embedded newlines")
        }
        // A clean session writes no diagnostics at all; stderr is prose-only when present.
        XCTAssertTrue(stderr.isEmpty, "stderr must stay empty in a clean session: \(stderr)")
    }

    /// TRANSPORT-002: every response echoes jsonrpc 2.0 and the exact id, preserving
    /// string-vs-number, and carries exactly one of result or error.
    func testEnvelopeAndIdFidelity() throws {
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(id: "handshake"),
            #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":-1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":42,"method":"logging/setLevel"}"#,
            #"{"jsonrpc":"2.0","id":"last","method":"tools/call","params":{"name":"version"}}"#,
        ])
        XCTAssertTrue(stderr.isEmpty, "stderr must stay empty in a clean session")
        XCTAssertEqual(frames.last, "")
        let responses = try frames.dropLast().map { try MCPSession.object($0) }
        XCTAssertEqual(responses.count, 7)
        for response in responses {
            XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
            let exclusive = (response["result"] != nil ? 1 : 0) + (response["error"] != nil ? 1 : 0)
            XCTAssertEqual(exclusive, 1, "exactly one of result or error, never both, never neither")
        }
        MCPSession.assertID(responses[0], equals: "handshake")
        MCPSession.assertID(responses[1], equals: "abc")
        MCPSession.assertID(responses[2], equals: 7)
        XCTAssertFalse(responses[2]["id"] is String, "the number id must not become a string")
        MCPSession.assertID(responses[3], equals: -1)
        MCPSession.assertID(responses[4], equals: NSNull())
        MCPSession.assertID(responses[5], equals: 42)
        MCPSession.assertID(responses[6], equals: "last")
        // The ping shapes answer {} promptly; the null id is a request, not silence.
        for ping in [responses[1], responses[2], responses[3], responses[4]] {
            XCTAssertEqual((ping["result"] as? [String: Any])?.count, 0)
        }
        let unknown = responses[5]["error"] as? [String: Any]
        XCTAssertEqual(unknown?["code"] as? Int, -32601)
    }

    /// TRANSPORT-003: invalid JSON, invalid UTF-8 and a batch array each yield exactly
    /// one error response, and the loop keeps serving.
    func testMalformedLinesAnsweredAndSurvived() throws {
        var bytes = Data()
        bytes.append(Data((MCPSession.initialize() + "\n").utf8))
        bytes.append(Data([0xFF, 0x0A])) // invalid UTF-8
        bytes.append(Data((#"{"jsonrpc":"2.0","id":1,"meth"# + "\n").utf8))
        bytes.append(Data(("not json at all\n").utf8))
        bytes.append(Data((#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"# + "\n").utf8))
        bytes.append(Data(("[]\n").utf8))
        bytes.append(Data((#"{"jsonrpc":"2.0","id":"after","method":"ping"}"# + "\n").utf8))
        let (frames, _) = try MCPSession.run(bytes: bytes)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 7, "one response per bad line, then the ping")
        try MCPSession.assertResult(responses[0], id: "init")
        // The invalid UTF-8 line, the truncated JSON and the prose line: parse errors.
        for frame in responses[1...3] {
            try MCPSession.assertError(frame, code: -32700, id: NSNull())
        }
        // A JSON array is batching: invalid, with no id and no per-element responses.
        for frame in responses[4...5] {
            try MCPSession.assertError(frame, code: -32600, id: NSNull())
        }
        try MCPSession.assertResult(responses[6], id: "after")
    }

    /// TRANSPORT-004: values that parse but are not valid requests each get exactly one
    /// -32600, with the id echoed when present; an explicit null id is still a request.
    func testInvalidRequestObjects() throws {
        let invalid: [(String, Any?)] = [
            ("5", NSNull()),
            (#""x""#, NSNull()),
            ("true", NSNull()),
            ("null", NSNull()),
            ("{}", NSNull()),
            (#"{"foo":1}"#, NSNull()),
            (#"{"id":1,"method":"ping"}"#, 1),      // jsonrpc missing
            (#"{"jsonrpc":"1.0","id":2,"method":"ping"}"#, 2),
            (#"{"jsonrpc":2.0,"id":3,"method":"ping"}"#, 3), // wrong type, not the string
            (#"{"jsonrpc":"2.0","id":9}"#, 9),       // method missing
        ]
        var lines = invalid.map(\.0)
        lines.append(MCPSession.initialize())
        lines.append(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        let (frames, _) = try MCPSession.run(lines)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, invalid.count + 2)
        for (index, (_, id)) in invalid.enumerated() {
            try MCPSession.assertError(responses[index], code: -32600, id: id)
        }
        try MCPSession.assertResult(responses[invalid.count], id: "init")
        // id: null is a request and is answered with the id echoed as null.
        try MCPSession.assertResult(responses[invalid.count + 1], id: NSNull())
    }

    /// TRANSPORT-005: CRLF is tolerated, blank lines are silent, and the final
    /// unterminated line is still served before the clean end.
    func testTerminatorTolerance() throws {
        var bytes = Data()
        bytes.append(Data((MCPSession.initialize(id: "crlf-init") + "\r\n").utf8))
        bytes.append(Data("\n".utf8))        // empty
        bytes.append(Data("   \n".utf8))     // whitespace only
        bytes.append(Data("\t\n".utf8))
        bytes.append(Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\r\n").utf8))
        bytes.append(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)) // no terminator
        let (frames, _) = try MCPSession.run(bytes: bytes)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 3, "blank lines produce zero bytes; both pings are served")
        try MCPSession.assertResult(responses[0], id: "crlf-init")
        try MCPSession.assertResult(responses[1], id: 1, "the CR before LF must never cause a parse error")
        try MCPSession.assertResult(responses[2], id: 2, "the unterminated final line is still parsed")
    }

    /// TRANSPORT-006: the per-line cap is at least 4 MiB, a 4 MiB request is served,
    /// and an 8 MiB line is refused with the documented plain error, not a crash.
    func testMessageSizeCap() throws {
        XCTAssertGreaterThanOrEqual(MCPServer.maxLineBytes, 4 * 1024 * 1024)
        func paddedLine(total: Int) -> String {
            let prefix = #"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"version","_meta":{"pad":""#
            let suffix = #""}}}"#
            let pad = total - prefix.utf8.count - suffix.utf8.count
            return prefix + String(repeating: "A", count: pad) + suffix
        }
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            paddedLine(total: MCPServer.maxLineBytes), // exactly the cap: served
            paddedLine(total: 8 * 1024 * 1024),        // above it: refused
            #"{"jsonrpc":"2.0","id":"after","method":"ping"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 4)
        try MCPSession.assertResult(responses[1], id: "big", "the 4 MiB valid line is served without error")
        try MCPSession.assertError(responses[2], code: -32600, id: NSNull())
        let error = try MCPSession.object(responses[2])
        let message = (error["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, MCPServer.oversizeLineMessage, "the documented plain error")
        try MCPSession.assertResult(responses[3], id: "after", "the server keeps serving after the refusal")
    }

    /// TRANSPORT-007: pipelined requests come back in FIFO order with no drops or
    /// duplicates, and a mixed volume yields exactly one response per request-bearing
    /// line and none for notifications.
    func testPipelinedOrderAndStress() throws {
        var pipelined = [MCPSession.initialize(id: "open")]
        for index in 0..<50 {
            pipelined.append(#"{"jsonrpc":"2.0","id":"p\#(index)","method":"ping"}"#)
        }
        let (ordered, _) = try MCPSession.run(pipelined)
        XCTAssertEqual(ordered.last, "")
        let orderedResponses = Array(ordered.dropLast())
        XCTAssertEqual(orderedResponses.count, 51)
        for (index, frame) in orderedResponses.dropFirst().enumerated() {
            let object = try MCPSession.object(frame)
            XCTAssertEqual(object["id"] as? String, "p\(index)", "FIFO order with no drops or duplicates")
        }

        // 200 mixed lines: ping, tools/list, a parse error, an unknown method, an
        // unknown notification — five kinds, 40 each. Only the notification is silent.
        var mixed = [MCPSession.initialize(id: "mixed-open")]
        for index in 0..<40 {
            mixed.append(#"{"jsonrpc":"2.0","id":"m1-\#(index)","method":"ping"}"#)
            mixed.append(#"{"jsonrpc":"2.0","id":"m2-\#(index)","method":"tools/list"}"#)
            mixed.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"ping","trunc"#)
            mixed.append(#"{"jsonrpc":"2.0","id":"m4-\#(index)","method":"resources/subscribe"}"#)
            mixed.append(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#)
        }
        let (frames, _) = try MCPSession.run(mixed)
        XCTAssertEqual(frames.last, "")
        let responses = try frames.dropLast().map { try MCPSession.object($0) }
        // 1 initialize + (40 pings + 40 lists + 40 parse errors + 40 unknown methods).
        XCTAssertEqual(responses.count, 161)
        XCTAssertFalse(responses.contains { $0["method"] != nil })
        for response in responses {
            let exclusive = (response["result"] != nil ? 1 : 0) + (response["error"] != nil ? 1 : 0)
            XCTAssertEqual(exclusive, 1)
        }
    }

    /// TRANSPORT-008: a deeply nested line and duplicate keys parse without a crash,
    /// and the server keeps serving after both.
    func testParserRobustness() throws {
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            deep,
            #"{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"after","method":"ping"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 4)
        let nesting = try MCPSession.object(responses[1])
        let nestingCode = (nesting["error"] as? [String: Any])?["code"] as? Int
        XCTAssertTrue(nestingCode == -32700 || nestingCode == -32600,
                      "a bounded error, never a crash: \(responses[1])")
        // Duplicate keys must not crash; which one Foundation keeps is its choice
        // (this runtime keeps the first), so the pinned behavior is: one response,
        // an id from the line, and the follow-up ping still served.
        let duplicate = try MCPSession.object(responses[2])
        XCTAssertTrue((duplicate["id"] as? Int).map { $0 == 1 || $0 == 2 } ?? false,
                      "the duplicated id answers with one of its values: \(duplicate)")
        try MCPSession.assertResult(responses[3], id: "after")
    }
}
