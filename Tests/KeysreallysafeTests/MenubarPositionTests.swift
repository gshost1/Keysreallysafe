import XCTest
@testable import KeysCore

final class MenubarPositionTests: XCTestCase {
    func testAbsentPositionIsSeededAndWritten() {
        let defaults = MemoryDefaults()
        let name = MenubarPosition.autosaveName
        let positionKey = MenubarPosition.positionKey(name)
        XCTAssertNil(defaults.object(forKey: positionKey))

        let decision = MenubarPosition.seedIfUnset(defaults: defaults, autosaveName: name,
                                                   preferred: MenubarPosition.preferredDistanceFromRightEdge)

        XCTAssertEqual(decision, .seeded(MenubarPosition.preferredDistanceFromRightEdge))
        XCTAssertEqual(defaults.object(forKey: positionKey) as? Double,
                       MenubarPosition.preferredDistanceFromRightEdge)
    }

    func testExistingPositionIsKeptUnchanged() {
        let defaults = MemoryDefaults()
        let name = MenubarPosition.autosaveName
        let positionKey = MenubarPosition.positionKey(name)
        let existing = 42.0
        defaults.set(existing, forKey: positionKey)

        let decision = MenubarPosition.seedIfUnset(defaults: defaults, autosaveName: name,
                                                   preferred: MenubarPosition.preferredDistanceFromRightEdge)

        XCTAssertEqual(decision, .keptExisting(existing))
        XCTAssertEqual(defaults.object(forKey: positionKey) as? Double, existing)
    }

    func testUserHiddenItemIsSkippedAndNotSeeded() {
        let defaults = MemoryDefaults()
        let name = MenubarPosition.autosaveName
        let positionKey = MenubarPosition.positionKey(name)
        defaults.set(false, forKey: MenubarPosition.visibleKey(name))

        let decision = MenubarPosition.seedIfUnset(defaults: defaults, autosaveName: name,
                                                   preferred: MenubarPosition.preferredDistanceFromRightEdge)

        XCTAssertEqual(decision, .skippedHidden)
        XCTAssertNil(defaults.object(forKey: positionKey))
    }
}

/// In-memory stand-in for the menu bar's defaults; nothing reaches ~/Library/Preferences.
final class MemoryDefaults: MenubarDefaults {
    private var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
