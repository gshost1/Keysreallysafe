import Darwin
import Foundation
import XCTest
@testable import KeysCore

/// The scheduled check's background install half — VAL-UPDATE-001..005,
/// VAL-CROSS-003 and VAL-H-002/H-004. An extension of `AppUpdaterTests` so the
/// whole updater surface stays under the one validation filter
/// (`swift test --filter AppUpdaterTests`). Every test drives the injected
/// seams: the release check, the quiet gate's activity timeline and clock, the
/// installer, the notification delivery, the manual offer's answer and the
/// quit. No network, disk image, signing identity, real dialog, Keychain or
/// installed app is ever touched.
extension AppUpdaterTests {

    /// The repo checkout root, for the source-level pins.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }


    // MARK: - VAL-UPDATE-001

    /// With Install updates automatically on, the daily check that finds a newer
    /// release installs it through the background path: no manual offer, no
    /// progress window, no alert, the fixed update notification, then the quit
    /// that hands over to the relaunch — and only after the quiet window.
    @MainActor
    func testEnabledDailyCheckInstallsANewerReleaseQuietlyWithNoModal() async throws {
        // Runtime-generated synthetic planted values, planted where a careless
        // template could pick them up: a key-shaped string in the release's
        // download URL and a path in its notes URL. Neither may reach the
        // notification or the log.
        let plantedKey = "sk-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let plantedPath = "/Users/synthetic-\(UUID().uuidString)/private/notes.md"
        let release = ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/example/\(plantedKey)/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: URL(fileURLWithPath: plantedPath)
        )
        let rig = try makeUpdateRig(release: { release })

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)

        XCTAssertEqual(rig.checks.calls, 1, "the default-on daily check ran once")
        XCTAssertEqual(rig.installer.installCalls, 1, "the scheduled check started the background install")
        XCTAssertEqual(rig.installer.releases.map(\.version), ["99.0.0"], "the install targets the newer release")
        XCTAssertEqual(rig.installer.startOffsets, [BackgroundUpdatePolicy.quietInterval],
                       "the install begins only after the quiet window, not at the check's instant")
        XCTAssertTrue(rig.alerts.all.isEmpty, "the scheduled path never raises the manual offer's modal")
        XCTAssertFalse(rig.window.orderedFront, "no dashboard window is surfaced over the headless app")
        XCTAssertEqual(rig.order.all, ["install", "notify", "relaunch", "quit"],
                       "the install, the notification and the relaunch quit happen in that order")
        XCTAssertEqual(rig.delivery.notifications, [AppNotification.updateInstalled],
                       "the fixed update notification and nothing else")
        XCTAssertEqual((try? rig.db.metaValue(AppPreferences.updateChecksKey)) ?? "", "on",
                       "the enabled state is the existing pref_update_checks key")
        XCTAssertEqual(rig.quits.calls, 1, "the relaunch quit runs exactly once")
        for note in rig.delivery.notifications {
            let haystack = "\(note.identifier)\n\(note.title)\n\(note.body)"
            XCTAssertFalse(haystack.localizedCaseInsensitiveContains(plantedKey), "the notification leaked a key-shaped value")
            XCTAssertFalse(haystack.localizedCaseInsensitiveContains(plantedPath), "the notification leaked a path")
            XCTAssertEqual(note.title, AppNotification.updateInstalled.title, "the template is fixed text")
            XCTAssertEqual(note.body, AppNotification.updateInstalled.body, "the template is fixed text")
        }
    }

    /// With the setting off, the existing behavior stands: no scheduled check,
    /// no automatic installation.
    @MainActor
    func testDisabledUpdateChecksKeepTheNoScheduledCheckBehavior() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() }, updateChecks: false)
        XCTAssertEqual((try? rig.db.metaValue(AppPreferences.updateChecksKey)) ?? "", "off",
                       "the disabled state is the existing pref_update_checks key")

        rig.controller.didLaunch()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(rig.checks.calls, 0, "no scheduled check runs while the setting is off")
        XCTAssertEqual(rig.installer.installCalls, 0, "no automatic installation starts")
        XCTAssertEqual(rig.quits.calls, 0, "nothing quits")
        XCTAssertEqual(rig.delivery.notifications, [], "nothing is notified")
        XCTAssertTrue(rig.alerts.all.isEmpty, "no modal appears either")
    }

    // MARK: - VAL-UPDATE-002

    /// The install waits out a pending Touch ID prompt and gateway traffic, and
    /// begins only once both have been absent for the whole quiet interval.
    @MainActor
    func testTheInstallWaitsOutAPendingPromptAndGatewayTraffic() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() })
        // A Touch ID ask is up for the first two fake seconds; a gateway request
        // is in flight at 3.0–3.5. The install may begin at 3.5 + 5 = 8.5.
        rig.activity.busy(from: 0, through: 2)
        rig.activity.busy(from: 3, through: 3.5)

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)

        XCTAssertEqual(rig.installer.startOffsets, [8.5],
                       "the install waits the full quiet interval after the last prompt and the last request")
        XCTAssertEqual(rig.installer.installCalls, 1)
        XCTAssertTrue(rig.installer.startOffsets.allSatisfy { $0 >= 2 }, "nothing installs while the prompt is up")
    }

    /// New activity inside the quiet window restarts it: an install that could
    /// have begun at 6.0 waits for the 4.0–4.5 request instead.
    @MainActor
    func testNewActivityInsideTheQuietWindowRestartsIt() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() })
        rig.activity.busy(from: 0, through: 1)
        rig.activity.busy(from: 4, through: 4.5)

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)

        XCTAssertEqual(rig.installer.startOffsets, [9.5],
                       "the quiet window restarts at the new activity's end (4.5 + 5), not the old quiet start (1.0 + 5)")
        XCTAssertEqual(rig.installer.installCalls, 1)
    }

    /// A Mac that never goes quiet defers the install to the next daily check:
    /// the wait is bounded, and nothing installs, quits or notifies.
    @MainActor
    func testAnAppThatNeverQuietsDefersTheInstall() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() }, waitLimit: 12)
        rig.activity.busy(from: 0, through: 10_000)

        rig.controller.didLaunch()
        await drain(until: !rig.logs.all.isEmpty)

        XCTAssertEqual(rig.installer.installCalls, 0, "a busy Mac never installs")
        XCTAssertEqual(rig.quits.calls, 0, "nothing quits")
        XCTAssertEqual(rig.delivery.notifications, [], "nothing is notified")
        XCTAssertEqual(rig.installer.runCount, 0, "the installer never runs")
        XCTAssertTrue(rig.logs.all.contains { $0.contains("deferred") }, "the deferral is logged for the next daily check")
    }

    // MARK: - VAL-UPDATE-003

    /// A failed release check never installs: no download, no install, no quit,
    /// no relaunch, no modal — and the failure is logged, not shown.
    @MainActor
    func testAFailedReleaseCheckNeverInstallsQuitsOrShowsAnything() async throws {
        let rig = try makeUpdateRig(release: { throw AppError.http("GitHub did not return a release.") })

        rig.controller.didLaunch()
        await drain(until: !rig.logs.all.isEmpty)

        XCTAssertEqual(rig.checks.calls, 1, "the daily check ran and failed")
        XCTAssertEqual(rig.installer.installCalls, 0, "a failed check never starts the install")
        XCTAssertEqual(rig.quits.calls, 0, "a failed check never quits or relaunches")
        XCTAssertEqual(rig.delivery.notifications, [])
        XCTAssertTrue(rig.alerts.all.isEmpty, "a failed scheduled check shows no app-owned modal")
        XCTAssertFalse(rig.window.orderedFront)
        XCTAssertTrue(rig.logs.all.contains { $0.contains("scheduled update check failed") }, "the failure is logged for diagnosis")
    }

    /// No newer release means nothing to do on the scheduled path.
    @MainActor
    func testNoNewerReleaseNeverInstallsOrShowsAnything() async throws {
        let current = ReleaseInfo(
            version: ProductAnalyticsConfiguration.appVersion,
            dmg: URL(string: "https://github.com/example/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
        let rig = try makeUpdateRig(release: { current })

        rig.controller.didLaunch()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(rig.checks.calls, 1, "the check ran and found no newer release")
        XCTAssertEqual(rig.installer.installCalls, 0, "no install for a non-newer release")
        XCTAssertEqual(rig.quits.calls, 0)
        XCTAssertEqual(rig.delivery.notifications, [])
        XCTAssertTrue(rig.alerts.all.isEmpty, "the scheduled path stays silent when it is already current")
    }

    // MARK: - VAL-UPDATE-004

    /// The automatic path runs the manual flow's own installer, and its quit hook
    /// stays unset: the background path delivers its notification first and quits
    /// after, so the installer never races the delivery. The installer it hands
    /// the background path also carries the quiet gate's activity (H2's pre-swap
    /// re-check), while the manual flow's own construction passes none.
    @MainActor
    func testTheAutomaticPathRunsTheManualsInstallerWithNoQuitHookOfItsOwn() throws {
        let clock = FakeClock()
        let activity = ScriptedUpdateActivity(clock: clock)
        let updater = BackgroundUpdater(activity: activity)
        let app = URL(fileURLWithPath: "/Applications/Keysrs.app")
        let release = newerRelease()

        let produced = updater.makeInstaller(release, app)
        let installer = try XCTUnwrap(produced as? UpdateInstaller,
                                      "the automatic path runs UpdateInstaller: the same checksum and stable-signing gates as the manual flow, by construction")
        XCTAssertEqual(installer.release.version, release.version)
        XCTAssertEqual(installer.app, app)
        XCTAssertNil(installer.quit, "the installer never quits by itself on the background path")
        XCTAssertTrue(installer.idleGate as? ScriptedUpdateActivity === activity,
                      "the background factory hands the installer the quiet gate's activity: the pre-swap re-check (H2)")

        let manual = UpdateInstaller(release: release, app: app)
        XCTAssertNil(manual.idleGate, "the manual Update Now keeps its modal window in charge of the timing")
    }

    /// A rejected checksum or signature never installs, quits, relaunches or
    /// notifies; the refusal is logged and the app keeps running.
    @MainActor
    func testRejectedChecksumOrSignatureNeverInstallsQuitsOrNotifies() async throws {
        let rejections = [
            "The download's checksum does not match the release. Nothing was installed; try again.",
            "signing identity changed; refusing to replace the app and invalidate Keychain access",
        ]
        for rejection in rejections {
            let rig = try makeUpdateRig(release: { self.newerRelease() })
            rig.installer.failWith(AppError.http(rejection))

            rig.controller.didLaunch()
            await drain(until: !rig.logs.all.isEmpty)

            XCTAssertEqual(rig.installer.installCalls, 1, "the background path handed the candidate to the installer")
            XCTAssertEqual(rig.installer.runCount, 1, "the installer ran and refused: \(rejection)")
            XCTAssertEqual(rig.quits.calls, 0, "a rejected verification never quits or relaunches: \(rejection)")
            XCTAssertEqual(rig.delivery.notifications, [], "a rejected verification notifies nothing")
            XCTAssertTrue(rig.alerts.all.isEmpty, "a rejected verification shows no app-owned modal")
            XCTAssertFalse(rig.window.orderedFront, "nothing is surfaced over the headless app")
            XCTAssertTrue(rig.logs.all.contains { $0.contains("did not install") }, "the refusal is logged for the next daily check")
        }
    }

    // MARK: - VAL-UPDATE-005

    /// The manual Check for Updates keeps its three-way choice and installs
    /// nothing before the person chooses Update Now — with the automatic
    /// setting on the whole time.
    @MainActor
    func testManualCheckKeepsTheThreeWayChoiceAndNeverInstallsBeforeUpdateNow() async throws {
        // Release Notes re-offers (its notes URL is nil here, so nothing opens),
        // Later leaves the app alone; neither installs.
        let rig = try makeUpdateRig(release: { self.newerRelease() }, script: [.releaseNotes, .later])
        XCTAssertTrue(rig.preferences.updateChecks, "the automatic setting is on throughout")

        rig.controller.checkForUpdates()
        await drain(until: rig.manualChoice.calls == 2)

        XCTAssertEqual(rig.checks.calls, 1, "the manual check runs immediately")
        XCTAssertEqual(rig.manualChoice.askedVersions, ["99.0.0", "99.0.0"], "Release Notes re-offers, Later ends it")
        XCTAssertEqual(rig.manualInstalls.calls, 0, "no install before the person chooses Update Now")
        XCTAssertEqual(rig.installer.installCalls, 0, "the manual path does not run the background install")
        XCTAssertEqual(rig.quits.calls, 0)
        XCTAssertEqual(rig.delivery.notifications, [])
        XCTAssertTrue(rig.alerts.all.isEmpty, "the scripted answers raised no real dialog")
    }

    /// Update Now runs the manual install path, and only after the choice.
    @MainActor
    func testManualUpdateNowRunsTheInstallOnlyAfterTheChoice() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() }, script: [.updateNow])
        XCTAssertTrue(rig.preferences.updateChecks, "the automatic setting is on: the choice is still the person's")

        rig.controller.checkForUpdates()
        await drain(until: rig.manualInstalls.calls == 1)

        XCTAssertEqual(rig.manualChoice.calls, 1)
        XCTAssertEqual(rig.manualVersions.all, ["99.0.0"], "Update Now installs the offered release")
        XCTAssertEqual(rig.installer.installCalls, 0, "the manual install runs through its own seam, not the background one")
        XCTAssertEqual(rig.quits.calls, 0, "the scripted manual seam quits nothing")
    }

    // MARK: - VAL-CROSS-003

    /// A successful background install notifies, quits for the relaunch, and the
    /// relaunched app comes back headless — accessory, no window, no welcome —
    /// with the person's preferences preserved, and it does not install again.
    @MainActor
    func testASuccessfulBackgroundInstallRelaunchesHeadlessWithPreferencesAndNotification() async throws {
        let rig = try HeadlessAppRig()
        defer { rig.stop() }
        let clock = FakeClock()
        let order = EventOrder()
        let installer = RecordingUpdateInstaller(clock: clock, order: order)
        let delivery = OrderRecordingDelivery(order: order)
        let quitCounter = CallCounter()
        let release = RelaunchReleasePlan()
        rig.notifier = AppNotifier(
            preferences: rig.preferences,
            authorizer: RecordingNotificationAuthorizer(),
            delivery: delivery
        )
        rig.background = BackgroundUpdater(
            activity: ScriptedUpdateActivity(clock: clock),
            makeInstaller: installer.factory,
            appURL: { URL(fileURLWithPath: "/tmp/nowhere-real/Keysrs.app") },
            notifier: rig.notifier,
            quit: { quitCounter.record(); order.record("quit") },
            now: { clock.now },
            pause: { seconds in clock.advance(seconds) }
        )
        rig.latestRelease = { release.latest() }

        rig.launch()
        // The real launch path drives the daily check.
        rig.extra.applicationDidFinishLaunching(Notification(name: Notification.Name("test launch")))
        await drain(until: quitCounter.calls == 1)

        XCTAssertEqual(installer.installCalls, 1, "the background install ran once")
        XCTAssertEqual(order.all, ["install", "notify", "relaunch", "quit"],
                       "install, then the notification, then the relaunch quit")
        XCTAssertEqual(delivery.notifications, [AppNotification.updateInstalled])
        XCTAssertEqual(rig.appliedPolicies, [.accessory], "the install never surfaced a window or changed activation")
        XCTAssertEqual(rig.window.orderedFrontCount, 0)
        XCTAssertFalse(rig.welcomeShown, "no welcome or old UI is offered")
        XCTAssertEqual(quitCounter.calls, 1)

        // The relaunch the helper performs: the same service, catalog and
        // preferences, assembled fresh exactly as a new process finds them.
        let before = (meter: rig.preferences.showUsageMeter, item: rig.preferences.menubarItem, updates: rig.preferences.updateChecks)
        release.currentNow()
        rig.relaunch()
        XCTAssertEqual(rig.appliedPolicies, [.accessory], "the relaunch is headless: accessory at rest")
        XCTAssertEqual(rig.window.orderedFrontCount, 0, "no dashboard window appears on its own")
        XCTAssertFalse(rig.welcomeShown, "no welcome appears after the relaunch")
        XCTAssertEqual(rig.preferences.showUsageMeter, before.meter, "preferences survive the relaunch")
        XCTAssertEqual(rig.preferences.menubarItem, before.item, "preferences survive the relaunch")
        XCTAssertEqual(rig.preferences.updateChecks, before.updates, "preferences survive the relaunch")

        // The relaunched app's own daily check finds the now-installed version
        // and installs nothing again.
        rig.extra.applicationDidFinishLaunching(Notification(name: Notification.Name("test relaunch")))
        await drain(until: release.calls >= 2)
        XCTAssertEqual(installer.installCalls, 1, "the relaunched app does not install again")
        XCTAssertEqual(quitCounter.calls, 1, "the relaunched app does not quit again")
    }

    // MARK: - the quiet gate's production sources

    /// A pending grant ask holds its Touch ID prompt, and an approved token that
    /// no one has claimed yet still dies with a restart — both keep the quiet
    /// gate waiting.
    func testUnsettledGrantAsksHoldTheQuietGate() throws {
        let pending = MCPPendingGrants()
        XCTAssertFalse(pending.anyUnsettled(), "an empty store settles nothing")

        let record = try pending.insert(key: "demo")
        XCTAssertTrue(pending.anyUnsettled(), "a pending ask holds its Touch ID prompt")

        let grant = Grant(
            id: "g1", key: "demo", provider: "openai", host: "api.openai.com", task: "task",
            methods: ["POST"], paths: [], createdAt: Date(), expiresAt: Date().addingTimeInterval(60),
            maxRequests: nil, maxUsd: nil, revokedAt: nil, windowMinutes: 30
        )
        pending.approve(id: record.id, token: "synthetic-grant-token", grant: grant)
        XCTAssertTrue(pending.anyUnsettled(), "an approved, unclaimed token would be dropped by a restart")

        _ = pending.claim(id: record.id, secret: record.secret)
        XCTAssertFalse(pending.anyUnsettled(), "once delivered the ask no longer holds the app")

        let second = try pending.insert(key: "demo")
        pending.deny(id: second.id, reason: "refused")
        XCTAssertFalse(pending.anyUnsettled(), "a denied ask is settled")
    }

    /// The wrapped presence gate counts a prompt while it is up and clears it
    /// when it resolves, without changing the gate's behavior.
    func testThePresenceGateWrapCountsPromptsInFlight() throws {
        let activity = InFlightWork()
        let inner = BlockingPresenceGate()
        addTeardownBlock { inner.releaseAll(AppError.authCancelled) }
        let gate = CountingPresenceGate(inner: inner, activity: activity)
        XCTAssertEqual(activity.count, 0)

        DispatchQueue.global().async { try? gate.require(reason: "demo") }
        XCTAssertTrue(inner.waitPrompts(1), "the prompt is up")

        XCTAssertEqual(activity.count, 1, "a prompt in progress is work the install must wait out")
        inner.release(nil)
        for _ in 0..<500 where activity.count != 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(activity.count, 0, "a resolved prompt is no longer in flight")
        XCTAssertNotNil(activity.lastTouched, "the moment it ran is remembered, so the quiet window restarts")
    }

    /// The gateway the app serves counts its requests into the service's
    /// counter: in flight while a call is held open, cleared when it ends.
    func testTheGatewayCountsItsRequestsIntoTheServiceCounter() async throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        let listener = try service.startGateway(port: 0)
        defer { service.stopGateway() }

        XCTAssertTrue(listener.activity === service.gatewayActivity,
                      "the listener the app serves counts into the service's counter")
        XCTAssertEqual(service.gatewayActivity.count, 0)

        // A connection that says nothing is a request in flight until it closes:
        // the listener holds the read until bytes arrive or the socket deadline.
        var fd = try openGatewaySocket(port: listener.boundPort)
        defer { if fd >= 0 { close(fd) } }
        try await until(service.gatewayActivity.count == 1)
        XCTAssertEqual(service.gatewayActivity.count, 1, "a served request is in flight")

        close(fd)
        fd = -1
        try await until(service.gatewayActivity.count == 0)
        XCTAssertEqual(service.gatewayActivity.count, 0, "the request ends with the call")
        XCTAssertNotNil(service.gatewayActivity.lastTouched, "the moment it ended is remembered, so the quiet window restarts")
    }

    // MARK: - VAL-H-002: idleness re-checked through the install

    /// The quiet gate opened, the download ran for minutes — and the Mac turned
    /// busy DURING the install: a Touch ID ask or a gateway call came up while
    /// the installer worked. The relaunch must not kill it: busy at quit time
    /// defers to the next daily check with the existing deferred line, and the
    /// app keeps running. The fake installer marks the scripted activity busy at
    /// the top of its run — the exact moment the real path's own re-check reads
    /// it (the fake gains the hook the onSleep/failWith pattern set).
    @MainActor
    func testBusyDiscoveredDuringTheInstallDefersTheRelaunchWithoutQuitting() async throws {
        let rig = try makeUpdateRig(release: { self.newerRelease() })
        rig.installer.onRun = {
            rig.activity.busy(from: rig.clock.offset, through: 10_000)
        }

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls > 0)

        XCTAssertEqual(rig.installer.installCalls, 1, "the install began after the quiet window")
        XCTAssertEqual(rig.installer.runCount, 1, "the installer ran")
        XCTAssertGreaterThanOrEqual(rig.clock.offset, 10_000,
                                    "busy at quit time defers the relaunch: the app kept running through the busy stretch")
        XCTAssertEqual(rig.quits.calls, 1, "the quit came once the Mac went quiet again")
        XCTAssertTrue(
            rig.logs.all.contains { $0.contains("background update deferred") },
            "the deferral is the existing deferred line, logged for the next daily check"
        )
        XCTAssertEqual(
            rig.delivery.notifications, [AppNotification.updateInstalled],
            "the update did install, so its notification was already delivered; only the relaunch waits"
        )
        XCTAssertEqual(Array(rig.order.all.suffix(2)), ["relaunch", "quit"],
                       "the restart helper starts only right before the quit (S2)")
    }

    /// S2: the background path's swap leaves the restart helper pending, and the
    /// helper starts only after the quit-time re-check passes, right before the
    /// quit. The installer is the production factory's real `UpdateInstaller`
    /// (its download, disk image and signing steps cannot run offline, so the
    /// stand-in run makes the Mac busy and then calls the real post-swap
    /// hand-off), with its spawn seam counting instead of spawning. Failed
    /// pre-fix: the helper was spawned inside run(), before the re-check, so it
    /// ran — and would have deleted the bundle 30 s later — while the app stayed
    /// up.
    @MainActor
    func testABusyQuitTimeHoldsTheRestartHelperUntilTheNextQuietWindow() async throws {
        let clock = FakeClock()
        let activity = ScriptedUpdateActivity(clock: clock)
        let order = EventOrder()
        let logs = LineBag()
        let busyUntil: TimeInterval = 120
        let release = newerRelease()
        let real = try XCTUnwrap(
            BackgroundUpdater(activity: activity).makeInstaller(release, URL(fileURLWithPath: "/nonexistent/Keysrs.app"))
                as? UpdateInstaller
        )
        var spawnedAt: [TimeInterval] = []
        real.spawn = { argv in
            XCTAssertEqual(argv.first, "/bin/sh")
            spawnedAt.append(clock.offset)
            order.record("spawn")
        }
        let stand = SwappingInstaller(real: real) {
            activity.busy(from: clock.offset, through: busyUntil)
        }
        let updater = BackgroundUpdater(
            activity: activity,
            makeInstaller: { _, _ in stand },
            appURL: { URL(fileURLWithPath: "/nonexistent/Keysrs.app") },
            quit: { order.record("quit") },
            now: { clock.now },
            pause: { seconds in clock.advance(seconds) },
            log: { line in logs.record(line) }
        )

        updater.install(release)
        await drain(until: order.all.contains("quit"))

        XCTAssertTrue(logs.all.contains { $0.contains("background update deferred") },
                      "busy at quit time is logged as the deferral")
        XCTAssertEqual(order.all, ["spawn", "quit"], "one helper, started right before the quit")
        XCTAssertEqual(spawnedAt.count, 1)
        XCTAssertGreaterThanOrEqual(spawnedAt.first ?? 0, busyUntil + BackgroundUpdatePolicy.quietInterval,
                                    "the helper waited out the busy stretch and a full quiet window")
        XCTAssertFalse(updater.inFlight, "the install is over once the app hands off")
    }

    /// S2 at the installer: the background hand-off neither spawns nor quits, and
    /// `relaunch()` spawns exactly once; the manual Update Now still spawns and
    /// quits at the end of its own run.
    @MainActor
    func testTheInstallerHandOffSpawnsOnlyWhenTheCallerSays() throws {
        let release = newerRelease()
        var spawns = 0
        var quits = 0
        let background = UpdateInstaller(release: release, app: URL(fileURLWithPath: "/nonexistent/Keysrs.app"))
        background.defersRelaunch = true
        background.spawn = { _ in spawns += 1 }
        background.quit = { quits += 1 }
        try background.handOff(["/bin/sh"])
        XCTAssertEqual(spawns, 0, "the background swap leaves the helper pending")
        XCTAssertEqual(quits, 0)
        try background.relaunch()
        try background.relaunch()
        XCTAssertEqual(spawns, 1, "relaunch starts the pending helper once")
        XCTAssertEqual(quits, 0, "the background updater quits by itself")

        let manual = UpdateInstaller(release: release, app: URL(fileURLWithPath: "/nonexistent/Keysrs.app"))
        manual.spawn = { _ in spawns += 1 }
        manual.quit = { quits += 1 }
        try manual.handOff(["/bin/sh"])
        XCTAssertEqual(spawns, 2, "the manual flow keeps spawning at the end of its run")
        XCTAssertEqual(quits, 1)
    }

    /// The pre-swap half of VAL-H-002, pinned on the source: the real
    /// `UpdateInstaller.run()` cannot run offline (download, disk image,
    /// signing identity), so what is pinned is the gate's PLACEMENT — the
    /// idleness re-check fires inside the installer's run, before the first
    /// bundle move, and throws the deferral the background updater recognizes.
    /// A gate after the first move would leave a half-swapped app behind, and a
    /// relauncher is about to be pending the moment the moves start.
    func testTheRealInstallerRechecksIdlenessBeforeTheFirstMove() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppUpdater.swift"), encoding: .utf8
        )
        let gate = try XCTUnwrap(
            source.range(of: "if let idleGate, idleGate.busy"),
            "the pre-swap gate: the background path re-checks idleness inside the installer's run"
        )
        let firstMove = try XCTUnwrap(
            source.range(of: "fm.moveItem(at: plan.app, to: plan.previous)"),
            "the swap's first bundle move"
        )
        XCTAssertLessThan(
            gate.lowerBound, firstMove.lowerBound,
            "the gate fires before the running bundle starts moving"
        )
        XCTAssertTrue(
            source.contains("BackgroundInstallBusy"),
            "the gate throws the background path's own deferral, not a generic failure"
        )
        let background = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/BackgroundUpdates.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            background.contains("is BackgroundInstallBusy"),
            "the background path answers the gate's deferral with its deferred line, not the did-not-install one"
        )
    }

    // MARK: - VAL-H-004: the relay and recent token use

    /// The relay source of VAL-H-004: the relay being on is work the install
    /// must wait out — the swap would cut every connected agent's pipe — so the
    /// scheduled install defers while it runs and completes once it is off. The
    /// host is the real one over a fake dialer, started offline beside the rig
    /// catalog's own lock.
    @MainActor
    func testTheRelayBeingOnHoldsTheInstallUntilItIsOff() async throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        service.relayHost = RelayHost(
            log: { _ in },
            dialer: FakeRelayDialer([.success(FakeRelaySocket())]),
            blocker: FakeSleepBlocker()
        )
        service.relayHost.start(
            origin: URL(string: "https://keysrs-relay.me.workers.dev")!,
            secret: "ksfr_" + String(repeating: "b", count: 48),
            gatewayPort: 1,
            relayLock: try RelayLock(at: RelayLock.url(beside: db.path))
        )
        defer { service.relayHost.stop() }
        XCTAssertTrue(service.relayHost.isOn, "the rig's relay is on")

        let clock = FakeClock()
        let gate = AppUpdateActivity(
            prompts: InFlightWork(),
            pendingGrants: MCPPendingGrants(),
            gateway: InFlightWork(),
            recentUse: ServiceRecentUse(service: service, now: { clock.now }),
            now: { clock.now }
        )
        XCTAssertTrue(gate.busy, "a relay that is on is activity the install must wait out")

        let rig = try makeUpdateRig(release: { self.newerRelease() }, waitLimit: 12, activity: gate)

        rig.controller.didLaunch()
        await drain(until: rig.logs.all.contains { $0.contains("deferred") })

        XCTAssertEqual(rig.installer.installCalls, 0, "the install never begins while the relay is on")
        XCTAssertEqual(rig.quits.calls, 0, "nothing quits while the relay is on")

        // The relay goes off and the next daily check finds the Mac quiet: the
        // install completes, relaunch and all.
        service.relayHost.stop()
        XCTAssertFalse(service.relayHost.isOn, "the rig's relay is off")

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)

        XCTAssertEqual(rig.installer.installCalls, 1, "the install completes once the relay is off")
        XCTAssertEqual(rig.order.all, ["install", "notify", "relaunch", "quit"], "install, notify, quit in the usual order")
    }

    /// The grant source of VAL-H-004: a grant used moments ago is a session the
    /// install's restart would cut off — grants live only in the running app's
    /// memory — so a use inside the recent-use window holds the gate and the
    /// install defers; once the stamp ages out with no new call, the next daily
    /// check installs and relaunches. The authorize path stamps `lastUsedAt`
    /// exactly as the gateway does for a real call.
    @MainActor
    func testAGrantUsedMomentsAgoHoldsTheInstallUntilTheWindowPasses() async throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        let clock = FakeClock()
        let gate = AppUpdateActivity(
            prompts: InFlightWork(),
            pendingGrants: MCPPendingGrants(),
            gateway: InFlightWork(),
            recentUse: ServiceRecentUse(service: service, now: { clock.now }),
            now: { clock.now }
        )

        let (grant, token) = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com", request: GrantRequest(task: "rig")
        )
        guard case .success = service.grants.authorize(
            token: token, key: "demo", host: "api.openai.com", method: "POST",
            rest: "v1/messages", providerPrefix: "", now: clock.now
        ) else {
            return XCTFail("the rig's grant must authorize")
        }
        XCTAssertEqual(
            service.grants.grant(id: grant.id)?.lastUsedAt, clock.now,
            "the authorize path stamps the grant's last use"
        )

        XCTAssertTrue(gate.busy, "a grant used moments ago is activity the install must wait out")
        XCTAssertEqual(gate.lastBusy, clock.now, "the stamp the quiet gate reads is the grant's last use")

        let rig = try makeUpdateRig(release: { self.newerRelease() }, waitLimit: 12, activity: gate)

        rig.controller.didLaunch()
        await drain(until: rig.logs.all.contains { $0.contains("deferred") })

        XCTAssertEqual(rig.installer.installCalls, 0, "the install defers while the grant's use is inside the window")
        XCTAssertEqual(rig.quits.calls, 0, "nothing quits while the grant's use is inside the window")

        clock.advance(BackgroundUpdatePolicy.recentUseInterval + 1)
        XCTAssertFalse(gate.busy, "a stamp older than the recent-use window no longer holds the gate")

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)
        XCTAssertEqual(rig.installer.installCalls, 1, "the next daily check installs once the use has aged out")
    }

    /// The client-token source of VAL-H-004: a client token whose last forwarded
    /// call ran moments ago is a session the restart would cut off (the
    /// in-memory gateway targets die with the process), so a persisted
    /// `last_used_at` inside the recent-use window holds the gate; aged out
    /// with no new call, the install completes.
    @MainActor
    func testAClientTokenUsedMomentsAgoHoldsTheInstallUntilTheWindowPasses() async throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        let clock = FakeClock()
        let gate = AppUpdateActivity(
            prompts: InFlightWork(),
            pendingGrants: MCPPendingGrants(),
            gateway: InFlightWork(),
            recentUse: ServiceRecentUse(service: service, now: { clock.now }),
            now: { clock.now }
        )

        // An active client token whose row the gateway's use path just stamped,
        // exactly as a forwarded call does. The token is built at runtime.
        let token = GatewayClientToken.generate()
        let client = try db.insertGatewayClient(
            keyName: "demo",
            label: "rig",
            tokenHash: GatewayClientToken.hash(token),
            hint: GatewayClientToken.hint(token),
            methods: ["POST"],
            pathPrefix: nil,
            host: "api.openai.com",
            createdAt: UTC.iso(clock.now),
            expiresAt: UTC.iso(clock.date(at: 86_400))
        )
        try db.touchGatewayClient(id: client.id, at: UTC.iso(clock.now))

        XCTAssertTrue(gate.busy, "a client token used moments ago is activity the install must wait out")
        XCTAssertEqual(gate.lastBusy, clock.now, "the stamp the quiet gate reads is the token's last use")

        let rig = try makeUpdateRig(release: { self.newerRelease() }, waitLimit: 12, activity: gate)

        rig.controller.didLaunch()
        await drain(until: rig.logs.all.contains { $0.contains("deferred") })

        XCTAssertEqual(rig.installer.installCalls, 0, "the install defers while the token's use is inside the window")
        XCTAssertEqual(rig.quits.calls, 0, "nothing quits while the token's use is inside the window")

        clock.advance(BackgroundUpdatePolicy.recentUseInterval + 1)
        XCTAssertFalse(gate.busy, "a stamp older than the recent-use window no longer holds the gate")

        rig.controller.didLaunch()
        await drain(until: rig.quits.calls == 1)
        XCTAssertEqual(rig.installer.installCalls, 1, "the next daily check installs once the use has aged out")
    }

    /// VAL-H-004's wiring, pinned on the source: the app's assembled activity
    /// is built with the relay-and-recent-use source over the service. The
    /// assembled `BackgroundUpdater` is not reachable from a rig (`assembleApp`
    /// builds it internally), so the wiring is pinned where it lives.
    func testTheAssembledAppConsultsTheRelayAndRecentTokenUse() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppRuntime.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("recentUse: ServiceRecentUse(service: service)"),
            "AppRuntime.assembleApp hands the app's own relay, grants and client tokens to the quiet gate"
        )
    }

    // MARK: - fixtures

    private func newerRelease() -> ReleaseInfo {
        ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
    }

    /// Yields the main actor until `condition` holds, bounded: the check and the
    /// background install run as main-actor tasks the test interleaves with.
    @MainActor
    private func drain(until condition: @autoclosure () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Polls on short sleeps, bounded — listener work happens off the main actor,
    /// so the test yields until the counter settles.
    private func until(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A controller over a temp catalog with every update side effect injected
    /// and recorded: the release check, the quiet gate's clock and activity, the
    /// installer, the notification delivery, the manual offer's answer and the
    /// quit. Nothing reaches the network, a disk image, a signing identity, a
    /// real dialog or the real notification center.
    @MainActor
    private func makeUpdateRig(
        release: @escaping () throws -> ReleaseInfo,
        script: [UpdateChoice] = [],
        updateChecks: Bool = true,
        waitLimit: TimeInterval = BackgroundUpdatePolicy.waitLimit,
        activity: (any UpdateActivitySource)? = nil
    ) throws -> UpdateRig {
        let (db, dir) = try makeDB()
        let preferences = AppPreferences(catalog: db)
        try preferences.setUpdateChecks(updateChecks)
        let clock = FakeClock()
        let scripted = ScriptedUpdateActivity(clock: clock)
        let order = EventOrder()
        let installer = RecordingUpdateInstaller(clock: clock, order: order)
        let delivery = OrderRecordingDelivery(order: order)
        let checks = CallCounter()
        let manualChoice = ScriptedUpdateChoice(script)
        let manualInstalls = CallCounter()
        let manualVersions = LineBag()
        let quits = CallCounter()
        let alerts = LineBag()
        let logs = LineBag()
        let window = FakeDashboardWindow()
        let notifier = AppNotifier(
            preferences: preferences,
            authorizer: RecordingNotificationAuthorizer(),
            delivery: delivery
        )
        let background = BackgroundUpdater(
            activity: activity ?? scripted,
            makeInstaller: installer.factory,
            appURL: { dir.appendingPathComponent("Keysrs.app") },
            notifier: notifier,
            quit: { quits.record(); order.record("quit") },
            now: { clock.now },
            pause: { seconds in clock.advance(seconds) },
            log: { line in logs.record(line) },
            waitLimit: waitLimit
        )
        let controller = AppWindowController(
            url: URL(string: "http://127.0.0.1:1/")!,
            preferences: preferences,
            activation: AppActivation(apply: { _ in }),
            window: window,
            presentAlert: { title, text in alerts.record("\(title): \(text)") },
            registerLoginItem: {},
            latestRelease: {
                checks.record()
                return try release()
            },
            offerChoice: { offered in manualChoice.choose(offered) },
            startManualUpdate: { offered in
                manualInstalls.record()
                manualVersions.record(offered.version)
            },
            background: background,
            log: { line in logs.record(line) }
        )
        return UpdateRig(
            controller: controller,
            db: db,
            dir: dir,
            preferences: preferences,
            clock: clock,
            activity: scripted,
            installer: installer,
            delivery: delivery,
            order: order,
            checks: checks,
            manualChoice: manualChoice,
            manualInstalls: manualInstalls,
            manualVersions: manualVersions,
            quits: quits,
            alerts: alerts,
            logs: logs,
            window: window
        )
    }
}

/// The recorded pieces of one controller-level background-update test.
@MainActor
private struct UpdateRig {
    let controller: AppWindowController
    let db: CatalogDB
    let dir: URL
    let preferences: AppPreferences
    let clock: FakeClock
    let activity: ScriptedUpdateActivity
    let installer: RecordingUpdateInstaller
    let delivery: OrderRecordingDelivery
    let order: EventOrder
    let checks: CallCounter
    let manualChoice: ScriptedUpdateChoice
    let manualInstalls: CallCounter
    let manualVersions: LineBag
    let quits: CallCounter
    let alerts: LineBag
    let logs: LineBag
    let window: FakeDashboardWindow
}

/// A clock the quiet gate reads; the injected pause advances it, so the whole
/// wait runs on scripted time instead of wall time.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var elapsed: TimeInterval = 0

    var offset: TimeInterval { lock.withLock { elapsed } }
    var now: Date { date(at: offset) }
    func date(at offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
}

/// The busy timeline the quiet gate samples, in fake-clock seconds: busy during
/// each [start, end) stretch, and `lastBusy` is the end of the latest finished
/// stretch — the shape the production counters report.
private final class ScriptedUpdateActivity: UpdateActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var stretches: [(start: TimeInterval, end: TimeInterval)] = []
    private let clock: FakeClock

    init(clock: FakeClock) { self.clock = clock }

    func busy(from start: TimeInterval, through end: TimeInterval) {
        lock.withLock { stretches.append((start, end)) }
    }

    var busy: Bool {
        let now = clock.offset
        return lock.withLock { stretches.contains { $0.start <= now && now < $0.end } }
    }

    var lastBusy: Date? {
        let now = clock.offset
        let ends = lock.withLock { stretches.filter { $0.end <= now }.map(\.end) }
        return ends.max().map { clock.date(at: $0) }
    }
}

/// Records the app-side events in one place so a test can pin their order.
private final class EventOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.withLock { events.append(event) } }
    var all: [String] { lock.withLock { events } }
}

/// A lock-guarded string list an injected seam can append to from any task.
private final class LineBag: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func record(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// The delivery seam that records into the shared order and every payload, and
/// never posts to the real notification center.
private final class OrderRecordingDelivery: NotificationDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [AppNotification] = []
    private let order: EventOrder

    init(order: EventOrder) { self.order = order }

    func deliver(_ notification: AppNotification) async {
        lock.withLock { notes.append(notification) }
        order.record("notify")
    }

    var notifications: [AppNotification] { lock.withLock { notes } }
}

/// The installer fake for the background path: records what it was handed and
/// when, then succeeds or throws the scripted verification failure. No
/// download, disk image or signing identity is ever touched.
@MainActor
private final class RecordingUpdateInstaller: BackgroundInstallRunning, @unchecked Sendable {
    private let clock: FakeClock
    private let order: EventOrder
    private var handled: [(release: ReleaseInfo, app: URL)] = []
    private var starts: [TimeInterval] = []
    private var runs = 0
    private var failure: Error?

    init(clock: FakeClock, order: EventOrder) {
        self.clock = clock
        self.order = order
    }

    /// The factory the test hands the updater: records the call and returns self.
    var factory: @MainActor (ReleaseInfo, URL) -> any BackgroundInstallRunning {
        { release, app in
            self.note(release: release, app: app)
            return self
        }
    }

    func failWith(_ error: Error) { failure = error }

    /// Set before the drive; called at the top of run(), so a test can make
    /// the Mac busy at the exact moment the real path's own re-check reads it
    /// (H2: busy discovered DURING the install must defer, not quit).
    var onRun: (() -> Void)?

    func run() async throws {
        runs += 1
        order.record("install")
        onRun?()
        if let failure { throw failure }
    }

    func relaunch() throws { order.record("relaunch") }

    var installCalls: Int { handled.count }
    var runCount: Int { runs }
    var releases: [ReleaseInfo] { handled.map(\.release) }
    var startOffsets: [TimeInterval] { starts }

    private func note(release: ReleaseInfo, app: URL) {
        handled.append((release, app))
        starts.append(clock.offset)
    }
}

/// The background stand-in around a real `UpdateInstaller`: its run marks the
/// Mac busy, as a Touch ID ask arriving mid-install would, and then performs the
/// real installer's post-swap hand-off; the relaunch is the real one.
@MainActor
private final class SwappingInstaller: BackgroundInstallRunning {
    let real: UpdateInstaller
    let duringRun: () -> Void

    init(real: UpdateInstaller, duringRun: @escaping () -> Void) {
        self.real = real
        self.duringRun = duringRun
    }

    func run() async throws {
        duringRun()
        try real.handOff(AppUpdater.relauncher(
            pid: getpid(),
            old: URL(fileURLWithPath: "/nonexistent/Keysrs.app.previous"),
            new: URL(fileURLWithPath: "/nonexistent/Keysrs.app")
        ))
    }

    func relaunch() throws { try real.relaunch() }
}

/// The manual offer's scripted answers, in order; an exhausted script answers
/// Later, so an unscripted manual check can never install by accident.
@MainActor
private final class ScriptedUpdateChoice {
    private var pending: [UpdateChoice]
    private var asked: [String] = []

    init(_ script: [UpdateChoice]) { pending = script }

    var calls: Int { asked.count }
    var askedVersions: [String] { asked }

    func choose(_ release: ReleaseInfo) -> UpdateChoice {
        asked.append(release.version)
        return pending.isEmpty ? .later : pending.removeFirst()
    }
}

/// The release the relaunch test serves: newer first, then the version the
/// relaunched app runs, so the second launch's own check finds nothing to do.
private final class RelaunchReleasePlan: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private(set) var calls = 0

    func latest() -> ReleaseInfo {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if delivered {
            return ReleaseInfo(
                version: ProductAnalyticsConfiguration.appVersion,
                dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v\(ProductAnalyticsConfiguration.appVersion)/Keysrs-arm64.dmg")!,
                checksum: .digest(String(repeating: "a", count: 64)),
                expectedBytes: 1,
                notes: nil
            )
        }
        return ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
    }

    func currentNow() {
        lock.lock()
        delivered = true
        lock.unlock()
    }
}

/// Connects to the gateway and says nothing: the request it holds stays in
/// flight until the socket closes.
private func openGatewaySocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw AppError.http("socket failed") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        throw AppError.http("connect failed")
    }
    return fd
}
