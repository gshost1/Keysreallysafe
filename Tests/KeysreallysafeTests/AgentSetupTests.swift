import XCTest
@testable import KeysCore

/// Config files written for other programs: TOML section surgery, the Droid settings merge,
/// and the tunnel command. All of it must stay secret-free.
final class AgentSetupTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try TempDir.make().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: - TOML

    func testTOMLUpsertReplacesAnOwnedSectionAndLeavesTheRestAlone() {
        let before = """
        model = "grok-4.6"

        [ui]
        theme = "tokyonight"

        [model.keysrs]
        model = "old-model"
        base_url = "http://127.0.0.1:12767/old"

        [models]
        default = "grok-4.6"
        """
        let after = TOMLFile.upsertSection(
            before,
            header: "model.keysrs",
            bodyLines: GrokSetup.sectionBody(key: "work", port: 12767, model: "grok-4.6")
        )
        XCTAssertTrue(after.contains("base_url = \"http://127.0.0.1:12767/work\""))
        XCTAssertFalse(after.contains("old-model"))
        XCTAssertEqual(after.components(separatedBy: "\n").filter { $0.contains("[model.keysrs]") }.count, 1)
        // Neighbouring sections and top-level keys are untouched.
        XCTAssertTrue(after.contains("theme = \"tokyonight\""))
        XCTAssertTrue(after.contains("default = \"grok-4.6\""))
        XCTAssertTrue(after.hasPrefix("model = \"grok-4.6\""))
    }

    func testTOMLUpsertAppendsWhenTheSectionIsMissing() {
        let before = "[ui]\ntheme = \"tokyonight\"\n"
        let after = TOMLFile.upsertSection(
            before, header: "model.keysrs",
            bodyLines: ["model = \"grok-4.6\"", "base_url = \"http://127.0.0.1:12767/work\""]
        )
        XCTAssertTrue(after.hasPrefix(before))
        XCTAssertTrue(after.contains("[model.keysrs]"))
        XCTAssertTrue(after.contains("base_url = \"http://127.0.0.1:12767/work\""))
    }

    func testTOMLTopLevelKeyReplacesOrInsertsAboveTheFirstHeader() {
        let before = "model = \"gpt-6-astra\"\n\n[projects.x]\ntrust_level = \"trusted\"\n"
        let replaced = TOMLFile.upsertTopLevelKey(before, line: "model = \"claude-sonnet-4-5\"", key: "model")
        XCTAssertTrue(replaced.contains("model = \"claude-sonnet-4-5\""))
        XCTAssertEqual(replaced.components(separatedBy: "\n").filter { $0.hasPrefix("model =") }.count, 1)
        XCTAssertTrue(replaced.contains("[projects.x]"))

        let added = TOMLFile.upsertTopLevelKey(before, line: "model_provider = \"keysrs\"", key: "model_provider")
        // The new key must land above the first section header, not necessarily on line one.
        let addedLines = added.components(separatedBy: "\n")
        let providerAt = addedLines.firstIndex(of: "model_provider = \"keysrs\"")
        let headerAt = addedLines.firstIndex(of: "[projects.x]")
        XCTAssertNotNil(providerAt)
        XCTAssertNotNil(headerAt)
        XCTAssertLessThan(providerAt!, headerAt!)
        XCTAssertTrue(added.contains("model = \"gpt-6-astra\""))

        let empty = TOMLFile.upsertTopLevelKey("", line: "model = \"x\"", key: "model")
        XCTAssertTrue(empty.hasPrefix("model = \"x\""))
    }

    // MARK: - Droid settings.json

    func testDroidUpsertWritesAnEnvReferenceNeverASecret() throws {
        try DroidSetup.upsert(
            home: home, key: "anthropic-work", port: 12767, model: "claude-sonnet-4-5-20250929",
            displayName: "Keysrs anthropic-work", providerKind: "anthropic", liveKeyNames: ["anthropic-work"]
        )
        let url = DroidSetup.settingsURL(home: home)
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let models = obj["customModels"] as! [[String: Any]]
        XCTAssertEqual(models.count, 1)
        let entry = models[0]
        XCTAssertEqual(entry["baseUrl"] as? String, "http://127.0.0.1:12767/anthropic-work")
        XCTAssertEqual(entry["apiKey"] as? String, "${KEYSRS_DROID_TOKEN}")
        XCTAssertEqual(entry["provider"] as? String, "anthropic")
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(raw.contains("fixtureSecret"), "no vault secret may land in Droid's settings")
        // A first write has nothing to back up; the file itself is owner-only.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(DroidSetup.verify(home: home, key: "anthropic-work", port: 12767))
    }

    func testDroidUpsertMergesKeepsSiblingsAndPrunesDeadKeys() throws {
        let url = DroidSetup.settingsURL(home: home)
        let existing: [String: Any] = [
            "customModels": [
                [
                    "model": "vendor/x", "displayName": "Vendor direct", "provider": "generic-chat-completion-api",
                    "baseUrl": "https://api.vendor.example/v1", "apiKey": "sk-user-owns-this",
                ],
                [
                    "model": "gone", "displayName": "Keysrs gone", "provider": "anthropic",
                    "baseUrl": "http://127.0.0.1:12767/deleted-key", "apiKey": "${KEYSRS_DROID_TOKEN}",
                ],
                [
                    "model": "claude-sonnet-4-5-20250929", "displayName": "Keysrs sibling", "provider": "anthropic",
                    "baseUrl": "http://127.0.0.1:12767/other-key", "apiKey": "${KEYSRS_DROID_TOKEN}",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)
        try DroidSetup.upsert(
            home: home, key: "anthropic-work", port: 12767, model: "claude-sonnet-4-5-20250929",
            displayName: "Keysrs anthropic-work", providerKind: "anthropic",
            liveKeyNames: ["anthropic-work", "other-key"]
        )
        // An existing settings file is backed up before the first edit, owner-only.
        let backup = url.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        let afterFirst = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        let models = try XCTUnwrap(afterFirst["customModels"] as? [[String: Any]])
        XCTAssertEqual(models.count, 3, "vendor entry and live sibling stay, dead key is pruned, ours appended")
        XCTAssertFalse(models.contains { ($0["baseUrl"] as? String)?.contains("deleted-key") ?? false })
        XCTAssertTrue(models.contains { ($0["baseUrl"] as? String) == "https://api.vendor.example/v1" })
        XCTAssertTrue(models.contains { ($0["baseUrl"] as? String) == "http://127.0.0.1:12767/other-key" })
        XCTAssertTrue(models.contains { ($0["baseUrl"] as? String) == "http://127.0.0.1:12767/anthropic-work" })

        // A second run replaces instead of duplicating.
        try DroidSetup.upsert(
            home: home, key: "anthropic-work", port: 12767, model: "claude-haiku-4-5",
            displayName: "Keysrs anthropic-work", providerKind: "anthropic",
            liveKeyNames: ["anthropic-work", "other-key"]
        )
        let afterSecond = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        let after = try XCTUnwrap(afterSecond["customModels"] as? [[String: Any]])
        XCTAssertEqual(after.filter { ($0["baseUrl"] as? String)?.hasSuffix("anthropic-work") ?? false }.count, 1)
        let mine = after.first { ($0["baseUrl"] as? String)?.hasSuffix("anthropic-work") ?? false }
        XCTAssertEqual(mine?["model"] as? String, "claude-haiku-4-5")
    }

    func testDroidVerifyNamesTheFixBeforeSetup() {
        let problem = DroidSetup.verify(home: home, key: "anthropic-work", port: 12767)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("keys setup droid") ?? false)
    }

    // MARK: - Codex config.toml

    func testCodexUpsertWritesTheProviderBlockAndOptionalDefaults() throws {
        try CodexSetup.upsert(home: home, key: "router", port: 12767, wire: "chat", setDefault: false, model: nil)
        let url = CodexSetup.configURL(home: home)
        var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains("[model_providers.keysrs]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:12767/router\""))
        XCTAssertTrue(text.contains("env_key = \"KEYSRS_CODEX_TOKEN\""))
        XCTAssertTrue(text.contains("wire_api = \"chat\""))
        XCTAssertFalse(text.contains("model_provider ="), "no default is set without --set-default")
        XCTAssertNil(CodexSetup.verify(home: home, key: "router", port: 12767))

        try CodexSetup.upsert(home: home, key: "router", port: 12767, wire: "chat", setDefault: true, model: "vendor/x")
        text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("model_provider = \"keysrs\""))
        XCTAssertTrue(text.contains("model = \"vendor/x\""))
        XCTAssertEqual(
            text.components(separatedBy: "\n").filter { $0.contains("base_url =") }.count, 1,
            "the second run replaced the block rather than adding another"
        )
    }

    func testGrokUpsertAndVerify() throws {
        try GrokSetup.upsert(home: home, key: "xai-key", port: 12767, model: "grok-4.6")
        let url = GrokSetup.configURL(home: home)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains("[model.keysrs]"))
        XCTAssertTrue(text.contains("model = \"grok-4.6\""))
        XCTAssertTrue(text.contains("env_key = \"KEYSRS_GROK_TOKEN\""))
        XCTAssertNil(GrokSetup.verify(home: home, key: "xai-key", port: 12767))
        XCTAssertNotNil(GrokSetup.verify(home: home, key: "other-key", port: 12767))
    }

    // MARK: - agent metadata, launch env and the tunnel

    func testAgentMetadataAndLaunchEnvironment() throws {
        XCTAssertEqual(try CodingAgent.parse("droid"), .droid)
        XCTAssertThrowsError(try CodingAgent.parse("cursor"))
        XCTAssertEqual(CodingAgent.claude.launchEnv(key: "k", port: 12767, token: "ksf_1"), [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:12767/k",
            "ANTHROPIC_AUTH_TOKEN": "ksf_1",
        ])
        XCTAssertEqual(CodingAgent.codex.launchEnv(key: "k", port: 12767, token: "ksf_2"),
                       ["KEYSRS_CODEX_TOKEN": "ksf_2"])
        XCTAssertEqual(CodingAgent.grok.tokenVar, "KEYSRS_GROK_TOKEN")
        XCTAssertEqual(CodingAgent.droid.supportedAPIs, Set(["anthropic", "openai"]))
        XCTAssertEqual(CodingAgent.claude.supportedAPIs, Set(["anthropic"]))
        XCTAssertEqual(CodingAgent.defaultModel(for: Providers.Record(
            id: "x", name: "x", host: nil, api: "anthropic", authHeader: "Authorization",
            authPrefix: "Bearer ", pathPrefix: "", gateway: true
        )), "claude-sonnet-4-5-20250929")
        XCTAssertEqual(try CodingAgent.codexWire(for: Providers.provider(id: "openrouter")!, override: nil), "chat")
        XCTAssertEqual(try CodingAgent.codexWire(for: Providers.provider(id: "openai")!, override: nil), "responses")
        XCTAssertThrowsError(try CodingAgent.droidProviderKind(for: Providers.provider(id: "fal")!, override: nil))
    }

    func testTunnelCommandShapeAndValidation() throws {
        let argv = try Tunnel.argv(userHost: " user@server.example.com ", remotePort: 12767, localPort: 12767)
        XCTAssertEqual(argv.first, "ssh")
        XCTAssertTrue(argv.contains("-R"))
        XCTAssertEqual(argv[argv.firstIndex(of: "-R")! + 1], "12767:127.0.0.1:12767")
        XCTAssertTrue(argv.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(argv.last, "user@server.example.com")
        XCTAssertThrowsError(try Tunnel.argv(userHost: "", remotePort: 12767, localPort: 12767))
        XCTAssertThrowsError(try Tunnel.argv(userHost: "a b", remotePort: 12767, localPort: 12767))
        XCTAssertThrowsError(try Tunnel.argv(userHost: "a@b", remotePort: 0, localPort: 12767))
        let text = Tunnel.instructions(key: "router", userHost: "user@server", remotePort: 12767, localPort: 12767)
        XCTAssertTrue(text.contains("keys client issue router"))
        XCTAssertTrue(text.contains("http://127.0.0.1:12767/router"))
    }
}
