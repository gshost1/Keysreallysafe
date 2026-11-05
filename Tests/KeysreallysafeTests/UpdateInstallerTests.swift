import Darwin
import Foundation
import XCTest
@testable import KeysCore

/// The update machine's ownership and phase ordering, tested where the review
/// found it broken: a progress write that lands after its run ended, a cancel
/// that arrives while verification is suspended, and a restart that fails after
/// the bundle has already been swapped. Everything here is offline — the
/// download, the disk image, the checksum and the signature gate are all
/// injected, and the only paths touched are in a temp directory.
final class UpdateInstallerTests: XCTestCase {

    // MARK: - 1. a late progress write never revives the machine

    /// The download's progress sink is a `@MainActor` hop queued from the URL
    /// session's own queue, so one can land after the run has ended. Before the
    /// claim token it wrote `.downloading` unconditionally, which put the
    /// machine back to non-idle for the life of the process: every later check
    /// was answered "Update Already in Progress" until the app was relaunched.
    @MainActor
    func testALateProgressWriteAfterTheRunEndsLeavesTheMachineIdle() async throws {
        let coordinator = UpdateCoordinator()
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator)
        let stalled = LateSink()
        // The download is still in flight when the run is ended underneath it,
        // and the sink it captured has not been called yet: exactly the state a
        // queued `@MainActor` progress hop is in.
        let download = SuspendableStep()
        installer.downloadStep = { _, _, progress in
            stalled.hold(progress)
            await download.reach()
        }

        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        let run = Task { try await installer.run() }
        await harness.until { stalled.sink != nil }
        XCTAssertEqual(coordinator.phase, .downloading(.manual, written: 0, expected: 0))

        coordinator.finish(claim)
        XCTAssertTrue(coordinator.isIdle, "the run ended before its last progress report arrived")

        stalled.fire(fraction: 1, expected: 1_000)
        XCTAssertEqual(coordinator.phase, .idle,
                       "a progress report from a run that ended must not revive the machine")
        XCTAssertNotNil(coordinator.beginCheck(.background),
                        "and a later check is not refused as 'already in progress'")

        download.open()
        do {
            _ = try await run.value
            XCTFail("the run whose claim is gone stops at its next boundary")
        } catch let stopped as UpdateStopped {
            XCTAssertEqual(stopped.why, .superseded)
        }
        XCTAssertEqual(coordinator.phase, .checking(.background),
                       "and leaves the machine to the run that took it over")
    }

    /// The phase never moves backwards while a claim is live: a progress report
    /// that arrives after verification started must not put the machine back to
    /// `.downloading`, which would re-enable Cancel over work already done.
    @MainActor
    func testProgressNeverMovesThePhaseBackwards() throws {
        let coordinator = UpdateCoordinator()
        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        coordinator.step(.downloading(.manual, written: 10, expected: 100), for: claim)
        coordinator.step(.verifying(.manual), for: claim)
        XCTAssertEqual(coordinator.phase, .verifying(.manual))

        coordinator.step(.downloading(.manual, written: 90, expected: 100), for: claim)
        XCTAssertEqual(coordinator.phase, .verifying(.manual),
                       "a late progress report leaves the phase where the run actually is")
        XCTAssertTrue(coordinator.phase.allowsCancel, "and cannot re-enable Cancel from the swap")
    }

    // MARK: - 5. a refused caller's finish cannot wipe the winner's claim

    /// The loser of a claim is refused and gets no token, so there is nothing for
    /// its `defer` to release. A token a newer run replaced is ignored too: the
    /// older run's cleanup used to free the machine out from under the run that
    /// had just taken it over.
    @MainActor
    func testAStaleClaimCannotReleaseTheLiveOne() throws {
        let coordinator = UpdateCoordinator()
        let scheduled = try XCTUnwrap(coordinator.beginCheck(.background))
        let manual = try XCTUnwrap(coordinator.beginCheck(.manual))

        coordinator.finish(scheduled)
        XCTAssertFalse(coordinator.isIdle, "the superseded run's finish is ignored")
        XCTAssertTrue(coordinator.isCurrent(manual))
        coordinator.finishCheck(scheduled)
        XCTAssertTrue(coordinator.isCurrent(manual), "nor does its finishCheck")
        coordinator.step(.swapping(.manual), for: scheduled)
        XCTAssertEqual(coordinator.phase, .checking(.manual),
                       "and a superseded run's step writes nothing")

        coordinator.finishCheck(manual)
        XCTAssertTrue(coordinator.isIdle)
    }

    /// The scheduled path's setting defaults to refusing, not allowing: a
    /// coordinator assembled without the preference — a rig, a future caller —
    /// must not install unwatched. The background updater opts in explicitly.
    @MainActor
    func testAFreshCoordinatorDoesNotAllowABackgroundInstall() throws {
        let coordinator = UpdateCoordinator()
        let claim = try XCTUnwrap(coordinator.beginInstall(.background))
        XCTAssertEqual(coordinator.stopReason(claim), .disabled,
                       "an unwired coordinator fails closed: automatic updates must be opted in")
        XCTAssertThrowsError(try coordinator.checkContinue(claim)) { error in
            XCTAssertEqual(error as? UpdateStopped, UpdateStopped(why: .disabled))
        }
    }

    /// The background updater changes the setting seam only when it is handed
    /// one: building it over a coordinator that was already wired (or never
    /// wired) must not quietly turn automatic installs on.
    @MainActor
    func testTheBackgroundUpdaterLeavesTheSettingSeamAloneUnlessGivenOne() throws {
        let unwired = UpdateCoordinator()
        _ = BackgroundUpdater(activity: IdleActivity(), coordinator: unwired)
        let refused = try XCTUnwrap(unwired.beginInstall(.background))
        XCTAssertEqual(unwired.stopReason(refused), .disabled, "no `allowed`, so the fail-closed default stands")

        let wired = UpdateCoordinator()
        wired.backgroundAllowed = { false }
        _ = BackgroundUpdater(activity: IdleActivity(), coordinator: wired)
        let stillRefused = try XCTUnwrap(wired.beginInstall(.background))
        XCTAssertEqual(wired.stopReason(stillRefused), .disabled, "an existing wiring is not overwritten")

        let opted = UpdateCoordinator()
        _ = BackgroundUpdater(activity: IdleActivity(), allowed: { true }, coordinator: opted)
        let allowed = try XCTUnwrap(opted.beginInstall(.background))
        XCTAssertNil(opted.stopReason(allowed), "an explicit `allowed` opts in")
    }

    /// A claim past the swap is never released in this process: a second claim
    /// would stage a new install beside an already-replaced bundle.
    @MainActor
    func testAClaimPastTheSwapIsNeverReleased() throws {
        let coordinator = UpdateCoordinator()
        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        for phase in [UpdateCoordinator.Phase.swapping(.manual), .relaunching(.manual),
                      .installedPendingRelaunch(.manual)] {
            coordinator.step(phase, for: claim)
            coordinator.finish(claim)
            XCTAssertEqual(coordinator.phase, phase, "\(phase) keeps its claim")
            XCTAssertFalse(coordinator.isIdle)
        }
        XCTAssertNil(coordinator.beginInstall(.manual), "so no second install can start")
        XCTAssertNil(coordinator.beginCheck(.manual), "and no lookup")
    }

    // MARK: - 2. cancel is observed while verification is suspended

    /// Verification used to run synchronously on the main actor — hash,
    /// `hdiutil`, the plist read, `copyItem`, codesign — so a Cancel click could
    /// not be handled until every check had already passed and the run reached
    /// the swap regardless. Each blocking step now does its work in a detached
    /// task and is awaited, which is what leaves the main actor free to deliver
    /// the click. Pinned on the source because the production steps cannot run
    /// offline (a real disk image and signing identity).
    func testEveryVerificationStepRunsOffTheMainActor() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppUpdater.swift"), encoding: .utf8
        )
        for step in ["sha256Step", "mountStep", "versionStep", "stageStep", "validateStep"] {
            let declaration = try XCTUnwrap(source.range(of: "var \(step): @Sendable"),
                                            "\(step) exists as an injectable, sendable step")
            let body = source[declaration.lowerBound...].prefix(400)
            XCTAssertTrue(body.contains("Task.detached"),
                          "\(step)'s production value hops off the main actor instead of blocking it")
        }
        let run = try XCTUnwrap(source.range(of: "func verifyAndSwap("))
        let body = source[run.lowerBound...]
        for awaited in ["try await versionStep(", "try await stageStep(", "try await validateStep("] {
            XCTAssertTrue(body.contains(awaited),
                          "the run suspends at \(awaited), so the main actor can deliver a Cancel")
        }
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "try await validateStep(")).lowerBound,
                          try XCTUnwrap(body.ranges(of: "try coordinator.checkContinue(claim)").last).lowerBound,
                          "the boundary after the signature gate is reachable by a cancel that landed during it")
    }

    /// The real installer, with every seam suspended, is stop-able while it
    /// verifies: the person's Cancel is accepted mid-run and the next boundary
    /// stops the run with nothing staged beside the app.
    @MainActor
    func testACancelDuringSuspendedVerificationStopsBeforeAnythingIsStaged() async throws {
        let coordinator = UpdateCoordinator()
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator)
        let gate = SuspendableStep()
        installer.sha256Step = { _ in
            await gate.reach()
            return InstallerHarness.digest
        }

        XCTAssertNotNil(coordinator.beginInstall(.manual))
        let run = Task { try await installer.run() }
        // The run is suspended inside verification: the main actor is free, so a
        // person's Cancel is handled now, exactly as the real click would be.
        await harness.until { gate.reached }
        XCTAssertEqual(coordinator.phase, .verifying(.manual), "the run is verifying")

        installer.cancel()
        XCTAssertTrue(coordinator.cancelRequested, "the cancel was accepted while verification ran")
        gate.open()

        do {
            try await run.value
            XCTFail("a cancel during verification must stop the run before the swap")
        } catch let stopped as UpdateStopped {
            XCTAssertEqual(stopped.why, .cancelled)
        }
        XCTAssertEqual(harness.stages, 0, "nothing was staged beside the app")
        XCTAssertEqual(harness.swaps, 0, "and the running bundle never moved")
        XCTAssertEqual(coordinator.phase, .verifying(.manual),
                       "the phase is left where the run stopped, not moved on")
    }

    // MARK: - 3. a failed restart after the swap keeps the claim

    /// The bundle is replaced and the restart helper fails to start. The update
    /// did happen, so nothing may release the claim or report a failed update:
    /// the phase says installed-but-not-restarted, and the only retry is
    /// `relaunch()`. A second claim used to re-claim the machine and then try to
    /// set the already-replaced bundle aside.
    @MainActor
    func testAFailedRestartKeepsTheInstalledPendingClaimAndOnlyRelaunchRetries() async throws {
        let coordinator = UpdateCoordinator()
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator)
        let attempts = AttemptCounter()
        installer.spawn = { _ in
            attempts.bump()
            throw AppError.http("the restart helper could not start")
        }

        XCTAssertNotNil(coordinator.beginInstall(.manual))
        do {
            try await installer.run()
            XCTFail("the failing helper must be reported")
        } catch {}
        XCTAssertEqual(harness.swaps, 1, "the bundle really was replaced")

        XCTAssertEqual(coordinator.phase, .installedPendingRelaunch(.manual),
                       "the bundle was replaced: the phase says so and stays claimed")
        XCTAssertNotNil(coordinator.claim, "the claim is not released after the swap")
        XCTAssertNil(coordinator.beginInstall(.manual),
                     "a second install is refused rather than re-swapping the bundle")
        XCTAssertNil(coordinator.beginCheck(.background))

        XCTAssertThrowsError(try coordinator.restartPending(), "the retry still finds the helper failing")
        XCTAssertEqual(attempts.count, 2, "the retry attempted the restart, not a second install")
        XCTAssertEqual(harness.swaps, 1, "and the bundle was still swapped exactly once")
        XCTAssertEqual(coordinator.phase, .installedPendingRelaunch(.manual))

        installer.spawn = { _ in attempts.bump() }
        XCTAssertTrue(try coordinator.restartPending(), "the retry that works starts the helper")
        XCTAssertEqual(attempts.count, 3)
    }

    /// The first move of the swap fails, so the running bundle never left. The
    /// claim used to stay in `.swapping` — a phase `finish()` refuses — and
    /// every later check was refused until the app was relaunched.
    @MainActor
    func testAFailedFirstMoveReleasesTheClaimAndRemovesTheStagedBundle() async throws {
        let coordinator = UpdateCoordinator()
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator)
        // A non-empty directory already at the set-aside name makes the move fail.
        let previous = harness.root.appendingPathComponent(AppUpdater.previousName, isDirectory: true)
        try FileManager.default.createDirectory(at: previous.appendingPathComponent("leftover"), withIntermediateDirectories: true)

        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        do {
            try await installer.run()
            XCTFail("the failed move must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be set aside"), error.localizedDescription)
        }
        XCTAssertEqual(coordinator.phase, .verifying(.manual), "nothing moved, so the swap phase was rolled back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.app.path), "the running bundle stayed put")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(AppUpdater.incomingName).path),
                       "the staged bundle was removed")
        coordinator.finish(claim)
        XCTAssertTrue(coordinator.isIdle, "and the claim releases, so the next check can run")
    }

    /// A cancel that lands during the signature check, after staging, stops the
    /// run and leaves nothing beside the running app.
    @MainActor
    func testACancelAfterStagingRemovesTheStagedBundle() async throws {
        let coordinator = UpdateCoordinator()
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator)
        let gate = SuspendableStep()
        installer.validateStep = { _, _ in await gate.reach() }

        XCTAssertNotNil(coordinator.beginInstall(.manual))
        let run = Task { try await installer.run() }
        await harness.until { gate.reached }
        let incoming = harness.root.appendingPathComponent(AppUpdater.incomingName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path), "the candidate is staged")

        installer.cancel()
        gate.open()
        do {
            try await run.value
            XCTFail("the cancel must stop the run")
        } catch let stopped as UpdateStopped {
            XCTAssertEqual(stopped.why, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "the staged bundle was removed")
        XCTAssertEqual(harness.swaps, 0)
    }

    /// The scheduled install is `.downloading` from its first step, sidecar
    /// included. It used to read `.waiting` until the first progress report, so
    /// the person's Check for Updates took it over and a second download
    /// started beside it.
    @MainActor
    func testAScheduledInstallCannotBeTakenOverOnceItsInstallerRuns() async throws {
        let coordinator = UpdateCoordinator()
        coordinator.backgroundAllowed = { true }
        let harness = InstallerHarness()
        let installer = harness.installer(coordinator: coordinator, origin: .background)
        let gate = SuspendableStep()
        installer.downloadStep = { _, _, _ in await gate.reach() }

        let claim = try XCTUnwrap(coordinator.beginInstall(.background, waiting: true))
        let run = Task { try await installer.run() }
        await harness.until { gate.reached }

        XCTAssertEqual(coordinator.phase, .downloading(.background, written: 0, expected: 0))
        XCTAssertNil(coordinator.beginCheck(.manual), "a download in flight is not taken over")
        XCTAssertTrue(coordinator.isCurrent(claim))
        installer.cancel()
        gate.open()
        _ = try? await run.value
        coordinator.finish(claim)
    }

    /// A run that was taken over clears only its own download stop. Its
    /// `defer` used to erase the hook the run that replaced it had installed,
    /// so the person's Cancel no longer stopped their download.
    @MainActor
    func testAStaleRunCannotClearTheLiveRunsDownloadStop() throws {
        let coordinator = UpdateCoordinator()
        let stale = try XCTUnwrap(coordinator.beginInstall(.background, waiting: true))
        var staleStops = 0
        coordinator.setCancelDownload(stale) { staleStops += 1 }

        let live = try XCTUnwrap(coordinator.beginCheck(.manual), "the person takes over the quiet wait")
        var liveStops = 0
        coordinator.setCancelDownload(stale) { staleStops += 1 }
        coordinator.setCancelDownload(live) { liveStops += 1 }
        coordinator.clearCancelDownload(stale)

        coordinator.cancel()
        XCTAssertEqual(liveStops, 1, "the live run's download stop survived the stale run's cleanup")
        XCTAssertEqual(staleStops, 0, "and a stale run cannot install one")
        coordinator.finishCheck(live)
    }

    // MARK: - 4. a lookup never blocks the person's click

    /// The scheduled path may be looking up the release or waiting out its quiet
    /// window; neither is an install, so the person's Check for Updates is not
    /// refused. The scheduled run is superseded and steps down.
    @MainActor
    func testAManualCheckIsNotRefusedByABackgroundLookupOrQuietWait() throws {
        for inQuietWait in [false, true] {
            let coordinator = UpdateCoordinator()
            let scheduled = try XCTUnwrap(coordinator.beginCheck(.background))
            if inQuietWait { XCTAssertNotNil(coordinator.beginInstall(.background, waiting: true)) }

            let manual = try XCTUnwrap(coordinator.beginCheck(.manual),
                                       "the person's click is never answered 'in progress' by a lookup")
            XCTAssertFalse(coordinator.isCurrent(scheduled))
            XCTAssertThrowsError(try coordinator.checkContinue(scheduled)) { error in
                XCTAssertEqual(error as? UpdateStopped, UpdateStopped(why: .superseded),
                               "the scheduled run steps down at its next boundary")
            }
            coordinator.finishCheck(manual)
            XCTAssertTrue(coordinator.isIdle)
        }
    }

    // MARK: - 7. the quiet wait is its own phase

    /// The scheduled install used to report `.downloading(written: 0, expected: 0)`
    /// while it sat in its quiet wait, which the progress window rendered as a
    /// download that had not started. It is a claim with nothing downloading, so
    /// it says so.
    @MainActor
    func testAScheduledInstallInItsQuietWaitSaysSoAndCannotMoveOn() throws {
        let coordinator = UpdateCoordinator()
        let claim = try XCTUnwrap(coordinator.beginInstall(.background, waiting: true))
        XCTAssertEqual(coordinator.phase, .waiting(.background))
        XCTAssertTrue(coordinator.isInstalling(.background), "the quiet wait is an install claim")
        if case .downloading = coordinator.phase {
            XCTFail("the quiet wait is not a download: it reports no bytes because none are moving")
        }
        coordinator.step(.downloading(.background, written: 10, expected: 100), for: claim)
        XCTAssertEqual(coordinator.phase, .downloading(.background, written: 10, expected: 100))
    }

    // MARK: - 8. the stop reason travels on the error

    /// The scheduled path used to answer a stop with `catch is UpdateStopped` and
    /// then guess the reason from the coordinator's flags — which belong to
    /// whichever run holds the claim by then, so a superseded run logged the
    /// wrong one. The thrown error carries the reason.
    func testEveryStopReasonIsDistinctAndSelfDescribing() {
        let reasons: [(UpdateStopped.Why, String)] = [
            (.cancelled, "cancelled"),
            (.disabled, "automatic updates"),
            (.superseded, "Check for Updates"),
        ]
        for (why, fragment) in reasons {
            let stopped = UpdateStopped(why: why)
            let text = try? XCTUnwrap(stopped.errorDescription)
            XCTAssertTrue((text ?? "").localizedCaseInsensitiveContains(fragment),
                          "\(why) explains itself: \(text ?? "nil")")
        }
        XCTAssertEqual(Set(reasons.map(\.0)), [.cancelled, .disabled, .superseded],
                       "no two stops share a reason")
    }

    /// The scheduled path logs the reason from the thrown error and never
    /// re-reads the coordinator's flags: with the claim already taken over, a
    /// flag read would blame the wrong thing.
    func testTheBackgroundPathTakesTheStopReasonFromTheError() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/BackgroundUpdates.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("catch let stopped as UpdateStopped"),
                      "the stop is caught with its reason bound")
        XCTAssertTrue(source.contains("logStopped(stopped.why)"),
                      "and the reason passed on from the error")
        XCTAssertFalse(source.contains("stoppedReason("),
                       "nothing guesses the reason back from the coordinator's flags")
        XCTAssertFalse(source.contains("catch is UpdateStopped"),
                       "a bare catch would discard the reason")
        XCTAssertTrue(source.contains("coordinator.stopReason(claim)"),
                      "the quiet wait's stop asks the machine through this run's own claim")
    }

    // MARK: - fixtures

    /// The offline installer: every disk and network step is a seam, and the
    /// "app" is a directory in a temp folder that the swap really renames.
    @MainActor
    private final class InstallerHarness {
        nonisolated static let digest = String(repeating: "a", count: 64)
        let root: URL
        let app: URL
        /// The running bundle was renamed aside: the swap really happened on
        /// disk, so the count is the filesystem's, not a seam's.
        var swaps: Int {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(AppUpdater.previousName).path) ? 1 : 0
        }
        let release = ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(InstallerHarness.digest),
            expectedBytes: nil,
            notes: nil
        )

        init() {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("krs-updater-\(UUID().uuidString)", isDirectory: true)
            root = base
            app = base.appendingPathComponent("Keysrs.app", isDirectory: true)
            try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }

        func installer(coordinator: UpdateCoordinator, origin: UpdateOrigin = .manual) -> UpdateInstaller {
            let installer = UpdateInstaller(release: release, app: app, coordinator: coordinator, origin: origin)
            installer.downloadStep = { _, _, _ in }
            installer.sha256Step = { _ in InstallerHarness.digest }
            installer.mountStep = { _, mount in
                let candidate = mount.appendingPathComponent("Keysrs.app", isDirectory: true)
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                return mount.path
            }
            installer.unmountStep = { _, _ in }
            installer.versionStep = { _, _ in }
            let counter = StageCounter()
            installer.stageStep = { _, incoming in
                counter.bump()
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            }
            self.stages_ = counter
            installer.validateStep = { _, _ in }
            installer.spawn = { _ in }
            return installer
        }

        /// How many times the candidate was staged, counted by a seam: the
        /// `@Sendable` step cannot touch the harness itself.
        var stages: Int { stages_?.count ?? 0 }
        private var stages_: StageCounter?

        func until(_ condition: @escaping () -> Bool) async {
            for _ in 0..<1_000 where !condition() {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private final class StageCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func bump() { lock.withLock { attempts += 1 } }
        var count: Int { lock.withLock { attempts } }
    }

    /// The progress sink held past its run's end, as a queued `@MainActor` hop
    /// from the URL session's delegate queue is.
    @MainActor
    private final class LateSink {
        private(set) var sink: (@MainActor @Sendable (Double, Int64) -> Void)?
        func hold(_ sink: @escaping @MainActor @Sendable (Double, Int64) -> Void) { self.sink = sink }
        func fire(fraction: Double, expected: Int64) { sink?(fraction, expected) }
    }

    /// A verification step that suspends until the test opens it, so the test
    /// can act while the run is mid-verification.
    private final class SuspendableStep: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false
        private var didReach = false

        var reached: Bool { lock.withLock { didReach } }

        func reach() async {
            await withCheckedContinuation { pending in
                lock.withLock {
                    didReach = true
                    if opened { return pending.resume() }
                    waiting = pending
                }
            }
        }

        func open() {
            let pending = lock.withLock {
                opened = true
                let saved = waiting
                waiting = nil
                return saved
            }
            pending?.resume()
        }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func bump() { lock.withLock { attempts += 1 } }
        var count: Int { lock.withLock { attempts } }
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let range = range(of: needle, range: search) {
            found.append(range)
            guard range.upperBound < endIndex else { break }
            search = range.upperBound..<endIndex
        }
        return found
    }
}

private extension UpdateInstallerTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// Always idle, so a rig can build a background updater without scripting a
/// timeline.
private struct IdleActivity: UpdateActivitySource {
    var busy: Bool { false }
    var lastBusy: Date? { nil }
}
