import Foundation
import XCTest
@testable import KeysCore

final class DoctorInstallTests: XCTestCase {
    private let fm = FileManager.default

    /// A Fake.app holding a `keys` binary with the given bytes; returns (bundle, binary).
    private func makeFakeApp(_ dir: URL, bytes: String) throws -> (app: URL, binary: URL) {
        let app = dir.appendingPathComponent("Fake.app")
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("keys")
        try Data(bytes.utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (app, binary)
    }

    /// A `<dir>/.local/bin/keys` symlink to `target`; returns the link.
    private func makeLink(_ dir: URL, to target: URL) throws -> URL {
        let bin = dir.appendingPathComponent(".local/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("keys")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    func testAppWithMatchingCommandAndEnabledLogin() throws {
        let dir = try TempDir.make()
        let (app, binary) = try makeFakeApp(dir, bytes: "installed-binary")
        let hash = Doctor.fileSHA256(binary)
        let link = try makeLink(dir, to: binary)
        let running = dir.appendingPathComponent("checkout/keys")

        let install = DoctorInstall(
            appBundle: app,
            bundleBinarySHA256: hash,
            runningExecutable: running,
            runningBinarySHA256: "deadbeef",
            commandOnPath: link,
            commandTarget: binary.path,
            commandSHA256: Doctor.fileSHA256(link),
            loginItem: .enabled
        )
        let text = Doctor.installLines(install).joined(separator: "\n")

        XCTAssertTrue(text.contains("app  \(app.path)  sha256=\(hash!)"))
        XCTAssertTrue(text.contains("login  enabled"))
        XCTAssertTrue(text.contains("command  \(link.path) -> \(binary.path)  sha256=\(hash!)  match"))
        XCTAssertFalse(text.contains("autostart"))
        XCTAssertFalse(text.contains("legacy"))
        XCTAssertFalse(text.contains("sha256=missing"))
    }

    func testStaleCommandDiffersAndMissingCommandHints() throws {
        let dir = try TempDir.make()
        let (app, _) = try makeFakeApp(dir, bytes: "installed-binary")

        let stale = DoctorInstall(
            appBundle: app,
            bundleBinarySHA256: "aaaa",
            commandOnPath: dir.appendingPathComponent(".local/bin/keys"),
            commandTarget: nil,
            commandSHA256: "bbbb",
            loginItem: .enabled
        )
        let staleLines = Doctor.installLines(stale)
        XCTAssertTrue(staleLines.contains { $0.hasPrefix("command  ") && $0.hasSuffix(" differs") })

        let absent = DoctorInstall(appBundle: app, bundleBinarySHA256: "aaaa", loginItem: .enabled)
        let absentLines = Doctor.installLines(absent)
        XCTAssertTrue(absentLines.contains("command  keys not on PATH (Install Command Line Tool… in the Keysrs menu)"))
    }

    func testAppWithLegacyLeftovers() throws {
        let dir = try TempDir.make()
        let (app, binary) = try makeFakeApp(dir, bytes: "installed-binary")
        let hash = Doctor.fileSHA256(binary)
        let link = try makeLink(dir, to: binary)

        let install = DoctorInstall(
            appBundle: app,
            bundleBinarySHA256: hash,
            runningExecutable: binary,
            runningBinarySHA256: hash,
            commandOnPath: link,
            commandTarget: binary.path,
            commandSHA256: hash,
            loginItem: .enabled,
            legacyPlistExists: true,
            legacyBinaryExists: true,
            legacyAgentLoaded: false
        )
        let lines = Doctor.installLines(install)
        let legacy = lines.filter { $0.hasPrefix("legacy  ") }
        XCTAssertEqual(legacy.count, 1)
        XCTAssertTrue(legacy[0].hasSuffix("remove with: keys autostart --remove"))
        XCTAssertTrue(legacy[0].contains("plist present"))
        XCTAssertTrue(legacy[0].contains("bin present"))
        XCTAssertTrue(legacy[0].contains("agent not loaded"))
        // No 0.9.x "autostart … missing" or "binary … missing" status lines next to an app install.
        XCTAssertFalse(lines.contains { $0.hasPrefix("autostart  ") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("binary  ") })
        XCTAssertFalse(lines.contains { $0.contains("missing") })
    }

    func testLegacyOnlyKeepsOldTwoLines() throws {
        let plist = URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.keysreallysafe.menubar.plist")
        let match = DoctorInstall(
            runningExecutable: URL(fileURLWithPath: "/old/bin/keys"),
            runningBinarySHA256: "same",
            legacyPlist: plist,
            legacyPlistExists: true,
            legacyBinaryExists: true,
            legacyBinarySHA256: "same"
        )
        let matchLines = Doctor.installLines(match)
        XCTAssertEqual(matchLines.count, 2)
        XCTAssertEqual(matchLines[0], "autostart  \(plist.path)  present")
        XCTAssertEqual(matchLines[1], "binary  installed sha256=same  running sha256=same  match")

        var differ = match
        differ.runningBinarySHA256 = "other"
        XCTAssertTrue(Doctor.installLines(differ)[1].hasSuffix("differs"))
        XCTAssertFalse(Doctor.installLines(differ).contains { $0.hasPrefix("app  ") })
        XCTAssertFalse(Doctor.installLines(differ).contains { $0.hasPrefix("legacy  ") })
    }

    func testNothingInstalled() throws {
        let running = URL(fileURLWithPath: "/tmp/checkout/.build/debug/keys")
        let install = DoctorInstall(runningExecutable: running)
        let lines = Doctor.installLines(install)
        XCTAssertEqual(lines, ["app  not installed (running from \(running.path))"])
        XCTAssertFalse(lines.contains { $0.contains("legacy") })
        XCTAssertFalse(lines.contains { $0.contains("autostart") })
        XCTAssertFalse(lines.contains { $0.contains("binary") })
    }

    func testLoginItemWordMapping() {
        XCTAssertEqual(LoginItemState(word: "enabled"), .enabled)
        XCTAssertEqual(LoginItemState(word: "not-registered"), .notRegistered)
        XCTAssertEqual(LoginItemState(word: "requires-approval"), .requiresApproval)
        XCTAssertEqual(LoginItemState(word: "not-found"), .notFound)
        XCTAssertEqual(LoginItemState(word: ""), .notQueried)
        XCTAssertEqual(LoginItemState(word: "garbage"), .notQueried)
        XCTAssertEqual(LoginItemState(word: "0"), .notQueried)

        for state in [LoginItemState.enabled, .notRegistered, .requiresApproval, .notFound] {
            XCTAssertEqual(LoginItemState(word: state.statusWord), state)
        }

        // A not-queried login item prints with a hint.
        let install = DoctorInstall(appBundle: URL(fileURLWithPath: "/Applications/Fake.app"), loginItem: .notQueried)
        let login = Doctor.installLines(install).first { $0.hasPrefix("login  ") }
        XCTAssertEqual(login, "login  not queried (open Keysrs to see Start at Login)")
    }

    func testLoginItemStatusCommandIsHiddenButResolvable() throws {
        let parsed = try KeysCLI.parseAsRoot(["login-item-status"])
        XCTAssertTrue(parsed is LoginItemStatusCommand)
        XCTAssertFalse(LoginItemStatusCommand.configuration.shouldDisplay)
    }

    // A non-zero exit / failed probe (runner returns nil) resolves to .notQueried, and the
    // injected PATH is what locates the app bundle.
    func testLiveResolvesBundleFromPathAndMapsFailedProbe() throws {
        let dir = try TempDir.make()
        let (app, binary) = try makeFakeApp(dir, bytes: "installed-binary")
        let link = try makeLink(dir, to: binary)
        let env = ["PATH": link.deletingLastPathComponent().path]

        // Running through the PATH link, so the binary is the bundle's own.
        let enabled = DoctorInstall.live(environment: env, probeAgent: false, runningExecutable: link,
                                         loginRunner: { _ in "enabled" })
        XCTAssertEqual(enabled.appBundle?.path, app.path)
        XCTAssertEqual(enabled.commandOnPath?.path, link.path)
        XCTAssertEqual(enabled.loginItem, .enabled)

        let failed = DoctorInstall.live(environment: env, probeAgent: false, runningExecutable: link,
                                        loginRunner: { _ in nil })
        XCTAssertEqual(failed.loginItem, .notQueried)

        let garbage = DoctorInstall.live(environment: env, probeAgent: false, runningExecutable: link,
                                         loginRunner: { _ in "???" })
        XCTAssertEqual(garbage.loginItem, .notQueried)
    }

    // A dev build or stray copy must not run the installed bundle's binary and report that
    // build's login item as its own.
    func testLiveDoesNotAskABundleItIsNotRunningFrom() throws {
        let dir = try TempDir.make()
        let (_, binary) = try makeFakeApp(dir, bytes: "installed-binary")
        let link = try makeLink(dir, to: binary)
        let env = ["PATH": link.deletingLastPathComponent().path]
        let elsewhere = dir.appendingPathComponent("checkout/.build/debug/keys")
        var asked = false
        let install = DoctorInstall.live(environment: env, probeAgent: false, runningExecutable: elsewhere,
                                         loginRunner: { _ in asked = true; return "enabled" })
        XCTAssertFalse(asked)
        XCTAssertEqual(install.loginItem, .notQueried)
    }

    // The probe must survive an older binary's usage flood on stderr and give up on a hang.
    func testProbeLoginItemHandlesStderrFloodAndTimeout() throws {
        let dir = try TempDir.make()
        func script(_ name: String, _ body: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let current = try script("current", "echo enabled")
        XCTAssertEqual(DoctorInstall.probeLoginItem(binary: current), "enabled")
        let older = try script("older", "head -c 200000 /dev/zero | tr '\\0' u >&2; exit 64")
        let started = Date()
        XCTAssertNil(DoctorInstall.probeLoginItem(binary: older, timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let hung = try script("hung", "sleep 5")
        XCTAssertNil(DoctorInstall.probeLoginItem(binary: hung, timeout: 0.5))
    }
}
