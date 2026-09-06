import CryptoKit
import Foundation
import Security

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
    var lastUsedAt: Date?
    var revokedAt: Date?
    var revokeReason: String?

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
            "last_used_at": lastUsedAt.map(UTC.iso) as Any? ?? NSNull(),
            "revoked_at": revokedAt.map(UTC.iso) as Any? ?? NSNull(),
            "revoke_reason": revokeReason as Any? ?? NSNull(),
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
        if allowed.isEmpty { return true }
        var r = rest
        while r.hasPrefix("/") { r.removeFirst() }
        var path = "/" + r
        let pp = "/" + providerPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pp != "/", path == pp || path.hasPrefix(pp + "/") {
            path = String(path.dropFirst(pp.count))
            if path.isEmpty { path = "/" }
        }
        for a in allowed {
            if path == a || path.hasPrefix(a + "/") { return true }
        }
        return false
    }
}

enum GrantDenial: Error, Equatable {
    case required
    case invalid
    case expired
    case revoked
    case keyMismatch
    case method(String)
    case path(String)
    case requestLimit
    case usdLimit
    case targetChanged

    var status: Int {
        switch self {
        case .required, .invalid: return 401
        case .requestLimit, .usdLimit: return 429
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
        case .path(let p): return "path \(p) is outside this grant"
        case .requestLimit: return "grant request limit reached"
        case .usdLimit: return "grant spend limit reached (estimate, checked after each call)"
        case .targetChanged: return "key provider or host changed since the grant; issue a new one"
        }
    }
}

enum GrantToken {
    static let prefix = "ksf_"

    static func generate(id: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        return prefix + id + "_" + base64url(Data(bytes))
    }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
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
            maxUsd: request.maxUsd
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
        guard let stored = hashes[id], Self.constantTimeEqual(stored, presented) else {
            return .failure(.invalid)
        }
        if g.isExpired(at: now) { return .failure(.expired) }
        if g.key != key { return .failure(.keyMismatch) }
        if g.host != host { return .failure(.targetChanged) }
        let m = method.uppercased()
        if !g.methods.contains(m) { return .failure(.method(m)) }
        if !GrantPath.matches(rest: rest, prefix: providerPrefix, allowed: g.paths) {
            return .failure(.path("/" + rest))
        }
        if let cap = g.maxRequests, g.requests >= cap { return .failure(.requestLimit) }
        if let cap = g.maxUsd, g.usd >= cap { return .failure(.usdLimit) }
        g.requests += 1
        g.lastUsedAt = now
        grants[id] = g
        return .success(g)
    }

    /// Add an estimated cost after a call finished. Enforcement is post-hoc: one call can overshoot.
    func charge(id: String, usd: Double?) {
        guard let usd, usd > 0 else { return }
        lock.lock()
        if var g = grants[id] {
            g.usd += usd
            grants[id] = g
        }
        lock.unlock()
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

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}
