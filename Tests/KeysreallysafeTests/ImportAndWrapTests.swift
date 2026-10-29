import Foundation
import XCTest
@testable import KeysCore

/// VAL-IMW-001..013: the `import_and_wrap` flow — the app-side service, the
/// origin-token-gated route, and the MCP tool that relays it — plus the fail-closed
/// real-app isolation guard every control-channel test now runs through (owner
/// directive 2026-10-28). Every rig is a temp catalog beside a temp control file with
/// a fake presence gate and a fake secret store; nothing here can reach the installed
/// app, the real Keychain or ~/Library/Application Support/Keysreallysafe, and the
/// guard fails the test loudly if a path under test ever resolves there. Every "key"
/// is an obviously fake body built at runtime; the one real token the flow mints is
/// asserted only where it lives — the rewritten env file — never on the wire.
final class ImportAndWrapTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var openrouterValue: String { "sk-or-" + fakeBody + "02" }
    private var groqValue: String { "gsk_" + fakeBody + "03" }
    private var plainValue: String { "sk-" + fakeBody + "04" }
    private var awsAccessValue: String { "AKIA" + fakeBody + "05" }
    private var awsSecretValue: String { fakeBody + "AWSSECRET06" }
    private var vertexValue: String { "vt-" + fakeBody + "07" }
    private var stripeValue: String { "sk_" + fakeBody + "08" }
    private var clientTokenValue: String { GatewayClientToken.prefix + String(repeating: "a", count: 48) }

    // MARK: - Rigs

    /// A gated service over a temp catalog. The owner directive's guard runs on the
    /// catalog path first: a rig that somehow resolved to the production location
    /// fails closed before a single byte moves.
    private struct Vault {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let dir: URL
    }

    private func makeVault(secrets: MemorySecretStore = MemorySecretStore()) throws -> Vault {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db, secrets: secrets)
        return Vault(service: service, db: db, gate: gate, dir: dir)
    }

    /// A project folder named `name` inside the vault's temp tree.
    @discardableResult
    private func makeProject(_ name: String = "acme", in dir: URL) throws -> URL {
        let project = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// Writes an env file at `relative` under `root`, creating intermediate folders.
    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL, mode: mode_t? = nil) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let mode { chmod(url.path, mode) }
        return url
    }

    /// The in-process app: a real APIHandler over a temp catalog behind a recording
    /// loopback server on an ephemeral port, `control.json` beside that same catalog —
    /// the shape the import tool reaches. Guarded against production paths like every
    /// other control-channel rig (owner directive 2026-10-28).
    private struct Site {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let log: RequestLog
        let control: URL
        let dir: URL
    }

    private func makeSite() throws -> Site {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        addTeardownBlock { server.stop() }
        let control = ControlFile.url(beside: db.path)
        // Both isolation guards: the onboarding-side path check and the shared
        // configuration guard, before any write.
        try assertNotProductionPath(control)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(
            service: service, db: db, gate: gate, handler: handler, server: server, log: log,
            control: control, dir: dir
        )
    }

    /// A control URL no live site answers: a fresh temp tree with no control.json in
    /// it — guarded like every other control-channel path.
    private func deadControl() throws -> URL {
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try assertNotProductionPath(control)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        return control
    }

    /// The onboarding group wired over injected seams, never the machine's real
    /// catalog or installed app.
    private func roster(
        control: URL,
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath }
    ) -> MCPToolRegistry {
        MCPToolRegistry(groups: [MCPOnboardingTools(control: control, projectFolder: projectFolder, launch: .neverLaunching)])
    }

    /// One import tools/call through real server frames — the surface the model sees.
    private func callTool(
        _ registry: MCPToolRegistry,
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"import_and_wrap","arguments":\#(argumentsJSON)}}"#,
        ], registry: registry, file: file, line: line)
        XCTAssertEqual(frames.last, "", file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    /// The service result as the wire renders it, for shape and leak assertions.
    private func wire(_ payload: [String: Any]) throws -> String {
        String(decoding: try JSONValue.data(payload), as: UTF8.self)
    }

    /// Values never touch disk outside the env file and its 0600 backup.
    private func assertNoSentinel(_ needle: String, in dir: URL, skipping: [URL],
                                   file: StaticString = #filePath, line: UInt = #line) {
        let skip = Set(skipping.map { $0.resolvingSymlinksInPath().path })
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard !skip.contains(url.resolvingSymlinksInPath().path), let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: Data(needle.utf8)), "\(url.lastPathComponent) holds a value", file: file, line: line)
        }
    }

    /// Every `keysrs-backup` file anywhere under `dir` — after VAL-O-002 the only
    /// place one exists is the catalog's own backups tree; the project holds none.
    private func backupFiles(under dir: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent.contains("keysrs-backup") { out.append(url) }
        }
        return out
    }

    // MARK: - VAL-IMW-001 (one prompt, naming keys and project label)

    /// The whole import happens under exactly one presence call whose reason names the
    /// keys being imported/wrapped and the project's label — never a path, a value or
    /// a token. Existing values reuse their key; AWS pairs and credential URLs import
    /// under the reserved "imported" id and stay in place.
    func testOnePromptNamesKeysAndProjectLabel() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try vault.service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        try write("""
        OPENAI_API_KEY=\(plainValue)
        ANTHROPIC_API_KEY=\(anthropicValue)
        ROUTER_API_KEY=\(openrouterValue)
        DATABASE_URL=postgres://u:p@h/db
        """, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertEqual(vault.gate.reasons.count, 1, "exactly one presence call for the whole import")
        let reason = vault.gate.reasons[0]
        XCTAssertEqual(
            reason,
            "import and wrap 4 keys for project acme: openai, anthropic, openrouter, database-url",
            "the reason names the keys and the project label"
        )
        XCTAssertFalse(reason.contains(project.path), "no path in the reason")
        XCTAssertFalse(reason.contains(fakeBody), "no value in the reason")
        XCTAssertFalse(reason.contains("ksfc_"), "no token in the reason")

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["status"] as? String }, ["wrapped", "wrapped", "wrapped", "imported_not_wrapped"])
        XCTAssertEqual(outcomes.map { $0["key"] as? String }, ["openai", "anthropic", "router", "imported"])
        XCTAssertEqual(result["project_label"] as? String, "acme")
    }

    // MARK: - VAL-O-003 (the docker flag is named in the one prompt)

    /// docker:true also turns on the global Docker gateway access, so the single
    /// Touch ID reason must say so: the one prompt names the keys, the project AND
    /// the Docker access it opens. The docker:false wording keeps its pin above
    /// (testOnePromptNamesKeysAndProjectLabel). Failed pre-fix: the docker:true
    /// reason named only the keys and the project, and the preference flipped
    /// unannounced.
    func testTheDockerFlagIsNamedInTheSinglePrompt() throws {
        let vault = try makeVault()
        let project = try makeProject("dockreason", in: vault.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        _ = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: true)

        XCTAssertEqual(vault.gate.reasons.count, 1, "still exactly one presence call for the whole import")
        XCTAssertEqual(
            vault.gate.reasons[0],
            "import and wrap 1 key for project dockreason: openai"
                + " and allow Docker containers to reach the gateway",
            "the one reason names the keys, the project and the Docker access it turns on"
        )
        XCTAssertFalse(vault.gate.reasons[0].contains(project.path), "still no path in the reason")
        XCTAssertEqual(try vault.db.metaValue(AppPreferences.dockerAccessKey), "on",
                       "the preference is set once the rewrite succeeded")
    }

    // MARK: - VAL-O-002 (backups are kept outside the project, under the catalog)

    /// The wrap-time backup holds the original secret values, so it must not sit in
    /// the project the agent works in — one `git add -A` away from the repo, one
    /// `git clean` away from gone. The import keeps it under the catalog's own
    /// backups tree instead (the file's hashed folder, 0700 directory, 0600 file),
    /// the result states it without a path, nothing backup-shaped exists under the
    /// project, and unwrap restores from the new location. The inverted
    /// backup-beside-the-file pins are the pre-fix evidence; this is the new
    /// location's white box.
    func testBackupsLiveOutsideTheProjectUnderTheCatalog() throws {
        let site = try makeSite()
        let project = try makeProject("keptbackups", in: site.dir)
        let original = "OPENAI_API_KEY=\(plainValue)\nOPENAI_BASE_URL=https://api.example.internal/v1\n"
        let env = try write(original, to: "sub/.env", under: project)

        let result = try site.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertTrue(
            try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty,
            "no backup file exists under the project"
        )
        let root = EnvFileWriter.backupsRoot(beside: site.db.path)
        XCTAssertEqual(
            root.path, site.db.path.deletingLastPathComponent().appendingPathComponent("backups").path,
            "the backups tree is a sibling of the catalog, like control.json and relay.lock"
        )
        let dir = try XCTUnwrap(EnvFileWriter.backupDirectory(for: env, under: root))
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.count, 1, "one backup in the file's hashed folder")
        XCTAssertTrue(names[0].hasPrefix(".env.keysrs-backup-"), "the backup keeps the wrapped file's name")
        let backup = dir.appendingPathComponent(names[0])
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8), "the backup holds the original bytes")
        XCTAssertEqual(try EnvFileWriter.currentMode(backup), 0o600)
        XCTAssertEqual(try EnvFileWriter.currentMode(dir), 0o700, "the hashed folder is 0700")
        XCTAssertEqual(try EnvFileWriter.currentMode(root), 0o700, "the backups root is 0700")
        XCTAssertEqual(result["backup_kept_outside_project"] as? Bool, true)
        let wire = try wire(result)
        XCTAssertFalse(wire.contains(site.dir.path), "no absolute path in the result")
        XCTAssertFalse(wire.contains(root.path), "the backup location is not spelled out")

        // unwrap restores from the new location: the replaced companion comes back
        // with its original value, byte-for-byte — proof the restore read the
        // outside-the-project backup (the fallback would have removed the line).
        _ = try site.service.unwrap(file: env.path, folder: nil)
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8),
                       "unwrap restores byte-for-byte from the backup kept outside the project")
    }

    // MARK: - VAL-O-007 (a rewrite failure revokes the minted token; no path leaks)

    /// The project token is minted right before the rewrite, so a rewrite that
    /// fails after it must not leave a live 30-day token with no file pointing at
    /// it: the failure path revokes the just-minted token (with its client_revoke
    /// audit row), rethrows a message with no absolute path, leaves the docker
    /// preference untouched (VAL-O-003's ordering) and records nothing. The
    /// injected failure is deterministic: a plain file squatting on the backups
    /// tree's root, so the very first backup cannot be created. Failed pre-fix:
    /// the import succeeded (the blocker changed nothing) and the token stayed
    /// live with no audit row.
    func testARewriteFailureRevokesTheMintedTokenAndNamesNoPath() throws {
        let vault = try makeVault()
        let project = try makeProject("failedrewrite", in: vault.dir)
        let original = "OPENAI_API_KEY=\(plainValue)\n"
        let env = try write(original, to: ".env", under: project)
        // The blocker: a regular file where the backups tree's root would go.
        try Data("x".utf8).write(to: EnvFileWriter.backupsRoot(beside: vault.db.path))

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: true)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertFalse(message.contains("/"), "the error text carries no path: \(message)")
        }

        // The just-minted project token is revoked, and the audit row says so.
        let clients = try vault.db.gatewayClients(keyName: "openai")
        XCTAssertEqual(clients.count, 1, "the minted client row exists")
        XCTAssertNotNil(clients[0].revokedAt, "the rewrite failure revoked the minted project token")
        XCTAssertTrue(
            try vault.db.keyEvents(name: "openai", limit: 10).contains { $0.action == "client_revoke" },
            "the revocation wrote its client_revoke audit row"
        )
        // The docker preference is set only after a successful rewrite (VAL-O-003).
        XCTAssertNil(try vault.db.metaValue(AppPreferences.dockerAccessKey),
                     "a failed rewrite leaves the docker preference untouched")
        // Nothing was recorded, and the file kept its original bytes.
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty, "no wrapped_files record survived")
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8), "the file was not rewritten")
    }

    // MARK: - VAL-O-009 (a symlinked directory swapped under the prompt is refused)

    /// The scan resolves every entry before reading it, but the apply-time pass used
    /// the report's UNRESOLVED spelling — so a directory symlink swapped during the
    /// parked Touch ID window made the import read, back up and wrap a file OUTSIDE
    /// the project root under the one approval. The verify pass and the pre-write
    /// re-check both resolve the file through POSIX realpath and prove it is still
    /// inside the project root; the swapped symlink is refused with the path-free
    /// nothing-was-imported error, nothing is stored, and the outside target is
    /// untouched. Failed pre-fix: the import succeeded — the outside file was read
    /// as the original, its backup landed in the outside tree, and the value was
    /// stored and recorded.
    func testASymlinkedDirectorySwappedUnderThePromptIsRefused() throws {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let gate = BlockingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true),
            openRouter: OpenRouterHTTP(),
            relaySecrets: MemorySecretStore()
        )
        let project = try makeProject(in: dir)
        // The env file lives in realdir; `ali` is a directory symlink to it that
        // sorts BEFORE `realdir`, so the scan reports the file through `ali` — the
        // spelling a swap can redirect.
        let original = "OPENAI_API_KEY=\(plainValue)\n"
        _ = try write(original, to: "realdir/.env", under: project)
        try fm.createSymbolicLink(
            atPath: project.appendingPathComponent("ali").path,
            withDestinationPath: project.appendingPathComponent("realdir").path
        )
        // The outside target: the same variable and value, so nothing but the
        // resolved-path containment check can tell the two apart.
        let outside = try TempDir.make()
        let outsideEnv = try write(original, to: "inside/.env", under: outside)
        let outsideData = try Data(contentsOf: outsideEnv)

        // The prompt parks; the symlink is swapped to the outside tree; release.
        let alias = project.appendingPathComponent("ali")
        let outsideDir = outsideEnv.deletingLastPathComponent()
        let fileManager = FileManager.default
        let swapped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = gate.waitPrompts(1, timeout: 10)
            try? fileManager.removeItem(atPath: alias.path)
            try? fileManager.createSymbolicLink(atPath: alias.path, withDestinationPath: outsideDir.path)
            swapped.signal()
            gate.release()
        }

        XCTAssertThrowsError(
            try service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertEqual(message, "a file in the project could not be read; nothing was imported",
                           "the path-free refusal, before anything was stored or written")
        }
        XCTAssertEqual(swapped.wait(timeout: .now() + 10), .success)

        // The outside target is untouched: same bytes, no backup landed in its tree,
        // and the import stored nothing and recorded nothing anywhere.
        XCTAssertEqual(try Data(contentsOf: outsideEnv), outsideData, "the outside file is untouched")
        XCTAssertTrue(try backupFiles(under: outside).isEmpty,
                      "no keysrs-backup landed in the outside tree")
        XCTAssertEqual(try service.list(), [], "the value was never stored from the outside file")
        XCTAssertTrue(try db.listWrappedFiles().isEmpty, "no record was written")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty)
    }

    // MARK: - VAL-IMW-002 (the app reads the values; nothing crosses the MCP surface)

    /// The MCP request carries the folder, names and flags only; the request log proves
    /// it; the tool result and every disk surface hold no value and no token outside
    /// the env file and its backup.
    func testTheAppReadsTheValuesAndNothingLeaks() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        let env = try write("""
        # agent config
        export OPENAI_API_KEY="\(plainValue)" # router
        GROQ_API_KEY=\(groqValue)
        """, to: ".env", under: project)

        let (isError, text) = try callTool(
            roster(control: site.control, projectFolder: { project.path }),
            arguments: ["folder": project.path]
        )
        XCTAssertFalse(isError, "an unexpected tool error: \(text)")
        XCTAssertFalse(text.contains(fakeBody), "no value in the tool result")
        XCTAssertFalse(text.contains("ksfc_"), "no token in the tool result")

        // The wire: exactly one import call, its body the folder alone — no value, no
        // variable name even, because no filter was requested.
        let calls = site.log.all.filter { $0.path == "/api/mcp/import_and_wrap" }
        XCTAssertEqual(calls.count, 1, "one app call for the whole import")
        XCTAssertEqual(calls[0].method, "POST")
        XCTAssertEqual(calls[0].headers["x-ksf-token"], site.handler.originToken, "origin-token gated")
        let body = String(decoding: calls[0].body, as: UTF8.self)
        let sent = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        XCTAssertEqual(Set(sent.keys), ["folder"], "names and flags only cross the wire")
        XCTAssertFalse(body.contains(fakeBody), "no value crossed the wire")

        // The file was rewritten by the app: token in, raw value gone.
        let rewritten = try String(contentsOf: env, encoding: .utf8)
        XCTAssertFalse(rewritten.contains(fakeBody), "the raw value is gone from the file")
        XCTAssertTrue(rewritten.contains("ksfc_"), "the one token is in the file")
        XCTAssertTrue(rewritten.contains("export OPENAI_API_KEY=\"ksfc_"), "export and quotes kept")

        // And nothing value-shaped landed anywhere else on disk. The backup never
        // lands inside the project (VAL-O-002): the original values are kept under
        // the catalog's own backups tree instead, and that file is the one place a
        // value legitimately lives outside the env file.
        XCTAssertTrue(
            try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty,
            "no backup file exists under the project"
        )
        assertNoSentinel(fakeBody, in: site.dir, skipping: [env] + backupFiles(under: site.dir))
    }

    // MARK: - VAL-IMW-003 (dedupe by value)

    /// An existing same-value key is reused (new: false, no duplicate row); the same
    /// new value twice shares one new key — both lines get the same token.
    func testDedupeByValue() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try vault.service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        try write("""
        ROUTER_API_KEY=\(openrouterValue)
        GROQ_API_KEY=\(groqValue)
        GROQ2_API_KEY=\(groqValue)
        """, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes[0]["key"] as? String, "router", "the existing key is reused")
        XCTAssertEqual(outcomes[0]["new"] as? Bool, false)
        XCTAssertEqual(outcomes[1]["key"] as? String, "groq", "the first sighting names the key")
        XCTAssertEqual(outcomes[2]["key"] as? String, "groq", "the duplicate shares it")
        XCTAssertEqual(outcomes[2]["new"] as? Bool, true)
        XCTAssertEqual(Set(try vault.service.list().map(\.name)), ["router", "groq"],
                       "no duplicate key was created")

        let file = EnvFile.parse(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8))
        let first = try XCTUnwrap(file.value(of: "GROQ_API_KEY"))
        XCTAssertEqual(file.value(of: "GROQ2_API_KEY"), first, "both lines hold the one token")
    }

    // MARK: - VAL-IMW-004 (new keys: suggested names, runtime kind, gateway on)

    /// New keys get WrapNames-suggested names (provider id, folder-slug hint, -2
    /// disambiguation), runtime kind, notes naming the import, and their gateway on —
    /// all under the single prompt.
    func testNewKeysStoredWithSuggestedNamesGatewayOn() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        // "openai" already exists holding a different value, so the suggestion disambiguates.
        try vault.service.add(name: "openai", provider: "openai", kind: "runtime", notes: "", secret: "zz" + fakeBody + "existing")
        try write("""
        OPENAI_API_KEY=\(plainValue)
        ANTHROPIC_API_KEY=\(anthropicValue)
        """, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let byName = Dictionary(
            (result["variables"] as! [[String: Any]]).map { ($0["key"] as? String ?? "", $0) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertEqual(byName["openai-acme"]?["variable"] as? String, "OPENAI_API_KEY",
                       "the taken provider id disambiguates with the folder slug")
        XCTAssertEqual(byName["anthropic"]?["variable"] as? String, "ANTHROPIC_API_KEY",
                       "an untaken provider id is the name")

        let rows = Dictionary(try vault.service.list().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows["openai-acme"]?.provider, "openai")
        XCTAssertEqual(rows["anthropic"]?.kind, "runtime")
        XCTAssertEqual(rows["anthropic"]?.notes, "imported by import_and_wrap for acme")
        XCTAssertTrue(vault.service.isGatewayEnabled("openai-acme"), "the gateway is on for the new key")
        XCTAssertTrue(vault.service.isGatewayEnabled("anthropic"))
        XCTAssertEqual(vault.gate.reasons.count, 1, "one prompt covered the adds and the enables")
    }

    // MARK: - VAL-IMW-005 (one project token, 30-day expiry)

    /// Exactly one client token is minted for the project — one row, one hash, one
    /// hint, one 30-day expiry — with one membership row per wrapped key; every wrapped
    /// line holds that one token and each key's base URL differs by name.
    func testOneProjectTokenWithMembersAndExpiry() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try write("""
        OPENAI_API_KEY=\(plainValue)
        ANTHROPIC_API_KEY=\(anthropicValue)
        GROQ_API_KEY=\(groqValue)
        """, to: ".env", under: project)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false, now: now)

        let expiresAt = UTC.iso(now.addingTimeInterval(TimeInterval(GatewayClientToken.defaultDays) * 86_400))
        XCTAssertEqual(result["expires_at"] as? String, expiresAt, "the result reports the 30-day expiry")

        // ONE row: the first member's name is the row's key_name, and no other row exists.
        let clients = try vault.service.gatewayClients(name: "openai")
        XCTAssertEqual(clients.count, 1, "exactly one gateway_clients row for the import")
        let client = clients[0]
        XCTAssertEqual(client.project, try vault.service.resolveProject(folder: project.path).id)
        XCTAssertEqual(client.label, "import_and_wrap acme")
        XCTAssertEqual(client.expiresAt, expiresAt)
        XCTAssertTrue(try vault.service.gatewayClients(name: "anthropic").isEmpty,
                      "the other members have no per-key rows of their own")

        // One membership row per wrapped key, each with its own approved host.
        let members = try vault.db.gatewayClientKeys(clientID: client.id)
        XCTAssertEqual(members.map(\.keyName), ["anthropic", "groq", "openai"], "one membership per wrapped key")
        for member in members {
            XCTAssertEqual(member.host, Providers.provider(id: member.keyName)?.host)
        }

        // The file: all three lines hold the ONE token, and the base URLs differ per key.
        let file = EnvFile.parse(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8))
        let token = try XCTUnwrap(file.value(of: "OPENAI_API_KEY"))
        XCTAssertEqual(file.value(of: "ANTHROPIC_API_KEY"), token, "one token on every wrapped line")
        XCTAssertEqual(file.value(of: "GROQ_API_KEY"), token)
        XCTAssertEqual(client.hint, GatewayClientToken.hint(token), "the row's hint is the token's last 4")
        XCTAssertEqual(file.value(of: "OPENAI_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/openai")
        XCTAssertEqual(file.value(of: "ANTHROPIC_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/anthropic")
        XCTAssertEqual(file.value(of: "GROQ_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/groq")

        // That one token authorizes every member key at the mint's own clock, and only
        // POST/GET.
        let memberCases: [(name: String, header: [String: String])] = [
            ("openai", ["authorization": "Bearer \(token)"]),
            ("anthropic", ["x-api-key": token]),
            ("groq", ["api-key": token]),
        ]
        for member in memberCases {
            if case .allowed = vault.service.authorizeGatewayClient(
                name: member.name, headers: member.header, method: "POST", rest: "/v1/messages", now: now
            ) {} else { XCTFail("the one token must serve \(member.name)") }
        }
        if case .allowed = vault.service.authorizeGatewayClient(
            name: "openai", headers: ["authorization": "Bearer \(token)"], method: "DELETE", rest: "/v1/messages"
        ) { XCTFail("DELETE is outside the minted scope") }
    }

    // MARK: - VAL-IMW-006 (the rewritten file)

    /// The rewrite touches the value span only: export, quotes, spacing and inline
    /// comments stay byte-identical, the file ends with a newline, the 0600 backup
    /// holds the original values, the raw value is gone, and the mode is kept.
    func testRewrittenFileKeepsEverythingButTheValueSpan() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        let original = """
        # agent config
        export OPENAI_API_KEY="\(plainValue)" # router
        DEBUG=1
        """  // no trailing newline on purpose
        let env = try write(original, to: ".env", under: project, mode: 0o640)

        _ = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let text = try String(contentsOf: env, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# agent config\n"), "comments are kept")
        XCTAssertTrue(text.contains("export OPENAI_API_KEY=\"ksfc_"), "export and the opening quote are kept")
        XCTAssertTrue(text.contains("\" # router\n"), "the closing quote and inline comment are kept")
        XCTAssertTrue(text.contains("DEBUG=1\n"), "untouched lines are untouched")
        XCTAssertTrue(text.hasSuffix("\n"), "the file ends with a newline")
        XCTAssertFalse(text.contains(fakeBody), "the raw value is gone")

        // The backup is kept outside the project (VAL-O-002), under the catalog's
        // own backups tree: the original bytes, 0600, inside a 0700 folder.
        XCTAssertTrue(
            try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty,
            "no backup beside the file"
        )
        let backups = try backupFiles(under: vault.dir)
        XCTAssertEqual(backups.count, 1, "one backup under the catalog's backups tree")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8), "the backup holds the original bytes")
        XCTAssertEqual(try EnvFileWriter.currentMode(backup), 0o600)
        XCTAssertEqual(
            try EnvFileWriter.currentMode(URL(fileURLWithPath: backup.deletingLastPathComponent().path)), 0o700,
            "the backup's folder is 0700"
        )
        XCTAssertEqual(try EnvFileWriter.currentMode(env), 0o640, "the rewritten file keeps its mode")
    }

    // MARK: - VAL-IMW-007 (non-proxyable imported, left in place)

    /// A gateway:false provider, an AWS SigV4 pair and a credential URL are all
    /// imported into the vault but their lines are left untouched, each outcome
    /// reporting the `keys env` fallback command shape.
    func testNonProxyableImportedButLeftInPlace() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        let original = """
        VERTEX_API_KEY=\(vertexValue)
        AWS_ACCESS_KEY_ID=\(awsAccessValue)
        AWS_SECRET_ACCESS_KEY=\(awsSecretValue)
        DATABASE_URL=postgres://u:p@h/db
        """
        let env = try write(original, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertEqual(vault.gate.reasons.count, 1, "the import still happens under one prompt")
        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["status"] as? String },
                       Array(repeating: "imported_not_wrapped", count: 4))
        let byName = Dictionary(outcomes.map { ($0["variable"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        for (variable, name) in [
            ("VERTEX_API_KEY", "vertex"), ("AWS_ACCESS_KEY_ID", "imported"),
            ("AWS_SECRET_ACCESS_KEY", "imported-acme"), ("DATABASE_URL", "imported-2"),
        ] {
            XCTAssertEqual(byName[variable]?["key"] as? String, name, "\(variable) imports under a suggested name")
            let reason = byName[variable]?["reason"] as? String ?? ""
            XCTAssertTrue(reason.contains("keys env \(name)"), "\(variable)'s outcome reports the keys env fallback: \(reason)")
        }
        XCTAssertTrue((byName["VERTEX_API_KEY"]?["reason"] as? String ?? "").contains("Google Vertex AI"),
                      "the refusal names the provider")

        // In the vault, under the right provider ids; gateway off; lines untouched; no
        // backup, no token, no rewrite.
        let rows = Dictionary(try vault.service.list().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows["vertex"]?.provider, "vertex", "the gateway:false provider keeps its own id")
        XCTAssertEqual(rows["imported"]?.provider, "imported", "the reserved id for what the scan found")
        XCTAssertEqual(rows["imported-acme"]?.provider, "imported")
        XCTAssertFalse(vault.service.isGatewayEnabled("vertex"), "nothing was enabled for a non-proxyable key")
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8), "the file is byte-identical")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty,
                      "no backup: nothing was rewritten")
        XCTAssertTrue(try backupFiles(under: vault.dir).isEmpty, "no backup anywhere: nothing was rewritten")
        XCTAssertEqual(result["backup_kept_outside_project"] as? Bool, false,
                       "the result states honestly that no backup was kept")
        XCTAssertTrue(result["expires_at"] is NSNull, "no token was minted")
    }

    // MARK: - VAL-IMW-008 (unrecognized values are not imported)

    /// A key-shaped value with no recognized provider and no vault match is not
    /// imported, not wrapped, and reported with the wrapPlan refusal wording.
    func testProviderlessUnvaultedNotImported() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        let original = "STRIPE_SECRET_KEY=\(stripeValue)\n"
        let env = try write(original, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0]["status"] as? String, "skipped")
        XCTAssertEqual(
            outcomes[0]["reason"] as? String,
            "not in the vault and no provider recognised; add it with keys add, then rerun",
            "the wrapPlan refusal wording"
        )
        XCTAssertTrue(outcomes[0]["key"] is NSNull, "nothing was stored")
        XCTAssertTrue(try vault.service.list().isEmpty)
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8), "the line is untouched")
        XCTAssertTrue(result["expires_at"] is NSNull)
    }

    // MARK: - VAL-IMW-009 (the docker flag only acts when true)

    /// docker:true sets pref_docker_access on and writes host.docker.internal base
    /// URLs; absent/false leaves the pref untouched (absent = off) and writes loopback.
    func testDockerFlagOnlyActsWhenTrue() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertNil(try vault.db.metaValue(AppPreferences.dockerAccessKey),
                     "absent/false never touches the pref")
        XCTAssertEqual(result["docker_access"] as? Bool, false)
        XCTAssertEqual(result["base_url_host"] as? String, "127.0.0.1")
        let file = EnvFile.parse(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8))
        XCTAssertEqual(file.value(of: "OPENAI_BASE_URL"), "http://127.0.0.1:\(GatewayListener.port)/openai")

        // A second import, docker true: the pref turns on, the URLs point at Docker's
        // host. A distinct new value so the second import adds its own key, whose
        // suggested name carries THIS project's folder slug.
        let project2 = try makeProject("dockproj", in: vault.dir)
        try write("OPENAI_API_KEY=sk-\(fakeBody)09\n", to: ".env", under: project2)
        let result2 = try vault.service.importAndWrap(folder: project2.path, variables: nil, docker: true)

        XCTAssertEqual(try vault.db.metaValue(AppPreferences.dockerAccessKey), "on")
        XCTAssertEqual(result2["docker_access"] as? Bool, true, "the live setting reflects the change")
        XCTAssertEqual(result2["base_url_host"] as? String, "host.docker.internal")
        let file2 = EnvFile.parse(try String(contentsOf: project2.appendingPathComponent(".env"), encoding: .utf8))
        XCTAssertEqual(file2.value(of: "OPENAI_BASE_URL"), "http://host.docker.internal:\(GatewayListener.port)/openai-dockproj",
                      "the base URL points at host.docker.internal for the docker import")
    }

    // MARK: - VAL-IMW-010 (the result shape)

    /// The result carries exactly the pinned top-level and per-outcome keys, relative
    /// file paths, and no absolute path anywhere.
    func testResultShapeIsExact() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try vault.service.add(name: "router", provider: "openrouter", kind: "runtime", notes: "", secret: openrouterValue)
        try write("""
        OPENAI_API_KEY=\(plainValue)
        ROUTER_API_KEY=\(openrouterValue)
        DATABASE_URL=postgres://u:p@h/db
        STRIPE_SECRET_KEY=\(stripeValue)
        ALREADY_WRAPPED=\(clientTokenValue)
        """, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertEqual(Set(result.keys),
                       ["project_label", "expires_at", "docker_access", "base_url_host", "backup_kept_outside_project", "variables"],
                       "exactly the six top-level keys")
        XCTAssertEqual(result["project_label"] as? String, "acme")
        XCTAssertTrue(result["expires_at"] is String)
        XCTAssertEqual(result["backup_kept_outside_project"] as? Bool, true,
                       "the result states a backup was kept outside the project")
        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["variable"] as? String },
                       ["OPENAI_API_KEY", "ROUTER_API_KEY", "DATABASE_URL", "STRIPE_SECRET_KEY", "ALREADY_WRAPPED"])
        XCTAssertEqual(outcomes.map { $0["status"] as? String },
                       ["wrapped", "wrapped", "imported_not_wrapped", "skipped", "skipped"])
        for outcome in outcomes {
            let status = outcome["status"] as? String
            XCTAssertEqual(outcome["file"] as? String, ".env", "the relative path")
            let keys = Set(outcome.keys)
            if status == "wrapped" {
                XCTAssertEqual(keys, ["variable", "file", "key", "provider", "status", "new"],
                               "a wrapped row carries new, never a reason")
            } else {
                XCTAssertEqual(keys, ["variable", "file", "key", "provider", "status", "reason"],
                               "every other row carries its reason")
            }
        }
        XCTAssertEqual((outcomes[4]["reason"] as? String), "already wrapped")

        let wire = try wire(result)
        XCTAssertFalse(wire.contains(project.path), "no absolute path in the result")
        XCTAssertFalse(wire.contains(fakeBody), "no value in the result")
        XCTAssertFalse(wire.contains("ksfc_"), "no token in the result")

        let file = EnvFile.parse(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8))
        XCTAssertEqual(file.value(of: "ALREADY_WRAPPED"), clientTokenValue,
                       "an already-wrapped line is left exactly as it was")
    }

    // MARK: - the nothing-to-import early return

    /// A folder whose only candidate is already a token imports nothing: no prompt is
    /// spent, no token is minted, and the result still answers the one honest outcome.
    func testNothingToImportSpendsNoPrompt() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        let original = "ALREADY_WRAPPED=\(clientTokenValue)\nDEBUG=1\n"
        let env = try write(original, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertEqual(vault.gate.reasons.count, 0, "nothing to import means no prompt")
        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["status"] as? String }, ["skipped"])
        XCTAssertEqual(outcomes[0]["reason"] as? String, "already wrapped")
        XCTAssertTrue(result["expires_at"] is NSNull, "no token was minted")
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8), "nothing was rewritten")
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty)
    }

    // MARK: - the candidate cap

    /// The prompt's key list and the import itself cap at the wrap batch's 64
    /// candidates, with the same refusal wording class.
    func testTooManyCandidatesRefusesTheWholeCall() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        let lines = (1...(WrapPlan.maxCandidates + 1)).map { "KEY_\($0)_API_KEY=\(fakeBody)\($0)" }
        try write(lines.joined(separator: "\n") + "\n", to: ".env", under: project)

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertEqual(message, "too many variables to import at once (at most \(WrapPlan.maxCandidates))")
        }
        XCTAssertEqual(vault.gate.reasons.count, 0, "the cap refuses before any prompt")
    }

    // MARK: - the variables filter

    /// `variables` restricts the import to those names; an unfound requested name
    /// answers not_found, and nothing else is touched or named in the prompt.
    func testVariablesFilterAndNotFound() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try write("""
        OPENAI_API_KEY=\(plainValue)
        GROQ_API_KEY=\(groqValue)
        """, to: ".env", under: project)

        let result = try vault.service.importAndWrap(
            folder: project.path, variables: ["GROQ_API_KEY", "MISSING_KEY"], docker: false
        )

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["variable"] as? String }, ["GROQ_API_KEY", "MISSING_KEY"],
                       "only the requested names answer")
        XCTAssertEqual(outcomes[0]["status"] as? String, "wrapped")
        XCTAssertEqual(outcomes[1]["status"] as? String, "not_found")
        XCTAssertEqual(outcomes[1]["reason"] as? String, "not found in the project's env files")
        XCTAssertTrue(outcomes[1]["file"] is NSNull, "a not_found name has no file")
        XCTAssertEqual(vault.gate.reasons.count, 1)
        XCTAssertTrue(vault.gate.reasons[0].contains("1 key"), "only the imported key is named in the prompt")
        XCTAssertTrue(vault.gate.reasons[0].contains("groq"), "the requested key is named in the prompt")

        let file = EnvFile.parse(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8))
        XCTAssertEqual(file.value(of: "OPENAI_API_KEY"), plainValue, "the filtered-out line is untouched")
        XCTAssertTrue(GatewayClientToken.looksLikeToken(file.value(of: "GROQ_API_KEY") ?? ""))
        XCTAssertNil(file.value(of: "OPENAI_BASE_URL"), "no companion for the untouched variable")
    }

    // MARK: - VAL-IMW-012 (name conflicts are skipped, never overwritten)

    /// A suggested name already holding a different value (here: a Keychain item with
    /// no catalog row) skips the variable and reports it; the existing secret is never
    /// overwritten and nothing is wrapped.
    func testNameConflictSkippedNeverOverwritten() throws {
        let secrets = MemorySecretStore()
        let otherValue = "zz" + fakeBody + "conflict"
        try secrets.add(name: "openai", secret: otherValue) // in the store, not in the catalog
        let vault = try makeVault(secrets: secrets)
        let project = try makeProject(in: vault.dir)
        let original = "OPENAI_API_KEY=\(plainValue)\n"
        let env = try write(original, to: ".env", under: project)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0]["status"] as? String, "skipped")
        XCTAssertEqual(outcomes[0]["reason"] as? String,
                       "the key name openai is taken by a different value; nothing was overwritten")
        XCTAssertTrue(try vault.service.list().isEmpty, "no catalog row was created or overwritten")
        XCTAssertEqual(try secrets.get(name: "openai"), otherValue, "the existing secret kept its value")
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8), "the line is untouched")
        XCTAssertTrue(result["expires_at"] is NSNull, "no token was minted for nothing")
    }

    // MARK: - VAL-IMW-013 (wrapped files are recorded for both paths)

    /// Every file the import rewrote is recorded in wrapped_files (canonical path +
    /// project, and the BASE_URL companions its rewrite wrote); the existing keys wrap
    /// apply path records its files and companions too; a file whose values were only
    /// imported-not-wrapped is never recorded.
    func testWrappedFilesRecordedForBothPaths() throws {
        let vault = try makeVault()
        let project = try makeProject(in: vault.dir)
        try write("AWS_ACCESS_KEY_ID=\(awsAccessValue)\n", to: ".env", under: project)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: "sub/.env", under: project)

        _ = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let sub = project.appendingPathComponent("sub/.env")
        let recorded = try vault.db.listWrappedFiles()
        XCTAssertEqual(
            recorded.map(\.path), [KeysService.canonicalPath(sub.path)].compactMap { $0 },
            "the rewritten file, by realpath-canonical path; the aws-only file is absent"
        )
        XCTAssertEqual(recorded[0].project, try vault.service.resolveProject(folder: project.path).id)
        XCTAssertFalse(recorded[0].wrappedAt.isEmpty)

        // The keys wrap apply path records too: the CLI's WrapRunner passes its file's
        // path through the plan, and wrapApply writes the row at the shared apply point.
        let wrapDir = try makeProject("wrapproj", in: vault.dir)
        let env = try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: wrapDir)
        let runner = WrapRunner(backend: ServiceWrapBackend(service: vault.service), out: { _ in }, confirm: { true })
        var wrapOptions = WrapRunner.Options(file: env)
        wrapOptions.backupRoot = EnvFileWriter.backupsRoot(beside: vault.db.path)
        _ = try runner.run(wrapOptions)

        let after = try vault.db.listWrappedFiles()
        XCTAssertEqual(after.count, 2, "both paths recorded")
        let wrapRow = try XCTUnwrap(
            after.first { $0.path == KeysService.canonicalPath(env.path) },
            "the keys wrap path recorded its file by canonical path"
        )
        XCTAssertEqual(wrapRow.project, try vault.service.resolveProject(folder: wrapDir.path).id,
                       "keys wrap records the file under its own folder's project")

        // The companions each path wrote ride the record (VAL-O-008): the import's
        // sub/.env wrote only the OpenAI companion, and keys wrap derives the
        // ANTHROPIC companion from the plan exactly as WrapRunner does.
        XCTAssertEqual(try vault.db.recordedCompanions(path: recorded[0].path), ["OPENAI_BASE_URL"],
                       "the import records the companion its rewrite wrote")
        XCTAssertEqual(try vault.db.recordedCompanions(path: wrapRow.path), ["ANTHROPIC_BASE_URL"],
                       "keys wrap records the companion its plan wrote")
    }

    // MARK: - the changed-file refusal

    /// A file edited while the import's prompt was up refuses the whole import before
    /// anything changes: the vault stays untouched, no token, no rewrite, no backup.
    func testChangedFileRefusesBeforeAnyMutation() throws {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let gate = BlockingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true),
            openRouter: OpenRouterHTTP(),
            relaySecrets: MemorySecretStore()
        )
        let project = try makeProject(in: dir)
        let edited = "OPENAI_API_KEY=\(groqValue)\n" // a different value, same variable
        let env = try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        // The prompt parks; the file changes under it; the approval then releases.
        let editedSignal = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = gate.waitPrompts(1, timeout: 10)
            try? Data(edited.utf8).write(to: env)
            editedSignal.signal()
            gate.release()
        }

        XCTAssertThrowsError(
            try service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertEqual(message, "a file in the project changed while the import ran; nothing was imported")
        }
        XCTAssertEqual(editedSignal.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(try service.list(), [], "nothing was imported")
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), edited, "the file kept the edit")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: project.path).filter { $0.contains("keysrs-backup") }.isEmpty)
        XCTAssertTrue(try backupFiles(under: dir).isEmpty, "the refusal left no backup anywhere")
    }

    // MARK: - the route

    /// The route is origin-token gated, relays the flow's payload verbatim, refuses
    /// malformed bodies with the house envelope, and never answers a GET.
    func testRouteIsTokenGatedAndValidatesTheBody() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        let body = try JSONValue.data(["folder": project.path] as [String: Any])
        XCTAssertEqual(
            handle(site.handler, method: "POST", path: "/api/mcp/import_and_wrap", body: body, token: false).status,
            403, "no origin token, no import"
        )

        let ok = handle(site.handler, method: "POST", path: "/api/mcp/import_and_wrap", body: body)
        XCTAssertEqual(ok.status, 200)
        let payload = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
        XCTAssertEqual(payload["project_label"] as? String, "acme", "the route relays the flow's payload")
        XCTAssertEqual(Set(payload.keys),
                       ["project_label", "expires_at", "docker_access", "base_url_host", "backup_kept_outside_project", "variables"])

        for (label, bad) in [
            ("folder not a string", ["folder": 42] as [String: Any]),
            ("variables not a list", ["variables": "OPENAI_API_KEY"]),
            ("variables not strings", ["variables": [42] as [Any]]),
            ("docker not a boolean", ["docker": "yes"]),
            ("an invalid variable name", ["folder": project.path, "variables": ["lower-case"]]),
            ("a missing folder", ["folder": project.appendingPathComponent("no-such").path]),
        ] {
            let response = handle(site.handler, method: "POST", path: "/api/mcp/import_and_wrap",
                                 body: try JSONValue.data(bad))
            XCTAssertEqual(response.status, 400, "refused: \(label)")
            let envelope = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertNotNil(envelope["error"] as? String, "the house envelope names the refusal: \(label)")
        }
        XCTAssertEqual(handle(site.handler, method: "GET", path: "/api/mcp/import_and_wrap").status, 405,
                       "the route is a POST, never a state-carrying GET")
    }

    // MARK: - VAL-IMW-002/005 at the tool surface

    /// The tool relays the app's answer with the presence call's longer bound in play,
    /// the wire carries the docker flag, and the result's project facts are labels only.
    func testToolRelaysTheAppAnswerOverNamesOnlyWire() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        let result = try JSONSerialization.jsonObject(
            with: Data(try callTool(
                roster(control: site.control, projectFolder: { project.path }),
                arguments: ["folder": project.path, "docker": true]
            ).text.utf8)
        ) as! [String: Any]

        XCTAssertEqual(result["project_label"] as? String, "acme")
        XCTAssertEqual(result["docker_access"] as? Bool, true, "the docker flag reached the app")
        XCTAssertEqual(result["base_url_host"] as? String, "host.docker.internal")
        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0]["key"] as? String, "openai")

        let sent = try JSONSerialization.jsonObject(
            with: Data(String(decoding: site.log.all.last { $0.path == "/api/mcp/import_and_wrap" }!.body, as: UTF8.self).utf8)
        ) as! [String: Any]
        XCTAssertEqual(Set(sent.keys), ["folder", "docker"], "the flags crossed, nothing else")
    }

    // MARK: - VAL-IMW-011 (app down is a whole-call failure)

    /// Without the app the whole call fails with the pinned not-running sentence —
    /// never a partial answer — within the sweep's bound.
    func testAppDownFailsTheWholeCallWithThePinnedSentence() throws {
        let project = try makeProject(in: try TempDir.make())
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)

        let started = Date()
        let (isError, text) = try callTool(
            roster(control: try deadControl(), projectFolder: { project.path }),
            arguments: ["folder": project.path]
        )
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2, "within the sweep's 2 s bound")
        XCTAssertTrue(isError, "the whole call fails, never a partial answer")
        XCTAssertEqual(text, AppConnection.notRunningMessage, "the pinned sentence, byte for byte")
        XCTAssertFalse(text.contains("variables"), "no partial payload rides the failure")
    }

    // MARK: - the presence call bound

    /// The presence-gated import call sits out a slow approval: its bound is the longer
    /// one, while the 10 s default (pinned in MCPAppConnectionTests) stays untouched.
    func testPresenceCallBoundIsLongerThanTheDefault() {
        XCTAssertEqual(AppConnection.presenceCallTimeout, 120, "the documented presence-call bound")
        XCTAssertEqual(AppConnection.appCallTimeout, 10, "the default every other call keeps")
    }

    // MARK: - VAL-O-006 (the folder input is restricted to the session working directory)

    /// import_and_wrap takes the same `folder` input as the two read-only tools, and
    /// it is the write path — so the same safety property applies (VAL-O-006, the
    /// mission's recorded decision): a folder outside the session working directory
    /// is refused at the tool layer with the path-free error, before anything is
    /// sent to the app. Failed pre-fix: the outside folder was forwarded to the app
    /// and imported.
    func testTheToolRefusesAFolderOutsideTheSessionWorkingDirectory() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)
        let outside = try TempDir.make()
        try write("OUTSIDE_KEY=\(groqValue)\n", to: ".env", under: outside)

        let (isError, text) = try callTool(
            roster(control: site.control, projectFolder: { project.path }),
            arguments: ["folder": outside.path]
        )
        XCTAssertTrue(isError, "an outside folder is a plain refusal, not an import: \(text)")
        XCTAssertEqual(text, "the folder must be this session's working directory or inside it",
                       "the onboarding group's shared path-free message")
        XCTAssertTrue(
            try site.log.all.filter { $0.path == "/api/mcp/import_and_wrap" }.isEmpty,
            "the outside folder never reached the app"
        )
        XCTAssertTrue(try site.service.list().isEmpty, "nothing was imported from it")
    }

    // MARK: - S1 (the folder is always the session's, in canonical form)

    /// The canonical spelling of a temp path, the form the tool now sends.
    private func canonical(_ url: URL) throws -> String {
        try Project.canonicalFolder(url.path)
    }

    /// The folder field the tool put on the wire, or nil when it sent none.
    private func sentFolder(_ site: Site) throws -> String? {
        guard let request = site.log.all.last(where: { $0.path == "/api/mcp/import_and_wrap" }) else { return nil }
        let sent = try JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
        return sent["folder"] as? String
    }

    /// With no `folder` argument the tool used to send none, and the app fell back to
    /// its own working directory (usually `/`), scanning and rewriting env files far
    /// outside the session. The rig moves this process's working directory — the
    /// in-process app's — to a separate folder holding its own env file: the call must
    /// send the session's canonical folder and leave that other file byte-for-byte.
    func testNoFolderArgumentSendsTheSessionFolderNotTheAppWorkingDirectory() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)
        let elsewhere = try TempDir.make()
        let elsewhereEnv = try write("GROQ_API_KEY=\(groqValue)\n", to: ".env", under: elsewhere)
        let before = try Data(contentsOf: elsewhereEnv)

        let previous = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(elsewhere.path))
        defer { fm.changeCurrentDirectoryPath(previous) }

        let (isError, text) = try callTool(
            roster(control: site.control, projectFolder: { project.path }), arguments: [:]
        )
        XCTAssertFalse(isError, text)
        XCTAssertEqual(try sentFolder(site), try canonical(project), "the session's canonical folder crossed")
        XCTAssertEqual(try Data(contentsOf: elsewhereEnv), before, "the app's working directory was not touched")
        XCTAssertEqual(try site.service.list().map(\.name), ["openai"], "only the session's key was imported")
    }

    /// A relative folder is resolved against the session folder and sent canonical,
    /// and a symlink inside the session is resolved once, at the check.
    func testRelativeAndSymlinkedFoldersAreSentCanonical() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        let sub = try makeProject("sub", in: project)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: sub)
        try fm.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: sub)
        let registry = roster(control: site.control, projectFolder: { project.path })

        for spelling in ["sub", "./sub/", "link"] {
            let (isError, text) = try callTool(registry, arguments: ["folder": spelling])
            XCTAssertFalse(isError, "\(spelling): \(text)")
            XCTAssertEqual(try sentFolder(site), try canonical(sub), "\(spelling) crossed canonical")
        }
    }

    /// A session started in `/` or the home folder is not a project: the import is
    /// refused before anything reaches the app, with a path-free message.
    func testASessionInTheRootOrHomeFolderIsRefused() throws {
        let site = try makeSite()
        for session in ["/", NSHomeDirectory()] {
            let (isError, text) = try callTool(
                roster(control: site.control, projectFolder: { session }), arguments: [:]
            )
            XCTAssertTrue(isError, "\(session) is refused: \(text)")
            XCTAssertFalse(text.contains(NSHomeDirectory()), "the refusal is path-free")
        }
        XCTAssertTrue(
            try site.log.all.filter { $0.path == "/api/mcp/import_and_wrap" }.isEmpty,
            "nothing reached the app"
        )
        XCTAssertTrue(try site.service.list().isEmpty)
    }

    /// The route no longer has a default: a body without a folder, or with a relative
    /// one, is a 400 and imports nothing — the app never falls back to its own cwd.
    func testRouteRefusesAMissingOrRelativeFolder() throws {
        let site = try makeSite()
        let project = try makeProject(in: site.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)
        for body in [[:], ["folder": NSNull()], ["folder": "acme"], ["docker": false]] as [[String: Any]] {
            let response = handle(site.handler, method: "POST", path: "/api/mcp/import_and_wrap",
                                  body: try JSONValue.data(body))
            XCTAssertEqual(response.status, 400, "refused: \(body)")
        }
        XCTAssertTrue(try site.service.list().isEmpty, "nothing was imported")
        XCTAssertEqual(site.gate.reasons.count, 0, "no prompt was raised")
    }

    // MARK: - the fail-closed isolation guard (owner directive 2026-10-28)

    /// The guard's own proof: the production locations — the default catalog seam, the
    /// control file beside it, the Application Support root itself — fail closed, while
    /// a temp path passes. A test rig that reaches for the real app dies here instead.
    /// The production control shape is built directly (the resolver itself now refuses
    /// under the tripwire, which is this suite's own subject), and the shared guard is
    /// asserted on the same shapes — both guards fail closed on production paths.
    func testGuardFailsClosedOnProductionPaths() throws {
        let productionControl = Paths.appSupport.appendingPathComponent("control.json")
        XCTAssertThrowsError(try assertNotProductionPath(Paths.appSupport))
        XCTAssertThrowsError(try assertNotProductionPath(Paths.appSupport.appendingPathComponent("catalog.db")), "the production-default catalog seam")
        XCTAssertThrowsError(try assertNotProductionPath(productionControl), "the production-default control seam")
        XCTAssertThrowsError(try AppConnectionIsolationGuard.assertIsolated(control: productionControl),
                             "the shared guard rejects the production control shape too")
        XCTAssertThrowsError(try assertNotProductionPath(Paths.appSupport.appendingPathComponent("nested/control.json")))
        XCTAssertNoThrow(try assertNotProductionPath(try TempDir.make().appendingPathComponent("catalog.db")))
        XCTAssertNoThrow(try assertNotProductionPath(try deadControl()))
    }

    // MARK: - the sweep's offline row

    /// The sweep's argument row is safe offline: against the unwritten control file the
    /// tool answers its not-running result, appends no prompt, and stays inside the
    /// bound — the shape MCPOutputGuardSweepTests drives roster-wide.
    func testSweepRowIsSafeOffline() throws {
        let rig = try MCPSweepRig.make()
        let arguments = try XCTUnwrap(MCPSweepRig.argumentRows["import_and_wrap"],
                                      "the sweep row for import_and_wrap exists")
        let started = Date()
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"import_and_wrap","arguments":\#(String(decoding: try JSONValue.data(arguments), as: UTF8.self))}}"#,
        ], registry: try rig.registry())
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2)
        let result = try MCPSession.assertResult(frames[1], id: "t")
        XCTAssertTrue(result["isError"] as? Bool ?? false, "no app means the not-running result")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, AppConnection.notRunningMessage)
    }

    // MARK: - the onboarding counters (VAL-INT-004)

    /// A completed import records the onboarding `key_import` and `onboarding_finished`
    /// counters, and records nothing at all while analytics sharing is off (the opt-in
    /// gate). Each run imports into a fresh project, because an import rewrites its env
    /// file and a second run over the same file would find it already wrapped.
    func testImportRecordsKeyImportAndOnboardingFinishedOnlyWhenSharingIsOn() throws {
        let vault = try makeVault()
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: vault.db, transport: transport)
        vault.service.analytics = analytics

        func counts() throws -> [String: Int]? {
            (((try analytics.status()["preview"] as? [String: Any])?["reports"] as? [[String: Any]])?
                .first?["counts"] as? [String: Int])
        }

        let offProject = try makeProject("off", in: vault.dir)
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: offProject)
        _ = try vault.service.importAndWrap(folder: offProject.path, variables: nil, docker: false)
        XCTAssertNil(try counts(), "sharing is off: the import records nothing")

        try analytics.setEnabled(true, consentVersion: 2)
        let onProject = try makeProject("on", in: vault.dir)
        try write("GROQ_API_KEY=\(groqValue)\n", to: ".env", under: onProject)
        _ = try vault.service.importAndWrap(folder: onProject.path, variables: nil, docker: false)
        let counts = try XCTUnwrap(try counts(), "the import recorded counters")
        XCTAssertEqual(counts["key_import"], 1, "the import records one key_import")
        XCTAssertEqual(counts["onboarding_finished"], 1, "a completed import records one onboarding_finished")
    }
}
