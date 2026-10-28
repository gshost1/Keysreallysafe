import Foundation
import XCTest
@testable import KeysCore

/// VAL-MCP-LIFECYCLE-010, the parse-level half: `mcp` is a registered `keys`
/// subcommand, exactly once. The process half — `keys mcp --help` exits 0 with
/// usage text, `keys mcp --bogus` exits 64, neither starts a server — is
/// `scripts/tests/test_keys_mcp_stdio.py`, which spawns the built binary.
final class McpCommandTests: XCTestCase {

    func testMCPCliSurface() {
        XCTAssertEqual(McpCommand.configuration.commandName, "mcp")
        XCTAssertFalse(McpCommand.configuration.abstract.isEmpty)
        // The subcommand list holds McpCommand exactly once; more would double-list
        // it in `keys --help`, none would make it unreachable.
        let registered = KeysCLI.configuration.subcommands
            .filter { String(describing: $0).hasSuffix("McpCommand") }
        XCTAssertEqual(registered.count, 1, "mcp appears exactly once in the subcommand list")
        // `keys --help` is generated from the same list the parse uses, so the
        // registry is the help listing.
        XCTAssertFalse(KeysCLI.configuration.subcommands.isEmpty)
    }
}
