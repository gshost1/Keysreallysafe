import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-REGISTRY-001..003: the mission roster exactly (no hidden tools), the
/// one-file-plus-one-line seam, and containment of an invalid registration.
final class MCPRegistryTests: XCTestCase {

    /// The full mission roster: milestone 1's five, then the two the milestone-2
    /// grants feature adds. The roster test pins the registry to this set, so a tool
    /// outside it can never appear by accident, while `tools/list == declared` keeps
    /// every tool a group registers covered as the later groups land.
    static let milestoneOneRoster = ["version", "list_keys", "gateway_info", "open_app", "check_update"]
    static let milestoneTwoRoster = ["request_grant", "grant_status"]
    static let missionRoster = milestoneOneRoster + milestoneTwoRoster

    /// Names no revision of this mission registers: the parallel missions' tools and
    /// the cancel tool that deliberately does not exist (denial is the user
    /// cancelling Touch ID).
    static let neverRegistered = [
        "scan_project", "check_exposure", "import_and_wrap", "test_keys",
        "revoke_all", "activity", "send_feedback", "grant_cancel",
    ]

    // MARK: - REGISTRY-001

    /// The roster is exactly what the registry declares: each name once, the same
    /// list on every call and every instance, nothing outside the mission roster,
    /// and every not-yet-built name absent from the list and -32602.
    func testMissionRosterExact() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ])
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let listed = try Self.names(in: responses[1], id: 1)
        let again = try Self.names(in: responses[2], id: 2)

        // Each name exactly once, and deterministic across calls.
        XCTAssertEqual(Set(listed).count, listed.count, "no tool name appears twice: \(listed)")
        XCTAssertEqual(listed, again, "tools/list is deterministic")

        // tools/list is exactly the registered roster: nothing hidden, nothing
        // missing. The registry's declared groups are the single source of truth, so
        // this stays exact as later groups register through the seam.
        let declared = MCPToolRegistry.default.groups.flatMap { $0.tools().map(\.name) }
        XCTAssertEqual(listed, declared, "tools/list must equal the registered roster")

        // No tool outside the mission roster can appear by accident.
        let foreign = Set(listed).subtracting(Self.missionRoster)
        XCTAssertTrue(foreign.isEmpty, "tools/list names a tool outside the mission roster: \(foreign.sorted())")

        // The tool this feature pins: `version`, registered as its own group.
        XCTAssertTrue(listed.contains("version"), "version is registered as its own group")

        // List and call share one registry: every listed name resolves.
        for name in listed {
            XCTAssertNotNil(MCPToolRegistry.default.group(for: name), "tools/call must resolve \(name)")
        }

        // Not-yet-built names are absent from the list and answer -32602.
        var lines = [MCPSession.initialize()]
        for (index, name) in Self.neverRegistered.enumerated() {
            lines.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"\#(name)"}}"#)
        }
        let (probeFrames, _) = try MCPSession.run(lines)
        for (index, name) in Self.neverRegistered.enumerated() {
            XCTAssertFalse(listed.contains(name), "\(name) must not be listed")
            try MCPSession.assertError(probeFrames[index + 1], code: -32602, id: index)
        }
    }

    // MARK: - REGISTRY-002

    /// A tool group defined in the TEST target — its own file, registered by one
    /// line appended to the shipped groups list — appears in `tools/list` and its
    /// handler answers a `tools/call` round trip. The baseline roster is unchanged
    /// and first; a second instance reproduces the same order.
    func testSeamRegistersNewGroup() throws {
        let (baselineFrames, baselineStderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
        ])
        XCTAssertTrue(baselineStderr.isEmpty, "the shipped roster registers cleanly")
        let baseline = try Self.names(in: baselineFrames[1], id: 1)
        XCTAssertTrue(baseline.contains("version"))

        // The whole change for a new group: one new file (MCPRegistryTestGroup.swift)
        // plus one line in the groups list. MCPServer, the guard and the other groups
        // are untouched.
        let augmented = MCPToolRegistry(groups: MCPToolRegistry.groups + [MCPRegistryProbeGroup()])
        XCTAssertTrue(augmented.diagnostics.isEmpty, "a valid group registers cleanly")

        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"probe","method":"tools/call","params":{"name":"registry_probe"}}"#,
        ], registry: augmented)
        XCTAssertTrue(stderr.isEmpty)
        let listed = try Self.names(in: frames[1], id: 1)

        // Additive and ordered: the baseline is unchanged and first, the new tool last.
        XCTAssertEqual(Array(listed.prefix(baseline.count)), baseline, "the baseline roster is unchanged and first")
        XCTAssertEqual(listed.count, baseline.count + 1)
        XCTAssertEqual(listed.last, MCPRegistryProbeGroup.toolName)

        // The new entry is complete: a name, a description and an object-rooted schema.
        let entry = try Self.toolEntry(in: frames[1], id: 1, name: MCPRegistryProbeGroup.toolName)
        XCTAssertFalse((entry["description"] as? String ?? "").isEmpty, "the new tool has a description")
        XCTAssertEqual((entry["inputSchema"] as? [String: Any])?["type"] as? String, "object")

        // The handler answers a tools/call round trip.
        let result = try MCPSession.assertResult(frames[2], id: "probe")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["probe"] as? Bool, true)
        XCTAssertEqual(parsed?["echo"] as? String, "registry_probe")

        // A second instance reproduces the same order.
        let (againFrames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
        ], registry: MCPToolRegistry(groups: MCPToolRegistry.groups + [MCPRegistryProbeGroup()]))
        XCTAssertEqual(try Self.names(in: againFrames[1], id: 1), listed)
    }

    // MARK: - REGISTRY-003

    /// A group with an empty name, a name outside the pattern, a non-object-rooted
    /// schema, or a duplicate name is refused as a unit: exactly one diagnostic on
    /// stderr, the valid roster still serves and the next call answers.
    func testInvalidRegistrationContained() throws {
        let cases: [(label: String, refused: MCPRefusedToolGroup)] = [
            ("an empty name", MCPRefusedToolGroup(name: "")),
            ("a name outside the pattern", MCPRefusedToolGroup(name: "bad name!")),
            ("a non-object-rooted schema", MCPRefusedToolGroup(name: "bad_schema", schema: ["type": "array"])),
            ("a duplicate name", MCPRefusedToolGroup(name: "version")),
        ]
        for (label, refused) in cases {
            let registry = MCPToolRegistry(groups: [MCPVersionTool(), refused])
            XCTAssertEqual(registry.diagnostics.count, 1, "exactly one refusal for \(label)")
            XCTAssertEqual(registry.tools.map(\.name), ["version"], "the refused group contributes no tools for \(label)")

            // The server keeps serving and answers tools/list for the valid groups;
            // the one diagnostic reaches stderr and nothing else does.
            let (frames, stderr) = try MCPSession.run([
                MCPSession.initialize(),
                #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            ], registry: registry)
            XCTAssertEqual(stderr, registry.diagnostics, "the refusal reaches stderr for \(label)")
            XCTAssertEqual(stderr.count, 1, "exactly one diagnostic for \(label)")
            XCTAssertFalse(stderr.first?.contains("\n") ?? true, "the diagnostic is one line")
            XCTAssertTrue(stderr.first?.contains("refused_probe") ?? false, "the diagnostic names the group")

            XCTAssertEqual(try Self.names(in: frames[1], id: 1), ["version"], "the valid roster still serves for \(label)")
            try MCPSession.assertResult(frames[2], id: 2)
        }
    }

    // MARK: - Helpers

    /// The `tools/list` names in one frame, in order.
    private static func names(in frame: String, id: Any) throws -> [String] {
        let result = try MCPSession.assertResult(frame, id: id)
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// One `tools/list` entry by name.
    private static func toolEntry(in frame: String, id: Any, name: String) throws -> [String: Any] {
        let result = try MCPSession.assertResult(frame, id: id)
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.first { $0["name"] as? String == name } ?? [:]
    }
}
