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
        XCTAssertEqual(status, .exited(0))
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
        let runner = FakeCommandRunner()
        let (service, gate) = makeGatedService(db: db, runner: runner)
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
        let runner = FakeCommandRunner()
        let (service, _) = makeGatedService(
            db: db, secrets: inner, gate: RecordingPresenceGate(error: .authFailed), runner: runner
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
        runner.exit = .exited(7)
        XCTAssertEqual(try service.env(name: "xai", variable: "FOO", command: ["false"]), .exited(7))
        runner.exit = .signaled(SIGINT)
        XCTAssertEqual(try service.env(name: "xai", variable: "FOO", command: ["sleep", "9"]).status, 130)
    }

    func testSpawnRunnerInjectsEnvIntoChild() throws {
        let dir = try TempDir.make()
        let out = dir.appendingPathComponent("out")
        let runner = SpawnCommandRunner(restoresHandlers: true)
        let status = try runner.run(
            argv: ["/bin/sh", "-c", "printf %s \"$KRS_TEST\" > \"$1\"", "sh", out.path],
            extraEnv: ["KRS_TEST": fixtureSecret]
        )
        XCTAssertEqual(status, .exited(0))
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), fixtureSecret)
    }

    func testParseEnvCommand() throws {
        let (pairs, command) = try parseEnv(["xai", "OPENAI_API_KEY", "--", "curl", "-sS", "https://example.invalid"])
        XCTAssertEqual(pairs, [EnvPair(name: "xai", variable: "OPENAI_API_KEY")])
        XCTAssertEqual(command, ["curl", "-sS", "https://example.invalid"])
    }

    func testParseEnvCommandTakesSeveralPairs() throws {
        let (pairs, command) = try parseEnv([
            "modal-id", "MODAL_TOKEN_ID", "modal-secret", "MODAL_TOKEN_SECRET", "--", "bun", "run", "--watch", "batch.ts",
        ])
        XCTAssertEqual(pairs, [
            EnvPair(name: "modal-id", variable: "MODAL_TOKEN_ID"),
            EnvPair(name: "modal-secret", variable: "MODAL_TOKEN_SECRET"),
        ])
        XCTAssertEqual(command, ["bun", "run", "--watch", "batch.ts"])

        // The first -- ends keys' own arguments; a nested keys env keeps its own.
        let nested = try parseEnv(["a", "A", "--", "keys", "env", "b", "B", "--", "bun", "x.ts"])
        XCTAssertEqual(nested.pairs, [EnvPair(name: "a", variable: "A")])
        XCTAssertEqual(nested.command, ["keys", "env", "b", "B", "--", "bun", "x.ts"])
    }

    func testParseEnvCommandRefusesWhatItWouldHaveToGuess() throws {
        let grammar = "(keys env <name> <variable> [<name> <variable> ...] -- <command>)"
        // Without --, "b B cmd" could be a pair and a command or the command itself.
        XCTAssertEqual(usage { _ = try self.parseEnv(["a", "A", "b", "B", "cmd"]) }, "missing command after -- \(grammar)")
        XCTAssertEqual(usage { _ = try self.parseEnv(["a", "A", "--"]) }, "missing command after -- \(grammar)")
        XCTAssertEqual(
            usage { _ = try self.parseEnv(["a", "A", "b", "--", "cmd"]) },
            "b has no variable; keys env takes <name> <variable> pairs before --"
        )
        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["env", "a"]))
    }

    func testEnvSetsSeveralVariablesUnderOnePresencePrompt() throws {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        let runner = FakeCommandRunner()
        let (service, gate) = makeGatedService(db: db, secrets: secrets, runner: runner)
        try service.add(name: "modal-id", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "modal-secret", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret + "2")

        let status = try service.env(
            pairs: [
                EnvPair(name: "modal-id", variable: "MODAL_TOKEN_ID"),
                EnvPair(name: "modal-secret", variable: "MODAL_TOKEN_SECRET"),
                EnvPair(name: "modal-id", variable: "\"MODAL_ID_AGAIN\""),
            ],
            command: ["bun", "batch.ts"]
        )
        XCTAssertEqual(status, .exited(0))
        XCTAssertEqual(gate.reasons, ["unlock 2 keys: modal-id and modal-secret"])
        XCTAssertEqual(runner.lastArgv, ["bun", "batch.ts"])
        XCTAssertEqual(runner.lastExtraEnv, [
            "MODAL_TOKEN_ID": fixtureSecret,
            "MODAL_TOKEN_SECRET": fixtureSecret + "2",
            "MODAL_ID_AGAIN": fixtureSecret,
        ])
        // One env event per key, as a single keys env writes, and both keys marked used.
        for name in ["modal-id", "modal-secret"] {
            XCTAssertEqual(try service.keyEvents(name: name).filter { $0.action == "env" }.map(\.caller), ["env"], name)
        }
        XCTAssertTrue(try service.list().allSatisfy { $0.lastUsedAt != nil })
    }

    func testEnvMissingKeyAmongSeveralRunsNothingAndDoesNotPrompt() throws {
        let (db, _) = try makeDB()
        let runner = FakeCommandRunner()
        let (service, gate) = makeGatedService(db: db, runner: runner)
        try service.add(name: "modal-id", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.env(
            pairs: [EnvPair(name: "modal-id", variable: "A"), EnvPair(name: "modal-secret", variable: "B")],
            command: ["true"]
        )) { error in
            guard let app = error as? AppError, case .notFound("modal-secret") = app else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertEqual(gate.reasons, [])
        XCTAssertNil(runner.lastArgv)
        XCTAssertNil(try service.list()[0].lastUsedAt)
        XCTAssertEqual(try service.keyEvents(name: "modal-id").filter { $0.action == "env" }, [])
    }

    func testEnvUnreadableKeyAmongSeveralRunsNothing() throws {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        let runner = FakeCommandRunner()
        let (service, gate) = makeGatedService(db: db, secrets: secrets, runner: runner)
        try service.add(name: "modal-id", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        // A catalog row whose Keychain item is gone.
        try db.insertCatalog(CatalogRow(
            name: "modal-secret", provider: "xai", kind: "runtime", notes: "",
            createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil
        ))
        XCTAssertThrowsError(try service.env(
            pairs: [EnvPair(name: "modal-id", variable: "A"), EnvPair(name: "modal-secret", variable: "B")],
            command: ["true"]
        ))
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertNil(runner.lastArgv)
        XCTAssertEqual(try service.keyEvents(name: "modal-id").filter { $0.action == "env" }, [])
    }

    func testEnvRefusesTheSameVariableTwice() throws {
        let (service, runner, _) = try makeEnvService()
        try service.add(name: "a", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "b", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(
            usage {
                _ = try service.env(pairs: [EnvPair(name: "a", variable: "X"), EnvPair(name: "b", variable: "`X`")], command: ["true"])
            },
            "X is given twice"
        )
        XCTAssertNil(runner.lastArgv)
    }

    func testPresenceReasonNamesEveryKey() {
        XCTAssertEqual(KeysService.unlockReason(["a"]), "unlock a")
        XCTAssertEqual(KeysService.unlockReason(["a", "b"]), "unlock 2 keys: a and b")
        XCTAssertEqual(KeysService.unlockReason(["a", "b", "c"]), "unlock 3 keys: a, b and c")
    }

    private func parseEnv(_ arguments: [String]) throws -> (pairs: [EnvPair], command: [String]) {
        let parsed = try KeysCLI.parseAsRoot(["env"] + arguments)
        return try XCTUnwrap(parsed as? EnvCommand).parsed()
    }

    private func makeEnvService() throws -> (KeysService, FakeCommandRunner, FakeClipboard) {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        let clipboard = FakeClipboard()
        let runner = FakeCommandRunner()
        let (service, _) = makeGatedService(db: db, secrets: secrets, clipboard: clipboard, runner: runner)
        return (service, runner, clipboard)
    }
}
