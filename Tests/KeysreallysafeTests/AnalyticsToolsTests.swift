import Foundation
import XCTest
@testable import KeysCore

/// F2 VAL-AN-006..011: the analytics-sharing app route and the
/// `set_analytics_sharing` tool. The route runs in-process over a temp catalog on
/// an ephemeral port (never 12766/12767, never the installed app), consent is a
/// real `ProductAnalytics` with a recording transport, and the one confirmation
/// line is captured through the injectable seam. The tool is driven over the
/// in-process `MCPSession` rig against the synthetic app, exactly as `keys mcp`
/// would serve it.
final class AnalyticsToolsTests: XCTestCase {

    /// The contract's pinned not-running sentence, byte for byte.
    private static let notRunningSentence = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    private let fm = FileManager.default

    /// The capturing stand-in for the app's one analytics log seam.
    private final class LogSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func log(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    }

    private struct Site {
        let server: LoopbackHTTPServer
        let handler: APIHandler
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let control: URL
        let gate: RecordingPresenceGate
        let log: LogSpy
        let transport: ProductAnalyticsTests.Transport
        let analytics: ProductAnalytics
        let tools: MCPAnalyticsTools
    }

    /// The in-process app: a real `APIHandler` behind a loopback server on an
    /// ephemeral port, `control.json` beside the catalog naming it, a real
    /// `ProductAnalytics` (default off) with a recording transport, and the log
    /// seam captured.
    private func makeSite() throws -> Site {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, transport: transport)
        service.analytics = analytics
        let log = LogSpy()
        service.analyticsLog = { log.log($0) }
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(server: server, handler: handler, service: service, db: db, dir: dir,
                    control: control, gate: gate, log: log, transport: transport,
                    analytics: analytics, tools: MCPAnalyticsTools(control: control, launch: .neverLaunching))
    }

    /// One tool call answered as the server would answer it: a throw becomes the
    /// isError result `MCPServer.serveToolsCall` makes of it, so the pinned
    /// sentences and refusal wording are asserted exactly as a client sees them.
    private func served(_ tools: MCPAnalyticsTools, _ arguments: [String: Any]) -> MCPToolResult {
        do {
            return try tools.call("set_analytics_sharing", arguments: arguments)
        } catch {
            return MCPToolResult.failure(MCPToolErrorFormatter.message(for: error))
        }
    }

    private func text(_ result: MCPToolResult) -> String {
        (result.content.first?["text"] as? String) ?? ""
    }

    /// One dashboard request to the sharing route, carrying the origin token.
    private func post(_ site: Site, _ body: Any) throws -> HTTPResponse {
        handle(site.handler, method: "POST", path: "/api/mcp/analytics/sharing", body: try JSONValue.data(body))
    }

    // MARK: - The route (VAL-AN-006, 007, 008, 011)

    /// A set reaches the app route, goes through `setEnabled` (consent version 2),
    /// returns the bounded `{"enabled": <bool>}` — never the status preview — and
    /// writes exactly one confirmation line through the seam. Enabling sends
    /// nothing and asks for no Touch ID.
    func testRouteSetsConsentLogsOneLineAndAnswersBounded() throws {
        let site = try makeSite()
        defer { site.server.stop() }

        // Fresh state is off, with no consent written.
        XCTAssertEqual(site.analytics.isEnabled, false)
        XCTAssertNil(try site.db.metaValue(ProductAnalytics.stateKey))

        let on = try post(site, ["enabled": true])
        XCTAssertEqual(on.status, 200)
        let onBody = try JSONSerialization.jsonObject(with: on.body) as? [String: Any]
        XCTAssertEqual(onBody?["enabled"] as? Bool, true)
        XCTAssertEqual(Set(onBody?.keys.map { $0 } ?? []), ["enabled"], "the bounded answer, never the status preview")
        XCTAssertEqual(site.analytics.isEnabled, true)
        XCTAssertEqual(site.log.recorded, ["analytics sharing turned on"])
        XCTAssertTrue(site.transport.calls.isEmpty, "enabling sends nothing")
        XCTAssertTrue(site.transport.fetches.isEmpty, "enabling fetches nothing")
        XCTAssertEqual(site.gate.reasons, [], "no Touch ID on the sharing path")

        let off = try post(site, ["enabled": false])
        XCTAssertEqual(off.status, 200)
        let offBody = try JSONSerialization.jsonObject(with: off.body) as? [String: Any]
        XCTAssertEqual(offBody?["enabled"] as? Bool, false)
        XCTAssertEqual(Set(offBody?.keys.map { $0 } ?? []), ["enabled"])
        XCTAssertEqual(site.analytics.isEnabled, false)
        XCTAssertEqual(site.log.recorded, ["analytics sharing turned on", "analytics sharing turned off"])
        XCTAssertTrue(site.transport.calls.isEmpty)
    }

    /// A non-boolean (or missing) `enabled` is refused with no state change and no
    /// log line: the validation mirrors `/api/analytics`.
    func testRouteRefusesNonBooleanWithNoChangeAndNoLogLine() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let cases: [(label: String, body: Any)] = [
            ("a number", ["enabled": 1]),
            ("a string", ["enabled": "true"]),
            ("null", ["enabled": NSNull()]),
            ("missing", [:]),
            ("an extra key", ["enabled": true, "endpoint": "https://evil.example"]),
            ("a non-object", [1, 2, 3]),
        ]
        for (label, body) in cases {
            let response = try post(site, body)
            XCTAssertEqual(response.status, 400, "\(label) is refused")
        }
        XCTAssertEqual(site.analytics.isEnabled, false, "a refused call changes no state")
        XCTAssertEqual(site.log.recorded, [], "a refused call writes no log line")
        XCTAssertTrue(site.transport.calls.isEmpty)
        XCTAssertNil(try site.db.metaValue(ProductAnalytics.stateKey), "no consent written by a refusal")
    }

    /// The menubar.log line through a real `AppLogFile`: `<UTC ISO> analytics
    /// sharing turned on|off`, exactly one line per set, no other data.
    func testLogLineIsOneTimestampedConfirmation() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let logURL = site.dir.appendingPathComponent("menubar.log")
        let file = AppLogFile(url: logURL)
        site.service.analyticsLog = { file.write($0) }

        XCTAssertEqual(try post(site, ["enabled": true]).status, 200)
        XCTAssertEqual(try post(site, ["enabled": false]).status, 200)

        let written = try String(contentsOf: logURL, encoding: .utf8)
        let lines = written.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.last, "", "the log ends with a newline")
        let entries = lines.dropLast()
        XCTAssertEqual(entries.count, 2, "exactly one line per successful set")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z analytics sharing turned (on|off)$"#
        for entry in entries {
            XCTAssertNotNil(entry.range(of: pattern, options: .regularExpression), "the line format: \(entry)")
        }
        XCTAssertTrue(entries[0].hasSuffix("analytics sharing turned on"))
        XCTAssertTrue(entries[1].hasSuffix("analytics sharing turned off"))
    }

    // MARK: - The tool (VAL-AN-006, 010, 011)

    /// The tool over the real dispatch: `set_analytics_sharing(true/false)` reaches
    /// the app route, flips consent, writes the line, and answers the bounded
    /// `{"enabled": <bool>}` — and sends nothing.
    func testToolSetsConsentOverTheRig() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let registry = try MCPRoster.registry(
            catalog: { site.db },
            control: site.control,
            fetchLatestRelease: { throw AppError.usage("the analytics tool test fetches no release") }
        )
        func call(_ arguments: [String: Any]) throws -> [String: Any] {
            let encoded = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
            let line = #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"set_analytics_sharing","arguments":\#(encoded)}}"#
            let (frames, stderr) = try MCPSession.run([MCPSession.initialize(), line], registry: registry)
            XCTAssertEqual(stderr, [], "the roster registers cleanly")
            let result = try MCPSession.assertResult(frames[1], id: "s")
            XCTAssertEqual(result["isError"] as? Bool, false)
            let answer = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any] ?? [:]
        }
        let on = try call(["enabled": true])
        XCTAssertEqual(Set(on.keys), ["enabled"], "the tool relays the bounded answer")
        XCTAssertEqual(on["enabled"] as? Bool, true)
        XCTAssertEqual(site.analytics.isEnabled, true)
        XCTAssertEqual(site.log.recorded, ["analytics sharing turned on"])
        XCTAssertTrue(site.transport.calls.isEmpty, "the tool sends nothing")

        let off = try call(["enabled": false])
        XCTAssertEqual(off["enabled"] as? Bool, false)
        XCTAssertEqual(site.analytics.isEnabled, false)
        XCTAssertEqual(site.log.recorded.count, 2)
    }

    /// A non-boolean (or missing) `enabled` is a local refusal: no round trip, no
    /// state change, no log line.
    func testToolRefusesNonBooleanLocallyWithNoRoundTrip() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let cases: [(label: String, arguments: [String: Any], expected: String)] = [
            ("missing", [:], "enabled is required"),
            ("null", ["enabled": NSNull()], "enabled is required"),
            ("a number", ["enabled": 1], "enabled must be true or false"),
            ("a string", ["enabled": "true"], "enabled must be true or false"),
        ]
        for (label, arguments, expected) in cases {
            let result = served(site.tools, arguments)
            XCTAssertEqual(result.isError, true, "\(label) is a tool error result")
            XCTAssertTrue(text(result).contains(expected), "\(label) names the argument: \(text(result))")
        }
        XCTAssertEqual(site.analytics.isEnabled, false)
        XCTAssertEqual(site.log.recorded, [])
        XCTAssertTrue(site.transport.calls.isEmpty)
    }

    /// With no app running (an unwritten control file), the tool answers the pinned
    /// not-running sentence as a tool error result, byte for byte through the guard.
    func testNotRunningSentence() throws {
        let dir = try TempDir.make()
        let control = dir.appendingPathComponent("control.json")
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        let tools = MCPAnalyticsTools(control: control, launch: .neverLaunching)
        let result = served(tools, ["enabled": true])
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(text(result), Self.notRunningSentence)
        let screened = MCPOutputGuard.production.screened(result)
        XCTAssertEqual((screened.content.first?["text"] as? String) ?? "", Self.notRunningSentence,
                       "the pinned sentence passes the output guard")
        XCTAssertEqual(screened.isError, true)
    }

    // MARK: - The app-runtime seam (VAL-INT-004)

    /// The repo checkout root, for the source-level pin below.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// VAL-INT-004: the one analytics log seam is wired in `AppRuntime.run()` beside
    /// the relay host, so the running app (and only the app) records the
    /// `set_analytics_sharing` confirmation line. That path needs a signed bundle and
    /// a window server, so it cannot be driven in a test; the assignment is pinned at
    /// the source instead — the exact line the route drives, writing the menubar log.
    func testAppRuntimeWiresTheAnalyticsLogSeam() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/AppRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("service.analyticsLog = { logFile.write($0) }"),
            "AppRuntime.run() wires KeysService.analyticsLog to the menubar log beside the relay host"
        )
    }
}
