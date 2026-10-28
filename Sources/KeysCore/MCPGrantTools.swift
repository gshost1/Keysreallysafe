import Foundation

/// The grants group: `request_grant` and `grant_status` — the two tools that can
/// mint anything, and neither of them does. `request_grant` asks the app (the only
/// issuer) to create a pending request and answers `{status:"pending", id}` while
/// the user's Touch ID prompt is up; `grant_status` polls it and, on exactly one
/// approved poll, hands over the token. Nothing here holds a secret, a key value or
/// a long-lived token, and the app's answer is relayed whole — the output guard's
/// one handover exemption is the delivered token and nothing else.
///
/// **No host input.** The host is derived from the key's row exactly as `keys grant`
/// does and shown in the prompt, because a caller-chosen host would contradict the
/// threat model. The one project fact this process sends is its own folder — the
/// app canonicalizes it and owns the projects row; the label never travels back
/// except inside the prompt the user reads.
///
/// @unchecked: the seam closures are not Sendable, but the group is constructed
/// once and called from the server's single-threaded loop, never across a
/// concurrency domain.
struct MCPGrantTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "grants"

    private let control: URL
    /// The MCP process's own project folder — the server's working directory by
    /// default — as the create body carries it. Injectable so a test names a folder
    /// it built; production never overrides it.
    private let projectFolder: () -> String
    /// The launch seams behind `AppConnection.connect()`: the grant tools
    /// auto-launch the installed app when no live one exists, and tests wire
    /// recording fakes so no test path ever opens the real app or sleeps.
    private let launch: AppLaunchSeam

    init(
        control: URL = ControlFile.url(),
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath },
        launch: AppLaunchSeam = .production
    ) {
        self.control = control
        self.projectFolder = projectFolder
        self.launch = launch
    }

    func tools() -> [MCPTool] { [requestGrant, grantStatus] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "request_grant": return try serveRequestGrant(arguments)
        case "grant_status": return try serveGrantStatus(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    /// The ask's shape: key, task, methods/paths, minutes, the two caps and the
    /// profile. No host property, by design — see the group doc above.
    private var requestGrant: MCPTool {
        MCPTool(
            name: "request_grant",
            title: "Request a grant",
            description: "Ask the user to approve a scoped, time-boxed grant for one vault key, through the "
                + "Keysrs gateway. Returns {status:\"pending\", id} immediately, before the user decides; poll "
                + "grant_status with the id. The user approves with Touch ID in the Keysrs app; the token, base "
                + "URL and auth header are handed over on exactly one approved poll. The host is the key's own "
                + "and is never an input. Denial, expiry and refusal are all plain answers, never a hang.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "task": ["type": "string"],
                    "methods": ["type": "array", "items": ["type": "string"]],
                    "paths": ["type": "array", "items": ["type": "string"]],
                    "minutes": ["type": "integer"],
                    "max_requests": ["type": "integer"],
                    "max_usd": ["type": "number"],
                    "profile": ["type": "string"],
                ] as [String: Any],
                "required": ["key"],
                "additionalProperties": false,
            ]
        )
    }

    private var grantStatus: MCPTool {
        MCPTool(
            name: "grant_status",
            title: "Poll a grant request",
            description: "Poll one request_grant ask by its id: pending, approved (the token, base_url, "
                + "auth_header and gateway_url — delivered once, on exactly this poll), approved with "
                + "delivered:true after that, denied with a reason (cancelled, failed, unavailable), expired, "
                + "or not_found. With no id, a status-only listing of the app's requests that never carries a "
                + "token in any state.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                ] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    // MARK: - The tools

    /// Forwards the ask to the app's create route over the one control channel; the
    /// app owns every validation, the projects row and the prompt. `key` is the one
    /// argument this tool checks itself, so a missing key is refused without a
    /// round trip; everything else is the app's to judge.
    private func serveRequestGrant(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let key = JSONValue.string(arguments["key"]) else {
            throw AppError.usage("key is required")
        }
        var body: [String: Any] = ["key": key, "folder": projectFolder()]
        if let task = JSONValue.string(arguments["task"]) { body["task"] = task }
        if let methods = arguments["methods"] as? [Any] { body["methods"] = methods }
        if let paths = arguments["paths"] as? [Any] { body["paths"] = paths }
        if let minutes = arguments["minutes"], !(minutes is NSNull) { body["minutes"] = minutes }
        if let maxRequests = arguments["max_requests"], !(maxRequests is NSNull) {
            body["max_requests"] = maxRequests
        }
        if let maxUsd = arguments["max_usd"], !(maxUsd is NSNull) { body["max_usd"] = maxUsd }
        if let profile = JSONValue.string(arguments["profile"]) { body["profile"] = profile }
        let app = try AppConnection.connect(control: control, launch: launch)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/grants", body: body, expect: 200)
        )
    }

    /// Polls one request, or lists every request when no id came. The approved answer
    /// carries the token, and that one value is declared as the result's handover so
    /// the output guard lets exactly it through — every other token shape in any
    /// result is the guard's to refuse.
    private func serveGrantStatus(_ arguments: [String: Any]) throws -> MCPToolResult {
        let app = try AppConnection.connect(control: control, launch: launch)
        if let id = JSONValue.string(arguments["id"]) {
            // The id shapes the route's path, so it is checked here too: anything
            // that is not the 8-hex id the app issued is a plain refusal, never a
            // mangled request to the app.
            guard id.count == 8, id.allSatisfy({ $0.isHexDigit }) else {
                throw AppError.usage("grant_status takes the request's 8-character id")
            }
            let answer = try app.call(method: "POST", path: "/api/mcp/grants/\(id)/status", body: [:], expect: 200)
            if let token = answer["token"] as? String {
                return try MCPToolResult.json(answer, handover: token)
            }
            return try MCPToolResult.json(answer)
        }
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/grants/status", body: [:], expect: 200)
        )
    }
}
