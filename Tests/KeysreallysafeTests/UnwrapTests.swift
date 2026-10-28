import Foundation
import XCTest
@testable import KeysCore

/// VAL-UNWRAP-001..007: `keys unwrap` — the app-side restore flow, the
/// origin-token-gated `/api/unwrap` route, and the CLI runner's keys-wrap exit-6
/// discipline. Every rig is a temp catalog beside a temp control file with a fake
/// presence gate and a fake secret store (owner directive 2026-10-28): the
/// fail-closed guard runs on every control-channel path, so nothing here can reach
/// the installed app, the real Keychain or ~/Library/Application Support/Keysreallysafe
/// — an unwrap reaching the real app would unwrap real files and revoke real tokens,
/// and must be impossible from a test. Fake key bodies are built at runtime
/// (NEVER-REAL); restored values are asserted in the env file only, and never appear
/// in a prompt, a result or the CLI's output.
final class UnwrapTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var openaiValue: String { "sk-" + fakeBody + "02" }
    private var openrouterValue: String { "sk-or-" + fakeBody + "03" }
    private var groqValue: String { "gsk_" + fakeBody + "04" }

    // MARK: - Rigs

    /// The in-process app: a real APIHandler over a temp catalog behind a recording
    /// loopback server on an ephemeral port, `control.json` beside that same catalog.
    /// The fail-closed guard runs on the catalog and the control file before anything
    /// moves (owner directive 2026-10-28).
    private struct Site {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
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
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        addTeardownBlock { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try assertNotProductionPath(control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(service: service, db: db, gate: gate, handler: handler, server: server, control: control, dir: dir)
    }

    /// A control URL no live site answers: a fresh temp tree with no control.json in
    /// it — guarded against production paths like every other control-channel rig.
    private func deadControl() throws -> URL {
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try assertNotProductionPath(control)
        return control
    }

    /// A gated service over a temp catalog, no site — for the flows that never touch
    /// the control channel (the per-key wrap path).
    private struct Vault {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let dir: URL
    }

    private func makeVault() throws -> Vault {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db)
        return Vault(service: service, db: db, gate: gate, dir: dir)
    }

    /// A project folder named `name` inside the site's temp tree.
    @discardableResult
    private func makeProject(_ name: String, in dir: URL) throws -> URL {
        let project = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// Writes an env file at `relative` under `root`, creating intermediate folders.
    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The value of one variable in an env file on disk.
    private func value(_ name: String, in file: URL) throws -> String? {
        let text = try String(contentsOf: file, encoding: .utf8)
        return EnvFile.parse(text).value(of: name)
    }

    /// The wrap-time backups beside a file (`<file>.keysrs-backup-<ts>`).
    private func backups(beside file: URL) throws -> [URL] {
        let names = try fm.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        return names.filter { $0.hasPrefix(file.lastPathComponent + ".keysrs-backup-") }
            .map { file.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// One import_and_wrap call over the site's own service (its single prompt is
    /// accounted for in every delta below).
    @discardableResult
    private func wrapByImport(_ site: Site, folder: URL) throws -> [String: Any] {
        try site.service.importAndWrap(folder: folder.path, variables: nil, docker: false)
    }

    /// The vault key name the import chose for one variable, straight from the result —
    /// the tests never guess the naming scheme.
    private func importedKey(_ payload: [String: Any], _ variable: String) throws -> String {
        let rows = (payload["variables"] as? [Any])?.compactMap(JSONValue.object) ?? []
        let row = try XCTUnwrap(rows.first { JSONValue.string($0["variable"]) == variable })
        return try XCTUnwrap(JSONValue.string(row["key"]))
    }

    /// Asserts the gateway allows (or denies) one request with a client token. Used
    /// both before an unwrap (proving the token was live under the right key name) and
    /// after it (proving it died), so a denial is never vacuous.
    private func assertDecision(
        _ expected: String, name: String, token: String,
        service: KeysService,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let decision = service.authorizeGatewayClient(
            name: name, headers: ["authorization": "Bearer \(token)"], method: "POST", rest: ""
        )
        guard case let .denied(reason) = decision else {
            XCTAssertEqual(expected, "allowed", "the token for \(name) was expected dead", file: file, line: line)
            return
        }
        XCTAssertEqual(reason, expected, "the decision reason for \(name)", file: file, line: line)
    }

    // MARK: - VAL-UNWRAP-001 (one prompt; byte-for-byte restoration)

    /// With the wrap backup present and the file unedited since wrap, the file form
    /// shows exactly one Touch ID whose reason names the file, restores every wrapped
    /// line's value from the vault, and returns the file byte-for-byte to its pre-wrap
    /// content — companions the wrap replaced restored from the backup, companions it
    /// appended removed.
    func testFileFormRestoresByteForByteUnderOnePrompt() throws {
        let site = try makeSite()
        let project = try makeProject("acme", in: site.dir)
        let original = """
        # top comment
        export OPENAI_API_KEY="\(openaiValue)" # inline
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_BASE_URL=https://api.example.internal/v1
        """
        let env = try write(original + "\n", to: ".env", under: project)
        let originalData = try Data(contentsOf: env)
        _ = try wrapByImport(site, folder: project)

        let wrappedData = try Data(contentsOf: env)
        XCTAssertNotEqual(wrappedData, originalData, "the import rewrote the file")
        let wrappedText = String(decoding: wrappedData, as: UTF8.self)
        XCTAssertTrue(wrappedText.contains("ksfc_"), "the wrapped file holds the token")
        XCTAssertFalse(wrappedText.contains(openaiValue), "the raw value is gone from the wrapped file")
        XCTAssertEqual(try backups(beside: env).count, 1, "the wrap wrote one backup")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 1, "the import recorded the file")
        let promptsBefore = site.gate.reasons.count

        let result = try site.service.unwrap(file: env.path, folder: nil)

        XCTAssertEqual(site.gate.reasons.count - promptsBefore, 1, "exactly one Touch ID for the whole unwrap")
        let reason = try XCTUnwrap(site.gate.reasons.last)
        XCTAssertTrue(reason.contains(".env"), "the reason names the file: \(reason)")
        XCTAssertTrue(reason.contains("unwrap"), "the reason says what the call does: \(reason)")
        XCTAssertFalse(reason.contains(fakeBody), "no value in the reason")
        XCTAssertFalse(reason.contains("ksfc_"), "no token in the reason")

        let restoredData = try Data(contentsOf: env)
        XCTAssertEqual(restoredData, originalData, "byte-for-byte restoration of the pre-wrap file")
        let restoredText = String(decoding: restoredData, as: UTF8.self)
        XCTAssertFalse(restoredText.contains("ksfc_"), "no token left in the file")

        let files = try XCTUnwrap(result["files"] as? [[String: Any]], "the result lists its files")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["restored"] as? [String], ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertEqual((files[0]["failed"] as? [Any])?.count, 0)
        XCTAssertEqual(files[0]["companions_restored"] as? [String], ["OPENAI_BASE_URL"])
        XCTAssertEqual(files[0]["companions_removed"] as? [String], ["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "the record is cleared for the unwrapped file")
        // The wire result never carries a value or a token either.
        let wire = String(decoding: try JSONValue.data(result), as: UTF8.self)
        XCTAssertFalse(wire.contains(fakeBody))
        XCTAssertFalse(wire.contains("ksfc_"))
    }

    // MARK: - VAL-UNWRAP-002 (tokens revoked, dead immediately)

    /// The file form revokes exactly the tokens found in that file, found by hashing
    /// each wrapped line's own token value; another project's file and token are
    /// untouched.
    func testFileFormRevokesExactlyThatFilesTokens() throws {
        let site = try makeSite()
        let alpha = try makeProject("alpha", in: site.dir)
        let beta = try makeProject("beta", in: site.dir)
        let envA = try write("OPENAI_API_KEY=\(openaiValue)\n", to: ".env", under: alpha)
        let envB = try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: beta)
        let importA = try wrapByImport(site, folder: alpha)
        let importB = try wrapByImport(site, folder: beta)
        let keyA = try importedKey(importA, "OPENAI_API_KEY")
        let keyB = try importedKey(importB, "ANTHROPIC_API_KEY")
        let tokenA = try XCTUnwrap(try value("OPENAI_API_KEY", in: envA))
        let tokenB = try XCTUnwrap(try value("ANTHROPIC_API_KEY", in: envB))
        let wrappedB = try Data(contentsOf: envB)
        assertDecision("allowed", name: keyA, token: tokenA, service: site.service)
        assertDecision("allowed", name: keyB, token: tokenB, service: site.service)

        _ = try site.service.unwrap(file: envA.path, folder: nil)

        assertDecision("revoked", name: keyA, token: tokenA, service: site.service)
        assertDecision("allowed", name: keyB, token: tokenB, service: site.service)
        XCTAssertEqual(try Data(contentsOf: envB), wrappedB, "the other project's file is untouched")
        let rows = try site.db.listWrappedFiles()
        XCTAssertEqual(rows.map(\.path), [KeysService.canonicalPath(envB.path) ?? envB.path],
                       "only the unwrapped file's record is cleared")
    }

    /// The no-argument form restores every wrapped file recorded for the cwd's
    /// project and revokes that project's client tokens; each member's authorization
    /// dies with the project token (authorize denies for every member key).
    func testProjectFormRestoresEveryRecordedFileAndRevokesProjectTokens() throws {
        let site = try makeSite()
        let project = try makeProject("acme", in: site.dir)
        let originalRoot = "# root\nOPENAI_API_KEY=\(openaiValue)\n"
        let originalSub = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        let root = try write(originalRoot, to: ".env", under: project)
        let sub = try write(originalSub, to: "sub/.env.local", under: project)
        let imported = try wrapByImport(site, folder: project)
        let openaiKey = try importedKey(imported, "OPENAI_API_KEY")
        let anthropicKey = try importedKey(imported, "ANTHROPIC_API_KEY")
        let token = try XCTUnwrap(try value("OPENAI_API_KEY", in: root))
        XCTAssertEqual(try value("ANTHROPIC_API_KEY", in: sub), token, "one project token covers both files")
        assertDecision("allowed", name: openaiKey, token: token, service: site.service)
        assertDecision("allowed", name: anthropicKey, token: token, service: site.service)
        let promptsBefore = site.gate.reasons.count

        let result = try site.service.unwrap(file: nil, folder: project.path)

        XCTAssertEqual(site.gate.reasons.count - promptsBefore, 1, "one Touch ID for the whole call")
        let reason = try XCTUnwrap(site.gate.reasons.last)
        XCTAssertTrue(reason.contains("acme"), "the reason names the project: \(reason)")
        XCTAssertEqual(try Data(contentsOf: root), Data(originalRoot.utf8), "the root file is byte-for-byte restored")
        XCTAssertEqual(try Data(contentsOf: sub), Data(originalSub.utf8), "the subfolder file is byte-for-byte restored")

        assertDecision("revoked", name: openaiKey, token: token, service: site.service)
        assertDecision("revoked", name: anthropicKey, token: token, service: site.service)
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "every record is cleared")
        XCTAssertEqual(result["revoked"] as? Int, 1, "the one project token was revoked")
        XCTAssertEqual(result["project"] as? String, "acme")
    }

    /// The per-key wrap path (`keys wrap`, one token per key) unwraps the same way:
    /// each line's key comes from the wrap-time companion or the token's own row, and
    /// every token the file held is revoked.
    func testPerKeyWrapTokensAreFoundByHashAndRevoked() throws {
        let vault = try makeVault()
        let project = try makeProject("perkey", in: vault.dir)
        let original = "OPENAI_API_KEY=\(openaiValue)\nGROQ_API_KEY=\(groqValue)\n"
        let env = try write(original, to: ".env", under: project)
        let originalData = try Data(contentsOf: env)
        let parsed = EnvFile.parse(original)
        let found = WrapDetect.candidates(in: parsed, nameHint: "perkey")
        XCTAssertEqual(found.count, 2, "two wrap candidates")

        let plan = try vault.service.wrapPlan(file: ".env", candidates: found.map(\.candidate), path: env.path)
        let issued = try vault.service.wrapApply(id: plan.id)
        XCTAssertEqual(issued.count, 2, "keys wrap mints one token per key")
        let tokens = Dictionary(issued.map { ($0.key, $0.token) }, uniquingKeysWith: { a, _ in a })

        // The WrapRunner rewrite, reproduced: value spans become the tokens and the
        // OpenAI companion is set (the Groq line deliberately gets none, so its key
        // must resolve from the token's own row).
        var wrapped = EnvFile.parse(original)
        for (slot, item) in zip(found, plan.items) {
            wrapped.setValue(at: slot.index, tokens[item.key ?? ""] ?? "")
        }
        wrapped.upsert(name: "OPENAI_BASE_URL", value: "http://127.0.0.1:12767/\(issued[0].key)")
        _ = try EnvFileWriter.rewrite(env, original: originalData, text: wrapped.render())
        XCTAssertEqual(try vault.db.listWrappedFiles().count, 1, "the wrap apply point recorded the file")

        let promptsBefore = vault.gate.reasons.count
        let result = try vault.service.unwrap(file: env.path, folder: nil)
        XCTAssertEqual(vault.gate.reasons.count - promptsBefore, 1)

        XCTAssertEqual(try Data(contentsOf: env), originalData, "the file returns to its pre-wrap bytes")
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["restored"] as? [String], ["OPENAI_API_KEY", "GROQ_API_KEY"],
                       "the companion-named key and the token-row-named key both restore")
        XCTAssertEqual(result["revoked"] as? Int, 2, "both per-key tokens were revoked")
        for issued_ in issued {
            let headers = ["authorization": "Bearer \(issued_.token)"]
            if case .allowed = vault.service.authorizeGatewayClient(name: issued_.key, headers: headers, method: "POST", rest: "") {
                XCTFail("\(issued_.key)'s token must be dead after unwrap")
            }
        }
        XCTAssertEqual(try vault.db.listWrappedFiles().count, 0, "the record is cleared")
    }

    // MARK: - VAL-UNWRAP-003 (BASE_URL companions)

    /// Without a backup, the documented fallback: gateway-pointing URL lines are
    /// removed (both the replaced and the appended one), while the wrapped values are
    /// still restored from the vault.
    func testNoBackupRemovesGatewayPointingCompanions() throws {
        let site = try makeSite()
        let project = try makeProject("nobackup", in: site.dir)
        let env = try write(
            "OPENAI_API_KEY=\(openaiValue)\nANTHROPIC_API_KEY=\(anthropicValue)\nOPENAI_BASE_URL=https://api.example.internal/v1\n",
            to: ".env", under: project
        )
        _ = try wrapByImport(site, folder: project)
        for backup in try backups(beside: env) { try fm.removeItem(at: backup) }
        XCTAssertTrue(try backups(beside: env).isEmpty)

        let result = try site.service.unwrap(file: env.path, folder: nil)

        let restored = try String(contentsOf: env, encoding: .utf8)
        XCTAssertTrue(restored.contains(openaiValue), "the vault value is restored")
        XCTAssertTrue(restored.contains(anthropicValue), "the second vault value is restored")
        XCTAssertFalse(restored.contains("127.0.0.1:12767"), "no gateway-pointing URL line remains")
        XCTAssertFalse(restored.contains("OPENAI_BASE_URL"), "the replaced companion is removed by the fallback")
        XCTAssertFalse(restored.contains("ANTHROPIC_BASE_URL"), "the appended companion is removed")
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["companions_removed"] as? [String],
                       ["OPENAI_BASE_URL", "ANTHROPIC_BASE_URL"])
        XCTAssertEqual((files[0]["companions_restored"] as? [Any])?.count, 0)
        XCTAssertEqual((files[0]["backup"] as? String) ?? "", "", "no backup was found")
    }

    // MARK: - VAL-UNWRAP-004 (project default and unknown project)

    /// A cwd with no recorded wrapped files answers an honest error stating nothing
    /// was changed — and shows no Touch ID.
    func testProjectFormOnAnUnknownProjectChangesNothing() throws {
        let site = try makeSite()
        let project = try makeProject("fresh", in: site.dir)
        let env = try write("OPENAI_API_KEY=\(openaiValue)\n", to: ".env", under: project)
        let before = try Data(contentsOf: env)
        let promptsBefore = site.gate.reasons.count

        XCTAssertThrowsError(try site.service.unwrap(file: nil, folder: project.path)) { error in
            guard case AppError.notFound(let message) = error else {
                return XCTFail("expected a not-found refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("nothing was changed"), "the error states nothing was changed: \(message)")
        }
        XCTAssertEqual(site.gate.reasons.count, promptsBefore, "no Touch ID when there is nothing to unwrap")
        XCTAssertEqual(try Data(contentsOf: env), before, "the file is untouched")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "no record was created")
    }

    // MARK: - VAL-UNWRAP-005 (the app-down discipline of keys wrap)

    /// Without the app, both forms of the command fail with keys wrap's control
    /// sentence and its exit code 6 — and nothing is ever auto-launched.
    func testAppDownExitsSixWithTheControlSentence() throws {
        let control = try deadControl()
        let runner = UnwrapRunner(connect: { try ControlClient.connect(control: control) }, out: { _ in })
        let sentence = "no running Keysrs site owns the gateway; open Keysrs.app or run keys dashboard, then retry"

        for path in ["/nowhere/.env", nil] {
            XCTAssertThrowsError(try runner.run(path: path)) { error in
                guard case AppError.siteUnavailable(let message) = error else {
                    return XCTFail("expected the wrap-style site-unavailable error, got \(error)")
                }
                XCTAssertEqual(message, sentence, "the pinned control sentence")
                XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6, "exit 6, like keys wrap")
            }
        }
    }

    // MARK: - VAL-UNWRAP-006 (a dead vault key is reported, not silently skipped)

    /// A wrapped line whose vault key was deleted is a stated per-line failure; the
    /// other lines are still restored, the dead line keeps its (now revoked) token,
    /// and the result says all of it.
    func testDeadVaultKeyIsAStatedPerLineFailure() throws {
        let site = try makeSite()
        let project = try makeProject("dead", in: site.dir)
        let env = try write("OPENAI_API_KEY=\(openaiValue)\nANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: project)
        let imported = try wrapByImport(site, folder: project)
        let anthropicKey = try importedKey(imported, "ANTHROPIC_API_KEY")
        let openaiKey = try importedKey(imported, "OPENAI_API_KEY")
        let token = try XCTUnwrap(try value("ANTHROPIC_API_KEY", in: env))
        try site.service.remove(name: anthropicKey)
        let promptsBefore = site.gate.reasons.count

        let result = try site.service.unwrap(file: env.path, folder: nil)

        XCTAssertEqual(site.gate.reasons.count - promptsBefore, 1, "still one Touch ID for the whole call")
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["restored"] as? [String], ["OPENAI_API_KEY"], "the live line is restored")
        let failed = try XCTUnwrap(files[0]["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.map { $0["variable"] as? String }, ["ANTHROPIC_API_KEY"])
        XCTAssertTrue((failed[0]["reason"] as? String)?.contains(anthropicKey) == true, "the failure names the gone key")

        let text = try String(contentsOf: env, encoding: .utf8)
        XCTAssertTrue(text.contains(openaiValue), "the restored value is back in its line")
        XCTAssertTrue(text.contains("ksfc_"), "the failed line keeps its token")
        assertDecision("revoked", name: openaiKey, token: token, service: site.service)
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "the record is cleared")
    }

    /// A project token serving several keys leaves a line with no gateway companion
    /// unattributable: unwrap reports it instead of guessing, and still restores the
    /// companioned lines.
    func testMultiMemberLineWithoutACompanionIsAStatedFailure() throws {
        let site = try makeSite()
        let project = try makeProject("many", in: site.dir)
        let env = try write("OPENAI_API_KEY=\(openaiValue)\nROUTER_API_KEY=\(openrouterValue)\n", to: ".env", under: project)
        _ = try wrapByImport(site, folder: project)

        let result = try site.service.unwrap(file: env.path, folder: nil)

        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["restored"] as? [String], ["OPENAI_API_KEY"])
        let failed = try XCTUnwrap(files[0]["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.map { $0["variable"] as? String }, ["ROUTER_API_KEY"])
        XCTAssertTrue((failed[0]["reason"] as? String)?.contains("cannot tell which vault key") == true)
        let text = try String(contentsOf: env, encoding: .utf8)
        XCTAssertTrue(text.contains(openaiValue), "the companioned line is restored")
        XCTAssertTrue(text.contains("ksfc_"), "the unattributable line keeps its token")
    }

    /// A file with nothing wrapped answers honestly without a prompt, and a stale
    /// record pointing at it is cleared.
    func testNothingToUnwrapIsHonestWithoutAPrompt() throws {
        let site = try makeSite()
        let project = try makeProject("plain", in: site.dir)
        let env = try write("OPENAI_API_KEY=\(openaiValue)\n", to: ".env", under: project)
        try site.service.recordWrappedFile(path: env.path, project: "stale-id")
        let before = try Data(contentsOf: env)
        let promptsBefore = site.gate.reasons.count

        let result = try site.service.unwrap(file: env.path, folder: nil)

        XCTAssertEqual(site.gate.reasons.count, promptsBefore, "no Touch ID for a file with nothing to unwrap")
        XCTAssertEqual(try Data(contentsOf: env), before, "the file is untouched")
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["restored"] as? [String], [])
        XCTAssertNotNil(files[0]["message"], "the result states there was nothing to unwrap")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "the stale record was cleared")
    }

    /// A recorded file the user deleted since wrap is a stated per-file failure; the
    /// other files still restore and the project's tokens still die.
    func testRecordedFileGoneFromDiskIsAStatedPerFileFailure() throws {
        let site = try makeSite()
        let project = try makeProject("gone", in: site.dir)
        let root = try write("OPENAI_API_KEY=\(openaiValue)\n", to: ".env", under: project)
        let sub = try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: "sub/.env.local", under: project)
        let imported = try wrapByImport(site, folder: project)
        let openaiKey = try importedKey(imported, "OPENAI_API_KEY")
        let token = try XCTUnwrap(try value("OPENAI_API_KEY", in: root))
        // The canonical spelling must be captured while the file still exists: realpath
        // cannot resolve a deleted path, and the record holds the canonical form.
        let subCanonical = KeysService.canonicalPath(sub.path) ?? sub.path
        try fm.removeItem(at: sub)

        let result = try site.service.unwrap(file: nil, folder: project.path)

        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: files.map { (($0["file"] as? String) ?? "", $0) })
        let subRow = try XCTUnwrap(byName[subCanonical])
        XCTAssertTrue((subRow["message"] as? String ?? "").contains("no longer exists"),
                      "the missing file is stated: \(subRow)")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "its stale record is cleared")
        XCTAssertTrue(try String(contentsOf: root, encoding: .utf8).contains(openaiValue),
                      "the surviving file is still restored")
        assertDecision("revoked", name: openaiKey, token: token, service: site.service)
    }

    // MARK: - The route and the CLI runner (both forms, the token gate, no leaks)

    /// The route is origin-token gated like /api/wrap (403 without the token), and the
    /// CLI runner drives the whole flow over a temp control channel — the temp control
    /// file the owner directive requires, never the installed app's.
    func testRouteIsTokenGatedAndTheRunnerWorksOverTheControlChannel() throws {
        let site = try makeSite()
        let project = try makeProject("runner", in: site.dir)
        let original = "OPENAI_API_KEY=\(openaiValue)\nANTHROPIC_API_KEY=\(anthropicValue)\n"
        let env = try write(original, to: ".env", under: project)
        let originalData = try Data(contentsOf: env)
        _ = try wrapByImport(site, folder: project)

        // The gate: no token, no unwrap.
        let denied = handle(site.handler, method: "POST", path: "/api/unwrap",
                            body: try JSONValue.data(["file": env.path]), token: false)
        XCTAssertEqual(denied.status, 403, "the route refuses a request without the origin token")
        // An empty body is a usage refusal, not a crash.
        let bad = handle(site.handler, method: "POST", path: "/api/unwrap", body: Data())
        XCTAssertEqual(bad.status, 400)

        // The file form through the real runner and control client.
        var lines: [String] = []
        let runner = UnwrapRunner(
            connect: { try ControlClient.connect(control: site.control) },
            out: { lines.append($0) }
        )
        _ = try runner.run(path: env.path)
        XCTAssertEqual(try Data(contentsOf: env), originalData, "the runner's call restored the file")
        let printed = lines.joined(separator: "\n")
        XCTAssertTrue(printed.contains("OPENAI_API_KEY"), "the output names what was restored")
        XCTAssertFalse(printed.contains(fakeBody), "the CLI never prints a value")
        XCTAssertFalse(printed.contains("ksfc_"), "the CLI never prints a token")

        // The project form through the injected cwd seam.
        _ = try wrapByImport(site, folder: project)
        lines.removeAll()
        let projectRunner = UnwrapRunner(
            connect: { try ControlClient.connect(control: site.control) },
            out: { lines.append($0) },
            projectFolder: { project.path }
        )
        _ = try projectRunner.run(path: nil)
        XCTAssertEqual(try Data(contentsOf: env), originalData, "the project form restored the file too")
        XCTAssertFalse(lines.joined(separator: "\n").contains("ksfc_"))
    }

    /// The CLI surface: `keys unwrap` is registered beside `keys wrap` (the build
    /// itself pins the registration — the command appears in KeysCLI's subcommands
    /// list) with an optional path, and asks for no terminal input of its own: the one
    /// Touch ID in the app is the only gate, so there is no confirm and no
    /// non-interactive guard. Its control connection is UnwrapRunner's injectable
    /// connect seam, the same shape as keys wrap's ControlWrapBackend.connect — the
    /// runner test above drives it against the temp control file, and nothing ever
    /// constructs the command's production default connect from a test (owner
    /// directive 2026-10-28).
    func testTheUnwrapUsageTextNamesTheExitSixDiscipline() {
        XCTAssertTrue(UnwrapCommand.configuration.commandName == "unwrap")
        XCTAssertTrue(UnwrapCommand.configuration.abstract.contains("one Touch ID"))
        XCTAssertTrue(UnwrapCommand.configuration.discussion.contains("exits 6"))
        XCTAssertTrue(UnwrapCommand.configuration.discussion.contains("never launches anything itself"))
    }
}
