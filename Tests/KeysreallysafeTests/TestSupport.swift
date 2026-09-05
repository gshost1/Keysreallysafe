import Foundation
@testable import KeysCore

enum Fixtures {
    static let root: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    static var grokHome: URL { root.appendingPathComponent("grok-home") }
    static var claudeHome: URL { root.appendingPathComponent("claude-home") }
    static var claudeDedupHome: URL { root.appendingPathComponent("claude-dedup") }
    static var codexHome: URL { root.appendingPathComponent("codex-home") }
    static var grokQuotaHome: URL { root.appendingPathComponent("grok-quota") }
    static var codexQuotaHome: URL { root.appendingPathComponent("codex-quota") }
    static var turnCompleted: URL { root.appendingPathComponent("turn_completed.json") }
    static var twoModels: URL { root.appendingPathComponent("two_models.json") }
}

enum TempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("krs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}

func makeDB() throws -> (CatalogDB, URL) {
    let dir = try TempDir.make()
    let path = dir.appendingPathComponent("catalog.db")
    return (try CatalogDB(path: path), dir)
}

func makeService(db: CatalogDB) -> (KeysService, MemorySecretStore, FakeClipboard) {
    let secrets = MemorySecretStore()
    let clipboard = FakeClipboard()
    let service = KeysService(
        catalog: db,
        secrets: secrets,
        clipboard: clipboard,
        grokHome: Fixtures.grokHome,
        claudeHome: Fixtures.claudeHome,
        codexHome: Fixtures.codexHome
    )
    return (service, secrets, clipboard)
}

final class ThrowingSecretStore: SecretStore, @unchecked Sendable {
    var error: AppError
    init(_ error: AppError) { self.error = error }
    func add(name: String, secret: String) throws { throw error }
    func get(name: String) throws -> String { throw error }
    func delete(name: String) throws { throw error }
    func replace(name: String, secret: String) throws { throw error }
    func deleteAll() throws { throw error }
    func confirmPresence(reason: String) throws { throw error }
}

final class FakeOpenRouter: OpenRouterFetching, @unchecked Sendable {
    var snapshot: CatalogDB.ProviderSnapshot
    var calls: [String] = []
    var error: Error?
    init(snapshot: CatalogDB.ProviderSnapshot) {
        self.snapshot = snapshot
    }
    func fetch(secret: String) throws -> CatalogDB.ProviderSnapshot {
        calls.append(secret)
        if let error { throw error }
        return snapshot
    }
}

final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    var lastArgv: [String]?
    var lastExtraEnv: [String: String]?
    var status: Int32 = 0
    var error: Error?
    func run(argv: [String], extraEnv: [String: String]) throws -> Int32 {
        lastArgv = argv
        lastExtraEnv = extraEnv
        if let error { throw error }
        return status
    }
}

final class RecordingPresenceGate: PresenceGate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reasons: [String] = []
    var error: AppError?
    func require(reason: String) throws {
        lock.lock()
        reasons.append(reason)
        let err = error
        lock.unlock()
        if let err { throw err }
    }
}

func fieldNames(_ value: Any) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
}

let sentinelMessage = "DO-NOT-INGEST-MESSAGE-TEXT"
let sentinelRaw = "DO-NOT-INGEST-RAW-INPUT"
let sentinelClaude = "DO-NOT-INGEST-CLAUDE-CONTENT"
let fixtureSecret = "unit-test-secret-value-xyz"
