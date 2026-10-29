import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-LIFECYCLE-001..003: the initialize result's exact shape, the legacy-era
/// protocol-version negotiation, and the parameter validation around it.
final class MCPServerInitializeTests: XCTestCase {

    /// LIFECYCLE-001: the result has exactly the four keys, capabilities declare
    /// tools only, and serverInfo carries the pinned name and the version constant.
    func testInitializeResultShape() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            MCPSession.initialize(id: "rich"), // identical answer whatever the client says
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 2)

        let result = try MCPSession.assertResult(responses[0], id: "init")
        XCTAssertEqual(Set(result.keys), ["protocolVersion", "capabilities", "serverInfo", "instructions"],
                       "no extra keys")
        let capabilities = result["capabilities"] as? [String: Any]
        XCTAssertEqual(Array((capabilities ?? [:]).keys).sorted(), ["tools"], "tools-only, no listChanged")
        XCTAssertEqual((capabilities?["tools"] as? [String: Any])?.count, 0)
        let serverInfo = result["serverInfo"] as? [String: Any]
        XCTAssertEqual(Array((serverInfo ?? [:]).keys).sorted(), ["name", "version"])
        XCTAssertEqual(serverInfo?["name"] as? String, "keysrs")
        // Never a literal: the pin survives the 0.14.0 version bump.
        XCTAssertEqual(serverInfo?["version"] as? String, ProductAnalyticsConfiguration.appVersion)

        // Client capabilities and clientInfo are ignored: the second initialize,
        // rich on the client side, produces the identical result.
        let richFrame = #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{}},"clientInfo":{"name":"Claude Code","version":"2.1.0"}}}"#
        let (richFrames, _) = try MCPSession.run([richFrame])
        XCTAssertEqual(richFrames.last, "")
        let richResult = try MCPSession.assertResult(richFrames[0], id: 2)
        XCTAssertEqual(try JSONValue.data(richResult), try JSONValue.data(result),
                       "client fields never change the server's answer")
    }

    /// LIFECYCLE-002: each supported version is echoed, an unknown one is answered
    /// with the newest supported, never an error.
    func testVersionNegotiation() throws {
        var lines = [String]()
        for version in MCPServer.supportedProtocolVersions {
            lines.append(MCPSession.initialize(id: "v\(version)", version: version))
        }
        for (index, version) in ["2026-07-28", "1", ""].enumerated() {
            lines.append(MCPSession.initialize(id: "u\(index)", version: version))
        }
        let (frames, _) = try MCPSession.run(lines)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 7)
        for (index, version) in MCPServer.supportedProtocolVersions.enumerated() {
            let result = try MCPSession.assertResult(responses[index], id: "v\(version)")
            XCTAssertEqual(result["protocolVersion"] as? String, version, "a supported version is echoed")
        }
        for index in 0..<3 {
            let result = try MCPSession.assertResult(responses[4 + index], id: "u\(index)")
            XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.newestProtocolVersion,
                           "an unsupported version gets the newest supported, not an error")
        }
        XCTAssertEqual(MCPServer.newestProtocolVersion, "2025-11-25")
    }

    /// LIFECYCLE-003: a missing or wrong-typed protocolVersion and non-object params
    /// are each one -32602 with the id echoed, and a valid initialize still follows.
    func testInitializeParamsValidation() throws {
        let bad: [(String, Any?)] = [
            (#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, 1),                       // params absent
            (#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#, 2),           // version missing
            (#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":5}}"#, 3),
            (#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":{}}}"#, 4),
            (#"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":null}}"#, 5),
            (#"{"jsonrpc":"2.0","id":6,"method":"initialize","params":[]}"#, 6),
            (#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":"x"}"#, 7),
            (#"{"jsonrpc":"2.0","id":8,"method":"initialize","params":5}"#, 8),
        ]
        var lines = bad.map(\.0)
        lines.append(#"{"jsonrpc":"2.0","id":"closed","method":"ping"}"#)
        lines.append(MCPSession.initialize(id: "recovered"))
        lines.append(#"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#)
        let (frames, _) = try MCPSession.run(lines)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, bad.count + 3)
        for (index, (_, id)) in bad.enumerated() {
            try MCPSession.assertError(responses[index], code: -32602, id: id)
        }
        // None of the failed handshakes initialized the session: the next request is
        // still refused, the valid initialize opens it, and the server keeps serving.
        try MCPSession.assertError(responses[bad.count], code: -32600, id: "closed")
        try MCPSession.assertResult(responses[bad.count + 1], id: "recovered")
        try MCPSession.assertResult(responses[bad.count + 2], id: "ping")
    }
}
