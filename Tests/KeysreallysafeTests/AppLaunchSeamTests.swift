import XCTest
@testable import KeysCore

/// VAL-CONNECT-003 and VAL-CONNECT-004 on the CLI side: every eligible
/// app-dependent caller routes through the ONE seam (`AppConnection.connect()`,
/// which owns open, bounded wait and the single retry), keeps the plain sentence
/// and exit 6 when the launch fails, and keeps its own `gatewayDown` wording when
/// the app is healthy but its gateway is not; the graceful no-app population stays
/// on the plain control client and never launches. The traces are table-driven:
/// each caller is driven with a recording launcher that refuses every open, over
/// a control file beside a temp catalog that nothing owns — so no drive can ever
/// resolve the machine's real catalog or reach the installed app.
final class AppLaunchSeamTests: XCTestCase {

    /// The repo checkout root, for the source-level pins.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var cliSource: String {
        (try? String(contentsOf: repoRoot.appendingPathComponent("Sources/KeysCore/CLI.swift"), encoding: .utf8)) ?? ""
    }

    /// A control file path that no app owns: beside a temp catalog that does not
    /// exist, like a fresh machine. Every drive in this suite is confined to one
    /// of these, never the default catalog location — the guard fails closed on
    /// the URL before the drive runs.
    private func nowhereControl() throws -> URL {
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: .neverLaunching)
        return control
    }

    // MARK: - The eligible caller table (VAL-CONNECT-003)

    /// Every eligible CLI caller, driven against a refused launcher, an instant
    /// clock and an ownerless control file: the same one-seam trace (bundle id,
    /// installed path, one retry), the exact plain sentence, and exit 6 — no
    /// caller's own wording anywhere.
    func testEligibleCallersLaunchThroughTheOneSeam() throws {
        let nowhere = try nowhereControl()
        // The guard with the drives' own values: the explicit temporary control
        // URL and the refused fake pair every case below runs with.
        try AppConnectionIsolationGuard.assertIsolated(control: nowhere, launch: refusedLaunch().seam)
        let cases: [(label: String, drive: (RecordingAppLaunch) throws -> Void)] = [
            ("keys grant", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["grant", "demo"]) as? GrantCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys grants", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["grants"]) as? GrantsCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys revoke", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["revoke", "a1b2c3d4"]) as? RevokeCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys renew", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["renew", "a1b2c3d4"]) as? RenewCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys gateway on", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["gateway", "on", "demo"]) as? GatewayCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys gateway off", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["gateway", "off", "demo"]) as? GatewayCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys gateway cheapest on", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["gateway", "cheapest", "on", "demo"]) as? GatewayCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys relay on", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["relay", "on"]) as? RelayOnCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys relay off", { seam in
                try XCTUnwrap(try KeysCLI.parseAsRoot(["relay", "off"]) as? RelayOffCommand)
                    .run(launch: seam.seam, control: nowhere)
            }),
            ("keys tunnel --print", { seam in
                try XCTUnwrap(
                    try KeysCLI.parseAsRoot(["tunnel", "user@server.example.com", "--print-only"]) as? TunnelCommand
                ).run(launch: seam.seam, control: nowhere, gatewayListening: { true })
            }),
            ("the grant path of keys agent", { seam in
                try AgentCommand.issueGrant(
                    agent: .claude, key: "demo", minutes: nil, profile: nil,
                    launch: seam.seam, control: nowhere
                )
            }),
        ]

        for testCase in cases {
            let launch = refusedLaunch()
            XCTAssertThrowsError(try testCase.drive(launch), "\(testCase.label): the launch fails") { error in
                guard case AppError.siteUnavailable(let message) = error else {
                    return XCTFail("\(testCase.label): expected .siteUnavailable, got \(error)")
                }
                XCTAssertEqual(message, AppConnection.notRunningMessage,
                               "\(testCase.label): the seam's plain sentence, byte for byte")
                XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6,
                               "\(testCase.label): the CLI keeps exit 6")
            }

            XCTAssertEqual(
                launch.launchTargets,
                ["bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)",
                 "bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)"],
                "\(testCase.label): the one-seam trace — bundle id, installed path, exactly one retry"
            )
        }
    }

    /// A refused launcher: nothing is installed, and the clock never sleeps, so a
    /// drive runs the whole real policy instantly against the fakes.
    private func refusedLaunch() -> RecordingAppLaunch {
        let launch = RecordingAppLaunch()
        launch.openBundleID = false
        launch.openInstalledPath = false
        return launch
    }

    /// `keys wrap` joins the same policy at its first real app contact: a file WITH
    /// something to wrap reaches the backend's connect closure, which is the seam.
    /// The value is a runtime-generated synthetic string, never a committed key
    /// literal.
    func testWrapLaunchesThroughTheOneSeam() throws {
        let dir = try TempDir.make()
        let file = dir.appendingPathComponent("agent.env")
        try Data("OPENAI_API_KEY=sk-synthetic-\(UUID().uuidString)\n".utf8).write(to: file)
        let launch = refusedLaunch()
        let control = try nowhereControl()
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        let command = try XCTUnwrap(try KeysCLI.parseAsRoot(["wrap", file.path, "--yes"]) as? WrapCommand)

        XCTAssertThrowsError(try command.run(launch: launch.seam, control: control)) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected .siteUnavailable, got \(error)")
            }
            XCTAssertEqual(message, AppConnection.notRunningMessage)
            XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6)
        }
        XCTAssertEqual(
            launch.launchTargets,
            ["bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)",
             "bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)"],
            "the one-seam trace once the plan needs the app"
        )
    }

    /// The seam's launch POLICY, pinned on the source (VAL-H-003): only the
    /// install at the fixed location may be opened. LaunchServices registers a
    /// mounted disk image's copy or a build output under the same bundle id as
    /// readily as the real install, so `openInstalledApp` must check the
    /// resolution — through the launcher's `resolve` seam — before the open by
    /// id, and refuse anything that is not the installed path. The pin is
    /// source-level because the refusal needs a launcher that resolves to a
    /// foreign URL, which the pre-fix seam cannot even express.
    func testTheSeamRefusesABundleIDResolutionThatIsNotTheInstall() throws {
        let seam = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppConnection.swift"), encoding: .utf8
        )
        let check = try XCTUnwrap(
            seam.range(of: "resolve(bundleID: appBundleID)"),
            "the seam inspects where LaunchServices resolved the bundle id before opening by it"
        )
        let byID = try XCTUnwrap(
            seam.range(of: "open(bundleID: appBundleID)"),
            "the open by bundle id"
        )
        XCTAssertLessThan(
            check.lowerBound, byID.lowerBound,
            "the resolution is checked before the bundle-id open, so a foreign resolution is never opened"
        )
        XCTAssertTrue(
            seam.contains("registered != installedAppURL"),
            "a resolution that is not the installed location is refused and the installed-path form is used"
        )
    }

    /// VAL-H-003's behavior: a launcher whose bundle-id resolution is a mounted
    /// disk image's copy (/Volumes/Keysrs/Keysrs.app — what LaunchServices
    /// answers while the DMG is mounted) is REFUSED: no open by the bundle id
    /// happens at all, and the installed-path form is used on both attempts.
    /// The launcher fake would accept the bundle-id open (`openBundleID` true),
    /// so the trace proves the policy never asked.
    func testALaunchServicesResolutionElsewhereIsRefusedForTheInstalledPath() throws {
        let launch = RecordingAppLaunch()
        launch.registeredBundleURL = URL(fileURLWithPath: "/Volumes/Keysrs/Keysrs.app")
        launch.openBundleID = true
        launch.openInstalledPath = false
        let control = try nowhereControl()
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)

        XCTAssertThrowsError(try AppConnection.connect(control: control, launch: launch.seam)) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected the seam's plain not-running sentence, got \(error)")
            }
            XCTAssertEqual(message, AppConnection.notRunningMessage, "the plain sentence, byte for byte")
        }

        XCTAssertFalse(
            launch.launchTargets.contains { $0.hasPrefix("bundle:") },
            "the mounted-disk-image resolution is never opened by its bundle id"
        )
        XCTAssertEqual(
            launch.launchTargets,
            ["path:\(AppConnection.installedAppURL.path)", "path:\(AppConnection.installedAppURL.path)"],
            "the installed-path form on both attempts, with no bundle-id open between them"
        )
    }

    // MARK: - tunnel and relay run keep gatewayDown (VAL-CONNECT-003)

    /// A healthy app whose gateway is still not listening keeps `keys tunnel`'s own
    /// gatewayDown wording and exit 6 — the plain not-running sentence never
    /// replaces it, and a healthy app means no launch at all.
    func testTunnelKeepsGatewayDownWhenTheAppIsHealthy() throws {
        let (server, handler, log, control) = try Self.makeSite()
        defer { server.stop() }
        let launch = RecordingAppLaunch()
        launch.failOnOpen = true
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let command = try XCTUnwrap(
            try KeysCLI.parseAsRoot(["tunnel", "user@server.example.com", "--print-only"]) as? TunnelCommand
        )
        XCTAssertThrowsError(try command.run(launch: launch.seam, control: control, gatewayListening: { false })) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected .siteUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("gateway is not listening"), "the gatewayDown wording, unchanged")
            XCTAssertFalse(message.contains(AppConnection.notRunningMessage),
                           "a healthy app is not reported as not running")
            XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6)
        }
        XCTAssertFalse(launch.opened, "the healthy app is the fast path: nothing launched")
        XCTAssertEqual(log.count, 0, "the fast path connects on the file alone; the gateway check is its own seam")
    }

    /// `keys relay run` shares the tunnel's gate, so the same healthy-app/
    /// gateway-down outcome keeps its byte-identical wording.
    func testRelayRunKeepsGatewayDownWhenTheAppIsHealthy() throws {
        let (server, handler, _, control) = try Self.makeSite()
        defer { server.stop() }
        let launch = RecordingAppLaunch()
        launch.failOnOpen = true
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let relay = RelayRunCommand()
        XCTAssertThrowsError(
            try relay.requireGatewayUp(control: control, launch: launch.seam, gatewayListening: { false })
        ) { error in
            XCTAssertEqual((error as? AppError)?.description, TunnelCommand.gatewayDown().description,
                           "relay run and tunnel share the one wording")
            XCTAssertEqual((error as? AppError)?.exitCode, 6)
        }
        XCTAssertFalse(launch.opened, "a healthy app launches nothing")
    }

    /// With no app up at all, the direct gateway consumers get the app LAUNCHED for
    /// them and, if the gateway is then still closed, the failure is gatewayDown —
    /// not the launch's. The gate's one request is the health probe.
    func testTunnelLaunchesThenKeepsGatewayDown() throws {
        let (server, handler, log, control) = try Self.makeSite()
        defer { server.stop() }
        let launch = RecordingAppLaunch()
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        launch.onSleep = { count in
            if count == 1 {
                try? ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
            }
        }
        let command = try XCTUnwrap(
            try KeysCLI.parseAsRoot(["tunnel", "user@server.example.com", "--print-only"]) as? TunnelCommand
        )
        XCTAssertThrowsError(
            try command.run(launch: launch.seam, control: control, gatewayListening: { false })
        ) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected .siteUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("gateway is not listening"), "gatewayDown after a successful launch")
        }
        XCTAssertEqual(launch.launchTargets, ["bundle:\(AppConnection.appBundleID)"], "the app was launched")
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath],
                       "the gate's one request is the health probe")
    }

    // MARK: - The graceful population never launches (VAL-CONNECT-004)

    /// A file with nothing to wrap never reaches the app: the backend's connect is
    /// lazy, so the seam is never asked for anything — proven with a launcher that
    /// fails the test the moment it is called.
    func testWrapWithNothingToWrapNeverLaunches() throws {
        let dir = try TempDir.make()
        let file = dir.appendingPathComponent("empty.env")
        try Data("FOO=not-a-key\nBAR=12\n".utf8).write(to: file)

        let launch = RecordingAppLaunch()
        launch.failOnOpen = true
        let control = try nowhereControl()
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        let command = try XCTUnwrap(try KeysCLI.parseAsRoot(["wrap", file.path, "--yes"]) as? WrapCommand)
        try command.run(launch: launch.seam, control: control)
        XCTAssertFalse(launch.opened, "nothing to wrap: no running app is needed, none is launched")
    }

    /// The `keys list --json` app-view merge stays on the graceful path: no live
    /// control file means the local rows answer and no launch exists to observe.
    func testListMergeStaysGraceful() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let control = ControlFile.url(beside: db.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: .neverLaunching)

        let rows = try ListCommand.jsonRows(service: service)
        XCTAssertEqual(rows.count, 1, "the app-free merge answers from the local rows")
        XCTAssertEqual(rows.first?["name"] as? String, "demo")
    }

    // MARK: - The structural pins

    /// Launch behavior and its constants live only in `AppConnection` (the policy)
    /// and `AppLaunch` (the injectable effects): no other source in the product
    /// can resolve a bundle id, name the installed path, or open an app on a
    /// caller's behalf. The AppRuntime's second-instance check names the bundle id
    /// but never opens anything — the scan pins that too.
    func testTheOneSeamOwnsTheLaunchPrimitives() throws {
        let sources = try FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/KeysCore"), includingPropertiesForKeys: nil
        )
        // DoctorInstall names the installed path only to LOCATE the bundle for its
        // install-state diagnostics; it never opens anything, so it is not a launcher.
        let owners: Set<String> = ["AppConnection.swift", "AppLaunch.swift", "DoctorInstall.swift"]
        var scanned = 0
        for url in sources where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if !owners.contains(url.lastPathComponent) {
                XCTAssertFalse(source.contains("urlForApplication"),
                               "\(url.lastPathComponent): resolving an app by bundle id is the one seam's")
                XCTAssertFalse(source.contains("/Applications/Keysrs.app"),
                               "\(url.lastPathComponent): naming the installed app is the one seam's")
            }
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 0, "the scan found the sources")

        // The `keys unwrap` caller (the onboarding slice, merged onto this branch)
        // is documented on the seam: it exists and deliberately keeps the plain
        // control client — no auto-launch — so it is a parsed command, not a
        // launch-seam caller.
        let seam = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppConnection.swift"), encoding: .utf8
        )
        XCTAssertTrue(seam.contains("keys unwrap"), "the seam documents the unwrap caller")
        XCTAssertNoThrow(try KeysCLI.parseAsRoot(["unwrap"]), "keys unwrap is a real command on the merged branch")
    }

    /// The caller map is the contract's: the eligible set routes through
    /// `AppConnection.connect()` (relay run through the shared tunnel gate), the
    /// graceful set stays on the plain `ControlClient.connect()`, and nothing else
    /// touches either.
    func testTheCallerMapIsTheApprovedOne() throws {
        let blocks = Self.commandBlocks(Self.cliSource)

        // Who routes through the one seam. RelayRunCommand delegates to the shared
        // tunnel gate rather than duplicating the policy, so both spellings count.
        let seamRouted = blocks.filter { _, body in
            body.contains("AppConnection.connect") || body.contains("TunnelCommand.requireGatewayUp")
        }
        XCTAssertEqual(
            Set(seamRouted.keys),
            ["GrantCommand", "GrantsCommand", "RevokeCommand", "RenewCommand", "GatewayCommand", "WrapCommand",
             "AgentCommand", "RelayOnCommand", "RelayOffCommand", "TunnelCommand", "RelayRunCommand",
             "DashboardCommand"],
            "exactly the eligible population routes through AppConnection.connect"
        )

        // Who stays on the graceful control client. ProviderUnhideCommand routes
        // through ProviderHideCommand.setHidden, so it has no connect of its own.
        // UnwrapCommand is the onboarding slice's `keys unwrap`: it deliberately
        // keeps the plain client and never auto-launches (a script gets exit 6).
        let graceful = blocks.filter { _, body in body.contains("ControlClient.connect") }
        XCTAssertEqual(
            Set(graceful.keys),
            ["ListCommand", "ClientIssueCommand", "ProviderAddCommand", "ProviderRmCommand", "ProviderHideCommand",
             "AgentCommand", "RelayPairIssueCommand", "RelayPairRequireCommand", "RelayStatusCommand",
             "RelayResetCommand", "UnwrapCommand"],
            "exactly the graceful population keeps the plain control client"
        )
    }

    // MARK: - Rigs

    /// A synthetic app site — the real APIHandler behind a loopback server on an
    /// ephemeral port — for the healthy-app cases. The world is guarded before
    /// any fixture: the control URL beside the catalog, the fake launch pair and
    /// the fake secret store are fail-closed-checked first. Never the installed
    /// app, never ports 12765/12766/12767.
    private static func makeSite() throws -> (
        server: LoopbackHTTPServer, handler: APIHandler, log: RequestLog, control: URL
    ) {
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let db = try CatalogDB(path: catalog)
        let (service, _) = makeGatedService(db: db, secrets: secrets)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        return (server, handler, log, control)
    }

    /// CLI.swift cut into one block per top-level `struct`, keyed by name.
    private static func commandBlocks(_ source: String) -> [String: String] {
        var blocks: [String: String] = [:]
        var current: String?
        var body: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("struct ") {
                if let current { blocks[current] = body.joined(separator: "\n") }
                let name = line.split(separator: " ", maxSplits: 2)[1].split(separator: ":").first.map(String.init)!
                current = name
                body = [String(line)]
            } else if current != nil {
                body.append(String(line))
            }
        }
        if let current { blocks[current] = body.joined(separator: "\n") }
        return blocks
    }
}
