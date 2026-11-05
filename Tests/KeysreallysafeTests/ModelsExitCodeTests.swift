import Foundation
import XCTest
@testable import KeysCore

/// `keys models` and `keys test` answer the same provider fact, so they must agree on
/// the exit code a script reads. The JSON arm of `keys models` hardcoded 5, while the
/// text arm and `keys test` use `ProviderCheck.Outcome.cliExitCode`, which is 2 when the
/// provider has no read-only check endpoint (nothing was sent) — so the same cached
/// outcome exited 5 with `--json` and 2 without it.
final class ModelsExitCodeTests: XCTestCase {

    /// The outcome a provider without a check endpoint reports, recorded by a real
    /// `checkProvider` call so the command reads it back from the catalog.
    private func cachedNoEndpoint(cached: Bool) throws -> (service: KeysService, db: CatalogDB) {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        // `other` is the parser with no read-only endpoint, so nothing is sent.
        try service.add(name: "demo", provider: "other", kind: "runtime", notes: "", secret: fixtureSecret)
        return (service, db)
    }

    /// The exit code every arm must agree on, from the recorded check itself.
    func testEveryArmUsesTheOutcomeExitCode() throws {
        let (service, _) = try cachedNoEndpoint(cached: false)
        let recorded = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(recorded.outcome, .noCheckEndpoint)
        XCTAssertEqual(recorded.outcome.cliExitCode, 2, "nothing was sent: 2, not 5")
        XCTAssertEqual(try service.lastCheck(name: "demo")?.outcome.cliExitCode, 2,
                       "the cached read carries the same outcome")
    }

    /// The fix in the source: the JSON arm of `keys models` exits the outcome's code,
    /// not a literal 5. Pinned structurally because the arm ends the process.
    func testTheModelsJsonArmExitsTheOutcomesCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = try String(contentsOf: root.appendingPathComponent("Sources/KeysCore/CLI.swift"), encoding: .utf8)
        let lines = cli.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct ModelsCommand") }) else {
            return XCTFail("ModelsCommand not found")
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("struct ") || $0.hasPrefix("enum ") } ?? lines.endIndex
        let block = lines[start..<end].joined(separator: "\n")

        XCTAssertFalse(block.contains("Darwin.exit(5)"), "the JSON arm hardcoded 5")
        XCTAssertEqual(
            block.components(separatedBy: "cliExitCode").count - 1, 2,
            "both failure arms — JSON and text — use the outcome's code"
        )
    }
}
