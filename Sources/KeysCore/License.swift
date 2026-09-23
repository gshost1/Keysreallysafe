import CryptoKit
import Foundation
import IOKit

/// Trial and license state. A license is an Ed25519-signed key checked against
/// the public key below, activated once per Mac at keysrs.com (at most `seats`
/// Macs) and re-confirmed every `checkInDays`; between check-ins everything is
/// offline. Only the usage meter's ingestion and the issue of new gateway grants
/// depend on it. The vault, copy, reveal, env, rotate, purge and removal never
/// do: a lapsed trial can always get its keys back out.
enum LicenseConfiguration {
    /// Public half of the Ed25519 key whose private seed lives in the login
    /// Keychain of the build Mac as `keysrs.license-signing`, and in the site
    /// Worker's secrets so checkout can issue keys and activations.
    static let publicKeyBase64 = "JBXZvujkBlQx/ckElnqn4/ove5ZT95thR6OkLZaNscw="
    static let trialDays = 14
    /// A license covers one major version; a later major asks for a new one.
    static let major = 1
    static let seats = 2
    static let buyURL = "https://keysrs.com/#pricing"
    static let activateURL = URL(string: "https://keysrs.com/api/license/activate")!
    static let deactivateURL = URL(string: "https://keysrs.com/api/license/deactivate")!
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

/// A `<prefix>.<base64url payload JSON>.<base64url signature>` token signed over
/// the ASCII bytes of `<prefix>.<payload>`. The prefix is part of what is signed,
/// so a token of one kind never verifies as another.
enum SignedToken {
    static func open(_ raw: String, prefix: String, publicKeyBase64: String) throws -> Data {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 2_048, parts.count == 3, parts[0] == prefix,
              let payloadData = LicenseKey.base64urlDecode(String(parts[1])),
              let signature = LicenseKey.base64urlDecode(String(parts[2])), signature.count == 64,
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseError.malformed
        }
        guard publicKey.isValidSignature(signature, for: Data("\(prefix).\(parts[1])".utf8)) else {
            throw LicenseError.badSignature
        }
        return payloadData
    }

    static func sign<T: Encodable>(_ payload: T, prefix: String, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadPart = LicenseKey.base64url(try encoder.encode(payload))
        let signature = try privateKey.signature(for: Data("\(prefix).\(payloadPart)".utf8))
        return "\(prefix).\(payloadPart).\(LicenseKey.base64url(signature))"
    }
}

/// `keysrs1.…`: the key a buyer receives. Ed25519 is deterministic, so the same
/// payload always yields the same key and a buyer can fetch it again.
enum LicenseKey {
    static let prefix = "keysrs1"

    static func verify(_ raw: String, publicKeyBase64: String = LicenseConfiguration.publicKeyBase64,
                       now: Date = Date()) throws -> LicensePayload {
        let payloadData = try SignedToken.open(raw, prefix: prefix, publicKeyBase64: publicKeyBase64)
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
        try SignedToken.sign(payload, prefix: prefix, privateKey: privateKey)
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

/// `keysrsa1.…`: keysrs.com's answer to an activation or check-in, binding one
/// license to one install until `exp`. `due` is when the next check-in is asked
/// for; the gap to `exp` is the offline grace period.
struct ActivationPayload: Codable, Equatable, Sendable {
    let v: Int
    let lid: String
    let iid: String
    let iat: Int
    let due: Int
    let exp: Int
}

enum ActivationToken {
    static let prefix = "keysrsa1"

    static func verify(_ raw: String, publicKeyBase64: String = LicenseConfiguration.publicKeyBase64) throws -> ActivationPayload {
        let data = try SignedToken.open(raw, prefix: prefix, publicKeyBase64: publicKeyBase64)
        guard let payload = try? JSONDecoder().decode(ActivationPayload.self, from: data), payload.v == 1,
              payload.iat <= payload.due, payload.due <= payload.exp else {
            throw LicenseError.malformed
        }
        return payload
    }

    static func sign(_ payload: ActivationPayload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try SignedToken.sign(payload, prefix: prefix, privateKey: privateKey)
    }
}

// MARK: - keysrs.com

enum LicenseServerError: Error, Equatable {
    case seatLimit(Int)
    case revoked
    case rejected
    case unreachable

    /// What the dashboard and CLI say. One sentence each, with the way out.
    var message: String {
        switch self {
        case .seatLimit(let seats):
            return "This license is already active on \(seats) Macs. Remove one on your license page (the link is in your purchase email), or write to support@keysrs.com."
        case .revoked:
            return "This license was revoked after a refund or dispute. Write to support@keysrs.com if that is a mistake."
        case .rejected:
            return "keysrs.com did not accept this key. Paste the whole line from your purchase email."
        case .unreachable:
            return "Couldn't reach keysrs.com to confirm the license. Check the internet connection and try again."
        }
    }
}

/// The only network calls the license makes: activation (which is also the
/// 30-day check-in) and freeing this Mac's seat. They carry the key, a random
/// install id and the hardware model name, nothing else.
protocol LicenseServer: Sendable {
    func activate(key: String, installID: String, model: String) throws -> String
    func deactivate(key: String, installID: String)
}

struct HTTPLicenseServer: LicenseServer {
    func activate(key: String, installID: String, model: String) throws -> String {
        let (status, body) = try post(LicenseConfiguration.activateURL, ["key": key, "install_id": installID, "model": model])
        switch status {
        case 200:
            guard let token = body["activation"] as? String else { throw LicenseServerError.unreachable }
            return token
        case 409: throw LicenseServerError.seatLimit((body["seats"] as? Int) ?? LicenseConfiguration.seats)
        case 403: throw LicenseServerError.revoked
        case 400: throw LicenseServerError.rejected
        default: throw LicenseServerError.unreachable
        }
    }

    func deactivate(key: String, installID: String) {
        _ = try? post(LicenseConfiguration.deactivateURL, ["key": key, "install_id": installID])
    }

    private func post(_ url: URL, _ object: [String: String]) throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, Data)?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 20) == .timedOut { task.cancel(); throw LicenseServerError.unreachable }
        guard let (status, data) = result else { throw LicenseServerError.unreachable }
        return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
}

/// A random id for this install, kept in the login Keychain beside a local hash
/// of this Mac's hardware UUID. If the Keychain is carried to another Mac
/// (Migration Assistant), the hash no longer matches and that Mac gets its own
/// id, so it needs its own seat. The hash never leaves the Mac.
protocol InstallIdentity: Sendable {
    func installID() throws -> String
}

struct KeychainInstallIdentity: InstallIdentity {
    static let service = "keysrs.install"
    static let account = "install-id"

    func installID() throws -> String {
        let machine = Self.machineHash()
        if let stored = try read() {
            let parts = stored.split(separator: "|").map(String.init)
            if parts.count == 2, UUID(uuidString: parts[0]) != nil, parts[1] == machine { return parts[0] }
        }
        let id = UUID().uuidString.lowercased()
        try write("\(id)|\(machine)")
        return id
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    private func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw AppError.usage("install id unavailable (\(status))") }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw AppError.usage("install id unavailable (\(status))") }
    }

    static func machineHash() -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(entry) }
        let uuid = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? "unknown"
        return SHA256.hash(data: Data("keysrs.install.\(uuid)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `Mac15,6` and the like: shown on the buyer's license page so they can tell their Macs apart.
    static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0, size < 64 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = String(cString: bytes)
        return model.range(of: "^[A-Za-z0-9,._ -]{1,32}$", options: .regularExpression) != nil ? model : "Mac"
    }
}

// MARK: - status

struct LicenseStatus: Equatable, Sendable {
    /// `unconfirmed`: a key is stored but this Mac holds no current activation
    /// (never activated, or no check-in within the grace period) and the trial
    /// is over. It behaves like `expired` and says why.
    enum State: String, Sendable { case trial, licensed, expired, unconfirmed }
    let state: State
    let trialStartedAt: Date
    let trialEndsAt: Date
    let daysLeft: Int
    let license: LicensePayload?
    var activation: ActivationPayload? = nil
    /// Why the last activation or check-in failed, if it did.
    var problem: LicenseServerError? = nil

    var isActive: Bool { state == .trial || state == .licensed }

    var json: [String: Any] {
        var object: [String: Any] = [
            "state": state.rawValue,
            "trial_started": UTC.iso(trialStartedAt),
            "trial_ends": UTC.iso(trialEndsAt),
            "days_left": daysLeft,
            "major": LicenseConfiguration.major,
            "seats": LicenseConfiguration.seats,
            "buy_url": LicenseConfiguration.buyURL,
        ]
        if let license {
            var info: [String: Any] = ["id": license.id, "email": license.email,
                                       "issued": UTC.iso(Date(timeIntervalSince1970: Double(license.iat)))]
            if let activation {
                info["check_in_due"] = UTC.iso(Date(timeIntervalSince1970: Double(activation.due)))
                info["valid_until"] = UTC.iso(Date(timeIntervalSince1970: Double(activation.exp)))
            }
            object["license"] = info
        } else {
            object["license"] = NSNull()
        }
        object["problem"] = problem.map { ["code": "\($0)", "message": $0.message] } ?? NSNull()
        return object
    }

    /// What a lapsed feature says. One sentence, no scolding.
    static let lapsedMessage = "trial ended; enter a license in the dashboard or buy one at \(LicenseConfiguration.buyURL) to keep measuring and issuing grants (your keys stay available)"
    static let unconfirmedMessage = "the license needs confirming with keysrs.com (once every 30 days); connect to the internet, or open the dashboard to retry (your keys stay available)"
}

/// Trial start, license key and activation live in the private local catalog's
/// `meta` table, beside the analytics preference, so they follow the catalog and
/// vanish with `keys purge`. Catalog transactions serialise the CLI and
/// dashboard processes. An activation copied with the catalog to another Mac
/// names the other install and does not count there.
final class LicenseManager: @unchecked Sendable {
    static let trialKey = "license_trial_started_at"
    static let licenseKey = "license_key"
    static let activationKey = "license_activation"
    static let problemKey = "license_problem"
    /// How often the menu bar may retry a failed or due check-in.
    static let retryInterval: TimeInterval = 60 * 60
    private let catalog: CatalogDB
    private let now: @Sendable () -> Date
    private let publicKeyBase64: String
    private let server: any LicenseServer
    private let identity: any InstallIdentity
    private let model: String
    private let lock = NSLock()
    private var cachedInstallID: String?
    private var lastCheckIn: Date?

    init(catalog: CatalogDB, publicKeyBase64: String = LicenseConfiguration.publicKeyBase64,
         now: @escaping @Sendable () -> Date = { Date() },
         server: any LicenseServer = HTTPLicenseServer(),
         identity: any InstallIdentity = KeychainInstallIdentity(),
         model: String = KeychainInstallIdentity.model()) {
        self.catalog = catalog
        self.publicKeyBase64 = publicKeyBase64
        self.now = now
        self.server = server
        self.identity = identity
        self.model = model
    }

    /// The first status call starts the trial; nothing else ever moves it.
    func status() throws -> LicenseStatus {
        let current = now()
        let started = try trialStart(current)
        let ends = started.addingTimeInterval(Double(LicenseConfiguration.trialDays) * 86_400)
        let daysLeft = max(0, Int((ends.timeIntervalSince(current) / 86_400).rounded(.up)))
        let trialState: LicenseStatus.State = current < ends ? .trial : .expired
        let problem = try catalog.metaValue(Self.problemKey).flatMap(Self.decodeProblem)
        guard let key = try storedKey(), let payload = try? LicenseKey.verify(key, publicKeyBase64: publicKeyBase64, now: current) else {
            return LicenseStatus(state: trialState, trialStartedAt: started, trialEndsAt: ends, daysLeft: daysLeft, license: nil)
        }
        if let activation = try currentActivation(for: payload, at: current) {
            return LicenseStatus(state: .licensed, trialStartedAt: started, trialEndsAt: ends, daysLeft: daysLeft,
                                 license: payload, activation: activation, problem: problem)
        }
        // A key this Mac has not confirmed still leaves the trial running.
        return LicenseStatus(state: trialState == .trial ? .trial : .unconfirmed, trialStartedAt: started, trialEndsAt: ends,
                             daysLeft: daysLeft, license: payload, problem: problem)
    }

    /// The stored start is authoritative even if the clock now reads earlier:
    /// winding the clock back must not hand out a fresh trial. Status is read on
    /// every menu bar refresh and ingest, so only the one-time write takes the
    /// catalog's write lock; the transaction re-reads so two processes agree.
    private func trialStart(_ current: Date) throws -> Date {
        if let stored = try catalog.metaValue(Self.trialKey), let date = UTC.parse(stored) { return date }
        return try catalog.withTransaction {
            if let stored = try catalog.metaValue(Self.trialKey), let date = UTC.parse(stored) { return date }
            try catalog.setMeta(Self.trialKey, UTC.iso(current))
            return current
        }
    }

    private func storedKey() throws -> String? {
        try catalog.metaValue(Self.licenseKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func installID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedInstallID { return cachedInstallID }
        let id = try identity.installID()
        cachedInstallID = id
        return id
    }

    private func currentActivation(for license: LicensePayload, at date: Date) throws -> ActivationPayload? {
        guard let token = try catalog.metaValue(Self.activationKey), !token.isEmpty,
              let activation = try? ActivationToken.verify(token, publicKeyBase64: publicKeyBase64),
              activation.lid == license.id,
              let id = try? installID(), activation.iid == id,
              date.timeIntervalSince1970 < Double(activation.exp) else { return nil }
        return activation
    }

    var isActive: Bool { (try? status().isActive) ?? true }

    /// Checks the key locally, then activates this Mac at keysrs.com. Nothing is
    /// stored unless both succeed, so a refused key leaves the Mac as it was.
    @discardableResult
    func activate(_ key: String) throws -> LicenseStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try LicenseKey.verify(trimmed, publicKeyBase64: publicKeyBase64, now: now())
        let token = try confirm(key: trimmed, license: payload)
        try catalog.withTransaction {
            try catalog.setMeta(Self.licenseKey, trimmed)
            try catalog.setMeta(Self.activationKey, token)
            try catalog.setMeta(Self.problemKey, "")
        }
        return try status()
    }

    private func confirm(key: String, license: LicensePayload) throws -> String {
        let id: String
        do { id = try installID() } catch { throw LicenseServerError.unreachable }
        let token = try server.activate(key: key, installID: id, model: model)
        guard let activation = try? ActivationToken.verify(token, publicKeyBase64: publicKeyBase64),
              activation.lid == license.id, activation.iid == id else {
            throw LicenseServerError.rejected
        }
        return token
    }

    /// The menu bar calls this on its refresh timer, off the main thread. It
    /// contacts keysrs.com only when a stored key has no activation yet or its
    /// check-in is due, and at most once an hour. A refusal (revoked, or its
    /// seat given to another Mac) ends this Mac's activation at once; being
    /// offline changes nothing until the grace period runs out.
    func checkInIfDue() {
        let current = now()
        lock.lock()
        if let lastCheckIn, current.timeIntervalSince(lastCheckIn) < Self.retryInterval { lock.unlock(); return }
        lock.unlock()
        guard let key = try? storedKey(),
              let payload = try? LicenseKey.verify(key, publicKeyBase64: publicKeyBase64, now: current) else { return }
        if let activation = try? currentActivation(for: payload, at: current),
           current.timeIntervalSince1970 < Double(activation.due) { return }
        lock.lock(); lastCheckIn = current; lock.unlock()
        do {
            let token = try confirm(key: key, license: payload)
            try? catalog.withTransaction {
                try catalog.setMeta(Self.activationKey, token)
                try catalog.setMeta(Self.problemKey, "")
            }
        } catch let error as LicenseServerError where error != .unreachable {
            try? catalog.withTransaction {
                try catalog.setMeta(Self.activationKey, "")
                try catalog.setMeta(Self.problemKey, "\(error)")
            }
        } catch {
            // Offline: keep the current activation until it expires.
        }
    }

    /// Forgets the key on this Mac and frees its seat at keysrs.com (best effort).
    @discardableResult
    func deactivate() throws -> LicenseStatus {
        if let key = try storedKey(), let id = try? installID() {
            server.deactivate(key: key, installID: id)
        }
        try catalog.withTransaction {
            try catalog.setMeta(Self.licenseKey, "")
            try catalog.setMeta(Self.activationKey, "")
            try catalog.setMeta(Self.problemKey, "")
        }
        return try status()
    }

    /// Ingestion and grant issue call this; the vault does not.
    func requireActive() throws {
        let status = try status()
        guard status.isActive else {
            throw AppError.usage(status.state == .unconfirmed ? LicenseStatus.unconfirmedMessage : LicenseStatus.lapsedMessage)
        }
    }

    private static func decodeProblem(_ raw: String) -> LicenseServerError? {
        switch raw {
        case "revoked": return .revoked
        case "rejected": return .rejected
        case _ where raw.hasPrefix("seatLimit"): return .seatLimit(LicenseConfiguration.seats)
        default: return nil
        }
    }
}
