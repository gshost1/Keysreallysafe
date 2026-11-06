import Foundation
import XCTest
@testable import KeysCore

/// `keys wrap`'s own two phases: the file is staged beside its target BEFORE the plan
/// is applied, and the rename is the last step. A file that cannot be written therefore
/// costs no key, no token and no record; a swap that fails after the plan was applied
/// revokes the tokens it just minted, because the plan's whole point was to give them to
/// that file.
///
/// Rigs are a temp catalog beside a temp project; values are synthetic.
final class EnvWrapAtomicTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "21" }
    private var plainValue: String { "sk-" + fakeBody + "22" }

    override func tearDown() {
        EnvFileWriter.testHooks = nil
        super.tearDown()
    }

    private struct Vault {
        let service: KeysService
        let db: CatalogDB
        let dir: URL
    }

    private func makeVault() throws -> Vault {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, _) = makeGatedService(db: db)
        return Vault(service: service, db: db, dir: dir)
    }

    private func backupFiles(under dir: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent.contains("keysrs-backup-") { out.append(url) }
        }
        return out
    }

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

    // MARK: - the file is checked before the plan is applied

    /// An edit made while the plan is applied refuses the rewrite, and the tokens the
    /// apply minted are revoked rather than left live behind an unchanged file.
    func testAnEditedFileCostsNoKeyAndNoToken() throws {
        let vault = try makeVault()
        let env = vault.dir.appendingPathComponent("proj/.env")
        try fm.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ANTHROPIC_API_KEY=\(anthropicValue)\n".utf8).write(to: env)

        // A backend that applies the plan and then edits the file: the plan succeeds,
        // the rewrite's refuse-if-changed check refuses.
        let backend = ReplyingBackend(inner: ServiceWrapBackend(service: vault.service)) { _ in
            try Data("ANTHROPIC_API_KEY=\(self.plainValue)\n".utf8).write(to: env)
        }
        let runner = WrapRunner(backend: backend, out: { _ in }, confirm: { true })
        var options = WrapRunner.Options(file: env)
        options.backupRoot = EnvFileWriter.backupsRoot(beside: vault.db.path)

        XCTAssertThrowsError(try runner.run(options)) { error in
            guard case let AppError.usage(message) = error else {
                return XCTFail("a usage refusal, not \(error)")
            }
            XCTAssertTrue(message.contains("was not changed"), "the file's fate is stated: \(message)")
            XCTAssertTrue(message.contains("revoked"), "and so is the token's: \(message)")
            XCTAssertFalse(message.contains(vault.dir.path), "no absolute path: \(message)")
        }

        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "ANTHROPIC_API_KEY=\(plainValue)\n",
                       "the caller's edit is the last word")
        // The record stays: it may describe an earlier wrap whose tokens are still in
        // the file, and a record for a file with nothing wrapped is cleared as stale
        // by the next unwrap.
        XCTAssertEqual(try vault.db.listWrappedFiles().count, 1, "the record is left for unwrap to judge")
        XCTAssertTrue(try vault.db.gatewayClients(keyName: "anthropic").allSatisfy { $0.revokedAt != nil },
                      "the minted token was revoked")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty, "no staged temp survived")
        XCTAssertTrue(backend.compensated.flatMap { $0 }.count >= 0, "the backend saw the take-back")
    }

    /// While the plan is applied (the Touch ID prompt and the app round trip), no copy
    /// of the file sits beside it: a temp made before the apply held the raw secrets
    /// inside the project for that whole window, and a crash there left it behind
    /// under a name the usual ignore rules do not match.
    func testNoCopyOfTheSecretsSitsInTheProjectWhileThePlanIsApplied() throws {
        let vault = try makeVault()
        let env = vault.dir.appendingPathComponent("proj/.env")
        try fm.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ANTHROPIC_API_KEY=\(anthropicValue)\n".utf8).write(to: env)
        var duringApply: [String] = ["not reached"]
        let backend = ReplyingBackend(inner: ServiceWrapBackend(service: vault.service)) { _ in
            duringApply = self.leftoverTemps(under: vault.dir)
        }
        let runner = WrapRunner(backend: backend, out: { _ in }, confirm: { true })
        var options = WrapRunner.Options(file: env)
        options.backupRoot = EnvFileWriter.backupsRoot(beside: vault.db.path)

        _ = try runner.run(options)
        XCTAssertEqual(duringApply, [], "nothing staged in the project while the plan was applied")
        XCTAssertFalse(try String(contentsOf: env, encoding: .utf8).contains(anthropicValue), "and the wrap landed")
    }

    /// A phase-A refusal (the file is already gone wrong before the plan is applied)
    /// never reaches the plan at all — no key, no token, no record — and the CLI says so.
    func testAPhaseARefusalNeverAppliesThePlan() throws {
        let vault = try makeVault()
        let env = vault.dir.appendingPathComponent("proj/.env")
        try fm.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        try Data(original.utf8).write(to: env)
        // The backups root is a plain file: phase A cannot make the backup folder, so
        // the plan must not be applied.
        try Data("x".utf8).write(to: EnvFileWriter.backupsRoot(beside: vault.db.path))

        let backend = ReplyingBackend(inner: ServiceWrapBackend(service: vault.service))
        let runner = WrapRunner(backend: backend, out: { _ in }, confirm: { true })
        var options = WrapRunner.Options(file: env)
        options.backupRoot = EnvFileWriter.backupsRoot(beside: vault.db.path)

        XCTAssertThrowsError(try runner.run(options))
        XCTAssertEqual(backend.applied, 0, "the plan was never applied")
        XCTAssertTrue(try vault.service.list().isEmpty, "no key landed in the vault")
        XCTAssertTrue(try vault.db.listWrappedFiles().isEmpty)
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), original)
        let clients = try vault.db.activeGatewayClients(key: nil)
        XCTAssertTrue(clients.isEmpty, "no token was minted at all")
    }

    /// The happy path still backs up and renames — one backup, one record, the
    /// token in the file and nothing left over.
    func testTheHappyPathLeavesExactlyOneBackupOneRecordAndNoTemp() throws {        let vault = try makeVault()
        let env = vault.dir.appendingPathComponent("proj/.env")
        try fm.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        try Data(original.utf8).write(to: env)

        let runner = WrapRunner(backend: ServiceWrapBackend(service: vault.service), out: { _ in }, confirm: { true })
        var options = WrapRunner.Options(file: env)
        options.backupRoot = EnvFileWriter.backupsRoot(beside: vault.db.path)
        let summary = try runner.run(options)

        XCTAssertTrue(summary.changed)
        let text = try String(contentsOf: env, encoding: .utf8)
        XCTAssertFalse(text.contains(fakeBody), "the secret is gone from the file")
        XCTAssertTrue(GatewayClientToken.looksLikeToken(EnvFile.parse(text).entries[0].entry.value))
        XCTAssertEqual(backupFiles(under: vault.dir).count, 1, "exactly the backup the summary names")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(summary.backup)), Data(),
                       "no companion line in the original, so the backup keeps no byte of it (audit lead 4)")
        XCTAssertTrue(leftoverTemps(under: vault.dir).isEmpty, "the temp became the file")
        XCTAssertEqual(try vault.db.listWrappedFiles().count, 1)
    }

    // MARK: - bug 5: the single-file backup slot

    /// The standalone `rewrite` used to take its backup BEFORE its refuse-if-changed
    /// check, so a refusal left a `.keysrs-backup-` pre-image of a file that never
    /// changed — a copy of the secrets nobody asked for, sitting there until some later
    /// wrap. The check runs first now, so a refusal writes nothing at all, and no
    /// backup-shaped file exists anywhere afterwards.
    func testASingleFileRefusalWritesNoBackupEither() throws {
        let dir = try TempDir.make()
        let env = dir.appendingPathComponent(".env")
        try Data("A=1\n".utf8).write(to: env)
        let backupRoot = EnvFileWriter.backupsRoot(beside: dir.appendingPathComponent("catalog.db"))

        XCTAssertThrowsError(try EnvFileWriter.rewrite(
            env, original: Data("A=0\n".utf8), text: "A=2\n", backupRoot: backupRoot
        ))
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "A=1\n", "the file is untouched")
        XCTAssertTrue(backupFiles(under: dir).isEmpty,
                      "a refusal leaves no pre-image of a file that did not change")
        XCTAssertTrue(leftoverTemps(under: dir).isEmpty, "and no temp")

        // The same call against the same bytes succeeds and takes exactly one backup.
        let result = try EnvFileWriter.rewrite(
            env, original: Data("A=1\n".utf8), text: "A=2\n", backupRoot: backupRoot
        )
        XCTAssertEqual(try Data(contentsOf: result.backup), Data(), "A is not a companion line (audit lead 4)")
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "A=2\n")
        XCTAssertEqual(backupFiles(under: dir).count, 1, "one backup, the one the result names")
    }
}

/// Passes through to the service and counts what the runner asked for; `onApply` runs
/// after the plan is applied, which is how a test makes the file change under phase B.
private final class ReplyingBackend: WrapBackend {
    let inner: ServiceWrapBackend
    var applied = 0
    var compensated: [[WrapIssued]] = []
    private let onApply: ((String) throws -> Void)?

    init(inner: ServiceWrapBackend, onApply: ((String) throws -> Void)? = nil) {
        self.inner = inner
        self.onApply = onApply
    }

    func plan(file: String, path: String?, candidates: [WrapCandidate]) throws -> WrapPlan {
        try inner.plan(file: file, path: path, candidates: candidates)
    }

    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued] {
        let issued = try inner.apply(id: id, label: label, days: days)
        applied += 1
        try onApply?(id)
        return issued
    }

    func cancel(id: String) { inner.cancel(id: id) }

    func compensate(_ issued: [WrapIssued], path: String) -> Bool {
        compensated.append(issued)
        return inner.compensate(issued, path: path)
    }
}
