import CryptoKit
import Foundation

/// Trial and license state. A license is an Ed25519-signed token that the app
/// checks offline against the public key below; nothing here contacts a server.
/// Only the usage meter's ingestion and the issue of new gateway grants depend
/// on it. The vault, copy, reveal, env, rotate, purge and removal never do: a
/// lapsed trial can always get its keys back out.
enum LicenseConfiguration {
    /// Public half of the Ed25519 key whose private seed lives in the login
    /// Keychain of the build Mac as `keysrs.license-signing`, and in the site
    /// Worker's secrets so checkout can issue keys.
    static let publicKeyBase64 = "JBXZvujkBlQx/ckElnqn4/ove5ZT95thR6OkLZaNscw="
    static let trialDays = 14
    /// A license covers one major version; a later major asks for a new one.
    static let major = 1
    static let buyURL = "https://keysrs.com/#pricing"
}

struct LicensePayload: Codable, Equatable, Sendable {
    let v: Int
    let id: String
    let email: String
    let iat: Int
    let major: Int
}

enum LicenseError: Error, Equatable {
    case malformed
    case badSignature
    case unsupportedVersion
    case wrongMajor(Int)
    case futureDated
}

/// `keysrs1.<base64url payload JSON>.<base64url signature>`, signed over the
/// ASCII bytes of `keysrs1.<payload>`. Ed25519 is deterministic, so the same
/// payload always yields the same key and a buyer can fetch it again.
enum LicenseKey {
    static let prefix = "keysrs1"

    static func verify(_ raw: String, publicKeyBase64: String = LicenseConfiguration.publicKeyBase64,
                       now: Date = Date()) throws -> LicensePayload {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard key.utf8.count <= 2_048, parts.count == 3, parts[0] == prefix,
              let payloadData = base64urlDecode(String(parts[1])),
              let signature = base64urlDecode(String(parts[2])), signature.count == 64,
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseError.malformed
        }
        let signed = Data("\(prefix).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signed) else { throw LicenseError.badSignature }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData),
              payload.id.utf8.count <= 128, !payload.id.isEmpty,
              payload.email.utf8.count <= 254, payload.email.contains("@") else {
            throw LicenseError.malformed
        }
        guard payload.v == 1 else { throw LicenseError.unsupportedVersion }
        guard payload.major == LicenseConfiguration.major else { throw LicenseError.wrongMajor(payload.major) }
        // A day of clock skew is tolerated; anything further is not a key we issued yet.
        guard Double(payload.iat) <= now.timeIntervalSince1970 + 86_400 else { throw LicenseError.futureDated }
        return payload
    }

    /// Used by tests and the support tooling; the app itself never signs.
    static func sign(_ payload: LicensePayload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadPart = base64url(try encoder.encode(payload))
        let signature = try privateKey.signature(for: Data("\(prefix).\(payloadPart)".utf8))
        return "\(prefix).\(payloadPart).\(base64url(signature))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

struct LicenseStatus: Equatable, Sendable {
    enum State: String, Sendable { case trial, licensed, expired }
    let state: State
    let trialStartedAt: Date
    let trialEndsAt: Date
    let daysLeft: Int
    let license: LicensePayload?

    var isActive: Bool { state != .expired }

    var json: [String: Any] {
        var object: [String: Any] = [
            "state": state.rawValue,
            "trial_started": UTC.iso(trialStartedAt),
            "trial_ends": UTC.iso(trialEndsAt),
            "days_left": daysLeft,
            "major": LicenseConfiguration.major,
            "buy_url": LicenseConfiguration.buyURL,
        ]
        if let license {
            object["license"] = ["id": license.id, "email": license.email,
                                 "issued": UTC.iso(Date(timeIntervalSince1970: Double(license.iat)))]
        } else {
            object["license"] = NSNull()
        }
        return object
    }

    /// What a lapsed feature says. One sentence, no scolding.
    static let lapsedMessage = "trial ended; enter a license in the dashboard or buy one at \(LicenseConfiguration.buyURL) to keep measuring and issuing grants (your keys stay available)"
}

/// Trial start and license live in the private local catalog's `meta` table,
/// beside the analytics preference, so they follow the catalog and vanish with
/// `keys purge`. Catalog transactions serialise the CLI and dashboard processes.
final class LicenseManager: @unchecked Sendable {
    static let trialKey = "license_trial_started_at"
    static let licenseKey = "license_key"
    private let catalog: CatalogDB
    private let now: @Sendable () -> Date
    private let publicKeyBase64: String

    init(catalog: CatalogDB, publicKeyBase64: String = LicenseConfiguration.publicKeyBase64,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.publicKeyBase64 = publicKeyBase64
        self.now = now
    }

    /// The first status call starts the trial; nothing else ever moves it.
    func status() throws -> LicenseStatus {
        try catalog.withTransaction {
            let current = now()
            let started: Date
            // The stored start is authoritative even if the clock now reads earlier:
            // winding the clock back must not hand out a fresh trial.
            if let stored = try catalog.metaValue(Self.trialKey), let date = UTC.parse(stored) {
                started = date
            } else {
                started = current
                try catalog.setMeta(Self.trialKey, UTC.iso(current))
            }
            let ends = started.addingTimeInterval(Double(LicenseConfiguration.trialDays) * 86_400)
            let daysLeft = max(0, Int((ends.timeIntervalSince(current) / 86_400).rounded(.up)))
            if let stored = try catalog.metaValue(Self.licenseKey),
               let payload = try? LicenseKey.verify(stored, publicKeyBase64: publicKeyBase64, now: current) {
                return LicenseStatus(state: .licensed, trialStartedAt: started, trialEndsAt: ends, daysLeft: daysLeft, license: payload)
            }
            let state: LicenseStatus.State = current < ends ? .trial : .expired
            return LicenseStatus(state: state, trialStartedAt: started, trialEndsAt: ends, daysLeft: daysLeft, license: nil)
        }
    }

    var isActive: Bool { (try? status().isActive) ?? true }

    @discardableResult
    func activate(_ key: String) throws -> LicenseStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try LicenseKey.verify(trimmed, publicKeyBase64: publicKeyBase64, now: now())
        try catalog.withTransaction { try catalog.setMeta(Self.licenseKey, trimmed) }
        return try status()
    }

    @discardableResult
    func deactivate() throws -> LicenseStatus {
        try catalog.withTransaction { try catalog.setMeta(Self.licenseKey, "") }
        return try status()
    }

    /// Ingestion and grant issue call this; the vault does not.
    func requireActive() throws {
        guard try status().isActive else { throw AppError.usage(LicenseStatus.lapsedMessage) }
    }
}
