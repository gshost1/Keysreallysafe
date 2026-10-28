import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-LIFECYCLE-004..007: the handshake's idempotence, the ordering gate,
/// notification discipline and the dispatch table, each on a fresh server where
/// per-instance state matters.
final class MCPServerLifecycleTests: XCTestCase {

    /// LIFECYCLE-004: a second initialize is an idempotent re-answer, and
    /// notifications/initialized is silent in every form — early, normal, duplicate.
    func testHandshakeRobustness() throws {
        // Early: before any initialize, it produces zero stdout bytes and breaks nothing.
        let (early, _) = try MCPSession.run([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        ])
        XCTAssertEqual(early, [], "an early notification answers nothing")

        let (frames, _) = try MCPSession.run([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, // early again, with company
            MCPSession.initialize(id: "first"),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, // normal
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, // duplicate
            MCPSession.initialize(id: "second"),                        // idempotent re-answer
            #"{"jsonrpc":"2.0","id":"tool","method":"tools/call","params":{"name":"version"}}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 3, "the notifications contribute zero bytes")
        let first = try MCPSession.assertResult(responses[0], id: "first")
        let second = try MCPSession.assertResult(responses[1], id: "second")
        XCTAssertEqual(Set(second.keys), ["protocolVersion", "capabilities", "serverInfo", "instructions"])
        XCTAssertEqual(second["protocolVersion"] as? String, first["protocolVersion"] as? String)
        let call = try MCPSession.assertResult(responses[2], id: "tool")
        XCTAssertTrue(((call["content"] as? [[String: Any]])?.first?["text"] as? String)?.isEmpty == false)
    }

    /// LIFECYCLE-005: every request before initialize — ping included — is refused
    /// with -32600, and after the initialize response tools are served without
    /// waiting for notifications/initialized.
    func testLifecycleOrdering() throws {
        let (frames, _) = try MCPSession.run([
            #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"b","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":"d","method":"server/discover"}"#,
            MCPSession.initialize(id: "open"),
            #"{"jsonrpc":"2.0","id":"e","method":"tools/list"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 6)
        for (index, id) in ["a", "b", "c", "d"].enumerated() {
            try MCPSession.assertError(responses[index], code: -32600, id: id,
                                       "every pre-initialize request, ping included")
        }
        try MCPSession.assertResult(responses[4], id: "open")
        let tools = try MCPSession.assertResult(responses[5], id: "e")
        XCTAssertNotNil(tools["tools"] as? [[String: Any]],
                         "requests between the response and notifications/initialized are served")
    }

    /// LIFECYCLE-006: unknown notifications and notifications/cancelled are silent
    /// before, during and after the handshake, and a notification-shaped method
    /// carrying an id is an unknown request (-32601).
    func testNotificationDiscipline() throws {
        let (before, _) = try MCPSession.run([
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#,
        ])
        XCTAssertEqual(before, [], "unknown notifications before the handshake answer nothing")

        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"x","reason":"user"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/anything/else"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 3, "zero bytes for the notifications, ever")
        try MCPSession.assertResult(responses[0], id: "init")
        try MCPSession.assertError(responses[1], code: -32601, id: 9,
                                   "an id makes it a request for an unknown method")
        try MCPSession.assertResult(responses[2], id: "ping", "the server keeps serving")
    }

    /// LIFECYCLE-007: ping answers exactly {}, the unknown-method table stays at
    /// -32601, and a second server instance in the same process starts uninitialized.
    func testDispatchAndFreshInstance() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"server/discover"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"prompts/list"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"logging/setLevel"}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"completion/complete"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 7)
        let ping = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(ping.count, 0, "ping answers exactly {}")
        for index in 2...6 {
            try MCPSession.assertError(responses[index], code: -32601, id: index)
            let error = try MCPSession.object(responses[index])
            let message = (error["error"] as? [String: Any])?["message"] as? String
            XCTAssertFalse(message?.contains("\n") ?? true, "one plain sentence")
        }

        // A second instance in the same process starts as uninitialized as the first.
        let (fresh, _) = try MCPSession.run([
            #"{"jsonrpc":"2.0","id":"early","method":"tools/list"}"#,
        ])
        XCTAssertEqual(fresh.last, "")
        try MCPSession.assertError(fresh[0], code: -32600, id: "early")
    }
}
