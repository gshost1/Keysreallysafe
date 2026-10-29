import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-TOOLS-001..007: the tools surface over the registry — the list's shape,
/// the roster's entries, tools/call's dispatch validation, the result shapes, the
/// scrubbing tool-error formatter and the argument tolerance.
final class MCPServerToolsTests: XCTestCase {

    /// TOOLS-001: tools/list is one page with no nextCursor, and unknown params
    /// change nothing.
    func testToolsListShape() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"stale"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{}}}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 4)
        let names = (try MCPSession.assertResult(responses[1], id: 1))["tools"]
        XCTAssertNotNil(names as? [[String: Any]], "the roster is present")
        for id in [2, 3] {
            let result = try MCPSession.assertResult(responses[id], id: id)
            XCTAssertNil(result["nextCursor"], "single page, always")
            XCTAssertEqual(Set(result.keys), ["tools"])
            let listed = (result["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            XCTAssertEqual(listed, (names as? [[String: Any]])?.compactMap { $0["name"] as? String },
                           "bogus params are ignored and change nothing")
        }
    }

    /// TOOLS-002: every entry has a valid unique name, a description and an
    /// object-rooted inputSchema, and the order is deterministic across calls and
    /// instances.
    func testToolEntriesComplete() throws {
        let namePattern = try NSRegularExpression(pattern: "^[a-zA-Z0-9_-]{1,64}$")
        func validName(_ name: String) -> Bool {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return namePattern.firstMatch(in: name, range: range) != nil
        }

        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let first = ((try MCPSession.assertResult(responses[1], id: 1))["tools"] as? [[String: Any]]) ?? []
        let second = ((try MCPSession.assertResult(responses[2], id: 2))["tools"] as? [[String: Any]]) ?? []
        XCTAssertFalse(first.isEmpty, "the registry has at least the version tool")

        var seen = Set<String>()
        for tool in first {
            let name = tool["name"] as? String
            XCTAssertNotNil(name)
            XCTAssertTrue(validName(name ?? ""), "name must match ^[a-zA-Z0-9_-]{1,64}$: \(name ?? "")")
            XCTAssertFalse(seen.contains(name ?? ""), "names are unique")
            seen.insert(name ?? "")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, "description expected")
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "the schema root must be an object")
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            for (key, value) in properties {
                XCTAssertTrue(value is [String: Any], "property \(key) must be an object")
            }
        }
        XCTAssertTrue(seen.contains("version"), "the version tool is registered as its own group")
        XCTAssertEqual(first.map { $0["name"] as? String }, second.map { $0["name"] as? String },
                       "two consecutive calls list identically")

        // A second server instance reproduces the same order.
        let (fresh, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ])
        XCTAssertEqual(fresh.last, "")
        XCTAssertEqual(fresh.count, 3, "the initialize response and the one tools/list response")
        let freshList = ((try MCPSession.assertResult(fresh[1], id: "list"))["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(freshList.map { $0["name"] as? String }, first.map { $0["name"] as? String },
                       "a fresh instance is deterministic")
    }

    /// TOOLS-003: an unknown tool name is a protocol error (-32602) naming the tool,
    /// names are case-sensitive, and every malformed params shape is -32602 too.
    func testCallDispatchValidation() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"definitely_not_a_tool"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"Version"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"VERSION"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":5}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call"}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":"x"}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"version","arguments":"junk"}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"version","arguments":[]}}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 11)
        for index in 1...9 {
            try MCPSession.assertError(responses[index], code: -32602, id: index,
                                       "an unknown tool or malformed params is a protocol error")
        }
        let unknown = try MCPSession.object(responses[1])
        let message = ((unknown["error"] as? [String: Any])?["message"] as? String) ?? ""
        XCTAssertTrue(message.contains("definitely_not_a_tool"), "the message names the requested tool")
        // Never a tools result: the envelope carries error, not a result with isError.
        XCTAssertNil(unknown["result"])
        try MCPSession.assertResult(responses[10], id: "ping", "the server keeps serving")
    }

    /// TOOLS-004: a successful call returns text blocks with non-empty text, isError
    /// not true, and the id echoed.
    func testSuccessResultShape() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"v","method":"tools/call","params":{"name":"version"}}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let result = try MCPSession.assertResult(responses[1], id: "v")
        let content = result["content"] as? [[String: Any]]
        XCTAssertNotNil(content)
        XCTAssertFalse(content?.isEmpty ?? true)
        for block in content ?? [] {
            XCTAssertEqual(block["type"] as? String, "text", "text blocks only in this mission")
            XCTAssertFalse((block["text"] as? String ?? "").isEmpty, "a block's text is non-empty")
        }
        XCTAssertNotEqual(result["isError"] as? Bool, true, "isError is absent or false")
        // The `version` tool answers the single version constant, like keys version --json.
        let text = (content?.first?["text"] as? String) ?? ""
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["version"] as? String, ProductAnalyticsConfiguration.appVersion)
        XCTAssertEqual(VersionCommand.jsonObject(), ["version": ProductAnalyticsConfiguration.appVersion])
    }

    /// TOOLS-005: every tool-handler throw becomes an isError result inside the
    /// envelope — an unexpected non-AppError included — and -32603 never appears.
    func testFailureInsideResult() throws {
        struct Unexpected: Error {}
        let registry = MCPToolRegistry(groups: [
            TestToolGroup(name: "app") { _, _ in throw AppError.siteUnavailable("Keysrs isn't running. Open Keysrs from Applications, then try again.") },
            TestToolGroup(name: "sqlite") { _, _ in throw AppError.sqlite("disk I/O error") },
            TestToolGroup(name: "surprise") { _, _ in throw Unexpected() },
        ])
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sqlite"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"surprise"}}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
        ], registry: registry)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 5)
        for index in 1...3 {
            let result = try MCPSession.assertResult(responses[index], id: index,
                                                      "a tool failure lives inside the result, never the error envelope")
            XCTAssertEqual(result["isError"] as? Bool, true)
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            XCTAssertFalse(text.isEmpty, "content plus isError: a plain message")
        }
        // The unexpected throw still becomes a plain sentence the model can read.
        let surprise = try MCPSession.assertResult(responses[3], id: 3)
        let text = ((surprise["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, MCPToolErrorFormatter.unexpectedFailureMessage)
        // No throw may surface as a frame fault, and the next ping is served.
        try MCPSession.assertResult(responses[4], id: "ping")
        for frame in responses {
            let error = (try MCPSession.object(frame))["error"] as? [String: Any]
            XCTAssertNotEqual(error?["code"] as? Int, -32603, "-32603 is reserved for frame faults")
        }
    }

    /// TOOLS-006: tool text never carries a stack, an internal path or a pid; the
    /// formatter scrubs planted paths and pids from real AppError text.
    func testErrorTextHygiene() throws {
        let plantedPath = "/tmp/krs-\(UUID().uuidString.prefix(8))/catalog.db"
        let plantedPID = Int.random(in: 100_000...999_999)
        let registry = MCPToolRegistry(groups: [
            MCPVersionTool(),
            TestToolGroup(name: "ingest") { _, _ in
                throw AppError.ingestIO("could not read \(plantedPath) (pid \(plantedPID))")
            },
            TestToolGroup(name: "owner") { _, _ in throw AppError.gatewayOwned(pid_t(plantedPID)) },
            TestToolGroup(name: "user") { _, _ in throw AppError.usage("run it from \(plantedPath) or .build/debug/keys") },
        ])
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ingest"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"owner"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"user"}}"#,
        ], registry: registry)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 5)

        func resultText(_ frame: String, _ id: Any) throws -> String {
            let result = try MCPSession.assertResult(frame, id: id)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let successText = try resultText(responses[1], 1)
        let failures = [
            try resultText(responses[2], 2),
            try resultText(responses[3], 3),
            try resultText(responses[4], 4),
        ]

        for text in [successText] + failures {
            for marker in ["fatal error", "Swift runtime", "Backtrace", "Thread ", "precondition",
                           "KeysCore.", "AppError(", "signal"] {
                XCTAssertFalse(text.contains(marker), "no \(marker) in tool text")
            }
            XCTAssertFalse(text.range(of: "0x[0-9a-fA-F]{8,}", options: .regularExpression) != nil,
                           "no addresses in tool text")
        }
        // The planted path and pid are gone, but the sentence survives.
        for text in failures {
            for forbidden in ["/tmp/", "/Users/", "/private/", ".build/", "catalog.db", plantedPath] {
                XCTAssertFalse(text.contains(forbidden), "\(forbidden) must be scrubbed: \(text)")
            }
            XCTAssertFalse(text.contains(String(plantedPID)), "the pid must be scrubbed: \(text)")
        }
        XCTAssertTrue(failures[0].contains("could not read"), "the plain sentence survives scrubbing")
    }

    /// TOOLS-007: the no-input version tool tolerates absent, empty, null and extra
    /// arguments, _meta dispatches normally, and hostile arguments never crash it.
    func testArgumentTolerance() throws {
        let hostile = String(repeating: "A", count: 100 * 1024)
        let tenThousand = String(repeating: "n", count: 10_000)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"version","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"version","arguments":null}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"version","arguments":{"junk":1}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"version","_meta":{}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"version","arguments":{"pad":"\#(hostile)"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"version","arguments":{"emoji":"🤖中文"}}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"\#(tenThousand)"}}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 10, "one single-line response per input")
        for index in 1...7 {
            let result = try MCPSession.assertResult(responses[index], id: index)
            XCTAssertNotEqual(result["isError"] as? Bool, true,
                              "absent, null, empty, extra and hostile arguments are tolerated")
        }
        try MCPSession.assertError(responses[8], code: -32602, id: 8,
                                   "the 10 000-character tool name is refused, in one line")
        try MCPSession.assertResult(responses[9], id: "ping", "the server keeps serving")
    }
}
