import Foundation

/// The activity group: `activity(window?, project?)` — recent gateway use read
/// locally from the catalog, the `list_keys` precedent. Forwarded calls are the
/// gateway's `usage_events` rows (`source='gateway'`), refusals are its
/// `gateway_denied` audit rows, and the project labels come from each key's
/// active project-bound client tokens; all three are on-disk facts, so this
/// group needs no running app — no control file is read and there is no
/// not-running answer.
///
/// **Construction is offline-safe.** Nothing here opens anything at init: the
/// catalog is a seam with a production default and the clock is injected, so
/// building the production roster touches neither the real catalog nor the
/// network. The catalog opens on the first call, freshly, never cached.
///
/// **No secret anywhere.** Rows carry a key name, project labels, counts and the
/// spend the ledger already computed — never a token, a key value, a request
/// body or a path. Labels are the only project fact that leaves the Mac; the
/// guard's token-shape rule is the backstop over all of it.
///
/// @unchecked: the seam closures are not Sendable, but the group is constructed
/// once and called from the server's single-threaded loop, never across a
/// concurrency domain.
struct MCPActivityTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "activity"

    /// The window's default and its bounds, in whole hours.
    static let defaultWindowHours = 24
    static let windowHoursRange = 1...720

    /// Opens the local catalog. `activity` works with the app closed, exactly like
    /// `keys list`, because the usage rows, the refusal rows and the client-token
    /// rows are on-disk facts both processes can read. The default resolves at
    /// CALL time through the tripwire-checked resolver, so under test isolation
    /// with no `KEYS_CATALOG` the tool refuses instead of opening the real
    /// catalog (VAL-G-003).
    private let openCatalog: () throws -> CatalogDB
    /// The clock the rolling window is measured from. Injected so a test can pin
    /// its boundaries precisely.
    private let now: () -> Date

    init(
        catalog: @escaping () throws -> CatalogDB = { try CatalogDB(path: try Paths.resolvingCatalog()) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.openCatalog = catalog
        self.now = now
    }

    func tools() -> [MCPTool] { [activity] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "activity": return try serveActivity(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var activity: MCPTool {
        MCPTool(
            name: "activity",
            title: "Recent gateway activity",
            description: "Recent gateway use, one row per key that was used: the window's forwarded "
                + "request count, its refused request count, the projects using the key by label, and "
                + "the spend the ledger already computed (priced/unpriced call counts; usd is null when "
                + "no call could be priced — an unknown cost is never shown as zero). window is whole "
                + "hours (default 24, 1 to 720); project filters to one project's label. Reads the local "
                + "catalog, so the Keysrs app does not need to be running. Never returns a token, a key "
                + "value or a request body.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "window": ["type": "integer", "minimum": 1, "maximum": 720],
                    "project": ["type": "string"],
                ] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    // MARK: - The tool

    /// The aggregation, one read of the window's calls and one of its refusals,
    /// grouped by key name. `now − window·3600` to `now`, half-open, compared as
    /// ISO strings exactly like the catalog's usage query. A key with no active
    /// project client carries an empty project list — honest, no invention.
    private func serveActivity(_ arguments: [String: Any]) throws -> MCPToolResult {
        let window = try Self.windowHours(arguments["window"])
        let filter = try Self.projectFilter(arguments["project"])
        let catalog = try openCatalog()
        let end = now()
        let start = end.addingTimeInterval(-Double(window) * 3600)

        var requests: [String: Int] = [:]
        var spend: [String: KeysService.GatewayMonth] = [:]
        for event in try catalog.usageEvents(from: UTC.iso(start), to: UTC.iso(end), source: .keys) {
            guard let key = event.keyName else { continue }
            requests[key, default: 0] += 1
            var month = spend[key] ?? KeysService.GatewayMonth()
            month.calls += 1
            if let usd = SpendQueries.gatewayUsd(event) {
                month.usd = (month.usd ?? 0) + usd
                month.pricedCalls += 1
            } else {
                month.unpricedCalls += 1
            }
            spend[key] = month
        }
        var refusals: [String: Int] = [:]
        for row in try catalog.gatewayRefusals(from: UTC.iso(start), to: UTC.iso(end)) {
            refusals[row.name, default: 0] += 1
        }

        // One row per key used in the window: a key that only refused a request, or
        // only forwarded one, is still used, so the union of both sides is the roster.
        var rows: [[String: Any]] = []
        for key in Set(requests.keys).union(refusals.keys).sorted() {
            let labels = Project.inUseLabels(clients: try catalog.gatewayClients(keyName: key), now: end)
            if let filter, !labels.contains(filter) { continue }
            rows.append([
                "key": key,
                "projects": labels,
                "requests": requests[key] ?? 0,
                "refusals": refusals[key] ?? 0,
                "spend": Self.spend(spend[key] ?? KeysService.GatewayMonth()),
            ])
        }
        return try MCPToolResult.json(["window_hours": window, "rows": rows])
    }

    /// The one spend shape, the `GatewayMonth` honesty vocabulary: the priced sum,
    /// the call counts, and `usd` nil when nothing was priced. A reported zero is a
    /// known zero; an unpriced call is unknown, never a fake $0.
    private static func spend(_ month: KeysService.GatewayMonth) -> [String: Any] {
        [
            "usd": month.usd as Any? ?? NSNull(),
            "calls": month.calls,
            "priced_calls": month.pricedCalls,
            "unpriced_calls": month.unpricedCalls,
            "kind": month.kind,
        ]
    }

    // MARK: - Argument validation

    /// `window` as whole hours: absent means the default, anything that is not a
    /// whole number in 1...720 is a local argument error, so a bad call is refused
    /// without a catalog read.
    private static func windowHours(_ raw: Any?) throws -> Int {
        guard let raw, !(raw is NSNull) else { return defaultWindowHours }
        guard let value = wholeNumber(raw), windowHoursRange.contains(value) else {
            throw AppError.usage("window must be a whole number of hours from 1 to 720")
        }
        return value
    }

    /// A JSON number that is a whole integer, or nil for anything else. A boolean is
    /// rejected explicitly: `NSNumber` would read one as 1. A fractional number is
    /// rejected because `window` is whole hours, not a duration in hours.
    private static func wholeNumber(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(number) {
            let value = number.doubleValue
            guard value == value.rounded(), value.magnitude <= Double(Int.max) else { return nil }
            return Int(value)
        }
        return number.intValue
    }

    /// `project` as an optional label: absent means no filter, a non-empty string
    /// is the exact label to keep, anything else is a local argument error. An
    /// unknown label is not an error here — it simply keeps no rows.
    private static func projectFilter(_ raw: Any?) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let label = raw as? String, !label.isEmpty else {
            throw AppError.usage("project must be a project label")
        }
        return label
    }
}
