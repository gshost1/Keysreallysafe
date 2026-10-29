import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-REGISTRY-001..003: the mission roster exactly (no hidden tools), the
/// one-file-plus-one-line seam, and containment of an invalid registration.
final class MCPRegistryTests: XCTestCase {

    /// The full mission roster: the mcp-core mission's five read tools, its two
    /// grants tools, then the onboarding mission's tools in registration order
    /// — scan_project, check_exposure, import_and_wrap, test_keys.
    static let milestoneOneRoster = ["version", "list_keys", "gateway_info", "open_app", "check_update"]
    static let milestoneTwoRoster = ["request_grant", "grant_status"]
    static let onboardingRoster = ["scan_project", "check_exposure", "import_and_wrap", "test_keys"]
    static let missionRoster = milestoneOneRoster + milestoneTwoRoster + onboardingRoster

    /// Names no revision of this server has registered: the parallel missions'
    /// tools, the cancel tool that deliberately does not exist (denial is the
    /// user cancelling Touch ID), and `keys unwrap` — the restore flow is
    /// CLI-only on purpose (the MCP surface never rewrote the user's files,
    /// and revocation stays in the app), so its absence is pinned like the rest.
    static let neverRegistered = [
        "revoke_all", "activity", "send_feedback", "grant_cancel", "unwrap",
    ]

    // MARK: - REGISTRY-001

    /// The roster is the LITERAL mission set, pinned by name — not by comparing
    /// `tools/list` to the registry's own declared groups, which is self-referential
    /// and would let a wrongly-named tool pass. The mission's eight tools, in
    /// registration order, each once; every listed name answers `tools/call`, and
    /// the not-yet-built names still answer -32602 and are absent — future tools
    /// appear by registration, never by accident.
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

        // Each name exactly once, and deterministic across calls and instances.
        XCTAssertEqual(listed, again, "tools/list is deterministic")
        XCTAssertEqual(Set(listed).count, listed.count, "no tool name appears twice: \(listed)")

        // The literal mission roster. A wrongly-named tool, a missing one or a
        // duplicate fails here, whatever the registry declares.
        XCTAssertEqual(listed, Self.missionRoster, "tools/list is exactly the mission's roster")

        // List and call share one registry: every listed name answers tools/call.
        // The calls run over the sweep rig's wiring so the catalog-bound tools read
        // temp state, never the machine's real catalog or installed app; an
        // app-bound tool answers with its not-running result there, and what is
        // pinned is that a LISTED name is never the unknown-tool -32602.
        let rig = try MCPSweepRig.make()
        var lines = [MCPSession.initialize()]
        for name in listed {
            guard let row = MCPSweepRig.argumentRows[name] else {
                XCTFail("no argument row for the listed tool \"\(name)\"; add one to MCPSweepRig.argumentRows")
                continue
            }
            let arguments = String(decoding: try JSONValue.data(row), as: UTF8.self)
            lines.append(#"{"jsonrpc":"2.0","id":"call:\#(name)","method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        }
        let (callFrames, callStderr) = try MCPSession.run(lines, registry: try rig.registry())
        XCTAssertEqual(callFrames.last, "")
        XCTAssertTrue(callStderr.isEmpty, "the rig-wired roster registers cleanly")
        let callResponses = Array(callFrames.dropLast())
        XCTAssertEqual(callResponses.count, 1 + listed.count, "every listed name is called")
        for (index, name) in listed.enumerated() {
            // assertResult already pins the response is a tools result, never a
            // -32602 error frame; content proves a listed name always answers.
            let answered = try MCPSession.assertResult(callResponses[1 + index], id: "call:\(name)")
            let blocks = (answered["content"] as? [[String: Any]]) ?? []
            XCTAssertFalse(blocks.isEmpty, "\(name) answers tools/call — a listed name is never an unknown tool")
        }

        // Names no revision of this server registers are absent from the list and
        // answer -32602: the parallel missions' tools and the cancel tool that
        // deliberately does not exist (denial is the user cancelling Touch ID).
        var probeLines = [MCPSession.initialize()]
        for (index, name) in Self.neverRegistered.enumerated() {
            probeLines.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"\#(name)"}}"#)
        }
        let (probeFrames, _) = try MCPSession.run(probeLines)
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
