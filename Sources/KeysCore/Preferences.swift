import Foundation

/// Choices the person makes on first launch and can change later from the menu.
/// Stored in the private catalog's `meta` table, so every Keysrs process (menu bar, dashboard, CLI) reads the same answer.
final class AppPreferences: @unchecked Sendable {
    static let welcomeKey = "welcome_answered_at"
    /// Catalog keys left by the product analytics that earlier releases shipped:
    /// the consent and unsent reports, the downloaded comparison table, and the
    /// welcome window's "asked" marker. Nothing reads them any more.
    static let retiredAnalyticsKeys = ["product_analytics_v1", "product_analytics_benchmarks", "welcome_analytics_consent_asked"]
    private let catalog: CatalogDB

    init(catalog: CatalogDB) {
        self.catalog = catalog
    }

    var updateChecks: Bool {
        // Absent means the 0.14 default: the daily check runs and installs a
        // verified release. 0.13 stored "off" only after an explicit turn-off,
        // and the one-time migration below defaults only an absent value.
        ((try? catalog.metaValue(Self.updateChecksKey)) ?? "on") == "on"
    }

    func setUpdateChecks(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.updateChecksKey, on ? "on" : "off") }
    }

    static let updateChecksKey = "pref_update_checks"

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

    /// The 0.13-to-0.14 migration: the app became headless, so the menu-bar item
    /// is off until the person turns it on, and updates install
    /// automatically. Only absent values are defaulted: 0.13 stored "off" for
    /// update checks solely after an explicit turn-off, so force-writing "on"
    /// would silently re-enable automatic installs over a choice the person
    /// made. Applied once per store, with no prompt and no keep-old-UI choice;
    /// a later launch never overwrites choices made after this one. Usage rows
    /// and every unrelated preference are left alone.
    func applyHeadlessDefaults() throws {
        guard (try? catalog.metaValue(Self.headlessDefaultsKey)) != "yes" else { return }
        try catalog.withTransaction {
            try catalog.setMeta(Self.menubarItemKey, "off")
            if try catalog.metaValue(Self.updateChecksKey) == nil {
                try catalog.setMeta(Self.updateChecksKey, "on")
            }
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

    static let relayAwakeWhileSharedKey = "pref_relay_awake_shared"

    /// Holding the Mac awake for as long as a share is live costs power for hours, not
    /// minutes, so it is off until the person turns it on, and it only ever holds on the
    /// power adapter.
    var relayAwakeWhileShared: Bool { (try? catalog.metaValue(Self.relayAwakeWhileSharedKey)) == "on" }

    func setRelayAwakeWhileShared(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.relayAwakeWhileSharedKey, on ? "on" : "off") }
    }

    static let dockerAccessKey = "pref_docker_access"

    /// Whether Docker Desktop may route through the gateway. Off until the person
    /// turns it on. The onboarding mission owns this setting's enforcement (the
    /// gateway's call-site Host acceptance) and its import-driven setter
    /// (`import_and_wrap` with `docker: true` writes "on"); the MCP surface only
    /// reads it (`gateway_info` reports it), and a dashboard toggle UI remains the
    /// headless-app mission's area. The "on"/"off" values follow the `pref_*`
    /// convention so those setters land beside the other toggles without a migration.
    var dockerAccess: Bool { (try? catalog.metaValue(Self.dockerAccessKey)) == "on" }

    /// The import-driven setter the doc comment above names: `import_and_wrap` with
    /// `docker: true` writes "on" here; the import never writes "off" (absent/false
    /// leaves whatever the person chose alone).
    func setDockerAccess(_ on: Bool) throws {
        try catalog.withTransaction { try catalog.setMeta(Self.dockerAccessKey, on ? "on" : "off") }
    }

    var loginRegistrationAttempted: Bool { (try? catalog.metaValue("app_login_registered")) == "yes" }

    func recordLoginRegistration() throws {
        try catalog.withTransaction { try catalog.setMeta("app_login_registered", "yes") }
    }

    /// What the welcome window still has to ask: only the first-run question.
    struct WelcomePlan: Equatable, Sendable {
        var firstRun: Bool
        var isEmpty: Bool { !firstRun }
    }

    func welcomePlan() -> WelcomePlan {
        let answered = (try? catalog.metaValue(Self.welcomeKey)).map { !$0.isEmpty } ?? false
        return WelcomePlan(firstRun: !answered)
    }

    /// Deletes what the removed product analytics left in the catalog, so an
    /// upgraded install keeps no queued reports. Safe to run on every launch.
    func removeRetiredAnalytics() throws {
        try catalog.withTransaction {
            for key in Self.retiredAnalyticsKeys { try catalog.deleteMeta(key) }
        }
    }

    func recordWelcome(_ plan: WelcomePlan, now: Date = Date()) throws {
        try catalog.withTransaction {
            if plan.firstRun {
                try catalog.setMeta(Self.welcomeKey, UTC.iso(now))
            }
        }
    }
}
