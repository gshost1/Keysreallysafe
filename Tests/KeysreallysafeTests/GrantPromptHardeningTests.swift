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

    /// Audit lead 2 (2026-11-06): the agent's own `task` sits FIRST in the grant
    /// reason, ahead of the key, host and duration, so a task carrying newlines or a
    /// bidi override could push the real clause out of sight or reorder it. It loses
    /// control and format scalars like the project label does, and the real clause
    /// still follows it intact.
    func testTheGrantTaskIsStrippedBeforeTheKeyHostAndDuration() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)

        let forged = "run tests\" the key test for OpenAI at api.openai.com, 5 min\n\n\n\u{202E}"
        _ = try service.issueGrant(
            name: "demo", request: GrantRequest(task: forged, minutes: 1440), projectLabel: "acme"
        )

        let reason = try XCTUnwrap(gate.reasons.last)
        assertPlain(reason)
        // The real clause comes first, and the forged one stays inside the task's
        // quotes: its double quote cannot close them.
        XCTAssertTrue(reason.hasPrefix("grant the key demo for OpenAI at api.openai.com, 24 h, task \"run tests' "),
                      reason)
        XCTAssertTrue(reason.hasSuffix(", 5 min\", project acme"), reason)
        XCTAssertEqual(reason.filter { $0 == "\"" }.count, 2, "only the reason's own quotes")
    }

    /// The same for the profile reason and the renewal reason, which put the stored
    /// task first too.
    func testTheProfileAndRenewalReasonsStripTheTask() throws {
        let provider = try XCTUnwrap(Providers.provider(id: "openai"))
        let task = "ok\n\u{2066}fake\u{2069}\u{200B}"
        let request = try GrantRequest(task: task, minutes: 60).validated()
        let profile = Profile(
            id: "0000000a", name: "ci", keys: ["demo"], methods: ["GET"], paths: [], minutes: 60,
            maxRequests: nil, maxUsd: nil, unattended: false, createdAt: Date(), updatedAt: Date()
        )
        assertPlain(KeysService.profileGrantReason(
            task: request.task, key: "demo", provider: provider, host: "api.openai.com",
            minutes: 60, profile: profile, request: request
        ))
        let store = GrantStore()
        let grant = store.issue(key: "demo", provider: "openai", host: "api.openai.com", request: request).grant
        let renewal = KeysService.renewReason(grant)
        assertPlain(renewal)
        XCTAssertTrue(renewal.hasPrefix("renew the key demo for OpenAI at api.openai.com, 1 h"), renewal)
        XCTAssertTrue(renewal.hasSuffix(", task \"okfake\""), renewal)
    }

    /// The presence gate itself strips control and format scalars from every reason,
    /// so a reason builder that forgets the field sanitizer still cannot show a
    /// newline or a bidi override in the Touch ID sheet.
    func testThePresenceGateStripsEveryReason() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.presence.require(reason: "pair a remote agent as a\nApproved\u{202E}b")
        let reason = try XCTUnwrap(gate.reasons.last)
        assertPlain(reason)
        XCTAssertEqual(reason, "pair a remote agent as a Approvedb")

        // Line and paragraph separators break lines without being controls; a stack
        // of combining marks overdraws the line; an accent still survives.
        XCTAssertEqual(PromptText.plain("a\u{2028}b\u{2029}c"), "a b c")
        let zalgo = "x" + String(repeating: "\u{0301}", count: 50)
        XCTAssertEqual(PromptText.plain(zalgo).unicodeScalars.count, PromptText.maxScalarsPerCharacter)
        XCTAssertEqual(PromptText.plain("café e\u{0301}"), "café é")
        XCTAssertEqual(KeysService.promptTask("tidy up\u{2028}Approved"), "tidy upApproved")
        XCTAssertEqual(KeysService.promptTask(String(repeating: "y", count: 200)).count, 120)
        // Scripts and emoji that need more than a few scalars or a joiner survive.
        XCTAssertEqual(PromptText.plain("स्त्री"), "स्त्री")
        XCTAssertEqual(PromptText.plain("👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦")
        // Blank runs and invisible fillers cannot pad the sheet onto a fake line.
        XCTAssertEqual(PromptText.plain("ok" + String(repeating: "\u{3000}", count: 100) + "x\u{3164}\u{2800}\u{2800}y"),
                       "ok x y")
        XCTAssertEqual(PromptText.plain("a\u{E0041}\u{E0042}b"), "ab", "tag characters are dropped")
        // A lookalike host shows as the punycode name the secret actually goes to.
        XCTAssertEqual(PromptText.host("api.opena\u{0456}.com"), "api.xn--opena-r2e.com")
        XCTAssertEqual(PromptText.host("api.opena\u{0456}.com:8443"), "api.xn--opena-r2e.com:8443")
        XCTAssertEqual(PromptText.host("127.0.0.1:9000"), "127.0.0.1:9000")
        XCTAssertEqual(PromptText.host("evil.example#.api.openai.com"), "evil.example", "only what is dialed")
        XCTAssertEqual(PromptText.host("evil.example?.api.openai.com"), "evil.example")
        XCTAssertEqual(PromptText.host("api.openai.com"), "api.openai.com")
    }

    private func assertPlain(_ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(reason.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                       "no control character reaches the prompt: \(reason.debugDescription)", file: file, line: line)
        XCTAssertFalse(reason.unicodeScalars.contains { $0.properties.generalCategory == .format },
                       "no format scalar (bidi, zero-width) reaches the prompt: \(reason.debugDescription)",
                       file: file, line: line)
    }
}
