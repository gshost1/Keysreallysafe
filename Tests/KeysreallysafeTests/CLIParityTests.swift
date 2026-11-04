import ArgumentParser
import Foundation
import XCTest
@testable import KeysCore

final class CLIParityTests: XCTestCase {
    func testEveryNewCommandIsRegistered() {
        let names = Set(KeysCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        for name in ["edit", "events", "prefs", "expiring", "update", "quit"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testEditNeedsSomethingToChange() throws {
        XCTAssertThrowsError(try EditCommand.parse(["demo"]).run())
        XCTAssertThrowsError(try EditCommand.parse(["demo", "--host", "a.example", "--clear-host"]).run())
    }

    func testPrefsRefusesUnknownPreferenceAndState() throws {
        XCTAssertThrowsError(try PrefsSetCommand.parse(["bogus", "on"]).run())
        XCTAssertThrowsError(try PrefsSetCommand.parse(["menubar-item", "maybe"]).run())
    }

    func testEditRefusesEmptyHost() {
        XCTAssertThrowsError(try EditCommand.parse(["demo", "--host", " "]).run())
    }

    func testTsvCellKeepsOneRowPerRecord() {
        XCTAssertEqual(tsvCell("a\tb\nc"), "a b c")
    }
}
