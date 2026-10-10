import XCTest
@testable import KeysCore

/// The one-click updater's offline parts: what GitHub's release API says, how a checksum file is
/// read, what the restart helper runs, and what is cleaned up beside the app. No network, no
/// disk images, no signing.
final class AppUpdaterTests: XCTestCase {
    private static let digest = "4c4687e339cfc0cec6046fa1ba55d92a187278eec4d1f69513bb51052756177d"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TempDir.make().appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Release API response

    private func releaseJSON(assets: String) -> String {
        """
        {"tag_name":"v0.10.1","html_url":"https://github.com/gshost1/Keysreallysafe/releases/tag/v0.10.1",
         "target_commitish":"main","draft":false,"prerelease":false,"assets":[\(assets)]}
        """
    }

    private var dmgAsset: String {
        """
        {"name":"Keysrs-arm64.dmg","size":2410943,
         "browser_download_url":"https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg",
         "digest":"sha256:\(Self.digest)"}
        """
    }

    func testReleaseParsesVersionDownloadDigestSizeAndNotes() throws {
        let info = try AppUpdater.parseRelease(Data(releaseJSON(assets: dmgAsset).utf8))
        XCTAssertEqual(info.version, "0.10.1")
        XCTAssertEqual(info.dmg, URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg"))
        XCTAssertEqual(info.checksum, .digest(Self.digest))
        XCTAssertEqual(info.expectedBytes, 2410943)
        XCTAssertEqual(info.notes, URL(string: "https://github.com/gshost1/Keysreallysafe/releases/tag/v0.10.1"))
    }

    func testReleaseWithoutDigestFallsBackToTheSidecarAsset() throws {
        let assets = """
        {"name":"Keysrs-arm64.dmg","size":2410943,
         "browser_download_url":"https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg"},
        {"name":"Keysrs-arm64.dmg.sha256","size":77,
         "browser_download_url":"https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg.sha256"}
        """
        let info = try AppUpdater.parseRelease(Data(releaseJSON(assets: assets).utf8))
        XCTAssertEqual(info.checksum,
                       .sidecar(URL(string: "https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg.sha256")!))
    }

    func testReleaseWithoutAnyChecksumIsStillParsedButUnverifiable() throws {
        let assets = """
        {"name":"Keysrs-arm64.dmg","size":2410943,
         "browser_download_url":"https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-arm64.dmg"}
        """
        let info = try AppUpdater.parseRelease(Data(releaseJSON(assets: assets).utf8))
        XCTAssertNil(info.checksum)
    }

    func testReleaseRefusesMissingDownloadAndBadTagsAndNonHTTPSURLs() {
        let wrongName = """
        {"name":"Keysrs-x86.dmg","browser_download_url":"https://github.com/gshost1/Keysreallysafe/releases/download/v0.10.1/Keysrs-x86.dmg"}
        """
        XCTAssertThrowsError(try AppUpdater.parseRelease(Data(releaseJSON(assets: wrongName).utf8)))
        let plainHTTP = """
        {"name":"Keysrs-arm64.dmg","browser_download_url":"http://example.com/Keysrs-arm64.dmg"}
        """
        XCTAssertThrowsError(try AppUpdater.parseRelease(Data(releaseJSON(assets: plainHTTP).utf8)))
        XCTAssertThrowsError(try AppUpdater.parseRelease(Data(#"{"tag_name":"not-a-version","assets":[]}"#.utf8)))
        XCTAssertThrowsError(try AppUpdater.parseRelease(Data(#"{"assets":[]}"#.utf8)))
    }

    // MARK: - Checksums

    func testChecksumNormalizationAcceptsOnlyHex64() {
        XCTAssertEqual(AppUpdater.normalizedChecksum(Self.digest.uppercased()), Self.digest)
        XCTAssertEqual(AppUpdater.normalizedChecksum(Self.digest), Self.digest)
        XCTAssertNil(AppUpdater.normalizedChecksum("short"))
        XCTAssertNil(AppUpdater.normalizedChecksum(String(repeating: "g", count: 64)))
        XCTAssertEqual(AppUpdater.normalizedDigest("sha256:\(Self.digest)"), Self.digest)
        XCTAssertNil(AppUpdater.normalizedDigest("md5:\(Self.digest)"))
        XCTAssertNil(AppUpdater.normalizedDigest(Self.digest))
    }

    func testChecksumSidecarAcceptsCommonFormatsAndRefusesAnythingElse() {
        XCTAssertEqual(AppUpdater.parseChecksumSidecar("\(Self.digest)  Keysrs-arm64.dmg\n"), Self.digest)
        XCTAssertEqual(AppUpdater.parseChecksumSidecar("SHA256 (Keysrs-arm64.dmg) = \(Self.digest.uppercased())"), Self.digest)
        XCTAssertEqual(AppUpdater.parseChecksumSidecar(Self.digest), Self.digest)
        XCTAssertEqual(AppUpdater.parseChecksumSidecar("not a checksum\n\(Self.digest)  Keysrs-arm64.dmg"), Self.digest)
        XCTAssertNil(AppUpdater.parseChecksumSidecar("thanks for downloading"))
        XCTAssertNil(AppUpdater.parseChecksumSidecar(""))
        XCTAssertNil(AppUpdater.parseChecksumSidecar("SHA256 (Keysrs-arm64.dmg) = not-hex"))
    }

    func testHexSha256StreamsAFile() throws {
        let file = directory.appendingPathComponent("content")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AppUpdater.hexSha256(fileAt: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Version gate

    func testCandidateVersionMustMatchTheReleaseAndBeatTheInstalledOne() throws {
        let info = ["CFBundleShortVersionString": "0.11.0"]
        XCTAssertEqual(try AppUpdater.candidateVersion(infoDictionary: info, release: "0.11.0", current: "0.10.1"), "0.11.0")
        XCTAssertThrowsError(try AppUpdater.candidateVersion(infoDictionary: info, release: "0.12.0", current: "0.10.1"))
        XCTAssertThrowsError(try AppUpdater.candidateVersion(infoDictionary: info, release: "0.11.0", current: "0.11.0"))
        XCTAssertThrowsError(try AppUpdater.candidateVersion(infoDictionary: [:], release: "0.11.0", current: "0.10.1"))
    }

    // MARK: - Disk image listing

    func testMountPointIsFoundInsideSystemEntitiesOrAtTheTopLevel() {
        // The shape `hdiutil attach -plist` really prints: a dictionary, not an array.
        let real = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>system-entities</key><array>
          <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
          <dict><key>content-hint</key><string>41504653-0000-11AA-AA11-00306543ECAC</string><key>mount-point</key><string>/tmp/keysrs-update/mount</string></dict>
          <dict><key>content-hint</key><string>Apple_APFS</string></dict>
        </array></dict>
        </plist>
        """
        XCTAssertEqual(AppUpdater.mountPoint(fromPlist: Data(real.utf8)), "/tmp/keysrs-update/mount")
        let nested = """
        <plist version="1.0"><array><dict><key>system-entities</key><array>
          <dict><key>mount-point</key><string>/tmp/nested</string></dict>
        </array></dict></array></plist>
        """
        XCTAssertEqual(AppUpdater.mountPoint(fromPlist: Data(nested.utf8)), "/tmp/nested")
        let top = """
        <plist version="1.0"><array><dict><key>mount-point</key><string>/Volumes/Keysrs</string></dict></array></plist>
        """
        XCTAssertEqual(AppUpdater.mountPoint(fromPlist: Data(top.utf8)), "/Volumes/Keysrs")
        XCTAssertNil(AppUpdater.mountPoint(fromPlist: Data("not a plist".utf8)))
    }

    func testErrorDialogsShowTheMessageNotAnErrorNumber() {
        let error: Error = AppError.http("The download could not be opened as a disk image.")
        XCTAssertEqual(error.localizedDescription, "The download could not be opened as a disk image.")
    }

    // MARK: - Restart helper

    func testRelauncherCarriesPathsAsArgumentsNeverInsideTheScript() {
        let argv = AppUpdater.relauncher(pid: 4242,
                                         old: URL(fileURLWithPath: "/Applications/My Keys.app.old"),
                                         new: URL(fileURLWithPath: "/Applications/Keysrs.app"))
        XCTAssertEqual(argv[0], "/bin/sh")
        XCTAssertEqual(argv[1], "-c")
        XCTAssertEqual(argv[3], "keysrs-update")
        XCTAssertEqual(argv[4], "4242")
        XCTAssertEqual(argv[5], "/Applications/My Keys.app.old")
        XCTAssertEqual(argv[6], "/Applications/Keysrs.app")
        // A folder name with a space must never reach the shell string.
        XCTAssertFalse(argv[2].contains("My Keys"))
        XCTAssertTrue(argv[2].contains(#"kill -0 "$1""#))
        XCTAssertTrue(argv[2].contains(#"rm -rf "$2""#))
        XCTAssertTrue(argv[2].contains(#"/usr/bin/open "$3""#))
    }

    func testInstallPlanKeepsTheSwapBesideTheApp() {
        let plan = AppUpdater.installPlan(app: URL(fileURLWithPath: "/Applications/Keysrs.app"))
        XCTAssertEqual(plan.incoming, URL(fileURLWithPath: "/Applications/.Keysrs.app.incoming"))
        XCTAssertEqual(plan.previous, URL(fileURLWithPath: "/Applications/.Keysrs.app.previous"))
    }

    func testSweepRemovesOnlyTheUpdaterOwnLeftovers() throws {
        let fm = FileManager.default
        let app = directory.appendingPathComponent("Keysrs.app", isDirectory: true)
        let leftovers = [".Keysrs.app.incoming", ".Keysrs.app.previous"].map { directory.appendingPathComponent($0, isDirectory: true) }
        let keep = directory.appendingPathComponent("My Keysrs.app", isDirectory: true)
        try ([app] + leftovers + [keep]).forEach { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
        AppUpdater.sweepStaleInstall(around: app, fileManager: fm)
        for leftover in leftovers { XCTAssertFalse(fm.fileExists(atPath: leftover.path)) }
        XCTAssertTrue(fm.fileExists(atPath: app.path))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
    }
}
