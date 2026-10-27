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
              duration_ms INTEGER,
              upstream_host TEXT,
              reason TEXT,
              PRIMARY KEY (source, session_id, prompt_id, model)
            );
            """)
        // Off for every key that existed before the setting did: turning it on changes where
        // a key's calls go, so only the user does that.
        if try !tableHasColumn("catalog", "gateway_cheapest") {
            try exec("ALTER TABLE catalog ADD COLUMN gateway_cheapest INTEGER NOT NULL DEFAULT 0;")
        }
        // Gateway calls used to keep their status in a separate gateway_usage table, which is
        // left in place for older binaries; a usage_events table from those versions lacks it.
        if try !tableHasColumn("usage_events", "http_status") {
            try exec("ALTER TABLE usage_events ADD COLUMN http_status INTEGER;")
        }
        // How long a gateway call took, where it went and why it ended (GatewayReason), for
        // `keys log`. Rows stored before these columns existed keep NULL: nobody knows.
        for (column, type) in [("duration_ms", "INTEGER"), ("upstream_host", "TEXT"), ("reason", "TEXT")] {
            if try !tableHasColumn("usage_events", column) {
                try exec("ALTER TABLE usage_events ADD COLUMN \(column) \(type);")
            }
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
              detail TEXT,
              http_status INTEGER
            );
            """)
        // The status the gateway answered a refused call with (gateway_denied), for `keys log`.
        if try !tableHasColumn("key_events", "http_status") {
            try exec("ALTER TABLE key_events ADD COLUMN http_status INTEGER;")
        }
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
              last_used_at TEXT,
              host TEXT
            );
            """)
        // A client is bound to the upstream host it was issued for. Clients from before the
        // column existed get the key's current host once, at the first start that knows the
        // provider table (KeysService), so they keep working only while the host stays put.
        if try !tableHasColumn("gateway_clients", "host") {
            try exec("ALTER TABLE gateway_clients ADD COLUMN host TEXT;")
            try exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('\(Self.clientHostBackfillKey)', 'pending');")
        }
        try exec("CREATE INDEX IF NOT EXISTS gateway_clients_key ON gateway_clients (key_name, id);")
        // Pairings hold hashes, not credentials, so like gateway_clients they belong in the
        // catalog and not the Keychain. `keys` is a comma-separated scope; empty means all keys.
        try exec("""
            CREATE TABLE IF NOT EXISTS relay_pairings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              label TEXT NOT NULL DEFAULT '',
              token_hash TEXT NOT NULL UNIQUE,
              hint TEXT NOT NULL DEFAULT '',
              keys TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              expires_at TEXT,
              revoked_at TEXT,
              last_used_at TEXT
            );
            """)
        // A permission profile is a saved bound on grant issuance: key names and scope
        // numbers only — no secret, no token, no hash — so the row is strictly less
        // sensitive than a gateway_clients row. Consulted only by issuance; the request
        // path never reads it, and purge empties it with everything else (wipeData walks
        // every table by name).
        try exec("""
            CREATE TABLE IF NOT EXISTS grant_profiles (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              key_names TEXT NOT NULL,
              methods TEXT NOT NULL,
              paths_json TEXT NOT NULL DEFAULT '[]',
              minutes INTEGER NOT NULL,
              max_requests INTEGER,
              max_usd REAL,
              unattended INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS custom_providers (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              host TEXT,
              api TEXT NOT NULL DEFAULT 'other',
              auth_header TEXT NOT NULL DEFAULT 'Authorization',
              auth_prefix TEXT NOT NULL DEFAULT 'Bearer ',
              path_prefix TEXT NOT NULL DEFAULT '',
              key_prefix TEXT,
              note TEXT,
              gateway INTEGER NOT NULL DEFAULT 1,
              created_at TEXT NOT NULL
            );
            """)
        // A user-set token limit for one window of a locally tracked row. The CHECKs hold the
        // shape the API already validates, so a row written another way cannot sneak past them.
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_limits (
              source TEXT NOT NULL,
              window TEXT NOT NULL CHECK (window IN ('five_hour', 'weekly', 'monthly')),
              tokens INTEGER NOT NULL CHECK (tokens > 0),
              PRIMARY KEY (source, window)
            );
            """)
        // A subscription the user pinned on the Usage pane: a plan name and an optional limit
        // for a tool Keysrs cannot measure locally (or Factory, whose usage is Droid's here).
        // The limit is one fact in three fields, and the CHECKs hold the all-or-nothing shape
        // the API already enforces.
        try exec("""
            CREATE TABLE IF NOT EXISTS subscriptions (
              id TEXT PRIMARY KEY,
              tool TEXT NOT NULL CHECK (tool IN ('cursor', 'gemini', 'copilot', 'perplexity', 'chatgpt', 'factory', 'custom')),
              name TEXT NOT NULL DEFAULT '',
              plan TEXT NOT NULL,
              limit_amount REAL,
              limit_unit TEXT CHECK (limit_unit IS NULL OR limit_unit IN ('tokens', 'requests', 'credits', 'usd')),
              limit_period TEXT CHECK (limit_period IS NULL OR limit_period IN ('five_hour', 'weekly', 'monthly')),
              created_at TEXT NOT NULL,
              CHECK ((limit_amount IS NULL) = (limit_unit IS NULL) AND (limit_amount IS NULL) = (limit_period IS NULL))
            );
            """)
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

    /// Meta rows whose key starts with `prefix` (a literal prefix, not a LIKE pattern).
    func metaRows(prefix: String) throws -> [(key: String, value: String)] {
        try query("SELECT key, value FROM meta WHERE substr(key, 1, ?) = ? ORDER BY key;", prefix.count, prefix) {
            (columnText($0, 0) ?? "", columnText($0, 1) ?? "")
        }
    }

    func deleteMeta(_ key: String) throws {
        try run("DELETE FROM meta WHERE key = ?;", key)
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("""
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, key, value)
    }

    // MARK: - Custom providers (user-added catalog entries)

    /// Built-in provider ids the user hid from the Add dialog, as a JSON array under meta.
    static let hiddenProvidersKey = "hidden_providers"

    func hiddenProviderIds() throws -> Set<String> {
        guard let raw = try metaValue(Self.hiddenProvidersKey),
              let ids = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String] else {
            return []
        }
        return Set(ids)
    }

    func setHiddenProviderIds(_ ids: Set<String>) throws {
        let sorted = ids.sorted()
        let data = try JSONSerialization.data(withJSONObject: sorted.isEmpty ? [] : sorted)
        try setMeta(Self.hiddenProvidersKey, String(decoding: data, as: UTF8.self))
    }

    func listCustomProviders() throws -> [Providers.Record] {
        try query(
            "SELECT id, name, host, api, auth_header, auth_prefix, path_prefix, key_prefix, note, gateway "
                + "FROM custom_providers ORDER BY created_at, id;"
        ) { stmt in
            Providers.Record(
                id: columnText(stmt, 0) ?? "",
                name: columnText(stmt, 1) ?? "",
                host: columnText(stmt, 2),
                api: columnText(stmt, 3) ?? "other",
                authHeader: columnText(stmt, 4) ?? "Authorization",
                authPrefix: columnText(stmt, 5) ?? "Bearer ",
                pathPrefix: columnText(stmt, 6) ?? "",
                gateway: sqlite3_column_int64(stmt, 9) != 0,
                group: "yours",
                keyPrefix: columnText(stmt, 7),
                note: columnText(stmt, 8),
                custom: true
            )
        }
    }

    func customProviderExists(id: String) throws -> Bool {
        try one("SELECT 1 FROM custom_providers WHERE id = ?;", id) { _ in true } ?? false
    }

    func insertCustomProvider(_ record: Providers.Record) throws {
        try withLock {
            do {
                try run(
                    """
                    INSERT INTO custom_providers
                      (id, name, host, api, auth_header, auth_prefix, path_prefix, key_prefix, note, gateway, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    record.id, record.name, record.host, record.api, record.authHeader, record.authPrefix,
                    record.pathPrefix, record.keyPrefix, record.note, record.gateway ? 1 : 0, UTC.iso(Date())
                )
            } catch where sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                throw AppError.alreadyExists(record.id)
            }
        }
    }

    /// True when the row existed; false means it was never there.
    @discardableResult
    func deleteCustomProvider(id: String) throws -> Bool {
        try withLock { try run("DELETE FROM custom_providers WHERE id = ?;", id) > 0 }
    }

    // MARK: usage limits

    struct UsageLimit: Equatable {
        var source: String
        var window: String
        var tokens: Int

        func jsonObject() -> [String: Any] {
            ["source": source, "window": window, "tokens": tokens]
        }
    }

    func usageLimits(source: String? = nil) throws -> [UsageLimit] {
        var sql = "SELECT source, window, tokens FROM usage_limits"
        var args: [any SQLBindable] = []
        if let source {
            sql += " WHERE source = ?"
            args.append(source)
        }
        sql += " ORDER BY source, window;"
        return try query(sql, args) {
            UsageLimit(
                source: columnText($0, 0) ?? "",
                window: columnText($0, 1) ?? "",
                tokens: Int(sqlite3_column_int64($0, 2))
            )
        }
    }

    /// Upsert: setting a limit again replaces it, so the row is always the one truth.
    func setUsageLimit(source: String, window: String, tokens: Int) throws {
        try withLock {
            try run("""
                INSERT INTO usage_limits (source, window, tokens)
                VALUES (?, ?, ?)
                ON CONFLICT(source, window) DO UPDATE SET tokens = excluded.tokens;
                """, source, window, tokens)
        }
    }

    /// True when a limit existed; clearing an already-clear window is fine either way.
    @discardableResult
    func clearUsageLimit(source: String, window: String) throws -> Bool {
        try withLock { try run("DELETE FROM usage_limits WHERE source = ? AND window = ?;", source, window) > 0 }
    }

    // MARK: subscriptions (plans the user pinned on the Usage pane)

    struct Subscription: Equatable {
        var id: String
        var tool: String
        var name: String
        var plan: String
        var limitAmount: Double?
        var limitUnit: String?
        var limitPeriod: String?
        var createdAt: String

        /// The three limit fields as one value, when the row has a limit at all.
        var limit: Subscriptions.LimitFields? {
            guard let limitAmount, let limitUnit, let limitPeriod else { return nil }
            return Subscriptions.LimitFields(amount: limitAmount, unit: limitUnit, period: limitPeriod)
        }

        func jsonObject() -> [String: Any] {
            [
                "id": id,
                "tool": tool,
                "name": name,
                "plan": plan,
                "limit_amount": limitAmount as Any? ?? NSNull(),
                "limit_unit": limitUnit as Any? ?? NSNull(),
                "limit_period": limitPeriod as Any? ?? NSNull(),
                "created_at": createdAt,
            ]
        }
    }

    private static let subscriptionColumns =
        "id, tool, name, plan, limit_amount, limit_unit, limit_period, created_at"

    private func decodeSubscription(_ stmt: OpaquePointer) -> Subscription {
        func double(_ idx: Int32) -> Double? { sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx) }
        return Subscription(
            id: columnText(stmt, 0) ?? "",
            tool: columnText(stmt, 1) ?? "",
            name: columnText(stmt, 2) ?? "",
            plan: columnText(stmt, 3) ?? "",
            limitAmount: double(4),
            limitUnit: columnText(stmt, 5),
            limitPeriod: columnText(stmt, 6),
            createdAt: columnText(stmt, 7) ?? ""
        )
    }

    func listSubscriptions() throws -> [Subscription] {
        try query(
            "SELECT \(Self.subscriptionColumns) FROM subscriptions ORDER BY created_at, id;",
            row: decodeSubscription
        )
    }

    func subscription(id: String) throws -> Subscription? {
        try one("SELECT \(Self.subscriptionColumns) FROM subscriptions WHERE id = ?;", id, row: decodeSubscription)
    }

    /// The one Factory subscription, if there is one; it attaches to the Droid row.
    func factorySubscription() throws -> Subscription? {
        try one(
            "SELECT \(Self.subscriptionColumns) FROM subscriptions WHERE tool = 'factory' ORDER BY created_at, id;",
            row: decodeSubscription
        )
    }

    func insertSubscription(_ row: Subscription) throws {
        try withLock {
            do {
                try run("""
                    INSERT INTO subscriptions
                      (id, tool, name, plan, limit_amount, limit_unit, limit_period, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    row.id, row.tool, row.name, row.plan, row.limitAmount, row.limitUnit, row.limitPeriod,
                    row.createdAt)
            } catch where sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                throw AppError.alreadyExists(row.id)
            }
        }
    }

    /// True when the row existed; the id and the tool never change, only the user's fields do.
    @discardableResult
    func updateSubscription(_ row: Subscription) throws -> Bool {
        try withLock {
            try run("""
                UPDATE subscriptions SET tool = ?, name = ?, plan = ?,
                  limit_amount = ?, limit_unit = ?, limit_period = ? WHERE id = ?;
                """, row.tool, row.name, row.plan, row.limitAmount, row.limitUnit, row.limitPeriod, row.id) > 0
        }
    }

    /// True when the row existed.
    @discardableResult
    func deleteSubscription(id: String) throws -> Bool {
        try withLock { try run("DELETE FROM subscriptions WHERE id = ?;", id) > 0 }
    }

    private static let catalogColumns = "name, provider, kind, notes, created_at, last_used_at, gateway_host, version, gateway_cheapest"

    func insertCatalog(_ row: CatalogRow) throws {
        try withLock {
            do {
                try run(
                    "INSERT INTO catalog (\(Self.catalogColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
                    row.name, row.provider, row.kind, row.notes, row.createdAt, row.lastUsedAt, row.gatewayHost,
                    row.version, row.gatewayCheapest ? 1 : 0
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
        host: String,
        createdAt: String,
        expiresAt: String
    ) throws -> GatewayClient {
        try withLock {
            try run("""
                INSERT INTO gateway_clients
                  (key_name, label, token_hash, hint, methods, path_prefix, created_at, expires_at, host)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, keyName, label, tokenHash, hint, methods.joined(separator: ","), pathPrefix, createdAt, expiresAt, host)
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
                hint: hint,
                host: host
            )
        }
    }

    static let clientHostBackfillKey = "gateway_clients_host_backfill"

    /// Clients with no stored host, i.e. issued before host binding existed.
    func unboundGatewayClients() throws -> [GatewayClient] {
        try query(
            "SELECT \(Self.gatewayClientColumns) FROM gateway_clients WHERE host IS NULL ORDER BY id;",
            row: decodeGatewayClient
        )
    }

    func bindGatewayClient(id: Int64, host: String) throws {
        try run("UPDATE gateway_clients SET host = ? WHERE id = ? AND host IS NULL;", host, id)
    }

    private static let gatewayClientColumns =
        "id, key_name, label, hint, methods, path_prefix, created_at, expires_at, revoked_at, last_used_at, host"

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
            hint: columnText(stmt, 3) ?? "",
            host: columnText(stmt, 10)
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

    // MARK: relay pairings

    func insertRelayPairing(
        label: String,
        tokenHash: String,
        hint: String,
        keys: [String],
        createdAt: String,
        expiresAt: String?
    ) throws -> RelayPairingRecord {
        try withLock {
            try run("""
                INSERT INTO relay_pairings (label, token_hash, hint, keys, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """, label, tokenHash, hint, keys.joined(separator: ","), createdAt, expiresAt)
            return RelayPairingRecord(
                id: sqlite3_last_insert_rowid(db),
                label: label,
                tokenHash: tokenHash,
                hint: hint,
                keys: keys,
                createdAt: createdAt,
                expiresAt: expiresAt,
                revokedAt: nil,
                lastUsedAt: nil
            )
        }
    }

    private static let relayPairingColumns =
        "id, label, token_hash, hint, keys, created_at, expires_at, revoked_at, last_used_at"

    private func decodeRelayPairing(_ stmt: OpaquePointer) -> RelayPairingRecord {
        RelayPairingRecord(
            id: sqlite3_column_int64(stmt, 0),
            label: columnText(stmt, 1) ?? "",
            tokenHash: columnText(stmt, 2) ?? "",
            hint: columnText(stmt, 3) ?? "",
            keys: (columnText(stmt, 4) ?? "").split(separator: ",").map(String.init),
            createdAt: columnText(stmt, 5) ?? "",
            expiresAt: columnText(stmt, 6),
            revokedAt: columnText(stmt, 7),
            lastUsedAt: columnText(stmt, 8)
        )
    }

    func relayPairings() throws -> [RelayPairingRecord] {
        try query("SELECT \(Self.relayPairingColumns) FROM relay_pairings ORDER BY id;", row: decodeRelayPairing)
    }

    func relayPairing(tokenHash: String) throws -> RelayPairingRecord? {
        try one(
            "SELECT \(Self.relayPairingColumns) FROM relay_pairings WHERE token_hash = ? LIMIT 1;", tokenHash,
            row: decodeRelayPairing
        )
    }

    /// Returns false when the pairing was already revoked. The row and its hash stay: a revoked
    /// credential must keep being recognisable as revoked.
    func revokeRelayPairing(id: Int64, at iso: String) throws -> Bool {
        try run("UPDATE relay_pairings SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL;", iso, id) > 0
    }

    func touchRelayPairing(id: Int64, at iso: String) throws {
        try run("UPDATE relay_pairings SET last_used_at = ? WHERE id = ?;", iso, id)
    }

    // MARK: grant profiles

    private static let profileColumns =
        "id, name, key_names, methods, paths_json, minutes, max_requests, max_usd, unattended, created_at, updated_at"

    /// Paths can hold characters a CSV join would corrupt (`GrantPath.normalize` allows
    /// commas), so they live as a JSON array; grant behavior must not change to make
    /// storage easier. Key names cannot contain commas (`KeyName.validate`), so those
    /// stay joined like `gateway_clients.methods`.
    private static func encodePaths(_ paths: [String]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: paths, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw AppError.sqlite("grant_profiles paths could not be encoded")
        }
        return json
    }

    /// A paths column that does not parse refuses the whole row: decoding it as empty
    /// would silently widen a profile to "any path", which is the one direction a bound
    /// must never go.
    private static func decodePaths(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let paths = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            throw AppError.sqlite("grant_profiles row has unreadable paths")
        }
        return paths
    }

    private func decodeProfile(_ stmt: OpaquePointer) throws -> Profile {
        Profile(
            id: columnText(stmt, 0) ?? "",
            name: columnText(stmt, 1) ?? "",
            keys: (columnText(stmt, 2) ?? "").split(separator: ",").map(String.init),
            methods: Set((columnText(stmt, 3) ?? "").split(separator: ",").map(String.init)),
            paths: try Self.decodePaths(columnText(stmt, 4) ?? "[]"),
            minutes: Int(sqlite3_column_int64(stmt, 5)),
            maxRequests: columnOptionalInt(stmt, 6),
            maxUsd: columnOptionalDouble(stmt, 7),
            unattended: sqlite3_column_int64(stmt, 8) != 0,
            createdAt: UTC.parse(columnText(stmt, 9) ?? "") ?? Date(timeIntervalSince1970: 0),
            updatedAt: UTC.parse(columnText(stmt, 10) ?? "") ?? Date(timeIntervalSince1970: 0)
        )
    }

    func insertProfile(_ profile: Profile) throws {
        try withLock { () -> Void in
            try run("""
                INSERT INTO grant_profiles
                  (id, name, key_names, methods, paths_json, minutes, max_requests, max_usd, unattended, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                profile.id, profile.name, profile.keys.joined(separator: ","),
                profile.methods.sorted().joined(separator: ","), try Self.encodePaths(profile.paths),
                profile.minutes, profile.maxRequests, profile.maxUsd, profile.unattended,
                UTC.iso(profile.createdAt), UTC.iso(profile.updatedAt))
        }
    }

    func profileExists(name: String) throws -> Bool {
        try one("SELECT 1 FROM grant_profiles WHERE name = ? LIMIT 1;", name) { _ in true } ?? false
    }

    func profile(name: String) throws -> Profile? {
        try one(
            "SELECT \(Self.profileColumns) FROM grant_profiles WHERE name = ? LIMIT 1;", name,
            row: decodeProfile
        )
    }

    /// The dashboard's rows know the id, and DELETE /api/profiles/<id> is the id form of the
    /// CLI's name-based remove.
    func profile(id: String) throws -> Profile? {
        try one(
            "SELECT \(Self.profileColumns) FROM grant_profiles WHERE id = ? LIMIT 1;", id,
            row: decodeProfile
        )
    }

    func listProfiles() throws -> [Profile] {
        try query("SELECT \(Self.profileColumns) FROM grant_profiles ORDER BY name;", row: decodeProfile)
    }

    /// Returns false when no profile had the id.
    func deleteProfile(id: String) throws -> Bool {
        try run("DELETE FROM grant_profiles WHERE id = ?;", id) > 0
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

    func updateGatewayCheapest(name: String, enabled: Bool) throws -> CatalogRow {
        try withLock {
            if try run("UPDATE catalog SET gateway_cheapest = ? WHERE name = ?;", enabled ? 1 : 0, name) == 0 {
                throw AppError.notFound(name)
            }
            guard let row = try catalogRow(name: name) else {
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
        ModelColor(model: columnText(stmt, 0) ?? "", slot: Int(sqlite3_column_int64(stmt, 1)))
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

    /// Whether a session has any row under `source` besides `promptId`; remote import asks it
    /// before storing a session total next to that session's per-request rows.
    func usageSessionHasRows(source: String, sessionId: String, excludingPromptId promptId: String) throws -> Bool {
        try one(
            "SELECT 1 FROM usage_events WHERE source = ? AND session_id = ? AND prompt_id != ? LIMIT 1;",
            source, sessionId, promptId
        ) { _ in true } ?? false
    }

    func deleteUsage(source: String, sessionId: String, promptId: String, model: String) throws {
        try withLock {
            _ = try run(
                "DELETE FROM usage_events WHERE source = ? AND session_id = ? AND prompt_id = ? AND model = ?;",
                source, sessionId, promptId, model
            )
        }
    }

    /// What a reader stores for a line that carried no time. A re-import of the same row must
    /// not push a row that has a real time back to it, where it would leave every window.
    private static let epochSentinel = "1970-01-01T00:00:00Z"

    enum Upsert { case inserted, updated, unchanged }

    /// `insertUsage` that tells a real change from a replay of identical values, so a re-import
    /// neither counts rows as updated nor bumps the catalog version for nothing. The epoch
    /// sentinel is compared the way the upsert applies it: it never replaces a real time.
    func upsertUsage(_ event: UsageEvent) throws -> Upsert {
        try withLock {
            let old = try one(
                "SELECT \(Self.usageColumns) FROM usage_events WHERE source = ? AND session_id = ? AND prompt_id = ? AND model = ?;",
                event.source, event.sessionId, event.promptId, event.model, row: event(from:)
            )
            guard let old else {
                try insertUsage(event)
                return .inserted
            }
            var merged = event
            if merged.occurredAt == Self.epochSentinel && old.occurredAt != Self.epochSentinel {
                merged.occurredAt = old.occurredAt
            }
            if merged == old { return .unchanged }
            try insertUsage(event)
            return .updated
        }
    }

    /// Every row under `source`.
    func usageRows(source: String) throws -> [UsageEvent] {
        try query("SELECT \(Self.usageColumns) FROM usage_events WHERE source = ?;", source, row: event(from:))
    }

    /// Every row a session has under `source`, for remote import's residual arithmetic.
    func usageRows(source: String, sessionId: String) throws -> [UsageEvent] {
        try query("SELECT \(Self.usageColumns) FROM usage_events WHERE source = ? AND session_id = ?;",
                  source, sessionId, row: event(from:))
    }

    /// The (prompt id, model) pairs among `promptIds` that `source` already holds, whatever the session.
    func usagePromptModels(source: String, promptIds: [String]) throws -> [(prompt: String, model: String)] {
        guard !promptIds.isEmpty else { return [] }
        let marks = promptIds.map { _ in "?" }.joined(separator: ", ")
        let args: [any SQLBindable] = [source] + promptIds
        return try query("SELECT prompt_id, model FROM usage_events WHERE source = ? AND prompt_id IN (\(marks));",
                         args) { (columnText($0, 0) ?? "", columnText($0, 1) ?? "") }
    }

    private static let usageColumns = """
        source, session_id, prompt_id, model, occurred_at, provider,
        cwd, session_title, model_calls,
        input_tokens, output_tokens, cached_read_tokens, cache_creation_tokens,
        reasoning_tokens, cost_usd_ticks, key_name, http_status,
        duration_ms, upstream_host, reason
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
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, session_id, prompt_id, model) DO UPDATE SET
                  occurred_at = CASE WHEN excluded.occurred_at = '\(Self.epochSentinel)'
                                      AND usage_events.occurred_at != '\(Self.epochSentinel)'
                                     THEN usage_events.occurred_at ELSE excluded.occurred_at END,
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
                  http_status = excluded.http_status,
                  duration_ms = excluded.duration_ms,
                  upstream_host = excluded.upstream_host,
                  reason = excluded.reason;
                """,
                event.source, event.sessionId, event.promptId, event.model, event.occurredAt, event.provider,
                event.cwd, event.sessionTitle, event.modelCalls,
                event.inputTokens, event.outputTokens, event.cachedReadTokens, event.cacheCreationTokens,
                event.reasoningTokens, event.costUsdTicks, event.keyName, event.httpStatus,
                event.durationMs, event.upstreamHost, event.reason
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
            inputTokens: Int(sqlite3_column_int64(stmt, 9)),
            outputTokens: Int(sqlite3_column_int64(stmt, 10)),
            cachedReadTokens: Int(sqlite3_column_int64(stmt, 11)),
            cacheCreationTokens: Int(sqlite3_column_int64(stmt, 12)),
            reasoningTokens: Int(sqlite3_column_int64(stmt, 13)),
            costUsdTicks: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 14),
            keyName: columnText(stmt, 15),
            httpStatus: columnOptionalInt(stmt, 16),
            durationMs: columnOptionalInt(stmt, 17),
            upstreamHost: columnText(stmt, 18),
            reason: columnText(stmt, 19)
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

    func insertKeyEvent(ts: String, name: String, action: String, caller: String?, detail: String?, httpStatus: Int? = nil) throws {
        try run(
            "INSERT INTO key_events (ts, name, action, caller, detail, http_status) VALUES (?, ?, ?, ?, ?, ?);",
            ts, name, action, caller, detail, httpStatus
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

    // MARK: gateway request log (keys log, keys doctor)

    /// The newest usage row and key event, so a followed log reads only what came after.
    func gatewayLogCursor() throws -> GatewayLogCursor {
        let call = try one("SELECT COALESCE(MAX(rowid), 0) FROM usage_events;") { sqlite3_column_int64($0, 0) } ?? 0
        let refusal = try one("SELECT COALESCE(MAX(id), 0) FROM key_events;") { sqlite3_column_int64($0, 0) } ?? 0
        return GatewayLogCursor(call: call, refusal: refusal)
    }

    /// The last `limit` entries written up to `cursor`, oldest first.
    func gatewayLog(
        through cursor: GatewayLogCursor, key: String? = nil, filter: GatewayLogFilter = .all, limit: Int
    ) throws -> [GatewayLogEntry] {
        try gatewayLogEntries(after: GatewayLogCursor(call: 0, refusal: 0), through: cursor, key: key,
                              filter: filter, newestLimit: limit).reversed()
    }

    /// Every entry written after `after` and up to `through`, oldest first.
    func gatewayLog(
        after: GatewayLogCursor, through: GatewayLogCursor, key: String? = nil, filter: GatewayLogFilter = .all
    ) throws -> [GatewayLogEntry] {
        try gatewayLogEntries(after: after, through: through, key: key, filter: filter, newestLimit: nil)
    }

    /// Forwarded calls are the gateway's usage rows; refusals are its `gateway_denied` audit
    /// entries, which name no host (nothing went upstream) and take the key's provider from the
    /// catalog. The path a call took is in its session id (`GatewayUsageRow.usageEvent`) or the
    /// event's caller. With `newestLimit` the newest entries come first.
    private func gatewayLogEntries(
        after: GatewayLogCursor, through: GatewayLogCursor, key: String?, filter: GatewayLogFilter, newestLimit: Int?
    ) throws -> [GatewayLogEntry] {
        // A followed log asks every second for the few rows after its cursor: `+source` keeps
        // SQLite on that rowid range instead of the primary key's walk over every gateway row.
        var callWhere = (after.call > 0 ? "+source" : "source") + " = 'gateway' AND rowid > ? AND rowid <= ?"
        var refusalWhere = "e.action = 'gateway_denied' AND e.id > ? AND e.id <= ?"
        var callArgs: [any SQLBindable] = [after.call, through.call]
        var refusalArgs: [any SQLBindable] = [after.refusal, through.refusal]
        if let key {
            callWhere += " AND key_name = ?"
            callArgs.append(key)
            refusalWhere += " AND e.name = ?"
            refusalArgs.append(key)
        }
        let gatewaySide = "(reason IS NOT NULL AND reason != '\(GatewayReason.upstreamStatus)')"
        switch filter {
        case .all: break
        case .failed: callWhere += " AND (http_status IS NULL OR http_status < 200 OR http_status > 299 OR \(gatewaySide))"
        case .gatewaySide:
            callWhere += " AND \(gatewaySide)"
            refusalWhere += " AND e.detail IN (" + GatewayLogFilter.gatewaySideRefusals.map { _ in "?" }.joined(separator: ", ") + ")"
            refusalArgs += GatewayLogFilter.gatewaySideRefusals.map { $0 as any SQLBindable }
        }
        let order = newestLimit == nil ? "ASC" : "DESC"
        var sql = """
            SELECT kind, ts, key_name, provider, host, status, duration_ms, reason, via FROM (
              SELECT 0 AS kind, rowid AS seq, occurred_at AS ts, key_name, provider, upstream_host AS host,
                     http_status AS status, duration_ms, reason,
                     CASE WHEN substr(session_id, 1, 9) = 'gw-relay:' THEN 'relay' ELSE 'loopback' END AS via
              FROM usage_events WHERE \(callWhere)
              UNION ALL
              SELECT 1, e.id, e.ts, e.name, c.provider, NULL, e.http_status, NULL, e.detail,
                     CASE WHEN e.caller = 'relay' THEN 'relay' ELSE 'loopback' END
              FROM key_events e LEFT JOIN catalog c ON c.name = e.name WHERE \(refusalWhere)
            )
            ORDER BY ts \(order), kind \(order), seq \(order)
            """
        var args = callArgs + refusalArgs
        if let newestLimit {
            sql += " LIMIT ?"
            args.append(newestLimit)
        }
        return try query(sql + ";", args) { stmt in
            GatewayLogEntry(
                kind: sqlite3_column_int64(stmt, 0) == 1 ? .refusal : .call,
                ts: columnText(stmt, 1) ?? "",
                key: columnText(stmt, 2) ?? "",
                provider: columnText(stmt, 3),
                host: columnText(stmt, 4),
                status: columnOptionalInt(stmt, 5),
                durationMs: columnOptionalInt(stmt, 6),
                reason: columnText(stmt, 7),
                via: columnText(stmt, 8) ?? "loopback"
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
            version: Int(sqlite3_column_int64(stmt, 7)),
            gatewayCheapest: sqlite3_column_int64(stmt, 8) != 0
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
        return Int(sqlite3_column_int64(stmt, idx))
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
