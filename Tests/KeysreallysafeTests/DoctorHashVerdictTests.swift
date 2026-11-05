import Foundation
import XCTest
@testable import KeysCore

/// A SHA-256 the probe could not read is *missing*, not different. `commandLine` already
/// said `missing`, while `runningLine` and the legacy-only `binary` line said `differs`
/// whenever either hash was nil — so an unreadable bundle binary, or a legacy binary
/// doctor could not read beside a running hash it also could not read, claimed a
/// mismatch nobody observed.
final class DoctorHashVerdictTests: XCTestCase {

    private func appWorld(bundleHash: String?, runningHash: String?) -> DoctorInstall {
        DoctorInstall(
            appBundle: URL(fileURLWithPath: "/Applications/Keysrs.app"),
            bundleBinarySHA256: bundleHash,
            runningExecutable: URL(fileURLWithPath: "/Applications/Keysrs.app/Contents/MacOS/keys"),
            runningBinarySHA256: runningHash,
            loginItem: .enabled
        )
    }

    /// Both hashes nil: nothing was read, so nothing can differ.
    func testAnUnreadableRunningBinaryIsMissingNotDifferent() {
        let lines = Doctor.installLines(appWorld(bundleHash: nil, runningHash: nil))
        let running = lines.first { $0.hasPrefix("running  ") }
        XCTAssertEqual(running, "running  /Applications/Keysrs.app/Contents/MacOS/keys  sha256=missing  missing")
        XCTAssertFalse(lines.contains { $0.hasSuffix("differs") }, "no line claims a difference")
    }

    /// A readable bundle binary and an unreadable running one: still unknown, not "differs".
    func testAReadableBundleWithAnUnreadableRunningBinaryIsUnknown() {
        let lines = Doctor.installLines(appWorld(bundleHash: "aaaa", runningHash: nil))
        let running = lines.first { $0.hasPrefix("running  ") }
        XCTAssertTrue(running?.hasSuffix("  unknown") == true, running ?? "")
    }

    /// One unreadable installed side is unknown too, in the other direction.
    func testAnUnreadableBundleBinaryIsUnknown() {
        let lines = Doctor.installLines(appWorld(bundleHash: nil, runningHash: "aaaa"))
        XCTAssertTrue(lines.first { $0.hasPrefix("running  ") }?.hasSuffix("unknown") == true)
    }

    /// Two equal hashes still say match, and two different ones still say differs.
    func testBothHashesPresentKeepsMatchAndDiffers() {
        XCTAssertTrue(
            Doctor.installLines(appWorld(bundleHash: "aaaa", runningHash: "aaaa"))
                .first { $0.hasPrefix("running  ") }!.hasSuffix("match")
        )
        XCTAssertTrue(
            Doctor.installLines(appWorld(bundleHash: "aaaa", runningHash: "bbbb"))
                .first { $0.hasPrefix("running  ") }!.hasSuffix("differs")
        )
    }

    /// The legacy-only branch has the same rule: an unreadable legacy binary (whose row
    /// is only printed because the file exists) next to an unreadable running hash used
    /// to read `missing  missing  differs`.
    func testTheLegacyOnlyBinaryLineTreatsNilAsMissing() {
        let plist = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.keysreallysafe.menubar.plist")
        let unreadable = DoctorInstall(
            runningExecutable: URL(fileURLWithPath: "/old/bin/keys"),
            runningBinarySHA256: nil,
            legacyPlist: plist,
            legacyPlistExists: true,
            legacyBinaryExists: true,
            legacyBinarySHA256: nil
        )
        XCTAssertEqual(
            Doctor.installLines(unreadable)[1],
            "binary  installed sha256=missing  running sha256=missing  missing"
        )

        var half = unreadable
        half.runningBinarySHA256 = "aaaa"
        XCTAssertTrue(Doctor.installLines(half)[1].hasSuffix("unknown"), "one side read is not a difference")

        var differ = unreadable
        differ.legacyBinarySHA256 = "aaaa"
        differ.runningBinarySHA256 = "bbbb"
        XCTAssertTrue(Doctor.installLines(differ)[1].hasSuffix("differs"), "two read, unequal hashes")
    }

    /// The three verdicts share one vocabulary, so no line says "differs" about a hash
    /// it could not read while another says "missing" about the same absence.
    func testTheVerdictVocabularyIsShared() {
        XCTAssertEqual(Doctor.shaVerdict(nil, nil), "missing")
        XCTAssertEqual(Doctor.shaVerdict(nil, "aaaa"), "unknown")
        XCTAssertEqual(Doctor.shaVerdict("aaaa", nil), "unknown")
        XCTAssertEqual(Doctor.shaVerdict("aaaa", "aaaa"), "match")
        XCTAssertEqual(Doctor.shaVerdict("aaaa", "bbbb"), "differs")
    }

    /// A PATH binary next to a readable bundle, where the command's own hash could not be
    /// read. That link is where doctor always said `missing`, and routing the verdict
    /// through `shaVerdict` turned the same absence into `unknown` — a different word for
    /// a case that had not changed. Only the comparison between two hashes is unknown.
    func testAnUnreadableCommandBinaryStillSaysMissing() {
        let install = DoctorInstall(
            appBundle: URL(fileURLWithPath: "/Applications/Keysrs.app"),
            bundleBinarySHA256: "aaaa",
            commandOnPath: URL(fileURLWithPath: "/Users/x/.local/bin/keys"),
            commandTarget: nil,
            commandSHA256: nil,
            loginItem: .enabled
        )
        let line = Doctor.installLines(install).first { $0.hasPrefix("command  ") }
        XCTAssertEqual(line, "command  /Users/x/.local/bin/keys  sha256=missing  missing")
    }
}
