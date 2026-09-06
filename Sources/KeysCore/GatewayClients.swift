import CryptoKit
import Foundation
import Security

/// A revocable, expiring capability to route through the gateway with one key.
/// The dashboard's per-launch token is a browser CSRF defense and is never accepted here.
struct GatewayClient: Equatable {
    var id: Int64
    var keyName: String
    var label: String
    var methods: [String]
    /// Upstream path prefix (after the key segment) the client may call, e.g. `v1/messages`.
    /// nil means any path under the key.
    var pathPrefix: String?
    var createdAt: String
    var expiresAt: String
    var revokedAt: String?
    var lastUsedAt: String?
    /// Last four characters of the token, for recognising it in a list. Never the token.
    var hint: String

    func isActive(now: Date) -> Bool {
        if revokedAt != nil { return false }
        guard let exp = UTC.parse(expiresAt) else { return false }
        return exp > now
    }

    func allows(method: String, rest: String) -> Bool {
        guard methods.contains(method.uppercased()) else { return false }
        // A `..` segment would pass a prefix check here and be collapsed upstream into a
        // different path, so no request path with dot segments is in scope for any client.
        guard !GatewayClientToken.hasDotSegment(rest) else { return false }
        guard let pathPrefix, !pathPrefix.isEmpty else { return true }
        return rest == pathPrefix || rest.hasPrefix(pathPrefix + "/")
    }

    func jsonObject(now: Date = Date()) -> [String: Any] {
        [
            "id": id,
            "key": keyName,
            "label": label,
            "methods": methods,
            "path_prefix": pathPrefix as Any? ?? NSNull(),
            "created_at": createdAt,
            "expires_at": expiresAt,
            "revoked_at": revokedAt as Any? ?? NSNull(),
            "last_used_at": lastUsedAt as Any? ?? NSNull(),
            "hint": hint,
            "active": isActive(now: now),
        ]
    }
}

enum GatewayClientToken {
    static let prefix = "ksfc_"
    static let defaultDays = 30
    static let maxDays = 365
    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    static let defaultMethods = ["POST"]

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func looksLikeToken(_ value: String) -> Bool {
        value.hasPrefix(prefix) && value.count == prefix.count + 48
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hint(_ token: String) -> String {
        String(token.suffix(4))
    }

    /// The client presents the capability where its SDK would put the provider key. Any of the
    /// provider auth headers, or `X-KSF-Client`, is accepted. `X-KSF-Token` (the dashboard's
    /// CSRF token) is deliberately not consulted.
    static func extract(headers: [String: String]) -> String? {
        if let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let candidate = parts[1].trimmingCharacters(in: .whitespaces)
                if looksLikeToken(candidate) { return candidate }
            }
        }
        for name in ["x-ksf-client", "x-api-key", "x-goog-api-key", "api-key"] {
            if let value = headers[name]?.trimmingCharacters(in: .whitespaces), looksLikeToken(value) {
                return value
            }
        }
        return nil
    }

    static func validateMethods(_ methods: [String]) throws -> [String] {
        let upper = methods.map { $0.uppercased() }
        guard !upper.isEmpty else { throw AppError.usage("at least one method is required") }
        for m in upper where !allowedMethods.contains(m) {
            throw AppError.usage("unsupported method \(m)")
        }
        return Array(Set(upper)).sorted()
    }

    /// Mirrors `GatewayListener.splitKey`, which strips a trailing slash from the request path.
    static func validatePathPrefix(_ prefix: String?) throws -> String? {
        guard var p = prefix?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        if p.isEmpty { return nil }
        if hasDotSegment(p) || p.contains("?") || p.contains("#") || p.contains("\0") || p.count > 200 {
            throw AppError.usage("invalid path prefix")
        }
        return p
    }

    /// True when any `/`-separated segment is `.` or `..`, before or after percent-decoding.
    static func hasDotSegment(_ path: String) -> Bool {
        for candidate in [path, path.removingPercentEncoding ?? path] {
            for segment in candidate.split(separator: "/", omittingEmptySubsequences: false)
            where segment == "." || segment == ".." {
                return true
            }
        }
        return false
    }

    static func validateDays(_ days: Int?) throws -> Int {
        let d = days ?? defaultDays
        guard d >= 1, d <= maxDays else { throw AppError.usage("expiry must be 1 to \(maxDays) days") }
        return d
    }
}

enum GatewayClientDecision: Equatable {
    case allowed(GatewayClient)
    case denied(String)
}
