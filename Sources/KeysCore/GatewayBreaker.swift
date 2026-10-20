import Foundation

/// Stops an agent's retry loop against a revoked or wrong key. After `threshold` consecutive
/// upstream 401/403 answers for one key the gateway answers the next calls itself for
/// `cooldown`, so the provider is not hammered and the caller gets one clear reason instead
/// of the same denial forever. Any other upstream status resets the count; turning the
/// gateway on again for the key clears the pause. In memory only, like the gateway's secrets.
final class GatewayBreaker: @unchecked Sendable {
    static let threshold = 5
    static let cooldown: TimeInterval = 60
    static let code = "upstream_auth_blocked"

    enum Verdict: Equatable {
        case closed
        case open(retryAfterSeconds: Int)
    }

    private struct State {
        var consecutive = 0
        var openUntil: Date?
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether a call with `key` may go upstream right now. Once the cool-down has passed the
    /// next call is let through as a probe; one more 401/403 re-opens the pause at once.
    func check(key: String) -> Verdict {
        lock.lock()
        defer { lock.unlock() }
        guard let until = states[key]?.openUntil else { return .closed }
        let remaining = until.timeIntervalSince(now())
        if remaining <= 0 { return .closed }
        return .open(retryAfterSeconds: max(1, Int(remaining.rounded(.up))))
    }

    /// Feeds one upstream status. True exactly when this status tripped the breaker, so the
    /// caller can write one audit entry per trip rather than one per blocked call.
    @discardableResult
    func record(key: String, status: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State()
        guard status == 401 || status == 403 else {
            states[key] = nil
            return false
        }
        state.consecutive = min(Self.threshold, state.consecutive + 1)
        var tripped = false
        if state.consecutive >= Self.threshold {
            let wasOpen = state.openUntil.map { $0 > now() } ?? false
            state.openUntil = now().addingTimeInterval(Self.cooldown)
            tripped = !wasOpen
        }
        states[key] = state
        return tripped
    }

    func reset(key: String) {
        lock.lock()
        states[key] = nil
        lock.unlock()
    }

    static func message(key: String, retryAfterSeconds: Int) -> String {
        "the provider answered 401/403 to the last \(threshold) calls with \(key); calls are paused for \(retryAfterSeconds)s so a retry loop stops; check the key with keys test \(key), or rotate it and turn the gateway on again"
    }
}
