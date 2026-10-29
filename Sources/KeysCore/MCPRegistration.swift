import Foundation

/// `keys setup mcp`: registering the `keys mcp` stdio server with the five agent
/// clients (Claude Code, Codex, Cursor, Droid, Claude Desktop), and `--remove`, its
/// exact undo. Every writer takes the target file's URL explicitly, so no caller can
/// reach the user's real config by accident: the CLI resolves those URLs from the
/// documented home overrides (`KEYS_CLAUDE_JSON`, `CODEX_HOME`, `KEYS_CURSOR_HOME`,
/// `KEYS_DROID_HOME`, `KEYS_CLAUDE_DESKTOP_HOME`) and tests pass temp ones. Nothing
/// written holds a secret — an entry names the resolved executable and the stdio
/// argument, nothing else.
enum MCPRegistration {
    /// One source of truth for the server name every client file and the report carry.
    static let serverName = "keysrs"
    /// The stdio args every client entry carries: the `mcp` subcommand.
    static let stdioArgs = ["mcp"]
    /// Codex keeps MCP servers as `[mcp_servers.<name>]` tables.
    static let codexSection = "mcp_servers.\(serverName)"

    // MARK: - the command

    /// The absolute path the clients launch: the symlink-resolved executable, never a
    /// symlink such as `~/.local/bin/keys` that a later uninstall would break.
    static func resolvedCommand(executable: URL?) throws -> String {
        guard let executable else {
            throw AppError.usage("could not locate the keys executable to register")
        }
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), path.hasSuffix("/keys"),
              !path.contains("~"), !path.contains("./"), !path.contains(".."), !path.hasSuffix("/") else {
            throw AppError.usage("the resolved keys executable path \(path) is not an absolute path to the keys binary")
        }
        return path
    }

    // MARK: - the five clients

    /// The five clients `keys setup mcp` writes, in the order the command reports
    /// them. Each knows its config file and its entry shape; the merge rules are the
    /// shared machinery below.
    enum Client: String, CaseIterable {
        case claudeCode = "claude_code"
        case codex
        case cursor
        case droid
        case claudeDesktop = "claude_desktop"

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .droid: return "Droid"
            case .claudeDesktop: return "Claude Desktop"
            }
        }

        /// The entry this client's config carries for the server. One shape per
        /// client, pinned to what each client documents: Claude Code names stdio and
        /// an explicitly empty env; Cursor and Claude Desktop carry no type key;
        /// Droid names stdio with no env.
        func entry(command: String) -> [String: Any] {
            let args = MCPRegistration.stdioArgs
            switch self {
            case .claudeCode:
                return ["type": "stdio", "command": command, "args": args, "env": [String: Any]()]
            case .cursor, .claudeDesktop:
                return ["command": command, "args": args]
            case .droid:
                return ["type": "stdio", "command": command, "args": args]
            case .codex:
                return [:]  // Codex keeps servers in TOML; registerCodex writes the table.
            }
        }

        /// Droid's own mcp.json carries no trailing newline; every other file keeps
        /// the one the house JSON writer writes.
        var trailingNewline: Bool { self != .droid }

        func configURL(in targets: Targets) -> URL {
            switch self {
            case .claudeCode: return targets.claudeCode
            case .codex: return targets.codex
            case .cursor: return targets.cursor
            case .droid: return targets.droid
            case .claudeDesktop: return targets.claudeDesktop
            }
        }

        func register(in targets: Targets, command: String) throws {
            let url = configURL(in: targets)
            switch self {
            case .codex:
                try MCPRegistration.registerCodex(config: url, command: command)
            case .claudeCode, .cursor, .droid, .claudeDesktop:
                try MCPRegistration.write(
                    try MCPRegistration.mergedObject(at: url, entry: entry(command: command)),
                    to: url, trailingNewline: trailingNewline)
            }
        }

        /// nil-safe removal: false when nothing of ours is registered, so a remove
        /// with nothing to do never writes, never creates a `.bak` and never errors.
        @discardableResult
        func remove(from targets: Targets) throws -> Bool {
            let url = configURL(in: targets)
            switch self {
            case .codex:
                return try MCPRegistration.removeCodex(config: url)
            case .claudeCode, .cursor, .droid, .claudeDesktop:
                guard let object = try MCPRegistration.objectWithoutOurEntry(at: url) else { return false }
                try MCPRegistration.write(object, to: url, trailingNewline: trailingNewline)
                return true
            }
        }
    }

    /// The five files the command touches, resolved once so every path it uses is
    /// visible in one place. Production reads the documented overrides; tests and
    /// shell checks pass an all-temp instance — the five real config files exist on
    /// this machine and must never be touched by a test.
    struct Targets {
        let claudeCode: URL      // ~/.claude.json (KEYS_CLAUDE_JSON)
        let codex: URL           // ~/.codex/config.toml (CODEX_HOME)
        let cursor: URL          // ~/.cursor/mcp.json (KEYS_CURSOR_HOME)
        let droid: URL           // ~/.factory/mcp.json (KEYS_DROID_HOME)
        let claudeDesktop: URL   // ~/Library/Application Support/Claude/claude_desktop_config.json (KEYS_CLAUDE_DESKTOP_HOME)

        static var production: Targets {
            Targets(
                claudeCode: Paths.claudeJSON,
                codex: CodexSetup.configURL(home: Paths.codexHome),
                cursor: Paths.cursorHome.appendingPathComponent("mcp.json"),
                droid: Paths.droidHome.appendingPathComponent("mcp.json"),
                claudeDesktop: Paths.claudeDesktopHome.appendingPathComponent("claude_desktop_config.json")
            )
        }
    }

    // MARK: - Codex, the one TOML client

    /// Codex keeps servers as `[mcp_servers.<name>]` tables. The edit is surgical —
    /// every byte outside our table stays as the user wrote it — and a CRLF file is
    /// refused rather than edited, on both the add and the remove path (the existing
    /// house Codex rule).
    static func registerCodex(config: URL, command: String) throws {
        let text = try codexText(config)
        try AgentConfigFile.write(
            text: TOMLFile.upsertSection(text, header: codexSection, bodyLines: codexBody(command: command)),
            to: config)
    }

    @discardableResult
    static func removeCodex(config: URL) throws -> Bool {
        let text = try codexText(config)
        guard text.components(separatedBy: "\n")
            .contains(where: { $0.trimmingCharacters(in: .whitespaceCharacters) == "[\(codexSection)]" })
        else { return false }
        try AgentConfigFile.write(text: TOMLFile.removeSection(text, header: codexSection), to: config)
        return true
    }

    /// The two lines of our Codex table: the executable and the stdio args.
    private static func codexBody(command: String) -> [String] {
        [
            "command = \(TOMLFile.quote(command))",
            "args = [\(stdioArgs.map { TOMLFile.quote($0) }.joined(separator: ", "))]",
        ]
    }

    /// The file's bytes with CRLF refused before anything is decided or written. The
    /// check is on the bytes, not the String: a CR that is always followed by an LF is
    /// a single grapheme cluster, so `contains("\r")` misses exactly the CRLF files
    /// it is meant to guard.
    private static func codexText(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try Data(contentsOf: url)
        if data.contains(0x0D) {
            throw AppError.usage("\(url.path) uses CRLF line endings; normalize it and retry")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - the shared JSON merge (the four JSON clients)

    /// The client file's object with our entry set under top-level `mcpServers`. The
    /// file is read through `AgentConfigFile.readJSON`, so an unparsable file throws
    /// the house wording instead of being clobbered; a wrong-typed `mcpServers` and a
    /// wrong-typed entry of ours are refused, and everything else — the ~100 sibling
    /// keys of `~/.claude.json` included — is carried through untouched.
    private static func mergedObject(at url: URL, entry: [String: Any]) throws -> [String: Any] {
        var object = try AgentConfigFile.readJSON(url)
        var servers: [String: Any]
        if let existing = JSONValue.object(object["mcpServers"]) {
            servers = existing
        } else if object["mcpServers"] == nil {
            servers = [:]
        } else {
            throw AppError.usage("\(url.path) has an mcpServers key that is not an object; fix or remove it and retry")
        }
        if let ours = servers[serverName], JSONValue.object(ours) == nil {
            throw AppError.usage("\(url.path) has a \(serverName) entry that is not an object; fix or remove it and retry")
        }
        servers[serverName] = entry
        object["mcpServers"] = servers
        return object
    }

    /// The client file's object with our entry removed, or nil when there is nothing
    /// of ours to remove (missing file, no `mcpServers`, no entry under our name). An
    /// `mcpServers` left empty is dropped rather than written back as an empty object;
    /// a wrong-typed value under our name is refused instead of deleted, the same way
    /// registration refuses it.
    private static func objectWithoutOurEntry(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var object = try AgentConfigFile.readJSON(url)
        guard var servers = JSONValue.object(object["mcpServers"]) else { return nil }
        guard let ours = servers[serverName] else { return nil }
        guard JSONValue.object(ours) != nil else {
            throw AppError.usage("\(url.path) has a \(serverName) entry that is not an object; fix or remove it and retry")
        }
        servers.removeValue(forKey: serverName)
        if servers.isEmpty {
            object.removeValue(forKey: "mcpServers")
        } else {
            object["mcpServers"] = servers
        }
        return object
    }

    /// The file's bytes: 2-space pretty, sorted keys (the DroidSetup idiom), through
    /// `AgentConfigFile.write` for the rolling 0600 `.bak` and the atomic update.
    private static func write(_ object: [String: Any], to url: URL, trailingNewline: Bool) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var text = String(decoding: data, as: UTF8.self)
        if trailingNewline { text += "\n" }
        try AgentConfigFile.write(text: text, to: url)
    }

    // MARK: - the report

    /// The `keys setup mcp --json` line: one sorted-key object naming per client the
    /// config path it wrote (or cleaned), the server name and the command. A present
    /// key is a fact — removal resolved no executable, so it reports none.
    static func reportJSON(action: String, clients: [String: String], command: String?) -> [String: Any] {
        var report: [String: Any] = ["action": action, "clients": clients, "server": serverName]
        if let command { report["command"] = command }
        return report
    }
}
