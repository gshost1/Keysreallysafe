import XCTest
@testable import KeysCore

final class MenubarPositionTests: XCTestCase {
    private func throwawayDefaults() -> (UserDefaults, String) {
        let name = "keysrs.test.menubar-position.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testAbsentPositionIsSeededAndWritten() {
        let (defaults, suite) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = MenubarPosition.autosaveName
        let positionKey = MenubarPosition.positionKey(name)
        defaults.set(false, forKey: MenubarPosition.visibleKey(name))

        let decision = MenubarPosition.seedIfUnset(defaults: defaults, autosaveName: name,
                                                   preferred: MenubarPosition.preferredDistanceFromRightEdge)

        XCTAssertEqual(decision, .skippedHidden)
        XCTAssertNil(defaults.object(forKey: positionKey))
    }
}
