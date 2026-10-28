import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-GUARD-001..009: the single output guard every `tools/call` result passes
/// through before `MCPServer` writes it. The guard runs before the write (never as a
/// post-write corrector), rejects exact forbidden values and full token shapes,
/// replaces rather than scrubs, exempts exactly one handover value, fails closed,
/// never logs what it rejected, ships with a deliberately empty forbidden set, and
/// no MCP tool may call a presence-gated read.
final class MCPOutputGuardTests: XCTestCase {

    /// The repo checkout root, for the seam's source-level pins.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The first text block's text of a tools result.
    private static func resultText(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// The exact bytes the write path would emit for a result — byte-equality here is
    /// byte-identity of what the client receives.
    private static func wireBytes(_ result: MCPToolResult) throws -> Data {
        try JSONValue.data(result.jsonObject())
    }

    // MARK: - GUARD-001

    /// The guard runs before the single write path — a rejected call yields exactly
    /// one complete replacement line, nothing partial — and its scope is tools/call
    /// results only: the static answers are byte-identical with and without a guard,
    /// even one whose provider throws at every fetch.
    func testGuardBeforeWriteAndScope() throws {
        let registry = MCPToolRegistry(groups: [
            MCPVersionTool(),
            TestToolGroup(name: "leaky") { _, _ in
                MCPToolResult(content: [["type": "text", "text": "the secret is \(fixtureSecret)"]], isError: false)
            },
        ])

        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
        ], registry: registry, outputGuard: MCPOutputGuard(forbiddenValues: [fixtureSecret]))
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 2, "exactly one complete response line, nothing partial reaches the stream")
        let replaced = try MCPSession.assertResult(responses[1], id: 1, "the guard is not a post-write corrector")
        XCTAssertEqual(replaced["isError"] as? Bool, true)
        XCTAssertEqual(Self.resultText(replaced), MCPOutputGuard.rejectionMessage)
        XCTAssertFalse(frames.joined(separator: "\n").contains(fixtureSecret), "zero bytes of the value reach the writer")

        // Scope: initialize, ping and tools/list never pass through the guard, so a
        // throwing provider cannot touch them — byte-identical to a guard-less run.
        let statics = [
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ]
        let throwing = MCPOutputGuard(forbiddenValues: {
            throw AppError.keychain("the forbidden-value provider is unavailable")
        })
        let (guarded, _) = try MCPSession.run(statics, registry: registry, outputGuard: throwing)
        let (guardless, _) = try MCPSession.run(statics, registry: registry, outputGuard: nil)
        XCTAssertEqual(guarded, guardless, "the guard covers tools/call results only")
        XCTAssertEqual(guarded.count, 4, "the three answers plus the trailing newline chunk")
    }

    // MARK: - GUARD-002

    /// The planted value is rejected in every placement a result can carry it in:
    /// a text block, a second content block, a nested object value, a longer
    /// concatenated string, escaped JSON inside a text block, a non-text block
    /// field, an isError result's text, and a tool throw whose message still
    /// carries it. Error text is content, not an exemption.
    func testSecretValuesRejectedEverywhere() throws {
        let placements: [(String, MCPToolResult)] = [
            ("a text block", MCPToolResult(
                content: [["type": "text", "text": fixtureSecret]], isError: false)),
            ("a second content block", MCPToolResult(
                content: [["type": "text", "text": "ok"], ["type": "text", "text": fixtureSecret]], isError: false)),
            ("a nested object value", MCPToolResult(
                content: [["type": "text", "text": "ok", "nested": ["deep": ["secret": fixtureSecret]]]], isError: false)),
            ("a longer concatenated string", MCPToolResult(
                content: [["type": "text", "text": "the key \(fixtureSecret) was rejected"]], isError: false)),
            ("escaped JSON inside a text block", MCPToolResult(
                content: [["type": "text", "text": #"{"api_key":"\#(fixtureSecret)"}"#]], isError: false)),
            ("a non-text block field", MCPToolResult(
                content: [["type": "resource", "uri": fixtureSecret]], isError: false)),
            ("an isError result's text", MCPToolResult(
                content: [["type": "text", "text": fixtureSecret]], isError: true)),
        ]
        for (label, planted) in placements {
            let registry = MCPToolRegistry(groups: [TestToolGroup(name: "leaky") { _, _ in planted }])
            let (frames, _) = try MCPSession.run([
                MCPSession.initialize(),
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
            ], registry: registry, outputGuard: MCPOutputGuard(forbiddenValues: [fixtureSecret]))
            XCTAssertEqual(frames.last, "")
            let responses = Array(frames.dropLast())
            XCTAssertEqual(responses.count, 2, "one complete response line for \(label)")
            let replaced = try MCPSession.assertResult(responses[1], id: 1)
            XCTAssertEqual(replaced["isError"] as? Bool, true, "\(label) is replaced, not scrubbed")
            XCTAssertEqual(Self.resultText(replaced), MCPOutputGuard.rejectionMessage, label)
            XCTAssertFalse(
                frames.joined(separator: "\n").contains(fixtureSecret),
                "zero bytes of the planted value reach the writer for \(label)"
            )
        }

        // A tool throw whose scrubbed message still carries the value: the failure
        // result goes through the guard like any other result.
        let thrower = MCPToolRegistry(groups: [TestToolGroup(name: "leaky") { _, _ in
            throw AppError.usage("the secret is \(fixtureSecret)")
        }])
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
        ], registry: thrower, outputGuard: MCPOutputGuard(forbiddenValues: [fixtureSecret]))
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let replaced = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(replaced["isError"] as? Bool, true, "error text is content, not an exemption")
        XCTAssertFalse(frames.joined(separator: "\n").contains(fixtureSecret))
    }

    // MARK: - GUARD-003

    /// Full token shapes are rejected unconditionally — by the production guard, with
    /// its empty forbidden set: a real minted grant token and a synthetic one, a real
    /// client token and a synthetic one, and both `ksfp_` shapes. The shape list is
    /// one constant in the guard.
    func testTokenShapesRejected() throws {
        let rig = try MCPSweepRig.make()
        let syntheticGrant = "ksf_0123abcd_" + String(repeating: "Q", count: 43)
        let syntheticClient = "ksfc_" + String(repeating: "a", count: 48)
        let realPairing = RelayPairing.generate()
        let syntheticPairing = "ksfp_" + String(repeating: "b", count: 48)

        // The minted tokens really are the shapes the rule names.
        XCTAssertTrue(rig.grantToken.hasPrefix("ksf_"), String(rig.grantToken.prefix(4)))
        XCTAssertTrue(rig.clientToken.hasPrefix("ksfc_"))
        XCTAssertTrue(realPairing.hasPrefix("ksfp_"))

        let tokens = [
            ("a real grant token", rig.grantToken),
            ("a synthetic grant token", syntheticGrant),
            ("a real client token", rig.clientToken),
            ("a synthetic client token", syntheticClient),
            ("a real relay-pairing credential", realPairing),
            ("a synthetic ksfp_ token", syntheticPairing),
        ]
        for (label, token) in tokens {
            let registry = MCPToolRegistry(groups: [TestToolGroup(name: "leaky") { _, _ in
                MCPToolResult(content: [["type": "text", "text": "granted: \(token)"]], isError: false)
            }])
            // No outputGuard argument: the production guard, whose only live rule is
            // the token shape one. That is what "unconditional" means.
            let (frames, _) = try MCPSession.run([
                MCPSession.initialize(),
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
            ], registry: registry)
            XCTAssertEqual(frames.last, "")
            let responses = Array(frames.dropLast())
            let replaced = try MCPSession.assertResult(responses[1], id: 1)
            XCTAssertEqual(replaced["isError"] as? Bool, true, "\(label) is rejected unconditionally")
            XCTAssertEqual(Self.resultText(replaced), MCPOutputGuard.rejectionMessage)
            XCTAssertFalse(
                frames.joined(separator: "\n").contains(token),
                "zero bytes of \(label) reach the writer"
            )
        }

        // The shape list is one constant in the guard, naming every prefix.
        for prefix in ["ksf_", "ksfc_", "ksfp_"] {
            XCTAssertTrue(MCPOutputGuard.tokenShapePattern.contains(prefix), "one constant names the \(prefix) shape")
        }
    }

    // MARK: - GUARD-004

    /// Benign text passes byte-identically — no false positives from fragments,
    /// prefixes or shape-likes — and a rejection replaces the whole result with the
    /// guard's fixed message, never a redaction, never an echo.
    func testMatchingDiscipline() throws {
        // A token-shaped forbidden value whose last-4 hint is in the benign corpus:
        // a fragment rule would reject the hint; exact-value matching passes it.
        let clientToken = "ksfc_" + String(repeating: "c", count: 44) + "abcd"
        let outputGuard = MCPOutputGuard(forbiddenValues: [fixtureSecret, clientToken])
        let benign: [(String, String)] = [
            ("a last-4 hint", "…abcd"),
            ("a bare grant id", "deadbeef"),
            ("the bare ksf_ prefix", "ksf_"),
            ("the bare ksfc_ prefix", "ksfc_"),
            ("the bare ksfp_ prefix", "ksfp_"),
            ("a malformed grant-like", "ksf_1"),
            ("a malformed client-like", "ksfc_short"),
            ("a gateway URL", "http://127.0.0.1:12767/demo"),
            ("the word token", "token"),
        ]
        for (label, text) in benign {
            let planted = MCPToolResult(content: [["type": "text", "text": text]], isError: false)
            XCTAssertEqual(try Self.wireBytes(outputGuard.screened(planted)), try Self.wireBytes(planted),
                           "\(label) passes byte-identically")
        }

        // The same corpus through the whole server, guard on and guard off.
        let registry = MCPToolRegistry(groups: benign.enumerated().map { index, entry in
            TestToolGroup(name: "benign\(index)") { _, _ in
                MCPToolResult(content: [["type": "text", "text": entry.1]], isError: false)
            }
        })
        var lines = [MCPSession.initialize()]
        for index in benign.indices {
            lines.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"benign\#(index)"}}"#)
        }
        let (guarded, _) = try MCPSession.run(lines, registry: registry, outputGuard: outputGuard)
        let (guardless, _) = try MCPSession.run(lines, registry: registry, outputGuard: nil)
        XCTAssertEqual(guarded, guardless, "benign text passes untouched")

        // A rejection replaces the result with the fixed error — never the original
        // with a mask, never a fragment, never the value echoed back.
        let leaky = MCPToolRegistry(groups: [TestToolGroup(name: "leaky") { _, _ in
            MCPToolResult(content: [["type": "text", "text": "value \(fixtureSecret) here"]], isError: false)
        }])
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
        ], registry: leaky, outputGuard: outputGuard)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let replaced = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(replaced["isError"] as? Bool, true)
        XCTAssertEqual(Self.resultText(replaced), MCPOutputGuard.rejectionMessage,
                       "the message is the guard's constant, compared against it")
        let whole = frames.joined(separator: "\n")
        XCTAssertFalse(whole.contains(fixtureSecret), "the rejected value is never echoed")
        XCTAssertFalse(whole.contains("[redacted]"), "the result is never scrubbed in place")
        XCTAssertFalse(whole.contains(" here"), "no masked fragment of the original survives")
    }

    // MARK: - GUARD-005

    /// The handover exemption is exactly one value: the approved `grant_status`
    /// result carries its own grant's token and is NOT replaced; the same token from
    /// any other tool is; the handover plus a second token is; and non-approved
    /// grant_status states carry no `ksf_` value at all.
    func testHandoverExemptionSingleValue() throws {
        let rig = try MCPSweepRig.make()
        let secondToken = "ksf_ffffffff_" + String(repeating: "Z", count: 43)
        let approvedPayload = String(decoding: try JSONValue.data([
            "status": "approved",
            "token": rig.grantToken,
            "base_url": "http://127.0.0.1:12767",
            "auth_header": "Authorization",
            "gateway_url": "http://127.0.0.1:12767/demo",
        ] as [String: Any]), as: UTF8.self)
        let twoTokensPayload = String(decoding: try JSONValue.data([
            "status": "approved",
            "token": rig.grantToken,
            "other": secondToken,
        ] as [String: Any]), as: UTF8.self)

        let registry = MCPToolRegistry(groups: [
            // The grant_status-shaped approved handover: it carries its own grant's
            // token and declares it as the one value it is delivering.
            TestToolGroup(name: "handover") { _, _ in
                MCPToolResult(content: [["type": "text", "text": approvedPayload]], isError: false, handover: rig.grantToken)
            },
            // The same approved token from a tool that is not handing it over.
            TestToolGroup(name: "probe") { _, _ in
                let text = String(decoding: try JSONValue.data(["token": rig.grantToken]), as: UTF8.self)
                return MCPToolResult(content: [["type": "text", "text": text]], isError: false)
            },
            // The approved handover PLUS a second token.
            TestToolGroup(name: "greedy") { _, _ in
                MCPToolResult(content: [["type": "text", "text": twoTokensPayload]], isError: false, handover: rig.grantToken)
            },
            // Non-approved grant_status states: no token in any of them.
            TestToolGroup(name: "pending") { _, _ in try MCPToolResult.json(["status": "pending", "id": "0123abcd"]) },
            TestToolGroup(name: "denied") { _, _ in try MCPToolResult.json(["status": "denied", "reason": "cancelled"]) },
            TestToolGroup(name: "expired") { _, _ in try MCPToolResult.json(["status": "expired"]) },
            TestToolGroup(name: "not_found") { _, _ in try MCPToolResult.json(["status": "not_found"]) },
        ])

        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"handover"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greedy"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pending"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"denied"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"expired"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"not_found"}}"#,
        ], registry: registry, outputGuard: MCPOutputGuard(forbiddenValues: [fixtureSecret]))
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 8)

        // The one permitted handover: the approved result delivers its token and the
        // base URL, and is not replaced. The URL is asserted on the decoded text
        // (its slashes are escaped in the frame bytes).
        let delivered = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertNotEqual(delivered["isError"] as? Bool, true, "the approved handover is permitted")
        XCTAssertTrue(responses[1].contains(rig.grantToken), "the approved token is delivered")
        XCTAssertTrue(Self.resultText(delivered).contains("127.0.0.1:12767"), "the base URL is delivered")

        // Per-value, not per-tool: the same token from any other tool is rejected.
        let rejected = try MCPSession.assertResult(responses[2], id: 2)
        XCTAssertEqual(rejected["isError"] as? Bool, true, "the exemption does not follow the tool")
        XCTAssertEqual(Self.resultText(rejected), MCPOutputGuard.rejectionMessage)
        XCTAssertFalse(responses[2].contains(rig.grantToken))

        // Exactly one entry: the handover carrying its token PLUS a second token is
        // rejected — the exemption covers one value, not the result.
        let greedy = try MCPSession.assertResult(responses[3], id: 3)
        XCTAssertEqual(greedy["isError"] as? Bool, true, "a second token ends the exemption")
        XCTAssertFalse(responses[3].contains(rig.grantToken))
        XCTAssertFalse(responses[3].contains(secondToken))

        // Non-approved states carry no ksf_ value at all and pass clean.
        for (frame, id) in zip(responses[4...], [4, 5, 6, 7]) {
            let state = try MCPSession.assertResult(frame, id: id)
            XCTAssertNotEqual(state["isError"] as? Bool, true, "a tokenless state is not replaced")
            XCTAssertFalse(frame.contains("ksf_"), "no ksf_ value in a non-approved state")
        }
    }

    // MARK: - GUARD-006

    /// With the forbidden-value provider throwing, every tools/call result is
    /// replaced; the static answers keep working; the process stays up; and swapping
    /// a working provider back serves normally — no poisoned state.
    func testFailClosedOnProviderError() throws {
        let box = GuardProviderBox(values: [fixtureSecret])
        let outputGuard = MCPOutputGuard(forbiddenValues: box.valuesNow)
        let registry = MCPToolRegistry(groups: [
            MCPVersionTool(),
            TestToolGroup(name: "clean") { _, _ in try MCPToolResult.json(["ok": true]) },
        ])

        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"version"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"clean"}}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ], registry: registry, outputGuard: outputGuard)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 5)
        for index in [1, 2] {
            let replaced = try MCPSession.assertResult(
                responses[index], id: index, "a provider fault refuses every tools/call result")
            XCTAssertEqual(replaced["isError"] as? Bool, true)
            XCTAssertEqual(Self.resultText(replaced), MCPOutputGuard.rejectionMessage)
        }
        try MCPSession.assertResult(responses[3], id: "ping", "the server stays up and keeps serving")
        XCTAssertEqual(try MCPSession.toolNames(in: responses[4], id: "list").count, 2,
                       "tools/list still answers under the fault")

        // Swapped back, calls serve normally: the fault poisoned nothing.
        box.faulty = false
        let (recovered, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"version"}}"#,
        ], registry: registry, outputGuard: outputGuard)
        XCTAssertEqual(recovered.last, "")
        let versionResult = try MCPSession.assertResult(Array(recovered.dropLast())[1], id: 1)
        XCTAssertNotEqual(versionResult["isError"] as? Bool, true, "no poisoned state after the fault")
        let decoded = try JSONSerialization.jsonObject(
            with: Data(Self.resultText(versionResult).utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["version"] as? String, ProductAnalyticsConfiguration.appVersion,
                       "the real version result is served again")
    }

    // MARK: - GUARD-007

    /// Nothing rejected is ever logged or persisted: after a rejection, a recursive
    /// byte scan of the whole support directory (catalog, WAL and SHM, control.json,
    /// any log) and the captured stderr find zero occurrences of the value.
    func testNothingLoggedOrPersisted() throws {
        let rig = try MCPSweepRig.make()
        // A value unique to this run, so the scan can never be satisfied by accident.
        let unique = "planted-\(UUID().uuidString)-secret"
        let registry = MCPToolRegistry(groups: [
            MCPVersionTool(),
            TestToolGroup(name: "leaky") { _, _ in
                MCPToolResult(content: [["type": "text", "text": "the secret is \(unique)"]], isError: false)
            },
        ])
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"leaky"}}"#,
        ], registry: registry, outputGuard: MCPOutputGuard(forbiddenValues: [unique]))
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let replaced = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(replaced["isError"] as? Bool, true)
        XCTAssertFalse(frames.joined(separator: "\n").contains(unique), "stdout never carries the rejected value")
        XCTAssertFalse(stderr.joined(separator: "\n").contains(unique), "stderr never carries the rejected value")
        assertNoSentinel(unique, in: rig.dir)
    }

    // MARK: - GUARD-008

    /// The production guard construction references no secret store: it is built with
    /// no arguments, the forbidden set is empty by construction, the value rule is
    /// inert in production — while the unconditional token-shape rule is live — and
    /// the guard's source never names the secret-store or presence-gate types.
    func testProductionWiringHasNoSecretStore() throws {
        let production = MCPOutputGuard.production
        XCTAssertEqual(try production.forbiddenValues(), [],
                       "the production forbidden-value set is empty BY CONSTRUCTION")

        // The value rule is inert in production: an arbitrary planted VALUE passes
        // untouched (no vault value can be in MCP-process memory to match against).
        let value = MCPToolResult(content: [["type": "text", "text": "value \(fixtureSecret)"]], isError: false)
        XCTAssertEqual(try Self.wireBytes(production.screened(value)), try Self.wireBytes(value))

        // The token-shape rule is the live production protection.
        let token = try MCPSweepRig.make().grantToken
        let shaped = MCPToolResult(content: [["type": "text", "text": "granted: \(token)"]], isError: false)
        XCTAssertEqual(try Self.wireBytes(production.screened(shaped)),
                       try Self.wireBytes(MCPOutputGuard.replacement),
                       "a full token shape is rejected by the production guard itself")

        // Type-level: the guard's source never names the secret-store or
        // presence-gate types, so no construction of it can reference one.
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/MCPOutputGuard.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("SecretStore"), "the guard never names the secret-store type")
        XCTAssertFalse(source.contains("PresenceGate"), "the guard never names the presence-gate type")
    }

    // MARK: - GUARD-009

    /// No MCP tool may call a presence-gated read. Construction-level: the MCPRun
    /// seam takes no presence gate and no secret store — none of the seam's sources
    /// names either type. Behaviorally: across the full roster over the planted rig,
    /// the recording gate records zero new reasons.
    func testNoPresenceGatedRead() throws {
        for name in ["MCPServer.swift", "MCPOutputGuard.swift", "MCPToolRegistry.swift", "MCPVersionTool.swift"] {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/\(name)"),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("SecretStore"), "\(name) takes no secret store")
            XCTAssertFalse(source.contains("PresenceGate"), "\(name) takes no presence gate")
        }

        // Behaviorally: every registered tool runs against the planted rig and not
        // one of them prompts for presence.
        let rig = try MCPSweepRig.make()
        let registry = rig.registry
        let (listing, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ], registry: registry)
        let roster = try MCPSession.toolNames(in: listing[1], id: "list")
        XCTAssertFalse(roster.isEmpty)

        var lines = [MCPSession.initialize()]
        for (index, name) in roster.enumerated() {
            guard let row = MCPSweepRig.argumentRows[name] else {
                XCTFail("no argument row for the registered tool \"\(name)\"; add safe offline arguments to MCPSweepRig.argumentRows")
                continue
            }
            let arguments = String(decoding: try JSONValue.data(row), as: UTF8.self)
            lines.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        }
        let (frames, _) = try MCPSession.run(lines, registry: registry)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 1 + roster.count, "every registered tool is called")
        XCTAssertEqual(rig.gate.reasons.count, rig.setupPrompts,
                       "no MCP tool triggers or needs presence; a read tool growing a presence prompt fails here")
    }
}

/// A forbidden-value provider that throws through a `ThrowingSecretStore` while
/// `faulty` and serves the planted list once it is not, so one guard instance can
/// prove both the fail-closed fault and the clean recovery.
private final class GuardProviderBox: @unchecked Sendable {
    var faulty = true
    let store = ThrowingSecretStore(AppError.keychain("the keychain is unavailable"))
    let values: [String]

    init(values: [String]) { self.values = values }

    func valuesNow() throws -> [String] {
        guard !faulty else {
            // The provider is store-backed, so the store's fault is the provider's fault.
            _ = try store.get(name: "demo")
            return values
        }
        return values
    }
}
