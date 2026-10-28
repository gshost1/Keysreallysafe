import Foundation

/// The app's pending-request store for grants asked over MCP, the `wrapPending`
/// pattern (an `NSLock`-guarded dictionary keyed by id, because `APIHandler.handle`
/// runs on listener threads). A record is one `request_grant` ask between the
/// create call and the one Touch ID prompt's resolution: it holds the state a
/// `grant_status` poll reports and — only between approval and the first delivery —
/// the token's plaintext, because `GrantStore` keeps only its hash.
///
/// The store is memory and nothing else: a restart drops every pending request
/// (`not_found`), nothing token-shaped is ever persisted, and screen lock's revoke
/// path is unaffected by it. The one clock every TTL, retention and expiry decision
/// reads is injectable (`inject`), so a test advances time instead of sleeping;
/// production never touches the seam and reads the wall clock.
final class MCPPendingGrants: @unchecked Sendable {
    /// How long a request stays resolvable, from its create moment. Independent of
    /// the grant's own `minutes`: the pending phase is how long the *ask* lives,
    /// not how long the grant does.
    static let ttl: TimeInterval = 300
    /// How many unresolved requests may exist at once. Over the cap the create is a
    /// plain refusal — an agent's runaway loop cannot queue prompts on the user.
    static let liveCap = 8
    /// How long a terminal record (delivered, denied, expired) keeps answering
    /// `not expired` polls before it is pruned to the honest `not_found`.
    static let retention: TimeInterval = 300

    /// One request's state. `approved` is the only state that holds a token, and
    /// `claim` moves it to `delivered` in the same locked step that reads it, so the
    /// token is handed over exactly once however many polls race.
    enum Resolution {
        case pending
        case approved(token: String, grant: Grant)
        case delivered
        case denied(reason: String)
        case expired
    }

    struct Record {
        var id: String
        var key: String
        var createdAt: Date
        var expiresAt: Date
        var resolution: Resolution
        /// When the request left `pending` (approval, denial, expiry), for retention.
        var resolvedAt: Date?
        /// When the one delivery happened, for the delivered records' retention.
        var deliveredAt: Date?
    }

    /// What one `claim(id:)` poll hands its caller, after the consume-once flip.
    enum Claim {
        case pending
        case approved(token: String, grant: Grant)
        case delivered
        case denied(reason: String)
        case expired
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var clock: () -> Date = { Date() }

    /// The test seam for the store's one clock. Production never calls it.
    func inject(now: @escaping () -> Date) {
        lock.lock()
        clock = now
        lock.unlock()
    }

    /// Stores a new request, refusing over the live cap. Prunes first, so an
    /// expired record frees its slot before the cap is counted.
    func insert(key: String) throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        let now = clock()
        var live = 0
        for record in records.values {
            if case .pending = record.resolution, record.expiresAt > now { live += 1 }
        }
        guard live < Self.liveCap else {
            throw AppError.usage(
                "too many grant requests are waiting; wait for one to resolve or expire, then ask again"
            )
        }
        var id = GrantToken.newID()
        while records[id] != nil { id = GrantToken.newID() }
        let record = Record(
            id: id, key: key, createdAt: now,
            expiresAt: now.addingTimeInterval(Self.ttl),
            resolution: .pending, resolvedAt: nil, deliveredAt: nil
        )
        records[id] = record
        return record
    }

    /// The approval thread's success path: only a still-pending record takes it.
    func approve(id: String, token: String, grant: Grant) {
        lock.lock()
        defer { lock.unlock() }
        guard records[id] != nil, case .pending = records[id]?.resolution else { return }
        records[id]?.resolution = .approved(token: token, grant: grant)
        records[id]?.resolvedAt = clock()
    }

    /// The approval thread's denial path: only a still-pending record takes it.
    func deny(id: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard records[id] != nil, case .pending = records[id]?.resolution else { return }
        records[id]?.resolution = .denied(reason: reason)
        records[id]?.resolvedAt = clock()
    }

    /// Whether the request is still live — the `stillValid` answer issuance re-checks
    /// after its prompt, so an approval that lands after the TTL never mints.
    func isLive(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[id], case .pending = record.resolution else { return false }
        return record.expiresAt > clock()
    }

    /// One poll, with the consume-once flip inside the same lock the read holds:
    /// exactly one racing poller can see `approved` carrying the token.
    func claim(id: String) -> Claim? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        guard let record = records[id] else { return nil }
        switch record.resolution {
        case .pending:
            return .pending
        case .approved(let token, let grant):
            records[id]?.resolution = .delivered
            records[id]?.deliveredAt = clock()
            return .approved(token: token, grant: grant)
        case .delivered:
            return .delivered
        case .denied(let reason):
            return .denied(reason: reason)
        case .expired:
            return .expired
        }
    }

    /// Every record for the status-only listing — states and reasons, never a token.
    func statuses() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return records.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// The record as the store holds it (expiry transitions applied), the white-box
    /// view that proves no token survives delivery.
    func snapshot(id: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return records[id]
    }

    /// Expiry and pruning, under the caller's lock. A record dies at its TTL wherever
    /// it stood: pending fails closed, and an approved-but-undelivered token is
    /// dropped — nobody may still collect an ask the caller let lapse. Terminal
    /// records keep answering polls for a retention window, then are pruned so the
    /// honest answer for them is the house `not_found`.
    private func refreshLocked() {
        let now = clock()
        let snapshot = records
        var prune: [String] = []
        for (id, record) in snapshot {
            var updated = record
            if now >= updated.expiresAt {
                switch updated.resolution {
                case .pending, .approved:
                    updated.resolution = .expired
                    updated.resolvedAt = updated.expiresAt
                    records[id] = updated
                case .delivered, .denied, .expired:
                    break
                }
            }
            let terminalSince: Date? = switch updated.resolution {
            case .delivered: updated.deliveredAt
            case .denied, .expired: updated.resolvedAt
            case .pending, .approved: nil
            }
            if let since = terminalSince, now.timeIntervalSince(since) > Self.retention {
                prune.append(id)
            }
        }
        for id in prune { records.removeValue(forKey: id) }
    }
}

extension KeysService {
    /// Creates a pending grant request for the MCP grants surface: validates
    /// everything the ask can get wrong SYNCHRONOUSLY (a second live site, an
    /// unknown key, a non-proxiable provider, an unresolvable host, the request's
    /// own shape, every profile over-ceiling case) and refuses before any prompt,
    /// then hands the ask to the one approval prompt and returns the request's id
    /// while that prompt is up. The answer the caller gets is pending and tokenless;
    /// the token, if the user approves, is delivered on exactly one later poll.
    ///
    /// The folder is the MCP process's project folder — the app canonicalizes it,
    /// derives the label and get-or-creates the `projects` row; the calling process
    /// never writes one. The label is the only project fact that reaches the prompt.
    func requestMCPGrant(
        name: String,
        request raw: GrantRequest,
        profile profileName: String?,
        specified: GrantSpecified,
        folder: String
    ) throws -> String {
        // The owner check runs at CREATE time: a second live site is a clear error
        // here, never a denial the user has to cancel a prompt over.
        try requireGatewayOwner()
        let row = try existingRow(name)
        let request = try raw.validated()
        guard let provider = Providers.provider(id: row.provider), provider.gateway else {
            throw AppError.usage("gateway is not available for provider \(row.provider); a grant cannot be issued")
        }
        guard (row.gatewayHost ?? provider.host) != nil else {
            throw AppError.usage("set a gateway host for \(name) first (this provider has one host per account)")
        }
        // The profile's bounds are checked here so an over-ceiling ask consumes no
        // Touch ID; issuance re-runs `bounded` after the prompt against the profile
        // as it stands then, so a grant can only ever be bounded tighter than the
        // user read at approval.
        if let profileName {
            let profile = try self.profile(name: profileName)
            _ = try profile.bounded(
                request: request, specified: specified, key: name, providerPrefix: provider.pathPrefix
            )
        }
        let project = try resolveProject(folder: folder)
        let record = try mcpPendingGrants.insert(key: name)
        let armed = DispatchSemaphore(value: 0)
        runMCPApproval(
            id: record.id, name: name, request: request, profile: profileName, specified: specified,
            projectLabel: project.label, armed: armed
        )
        // Answer while the prompt is provably up: the arming gate fires when
        // `require` is entered (or when a fail-fast gate resolves instantly), so
        // the caller holds a real pending state, never a claim the app cannot back.
        _ = armed.wait(timeout: .now() + 2)
        return record.id
    }

    /// One request's poll, rendered as the payload `grant_status` relays: pending
    /// (tokenless), approved (the token plus the exact `keysGrant` connection fields
    /// — the only time a token is returned), approved with `delivered: true` (no
    /// token), denied with its reason, expired, or the house not-found for an id
    /// this process never issued or has already pruned.
    func mcpGrantStatus(id raw: String) throws -> [String: Any] {
        guard raw.count == 8, raw.allSatisfy({ $0.isHexDigit }) else {
            throw AppError.notFound("pending grant request")
        }
        guard let claim = mcpPendingGrants.claim(id: raw) else {
            throw AppError.notFound("pending grant request \(raw)")
        }
        switch claim {
        case .pending:
            return ["status": "pending", "id": raw]
        case .approved(let token, let grant):
            var body = grant.jsonObject()
            body["status"] = "approved"
            body["token"] = token
            body["gateway_url"] = "http://127.0.0.1:\(GatewayListener.port)/\(grant.key)"
            let prefix = Providers.provider(id: grant.provider)?.pathPrefix ?? ""
            body["base_url"] = "http://127.0.0.1:\(GatewayListener.port)/\(grant.key)" + prefix
            body["auth_header"] = Providers.provider(id: grant.provider)?.authHeader ?? "Authorization"
            return body
        case .delivered:
            return ["status": "approved", "id": raw, "delivered": true]
        case .denied(let reason):
            return ["status": "denied", "id": raw, "reason": reason]
        case .expired:
            return ["status": "expired", "id": raw]
        }
    }

    /// The no-id status listing: every request's id, key and state — never a token
    /// in any state, so a status poller cannot collect another session's approval.
    func mcpGrantStatuses() -> [[String: Any]] {
        mcpPendingGrants.statuses().map { record in
            var entry: [String: Any] = ["id": record.id, "key": record.key]
            switch record.resolution {
            case .pending:
                entry["status"] = "pending"
            case .approved:
                entry["status"] = "approved"
            case .delivered:
                entry["status"] = "approved"
                entry["delivered"] = true
            case .denied(let reason):
                entry["status"] = "denied"
                entry["reason"] = reason
            case .expired:
                entry["status"] = "expired"
            }
            return entry
        }
    }

    /// The approval half of a pending request: the existing issuance, behind its
    /// one prompt, on the app's own queue — `requestMCPGrant` has already validated,
    /// so this thread blocks only in `require`. The record is settled to whatever
    /// the user did; an approval that lands after the request's TTL never mints
    /// (`stillValid` is the store's own live check), and a denial is terminal.
    private func runMCPApproval(
        id: String,
        name: String,
        request: GrantRequest,
        profile: String?,
        specified: GrantSpecified,
        projectLabel: String,
        armed: DispatchSemaphore
    ) {
        let promptGate = MCPArmingGate(inner: presence) { armed.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let issued = try self.issueGrant(
                    name: name,
                    request: request,
                    profile: profile,
                    specified: specified,
                    caller: "mcp",
                    projectLabel: projectLabel,
                    gate: promptGate,
                    stillValid: { [weak self] in self?.mcpPendingGrants.isLive(id: id) ?? false }
                )
                self.mcpPendingGrants.approve(id: id, token: issued.token, grant: issued.grant)
            } catch {
                // An expired (or already-resolved) request keeps its honest state:
                // a late approval must never mint, and a denial must not overwrite
                // the expiry the caller already read.
                if self.mcpPendingGrants.isLive(id: id) {
                    self.mcpPendingGrants.deny(id: id, reason: Self.mcpDenialReason(error) ?? "failed")
                }
            }
            // Whatever the outcome, the create call that armed this thread is free.
            armed.signal()
        }
    }

    /// The three honest denial reasons a presence outcome maps to. Anything else
    /// that can strike after validation (a second site appearing, a changed target)
    /// is "failed": the ask resolved without issuing, and that is what it was.
    private static func mcpDenialReason(_ error: Error) -> String? {
        guard let app = error as? AppError else { return nil }
        switch app {
        case .authCancelled: return "cancelled"
        case .authFailed: return "failed"
        case .authUnavailable: return "unavailable"
        default: return nil
        }
    }
}

/// The seam that tells the create route the approval prompt is up: `require` fires
/// `onEnter` immediately before handing the prompt to the real gate, so the route
/// can answer `{status:"pending"}` while the prompt is provably in flight (and with
/// a fail-fast gate, after the resolution already landed — either way the caller
/// never holds a pending state the app cannot back).
final class MCPArmingGate: PresenceGate, @unchecked Sendable {
    private let inner: any PresenceGate
    private let onEnter: () -> Void

    init(inner: any PresenceGate, onEnter: @escaping () -> Void) {
        self.inner = inner
        self.onEnter = onEnter
    }

    func require(reason: String) throws {
        onEnter()
        try inner.require(reason: reason)
    }
}
