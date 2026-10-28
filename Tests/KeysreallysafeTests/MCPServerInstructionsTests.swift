import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-INSTRUCTIONS-001..002: the initialize result carries the frozen six-rule
/// instructions string — present, sane, never anywhere else, byte-for-byte as the
/// contract freezes it.
final class MCPServerInstructionsTests: XCTestCase {

    /// The contract's literal, copied verbatim from the validation contract's fenced
    /// block: seven lines, LF-joined, no trailing newline.
    static let frozen = """
Keysrs is the local API-key vault on this Mac. When using its tools, follow these rules:
1. Never open or read .env files yourself; use the scan_project tool instead.
2. Ask the user before importing keys or requesting a grant.
3. Prefer the gateway token over raw keys.
4. If no key exists, ask the user to run `keys add` in their own terminal; the agent never types a key.
5. After a failure, offer send_feedback but never send it.
6. Never print tokens back to the user unless they ask.
"""

    /// INSTRUCTIONS-001: every initialize carries instructions, no other method's
    /// result does, and the text holds no token shape and no absolute path.
    func testInstructionsPresentAndSane() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            MCPSession.initialize(id: "again"),
            #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"l","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"version"}}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 5)

        var instructions = ""
        for index in 0...1 {
            let result = try MCPSession.assertResult(responses[index], id: index == 0 ? "init" : "again")
            let text = result["instructions"] as? String
            XCTAssertNotNil(text, "every initialize response carries instructions")
            instructions = text ?? ""
        }
        XCTAssertFalse(instructions.isEmpty)
        // Sane static text: no token shapes, no absolute paths.
        for shape in ["ksf_", "ksfc_", "ksfp_"] {
            XCTAssertFalse(instructions.contains(shape), "no \(shape) literal in instructions")
        }
        XCTAssertFalse(instructions.contains("/"), "no absolute paths in instructions")

        // The instructions string appears in no ping or tools result.
        for index in 2...4 {
            let frame = responses[index]
            XCTAssertFalse(frame.contains(instructions), "instructions are only in initialize")
        }
    }

    /// INSTRUCTIONS-002: the byte-for-byte pin — LF-joined, no trailing newline,
    /// exactly the seven contract lines.
    func testInstructionsBytePinned() throws {
        let (frames, _) = try MCPSession.run([MCPSession.initialize()])
        XCTAssertEqual(frames.last, "")
        let result = try MCPSession.assertResult(frames[0], id: "init")
        let instructions = (result["instructions"] as? String) ?? ""

        XCTAssertEqual(Data(instructions.utf8), Data(Self.frozen.utf8),
                       "the instructions string is the contract's literal, byte for byte")
        XCTAssertEqual(instructions, Self.frozen)
        XCTAssertFalse(instructions.hasSuffix("\n"), "no trailing newline")
        XCTAssertFalse(instructions.contains("\r"), "LF-joined, never CRLF")
        XCTAssertEqual(instructions.split(separator: "\n", omittingEmptySubsequences: false).count, 7,
                       "the preamble line plus the six rules")
        // The six rules, each present once.
        for rule in ["scan_project", "keys add", "send_feedback"] {
            XCTAssertEqual(instructions.components(separatedBy: rule).count - 1, 1)
        }
        XCTAssertEqual(MCPServer.instructions, Self.frozen, "the server constant matches the contract literal")
    }
}
