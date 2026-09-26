import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CatalogDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    let path: URL

    init(path: URL) throws {
        self.path = path
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: dir.lastPathComponent == "Keysreallysafe" ? [.posixPermissions: 0o700] : nil
        )
        if dir.lastPathComponent == "Keysreallysafe" {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = path.path.withCString { cPath in
            sqlite3_open_v2(cPath, &db, flags, nil)
        }
        guard status == SQLITE_OK, db != nil else {
            throw AppError.sqlite("open failed")
        }
        try exec("PRAGMA busy_timeout=5000")
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        // Overwrite freed pages so a deleted row does not linger in the file or the WAL.
        try exec("PRAGMA secure_delete=ON")
        try migrate()
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS catalog (
              name TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'runtime',
              notes TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              last_used_at TEXT,
              gateway_host TEXT,
              version INTEGER NOT NULL DEFAULT 1
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_events (
              source TEXT NOT NULL,
              session_id TEXT NOT NULL,
              prompt_id TEXT NOT NULL,
              model TEXT NOT NULL,
              occurred_at TEXT NOT NULL,
              provider TEXT NOT NULL,
              cwd TEXT,
              session_title TEXT,
              model_calls INTEGER,
              input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cached_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              reasoning_tokens INTEGER NOT NULL DEFAULT 0,
              cost_usd_ticks INTEGER,
              key_name TEXT,
              http_status INTEGER,
              PRIMARY KEY (source, session_id, prompt_id, model)
            );
            """)
        // Gateway calls used to keep their status in a separate gateway_usage table, which is
        // left in place for older binaries; a usage_events table from those versions lacks it.
        if try !tableHasColumn("usage_events", "http_status") {
            try exec("ALTER TABLE usage_events ADD COLUMN http_status INTEGER;")
        }
        try exec("CREATE INDEX IF NOT EXISTS usage_events_occurred ON usage_events (occurred_at);")
        try exec("CREATE INDEX IF NOT EXISTS usage_events_model ON usage_events (model);")
        try exec("""
            CREATE TABLE IF NOT EXISTS ingest_files (
              path TEXT PRIMARY KEY,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              byte_offset INTEGER NOT NULL,
              tail_sig TEXT,
              parser_json TEXT
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
        try exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('catalog_version', '0');")
        try exec("""
            CREATE TABLE IF NOT EXISTS model_colors (
              model TEXT PRIMARY KEY,
              slot INTEGER NOT NULL
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS usage_events_key ON usage_events (key_name);")
        try exec("""
            CREATE TABLE IF NOT EXISTS key_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              name TEXT NOT NULL,
              action TEXT NOT NULL,
              caller TEXT,
              detail TEXT
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS key_events_name_ts ON key_events (name, ts DESC, id DESC);")
        try exec("""
            CREATE TABLE IF NOT EXISTS provider_checks (
              key_name TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              host TEXT NOT NULL,
              ts TEXT NOT NULL,
              outcome TEXT NOT NULL,
              http_status INTEGER,
              models_json TEXT NOT NULL DEFAULT '[]',
              request_id TEXT,
              message TEXT,
              endpoint TEXT
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS provider_snapshots (
              provider TEXT NOT NULL,
              key_name TEXT NOT NULL,
              ts TEXT NOT NULL,
              usage_daily REAL,
              usage_weekly REAL,
              usage_monthly REAL,
              "limit" REAL,
              limit_remaining REAL,
              raw_kind TEXT
            );
            """)
        try exec(
            "CREATE INDEX IF NOT EXISTS provider_snapshots_key_ts ON provider_snapshots (provider, key_name, ts DESC);"
        )
        try exec("""
            CREATE TABLE IF NOT EXISTS gateway_clients (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              key_name TEXT NOT NULL,
              label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE,
              hint TEXT NOT NULL DEFAULT '',
              methods TEXT NOT NULL,
              path_prefix TEXT,
              created_at TEXT NOT NULL,
              expires_at TEXT NOT NULL,
              revoked_at TEXT,
              last_used_at TEXT
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS gateway_clients_key ON gateway_clients (key_name, id);")
        // Cursors written before 0.2 held the last 32 raw bytes of a log as hex, which could include
        // a fragment of a user message. Clear any that remain, and checkpoint and vacuum so neither
        // the main file nor the WAL keeps the old page images. The vacuum is best effort.
        try exec("UPDATE ingest_files SET tail_sig = NULL WHERE tail_sig != '' AND tail_sig NOT LIKE 'v2:%';")
        if sqlite3_changes(db) > 0 {
            try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try? exec("VACUUM")
        }
    }

    struct IngestFileCursor: Equatable {
        var size: Int64
        var mtimeMs: Int64
        var byteOffset: Int64
        var tailSig: String? = nil
        var parserJSON: String? = nil
    }

    func ingestFile(path: String) throws -> IngestFileCursor? {
        try one("SELECT size, mtime, byte_offset, tail_sig, parser_json FROM ingest_files WHERE path = ?;", path) {
            IngestFileCursor(
                size: sqlite3_column_int64($0, 0),
                mtimeMs: sqlite3_column_int64($0, 1),
                byteOffset: sqlite3_column_int64($0, 2),
                tailSig: columnText($0, 3),
                parserJSON: columnText($0, 4)
            )
        }
    }

    func upsertIngestFile(
        path: String,
        size: Int64,
        mtimeMs: Int64,
        byteOffset: Int64,
        tailSig: String? = nil,
        parserJSON: String? = nil
    ) throws {
        try run("""
            INSERT INTO ingest_files (path, size, mtime, byte_offset, tail_sig, parser_json)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
              size = excluded.size,
              mtime = excluded.mtime,
              byte_offset = excluded.byte_offset,
              tail_sig = excluded.tail_sig,
              parser_json = excluded.parser_json;
            """, path, size, mtimeMs, byteOffset, tailSig, parserJSON)
    }

    func lastIngestAt() throws -> String? {
        try metaValue("last_ingest_at")
    }

    func setLastIngestAt(_ iso: String) throws {
        try setMeta("last_ingest_at", iso)
    }

    func catalogVersion() throws -> Int {
        Int(try metaValue("catalog_version") ?? "0") ?? 0
    }

    private var inTransaction = false

    @discardableResult
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            if inTransaction {
                return try body()
            }
            try exec("BEGIN IMMEDIATE")
            inTransaction = true
            do {
                let result = try body()
                try exec("COMMIT")
                inTransaction = false
                return result
            } catch {
                inTransaction = false
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    func bumpCatalogVersion() throws {
        try withLock {
            try exec(
                "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'catalog_version';"
            )
        }
    }

    func metaValue(_ key: String) throws -> String? {
        try one("SELECT value FROM meta WHERE key = ?;", key) { columnText($0, 0) } ?? nil
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("""
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, key, value)
    }

    private static let catalogColumns = "name, provider, kind, notes, created_at, last_used_at, gateway_host, version"

    func insertCatalog(_ row: CatalogRow) throws {
        try withLock {
            do {
                try run(
                    "INSERT INTO catalog (\(Self.catalogColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                    row.name, row.provider, row.kind, row.notes, row.createdAt, row.lastUsedAt, row.gatewayHost,
                    row.version
                )
            } catch where sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                throw AppError.alreadyExists(row.name)
            }
        }
    }

    func deleteCatalog(name: String) throws {
        try withLock {
            if try run("DELETE FROM catalog WHERE name = ?;", name) == 0 {
                throw AppError.notFound(name)
            }
            // A capability for a key that no longer exists must not outlive it.
            try run("DELETE FROM gateway_clients WHERE key_name = ?;", name)
        }
    }

    // MARK: gateway clients

    func insertGatewayClient(
        keyName: String,
        label: String,
        tokenHash: String,
        hint: String,
        methods: [String],
        pathPrefix: String?,
        createdAt: String,
        expiresAt: String
    ) throws -> GatewayClient {
        try withLock {
            try run("""
                INSERT INTO gateway_clients
                  (key_name, label, token_hash, hint, methods, path_prefix, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, keyName, label, tokenHash, hint, methods.joined(separator: ","), pathPrefix, createdAt, expiresAt)
            return GatewayClient(
                id: sqlite3_last_insert_rowid(db),
                keyName: keyName,
                label: label,
                methods: methods,
                pathPrefix: pathPrefix,
                createdAt: createdAt,
                expiresAt: expiresAt,
                revokedAt: nil,
                lastUsedAt: nil,
                hint: hint
            )
        }
    }

    private static let gatewayClientColumns =
        "id, key_name, label, hint, methods, path_prefix, created_at, expires_at, revoked_at, last_used_at"

    private func decodeGatewayClient(_ stmt: OpaquePointer) -> GatewayClient {
        GatewayClient(
            id: sqlite3_column_int64(stmt, 0),
            keyName: columnText(stmt, 1) ?? "",
            label: columnText(stmt, 2) ?? "",
            methods: (columnText(stmt, 4) ?? "").split(separator: ",").map(String.init),
            pathPrefix: columnText(stmt, 5),
            createdAt: columnText(stmt, 6) ?? "",
            expiresAt: columnText(stmt, 7) ?? "",
            revokedAt: columnText(stmt, 8),
            lastUsedAt: columnText(stmt, 9),
            hint: columnText(stmt, 3) ?? ""
        )
    }

    func gatewayClients(keyName: String) throws -> [GatewayClient] {
        try query(
            "SELECT \(Self.gatewayClientColumns) FROM gateway_clients WHERE key_name = ? ORDER BY id;", keyName,
            row: decodeGatewayClient
        )
    }

    func gatewayClient(tokenHash: String) throws -> GatewayClient? {
        try one(
            "SELECT \(Self.gatewayClientColumns) FROM gateway_clients WHERE token_hash = ? LIMIT 1;", tokenHash,
            row: decodeGatewayClient
        )
    }

    /// Returns false when no such client belongs to the key or it was already revoked.
    func revokeGatewayClient(id: Int64, keyName: String, at iso: String) throws -> Bool {
        try run(
            "UPDATE gateway_clients SET revoked_at = ? WHERE id = ? AND key_name = ? AND revoked_at IS NULL;",
            iso, id, keyName
        ) > 0
    }

    func touchGatewayClient(id: Int64, at iso: String) throws {
        try run("UPDATE gateway_clients SET last_used_at = ? WHERE id = ?;", iso, id)
    }

    func catalogExists(name: String) throws -> Bool {
        try one("SELECT 1 FROM catalog WHERE name = ? LIMIT 1;", name) { _ in true } ?? false
    }

    func catalogRow(name: String) throws -> CatalogRow? {
        try one("SELECT \(Self.catalogColumns) FROM catalog WHERE name = ?;", name, row: decodeCatalog)
    }

    func updateCatalog(name: String, provider: String?, kind: String?, notes: String?) throws -> CatalogRow {
        try withLock {
            guard var row = try catalogRow(name: name) else {
                throw AppError.notFound(name)
            }
            if let provider { row.provider = provider }
            if let kind { row.kind = kind }
            if let notes { row.notes = notes }
            let changed = try run(
                "UPDATE catalog SET provider = ?, kind = ?, notes = ? WHERE name = ?;",
                row.provider, row.kind, row.notes, name
            )
            if changed == 0 {
                throw AppError.notFound(name)
            }
            return row
        }
    }

    func updateGatewayHost(name: String, host: String?) throws -> CatalogRow {
        try withLock {
            guard try catalogRow(name: name) != nil else {
                throw AppError.notFound(name)
            }
            if try run("UPDATE catalog SET gateway_host = ? WHERE name = ?;", host, name) == 0 {
                throw AppError.notFound(name)
            }
            guard let row = try catalogRow(name: name) else {
                throw AppError.notFound(name)
            }
            return row
        }
    }

    struct ModelColor: Equatable {
        var model: String
        var slot: Int
    }

    /// First sighting takes the lowest unused slot in 0..<24; further models wrap.
    func ensureModelColors() throws {
        try withTransaction {
            var occupied = Set<Int>()
            var known = Set<String>()
            for color in try query("SELECT model, slot FROM model_colors;", row: decodeModelColor) {
                known.insert(color.model)
                occupied.insert(color.slot)
            }
            var assignedCount = known.count
            let pending = try query("""
                SELECT model FROM usage_events
                GROUP BY model
                ORDER BY MIN(occurred_at), model;
                """) { columnText($0, 0) ?? "" }
            for model in pending {
                if model.isEmpty || known.contains(model) { continue }
                let slot: Int
                if let free = (0..<24).first(where: { !occupied.contains($0) }) {
                    slot = free
                    occupied.insert(slot)
                } else {
                    slot = assignedCount % 24
                }
                try run("INSERT OR IGNORE INTO model_colors (model, slot) VALUES (?, ?);", model, slot)
                known.insert(model)
                assignedCount += 1
            }
        }
    }

    private func decodeModelColor(_ stmt: OpaquePointer) -> ModelColor {
        ModelColor(model: columnText(stmt, 0) ?? "", slot: Int(sqlite3_column_int(stmt, 1)))
    }

    func listModelColors() throws -> [ModelColor] {
        try query("""
            SELECT c.model, c.slot
            FROM model_colors c
            INNER JOIN (SELECT DISTINCT model FROM usage_events) u ON u.model = c.model
            ORDER BY c.slot, c.model;
            """, row: decodeModelColor)
    }

    func listCatalog() throws -> [CatalogRow] {
        try query("SELECT \(Self.catalogColumns) FROM catalog ORDER BY name;", row: decodeCatalog)
    }

    func touchLastUsed(name: String, at iso: String) throws {
        try run("UPDATE catalog SET last_used_at = ? WHERE name = ?;", iso, name)
    }

    @discardableResult
    func usageExists(source: String, sessionId: String, promptId: String, model: String) throws -> Bool {
        try one(
            "SELECT 1 FROM usage_events WHERE source = ? AND session_id = ? AND prompt_id = ? AND model = ? LIMIT 1;",
            source, sessionId, promptId, model
        ) { _ in true } ?? false
    }

    private static let usageColumns = """
        source, session_id, prompt_id, model, occurred_at, provider,
        cwd, session_title, model_calls,
        input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
        reasoning_tokens, cost_usd_ticks, key_name, http_status
        """

    /// Upserts one event; true when it was new, false when it replaced an existing row.
    @discardableResult
    func insertUsage(_ event: UsageEvent) throws -> Bool {
        try withLock {
            let existed = try usageExists(
                source: event.source, sessionId: event.sessionId, promptId: event.promptId, model: event.model
            )
            try run("""
                INSERT INTO usage_events (\(Self.usageColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, session_id, prompt_id, model) DO UPDATE SET
                  occurred_at = excluded.occurred_at,
                  provider = excluded.provider,
                  cwd = excluded.cwd,
                  session_title = excluded.session_title,
                  model_calls = excluded.model_calls,
                  input_tokens = excluded.input_tokens,
                  output_tokens = excluded.output_tokens,
                  cached_read_tokens = excluded.cached_read_tokens,
                  cache_creation_tokens = excluded.cache_creation_tokens,
                  reasoning_tokens = excluded.reasoning_tokens,
                  cost_usd_ticks = excluded.cost_usd_ticks,
                  key_name = excluded.key_name,
                  http_status = excluded.http_status;
                """,
                event.source, event.sessionId, event.promptId, event.model, event.occurredAt, event.provider,
                event.cwd, event.sessionTitle, event.modelCalls,
                event.inputTokens, event.outputTokens, event.cachedReadTokens, event.cacheCreationTokens,
                event.reasoningTokens, event.costUsdTicks, event.keyName, event.httpStatus
            )
            return !existed
        }
    }

    func usageEvents(
        from startISO: String,
        to endISO: String,
        source: SourceFilter,
        key: String? = nil,
        provider: String? = nil
    ) throws -> [UsageEvent] {
        var sql = "SELECT \(Self.usageColumns) FROM usage_events WHERE occurred_at >= ? AND occurred_at < ?"
        var args: [any SQLBindable] = [startISO, endISO]
        if let values = source.sqlValues, !values.isEmpty {
            sql += " AND source IN (" + values.map { _ in "?" }.joined(separator: ", ") + ")"
            args += values as [any SQLBindable]
        }
        if let key {
            sql += " AND key_name = ?"
            args.append(key)
        }
        // Narrowing to one provider happens here, before any aggregation, so totals, rows,
        // daily and hourly buckets all describe the same set of calls.
        if let provider {
            sql += " AND provider = ?"
            args.append(provider)
        }
        sql += " ORDER BY occurred_at, model;"
        return try query(sql, args, row: event(from:))
    }

    private func event(from stmt: OpaquePointer) -> UsageEvent {
        UsageEvent(
            source: columnText(stmt, 0) ?? "",
            sessionId: columnText(stmt, 1) ?? "",
            promptId: columnText(stmt, 2) ?? "",
            model: columnText(stmt, 3) ?? "unknown",
            occurredAt: columnText(stmt, 4) ?? "",
            provider: columnText(stmt, 5) ?? "",
            cwd: columnText(stmt, 6),
            sessionTitle: columnText(stmt, 7),
            modelCalls: columnOptionalInt(stmt, 8),
            inputTokens: Int(sqlite3_column_int(stmt, 9)),
            outputTokens: Int(sqlite3_column_int(stmt, 10)),
            cachedReadTokens: Int(sqlite3_column_int(stmt, 11)),
            cacheCreationTokens: Int(sqlite3_column_int(stmt, 12)),
            reasoningTokens: Int(sqlite3_column_int(stmt, 13)),
            costUsdTicks: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 14),
            keyName: columnText(stmt, 15),
            httpStatus: columnOptionalInt(stmt, 16)
        )
    }

    /// Latest read-only provider check per key. Model IDs and status only; never a secret.
    func upsertProviderCheck(_ r: ProviderCheck.Result) throws {
        let models = (try? JSONValue.data(r.models)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try run("""
            INSERT INTO provider_checks
              (key_name, provider, host, ts, outcome, http_status, models_json, request_id, message, endpoint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key_name) DO UPDATE SET
              provider = excluded.provider, host = excluded.host, ts = excluded.ts,
              outcome = excluded.outcome, http_status = excluded.http_status,
              models_json = excluded.models_json, request_id = excluded.request_id,
              message = excluded.message, endpoint = excluded.endpoint;
            """, r.key, r.provider, r.host, r.checkedAt, r.outcome.rawValue, r.httpStatus, models,
            r.requestId, r.message, r.endpoint)
    }

    func providerCheck(keyName: String) throws -> ProviderCheck.Result? {
        try one("""
            SELECT key_name, provider, host, ts, outcome, http_status, models_json, request_id, message, endpoint
            FROM provider_checks WHERE key_name = ?;
            """, keyName) { stmt in
            let modelsData = Data((columnText(stmt, 6) ?? "[]").utf8)
            let models = ((try? JSONSerialization.jsonObject(with: modelsData)) as? [Any])?
                .compactMap { $0 as? String } ?? []
            return ProviderCheck.Result(
                key: columnText(stmt, 0) ?? keyName,
                provider: columnText(stmt, 1) ?? "",
                host: columnText(stmt, 2) ?? "",
                checkedAt: columnText(stmt, 3) ?? "",
                outcome: ProviderCheck.Outcome(rawValue: columnText(stmt, 4) ?? "") ?? .malformed,
                httpStatus: columnOptionalInt(stmt, 5),
                models: models,
                requestId: columnText(stmt, 7),
                message: columnText(stmt, 8),
                endpoint: columnText(stmt, 9)
            )
        }
    }

    func deleteProviderCheck(keyName: String) throws {
        try run("DELETE FROM provider_checks WHERE key_name = ?;", keyName)
    }

    struct KeyEventRow: Equatable {
        var id: Int64
        var ts: String
        var name: String
        var action: String
        var caller: String?
        var detail: String?
    }

    func insertKeyEvent(ts: String, name: String, action: String, caller: String?, detail: String?) throws {
        try run(
            "INSERT INTO key_events (ts, name, action, caller, detail) VALUES (?, ?, ?, ?, ?);",
            ts, name, action, caller, detail
        )
    }

    func keyEvents(name: String, limit: Int) throws -> [KeyEventRow] {
        try query("""
            SELECT id, ts, name, action, caller, detail
            FROM key_events
            WHERE name = ?
            ORDER BY ts DESC, id DESC
            LIMIT ?;
            """, name, limit) {
            KeyEventRow(
                id: sqlite3_column_int64($0, 0),
                ts: columnText($0, 1) ?? "",
                name: columnText($0, 2) ?? "",
                action: columnText($0, 3) ?? "",
                caller: columnText($0, 4),
                detail: columnText($0, 5)
            )
        }
    }

    struct ProviderSnapshot: Equatable {
        var provider: String
        var keyName: String
        var ts: String
        var usageDaily: Double?
        var usageWeekly: Double?
        var usageMonthly: Double?
        var limit: Double?
        var limitRemaining: Double?
        var rawKind: String?
    }

    func insertProviderSnapshot(_ row: ProviderSnapshot) throws {
        try run("""
            INSERT INTO provider_snapshots (
              provider, key_name, ts, usage_daily, usage_weekly, usage_monthly,
              "limit", limit_remaining, raw_kind
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, row.provider, row.keyName, row.ts, row.usageDaily, row.usageWeekly, row.usageMonthly,
            row.limit, row.limitRemaining, row.rawKind)
    }

    func latestProviderSnapshot(provider: String) throws -> ProviderSnapshot? {
        try one("""
            SELECT provider, key_name, ts, usage_daily, usage_weekly, usage_monthly,
                   "limit", limit_remaining, raw_kind
            FROM provider_snapshots
            WHERE provider = ?
            ORDER BY ts DESC
            LIMIT 1;
            """, provider) {
            ProviderSnapshot(
                provider: columnText($0, 0) ?? "",
                keyName: columnText($0, 1) ?? "",
                ts: columnText($0, 2) ?? "",
                usageDaily: columnOptionalDouble($0, 3),
                usageWeekly: columnOptionalDouble($0, 4),
                usageMonthly: columnOptionalDouble($0, 5),
                limit: columnOptionalDouble($0, 6),
                limitRemaining: columnOptionalDouble($0, 7),
                rawKind: columnText($0, 8)
            )
        }
    }

    func incrementVersion(name: String) throws -> Int {
        try withLock {
            if try run("UPDATE catalog SET version = version + 1 WHERE name = ?;", name) == 0 {
                throw AppError.notFound(name)
            }
            guard let row = try catalogRow(name: name) else { throw AppError.notFound(name) }
            return row.version
        }
    }

    func newestUsage(source: String) throws -> String? {
        try one("SELECT MAX(occurred_at) FROM usage_events WHERE source = ?;", source) { columnText($0, 0) } ?? nil
    }

    /// Every table is emptied, meta included, so a table or meta key added later cannot be
    /// forgotten here; only the catalog version is put back so open dashboards reload.
    func wipeData() throws {
        try withLock {
            let tables = try query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\';"
            ) { columnText($0, 0) }.compactMap { $0 }
            try exec("BEGIN IMMEDIATE")
            do {
                for table in tables {
                    try exec("DELETE FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\";")
                }
                try exec("INSERT INTO meta (key, value) VALUES ('catalog_version', '0');")
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    private func decodeCatalog(_ stmt: OpaquePointer) -> CatalogRow {
        CatalogRow(
            name: columnText(stmt, 0) ?? "",
            provider: columnText(stmt, 1) ?? "",
            kind: columnText(stmt, 2) ?? "runtime",
            notes: columnText(stmt, 3) ?? "",
            createdAt: columnText(stmt, 4) ?? "",
            lastUsedAt: columnText(stmt, 5),
            gatewayHost: columnText(stmt, 6),
            version: Int(sqlite3_column_int(stmt, 7))
        )
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            let message = String(cString: err)
            sqlite3_free(err)
            if rc != SQLITE_OK { throw AppError.sqlite(message) }
        } else if rc != SQLITE_OK {
            throw sqliteError()
        }
    }

    private func tableHasColumn(_ table: String, _ column: String) throws -> Bool {
        try one("SELECT 1 FROM pragma_table_info(?) WHERE name = ?;", table, column) { _ in true } ?? false
    }

    // MARK: statements

    /// Prepares, binds by position, steps until done and finalizes, all under the lock.
    /// `row` sees each result row; the return value is sqlite3_changes for a write.
    @discardableResult
    private func step(_ sql: String, _ args: [any SQLBindable], row: (OpaquePointer) throws -> Bool) throws -> Int {
        try withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw sqliteError() }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in args.enumerated() { arg.bind(stmt, Int32(i + 1)) }
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    if try !row(stmt) { return 0 }
                case SQLITE_DONE:
                    return Int(sqlite3_changes(db))
                default:
                    throw sqliteError()
                }
            }
        }
    }

    /// Runs a write; returns the number of rows it changed.
    @discardableResult
    private func run(_ sql: String, _ args: any SQLBindable...) throws -> Int {
        try step(sql, args) { _ in true }
    }

    private func query<T>(_ sql: String, _ args: [any SQLBindable], row: (OpaquePointer) throws -> T) throws -> [T] {
        var out: [T] = []
        try step(sql, args) { out.append(try row($0)); return true }
        return out
    }

    private func query<T>(_ sql: String, _ args: any SQLBindable..., row: (OpaquePointer) throws -> T) throws -> [T] {
        try query(sql, args, row: row)
    }

    /// The first result row, or nil when there is none.
    private func one<T>(_ sql: String, _ args: any SQLBindable..., row: (OpaquePointer) throws -> T) throws -> T? {
        var out: T?
        try step(sql, args) { out = try row($0); return false }
        return out
    }

    private func sqliteError() -> AppError {
        if let db, let msg = sqlite3_errmsg(db) {
            return .sqlite(String(cString: msg))
        }
        return .sqlite("unknown sqlite error")
    }

    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer, _ idx: Int32) -> Int? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, idx))
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer, _ idx: Int32) -> Double? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, idx)
    }
}

/// A value bound to a statement parameter. Integers bind as 64-bit.
fileprivate protocol SQLBindable {
    func bind(_ stmt: OpaquePointer, _ idx: Int32)
}

extension String: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) {
        sqlite3_bind_text(stmt, idx, self, -1, SQLITE_TRANSIENT)
    }
}

extension Int: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) { sqlite3_bind_int64(stmt, idx, Int64(self)) }
}

extension Int64: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) { sqlite3_bind_int64(stmt, idx, self) }
}

extension Double: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) { sqlite3_bind_double(stmt, idx, self) }
}

extension Bool: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) { sqlite3_bind_int64(stmt, idx, self ? 1 : 0) }
}

extension Optional: SQLBindable where Wrapped: SQLBindable {
    fileprivate func bind(_ stmt: OpaquePointer, _ idx: Int32) {
        if let self { self.bind(stmt, idx) } else { sqlite3_bind_null(stmt, idx) }
    }
}
