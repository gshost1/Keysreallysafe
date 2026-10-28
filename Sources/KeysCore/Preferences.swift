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

    var updateChecks: Bool { (try? catalog.metaValue("pref_update_checks")) == "on" }

    func setUpdateChecks(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta("pref_update_checks", on ? "on" : "off") }
    }

    static let relayStayAwakeKey = "pref_relay_stay_awake"

    /// Keeping the Mac from idle sleep for relayed calls costs battery, so it is off until
    /// the person turns it on in the menu or in Settings.
    var relayStayAwake: Bool { (try? catalog.metaValue(Self.relayStayAwakeKey)) == "on" }

    func setRelayStayAwake(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.relayStayAwakeKey, on ? "on" : "off") }
    }

    static let dockerAccessKey = "pref_docker_access"

    /// Whether Docker Desktop may route through the gateway. Off until the person
    /// turns it on; the MCP surface only READS it (the `gateway_info` tool reports
    /// it), while the setter and the enforcement belong to the headless-app
    /// mission. The "on"/"off" values follow the `pref_*` convention so that
    /// setter lands beside the other toggles without a migration.
    var dockerAccess: Bool { (try? catalog.metaValue(Self.dockerAccessKey)) == "on" }

    static let hiddenUsageKey = "pref_hidden_usage"
    static let hiddenUsageMax = 64

    /// Usage cards the person turned off in Settings, by source or subscription id. The
    /// dashboard keeps its own copy per browser and mirrors it here so the menu bar, which has
    /// no browser storage, hides the same tools.
    var hiddenUsage: Set<String> {
        guard let raw = try? catalog.metaValue(Self.hiddenUsageKey),
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else { return [] }
        return Set(list)
    }

    func setHiddenUsage(_ ids: [String]) throws {
        let clean = Array(Set(ids.filter { (1...64).contains($0.count) && !$0.contains(where: \.isNewline) })).sorted()
        guard clean.count <= Self.hiddenUsageMax else { throw AppError.usage("too many hidden cards") }
        let data = try JSONSerialization.data(withJSONObject: clean)
        try catalog.withTransaction { try catalog.setMeta(Self.hiddenUsageKey, String(decoding: data, as: UTF8.self)) }
    }

    var loginRegistrationAttempted: Bool { (try? catalog.metaValue("app_login_registered")) == "yes" }

    func recordLoginRegistration() throws {
        try catalog.withTransaction { try catalog.setMeta("app_login_registered", "yes") }
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
