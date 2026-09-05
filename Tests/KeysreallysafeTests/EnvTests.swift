import XCTest
@testable import KeysCore

final class EnvTests: XCTestCase {
    func testEnvVarNames() {
        XCTAssertNoThrow(try EnvVar.validate("OPENAI_API_KEY"))
        XCTAssertNoThrow(try EnvVar.validate("_PRIVATE"))
        XCTAssertNoThrow(try EnvVar.validate("A"))
        XCTAssertNoThrow(try EnvVar.validate("http_proxy"))
        XCTAssertEqual(usage { try EnvVar.validate("") }, "environment variable name is missing (example: OPENAI_API_KEY)")
        XCTAssertEqual(
            usage { try EnvVar.validate("$OPENAI_API_KEY") },
            "use OPENAI_API_KEY not $OPENAI_API_KEY — no dollar sign"
        )
        XCTAssertEqual(
            usage { try EnvVar.validate("FOO-BAR") },
            #"invalid environment variable "FOO-BAR" (letters, digits, underscore only, e.g. OPENAI_API_KEY)"#
        )
        XCTAssertEqual(
            usage { try EnvVar.validate("--true") },
            #"invalid environment variable "--true" (letters, digits, underscore only, e.g. OPENAI_API_KEY)"#
        )
        XCTAssertNoThrow(try EnvVar.validate("\u{00A0}OPENAI_API_KEY\u{00A0}"))
        XCTAssertNoThrow(try EnvVar.validate("\"OPENAI_API_KEY\""))
        XCTAssertNoThrow(try EnvVar.validate("`OPENAI_API_KEY`"))
        XCTAssertNoThrow(try EnvVar.validate("“OPENAI_API_KEY”"))
        XCTAssertThrowsError(try EnvVar.validate("1ABC"))
        XCTAssertThrowsError(try EnvVar.validate("FOO=BAR"))
        XCTAssertThrowsError(try EnvVar.validate("FOO BAR"))
    }

    private func usage(_ body: () throws -> Void) -> String {
        do {
            try body()
            XCTFail("expected usage error")
            return ""
        } catch let error as AppError {
            return error.description
        } catch {
            XCTFail("expected AppError, got \(error)")
            return ""
        }
    }

    func testEnvInjectsSecretWithoutClipboardAndTouchesLastUsed() throws {
        let (service, runner, clipboard) = try makeEnvService()
        try service.add(
            name: "xai",
            provider: "xai",
            kind: "runtime",
            notes: "",
            secret: fixtureSecret
        )
        XCTAssertNil(try service.list()[0].lastUsedAt)

        let status = try service.env(
            name: "xai",
            variable: "OPENAI_API_KEY",
            command: ["curl", "https://example.invalid"]
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(runner.lastArgv, ["curl", "https://example.invalid"])
        XCTAssertEqual(runner.lastExtraEnv, ["OPENAI_API_KEY": fixtureSecret])
        XCTAssertNil(clipboard.value)
        XCTAssertNotNil(try service.list()[0].lastUsedAt)
    }

    func testEnvMissingCommandDoesNotSpawn() throws {
        let (service, runner, _) = try makeEnvService()
        try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.env(name: "xai", variable: "FOO", command: [])) { error in
            guard let app = error as? AppError, case .usage = app else {
                return XCTFail("expected usage, got \(error)")
            }
        }
        XCTAssertNil(runner.lastArgv)
    }

    func testUnknownKeyDoesNotPromptPresence() throws {
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let runner = FakeCommandRunner()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: MemorySecretStore(), presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            runner: runner
        )
        XCTAssertThrowsError(try service.env(name: "nosuch", variable: "OPENAI_API_KEY", command: ["true"])) { error in
            guard let app = error as? AppError, case .notFound = app else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertEqual(gate.reasons, [])
        XCTAssertNil(runner.lastArgv)
    }

    func testEnvUnknownKeyDoesNotSpawn() throws {
        let (service, runner, _) = try makeEnvService()
        XCTAssertThrowsError(try service.env(name: "xai", variable: "FOO", command: ["true"])) { error in
            guard let app = error as? AppError, case .notFound = app else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertNil(runner.lastArgv)
    }

    func testEnvPresenceFailureDoesNotSpawn() throws {
        let (db, _) = try makeDB()
        let inner = MemorySecretStore()
        try inner.add(name: "xai", secret: fixtureSecret)
        try db.insertCatalog(CatalogRow(
            name: "xai",
            provider: "xai",
            kind: "runtime",
            notes: "",
            createdAt: "2026-01-01T00:00:00Z",
            lastUsedAt: nil
        ))
        let gate = RecordingPresenceGate()
        gate.error = .authFailed
        let runner = FakeCommandRunner()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: inner, presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            runner: runner
        )
        XCTAssertThrowsError(try service.env(name: "xai", variable: "FOO", command: ["true"])) { error in
            guard let app = error as? AppError, case .authFailed = app else {
                return XCTFail("expected authFailed, got \(error)")
            }
        }
        XCTAssertNil(runner.lastArgv)
        XCTAssertEqual(try inner.get(name: "xai"), fixtureSecret)
    }

    func testEnvPropagatesChildExitStatus() throws {
        let (service, runner, _) = try makeEnvService()
        try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        runner.status = 7
        XCTAssertEqual(try service.env(name: "xai", variable: "FOO", command: ["false"]), 7)
    }

    func testFoundationRunnerInjectsEnvIntoChild() throws {
        let dir = try TempDir.make()
        let out = dir.appendingPathComponent("out")
        let runner = FoundationCommandRunner()
        let status = try runner.run(
            argv: ["/bin/sh", "-c", "printf %s \"$KRS_TEST\" > \"$1\"", "sh", out.path],
            extraEnv: ["KRS_TEST": fixtureSecret]
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), fixtureSecret)
    }

    func testParseEnvCommand() throws {
        let parsed = try KeysCLI.parseAsRoot(["env", "xai", "OPENAI_API_KEY", "--", "curl", "-sS", "https://example.invalid"])
        let env = try XCTUnwrap(parsed as? EnvCommand)
        XCTAssertEqual(env.name, "xai")
        XCTAssertEqual(env.variable, "OPENAI_API_KEY")
        XCTAssertEqual(env.command, ["curl", "-sS", "https://example.invalid"])
    }

    private func makeEnvService() throws -> (KeysService, FakeCommandRunner, FakeClipboard) {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        let clipboard = FakeClipboard()
        let runner = FakeCommandRunner()
        let service = KeysService(
            catalog: db,
            secrets: secrets,
            clipboard: clipboard,
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            runner: runner
        )
        return (service, runner, clipboard)
    }
}
