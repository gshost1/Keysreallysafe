import Foundation
import XCTest
@testable import KeysCore

/// VAL-CROSS-002: the planted-secret sweep — with the full fake rig (a key planted
/// with the fake secret, a live grant, a client token), every registered tool is
/// called with its per-tool argument row and the union of captured response bytes
/// contains zero occurrences of the planted values. The sweep is roster-derived: it
/// enumerates `tools/list`, never a typed list, so any tool a later mission
/// registers is swept by default and must add safe offline arguments (or exempt
/// itself with a written reason) or the sweep fails naming the tool.
final class MCPOutputGuardSweepTests: XCTestCase {

    /// The one allowed exception: the `grant_status` approved handover carrying its
    /// own grant's token (the grants feature registers that tool in milestone 2).
    /// Keyed by tool name, so the allowance follows the handover, not the bytes.
    private static let allowedHandovers: [String: [String]] = [:]

    func testPlantedSecretSweep() throws {
        let rig = try MCPSweepRig.make()
        let registry = rig.registry

        // Roster-derived: the roster comes from tools/list of the rig-wired registry.
        let (listing, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ], registry: registry)
        let roster = try MCPSession.toolNames(in: listing[1], id: "list")
        XCTAssertFalse(roster.isEmpty, "the registry has at least the version tool")

        // Every tool registered in production must be swept. A group that lands in
        // the production list without being wired over the rig fails here by name:
        // wire it over the rig in `MCPSweepRig.registry` and add its argument row.
        let (productionListing, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ])
        let production = try MCPSession.toolNames(in: productionListing[1], id: "list")
        XCTAssertEqual(
            Set(production), Set(roster),
            "every registered tool must be swept; wire the missing ones over the rig in MCPSweepRig.registry and add their argument rows"
        )

        // Every registered tool is called with its per-tool argument row. A tool
        // with no row fails the sweep by name — that is the default-on coverage.
        var rows: [(name: String, arguments: [String: Any])] = []
        var missing: [String] = []
        for name in roster {
            if let row = MCPSweepRig.argumentRows[name] {
                rows.append((name, row))
            } else {
                missing.append(name)
            }
        }
        for name in missing {
            XCTFail("no argument row for the registered tool \"\(name)\"; add safe offline arguments to MCPSweepRig.argumentRows or exempt it with a written reason")
        }

        var lines = [MCPSession.initialize(), #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#]
        for (index, row) in rows.enumerated() {
            let arguments = String(decoding: try JSONValue.data(row.arguments), as: UTF8.self)
            lines.append(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"\#(row.name)","arguments":\#(arguments)}}"#)
        }
        // The production wiring: the guard ships with its empty forbidden set, so the
        // sweep proves no tool PULLS the planted values out of the rig — the
        // structural protection, with the token-shape rule as the backstop.
        let (frames, _) = try MCPSession.run(lines, registry: registry)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 2 + rows.count, "one response per request, nothing else")

        let forbidden = [fixtureSecret, rig.grantToken, rig.clientToken]
        // The listing and handshake frames carry none of the planted values.
        for frame in [responses[0], responses[1]] {
            for value in forbidden {
                XCTAssertFalse(frame.contains(value), "a non-tool frame leaks a planted value")
            }
        }
        // Every tool's response: zero occurrences, with the one allowed exception.
        for (index, row) in rows.enumerated() {
            let frame = responses[2 + index]
            _ = try MCPSession.assertResult(frame, id: index, "every registered tool answers")
            let allowed = Self.allowedHandovers[row.name] ?? []
            for value in forbidden where !allowed.contains(value) {
                XCTAssertFalse(
                    frame.contains(value),
                    "the \"\(row.name)\" response leaks a planted value; no registered tool may return it"
                )
            }
        }
        // And the whole captured session, as bytes: the union of response bytes.
        let union = responses.joined(separator: "\n")
        for value in forbidden {
            let allowedAnywhere = Self.allowedHandovers.values.contains { $0.contains(value) }
            if !allowedAnywhere {
                XCTAssertFalse(union.contains(value), "the session's response bytes leak a planted value")
            }
        }
    }
}
