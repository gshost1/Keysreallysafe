import Foundation
import XCTest
@testable import KeysCore

/// The persisted app choices, the one-time headless migration, and the welcome
/// window that is asked once.
final class PreferencesTests: XCTestCase {
    func testAppSettingsDefaultToAutomaticUpdatesAndRememberLoginRegistration() throws {
        let (db, directory) = try makeDB()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefs = AppPreferences(catalog: db)
        // The 0.14 headless defaults: menu-bar item off, automatic update
        // installs on.
        XCTAssertFalse(prefs.menubarItem)
        XCTAssertTrue(prefs.updateChecks, "Install updates automatically is the fresh default")
        XCTAssertFalse(prefs.loginRegistrationAttempted)
        try prefs.setUpdateChecks(true)
        try prefs.recordLoginRegistration()
        let reopened = AppPreferences(catalog: db)
        XCTAssertTrue(reopened.updateChecks)
        XCTAssertTrue(reopened.loginRegistrationAttempted)
        try reopened.setUpdateChecks(false)
        XCTAssertFalse(prefs.updateChecks)
    }

    func testNewSettingsPersistIndependently() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        try prefs.setMenubarItem(true)
        let reopened = AppPreferences(catalog: db)
        XCTAssertTrue(reopened.menubarItem, "the item choice survives reopening the store")
        XCTAssertTrue(reopened.updateChecks, "changing one value leaves the other at its default")
        try reopened.setUpdateChecks(false)
        let third = AppPreferences(catalog: db)
        XCTAssertTrue(third.menubarItem)
        XCTAssertFalse(third.updateChecks)
    }

    // VAL-H-005: a 0.13 store wrote "off" for update checks only after an explicit
    // turn-off, and the headless-defaults migration force-wrote "on" over it — a
    // stored answer must survive; only an absent value is defaulted.
    func testHeadlessDefaultsMigrateOnceAndPreserveUnrelatedState() throws {
        let (db, _) = try makeDB()
        // A 0.13-shaped store: the welcome answered, the relay's keep-awake
        // chosen, update checks explicitly turned off, and usage rows in the
        // catalog.
        try db.setMeta(AppPreferences.welcomeKey, "2026-10-01T00:00:00Z")
        try db.setMeta(AppPreferences.relayStayAwakeKey, "on")
        try db.setMeta("pref_update_checks", "off")
        let before = try db.allUsageEvents()
        let prefs = AppPreferences(catalog: db)
        try prefs.applyHeadlessDefaults()
        XCTAssertFalse(prefs.menubarItem, "the menu-bar item is off after the migration")
        XCTAssertFalse(prefs.updateChecks, "an explicitly stored \"off\" survives the migration; only an absent value is defaulted")
        XCTAssertEqual(try db.allUsageEvents(), before, "usage rows survive the migration untouched")
        XCTAssertTrue(prefs.relayStayAwake, "an unrelated preference keeps its answer")
        XCTAssertTrue(prefs.welcomePlan().isEmpty, "the answered welcome is not asked again")

        // The migration marker holds: choices made after it are never overwritten.
        try prefs.setMenubarItem(true)
        try prefs.setUpdateChecks(false)
        try prefs.applyHeadlessDefaults()
        XCTAssertTrue(prefs.menubarItem, "a later launch does not reapply defaults over the user's choice")
        XCTAssertFalse(prefs.updateChecks)
    }

    func testFreshStoreMigrationWritesTheSameDefaults() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        try prefs.applyHeadlessDefaults()
        XCTAssertFalse(prefs.menubarItem)
        XCTAssertTrue(prefs.updateChecks)
        // A second application is a no-op, not a reset.
        try prefs.setMenubarItem(true)
        try prefs.applyHeadlessDefaults()
        XCTAssertTrue(prefs.menubarItem)
    }

    func testWelcomeAsksOnceAndRecordsTheAnswer() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        let first = prefs.welcomePlan()
        XCTAssertEqual(first, .init(firstRun: true))
        try prefs.recordWelcome(first)
        XCTAssertTrue(prefs.welcomePlan().isEmpty, "the welcome is not asked again")
    }

    /// An upgrade from a release with product analytics: its consent, unsent reports,
    /// comparison table and "asked" marker are deleted, and nothing else is touched.
    func testRetiredAnalyticsStateIsRemovedAndNothingElse() throws {
        let (db, _) = try makeDB()
        try db.setMeta("product_analytics_v1", #"{"enabled":true,"reports":[{"day":"2026-10-30"}]}"#)
        try db.setMeta("product_analytics_benchmarks", "{}")
        try db.setMeta("welcome_analytics_consent_asked", "2")
        try db.setMeta(AppPreferences.welcomeKey, "2026-09-01T00:00:00Z")
        try db.setMeta(AppPreferences.relayStayAwakeKey, "on")
        let prefs = AppPreferences(catalog: db)
        try prefs.removeRetiredAnalytics()
        for key in AppPreferences.retiredAnalyticsKeys {
            XCTAssertNil(try db.metaValue(key), key)
        }
        XCTAssertTrue(prefs.relayStayAwake)
        XCTAssertTrue(prefs.welcomePlan().isEmpty, "the welcome answer survives")
        try prefs.removeRetiredAnalytics()   // a second launch is a no-op
    }

    // MARK: - The token-gated preferences and Quit routes

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testPreferencesRouteReadsAndWritesThePersistedChoices() throws {
        let (handler, service, _) = try makeHandler()
        let initial = try object(handle(handler, method: "GET", path: "/api/preferences"))
        XCTAssertNil(initial["show_usage_meter"], "the retired meter choice is not reported")
        XCTAssertEqual(initial["menubar_item"] as? Bool, false)
        XCTAssertEqual(initial["update_checks"] as? Bool, true, "Install updates automatically is on by default")

        let written = try object(handle(
            handler, method: "POST", path: "/api/preferences/update-checks",
            body: try JSONValue.data(["on": false])
        ))
        XCTAssertEqual(written["update_checks"] as? Bool, false, "the write answers the persisted state")
        XCTAssertFalse(service.preferences.updateChecks)
        XCTAssertFalse(service.preferences.menubarItem, "one write leaves the other choices alone")

        // The plan-window meter's routes are gone, not quietly accepted.
        for (method, path) in [("POST", "/api/preferences/show-usage-meter"), ("POST", "/api/preferences/hidden-usage"),
                               ("GET", "/api/limits"), ("PUT", "/api/limits/droid/weekly"),
                               ("GET", "/api/subscriptions"), ("POST", "/api/subscriptions")] {
            let gone = handle(handler, method: method, path: path, body: try JSONValue.data(["on": true]))
            XCTAssertEqual(gone.status, 405, "\(method) \(path)")
        }
    }

    func testPreferencesWritesWithoutThePageTokenAreRefused() throws {
        let (handler, service, _) = try makeHandler()
        for path in ["/api/preferences/menubar-item", "/api/preferences/update-checks", "/api/app/quit"] {
            let refused = handle(handler, method: "POST", path: path,
                                 body: try JSONValue.data(["on": true]), token: false)
            XCTAssertEqual(refused.status, 403, path)
            XCTAssertEqual(try object(refused)["error"] as? String, "missing or bad token", path)
        }
        XCTAssertFalse(service.preferences.menubarItem)
        XCTAssertTrue(service.preferences.updateChecks, "a refused write changed nothing")
    }

    func testPreferenceTogglesRejectABodyThatIsNotOneBoolean() throws {
        let (handler, service, _) = try makeHandler()
        let bodies: [(String, Data)] = [
            ("a non-boolean on", try JSONValue.data(["on": "yes"])),
            ("a missing on", try JSONValue.data(["enabled": true])),
            ("an extra field", try JSONValue.data(["on": true, "extra": 1])),
            ("an empty body", Data()),
        ]
        for path in ["/api/preferences/menubar-item", "/api/preferences/update-checks"] {
            for (why, body) in bodies {
                let refused = handle(handler, method: "POST", path: path, body: body)
                XCTAssertEqual(refused.status, 400, "\(path) with \(why)")
            }
        }
        XCTAssertFalse(service.preferences.menubarItem, "no bad body wrote a choice")
        XCTAssertTrue(service.preferences.updateChecks)
    }

    func testPreferenceWritesDriveTheRunningAppSurfaces() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        var menubar: [Bool] = []
        var updates: [Bool] = []
        let handler = APIHandler(service: service, webRoot: web,
                                 setMenubarItem: { menubar.append($0) },
                                 setUpdateChecks: { updates.append($0) })
        _ = handle(handler, method: "POST", path: "/api/preferences/menubar-item",
                   body: try JSONValue.data(["on": true]))
        _ = handle(handler, method: "POST", path: "/api/preferences/update-checks",
                   body: try JSONValue.data(["on": false]))
        XCTAssertEqual(menubar, [true], "the menu-bar write told the running app")
        XCTAssertEqual(updates, [false], "the update write told the running app to reschedule")
        XCTAssertTrue(service.preferences.menubarItem)
        XCTAssertFalse(service.preferences.updateChecks)
    }

    func testQuitRouteAnswersBeforeTerminationIsDispatched() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let terminations = QuitScheduler()
        var terminated = 0
        let handler = APIHandler(service: service, webRoot: web,
                                 quitApp: { { terminated += 1 } },
                                 scheduleQuit: { [terminations] in terminations.schedule($0) })
        let response = handle(handler, method: "POST", path: "/api/app/quit")
        XCTAssertEqual(response.status, 200, "the dashboard Quit answers success first")
        XCTAssertEqual(try object(response)["ok"] as? Bool, true)
        XCTAssertEqual(terminated, 0, "termination waits for the response to be sent")
        XCTAssertEqual(terminations.actions.count, 1, "termination is dispatched, not run inline")
        terminations.actions.forEach { $0() }
        XCTAssertEqual(terminated, 1, "the scheduled action is the app's shutdown")
    }

    func testQuitRouteRefusesWhenNoAppOwnsTheDashboard() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        var scheduled = false
        let handler = APIHandler(service: service, webRoot: web,
                                 quitApp: { nil },
                                 scheduleQuit: { _ in scheduled = true })
        let response = handle(handler, method: "POST", path: "/api/app/quit")
        XCTAssertEqual(response.status, 409, "a site no app owns refuses to exit someone else's process")
        XCTAssertFalse(scheduled)
    }
}
