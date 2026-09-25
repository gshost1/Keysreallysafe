import Foundation
import XCTest
@testable import KeysCore

final class StableSigningTests: XCTestCase {
    func testAppleSignedBuildPassesFreshAndUpgradeValidation() throws {
        guard ProcessInfo.processInfo.environment["KEYS_SIGNING_IDENTITY"] != nil else {
            throw XCTSkip("requires Apple signing identity; run before deploying signing changes")
        }
        let directory = try TempDir.make()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/sign-local.py")
        let first = directory.appendingPathComponent("v1")
        let second = directory.appendingPathComponent("v2")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: first)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: second)
        for binary in [first, second] {
            let result = try LoginItem.run("/usr/bin/python3", [script.path, binary.path])
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        XCTAssertNoThrow(try StableSigning.validate(first, replacing: nil))
        XCTAssertNoThrow(try StableSigning.validate(second, replacing: first))
        let adHoc = directory.appendingPathComponent("legacy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adHoc)
        let result = try LoginItem.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "keysreallysafe", adHoc.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertThrowsError(try StableSigning.validate(first, replacing: adHoc))
        XCTAssertThrowsError(try StableSigning.validate(adHoc, replacing: first))
    }

    func testRejectsAdHocExecutableBeforeInstallation() throws {
        let directory = try TempDir.make()
        let binary = directory.appendingPathComponent("keys")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let signed = try LoginItem.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "keysreallysafe", binary.path])
        XCTAssertEqual(signed.status, 0, signed.stderr)
        XCTAssertThrowsError(try StableSigning.validate(binary, replacing: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("Ad-hoc/self-signed"))
        }
    }

    func testRejectsAppleExecutableWithDifferentIdentifier() throws {
        XCTAssertThrowsError(try StableSigning.validate(URL(fileURLWithPath: "/usr/bin/true"), replacing: nil))
    }

    func testTeamCannotInjectAWeakerRequirement() throws {
        XCTAssertThrowsError(try StableSigning.requirement(team: "X\" or true"))
        XCTAssertThrowsError(try StableSigning.requirement(team: ""))
    }
}
