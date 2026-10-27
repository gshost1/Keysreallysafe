import CryptoKit
import Foundation

/// Pairing between the user and one remote agent (docs/proposals/relay-pairing.md): the agent
/// presents a `ksfp_…` credential on every relayed request and the Mac's relay checks it before
/// the request body is buffered. Pairing is an additional gate — the gateway's grant and client
/// token checks still run on every replayed request — and it is off unless the user turns
/// `relay_pairing_required` on.

/// One row of the catalog's `relay_pairings` table. Only the credential's hash and hint are
/// stored, never the credential — the same posture as `gateway_clients`, so the catalog (not
/// the Keychain) is the right home.
struct RelayPairingRecord: Equatable {
    var id: Int64
    var label: String
    var tokenHash: String
    /// Last four characters of the credential, for recognising it in a list. Never the credential.
    var hint: String
    /// Key names this pairing may reach; empty means all keys.
    var keys: [String]
    var createdAt: String
    var expiresAt: String?
    var revokedAt: String?
    var lastUsedAt: String?

    func isActive(now: Date) -> Bool {
        if revokedAt != nil { return false }
        guard let expiresAt, let exp = UTC.parse(expiresAt) else { return true }
        return exp > now
    }
}

/// The `ksfp_…` credential helpers, mirroring `GatewayClientToken`: 24 random bytes,
/// hex-encoded; SHA-256 hash stored; last-4 hint shown.
enum RelayPairing {
    static let prefix = "ksfp_"
    static let defaultDays = 30
    static let maxDays = 365
    /// The agent header carrying the credential, lower-cased as headers are framed.
    static let header = "x-ksf-pair"

    static func generate() -> String {
        prefix + Hex.encode(SecureRandom.bytes(24))
    }

    static func looksLikeCredential(_ value: String) -> Bool {
        value.hasPrefix(prefix) && value.count == prefix.count + 48
    }

    static func hash(_ credential: String) -> String {
        Hex.encode(SHA256.hash(data: Data(credential.utf8)))
    }

    static func hint(_ credential: String) -> String {
        String(credential.suffix(4))
    }

    static func validateDays(_ days: Int?) throws -> Int {
        let d = days ?? defaultDays
        guard d >= 1, d <= maxDays else { throw AppError.usage("expiry must be 1 to \(maxDays) days") }
        return d
    }
}

/// What the pairing check concludes about one relayed request. Missing, malformed and unknown
/// credentials are deliberately one verdict: the wire must not distinguish "never issued".
enum RelayPairingVerdict: Equatable {
    /// Enforcement is off; the request takes today's path.
    case notRequired
    case ok
    case pairingRequired
    case expired
    case revoked
    case outOfScope
}

/// The check RelayClient runs on each REQUEST frame, injected so the terminal relay, the app's
/// relay host and tests share it. It must read the catalog (hashes) only: never the Keychain,
/// never a presence prompt — a relayed request cannot wait for Touch ID on the receive loop.
typealias RelayPairingVerifier = @Sendable (_ credential: String?, _ keyName: String?, _ now: Date) -> RelayPairingVerdict
