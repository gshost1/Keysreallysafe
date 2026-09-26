import Foundation
import LocalAuthentication
import Security

/// Storage only. Presence (Touch ID or the login password) is `KeysService.presence`,
/// asked before every read, so no store can hand out a secret on its own.
protocol SecretStore: Sendable {
    func add(name: String, secret: String) throws
    func get(name: String) throws -> String
    func delete(name: String) throws
    func replace(name: String, secret: String) throws
    func deleteAll() throws
}

/// File-based generic-password query. An ad-hoc CLI cannot use the
/// data-protection keychain (`errSecMissingEntitlement` / -34018) and the
/// file-based keychain does not honor `kSecAttrAccessControl` (add then
/// returns `errSecAuthFailed`, which the UI called Touch ID cancelled).
/// User-presence is `PresenceGate` on get, not a Keychain ACL.
enum KeychainQuery {
    static func item(service: String, name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }
}

protocol PresenceGate: Sendable {
    func require(reason: String) throws
}

/// Touch ID or Mac password on every get/copy. New context each call; no reuse duration.
/// Failures are distinguished: unavailable (no GUI session, sandbox, nothing enrolled),
/// cancelled (user, app or system), and failed (wrong password / biometry mismatch).
struct LocalPresenceGate: PresenceGate {
    func require(reason: String) throws {
        let context = LAContext()
        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
            throw AppError.authUnavailable(Self.unavailableReason(evalError))
        }
        let done = MainSafeWait<(Bool, Error?)>()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            done.finish((success, error))
        }
        let (success, error) = done.wait()
        if let error = error as? LAError {
            throw Self.map(error)
        }
        if let error {
            throw AppError.authUnavailable(error.localizedDescription)
        }
        guard success else { throw AppError.authFailed }
    }

    static func map(_ error: LAError) -> AppError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return .authCancelled
        case .authenticationFailed, .userFallback:
            return .authFailed
        case .passcodeNotSet:
            return .authUnavailable("no login password is set on this Mac")
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            return .authUnavailable("Touch ID is not available; the login password prompt could not be shown")
        case .notInteractive:
            return .authUnavailable(
                "no interactive session (sandbox or headless); run keys from a Terminal outside the sandbox")
        default:
            return .authUnavailable("LocalAuthentication error \(error.code.rawValue)")
        }
    }

    private static func unavailableReason(_ error: NSError?) -> String {
        if let error, let la = LAError(_nsError: error) as LAError? {
            if case .authUnavailable(let m) = map(la) { return m }
        }
        return "this Mac has no Touch ID or password to unlock keys"
    }
}

/// macOS Keychain generic passwords. Presence is the gate, not a Keychain ACL.
struct KeychainStore: SecretStore {
    var service: String = "keysreallysafe"

    func add(name: String, secret: String) throws {
        try KeyName.validate(name)
        var query = KeychainQuery.item(service: service, name: name)
        query[kSecValueData as String] = Data(secret.utf8)
        try Self.finish(SecItemAdd(query as CFDictionary, nil), op: "add", name: name)
    }

    func get(name: String) throws -> String {
        try KeyName.validate(name)
        var query = KeychainQuery.item(service: service, name: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try Self.finish(status, op: "read", name: name)
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw AppError.keychain("invalid secret encoding")
        }
        return secret
    }

    func delete(name: String) throws {
        try KeyName.validate(name)
        let query = KeychainQuery.item(service: service, name: name)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try Self.finish(status, op: "delete", name: name)
    }

    func replace(name: String, secret: String) throws {
        try KeyName.validate(name)
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        let query = KeychainQuery.item(service: service, name: name)
        let attrs: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        try Self.finish(status, op: "update", name: name)
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 0.9.0 and 0.9.1 kept the removed optimizer's encryption key under its own service.
        _ = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "keysreallysafe.optimizer"] as CFDictionary)
        if status == errSecItemNotFound { return }
        try Self.finish(status, op: "delete", name: service)
    }

    private static func finish(_ status: OSStatus, op: String, name: String) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw AppError.alreadyExists(name)
        case errSecItemNotFound:
            throw AppError.notFound(name)
        case errSecUserCanceled, errSecAuthFailed:
            throw AppError.authFailed
        case errSecInteractionNotAllowed:
            throw AppError.keychain("\(op) needs a login session (restart keys dashboard from Terminal)")
        default:
            throw AppError.keychain("\(op) failed (\(status))")
        }
    }
}
