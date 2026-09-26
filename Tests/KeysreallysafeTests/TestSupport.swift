import Foundation
import XCTest
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

    /// The one turn_completed line of a synthetic Grok session in grok-home.
    static func grokTurnLine(_ session: String) throws -> String {
        let url = grokHome.appendingPathComponent("sessions/synth/\(session)/updates.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"turn_completed\"") }) else {
            throw AppError.notFound(session)
        }
        return String(line)
    }
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
    let (service, _) = makeGatedService(db: db, secrets: secrets, clipboard: clipboard)
    return (service, secrets, clipboard)
}

/// A service over the fixture homes whose presence gate records every prompt it would show.
func makeGatedService(
    db: CatalogDB,
    secrets: any SecretStore = MemorySecretStore(),
    gate: RecordingPresenceGate = RecordingPresenceGate(),
    clipboard: any ClipboardClient = FakeClipboard(),
    runner: any CommandRunner = FoundationCommandRunner(),
    openRouter: any OpenRouterFetching = OpenRouterHTTP()
) -> (KeysService, RecordingPresenceGate) {
    let service = KeysService(
        catalog: db,
        secrets: secrets,
        presence: gate,
        clipboard: clipboard,
        grokHome: Fixtures.grokHome,
        claudeHome: Fixtures.claudeHome,
        codexHome: Fixtures.codexHome,
        runner: runner,
        openRouter: openRouter
    )
    return (service, gate)
}

/// A dashboard handler over a fresh catalog, serving a stub Web/index.html.
func makeHandler() throws -> (APIHandler, KeysService, URL) {
    let (db, dir) = try makeDB()
    let (service, _, _) = makeService(db: db)
    let web = dir.appendingPathComponent("Web", isDirectory: true)
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    try "<html><head></head><title>Keysreallysafe</title></html>".write(
        to: web.appendingPathComponent("index.html"),
        atomically: true,
        encoding: .utf8
    )
    return (APIHandler(service: service, webRoot: web), service, dir)
}

/// One dashboard request from the loopback origin. Mutations carry the CSRF token unless
/// `token` is false; caller headers win over both defaults.
func handle(
    _ handler: APIHandler,
    method: String,
    path: String,
    query: [String: String] = [:],
    headers: [String: String] = [:],
    body: Data = Data(),
    token: Bool = true
) -> HTTPResponse {
    var headers = headers
    headers["host"] = headers["host"] ?? "127.0.0.1:12765"
    if token, method != "GET", method != "HEAD" {
        headers["x-ksf-token"] = headers["x-ksf-token"] ?? handler.originToken
    }
    return handler.handle(HTTPRequest(
        method: method,
        path: path,
        query: query,
        headers: headers,
        body: body,
        serverPort: 12765
    ))
}

/// Requests a stub upstream received, in arrival order.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var last: HTTPRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    func record(_ request: HTTPRequest) { lock.lock(); requests.append(request); lock.unlock() }
}

/// A stub upstream, a service with a recording presence gate and a gateway listener in front,
/// all started. The rig adds no key: `key(_:)` adds one and points its gateway at the stub.
final class GatewayRig {
    let db: CatalogDB
    let dir: URL
    let service: KeysService
    let gate: RecordingPresenceGate
    let stub: LoopbackHTTPServer
    let gateway: GatewayListener

    init(upstream: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        (db, dir) = try makeDB()
        (service, gate) = makeGatedService(db: db)
        stub = try LoopbackHTTPServer(port: 0, handler: upstream)
        gateway = try GatewayListener(service: service, port: 0)
        stub.start()
        gateway.start()
    }

    func stop() {
        gateway.stop()
        stub.stop()
    }

    func key(_ name: String = "demo", provider: String = "openai", secret: String = fixtureSecret) throws {
        try service.add(name: name, provider: provider, kind: "runtime", notes: "", secret: secret)
        _ = try service.setGateway(name: name, enabled: true, host: "127.0.0.1:\(stub.boundPort)")
    }

    func url(_ rest: String, key: String = "demo") -> URL {
        URL(string: "http://127.0.0.1:\(gateway.boundPort)/\(key)/\(rest)")!
    }

    /// The gateway answers the client before it records usage, so wait (boundedly) for the rows.
    func usageRows() async throws -> [UsageEvent] {
        var rows: [UsageEvent] = []
        for _ in 0..<200 where rows.isEmpty {
            rows = try db.gatewayEvents()
            if rows.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        return rows
    }
}

/// Fails if any file under `dir` (the catalog and its WAL included) holds `needle`.
func assertNoSentinel(_ needle: String, in dir: URL, file: StaticString = #filePath, line: UInt = #line) {
    let bytes = Data(needle.utf8)
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        if let data = try? Data(contentsOf: url) {
            XCTAssertNil(data.range(of: bytes), "sentinel found in \(url.path)", file: file, line: line)
        }
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    func add(name: String, secret: String) throws {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        if items[name] != nil { throw AppError.alreadyExists(name) }
        items[name] = secret
    }

    func get(name: String) throws -> String {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        guard let value = items[name] else { throw AppError.notFound(name) }
        return value
    }

    func delete(name: String) throws {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: name)
    }

    func replace(name: String, secret: String) throws {
        try KeyName.validate(name)
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        lock.lock()
        defer { lock.unlock() }
        guard items[name] != nil else { throw AppError.notFound(name) }
        items[name] = secret
    }

    func deleteAll() throws {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
}

final class FakeClipboard: ClipboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: String?
    private(set) var lastBackgroundWipe: TimeInterval?

    func copy(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func copyAndHoldUntilWipe(_ value: String) {
        copy(value)
    }

    func copyAndWipeInBackground(_ value: String) {
        copy(value)
        lock.lock()
        lastBackgroundWipe = ClipboardWipe.seconds
        lock.unlock()
    }
}

final class ThrowingSecretStore: SecretStore, @unchecked Sendable {
    var error: AppError
    init(_ error: AppError) { self.error = error }
    func add(name: String, secret: String) throws { throw error }
    func get(name: String) throws -> String { throw error }
    func delete(name: String) throws { throw error }
    func replace(name: String, secret: String) throws { throw error }
    func deleteAll() throws { throw error }
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
    init(error: AppError? = nil) { self.error = error }
    func require(reason: String) throws {
        lock.lock()
        reasons.append(reason)
        let err = error
        lock.unlock()
        if let err { throw err }
    }
}

extension UsageEvent {
    /// One local usage row; the provider follows from the source.
    static func fixture(
        source: String = "grok-local", session: String = "s", prompt: String = "p",
        model: String = "grok-4.6-build", at: String = "2026-01-15T12:00:00Z", cwd: String? = nil,
        input: Int = 1, output: Int = 1, ticks: Int64? = nil
    ) -> UsageEvent {
        let provider = ["claude-local": "anthropic", "codex-local": "openai"][source] ?? "xai"
        return UsageEvent(
            source: source, sessionId: session, promptId: prompt, model: model, occurredAt: at,
            provider: provider, cwd: cwd, modelCalls: 1, inputTokens: input, outputTokens: output,
            costUsdTicks: ticks
        )
    }
}

/// A priced Grok turn of 10 input and 5 output tokens.
func grokEvent(at iso: String, usd: Double, prompt: String, model: String = "grok-4.6-build") -> UsageEvent {
    .fixture(
        session: "boundary", prompt: prompt, model: model, at: iso, input: 10, output: 5,
        ticks: Int64((usd * Ticks.perUSD).rounded())
    )
}

/// One Claude Code assistant line; the request id defaults to the uuid.
func assistantLine(
    uuid: String, model: String = "claude-sonnet-5", input: Int = 10, output: Int,
    requestId: String? = nil, session: String = "inc-sess",
    cwd: String = "/tmp/keysreallysafe-fixture", at: String = "2026-01-15T12:00:00.000Z"
) -> String {
    let request = requestId ?? uuid
    return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"requestId\":\"\(request)\",\"sessionId\":\"\(session)\",\"timestamp\":\"\(at)\",\"cwd\":\"\(cwd)\",\"message\":{\"id\":\"msg-\(request)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
}

func fieldNames(_ value: Any) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
}

let sentinelMessage = "DO-NOT-INGEST-MESSAGE-TEXT"
let sentinelRaw = "DO-NOT-INGEST-RAW-INPUT"
let sentinelClaude = "DO-NOT-INGEST-CLAUDE-CONTENT"
let fixtureSecret = "unit-test-secret-value-xyz"

/// One grant for `key` on a service whose secret store has no presence gate (or a recording one).
@discardableResult
func grantFor(_ service: KeysService, _ key: String, task: String = "test", minutes: Int = 30) throws -> String {
    try service.issueGrant(name: key, request: GrantRequest(task: task, minutes: minutes), caller: "test").token
}

extension CatalogDB {
    /// Every stored usage row, in the order the spend queries use.
    func allUsageEvents() throws -> [UsageEvent] {
        try usageEvents(from: "", to: "\u{10FFFF}", source: .all)
    }

    /// Every stored gateway call.
    func gatewayEvents() throws -> [UsageEvent] {
        try usageEvents(from: "", to: "\u{10FFFF}", source: .keys)
    }
}

extension CodexIngest {
    /// A whole rollout through one parser, without touching a catalog.
    static func parseFile(_ url: URL) throws -> [UsageEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var parser = LineParser(sessionId: sessionIdFromFilename(url.lastPathComponent))
        return text.split(separator: "\n").compactMap { parser.consume(String($0)) }
    }
}
