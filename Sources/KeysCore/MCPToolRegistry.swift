import Foundation

/// One tool as `tools/list` shows it. The schema is structural JSON Schema 2020-12
/// with no `$schema` key and a root object; this mission validates shape only.
struct MCPTool {
    let name: String
    let title: String?
    let description: String
    let inputSchema: [String: Any]

    func jsonObject() -> [String: Any] {
        var out: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
        if let title { out["title"] = title }
        return out
    }
}

/// What a tool hands back: content blocks plus the failure flag. This mission's
/// tools emit text blocks only, so the one-block conveniences cover everything.
struct MCPToolResult {
    let content: [[String: Any]]
    let isError: Bool
    /// The ONE value this result is permitted to carry even though the output
    /// guard's rules would otherwise reject it: the token a `grant_status` approval
    /// is handing over. Only the grants flow ever sets it; it is nil for every other
    /// result, and the guard exempts exactly this value — never a tool, never a
    /// second value in the same result. It is never serialized into the result.
    let handover: String?

    init(content: [[String: Any]], isError: Bool, handover: String? = nil) {
        self.content = content
        self.isError = isError
        self.handover = handover
    }

    /// One text block.
    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": text]], isError: false)
    }

    /// One text block holding the compact one-line JSON encoding of `value`.
    static func json(_ value: Any) throws -> MCPToolResult {
        MCPToolResult(
            content: [["type": "text", "text": String(decoding: try JSONValue.data(value), as: UTF8.self)]],
            isError: false
        )
    }

    /// One text block whose JSON carries the one value the output guard exempts for
    /// this result: the token a `grant_status` approval is handing over. The only
    /// caller is the grants flow's approved poll, and the exemption is this value
    /// for this result — never a tool, never a second value.
    static func json(_ value: Any, handover: String) throws -> MCPToolResult {
        MCPToolResult(
            content: [["type": "text", "text": String(decoding: try JSONValue.data(value), as: UTF8.self)]],
            isError: false,
            handover: handover
        )
    }

    /// One text block carrying a plain failure sentence (already formatter-scrubbed).
    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": message]], isError: true)
    }

    func jsonObject() -> [String: Any] { ["content": content, "isError": isError] }
}

/// A tool group. **This is the seam the parallel missions extend: to add a tool
/// group, create `Sources/KeysCore/MCP<Topic>Tools.swift` conforming to
/// `MCPToolGroup` and add one line to `MCPToolRegistry.groups`.** The
/// server, the output guard and the other groups stay untouched.
///
/// The contract a group must satisfy to register:
/// - `groupName` — a stable identifier, used only to name the group in a refusal
///   diagnostic.
/// - `tools()` — the group's tools in a deterministic order. Each tool's `name`
///   must match `^[a-zA-Z0-9_-]{1,64}$` and be unique across every registered
///   group; `description` is the sentence `tools/list` shows; `inputSchema` must be
///   an object-rooted JSON Schema (`"type": "object"`). A group that breaks any of
///   these is refused as a unit at registration — one diagnostic on stderr, no
///   tools from that group, and the valid groups keep serving.
/// - `call(_:arguments:)` — runs one of this group's tools. A throw becomes an
///   `isError` result; the error formatter scrubs it, so plain AppError prose is
///   fine to throw.
protocol MCPToolGroup: Sendable {
    /// The group's registration name.
    static var groupName: String { get }
    /// The tools this group serves, in a deterministic order.
    func tools() -> [MCPTool]
    /// Run one of this group's tools.
    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult
}

extension MCPToolGroup {
    /// `groupName` as an instance value, so an `any MCPToolGroup` can name itself in
    /// a refusal diagnostic (a static requirement is not reachable through the
    /// existential otherwise).
    var registeredGroupName: String { Self.groupName }
}

/// Holds the groups. The roster is deterministic — groups in list order, each
/// group's tools in their order — and one name resolves to the first group that
/// registered it, so `tools/list` and `tools/call` always agree.
///
/// Registration is contained: a group whose tools break the `MCPToolGroup` contract
/// (a name outside `^[a-zA-Z0-9_-]{1,64}$`, a non-object-rooted schema, or a name
/// another group already took) is refused as a unit. It contributes no tools, it
/// produces exactly one diagnostic, and every valid group still serves — an invalid
/// registration never takes the server down.
struct MCPToolRegistry {
    let groups: [any MCPToolGroup]
    /// One prose line per refused group, in registration order. `MCPServer` reports
    /// these on stderr before it serves anything; nothing else writes them. Empty
    /// for a clean roster.
    let diagnostics: [String]
    private let roster: [MCPTool]
    private let handlers: [String: any MCPToolGroup]

    init(groups: [any MCPToolGroup]) {
        self.groups = groups
        var roster: [MCPTool] = []
        var handlers: [String: any MCPToolGroup] = [:]
        var diagnostics: [String] = []
        for group in groups {
            let declared = group.tools()
            if let refusal = Self.refusal(declared, in: group, taken: handlers) {
                diagnostics.append(refusal)
                continue
            }
            for tool in declared {
                handlers[tool.name] = group
                roster.append(tool)
            }
        }
        self.roster = roster
        self.handlers = handlers
        self.diagnostics = diagnostics
    }

    var tools: [MCPTool] { roster }

    /// The group owning `name`, nil when no registered tool has it.
    func group(for name: String) -> (any MCPToolGroup)? { handlers[name] }

    /// The shipped groups, in registration order. **The one list to edit: a new tool
    /// group is one new file in `Sources/KeysCore/` plus one line here, and nothing
    /// else changes.** Computed so no shared non-Sendable state exists; the roster
    /// it builds is deterministic. Every group's construction is offline-safe —
    /// nothing opens a catalog or contacts the app until a tool is actually called.
    static var groups: [any MCPToolGroup] { [MCPVersionTool(), MCPReadTools(), MCPGrantTools(), MCPFeedbackTools(), MCPAnalyticsTools(), MCPRevokeTools(), MCPActivityTools()] }

    /// The server's roster. Production builds this from `groups`, so the
    /// registration line above is the only place a group is added.
    static var `default`: MCPToolRegistry { MCPToolRegistry(groups: MCPToolRegistry.groups) }

    /// The first reason `tools` cannot register as a group, or nil when the group is
    /// valid. Exactly one reason per group keeps the diagnostic count at one.
    private static func refusal(
        _ tools: [MCPTool],
        in group: any MCPToolGroup,
        taken: [String: any MCPToolGroup]
    ) -> String? {
        for tool in tools {
            guard isValidToolName(tool.name) else {
                return "refused MCP tool group \"\(group.registeredGroupName)\": tool name \"\(tool.name)\" must match ^[a-zA-Z0-9_-]{1,64}$"
            }
            guard tool.inputSchema["type"] as? String == "object" else {
                return "refused MCP tool group \"\(group.registeredGroupName)\": tool \"\(tool.name)\" needs an object-rooted inputSchema"
            }
            guard taken[tool.name] == nil else {
                return "refused MCP tool group \"\(group.registeredGroupName)\": tool \"\(tool.name)\" is already registered"
            }
        }
        return nil
    }

    /// The MCP tool-name rule, `^[a-zA-Z0-9_-]{1,64}$`, as plain Swift so no
    /// non-Sendable regex is shared.
    static func isValidToolName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
