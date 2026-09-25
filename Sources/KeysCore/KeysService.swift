import Darwin
import Foundation

final class KeysService: @unchecked Sendable {
    let catalog: CatalogDB
    let secrets: any SecretStore
    /// Asked before every secret read (get, copy, reveal, env, gateway enable, provider check)
    /// and before grant, client issue, delete, rotate and purge.
    let presence: any PresenceGate
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
    let grants = GrantStore()
    var checker: any ProviderCheckFetching = ProviderCheckHTTP()
    var analytics: ProductAnalytics?
    /// First-launch answers: background Claude limit refresh, analytics question asked.
    let preferences: AppPreferences
    private var screenLockObserver: NSObjectProtocol?

    init(
        catalog: CatalogDB,
        secrets: any SecretStore,
        presence: any PresenceGate,
        clipboard: any ClipboardClient,
        grokHome: URL = Paths.grokHome,
        claudeHome: URL = Paths.claudeHome,
        codexHome: URL = Paths.codexHome,
        runner: any CommandRunner = FoundationCommandRunner(),
        openRouter: any OpenRouterFetching = OpenRouterHTTP()
    ) {
        self.catalog = catalog
        self.secrets = secrets
        self.presence = presence
        self.clipboard = clipboard
        self.grokHome = grokHome
        self.claudeHome = claudeHome
        self.codexHome = codexHome
        self.runner = runner
        self.openRouter = openRouter
        self.preferences = AppPreferences(catalog: catalog)
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
        let provider = Providers.provider(id: row.provider)
        let host = row.gatewayHost ?? provider?.host
        let check = try? catalog.providerCheck(keyName: row.name)
        let active = grants.list().filter { $0.key == row.name }
        return [
            "name": row.name,
            "provider": row.provider,
            "host": host as Any? ?? NSNull(),
            "checkable": provider.map { ProviderCheck.endpoint(for: $0) != nil } ?? false,
            "last_check": check.map { c -> [String: Any] in
                [
                    "checked_at": c.checkedAt,
                    "outcome": c.outcome.rawValue,
                    "ok": c.ok,
                    "model_count": c.models.count,
                    "summary": c.summary,
                ]
            } as Any? ?? NSNull(),
            "active_grants": active.count,
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
            "version": row.version,
        ]
    }

    func isGatewayEnabled(_ name: String) -> Bool {
        gatewayLock.withLock { gatewayCache[name] != nil }
    }

    func isGatewayRunning() -> Bool {
        gatewayLock.withLock { gatewayListener != nil }
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
        guard let cached = gatewayLock.withLock({ gatewayCache[name] }) else { return nil }
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

    /// Enable requires one Touch ID (the same presence check as copy). Secret is held in memory only.
    func setGateway(
        name: String,
        enabled: Bool,
        host: String?,
        caller: String = "dashboard",
        reason: String? = nil
    ) throws -> CatalogRow {
        try requireGatewayOwner()
        let row = try existingRow(name)
        if enabled {
            guard let provider = Providers.provider(id: row.provider), provider.gateway else {
                throw AppError.usage("gateway is not available for this provider")
            }
            guard let resolved = try host.map(GatewayHost.validate) ?? row.gatewayHost ?? provider.host else {
                throw AppError.usage("host is required")
            }
            if let previous = gatewayLock.withLock({ gatewayCache[name] }),
               previous.host != resolved || previous.provider.id != provider.id
            {
                disableGatewayMemory(name: name, reason: "target_changed")
            }
            try presence.require(reason: reason ?? "Unlock \(name)")
            let target = GatewayTarget(
                name: name, secret: try secrets.get(name: name), provider: provider, host: resolved, version: row.version
            )
            gatewayLock.withLock { gatewayCache[name] = target }
            let updated = try catalog.updateGatewayHost(name: name, host: resolved)
            try recordKeyEvent(name: name, action: "gateway_enable", caller: caller)
            return updated
        }
        _ = gatewayLock.withLock { gatewayCache.removeValue(forKey: name) }
        revokeGrants(key: name, reason: "gateway_off", caller: caller)
        try recordKeyEvent(name: name, action: "gateway_disable", caller: caller)
        return row
    }

    // MARK: - Grants (temporary, narrowly scoped access)

    /// One presence prompt per grant. Names the task, provider, host and expiry in the prompt.
    /// If the gateway is off for the key, this turns it on with the same single prompt.
    func issueGrant(
        name: String,
        request raw: GrantRequest,
        caller: String = "dashboard"
    ) throws -> (grant: Grant, token: String) {
        try requireGatewayOwner()
        let row = try existingRow(name)
        let request = try raw.validated()
        guard let provider = Providers.provider(id: row.provider), provider.gateway else {
            throw AppError.usage("gateway is not available for provider \(row.provider); a grant cannot be issued")
        }
        guard let host = row.gatewayHost ?? provider.host else {
            throw AppError.usage("set a gateway host for \(name) first (this provider has one host per account)")
        }
        let reason = Self.grantReason(
            task: request.task, key: name, provider: provider, host: host, minutes: request.minutes
        )
        if let cached = lookupGateway(name: name), cached.host == host {
            try presence.require(reason: reason)
        } else {
            _ = try setGateway(name: name, enabled: true, host: host, caller: caller, reason: reason)
        }
        grants.prune()
        let issued = grants.issue(key: name, provider: provider.id, host: host, request: request)
        try recordKeyEvent(
            name: name,
            action: "grant",
            caller: caller,
            detail: Self.grantDetail(issued.grant)
        )
        return issued
    }

    static func grantReason(task: String, key: String, provider: Providers.Record, host: String, minutes: Int) -> String {
        let span = minutes % 60 == 0 && minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
        return "Grant \"\(task)\" the key \(key) for \(provider.name) at \(host), \(span)"
    }

    static func grantDetail(_ g: Grant) -> String {
        var parts = ["\(g.id)", g.task, "until \(UTC.iso(g.expiresAt))", "\(g.host)"]
        if g.methods != Grant.allMethods { parts.append(g.methods.sorted().joined(separator: ",")) }
        if !g.paths.isEmpty { parts.append(g.paths.joined(separator: ",")) }
        if let n = g.maxRequests { parts.append("max \(n) req") }
        if let u = g.maxUsd { parts.append(String(format: "max $%.2f", u)) }
        return parts.joined(separator: " · ")
    }

    func listGrants(includeInactive: Bool = false) -> [Grant] {
        grants.list(includeInactive: includeInactive)
    }

    @discardableResult
    func revokeGrant(id: String, caller: String = "dashboard") throws -> Grant {
        guard let g = grants.revoke(id: id, reason: "revoked") else { throw AppError.notFound(id) }
        try? recordKeyEvent(name: g.key, action: "grant_revoke", caller: caller, detail: "\(g.id) · \(g.task)")
        return g
    }

    @discardableResult
    func revokeGrants(key: String? = nil, reason: String, caller: String = "dashboard") -> [Grant] {
        let touched = grants.revokeAll(key: key, reason: reason)
        for g in touched {
            try? recordKeyEvent(name: g.key, action: "grant_revoke", caller: caller, detail: "\(g.id) · \(reason)")
        }
        return touched
    }

    /// Screen lock, logout and process exit all fail closed.
    func handleScreenLock() {
        revokeGrants(reason: "screen_lock", caller: "system")
    }

    /// Idempotent. The app registers at startup so grants die with screen lock
    /// even before the gateway listener starts.
    func observeScreenLock() {
        if screenLockObserver != nil { return }
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenLock()
        }
    }

    func authorizeGateway(
        token: String?,
        target: GatewayTarget,
        method: String,
        rest: String
    ) -> Result<Grant, GrantDenial> {
        grants.authorize(
            token: token,
            key: target.name,
            host: target.host,
            method: method,
            rest: rest,
            providerPrefix: target.provider.pathPrefix
        )
    }

    // MARK: - Provider checks (read-only)

    /// Authentication status and model list from the provider's read-only endpoint.
    /// Uses the in-memory gateway secret when present, else one presence prompt.
    func checkProvider(name: String, caller: String = "dashboard") throws -> ProviderCheck.Result {
        let row = try existingRow(name)
        guard let provider = Providers.provider(id: row.provider) else {
            throw AppError.usage("unknown provider \(row.provider); edit the key and pick one from the list")
        }
        let host = row.gatewayHost ?? provider.host
        // Before any presence prompt: a provider with nothing to probe must not ask for Touch ID.
        guard ProviderCheck.endpoint(for: provider) != nil else {
            let result = ProviderCheck.noEndpoint(key: name, provider: provider, host: host ?? "")
            try catalog.upsertProviderCheck(result)
            return result
        }
        guard let host else {
            throw AppError.usage("set a gateway host for \(name) first (this provider has one host per account)")
        }
        let secret: String
        if let cached = gatewayLock.withLock({ gatewayCache[name]?.secret }) {
            secret = cached
        } else {
            try presence.require(reason: "Check \(name) against \(provider.name) at \(host) (read-only)")
            secret = try secrets.get(name: name)
        }
        let result = ProviderCheck.run(key: name, provider: provider, host: host, secret: secret, fetcher: checker)
        try catalog.upsertProviderCheck(result)
        try recordKeyEvent(
            name: name,
            action: "check",
            caller: caller,
            detail: result.summary,
            touchLastUsed: true
        )
        return result
    }

    func lastCheck(name: String) throws -> ProviderCheck.Result? {
        try KeyName.validate(name)
        return try catalog.providerCheck(keyName: name)
    }

    func startGateway(port: UInt16 = GatewayListener.port) throws -> GatewayListener {
        if let running = gatewayLock.withLock({ gatewayListener }) {
            return running
        }
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
        // Another thread may have started one meanwhile; keep the first and drop ours.
        let winner: GatewayListener = gatewayLock.withLock {
            if let existing = gatewayListener { return existing }
            gatewayListener = listener
            return listener
        }
        guard winner === listener else {
            listener.stop()
            return winner
        }
        listener.start()
        observeScreenLock()
        return listener
    }

    func stopGateway() {
        revokeGrants(reason: "gateway_stopped", caller: "system")
        let listener = gatewayLock.withLock {
            defer { gatewayListener = nil }
            return gatewayListener
        }
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
        _ = try existingRow(name)
        let ttlDays = try GatewayClientToken.validateDays(days)
        let allowed = try GatewayClientToken.validateMethods(methods ?? GatewayClientToken.defaultMethods)
        let prefix = try GatewayClientToken.validatePathPrefix(pathPrefix)
        let trimmedLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try presence.require(reason: "Issue gateway client for \(name)")
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
        _ = try existingRow(name)
        return try catalog.gatewayClients(keyName: name)
    }

    func revokeGatewayClient(name: String, id: Int64, caller: String = "dashboard") throws -> GatewayClient {
        _ = try existingRow(name)
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
        return .allowed(client)
    }

    /// Called once the key resolved and the call is about to be forwarded, so `last_used_at`
    /// means an upstream call, not a rejected attempt.
    func noteGatewayClientUse(_ client: GatewayClient, now: Date = Date()) {
        try? catalog.touchGatewayClient(id: client.id, at: UTC.iso(now))
    }

    /// Audit a denial only for a key that exists; a made-up name must not grow the log.
    func recordGatewayDenial(name: String, reason: String) {
        guard (try? catalog.catalogExists(name: name)) == true else { return }
        try? recordKeyEvent(name: name, action: "gateway_denied", caller: "gateway", detail: reason)
    }

    func recordGatewayUsage(_ row: GatewayUsageRow, grantId: String? = nil) throws {
        analytics?.record((200..<400).contains(row.status) ? .gatewaySuccess : .gatewayFailure, durationMS: row.durationMs)
        var event = row.usageEvent()
        if let grantId {
            grants.charge(id: grantId, usd: SpendQueries.gatewayUsd(event))
        }
        try catalog.withTransaction {
            // The upstream request id is the prompt id so a local event with the same id can be
            // matched. A proxy that repeats ids must not collapse two calls into one row, so a
            // second sighting of an id gets a suffix (and then no longer correlates).
            if row.requestId != nil,
               try catalog.usageExists(source: "gateway", sessionId: event.sessionId, promptId: event.promptId, model: event.model)
            {
                event.promptId += "+" + UUID().uuidString.lowercased()
            }
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
        // Straight from the gateway rows: the unkeyed report drops calls a local log correlated.
        let events = try catalog.usageEvents(from: UTC.iso(start), to: UTC.iso(end), source: .keys)
        var out: [String: GatewayMonth] = [:]
        for event in events {
            guard let key = event.keyName else { continue }
            var month = out[key] ?? GatewayMonth()
            month.calls += 1
            if let usd = SpendQueries.gatewayUsd(event) {
                month.usd = (month.usd ?? 0) + usd
                month.pricedCalls += 1
            } else {
                month.unpricedCalls += 1
            }
            out[key] = month
        }
        return out
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
            row = try catalog.updateGatewayHost(name: name, host: nextHost)
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
                "input_per_mtok": NSNull(),
                "output_per_mtok": NSNull(),
                "cache_read_per_mtok": NSNull(),
            ]
            if let price = ModelPrices.lookup(row.model) {
                obj["priced"] = true
                obj["input_per_mtok"] = price.inputPerMTok
                obj["output_per_mtok"] = price.outputPerMTok
                obj["cache_read_per_mtok"] = price.cacheReadPerMTok
            }
            return obj
        }
    }

    func get(name: String) throws -> String {
        _ = try existingRow(name)
        try presence.require(reason: "Unlock \(name)")
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
        _ = try existingRow(name)
        try presence.require(reason: "Delete \(name)")
        _ = gatewayLock.withLock { gatewayCache.removeValue(forKey: name) }
        revokeGrants(key: name, reason: "key_deleted", caller: caller)
        try secrets.delete(name: name)
        try catalog.deleteCatalog(name: name)
        try? catalog.deleteProviderCheck(keyName: name)
        try recordKeyEvent(name: name, action: "rm", caller: caller)
    }

    func rotate(name: String, secret: String, caller: String = "dashboard") throws -> CatalogRow {
        try requireGatewayOwner()
        _ = try existingRow(name)
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        try presence.require(reason: "Unlock \(name)")
        try secrets.replace(name: name, secret: secret)
        let version = try catalog.incrementVersion(name: name)
        gatewayLock.withLock {
            gatewayCache[name]?.secret = secret
            gatewayCache[name]?.version = version
        }
        try recordKeyEvent(name: name, action: "rotate", caller: caller)
        guard let row = try catalog.catalogRow(name: name) else {
            throw AppError.notFound(name)
        }
        return row
    }

    func keyEvents(name: String, limit: Int = 50) throws -> [CatalogDB.KeyEventRow] {
        _ = try existingRow(name)
        let capped = min(50, max(1, limit))
        return try catalog.keyEvents(name: name, limit: capped)
    }

    func purge(confirmation: String) throws {
        try requireGatewayOwner()
        try presence.require(reason: "Purge Keysrs")
        guard confirmation == "purge" else {
            throw AppError.usage("type purge to confirm")
        }
        try Self.removeRetiredOptimizerData(catalogDirectory: catalog.path.deletingLastPathComponent())
        gatewayLock.withLock { gatewayCache.removeAll() }
        revokeGrants(reason: "purge", caller: "purge")
        try secrets.deleteAll()
        try analytics?.setEnabled(false, consentVersion: ProductAnalytics.consentVersion)
        try catalog.wipeData()
    }

    /// 0.9.0 and 0.9.1 shipped an experimental optimizer that kept encrypted
    /// payloads in `optimizer/` next to the catalog (its Keychain key lives under
    /// the retired service `keysreallysafe.optimizer`, which `KeychainStore.deleteAll`
    /// removes). Nothing reads either since the optimizer was removed, but purge
    /// still promises to leave no Keysrs data behind on machines that ran them.
    static func removeRetiredOptimizerData(catalogDirectory: URL) throws {
        let directory = catalogDirectory.appendingPathComponent("optimizer", isDirectory: true)
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: directory.path)) != nil else { return }
        try fm.removeItem(at: directory)
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
        // Only the action's fixed enum crosses into product analytics.
        // The name, caller and audit detail stay in the local audit table.
        let event: ProductAnalyticsEvent? = switch action {
        case "add": .keyAdd
        case "copy": .keyCopy
        case "rm": .keyDelete
        case "grant": .grantCreate
        case "client_issue": .clientCreate
        default: nil
        }
        if let event { analytics?.record(event) }
    }

    func pollOpenRouter() throws {
        let rows = try catalog.listCatalog()
        for row in rows {
            guard row.provider == "openrouter", row.kind == "billing" else { continue }
            guard let secret = gatewayLock.withLock({ gatewayCache[row.name]?.secret }) else { continue }
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
        // A pass already running will refresh the data; do not queue a request thread behind it.
        guard ingestLock.try() else { return }
        defer { ingestLock.unlock() }
        if let iso = try catalog.lastIngestAt(), let date = UTC.parse(iso) {
            if Date().timeIntervalSince(date) < olderThan { return }
        }
        _ = try ingestLocked(.all)
    }

    private func ingestLocked(_ source: Ingest.Source) throws -> [(name: String, report: IngestReport)] {
        // Every ingest path (explicit, scheduled, the dashboard's stale refresh) comes through here.
        var succeeded = false
        defer { analytics?.record(succeeded ? .ingestSuccess : .ingestFailure) }
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
        succeeded = true
        return reports
    }

    func requireGatewayOwner() throws {
        let us = ProcessInfo.processInfo.processIdentifier
        if let owner = gatewayOwnerPid(), owner != us {
            throw AppError.gatewayOwned(owner)
        }
    }

    /// Validates the name and returns its catalog row, or throws notFound.
    private func existingRow(_ name: String) throws -> CatalogRow {
        try KeyName.validate(name)
        guard let row = try catalog.catalogRow(name: name) else { throw AppError.notFound(name) }
        return row
    }

    private func disableGatewayMemory(name: String, reason: String) {
        guard gatewayLock.withLock({ gatewayCache.removeValue(forKey: name) }) != nil else { return }
        revokeGrants(key: name, reason: reason)
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
        let row = try existingRow(name)
        let variable = EnvVar.canonicalize(variable)
        try EnvVar.validate(variable)
        guard !command.isEmpty else { throw AppError.usage("missing command after --") }
        let provider = Providers.provider(id: row.provider)
        let where_ = row.gatewayHost ?? provider?.host ?? "no fixed host"
        let line = "keys env: \(name) is a \(provider?.name ?? row.provider) key (\(where_)); the raw value goes to \(command[0]) as \(variable)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let secret = try get(name: name)
        try recordKeyEvent(name: name, action: "env", caller: caller, touchLastUsed: true)
        return try runner.run(argv: command, extraEnv: [variable: secret])
    }

    func liveStatus() throws -> LiveStatus {
        let grokWeek = try spend(range: .week, by: .model, source: .grok)
        let openaiWeek = try spend(range: .week, by: .model, source: .openai)
        let period = SpendPeriod.calendarWeek(now: Date(), timeZone: .current)
        var status = LiveStatus.scan(
            grokHome: grokHome,
            claudeHome: claudeHome,
            grokWeekUsd: grokWeek.totals.grokUsd,
            claudePlan: Paths.appSupport.appendingPathComponent("claude-plan.json"),
            openaiWeekTokens: openaiWeek.totals.openaiTokens,
            openaiWeekUsdEstimate: openaiWeek.totals.openaiUsdEstimate,
            codexHome: codexHome,
            weekPeriod: period
        )
        status.lastIngestAt = try catalog.lastIngestAt()
        status.catalogVersion = try catalog.catalogVersion()
        applyOpenRouter(&status)
        // Plan-window peaks for the day's report; a no-op unless sharing is on.
        analytics?.observe(status)
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
        key: String? = nil,
        provider: String? = nil
    ) throws -> SpendReport {
        try SpendQueries(db: catalog).report(
            range: range,
            by: by,
            source: source,
            now: now,
            timeZone: timeZone,
            key: key,
            provider: provider
        )
    }
}

enum AppFactory {
    static func makeService() throws -> KeysService {
        let db = try CatalogDB(path: Paths.catalogDB)
        let service = KeysService(
            catalog: db,
            secrets: KeychainStore(),
            presence: LocalPresenceGate(),
            clipboard: AppKitClipboard()
        )
        service.observeScreenLock()
        service.analytics = ProductAnalytics(catalog: db)
        return service
    }
}
