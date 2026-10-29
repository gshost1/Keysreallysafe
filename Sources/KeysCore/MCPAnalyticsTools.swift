import CoreFoundation
import Foundation

/// The analytics group: `set_analytics_sharing`, the one tool that records the
/// person's answer to the onboarding analytics question ("share daily usage totals
/// and compare"). It is app-bound by design — consent lives in the app's catalog
/// meta, and the app owns the confirmation line — so this is a thin delegate that
/// posts the answer to the app's route and relays the bounded `{"enabled": <bool>}`.
/// Only "off" takes effect from here; "on" comes back as
/// `pending_user_confirmation` until the person turns it on in the app (S5).
///
/// The rule the tool name cannot enforce is pinned in the frozen server
/// instructions: the agent may call it only after the user has explicitly answered
/// the analytics question, and never enables sharing on its own. Off unless set:
/// the default state is off, and enabling transmits nothing — only the dashboard's
/// own timer uploads a report.
///
/// **Construction is offline-safe.** Nothing here opens anything at init: the
/// control file is read per call, freshly, through `AppConnection`.
///
/// @unchecked: the group is constructed once and called from the server's
/// single-threaded loop, never across a concurrency domain.
struct MCPAnalyticsTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "analytics"

    /// The control file the app is reached through, or nil to resolve the
    /// default inside `AppConnection.connect()` at call time — a Swift default
    /// argument cannot throw, so construction stays offline-safe and the
    /// tripwire-checked resolution (VAL-G-003) happens per call. `AppConnection`
    /// is the only seam — the same one every app-bound tool routes through.
    private let control: URL?
    /// The launch seams behind `AppConnection.connect()`: the app-bound tool
    /// auto-launches the installed app when no live one exists, and tests wire
    /// recording fakes so no test path ever opens the real app or sleeps.
    private let launch: AppLaunchSeam

    init(control: URL? = nil, launch: AppLaunchSeam = .production) {
        self.control = control
        self.launch = launch
    }

    func tools() -> [MCPTool] { [setAnalyticsSharing] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "set_analytics_sharing": return try serveSetAnalyticsSharing(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var setAnalyticsSharing: MCPTool {
        MCPTool(
            name: "set_analytics_sharing",
            title: "Set analytics sharing",
            description: "Record the user's answer to the analytics question: share daily aggregate usage totals "
                + "to compare, or keep them local (the default). Ask it once, after a successful import or "
                + "when the user brings it up. enabled false turns sharing off. enabled true does not turn "
                + "it on: it answers status pending_user_confirmation, and the user then turns sharing on "
                + "in the Keysrs app, whose switch is the confirmation. Never sends a report and asks for "
                + "no Touch ID. Only call this after the user has explicitly answered; never enable sharing "
                + "on your own.",
            inputSchema: [
                "type": "object",
                "properties": ["enabled": ["type": "boolean"]] as [String: Any],
                "required": ["enabled"],
                "additionalProperties": false,
            ]
        )
    }

    /// The one argument is checked here, so a bad call is refused locally — no round
    /// trip — and the app re-validates it its side (house style: the route never
    /// trusts a caller's types). An explicit JSON boolean is required: a number or a
    /// string is not an answer, and the route refuses it the same way.
    private func serveSetAnalyticsSharing(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let raw = arguments["enabled"], !(raw is NSNull) else {
            throw AppError.usage("enabled is required")
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AppError.usage("enabled must be true or false")
        }
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(
                method: "POST", path: "/api/mcp/analytics/sharing",
                body: ["enabled": number.boolValue], expect: 200
            )
        )
    }
}
