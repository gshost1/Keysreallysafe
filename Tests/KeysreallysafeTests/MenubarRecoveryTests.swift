import AppKit
import XCTest
@testable import KeysCore

final class MenubarRecoveryTests: XCTestCase {
    private let defaults = MemoryDefaults()

    /// Recovery runs on the main actor after its delay, and a busy CI runner has run it well
    /// past a fixed 150 ms window (the "recovered" log line came after the failed asserts), so
    /// a replacement is waited for. The bound is only a ceiling for a broken build: a throttled
    /// local run stalled the main thread for over 5 s. Checks that nothing was replaced still
    /// use a short fixed wait: a late recovery can only make those pass, never fail.
    @MainActor private func replaced(_ controller: MenubarItemController, from item: NSStatusItem,
                                     within timeout: Duration = .seconds(30)) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while controller.item === item {
            if clock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @MainActor func testWakeReplacesEvenNominallyVisibleItemAndPreservesMenu() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(20), defaults: defaults)
        defer { controller.stop() }
        let original = controller.item
        original.button?.title = "C 12%  X 34%"
        original.button?.toolTip = "Usage"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Keysrs", action: nil, keyEquivalent: "")
        original.menu = menu
        original.isVisible = true
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let didReplace = try await replaced(controller, from: original)
        XCTAssertTrue(didReplace)
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
                                               recoveryDelay: .milliseconds(20), defaults: defaults)
        defer { controller.stop() }
        let original = controller.item
        controller.menuIsOpen = true
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === original, "no recovery while the menu is open")
        controller.menuDidClose()
        let didReplace = try await replaced(controller, from: original)
        XCTAssertTrue(didReplace, "the deferred recovery runs once the menu closes")
    }

    @MainActor func testHiddenItemRecoversButHealthyRefreshDoesNotReplaceItem() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: .milliseconds(20), defaults: defaults)
        defer { controller.stop() }
        let original = controller.item
        original.isVisible = false
        controller.checkVisibility()
        let didReplace = try await replaced(controller, from: original)
        XCTAssertTrue(didReplace)
        let recovered = controller.item
        XCTAssertTrue(recovered.isVisible)
        controller.checkVisibility()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.item === recovered)
    }

    @MainActor func testTransitionBurstCoalescesAndStopCancelsRecovery() async throws {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let delay = Duration.milliseconds(400)
        let controller = MenubarItemController(workspaceCenter: center, appCenter: center,
                                               recoveryDelay: delay, defaults: defaults)
        var stopped = false
        defer { if !stopped { controller.stop() } }
        let original = controller.item
        // Each request restarts the delay, so the item can only change mid-burst if some gap
        // between two requests, or since the last one, reached the delay. A busy CI runner can
        // oversleep a 10 ms step by that much; the check is skipped for a step where it did.
        let clock = ContinuousClock()
        var longestGap = Duration.zero
        var lastRequest: ContinuousClock.Instant?
        var recoveredMidBurst = false
        for _ in 0..<5 {
            let now = clock.now
            if let lastRequest { longestGap = max(longestGap, now - lastRequest) }
            lastRequest = now
            controller.requestRecovery(reason: "test transition")
            try await Task.sleep(for: .milliseconds(10))
            if longestGap < delay, clock.now - now < delay {
                XCTAssertTrue(controller.item === original)
            } else {
                recoveredMidBurst = true
            }
        }
        let didReplace = try await replaced(controller, from: original)
        XCTAssertTrue(didReplace)
        var recovered = controller.item
        if recoveredMidBurst {
            // A recovery that fired mid-burst leaves the later requests to schedule one more,
            // which is correct; the coalescing check below is about the burst's last request,
            // so wait for the item to hold still for longer than the delay first.
            let deadline = clock.now.advanced(by: .seconds(30))
            while clock.now < deadline {
                try await Task.sleep(for: delay + .milliseconds(300))
                if controller.item === recovered { break }
                recovered = controller.item
            }
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(controller.item === recovered)
        controller.requestRecovery(reason: "pending at shutdown")
        controller.stop()
        stopped = true
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(controller.item === recovered)
    }
}
