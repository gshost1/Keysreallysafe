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

    var updateChecks: Bool {
        // Absent means the 0.14 default: the daily check runs and installs a
        // verified release. 0.13 stored "off" only after an explicit turn-off,
        // and the one-time migration re-applies the new default below.
        ((try? catalog.metaValue(Self.updateChecksKey)) ?? "on") == "on"
    }

    func setUpdateChecks(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.updateChecksKey, on ? "on" : "off") }
    }

    static let updateChecksKey = "pref_update_checks"

    static let showUsageMeterKey = "pref_show_usage_meter"

    /// The global plan-window meter on the Usage pane. Off by default: hiding it
    /// is presentation only — the per-provider card preferences below stay
    /// independent, and ingest, totals and charts never consult it.
    var showUsageMeter: Bool { (try? catalog.metaValue(Self.showUsageMeterKey)) == "on" }

    func setShowUsageMeter(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.showUsageMeterKey, on ? "on" : "off") }
    }

    static let menubarItemKey = "pref_menubar_item"

    /// The menu-bar status item. Off by default in the headless app; an
    /// intentional off must never be read as an accidental disappearance.
    var menubarItem: Bool { (try? catalog.metaValue(Self.menubarItemKey)) == "on" }

    func setMenubarItem(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.menubarItemKey, on ? "on" : "off") }
    }

    static let notificationsAuthorizedVersionKey = "pref_notifications_authorized_version"

    /// The app version that last asked for macOS notification permission. The ask
    /// happens once per install/update: a stored version equal to the running one
    /// means the person already answered, so no second dialog is raised.
    var notificationsAuthorizedVersion: String? {
        try? catalog.metaValue(Self.notificationsAuthorizedVersionKey)
    }

    func recordNotificationsAuthorized(version: String) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.notificationsAuthorizedVersionKey, version) }
    }

    static let headlessDefaultsKey = "headless_defaults_applied"

    /// The 0.13-to-0.14 migration: the app became headless, so the meter and the
    /// menu-bar item are off until the person turns them on, and updates install
    /// automatically (the old key meant "check for updates", and its meaning
    /// changed, so the migration re-applies the default rather than carrying a
    /// stale answer over). Applied once per store, with no prompt and no
    /// keep-old-UI choice; a later launch never overwrites choices made after
    /// this one. Usage rows and every unrelated preference are left alone.
    func applyHeadlessDefaults() throws {
        guard (try? catalog.metaValue(Self.headlessDefaultsKey)) != "yes" else { return }
        try catalog.withTransaction {
            try catalog.setMeta(Self.showUsageMeterKey, "off")
            try catalog.setMeta(Self.menubarItemKey, "off")
            try catalog.setMeta(Self.updateChecksKey, "on")
            try catalog.setMeta(Self.headlessDefaultsKey, "yes")
        }
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
