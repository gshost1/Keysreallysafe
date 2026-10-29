import XCTest
@testable import KeysCore

/// VAL-CROSS-002 and VAL-H-008: `keys dashboard` has two halves behind one
/// branch. The bundled binary shows the app's window through the one shared app
/// connection; this suite drives the real parsed command over recording launch
/// fakes and a synthetic app site and proves for that half: one show call, no
/// browser open, no second dashboard server (the show path RETURNS — it binds no
/// site and runs no loop), the same auto-launch behavior when no app is up, and
/// the plain not-running sentence with exit 6 when the launch fails. The other
/// half is the checkout dev copy: a checkout build serves its own Web/ on the
/// documented dev port, with the browser open skipped whenever KEYS_NO_OPEN
/// asks for it — the branch decision, the serve path and the switch are all
/// driven here. The browser-open recorder is the pair of the request log
/// (nothing but the probe and the show route was ever called) and the source
/// belt at the bottom: the app-window path names no opening or binding code,
/// and the dev copy's open is the CLI's only one, behind the switch.
final class DashboardCommandTests: XCTestCase {

    /// The repo checkout root, for the source belt.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A synthetic app site: the real APIHandler behind a loopback server on an
    /// ephemeral port, with a show spy standing in for the window controller and
    /// the request log the ordering assertions read. The world is guarded before
    /// any fixture: the control URL beside the catalog, the fake launch pair and
    /// the fake secret store are fail-closed-checked first. Never the installed
    /// app, never ports 12765/12766/12767.
    private func makeSite() throws -> (
        server: LoopbackHTTPServer, handler: APIHandler, log: RequestLog, control: URL, show: ShowSpy
    ) {
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let db = try CatalogDB(path: catalog)
        let (service, _) = makeGatedService(db: db, secrets: secrets)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let show = ShowSpy()
        let handler = APIHandler(service: service, webRoot: web, showAppWindow: { show.show() })
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        return (server, handler, log, control, show)
    }

    /// The parsed command, driven with a given launch seam.
    private func command(_ arguments: [String] = []) throws -> DashboardCommand {
        try XCTUnwrap(try KeysCLI.parseAsRoot(["dashboard"] + arguments) as? DashboardCommand)
    }

    /// With a healthy app already up, the bundled `keys dashboard` connects without
    /// launching anything and shows the window exactly once: one show call, no probe
    /// (a live control file is the fast path), no browser, and the show path
    /// RETURNS — it never binds a second dashboard server or runs a loop. The
    /// compatibility flags still parse.
    func testDashboardShowsTheAppWindowThroughTheSharedSeam() throws {
        let (server, handler, log, control, show) = try makeSite()
        defer { server.stop() }
        let launch = RecordingAppLaunch()
        launch.failOnOpen = true
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let month = try command(["--month"])
        try month.run(launch: launch.seam, control: control, build: .installedBundle)

        XCTAssertFalse(launch.opened, "a healthy app means no launch at all")
        XCTAssertEqual(show.calls, 1, "one show call, the app's own window")
        XCTAssertEqual(log.count, 1, "the show route is the one request")
        XCTAssertEqual(log.all.first?.method, "POST")
        XCTAssertEqual(log.all.first?.path, "/api/mcp/app/show")
        XCTAssertEqual(log.all.first?.headers["x-ksf-token"] ?? "", handler.originToken,
                       "the show call carries the per-launch token")

        // The source belt under "no browser, no second server", adjusted to the
        // restored reality (VAL-H-008): the app-window half of `keys dashboard`
        // stays pure show — its method names no browser open, no site bind, no
        // service and no loop — while the checkout dev copy, the one place in
        // the whole CLI that opens a browser, sits inside the same command's
        // block behind the KEYS_NO_OPEN switch on the documented dev port.
        let cli = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/CLI.swift"), encoding: .utf8)
        let showBlock = Self.methodBlock("showAppWindow", in: cli)
        for forbidden in ["LoopbackSite", "RunLoop", "makeService", "AppFactory", "NSWorkspace", "openBrowser", "serveLoop"] {
            XCTAssertFalse(showBlock.contains(forbidden), "the app-window path never \(forbidden == "RunLoop" ? "runs a server loop" : forbidden)")
        }
        let dashboardBlock = Self.commandBlock("DashboardCommand", in: cli)
        XCTAssertTrue(dashboardBlock.contains("noOpenBrowser"), "the dev copy's browser open stays behind the KEYS_NO_OPEN switch")
        XCTAssertTrue(dashboardBlock.contains("LoginItem.dashboardPort"), "the dev copy binds the documented dev port")
        XCTAssertTrue(dashboardBlock.contains("LoopbackSite.bind"), "a checkout build serves its own site again")
        let outsideDashboard = cli.replacingOccurrences(of: dashboardBlock, with: "")
        XCTAssertFalse(outsideDashboard.contains("NSWorkspace"), "the dashboard's dev copy is the only CLI path that opens a browser")
    }

    /// With no app running, `keys dashboard` uses the same auto-launch behavior:
    /// open by bundle id, wait on the bounded backoff for the healthy control
    /// endpoint, then show the window once — no retry, no browser, and the
    /// app's synthetic site stays the single dashboard owner.
    func testDashboardLaunchesWhenNoAppIsRunning() throws {
        let (server, handler, log, control, show) = try makeSite()
        defer { server.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path), "no live app")

        let launch = RecordingAppLaunch()
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)
        launch.onSleep = { count in
            if count == 1 {
                try? ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
            }
        }
        try command().run(launch: launch.seam, control: control, build: .installedBundle)

        XCTAssertEqual(launch.launchTargets, ["bundle:\(AppConnection.appBundleID)"],
                       "the shared launch path: one open, no retry")
        XCTAssertEqual(launch.sleeps, [0.25], "the bounded wait up to health")
        XCTAssertEqual(show.calls, 1, "the window is shown exactly once after the launch")
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath, "/api/mcp/app/show"],
                       "launch → healthy control → show, in order")
        for request in log.all {
            XCTAssertEqual(request.headers["x-ksf-token"] ?? "", handler.originToken,
                           "both calls carry the per-launch token")
        }
    }

    /// When the launch fails, `keys dashboard` is the plain not-running sentence
    /// with exit 6, exactly like every eligible caller — no show, no browser, no
    /// site: not one request left the machine.
    func testDashboardLaunchFailureIsThePlainSentenceExit6() throws {
        let (server, _, log, control, show) = try makeSite()
        defer { server.stop() }
        let launch = RecordingAppLaunch()
        launch.openBundleID = false
        launch.openInstalledPath = false
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: launch.seam)

        XCTAssertThrowsError(try command().run(launch: launch.seam, control: control, build: .installedBundle)) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected .siteUnavailable, got \(error)")
            }
            XCTAssertEqual(message, AppConnection.notRunningMessage, "the exact sentence, byte for byte")
            XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6, "the CLI keeps exit 6")
        }
        XCTAssertEqual(show.calls, 0, "no show after a failed launch")
        XCTAssertEqual(log.count, 0, "no browser, no show, no site: nothing was called")
        XCTAssertEqual(
            launch.launchTargets,
            ["bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)",
             "bundle:\(AppConnection.appBundleID)", "path:\(AppConnection.installedAppURL.path)"],
            "one attempt, then exactly one retry"
        )
    }

    /// The checkout dev-copy rig: a real service over the guarded temp catalog, a
    /// temp Web/ holding a dev page, and a real loopback server on an ephemeral
    /// port (never the dev or app ports) that the injected bind seam hands back
    /// in place of the real 12765 bind. The browser open is a spy and the serve
    /// loop a no-op, so the drive ends when the command returns.
    private func makeServeRig() throws -> (service: KeysService, handler: APIHandler, server: LoopbackHTTPServer) {
        let secrets = MemorySecretStore()
        let (dir, catalog, _) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let db = try CatalogDB(path: catalog)
        let (service, _) = makeGatedService(db: db, secrets: secrets)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<!doctype html><title>checkout dev copy</title>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        return (service, handler, server)
    }

    /// VAL-H-008, the checkout half of the branch: a checkout build serves its own
    /// Web/ on the documented dev port — the bind seam sees the real service and
    /// the dev port, the site it returns serves the dev page, and the browser
    /// open targets exactly that bound URL.
    func testCheckoutBuildServesTheDevCopyOnTheDashboardPort() throws {
        let rig = try makeServeRig()
        defer { rig.server.stop() }
        var bound: [(service: KeysService, preferred: UInt16)] = []
        var opened: [URL] = []

        try command().run(
            launch: .neverLaunching,
            control: nil,
            build: .checkout,
            makeService: { rig.service },
            bind: { service, port in
                bound.append((service, port))
                return rig.server
            },
            openBrowser: { opened.append($0) },
            serveLoop: { _ in }
        )

        XCTAssertEqual(bound.count, 1, "one bind, the dev copy's own site")
        XCTAssertTrue(bound[0].service === rig.service, "the site serves the command's own service")
        XCTAssertEqual(bound[0].preferred, LoginItem.dashboardPort, "the documented dev port")
        XCTAssertEqual(opened.map(\.absoluteString), ["http://127.0.0.1:\(rig.server.boundPort)/?range=month"],
                       "the browser open targets the bound dev site")

        let page = handle(rig.handler, method: "GET", path: "/")
        XCTAssertEqual(page.status, 200, "the dev copy serves its Web root")
        XCTAssertTrue(
            String(decoding: page.body, as: UTF8.self).contains("checkout dev copy"),
            "the page is the checkout's Web/, not the app's copy"
        )
    }

    /// VAL-H-008: KEYS_NO_OPEN keeps the dev copy's browser tab off — the
    /// helper's own empty and "0" spellings are the documented off values.
    func testCheckoutDevCopyHonorsNoOpenBrowser() throws {
        let rig = try makeServeRig()
        defer { rig.server.stop() }
        let cases: [(value: String?, opens: Int)] = [
            (nil, 1), ("", 1), ("0", 1), ("1", 0), ("true", 0),
        ]
        for testCase in cases {
            var opened = 0
            try command().run(
                launch: .neverLaunching,
                control: nil,
                build: .checkout,
                environment: testCase.value.map { ["KEYS_NO_OPEN": $0] } ?? [:],
                makeService: { rig.service },
                bind: { _, _ in rig.server },
                openBrowser: { _ in opened += 1 },
                serveLoop: { _ in }
            )
            XCTAssertEqual(
                opened, testCase.opens,
                "KEYS_NO_OPEN=\(testCase.value ?? "<unset>") \(testCase.opens == 0 ? "stops" : "allows") the open"
            )
        }
    }

    /// VAL-H-008, the branch source: a binary inside a .app bundle owns the app's
    /// dashboard; anything else is a checkout build. This test process runs
    /// outside any bundle, and a synthesized bundle directory resolves as the
    /// installed one.
    func testTheBuildDecisionFollowsTheBundle() throws {
        XCTAssertEqual(DashboardCommand.Build.current(), .checkout, "the test runner is not an app bundle")

        let root = try TempDir.make()
        let app = root.appendingPathComponent("Keysrs.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents").appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: macos.appendingPathComponent("keys"))
        let info = ["<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
                    "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key>"
                    + "<string>com.keysreallysafe.keysrs</string></dict></plist>"]
        try info.joined(separator: "\n").write(
            to: app.appendingPathComponent("Contents").appendingPathComponent("Info.plist"),
            atomically: true, encoding: .utf8
        )
        let bundle = try XCTUnwrap(Bundle(url: app), "the synthesized app directory loads as a bundle")
        XCTAssertEqual(DashboardCommand.Build.current(bundle: bundle), .installedBundle,
                       "a binary inside a .app bundle shows the app's window")
    }

    /// The `DashboardCommand` block of CLI.swift, from its declaration to the next
    /// top-level one — the structural half of the no-browser/no-second-server pin.
    private static func commandBlock(_ name: String, in source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name)") }) else {
            XCTFail("struct \(name) not found in CLI.swift")
            return ""
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("struct ") || $0.hasPrefix("enum ") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// One method of the DashboardCommand block, from its declaration line to the
    /// brace that closes it (brace depth counted over the whole body, so a
    /// signature split over several lines still ends at its own closing brace).
    /// The belt over the restored dashboard branch (VAL-H-008) needs the
    /// app-window half alone: the command's block also holds the checkout dev
    /// copy, which does bind and open.
    private static func methodBlock(_ name: String, in source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else {
            XCTFail("func \(name) not found in CLI.swift")
            return ""
        }
        var depth = 0
        var end = start
        for index in start..<lines.endIndex {
            depth += lines[index].filter { $0 == "{" }.count
            depth -= lines[index].filter { $0 == "}" }.count
            end = index
            if depth == 0 { break }
        }
        return lines[start...end].joined(separator: "\n")
    }
}
