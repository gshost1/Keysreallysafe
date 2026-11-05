import XCTest
@testable import KeysCore

/// The one update state machine both install paths claim. Three confirmed
/// bugs drove it: the manual `updating` flag and the background `inFlight` flag
/// could both be true at once and stage two installers beside the same
/// `.Keysrs.app.incoming` / `.previous` names; a scheduled check that had
/// already passed its `updateChecks` guard still installed after the person
/// turned automatic updates off; and Cancel after the DMG download stopped
/// nothing, because the cancel flag was read once, at the end of the download.
/// Every test here is offline: no download, no disk image, no signing identity,
/// no real `/Applications`.
final class UpdateCoordinatorTests: XCTestCase {

    // MARK: - one install at a time, across both paths

    /// The manual path and the scheduled path share one claim: whichever starts
    /// first holds it, and the other is refused — the bug was two installers
    /// renaming the running bundle through the same staging names.
    @MainActor
    func testTheSecondStartIsRefusedWhileAnInstallHoldsTheMachine() throws {
        let coordinator = UpdateCoordinator()
        XCTAssertTrue(coordinator.isIdle)

        let claim = try XCTUnwrap(coordinator.beginInstall(.manual), "the first install claims the idle machine")
        XCTAssertEqual(coordinator.origin, .manual)
        XCTAssertFalse(coordinator.isIdle)
        XCTAssertTrue(coordinator.isInstalling(.manual))

        XCTAssertNil(coordinator.beginInstall(.background),
                     "a scheduled install must not start beside a manual one")
        XCTAssertNil(coordinator.beginCheck(.background),
                     "nor its check: the machine is claimed either way")
        XCTAssertNil(coordinator.beginInstall(.manual), "nor a second manual install")
        XCTAssertEqual(coordinator.origin, .manual, "the first claim is untouched by the refusals")
        XCTAssertTrue(coordinator.isInstalling(.manual))
        XCTAssertTrue(coordinator.isCurrent(claim), "and the claim handed out is still the live one")
    }

    /// A release lookup holds the machine against the timer's check and against
    /// an install, so the daily check cannot start beside a lookup in flight.
    @MainActor
    func testACheckHoldsTheMachineAgainstASecondCheckAndAgainstAnInstall() throws {
        let coordinator = UpdateCoordinator()
        let lookup = try XCTUnwrap(coordinator.beginCheck(.manual))
        XCTAssertNil(coordinator.beginCheck(.manual), "two lookups cannot run at once")
        XCTAssertNil(coordinator.beginCheck(.background), "the timer cannot start one beside it")
        XCTAssertNil(coordinator.beginInstall(.background), "an install cannot start under a lookup")

        coordinator.finishCheck(lookup)
        XCTAssertTrue(coordinator.isIdle, "the lookup's own claim is released")
        XCTAssertNotNil(coordinator.beginInstall(.background), "and the machine is free again")
    }

    /// The person's click is never answered with "in progress" because the app
    /// happened to be looking at GitHub itself: their Check for Updates takes the
    /// machine over from a scheduled lookup or a scheduled quiet wait. The run
    /// that lost it stops at its next boundary and must not release the claim.
    @MainActor
    func testAManualCheckTakesOverAScheduledLookupOrWait() throws {
        for takeOver in [true, false] {
            let coordinator = UpdateCoordinator()
            let scheduled = try XCTUnwrap(coordinator.beginCheck(.background))
            if !takeOver {
                XCTAssertNotNil(coordinator.beginInstall(.background, waiting: true),
                                "the scheduled path is in its quiet wait")
            }

            let manual = try XCTUnwrap(coordinator.beginCheck(.manual),
                                       "the person's check takes the machine over")
            XCTAssertFalse(coordinator.isCurrent(scheduled), "the scheduled run's claim is superseded")
            XCTAssertEqual(coordinator.origin, .manual)

            coordinator.finishCheck(scheduled)
            XCTAssertEqual(coordinator.origin, .manual,
                           "the superseded run's finish must not release the manual claim")
            XCTAssertThrowsError(try coordinator.checkContinue(scheduled)) { error in
                XCTAssertEqual(error as? UpdateStopped, UpdateStopped(why: .superseded),
                               "the run that lost the machine steps down instead of installing")
            }
            coordinator.finishCheck(manual)
            XCTAssertTrue(coordinator.isIdle)
        }
    }

    /// An install claim is never taken over: once bytes have been downloaded or
    /// the bundle has begun to move, a second lookup would stage a second copy
    /// beside the same names.
    @MainActor
    func testAManualCheckNeverTakesOverAnInstallClaim() throws {
        let coordinator = UpdateCoordinator()
        XCTAssertNotNil(coordinator.beginInstall(.background))
        XCTAssertNil(coordinator.beginCheck(.manual), "a lookup cannot start under an install")
        XCTAssertEqual(coordinator.origin, .background)
    }

    /// The scheduled check hands its own claim to the install it starts: the
    /// daily check and the install are one non-idle stretch, and the check's
    /// `finishCheck` must not free the machine out from under the install.
    @MainActor
    func testTheScheduledChecksClaimHandsOverToItsInstall() throws {
        let coordinator = UpdateCoordinator()
        let checking = try XCTUnwrap(coordinator.beginCheck(.background))

        let installing = try XCTUnwrap(coordinator.beginInstall(.background, waiting: true),
                                       "the check's own install takes over")
        XCTAssertEqual(installing, checking, "the hand-over keeps the one claim, and so its token")
        XCTAssertTrue(coordinator.isInstalling(.background))
        XCTAssertEqual(coordinator.phase, .waiting(.background),
                       "an install that still has to wait for the Mac to be idle says so")
        coordinator.finishCheck(installing)
        XCTAssertTrue(coordinator.isInstalling(.background),
                      "the check ending must not release the install that is now running")

        coordinator.finish(installing)
        XCTAssertTrue(coordinator.isIdle)
    }

    /// The message the losing caller gets, which the manual path shows and the
    /// scheduled path logs instead of a click that does nothing.
    func testTheBusyRefusalSaysSoInWords() {
        XCTAssertEqual(UpdateBusy().localizedDescription, "update already in progress")
        XCTAssertEqual(UpdateCoordinator.busyMessage, "update already in progress")
    }

    // MARK: - cancel up to the swap, never past it

    /// Cancel is live through the download and every verification step — the
    /// run really does stop at the next boundary — and dead from the moment the
    /// running bundle begins to move. The progress window disables the button
    /// on exactly this, so the UI and the machine cannot disagree.
    @MainActor
    func testCancelIsLiveUntilTheSwapAndRefusedAfterIt() {
        XCTAssertTrue(UpdateCoordinator.Phase.checking(.manual).allowsCancel)
        XCTAssertTrue(UpdateCoordinator.Phase.downloading(.manual, written: 10, expected: 100).allowsCancel)
        XCTAssertTrue(UpdateCoordinator.Phase.verifying(.manual).allowsCancel)
        XCTAssertFalse(UpdateCoordinator.Phase.swapping(.manual).allowsCancel,
                       "the bundle is moving: there is no step left to stop at")
        XCTAssertFalse(UpdateCoordinator.Phase.relaunching(.manual).allowsCancel)
        XCTAssertFalse(UpdateCoordinator.Phase.idle.allowsCancel)
    }

    /// A refused cancel leaves the run alone: no flag, and the download is not
    /// killed mid-swap.
    @MainActor
    func testACancelAfterTheSwapMovesNothing() throws {
        let coordinator = UpdateCoordinator()
        var downloadCancels = 0
        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        coordinator.setCancelDownload(claim) { downloadCancels += 1 }
        coordinator.step(.swapping(.manual), for: claim)

        coordinator.cancel()
        XCTAssertFalse(coordinator.cancelRequested, "a cancel from `.swapping` on is refused")
        XCTAssertEqual(downloadCancels, 0, "and does not reach a download")
        XCTAssertNoThrow(try coordinator.checkContinue(claim), "the run keeps going to the relaunch")
    }

    /// A cancel during verification sets the flag and stops the download, and
    /// the boundary refuses with the silent cancellation both paths answer
    /// without an error dialog.
    @MainActor
    func testACancelDuringVerificationStopsTheNextBoundary() throws {
        let coordinator = UpdateCoordinator()
        var downloadCancels = 0
        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        coordinator.setCancelDownload(claim) { downloadCancels += 1 }
        coordinator.step(.verifying(.manual), for: claim)

        coordinator.cancel()
        XCTAssertTrue(coordinator.cancelRequested)
        XCTAssertEqual(downloadCancels, 1, "the live download, if any, is stopped too")

        XCTAssertThrowsError(try coordinator.checkContinue(claim)) { error in
            XCTAssertEqual(error as? UpdateStopped, UpdateStopped(why: .cancelled))
        }
        XCTAssertNotNil(coordinator.stopReason(claim))
    }

    /// The real installer's first boundary, with nothing downloaded: a cancel
    /// that lands before `run()` stops it before it creates a download at all.
    /// The digest checksum needs no sidecar fetch, so this runs offline.
    @MainActor
    func testTheRealInstallerStopsAtItsFirstBoundaryWhenAlreadyCancelled() async throws {
        let coordinator = UpdateCoordinator()
        let release = ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("krs-update-\(UUID().uuidString)/Keysrs.app", isDirectory: true)
        XCTAssertNotNil(coordinator.beginInstall(.manual))
        let installer = UpdateInstaller(release: release, app: app, coordinator: coordinator, origin: .manual)
        installer.cancel()

        do {
            try await installer.run()
            XCTFail("a cancelled install must not run to the swap")
        } catch let stopped as UpdateStopped {
            XCTAssertEqual(stopped.why, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path),
                       "nothing was staged or moved beside the app")
    }

    /// An installer whose claim is gone refuses to start at all, so a second
    /// run can never rename the bundle under the first one.
    @MainActor
    func testAnInstallerWithoutTheClaimRefusesToRun() async throws {
        let coordinator = UpdateCoordinator()
        let release = ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
        let installer = UpdateInstaller(
            release: release,
            app: FileManager.default.temporaryDirectory.appendingPathComponent("Keysrs.app"),
            coordinator: coordinator,
            origin: .manual
        )
        do {
            try await installer.run()
            XCTFail("an unclaimed installer must refuse")
        } catch {
            XCTAssertEqual(error as? UpdateBusy, UpdateBusy())
        }
    }

    /// The real installer also stops for the scheduled path's own setting: with
    /// automatic updates off, its first boundary refuses before anything is
    /// fetched. The digest checksum needs no sidecar download, so this is offline.
    @MainActor
    func testTheRealInstallerStopsWhenAutomaticUpdatesAreOff() async throws {
        let coordinator = UpdateCoordinator()
        coordinator.backgroundAllowed = { false }
        let release = ReleaseInfo(
            version: "99.0.0",
            dmg: URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v99.0.0/Keysrs-arm64.dmg")!,
            checksum: .digest(String(repeating: "a", count: 64)),
            expectedBytes: 1,
            notes: nil
        )
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("krs-update-\(UUID().uuidString)/Keysrs.app", isDirectory: true)
        XCTAssertNotNil(coordinator.beginInstall(.background))
        let installer = UpdateInstaller(release: release, app: app, coordinator: coordinator, origin: .background)

        do {
            try await installer.run()
            XCTFail("the scheduled install must not proceed with automatic updates off")
        } catch let stopped as UpdateStopped {
            XCTAssertEqual(stopped.why, .disabled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path),
                       "nothing was staged or moved beside the app")
    }
    // MARK: - automatic updates turned off during the scheduled install

    /// The scheduled path re-reads the person's setting at every pre-swap
    /// boundary: turning automatic updates off during the download means the
    /// release is not installed, however far the check had already got.
    @MainActor
    func testTurningAutomaticUpdatesOffStopsTheBackgroundBoundaries() throws {
        let coordinator = UpdateCoordinator()
        var allowed = true
        coordinator.backgroundAllowed = { allowed }
        let claim = try XCTUnwrap(coordinator.beginInstall(.background))
        XCTAssertNil(coordinator.stopReason(claim))

        allowed = false
        XCTAssertEqual(coordinator.stopReason(claim), .disabled, "the background run stops once the setting is off")
        XCTAssertThrowsError(try coordinator.checkContinue(claim)) { error in
            XCTAssertEqual(error as? UpdateStopped, UpdateStopped(why: .disabled))
        }
    }

    /// The manual path is the person's own click: the automatic-updates setting
    /// has no say in it.
    @MainActor
    func testTheAutomaticUpdatesSettingDoesNotStopAManualRun() throws {
        let coordinator = UpdateCoordinator()
        coordinator.backgroundAllowed = { false }
        let claim = try XCTUnwrap(coordinator.beginInstall(.manual))
        XCTAssertNil(coordinator.stopReason(claim))
        XCTAssertNoThrow(try coordinator.checkContinue(claim))
    }

    // MARK: - the wiring, pinned where it lives

    /// The boundaries have to be in `run()` and in the right order: one after
    /// the download, before anything is verified or moved — where the cancel
    /// used to be ignored — and one immediately before the first bundle move.
    /// The swap is not cancellable, so the last boundary precedes it.
    func testTheRealInstallerChecksTheMachineAtEveryBoundaryBeforeTheSwap() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppUpdater.swift"), encoding: .utf8
        )
        let boundaries = source.ranges(of: "try coordinator.checkContinue(claim)")
        XCTAssertGreaterThanOrEqual(boundaries.count, 4,
                                    "every step boundary reads the machine: cancel and the updates setting must both stop the run")

        let download = try XCTUnwrap(source.range(of: "try await downloader.download(from: release.dmg"),
                                      "the DMG download")
        let verifying = try XCTUnwrap(source.range(of: "coordinator.step(.verifying(origin), for: claim)"),
                                     "the verification phase")
        let firstMove = try XCTUnwrap(source.range(of: "fm.moveItem(at: plan.app, to: plan.previous)"),
                                     "the swap's first bundle move")
        let between = try XCTUnwrap(boundaries.first { $0.lowerBound > download.upperBound && $0.lowerBound < verifying.lowerBound },
                                    "a boundary fires between the download and verification")
        XCTAssertLessThan(download.lowerBound, between.lowerBound,
                          "the boundary where the cancel used to be ignored comes after the download")
        let lastBeforeSwap = try XCTUnwrap(boundaries.last { $0.lowerBound < firstMove.lowerBound },
                                          "a boundary fires before the running bundle starts moving")
        XCTAssertLessThan(lastBeforeSwap.lowerBound, firstMove.lowerBound,
                          "the last cancelling boundary precedes the first move")
        XCTAssertTrue(source.contains("cancelButton.isEnabled = phase.allowsCancel"),
                      "the progress window's Cancel follows the one phase: enabled while stoppable, disabled once the swap begins")
    }

    /// Both callers claim the one machine before anything is built: the manual
    /// Update Now against the background's install, which used to keep separate
    /// flags and could stage two installers at once.
    func testBothPathsClaimTheOneMachineBeforeBuildingAnything() throws {
        let window = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppWindow.swift"), encoding: .utf8
        )
        let claim = try XCTUnwrap(window.range(of: "guard let claim = coordinator.beginInstall(.manual)"))
        let build = try XCTUnwrap(window.range(of: "UpdateInstaller(release: release, app: Bundle.main.bundleURL"),
                                "the manual installer")
        XCTAssertLessThan(claim.lowerBound, build.lowerBound,
                          "Update Now claims the machine before it builds an installer")
        XCTAssertTrue(window.contains("Update Already in Progress"),
                      "a second Update Now tells the person instead of a click that does nothing")

        let background = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/BackgroundUpdates.swift"), encoding: .utf8
        )
        let backgroundClaim = try XCTUnwrap(background.range(of: "guard let claim = coordinator.beginInstall(.background, waiting: true)"))
        let backgroundTask = try XCTUnwrap(background.range(of: "Task { @MainActor in"),
                                          "the scheduled install's task")
        XCTAssertLessThan(backgroundClaim.lowerBound, backgroundTask.lowerBound,
                          "the scheduled install claims the machine before it waits or builds anything")
        XCTAssertTrue(background.contains("coordinator.stopReason(claim)"),
                      "the quiet wait re-reads the machine, on this run's own claim, before the installer is built")

        XCTAssertTrue(window.contains("background?.coordinator ?? UpdateCoordinator()"),
                      "the controller and the scheduled updater share one instance")
    }

    /// A scheduled check re-reads the setting after the release lookup, not
    /// only at the guard that armed it.
    func testAScheduledCheckRereadsTheSettingAfterTheLookup() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppWindow.swift"), encoding: .utf8
        )
        let lookup = try XCTUnwrap(source.range(of: "let release = try await latestRelease()"))
        let reread = try XCTUnwrap(source.range(of: "else if preferences.updateChecks"),
                                   "the setting is read again once the lookup returns")
        XCTAssertLessThan(lookup.lowerBound, reread.lowerBound)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
