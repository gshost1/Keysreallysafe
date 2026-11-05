import AppKit
import Foundation

/// The scheduled check's install half. The manual flow keeps its modal; this is
/// the headless counterpart the daily check uses: it waits out the person's
/// Touch ID prompts and the gateway's in-flight traffic, then runs the same
/// `UpdateInstaller` the manual Update Now runs — the same checksum and
/// stable-signing gates by construction — delivers the fixed update
/// notification, and quits so the relaunch helper swaps in the new bundle. It
/// shows nothing: no window, no progress UI, no alert. A headless app never
/// raises an app-owned modal, and any failure simply waits for the next daily
/// check.

/// The quiet window's shape: how long the app must be free of prompts and
/// gateway traffic, how often that is sampled, and how long the wait may run
/// before it defers to the next daily check.
enum BackgroundUpdatePolicy {
    /// "A few seconds": no Touch ID prompt is up, no gateway request is in
    /// flight, and neither has run within this interval.
    static let quietInterval: TimeInterval = 5
    /// "The last few minutes": how recently the relay, an active grant or a
    /// client token must have run to count as work the install must wait out.
    /// Agent traffic comes in bursts with gaps far longer than the quiet
    /// interval, and the restart the install performs would cut the relay's
    /// socket and drop every grant and the in-memory token cache — so a use
    /// this fresh holds the gate, and an older stamp is stale and frees it.
    /// Deliberately its own constant, not the 5-second window: that one is
    /// about a call in flight, this one about a session still being mid-run.
    static let recentUseInterval: TimeInterval = 5 * 60
    /// How often the quiet gate samples activity. Sampling repeatedly is what
    /// keeps the gate from inferring idle from one instantaneous reading.
    static let sampleInterval: TimeInterval = 0.5
    /// The wait is bounded: a Mac that never goes quiet defers the install to
    /// the next daily check rather than waiting the day away.
    static let waitLimit: TimeInterval = 10 * 60
}

/// The install the background path runs: the manual flow's own `UpdateInstaller`,
/// so the checksum and stable-signing verification are the same by construction.
/// A protocol only so tests can fake the download and script failures without
/// touching disk images or signing identities.
@MainActor
protocol BackgroundInstallRunning {
    func run() async throws
    /// Starts the restart helper `run()` left pending; called only right before
    /// the quit, once the quit-time idleness re-check passed.
    func relaunch() throws
}

extension UpdateInstaller: BackgroundInstallRunning {}

/// The pre-swap gate's refusal (H2): the Mac turned busy while the installer's
/// download ran, so the swap — which moves the running bundle out from under
/// the process and leaves a relaunch helper pending — must not begin. Nothing
/// has moved and nothing is pending when this is thrown; the background
/// updater recognizes it and answers with its deferred line, never the
/// did-not-install one, because the next daily check can simply try again.
struct BackgroundInstallBusy: Error {}

/// One kind of work the automatic install must wait out (a Touch ID prompt, a
/// gateway request). Counts the units in progress and remembers when a unit
/// last began or ended: the quiet gate samples the count, and the stamp is what
/// restarts the quiet window for a short unit that starts and finishes between
/// two samples. Lock-guarded, because gateway listener threads and presence
/// callers bump it from their own threads.
final class InFlightWork: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var lastAt: Date?

    func begin(_ now: Date = Date()) {
        lock.withLock {
            active += 1
            lastAt = now
        }
    }

    func end(_ now: Date = Date()) {
        lock.withLock {
            active = max(0, active - 1)
            lastAt = now
        }
    }

    var count: Int { lock.withLock { active } }
    var lastTouched: Date? { lock.withLock { lastAt } }
}

/// Wraps a presence gate and counts its prompts, so the app can know a Touch ID
/// ask is up without changing any gate's behavior or refusal reasons. The app's
/// factory wraps the production gate in it; a test gate left unwrapped simply
/// reports no prompts.
struct CountingPresenceGate: PresenceGate {
    let inner: any PresenceGate
    let activity: InFlightWork

    func require(reason: String) throws {
        activity.begin()
        defer { activity.end() }
        try inner.require(reason: reason)
    }
}

/// What the quiet gate samples before an automatic install. Production reads the
/// app's own counters; a test scripts busy and idle stretches.
protocol UpdateActivitySource: Sendable {
    /// A prompt is up, an ask is still unsettled, or a gateway request is in
    /// flight right now.
    var busy: Bool { get }
    /// When such work last began or ended; nil when there never was any.
    var lastBusy: Date? { get }
}

/// The app's own state as the quiet gate reads it: the presence-prompt counter
/// fed by the wrapped production gate, the pending grant asks (a restart drops
/// the store and any undelivered token with it), the gateway's counter, and —
/// H4 — the relay and recent grant/client-token use below.
struct AppUpdateActivity: UpdateActivitySource {
    let prompts: InFlightWork
    let pendingGrants: MCPPendingGrants
    let gateway: InFlightWork
    /// The relay and recent token use; nil where nothing runs one (a rig that
    /// builds only the prompt and gateway counters).
    let recentUse: (any RecentUseSource)?
    let now: @Sendable () -> Date

    init(
        prompts: InFlightWork,
        pendingGrants: MCPPendingGrants,
        gateway: InFlightWork,
        recentUse: (any RecentUseSource)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.prompts = prompts
        self.pendingGrants = pendingGrants
        self.gateway = gateway
        self.recentUse = recentUse
        self.now = now
    }

    var busy: Bool {
        prompts.count > 0 || pendingGrants.anyUnsettled() || gateway.count > 0
            || recentUse?.relayOn == true
            || recentUseIsFresh
    }

    var lastBusy: Date? {
        var stamps = [prompts.lastTouched, gateway.lastTouched]
        if recentUseIsFresh, let last = recentUse?.lastUse { stamps.append(last) }
        return stamps.compactMap { $0 }.max()
    }

    /// Whether the relay or token use ran within the recent-use window (H4). A
    /// stamp older than the window is stale — the session it belonged to is
    /// over, and the install may proceed.
    private var recentUseIsFresh: Bool {
        guard let last = recentUse?.lastUse else { return false }
        return now().timeIntervalSince(last) < BackgroundUpdatePolicy.recentUseInterval
    }
}

/// The relay and recent token use the quiet gate also consults (H4): whether the
/// relay is on, and when the relay, an active grant or a client token last ran.
/// The install's restart would cut the relay's socket and drop every grant and
/// the in-memory token cache, and an agent mid-burst would lose its session to
/// it — so the gate holds while a use is within the recent-use window, and the
/// relay being on holds it outright, whatever the stamps say.
protocol RecentUseSource: Sendable {
    /// The relay socket is up: agents may be connected right now.
    var relayOn: Bool { get }
    /// When the relay, an active grant or a client token was last used; nil
    /// when none ever was. The newest stamp is what the gate reads.
    var lastUse: Date? { get }
}

/// The app's own relay, grant store and client tokens as the quiet gate reads
/// them: the running relay host, the in-memory grants the gateway's authorize
/// path stamps, and the client tokens' persisted `last_used_at`.
struct ServiceRecentUse: RecentUseSource {
    let service: KeysService
    let now: @Sendable () -> Date

    init(service: KeysService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    var relayOn: Bool { service.relayHost.isOn }

    var lastUse: Date? {
        var stamps: [Date] = []
        if let relayed = service.relayHost.lastRelayedCall { stamps.append(relayed) }
        // Active grants only: a revoked or expired grant can no longer run, so
        // its last use is not a session the restart would cut off.
        stamps += service.grants.list(now: now()).compactMap(\.lastUsedAt)
        if let clientUse = try? service.catalog.latestActiveClientTokenUse() {
            stamps.append(clientUse)
        }
        return stamps.max()
    }
}

/// The scheduled check's install half: the quiet wait, the installer, the
/// notification and the quit that hands the process to the relaunch helper.
@MainActor
final class BackgroundUpdater {
    private let activity: any UpdateActivitySource
    /// The same installer the manual path runs; internal so a test can pin that
    /// the automatic path really uses it.
    let makeInstaller: @MainActor (ReleaseInfo, URL) -> any BackgroundInstallRunning
    private let appURL: () -> URL
    private let notifier: AppNotifier?
    private let quit: @MainActor () -> Void
    private let now: @Sendable () -> Date
    private let pause: @Sendable (TimeInterval) async -> Void
    private let log: (String) -> Void
    private let quietInterval: TimeInterval
    private let sampleInterval: TimeInterval
    private let waitLimit: TimeInterval
    /// The one update machine, shared with the manual flow. A second install —
    /// manual Update Now or another scheduled one — is refused while it is
    /// claimed, so the two can never stage beside the same bundle names.
    let coordinator: UpdateCoordinator

    init(
        activity: any UpdateActivitySource,
        makeInstaller: (@MainActor (ReleaseInfo, URL) -> any BackgroundInstallRunning)? = nil,
        appURL: @escaping () -> URL = { Bundle.main.bundleURL },
        notifier: AppNotifier? = nil,
        quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        log: @escaping (String) -> Void = { _ in },
        quietInterval: TimeInterval = BackgroundUpdatePolicy.quietInterval,
        sampleInterval: TimeInterval = BackgroundUpdatePolicy.sampleInterval,
        waitLimit: TimeInterval = BackgroundUpdatePolicy.waitLimit,
        allowed: (() -> Bool)? = nil,
        coordinator: UpdateCoordinator = UpdateCoordinator()
    ) {
        self.activity = activity
        self.coordinator = coordinator
        // The coordinator refuses a scheduled run unless someone says the
        // person's setting allows it, so it fails closed. Only an explicit
        // `allowed` changes that: the controller that owns the preference wires
        // the seam from `updateChecks`, and a default here would quietly
        // overwrite a coordinator that was already wired.
        if let allowed { coordinator.backgroundAllowed = allowed }
        // The background factory: the manual flow's own installer with the
        // quiet gate's activity attached, so the swap itself is refused when the
        // Mac turned busy during the download (H2). Built in the body because
        // a default argument cannot see the sibling parameter it would capture.
        // The manual flow constructs its own installer and passes no gate: its
        // modal progress window keeps the person in charge of the timing.
        self.makeInstaller = makeInstaller ?? { [coordinator] release, app in
            let installer = UpdateInstaller(release: release, app: app, coordinator: coordinator, origin: .background)
            installer.idleGate = activity
            installer.defersRelaunch = true
            return installer
        }
        self.appURL = appURL
        self.notifier = notifier
        self.quit = quit
        self.now = now
        self.pause = pause
        self.log = log
        self.quietInterval = quietInterval
        self.sampleInterval = sampleInterval
        self.waitLimit = waitLimit
    }

    /// The scheduled path found a newer release: wait for the quiet window, then
    /// install through the same gates the manual flow uses, notify, and quit for
    /// the relaunch. Its own task, so the check that found the release is not
    /// held open; one install at a time. Idleness is re-checked THROUGH the
    /// install (H2), because the download and the swap take minutes and the
    /// window that opened before them says nothing about the moment they end:
    /// once right before the swap (inside the installer — that gate is the one
    /// that guarantees no relaunch helper was spawned, because it fires before
    /// the first bundle move) and once immediately before the quit. Busy before
    /// the swap defers to the next daily check; busy before the quit holds the
    /// restart helper and the quit until the next quiet window.
    func install(_ release: ReleaseInfo) {
        // The claim is the one install slot for both paths. The scheduled check
        // already holds it in `.checking(.background)`, so this hands over; a
        // manual install that got there first wins and this one logs instead of
        // staging a second bundle beside the same names. The phase is `waiting`:
        // nothing is downloading yet, and saying so keeps the manual check's
        // "in progress" honest without pretending a download has begun.
        guard let claim = coordinator.beginInstall(.background, waiting: true) else {
            log("background update skipped: \(UpdateCoordinator.busyMessage)")
            return
        }
        Task { @MainActor in
            defer { coordinator.finish(claim) }
            guard await self.waitForQuiet(claim) else {
                if let why = coordinator.stopReason(claim) { self.logStopped(why) }
                else { self.logDeferred() }
                return
            }
            // The quiet wait can take the full wait limit: a cancel or the
            // person turning automatic updates off during it stops the run
            // before anything is even built. The reason comes from the one place
            // that decides it, on this run's own claim.
            if let why = coordinator.stopReason(claim) {
                self.logStopped(why)
                return
            }
            let installer = self.makeInstaller(release, self.appURL())
            // The installer's own quit hook stays unset on this path: the
            // notification is delivered first and the quit runs after, so the
            // relaunch helper never races the delivery. Clearing it also covers
            // a factory that set one.
            if let manual = installer as? UpdateInstaller { manual.quit = nil }
            do {
                try await installer.run()
            } catch is BackgroundInstallBusy {
                // The pre-swap gate fired: nothing moved and nothing is
                // pending, so the deferral is the whole story.
                self.logDeferred()
                return
            } catch let stopped as UpdateStopped {
                // A step boundary stopped it with nothing moved and nothing
                // pending: cancelled, automatic updates turned off, or the
                // person's own Check for Updates took the machine over.
                self.logStopped(stopped.why)
                return
            } catch {
                // A failure after the swap is not a failure to install: the new
                // bundle is in place and only the restart is left. The claim
                // stays, so the next attempt is a relaunch and never a second
                // swap beside an already-replaced bundle.
                if coordinator.phase == .installedPendingRelaunch(.background) {
                    self.log("background update installed but did not restart: \(error.localizedDescription)")
                    return
                }
                self.log("background update did not install: \(error.localizedDescription)")
                return
            }
            // The bundle in place is the new one from here. Until the helper
            // starts, the person's Check for Updates finishes the restart
            // instead of being told the machine is busy — the quiet wait below
            // has no limit, and a Mac that never goes quiet would otherwise
            // shut them out for good.
            let quit = self.quit
            coordinator.installedPendingRelaunch(claim) {
                try installer.relaunch()
                quit()
            }
            await self.notifier?.noteUpdateInstalled()
            // The quit's own re-check: a prompt or gateway call that came up
            // while the installer ran must not die to the relaunch. The swap
            // is done but the restart helper has not started (S2): it deletes
            // the old bundle and opens the new one once this process is gone,
            // so starting it while the app stays up would pull the bundle out
            // from under a running app and open a second copy. Busy here waits
            // for the next quiet window, and only then are the helper and the
            // quit started, back to back. A person quitting first simply
            // launches the new version next time; the leftover old bundle is
            // swept at that launch.
            if self.activity.busy {
                self.logDeferred()
                while !(await self.waitForQuiet()) {
                    if Task.isCancelled { return }
                }
            }
            // A failed restart is retried here, with the claim and the helper
            // still held: the bundle in place is the new one, so the next daily
            // check must find this same "installed, relaunch pending" state and
            // not stage a second swap beside an already-replaced bundle. The
            // retries are bounded by the wait limit; past it the app stays up
            // and a person quitting normally launches the new version.
            var attempts = 0
            while true {
                do {
                    try installer.relaunch()
                    self.quit()
                    return
                } catch {
                    attempts += 1
                    self.log("background update installed but did not restart: \(error.localizedDescription)")
                    if attempts < Self.relaunchAttempts, await self.waitForQuiet() { continue }
                    // Out of attempts: the machine stays in installed-pending-
                    // relaunch, and a later Check for Updates runs the restart.
                    return
                }
            }
        }
    }

    /// How many times a failed restart helper start is retried before the
    /// installed-but-not-restarted state is left for the next launch.
    static let relaunchAttempts = 3

    /// The deferral the next daily check picks up, in the one wording the log
    /// already carries.
    private func logDeferred() {
        log("background update deferred: the Mac stayed busy for \(Int(self.waitLimit)) seconds")
    }

    /// A run stopped at a pre-swap boundary: the person turned automatic
    /// updates off, cancelled, or their own Check for Updates took the machine
    /// over. Nothing moved, and the next daily check starts from scratch only if
    /// the setting is on again. The reason comes from the thrown error, never
    /// from re-reading the coordinator's flags — those belong to whichever run
    /// holds the claim now, which after a takeover is not this one.
    private func logStopped(_ why: UpdateStopped.Why) {
        let reason: String
        switch why {
        case .cancelled: reason = "it was cancelled"
        case .disabled: reason = "automatic updates were turned off"
        case .superseded: reason = "the person started their own update check"
        }
        log("background update stopped before the swap: \(reason)")
    }

    /// Waits for the quiet window: nothing the app must stay alive for — a
    /// Touch ID prompt, a pending or undelivered grant ask, a gateway request —
    /// is up, none has run within the quiet interval, and that has held across
    /// repeated samples, so one instantaneous reading is never enough. Work
    /// that starts and ends between two samples still restarts the window
    /// through the activity stamp. Bounded: past `waitLimit` the install defers
    /// to the next daily check.
    private func waitForQuiet(_ claim: UpdateClaim? = nil) async -> Bool {
        let deadline = now().addingTimeInterval(waitLimit)
        var quietSince: Date?
        while true {
            if Task.isCancelled { return false }
            // A run that was taken over or switched off stops waiting at once
            // rather than sampling out the whole wait limit.
            if let claim, coordinator.stopReason(claim) != nil { return false }
            let moment = now()
            guard moment <= deadline else { return false }
            if activity.busy {
                quietSince = nil
            } else {
                let since = quietSince ?? moment
                quietSince = since
                // Work can begin and end between samples; the stamp keeps that
                // from reading as quiet.
                let quietStart = activity.lastBusy.map { max($0, since) } ?? since
                if moment.timeIntervalSince(quietStart) >= quietInterval { return true }
            }
            await pause(sampleInterval)
        }
    }
}
