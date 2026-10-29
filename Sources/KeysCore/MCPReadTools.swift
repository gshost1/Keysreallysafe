import Foundation

/// The read tools, one group: `list_keys`, `gateway_info`, `open_app` and
/// `check_update`, registered as the one line beside `MCPVersionTool` in
/// `MCPToolRegistry.groups`. Together with `version` they are this mission's
/// whole roster.
///
/// **Construction is offline-safe.** Nothing here opens anything at init: the
/// catalog, the app control file and the release fetch are seams with production
/// defaults, so building the production roster (which every in-process test
/// does) touches neither the real catalog nor the installed app. The catalog
/// opens on the first `list_keys` call, the app is contacted per call — freshly,
/// never cached — and the release fetch runs only when `check_update` is asked
/// for. A test wires the group over its own world instead.
///
/// **No secret anywhere.** `list_keys` reads the catalog rows directly — it never
/// builds a service, so this process cannot reach a vault value, and the
/// app-bound pair relays the app's answer without ever holding a grant or client
/// token. Labels, never project paths, are the only project fact that leaves the
/// Mac; the guard's token-shape rule is the backstop over all of it.
///
/// @unchecked: the seam closures are not Sendable, but the group is constructed
/// once and called from the server's single-threaded loop, never across a
/// concurrency domain.
struct MCPReadTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "read"

    /// Opens the local catalog — `list_keys` works with the app closed, exactly
    /// like `keys list`, because the catalog rows and the client-token rows are
    /// on-disk facts both processes can read.
    private let openCatalog: () throws -> CatalogDB
    /// The control file the app-bound tools connect through. `AppConnection` is the
    /// only seam — nothing here touches the raw control client.
    private let control: URL
    /// The read-only release fetch behind `check_update`: no network session is
    /// constructed here, and the production wiring is the existing check itself.
    private let fetchLatestRelease: () throws -> ReleaseInfo
    /// The launch seams behind `AppConnection.connect()`: the app-bound tools
    /// auto-launch the installed app when no live one exists, and tests wire
    /// recording fakes so no test path ever opens the real app or sleeps.
    private let launch: AppLaunchSeam

    init(
        catalog: @escaping () throws -> CatalogDB = { try CatalogDB(path: Paths.catalogDB) },
        control: URL = ControlFile.url(),
        fetchLatestRelease: @escaping () throws -> ReleaseInfo = { try UpdateCheck.latestReleaseSync() },
        launch: AppLaunchSeam = .production
    ) {
        self.openCatalog = catalog
        self.control = control
        self.fetchLatestRelease = fetchLatestRelease
        self.launch = launch
    }

    func tools() -> [MCPTool] { [listKeys, gatewayInfo, openApp, checkUpdate] }

    /// No tool takes an input; unknown arguments are ignored, as the server's
    /// structural validation allows.
    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "list_keys": return try serveListKeys()
        case "gateway_info": return try serveGatewayInfo()
        case "open_app": return try serveOpenApp()
        case "check_update": return try serveCheckUpdate()
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var listKeys: MCPTool {
        MCPTool(
            name: "list_keys",
            title: "List keys",
            description: "The vault's keys: name, provider, kind, and the projects using each one, by label. "
                + "In-use projects come from active project-bound client tokens. Reads the local catalog; "
                + "the Keysrs app does not need to be running. Never returns a key value.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )
    }

    private var gatewayInfo: MCPTool {
        MCPTool(
            name: "gateway_info",
            title: "Gateway state",
            description: "The gateway's state: its base URL, whether Docker may route through it, the app's live "
                + "grants, and the active project client tokens by label with expiry and a last-4 hint. "
                + "Requires the Keysrs app to be running.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )
    }

    private var openApp: MCPTool {
        MCPTool(
            name: "open_app",
            title: "Open Keysrs",
            description: "Bring the running Keysrs app's window to the front. Requires the app to be running; "
                + "it never opens a browser.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )
    }

    private var checkUpdate: MCPTool {
        MCPTool(
            name: "check_update",
            title: "Check for updates",
            description: "Whether a newer Keysrs release is available: the current version, the latest release "
                + "and update_available. Read-only: it never downloads or installs anything.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )
    }

    // MARK: - The tools

    /// The reduced shape the mission pins: one entry per catalog row holding
    /// exactly name, provider, kind and the in-use project labels. The model has
    /// no per-key last-4 and no per-key expiry, so none is invented here; and the
    /// projects are labels only — the canonical folder paths stay in the catalog.
    private func serveListKeys() throws -> MCPToolResult {
        let catalog = try openCatalog()
        let now = Date()
        var keys: [[String: Any]] = []
        for row in try catalog.listCatalog() {
            keys.append([
                "name": row.name,
                "provider": row.provider,
                "kind": row.kind,
                "projects": Project.inUseLabels(clients: try catalog.gatewayClients(keyName: row.name), now: now),
            ])
        }
        return try MCPToolResult.json(["keys": keys])
    }

    /// The app holds the live truth — grants live only in its memory, and it owns
    /// the window and the docker preference — so this is one call, relayed whole.
    /// Without the app the call fails AS A WHOLE with the not-running sentence:
    /// `gateway_info` reports live grants, and "no grants" must never be
    /// indistinguishable from "cannot see grants", so a partial answer (base URL
    /// and tokens without grants) is never emitted.
    private func serveGatewayInfo() throws -> MCPToolResult {
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/gateway_info", body: [:], expect: 200)
        )
    }

    /// The dedicated app-side show path, and nothing else: the app fronts its own
    /// window and answers ok; no window means nothing happened, still ok. There is
    /// deliberately no browser fallback on that path, and this tool never opens
    /// one either. With no app up, `connect()` launches it and waits for a healthy
    /// control endpoint first; if that launch fails the call is the plain
    /// not-running result and no show is attempted.
    private func serveOpenApp() throws -> MCPToolResult {
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/app/show", body: [:], expect: 200)
        )
    }

    /// One fetch, one comparison, nothing else: the current version (the single
    /// constant), the latest the release says, and whether the latest is newer.
    /// The fetch sits behind the injected seam, and every failure it reports
    /// becomes this tool's plain error — the download-and-swap path of the app's
    /// own updater is not reachable from here, so nothing is fetched beyond the
    /// release page, nothing is written, and the app is left running.
    private func serveCheckUpdate() throws -> MCPToolResult {
        let latest = try fetchLatestRelease()
        let current = ProductAnalyticsConfiguration.appVersion
        return try MCPToolResult.json([
            "current": current,
            "latest": latest.version,
            "update_available": UpdateCheck.isNewer(latest.version, than: current),
        ])
    }
}
