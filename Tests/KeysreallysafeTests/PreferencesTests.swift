import Foundation
import XCTest
@testable import KeysCore

/// The background Claude /usage refresh is opt-in, and the welcome window asks
/// each question once: an unticked box is an answer.
final class PreferencesTests: XCTestCase {
    func testAppSettingsDefaultToNoUpdateTrafficAndRememberLoginRegistration() throws {
        let (db, directory) = try makeDB()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefs = AppPreferences(catalog: db)
        XCTAssertFalse(prefs.updateChecks)
        XCTAssertFalse(prefs.loginRegistrationAttempted)
        try prefs.setUpdateChecks(true)
        try prefs.recordLoginRegistration()
        let reopened = AppPreferences(catalog: db)
        XCTAssertTrue(reopened.updateChecks)
        XCTAssertTrue(reopened.loginRegistrationAttempted)
        try reopened.setUpdateChecks(false)
        XCTAssertFalse(prefs.updateChecks)
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
}
