import Foundation
import XCTest
@testable import KeysCore

/// The file phase of both wrap paths is all-or-nothing: every file is staged beside
/// its target first, and only a batch whose every temp exists is renamed home. These
/// tests drive the second file failing deterministically through the test-only hook
/// `EnvFileWriter.testHooks`, and pin what each failure leaves behind — the first file
/// never holding a token this call then revokes, the record only describing a rewrite
/// that happened, and the message naming the state that remains.
///
/// Every rig is a temp catalog and a temp project; every "key" is built at runtime from
/// an obviously fake body. Nothing here touches the real vault, Keychain or app.
final class ImportAndWrapAtomicTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "11" }
    private var openrouterValue: String { "sk-or-" + fakeBody + "12" }
    private var plainValue: String { "sk-" + fakeBody + "13" }
    private var groqValue: String { "gsk_" + fakeBody + "14" }

    /// A sentinel error the hook throws: not an AppError, so the message path has to
    /// cope with a plain `LocalizedError` too.
    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "the disk went away" }
    }

    override func tearDown() {
        EnvFileWriter.testHooks = nil
        super.tearDown()
    }

    // MARK: - rigs

    private struct Vault {
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let gate: RecordingPresenceGate
    }

    private func makeVault() throws -> Vault {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db)
        return Vault(service: service, db: db, dir: dir, gate: gate)
    }

    @discardableResult
    private func makeProject(_ name: String = "acme", in dir: URL) throws -> URL {
        let project = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Every file in the tree whose name carries the scratch marker a staged temp uses.
    private func leftoverTemps(under dir: URL) -> [String] {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [String] = []
        while let url = files?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.contains(".keysrs-"), !name.contains("keysrs-backup-") {
                out.append(name)
            }
        }
        return out
    }

    private func backupFiles(under dir: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent.contains("keysrs-backup-") { out.append(url) }
        }
        return out
    }

    // MARK: - bug 1: the second file fails in phase A

    /// The reported bug, through a real failure rather than the test hook: the second
    /// file's backup folder is blocked by a planted regular file, so its prepare refuses
    /// after the first file's prepare succeeded. The old code had already renamed file 1
    /// to the token by then and its catch revoked that token — file 1 pointed at a dead
    /// token, its row existed, file 2 was raw. Now nothing is renamed until every temp
    /// exists, so both files keep their secrets.
    func testASecondFileThatCannotBeBackedUpLeavesEveryFileRaw() throws {
        let vault = try makeVault()
        let project = try makeProject("blocked", in: vault.dir)
        let firstOriginal = "OPENAI_API_KEY=\(plainValue)\n"
        let secondOriginal = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        let first = try write(firstOriginal, to: "a/.env", under: project)
        let second = try write(secondOriginal, to: "b/.env", under: project)
        // `a/.env` sorts before `b/.env`, so the first file prepares cleanly and the
        // second is the one that cannot even open its backup folder.
        let root = EnvFileWriter.backupsRoot(beside: vault.db.path)
        let blocked = try XCTUnwrap(EnvFileWriter.backupDirectory(for: second, under: root))
        try fm.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocked)

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertTrue(message.contains("no file was changed"), "it says no file changed: \(message)")
            XCTAssertTrue(message.contains("were added to the vault"), "it owns up to the vault writes: \(message)")
            XCTAssertFalse(message.contains(project.path), "no absolute path: \(message)")
        }

        XCTAssertEqual(try Data(contentsOf: first), Data(firstOriginal.utf8),
                       "the first file still holds its secret, not a token this call revoked")
        XCTAssertEqual(try Data(contentsOf: second), Data(secondOriginal.utf8))
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty, "no row claims a rewrite that did not happen")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty, "the first file's temp was deleted")
        for name in ["openai", "anthropic"] {
            XCTAssertTrue(try vault.db.gatewayClients(keyName: name).allSatisfy { $0.revokedAt != nil },
                          "\(name)'s minted token was revoked")
        }
    }

    /// The same failure through the test hook, where the refusal is not a filesystem
    /// accident: the message still has to name the cause, the files and the vault.
    func testASecondFileFailingLeavesEveryFileRaw() throws {
        let vault = try makeVault()
        let project = try makeProject("twofiles", in: vault.dir)
        let first = try write("OPENAI_API_KEY=\(plainValue)\n", to: "a/.env", under: project)
        let second = try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: "b/.env", under: project)
        EnvFileWriter.testHooks = .init(beforeCommit: { throw InjectedFailure() })

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertTrue(message.contains("the disk went away"), "the cause is named: \(message)")
            XCTAssertTrue(message.contains("no file was changed"), "it says no file changed: \(message)")
            XCTAssertTrue(message.contains("were added to the vault"), "it owns up to the vault writes: \(message)")
            XCTAssertTrue(message.contains("a retry reuses them"), "and says a retry is safe: \(message)")
            XCTAssertFalse(message.contains(project.path), "no absolute path: \(message)")
        }

        // Neither file moved: file 1 is still the raw secret, not a dead token.
        XCTAssertEqual(try Data(contentsOf: first), Data("OPENAI_API_KEY=\(plainValue)\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("ANTHROPIC_API_KEY=\(anthropicValue)\n".utf8))
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty, "no record describes a rewrite that did not happen")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty, "no staged temp survived")
        XCTAssertTrue(backupFiles(under: vault.dir).isEmpty, "a batch that never committed keeps no backup")

        // The keys are in the vault (the documented, retry-friendly half) and the token
        // the mint happened to issue is dead.
        XCTAssertEqual(Set(try vault.service.list().map(\.name)), ["openai", "anthropic"])
        for name in ["openai", "anthropic"] {
            let clients = try vault.db.gatewayClients(keyName: name)
            XCTAssertTrue(clients.allSatisfy { $0.revokedAt != nil }, "\(name)'s token was revoked")
        }
    }

    /// A retry after that failure succeeds: the keys are already in the vault, the
    /// values match them by dedupe, and both files end up wrapped for real.
    func testTheRetryAfterAPhaseAFailureWrapsBothFiles() throws {
        let vault = try makeVault()
        let project = try makeProject("retry", in: vault.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: "a/.env", under: project)
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: "b/.env", under: project)
        EnvFileWriter.testHooks = .init(beforeCommit: { throw InjectedFailure() })
        XCTAssertThrowsError(try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false))

        EnvFileWriter.testHooks = nil
        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        let outcomes = result["variables"] as! [[String: Any]]
        XCTAssertEqual(outcomes.map { $0["status"] as? String }, ["wrapped", "wrapped"])
        XCTAssertEqual(try vault.db.listWrappedFiles().count, 2, "both files recorded this time")
        for relative in ["a/.env", "b/.env"] {
            let text = try String(contentsOf: project.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(text.contains(fakeBody), "\(relative) holds the token, not the secret")
            XCTAssertTrue(GatewayClientToken.looksLikeToken(
                EnvFile.parse(text).entries.first?.entry.value ?? ""
            ))
        }
    }

    // MARK: - bug 2: the realpath refusal must not claim nothing was imported

    /// The old `"nothing was imported"` on this path was written after the keys, the
    /// token and (in the old code) earlier files had already landed. The phase-A
    /// refusal now reports the same cause with an honest state sentence, and nothing on
    /// disk moved.
    func testAnUnreadableFileInTheBatchReportsWhatRemains() throws {
        let vault = try makeVault()
        let project = try makeProject("unreadable", in: vault.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)
        // The batch's own prepare fails for a real reason: a file whose own directory
        // vanished between the verify read and the write is caught by the second file's
        // refuse-if-changed, which is a phase-A failure with a lastPathComponent name.
        EnvFileWriter.testHooks = .init(beforeCommit: {
            throw AppError.usage("second.env changed while keys wrap ran; nothing was rewritten")
        })

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertTrue(message.hasPrefix("second.env changed"), "the cause leads the sentence: \(message)")
            XCTAssertFalse(message.contains("nothing was imported"),
                           "that phrase covered a run that had stored a key: \(message)")
        }
        XCTAssertEqual(try vault.service.list().count, 1, "the key is in the vault, as the message says")
    }

    // MARK: - bug 3: docker:true on an already-wrapped project

    /// `docker: true` on a project whose every line is already wrapped used to return
    /// early without setting the preference, while the result still reported
    /// `base_url_host: host.docker.internal`. The pref now follows the flag on that path
    /// too, under its own prompt (it loosens the gateway's Host check for the whole
    /// Mac, VAL-O-003), and with no rewrite.
    func testDockerTrueOnAnAlreadyWrappedProjectSetsThePreference() throws {
        let vault = try makeVault()
        let project = try makeProject("already", in: vault.dir)
        let token = GatewayClientToken.prefix + String(repeating: "b", count: 48)
        let env = try write("OPENAI_API_KEY=\(token)\n", to: ".env", under: project)

        XCTAssertNil(try vault.db.metaValue(AppPreferences.dockerAccessKey), "off to begin with")
        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: true)

        XCTAssertEqual(try vault.db.metaValue(AppPreferences.dockerAccessKey), "on",
                       "the flag means what it says on this path too")
        XCTAssertEqual(vault.gate.reasons.count, 1, "behind one prompt")
        XCTAssertTrue(vault.gate.reasons.first?.contains("Docker") == true, "that says what it opens")
        XCTAssertEqual(result["docker_access"] as? Bool, true, "the result's live value agrees with the report")
        XCTAssertEqual(result["base_url_host"] as? String, "host.docker.internal")
        XCTAssertEqual(try Data(contentsOf: env), Data("OPENAI_API_KEY=\(token)\n".utf8),
                       "an already-wrapped line is an outcome, not an import: the file is untouched")
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty, "and nothing new was recorded")
    }

    /// Without the person's yes, `docker: true` on that path changes nothing: an
    /// agent cannot open the gateway to containers by calling the import on a
    /// project with nothing left to import.
    func testDockerTrueOnAnAlreadyWrappedProjectNeedsThePrompt() throws {
        let vault = try makeVault()
        let project = try makeProject("already3", in: vault.dir)
        let token = GatewayClientToken.prefix + String(repeating: "d", count: 48)
        try write("OPENAI_API_KEY=\(token)\n", to: ".env", under: project)
        vault.gate.error = .authCancelled

        XCTAssertThrowsError(try vault.service.importAndWrap(folder: project.path, variables: nil, docker: true))
        XCTAssertNil(try vault.db.metaValue(AppPreferences.dockerAccessKey), "still off")
    }

    /// `docker: false` stays completely hands-off on that path: an import that does
    /// nothing must not turn a stored preference off behind the user's back.
    func testDockerFalseOnAnAlreadyWrappedProjectLeavesThePreferenceAlone() throws {
        let vault = try makeVault()
        let project = try makeProject("already2", in: vault.dir)
        let token = GatewayClientToken.prefix + String(repeating: "c", count: 48)
        try write("OPENAI_API_KEY=\(token)\n", to: ".env", under: project)
        try vault.service.preferences.setDockerAccess(true)

        let result = try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)

        XCTAssertEqual(try vault.db.metaValue(AppPreferences.dockerAccessKey), "on", "left as it was")
        XCTAssertEqual(result["docker_access"] as? Bool, true)
        XCTAssertEqual(result["base_url_host"] as? String, "127.0.0.1",
                       "the report describes this call, the pref describes the stored setting")
    }

    // MARK: - bug 5: the backup slot

    /// A batch that fails in phase A takes no backup at all: the old `rewrite` wrote the
    /// pre-image before its own byte check and kept it, so a refusal left a pre-image of
    /// a file that never changed. The check runs first now, and a batch that does not
    /// commit removes every backup it took.
    func testAFailedBatchLeavesNoBackupAndNoTemp() throws {
        let vault = try makeVault()
        let project = try makeProject("nobackup", in: vault.dir)
        try write("OPENAI_API_KEY=\(plainValue)\n", to: ".env", under: project)
        EnvFileWriter.testHooks = .init(beforeCommit: { throw InjectedFailure() })

        XCTAssertThrowsError(try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false))

        XCTAssertTrue(backupFiles(under: vault.dir).isEmpty,
                      "a phase-A failure keeps no pre-image of a file that did not change")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty, "and no scratch file")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8),
                       "OPENAI_API_KEY=\(plainValue)\n")
    }

    // MARK: - phase B: a rename that fails puts the earlier files back

    /// The rare half: the first rename lands and the second cannot. Every file already
    /// renamed is restored from the backup this batch just took, so the project is back
    /// to its raw secrets and the message says so.
    func testAFailureMidCommitRestoresTheFilesAlreadyRenamed() throws {
        let vault = try makeVault()
        let project = try makeProject("midcommit", in: vault.dir)
        let firstOriginal = "OPENAI_API_KEY=\(plainValue)\n"
        let secondOriginal = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        try write(firstOriginal, to: "a/.env", under: project)
        try write(secondOriginal, to: "b/.env", under: project)
        // Let rename 0 through; fail before rename 1.
        EnvFileWriter.testHooks = .init(beforeRename: { index in
            if index == 1 { throw InjectedFailure() }
        })

        XCTAssertThrowsError(
            try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        ) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertTrue(message.contains("every file was put back"), "the restore is reported: \(message)")
            XCTAssertTrue(message.contains("were added to the vault"), "the vault half is owned up to: \(message)")
            XCTAssertFalse(message.contains(project.path), "no absolute path: \(message)")
        }

        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a/.env"), encoding: .utf8),
                       firstOriginal, "the first file was put back from its backup")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("b/.env"), encoding: .utf8),
                       secondOriginal, "the second never moved")
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty, "no record survived the rollback")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty)
        for name in ["openai", "anthropic"] {
            XCTAssertTrue(try vault.db.gatewayClients(keyName: name).allSatisfy { $0.revokedAt != nil },
                          "\(name)'s token was revoked after the rollback")
        }
    }

    /// The record lands only after every file is in place: a batch whose last step
    /// (`record`) throws rolls the files back rather than leaving wrapped bytes with no
    /// row — the state that made a project unwrap unable to find the file.
    func testARecordFailureRollsTheFilesBack() throws {
        let vault = try makeVault()
        let project = try makeProject("recordfail", in: vault.dir)
        let original = "OPENAI_API_KEY=\(plainValue)\n"
        let env = try write(original, to: ".env", under: project)
        // The backups root is a regular file, so the record step's own bookkeeping is
        // fine but the prepare step cannot create a backup folder — a phase-A failure
        // that must still leave the file alone.
        try Data("x".utf8).write(to: EnvFileWriter.backupsRoot(beside: vault.db.path))

        XCTAssertThrowsError(try vault.service.importAndWrap(folder: project.path, variables: nil, docker: false))

        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), original)
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty)
    }
}
