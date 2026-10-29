import Foundation
import XCTest
@testable import KeysCore

/// VAL-CONNECT-005: the app-connection tests fail closed against production
/// state. These are the guard's own positive and negative cases plus the two
/// structural pins: the guard never inspects the real `control.json` (path and
/// type comparison only), and every current auto-launch/`AppConnection` rig
/// block passes through the guard before the operation it guards. The suite
/// also pins the test-only no-launch seam a spawned `keys` process runs with
/// (`KEYS_TEST_NO_LAUNCH`), which is what makes even subprocess coverage —
/// production code a test cannot hand a Swift closure — unable to reach
/// LaunchServices or the installed app.
///
/// The belt intentionally does not scan this file (it deliberately constructs
/// forbidden configurations to prove the rejections) or the guard's own file
/// (it is the enforcement).
final class AppConnectionIsolationGuardTests: XCTestCase {

    // MARK: - Positive: valid temporary fixtures pass

    /// A guarded world and every accepted fake combination: the recording
    /// launch pair, the never-launching default, the fail-closed subprocess
    /// pair, and the memory secret store.
    func testTemporaryWorldAndFakesAreAccepted() throws {
        let secrets = MemorySecretStore()
        let recording = RecordingAppLaunch()
        let world = try AppConnectionIsolationGuard.makeWorld(launch: recording.seam, secrets: secrets)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.dir.path),
                      "makeWorld created the directory after the check passed")
        XCTAssertEqual(world.catalog.lastPathComponent, "catalog.db")
        XCTAssertEqual(world.control.lastPathComponent, "control.json")
        XCTAssertEqual(world.control.deletingLastPathComponent().path, world.dir.path,
                       "the control file is the catalog's sibling, the makeDB layout")

        // The accepted launch pairs and stores: re-checking the configured
        // world is idempotent, and each fake combination passes.
        XCTAssertNoThrow(try AppConnectionIsolationGuard.assertIsolated(
            control: world.control, launch: recording.seam, secrets: secrets
        ))
        XCTAssertNoThrow(try AppConnectionIsolationGuard.assertIsolated(
            control: world.control, launch: .neverLaunching
        ))
        XCTAssertNoThrow(try AppConnectionIsolationGuard.assertIsolated(
            control: world.control,
            launch: AppLaunchSeam(launcher: NoLaunchAppLauncher(), clock: NoSleepAppLaunchClock()),
            secrets: ThrowingSecretStore(AppError.usage("unused"))
        ))
        // No seam and no store configured is fine too: the rig then runs no
        // launch path and holds no vault.
        XCTAssertNoThrow(try AppConnectionIsolationGuard.assertIsolated(control: world.control))
    }

    // MARK: - Negative: production paths fail closed before any side effect

    /// Every production-shaped control configuration is rejected by comparison
    /// alone — the default control URL's shape (the installed catalog's sibling,
    /// built here beside the production catalog constant rather than through
    /// the throwing resolver, which refuses under the tripwire this very suite
    /// runs under), anything at or beneath the production app-support
    /// directory, and anything beneath the installed app bundle — including
    /// paths that do not exist, because the guard never asks the filesystem
    /// whether the rejection is deserved.
    func testProductionControlPathsFailClosed() throws {
        let forbidden: [(label: String, control: URL)] = [
            ("the default control URL's shape",
             ControlFile.url(beside: Paths.appSupport.appendingPathComponent("catalog.db"))),
            ("the default beside the installed catalog", ControlFile.url(beside: Paths.catalogDB)),
            ("the production control file itself", Paths.appSupport.appendingPathComponent("control.json")),
            ("a path beneath the production app-support directory",
             Paths.appSupport.appendingPathComponent("definitely-not-there").appendingPathComponent("control.json")),
            ("a path beneath the installed app bundle",
             AppConnection.installedAppURL.appendingPathComponent("Contents").appendingPathComponent("control.json")),
            ("a nonexistent production-shaped path",
             Paths.appSupport.appendingPathComponent("no-such-uuid-\(UUID().uuidString)").appendingPathComponent("control.json")),
        ]
        for case_ in forbidden {
            XCTAssertThrowsError(
                try AppConnectionIsolationGuard.assertIsolated(control: case_.control),
                "\(case_.label) must fail closed"
            ) { error in
                guard case AppError.usage(let message) = error else {
                    return XCTFail("\(case_.label): expected a usage refusal, got \(error)")
                }
                XCTAssertTrue(message.contains("test isolation rejected"),
                              "\(case_.label): the refusal names the isolation rule: \(message)")
                XCTAssertFalse(message.contains("Keychain"), "\(case_.label): a path refusal, not a store refusal")
            }
        }
    }

    /// The positive half of the path rule: a control URL that is neither
    /// production nor inside this process's temporary area is rejected too — a
    /// rig may not fall back to a checkout or home location and still pass.
    func testNonTemporaryControlPathsFailClosed() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let strays: [(label: String, control: URL)] = [
            ("a home-directory control file", home.appendingPathComponent("control.json")),
            ("a checkout control file", URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("control.json")),
        ]
        for case_ in strays {
            XCTAssertThrowsError(
                try AppConnectionIsolationGuard.assertIsolated(control: case_.control),
                "\(case_.label) must fail closed"
            ) { error in
                guard case AppError.usage(let message) = error else {
                    return XCTFail("\(case_.label): expected a usage refusal, got \(error)")
                }
                XCTAssertTrue(message.contains("temporary"), "\(case_.label): the refusal asks for a temporary URL: \(message)")
            }
        }
    }

    // MARK: - Negative: production implementations fail closed

    /// The production launch pair, each production half alone, and the
    /// production Keychain store are all refused before a rig can run them.
    /// Nothing here CALLS a production effect — the refusal is on the
    /// configuration, which is the whole point.
    func testProductionImplementationsFailClosed() throws {
        let (_, _, control) = try AppConnectionIsolationGuard.makeWorld()

        XCTAssertThrowsError(try AppConnectionIsolationGuard.assertIsolated(
            control: control,
            launch: AppLaunchSeam(launcher: LaunchServicesAppLauncher(), clock: ThreadAppLaunchClock())
        ), "the production launch pair must fail closed")
        XCTAssertThrowsError(try AppConnectionIsolationGuard.assertIsolated(
            control: control,
            launch: AppLaunchSeam(launcher: RecordingAppLaunch(), clock: ThreadAppLaunchClock())
        ), "the production clock half must fail closed on its own")
        XCTAssertThrowsError(try AppConnectionIsolationGuard.assertIsolated(
            control: control,
            launch: AppLaunchSeam(launcher: LaunchServicesAppLauncher(), clock: RecordingAppLaunch())
        ), "the production launcher half must fail closed on its own")
        // The production Keychain store now fails closed one step EARLIER than
        // the guard's configuration check: under the tripwire (VAL-H-001) its
        // construction refuses outright, so a rig cannot even hold one to be
        // rejected. The intent — no test runs wired to the real Keychain — is
        // preserved, stricter than before.
        XCTAssertThrowsError(try KeychainStore(), "the production Keychain store must fail closed") { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"),
                          "the refusal names the isolation rule: \(message)")
        }
    }

    // MARK: - The guard never inspects the real control file

    /// The guard judges configuration only. This pin holds it to that: the
    /// guard's own source may derive URLs and create its temp world, but it
    /// names no inspection API — no existence check, no directory listing, no
    /// read of any kind, no `ControlFile.read`/`live` — so the real
    /// `control.json` can never be its input.
    func testTheGuardNeverInspectsTheControlFile() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("AppConnectionIsolationGuard.swift"),
            encoding: .utf8
        )
        let forbidden = [
            "fileExists", "contentsOfDirectory", "Data(contentsOf", "String(contentsOf",
            "ControlFile.read", "ControlFile.live", "removeItem", "isReadableFile",
            "isWritableFile", "isExecutableFile", "setAttributes",
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token),
                           "the guard never inspects the control file: \"\(token)\" does not belong in it")
        }
        // And behaviorally: a nonexistent production-shaped path is refused
        // exactly like an existing one would be — the filesystem was never
        // consulted either way (pinned above the negative-path cases too, so
        // the refusal cannot depend on what happens to be installed).
        XCTAssertThrowsError(try AppConnectionIsolationGuard.assertIsolated(
            control: Paths.appSupport.appendingPathComponent("cannot-exist-\(UUID().uuidString)")
                .appendingPathComponent("control.json")
        ))
    }

    // MARK: - The test-only no-launch seam for spawned processes

    /// `AppLaunchSeam.production` is LaunchServices and the wall clock — the
    /// pair every production caller runs with — unless `KEYS_TEST_NO_LAUNCH`
    /// names a fail-closed test pair: a spawned `keys` process runs production
    /// code and cannot be handed a Swift closure, so the environment is the one
    /// injection channel its test rig has, and with it the process CANNOT
    /// reach LaunchServices or the installed app even on a down site: every
    /// open is refused and the clock never sleeps, so an app-bound call fails
    /// closed to the plain sentence, fast and bounded. The empty value means
    /// unset, the `Paths.env` convention.
    func testTheTestOnlyNoLaunchSeamFailsClosed() throws {
        // The production pair, resolved without the flag (and never opened here).
        let real = AppLaunchSeam.production(environment: [:])
        XCTAssertTrue(real.launcher is LaunchServicesAppLauncher, "no flag: the real launcher")
        XCTAssertTrue(real.clock is ThreadAppLaunchClock, "no flag: the real clock")
        XCTAssertTrue(AppLaunchSeam.production(environment: ["KEYS_TEST_NO_LAUNCH": ""]).launcher
                        is LaunchServicesAppLauncher, "an empty flag value means unset")

        // The fail-closed pair the flag selects.
        let refused = AppLaunchSeam.production(environment: ["KEYS_TEST_NO_LAUNCH": "1"])
        XCTAssertTrue(refused.launcher is NoLaunchAppLauncher, "the flag selects the no-launch launcher")
        XCTAssertTrue(refused.clock is NoSleepAppLaunchClock, "the flag selects the no-sleep clock")
        XCTAssertFalse(refused.launcher.open(bundleID: AppConnection.appBundleID),
                       "a bundle-id open is refused — LaunchServices is never reached")
        XCTAssertFalse(refused.launcher.open(installedAt: AppConnection.installedAppURL),
                       "an installed-path open is refused — the installed app is never reached")
        let started = Date()
        refused.clock.sleep(for: AppConnection.launchHealthBudget)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "the no-sleep clock returns instantly: the bounded schedule costs nothing")

        // The fail-closed pair is an accepted fake for the isolation guard, so
        // a rig (or a subprocess's own process-wide default) may carry it.
        let (_, _, control) = try AppConnectionIsolationGuard.makeWorld()
        XCTAssertNoThrow(try AppConnectionIsolationGuard.assertIsolated(control: control, launch: refused))
    }

    // MARK: - The structural belt over every current rig

    /// Every member block of the current app-connection/auto-launch rigs that
    /// configures a control-file URL, or hands one to `AppConnection.connect`,
    /// a tool group, the control file writer, or a launch-driving command, must
    /// carry an isolation-guard call positioned before that first use — so a
    /// new rig that forgets the guard fails this belt by file and declaration,
    /// before it can ever reach production state. Blocks whose only
    /// app-connection reach is `MCPRoster.groups`/`registry` are not listed
    /// here: the roster builder itself is guarded, and it is in the scanned
    /// files.
    func testEveryAppConnectionRigPassesTheGuard() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // The population: every suite that exercises auto-launch or
        // AppConnection today, plus the shared support they build rigs in — and,
        // since the 0.14 merge, the onboarding and feedback mission suites that
        // build the same control-channel rigs (their sites, dead controls and
        // tool rosters all configure control URLs). Deliberately not scanned:
        // this file and the guard's own file (they construct forbidden
        // configurations to prove the rejections), and ProductionTripwireTests
        // (the production-side tripwire's own proof file, same reason).
        let files = [
            "MCPAppConnectionTests.swift", "AppLaunchSeamTests.swift", "DashboardCommandTests.swift",
            "ReadToolsTests.swift", "GrantMCPTests.swift", "MCPClientFlowTests.swift",
            "MCPOutputGuardSweepTests.swift", "MCPOutputGuardTests.swift", "MCPRegistryTests.swift",
            "MCPServerTestSupport.swift", "TestSupport.swift",
        ]
        // A use hands the configured control world to something that can act on it.
        let uses = [
            "AppConnection.connect(", "MCPReadTools(", "MCPGrantTools(", "AppConnectionProbeGroup(",
            "ControlFile.write(", ".run(launch:", ".requireGatewayUp(",
        ]
        // A derive computes a control-file URL — pure math, but it must not
        // appear without the guard in the same block.
        let derives = ["ControlFile.url(", "appendingPathComponent(\"control.json\")"]
        let guardToken = "IsolationGuard"

        var scannedBlocks = 0
        for name in files {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for block in Self.memberBlocks(of: source) {
                let firstUse = Self.firstPosition(of: uses, in: block)
                let derivesHere = Self.firstPosition(of: derives, in: block) != nil
                guard firstUse != nil || derivesHere else { continue }
                scannedBlocks += 1
                let guardPosition = Self.firstPosition(of: [guardToken], in: block)
                XCTAssertNotNil(guardPosition,
                                "\(name): \(block.declaration) configures or uses a control URL; it must run the isolation guard first")
                if let firstUse, let guardPosition {
                    XCTAssertTrue(Self.isBefore(guardPosition, firstUse),
                                  "\(name): \(block.declaration) runs the guard AFTER an operation — the guard must precede the first use")
                }
            }
        }
        XCTAssertGreaterThan(scannedBlocks, 5, "the belt scanned the rig population")
    }

    // MARK: - The belt's block model

    /// One depth-1 member declaration and its body, comments excluded from the
    /// token scan (a commented-out token must not satisfy or trip the belt).
    private struct MemberBlock {
        var declaration: String
        var lines: [(index: Int, text: String)]
    }

    /// Cuts a test file into one block per depth-1 member: a new block starts
    /// at each exactly-4-space-indented line that is not a comment and not a
    /// closing brace; deeper lines belong to that member, shallower ones belong
    /// to no block, and comment lines never scan — a commented-out token must
    /// neither satisfy nor trip the belt.
    private static func memberBlocks(of source: String) -> [MemberBlock] {
        var blocks: [MemberBlock] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let content = String(line.drop(while: { $0 == " " }))
            if content.isEmpty || content.hasPrefix("//") { continue }
            let indent = line.count - content.count
            if indent == 4, !content.hasPrefix("}") {
                blocks.append(MemberBlock(declaration: content, lines: [(index, line)]))
            } else if indent > 4, !blocks.isEmpty {
                blocks[blocks.count - 1].lines.append((index, line))
            }
        }
        return blocks
    }

    /// The earliest (line, column) of any token in the block, or nil.
    private static func firstPosition(of tokens: [String], in block: MemberBlock) -> (line: Int, column: Int)? {
        var best: (line: Int, column: Int)?
        for (index, line) in block.lines {
            for token in tokens {
                if let range = line.range(of: token) {
                    let position = (line: index, column: line.distance(from: line.startIndex, to: range.lowerBound))
                    if best == nil || isBefore(position, best!) { best = position }
                }
            }
        }
        return best
    }

    /// Strictly earlier by line, then by column.
    private static func isBefore(_ a: (line: Int, column: Int), _ b: (line: Int, column: Int)) -> Bool {
        a.line < b.line || (a.line == b.line && a.column < b.column)
    }
}
