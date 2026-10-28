import Foundation
import XCTest
@testable import KeysCore

/// `keys wrap`: parsing and rewriting env files, matching values to the vault, and the whole
/// run against an in-memory vault with a recording presence gate (no Keychain, no Touch ID).
/// Every "key" below is built from an obviously fake body so no literal resembles a real one.
final class EnvWrapTests: XCTestCase {
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var openrouterValue: String { "sk-or-" + fakeBody + "02" }
    private var groqValue: String { "gsk_" + fakeBody + "03" }
    private var plainValue: String { "sk-" + fakeBody + "04" }

    // MARK: parsing

    func testParseKeepsEveryLineExactly() {
        let text = """
        # a comment
           # indented comment

        export OPENAI_API_KEY="quoted value" # trailing
        PLAIN = spaced  # inline
        SINGLE='lit $HOME'
        BACK=`tick`
        EMPTY=
        URL=http://example.test/#frag
        not an assignment
        1BAD=x
        """
        let file = EnvFile.parse(text)
        XCTAssertEqual(file.render(), text + "\n", "only the missing final newline is added")
        let byName = Dictionary(file.entries.map { ($0.entry.name, $0.entry) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["OPENAI_API_KEY"]?.value, "quoted value")
        XCTAssertEqual(byName["OPENAI_API_KEY"]?.quote, "\"")
        XCTAssertEqual(byName["PLAIN"]?.value, "spaced")
        XCTAssertEqual(byName["SINGLE"]?.value, "lit $HOME")
        XCTAssertEqual(byName["BACK"]?.value, "tick")
        XCTAssertEqual(byName["EMPTY"]?.value, "")
        XCTAssertEqual(byName["URL"]?.value, "http://example.test/#frag", "a # without a space before it is part of the value")
        XCTAssertNil(byName["1BAD"])
        XCTAssertEqual(file.entries.count, 6)
    }

    func testParseKeepsCRLFAndMultilineValues() {
        let text = "A=1\r\nPEM=\"-----BEGIN-----\r\nINNER_KEY=\(anthropicValue)\r\n-----END-----\"\r\nB=2"
        let file = EnvFile.parse(text)
        XCTAssertEqual(file.render(), text + "\r\n")
        XCTAssertNil(file.entries.first { $0.entry.name == "INNER_KEY" }, "a line inside a quoted value is not an assignment")
        XCTAssertTrue(WrapDetect.candidates(in: file, nameHint: nil).isEmpty)
        // An unclosed quote leaves everything as written and unparsed.
        let broken = "X=\"open\nY=\(anthropicValue)\n"
        XCTAssertEqual(EnvFile.parse(broken).render(), broken)
        XCTAssertTrue(EnvFile.parse(broken).entries.isEmpty)
    }

    func testSetValueKeepsQuotesExportAndComment() {
        var file = EnvFile.parse("export K=\"old\" # note\nJ=old2 # c\n")
        file.setValue(at: 0, "new")
        file.setValue(at: 1, "new2")
        XCTAssertEqual(file.render(), "export K=\"new\" # note\nJ=new2 # c\n")
    }

    func testUpsertAppendsAfterAFileWithoutTrailingNewline() {
        var file = EnvFile.parse("A=1\nB=2")
        file.upsert(name: "C", value: "3")
        XCTAssertEqual(file.render(), "A=1\nB=2\nC=3\n", "the appended line never glues onto the last one")
        file.upsert(name: "A", value: "9")
        XCTAssertEqual(file.render(), "A=9\nB=2\nC=3\n")
        XCTAssertEqual(EnvFile.parse("").render(), "")
    }

    // MARK: detection

    func testDetectionUsesNamePrefixAndBaseURL() {
        let text = """
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_API_KEY=\(openrouterValue)
        MY_FAST_ONE=\(groqValue)
        DEEPSEEK_API_KEY=\(plainValue)
        STRIPE_SECRET_KEY=sk_\(fakeBody)
        ALREADY=ksfc_\(String(repeating: "a", count: 48))
        SHORT_KEY=abc
        DATABASE_URL=postgres://u:p@h/db
        REF_KEY=${OTHER_KEY_VALUE_FROM_ENV}
        DEBUG=true
        """
        let found = WrapDetect.candidates(in: EnvFile.parse(text), nameHint: nil)
        let map = Dictionary(found.map { ($0.candidate.variable, $0.candidate.provider) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(Set(map.keys), ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "MY_FAST_ONE", "DEEPSEEK_API_KEY", "STRIPE_SECRET_KEY"])
        XCTAssertEqual(map["ANTHROPIC_API_KEY"], "anthropic")
        XCTAssertEqual(map["OPENAI_API_KEY"], "openrouter", "the specific sk-or- prefix beats the variable's family")
        XCTAssertEqual(map["MY_FAST_ONE"], "groq", "a distinctive prefix is enough on its own")
        XCTAssertEqual(map["DEEPSEEK_API_KEY"], "deepseek", "an ambiguous sk- defers to the name")
        XCTAssertEqual(map["STRIPE_SECRET_KEY"], .some(nil), "a short prefix alone names no provider")

        let viaURL = WrapDetect.candidates(
            in: EnvFile.parse("OPENAI_BASE_URL=https://api.deepseek.com/v1\nOPENAI_API_KEY=\(plainValue)\n"), nameHint: nil
        )
        XCTAssertEqual(viaURL.first?.candidate.provider, "deepseek")
    }

    func testSuggestedNames() {
        XCTAssertEqual(WrapNames.suggest(provider: "anthropic", hint: "My App", taken: []), "anthropic")
        XCTAssertEqual(WrapNames.suggest(provider: "anthropic", hint: "My App", taken: ["anthropic"]), "anthropic-my-app")
        XCTAssertEqual(
            WrapNames.suggest(provider: "anthropic", hint: "My App", taken: ["anthropic", "anthropic-my-app"]), "anthropic-2"
        )
        XCTAssertNoThrow(try KeyName.validate(WrapNames.suggest(provider: "x", hint: "Ünïcode ✓ dir", taken: ["x"])))
    }

    // MARK: matching

    func testPlanMatchesExistingAndProposesNewWithOnePrompt() throws {
        let (service, gate, _) = try makeVault()
        try service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        let plan = try service.wrapPlan(file: "x.env", candidates: [
            WrapCandidate(variable: "OPENAI_API_KEY", value: openrouterValue, provider: "openai"),
            WrapCandidate(variable: "ANTHROPIC_API_KEY", value: anthropicValue, provider: "anthropic", nameHint: "proj"),
            WrapCandidate(variable: "SECOND_COPY_KEY", value: anthropicValue, provider: nil),
            WrapCandidate(variable: "MYSTERY_KEY", value: "zz" + fakeBody, provider: nil),
        ])
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertEqual(plan.items[0], .init(variable: "OPENAI_API_KEY", key: "router", provider: "openrouter", isNew: false, skip: nil,
                                            host: Providers.provider(id: "openrouter")?.host))
        XCTAssertEqual(plan.items[1], .init(variable: "ANTHROPIC_API_KEY", key: "anthropic", provider: "anthropic", isNew: true, skip: nil,
                                            host: Providers.provider(id: "anthropic")?.host))
        XCTAssertEqual(plan.items[2].key, "anthropic", "the same value twice becomes one new key")
        XCTAssertNil(plan.items[3].key)
        XCTAssertNotNil(plan.items[3].skip)
        let blob = String(data: try JSONValue.data(plan.jsonObject()), encoding: .utf8)!
        XCTAssertFalse(blob.contains(fakeBody), "the plan carries names only")
        XCTAssertEqual(try service.list().map(\.name), ["router"], "planning adds nothing")
    }

    func testPlanRefusedWithoutPresence() throws {
        let (service, gate, _) = try makeVault()
        gate.error = .authCancelled
        XCTAssertThrowsError(try service.wrapPlan(file: "x.env", candidates: [
            WrapCandidate(variable: "ANTHROPIC_API_KEY", value: anthropicValue, provider: "anthropic"),
        ]))
    }

    func testApplyIsSingleUseAndExpires() throws {
        let (service, _, _) = try makeVault()
        let now = Date()
        let plan = try service.wrapPlan(
            file: "x.env", candidates: [WrapCandidate(variable: "ANTHROPIC_API_KEY", value: anthropicValue, provider: "anthropic")],
            now: now
        )
        XCTAssertThrowsError(try service.wrapApply(id: plan.id, now: now.addingTimeInterval(WrapPlan.lifetime + 1)))
        XCTAssertThrowsError(try service.wrapApply(id: plan.id, now: now), "an expired plan is gone, not retried")
        XCTAssertTrue(try service.list().isEmpty)
    }

    func testApplyRefusesAKeyRetargetedAfterThePlan() throws {
        let (service, _, _) = try makeVault()
        try service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        let plan = try service.wrapPlan(file: "x.env", candidates: [
            WrapCandidate(variable: "OPENROUTER_API_KEY", value: openrouterValue, provider: "openrouter"),
        ])
        XCTAssertEqual(plan.items[0].host, Providers.provider(id: "openrouter")?.host, "the plan shows where the key will go")
        _ = try service.patch(name: "router", provider: nil, kind: nil, notes: nil, host: "keys.attacker.example", updateHost: true)
        XCTAssertThrowsError(try service.wrapApply(id: plan.id), "the yes covered the old host only")
        XCTAssertTrue(try service.gatewayClients(name: "router").isEmpty)
        XCTAssertFalse(service.isGatewayEnabled("router"))
    }

    // MARK: the whole run

    func testRunRewritesFileWithOnePromptAndNoValuesOnScreen() throws {
        let (service, gate, dir) = try makeVault()
        try service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        let env = dir.appendingPathComponent("proj/.env")
        try FileManager.default.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        # agent config
        export OPENAI_API_KEY="\(openrouterValue)" # router
        ANTHROPIC_API_KEY=\(anthropicValue)
        DEBUG=1
        """  // no trailing newline on purpose
        try Data(original.utf8).write(to: env)
        chmod(env.path, 0o640)

        var lines: [String] = []
        let runner = WrapRunner(backend: ServiceWrapBackend(service: service), out: { lines.append($0) }, confirm: { true })
        let summary = try runner.run(.init(file: env))

        XCTAssertEqual(gate.reasons.count, 1, "one presence prompt for the whole batch")
        XCTAssertTrue(summary.changed)
        let text = try String(contentsOf: env, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains(fakeBody), "no original value is left in the file")
        let file = EnvFile.parse(text)
        let openai = try XCTUnwrap(file.value(of: "OPENAI_API_KEY"))
        let anthropic = try XCTUnwrap(file.value(of: "ANTHROPIC_API_KEY"))
        XCTAssertTrue(GatewayClientToken.looksLikeToken(openai))
        XCTAssertTrue(GatewayClientToken.looksLikeToken(anthropic))
        XCTAssertTrue(text.contains("export OPENAI_API_KEY=\"ksfc_"), "export and quotes are kept")
        XCTAssertTrue(text.contains("\" # router\n"), "the inline comment is kept")
        XCTAssertTrue(text.hasPrefix("# agent config\n"))
        XCTAssertEqual(file.value(of: "OPENAI_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/router")
        XCTAssertEqual(file.value(of: "ANTHROPIC_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/anthropic")
        XCTAssertTrue(text.contains("DEBUG=1\nOPENAI_BASE_URL=") || text.contains("DEBUG=1\nANTHROPIC_BASE_URL="),
                      "appended variables start on their own line")
        XCTAssertEqual(try EnvFileWriter.currentMode(env), 0o640, "permissions are kept")

        let backup = try XCTUnwrap(summary.backup)
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
        XCTAssertEqual(try EnvFileWriter.currentMode(backup), 0o600)

        XCTAssertEqual(Set(try service.list().map(\.name)), ["router", "anthropic"])
        XCTAssertTrue(service.isGatewayEnabled("router"))
        XCTAssertTrue(service.isGatewayEnabled("anthropic"))
        XCTAssertEqual(try service.gatewayClients(name: "router").count, 1)
        XCTAssertEqual(try service.gatewayClients(name: "router")[0].methods.sorted(), ["GET", "POST"])
        if case .allowed = service.authorizeGatewayClient(
            name: "anthropic", headers: ["x-api-key": anthropic], method: "POST", rest: "/v1/messages"
        ) {} else { XCTFail("the written token authorizes its key") }

        let screen = lines.joined(separator: "\n")
        XCTAssertFalse(screen.contains(fakeBody), "values never reach the terminal")
        XCTAssertFalse(screen.contains("ksfc_"), "tokens are written to the file, not printed")
        XCTAssertTrue(screen.contains("OPENAI_API_KEY -> router"))
        assertNoSentinel(fakeBody, in: dir.appendingPathComponent("catalog.db").deletingLastPathComponent(), skipping: [env, backup])
    }

    func testRunAgainFindsNothing() throws {
        let (service, gate, dir) = try makeVault()
        let env = dir.appendingPathComponent(".env")
        try Data("ANTHROPIC_API_KEY=\(anthropicValue)\n".utf8).write(to: env)
        let runner = WrapRunner(backend: ServiceWrapBackend(service: service), out: { _ in }, confirm: { true })
        _ = try runner.run(.init(file: env))
        let after = try Data(contentsOf: env)
        let again = try runner.run(.init(file: env))
        XCTAssertFalse(again.changed)
        XCTAssertEqual(try Data(contentsOf: env), after)
        XCTAssertEqual(gate.reasons.count, 1, "nothing to compare means no prompt")
    }

    func testDryRunAndDeclineChangeNothing() throws {
        for mode in ["dry-run", "decline"] {
            let (service, _, dir) = try makeVault()
            let env = dir.appendingPathComponent(".env")
            let original = Data("ANTHROPIC_API_KEY=\(anthropicValue)".utf8)
            try original.write(to: env)
            var options = WrapRunner.Options(file: env)
            options.dryRun = mode == "dry-run"
            let backend = RecordingBackend(service: service)
            let runner = WrapRunner(backend: backend, out: { _ in }, confirm: { false })
            let summary = try runner.run(options)
            XCTAssertFalse(summary.changed, mode)
            XCTAssertEqual(try Data(contentsOf: env), original, mode)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("keysrs") }, [], mode)
            XCTAssertTrue(try service.list().isEmpty, mode)
            XCTAssertFalse(service.isGatewayEnabled("anthropic"), mode)
            XCTAssertEqual(backend.cancelled.count, 1, "\(mode) drops the pending plan and its in-memory value")
            XCTAssertThrowsError(try service.wrapApply(id: backend.cancelled[0]), mode)
        }
    }

    func testRelayBaseURL() throws {
        let (service, _, dir) = try makeVault()
        let env = dir.appendingPathComponent("relay.env")
        try Data("OPENAI_API_KEY=\(openrouterValue)\nOPENAI_BASE_URL=https://openrouter.ai/api/v1\n".utf8).write(to: env)
        var options = WrapRunner.Options(file: env)
        options.relay = try RelayURL.validate("https://relay.example.workers.dev")
        _ = try WrapRunner(backend: ServiceWrapBackend(service: service), out: { _ in }, confirm: { true }).run(options)
        let file = EnvFile.parse(try String(contentsOf: env, encoding: .utf8))
        XCTAssertEqual(file.value(of: "OPENAI_BASE_URL"), "https://relay.example.workers.dev/openrouter")
        XCTAssertEqual(file.entries.filter { $0.entry.name == "OPENAI_BASE_URL" }.count, 1, "replaced, not duplicated")
    }

    func testRewriteRefusesAFileThatChangedUnderIt() throws {
        let dir = try TempDir.make()
        let env = dir.appendingPathComponent(".env")
        try Data("A=1\n".utf8).write(to: env)
        XCTAssertThrowsError(try EnvFileWriter.rewrite(env, original: Data("A=0\n".utf8), text: "A=2\n"))
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "A=1\n")
    }

    // MARK: client issue and the gateway route

    func testClientIssueCanTurnTheGatewayOnUnderOnePrompt() throws {
        let (service, gate, _) = try makeVault()
        try service.add(name: "claude", provider: "anthropic", kind: "runtime", notes: "", secret: anthropicValue)
        _ = try service.issueGatewayClient(name: "claude", label: "t", enableGateway: true)
        XCTAssertEqual(gate.reasons, ["issue gateway client for claude at api.anthropic.com"])
        XCTAssertTrue(service.isGatewayEnabled("claude"))
        _ = try service.issueGatewayClient(name: "claude", label: "t2")
        XCTAssertEqual(gate.reasons.count, 2)
    }

    func testWrapRoutesCarryNamesAndTokensOnly() throws {
        let (handler, service, _) = try makeHandler()
        let body = try JSONValue.data([
            "file": ".env",
            "candidates": [["variable": "ANTHROPIC_API_KEY", "value": anthropicValue, "provider": "anthropic"]],
        ])
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/wrap", body: body, token: false).status, 403)
        let planned = handle(handler, method: "POST", path: "/api/wrap", body: body)
        XCTAssertEqual(planned.status, 200)
        XCTAssertFalse(String(decoding: planned.body, as: UTF8.self).contains(fakeBody))
        let plan = try WrapPlan(json: JSONValue.object(try JSONSerialization.jsonObject(with: planned.body))!)
        let applied = handle(handler, method: "POST", path: "/api/wrap/\(plan.id)", body: Data("{}".utf8))
        XCTAssertEqual(applied.status, 201)
        let text = String(decoding: applied.body, as: UTF8.self)
        XCTAssertFalse(text.contains(fakeBody))
        XCTAssertTrue(text.contains("ksfc_"))
        XCTAssertTrue(service.isGatewayEnabled("anthropic"))
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/wrap/\(plan.id)", body: Data("{}".utf8)).status, 400)
        XCTAssertEqual(handle(handler, method: "DELETE", path: "/api/wrap/not-an-id").status, 404)
    }

    // MARK: helpers

    private func makeVault() throws -> (KeysService, RecordingPresenceGate, URL) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        return (service, gate, dir)
    }

    private func assertNoSentinel(_ needle: String, in dir: URL, skipping: [URL], file: StaticString = #filePath, line: UInt = #line) {
        let skip = Set(skipping.map { $0.resolvingSymlinksInPath().path })
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard !skip.contains(url.resolvingSymlinksInPath().path), let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: Data(needle.utf8)), "\(url.lastPathComponent) holds a value", file: file, line: line)
        }
    }
}

/// Passes through to the service and remembers which plans were dropped.
private final class RecordingBackend: WrapBackend {
    let inner: ServiceWrapBackend
    var cancelled: [String] = []
    init(service: KeysService) { inner = ServiceWrapBackend(service: service) }
    func plan(file: String, path: String?, candidates: [WrapCandidate]) throws -> WrapPlan {
        try inner.plan(file: file, path: path, candidates: candidates)
    }
    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued] { try inner.apply(id: id, label: label, days: days) }
    func cancel(id: String) {
        cancelled.append(id)
        inner.cancel(id: id)
    }
}
