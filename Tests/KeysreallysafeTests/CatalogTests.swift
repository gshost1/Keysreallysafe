import XCTest
@testable import KeysCore

final class CatalogTests: XCTestCase {
    func testInsertListDelete() throws {
        let (db, _) = try makeDB()
        let row = CatalogRow(
            name: "demo",
            provider: "xai",
            kind: "runtime",
            notes: "n",
            createdAt: "2026-01-15T00:00:00Z",
            lastUsedAt: nil
        )
        try db.insertCatalog(row)
        let listed = try db.listCatalog()
        XCTAssertEqual(listed.map(\.name), ["demo"])
        XCTAssertEqual(listed[0].provider, "xai")
        XCTAssertNil(listed[0].lastUsedAt)
        try db.touchLastUsed(name: "demo", at: "2026-01-15T12:00:00Z")
        XCTAssertEqual(try db.listCatalog()[0].lastUsedAt, "2026-01-15T12:00:00Z")
        try db.deleteCatalog(name: "demo")
        XCTAssertTrue(try db.listCatalog().isEmpty)
    }

    func testDuplicateNameFails() throws {
        let (db, _) = try makeDB()
        let row = CatalogRow(
            name: "demo",
            provider: "xai",
            kind: "runtime",
            notes: "",
            createdAt: "2026-01-15T00:00:00Z",
            lastUsedAt: nil
        )
        try db.insertCatalog(row)
        XCTAssertThrowsError(try db.insertCatalog(row))
    }

    func testNoSecretColumnInListJSON() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        let data = try JSONValue.data(service.listJSONObject())
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains(fixtureSecret))
        XCTAssertFalse(text.contains("\"secret\""))
        XCTAssertTrue(text.contains("\"name\":\"demo\""))
    }

    func testModelColorSlotsStableAndWrapAfter24() throws {
        let (db, _) = try makeDB()
        for i in 0..<25 {
            _ = try db.insertUsage(
                UsageEvent(
                    source: "grok-local",
                    sessionId: "colors",
                    promptId: "p\(i)",
                    model: "m-\(i)",
                    occurredAt: String(format: "2026-01-01T00:%02d:00Z", i),
                    provider: "xai",
                    cwd: nil,
                    sessionTitle: nil,
                    agentName: nil,
                    stopReason: nil,
                    modelCalls: 1,
                    apiDurationMs: 1,
                    inputTokens: 1,
                    outputTokens: 1,
                    cachedReadTokens: 0,
                    cacheCreationTokens: 0,
                    reasoningTokens: 0,
                    costUsdTicks: 1
                )
            )
        }
        try db.ensureModelColors()
        let first = try db.listModelColors()
        let byModel = Dictionary(uniqueKeysWithValues: first.map { ($0.model, $0.slot) })
        XCTAssertEqual(byModel["m-0"], 0)
        XCTAssertEqual(byModel["m-23"], 23)
        XCTAssertEqual(byModel["m-24"], 0)
        try db.ensureModelColors()
        let second = try db.listModelColors()
        XCTAssertEqual(second.map(\.model), first.map(\.model))
        XCTAssertEqual(second.map(\.slot), first.map(\.slot))
    }

    func testDBFileMode0600() throws {
        let dir = try TempDir.make()
        let keysDir = dir.appendingPathComponent("Keysreallysafe", isDirectory: true)
        let path = keysDir.appendingPathComponent("catalog.db")
        _ = try CatalogDB(path: path)
        let fileMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue ?? 0 & 0o777, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: keysDir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue ?? 0 & 0o777, 0o700)
    }
}
