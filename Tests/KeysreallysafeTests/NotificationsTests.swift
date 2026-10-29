import Foundation
import XCTest
@testable import KeysCore

/// VAL-NOTIFY-001..005: the app-owned notification service. Every trigger is
/// driven with injected authorization, delivery, clock and presence fakes, so no
/// test shows a real permission dialog, posts a real notification, reads a secret
/// or touches Touch ID.
final class NotificationsTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeGrant(
        id: String,
        key: String = "demo",
        expiresAt: Date,
        revokedAt: Date? = nil
    ) -> Grant {
        Grant(
            id: id, key: key, provider: "openai", host: "api.openai.com", task: "task",
            methods: ["POST"], paths: [], createdAt: instant, expiresAt: expiresAt,
            maxRequests: nil, maxUsd: nil, revokedAt: revokedAt, windowMinutes: 30
        )
    }

    private func makeClient(
        id: Int64,
        keyName: String = "demo",
        label: String = "agent",
        expiresAt: Date,
        revokedAt: Date? = nil
    ) -> GatewayClient {
        GatewayClient(
            id: id, keyName: keyName, label: label, methods: ["POST"], pathPrefix: nil,
            createdAt: UTC.iso(instant), expiresAt: UTC.iso(expiresAt),
            revokedAt: revokedAt.map(UTC.iso), lastUsedAt: nil, hint: "abcd"
        )
    }

    private func makeNotifier(
        _ delivery: RecordingNotificationDelivery,
        catalog: CatalogDB,
        authorizer: RecordingNotificationAuthorizer = RecordingNotificationAuthorizer()
    ) -> AppNotifier {
        let now = instant
        return AppNotifier(
            preferences: AppPreferences(catalog: catalog),
            authorizer: authorizer,
            delivery: delivery,
            clock: { now }
        )
    }

    /// A service over a real temp catalog whose presence gate blocks, so a pending
    /// grant's Touch ID prompt is provably up without any real Touch ID.
    private func makeBlockingService(db: CatalogDB, gate: BlockingPresenceGate) -> KeysService {
        KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true),
            openRouter: OpenRouterHTTP(),
            relaySecrets: MemorySecretStore()
        )
    }

    private func waitForDeliveries(_ delivery: RecordingNotificationDelivery, count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if delivery.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return delivery.count >= count
    }

    // MARK: - VAL-NOTIFY-001

    func testAuthorizationIsAskedOncePerInstalledVersion() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authorizer = RecordingNotificationAuthorizer()
        let notifier = makeNotifier(RecordingNotificationDelivery(), catalog: db, authorizer: authorizer)

        // First launch after an install: exactly one request.
        _ = await notifier.requestAuthorizationIfNeeded(version: "0.14.0")
        XCTAssertEqual(authorizer.requests, 1, "the first launch after install asks once")
        XCTAssertEqual(AppPreferences(catalog: db).notificationsAuthorizedVersion, "0.14.0")

        // A later launch of the same installed version does not ask again.
        let relaunch = makeNotifier(RecordingNotificationDelivery(), catalog: db, authorizer: authorizer)
        _ = await relaunch.requestAuthorizationIfNeeded(version: "0.14.0")
        XCTAssertEqual(authorizer.requests, 1, "a repeat launch of the same version does not re-ask")

        // Another install/update records a new version and asks once more.
        _ = await relaunch.requestAuthorizationIfNeeded(version: "0.15.0")
        XCTAssertEqual(authorizer.requests, 2, "the next install asks once")
        _ = await relaunch.requestAuthorizationIfNeeded(version: "0.15.0")
        XCTAssertEqual(authorizer.requests, 2, "and its own repeat launches do not")
        XCTAssertEqual(AppPreferences(catalog: db).notificationsAuthorizedVersion, "0.15.0")
    }

    func testAuthorizationIsRememberedEvenWhenDenied() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let authorizer = RecordingNotificationAuthorizer()
        authorizer.granted = false
        let notifier = makeNotifier(RecordingNotificationDelivery(), catalog: db, authorizer: authorizer)
        _ = await notifier.requestAuthorizationIfNeeded(version: "0.14.0")
        _ = await notifier.requestAuthorizationIfNeeded(version: "0.14.0")
        XCTAssertEqual(authorizer.requests, 1, "a denial is an answer and is not asked again")
    }

    // MARK: - VAL-NOTIFY-002

    func testExpiryWarningsUseTheThreeDayHorizonAndDedupeAcrossPolls() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = RecordingNotificationDelivery()
        let notifier = makeNotifier(delivery, catalog: db)

        let inWindowGrant = makeGrant(id: "g1", expiresAt: instant.addingTimeInterval(2 * 86_400))
        let outOfWindowGrant = makeGrant(id: "g2", expiresAt: instant.addingTimeInterval(10 * 86_400))
        let revoked = makeGrant(id: "g3", expiresAt: instant.addingTimeInterval(3600), revokedAt: instant)
        let alreadyExpired = makeGrant(id: "g4", expiresAt: instant.addingTimeInterval(-3600))
        let inWindowClient = makeClient(id: 1, expiresAt: instant.addingTimeInterval(86_400))
        let outOfWindowClient = makeClient(id: 2, expiresAt: instant.addingTimeInterval(30 * 86_400))
        let revokedClient = makeClient(id: 3, expiresAt: instant.addingTimeInterval(3600), revokedAt: instant)

        await notifier.warnExpiring(
            grants: [inWindowGrant, outOfWindowGrant, revoked, alreadyExpired],
            clients: [inWindowClient, outOfWindowClient, revokedClient],
            now: instant
        )
        XCTAssertEqual(delivery.notifications.map(\.kind), [.expiringCredential, .expiringCredential],
                       "one warning for the in-window grant and one for the in-window client")
        XCTAssertTrue(delivery.notifications.allSatisfy { $0.kind == .expiringCredential })

        // Repeated polling does not duplicate the same warning.
        await notifier.warnExpiring(grants: [inWindowGrant], clients: [inWindowClient], now: instant)
        XCTAssertEqual(delivery.count, 2, "a repeated poll repeats nothing")

        // A new credential entering the window warns once more.
        let another = makeGrant(id: "g5", expiresAt: instant.addingTimeInterval(86_400))
        await notifier.warnExpiring(grants: [another], clients: [], now: instant)
        XCTAssertEqual(delivery.count, 3, "a newly-expiring credential warns once")

        // Existing lifetimes are never extended to fit the horizon.
        XCTAssertEqual(inWindowGrant.expiresAt, instant.addingTimeInterval(2 * 86_400))
    }

    func testShortLivedGrantIsEligibleAtItsFirstActivePollWithoutExtension() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = RecordingNotificationDelivery()
        let notifier = makeNotifier(delivery, catalog: db)
        // The product's own grants live at most a day, so any active grant is
        // already inside the three-day horizon at its first poll.
        let shortLived = makeGrant(id: "g1", expiresAt: instant.addingTimeInterval(30 * 60))
        await notifier.warnExpiring(grants: [shortLived], clients: [], now: instant)
        XCTAssertEqual(delivery.count, 1, "a short-lived grant is warned at its first active poll")
        XCTAssertEqual(shortLived.expiresAt, instant.addingTimeInterval(30 * 60), "the lifetime is not extended")
    }

    func testAbsentOptionalEndpointDoesNotFailPollingOrSuppressWarnings() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inWindow = makeGrant(id: "g1", expiresAt: instant.addingTimeInterval(3600))
        let snapshot: @Sendable () -> AppNotificationState = {
            AppNotificationState(grants: [inWindow], clients: [], pendingGrantIDs: [])
        }

        // No endpoint at all: the poll still reads local state and warns.
        let absentDelivery = RecordingNotificationDelivery()
        let absent = AppNotificationPoller(
            notifier: makeNotifier(absentDelivery, catalog: db),
            endpoint: nil,
            snapshot: snapshot
        )
        await absent.poll()
        XCTAssertEqual(absentDelivery.count, 1, "an absent optional endpoint does not suppress a local warning")

        // An endpoint that is configured but unreachable fails without failing the poll.
        struct AbsentEndpoint: NotificationEndpointRefreshing {
            func refresh() throws { throw AppError.http("the optional endpoint is absent") }
        }
        let failingDelivery = RecordingNotificationDelivery()
        let failing = AppNotificationPoller(
            notifier: makeNotifier(failingDelivery, catalog: db),
            endpoint: AbsentEndpoint(),
            snapshot: snapshot
        )
        await failing.poll()
        XCTAssertEqual(failingDelivery.count, 1, "a failing optional endpoint is tolerated")
    }

    // MARK: - Launch seam

    @MainActor
    func testDefaultLaunchSeamRetainsThePollerOnTheService() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        let notifier = makeNotifier(RecordingNotificationDelivery(), catalog: db)
        AppRuntime.startNotificationPoller(notifier, service: service)
        XCTAssertNotNil(service.notificationPoller, "the poller is retained so its timer keeps polling")
        try await Task.sleep(for: .milliseconds(50))
        service.notificationPoller?.stop()
    }

    // MARK: - VAL-NOTIFY-003

    func testPendingGrantWarnsOnceAndARefusedAskWarnsNothing() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = BlockingPresenceGate()
        addTeardownBlock { gate.releaseAll(AppError.authCancelled) }
        let service = makeBlockingService(db: db, gate: gate)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)
        let delivery = RecordingNotificationDelivery()
        let notifier = makeNotifier(delivery, catalog: db)
        service.notifications = notifier

        // A refused ask never becomes pending, so it warns nothing.
        XCTAssertThrowsError(try service.requestMCPGrant(
            name: "missing",
            request: GrantRequest(task: "ship"),
            profile: nil, specified: GrantSpecified(), folder: dir.path
        ))
        await notifier.poll(
            grants: service.notificationSnapshot().grants,
            clients: service.notificationSnapshot().clients,
            pendingGrantIDs: service.notificationSnapshot().pendingGrantIDs
        )
        XCTAssertEqual(delivery.count, 0, "a refused ask is not pending and warns nothing")

        // A pending ask whose Touch ID prompt is up warns exactly once.
        let id = try service.requestMCPGrant(
            name: "demo",
            request: GrantRequest(task: "ship", minutes: 5, methods: ["GET"], paths: ["/v1/messages"]),
            profile: nil, specified: GrantSpecified(), folder: dir.path
        )
        XCTAssertTrue(gate.waitPrompts(1), "the Touch ID prompt is up")
        // The create path warns immediately, while the prompt is waiting.
        XCTAssertTrue(waitForDeliveries(delivery, count: 1), "a pending ask warns as soon as its prompt is up")
        XCTAssertEqual(delivery.notifications.map(\.kind), [.pendingGrant])

        let state = service.notificationSnapshot()
        XCTAssertTrue(state.pendingGrantIDs.contains(id), "the ask is pending while its prompt waits")
        await notifier.poll(grants: state.grants, clients: state.clients, pendingGrantIDs: state.pendingGrantIDs)
        XCTAssertEqual(delivery.count, 1, "the poll does not duplicate the pending warning")

        // A repeated poll while it is still pending does not duplicate the warning.
        let again = service.notificationSnapshot()
        await notifier.poll(grants: again.grants, clients: again.clients, pendingGrantIDs: again.pendingGrantIDs)
        XCTAssertEqual(delivery.count, 1, "a repeated poll does not duplicate the pending warning")

        // Releasing the prompt settles the ask; it is no longer pending.
        gate.release(nil)
    }

    // MARK: - VAL-NOTIFY-004

    func testBreakerTripWarnsAndANonTripDoesNot() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = RecordingNotificationDelivery()
        let notifier = makeNotifier(delivery, catalog: db)
        let breaker = GatewayBreaker()

        // Below the threshold nothing trips, so nothing warns.
        for _ in 0..<(GatewayBreaker.threshold - 1) {
            XCTAssertFalse(breaker.record(key: "k", status: 401))
        }
        XCTAssertEqual(delivery.count, 0, "a non-trip result warns nothing")

        // The trip itself is the event the app warns about.
        XCTAssertTrue(breaker.record(key: "k", status: 401))
        await notifier.noteBreakerTrip()
        XCTAssertEqual(delivery.notifications.map(\.kind), [.gatewayBreakerTrip])
    }

    // MARK: - VAL-NOTIFY-005

    func testEveryNotificationPayloadExcludesProhibitedContent() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = RecordingNotificationDelivery()
        let notifier = makeNotifier(delivery, catalog: db)

        // Runtime-generated synthetic planted values: a key value, a grant token,
        // a client token, a file path and presence-prompt text. Nothing is a
        // committed literal.
        let plantedKey = "sk-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let plantedGrantToken = GrantToken.generate(id: "0badc0de")
        let plantedClientToken = GatewayClientToken.generate()
        let plantedPath = "/Users/synthetic-\(UUID().uuidString)/private/notes.md"
        let plantedPrompt = "Keysrs wants to use the key demo to make a request"

        // Plant them where a careless template could pick them up.
        let grant = makeGrant(id: "g1", key: plantedKey, expiresAt: instant.addingTimeInterval(3600))
        let client = makeClient(id: 7, keyName: plantedPath, label: plantedClientToken,
                                expiresAt: instant.addingTimeInterval(3600))
        await notifier.warnExpiring(grants: [grant], clients: [client], now: instant)
        await notifier.warnPendingGrant(id: plantedGrantToken)
        await notifier.noteBreakerTrip()
        await notifier.noteUpdateInstalled()

        let kinds = Set(delivery.notifications.map(\.kind))
        XCTAssertEqual(kinds, [.expiringCredential, .pendingGrant, .gatewayBreakerTrip, .updateInstalled],
                       "every implemented event was exercised")

        let planted = [plantedKey, plantedGrantToken, plantedClientToken, plantedPath, plantedPrompt]
        for note in delivery.notifications {
            let haystack = "\(note.identifier)\n\(note.title)\n\(note.body)"
            for needle in planted {
                XCTAssertFalse(haystack.localizedCaseInsensitiveContains(needle),
                               "\(note.kind) payload leaked prohibited content")
            }
        }
    }
}
