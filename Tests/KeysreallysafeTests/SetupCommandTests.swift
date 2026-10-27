import XCTest
@testable import KeysCore

/// `keys setup --json` is the machine-readable report of the one agent-facing write. It
/// names the config file that was written, the environment variable the launcher fills
/// with a token, and the gateway URL — the facts a script needs to verify the step
/// without parsing prose. Claude Code writes no file, so its `config_path` is null and
/// the two variables it reads at launch stand in for it. A key the agent's config does
/// not carry is left out rather than guessed, and nothing here — line or file — may
/// hold a secret.
final class SetupCommandTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try TempDir.make().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: parsing

    func testParseSetupCommandWithJSONFlag() throws {
        let command = try XCTUnwrap(
            try KeysCLI.parseAsRoot(["setup", "droid", "--key", "work", "--json"]) as? SetupCommand
        )
        XCTAssertTrue(command.json)
        let human = try XCTUnwrap(try KeysCLI.parseAsRoot(["setup", "droid", "--key", "work"]) as? SetupCommand)
        XCTAssertFalse(human.json, "the human path is the default")
    }

    // MARK: one agent each, on a temp home

    func testDroidJSONNamesWhatItWrote() throws {
        try DroidSetup.upsert(
            home: home, key: "work", port: 12767, model: "claude-sonnet-4-5-20250929",
            displayName: "Keysrs work", providerKind: "anthropic", liveKeyNames: ["work"]
        )
        let line = try jsonLine(SetupCommand.Report(
            agent: .droid, key: "work", port: 12767,
            configPath: DroidSetup.settingsURL(home: home).path,
            model: "claude-sonnet-4-5-20250929", wire: "anthropic", displayName: "Keysrs work"
        ))
        let object = try parsed(line)
        XCTAssertEqual(Set(object.keys), [
            "agent", "base_url", "config_path", "display_name", "model", "token_env", "wire",
        ])
        XCTAssertEqual(object["agent"] as? String, "droid")
        XCTAssertEqual(object["config_path"] as? String, DroidSetup.settingsURL(home: home).path)
        XCTAssertEqual(object["token_env"] as? String, "KEYSRS_DROID_TOKEN")
        XCTAssertEqual(object["base_url"] as? String, "http://127.0.0.1:12767/work")
        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(object["wire"] as? String, "anthropic")
        XCTAssertEqual(object["display_name"] as? String, "Keysrs work")
        // The file the JSON points at holds the same two facts and nothing else.
        let raw = String(decoding: try Data(contentsOf: DroidSetup.settingsURL(home: home)), as: UTF8.self)
        XCTAssertTrue(raw.contains("http://127.0.0.1:12767/work"))
        XCTAssertTrue(raw.contains("KEYSRS_DROID_TOKEN"))
        XCTAssertFalse(raw.contains("fixtureSecret"), "no vault secret may land in Droid's settings")
        XCTAssertFalse(line.contains("fixtureSecret"))
    }

    func testCodexJSONReportsTheModelOnlyWhenItIsWritten() throws {
        try CodexSetup.upsert(home: home, key: "router", port: 12767, wire: "chat", setDefault: false, model: nil)
        let plain = try jsonLine(SetupCommand.Report(
            agent: .codex, key: "router", port: 12767,
            configPath: CodexSetup.configURL(home: home).path, model: nil, wire: "chat",
            setDefault: false
        ))
        let plainObject = try parsed(plain)
        XCTAssertEqual(Set(plainObject.keys), ["agent", "base_url", "config_path", "set_default", "token_env", "wire"])
        XCTAssertEqual(plainObject["set_default"] as? Bool, false)
        XCTAssertNil(plainObject["model"] as Any?, "without --set-default no model is written, so none is reported")

        try CodexSetup.upsert(home: home, key: "router", port: 12767, wire: "chat", setDefault: true, model: "vendor/x")
        let defaulted = try jsonLine(SetupCommand.Report(
            agent: .codex, key: "router", port: 12767,
            configPath: CodexSetup.configURL(home: home).path, model: "vendor/x", wire: "chat",
            setDefault: true
        ))
        let defaultedObject = try parsed(defaulted)
        XCTAssertEqual(Set(defaultedObject.keys), [
            "agent", "base_url", "config_path", "model", "set_default", "token_env", "wire",
        ])
        XCTAssertEqual(defaultedObject["set_default"] as? Bool, true)
        XCTAssertEqual(defaultedObject["model"] as? String, "vendor/x")
        for object in [plainObject, defaultedObject] {
            XCTAssertEqual(object["agent"] as? String, "codex")
            XCTAssertEqual(object["config_path"] as? String, CodexSetup.configURL(home: home).path)
            XCTAssertEqual(object["token_env"] as? String, "KEYSRS_CODEX_TOKEN")
            XCTAssertEqual(object["base_url"] as? String, "http://127.0.0.1:12767/router")
            XCTAssertEqual(object["wire"] as? String, "chat")
        }
        let raw = String(decoding: try Data(contentsOf: CodexSetup.configURL(home: home)), as: UTF8.self)
        XCTAssertTrue(raw.contains("env_key = \"KEYSRS_CODEX_TOKEN\""))
        XCTAssertFalse(raw.contains("fixtureSecret"), "no vault secret may land in Codex's config")
        XCTAssertFalse(plain.contains("fixtureSecret") || defaulted.contains("fixtureSecret"))
    }

    func testGrokJSONNamesWhatItWrote() throws {
        try GrokSetup.upsert(home: home, key: "xai-key", port: 12767, model: "grok-4.6")
        let line = try jsonLine(SetupCommand.Report(
            agent: .grok, key: "xai-key", port: 12767,
            configPath: GrokSetup.configURL(home: home).path, model: "grok-4.6"
        ))
        let object = try parsed(line)
        XCTAssertEqual(Set(object.keys), ["agent", "base_url", "config_path", "model", "token_env"])
        XCTAssertEqual(object["agent"] as? String, "grok")
        XCTAssertEqual(object["config_path"] as? String, GrokSetup.configURL(home: home).path)
        XCTAssertEqual(object["token_env"] as? String, "KEYSRS_GROK_TOKEN")
        XCTAssertEqual(object["base_url"] as? String, "http://127.0.0.1:12767/xai-key")
        XCTAssertEqual(object["model"] as? String, "grok-4.6")
        let raw = String(decoding: try Data(contentsOf: GrokSetup.configURL(home: home)), as: UTF8.self)
        XCTAssertTrue(raw.contains("env_key = \"KEYSRS_GROK_TOKEN\""))
        XCTAssertFalse(raw.contains("fixtureSecret"), "no vault secret may land in Grok's config")
        XCTAssertFalse(line.contains("fixtureSecret"))
    }

    func testClaudeJSONNamesItsLaunchVariablesInsteadOfAFile() throws {
        // Claude Code gets no config file; setup's report is the pair it reads at launch.
        let line = try jsonLine(SetupCommand.Report(agent: .claude, key: "work", port: 12767))
        let object = try parsed(line)
        XCTAssertEqual(Set(object.keys), ["agent", "base_url", "base_url_env", "config_path", "token_env"])
        XCTAssertEqual(object["agent"] as? String, "claude")
        XCTAssertTrue(object["config_path"] is NSNull, "claude writes no file, and the line says so")
        XCTAssertEqual(object["token_env"] as? String, "ANTHROPIC_AUTH_TOKEN")
        XCTAssertEqual(object["base_url_env"] as? String, "ANTHROPIC_BASE_URL")
        XCTAssertEqual(object["base_url"] as? String, "http://127.0.0.1:12767/work")
    }

    // MARK: helpers

    /// The JSON line for one report: one line, the shape every `--json` flag prints.
    private func jsonLine(_ report: SetupCommand.Report) throws -> String {
        let line = String(decoding: try JSONValue.data(SetupCommand.jsonObject(report)), as: UTF8.self)
        XCTAssertFalse(line.contains("\n"), "one line, the shape every --json flag prints")
        return line
    }

    /// The parsed line, pinned to sorted keys: re-serializing it reproduces it byte for byte.
    private func parsed(_ line: String) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(try JSONValue.data(object), Data(line.utf8), "keys must be sorted")
        return object
    }
}
