import XCTest
@testable import KeysCore

/// `keys version` is the feature-detection probe an agent runs before anything
/// else. Both it and `keys --version` used to be parse errors (exit 64), so a
/// script could not tell an old install from a new one, or a typo from a probe.
final class VersionCommandTests: XCTestCase {
    func testParseVersionCommand() throws {
        let parsed = try KeysCLI.parseAsRoot(["version"])
        let command = try XCTUnwrap(parsed as? VersionCommand)
        XCTAssertFalse(command.json, "the human line is the default")
    }

    func testParseVersionCommandWithJSONFlag() throws {
        let parsed = try KeysCLI.parseAsRoot(["version", "--json"])
        let command = try XCTUnwrap(parsed as? VersionCommand)
        XCTAssertTrue(command.json)
    }

    func testRootConfigurationArmsTheVersionFlag() {
        // swift-argument-parser prints this string and exits 0 when `--version`
        // appears, so it must hold the single version constant, not a copy.
        XCTAssertEqual(KeysCLI.configuration.version, ProductAnalyticsConfiguration.appVersion)
    }

    func testHumanLineNamesKeysrsAndTheVersion() {
        XCTAssertEqual(VersionCommand.humanLine(), "Keysrs \(ProductAnalyticsConfiguration.appVersion)")
    }

    func testJSONIsOneLineWithSortedKeys() throws {
        let line = String(decoding: try JSONValue.data(VersionCommand.jsonObject()), as: UTF8.self)
        XCTAssertFalse(line.contains("\n"), "one line, the shape every --json flag prints")
        XCTAssertEqual(line, "{\"version\":\"\(ProductAnalyticsConfiguration.appVersion)\"}")
        let object = try XCTUnwrap(try JSONValue.line(line))
        XCTAssertEqual(object["version"] as? String, ProductAnalyticsConfiguration.appVersion)
    }
}
