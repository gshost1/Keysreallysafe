import CryptoKit
import Foundation

/// A grant is one presence-approved, time-boxed capability to use one key through the
/// gateway. The client presents the grant token as its API key; the gateway swaps in the
/// real secret. Grants live only in the gateway owner's memory: a restart, screen lock,
/// gateway-off or revoke makes them fail closed.
struct Grant: Equatable, Sendable {
    static let defaultMinutes = 30
    static let maxMinutes = 24 * 60
    static let allMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var id: String
    var key: String
    var provider: String
    var host: String
    var task: String
    var methods: Set<String>
    var paths: [String]
    var createdAt: Date
    var expiresAt: Date
    var maxRequests: Int?
    var maxUsd: Double?
    var requests: Int = 0
    var usd: Double = 0
    /// Billable calls that came back with no price. `usd` leaves them out, so on a grant with
    /// `maxUsd` one of these means the cap can no longer be enforced (see `authorize`).
    var unpricedCalls: Int = 0
    var lastUsedAt: Date?
    var revokedAt: Date?
    var revokeReason: String?
    /// The profile this grant was issued under, if any. Display and audit only: the gateway's
    /// request path never reads it, and a grant keeps its scope after its profile is edited
    /// or removed — the profile was consulted once, at issuance.
    var profile: String?
    /// True exactly when the issuing profile was flagged unattended. A label for `keys grants`
    /// and the dashboard; it changes nothing about enforcement, and the grant still dies on
    /// screen lock, restart, revoke and expiry like any other.
    var unattended: Bool = false
    /// The window `issue` opened, in minutes. Renewal re-opens exactly this span from the
    /// renewal moment; it is never re-asked and never compounded.
    var windowMinutes: Int
    /// How many times this grant has been renewed in place.
    var renewals: Int = 0
    /// When the latest renewal happened; nil until the first.
    var renewedAt: Date?

    var isRevoked: Bool { revokedAt != nil }
    func isExpired(at now: Date) -> Bool { now >= expiresAt }
    func isActive(at now: Date) -> Bool { !isRevoked && !isExpired(at: now) }

    var status: String {
        if isRevoked { return "revoked" }
        if isExpired(at: Date()) { return "expired" }
        return "active"
    }

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "key": key,
            "provider": provider,
            "host": host,
            "task": task,
            "methods": methods.sorted(),
            "paths": paths,
            "created_at": UTC.iso(createdAt),
            "expires_at": UTC.iso(expiresAt),
            "max_requests": maxRequests as Any? ?? NSNull(),
            "max_usd": maxUsd as Any? ?? NSNull(),
            "requests": requests,
            "usd": usd,
            "unpriced_calls": unpricedCalls,
            "last_used_at": lastUsedAt.map(UTC.iso) as Any? ?? NSNull(),
            "revoked_at": revokedAt.map(UTC.iso) as Any? ?? NSNull(),
            "revoke_reason": revokeReason as Any? ?? NSNull(),
            "profile": profile as Any? ?? NSNull(),
            "unattended": unattended,
            "window_minutes": windowMinutes,
            "renewals": renewals,
            "renewed_at": renewedAt.map(UTC.iso) as Any? ?? NSNull(),
            "status": status,
        ]
    }
}

/// What the client asked for. Validated before any prompt.
struct GrantRequest {
    var task: String
    var minutes: Int = Grant.defaultMinutes
    var methods: Set<String> = Grant.allMethods
    var paths: [String] = []
    var maxRequests: Int?
    var maxUsd: Double?

    func validated() throws -> GrantRequest {
        var r = self
        r.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.task.isEmpty { r.task = "agent task" }
        if r.task.count > 120 { throw AppError.usage("task is too long (120 characters)") }
        guard minutes >= 1, minutes <= Grant.maxMinutes else {
            throw AppError.usage("minutes must be between 1 and \(Grant.maxMinutes)")
        }
        r.methods = Set(methods.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if r.methods.isEmpty { throw AppError.usage("at least one method is required") }
        if let bad = r.methods.first(where: { !Grant.allMethods.contains($0) }) {
            throw AppError.usage("unknown method \(bad)")
        }
        r.paths = try paths.map { try GrantPath.normalize($0) }.filter { !$0.isEmpty }
        if let maxRequests, maxRequests < 1 { throw AppError.usage("max requests must be at least 1") }
        if let maxUsd, !(maxUsd > 0) { throw AppError.usage("max usd must be positive") }
        return r
    }
}

/// Which of a grant ask's bounds the caller named, as opposed to the ones `GrantRequest` fills
/// with defaults. Only `issueGrant` reads it, and only under a profile: a named bound must sit
/// inside the profile (tighten, never widen), an unnamed one takes the profile's value as its
/// default. The surfaces that know what was actually said — the dashboard API body, the CLI
/// flags — build it; with no profile it is never consulted and nothing changes.
struct GrantSpecified: Equatable, Sendable {
    var minutes = false
    var methods = false
    var paths = false
    var maxRequests = false
    var maxUsd = false
}

enum GrantPath {
    /// A grant path is a prefix under the provider's path prefix, e.g. `/models`.
    static func normalize(_ raw: String) throws -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "" }
        if p.contains("?") || p.contains("..") || p.contains(" ") { throw AppError.usage("invalid path \(raw)") }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `rest` is the client's path after `/<key>`; may or may not repeat the provider prefix.
    static func matches(rest: String, prefix providerPrefix: String, allowed: [String]) -> Bool {
        // The path is forwarded as-is, and an upstream that collapses `/models/../responses`
        // would serve a scope the grant never named. Long-lived clients refuse these too.
        if GatewayClientToken.hasDotSegment(rest) { return false }
        if allowed.isEmpty { return true }
        let path = relative(rest: rest, prefix: providerPrefix)
        for a in scopes(allowed, prefix: providerPrefix) {
            if a == "/" || path == a || path.hasPrefix(a + "/") { return true }
        }
        return false
    }

    /// Grant paths are relative to the provider prefix, but `/v1/messages` is what an SDK
    /// sends and what people type; it was refused with "outside this grant (allows
    /// /v1/messages)". A scope that repeats the prefix means the same scope without it.
    private static func scopes(_ allowed: [String], prefix providerPrefix: String) -> [String] {
        allowed.map { relative(rest: $0, prefix: providerPrefix) }
    }

    /// When a denied path holds an allowed scope further in (`/v1/models` against
    /// `/models`), the caller almost always meant that longer scope: the provider serves
    /// under a segment the catalog prefix doesn't cover. Only suggested, never widened.
    static func suggestion(rest: String, prefix providerPrefix: String, allowed: [String]) -> String? {
        if GatewayClientToken.hasDotSegment(rest) { return nil }
        let segments = relative(rest: rest, prefix: providerPrefix).split(separator: "/").map(String.init)
        for a in scopes(allowed, prefix: providerPrefix) {
            let scope = a.split(separator: "/").map(String.init)
            guard !scope.isEmpty, scope.count < segments.count else { continue }
            for start in 1...(segments.count - scope.count) where Array(segments[start..<start + scope.count]) == scope {
                return "/" + segments[0..<start + scope.count].joined(separator: "/")
            }
        }
        return nil
    }

    private static func relative(rest: String, prefix providerPrefix: String) -> String {
        var r = rest
        while r.hasPrefix("/") { r.removeFirst() }
        var path = "/" + r
        let pp = "/" + providerPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pp != "/", path == pp || path.hasPrefix(pp + "/") {
            path = String(path.dropFirst(pp.count))
            if path.isEmpty { path = "/" }
        }
        return path
    }
}

enum GrantDenial: Error, Equatable {
    case required
    case invalid
    case expired
    case revoked
    case keyMismatch
    case method(String)
    case path(String, allowed: [String] = [], suggestion: String? = nil)
    case requestLimit
    case usdLimit
    case usdUnpriced
    case targetChanged

    var status: Int {
        switch self {
        case .required, .invalid: return 401
        case .requestLimit, .usdLimit, .usdUnpriced: return 429
        default: return 403
        }
    }

    var code: String {
        switch self {
        case .required: return "grant_required"
        case .invalid: return "grant_invalid"
        case .expired: return "grant_expired"
        case .revoked: return "grant_revoked"
        case .keyMismatch: return "grant_key_mismatch"
        case .method: return "grant_method_not_allowed"
        case .path: return "grant_path_not_allowed"
        case .requestLimit: return "grant_request_limit"
        case .usdLimit: return "grant_usd_limit"
        case .usdUnpriced: return "grant_usd_unpriced"
        case .targetChanged: return "grant_target_changed"
        }
    }

    var message: String {
        switch self {
        case .required:
            return "this gateway needs a grant token as the API key; run: keys grant <key> --task \"...\""
        case .invalid: return "grant token not recognised (restarted engine, or a typo)"
        case .expired: return "grant expired; issue a new one with keys grant"
        case .revoked: return "grant was revoked"
        case .keyMismatch: return "grant is for a different key"
        case .method(let m): return "method \(m) is outside this grant"
        case .path(let p, let allowed, let suggestion):
            var text = "path \(p) is outside this grant"
            if !allowed.isEmpty { text += " (allows \(allowed.joined(separator: ", ")))" }
            if let suggestion {
                text += "; grant paths are relative to the base URL, so for this call issue a grant with --paths \(suggestion)"
            }
            return text
        case .requestLimit: return "grant request limit reached"
        case .usdLimit: return "grant spend limit reached (checked after each call)"
        case .usdUnpriced:
            return "a call on this grant came back without a price, so its spend limit can no longer be enforced; issue a new grant (keys grant), or use --max-requests for a provider that reports no cost"
        case .targetChanged: return "key provider or host changed since the grant; issue a new one"
        }
    }

    /// Extra fields for the gateway's JSON error, so an agent can retry without guessing.
    var details: [String: Any] {
        guard case .path(_, let allowed, let suggestion) = self else { return [:] }
        var out: [String: Any] = ["allowed_paths": allowed]
        if let suggestion { out["suggested_paths"] = suggestion }
        return out
    }
}

/// A refused renewal. Every case is raised before the single presence prompt a renewal
/// costs, so a refusal consumes no Touch ID; the messages point at `keys grant`, the only
/// way to different bounds.
enum RenewalError: LocalizedError, Equatable {
    case notFound(String)
    case revoked(id: String, reason: String)
    case targetChanged
    case scopeImmutable

    var errorDescription: String? { message }

    var code: String {
        switch self {
        case .notFound: return "renew_not_found"
        case .revoked: return "renew_revoked"
        case .targetChanged: return "renew_target_changed"
        case .scopeImmutable: return "renew_scope_immutable"
        }
    }

    var status: Int {
        switch self {
        case .notFound: return 404
        case .revoked, .targetChanged: return 409
        case .scopeImmutable: return 400
        }
    }

    var message: String {
        switch self {
        case .notFound(let id):
            return "no grant \(id) to renew; a grant lives only in the running site's memory, so issue a new one with keys grant"
        case .revoked(let id, let reason):
            return "grant \(id) was revoked (\(reason)) and a revoked grant is never renewable; issue a new one with keys grant"
        case .targetChanged:
            return "the key or its host changed since this grant was issued, so it cannot be renewed; issue a new one with keys grant"
        case .scopeImmutable:
            return "renewal re-approves the grant exactly as it is and takes no scope fields; for different bounds issue a new grant with keys grant"
        }
    }
}

enum GrantToken {
    static let prefix = "ksf_"

    static func generate(id: String) -> String {
        prefix + id + "_" + base64url(Data(SecureRandom.bytes(32)))
    }

    static func newID() -> String {
        Hex.encode(SecureRandom.bytes(4))
    }

    static func idOf(_ token: String) -> String? {
        guard token.hasPrefix(prefix) else { return nil }
        let body = token.dropFirst(prefix.count)
        guard let idx = body.firstIndex(of: "_") else { return nil }
        let id = String(body[..<idx])
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func looksLikeToken(_ s: String) -> Bool {
        idOf(s.trimmingCharacters(in: .whitespaces)) != nil
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// In-memory grant table. Never persisted; hashes only, never tokens.
final class GrantStore: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private var hashes: [String: Data] = [:]

    func issue(
        key: String,
        provider: String,
        host: String,
        request: GrantRequest,
        profile: String? = nil,
        unattended: Bool = false,
        now: Date = Date()
    ) -> (grant: Grant, token: String) {
        var id = GrantToken.newID()
        lock.lock()
        while grants[id] != nil { id = GrantToken.newID() }
        let token = GrantToken.generate(id: id)
        let grant = Grant(
            id: id,
            key: key,
            provider: provider,
            host: host,
            task: request.task,
            methods: request.methods,
            paths: request.paths,
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(request.minutes * 60)),
            maxRequests: request.maxRequests,
            maxUsd: request.maxUsd,
            profile: profile,
            unattended: unattended,
            windowMinutes: request.minutes
        )
        grants[id] = grant
        hashes[id] = GrantToken.hash(token)
        lock.unlock()
        return (grant, token)
    }

    func list(includeInactive: Bool = false, now: Date = Date()) -> [Grant] {
        lock.lock()
        defer { lock.unlock() }
        return grants.values
            .filter { includeInactive || $0.isActive(at: now) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func grant(id: String) -> Grant? {
        lock.lock()
        defer { lock.unlock() }
        return grants[id]
    }

    @discardableResult
    func revoke(id: String, reason: String, now: Date = Date()) -> Grant? {
        lock.lock()
        defer { lock.unlock() }
        guard var g = grants[id] else { return nil }
        if g.revokedAt == nil {
            g.revokedAt = now
            g.revokeReason = reason
            grants[id] = g
        }
        hashes.removeValue(forKey: id)
        return g
    }

    /// Revoke every active grant, or only those for `key`. Returns the grants touched.
    @discardableResult
    func revokeAll(key: String? = nil, reason: String, now: Date = Date()) -> [Grant] {
        lock.lock()
        defer { lock.unlock() }
        var touched: [Grant] = []
        for (id, var g) in grants where g.isActive(at: now) && (key == nil || g.key == key) {
            g.revokedAt = now
            g.revokeReason = reason
            grants[id] = g
            hashes.removeValue(forKey: id)
            touched.append(g)
        }
        return touched
    }

    /// Re-open a grant in place for another window of its ORIGINAL lifetime: expiry moves to
    /// `now + windowMinutes`, the usage counters reset, and the renewal is counted. Identity,
    /// scope, caps and the stored token hash are untouched. A revoked grant is never renewable —
    /// `revoke` deletes the token hash, so a hashless row can never authorize again and must
    /// never be revived; expiry keeps the hash, which is what makes an expired grant renewable
    /// at all. Called only from `KeysService.renewGrant`, after its single presence prompt.
    @discardableResult
    func renew(id: String, now: Date = Date()) throws -> Grant {
        lock.lock()
        defer { lock.unlock() }
        guard var g = grants[id] else { throw RenewalError.notFound(id) }
        guard !g.isRevoked, hashes[id] != nil else {
            throw RenewalError.revoked(id: id, reason: g.revokeReason ?? "revoked")
        }
        g.expiresAt = now.addingTimeInterval(TimeInterval(g.windowMinutes * 60))
        g.requests = 0
        g.usd = 0
        g.unpricedCalls = 0
        g.lastUsedAt = nil
        g.renewals += 1
        g.renewedAt = now
        grants[id] = g
        return g
    }

    /// Authorize one request and count it. `rest` is the path after `/<key>`.
    func authorize(
        token: String?,
        key: String,
        host: String,
        method: String,
        rest: String,
        providerPrefix: String,
        now: Date = Date()
    ) -> Result<Grant, GrantDenial> {
        guard let token, !token.isEmpty else { return .failure(.required) }
        guard let id = GrantToken.idOf(token) else { return .failure(.invalid) }
        let presented = GrantToken.hash(token)
        lock.lock()
        defer { lock.unlock() }
        guard var g = grants[id] else { return .failure(.invalid) }
        if g.isRevoked { return .failure(.revoked) }
        guard let stored = hashes[id], ConstantTime.equal(stored, presented) else {
            return .failure(.invalid)
        }
        if g.isExpired(at: now) { return .failure(.expired) }
        if g.key != key { return .failure(.keyMismatch) }
        if g.host != host { return .failure(.targetChanged) }
        let m = method.uppercased()
        if !g.methods.contains(m) { return .failure(.method(m)) }
        if !GrantPath.matches(rest: rest, prefix: providerPrefix, allowed: g.paths) {
            let suggestion = GrantPath.suggestion(rest: rest, prefix: providerPrefix, allowed: g.paths)
            return .failure(.path("/" + rest, allowed: g.paths, suggestion: suggestion))
        }
        if let cap = g.maxRequests, g.requests >= cap { return .failure(.requestLimit) }
        if let cap = g.maxUsd, g.usd >= cap { return .failure(.usdLimit) }
        // Fail closed: once a call's cost is unknown, `usd` is a floor, not the spend, and a cap
        // checked against it would let the grant run on unbounded (as it did, to the cap and
        // past it, with Vercel calls that were never priced).
        if g.maxUsd != nil, g.unpricedCalls > 0 { return .failure(.usdUnpriced) }
        g.requests += 1
        g.lastUsedAt = now
        grants[id] = g
        return .success(g)
    }

    /// Add a finished call's cost: the provider's receipt, else a list-price estimate, else
    /// nil. Enforcement is post-hoc, so one call (or several in flight together) can overshoot.
    /// An unpriced call counts only when it could have been billed (`billable`).
    func charge(id: String, usd: Double?, billable: Bool = true) {
        lock.lock()
        if var g = grants[id] {
            if let usd {
                if usd > 0 { g.usd += usd }
            } else if billable {
                g.unpricedCalls += 1
            }
            grants[id] = g
        }
        lock.unlock()
    }

    /// Whether a call with no price may still have cost money. A provider bills a generation it
    /// answered; an error status or a read (model lists, balances) is not one. A call that never
    /// got an answer is left out too, which is the one place this errs toward the caller.
    static func billable(method: String, status: Int) -> Bool {
        !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) && (200..<300).contains(status)
    }

    /// Drop revoked/expired grants older than `age` so the table stays small.
    func prune(olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) {
        lock.lock()
        for (id, g) in grants where !g.isActive(at: now) {
            let end = g.revokedAt ?? g.expiresAt
            if now.timeIntervalSince(end) > age {
                grants.removeValue(forKey: id)
                hashes.removeValue(forKey: id)
            }
        }
        lock.unlock()
    }
}
