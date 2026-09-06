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
        try purgeLegacyTailSignatures()
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
              last_used_at TEXT
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
              agent_name TEXT,
              stop_reason TEXT,
              model_calls INTEGER,
              api_duration_ms INTEGER,
              input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cached_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              reasoning_tokens INTEGER NOT NULL DEFAULT 0,
              cost_usd_ticks INTEGER,
              PRIMARY KEY (source, session_id, prompt_id, model)
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS usage_events_occurred ON usage_events (occurred_at);")
        try exec("CREATE INDEX IF NOT EXISTS usage_events_model ON usage_events (model);")
        try exec("""
            CREATE TABLE IF NOT EXISTS ingest_files (
              path TEXT PRIMARY KEY,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              byte_offset INTEGER NOT NULL
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
        try exec("DELETE FROM usage_events WHERE model = '<synthetic>';")
        let removedSynthetic = sqlite3_changes(db)
        try exec("DELETE FROM usage_events WHERE model = 'unknown' AND source = 'codex-local';")
        let removed = removedSynthetic + sqlite3_changes(db)
        if removed > 0 {
            try exec("DELETE FROM ingest_files WHERE path LIKE '%/rollout-%';")
            try exec(
                "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'catalog_version';"
            )
        }
        if !(try hasColumn("catalog", "gateway_enabled")) {
            try exec("ALTER TABLE catalog ADD COLUMN gateway_enabled INTEGER NOT NULL DEFAULT 0;")
        }
        if !(try hasColumn("catalog", "gateway_host")) {
            try exec("ALTER TABLE catalog ADD COLUMN gateway_host TEXT;")
        }
        if !(try hasColumn("usage_events", "key_name")) {
            try exec("ALTER TABLE usage_events ADD COLUMN key_name TEXT;")
        }
        try exec("CREATE INDEX IF NOT EXISTS usage_events_key ON usage_events (key_name);")
        try exec("""
            CREATE TABLE IF NOT EXISTS gateway_usage (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              key TEXT NOT NULL,
              provider TEXT NOT NULL,
              model TEXT,
              input_tokens INTEGER,
              output_tokens INTEGER,
              cache_read_tokens INTEGER,
              cache_write_tokens INTEGER,
              status INTEGER,
              duration_ms INTEGER
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS gateway_usage_key_ts ON gateway_usage (key, ts);")
        if !(try hasColumn("gateway_usage", "request_id")) {
            try exec("ALTER TABLE gateway_usage ADD COLUMN request_id TEXT;")
        }
        try exec("UPDATE catalog SET gateway_enabled = 0;")
        if !(try hasColumn("catalog", "version")) {
            try exec("ALTER TABLE catalog ADD COLUMN version INTEGER NOT NULL DEFAULT 1;")
        }
        try rebuildUsagePrimaryKeyIfNeeded()
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
        if !(try hasColumn("ingest_files", "tail_sig")) {
            try exec("ALTER TABLE ingest_files ADD COLUMN tail_sig TEXT;")
        }
        if !(try hasColumn("ingest_files", "parser_json")) {
            try exec("ALTER TABLE ingest_files ADD COLUMN parser_json TEXT;")
        }
    }

    /// Cursor rows written before 0.2 held the last 32 raw bytes of each log as hex, which could
    /// include a fragment of a user message. Clear them, then checkpoint and vacuum so neither
    /// the main file nor the WAL keeps the old page images. Scope: this catalog file only.
    /// Copies made by Time Machine or by hand are outside what the app can reach.
    private func purgeLegacyTailSignatures() throws {
        // The marker is written only after the vacuum succeeded, so a busy database on one open
        // (another process mid-ingest) means the whole step runs again next time rather than the
        // freed pages being left behind. Nothing here may fail `init`.
        if try metaValue("tail_sig_format") == "v2" { return }
        try exec(
            "UPDATE ingest_files SET tail_sig = NULL WHERE tail_sig IS NOT NULL AND tail_sig != '' AND tail_sig NOT LIKE 'v2:%';"
        )
        let cleared = sqlite3_changes(db)
        if cleared > 0 {
            let previous = Int(try metaValue("tail_sig_purged_rows") ?? "0") ?? 0
            try setMeta("tail_sig_purged_rows", String(previous + Int(cleared)))
        }
        do {
            try exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try exec("VACUUM")
        } catch {
            return
        }
        try setMeta("tail_sig_format", "v2")
    }

    private func rebuildUsagePrimaryKeyIfNeeded() throws {
        if try tableSQL("usage_events") == nil, try tableSQL("usage_events_v3") != nil {
            try exec("ALTER TABLE usage_events_v3 RENAME TO usage_events;")
        }
        guard let sql = try tableSQL("usage_events") else { return }
        let compact = sql.replacingOccurrences(of: " ", with: "")
        // Session 3 briefly used PK without model; restore model so Grok
        // two-model turns stay two rows. Claude still last-wins on request id.
        let hasModel = compact.contains("prompt_id,model") || compact.contains("PRIMARYKEY(source,session_id,prompt_id,model)")
        if hasModel {
            if try metaValue("usage_pk") != "v3" {
                try setMeta("usage_pk", "v3")
            }
            return
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("""
                CREATE TABLE usage_events_v3 (
                  source TEXT NOT NULL,
                  session_id TEXT NOT NULL,
                  prompt_id TEXT NOT NULL,
                  model TEXT NOT NULL,
                  occurred_at TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  cwd TEXT,
                  session_title TEXT,
                  agent_name TEXT,
                  stop_reason TEXT,
                  model_calls INTEGER,
                  api_duration_ms INTEGER,
                  input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  cached_read_tokens INTEGER NOT NULL DEFAULT 0,
                  cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                  cost_usd_ticks INTEGER,
                  key_name TEXT,
                  PRIMARY KEY (source, session_id, prompt_id, model)
                );
                """)
            try exec("""
                INSERT OR IGNORE INTO usage_events_v3 (
                  source, session_id, prompt_id, model, occurred_at, provider,
                  cwd, session_title, agent_name, stop_reason, model_calls, api_duration_ms,
                  input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
                  reasoning_tokens, cost_usd_ticks, key_name
                )
                SELECT
                  source, session_id, prompt_id, model, occurred_at, provider,
                  cwd, session_title, agent_name, stop_reason, model_calls, api_duration_ms,
                  input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
                  reasoning_tokens, cost_usd_ticks, key_name
                FROM usage_events
                ORDER BY occurred_at DESC;
                """)
            try exec("DROP TABLE usage_events;")
            try exec("ALTER TABLE usage_events_v3 RENAME TO usage_events;")
            try exec("CREATE INDEX IF NOT EXISTS usage_events_occurred ON usage_events (occurred_at);")
            try exec("CREATE INDEX IF NOT EXISTS usage_events_model ON usage_events (model);")
            try exec("CREATE INDEX IF NOT EXISTS usage_events_key ON usage_events (key_name);")
            try exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('usage_pk', 'v3');")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func tableSQL(_ name: String) throws -> String? {
        let stmt = try prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    struct IngestFileCursor: Equatable {
        var size: Int64
        var mtimeMs: Int64
        var byteOffset: Int64
        var tailSig: String? = nil
        var parserJSON: String? = nil
    }

    func ingestFile(path: String) throws -> IngestFileCursor? {
        try withLock {
            let stmt = try prepare(
                "SELECT size, mtime, byte_offset, tail_sig, parser_json FROM ingest_files WHERE path = ?;"
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return IngestFileCursor(
                size: sqlite3_column_int64(stmt, 0),
                mtimeMs: sqlite3_column_int64(stmt, 1),
                byteOffset: sqlite3_column_int64(stmt, 2),
                tailSig: columnText(stmt, 3),
                parserJSON: columnText(stmt, 4)
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
        try withLock {
            let sql = """
                INSERT INTO ingest_files (path, size, mtime, byte_offset, tail_sig, parser_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                  size = excluded.size,
                  mtime = excluded.mtime,
                  byte_offset = excluded.byte_offset,
                  tail_sig = excluded.tail_sig,
                  parser_json = excluded.parser_json;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            sqlite3_bind_int64(stmt, 2, size)
            sqlite3_bind_int64(stmt, 3, mtimeMs)
            sqlite3_bind_int64(stmt, 4, byteOffset)
            bindText(stmt, 5, tailSig)
            bindText(stmt, 6, parserJSON)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
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

    func withTransaction(_ body: () throws -> Void) throws {
        try withLock {
            if inTransaction {
                try body()
                return
            }
            try exec("BEGIN IMMEDIATE")
            inTransaction = true
            do {
                try body()
                try exec("COMMIT")
                inTransaction = false
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

    func deleteSyntheticModels() throws -> Int {
        try withLock {
            try exec("DELETE FROM usage_events WHERE model = '<synthetic>';")
            let n = Int(sqlite3_changes(db))
            if n > 0 {
                try exec(
                    "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'catalog_version';"
                )
            }
            return n
        }
    }

    func metaValue(_ key: String) throws -> String? {
        try withLock {
            let stmt = try prepare("SELECT value FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnText(stmt, 0)
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try withLock {
            let sql = """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func clearMeta(_ key: String) throws {
        try withLock {
            let stmt = try prepare("DELETE FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func insertCatalog(_ row: CatalogRow) throws {
        try withLock {
            let sql = """
                INSERT INTO catalog (
                  name, provider, kind, notes, created_at, last_used_at, gateway_enabled, gateway_host, version
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, row.name)
            bindText(stmt, 2, row.provider)
            bindText(stmt, 3, row.kind)
            bindText(stmt, 4, row.notes)
            bindText(stmt, 5, row.createdAt)
            bindText(stmt, 6, row.lastUsedAt)
            sqlite3_bind_int(stmt, 7, row.gatewayEnabled ? 1 : 0)
            bindText(stmt, 8, row.gatewayHost)
            sqlite3_bind_int(stmt, 9, Int32(row.version))
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_CONSTRAINT {
                throw AppError.alreadyExists(row.name)
            }
            guard rc == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func deleteCatalog(name: String) throws {
        try withLock {
            let stmt = try prepare("DELETE FROM catalog WHERE name = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if sqlite3_changes(db) == 0 {
                throw AppError.notFound(name)
            }
            // A capability for a key that no longer exists must not outlive it.
            let clients = try prepare("DELETE FROM gateway_clients WHERE key_name = ?;")
            defer { sqlite3_finalize(clients) }
            bindText(clients, 1, name)
            guard sqlite3_step(clients) == SQLITE_DONE else { throw sqliteError() }
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
            let stmt = try prepare("""
                INSERT INTO gateway_clients
                  (key_name, label, token_hash, hint, methods, path_prefix, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, keyName)
            bindText(stmt, 2, label)
            bindText(stmt, 3, tokenHash)
            bindText(stmt, 4, hint)
            bindText(stmt, 5, methods.joined(separator: ","))
            bindText(stmt, 6, pathPrefix)
            bindText(stmt, 7, createdAt)
            bindText(stmt, 8, expiresAt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
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
        try withLock {
            let stmt = try prepare(
                "SELECT \(Self.gatewayClientColumns) FROM gateway_clients WHERE key_name = ? ORDER BY id;"
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, keyName)
            var out: [GatewayClient] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(decodeGatewayClient(stmt)) }
            return out
        }
    }

    func gatewayClient(tokenHash: String) throws -> GatewayClient? {
        try withLock {
            let stmt = try prepare(
                "SELECT \(Self.gatewayClientColumns) FROM gateway_clients WHERE token_hash = ? LIMIT 1;"
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, tokenHash)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeGatewayClient(stmt)
        }
    }

    /// Returns false when no such client belongs to the key or it was already revoked.
    func revokeGatewayClient(id: Int64, keyName: String, at iso: String) throws -> Bool {
        try withLock {
            let stmt = try prepare(
                "UPDATE gateway_clients SET revoked_at = ? WHERE id = ? AND key_name = ? AND revoked_at IS NULL;"
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, iso)
            sqlite3_bind_int64(stmt, 2, id)
            bindText(stmt, 3, keyName)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            return sqlite3_changes(db) > 0
        }
    }

    func touchGatewayClient(id: Int64, at iso: String) throws {
        try withLock {
            let stmt = try prepare("UPDATE gateway_clients SET last_used_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, iso)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func catalogExists(name: String) throws -> Bool {
        try withLock {
            let stmt = try prepare("SELECT 1 FROM catalog WHERE name = ? LIMIT 1;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func catalogRow(name: String) throws -> CatalogRow? {
        try withLock {
            let stmt = try prepare(
                """
                SELECT name, provider, kind, notes, created_at, last_used_at, gateway_enabled, gateway_host, version
                FROM catalog WHERE name = ?;
                """
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeCatalog(stmt)
        }
    }

    func updateCatalog(name: String, provider: String?, kind: String?, notes: String?) throws -> CatalogRow {
        try withLock {
            guard var row = try catalogRow(name: name) else {
                throw AppError.notFound(name)
            }
            if let provider { row.provider = provider }
            if let kind { row.kind = kind }
            if let notes { row.notes = notes }
            let sql = """
                UPDATE catalog SET provider = ?, kind = ?, notes = ?
                WHERE name = ?;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, row.provider)
            bindText(stmt, 2, row.kind)
            bindText(stmt, 3, row.notes)
            bindText(stmt, 4, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if sqlite3_changes(db) == 0 {
                throw AppError.notFound(name)
            }
            return row
        }
    }

    func updateGateway(name: String, enabled: Bool, host: String?) throws -> CatalogRow {
        try withLock {
            guard try catalogRow(name: name) != nil else {
                throw AppError.notFound(name)
            }
            let sql = """
                UPDATE catalog SET gateway_enabled = ?, gateway_host = ?
                WHERE name = ?;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            bindText(stmt, 2, host)
            bindText(stmt, 3, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if sqlite3_changes(db) == 0 {
                throw AppError.notFound(name)
            }
            guard let row = try catalogRow(name: name) else {
                throw AppError.notFound(name)
            }
            return row
        }
    }

    func updateGatewayEnabled(name: String, enabled: Bool) throws -> CatalogRow {
        try withLock {
            let sql = "UPDATE catalog SET gateway_enabled = ? WHERE name = ?;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            bindText(stmt, 2, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if sqlite3_changes(db) == 0 {
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
            let existing = try prepare("SELECT model, slot FROM model_colors;")
            defer { sqlite3_finalize(existing) }
            while sqlite3_step(existing) == SQLITE_ROW {
                let model = columnText(existing, 0) ?? ""
                known.insert(model)
                occupied.insert(Int(sqlite3_column_int(existing, 1)))
            }
            var assignedCount = known.count
            let pending = try prepare(
                """
                SELECT model FROM usage_events
                GROUP BY model
                ORDER BY MIN(occurred_at), model;
                """
            )
            defer { sqlite3_finalize(pending) }
            let insert = try prepare(
                "INSERT OR IGNORE INTO model_colors (model, slot) VALUES (?, ?);"
            )
            defer { sqlite3_finalize(insert) }
            while sqlite3_step(pending) == SQLITE_ROW {
                let model = columnText(pending, 0) ?? ""
                if model.isEmpty || known.contains(model) { continue }
                let slot: Int
                if let free = (0..<24).first(where: { !occupied.contains($0) }) {
                    slot = free
                    occupied.insert(slot)
                } else {
                    slot = assignedCount % 24
                }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bindText(insert, 1, model)
                sqlite3_bind_int(insert, 2, Int32(slot))
                guard sqlite3_step(insert) == SQLITE_DONE else { throw sqliteError() }
                known.insert(model)
                assignedCount += 1
            }
        }
    }

    func listModelColors() throws -> [ModelColor] {
        try withLock {
            let sql = """
                SELECT c.model, c.slot
                FROM model_colors c
                INNER JOIN (SELECT DISTINCT model FROM usage_events) u ON u.model = c.model
                ORDER BY c.slot, c.model;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var rows: [ModelColor] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    ModelColor(
                        model: columnText(stmt, 0) ?? "",
                        slot: Int(sqlite3_column_int(stmt, 1))
                    )
                )
            }
            return rows
        }
    }

    func listCatalog() throws -> [CatalogRow] {
        try withLock {
            let stmt = try prepare(
                """
                SELECT name, provider, kind, notes, created_at, last_used_at, gateway_enabled, gateway_host, version
                FROM catalog ORDER BY name;
                """
            )
            defer { sqlite3_finalize(stmt) }
            var rows: [CatalogRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(decodeCatalog(stmt))
            }
            return rows
        }
    }

    func touchLastUsed(name: String, at iso: String) throws {
        try withLock {
            let stmt = try prepare("UPDATE catalog SET last_used_at = ? WHERE name = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, iso)
            bindText(stmt, 2, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    enum InsertResult {
        case inserted
        case updated
        case duplicate
    }

    @discardableResult
    func usageExists(source: String, sessionId: String, promptId: String, model: String) throws -> Bool {
        try withLock {
            let stmt = try prepare(
                "SELECT 1 FROM usage_events WHERE source = ? AND session_id = ? AND prompt_id = ? AND model = ? LIMIT 1;"
            )
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source)
            bindText(stmt, 2, sessionId)
            bindText(stmt, 3, promptId)
            bindText(stmt, 4, model)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func insertUsage(_ event: UsageEvent) throws -> InsertResult {
        try withLock {
            let existedStmt = try prepare(
                """
                SELECT 1 FROM usage_events
                WHERE source = ? AND session_id = ? AND prompt_id = ? AND model = ?
                LIMIT 1;
                """
            )
            defer { sqlite3_finalize(existedStmt) }
            bindText(existedStmt, 1, event.source)
            bindText(existedStmt, 2, event.sessionId)
            bindText(existedStmt, 3, event.promptId)
            bindText(existedStmt, 4, event.model)
            let existed = sqlite3_step(existedStmt) == SQLITE_ROW
            let sql = """
                INSERT INTO usage_events (
                  source, session_id, prompt_id, model, occurred_at, provider,
                  cwd, session_title, agent_name, stop_reason, model_calls, api_duration_ms,
                  input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
                  reasoning_tokens, cost_usd_ticks, key_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, session_id, prompt_id, model) DO UPDATE SET
                  occurred_at = excluded.occurred_at,
                  provider = excluded.provider,
                  cwd = excluded.cwd,
                  session_title = excluded.session_title,
                  agent_name = excluded.agent_name,
                  stop_reason = excluded.stop_reason,
                  model_calls = excluded.model_calls,
                  api_duration_ms = excluded.api_duration_ms,
                  input_tokens = excluded.input_tokens,
                  output_tokens = excluded.output_tokens,
                  cached_read_tokens = excluded.cached_read_tokens,
                  cache_creation_tokens = excluded.cache_creation_tokens,
                  reasoning_tokens = excluded.reasoning_tokens,
                  cost_usd_ticks = excluded.cost_usd_ticks,
                  key_name = excluded.key_name;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, event.source)
            bindText(stmt, 2, event.sessionId)
            bindText(stmt, 3, event.promptId)
            bindText(stmt, 4, event.model)
            bindText(stmt, 5, event.occurredAt)
            bindText(stmt, 6, event.provider)
            bindText(stmt, 7, event.cwd)
            bindText(stmt, 8, event.sessionTitle)
            bindText(stmt, 9, event.agentName)
            bindText(stmt, 10, event.stopReason)
            bindInt(stmt, 11, event.modelCalls)
            bindInt(stmt, 12, event.apiDurationMs)
            sqlite3_bind_int(stmt, 13, Int32(event.inputTokens))
            sqlite3_bind_int(stmt, 14, Int32(event.outputTokens))
            sqlite3_bind_int(stmt, 15, Int32(event.cachedReadTokens))
            sqlite3_bind_int(stmt, 16, Int32(event.cacheCreationTokens))
            sqlite3_bind_int(stmt, 17, Int32(event.reasoningTokens))
            if let ticks = event.costUsdTicks {
                sqlite3_bind_int64(stmt, 18, ticks)
            } else {
                sqlite3_bind_null(stmt, 18)
            }
            bindText(stmt, 19, event.keyName)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if existed { return .updated }
            return sqlite3_changes(db) == 1 ? .inserted : .duplicate
        }
    }

    func usageEvents(
        from startISO: String,
        to endISO: String,
        source: SourceFilter,
        key: String? = nil
    ) throws -> [UsageEvent] {
        try withLock {
            var sql = """
                SELECT source, session_id, prompt_id, model, occurred_at, provider,
                       cwd, session_title, agent_name, stop_reason, model_calls, api_duration_ms,
                       input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
                       reasoning_tokens, cost_usd_ticks, key_name
                FROM usage_events
                WHERE occurred_at >= ? AND occurred_at < ?
                """
            if let values = source.sqlValues, !values.isEmpty {
                sql += " AND source IN (" + values.map { _ in "?" }.joined(separator: ", ") + ")"
            }
            if key != nil {
                sql += " AND key_name = ?"
            }
            sql += " ORDER BY occurred_at, model;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, startISO)
            bindText(stmt, 2, endISO)
            var idx: Int32 = 3
            if let values = source.sqlValues {
                for src in values {
                    bindText(stmt, idx, src)
                    idx += 1
                }
            }
            if let key {
                bindText(stmt, idx, key)
            }
            var events: [UsageEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(event(from: stmt))
            }
            return events
        }
    }

    func allUsageEvents() throws -> [UsageEvent] {
        try withLock {
            let sql = """
                SELECT source, session_id, prompt_id, model, occurred_at, provider,
                       cwd, session_title, agent_name, stop_reason, model_calls, api_duration_ms,
                       input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
                       reasoning_tokens, cost_usd_ticks, key_name
                FROM usage_events
                ORDER BY occurred_at, model;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var events: [UsageEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(event(from: stmt))
            }
            return events
        }
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
            agentName: columnText(stmt, 8),
            stopReason: columnText(stmt, 9),
            modelCalls: columnOptionalInt(stmt, 10),
            apiDurationMs: columnOptionalInt(stmt, 11),
            inputTokens: Int(sqlite3_column_int(stmt, 12)),
            outputTokens: Int(sqlite3_column_int(stmt, 13)),
            cachedReadTokens: Int(sqlite3_column_int(stmt, 14)),
            cacheCreationTokens: Int(sqlite3_column_int(stmt, 15)),
            reasoningTokens: Int(sqlite3_column_int(stmt, 16)),
            costUsdTicks: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 17),
            keyName: columnText(stmt, 18)
        )
    }

    func insertGatewayUsage(_ row: GatewayUsageRow) throws {
        try withLock {
            let sql = """
                INSERT INTO gateway_usage (
                  ts, key, provider, model, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, status, duration_ms, request_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, row.ts)
            bindText(stmt, 2, row.key)
            bindText(stmt, 3, row.provider)
            bindText(stmt, 4, row.model)
            bindInt(stmt, 5, row.inputTokens)
            bindInt(stmt, 6, row.outputTokens)
            bindInt(stmt, 7, row.cacheReadTokens)
            bindInt(stmt, 8, row.cacheWriteTokens)
            sqlite3_bind_int(stmt, 9, Int32(row.status))
            sqlite3_bind_int(stmt, 10, Int32(row.durationMs))
            bindText(stmt, 11, row.requestId)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func gatewayUsage(from startISO: String, to endISO: String, key: String? = nil) throws -> [GatewayUsageRow] {
        try withLock {
            var sql = """
                SELECT id, ts, key, provider, model, input_tokens, output_tokens,
                       cache_read_tokens, cache_write_tokens, status, duration_ms, request_id
                FROM gateway_usage
                WHERE ts >= ? AND ts < ?
                """
            if key != nil { sql += " AND key = ?" }
            sql += " ORDER BY ts;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, startISO)
            bindText(stmt, 2, endISO)
            if let key { bindText(stmt, 3, key) }
            var rows: [GatewayUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    GatewayUsageRow(
                        id: sqlite3_column_int64(stmt, 0),
                        ts: columnText(stmt, 1) ?? "",
                        key: columnText(stmt, 2) ?? "",
                        provider: columnText(stmt, 3) ?? "",
                        model: columnText(stmt, 4),
                        inputTokens: columnOptionalInt(stmt, 5),
                        outputTokens: columnOptionalInt(stmt, 6),
                        cacheReadTokens: columnOptionalInt(stmt, 7),
                        cacheWriteTokens: columnOptionalInt(stmt, 8),
                        status: Int(sqlite3_column_int(stmt, 9)),
                        durationMs: Int(sqlite3_column_int(stmt, 10)),
                        requestId: columnText(stmt, 11)
                    )
                )
            }
            return rows
        }
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
        try withLock {
            let sql = """
                INSERT INTO key_events (ts, name, action, caller, detail)
                VALUES (?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, ts)
            bindText(stmt, 2, name)
            bindText(stmt, 3, action)
            bindText(stmt, 4, caller)
            bindText(stmt, 5, detail)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func keyEvents(name: String, limit: Int) throws -> [KeyEventRow] {
        try withLock {
            let sql = """
                SELECT id, ts, name, action, caller, detail
                FROM key_events
                WHERE name = ?
                ORDER BY ts DESC, id DESC
                LIMIT ?;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [KeyEventRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    KeyEventRow(
                        id: sqlite3_column_int64(stmt, 0),
                        ts: columnText(stmt, 1) ?? "",
                        name: columnText(stmt, 2) ?? "",
                        action: columnText(stmt, 3) ?? "",
                        caller: columnText(stmt, 4),
                        detail: columnText(stmt, 5)
                    )
                )
            }
            return rows
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
        try withLock {
            let sql = """
                INSERT INTO provider_snapshots (
                  provider, key_name, ts, usage_daily, usage_weekly, usage_monthly,
                  "limit", limit_remaining, raw_kind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, row.provider)
            bindText(stmt, 2, row.keyName)
            bindText(stmt, 3, row.ts)
            bindDouble(stmt, 4, row.usageDaily)
            bindDouble(stmt, 5, row.usageWeekly)
            bindDouble(stmt, 6, row.usageMonthly)
            bindDouble(stmt, 7, row.limit)
            bindDouble(stmt, 8, row.limitRemaining)
            bindText(stmt, 9, row.rawKind)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func latestProviderSnapshot(provider: String) throws -> ProviderSnapshot? {
        try withLock {
            let sql = """
                SELECT provider, key_name, ts, usage_daily, usage_weekly, usage_monthly,
                       "limit", limit_remaining, raw_kind
                FROM provider_snapshots
                WHERE provider = ?
                ORDER BY ts DESC
                LIMIT 1;
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, provider)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return ProviderSnapshot(
                provider: columnText(stmt, 0) ?? "",
                keyName: columnText(stmt, 1) ?? "",
                ts: columnText(stmt, 2) ?? "",
                usageDaily: columnOptionalDouble(stmt, 3),
                usageWeekly: columnOptionalDouble(stmt, 4),
                usageMonthly: columnOptionalDouble(stmt, 5),
                limit: columnOptionalDouble(stmt, 6),
                limitRemaining: columnOptionalDouble(stmt, 7),
                rawKind: columnText(stmt, 8)
            )
        }
    }

    func incrementVersion(name: String) throws -> Int {
        try withLock {
            let stmt = try prepare("UPDATE catalog SET version = version + 1 WHERE name = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, name)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            if sqlite3_changes(db) == 0 { throw AppError.notFound(name) }
            guard let row = try catalogRow(name: name) else { throw AppError.notFound(name) }
            return row.version
        }
    }

    func deleteUsage(source: String) throws -> Int {
        try withLock {
            let stmt = try prepare("DELETE FROM usage_events WHERE source = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(db))
        }
    }

    func deleteIngestFiles(pathLike: String) throws {
        try withLock {
            let stmt = try prepare("DELETE FROM ingest_files WHERE path LIKE ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, pathLike)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func newestUsage(source: String) throws -> String? {
        try withLock {
            let stmt = try prepare("SELECT MAX(occurred_at) FROM usage_events WHERE source = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnText(stmt, 0)
        }
    }

    func wipeData() throws {
        try withLock {
            try exec("DELETE FROM catalog;")
            try exec("DELETE FROM usage_events;")
            try exec("DELETE FROM ingest_files;")
            try exec("DELETE FROM gateway_usage;")
            try exec("DELETE FROM gateway_clients;")
            try exec("DELETE FROM key_events;")
            try exec("DELETE FROM provider_snapshots;")
            try exec("DELETE FROM model_colors;")
            try exec("UPDATE meta SET value = '0' WHERE key = 'catalog_version';")
            try exec("DELETE FROM meta WHERE key = 'last_ingest_at';")
            try exec("DELETE FROM meta WHERE key = 'claude_dedup';")
            try exec("DELETE FROM meta WHERE key = 'gateway_owner_pid';")
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
            gatewayEnabled: sqlite3_column_int(stmt, 6) != 0,
            gatewayHost: columnText(stmt, 7),
            version: Int(sqlite3_column_int(stmt, 8))
        )
    }

    private func hasColumn(_ table: String, _ name: String) throws -> Bool {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == name { return true }
        }
        return false
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

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteError() }
        return stmt
    }

    private func sqliteError() -> AppError {
        if let db, let msg = sqlite3_errmsg(db) {
            return .sqlite(String(cString: msg))
        }
        return .sqlite("unknown sqlite error")
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, idx, Int32(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ idx: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
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
