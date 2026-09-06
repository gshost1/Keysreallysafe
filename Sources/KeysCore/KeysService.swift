import Darwin
import Foundation

final class KeysService: @unchecked Sendable {
    let catalog: CatalogDB
    let secrets: any SecretStore
    let clipboard: any ClipboardClient
    let runner: any CommandRunner
    var grokHome: URL
    var claudeHome: URL
    var codexHome: URL
    /// Serialises ingest passes only. A five-minute log scan must never hold up a gateway lookup.
    private let ingestLock = NSLock()
    /// Guards `gatewayCache` and `gatewayListener`; held for dictionary access only.
    private let gatewayLock = NSLock()
    private var gatewayCache: [String: GatewayTarget] = [:]
    private var gatewayListener: GatewayListener?
    var openRouter: any OpenRouterFetching

    init(
        catalog: CatalogDB,
        secrets: any SecretStore,
        clipboard: any ClipboardClient,
        grokHome: URL = Paths.grokHome,
        claudeHome: URL = Paths.claudeHome,
        codexHome: URL = Paths.codexHome,
        runner: any CommandRunner = FoundationCommandRunner(),
        openRouter: any OpenRouterFetching = OpenRouterHTTP()
    ) {
        self.catalog = catalog
        self.secrets = secrets
        self.clipboard = clipboard
        self.grokHome = grokHome
        self.claudeHome = claudeHome
        self.codexHome = codexHome
        self.runner = runner
        self.openRouter = openRouter
        ModelPrices.loadAtStartup()
        Providers.loadAtStartup()
    }

    func add(
        name: String,
        provider: String,
        kind: String,
        notes: String,
        secret: String,
        caller: String = "dashboard"
    ) throws {
        try KeyName.validate(name)
        try KeyKind.validate(kind)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else { throw AppError.usage("provider is required") }
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        if try catalog.catalogExists(name: name) {
            throw AppError.alreadyExists(name)
        }
        try secrets.add(name: name, secret: secret)
        let row = CatalogRow(
            name: name,
            provider: trimmedProvider,
            kind: kind,
            notes: notes,
            createdAt: UTC.iso(Date()),
            lastUsedAt: nil
        )
        do {
            try catalog.insertCatalog(row)
        } catch {
            try? secrets.delete(name: name)
            throw error
        }
        try recordKeyEvent(name: name, action: "add", caller: caller)
    }

    func list() throws -> [CatalogRow] {
        try catalog.listCatalog()
    }

    func listJSONObject() throws -> [[String: Any]] {
        let months = try monthGatewayByKey()
        return try list().map { keyJSONObject($0, month: months[$0.name]) }
    }

    func keyJSONObject(_ row: CatalogRow) throws -> [String: Any] {
        let month = try monthGatewayByKey()[row.name]
        return keyJSONObject(row, month: month)
    }

    func keyJSONObject(_ row: CatalogRow, month: GatewayMonth?) -> [String: Any] {
        let enabled = isGatewayEnabled(row.name)
        let month = month ?? GatewayMonth()
        return [
            "name": row.name,
            "provider": row.provider,
            "kind": row.kind,
            "notes": row.notes,
            "created_at": row.createdAt,
            "last_used_at": row.lastUsedAt as Any? ?? NSNull(),
            "gateway_enabled": enabled,
            "gateway_host": row.gatewayHost as Any? ?? NSNull(),
            "gateway_url": enabled
                ? "http://127.0.0.1:\(GatewayListener.port)/\(row.name)"
                : NSNull(),
            // null means "calls happened but none could be priced", not zero dollars.
            "usd_month": month.usd as Any? ?? NSNull(),
            "usd_month_kind": month.kind,
            "gateway_month_calls": month.calls,
            "gateway_month_unpriced_calls": month.unpricedCalls,
            "gateway_month_unpriced_tokens": month.unpricedTokens,
            "version": row.version,
        ]
    }

    func isGatewayEnabled(_ name: String) -> Bool {
        gatewayLock.lock()
        defer { gatewayLock.unlock() }
        return gatewayCache[name] != nil
    }

    func isGatewayRunning() -> Bool {
        gatewayLock.lock()
        defer { gatewayLock.unlock() }
        return gatewayListener != nil
    }

    func gatewayOwnerPid() -> pid_t? {
        guard let raw = try? catalog.metaValue("gateway_owner_pid"),
              let pid = pid_t(raw), pid > 0
        else { return nil }
        if !Self.pidIsAlive(pid) { return nil }
        return pid
    }

    func thisProcessOwnsGateway() -> Bool {
        let us = ProcessInfo.processInfo.processIdentifier
        if isGatewayRunning() { return true }
        return gatewayOwnerPid() == us
    }

    func lookupGateway(name: String) -> GatewayTarget? {
        gatewayLock.lock()
        let cached = gatewayCache[name]
        gatewayLock.unlock()
        guard let cached else { return nil }
        guard let row = try? catalog.catalogRow(name: name) else {
            disableGatewayMemory(name: name, reason: "target_changed")
            return nil
        }
        let catalogHost = row.gatewayHost ?? Providers.provider(id: row.provider)?.host
        if row.provider != cached.provider.id
            || catalogHost != cached.host
            || row.version != cached.version
        {
            disableGatewayMemory(name: name, reason: "target_changed")
            return nil
        }
        return cached
    }

    /// Enable requires one Touch ID (same `secrets.get` path as copy). Secret is held in memory only.
    func setGateway(name: String, enabled: Bool, host: String?, caller: String = "dashboard") throws -> CatalogRow {
        try requireGatewayOwner()
        try KeyName.validate(name)
        guard let row = try catalog.catalogRow(name: name) else {
            throw AppError.notFound(name)
        }
        if enabled {
            guard let provider = Providers.provider(id: row.provider), provider.gateway else {
                throw AppError.usage("gateway is not available for this provider")
            }
            let resolved: String
            if let host {
                resolved = try GatewayHost.validate(host)
            } else if let existing = row.gatewayHost, !existing.isEmpty {
                resolved = existing
            } else if let fallback = provider.host, !fallback.isEmpty {
                resolved = fallback
            } else {
                throw AppError.usage("host is required")
            }
            gatewayLock.lock()
            let previous = gatewayCache[name]
            gatewayLock.unlock()
            if let previous, previous.host != resolved || previous.provider.id != provider.id {
                disableGatewayMemory(name: name, reason: "target_changed")
            }
            let secret = try secrets.get(name: name)
            let version = row.version
            gatewayLock.lock()
            gatewayCache[name] = GatewayTarget(
                name: name,
                secret: secret,
                provider: provider,
                host: resolved,
                version: version
            )
            gatewayLock.unlock()
            let updated = try catalog.updateGateway(name: name, enabled: true, host: resolved)
            try recordKeyEvent(name: name, action: "gateway_enable", caller: caller)
            return updated
        }
        gatewayLock.lock()
        gatewayCache.removeValue(forKey: name)
        gatewayLock.unlock()
        let updated = try catalog.updateGatewayEnabled(name: name, enabled: false)
        try recordKeyEvent(name: name, action: "gateway_disable", caller: caller)
        return updated
    }

    func startGateway(port: UInt16 = GatewayListener.port) throws -> GatewayListener {
        gatewayLock.lock()
        if let gatewayListener {
            gatewayLock.unlock()
            return gatewayListener
        }
        gatewayLock.unlock()
        let listener = try GatewayListener(service: self, port: port)
        do {
            try catalog.setMeta(
                "gateway_owner_pid",
                String(ProcessInfo.processInfo.processIdentifier)
            )
        } catch {
            listener.stop()
            throw error
        }
        gatewayLock.lock()
        if let existing = gatewayListener {
            gatewayLock.unlock()
            listener.stop()
            return existing
        }
        listener.start()
        gatewayListener = listener
        gatewayLock.unlock()
        return listener
    }

    func stopGateway() {
        gatewayLock.lock()
        let listener = gatewayListener
        gatewayListener = nil
        gatewayLock.unlock()
        listener?.stop()
        let us = ProcessInfo.processInfo.processIdentifier
        if let raw = try? catalog.metaValue("gateway_owner_pid"), pid_t(raw) == us {
            try? catalog.clearMeta("gateway_owner_pid")
        }
    }

    // MARK: gateway clients

    /// Issuing a capability to spend a key is a key use, so it asks for presence like copy does.
    /// The token is returned once and only its hash is stored.
    func issueGatewayClient(
        name: String,
        label: String,
        days: Int? = nil,
        methods: [String]? = nil,
        pathPrefix: String? = nil,
        caller: String = "dashboard",
        now: Date = Date()
    ) throws -> (token: String, client: GatewayClient) {
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else { throw AppError.notFound(name) }
        let ttlDays = try GatewayClientToken.validateDays(days)
        let allowed = try GatewayClientToken.validateMethods(methods ?? GatewayClientToken.defaultMethods)
        let prefix = try GatewayClientToken.validatePathPrefix(pathPrefix)
        let trimmedLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try secrets.confirmPresence(reason: "Issue gateway client for \(name)")
        let token = GatewayClientToken.generate()
        let client = try catalog.insertGatewayClient(
            keyName: name,
            label: trimmedLabel,
            tokenHash: GatewayClientToken.hash(token),
            hint: GatewayClientToken.hint(token),
            methods: allowed,
            pathPrefix: prefix,
            createdAt: UTC.iso(now),
            expiresAt: UTC.iso(now.addingTimeInterval(TimeInterval(ttlDays) * 86_400))
        )
        try recordKeyEvent(
            name: name,
            action: "client_issue",
            caller: caller,
            detail: "#\(client.id) \(trimmedLabel) \(ttlDays)d \(allowed.joined(separator: "/"))"
        )
        return (token, client)
    }

    func gatewayClients(name: String) throws -> [GatewayClient] {
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else { throw AppError.notFound(name) }
        return try catalog.gatewayClients(keyName: name)
    }

    func revokeGatewayClient(name: String, id: Int64, caller: String = "dashboard") throws -> GatewayClient {
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else { throw AppError.notFound(name) }
        guard try catalog.revokeGatewayClient(id: id, keyName: name, at: UTC.iso(Date())) else {
            throw AppError.notFound("client \(id)")
        }
        try recordKeyEvent(name: name, action: "client_revoke", caller: caller, detail: "#\(id)")
        guard let client = try catalog.gatewayClients(keyName: name).first(where: { $0.id == id }) else {
            throw AppError.notFound("client \(id)")
        }
        return client
    }

    /// Decides whether one request may use `name` through the gateway. Never consults the
    /// dashboard token. Denial reasons are for the audit log; the caller sends a uniform 401.
    func authorizeGatewayClient(
        name: String,
        headers: [String: String],
        method: String,
        rest: String,
        now: Date = Date()
    ) -> GatewayClientDecision {
        guard let token = GatewayClientToken.extract(headers: headers) else {
            return .denied("no_client_token")
        }
        guard let client = try? catalog.gatewayClient(tokenHash: GatewayClientToken.hash(token)) else {
            return .denied("unknown_client")
        }
        guard client.keyName == name else { return .denied("wrong_key") }
        guard client.revokedAt == nil else { return .denied("revoked") }
        guard client.isActive(now: now) else { return .denied("expired") }
        guard client.allows(method: method, rest: rest) else { return .denied("out_of_scope") }
        try? catalog.touchGatewayClient(id: client.id, at: UTC.iso(now))
        return .allowed(client)
    }

    func recordGatewayUsage(_ row: GatewayUsageRow) throws {
        try catalog.withTransaction {
            try catalog.insertGatewayUsage(row)
            let event = UsageEvent(
                source: "gateway",
                sessionId: "gw:" + row.key,
                promptId: row.requestId ?? UUID().uuidString.lowercased(),
                model: row.model ?? "",
                occurredAt: row.ts,
                provider: row.provider,
                cwd: nil,
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: row.durationMs,
                inputTokens: row.inputTokens ?? 0,
                outputTokens: row.outputTokens ?? 0,
                cachedReadTokens: row.cacheReadTokens ?? 0,
                cacheCreationTokens: row.cacheWriteTokens ?? 0,
                reasoningTokens: 0,
                costUsdTicks: nil,
                keyName: row.key
            )
            _ = try catalog.insertUsage(event)
            try catalog.bumpCatalogVersion()
            try catalog.ensureModelColors()
            try recordKeyEvent(
                name: row.key,
                action: "gateway_call",
                caller: "dashboard",
                detail: row.model,
                touchLastUsed: true
            )
        }
    }

    /// This month's gateway calls for one key. `usd` is nil when no call could be priced,
    /// so an unknown cost is never shown as $0.
    struct GatewayMonth: Equatable {
        var usd: Double? = nil
        var calls: Int = 0
        var pricedCalls: Int = 0
        var unpricedCalls: Int = 0
        var unpricedTokens: Int = 0

        /// none: no calls. estimate: every call priced. partial: some priced. unknown: none priced.
        var kind: String {
            if calls == 0 { return "none" }
            if unpricedCalls == 0 { return "estimate" }
            if pricedCalls == 0 { return "unknown" }
            return "partial"
        }
    }

    func monthGatewayByKey(now: Date = Date(), timeZone: TimeZone = .current) throws -> [String: GatewayMonth] {
        let (start, end) = SpendRange.month.interval(now: now, timeZone: timeZone)
        let rows = try catalog.gatewayUsage(from: UTC.iso(start), to: UTC.iso(end))
        var out: [String: GatewayMonth] = [:]
        for row in rows {
            var month = out[row.key] ?? GatewayMonth()
            month.calls += 1
            if let usd = GatewayEstimate.usd(
                model: row.model,
                input: row.inputTokens ?? 0,
                output: row.outputTokens ?? 0,
                cacheRead: row.cacheReadTokens ?? 0,
                cacheWrite: row.cacheWriteTokens ?? 0,
                api: Providers.provider(id: row.provider)?.api
            ) {
                month.usd = (month.usd ?? 0) + usd
                month.pricedCalls += 1
            } else {
                month.unpricedCalls += 1
                month.unpricedTokens += (row.inputTokens ?? 0) + (row.outputTokens ?? 0)
                    + (row.cacheReadTokens ?? 0) + (row.cacheWriteTokens ?? 0)
            }
            out[row.key] = month
        }
        return out
    }

    func monthUsdByKey(now: Date = Date(), timeZone: TimeZone = .current) throws -> [String: Double] {
        try monthGatewayByKey(now: now, timeZone: timeZone).compactMapValues(\.usd)
    }

    /// Metadata only. Name and secret are immutable. No Touch ID.
    func patch(
        name: String,
        provider: String?,
        kind: String?,
        notes: String?,
        host: String? = nil,
        updateHost: Bool = false,
        caller: String = "dashboard"
    ) throws -> CatalogRow {
        try KeyName.validate(name)
        var nextProvider = provider
        if let provider {
            let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError.usage("provider is required") }
            nextProvider = trimmed
        }
        if let kind {
            try KeyKind.validate(kind)
        }
        var nextHost: String? = nil
        if updateHost {
            if let host, !host.isEmpty {
                nextHost = try GatewayHost.validate(host)
            } else {
                nextHost = nil
            }
        }
        if isGatewayEnabled(name), nextProvider != nil || updateHost {
            disableGatewayMemory(name: name, reason: "target_changed")
        }
        var row = try catalog.updateCatalog(name: name, provider: nextProvider, kind: kind, notes: notes)
        if updateHost {
            row = try catalog.updateGateway(name: name, enabled: false, host: nextHost)
        }
        try recordKeyEvent(name: name, action: "patch", caller: caller)
        return row
    }

    func modelsJSONObject() throws -> [[String: Any]] {
        try catalog.ensureModelColors()
        return try catalog.listModelColors().map { row in
            var obj: [String: Any] = [
                "model": row.model,
                "slot": row.slot,
                "priced": false,
                "source": NSNull(),
                "input_per_mtok": NSNull(),
                "output_per_mtok": NSNull(),
                "cache_read_per_mtok": NSNull(),
            ]
            if let price = ModelPrices.lookup(row.model) {
                obj["priced"] = true
                obj["source"] = price.source.rawValue
                obj["input_per_mtok"] = price.inputPerMTok
                obj["output_per_mtok"] = price.outputPerMTok
                obj["cache_read_per_mtok"] = price.cacheReadPerMTok
            }
            return obj
        }
    }

    func get(name: String) throws -> String {
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else {
            throw AppError.notFound(name)
        }
        return try secrets.get(name: name)
    }

    func copy(name: String, holdUntilWipe: Bool, caller: String = "dashboard") throws {
        let secret = try get(name: name)
        if holdUntilWipe {
            clipboard.copyAndHoldUntilWipe(secret)
        } else {
            clipboard.copyAndWipeInBackground(secret)
        }
        try recordKeyEvent(name: name, action: "copy", caller: caller, touchLastUsed: true)
    }

    func reveal(name: String, caller: String = "dashboard") throws -> String {
        let secret = try get(name: name)
        try recordKeyEvent(name: name, action: "reveal", caller: caller, touchLastUsed: true)
        return secret
    }

    func remove(name: String, caller: String = "dashboard") throws {
        try requireGatewayOwner()
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else {
            throw AppError.notFound(name)
        }
        try secrets.confirmPresence(reason: "Unlock \(name)")
        gatewayLock.lock()
        gatewayCache.removeValue(forKey: name)
        gatewayLock.unlock()
        try secrets.delete(name: name)
        try catalog.deleteCatalog(name: name)
        try recordKeyEvent(name: name, action: "rm", caller: caller)
    }

    func rotate(name: String, secret: String, caller: String = "dashboard") throws -> CatalogRow {
        try requireGatewayOwner()
        try KeyName.validate(name)
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        guard try catalog.catalogExists(name: name) else {
            throw AppError.notFound(name)
        }
        try secrets.confirmPresence(reason: "Unlock \(name)")
        try secrets.replace(name: name, secret: secret)
        let version = try catalog.incrementVersion(name: name)
        gatewayLock.lock()
        if var cached = gatewayCache[name] {
            cached.secret = secret
            cached.version = version
            gatewayCache[name] = cached
        }
        gatewayLock.unlock()
        try recordKeyEvent(name: name, action: "rotate", caller: caller)
        guard let row = try catalog.catalogRow(name: name) else {
            throw AppError.notFound(name)
        }
        return row
    }

    func keyEvents(name: String, limit: Int = 50) throws -> [CatalogDB.KeyEventRow] {
        try KeyName.validate(name)
        guard try catalog.catalogExists(name: name) else {
            throw AppError.notFound(name)
        }
        let capped = min(50, max(1, limit))
        return try catalog.keyEvents(name: name, limit: capped)
    }

    func purge(confirmation: String) throws {
        try requireGatewayOwner()
        try secrets.confirmPresence(reason: "Purge Keysreallysafe")
        guard confirmation == "purge" else {
            throw AppError.usage("type purge to confirm")
        }
        gatewayLock.lock()
        gatewayCache.removeAll()
        gatewayLock.unlock()
        try secrets.deleteAll()
        try catalog.wipeData()
    }

    func recordKeyEvent(
        name: String,
        action: String,
        caller: String,
        detail: String? = nil,
        touchLastUsed: Bool = false
    ) throws {
        let ts = UTC.iso(Date())
        try catalog.insertKeyEvent(
            ts: ts,
            name: name,
            action: action,
            caller: caller,
            detail: detail
        )
        if touchLastUsed {
            try catalog.touchLastUsed(name: name, at: ts)
        }
    }

    func pollOpenRouter() throws {
        let rows = try catalog.listCatalog()
        for row in rows {
            guard row.provider == "openrouter", row.kind == "billing" else { continue }
            gatewayLock.lock()
            let secret = gatewayCache[row.name]?.secret
            gatewayLock.unlock()
            guard let secret else { continue }
            do {
                var snap = try openRouter.fetch(secret: secret)
                snap.keyName = row.name
                snap.provider = "openrouter"
                if snap.ts.isEmpty { snap.ts = UTC.iso(Date()) }
                try catalog.insertProviderSnapshot(snap)
            } catch {
                let line = "openrouter poll failed for \(row.name): \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    func ingest(_ source: Ingest.Source) throws -> [(name: String, report: IngestReport)] {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        return try ingestLocked(source)
    }

    func ingestIfStale(olderThan: TimeInterval = IngestScheduler.staleInterval) throws {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        if let iso = try catalog.lastIngestAt(), let date = UTC.parse(iso) {
            if Date().timeIntervalSince(date) < olderThan { return }
        }
        _ = try ingestLocked(.all)
    }

    private func ingestLocked(_ source: Ingest.Source) throws -> [(name: String, report: IngestReport)] {
        try ensureClaudeDedupLocked()
        let reports = try Ingest.run(
            source: source,
            grokHome: grokHome,
            claudeHome: claudeHome,
            codexHome: codexHome,
            db: catalog
        )
        let changed = reports.reduce(0) { $0 + $1.report.rowsInserted + $1.report.rowsUpdated }
        if changed > 0 {
            try catalog.bumpCatalogVersion()
        }
        try catalog.ensureModelColors()
        try catalog.setLastIngestAt(UTC.iso(Date()))
        return reports
    }

    private func ensureClaudeDedupLocked() throws {
        if try catalog.metaValue("claude_dedup") == "request_id_v2" { return }
        try catalog.withTransaction {
            let removed = try catalog.deleteUsage(source: "claude-local")
            try catalog.deleteIngestFiles(pathLike: "%/projects/%")
            try catalog.setMeta("claude_dedup", "request_id_v2")
            if removed > 0 {
                try catalog.bumpCatalogVersion()
            }
        }
    }

    func requireGatewayOwner() throws {
        let us = ProcessInfo.processInfo.processIdentifier
        if let owner = gatewayOwnerPid(), owner != us {
            throw AppError.gatewayOwned(owner)
        }
    }

    private func disableGatewayMemory(name: String, reason: String) {
        gatewayLock.lock()
        let had = gatewayCache.removeValue(forKey: name) != nil
        gatewayLock.unlock()
        guard had else { return }
        _ = try? catalog.updateGatewayEnabled(name: name, enabled: false)
        try? recordKeyEvent(
            name: name,
            action: "gateway_disable",
            caller: "dashboard",
            detail: reason
        )
    }

    private static func pidIsAlive(_ pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    func env(
        name: String,
        variable: String,
        command: [String],
        caller: String = "env"
    ) throws -> Int32 {
        try KeyName.validate(name)
        let variable = EnvVar.canonicalize(variable)
        try EnvVar.validate(variable)
        guard !command.isEmpty else { throw AppError.usage("missing command after --") }
        let secret = try get(name: name)
        try recordKeyEvent(name: name, action: "env", caller: caller, touchLastUsed: true)
        return try runner.run(argv: command, extraEnv: [variable: secret])
    }

    func liveStatus() throws -> LiveStatus {
        let grokWeek = try spend(range: .week, by: .model, source: .grok)
        let openaiWeek = try spend(range: .week, by: .model, source: .openai)
        let period = SpendPeriod.calendarWeek(now: Date(), timeZone: .current)
        var status = try LiveStatus.scan(
            grokHome: grokHome,
            claudeHome: claudeHome,
            grokWeekUsd: grokWeek.totals.grokUsd,
            openaiWeekTokens: openaiWeek.totals.openaiTokens,
            openaiWeekUsdEstimate: openaiWeek.totals.openaiUsdEstimate,
            codexHome: codexHome,
            weekPeriod: period
        )
        status.lastIngestAt = try catalog.lastIngestAt()
        status.catalogVersion = try catalog.catalogVersion()
        applyOpenRouter(&status)
        return status
    }

    private func applyOpenRouter(_ status: inout LiveStatus) {
        let note = "enable the gateway for this key to poll"
        if let snap = try? catalog.latestProviderSnapshot(provider: "openrouter") {
            for i in status.plans.indices where status.plans[i].source == "openrouter" {
                status.plans[i].limit = snap.limit
                status.plans[i].limitRemaining = snap.limitRemaining
                status.plans[i].usageWeekly = snap.usageWeekly
                status.plans[i].snapshotAt = snap.ts
                status.plans[i].usageNote = nil
            }
        } else {
            for i in status.plans.indices where status.plans[i].source == "openrouter" {
                status.plans[i].usageNote = note
            }
        }
    }

    func spend(
        range: SpendRange,
        by: SpendGroup,
        source: SourceFilter,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        key: String? = nil
    ) throws -> SpendReport {
        try SpendQueries(db: catalog).report(
            range: range,
            by: by,
            source: source,
            now: now,
            timeZone: timeZone,
            key: key
        )
    }
}

enum AppFactory {
    static func makeService() throws -> KeysService {
        let db = try CatalogDB(path: Paths.catalogDB)
        return KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: KeychainStore(), presence: LocalPresenceGate()),
            clipboard: AppKitClipboard()
        )
    }
}
