import Foundation

/// Stops an agent's retry loop against a revoked or wrong key. After `threshold` consecutive
/// upstream 401/403 answers for one key the gateway answers the next calls itself for
/// `cooldown`, so the provider is not hammered and the caller gets one clear reason instead
/// of the same denial forever. Any other upstream status clears a streak but never a pause:
/// the calls that carry one were admitted before the trip. When the cool-down ends exactly one
/// call is let through as a probe, and its answer decides whether the key works again or the
/// pause resumes. Turning the gateway on again for the key (or rotating it) forgets
/// everything. In memory only, like the gateway's secrets.
final class GatewayBreaker: @unchecked Sendable {
    static let threshold = 5
    static let cooldown: TimeInterval = 60
    static let code = "upstream_auth_blocked"

    /// What a call carries from `check` back to `record`. The gateway's calls overlap (up to
    /// `GatewayListener.maxConcurrent` of them), so an answer can belong to a call admitted
    /// before the state moved on; the generation is what tells the two apart.
    struct Admission: Equatable, Sendable {
        /// The state generation the call was admitted under. Every trip and every `reset`
        /// bumps it, so an older value means the answer is already history.
        let generation: Int
        /// True for the single call let through when a cool-down ends.
        let probe: Bool
    }

    enum Verdict: Equatable {
        case closed(Admission)
        case open(retryAfterSeconds: Int)

        /// The admission token for a call that may go upstream; nil when the answer is a pause.
        var granted: Admission? {
            if case .closed(let admission) = self { return admission }
            return nil
        }
    }

    private enum State {
        /// Counting consecutive 401/403 answers; `count == 0` is the resting state.
        case closed(count: Int, generation: Int)
        /// Paused until `until`; the first caller after that becomes the probe.
        case open(until: Date, generation: Int)
        /// One probe is out. Other callers are answered locally until `deadline`, after which a
        /// new probe is admitted: a probe whose caller went away must not wedge the key.
        case halfOpen(generation: Int, deadline: Date)

        var generation: Int {
            switch self {
            case .closed(_, let generation), .open(_, let generation), .halfOpen(let generation, _):
                return generation
            }
        }
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether a call with `key` may go upstream right now, with the token `record` needs.
    /// Once the cool-down has passed the next call is let through as the only probe; a burst
    /// arriving while that probe is out is answered locally.
    func check(key: String) -> Verdict {
        lock.lock()
        defer { lock.unlock() }
        let instant = now()
        let state = states[key] ?? .closed(count: 0, generation: 0)
        switch state {
        case .closed(_, let generation):
            return .closed(Admission(generation: generation, probe: false))
        case .open(let until, let generation):
            let remaining = until.timeIntervalSince(instant)
            if remaining > 0 { return .open(retryAfterSeconds: max(1, Int(remaining.rounded(.up)))) }
            states[key] = .halfOpen(generation: generation, deadline: instant.addingTimeInterval(Self.cooldown))
            return .closed(Admission(generation: generation, probe: true))
        case .halfOpen(let generation, let deadline):
            if instant < deadline { return .open(retryAfterSeconds: 1) }
            // The probe never answered: its caller is gone, or the upstream call outlived the
            // cool-down. Let the next caller try rather than leave the key paused forever, and
            // give it a new generation so the abandoned probe's late answer is ignored.
            let next = generation + 1
            states[key] = .halfOpen(generation: next, deadline: instant.addingTimeInterval(Self.cooldown))
            return .closed(Admission(generation: next, probe: true))
        }
    }

    /// Feeds one upstream status back, tagged with the admission `check` handed out (nil for a
    /// feed with no call behind it, which applies to the current state — the gateway always
    /// passes one; only a test driving a raw streak omits it). True exactly when this status
    /// tripped the breaker, so the caller writes one audit entry per trip.
    ///
    /// Only a status the provider itself answered belongs here. A call the gateway answered
    /// itself (a refused connection, a timeout, a URL it could not build) has no upstream
    /// status at all, and feeding it as a made-up 502 would be evidence about this Mac's
    /// network rather than about the key: with `threshold` of them a working key would be
    /// paused, and a probe among them would close a pause nobody has disproved. The gateway
    /// leaves the state alone for those and calls `abandon` for an admitted probe.
    @discardableResult
    func record(key: String, status: Int, admitting admission: Admission? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let instant = now()
        let state = states[key] ?? .closed(count: 0, generation: 0)
        // An answer from a call admitted before the state moved on says nothing about the key
        // as the provider sees it now: that 200 belongs to the value the pause was earned on,
        // and that 401 to a call the pause already accounts for. Ignoring it is what stops an
        // in-flight sibling from erasing the pause it was tripped by.
        if let admission, admission.generation != state.generation { return false }
        guard status == 401 || status == 403 else {
            switch state {
            case .halfOpen(let generation, _):
                // The probe answered with anything else: the key works again.
                states[key] = .closed(count: 0, generation: generation)
            case .open:
                // Only the probe can end a pause, and the probe runs in the half-open state.
                break
            case .closed(_, let generation):
                states[key] = .closed(count: 0, generation: generation)
            }
            return false
        }
        switch state {
        case .halfOpen(let generation, _):
            // The probe was rejected: the pause resumes at once, and this is a trip of its own.
            states[key] = .open(until: instant.addingTimeInterval(Self.cooldown), generation: generation + 1)
            return true
        case .open(let until, let generation):
            let wasPaused = until > instant
            states[key] = .open(
                until: instant.addingTimeInterval(Self.cooldown),
                generation: wasPaused ? generation : generation + 1
            )
            return !wasPaused
        case .closed(let count, let generation):
            let next = min(Self.threshold, count + 1)
            guard next >= Self.threshold else {
                states[key] = .closed(count: next, generation: generation)
                return false
            }
            states[key] = .open(until: instant.addingTimeInterval(Self.cooldown), generation: generation + 1)
            return true
        }
    }

    /// A call the gateway admitted as the probe and then could not send at all (no response
    /// head: a refused connection, an unresolvable host, a timeout). It says nothing about the
    /// key, so it must neither close the pause nor count as a rejection; releasing the probe
    /// slot lets the next caller try instead of making a burst wait out the deadline for an
    /// attempt that never reached the provider. The generation moves so the attempt's fate is
    /// settled and cannot be reported twice.
    func abandon(key: String, admitting admission: Admission?) {
        lock.lock()
        defer { lock.unlock() }
        guard let admission, admission.probe else { return }
        let state = states[key] ?? .closed(count: 0, generation: 0)
        guard case .halfOpen(let generation, _) = state, generation == admission.generation else { return }
        states[key] = .open(until: now(), generation: generation + 1)
    }

    func reset(key: String) {
        lock.lock()
        // A fresh generation rather than a deletion: calls already in flight against the old
        // value must not count toward the new streak, nor close what this reopened.
        states[key] = .closed(count: 0, generation: (states[key]?.generation ?? 0) + 1)
        lock.unlock()
    }

    static func message(key: String, retryAfterSeconds: Int) -> String {
        "the provider answered 401/403 to the last \(threshold) calls with \(key); calls are paused for \(retryAfterSeconds)s so a retry loop stops; check the key with keys test \(key), or rotate it and turn the gateway on again"
    }
}
