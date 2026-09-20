import Darwin
import Foundation
import XCTest
@testable import KeysCore

final class OptimizerProcessTests: XCTestCase {
    func testEarlyExitDoesNotSignalParent() throws {
        let marker = "KEYS_TEST_OPTIMIZER_SIGPIPE_CHILD"
        if ProcessInfo.processInfo.environment[marker] == "1" {
            // Isolate the default disposition from XCTest and other test suites.
            signal(SIGPIPE, SIG_DFL)
            let request: [String: Any] = ["proposed_memory": ["content": String(repeating: "x", count: 90_000)]]
            XCTAssertThrowsError(try OptimizerProcess.run(request, [:], executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])) {
                guard case OptimizerEngineFailure.startedOutcomeUnknown = $0 else { return XCTFail("Unexpected lifecycle: \($0)") }
            }
            return
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "KeysreallysafeTests.OptimizerProcessTests/testEarlyExitDoesNotSignalParent", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit, "\(String(decoding: data, as: UTF8.self))")
        XCTAssertEqual(process.terminationStatus, 0, "\(String(decoding: data, as: UTF8.self))")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Executed 1 test"))
    }

    func testInvalidExecutableIsProvablyNotStarted() throws {
        XCTAssertThrowsError(try OptimizerProcess.run([:], [:], executable: URL(fileURLWithPath: "/missing/synthetic-engine"), arguments: [])) {
            guard case OptimizerEngineFailure.notStarted = $0 else { return XCTFail("Unexpected lifecycle: \($0)") }
        }
    }
}
