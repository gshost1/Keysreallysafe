import Foundation
import XCTest
@testable import KeysCore

/// The in-process rig for the `keys mcp` server tests: a scripted session through
/// the injected seam (the `UsageImportRun.run` precedent), never a subprocess and
/// never the real stdout, plus the assertions every response shares.
enum MCPSession {

    /// One scripted session: feed `lines`, capture the stdout frames and stderr prose.
    /// The output guard defaults to the production one — a session is what ships —
    /// and a test that wants a planted value, a throwing provider or no guard at all
    /// passes `outputGuard` explicitly.
    @discardableResult
    static func run(
        _ lines: [String],
        registry: MCPToolRegistry = .default,
        outputGuard: MCPOutputGuard? = MCPOutputGuard.production,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (frames: [String], stderr: [String]) {
        var iterator = lines.makeIterator()
        return try run(next: { iterator.next() }, registry: registry, outputGuard: outputGuard, file: file, line: line)
    }

    /// The byte-level variant, exactly as stdin delivers it: CRLF, blank lines, an
    /// unterminated final line and invalid UTF-8 survive the reader the same way.
    @discardableResult
    static func run(
        bytes: Data,
        registry: MCPToolRegistry = .default,
        outputGuard: MCPOutputGuard? = MCPOutputGuard.production,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (frames: [String], stderr: [String]) {
        var source = MCPLineSource(data: bytes)
        return try run(next: { source.next() }, registry: registry, outputGuard: outputGuard, file: file, line: line)
    }

    private static func run(
        next: () -> String?,
        registry: MCPToolRegistry,
        outputGuard: MCPOutputGuard?,
        file: StaticString,
        line: UInt
    ) throws -> (frames: [String], stderr: [String]) {
        var stdout = Data()
        var stderr: [String] = []
        var server = MCPServer(
            write: { stdout.append($0) },
            note: { stderr.append($0) },
            registry: registry,
            outputGuard: outputGuard
        )
        server.run(next: next)
        let text = String(decoding: stdout, as: UTF8.self)
        // The trailing empty chunk is the stream's final newline; every other chunk
        // is one complete frame.
        let frames = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (frames, stderr)
    }

    /// The initialize line a scripted session opens with.
    static func initialize(id: String = "init", version: String = "2025-06-18") -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","method":"initialize","params":{"protocolVersion":"\#(version)"}}"#
    }

    /// The `tools/list` tool names in one frame, in order — the roster-derived sweep
    /// enumerates these, never a typed list.
    static func toolNames(in frame: String, id: Any, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let result = try assertResult(frame, id: id, file: file, line: line)
        return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// One captured frame as a JSON object; fails the test when it is not one.
    static func object(_ frame: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        guard let object = parsed as? [String: Any] else {
            XCTFail("a captured frame is not a JSON object: \(frame)", file: file, line: line)
            return [:]
        }
        return object
    }

    /// The envelope every response must carry: `jsonrpc` 2.0, exactly one of
    /// `result`/`error`, no `method`, and the request's id echoed exactly.
    static func assertEnvelope(
        _ object: [String: Any],
        id expected: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0", file: file, line: line)
        XCTAssertNil(object["method"], "a response never carries a method", file: file, line: line)
        let exclusive = (object["result"] != nil ? 1 : 0) + (object["error"] != nil ? 1 : 0)
        XCTAssertEqual(exclusive, 1, "exactly one of result or error", file: file, line: line)
        assertID(object, equals: expected, file: file, line: line)
    }

    /// Asserts a frame is an error response with `code` and the id echoed.
    static func assertError(
        _ frame: String,
        code: Int,
        id: Any?,
        _ note: StaticString = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let object = try MCPSession.object(frame, file: file, line: line)
        assertEnvelope(object, id: id, file: file, line: line)
        XCTAssertNil(object["result"], "\(note)", file: file, line: line)
        guard let error = object["error"] as? [String: Any] else {
            XCTFail("no error object in \(frame) \(note)", file: file, line: line)
            return
        }
        XCTAssertEqual((error["code"] as? Int), code, "\(note)", file: file, line: line)
        let message = error["message"] as? String
        XCTAssertNotNil(message, "\(note)", file: file, line: line)
        XCTAssertFalse(message?.contains("\n") ?? true, "the message is one line", file: file, line: line)
    }

    /// Asserts a frame is a success response and returns its result object.
    @discardableResult
    static func assertResult(
        _ frame: String,
        id: Any?,
        _ note: StaticString = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let object = try MCPSession.object(frame, file: file, line: line)
        assertEnvelope(object, id: id, file: file, line: line)
        XCTAssertNil(object["error"], "\(note)", file: file, line: line)
        guard let result = object["result"] as? [String: Any] else {
            XCTFail("no result object in \(frame) \(note)", file: file, line: line)
            return [:]
        }
        return result
    }

    /// Ids are opaque: a string stays a string, a number stays a number, null stays null.
    static func assertID(
        _ object: [String: Any],
        equals expected: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let id = object["id"]
        switch expected {
        case let number as NSNumber where !isBoolean(number):
            guard let actual = id as? NSNumber, !isBoolean(actual) else {
                XCTFail("expected the number id \(number), got \(String(describing: id))", file: file, line: line)
                return
            }
            XCTAssertEqual(actual, number, file: file, line: line)
        case let string as String:
            XCTAssertEqual(id as? String, string, file: file, line: line)
        case is NSNull:
            XCTAssertTrue(id is NSNull, "expected a null id, got \(String(describing: id))", file: file, line: line)
        default:
            XCTFail("unsupported expected id \(String(describing: expected))", file: file, line: line)
        }
    }

    /// A JSON `true`/`false` parses as an NSNumber; numbers must never confuse it.
    static func isBoolean(_ any: Any) -> Bool {
        if let number = any as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return false
    }
}

/// One throwaway tool registered through the seam, for the tools tests. The answer
/// closure is the whole behavior, so one double covers every tool shape the
/// assertions plant: a JSON result, a throwing AppError, an unexpected throw.
/// @unchecked: the closure's `[String: Any]` arguments are not Sendable, but the
/// double never crosses a concurrency domain in these single-threaded sessions.
struct TestToolGroup: MCPToolGroup, @unchecked Sendable {
    static let groupName = "test"

    let name: String
    let answer: (String, [String: Any]) throws -> MCPToolResult

    init(name: String = "probe", _ answer: @escaping (String, [String: Any]) throws -> MCPToolResult) {
        self.name = name
        self.answer = answer
    }

    func tools() -> [MCPTool] {
        [MCPTool(
            name: name,
            title: "Probe",
            description: "A test-only tool registered through the seam.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )]
    }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        try answer(name, arguments)
    }
}

/// The planted-value rig the guard's sweep drives (VAL-CROSS-002's "full fake rig"):
/// a temp catalog with a gated service, one key whose secret is the planted value,
/// one live grant and one client token — the three values no tool result may ever
/// carry. Resolved projects join the rig when the project-identity feature lands.
/// The rig's own setup spends presence prompts (issuing the grant and the client
/// token); every tool call after it must spend none (VAL-MCP-GUARD-009).
enum MCPSweepRig {
    struct Built {
        let dir: URL
        let db: CatalogDB
        let service: KeysService
        let gate: RecordingPresenceGate
        let grantToken: String
        let clientToken: String
        /// The presence prompts the rig's SETUP consumed. A tool call that adds one
        /// means a tool tried a presence-gated read.
        let setupPrompts: Int

        /// The rig-wired roster the sweep drives: every production group, wired over
        /// the rig so its tools answer from THIS catalog and service, never the real
        /// ones. Today only the `version` group needs no external wiring; when a
        /// group lands that answers from the catalog or the app, construct it over
        /// `db`/`service` here — the sweep's production-roster comparison fails
        /// naming any tool registered in production but not swept.
        var registry: MCPToolRegistry { MCPToolRegistry(groups: [MCPVersionTool()]) }
    }

    /// The per-tool argument rows the sweep calls every registered tool with — safe
    /// offline arguments only. A registered tool with no row fails the sweep by
    /// name, so any tool a later mission registers is swept by default: add its row
    /// here (or exempt it with a written reason).
    static var argumentRows: [String: [String: Any]] { [
        "version": [:],
    ] }

    static func make(planted: String = fixtureSecret) throws -> Built {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: planted)
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:1", updateHost: true)
        let grantToken = try grantFor(service, "demo", task: "sweep")
        let client = try service.issueGatewayClient(name: "demo", label: "router")
        return Built(
            dir: dir,
            db: db,
            service: service,
            gate: gate,
            grantToken: grantToken,
            clientToken: client.token,
            setupPrompts: gate.reasons.count
        )
    }
}
