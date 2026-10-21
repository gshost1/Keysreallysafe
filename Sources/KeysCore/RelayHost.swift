import Darwin
import Foundation
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
    }

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
    private let lock = NSLock()
    private var running: Running?
    private var stayAwake = false
    // Confined to awakeQueue, except `awakeHeld`, which status reads.
    private let awakeQueue = DispatchQueue(label: "keysreallysafe.relay.awake")
    private let awakeHeld = LockedValue(false)
    private var lingerItem: DispatchWorkItem?

    init(
        log: @escaping @Sendable (String) -> Void = { line in FileHandle.standardError.write(Data("relay  \(line)\n".utf8)) },
        dialer: any RelayDialer = URLSessionRelayDialer(),
        blocker: any IdleSleepBlocker = IOKitIdleSleepBlocker(),
        linger: TimeInterval = RelayHost.defaultLinger
    ) {
        self.log = log
        self.dialer = dialer
        self.blocker = blocker
        self.linger = linger
    }

    var isOn: Bool { lock.withLock { running != nil } }

    var status: Status {
        let (origin, state) = lock.withLock { (running?.origin, running?.client.state) }
        return Status(on: origin != nil, origin: origin, state: state ?? RelayClient.State(), awake: awakeHeld.get())
    }

    /// Starts relaying with credentials the caller obtained behind presence, holding `relayLock`
    /// until `stop()`. Does nothing if this host is already on.
    func start(origin: URL, secret: String, gatewayPort: UInt16, relayLock: RelayLock) {
        let client = RelayClient(
            options: RelayClient.Options(url: origin, secret: secret, gatewayPort: gatewayPort),
            dialer: dialer,
            log: log,
            activity: { [weak self] in self?.activityChanged() }
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

    /// Waits until the idle-sleep decisions queued so far have been made; for tests.
    func settle() {
        awakeQueue.sync {}
    }

    private func activityChanged() {
        awakeQueue.async { [weak self] in self?.evaluateAwake() }
    }

    /// On awakeQueue. Holds the assertion while a relayed call is open and for `linger` after
    /// the last one, and only while the relay is on and the person asked for it.
    private func evaluateAwake() {
        let (wanted, busy) = lock.withLock { () -> (Bool, Bool) in
            (stayAwake && running != nil, (running?.client.inflightCount ?? 0) > 0)
        }
        guard wanted else {
            lingerItem?.cancel()
            lingerItem = nil
            if awakeHeld.get() {
                blocker.end()
                awakeHeld.set(false)
                log("letting the Mac sleep again")
            }
            return
        }
        if busy {
            lingerItem?.cancel()
            lingerItem = nil
            guard !awakeHeld.get() else { return }
            if blocker.begin(reason: "Keysrs is relaying a call from a cloud agent") {
                awakeHeld.set(true)
                log("keeping the Mac awake while relayed calls are open")
            } else {
                log("could not keep the Mac awake: the system refused the power assertion")
            }
        } else if awakeHeld.get(), lingerItem == nil {
            let item = DispatchWorkItem { [weak self] in self?.lingerEnded() }
            lingerItem = item
            awakeQueue.asyncAfter(deadline: .now() + linger, execute: item)
        }
    }

    /// On awakeQueue: the quiet period after the last call ran out.
    private func lingerEnded() {
        lingerItem = nil
        // A call that opened meanwhile keeps the assertion; its end schedules a new wait.
        guard (lock.withLock { running?.client.inflightCount ?? 0 }) == 0, awakeHeld.get() else { return }
        blocker.end()
        awakeHeld.set(false)
        let quiet = linger >= 60 ? "\(Int(linger / 60)) min" : "\(Int(linger.rounded())) s"
        log("letting the Mac sleep again: no relayed call for \(quiet)")
    }
}
