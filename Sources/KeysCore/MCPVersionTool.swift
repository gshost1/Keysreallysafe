import Foundation

/// The `version` tool group: the one tool that needs neither the app nor the
/// catalog, registered as its own group to prove the seam — later groups are one
/// file like this one plus one line in `MCPToolRegistry.default`.
struct MCPVersionTool: MCPToolGroup {
    static let groupName = "version"

    func tools() -> [MCPTool] {
        [MCPTool(
            name: Self.groupName,
            title: "Keysrs version",
            description: "The installed Keysrs version, the same single version constant `keys version --json` prints.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )]
    }

    /// No input: the arguments are ignored entirely, unknown ones included.
    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        try MCPToolResult.json(VersionCommand.jsonObject())
    }
}
