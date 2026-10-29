import Foundation

/// The revocation group: `revoke_all` and `revoke_project`, the two kill
/// switches. Both are app-bound — grants live only in the running app's
/// memory, and client-token revocation stays in the app process alongside them
/// — so this group is a thin delegate: it validates the one argument locally,
/// posts to the app's route and relays the bounded counts. Revocation only
/// removes access, so neither tool ever asks for Touch ID, exactly like the
/// revoke paths that already existed.
///
/// **Construction is offline-safe.** Nothing here opens anything at init: the
/// control file is read per call, freshly, through `AppConnection`.
///
/// @unchecked: the group is constructed once and called from the server's
/// single-threaded loop, never across a concurrency domain.
struct MCPRevokeTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "revoke"

    /// The control file the app is reached through, or nil to resolve the
    /// default inside `AppConnection.connect()` at call time — a Swift default
    /// argument cannot throw, so construction stays offline-safe and the
    /// tripwire-checked resolution (VAL-G-003) happens per call. `AppConnection`
    /// is the only seam — the same one every app-bound tool routes through.
    private let control: URL?
    /// The launch seams behind `AppConnection.connect()`: the app-bound tools
    /// auto-launch the installed app when no live one exists, and tests wire
    /// recording fakes so no test path ever opens the real app or sleeps.
    private let launch: AppLaunchSeam

    init(control: URL? = nil, launch: AppLaunchSeam = .production) {
        self.control = control
        self.launch = launch
    }

    func tools() -> [MCPTool] { [revokeAll, revokeProject] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "revoke_all": return try serveRevokeAll(arguments)
        case "revoke_project": return try serveRevokeProject(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var revokeAll: MCPTool {
        MCPTool(
            name: "revoke_all",
            title: "Revoke everything",
            description: "The kill switch: revoke every active grant and client token at once, or — with "
                + "key — only that vault key's grants and client tokens. Requires the app; no Touch ID, "
                + "because revocation only removes access. Answers {revoked_grants, revoked_clients}: counts "
                + "of what was still live and is now dead, so a second call answers zeros. Afterwards the "
                + "grants stop authorizing and the client tokens are refused. The vault's keys themselves "
                + "are untouched — this ends access, it never deletes a key.",
            inputSchema: [
                "type": "object",
                "properties": ["key": ["type": "string"]] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    private var revokeProject: MCPTool {
        MCPTool(
            name: "revoke_project",
            title: "Revoke a project's client tokens",
            description: "Revoke one project's active client tokens by their label — client tokens only: "
                + "grants carry no project and are untouched. Requires the app; no Touch ID. An unknown "
                + "label is a not-found error; a known label with nothing active answers "
                + "{revoked_clients: 0}. Answers {revoked_clients}.",
            inputSchema: [
                "type": "object",
                "properties": ["label": ["type": "string"]] as [String: Any],
                "required": ["label"],
                "additionalProperties": false,
            ]
        )
    }

    // MARK: - The tools

    /// The one argument is checked here, so a bad call is refused locally — no
    /// round trip — and the app re-validates its side (house style: the route
    /// never trusts a caller's types). A wrong-typed key must be a refusal, not
    /// a silently dropped one: dropping it would revoke EVERYTHING where the
    /// caller asked for one key. An explicitly empty key is a malformed NAME
    /// (it is a string, just not a valid one), never a quiet "all".
    private func serveRevokeAll(_ arguments: [String: Any]) throws -> MCPToolResult {
        var body: [String: Any] = [:]
        if let raw = arguments["key"], !(raw is NSNull) {
            guard let key = raw as? String else {
                throw AppError.usage("key must be a string")
            }
            try KeyName.validate(key)
            body["key"] = key
        }
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/revoke_all", body: body, expect: 200)
        )
    }

    /// The label is required here, so an empty or wrong-typed call is refused
    /// without a round trip; the app resolves the exact label and answers the
    /// one count.
    private func serveRevokeProject(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let label = JSONValue.string(arguments["label"]), !label.isEmpty else {
            throw AppError.usage("label is required")
        }
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/revoke_project", body: ["label": label], expect: 200)
        )
    }
}
