import AppKit
import XCTest
@testable import KeysCore

final class MenubarRecoveryTests: XCTestCase {
    @MainActor func testWakeReplacesEvenNominallyVisibleItemAndPreservesMenu() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(20))
        defer { controller.stop() }
        let original = controller.item
        original.button?.title = "C 12%  X 34%"
        original.button?.toolTip = "Usage"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Keysrs", action: nil, keyEquivalent: "")
        original.menu = menu
        original.isVisible = true
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.item === original)
        XCTAssertTrue(controller.item.isVisible)
        XCTAssertTrue(controller.item.menu === menu)
        XCTAssertEqual(controller.item.button?.title, "C 12%  X 34%")
        XCTAssertEqual(controller.item.button?.toolTip, "Usage")
        XCTAssertNil(original.menu)
    }

    @MainActor func testRecoveryWaitsForMenuToClose() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(20))
        defer { controller.stop() }
        let original = controller.item
        controller.menuIsOpen = true
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === original)
        controller.menuDidClose()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.item === original)
    }

    @MainActor func testHiddenItemRecoversButHealthyRefreshDoesNotReplaceItem() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(20))
        defer { controller.stop() }
        let original = controller.item
        original.isVisible = false
        controller.checkVisibility()
        try await Task.sleep(for: .milliseconds(150))
        let recovered = controller.item
        XCTAssertFalse(recovered === original)
        XCTAssertTrue(recovered.isVisible)
        controller.checkVisibility()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === recovered)
    }

    @MainActor func testTransitionBurstCoalescesAndStopCancelsRecovery() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(80))
        let original = controller.item
        for _ in 0..<5 {
            controller.requestRecovery(reason: "test transition")
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertTrue(controller.item === original)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.item === original)
        let recovered = controller.item
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === recovered)
        controller.requestRecovery(reason: "pending at shutdown")
        controller.stop()
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === recovered)
    }
}
