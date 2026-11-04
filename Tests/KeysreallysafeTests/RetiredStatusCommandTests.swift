import XCTest
@testable import KeysCore

/// `keys status` printed the plan-window cards removed on 2026-11-03; old scripts get a pointer.
final class RetiredStatusCommandTests: XCTestCase {
    func testStatusFailsWithAPointerToSpend() throws {
        for args in [["status"], ["status", "--json"]] {
            var command = try KeysCLI.parseAsRoot(args)
            XCTAssertThrowsError(try command.run()) { error in
                guard case .usage(let message) = error as? AppError else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(message.contains("keys spend --json"), message)
            }
        }
    }

    func testStatusIsHiddenFromHelp() {
        XCTAssertFalse(KeysCLI.helpMessage().contains("status"))
    }
}
