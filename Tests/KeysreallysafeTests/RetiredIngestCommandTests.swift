import XCTest
@testable import KeysCore

/// `keys ingest` and `keys usage import` fed the subscription chart removed on 2026-11-04; old
/// scripts get a pointer instead of an unknown-subcommand error, and nothing is read.
final class RetiredIngestCommandTests: XCTestCase {
    func testIngestAndUsageImportFailWithAPointerToSpend() throws {
        for args in [["ingest"], ["ingest", "claude"], ["usage", "import", "/tmp/export.jsonl"], ["usage"]] {
            var command = try KeysCLI.parseAsRoot(args)
            XCTAssertThrowsError(try command.run(), "\(args)") { error in
                guard case .usage(let message) = error as? AppError else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(message.contains("removed on 2026-11-04"), message)
                XCTAssertTrue(message.contains("keys spend"), message)
            }
        }
    }

    func testRetiredCommandsAreHiddenFromHelp() {
        let help = KeysCLI.helpMessage()
        XCTAssertFalse(help.contains("ingest"), help)
        XCTAssertFalse(help.contains("usage import"), help)
    }
}
