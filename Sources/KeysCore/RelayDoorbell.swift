import CoreGraphics
import CryptoKit
import Foundation

/// The doorbell (docs/relay.md, The doorbell): while the relay is off, the app may keep one
/// more outbound socket to the same Worker, which carries nothing but "an agent asks for the
/// relay" and this Mac's answer. Turning the relay on still takes a Touch ID, here, by the
/// person at the Mac. The doorbell is a signal plane only: it carries no request, no key, no
/// token, and it cannot turn anything on by itself.
///
/// Its credential is the doorbell key, derived from the relay secret (`DoorbellKey`), so the
/// Worker needs no second secret; it is kept apart from the relay secret because it has to be
/// readable at launch, without Touch ID, and it cannot be turned back into the relay secret.
enum DoorbellKey {
    static let prefix = "ksfd_"
    /// The HMAC context; Relay/src/protocol.js (DOORBELL.keyContext) uses the same bytes.
    static let context = "keysrs relay doorbell v1"
    /// The account under the relay's Keychain service that holds the derived key.
    static let accountName = "doorbell"

    static func derive(relaySecret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(context.utf8), using: SymmetricKey(data: Data(relaySecret.utf8))
        )
        return prefix + Hex.encode(Data(mac))
    }

    static func looksLikeKey(_ value: String) -> Bool {
        value.hasPrefix(prefix) && value.count == prefix.count + 64
    }
}

extension RelayProtocol {
    static let doorbellListenPath = "/.keysrs/doorbell/listen"
    static let doorbellRingPath = "/.keysrs/doorbell"
}

extension RelayURL {
    static func doorbellListenURL(_ origin: URL) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = RelayProtocol.doorbellListenPath
        return components.url!
    }

    /// Where an agent rings.
    static func doorbellRingURL(_ origin: URL) -> String {
        origin.absoluteString + RelayProtocol.doorbellRingPath
    }
}

/// One ring as the Worker frames it: an id to answer by and the SHA-256 hex of the client
/// token and pairing the agent rang with. The Worker never forwards the credentials
/// themselves, so whoever holds this socket learns nothing they could spend.
struct DoorbellRing: Equatable {
    var id: String
    var clientHash: String?
    var pairHash: String?

    static func parse(_ text: String) -> DoorbellRing? {
        guard text.utf8.count <= 4096,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["type"] as? String == "ring",
              let id = object["id"] as? String, id.count == 32, id.allSatisfy(\.isHexDigit)
        else { return nil }
        func hash(_ key: String) -> String? {
            guard let value = object[key] as? String, value.count == 64,
                  value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return value
        }
        return DoorbellRing(id: id, clientHash: hash("client"), pairHash: hash("pair"))
    }
}

/// This Mac's answer to a ring. The Worker turns each into the agent's status
/// (docs/relay.md, the doorbell's table); the Mac says only which case applies.
enum DoorbellAnswer: Equatable {
    /// The relay is on, or was just turned on.
    case on
    /// A Touch ID prompt for an earlier ring is still up.
    case pending
    /// The person at the Mac cancelled the prompt.
    case declined
    /// The credential is not a live client token or pairing here; nobody was asked.
    case refused
    /// The screen is locked, so nobody is there to ask.
    case away
    /// Asked too recently; ring again after `retryAfter` seconds.
    case notNow(retryAfter: Int)
    /// The relay could not be turned on for a reason the person has to fix on the Mac.
    case unavailable(String)

    var result: String {
        switch self {
        case .on: return "on"
        case .pending: return "pending"
        case .declined: return "declined"
        case .refused: return "refused"
        case .away: return "away"
        case .notNow: return "not_now"
        case .unavailable: return "unavailable"
        }
    }

    func json(id: String) -> String {
        var object: [String: Any] = ["type": "answer", "id": id, "result": result]
        if case .notNow(let after) = self { object["retry_after"] = after }
        // The message is one of the Mac's own refusals, already free of secrets; cut to what
        // the Worker passes on.
        if case .unavailable(let message) = self { object["message"] = String(message.prefix(400)) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// How often a ring may become a Touch ID prompt. The Worker already spaces rings ten seconds
/// apart; this is the Mac's own bound, because the Worker is not trusted: one prompt at a
/// time, none for `cooldown` after the person declined one, and at most `perHour` an hour.
/// A prompt nobody can dismiss by accident is the point of Touch ID, and a stream of them
/// would wear that down.
final class DoorbellGate: @unchecked Sendable {
    enum Admission: Equatable {
        case prompt
        case pending
        case notNow(retryAfter: Int)
    }

    static let defaultCooldown: TimeInterval = 600
    static let defaultPerHour = 6

    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let perHour: Int
    private var prompting = false
    private var declinedAt: Date?
    private var prompts: [Date] = []

    init(cooldown: TimeInterval = DoorbellGate.defaultCooldown, perHour: Int = DoorbellGate.defaultPerHour) {
        self.cooldown = cooldown
        self.perHour = perHour
    }

    /// Takes the one prompt slot, or says why not. A `.prompt` must be followed by `finished`.
    func admit(now: Date) -> Admission {
        lock.withLock {
            if prompting { return .pending }
            if let declinedAt, now.timeIntervalSince(declinedAt) < cooldown {
                return .notNow(retryAfter: Self.seconds(cooldown - now.timeIntervalSince(declinedAt)))
            }
            prompts.removeAll { now.timeIntervalSince($0) >= 3600 }
            if prompts.count >= perHour, let oldest = prompts.first {
                return .notNow(retryAfter: Self.seconds(3600 - now.timeIntervalSince(oldest)))
            }
            prompting = true
            prompts.append(now)
            return .prompt
        }
    }

    /// `prompted` false: the prompt never appeared (Touch ID unavailable), so it is not
    /// counted against the hour.
    func finished(declined: Bool, prompted: Bool = true, now: Date) {
        lock.withLock {
            prompting = false
            if declined { declinedAt = now }
            if !prompted, !prompts.isEmpty { prompts.removeLast() }
        }
    }

    private static func seconds(_ interval: TimeInterval) -> Int {
        max(1, Int(interval.rounded(.up)))
    }
}

/// Whether the console session's screen is locked. A prompt shown behind the lock screen
/// reaches nobody, so a ring then is answered "away" without one.
enum ScreenLock {
    static func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? ((session["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}

/// Holds the doorbell socket: dials, answers the keepalive, hands each ring to `onRing` off
/// the receive loop, sends the answer back, and redials with the relay's backoff until
/// cancelled. It never turns anything on: `onRing` is the service's, and it asks for Touch ID.
final class DoorbellClient: @unchecked Sendable {
    struct Options {
        var url: URL
        var key: String
        var pingInterval: TimeInterval = RelayProtocol.pingInterval
        var maxBackoff: TimeInterval = 60
        var stableAfter: TimeInterval = 60
        /// Rings handled at once, and per minute. The Worker sends one ring at a time, ten
        /// seconds apart; a Worker that does not is not trusted to, and what it sends beyond
        /// these is answered `not_now` without reaching the service.
        var maxConcurrentRings = 4
        var maxRingsPerMinute = 30
    }

    let options: Options
    let dialer: any RelayDialer
    /// Status lines; never given the key, a hash or a token.
    let log: @Sendable (String) -> Void
    let onRing: @Sendable (DoorbellRing) -> DoorbellAnswer
    /// Read before every dial: the Worker URL and doorbell key as they are stored now, so a
    /// `keys relay setup` in another process (a new secret, so a new key) reaches a doorbell
    /// that is already running, and a reset there ends it. nil ends the loop.
    let current: (@Sendable () -> (url: URL, key: String)?)?
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var phase = RelayClient.Phase.stopped
    private var lastError: String?
    private var lastReceived = Date.distantPast
    private var ringsOpen = 0
    private var ringTimes: [Date] = []
    private let ringQueue = DispatchQueue(label: "keysreallysafe.relay.doorbell", attributes: .concurrent)

    init(
        options: Options,
        dialer: any RelayDialer = URLSessionRelayDialer(),
        log: @escaping @Sendable (String) -> Void,
        onRing: @escaping @Sendable (DoorbellRing) -> DoorbellAnswer,
        current: (@Sendable () -> (url: URL, key: String)?)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.options = options
        self.dialer = dialer
        self.log = log
        self.onRing = onRing
        self.current = current
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
    }

    var state: RelayClient.State {
        lock.withLock { RelayClient.State(phase: phase, lastError: lastError, inflight: 0) }
    }

    var connectHeaders: [String: String] { Self.headers(key: options.key) }

    static func headers(key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", RelayProtocol.protocolHeader: RelayProtocol.version]
    }

    private func enter(_ next: RelayClient.Phase) {
        lock.withLock {
            phase = next
            if case .connected = next { lastError = nil }
        }
    }

    private func failed(_ line: String) {
        lock.withLock { lastError = line }
        log(line)
    }

    func backoff(failures: Int) -> TimeInterval {
        min(options.maxBackoff, pow(2.0, Double(max(0, failures - 1)))) * jitter()
    }

    func run() async {
        var failures = 0
        defer { enter(.stopped) }
        while !Task.isCancelled {
            let started = Date()
            var target = (url: options.url, key: options.key)
            if let current {
                guard let stored = current() else {
                    log("doorbell off: its key or the relay URL is no longer stored on this Mac")
                    break
                }
                target = stored
            }
            let host = target.url.host ?? target.url.absoluteString
            enter(.connecting)
            do {
                let socket = try await dialer.connect(url: RelayURL.doorbellListenURL(target.url), headers: Self.headers(key: target.key))
                if Task.isCancelled {
                    socket.close()
                    break
                }
                enter(.connected(since: now()))
                log("doorbell listening at \(host)")
                try await serve(socket)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                if let dial = error as? RelayDialError, dial.status == 401 {
                    // The doorbell key is derived from the relay secret: a 401 means the two
                    // sides hold different secrets, and the relay's own fix applies.
                    failed("the Worker refused the doorbell key (401): the Worker and this Mac hold different relay secrets; "
                        + "run keys relay setup, `npx wrangler secret put RELAY_SECRET`, then keys relay doorbell on")
                } else if let dial = error as? RelayDialError, let status = dial.status, [404, 426, 502, 503].contains(status) {
                    // A Worker from before the doorbell relays this path like any call: it
                    // waits for a Mac and answers 503, or the gateway answers 404.
                    failed("the Worker answered \(status) instead of opening the doorbell; it may predate it, so redeploy it from this checkout (cd Relay && npx wrangler deploy)")
                } else {
                    failed(error is RelayDialError ? "doorbell: \(error)" : "doorbell connection to \(host) lost: \(error.localizedDescription)")
                }
            }
            if Task.isCancelled { break }
            if Date().timeIntervalSince(started) >= options.stableAfter { failures = 0 }
            failures += 1
            let delay = backoff(failures: failures)
            enter(.waiting(until: now().addingTimeInterval(delay)))
            do { try await sleep(delay) } catch { break }
        }
    }

    /// Reads messages until the socket fails, with the relay's keepalive: a ping every
    /// interval, and silence for two of them counts as a dead socket.
    func serve(_ socket: any RelaySocket) async throws {
        lock.withLock { lastReceived = now() }
        let pinger = Task { [weak self, options, sleep] in
            while !Task.isCancelled {
                try await sleep(options.pingInterval)
                guard let self else { return }
                let silence = self.now().timeIntervalSince(self.lock.withLock { self.lastReceived })
                if silence > 2 * options.pingInterval {
                    self.log("doorbell: nothing heard from the Worker for \(Int(silence.rounded()))s; reconnecting")
                    socket.close()
                    return
                }
                socket.sendText("ping") { [weak self] error in
                    guard error != nil, let self else { return }
                    self.log("doorbell keepalive ping failed; reconnecting")
                    socket.close()
                }
            }
        }
        defer {
            pinger.cancel()
            socket.close()
        }
        while true {
            try Task.checkCancellation()
            let message = try await withTaskCancellationHandler {
                try await socket.receive()
            } onCancel: {
                socket.close()
            }
            lock.withLock { lastReceived = now() }
            guard case .text(let text) = message, text != "pong" else { continue }
            guard let ring = DoorbellRing.parse(text) else { continue }
            guard admitRing() else {
                socket.sendText(DoorbellAnswer.notNow(retryAfter: 60).json(id: ring.id)) { _ in }
                continue
            }
            // The answer may wait for a Touch ID prompt for minutes; the receive loop must
            // keep reading pongs meanwhile, so the ring is answered on its own thread.
            let onRing = self.onRing
            ringQueue.async { [weak self] in
                let answer = onRing(ring)
                self?.lock.withLock { self?.ringsOpen -= 1 }
                socket.sendText(answer.json(id: ring.id)) { _ in }
            }
        }
    }
}

extension DoorbellClient {
    /// Takes a ring slot within the per-socket bounds, or refuses.
    fileprivate func admitRing() -> Bool {
        lock.withLock {
            let at = now()
            ringTimes.removeAll { at.timeIntervalSince($0) >= 60 }
            guard ringsOpen < options.maxConcurrentRings, ringTimes.count < options.maxRingsPerMinute else { return false }
            ringsOpen += 1
            ringTimes.append(at)
            return true
        }
    }
}

/// The doorbell as the app runs it: one DoorbellClient from the moment it is started (at
/// launch when the person turned it on, or by `keys relay doorbell on`) until it is stopped.
final class DoorbellHost: @unchecked Sendable {
    struct Status: Equatable {
        var on: Bool
        var state: RelayClient.State
    }

    private struct Running {
        var client: DoorbellClient
        var task: Task<Void, Never>
        var done: DispatchSemaphore
    }

    let log: @Sendable (String) -> Void
    private let dialer: any RelayDialer
    private let lock = NSLock()
    /// Held across a whole start or stop, so the old loop is gone before a new one dials:
    /// two doorbell sockets would evict each other at the Worker.
    private let transition = NSLock()
    private var running: Running?

    init(
        log: @escaping @Sendable (String) -> Void = { line in FileHandle.standardError.write(Data("doorbell  \(line)\n".utf8)) },
        dialer: any RelayDialer = URLSessionRelayDialer()
    ) {
        self.log = log
        self.dialer = dialer
    }

    var isOn: Bool { lock.withLock { running != nil } }

    var status: Status {
        let state = lock.withLock { running?.client.state }
        return Status(on: state != nil, state: state ?? RelayClient.State())
    }

    /// Starts listening, replacing a doorbell already running (a new key after relay setup).
    func start(
        origin: URL, key: String,
        current: (@Sendable () -> (url: URL, key: String)?)? = nil,
        onRing: @escaping @Sendable (DoorbellRing) -> DoorbellAnswer
    ) {
        transition.lock()
        defer { transition.unlock() }
        stopLocked(wait: 2)
        let client = DoorbellClient(options: .init(url: origin, key: key), dialer: dialer, log: log, onRing: onRing, current: current)
        let done = DispatchSemaphore(value: 0)
        lock.withLock {
            let task = Task.detached { [weak self] in
                await client.run()
                // A loop that ended by itself (its key gone) is off, so turning it on again
                // starts a new one instead of finding this one "on".
                self?.lock.withLock { if self?.running?.client === client { self?.running = nil } }
                done.signal()
            }
            running = Running(client: client, task: task, done: done)
        }
        log("doorbell on; agents ring \(RelayURL.doorbellRingURL(origin)) to ask for the relay")
    }

    func stop(wait: TimeInterval = 2) {
        transition.lock()
        defer { transition.unlock() }
        if stopLocked(wait: wait) { log("doorbell off") }
    }

    /// Under `transition`. Says whether a loop was running.
    @discardableResult
    private func stopLocked(wait: TimeInterval) -> Bool {
        guard let stopping = lock.withLock({ () -> Running? in
            defer { running = nil }
            return running
        }) else { return false }
        stopping.task.cancel()
        _ = stopping.done.wait(timeout: .now() + wait)
        return true
    }
}
