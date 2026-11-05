import SQLite3
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
        XCTAssertThrowsError(try db.insertCatalog(row)) { error in
            guard case AppError.alreadyExists("demo") = error else { return XCTFail("\(error)") }
        }
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
            _ = try db.insertUsage(.fixture(
                session: "colors", prompt: "p\(i)", model: "m-\(i)",
                at: String(format: "2026-01-01T00:%02d:00Z", i), ticks: 1
            ))
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

    /// Token counts above Int32.max must survive a round-trip; the reads used to be 32-bit
    /// so anything over ~2.1 billion came back as a negative number.
    func testTokenCountsAboveInt32MaxRoundTrip() throws {
        let (db, _) = try makeDB()
        let input = 3_000_000_000
        let output = 3_000_000_001
        let cachedRead = 3_000_000_002
        let cacheCreation = 3_000_000_003
        let reasoning = 3_000_000_004
        XCTAssertGreaterThan(input, 2_147_483_647)
        let event = UsageEvent(
            source: "gateway", sessionId: "gw:big", promptId: "p1", model: "grok-4.6-build",
            occurredAt: "2026-01-15T12:00:00Z", provider: "xai", cwd: nil, sessionTitle: nil,
            modelCalls: 1,
            inputTokens: input, outputTokens: output, cachedReadTokens: cachedRead,
            cacheCreationTokens: cacheCreation, reasoningTokens: reasoning, costUsdTicks: nil
        )
        try db.insertUsage(event)

        let stored = try db.gatewayEvents()
        XCTAssertEqual(stored.count, 1)
        let got = stored[0]
        XCTAssertEqual(got.inputTokens, input)
        XCTAssertEqual(got.outputTokens, output)
        XCTAssertEqual(got.cachedReadTokens, cachedRead)
        XCTAssertEqual(got.cacheCreationTokens, cacheCreation)
        XCTAssertEqual(got.reasoningTokens, reasoning)

        let report = try SpendQueries(db: db).report(
            range: .month, by: .model,
            now: UTC.parse("2026-01-20T00:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(report.totals.inputTokens, input)
    }

    /// A 0.9 catalog has usage_events without http_status; opening it adds the column.
    func testOpeningPre010CatalogAddsGatewayStatusColumn() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE usage_events (
              source TEXT NOT NULL, session_id TEXT NOT NULL, prompt_id TEXT NOT NULL, model TEXT NOT NULL,
              occurred_at TEXT NOT NULL, provider TEXT NOT NULL, cwd TEXT, session_title TEXT, model_calls INTEGER,
              input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              cached_read_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              reasoning_tokens INTEGER NOT NULL DEFAULT 0, cost_usd_ticks INTEGER, key_name TEXT,
              PRIMARY KEY (source, session_id, prompt_id, model));
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = try CatalogDB(path: path)
        try db.insertUsage(GatewayUsageRow(ts: "2026-09-01T00:00:00Z", key: "k", provider: "openai", model: "gpt-4.1",
                                           status: 502, durationMs: 1, requestId: "r1").usageEvent())
        XCTAssertEqual(try db.gatewayEvents().map(\.httpStatus), [502])
        XCTAssertEqual(try CatalogDB(path: path).gatewayEvents().map(\.httpStatus), [502], "reopening is a no-op")
    }
}

/// Plan-window and limit tracking was removed on 2026-11-03. A catalog written by 0.14.x still
/// holds its tables and preferences; opening it must drop them and leave everything else.
final class RetiredPlanMeterMigrationTests: XCTestCase {
    private func rawExec(_ path: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK { XCTFail(String(cString: err!)); sqlite3_free(err) }
    }

    private func tableNames(_ path: URL) -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type = 'table';", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    func testLaunchRetiresTheMeterTablesAndPreferencesOnly() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        // A 0.14.1-shaped catalog: open once so every live table exists, then add what the
        // meter wrote the way that release did.
        do {
            let db = try CatalogDB(path: path)
            try db.setMeta(AppPreferences.welcomeKey, "2026-10-01T00:00:00Z")
        }
        try rawExec(path, """
            CREATE TABLE usage_limits (source TEXT NOT NULL, window TEXT NOT NULL, tokens INTEGER NOT NULL,
              PRIMARY KEY (source, window));
            INSERT INTO usage_limits VALUES ('droid', 'weekly', 1000000);
            CREATE TABLE subscriptions (id TEXT PRIMARY KEY, tool TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
              plan TEXT NOT NULL, limit_amount REAL, limit_unit TEXT, limit_period TEXT, created_at TEXT NOT NULL);
            INSERT INTO subscriptions VALUES ('s1', 'cursor', '', 'Pro', 500, 'requests', 'monthly', '2026-10-01T00:00:00Z');
            CREATE TABLE provider_snapshots (provider TEXT NOT NULL, key_name TEXT NOT NULL, ts TEXT NOT NULL,
              usage_daily REAL, usage_weekly REAL, usage_monthly REAL, "limit" REAL, limit_remaining REAL, raw_kind TEXT);
            CREATE INDEX provider_snapshots_key_ts ON provider_snapshots (provider, key_name, ts DESC);
            INSERT INTO provider_snapshots VALUES ('openrouter', 'or', '2026-10-01T00:00:00Z', 1, 2, 3, 100, 97, 'monthly');
            INSERT OR REPLACE INTO meta VALUES ('pref_claude_usage_refresh', 'on');
            INSERT OR REPLACE INTO meta VALUES ('pref_show_usage_meter', 'on');
            INSERT OR REPLACE INTO meta VALUES ('pref_hidden_usage', '["openai"]');
            """)
        XCTAssertTrue(tableNames(path).isSuperset(of: CatalogDB.retiredTables), "the 0.14 tables are in place")

        // Opening the catalog writes nothing: an older Keysrs still running against the same
        // file keeps its tables until this release's app launch retires them.
        let db = try CatalogDB(path: path)
        XCTAssertTrue(tableNames(path).isSuperset(of: CatalogDB.retiredTables), "open alone leaves them")
        XCTAssertEqual(try db.metaValue("pref_show_usage_meter"), "on")

        XCTAssertTrue(try db.removeRetiredPlanMeter())
        XCTAssertTrue(tableNames(path).isDisjoint(with: CatalogDB.retiredTables), "\(tableNames(path))")
        for key in CatalogDB.retiredMetaKeys {
            XCTAssertNil(try db.metaValue(key), key)
        }
        XCTAssertEqual(try db.metaValue(AppPreferences.welcomeKey), "2026-10-01T00:00:00Z", "other meta survives")
        XCTAssertNotNil(try db.metaValue("catalog_version"))

        // The second launch finds nothing to do, and purge's wipe still runs over the store.
        XCTAssertFalse(try db.removeRetiredPlanMeter())
        try db.wipeData()
        XCTAssertNil(try db.metaValue(AppPreferences.welcomeKey))
    }

    /// A 0.15-shaped catalog: rows from the four log readers and the cloud import beside the
    /// gateway ledger, the per-file cursors, the last-ingest stamp and colors for both kinds of
    /// model. Opening it changes nothing (a 0.15 process may still be using it); the launch
    /// cleanup keeps only the gateway's rows and colors, and a second run is a no-op.
    func testLaunchRetiresSubscriptionUsageAndKeepsTheGatewayLedger() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        do {
            let db = try CatalogDB(path: path)
            for source in ["claude-local", "codex-local", "grok-local", "droid-local", "claude-remote", "droid-remote"] {
                try db.insertUsage(.fixture(source: source, session: source, prompt: "p", model: "sub-\(source)", key: nil))
            }
            try db.insertUsage(.fixture(prompt: "gw-1", model: "gw-model", key: "alpha"))
            try db.setMeta("last_ingest_at", "2026-10-01T00:00:00Z")
            try db.setMeta(AppPreferences.welcomeKey, "2026-10-01T00:00:00Z")
        }
        try rawExec(path, """
            INSERT INTO model_colors (model, slot) VALUES ('sub-claude-local', 0), ('gw-model', 1), ('sub-grok-local', 2);
            CREATE TABLE ingest_files (path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime INTEGER NOT NULL,
              byte_offset INTEGER NOT NULL, tail_sig TEXT, parser_json TEXT);
            INSERT INTO ingest_files VALUES ('/Users/someone/.claude/projects/p/s.jsonl', 10, 1, 10, 'v2:00', NULL);
            """)

        let db = try CatalogDB(path: path)
        XCTAssertTrue(tableNames(path).contains("ingest_files"), "open alone leaves the cursors")
        XCTAssertTrue(try db.usageExists(source: "claude-local", sessionId: "claude-local", promptId: "p", model: "sub-claude-local"))
        let before = try db.catalogVersion()

        XCTAssertTrue(try db.removeRetiredSubscriptionUsage())
        XCTAssertFalse(tableNames(path).contains("ingest_files"))
        for source in ["claude-local", "codex-local", "grok-local", "droid-local", "claude-remote", "droid-remote"] {
            XCTAssertFalse(try db.usageExists(source: source, sessionId: source, promptId: "p", model: "sub-\(source)"), source)
        }
        XCTAssertEqual(try db.gatewayEvents().map(\.promptId), ["gw-1"], "the gateway ledger stays")
        XCTAssertEqual(try db.listModelColors().map(\.model), ["gw-model"], "colors of log-only models go")
        XCTAssertNil(try db.metaValue("last_ingest_at"))
        XCTAssertEqual(try db.metaValue(AppPreferences.welcomeKey), "2026-10-01T00:00:00Z", "other meta survives")
        XCTAssertEqual(try db.catalogVersion(), before + 1, "open dashboards reload")

        XCTAssertFalse(try db.removeRetiredSubscriptionUsage(), "the second launch finds nothing to do")
        XCTAssertEqual(try db.catalogVersion(), before + 1)
    }
}
