import XCTest
@testable import KeysCore

/// VAL-CROSS-002: `keys dashboard` shows the app window through the one shared
/// app connection. The suite drives the real parsed command over recording launch
/// fakes and a synthetic app site, and proves: one show call, no browser open, no
/// second dashboard server (the command RETURNS — it no longer binds a site or
/// runs a loop), the same auto-launch behavior when no app is up, and the plain
/// not-running sentence with exit 6 when the launch fails. The browser-open
/// recorder is the pair of the request log (nothing but the probe and the show
/// route was ever called) and the source belt at the bottom: the command has no
/// opening or binding code at all.
final class DashboardCommandTests: XCTestCase {

    /// The repo checkout root, for the source belt.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A synthetic app site: the real APIHandler behind a loopback server on an
    /// ephemeral port, with a show spy standing in for the window controller and
    /// the request log the ordering assertions read. Never the installed app, never
    /// ports 12765/12766/12767.
    private func makeSite() throws -> (
        server: LoopbackHTTPServer, handler: APIHandler, log: RequestLog, control: URL, show: ShowSpy
    ) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
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
        return (server, handler, log, ControlFile.url(beside: db.path), show)
    }

    /// The parsed command, driven with a given launch seam.
    private func command(_ arguments: [String] = []) throws -> DashboardCommand {
        try XCTUnwrap(try KeysCLI.parseAsRoot(["dashboard"] + arguments) as? DashboardCommand)
    }

    /// With a healthy app already up, `keys dashboard` connects without launching
    /// anything and shows the window exactly once: one show call, no probe (a live
    /// control file is the fast path), no browser, and the command RETURNS — it
    /// never binds a second dashboard server or runs a loop. The compatibility
    /// flags still parse.
    func testDashboardShowsTheAppWindowThroughTheSharedSeam() throws {
        let (server, handler, log, control, show) = try makeSite()
        defer { server.stop() }
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let month = try command(["--month"])
        let launch = RecordingAppLaunch()
        launch.failOnOpen = true
        try month.run(launch: launch.seam, control: control)

        XCTAssertFalse(launch.opened, "a healthy app means no launch at all")
        XCTAssertEqual(show.calls, 1, "one show call, the app's own window")
        XCTAssertEqual(log.count, 1, "the show route is the one request")
        XCTAssertEqual(log.all.first?.method, "POST")
        XCTAssertEqual(log.all.first?.path, "/api/mcp/app/show")
        XCTAssertEqual(log.all.first?.headers["x-ksf-token"] ?? "", handler.originToken,
                       "the show call carries the per-launch token")

        // The source belt under "no browser, no second server": the whole CLI driver
        // names no NSWorkspace (the browser open is gone) and the command's own
        // block binds no site and runs no loop — run(launch:) returning above is
        // the behavioral proof of that.
        let cli = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/CLI.swift"), encoding: .utf8)
        XCTAssertFalse(cli.contains("NSWorkspace"), "no CLI path opens a browser or an app itself")
        let block = Self.commandBlock("DashboardCommand", in: cli)
        for forbidden in ["LoopbackSite", "RunLoop", "makeService", "NSWorkspace"] {
            XCTAssertFalse(block.contains(forbidden), "keys dashboard never \(forbidden == "RunLoop" ? "runs a server loop" : forbidden)")
        }
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
        launch.onSleep = { count in
            if count == 1 {
                try? ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
            }
        }
        try command().run(launch: launch.seam, control: control)

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

        XCTAssertThrowsError(try command().run(launch: launch.seam, control: control)) { error in
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
}
