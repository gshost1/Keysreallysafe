import Foundation
@testable import KeysCore

/// A tool group defined entirely in the TEST target — its own file, registered by
/// one line in a groups list — to prove the registry seam: adding a group needs no
/// change to `MCPServer`, the guard or the other groups. Its handler answers a
/// `tools/call` round trip so the seam test can assert the whole path, not just the
/// listing.
struct MCPRegistryProbeGroup: MCPToolGroup {
    static let groupName = "registry_probe"
    static let toolName = "registry_probe"

    func tools() -> [MCPTool] {
        [MCPTool(
            name: Self.toolName,
            title: "Registry probe",
            description: "A test-only tool registered through the seam.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )]
    }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        try MCPToolResult.json(["probe": true, "echo": name])
    }
}

/// A group that must be refused at registration (VAL-MCP-REGISTRY-003): an empty
/// name, a name outside `^[a-zA-Z0-9_-]{1,64}$`, a non-object-rooted schema, or a
/// duplicate of a name another group already took. The invalid tool is the group's
/// only tool, so refusing the tool refuses the group.
/// @unchecked: the `[String: Any]` schema is not Sendable, but the group never
/// crosses a concurrency domain in these single-threaded sessions.
struct MCPRefusedToolGroup: MCPToolGroup, @unchecked Sendable {
    static let groupName = "refused_probe"

    let name: String
    let schema: [String: Any]

    init(name: String, schema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]) {
        self.name = name
        self.schema = schema
    }

    func tools() -> [MCPTool] {
        [MCPTool(name: name, title: "Refused", description: "A group that must not register.", inputSchema: schema)]
    }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        MCPToolResult.text("a refused group is never called")
    }
}
