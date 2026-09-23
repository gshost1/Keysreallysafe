import Foundation
import XCTest
@testable import KeysCore

/// The background Claude /usage refresh is opt-in, and the welcome window asks
/// each question once: an unticked box is an answer.
final class PreferencesTests: XCTestCase {
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
        let first = prefs.welcomePlan(analyticsConfigured: false, analyticsEnabled: false)
        XCTAssertEqual(first, .init(firstRun: true, askAnalytics: false), "no collector, no analytics question")
        try prefs.recordWelcome(first, claudeRefresh: false)
        XCTAssertTrue(prefs.welcomePlan(analyticsConfigured: false, analyticsEnabled: false).isEmpty)
        XCTAssertFalse(prefs.claudeUsageRefresh, "Continue with nothing ticked keeps it off")
    }

    func testAnalyticsQuestionAppearsOnceACollectorExists() throws {
        let (db, _) = try makeDB()
        let prefs = AppPreferences(catalog: db)
        try prefs.recordWelcome(prefs.welcomePlan(analyticsConfigured: false, analyticsEnabled: false), claudeRefresh: true)
        XCTAssertTrue(prefs.claudeUsageRefresh)
        // A later build ships with a collector: ask that one question, once.
        let later = prefs.welcomePlan(analyticsConfigured: true, analyticsEnabled: false)
        XCTAssertEqual(later, .init(firstRun: false, askAnalytics: true))
        try prefs.recordWelcome(later, claudeRefresh: false)
        XCTAssertTrue(prefs.claudeUsageRefresh, "answering analytics does not touch the Claude choice")
        XCTAssertTrue(prefs.welcomePlan(analyticsConfigured: true, analyticsEnabled: false).isEmpty, "declining is not asked again")
        XCTAssertTrue(AppPreferences(catalog: try makeDB().0).welcomePlan(analyticsConfigured: true, analyticsEnabled: true).askAnalytics == false,
                      "someone who already opted in is not asked")
    }
}
