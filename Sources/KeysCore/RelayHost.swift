import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// One relay per Mac. The Worker keeps a single Mac connection and gives it to whichever
/// connected last, so two relays would take it from each other on every redial. The app's
/// relay and `keys relay` both hold this lock for as long as they run.
final class RelayLock {
    /// The lock is taken; `pid` is the holder's when it could be read.
    struct Held: Error, Equatable {
        var pid: pid_t?
    }

    static func url(beside catalog: URL) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("relay.lock")
    }

    private var descriptor: Int32

    /// Takes the lock or throws `Held`. Released by `release()`, by deinit, and by the kernel
    /// when the process dies, so a crashed relay never blocks the next one.
    init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppError.http("could not open the relay lock at \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let pid = Self.readPid(fd)
            Darwin.close(fd)
            throw Held(pid: pid)
        }
        // For the refusal the next relay gets; nothing else reads it.
        _ = ftruncate(fd, 0)
        let line = Array("\(getpid())\n".utf8)
        _ = line.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, 0) }
        descriptor = fd
    }

    func release() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }

    /// Who holds the lock, without keeping it: nil when nobody does.
    static func holder(at url: URL) -> Held? {
        do {
            try RelayLock(at: url).release()
            return nil
        } catch let held as Held {
            return held
        } catch {
            return nil
        }
    }

    private static func readPid(_ fd: Int32) -> pid_t? {
        var buf = [UInt8](repeating: 0, count: 16)
        let n = buf.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }
}

extension RelayLock.Held {
    /// Whether the holder is the running Keysrs app, the process the control file names.
    func isApp(control: URL) -> Bool {
        guard let pid, let owner = ControlFile.live(at: control) else { return false }
        return owner.pid == pid
    }

    private var process: String { pid.map { "process \($0)" } ?? "another process" }

    /// Why `keys relay` in a Terminal does not start.
    func terminalRefusal(control: URL) -> String {
        if isApp(control: control) {
            return "the Keysrs app's relay is on (\(process)), and the Worker keeps only one Mac connection; "
                + "turn it off first (menu bar → Relay for Cloud Agents, or keys relay off), then run keys relay again"
        }
        return "another keys relay is already running on this Mac (\(process)), and the Worker keeps only one Mac "
            + "connection; stop that one with Ctrl-C in its Terminal first"
    }

    /// Why the app's relay does not turn on.
    var appRefusal: String {
        "keys relay is already running on this Mac (\(process)), and the Worker keeps only one Mac connection; "
            + "stop it with Ctrl-C in its Terminal, then turn the relay on here"
    }
}

/// Keeps the Mac from idle sleep. The relay holds it only when the person asked for it.
protocol IdleSleepBlocker: Sendable {
    /// False when the system refused.
    func begin(reason: String) -> Bool
    func end()
}

/// IOKit's PreventUserIdleSystemSleep assertion, the one `caffeinate -i` takes: the display
/// may still sleep, and closing the lid or choosing Sleep still sleeps the Mac.
final class IOKitIdleSleepBlocker: IdleSleepBlocker, @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID?

    func begin(reason: String) -> Bool {
        lock.withLock {
            if assertion != nil { return true }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
            )
            guard result == kIOReturnSuccess else { return false }
            assertion = id
            return true
        }
    }

    func end() {
        lock.withLock {
            if let id = assertion { IOPMAssertionRelease(id) }
            assertion = nil
        }
    }
}

/// Whether the Mac runs on its power adapter. Holding it awake for a share on battery would
/// drain it overnight, so "Keep Mac Awake While Sharing" only holds on power; a Mac without a
/// battery always reads as on power.
enum PowerSource {
    static func onExternalPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPMACPowerKey
    }
}

/// The relay as the app runs it (docs/relay.md): one RelayClient from the moment it is turned
/// on until it is turned off or the app quits, redialing on its own after a dropped socket or
/// sleep, its lines going to `log` (menubar.log in the app). It is never turned on by itself:
/// the secret leaves the Keychain only after a Touch ID, so a launch starts with it off.
final class RelayHost: @unchecked Sendable {
    struct Status: Equatable {
        var on: Bool
        var origin: URL?
        var state: RelayClient.State
        /// Whether the idle-sleep assertion is held right now.
        var awake: Bool
        /// Why it is held: for relayed calls, or because a share is live and the Mac is on power.
        var awakeReason: AwakeReason? = nil
    }

    enum AwakeReason: String, Equatable {
        case calls
        case shared
    }

    /// How often the share hold rechecks the shares and the power source: an expired share or
    /// an unplugged adapter lets the Mac sleep within this long.
    static let defaultShareCheckInterval: TimeInterval = 60

    /// How long the Mac is kept from idle sleep after the last relayed call, when the person
    /// asked for it: an agent's calls come in bursts with its own tool runs in between, and
    /// releasing the assertion between two calls lets an idle Mac sleep in the gap.
    static let defaultLinger: TimeInterval = 300

    private struct Running {
        var client: RelayClient
        var task: Task<Void, Never>
        var done: DispatchSemaphore
        var lock: RelayLock
        var origin: URL
    }

    private let log: @Sendable (String) -> Void
    private let dialer: any RelayDialer
    private let blocker: any IdleSleepBlocker
    private let linger: TimeInterval
    /// The clock the relay stamps its own activity with; injectable so a test
    /// scripts the moment (the update gate reads the stamp, H4).
    private let now: @Sendable () -> Date
    /// When a relayed call last opened or closed; nil until the first. A call
    /// relayed moments ago means an agent is mid-session, and the update
    /// install's restart would cut its pipe — the quiet gate reads this stamp
    /// to hold the install for the recent-use window.
    private let lastCallAt = LockedValue<Date?>(nil)
    private let lock = NSLock()
    private var running: Running?
    private var stayAwake = false
    private var awakeWhileShared = false
    private var shareLive: @Sendable () -> Bool = { false }
    private let onPower: @Sendable () -> Bool
    private let shareCheckInterval: TimeInterval
    // Confined to awakeQueue, except `awakeHeld` and `awakeReason`, which status reads.
    private let awakeQueue = DispatchQueue(label: "keysreallysafe.relay.awake")
    private let awakeHeld = LockedValue(false)
    private let awakeReason = LockedValue<AwakeReason?>(nil)
    private var lingerItem: DispatchWorkItem?
    private var shareTimer: DispatchSourceTimer?

    init(
        log: @escaping @Sendable (String) -> Void = { line in FileHandle.standardError.write(Data("relay  \(line)\n".utf8)) },
        dialer: any RelayDialer = URLSessionRelayDialer(),
        blocker: any IdleSleepBlocker = IOKitIdleSleepBlocker(),
        linger: TimeInterval = RelayHost.defaultLinger,
        onPower: @escaping @Sendable () -> Bool = { PowerSource.onExternalPower() },
        shareCheckInterval: TimeInterval = RelayHost.defaultShareCheckInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.log = log
        self.dialer = dialer
        self.blocker = blocker
        self.linger = linger
        self.onPower = onPower
        self.shareCheckInterval = shareCheckInterval
        self.now = now
    }

    var isOn: Bool { lock.withLock { running != nil } }

    /// When a relayed call last opened or closed; nil until the first (H4's
    /// quiet-gate source). Never reset by `stop()` — the last relayed call is
    /// still the last, and the window ages it out on its own.
    var lastRelayedCall: Date? { lastCallAt.get() }

    var status: Status {
        let (origin, state) = lock.withLock { (running?.origin, running?.client.state) }
        let held = awakeHeld.get()
        return Status(
            on: origin != nil, origin: origin, state: state ?? RelayClient.State(), awake: held,
            awakeReason: held ? awakeReason.get() : nil
        )
    }

    /// Starts relaying with credentials the caller obtained behind presence, holding `relayLock`
    /// until `stop()`. Does nothing if this host is already on.
    func start(origin: URL, secret: String, gatewayPort: UInt16, relayLock: RelayLock, pairing: RelayPairingVerifier? = nil) {
        var options = RelayClient.Options(url: origin, secret: secret, gatewayPort: gatewayPort)
        // The app's relay enforces pairing like `keys relay` in a Terminal does; the verifier
        // reads the catalog per request, so `keys relay pair require` applies without a restart.
        options.pairing = pairing
        let client = RelayClient(
            options: options,
            dialer: dialer,
            log: log,
            activity: { [weak self] in
                // A call opened or closed: stamp the moment for the update gate's
                // recent-use window (H4), then let the awake machinery decide.
                self?.lastCallAt.set(self?.now())
                self?.activityChanged()
            }
        )
        let done = DispatchSemaphore(value: 0)
        let started: Bool = lock.withLock {
            guard running == nil else { return false }
            let task = Task.detached {
                await client.run()
                done.signal()
            }
            running = Running(client: client, task: task, done: done, lock: relayLock, origin: origin)
            return true
        }
        guard started else {
            relayLock.release()
            return
        }
        // The awake choices are set before the relay starts; the share hold needs no call to
        // begin, so it is decided now rather than at the first relayed call.
        activityChanged()
        log("on; agents reach the gateway at \(RelayURL.baseURL(origin, key: "<key name>")) with a client token")
    }

    /// Closes the socket, which fails the calls in flight on the Worker as retryable, and
    /// waits briefly for the loop to end before giving up the lock.
    func stop(wait: TimeInterval = 2) {
        guard let stopping = lock.withLock({ () -> Running? in
            defer { running = nil }
            return running
        }) else { return }
        stopping.task.cancel()
        if stopping.done.wait(timeout: .now() + wait) == .timedOut {
            log("the relay loop did not end within \(Int(wait))s; it stops on its own")
        }
        stopping.lock.release()
        activityChanged()
        log("off")
    }

    /// Whether to keep the Mac from idle sleep while relayed calls are open.
    func setStayAwake(_ on: Bool) {
        lock.withLock { stayAwake = on }
        activityChanged()
    }

    /// Whether to keep the Mac from idle sleep for as long as a share is live and the Mac is on
    /// its power adapter, calls or not: the other machine's agent may call at any moment, and
    /// a sleeping Mac answers nothing. `live` reads the catalog; it is polled every
    /// `shareCheckInterval` while the hold is wanted, never on the relay's receive loop.
    func setStayAwakeWhileShared(_ on: Bool, live: @escaping @Sendable () -> Bool) {
        lock.withLock {
            awakeWhileShared = on
            shareLive = live
        }
        activityChanged()
    }

    /// Waits until the idle-sleep decisions queued so far have been made; for tests.
    func settle() {
        awakeQueue.sync {}
    }

    private func activityChanged() {
        awakeQueue.async { [weak self] in self?.evaluateAwake() }
    }

    /// On awakeQueue. Holds the assertion while a share is live and the Mac is on power, when
    /// the person asked for that; otherwise while a relayed call is open and for `linger` after
    /// the last one, when they asked for that. Never while the relay is off.
    private func evaluateAwake() {
        let (callsWanted, sharedWanted, busy, live) = lock.withLock { () -> (Bool, Bool, Bool, @Sendable () -> Bool) in
            (stayAwake && running != nil, awakeWhileShared && running != nil,
             (running?.client.inflightCount ?? 0) > 0, shareLive)
        }
        updateShareTimer(sharedWanted)
        if sharedWanted, live(), onPower() {
            lingerItem?.cancel()
            lingerItem = nil
            hold(.shared)
            return
        }
        guard callsWanted else {
            lingerItem?.cancel()
            lingerItem = nil
            release("letting the Mac sleep again")
            return
        }
        if busy {
            lingerItem?.cancel()
            lingerItem = nil
            hold(.calls)
        } else if awakeHeld.get(), lingerItem == nil {
            // The share hold just ended (expired, revoked, unplugged) with calls wanted: the
            // usual quiet period after the last call still applies before the Mac may sleep.
            if awakeReason.get() == .shared { awakeReason.set(.calls) }
            let item = DispatchWorkItem { [weak self] in self?.lingerEnded() }
            lingerItem = item
            awakeQueue.asyncAfter(deadline: .now() + linger, execute: item)
        }
    }

    /// On awakeQueue. Takes the assertion, or keeps it under a new reason, logging changes only.
    private func hold(_ reason: AwakeReason) {
        if awakeHeld.get() {
            guard awakeReason.get() != reason else { return }
            awakeReason.set(reason)
            log(reason == .shared
                ? "keeping the Mac awake while keys are shared and it is on power"
                : "keeping the Mac awake while relayed calls are open")
            return
        }
        let why = reason == .shared
            ? "Keysrs is sharing keys with another machine"
            : "Keysrs is relaying a call from a cloud agent"
        if blocker.begin(reason: why) {
            awakeHeld.set(true)
            awakeReason.set(reason)
            log(reason == .shared
                ? "keeping the Mac awake while keys are shared and it is on power"
                : "keeping the Mac awake while relayed calls are open")
        } else {
            log("could not keep the Mac awake: the system refused the power assertion")
        }
    }

    /// On awakeQueue.
    private func release(_ line: String) {
        guard awakeHeld.get() else { return }
        blocker.end()
        awakeHeld.set(false)
        awakeReason.set(nil)
        log(line)
    }

    /// On awakeQueue. The share hold has no event to wake it when a share expires or the
    /// adapter is pulled, so it rechecks on a timer for as long as it is wanted.
    private func updateShareTimer(_ wanted: Bool) {
        if !wanted {
            shareTimer?.cancel()
            shareTimer = nil
            return
        }
        guard shareTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: awakeQueue)
        timer.schedule(deadline: .now() + shareCheckInterval, repeating: shareCheckInterval)
        timer.setEventHandler { [weak self] in self?.evaluateAwake() }
        shareTimer = timer
        timer.resume()
    }

    /// On awakeQueue: the quiet period after the last call ran out.
    private func lingerEnded() {
        lingerItem = nil
        // A call that opened meanwhile keeps the assertion; its end schedules a new wait. A
        // share hold that took over meanwhile is the share check's to end.
        guard (lock.withLock { running?.client.inflightCount ?? 0 }) == 0, awakeHeld.get(),
              awakeReason.get() != .shared else { return }
        let quiet = linger >= 60 ? "\(Int(linger / 60)) min" : "\(Int(linger.rounded())) s"
        release("letting the Mac sleep again: no relayed call for \(quiet)")
    }
}
