import Foundation

/// Choices the person makes on first launch and can change later from the menu.
/// Stored in the private catalog's `meta` table beside the analytics
/// state, so every Keysrs process (menu bar, dashboard, CLI) reads the same answer.
final class AppPreferences: @unchecked Sendable {
    static let claudeRefreshKey = "pref_claude_usage_refresh"
    static let welcomeKey = "welcome_answered_at"
    static let analyticsAskedKey = "welcome_analytics_consent_asked"
    private let catalog: CatalogDB

    init(catalog: CatalogDB) {
        self.catalog = catalog
    }

    /// Running Claude Code's `/usage` on a timer is off until the person turns it
    /// on. Without it, Claude limits come only from the cache Claude Code writes
    /// itself, or from a refresh the person asks for.
    var claudeUsageRefresh: Bool {
        (try? catalog.metaValue(Self.claudeRefreshKey)) == "on"
    }

    func setClaudeUsageRefresh(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.claudeRefreshKey, on ? "on" : "off") }
    }

    /// What the welcome window still has to ask. The analytics question appears
    /// once per consent version, unless sharing is already on: an unticked box is
    /// an answer and is not asked again.
    struct WelcomePlan: Equatable, Sendable {
        var firstRun: Bool
        var askAnalytics: Bool
        var isEmpty: Bool { !firstRun && !askAnalytics }
    }

    func welcomePlan(analyticsEnabled: Bool) -> WelcomePlan {
        let answered = (try? catalog.metaValue(Self.welcomeKey)).map { !$0.isEmpty } ?? false
        let asked = (try? catalog.metaValue(Self.analyticsAskedKey)).flatMap { Int($0) } ?? 0
        return WelcomePlan(
            firstRun: !answered,
            askAnalytics: !analyticsEnabled && asked < ProductAnalytics.consentVersion
        )
    }

    func recordWelcome(_ plan: WelcomePlan, claudeRefresh: Bool, now: Date = Date()) throws {
        try catalog.withTransaction {
            if plan.firstRun {
                try catalog.setMeta(Self.welcomeKey, UTC.iso(now))
                try catalog.setMeta(Self.claudeRefreshKey, claudeRefresh ? "on" : "off")
            }
            if plan.askAnalytics {
                try catalog.setMeta(Self.analyticsAskedKey, String(ProductAnalytics.consentVersion))
            }
        }
    }
}
