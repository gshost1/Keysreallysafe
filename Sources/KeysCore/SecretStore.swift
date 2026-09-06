import Foundation
import LocalAuthentication
import Security

protocol SecretStore: Sendable {
    func add(name: String, secret: String) throws
    func get(name: String) throws -> String
    func delete(name: String) throws
    func replace(name: String, secret: String) throws
    func deleteAll() throws
    func confirmPresence(reason: String) throws
    /// Read after the caller already confirmed presence with a task-specific reason.
    func getAfterPresence(name: String) throws -> String
}

extension SecretStore {
    func getAfterPresence(name: String) throws -> String {
        try get(name: name)
    }

    func replace(name: String, secret: String) throws {
        try delete(name: name)
        try add(name: name, secret: secret)
    }

    func deleteAll() throws {}

    func confirmPresence(reason: String) throws {}
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    func add(name: String, secret: String) throws {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        if items[name] != nil { throw AppError.alreadyExists(name) }
        items[name] = secret
    }

    func get(name: String) throws -> String {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        guard let value = items[name] else { throw AppError.notFound(name) }
        return value
    }

    func delete(name: String) throws {
        try KeyName.validate(name)
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: name)
    }

    func replace(name: String, secret: String) throws {
        try KeyName.validate(name)
        guard !secret.isEmpty else { throw AppError.usage("empty secret") }
        lock.lock()
        defer { lock.unlock() }
        guard items[name] != nil else { throw AppError.notFound(name) }
        items[name] = secret
    }

    func deleteAll() throws {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
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
        let box = WaitBox()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            box.finish(success: success, error: error)
        }
        box.wait()
        if let error = box.error as? LAError {
            throw Self.map(error)
        }
        if let error = box.error {
            throw AppError.authUnavailable(error.localizedDescription)
        }
        guard box.success else { throw AppError.authFailed }
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

/// Keychain item plus a presence gate. Add/delete skip the gate (spec: Touch ID on get/copy).
struct GatedSecretStore: SecretStore {
    var inner: any SecretStore
    var presence: any PresenceGate

    func add(name: String, secret: String) throws {
        try inner.add(name: name, secret: secret)
    }

    func get(name: String) throws -> String {
        try presence.require(reason: "Unlock \(name)")
        return try inner.get(name: name)
    }

    func delete(name: String) throws {
        try inner.delete(name: name)
    }

    func replace(name: String, secret: String) throws {
        try inner.replace(name: name, secret: secret)
    }

    func deleteAll() throws {
        try inner.deleteAll()
    }

    func confirmPresence(reason: String) throws {
        try presence.require(reason: reason)
    }

    func getAfterPresence(name: String) throws -> String {
        try inner.get(name: name)
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

/// Wait for an LA callback without deadlocking the main run loop.
private final class WaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sema = DispatchSemaphore(value: 0)
    private var done = false
    var success = false
    var error: Error?

    func finish(success: Bool, error: Error?) {
        lock.lock()
        self.success = success
        self.error = error
        done = true
        lock.unlock()
        sema.signal()
    }

    func wait() {
        if Thread.isMainThread {
            while true {
                lock.lock()
                let done = self.done
                lock.unlock()
                if done { return }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            sema.wait()
        }
    }
}
