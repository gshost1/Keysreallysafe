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
    var grokBotHome: URL
    var droidHome: URL
    /// Serialises ingest passes only. A five-minute log scan must never hold up a gateway lookup.
    private let ingestLock = NSLock()
    /// Guards `gatewayCache` and `gatewayListener`; held for dictionary access only.
    private let gatewayLock = NSLock()
    private var gatewayCache: [String: GatewayTarget] = [:]
    private var gatewayListener: GatewayListener?
    var openRouter: any OpenRouterFetching
    let grants = GrantStore()
    /// Pauses a key after consecutive upstream 401/403 answers (GatewayBreaker).
    let breaker = GatewayBreaker()
    /// The relay secret's own store (Keychain service `keysreallysafe.relay` in the app, memory
    /// in tests). nil means this process has no relay storage, and the relay commands say so.
    let relaySecrets: (any SecretStore)?
    /// The relay this process runs when it is turned on from the menu, the dashboard or
    /// `keys relay on`. AppRuntime swaps in one that logs to menubar.log before the site serves.
    var relayHost = RelayHost()
    /// Held while the relay is turned on or off, so two toggles at once (menu and dashboard)
    /// cannot both find it off and race for the lock.
    private let relayToggleLock = NSLock()
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
        grokBotHome: URL = Paths.grokBotHome,
        droidHome: URL = Paths.droidHome,
        runner: any CommandRunner = SpawnCommandRunner(),
        openRouter: any OpenRouterFetching = OpenRouterHTTP(),
        relaySecrets: (any SecretStore)? = nil
    ) {
        self.catalog = catalog
        self.secrets = secrets
        self.relaySecrets = relaySecrets
        self.presence = presence
        self.clipboard = clipboard
        self.grokHome = grokHome
        self.claudeHome = claudeHome
        self.codexHome = codexHome
        self.grokBotHome = grokBotHome
        self.droidHome = droidHome
        self.runner = runner
        self.openRouter = openRouter
        self.preferences = AppPreferences(catalog: catalog)
        ModelPrices.loadAtStartup()
        Providers.loadAtStartup()
        // Custom providers are catalog rows like keys are, so they survive restarts. The overlay
        // is process-wide because gateway lookups and checks go through the static Providers
        // resolver; reinstalling it here is what keeps it in step with this catalog.
        let custom = (try? catalog.listCustomProviders()) ?? []
        Providers.setOverlay(Dictionary(custom.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        bindLegacyGatewayClients()
    }

    /// The host a key's gateway sends to: the per-key host, else the provider's one host.
    static func effectiveHost(_ row: CatalogRow) -> String? {
        row.gatewayHost ?? Providers.provider(id: row.provider)?.host
    }

    /// Runs once after the migration that added `gateway_clients.host`: binds each older client
    /// to its key's host as of the upgrade. It needs the provider table, which the catalog
    /// migration has no access to. A client left unbound (its key had no host) is refused.
    private func bindLegacyGatewayClients() {
        guard (try? catalog.metaValue(CatalogDB.clientHostBackfillKey)) == "pending" else { return }
        for client in (try? catalog.unboundGatewayClients()) ?? [] {
            guard let row = try? catalog.catalogRow(name: client.keyName), let host = Self.effectiveHost(row) else { continue }
            try? catalog.bindGatewayClient(id: client.id, host: host)
        }
        try? catalog.deleteMeta(CatalogDB.clientHostBackfillKey)
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

    // MARK: - Providers (the catalog entries keys point at)

    /// Adds a user-owned provider to the catalog. No presence prompt: a provider is routing
    /// metadata, not a secret. A custom id that matches a shipped one wins over it, which is
    /// how a wrong host in the shipped file gets fixed without waiting for a release.
    @discardableResult
    func addProvider(
        id: String,
        name: String,
        host: String? = nil,
        api: String = "other",
        authHeader: String = "Authorization",
        authPrefix: String = "Bearer ",
        pathPrefix: String = "",
        keyPrefix: String? = nil,
        note: String? = nil,
        gateway: Bool = true
    ) throws -> Providers.Record {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        try ProviderID.validate(trimmedID)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64,
              !trimmedName.contains(where: { $0.isNewline }) else {
            throw AppError.usage("provider name is required (at most one line, 64 characters)")
        }
        let trimmedAPI = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["openai", "anthropic", "gemini", "other"].contains(trimmedAPI) else {
            throw AppError.usage("api must be openai, anthropic, gemini or other")
        }
        let trimmedHeader = authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHeader.wholeMatch(of: /^[A-Za-z0-9-]{1,64}$/) != nil else {
            throw AppError.usage("auth header must be a plain header name, e.g. x-api-key")
        }
        // Not trimmed: "Bearer " and "Token " carry the space that separates the scheme from
        // the secret on the wire. Only newlines and length are refused here.
        guard authPrefix.count <= 32, !authPrefix.contains(where: { $0.isNewline }) else {
            throw AppError.usage("auth prefix must be at most 32 characters on one line")
        }
        var trimmedPath = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.hasPrefix("/") { trimmedPath = String(trimmedPath.dropFirst()) }
        guard trimmedPath.count <= 200,
              GatewayClientToken.isPlainPath(trimmedPath),
              !GatewayClientToken.hasDotSegment(trimmedPath) else {
            throw AppError.usage("path prefix must be a clean path, e.g. v1")
        }
        let trimmedHost = try host.map { try GatewayHost.validate($0) }
        let trimmedKeyPrefix = keyPrefix.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let trimmedKeyPrefix, trimmedKeyPrefix.count > 64 || trimmedKeyPrefix.contains(where: { $0.isNewline }) {
            throw AppError.usage("key prefix hint must be at most 64 characters on one line")
        }
        let trimmedNote = note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let trimmedNote, trimmedNote.count > 200 || trimmedNote.contains(where: { $0.isNewline }) {
            throw AppError.usage("note must be at most 200 characters on one line")
        }
        let record = Providers.Record(
            id: trimmedID,
            name: trimmedName,
            host: trimmedHost,
            api: trimmedAPI,
            authHeader: trimmedHeader,
            authPrefix: authPrefix,
            pathPrefix: trimmedPath.isEmpty ? "" : "/" + trimmedPath,
            gateway: gateway,
            group: "yours",
            keyPrefix: trimmedKeyPrefix,
            note: trimmedNote,
            custom: true
        )
        try catalog.insertCustomProvider(record)
        reinstallOverlay()
        return record
    }

    /// Removes a user-added provider. A built-in one is refused: hiding it is the supported
    /// way to take it out of the Add dialog, and deleting a provider a key still points at
    /// would silently turn that key's gateway off.
    func removeProvider(id: String) throws {
        try ProviderID.validate(id)
        guard try catalog.customProviderExists(id: id) else {
            if Providers.cache.value.byID[id] != nil {
                throw AppError.usage("\(id) is a built-in provider; hide it instead: keys provider hide \(id)")
            }
            throw AppError.notFound(id)
        }
        let referring = try catalog.listCatalog().filter { $0.provider == id }.map(\.name)
        guard referring.isEmpty else {
            throw AppError.usage(
                "\(id) is used by \(referring.joined(separator: ", ")); "
                    + "delete or edit those keys first, or hide the provider instead"
            )
        }
        guard try catalog.deleteCustomProvider(id: id) else { throw AppError.notFound(id) }
        reinstallOverlay()
    }

    /// Hides or unhides a built-in provider in this catalog only; the record still resolves,
    /// so keys that already use it keep their gateway, checks and name. A user-added provider
    /// is removed instead; hiding exists so the shipped list can be slimmed without a fork.
    func setProviderHidden(id: String, hidden: Bool) throws {
        try ProviderID.validate(id)
        if try catalog.customProviderExists(id: id) {
            throw AppError.usage("\(id) is a provider you added; remove it with keys provider rm \(id)")
        }
        guard Providers.cache.value.byID[id] != nil else { throw AppError.notFound(id) }
        var ids = try catalog.hiddenProviderIds()
        if hidden {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        try catalog.setHiddenProviderIds(ids)
    }

    private func reinstallOverlay() {
        let custom = (try? catalog.listCustomProviders()) ?? []
        Providers.setOverlay(Dictionary(custom.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    // MARK: usage limits

    /// Every saved window limit, for the dashboard's dialog and for tests.
    func usageLimits() throws -> [CatalogDB.UsageLimit] {
        try catalog.usageLimits()
    }

    /// Sets (or replaces) one window's token limit. The catalog version moves so an already-open
    /// dashboard reloads its status row on its next poll.
    @discardableResult
    func setUsageLimit(source: String, window: String, tokens: Int) throws -> CatalogDB.UsageLimit {
        let window = try UsageLimits.validate(source: source, window: window)
        try UsageLimits.validateTokens(tokens)
        let record = CatalogDB.UsageLimit(source: source, window: window.rawValue, tokens: tokens)
        try catalog.setUsageLimit(source: record.source, window: record.window, tokens: record.tokens)
        try syncFactorySubscription(window: window.rawValue, tokens: tokens)
        try catalog.bumpCatalogVersion()
        return record
    }

    /// Clears one window's limit; the window goes back to tokens only. Clearing a window that
    /// never had one is the same end state, so it is not an error.
    func clearUsageLimit(source: String, window: String) throws {
        let window = try UsageLimits.validate(source: source, window: window)
        _ = try catalog.clearUsageLimit(source: source, window: window.rawValue)
        try syncFactorySubscription(window: window.rawValue, tokens: nil)
        try catalog.bumpCatalogVersion()
    }

    /// A Factory subscription's token limit and the Droid row's Set limits control are the same
    /// fact seen from two dialogs. `usage_limits` is the single source of truth for a Droid
    /// window limit; this keeps the subscription's stored copy in step whenever the row's own
    /// control edits or clears that window, so the two surfaces can never show different numbers
    /// for the same window. A window the subscription does not name is a different fact and
    /// leaves the subscription alone.
    private func syncFactorySubscription(window: String, tokens: Int?) throws {
        guard var sub = try catalog.factorySubscription(),
              sub.limitUnit == "tokens", sub.limitPeriod == window
        else { return }
        let amount = tokens.map(Double.init)
        guard sub.limitAmount != amount else { return }
        sub.limitAmount = amount
        if amount == nil { sub.limitUnit = nil; sub.limitPeriod = nil }
        _ = try catalog.updateSubscription(sub)
    }

    // MARK: subscriptions (plans the user pinned on the Usage pane)

    func subscriptions() throws -> [CatalogDB.Subscription] {
        try catalog.listSubscriptions()
    }

    func subscription(id: String) throws -> CatalogDB.Subscription? {
        try catalog.subscription(id: id)
    }

    /// Adds a subscription. A second Factory subscription is refused: both would claim the one
    /// Droid row the Factory tool attaches to. A Factory token limit is written straight through
    /// to `usage_limits`, so the Droid window the subscription names becomes a percent meter with
    /// nothing left to disagree with it.
    @discardableResult
    func addSubscription(tool: String, name: String, plan: String, limit: Subscriptions.LimitFields?) throws -> CatalogDB.Subscription {
        if tool == "factory" {
            guard try catalog.factorySubscription() == nil else {
                throw AppError.usage("a Factory subscription already exists; edit it instead")
            }
        }
        let row = CatalogDB.Subscription(
            id: Hex.encode(SecureRandom.bytes(16)),
            tool: tool,
            name: name,
            plan: plan,
            limitAmount: limit?.amount,
            limitUnit: limit?.unit,
            limitPeriod: limit?.period,
            createdAt: UTC.iso(Date())
        )
        try catalog.insertSubscription(row)
        if tool == "factory", let limit, limit.unit == "tokens" {
            try setUsageLimit(source: "droid", window: limit.period, tokens: Int(limit.amount))
        }
        try catalog.bumpCatalogVersion()
        return row
    }

    /// Rewrites a subscription's user fields; the id and the tool stay. A Factory subscription
    /// keeps `usage_limits` (the single source of truth for its Droid window) in step: the window
    /// it no longer names is cleared, the one it newly names is set.
    @discardableResult
    func updateSubscription(id: String, name: String, plan: String, limit: Subscriptions.LimitFields?) throws -> CatalogDB.Subscription {
        guard var row = try catalog.subscription(id: id) else { throw AppError.notFound(id) }
        let oldLimit = row.limit
        row.name = name
        row.plan = plan
        row.limitAmount = limit?.amount
        row.limitUnit = limit?.unit
        row.limitPeriod = limit?.period
        guard try catalog.updateSubscription(row) else { throw AppError.notFound(id) }
        if row.tool == "factory" {
            if let oldLimit, oldLimit.unit == "tokens",
               !(limit?.unit == "tokens" && limit?.period == oldLimit.period)
            {
                try clearUsageLimit(source: "droid", window: oldLimit.period)
            }
            if let limit, limit.unit == "tokens" {
                try setUsageLimit(source: "droid", window: limit.period, tokens: Int(limit.amount))
            }
        }
        try catalog.bumpCatalogVersion()
        return row
    }

    func removeSubscription(id: String) throws {
        guard let row = try catalog.subscription(id: id) else { throw AppError.notFound(id) }
        _ = try catalog.deleteSubscription(id: id)
        // The window limit this subscription drove was the same fact as the subscription; with
        // the row gone it is nobody's limit any more.
        if row.tool == "factory", let limit = row.limit, limit.unit == "tokens" {
            try clearUsageLimit(source: "droid", window: limit.period)
        }
        try catalog.bumpCatalogVersion()
    }

    /// The catalog the dashboard uses: the user's providers first, then the shipped ones, with
    /// hidden entries still present (flagged) so the key table can render their names.
    func providersJSONObject() throws -> [String: Any] {
        let hiddenIDs = try catalog.hiddenProviderIds()
        var groups: [[String: Any]] = [["id": "yours", "name": "Yours"]]
        groups += Providers.builtinGroups().map { group in
            [
                "id": group["id"] ?? "",
                "name": group["name"] ?? group["id"] ?? "",
            ] as [String: Any]
        }
        let custom = (try? catalog.listCustomProviders()) ?? []
        let customIDs = Set(custom.map(\.id))
        var providers: [[String: Any]] = custom.map { $0.jsonObject(hiddenReason: nil) }
        for record in Providers.builtinList() {
            // A custom record with the same id has already replaced it above.
            if customIDs.contains(record.id) { continue }
            let reason = record.hidden ? "app" : hiddenIDs.contains(record.id) ? "user" : nil
            providers.append(record.jsonObject(hiddenReason: reason))
        }
        return ["groups": groups, "providers": providers]
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
            "gateway_cheapest": row.gatewayCheapest,
            "cheapest_supported": CheapestRouting.supports(provider: row.provider),
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
        var target = cached
        target.cheapest = row.gatewayCheapest && CheapestRouting.supports(provider: row.provider)
        return target
    }

    /// Changes where an aggregator sends the key's calls, never what the key can reach, so it
    /// asks for no Touch ID (like the other metadata); the audit log records each change.
    func setGatewayCheapest(name: String, enabled: Bool, caller: String = "dashboard") throws -> CatalogRow {
        let row = try existingRow(name)
        if enabled, !CheapestRouting.supports(provider: row.provider) {
            let provider = Providers.provider(id: row.provider)?.name ?? row.provider
            throw AppError.usage("\(provider) has no per-request price sort, so there is nothing to turn on for \(name)")
        }
        let updated = try catalog.updateGatewayCheapest(name: name, enabled: enabled)
        try? recordKeyEvent(name: name, action: "gateway_cheapest", caller: caller, detail: enabled ? "on" : "off")
        return updated
    }

    /// Enable requires one Touch ID (the same presence check as copy). Secret is held in memory only.
    func setGateway(
        name: String,
        enabled: Bool,
        host: String?,
        caller: String = "dashboard",
        reason: String? = nil,
        presenceChecked: Bool = false
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
            // A batch (keys wrap, client issue with the gateway) asked once for all of its keys,
            // and its own prompt or confirmed plan named each host.
            if !presenceChecked {
                try presence.require(reason: reason ?? Self.gatewayReason(key: name, provider: provider, host: resolved))
            }
            let target = GatewayTarget(
                name: name, secret: try secrets.get(name: name), provider: provider, host: resolved, version: row.version
            )
            gatewayLock.withLock { gatewayCache[name] = target }
            // Turning the gateway on is how a rotated key comes back into use; a pause earned
            // by the old value must not outlive it.
            breaker.reset(key: name)
            let updated = try catalog.updateGatewayHost(name: name, host: resolved)
            try recordKeyEvent(name: name, action: "gateway_enable", caller: caller)
            return updated
        }
        _ = gatewayLock.withLock { gatewayCache.removeValue(forKey: name) }
        revokeGrants(key: name, reason: "gateway_off", caller: caller)
        try recordKeyEvent(name: name, action: "gateway_disable", caller: caller)
        return row
    }

    /// Names where the key will be sent: the prompt is the only line a local process that
    /// rewrote the host cannot cross, so it must show the destination.
    static func gatewayReason(key: String, provider: Providers.Record, host: String) -> String {
        "send the key \(key) to \(provider.name) at \(host) through the gateway"
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

    /// The OS renders the prompt as `"<App>" is trying to <reason>.`, so reasons
    /// start lowercase to read mid-sentence; proper nouns keep their case.
    static func grantReason(task: String, key: String, provider: Providers.Record, host: String, minutes: Int) -> String {
        let span = minutes % 60 == 0 && minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
        return "grant \"\(task)\" the key \(key) for \(provider.name) at \(host), \(span)"
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
        // The unlocked secret was approved for one provider and host. lookupGateway drops it
        // if the catalog changed since (another process can rewrite it), so a changed target
        // needs a fresh approval instead of inheriting the old one.
        // The whole record must match, not just the id: a provider override (no prompt) that
        // keeps the id and host but changes the path or auth header would otherwise point
        // the approved secret at a different request.
        if let target = lookupGateway(name: name), target.provider == provider, target.host == host {
            secret = target.secret
        } else {
            try presence.require(reason: "check \(name) against \(provider.name) at \(host) (read-only)")
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
    }

    // MARK: gateway clients

    /// Issuing a capability to spend a key is a key use, so it asks for presence like copy does.
    /// The token is returned once and only its hash is stored. With `enableGateway` the same
    /// prompt also turns the gateway on, since a token for a key the gateway does not hold
    /// only ever gets 404.
    func issueGatewayClient(
        name: String,
        label: String,
        days: Int? = nil,
        methods: [String]? = nil,
        pathPrefix: String? = nil,
        caller: String = "dashboard",
        enableGateway: Bool = false,
        now: Date = Date()
    ) throws -> (token: String, client: GatewayClient) {
        let row = try existingRow(name)
        let ttlDays = try GatewayClientToken.validateDays(days)
        let allowed = try GatewayClientToken.validateMethods(methods ?? GatewayClientToken.defaultMethods)
        let prefix = try GatewayClientToken.validatePathPrefix(pathPrefix)
        if enableGateway {
            try requireGatewayOwner()
            guard let provider = Providers.provider(id: row.provider), provider.gateway else {
                throw AppError.usage("gateway is not available for provider \(row.provider)")
            }
        }
        guard let host = Self.effectiveHost(row) else {
            throw AppError.usage("set a gateway host for \(name) first (this provider has one host per account)")
        }
        try presence.require(reason: "issue gateway client for \(name) at \(host)")
        if enableGateway {
            _ = try setGateway(name: name, enabled: true, host: nil, caller: caller, presenceChecked: true)
        }
        return try mintGatewayClient(
            name: name, label: label, days: ttlDays, methods: allowed, pathPrefix: prefix, host: host,
            caller: caller, now: now
        )
    }

    /// Mints after presence was already taken by the caller; arguments are validated and `host`
    /// is the key's effective host the caller showed the user.
    private func mintGatewayClient(
        name: String, label: String, days ttlDays: Int, methods allowed: [String], pathPrefix prefix: String?,
        host: String, caller: String, now: Date
    ) throws -> (token: String, client: GatewayClient) {
        let trimmedLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let token = GatewayClientToken.generate()
        let client = try catalog.insertGatewayClient(
            keyName: name,
            label: trimmedLabel,
            tokenHash: GatewayClientToken.hash(token),
            hint: GatewayClientToken.hint(token),
            methods: allowed,
            pathPrefix: prefix,
            host: host,
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

    // MARK: keys wrap

    /// Wrap plans waiting for the user's yes. Each holds the secrets of keys it will add, in
    /// memory only, and dies after `WrapPlan.lifetime`.
    private let wrapLock = NSLock()
    private var wrapPending: [String: (plan: WrapPlan, secrets: [String: String], file: String, expires: Date)] = [:]

    /// One presence prompt covers the whole batch: reading every vault secret to compare with
    /// the file's values here, and later adding keys, turning the gateway on and minting tokens
    /// in `wrapApply`. Values never leave this process; the plan carries names only.
    func wrapPlan(file: String, candidates: [WrapCandidate], now: Date = Date()) throws -> WrapPlan {
        try requireGatewayOwner()
        guard !candidates.isEmpty else { throw AppError.usage("nothing to wrap") }
        guard candidates.count <= WrapPlan.maxCandidates else {
            throw AppError.usage("too many variables to wrap at once (at most \(WrapPlan.maxCandidates))")
        }
        let label = String(file.prefix(120))
        let rows = try catalog.listCatalog()
        try presence.require(reason: "match \(candidates.count) value\(candidates.count == 1 ? "" : "s") in \(label) against the vault and wrap them")
        var vault: [(name: String, secret: Data)] = []
        for row in rows {
            // A catalog row whose Keychain item is gone cannot match; it is not this command's problem.
            if let secret = try? secrets.get(name: row.name) { vault.append((row.name, Data(secret.utf8))) }
        }
        var taken = Set(rows.map(\.name))
        var newByValue: [Data: String] = [:]
        var newSecrets: [String: String] = [:]
        var items: [WrapPlan.Item] = []
        for c in candidates {
            try EnvVar.validate(c.variable)
            let value = Data(c.value.utf8)
            var match: String?
            for entry in vault where ConstantTime.equal(entry.secret, value) { match = match ?? entry.name }
            if let match, let row = rows.first(where: { $0.name == match }) {
                let provider = Providers.provider(id: row.provider)
                guard let provider, provider.gateway else {
                    items.append(.init(variable: c.variable, key: match, provider: row.provider, isNew: false,
                                       skip: "the gateway does not proxy \(provider?.name ?? row.provider)"))
                    continue
                }
                guard row.gatewayHost ?? provider.host != nil else {
                    items.append(.init(variable: c.variable, key: match, provider: row.provider, isNew: false,
                                       skip: "set a gateway host for \(match) first"))
                    continue
                }
                items.append(.init(variable: c.variable, key: match, provider: row.provider, isNew: false, skip: nil,
                                   host: Self.effectiveHost(row)))
                continue
            }
            if let name = newByValue[value] {
                let first = items.first { $0.key == name }
                items.append(.init(variable: c.variable, key: name, provider: first?.provider,
                                   isNew: true, skip: nil, host: first?.host))
                continue
            }
            guard let pid = c.provider, let provider = Providers.provider(id: pid) else {
                items.append(.init(variable: c.variable, key: nil, provider: nil, isNew: true,
                                   skip: "not in the vault and no provider recognised; add it with keys add, then rerun"))
                continue
            }
            guard provider.gateway, provider.host != nil else {
                items.append(.init(variable: c.variable, key: nil, provider: pid, isNew: true,
                                   skip: "the gateway cannot proxy \(provider.name) without a per-key host; add it with keys add"))
                continue
            }
            let name = WrapNames.suggest(provider: pid, hint: c.nameHint, taken: taken)
            taken.insert(name)
            newByValue[value] = name
            newSecrets[name] = c.value
            items.append(.init(variable: c.variable, key: name, provider: pid, isNew: true, skip: nil, host: provider.host))
        }
        let plan = WrapPlan(id: Hex.encode(SecureRandom.bytes(16)), items: items)
        wrapLock.withLock {
            wrapPending = wrapPending.filter { $0.value.expires > now }
            wrapPending[plan.id] = (plan, newSecrets, label, now.addingTimeInterval(WrapPlan.lifetime))
        }
        return plan
    }

    /// Carries out a plan the user said yes to, without another prompt: adds the new keys,
    /// turns the gateway on for every key and mints one client token per key.
    func wrapApply(
        id: String, label: String = "", days: Int? = nil, caller: String = "wrap", now: Date = Date()
    ) throws -> [WrapIssued] {
        try requireGatewayOwner()
        guard let pending = wrapLock.withLock({ wrapPending.removeValue(forKey: id) }), pending.expires > now else {
            throw AppError.usage("the wrap plan expired or was already used; run keys wrap again")
        }
        let ttlDays = try GatewayClientToken.validateDays(days)
        let methods = ["POST", "GET"]
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientLabel = trimmed.isEmpty ? "keys wrap \(pending.file)" : trimmed
        // The plan named each existing key's host and the user said yes to that; if one was
        // retargeted since, its gateway and token would go somewhere the user never saw.
        for item in pending.plan.items where item.skip == nil && !item.isNew {
            guard let key = item.key, let row = try? existingRow(key), Self.effectiveHost(row) == item.host else {
                throw AppError.usage("\(item.key ?? item.variable) changed host since the plan; run keys wrap again")
            }
        }
        var issued: [WrapIssued] = []
        for item in pending.plan.items where item.skip == nil {
            guard let key = item.key, !issued.contains(where: { $0.key == key }) else { continue }
            if item.isNew, let secret = pending.secrets[key], let provider = item.provider {
                try add(name: key, provider: provider, kind: "runtime", notes: "added by keys wrap from \(pending.file)",
                        secret: secret, caller: caller)
            }
            guard let host = item.host, let row = try? existingRow(key), Self.effectiveHost(row) == host else {
                throw AppError.usage("\(key) changed host since the plan; run keys wrap again")
            }
            _ = try setGateway(name: key, enabled: true, host: nil, caller: caller, presenceChecked: true)
            let minted = try mintGatewayClient(
                name: key, label: clientLabel, days: ttlDays, methods: methods, pathPrefix: nil, host: host,
                caller: caller, now: now
            )
            issued.append(WrapIssued(key: key, token: minted.token, clientID: minted.client.id, isNew: item.isNew))
        }
        return issued
    }

    func wrapCancel(id: String) {
        _ = wrapLock.withLock { wrapPending.removeValue(forKey: id) }
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
        // lookupGateway then holds the unlocked target to this same catalog host.
        guard let row = try? catalog.catalogRow(name: name), let host = client.host, host == Self.effectiveHost(row) else {
            return .denied("target_changed")
        }
        guard client.allows(method: method, rest: rest) else { return .denied("out_of_scope") }
        return .allowed(client)
    }

    /// Called once the key resolved and the call is about to be forwarded, so `last_used_at`
    /// means an upstream call, not a rejected attempt.
    func noteGatewayClientUse(_ client: GatewayClient, now: Date = Date()) {
        try? catalog.touchGatewayClient(id: client.id, at: UTC.iso(now))
    }

    /// Audit a denial only for a key that exists; a made-up name must not grow the log. The
    /// caller is the path the request took, as for a call, and `status` is what the gateway
    /// answered (nil for a breaker trip, which answers no call by itself); `keys log` shows both.
    func recordGatewayDenial(name: String, reason: String, status: Int? = nil, via: String? = nil) {
        guard (try? catalog.catalogExists(name: name)) == true else { return }
        try? recordKeyEvent(name: name, action: "gateway_denied", caller: via ?? "gateway", detail: reason, httpStatus: status)
    }

    func recordGatewayUsage(_ row: GatewayUsageRow, grantId: String? = nil, method: String = "POST") throws {
        analytics?.record((200..<400).contains(row.status) ? .gatewaySuccess : .gatewayFailure, durationMS: row.durationMs)
        var event = row.usageEvent()
        if let grantId {
            grants.charge(
                id: grantId, usd: SpendQueries.gatewayUsd(event),
                billable: GrantStore.billable(method: method, status: row.status)
            )
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
            // The caller is the path the call took: "relay" when keys relay replayed it, else
            // the loopback gateway itself (a local agent or a tunnel). Nothing here came from
            // the dashboard, which is what the audit log used to claim.
            try recordKeyEvent(
                name: row.key,
                action: "gateway_call",
                caller: row.via ?? "gateway",
                detail: row.model,
                touchLastUsed: true
            )
        }
    }

    // MARK: - Relay (docs/relay.md)

    static let relayURLMetaKey = "relay_url"
    static let relayKeychainService = "keysreallysafe.relay"
    /// The one account name under the relay's Keychain service.
    static let relaySecretName = "relay"

    struct RelayStatus: Equatable {
        var url: URL?
        /// Last four characters of the stored secret; nil when none is stored.
        var secretHint: String?
        var configured: Bool { url != nil && secretHint != nil }
    }

    private func relayStore() throws -> any SecretStore {
        guard let relaySecrets else { throw AppError.usage("relay storage is not available in this process") }
        return relaySecrets
    }

    /// What is stored, without reading the secret itself out loud: the hint lives in meta.
    func relayStatus() -> RelayStatus {
        let url = (try? catalog.metaValue(Self.relayURLMetaKey)).flatMap { $0 }.flatMap { try? RelayURL.validate($0) }
        let hint = (try? catalog.metaValue(Self.relayURLMetaKey + "_secret_hint")).flatMap { $0 }
        return RelayStatus(url: url, secretHint: hint)
    }

    /// Mints a fresh relay secret for `url`, replacing any earlier one, and returns it once.
    /// One presence check, like issuing a client token.
    func setupRelay(url rawURL: String, caller: String = "cli") throws -> (url: URL, secret: String) {
        let url = try RelayURL.validate(rawURL)
        let store = try relayStore()
        try presence.require(reason: "set up the relay to \(url.host ?? rawURL)")
        let secret = RelaySecret.generate()
        do {
            try store.replace(name: Self.relaySecretName, secret: secret)
        } catch AppError.notFound {
            try store.add(name: Self.relaySecretName, secret: secret)
        }
        try catalog.withTransaction {
            try catalog.setMeta(Self.relayURLMetaKey, url.absoluteString)
            try catalog.setMeta(Self.relayURLMetaKey + "_secret_hint", RelaySecret.hint(secret))
        }
        return (url, secret)
    }

    /// The URL and secret `keys relay` connects with. Presence first: the secret is a
    /// credential and leaves the store only for a connection the person is starting.
    func relayCredentials(urlOverride: String? = nil) throws -> (url: URL, secret: String) {
        let status = relayStatus()
        guard let url = try urlOverride.map(RelayURL.validate) ?? status.url else {
            throw AppError.usage("no relay is set up; run: keys relay setup --url https://<your worker>.workers.dev")
        }
        let store = try relayStore()
        // The hint says whether setup ever ran, so an unconfigured Mac is refused before
        // anyone is asked for Touch ID.
        guard status.secretHint != nil else {
            throw AppError.usage("no relay secret is stored; run: keys relay setup --url \(url.absoluteString)")
        }
        try presence.require(reason: "connect the relay to \(url.host ?? url.absoluteString)")
        let secret: String
        do {
            secret = try store.get(name: Self.relaySecretName)
        } catch AppError.notFound {
            throw AppError.usage("no relay secret is stored; run: keys relay setup --url \(url.absoluteString)")
        }
        guard RelaySecret.looksLikeSecret(secret) else {
            throw AppError.usage("the stored relay secret is not one keys relay setup made; run keys relay setup again")
        }
        return (url, secret)
    }

    var relayLockURL: URL { RelayLock.url(beside: catalog.path) }

    // MARK: relay pairing (docs/proposals/relay-pairing.md)

    /// The enforcement switch in the catalog's meta table. Absent means off, and off is
    /// byte-for-byte the relay behavior from before pairing existed.
    static let relayPairingRequiredMetaKey = "relay_pairing_required"

    func relayPairingRequired() -> Bool {
        (try? catalog.metaValue(Self.relayPairingRequiredMetaKey)) == "1"
    }

    func setRelayPairingRequired(_ required: Bool) throws {
        if required {
            try catalog.setMeta(Self.relayPairingRequiredMetaKey, "1")
        } else {
            try catalog.deleteMeta(Self.relayPairingRequiredMetaKey)
        }
    }

    /// Mints a pairing credential for one remote agent, behind one presence check like a
    /// client token. The credential is returned once; only its hash and hint are stored.
    /// A live label cannot be issued twice — revoking frees it — so a refusal here can never
    /// silently replace an existing pairing.
    func issueRelayPairing(
        label: String,
        keys: [String] = [],
        days: Int? = nil,
        now: Date = Date()
    ) throws -> (credential: String, pairing: RelayPairingRecord) {
        let trimmedLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmedLabel.isEmpty else { throw AppError.usage("a pairing needs a label") }
        let ttlDays = try RelayPairing.validateDays(days)
        var scope: [String] = []
        for key in keys {
            try KeyName.validate(key)
            if !scope.contains(key) { scope.append(key) }
        }
        if try catalog.relayPairings().contains(where: { $0.label == trimmedLabel && $0.revokedAt == nil }) {
            throw AppError.alreadyExists("a live pairing named \(trimmedLabel) already exists; revoke it first")
        }
        try presence.require(reason: "pair a remote agent as \(trimmedLabel)")
        let credential = RelayPairing.generate()
        let pairing = try catalog.insertRelayPairing(
            label: trimmedLabel,
            tokenHash: RelayPairing.hash(credential),
            hint: RelayPairing.hint(credential),
            keys: scope,
            createdAt: UTC.iso(now),
            expiresAt: UTC.iso(now.addingTimeInterval(TimeInterval(ttlDays) * 86_400))
        )
        return (credential, pairing)
    }

    /// The pairing check for one relayed request. It reads the catalog only — credential
    /// hashes, never the Keychain — and never prompts: it runs on the relay's receive loop,
    /// where a Touch ID prompt per request would be both useless and blocking.
    static func verifyRelayPairing(
        catalog: CatalogDB,
        credential: String?,
        keyName: String?,
        now: Date
    ) -> RelayPairingVerdict {
        guard (try? catalog.metaValue(relayPairingRequiredMetaKey)) == "1" else { return .notRequired }
        // Missing, malformed and unknown are one refusal: the wire must not distinguish them.
        guard let credential, RelayPairing.looksLikeCredential(credential) else { return .pairingRequired }
        let hash = RelayPairing.hash(credential)
        // The constant-time compare after the hash lookup keeps the check from answering a
        // timing oracle on the stored hashes, the same pattern GrantStore uses.
        guard let pairing = try? catalog.relayPairing(tokenHash: hash),
              ConstantTime.equal(pairing.tokenHash.utf8, hash.utf8) else { return .pairingRequired }
        if pairing.revokedAt != nil { return .revoked }
        // Expiry is exclusive: a request at exactly expires_at is already expired.
        if let expires = pairing.expiresAt.flatMap({ UTC.parse($0) }), now >= expires { return .expired }
        if !pairing.keys.isEmpty {
            guard let keyName, pairing.keys.contains(keyName) else { return .outOfScope }
        }
        // last_used_at means an accepted request, so a refusal must never move it.
        try? catalog.touchRelayPairing(id: pairing.id, at: UTC.iso(now))
        return .ok
    }

    func verifyRelayPairing(credential: String?, keyName: String?, now: Date = Date()) -> RelayPairingVerdict {
        Self.verifyRelayPairing(catalog: catalog, credential: credential, keyName: keyName, now: now)
    }

    /// The verifier a RelayClient calls per REQUEST frame. It captures the catalog and
    /// nothing else, so the relay holds no Keychain-backed store and no service cycle forms.
    func relayPairingVerifier() -> RelayPairingVerifier {
        let catalog = self.catalog
        return { credential, keyName, now in
            KeysService.verifyRelayPairing(catalog: catalog, credential: credential, keyName: keyName, now: now)
        }
    }

    /// The relay as the menu, the dashboard and `keys relay status` show it.
    struct RelayReport: Equatable {
        var configured: Bool
        var url: URL?
        var host: RelayHost.Status
        /// A relay this process does not run holds the lock: `keys relay` in a Terminal.
        var elsewhere: RelayLock.Held?
        var stayAwake: Bool
    }

    func relayReport() -> RelayReport {
        let stored = relayStatus()
        let host = relayHost.status
        return RelayReport(
            configured: stored.configured,
            url: host.origin ?? stored.url,
            host: host,
            elsewhere: host.on ? nil : RelayLock.holder(at: relayLockURL),
            stayAwake: preferences.relayStayAwake
        )
    }

    /// Turns this process's relay on, with one presence check because the secret leaves the
    /// Keychain, or off. It stays on until turned off or the process quits; nothing turns it
    /// back on at launch, like the gateway forgets its keys.
    func setRelay(enabled: Bool) throws -> RelayReport {
        try requireGatewayOwner()
        try relayToggleLock.withLock {
            guard enabled else {
                relayHost.stop()
                return
            }
            if relayHost.isOn { return }
            // Everything that can be refused without the secret is refused before Touch ID.
            guard relayStatus().configured else {
                throw AppError.usage(
                    "no relay is set up; deploy the Worker (docs/relay.md), then run: keys relay setup --url https://<your worker>.workers.dev"
                )
            }
            guard let port = gatewayLock.withLock({ gatewayListener?.boundPort }) else {
                throw AppError.usage("the gateway is not running in this process, so the relay would have nothing to reach")
            }
            let held: RelayLock
            do {
                held = try RelayLock(at: relayLockURL)
            } catch let busy as RelayLock.Held {
                throw AppError.usage(busy.appRefusal)
            }
            let (origin, secret) = try relayCredentials()
            relayHost.setStayAwake(preferences.relayStayAwake)
            relayHost.start(origin: origin, secret: secret, gatewayPort: port, relayLock: held)
        }
        return relayReport()
    }

    /// Whether the relay keeps the Mac from idle sleep while relayed calls are open. Off
    /// unless the person turns it on; stored, so it applies the next time the relay is on.
    func setRelayStayAwake(_ on: Bool) throws {
        try preferences.setRelayStayAwake(on)
        relayHost.setStayAwake(on)
    }

    /// For quitting: no presence, no owner check, whatever is in progress.
    func stopRelay() {
        relayHost.stop()
    }

    /// Forgets the URL and deletes the secret. The Worker keeps its copy until
    /// `wrangler secret delete RELAY_SECRET`, which the command reminds the person of.
    func resetRelay() throws {
        if let relaySecrets {
            do { try relaySecrets.delete(name: Self.relaySecretName) } catch AppError.notFound {}
        }
        try catalog.withTransaction {
            try catalog.deleteMeta(Self.relayURLMetaKey)
            try catalog.deleteMeta(Self.relayURLMetaKey + "_secret_hint")
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
        try presence.require(reason: "unlock \(name)")
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
        try presence.require(reason: "delete \(name)")
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
        try presence.require(reason: "unlock \(name)")
        try secrets.replace(name: name, secret: secret)
        let version = try catalog.incrementVersion(name: name)
        gatewayLock.withLock {
            gatewayCache[name]?.secret = secret
            gatewayCache[name]?.version = version
        }
        // The pause was earned by the old value; the new one gets to prove itself at once.
        breaker.reset(key: name)
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
        try presence.require(reason: "purge Keysrs")
        guard confirmation == "purge" else {
            throw AppError.usage("type purge to confirm")
        }
        try Self.removeRetiredOptimizerData(catalogDirectory: catalog.path.deletingLastPathComponent())
        try Self.removeRemoteImports(importsDir)
        gatewayLock.withLock { gatewayCache.removeAll() }
        revokeGrants(reason: "purge", caller: "purge")
        try secrets.deleteAll()
        try relaySecrets?.deleteAll()
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

    /// The drop folder holds usage exports the user brought in, and `imported/` inside it keeps
    /// the ones already read; purge promises to leave no Keysrs data behind, so both go.
    static func removeRemoteImports(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func recordKeyEvent(
        name: String,
        action: String,
        caller: String,
        detail: String? = nil,
        httpStatus: Int? = nil,
        touchLastUsed: Bool = false
    ) throws {
        let ts = UTC.iso(Date())
        try catalog.insertKeyEvent(
            ts: ts,
            name: name,
            action: action,
            caller: caller,
            detail: detail,
            httpStatus: httpStatus
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
            // The unlock must still be for this OpenRouter key; a catalog rewritten by another
            // process must not send a different provider's secret to openrouter.ai.
            guard let target = lookupGateway(name: row.name), target.provider.id == "openrouter" else { continue }
            do {
                var snap = try openRouter.fetch(secret: target.secret)
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

    /// The drop folder for remote usage exports, beside the catalog so a test catalog in a
    /// temporary folder never drains the real one.
    var importsDir: URL {
        catalog.path.deletingLastPathComponent().appendingPathComponent("imports", isDirectory: true)
    }

    /// `keys usage import`: the same insert path as an ingest pass, under the ingest lock.
    func importRemote(_ url: URL) throws -> IngestReport {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        let report = try RemoteImport.importFile(url, db: catalog)
        if report.changedRows > 0 {
            try catalog.bumpCatalogVersion()
            try catalog.ensureModelColors()
        }
        return report
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
        var reports = try Ingest.run(
            source: source,
            grokHome: grokHome,
            claudeHome: claudeHome,
            codexHome: codexHome,
            droidHome: droidHome,
            db: catalog
        )
        if source == .all {
            reports.append(("imports", RemoteImport.drain(importsDir, db: catalog)))
        }
        // Local rows that arrived since a remote import make some of its rows duplicates or
        // shrink a session total; settle that on every pass, whichever source was ingested.
        let reconciled = try RemoteImport.reconcile(db: catalog)
        let changed = reports.reduce(reconciled) { $0 + $1.report.changedRows }
        if changed > 0 {
            try catalog.bumpCatalogVersion()
        }
        try catalog.ensureModelColors()
        try catalog.setLastIngestAt(UTC.iso(Date()))
        succeeded = true
        return reports
    }

    /// Key mutations belong to the process serving the gateway, named by the control file
    /// beside this service's catalog; a Terminal `keys rm` must not pull a key out from under it.
    func requireGatewayOwner() throws {
        if let owner = ControlFile.live(at: ControlFile.url(beside: catalog.path)),
           owner.pid != ProcessInfo.processInfo.processIdentifier
        {
            throw AppError.gatewayOwned(owner.pid)
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

    func env(
        name: String,
        variable: String,
        command: [String],
        caller: String = "env"
    ) throws -> ChildExit {
        try env(pairs: [EnvPair(name: name, variable: variable)], command: command, caller: caller)
    }

    /// One presence check covers every pair, so a launch that needs a token id and its secret
    /// asks once. Every key is resolved and read before the command starts: a missing key or a
    /// failed read runs nothing. Each key is audited as a single `keys env` is.
    func env(pairs: [EnvPair], command: [String], caller: String = "env") throws -> ChildExit {
        guard !pairs.isEmpty else { throw AppError.usage("name a key and a variable before --") }
        var resolved: [(row: CatalogRow, variable: String)] = []
        for pair in pairs {
            let row = try existingRow(pair.name)
            let variable = EnvVar.canonicalize(pair.variable)
            try EnvVar.validate(variable)
            if resolved.contains(where: { $0.variable == variable }) {
                throw AppError.usage("\(variable) is given twice")
            }
            resolved.append((row, variable))
        }
        guard !command.isEmpty else { throw AppError.usage("missing command after --") }
        for (row, variable) in resolved {
            let provider = Providers.provider(id: row.provider)
            let where_ = row.gatewayHost ?? provider?.host ?? "no fixed host"
            let line = "keys env: \(row.name) is a \(provider?.name ?? row.provider) key (\(where_)); the raw value goes to \(command[0]) as \(variable)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        var names: [String] = []
        for (row, _) in resolved where !names.contains(row.name) {
            names.append(row.name)
        }
        try presence.require(reason: Self.unlockReason(names))
        var values: [String: String] = [:]
        for name in names {
            values[name] = try secrets.get(name: name)
        }
        for name in names {
            try recordKeyEvent(name: name, action: "env", caller: caller, touchLastUsed: true)
        }
        var extraEnv: [String: String] = [:]
        for (row, variable) in resolved {
            extraEnv[variable] = values[row.name]
        }
        return try runner.run(argv: command, extraEnv: extraEnv)
    }

    /// "unlock a", "unlock 2 keys: a and b": the prompt names every key it opens, the count
    /// first, so a sheet that cuts the list short still shows how many.
    static func unlockReason(_ names: [String]) -> String {
        guard names.count > 1 else { return "unlock \(names.first ?? "")" }
        return "unlock \(names.count) keys: " + names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
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
            weekPeriod: period,
            grokBotHome: grokBotHome,
            droidRow: try DroidUsage.row(catalog: catalog)
        )
        status.lastIngestAt = try catalog.lastIngestAt()
        status.catalogVersion = try catalog.catalogVersion()
        applyOpenRouter(&status)
        // The user's subscriptions take over their placeholders and attach Factory's plan to the
        // Droid row, before the poll hands the rows to the dashboard.
        status.plans = Subscriptions.merge(try catalog.listSubscriptions(), into: status.plans)
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
            clipboard: AppKitClipboard(),
            relaySecrets: KeychainStore(service: KeysService.relayKeychainService)
        )
        service.observeScreenLock()
        service.analytics = ProductAnalytics(catalog: db)
        return service
    }
}
