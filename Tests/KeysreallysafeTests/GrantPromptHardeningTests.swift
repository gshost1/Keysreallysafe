import XCTest
@testable import KeysCore

/// The 0.14 security review's informational grant items: the pending-ask poll
/// secret is compared in constant time (I1), and the folder-derived project label
/// in the grant's Touch ID reason cannot carry control characters or run long (I2).
final class GrantPromptHardeningTests: XCTestCase {

    /// I1: the claim still answers only the creator's secret, and the comparison is
    /// `ConstantTime.equal`, pinned on the source because timing is not observable
    /// in a unit test. Failed pre-fix: the claim compared with `==`.
    func testThePollSecretIsComparedInConstantTime() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/KeysCore/MCPGrants.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("record.secret == secret"), "no short-circuiting compare of the poll secret")
        XCTAssertTrue(source.contains("ConstantTime.equal(Array(record.secret.utf8), Array(secret.utf8))"))

        let pending = MCPPendingGrants()
        let ask = try pending.insert(key: "demo")
        XCTAssertNil(pending.claim(id: ask.id, secret: ask.secret + "x"), "a wrong secret learns nothing")
        XCTAssertNil(pending.claim(id: ask.id, secret: ""), "a missing secret learns nothing")
        XCTAssertNotNil(pending.claim(id: ask.id, secret: ask.secret), "the creator's secret still claims")
    }

    /// I2: a project label is a folder name a same-user process can choose. In the
    /// prompt it loses control characters (a newline would fake a second line of
    /// the Touch ID reason) and is capped at 60 characters; key and host stay.
    /// Failed pre-fix: the label went into the reason verbatim.
    func testTheGrantPromptLabelIsStrippedAndCapped() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)

        let hostile = "acme\nApproved by your administrator\u{7}\u{202E}" + String(repeating: "x", count: 100)
        _ = try service.issueGrant(name: "demo", request: GrantRequest(task: "fixture"), projectLabel: hostile)

        let reason = try XCTUnwrap(gate.reasons.last)
        XCTAssertFalse(reason.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                       "no control character reaches the prompt")
        XCTAssertFalse(reason.unicodeScalars.contains { $0 == "\u{202E}" }, "no bidi override either")
        let label = try XCTUnwrap(reason.components(separatedBy: ", project ").last)
        XCTAssertLessThanOrEqual(label.count, 60, "the label is capped")
        XCTAssertTrue(label.hasPrefix("acmeApproved by"), label)
        XCTAssertTrue(reason.contains("demo"), "the key is still named")
        XCTAssertEqual(KeysService.promptLabel("acme"), "acme", "an ordinary label is unchanged")
    }
}
