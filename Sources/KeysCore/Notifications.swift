import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// One notification the app owns. Its content is a fixed, non-sensitive template:
/// the title and body never carry a key value, a grant or client token, a file
/// path or any prompt text. The identifier is fixed per kind too, so repeated
/// deliveries replace rather than stack and no id, key or token leaks through it.
struct AppNotification: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// An active grant or client token has entered the warning horizon.
        case expiringCredential
        /// An MCP grant request is waiting for the person's approval.
        case pendingGrant
        /// `GatewayBreaker` paused a key after repeated upstream auth failures.
        case gatewayBreakerTrip
        /// A verified background update was installed.
        case updateInstalled
    }

    var kind: Kind
    var identifier: String
    var title: String
    var body: String

    static let expiringCredentialIdentifier = "keysrs.expiring-credential"
    static let pendingGrantIdentifier = "keysrs.pending-grant"
    static let gatewayBreakerTripIdentifier = "keysrs.gateway-breaker-trip"
    static let updateInstalledIdentifier = "keysrs.update-installed"

    /// The warning horizon: about three days. Existing grant lifetimes are never
    /// changed to fit it — a grant that expires sooner (the product's own grants
    /// live at most a day) is already inside the horizon while active and is
    /// warned at its first eligible poll.
    static let expiringCredential = AppNotification(
        kind: .expiringCredential,
        identifier: expiringCredentialIdentifier,
        title: "A Keysrs credential expires soon",
        body: "A gateway grant or client token expires within about three days. Open Keysrs to renew or replace it before it stops working."
    )

    static let pendingGrant = AppNotification(
        kind: .pendingGrant,
        identifier: pendingGrantIdentifier,
        title: "Keysrs is waiting for your approval",
        body: "An agent's request is waiting for approval. Open Keysrs to approve or deny it."
    )

    static let gatewayBreakerTrip = AppNotification(
        kind: .gatewayBreakerTrip,
        identifier: gatewayBreakerTripIdentifier,
        title: "Keysrs paused a key",
        body: "The provider rejected several calls in a row, so Keysrs paused that key to stop a retry loop. Open Keysrs to check or replace it."
    )

    static let updateInstalled = AppNotification(
        kind: .updateInstalled,
        identifier: updateInstalledIdentifier,
        title: "Keysrs updated",
        body: "Keysrs installed an update and is restarting."
    )
}

/// The app's authorization seam. One method, so a fake records exactly how many
/// times macOS was asked and a test never raises a real permission dialog.
protocol NotificationAuthorizing: Sendable {
    func requestAuthorization() async -> Bool
}

/// The app's delivery seam. One method, so a fake records every payload and a
/// test never posts to the real notification center.
protocol NotificationDelivering: Sendable {
    func deliver(_ notification: AppNotification) async
}

/// Production: macOS asks once and remembers the answer; the request only ever
/// runs from the app process, never from a CLI or MCP subprocess.
struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        #else
        return false
        #endif
    }
}

/// Production: a local notification, no remote push and no payload beyond the
/// fixed template.
struct SystemNotificationDelivery: NotificationDelivering {
    func deliver(_ notification: AppNotification) async {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }
}

/// The app-owned notification service. It reads only timing and status from the
/// existing grant, client-token, pending-grant and breaker state — never a secret
/// — and delivers fixed templates through the injected seams. Authorization is
/// asked once per installed version; warnings are de-duplicated per entity so a
/// repeated poll never repeats the same warning.
final class AppNotifier: @unchecked Sendable {
    /// About three days, the expiry warning horizon.
    static let expiryWarningHorizon: TimeInterval = 3 * 24 * 60 * 60
    /// How often the app polls local state for warnings.
    static let pollInterval: TimeInterval = 15 * 60

    private let preferences: AppPreferences
    private let authorizer: any NotificationAuthorizing
    private let delivery: any NotificationDelivering
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// Entities already warned, so repeated polls do not repeat a warning. The
    /// app process is the only poller, so this lives in memory with it.
    private var warnedExpiries: Set<String> = []
    private var warnedPendingGrants: Set<String> = []

    init(
        preferences: AppPreferences,
        authorizer: any NotificationAuthorizing = SystemNotificationAuthorizer(),
        delivery: any NotificationDelivering = SystemNotificationDelivery(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferences = preferences
        self.authorizer = authorizer
        self.delivery = delivery
        self.clock = clock
    }

    /// Asks macOS for permission once on the first launch after an install or
    /// update and never again for the same version. The version marker is stored
    /// once the ask returns, so a denial is remembered and not re-asked.
    @discardableResult
    func requestAuthorizationIfNeeded(version: String = ProductAnalyticsConfiguration.appVersion) async -> Bool {
        guard preferences.notificationsAuthorizedVersion != version else { return false }
        let granted = await authorizer.requestAuthorization()
        try? preferences.recordNotificationsAuthorized(version: version)
        return granted
    }

    /// One poll of local app-owned state. Warns once per newly-expiring credential
    /// and once per newly-pending grant request.
    func poll(grants: [Grant], clients: [GatewayClient], pendingGrantIDs: [String]) async {
        await warnExpiring(grants: grants, clients: clients, now: clock())
        for id in pendingGrantIDs { await warnPendingGrant(id: id) }
    }

    /// Warns for every active grant or client token whose expiry is inside the
    /// horizon and has not been warned yet. Revoked and already-expired entries
    /// are skipped; the existing lifetimes are never extended to fit the horizon.
    func warnExpiring(grants: [Grant], clients: [GatewayClient], now: Date) async {
        let horizon = now.addingTimeInterval(Self.expiryWarningHorizon)
        let newlyWarned = lock.withLock { () -> Int in
            var count = 0
            for grant in grants where grant.isActive(at: now) && grant.expiresAt <= horizon {
                if warnedExpiries.insert("grant:\(grant.id)").inserted { count += 1 }
            }
            for client in clients where client.isActive(now: now) {
                guard let expiry = UTC.parse(client.expiresAt), expiry <= horizon else { continue }
                if warnedExpiries.insert("client:\(client.id)").inserted { count += 1 }
            }
            return count
        }
        for _ in 0..<newlyWarned { await delivery.deliver(.expiringCredential) }
    }

    /// Warns once for a pending MCP grant request. A request that was refused
    /// before it became pending never reaches this call, so it warns nothing.
    func warnPendingGrant(id: String) async {
        let first = lock.withLock { warnedPendingGrants.insert(id).inserted }
        guard first else { return }
        await delivery.deliver(.pendingGrant)
    }

    /// The create path: an ask whose prompt is up now is time-sensitive, so it is
    /// warned immediately rather than at the next poll. Deduped with the poller's
    /// own warning by the request id, and delivered off the creating thread.
    func pendingGrantRequested(id: String) {
        Task { await self.warnPendingGrant(id: id) }
    }

    /// A `GatewayBreaker` trip, delivered once per trip. The async form is for a
    /// poller or a test; the gateway's listener thread uses the fire-and-forget
    /// `breakerTripped()` below so a notification never holds up a gateway answer.
    func noteBreakerTrip() async {
        await delivery.deliver(.gatewayBreakerTrip)
    }

    /// The gateway path: delivered off the caller's thread.
    func breakerTripped() {
        Task { await self.noteBreakerTrip() }
    }

    /// The background updater's completion event, delivered after a verified
    /// install.
    func noteUpdateInstalled() async {
        await delivery.deliver(.updateInstalled)
    }

    /// The updater path: delivered off the caller's thread, since the app is about
    /// to relaunch.
    func updateInstalled() {
        Task { await self.noteUpdateInstalled() }
    }
}

/// An optional, injected endpoint a notification poll may refresh before it
/// reads local state. The headless app has no required endpoint: the poller's
/// default is absent (`nil`), and an endpoint that is missing or fails is
/// tolerated, because every warning is driven by local app-owned state. The
/// parallel onboarding slice can supply one without changing that.
protocol NotificationEndpointRefreshing: Sendable {
    func refresh() throws
}

/// What one notification poll reads from local state.
struct AppNotificationState: Sendable {
    var grants: [Grant]
    var clients: [GatewayClient]
    var pendingGrantIDs: [String]
}

/// The app's notification poll. It runs the optional endpoint step (tolerating
/// an absent or failing endpoint), then hands local state to `AppNotifier`.
final class AppNotificationPoller: @unchecked Sendable {
    private let notifier: AppNotifier
    private let snapshot: @Sendable () -> AppNotificationState
    private let endpoint: (any NotificationEndpointRefreshing)?
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "keysrs.notifications", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(
        notifier: AppNotifier,
        endpoint: (any NotificationEndpointRefreshing)? = nil,
        interval: TimeInterval = AppNotifier.pollInterval,
        snapshot: @escaping @Sendable () -> AppNotificationState
    ) {
        self.notifier = notifier
        self.endpoint = endpoint
        self.interval = interval
        self.snapshot = snapshot
    }

    /// Starts the app's startup work: the one authorization ask and the repeating
    /// poll. Called once from the app process, never from a CLI or MCP subprocess.
    func start() {
        Task { await notifier.requestAuthorizationIfNeeded() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.pollSoon() }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func pollSoon() {
        Task { await poll() }
    }

    /// One poll. The optional endpoint is refreshed first and its absence or
    /// failure is tolerated: local app-owned state is read either way.
    func poll() async {
        if let endpoint {
            do { try endpoint.refresh() } catch { /* an absent optional endpoint is not an error */ }
        }
        let state = snapshot()
        await notifier.poll(
            grants: state.grants, clients: state.clients, pendingGrantIDs: state.pendingGrantIDs
        )
    }
}
