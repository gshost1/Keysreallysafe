import Foundation

/// The feedback group: `send_feedback`, the tool the frozen server instructions
/// point at ("After a failure, offer send_feedback but never send it"). The
/// tool is a thin delegate by design: the scrub runs IN THE APP, BY THE APP,
/// because only the app can enumerate the vault's values, and this process
/// must never hold one. It validates the three arguments locally — so a bad
/// call is refused with no round trip and nothing opened — posts the raw
/// draft to the app's feedback route over the one control channel, and relays
/// the app's whole answer: the scrubbed text, the per-category removal counts,
/// the destination and `opened`. No Touch ID anywhere on the path (scrubbing
/// removes secrets, it never reveals one), no handover exemption, and the
/// scrubbed text passes the output guard by construction.
///
/// **Construction is offline-safe.** Nothing here opens anything at init: the
/// control file is read per call, freshly, through `AppConnection`.
///
/// @unchecked: the group is constructed once and called from the server's
/// single-threaded loop, never across a concurrency domain.
struct MCPFeedbackTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "feedback"

    /// The control file the app is reached through. `AppConnection` is the
    /// only seam — the same one every app-bound tool routes through.
    private let control: URL

    init(control: URL = ControlFile.url()) {
        self.control = control
    }

    func tools() -> [MCPTool] { [sendFeedback] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "send_feedback": return try serveSendFeedback(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var sendFeedback: MCPTool {
        MCPTool(
            name: "send_feedback",
            title: "Send feedback",
            description: "Send feedback about Keysrs: the running app scrubs the draft first (key "
                + "values, Keysrs token shapes, provider-key-shaped strings, paths, key names, project "
                + "labels, emails and whatever the prompt argument marks are removed, over-length text "
                + "is capped), adds the Keysrs and macOS version, and opens the user's mail client "
                + "(destination \"email\", the default) or the GitHub issue page (destination \"github\") "
                + "prefilled with the scrubbed text. Returns the scrubbed text and per-category removal "
                + "counts. Requires the app; no Touch ID. The prompt argument's exact text is removed "
                + "from the draft as prompt text. Keysrs never submits the feedback: the user reviews "
                + "and sends it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "draft": ["type": "string"],
                    "destination": ["type": "string", "enum": ["email", "github"]],
                    "prompt": ["type": "string"],
                ] as [String: Any],
                "required": ["draft"],
                "additionalProperties": false,
            ]
        )
    }

    /// The three arguments are checked here, so a bad call is refused locally —
    /// no round trip, nothing opened — and the app re-validates them its side
    /// (house style: the route never trusts a caller's types). Everything else
    /// is the app's to do: the vault enumeration and the scrub must happen
    /// where the values live.
    private func serveSendFeedback(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let raw = arguments["draft"], !(raw is NSNull) else {
            throw AppError.usage("draft is required")
        }
        guard let draft = raw as? String, !draft.isEmpty else {
            throw AppError.usage("draft must be a non-empty string")
        }
        var body: [String: Any] = ["draft": draft]
        if let raw = arguments["destination"], !(raw is NSNull) {
            guard let destination = raw as? String, destination == "email" || destination == "github" else {
                throw AppError.usage("destination must be email or github")
            }
            body["destination"] = destination
        }
        if let raw = arguments["prompt"], !(raw is NSNull) {
            guard let prompt = raw as? String else {
                throw AppError.usage("prompt must be a string")
            }
            body["prompt"] = prompt
        }
        let app = try AppConnection.connect(control: control)
        return try MCPToolResult.json(
            try app.call(method: "POST", path: "/api/mcp/feedback", body: body, expect: 200)
        )
    }
}
