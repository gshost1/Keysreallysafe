import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-REGISTRY-001..003: the mission roster exactly (no hidden tools), the
/// one-file-plus-one-line seam, and containment of an invalid registration.
final class MCPRegistryTests: XCTestCase {

    /// The full merged mission roster: the mcp-core mission's five read tools,
    /// its two grants tools, the onboarding mission's four tools, then the
    /// feedback mission's five (send_feedback, set_analytics_sharing,
    /// revoke_all, revoke_project, activity) — in registration order, which is
    /// the order of the groups in `MCPToolRegistry.groups`.
    static let milestoneOneRoster = ["version", "list_keys", "gateway_info", "open_app", "check_update"]
    static let milestoneTwoRoster = ["request_grant", "grant_status"]
    static let onboardingRoster = ["scan_project", "check_exposure", "import_and_wrap", "test_keys"]
    static let feedbackRoster = ["send_feedback"]
    static let analyticsRoster = ["set_analytics_sharing"]
    static let revokeRoster = ["revoke_all", "revoke_project"]
    static let activityRoster = ["activity"]
    static let missionRoster = milestoneOneRoster + milestoneTwoRoster + onboardingRoster + feedbackRoster + analyticsRoster + revokeRoster + activityRoster

    /// Names no revision of this server has registered: the cancel tool that
    /// deliberately does not exist (denial is the user cancelling Touch ID), and
    /// `keys unwrap` — the restore flow is CLI-only on purpose (the MCP surface
    /// never rewrote the user's files, and revocation stays in the app), so its
    /// absence is pinned like the rest.
    static let neverRegistered = [
        "grant_cancel", "unwrap",
    ]

    // MARK: - REGISTRY-001

    /// The roster is the LITERAL mission set, pinned by name — not by comparing
    /// `tools/list` to the registry's own declared groups, which is self-referential
    /// and would let a wrongly-named tool pass. The mission's sixteen tools, in
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

    /// VAL-INT-002: the roster holds no forbidden tool KIND. The mission floor
    /// (AGENTS.md) names the shapes that must never exist — a tool that removes or
    /// rotates a key, reveals or copies a value, prints one into the environment,
    /// mints a long-lived token, or turns the relay on — so the listing is scanned
    /// for them by name, independently of the exact-set pin above: a future group
    /// that adds one of these fails here by name even if the roster literal is
    /// edited alongside it.
    func testNoForbiddenToolKindIsRegistered() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
        ])
        let listed = try Self.names(in: frames[1], id: 1)
        XCTAssertEqual(listed, Self.missionRoster, "the roster is the sixteen-tool union")

        // Tool names are snake_case, so the forbidden kinds are checked as whole
        // segments (never as substrings: `revoke_all` must not read as `rotate`).
        let forbiddenSegments: Set<String> = [
            "rm", "delete", "rotate", "reveal", "copy", "env", "export", "relay", "token", "long_lived",
        ]
        let forbiddenNames: Set<String> = [
            "env", "relay_on", "relay-on", "long_lived_token", "long-lived-token",
        ]
        for name in listed {
            let segments = Set(name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init))
            XCTAssertTrue(
                segments.isDisjoint(with: forbiddenSegments),
                "\(name) is a forbidden tool kind: none of rm/rotate/reveal/copy/env/long-lived-token/relay-on may be registered"
            )
            XCTAssertFalse(forbiddenNames.contains(name), "\(name) is a forbidden tool kind")
        }
    }

    // MARK: - REGISTRY-004: the default state seams fail closed under test isolation

    /// VAL-G-003: the production roster constructs offline (nothing resolves at
    /// init, so building `MCPToolRegistry.default` under the tripwire proves the
    /// offline-safe construction seam), but its DEFAULT state paths must refuse
    /// when reached: the catalog the read and activity groups would open and the
    /// control file the app-bound groups would connect through resolve through
    /// the tripwire-checked seams, so under XCTest with no `KEYS_CATALOG` (the
    /// CI environment) every state-bound default answers the isolation refusal —
    /// never the real catalog's rows, never the installed app. Pre-fix this row
    /// was deliberately not run: the old eager defaults would have opened the
    /// real catalog and read the real control.json with the owner's app live;
    /// the captured pre-fix evidence for the same resolution lives in
    /// ProductionTripwireTests.
    func testDefaultRegistryStateSeamsFailClosedUnderTestIsolation() throws {
        // Construction stays offline-safe: the default roster builds under the
        // tripwire, and the offline version tool answers normally.
        let registry = MCPToolRegistry.default
        XCTAssertTrue(registry.tools.contains { $0.name == "version" }, "the default roster still constructs")

        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"v","method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":"k","method":"tools/call","params":{"name":"list_keys"}}"#,
            #"{"jsonrpc":"2.0","id":"g","method":"tools/call","params":{"name":"gateway_info"}}"#,
        ], registry: registry)
        XCTAssertTrue(stderr.isEmpty, "the production roster registers cleanly")
        let responses = Array(frames.dropLast())

        let version = try MCPSession.assertResult(responses[1], id: "v")
        XCTAssertNotEqual(version["isError"] as? Bool, true, "version needs no state")

        // The state-bound defaults refuse with the isolation rule: the catalog
        // path and the control path both fail closed, before any file is read
        // or anything launched — so the refusal is never the not-running
        // sentence and never carries a production location.
        for (index, id, name) in [(2, "k", "list_keys"), (3, "g", "gateway_info")] {
            let result = try MCPSession.assertResult(responses[index], id: id)
            XCTAssertEqual(result["isError"] as? Bool, true, "\(name) refuses under the tripwire")
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            XCTAssertTrue(text.contains("test isolation"),
                          "\(name)'s refusal names the isolation rule: \(text)")
            XCTAssertNotEqual(text, AppConnection.notRunningMessage,
                              "\(name) refused before any launch, not after one")
            XCTAssertFalse(text.contains("/Users/"), "\(name)'s refusal names no production location")
        }
    }

    /// VAL-G-003's session half: `MCPSession.run`'s DEFAULT roster is the
    /// guarded test world, never the production default — so a scripted session
    /// that never passes a registry still runs over a fresh temp catalog (the
    /// empty answer below), and the isolation guard has run inside the roster
    /// builder before any group was constructed. Pre-fix the default was
    /// `MCPToolRegistry.default`, whose eager defaults resolved the production
    /// paths as values even for an offline session; this row was deliberately
    /// not run pre-fix (list_keys would have opened the real catalog).
    func testSessionDefaultRosterIsTheGuardedTestWorld() throws {
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"k","method":"tools/call","params":{"name":"list_keys"}}"#,
        ])
        XCTAssertTrue(stderr.isEmpty, "the guarded roster registers cleanly")
        let responses = Array(frames.dropLast())
        let result = try MCPSession.assertResult(responses[1], id: "k")
        XCTAssertNotEqual(result["isError"] as? Bool, true,
                          "the default roster answers from a temp catalog, not the real one")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual((decoded?["keys"] as? [Any])?.count, 0, "the guarded world's catalog is empty")
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
