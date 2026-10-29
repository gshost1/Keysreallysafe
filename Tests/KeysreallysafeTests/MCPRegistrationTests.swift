import XCTest
@testable import KeysCore

/// `keys setup mcp`: the registration of the `keys mcp` stdio server with the five
/// agent clients, and `--remove`, its exact undo. Every case writes into a temp root
/// only — the five real config files exist on this machine and must never be touched —
/// and no case ever calls `run()`: the CLI level only parses, the writer level writes.
final class MCPRegistrationTests: XCTestCase {
    private var root: URL!
    private var targets: MCPRegistration.Targets!
    /// A stand-in for the resolved executable path; nothing about it is secret.
    private let command = "/Test/Keysrs.app/Contents/MacOS/keys"

    override func setUpWithError() throws {
        root = try TempDir.make()
        targets = makeTargets(root: root)
    }

    /// Five temp paths under one root, the way a shell check confines the CLI.
    private func makeTargets(root: URL) -> MCPRegistration.Targets {
        MCPRegistration.Targets(
            claudeCode: root.appendingPathComponent("claude.json"),
            codex: root.appendingPathComponent("codex-home/config.toml"),
            cursor: root.appendingPathComponent("cursor-home/mcp.json"),
            droid: root.appendingPathComponent("factory-home/mcp.json"),
            claudeDesktop: root.appendingPathComponent("app-support/Claude/claude_desktop_config.json")
        )
    }

    // MARK: - one source of truth and the command resolver (VAL-REG-002)

    func testConstantsAndResolvedCommand() throws {
        XCTAssertEqual(MCPRegistration.serverName, "keysrs")
        XCTAssertEqual(MCPRegistration.stdioArgs, ["mcp"])
        XCTAssertEqual(MCPRegistration.codexSection, "mcp_servers.keysrs")
        // The entry shapes are built from those constants, one per client, pinned to
        // what each client documents.
        XCTAssertEqual(
            try canonicalBytes(MCPRegistration.Client.claudeCode.entry(command: command)),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()]))
        XCTAssertEqual(
            try canonicalBytes(MCPRegistration.Client.cursor.entry(command: command)),
            try canonicalBytes(["command": command, "args": ["mcp"]]))
        XCTAssertEqual(
            try canonicalBytes(MCPRegistration.Client.droid.entry(command: command)),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"]]))
        XCTAssertEqual(
            try canonicalBytes(MCPRegistration.Client.claudeDesktop.entry(command: command)),
            try canonicalBytes(["command": command, "args": ["mcp"]]))

        // A symlink resolves to the binary it points at; a direct path comes back
        // unchanged. Storing the symlink (~/.local/bin/keys) is what breaks the
        // registration when the symlink is removed, so the resolver must not.
        let app = root.appendingPathComponent("Keysrs.app/Contents/MacOS/keys")
        try FileManager.default.createDirectory(
            at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app.path, contents: Data("#!/bin/sh\n".utf8))
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("keys")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: app.path)
        let resolved = try MCPRegistration.resolvedCommand(executable: link)
        XCTAssertEqual(resolved, app.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNotEqual(resolved, link.path, "the stored value is the resolved binary, not the symlink")
        let direct = try MCPRegistration.resolvedCommand(executable: app)
        XCTAssertEqual(direct, app.resolvingSymlinksInPath().standardizedFileURL.path)
        for path in [resolved, direct] {
            XCTAssertTrue(path.hasPrefix("/"))
            XCTAssertTrue(path.hasSuffix("/keys"))
            XCTAssertFalse(path.contains("~"))
            XCTAssertFalse(path.contains("./"))
            XCTAssertFalse(path.contains(".."))
            XCTAssertFalse(path.hasSuffix("/"))
        }
        XCTAssertThrowsError(try MCPRegistration.resolvedCommand(executable: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("keys executable"))
        }
    }

    // MARK: - Claude Code (VAL-REG-003)

    func testClaudeCodeRegistration() throws {
        let url = targets.claudeCode
        // First registration with no file creates it holding only our entry, 0600,
        // no .bak (nothing existed), parent directory created.
        try MCPRegistration.Client.claudeCode.register(in: targets, command: command)
        var object = try readJSON(url)
        XCTAssertEqual(Set(object.keys), ["mcpServers"])
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: object)),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()]))
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertFalse(fileExists(url.appendingPathExtension("bak")))
        XCTAssertTrue(fileExists(url.deletingLastPathComponent()))

        // The big real-shaped seed: ~100 sibling top-level keys, a deep projects tree
        // and an existing sibling server. Every pre-existing key survives deep-equal.
        let seed = Self.bigClaudeSeed()
        try writeSeed(Self.jsonText(seed), to: url)
        try MCPRegistration.Client.claudeCode.register(in: targets, command: command)
        object = try readJSON(url)
        for (key, value) in seed where key != "mcpServers" {
            XCTAssertEqual(
                try canonicalBytes([key: value]), try canonicalBytes([key: object[key] as Any]),
                "the sibling top-level key \(key) must survive the merge"
            )
        }
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["everything-server", MCPRegistration.serverName])
        XCTAssertEqual(
            try canonicalBytes(["s": servers["everything-server"] as Any]),
            try canonicalBytes(["s": (seed["mcpServers"] as? [String: Any])!["everything-server"] as Any]),
            "the sibling server entry must be untouched"
        )
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: object)),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()]))

        // A hand edit after registration — the user's own server entry and a changed
        // projects value — survives a re-run, and our own stale entry is replaced,
        // not duplicated.
        var edited = object
        edited["mcpServers"] = [
            "everything-server": ["command": "/moved/server"],
            MCPRegistration.serverName: ["type": "stdio", "command": "/stale/keys", "args": ["mcp"]],
        ] as [String: Any]
        edited["numStartups"] = 99
        try writeSeed(Self.jsonText(edited), to: url)
        try MCPRegistration.Client.claudeCode.register(in: targets, command: command)
        object = try readJSON(url)
        XCTAssertEqual((object["numStartups"] as? Int), 99)
        let after = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual((after["everything-server"] as? [String: Any])?["command"] as? String, "/moved/server")
        XCTAssertEqual(try ourEntry(in: object)["command"] as? String, command)
        XCTAssertEqual(Set(after.keys), ["everything-server", MCPRegistration.serverName], "no duplicate of ours")
    }

    /// A realistic `~/.claude.json`: ~100 other top-level keys, a deep `projects`
    /// tree and an existing sibling stdio server, at least 139 KB serialized.
    private static func bigClaudeSeed() -> [String: Any] {
        var projects: [String: Any] = [:]
        for i in 0..<80 {
            let history = (0..<16).map {
                "fix the \($0)th regression in module-\(i): read the log, bisect the failure, patch the code, and re-run the whole suite before moving on"
            }
            projects["/Users/demo/work/project-\(i)"] = [
                "allowedTools": ["Bash(npm run build)", "Read", "Edit"],
                "history": history,
                "mcpContextUris": ["file:///Users/demo/work/project-\(i)/notes.md"],
                "lastSession": "2026-10-\(String(format: "%02d", (i % 28) + 1))T10:00:00Z",
                "settings": ["theme": "dark", "verbose": true, "depth": ["a": ["b": ["c": i]]]],
                "stats": ["linesAdded": 1200 + i, "linesRemoved": 300 + i],
            ] as [String: Any]
        }
        var seed: [String: Any] = [
            "projects": projects,
            "mcpServers": [
                "everything-server": [
                    "type": "stdio", "command": "/opt/everything/bin/server",
                    "args": ["--port", "7777"], "env": ["TOKEN": "the-user-owns-this"],
                ] as [String: Any],
            ],
            "numStartups": 42,
            "installMethod": "native",
            "firstCompletionDate": "2026-01-04T09:00:00Z",
            "hasCompletedOnboarding": true,
        ]
        for i in 0..<100 {
            seed["state_\(String(format: "%02d", i))"] = [
                "label": "state key \(i)",
                "pinned": i % 2 == 0,
                "entries": (0..<3).map { "entry-\(i)-\($0) with a comfortably long description sentence" },
                "nested": ["deep": ["deeper": ["deepest": i]]],
            ] as [String: Any]
        }
        return seed
    }

    /// The seed must be big enough to stand in for the real file (~139 KB).
    func testClaudeSeedIsRealisticallyBig() throws {
        let bytes = try JSONSerialization.data(withJSONObject: Self.bigClaudeSeed(), options: [.sortedKeys])
        XCTAssertGreaterThanOrEqual(bytes.count, 139 * 1024)
    }

    // MARK: - Codex (VAL-REG-004)

    func testCodexRegistration() throws {
        // First registration with no file creates the file holding only our table.
        try MCPRegistration.Client.codex.register(in: targets, command: command)
        let created = """
        [\(MCPRegistration.codexSection)]
        command = "\(command)"
        args = ["mcp"]
        """ + "\n"
        XCTAssertEqual(try text(targets.codex), created)
        XCTAssertEqual(try permissions(targets.codex), 0o600)
        XCTAssertFalse(fileExists(targets.codex.appendingPathExtension("bak")))

        // Into a seed with representative neighbours, our table lands surgically: every
        // byte outside it is string-equal to the input.
        let seed = """
        model = "gpt-5"
        model_provider = "openai"

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]
        startup_timeout_sec = 30

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"

        [mcp_servers.computer-use]
        cwd = "/tmp"
        enabled = false

        [projects.untitled]
        trust_level = "trusted"
        """ + "\n"
        try writeSeed(seed, to: targets.codex)
        try MCPRegistration.Client.codex.register(in: targets, command: command)
        let expected = """
        model = "gpt-5"
        model_provider = "openai"

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]
        startup_timeout_sec = 30

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"

        [mcp_servers.computer-use]
        cwd = "/tmp"
        enabled = false

        [projects.untitled]
        trust_level = "trusted"

        [\(MCPRegistration.codexSection)]
        command = "\(command)"
        args = ["mcp"]
        """ + "\n"
        XCTAssertEqual(try text(targets.codex), expected)
        // A second run is byte-identical (no duplicate append), and rolls the .bak.
        let once = try text(targets.codex)
        try MCPRegistration.Client.codex.register(in: targets, command: command)
        XCTAssertEqual(try text(targets.codex), once)
        XCTAssertEqual(try text(targets.codex.appendingPathExtension("bak")), once)

        // A user edit inside our table is overwritten with the canonical lines while
        // every other line, comment and table stays byte-identical.
        let edited = """
        model = "gpt-5"
        model_provider = "openai"

        [\(MCPRegistration.codexSection)]
        command = "/old/moved/keys"
        args = ["mcp", "--extra"]
        enabled = true

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]
        startup_timeout_sec = 30

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"
        """ + "\n"
        try writeSeed(edited, to: targets.codex)
        try MCPRegistration.Client.codex.register(in: targets, command: command)
        let repaired = """
        model = "gpt-5"
        model_provider = "openai"

        [\(MCPRegistration.codexSection)]
        command = "\(command)"
        args = ["mcp"]

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]
        startup_timeout_sec = 30

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"
        """ + "\n"
        XCTAssertEqual(try text(targets.codex), repaired)

        // CRLF is refused on both paths, with the file untouched and no .bak created
        // by the refusal (the .bak from the successful run above is removed first).
        let crlf = "[\(MCPRegistration.codexSection)]\r\ncommand = \"\(command)\"\r\nargs = [\"mcp\"]\r\n"
        try writeSeed(crlf, to: targets.codex)
        try? FileManager.default.removeItem(at: targets.codex.appendingPathExtension("bak"))
        XCTAssertThrowsError(
            try MCPRegistration.Client.codex.register(in: targets, command: command)
        ) { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage error, got \(error)")
            }
            XCTAssertTrue(message.contains(targets.codex.path), message)
            XCTAssertTrue(message.contains("CRLF"), message)
        }
        XCTAssertEqual(try text(targets.codex), crlf)
        XCTAssertFalse(fileExists(targets.codex.appendingPathExtension("bak")))
        XCTAssertThrowsError(try MCPRegistration.Client.codex.remove(from: targets)) { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage error, got \(error)")
            }
            XCTAssertTrue(message.contains(targets.codex.path), message)
        }
        XCTAssertEqual(try text(targets.codex), crlf)
    }

    // MARK: - Cursor (VAL-REG-005)

    func testCursorRegistration() throws {
        // A missing ~/.cursor directory is created; the file is 0600 with no .bak.
        XCTAssertFalse(fileExists(targets.cursor.deletingLastPathComponent()))
        try MCPRegistration.Client.cursor.register(in: targets, command: command)
        var object = try readJSON(targets.cursor)
        XCTAssertEqual(Set(object.keys), ["mcpServers"])
        // No type key: Cursor's stdio entries carry none.
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: object)),
            try canonicalBytes(["command": command, "args": ["mcp"]]))
        XCTAssertEqual(try permissions(targets.cursor), 0o600)
        XCTAssertFalse(fileExists(targets.cursor.appendingPathExtension("bak")))

        // A seeded sibling server stays deep-equal after the merge; a second run is
        // byte-identical with .bak == the current file.
        let seed: [String: Any] = [
            "mcpServers": [
                "claude-mem": ["command": "/usr/local/bin/claude-mem", "args": []],
            ] as [String: Any],
        ]
        try writeSeed(Self.jsonText(seed), to: targets.cursor)
        try MCPRegistration.Client.cursor.register(in: targets, command: command)
        object = try readJSON(targets.cursor)
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["claude-mem", MCPRegistration.serverName])
        XCTAssertEqual(
            try canonicalBytes(["s": servers["claude-mem"] as Any]),
            try canonicalBytes(["s": (seed["mcpServers"] as? [String: Any])!["claude-mem"] as Any]))
        let once = try text(targets.cursor)
        try MCPRegistration.Client.cursor.register(in: targets, command: command)
        XCTAssertEqual(try text(targets.cursor), once)
        XCTAssertEqual(try text(targets.cursor.appendingPathExtension("bak")), once)
    }

    // MARK: - Droid (VAL-REG-006)

    func testDroidRegistration() throws {
        // A pre-seeded top-level persistentPermissions object and a sibling server
        // are carried through deep-equal.
        let seed: [String: Any] = [
            "persistentPermissions": [
                "Bash(git:*)": "allow", "Read": "allow", "WebFetch(domain:keysrs.com)": "allow",
            ] as [String: Any],
            "mcpServers": [
                "sibling": ["type": "stdio", "command": "/opt/sibling/bin/srv", "args": ["-v"]],
            ] as [String: Any],
        ]
        try writeSeed(Self.jsonText(seed), to: targets.droid)
        let settings = targets.droid.deletingLastPathComponent().appendingPathComponent("settings.json")
        try writeSeed("{\"customModels\": []}\n", to: settings)

        try MCPRegistration.Client.droid.register(in: targets, command: command)
        let object = try readJSON(targets.droid)
        let ours = try ourEntry(in: object)
        XCTAssertEqual(
            try canonicalBytes(ours),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"]]))
        XCTAssertNil(ours["disabled"], "the server must be enabled")
        XCTAssertNil(ours["env"])
        XCTAssertEqual(
            try canonicalBytes(["s": object["persistentPermissions"] as Any]),
            try canonicalBytes(["s": seed["persistentPermissions"] as Any]))
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual(
            try canonicalBytes(["s": servers["sibling"] as Any]),
            try canonicalBytes(["s": (seed["mcpServers"] as? [String: Any])!["sibling"] as Any]))

        // 2-space pretty JSON with no trailing newline, so a second run is
        // byte-identical and .bak == the current file.
        let bytes = try Data(contentsOf: targets.droid)
        XCTAssertNotEqual(bytes.last, UInt8(ascii: "\n"), "droid's mcp.json carries no trailing newline")
        let once = try text(targets.droid)
        try MCPRegistration.Client.droid.register(in: targets, command: command)
        XCTAssertEqual(try text(targets.droid), once)
        XCTAssertEqual(try text(targets.droid.appendingPathExtension("bak")), once)

        // ~/.factory/settings.json — the file `keys setup droid` owns — stays
        // byte-identical; only mcp.json and its .bak appear beside it.
        XCTAssertEqual(try text(settings), "{\"customModels\": []}\n")
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: targets.droid.deletingLastPathComponent().path)
        XCTAssertEqual(Set(siblings), ["mcp.json", "mcp.json.bak", "settings.json"])
    }

    // MARK: - Claude Desktop (VAL-REG-007)

    func testClaudeDesktopRegistration() throws {
        // The real machine's shape: coworkUserFilesPath and preferences, no
        // mcpServers. Registration creates the key and merges around both.
        let seed: [String: Any] = [
            "coworkUserFilesPath": "/Users/demo/ClaudeFiles",
            "preferences": ["theme": "dark", "autoUpdates": true] as [String: Any],
        ]
        try writeSeed(Self.jsonText(seed), to: targets.claudeDesktop)
        try MCPRegistration.Client.claudeDesktop.register(in: targets, command: command)
        var object = try readJSON(targets.claudeDesktop)
        XCTAssertEqual(
            try canonicalBytes(["c": object["coworkUserFilesPath"] as Any]),
            try canonicalBytes(["c": seed["coworkUserFilesPath"] as Any]))
        XCTAssertEqual(
            try canonicalBytes(["p": object["preferences"] as Any]),
            try canonicalBytes(["p": seed["preferences"] as Any]))
        // The documented desktop stdio shape: command and args, no type key.
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: object)),
            try canonicalBytes(["command": command, "args": ["mcp"]]))

        // With no directory at all, the whole nested chain and the file are created,
        // 0600, no .bak, holding only mcpServers.
        let freshRoot = try TempDir.make()
        let fresh = makeTargets(root: freshRoot)
        XCTAssertFalse(fileExists(fresh.claudeDesktop.deletingLastPathComponent()))
        try MCPRegistration.Client.claudeDesktop.register(in: fresh, command: command)
        object = try readJSON(fresh.claudeDesktop)
        XCTAssertEqual(Set(object.keys), ["mcpServers"])
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: object)),
            try canonicalBytes(["command": command, "args": ["mcp"]]))
        XCTAssertEqual(try permissions(fresh.claudeDesktop), 0o600)
        XCTAssertFalse(fileExists(fresh.claudeDesktop.appendingPathExtension("bak")))
    }

    // MARK: - idempotency, the rolling .bak, a moved binary (VAL-REG-008)

    func testIdempotencyBakMovedBinary() throws {
        for client in MCPRegistration.Client.allCases {
            let url = client.configURL(in: targets)
            try client.register(in: targets, command: command)
            let first = try text(url)
            XCTAssertFalse(fileExists(url.appendingPathExtension("bak")),
                           "\(client): a brand-new file has no .bak on its first write")

            // A second run with the same inputs leaves the file byte-identical and the
            // .bak byte-equal to the current file (the rolling one-step backup).
            try client.register(in: targets, command: command)
            XCTAssertEqual(try text(url), first, "\(client): a second run is byte-identical")
            XCTAssertEqual(
                try text(url.appendingPathExtension("bak")), first,
                "\(client): the .bak rolls to the current file")
            XCTAssertEqual(try permissions(url), 0o600, "\(client): the file is 0600")
            XCTAssertEqual(try permissions(url.appendingPathExtension("bak")), 0o600, "\(client): the .bak is 0600")

            // A moved binary re-registration updates the path, present exactly once.
            let moved = "/Moved/Keysrs.app/Contents/MacOS/keys"
            try client.register(in: targets, command: moved)
            let after = try text(url)
            XCTAssertFalse(after.contains(command), "\(client): no stale command after the move")
            XCTAssertTrue(after.contains(moved), "\(client): the moved command is written")
            XCTAssertEqual(
                try text(url.appendingPathExtension("bak")), first,
                "\(client): the .bak holds the immediately-previous content")
            XCTAssertEqual(try permissions(url), 0o600)
            XCTAssertEqual(try permissions(url.appendingPathExtension("bak")), 0o600)
        }
    }

    // MARK: - removal (VAL-REG-009)

    func testRemoval() throws {
        // Seed all five with our entry plus user entries of their own.
        try writeSeed(Self.jsonText([
            "mcpServers": [
                MCPRegistration.serverName:
                    ["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()],
                "everything-server": ["command": "/opt/everything/bin/server"],
            ] as [String: Any],
            "projects": ["/Users/demo/work/a": ["allowedTools": ["Read"]]] as [String: Any],
            "numStartups": 3,
        ] as [String: Any]), to: targets.claudeCode)
        let claudeBefore = try text(targets.claudeCode)
        try writeSeed("""
        model = "gpt-5"

        [\(MCPRegistration.codexSection)]
        command = "\(command)"
        args = ["mcp"]

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"
        """ + "\n", to: targets.codex)
        try writeSeed(Self.jsonText([
            "mcpServers": [
                "claude-mem": ["command": "/usr/local/bin/claude-mem", "args": []],
                MCPRegistration.serverName: ["command": command, "args": ["mcp"]],
            ] as [String: Any],
        ] as [String: Any]), to: targets.cursor)
        try writeSeed(Self.jsonText([
            "persistentPermissions": ["Bash(git:*)": "allow"] as [String: Any],
            "mcpServers": [
                "sibling": ["type": "stdio", "command": "/opt/sibling/bin/srv", "args": ["-v"]],
                MCPRegistration.serverName: ["type": "stdio", "command": command, "args": ["mcp"]],
            ] as [String: Any],
        ] as [String: Any]), to: targets.droid)
        try writeSeed(Self.jsonText([
            "coworkUserFilesPath": "/Users/demo/ClaudeFiles",
            "preferences": ["theme": "dark"] as [String: Any],
            "mcpServers": [
                MCPRegistration.serverName: ["command": command, "args": ["mcp"]],
                "desktop-sibling": ["command": "/opt/desktop/bin/srv"],
            ] as [String: Any],
        ] as [String: Any]), to: targets.claudeDesktop)

        for client in MCPRegistration.Client.allCases {
            XCTAssertTrue(try client.remove(from: targets), "\(client): our entry was there to remove")
        }

        // Removal deletes only our entry and keeps every sibling and other top-level key.
        let claude = try readJSON(targets.claudeCode)
        XCTAssertEqual(try serverNames(in: claude), ["everything-server"])
        XCTAssertEqual((claude["numStartups"] as? Int), 3)
        XCTAssertEqual(
            try canonicalBytes(["p": claude["projects"] as Any]),
            try canonicalBytes(["p": (try readJSONString(claudeBefore))["projects"] as Any]))
        // The pre-remove file is in the rolling .bak, 0600.
        XCTAssertEqual(try text(targets.claudeCode.appendingPathExtension("bak")), claudeBefore)
        XCTAssertEqual(try permissions(targets.claudeCode.appendingPathExtension("bak")), 0o600)

        // The Codex neighbours are byte-identical.
        XCTAssertEqual(try text(targets.codex), """
        model = "gpt-5"

        [mcp_servers.node_repl]
        command = "npx"
        args = ["-y", "mcp-server-node-repl"]

        [mcp_servers.node_repl.env]
        NODE_ENV = "production"
        """ + "\n")

        let cursor = try readJSON(targets.cursor)
        XCTAssertEqual(try serverNames(in: cursor), ["claude-mem"])

        let droid = try readJSON(targets.droid)
        XCTAssertEqual(try serverNames(in: droid), ["sibling"])
        XCTAssertEqual((droid["persistentPermissions"] as? [String: Any])?.count, 1)

        // Claude Desktop keeps its sibling and both its own keys; when ours was the
        // only server, an mcpServers left empty by removal is dropped and the file
        // returns to exactly its two keys — never an mcpServers: null.
        let desktop = try readJSON(targets.claudeDesktop)
        XCTAssertEqual(try serverNames(in: desktop), ["desktop-sibling"])
        XCTAssertEqual((desktop["coworkUserFilesPath"] as? String), "/Users/demo/ClaudeFiles")
        XCTAssertNotNil(desktop["preferences"])
        let emptyRoot = try TempDir.make()
        let empty = MCPRegistration.Targets(
            claudeCode: emptyRoot.appendingPathComponent("claude.json"),
            codex: emptyRoot.appendingPathComponent("codex/config.toml"),
            cursor: emptyRoot.appendingPathComponent("cursor/mcp.json"),
            droid: emptyRoot.appendingPathComponent("factory/mcp.json"),
            claudeDesktop: emptyRoot.appendingPathComponent("Claude/claude_desktop_config.json")
        )
        try writeSeed(Self.jsonText([
            "coworkUserFilesPath": "/Users/demo/ClaudeFiles",
            "preferences": ["theme": "dark"] as [String: Any],
            "mcpServers": [
                MCPRegistration.serverName: ["command": command, "args": ["mcp"]],
            ] as [String: Any],
        ] as [String: Any]), to: empty.claudeDesktop)
        XCTAssertTrue(try MCPRegistration.Client.claudeDesktop.remove(from: empty))
        let dropped = try readJSON(empty.claudeDesktop)
        XCTAssertEqual(Set(dropped.keys), ["coworkUserFilesPath", "preferences"])

        // Removal when nothing was registered is a harmless no-op: no write, no .bak,
        // no error, no freshly created {} file.
        let noBak = targets.cursor.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: noBak)
        let cursorBytes = try text(targets.cursor)
        XCTAssertFalse(try MCPRegistration.Client.cursor.remove(from: targets))
        XCTAssertEqual(try text(targets.cursor), cursorBytes)
        XCTAssertFalse(fileExists(noBak))
        // A file without mcpServers at all.
        try writeSeed(Self.jsonText(["persistentPermissions": ["Read": "allow"]]), to: targets.droid)
        XCTAssertFalse(try MCPRegistration.Client.droid.remove(from: targets))
        XCTAssertEqual((try readJSON(targets.droid)["persistentPermissions"] as? [String: Any])?.count, 1)
        // A missing file.
        let missing = targets.claudeDesktop
        try FileManager.default.removeItem(at: missing)
        XCTAssertFalse(try MCPRegistration.Client.claudeDesktop.remove(from: targets))
        XCTAssertFalse(fileExists(missing))

        // Register → remove on fresh homes leaves the pinned end state per client:
        // the JSON files hold {}, the Codex file is empty again.
        let freshRoot = try TempDir.make()
        let fresh = makeTargets(root: freshRoot)
        for client in MCPRegistration.Client.allCases {
            try client.register(in: fresh, command: command)
            XCTAssertTrue(try client.remove(from: fresh))
        }
        for url in [fresh.claudeCode, fresh.cursor, fresh.droid, fresh.claudeDesktop] {
            XCTAssertEqual(try readJSON(url).count, 0, "\(url.path): {} minus the empty key")
        }
        XCTAssertEqual(try text(fresh.codex), "")
    }

    // MARK: - corrupt and wrong-typed inputs (VAL-REG-010)

    func testCorruptInputsRefused() throws {
        let broken: [(String, String)] = [
            ("truncated", "{\"mcpServers\": {\"keysrs\": {\"command\": \"/x"),
            ("stray comma", "{\"mcpServers\": {\"keysrs\": {},,}}"),
        ]
        for client in MCPRegistration.Client.allCases where client != .codex {
            let url = client.configURL(in: targets)
            for (label, garbage) in broken {
                try writeSeed(garbage, to: url)
                XCTAssertThrowsError(try client.register(in: targets, command: command), label) { error in
                    guard case AppError.usage(let message) = error else {
                        return XCTFail("\(client) \(label): expected a usage error, got \(error)")
                    }
                    XCTAssertTrue(message.contains(url.lastPathComponent), message)
                    XCTAssertTrue(message.contains("not valid JSON"), message)
                }
                XCTAssertEqual(try text(url), garbage, "\(client) \(label): never clobbered")
                XCTAssertFalse(fileExists(url.appendingPathExtension("bak")), "\(client) \(label): no .bak")
            }
        }
        // A wrong-typed mcpServers is refused with a usage error naming the file,
        // with the bytes untouched and no cast trap.
        for client in MCPRegistration.Client.allCases where client != .codex {
            let url = client.configURL(in: targets)
            for garbage in ["{\"mcpServers\": \"not-an-object\"}", "{\"mcpServers\": [\"keysrs\"]}"] {
                try writeSeed(garbage, to: url)
                XCTAssertThrowsError(try client.register(in: targets, command: command)) { error in
                    guard case AppError.usage(let message) = error else {
                        return XCTFail("\(client): expected a usage error, got \(error)")
                    }
                    XCTAssertTrue(message.contains(url.path), message)
                    XCTAssertTrue(message.contains("mcpServers"), message)
                }
                XCTAssertEqual(try text(url), garbage)
            }
        }
        // Our own entry under a wrong-typed value is refused, not replaced.
        for client in MCPRegistration.Client.allCases where client != .codex {
            let url = client.configURL(in: targets)
            let wrong = "{\"mcpServers\": {\"\(MCPRegistration.serverName)\": \"the user typed a string\"}}"
            try writeSeed(wrong, to: url)
            XCTAssertThrowsError(try client.register(in: targets, command: command)) { error in
                guard case AppError.usage(let message) = error else {
                    return XCTFail("\(client): expected a usage error, got \(error)")
                }
                XCTAssertTrue(message.contains(url.path), message)
                XCTAssertTrue(message.contains(MCPRegistration.serverName), message)
            }
            XCTAssertEqual(try text(url), wrong, "the user's value under our name is their data, not ours")
            XCTAssertThrowsError(
                try client.remove(from: targets),
                "removal refuses the same way instead of deleting the user's value")
        }
    }

    // MARK: - no secret ever reaches a file (VAL-REG-011)

    func testNoSecretWritten() throws {
        // register → re-register → user-edit → re-run → remove, on all five clients.
        for client in MCPRegistration.Client.allCases {
            try client.register(in: targets, command: command)
            try client.register(in: targets, command: command)
            let url = client.configURL(in: targets)
            if client == .codex {
                try writeSeed("""
                [\(MCPRegistration.codexSection)]
                command = "\(command)"
                args = ["mcp"]

                [mcp_servers.user]
                command = "npx"
                """ + "\n", to: url)
            } else {
                try writeSeed(Self.jsonText([
                    "mcpServers": [
                        "user-server": ["command": "/opt/user/bin/srv", "args": []],
                        MCPRegistration.serverName:
                            ["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()],
                    ] as [String: Any],
                    "userKey": ["a": 1],
                ] as [String: Any]), to: url)
            }
            try client.register(in: targets, command: command)
            try client.remove(from: targets)
        }
        assertNoSentinel(fixtureSecret, in: root)

        // A fresh registration's entries carry no env values at all (or an empty env
        // where the client's shape includes it), no KEYSRS_ token-variable reference,
        // and no URL of ours.
        let freshRoot = try TempDir.make()
        let fresh = makeTargets(root: freshRoot)
        try MCPRegistration.Client.claudeCode.register(in: fresh, command: command)
        try MCPRegistration.Client.cursor.register(in: fresh, command: command)
        try MCPRegistration.Client.droid.register(in: fresh, command: command)
        try MCPRegistration.Client.claudeDesktop.register(in: fresh, command: command)
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: try readJSON(fresh.claudeCode))),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"], "env": [String: Any]()]))
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: try readJSON(fresh.cursor))),
            try canonicalBytes(["command": command, "args": ["mcp"]]))
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: try readJSON(fresh.droid))),
            try canonicalBytes(["type": "stdio", "command": command, "args": ["mcp"]]))
        XCTAssertEqual(
            try canonicalBytes(try ourEntry(in: try readJSON(fresh.claudeDesktop))),
            try canonicalBytes(["command": command, "args": ["mcp"]]))
        for url in [fresh.claudeCode, fresh.cursor, fresh.droid, fresh.claudeDesktop] {
            let raw = try text(url)
            XCTAssertFalse(raw.contains("KEYSRS_"))
            XCTAssertFalse(raw.contains("http://127.0.0.1"))
        }
        assertNoSentinel(fixtureSecret, in: freshRoot)
    }

    // MARK: - confinement (VAL-REG-012)

    func testConfinement() throws {
        // The writers take explicit URLs, so a caller cannot reach the real home by
        // accident: every other case in this file drives temp URLs only. With the
        // overrides unset the production defaults apply; nothing here reads those
        // files — the assertions only check the resolved path strings.
        let produced = MCPRegistration.Targets.production
        let env = ProcessInfo.processInfo.environment
        if env["KEYS_CLAUDE_JSON"] == nil {
            XCTAssertTrue(produced.claudeCode.path.hasSuffix("/.claude.json"))
        }
        if env["CODEX_HOME"] == nil {
            XCTAssertTrue(produced.codex.path.hasSuffix("/.codex/config.toml"))
        }
        if env["KEYS_CURSOR_HOME"] == nil {
            XCTAssertTrue(produced.cursor.path.hasSuffix("/.cursor/mcp.json"))
        }
        if env["KEYS_CLAUDE_DESKTOP_HOME"] == nil {
            XCTAssertTrue(
                produced.claudeDesktop.path
                    .hasSuffix("Application Support/Claude/claude_desktop_config.json"))
        }
        if env["KEYS_DROID_HOME"] == nil {
            XCTAssertTrue(produced.droid.path.hasSuffix("/.factory/mcp.json"))
        }
        // The five targets resolve from the documented override variables; these are
        // path-string checks, never file reads.
        XCTAssertEqual(produced.claudeCode, Paths.claudeJSON)
        XCTAssertEqual(produced.codex, CodexSetup.configURL(home: Paths.codexHome))
        XCTAssertEqual(produced.cursor, Paths.cursorHome.appendingPathComponent("mcp.json"))
        XCTAssertEqual(produced.droid, Paths.droidHome.appendingPathComponent("mcp.json"))
        XCTAssertEqual(
            produced.claudeDesktop,
            Paths.claudeDesktopHome.appendingPathComponent("claude_desktop_config.json"))
    }

    // MARK: - the CLI surface (VAL-REG-013)

    func testMCPSurface() throws {
        // `mcp` parses as the agent argument, before any vault-key resolution.
        let command = try XCTUnwrap(try KeysCLI.parseAsRoot(["setup", "mcp"]) as? SetupCommand)
        XCTAssertEqual(command.agent, "mcp")
        XCTAssertFalse(command.remove)
        XCTAssertFalse(command.json)
        // --remove parses on the mcp surface and covers all five clients (no selectors).
        let removing = try XCTUnwrap(try KeysCLI.parseAsRoot(["setup", "mcp", "--remove"]) as? SetupCommand)
        XCTAssertTrue(removing.remove)
        let json = try XCTUnwrap(try KeysCLI.parseAsRoot(["setup", "mcp", "--json"]) as? SetupCommand)
        XCTAssertTrue(json.json)
        // Trailing junk and bad flags are parse failures, never "unknown agent".
        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["setup", "mcp", "extra"]))
        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["setup", "mcp", "--bogus"]))
        // The branch sits above the vault-key resolution: the writer surface takes no
        // key at all, and covers exactly the five clients.
        XCTAssertEqual(MCPRegistration.Client.allCases.count, 5)
    }

    func testReportJSONIsOneSortedLine() throws {
        let paths = [
            "claude_code": "/t/claude.json",
            "claude_desktop": "/t/desktop.json",
            "codex": "/t/config.toml",
            "cursor": "/t/mcp.json",
            "droid": "/t/factory/mcp.json",
        ]
        let register = MCPRegistration.reportJSON(action: "register", clients: paths, command: "/x/keys")
        var line = String(decoding: try JSONValue.data(register), as: UTF8.self)
        XCTAssertFalse(line.contains("\n"), "one line, the shape every --json flag prints")
        var parsed = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(try JSONValue.data(parsed), Data(line.utf8), "keys must be sorted")
        XCTAssertEqual(parsed["server"] as? String, MCPRegistration.serverName)
        XCTAssertEqual(parsed["action"] as? String, "register")
        XCTAssertEqual(parsed["command"] as? String, "/x/keys")
        XCTAssertEqual(parsed["clients"] as? [String: String], paths)
        XCTAssertFalse(line.contains(fixtureSecret))

        let remove = MCPRegistration.reportJSON(action: "remove", clients: paths, command: nil)
        line = String(decoding: try JSONValue.data(remove), as: UTF8.self)
        parsed = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(try JSONValue.data(parsed), Data(line.utf8))
        XCTAssertNil(parsed["command"] as Any?, "removal resolved no executable")
        XCTAssertFalse(line.contains(fixtureSecret))
    }

    // MARK: - helpers

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try readJSONString(try text(url))
    }

    private func readJSONString(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONValue.object(try JSONSerialization.jsonObject(with: Data(text.utf8))))
    }

    private func ourEntry(in object: [String: Any]) throws -> [String: Any] {
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        return try XCTUnwrap(servers[MCPRegistration.serverName] as? [String: Any])
    }

    /// The names registered under mcpServers, empty when the key is absent.
    private func serverNames(in object: [String: Any]) -> Set<String> {
        Set(((object["mcpServers"] as? [String: Any]) ?? [:]).keys)
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func writeSeed(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func permissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Canonical sorted-key bytes of one JSON value, so deep equality is a byte
    /// comparison (key order may change because the writer sorts keys).
    private func canonicalBytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// The house JSON text form: 2-space pretty, sorted keys, a trailing newline.
    private static func jsonText(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
