import Foundation

/// The coding agents Keysrs can wire to the local gateway. Every agent gets the same shape:
/// a config entry that names the gateway base URL and the environment variable the launch
/// token goes into, and a `keys agent <name> <key>` launcher that mints a grant and fills it.
/// No file this writes ever holds a secret; an unattended setup uses a long-lived client
/// token exported by hand instead.
enum CodingAgent: String, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case droid

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .droid: return "Droid"
        }
    }

    /// The executable `keys agent` runs.
    var executable: String { rawValue }

    /// What the Touch ID prompt and the audit log call the grant.
    var task: String {
        switch self {
        case .claude: return "a Claude Code session on this Mac"
        case .codex: return "a Codex session on this Mac"
        case .grok: return "a Grok session on this Mac"
        case .droid: return "a Droid session on this Mac"
        }
    }

    /// Default grant life. Long enough for a working session; a grant dies on screen lock
    /// anyway, and `keys agent` revokes what is left when the agent exits.
    static let grantMinutes = 480

    /// The environment variable the launch token goes into. Claude Code reads its base URL
    /// and auth token from its own two variables, so it has no Keysrs one.
    var tokenVar: String? {
        switch self {
        case .claude: return nil
        case .codex: return "KEYSRS_CODEX_TOKEN"
        case .grok: return "KEYSRS_GROK_TOKEN"
        case .droid: return "KEYSRS_DROID_TOKEN"
        }
    }

    /// The child environment for a launch: base URL plus token where the agent's own
    /// config expects them.
    func launchEnv(key: String, port: UInt16, token: String) -> [String: String] {
        let base = "http://127.0.0.1:\(port)/\(key)"
        switch self {
        case .claude:
            return ["ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": token]
        case .codex, .grok, .droid:
            return [tokenVar!: token]
        }
    }

    /// Which provider wire formats the agent can speak through the gateway.
    var supportedAPIs: Set<String> {
        switch self {
        case .claude: return ["anthropic"]
        case .codex, .grok: return ["openai"]
        case .droid: return ["anthropic", "openai"]
        }
    }

    /// The agent's config directory, honoring the same overrides the ingests use so tests
    /// and the CI fixtures never touch a real home.
    var configHome: URL? {
        switch self {
        case .claude: return nil
        case .codex: return Paths.codexHome
        case .grok: return Paths.grokHome
        case .droid: return Paths.env("KEYS_FACTORY_HOME")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory")
        }
    }

    static func parse(_ raw: String) throws -> CodingAgent {
        guard let agent = CodingAgent(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AppError.usage(
                "unknown agent \(raw.debugDescription) (supported: \(allCases.map(\.rawValue).joined(separator: ", ")))"
            )
        }
        return agent
    }

    /// A reasonable default model when the provider's wire makes one obvious. Everything
    /// else is the user's call: model names churn faster than releases, so refusing beats
    /// shipping a stale guess that 404s on the first request.
    static func defaultModel(for record: Providers.Record) -> String? {
        record.api == "anthropic" ? "claude-sonnet-4-5-20250929" : nil
    }

    /// Droid's provider kind: Anthropic Messages, OpenAI Responses, or the generic
    /// chat-completions shape most OpenAI-compatible providers serve.
    static func droidProviderKind(for record: Providers.Record, override: String? = nil) throws -> String {
        let allowed: Set<String> = ["anthropic", "openai", "generic-chat-completion-api"]
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(trimmed) else {
                throw AppError.usage("wire must be anthropic, openai or generic-chat-completion-api")
            }
            return trimmed
        }
        switch record.api {
        case "anthropic": return "anthropic"
        case "openai": return record.id == "openai" ? "openai" : "generic-chat-completion-api"
        default:
            throw AppError.usage(
                "Droid speaks the Anthropic, OpenAI Responses or chat-completions wire; "
                    + "\(record.name) serves \(record.api == "other" ? "an untracked" : "a \(record.api)") API"
            )
        }
    }

    /// Codex's wire API: Responses for the official OpenAI API, chat completions for the
    /// OpenAI-compatible routers and hosts.
    static func codexWire(for record: Providers.Record, override: String? = nil) throws -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["chat", "responses"].contains(trimmed) else {
                throw AppError.usage("wire must be chat or responses")
            }
            return trimmed
        }
        return record.id == "openai" && record.api == "openai" ? "responses" : "chat"
    }
}

/// Line-based edits to config files owned by other programs. Both Grok and Codex keep
/// settings in TOML, and neither file has a schema we can fully parse, so the edit is
/// deliberately surgical: everything outside the named section stays byte-identical.
enum TOMLFile {
    /// Replaces the body of the exact `[header]` section, or appends the section at the end.
    /// Comments inside a section we own are replaced with it; anything else is untouched.
    static func upsertSection(_ text: String, header: String, bodyLines: [String]) -> String {
        let lines = text.components(separatedBy: "\n")
        let headerLine = "[\(header)]"
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == headerLine }) {
            var end = lines.count
            if let next = lines[(start + 1)...].firstIndex(where: isSectionHeader) {
                end = next
            }
            var out = Array(lines[..<start])
            out.append(headerLine)
            out.append(contentsOf: bodyLines)
            if end < lines.count {
                out.append(contentsOf: lines[end...])
            }
            return out.joined(separator: "\n")
        }
        var out = text
        if !out.isEmpty {
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        out += headerLine + "\n" + bodyLines.joined(separator: "\n") + "\n"
        return out
    }

    /// Sets a key that must live before the first `[section]` header, replacing an
    /// existing assignment or inserting one just above the first header.
    static func upsertTopLevelKey(_ text: String, line: String, key: String) -> String {
        // A blank file has nothing above the header line to sit under.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return line + "\n"
        }
        var lines = text.components(separatedBy: "\n")
        let firstHeader = lines.firstIndex(where: isSectionHeader) ?? lines.count
        if let existing = lines[..<firstHeader].firstIndex(where: { assignmentKey($0) == key }) {
            lines[existing] = line
            return lines.joined(separator: "\n")
        }
        lines.insert(line, at: firstHeader)
        return lines.joined(separator: "\n")
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaceCharacters)
        return t.hasPrefix("[") && t.hasSuffix("]") && t.count > 2
    }

    /// The key of a `key = value` line, or nil for anything else.
    private static func assignmentKey(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaceCharacters)
        return key.isEmpty || key.hasPrefix("#") || key.hasPrefix("[") ? nil : key
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension CharacterSet {
    /// `whitespaceAndNewlines` minus newlines: TOML allows same-line comments, so a
    /// trailing `# ...` on a section header line must not defeat the match.
    static var whitespaceCharacters: CharacterSet {
        CharacterSet.whitespaces.subtracting(CharacterSet(charactersIn: "\r\n"))
    }
}

/// Writes, backs up and checks the agent-side config files. The backup lands beside the
/// file as `<name>.bak` (Droid already snapshots its own settings this way), and both the
/// file and the backup keep 0600 permissions because the config names a local vault.
enum AgentConfigFile {
    @discardableResult
    static func write(text: String, to url: URL) throws -> URL {
        let backup = url.appendingPathExtension("bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(text.utf8).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return backup
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The JSON object of a settings file, or an empty one when missing or unparsable.
    /// A broken file is never overwritten silently; callers that must not lose data
    /// re-check for parse failures before writing.
    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) else {
            throw AppError.usage("\(url.lastPathComponent) is not valid JSON; fix or remove it and retry")
        }
        return obj
    }
}

/// Droid (`~/.factory/settings.json`): one `customModels` entry per vault key, with
/// `apiKey` left as an environment reference that `keys agent droid` fills per launch.
enum DroidSetup {
    static let originPrefix = "http://127.0.0.1:"

    static func settingsURL(home: URL) -> URL {
        home.appendingPathComponent("settings.json")
    }

    static func entry(
        key: String, port: UInt16, model: String, displayName: String, providerKind: String
    ) -> [String: Any] {
        [
            "model": model,
            "displayName": displayName,
            "baseUrl": "\(originPrefix)\(port)/\(key)",
            "provider": providerKind,
            "apiKey": "${\(CodingAgent.droid.tokenVar!)}",
        ]
    }

    /// Upserts the entry and prunes Keysrs entries whose key no longer exists. The rest of
    /// the user's Droid settings is copied through unchanged.
    static func upsert(
        home: URL, key: String, port: UInt16, model: String, displayName: String, providerKind: String,
        liveKeyNames: Set<String>
    ) throws {
        let url = settingsURL(home: home)
        var settings = try AgentConfigFile.readJSON(url)
        var models = (settings["customModels"] as? [Any])?.compactMap { JSONValue.object($0) } ?? []
        let mine = "\(originPrefix)\(port)/\(key)"
        models.removeAll { existing in
            guard let base = JSONValue.string(existing["baseUrl"]), base.hasPrefix(originPrefix) else { return false }
            if base == mine { return true }  // replaced by the entry appended below
            // A sibling key's entry stays; a key that is gone from the vault leaves a
            // dead URL and is pruned.
            let name = base.dropFirst("\(originPrefix)\(port)/".count).split(separator: "/").first.map(String.init)
            return name.map { !liveKeyNames.contains($0) } ?? true
        }
        models.append(entry(key: key, port: port, model: model, displayName: displayName, providerKind: providerKind))
        settings["customModels"] = models
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AgentConfigFile.write(text: String(decoding: data, as: UTF8.self) + "\n", to: url)
    }

    /// nil when the settings file has a working Keysrs entry for this key. A raw token the
    /// user pasted in place of the `${VAR}` reference also counts: it is their credential.
    static func verify(home: URL, key: String, port: UInt16) -> String? {
        let url = settingsURL(home: home)
        guard let settings = try? AgentConfigFile.readJSON(url),
              let models = settings["customModels"] as? [Any] else {
            return "no customModels in \(url.path); run: keys setup droid --key \(key)"
        }
        let mine = "\(originPrefix)\(port)/\(key)"
        let ok = models.compactMap { JSONValue.object($0) }.contains {
            JSONValue.string($0["baseUrl"]) == mine && !(JSONValue.string($0["apiKey"]) ?? "").isEmpty
        }
        return ok ? nil : "no Keysrs custom model for \(key) in \(url.path); run: keys setup droid --key \(key)"
    }
}

/// Codex (`~/.codex/config.toml`): a `model_providers.keysrs` block whose `env_key` names
/// the variable `keys agent codex` exports.
enum CodexSetup {
    static let section = "model_providers.keysrs"

    static func configURL(home: URL) -> URL {
        home.appendingPathComponent("config.toml")
    }

    static func sectionBody(key: String, port: UInt16, wire: String) -> [String] {
        [
            "name = \(TOMLFile.quote("Keysrs gateway"))",
            "base_url = \(TOMLFile.quote("http://127.0.0.1:\(port)/\(key)"))",
            "env_key = \(TOMLFile.quote(CodingAgent.codex.tokenVar!))",
            "wire_api = \(TOMLFile.quote(wire))",
        ]
    }

    static func upsert(
        home: URL, key: String, port: UInt16, wire: String, setDefault: Bool, model: String?
    ) throws {
        let url = configURL(home: home)
        var text = AgentConfigFile.read(url)
        if text.contains("\r") {
            throw AppError.usage("\(url.path) uses CRLF line endings; normalize it and retry")
        }
        text = TOMLFile.upsertSection(text, header: section, bodyLines: sectionBody(key: key, port: port, wire: wire))
        if setDefault {
            text = TOMLFile.upsertTopLevelKey(text, line: "model_provider = \(TOMLFile.quote("keysrs"))", key: "model_provider")
            if let model {
                text = TOMLFile.upsertTopLevelKey(text, line: "model = \(TOMLFile.quote(model))", key: "model")
            }
        }
        try AgentConfigFile.write(text: text, to: url)
    }

    static func verify(home: URL, key: String, port: UInt16) -> String? {
        let url = configURL(home: home)
        let lines = AgentConfigFile.read(url).components(separatedBy: "\n")
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == header }) else {
            return "no keysrs provider in \(url.path); run: keys setup codex --key \(key)"
        }
        let want = "base_url = \(TOMLFile.quote("http://127.0.0.1:\(port)/\(key)"))"
        guard lines.dropFirst(start + 1).prefix(20)
            .contains(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == want }) else {
            return "the keysrs provider in \(url.path) points at another key; run: keys setup codex --key \(key)"
        }
        return nil
    }
}

/// Grok (`~/.grok/config.toml`): a `[model.keysrs]` block, the same shape Grok documents
/// for custom OpenAI-compatible endpoints.
enum GrokSetup {
    static let section = "model.keysrs"

    static func configURL(home: URL) -> URL {
        home.appendingPathComponent("config.toml")
    }

    static func sectionBody(key: String, port: UInt16, model: String) -> [String] {
        [
            "model = \(TOMLFile.quote(model))",
            "name = \(TOMLFile.quote("Keysrs gateway"))",
            "base_url = \(TOMLFile.quote("http://127.0.0.1:\(port)/\(key)"))",
            "env_key = \(TOMLFile.quote(CodingAgent.grok.tokenVar!))",
        ]
    }

    static func upsert(home: URL, key: String, port: UInt16, model: String) throws {
        let url = configURL(home: home)
        var text = AgentConfigFile.read(url)
        if text.contains("\r") {
            throw AppError.usage("\(url.path) uses CRLF line endings; normalize it and retry")
        }
        text = TOMLFile.upsertSection(text, header: section, bodyLines: sectionBody(key: key, port: port, model: model))
        try AgentConfigFile.write(text: text, to: url)
    }

    static func verify(home: URL, key: String, port: UInt16) -> String? {
        let url = configURL(home: home)
        let lines = AgentConfigFile.read(url).components(separatedBy: "\n")
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == header }) else {
            return "no keysrs model in \(url.path); run: keys setup grok --key \(key)"
        }
        let want = "base_url = \(TOMLFile.quote("http://127.0.0.1:\(port)/\(key)"))"
        guard lines.dropFirst(start + 1).prefix(20).contains(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == want })
        else {
            return "the keysrs model in \(url.path) points at another key; run: keys setup grok --key \(key)"
        }
        return nil
    }
}
