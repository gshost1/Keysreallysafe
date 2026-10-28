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

    /// One text block carrying a plain failure sentence (already formatter-scrubbed).
    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": message]], isError: true)
    }

    func jsonObject() -> [String: Any] { ["content": content, "isError": isError] }
}

/// A tool group: one new file in Sources/KeysCore plus one line in
/// `MCPToolRegistry.default` — the seam the parallel missions extend. A throw from
/// `call` becomes an isError result; the error formatter scrubs it, so plain
/// AppError prose is fine to throw.
protocol MCPToolGroup: Sendable {
    /// The group's registration name.
    static var groupName: String { get }
    /// The tools this group serves, in a deterministic order.
    func tools() -> [MCPTool]
    /// Run one of this group's tools.
    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult
}

/// Holds the groups. The roster is deterministic — groups in list order, each
/// group's tools in their order — and one name resolves to the first group that
/// registered it, so `tools/list` and `tools/call` always agree.
struct MCPToolRegistry {
    let groups: [any MCPToolGroup]
    private let roster: [MCPTool]
    private let handlers: [String: any MCPToolGroup]

    init(groups: [any MCPToolGroup]) {
        self.groups = groups
        var roster: [MCPTool] = []
        var handlers: [String: any MCPToolGroup] = [:]
        for group in groups {
            for tool in group.tools() {
                guard handlers[tool.name] == nil else { continue }
                handlers[tool.name] = group
                roster.append(tool)
            }
        }
        self.roster = roster
        self.handlers = handlers
    }

    var tools: [MCPTool] { roster }

    /// The group owning `name`, nil when no registered tool has it.
    func group(for name: String) -> (any MCPToolGroup)? { handlers[name] }

    /// The server's roster. One line per tool group: a new group is one new file
    /// plus one line here, and nothing else changes. Computed so no shared state
    /// exists to guard; the roster it builds is deterministic.
    static var `default`: MCPToolRegistry { MCPToolRegistry(groups: [MCPVersionTool()]) }
}
