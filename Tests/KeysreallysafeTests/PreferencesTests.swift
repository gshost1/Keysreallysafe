import Foundation
import XCTest
@testable import KeysCore

/// The background Claude /usage refresh is opt-in, and the welcome window asks
/// each question once: an unticked box is an answer.
final class PreferencesTests: XCTestCase {
    func testAppSettingsDefaultToAutomaticUpdatesAndRememberLoginRegistration() throws {
        let (db, directory) = try makeDB()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefs = AppPreferences(catalog: db)
        // The 0.14 headless defaults: meter off, menu-bar item off, automatic
        // update installs on.
        XCTAssertFalse(prefs.showUsageMeter)
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
        try prefs.setShowUsageMeter(true)
        let reopened = AppPreferences(catalog: db)
        XCTAssertTrue(reopened.showUsageMeter, "the meter choice survives reopening the store")
        XCTAssertFalse(reopened.menubarItem, "changing one value leaves the other two at their defaults")
        XCTAssertTrue(reopened.updateChecks)
        try reopened.setMenubarItem(true)
        try reopened.setUpdateChecks(false)
        let third = AppPreferences(catalog: db)
        XCTAssertTrue(third.showUsageMeter)
        XCTAssertTrue(third.menubarItem)
        XCTAssertFalse(third.updateChecks)
    }

    // VAL-H-005: a 0.13 store wrote "off" for update checks only after an explicit
    // turn-off, and the headless-defaults migration force-wrote "on" over it — a
    // stored answer must survive; only an absent value is defaulted.
    func testHeadlessDefaultsMigrateOnceAndPreserveUnrelatedState() throws {
        let (db, _) = try makeDB()
        // A 0.13-shaped store: the welcome answered, the analytics question
        // already asked for the current consent version, Claude refresh on,
        // cards hidden, the relay's keep-awake chosen, update checks explicitly
        // turned off, and usage rows in the catalog.
        try db.setMeta(AppPreferences.welcomeKey, "2026-10-01T00:00:00Z")
        try db.setMeta(AppPreferences.analyticsAskedKey, String(ProductAnalytics.consentVersion))
        try db.setMeta(AppPreferences.claudeRefreshKey, "on")
        try db.setMeta(AppPreferences.hiddenUsageKey, #"["openai"]"#)
        try db.setMeta(AppPreferences.relayStayAwakeKey, "on")
        try db.setMeta("pref_update_checks", "off")
        let before = try db.allUsageEvents()
        let prefs = AppPreferences(catalog: db)
        try prefs.applyHeadlessDefaults()
        XCTAssertFalse(prefs.showUsageMeter, "the meter is off after the migration")
        XCTAssertFalse(prefs.menubarItem)
        XCTAssertFalse(prefs.updateChecks, "an explicitly stored \"off\" survives the migration; only an absent value is defaulted")
        XCTAssertEqual(try db.allUsageEvents(), before, "usage rows survive the migration untouched")
        XCTAssertTrue(prefs.claudeUsageRefresh, "an unrelated preference keeps its answer")
        XCTAssertEqual(prefs.hiddenUsage, ["openai"])
        XCTAssertTrue(prefs.relayStayAwake)
        XCTAssertTrue(prefs.welcomePlan(analyticsEnabled: false).isEmpty, "the answered welcome is not asked again")

        // The migration marker holds: choices made after it are never overwritten.
        try prefs.setMenubarItem(true)
        try prefs.setUpdateChecks(false)
        try prefs.applyHeadlessDefaults()
        XCTAssertFalse(prefs.showUsageMeter)
        XCTAssertTrue(prefs.menubarItem, "a later launch does not reapply defaults over the user's choice")
        XCTAssertFalse(prefs.updateChecks)
    }

    func testFreshStoreMigrationWritesTheSameDefaults() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        try prefs.applyHeadlessDefaults()
        XCTAssertFalse(prefs.showUsageMeter)
        XCTAssertFalse(prefs.menubarItem)
        XCTAssertTrue(prefs.updateChecks)
        // A second application is a no-op, not a reset.
        try prefs.setShowUsageMeter(true)
        try prefs.applyHeadlessDefaults()
        XCTAssertTrue(prefs.showUsageMeter)
    }

    func testClaudeRefreshIsOffUntilTurnedOn() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        XCTAssertFalse(prefs.claudeUsageRefresh)
        try prefs.setClaudeUsageRefresh(true)
        XCTAssertTrue(AppPreferences(catalog: db).claudeUsageRefresh, "another process sees the choice")
        try prefs.setClaudeUsageRefresh(false)
        XCTAssertFalse(prefs.claudeUsageRefresh)
    }

    func testWelcomeAsksOnceAndRecordsTheAnswer() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        let first = prefs.welcomePlan(analyticsEnabled: false)
        XCTAssertEqual(first, .init(firstRun: true, askAnalytics: true))
        try prefs.recordWelcome(first, claudeRefresh: false)
        XCTAssertTrue(prefs.welcomePlan(analyticsEnabled: false).isEmpty, "declining is not asked again")
        XCTAssertFalse(prefs.claudeUsageRefresh, "Continue with nothing ticked keeps it off")
    }

    func testAnalyticsQuestionReturnsOnlyForANewConsentVersion() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        // Someone who answered the welcome under an older consent version.
        try db.setMeta(AppPreferences.welcomeKey, "2026-09-01T00:00:00Z")
        try db.setMeta(AppPreferences.claudeRefreshKey, "on")
        try db.setMeta(AppPreferences.analyticsAskedKey, String(ProductAnalytics.consentVersion - 1))
        let later = prefs.welcomePlan(analyticsEnabled: false)
        XCTAssertEqual(later, .init(firstRun: false, askAnalytics: true))
        try prefs.recordWelcome(later, claudeRefresh: false)
        XCTAssertTrue(prefs.claudeUsageRefresh, "answering analytics does not touch the Claude choice")
        XCTAssertTrue(prefs.welcomePlan(analyticsEnabled: false).isEmpty)
        XCTAssertFalse(AppPreferences(catalog: try makeDB().0).welcomePlan(analyticsEnabled: true).askAnalytics,
                       "someone who already opted in is not asked")
    }

    // MARK: - The token-gated preferences and Quit routes

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testPreferencesRouteReadsAndWritesThePersistedChoices() throws {
        let (handler, service, _) = try makeHandler()
        let initial = try object(handle(handler, method: "GET", path: "/api/preferences"))
        XCTAssertEqual(initial["show_usage_meter"] as? Bool, false)
        XCTAssertEqual(initial["menubar_item"] as? Bool, false)
        XCTAssertEqual(initial["update_checks"] as? Bool, true, "Install updates automatically is on by default")

        let written = try object(handle(
            handler, method: "POST", path: "/api/preferences/show-usage-meter",
            body: try JSONValue.data(["on": true])
        ))
        XCTAssertEqual(written["show_usage_meter"] as? Bool, true, "the write answers the persisted state")
        XCTAssertTrue(service.preferences.showUsageMeter)
        XCTAssertFalse(service.preferences.menubarItem, "one write leaves the other choices alone")
        XCTAssertTrue(service.preferences.updateChecks)
    }

    func testPreferencesWritesWithoutThePageTokenAreRefused() throws {
        let (handler, service, _) = try makeHandler()
        for path in ["/api/preferences/show-usage-meter", "/api/preferences/menubar-item",
                     "/api/preferences/update-checks", "/api/app/quit"] {
            let refused = handle(handler, method: "POST", path: path,
                                 body: try JSONValue.data(["on": true]), token: false)
            XCTAssertEqual(refused.status, 403, path)
            XCTAssertEqual(try object(refused)["error"] as? String, "missing or bad token", path)
        }
        XCTAssertFalse(service.preferences.showUsageMeter)
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
        for path in ["/api/preferences/show-usage-meter", "/api/preferences/menubar-item",
                     "/api/preferences/update-checks"] {
            for (why, body) in bodies {
                let refused = handle(handler, method: "POST", path: path, body: body)
                XCTAssertEqual(refused.status, 400, "\(path) with \(why)")
            }
        }
        XCTAssertFalse(service.preferences.showUsageMeter, "no bad body wrote a choice")
        XCTAssertFalse(service.preferences.menubarItem)
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
