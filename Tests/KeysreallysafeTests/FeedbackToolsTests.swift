import Foundation
import XCTest
@testable import KeysCore

/// F1 VAL-FB-009..015: the app route, the MCP tool and the end-to-end flow.
/// The route runs in-process over a temp catalog on an ephemeral port (never
/// 12766/12767, never the installed app), the mail client / GitHub page is a
/// counting spy, presence is a recording gate and the Keychain is a memory
/// store. The end-to-end case drives a real `tools/call send_feedback` through
/// the server's real dispatch against that synthetic app and proves no planted
/// fake secret survives anywhere.
final class FeedbackToolsTests: XCTestCase {

    /// The contract's pinned not-running sentence, byte for byte.
    private static let notRunningSentence = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    private let fm = FileManager.default

    // MARK: - Rigs

    /// The counting stand-in for the app's one "open this feedback URL" action.
    /// send_feedback's purpose IS opening the user's mail client or the GitHub
    /// issue page, so the route must drive exactly this seam, once, and tests
    /// must never open anything.
    private final class OpenSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
        var recorded: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        func open(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }

    private struct Site {
        let server: LoopbackHTTPServer
        let handler: APIHandler
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let control: URL
        let gate: RecordingPresenceGate
        let open: OpenSpy
        let log: RequestLog
        let tools: MCPFeedbackTools
        /// The planted vault value: the secret the `demo` key holds.
        let plantedSecret: String
    }

    /// The in-process app: a real `APIHandler` behind a loopback server on an
    /// ephemeral port, `control.json` beside the catalog naming it, one key
    /// holding the planted fake secret and one resolved project so the name and
    /// label passes have real rows. The opener spy stands in for NSWorkspace so
    /// nothing here ever opens a mail client or a browser.
    private func makeSite(open: OpenSpy = OpenSpy()) throws -> Site {
        let plantedSecret = "fake-vault-" + String(repeating: "s3", count: 8)
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: plantedSecret)
        let folder = dir.appendingPathComponent("fb-proj", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try service.resolveProject(folder: folder.path)

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web, openFeedbackURL: { open.open($0) })
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(
            server: server, handler: handler, service: service, db: db, dir: dir,
            control: control, gate: gate, open: open, log: log,
            tools: MCPFeedbackTools(control: control, launch: .neverLaunching), plantedSecret: plantedSecret
        )
    }

    /// One JSON body for `handle`.
    private func body(_ object: [String: Any]) throws -> Data {
        try JSONValue.data(object)
    }

    /// The first text block of a tool result decoded as one JSON object.
    private func payload(
        _ result: MCPToolResult, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let text = (result.content.first?["text"] as? String) ?? ""
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            XCTFail("the result text is not a JSON object: \(text)", file: file, line: line)
            return [:]
        }
        return decoded
    }

    /// One tool call answered as the server would answer it: a throw becomes
    /// the isError result `MCPServer.serveToolsCall` makes of it, so the pinned
    /// sentences and refusal wording are asserted exactly as a client sees them.
    private func served(_ tools: MCPFeedbackTools, _ arguments: [String: Any]) throws -> MCPToolResult {
        do {
            return try tools.call("send_feedback", arguments: arguments)
        } catch {
            return MCPToolResult.failure(MCPToolErrorFormatter.message(for: error))
        }
    }

    /// The decoded query items of a recorded URL, or nil when the URL has none.
    private func queryItems(of url: URL) throws -> [(name: String, value: String)]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        return items.compactMap { item in item.value.map { (name: item.name, value: $0) } }
    }

    // MARK: - The route (VAL-FB-001, 009, 010, 011, 014, 015)

    /// A planted draft comes back scrubbed with per-category counts and the
    /// Keysrs + macOS version footer, the opener seam fires exactly once with
    /// the mailto URL whose body is the scrubbed text (no planted value), the
    /// route never consumed a presence prompt, and the raw draft never reached
    /// disk — the temp tree, catalog and WAL included, holds none of it.
    func testRouteScrubsOpensMailtoOnceAndPersistsNothing() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let marker = "the user asked for MARKER-R5 output"
        let grant = GrantToken.generate(id: "feed0010")
        let plantedPath = "/Users/planted/" + "folder"
        let raw = "the \(site.plantedSecret) leaked with \(grant) from \(plantedPath) "
            + "in the demo project fb-proj about \(marker), line one,\nline two & café"

        let refused = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                             body: try body(["draft": raw]), token: false)
        XCTAssertEqual(refused.status, 403, "the feedback route inherits the origin-token gate")

        let promptsBefore = site.gate.reasons.count
        let response = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                              body: try body(["draft": raw, "destination": "email", "prompt": marker]))
        XCTAssertEqual(response.status, 200)
        let answer = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertEqual(Set(answer.keys), ["scrubbed", "removed", "destination", "opened"],
                       "the bounded answer shape")
        XCTAssertEqual(answer["destination"] as? String, "email")
        XCTAssertEqual(answer["opened"] as? Bool, true)
        let removed = answer["removed"] as! [String: Any]
        XCTAssertEqual(removed["vault_value"] as? Int, 1)
        XCTAssertEqual(removed["token"] as? Int, 1)
        XCTAssertEqual(removed["path"] as? Int, 1)
        XCTAssertEqual(removed["name"] as? Int, 2, "the key name and the project label")
        XCTAssertEqual(removed["prompt_text"] as? Int, 1)
        XCTAssertNil(removed["email"], "no email in this draft")

        // The scrubbed text: footer, mask, none of the planted values, and the
        // prose (including the comma, newline, ampersand and non-ASCII that make
        // the percent-encoding honest) survives.
        let scrubbed = answer["scrubbed"] as! String
        XCTAssertTrue(scrubbed.contains("[redacted]"))
        XCTAssertTrue(scrubbed.contains("line one,\nline two & café"))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expectedFooter = "\n\nKeysrs \(ProductAnalyticsConfiguration.appVersion) "
            + "on macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        XCTAssertTrue(scrubbed.hasSuffix(expectedFooter), "the version footer: \(scrubbed)")
        for planted in [site.plantedSecret, grant, plantedPath, marker, "demo", "fb-proj"] {
            XCTAssertFalse(scrubbed.contains(planted), "\(planted) survived the scrub")
        }

        // The opener seam: exactly once, the mailto URL, the scrubbed body.
        XCTAssertEqual(site.open.count, 1, "the mail client opens exactly once")
        let url = site.open.recorded.first
        XCTAssertEqual(url?.scheme, "mailto")
        XCTAssertEqual(url?.absoluteString.hasPrefix("mailto:support@keysrs.com?subject="), true)
        let query = try queryItems(of: url!) ?? []
        XCTAssertEqual(query.first?.name, "subject")
        XCTAssertEqual(query.first?.value, "Keysrs feedback")
        let bodyPair = query.first { $0.name == "body" }
        XCTAssertEqual(bodyPair?.value, scrubbed, "the mailto body is the scrubbed text, decoded equal")
        // The whole URL, percent-decoded, carries none of the planted values.
        let decodedURL = url!.absoluteString.removingPercentEncoding ?? ""
        for planted in [site.plantedSecret, grant, plantedPath, marker, "demo", "fb-proj"] {
            XCTAssertFalse(decodedURL.contains(planted), "\(planted) never enters the URL")
        }

        // No Touch ID anywhere on the path, and the raw draft never hit disk:
        // nothing under the temp tree (catalog, WAL, Web, control file) holds
        // it or any planted value — only the scrubbed text ever existed.
        XCTAssertEqual(site.gate.reasons.count, promptsBefore, "the route consumed zero presence prompts")
        for needle in [site.plantedSecret, grant, plantedPath, marker, raw] {
            assertNoSentinel(needle, in: site.dir)
        }
    }

    /// destination omitted or "email" opens the mailto URL; "github" opens the
    /// issue page with title and body; anything else is refused with nothing
    /// opened — decided locally in the tool, never a round trip.
    func testDestinationPicksMailtoOrGitHubIssueURL() throws {
        let open = OpenSpy()
        let site = try makeSite(open: open)
        defer { site.server.stop() }

        // Omitted destination: email is the default.
        var response = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                              body: try body(["draft": "the chart is nice"]))
        XCTAssertEqual(response.status, 200)
        var answer = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertEqual(answer["destination"] as? String, "email")
        XCTAssertEqual(site.open.recorded.first?.scheme, "mailto")

        response = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                          body: try body(["draft": "the chart is nice", "destination": "github"]))
        XCTAssertEqual(response.status, 200)
        answer = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertEqual(answer["destination"] as? String, "github")
        XCTAssertEqual(site.open.count, 2, "one open per call")
        let url = site.open.recorded.last
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertTrue(url?.absoluteString.hasPrefix("https://github.com/gshost1/Keysreallysafe/issues/new?") ?? false)
        let query = try queryItems(of: url!) ?? []
        XCTAssertTrue(query.contains { $0.name == "title" && $0.value == "Keysrs feedback" })
        XCTAssertTrue(query.contains { $0.name == "body" && $0.value == answer["scrubbed"] as? String })

        // A bad destination is the app's 400 and never opens anything.
        let before = site.open.count
        for destination in ["sms", "carrier pigeon"] {
            let bad = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                             body: try body(["draft": "the chart is nice", "destination": destination]))
            XCTAssertEqual(bad.status, 400, "\(destination) is not a destination")
        }
        XCTAssertEqual(site.open.count, before, "nothing opened for a bad destination")
    }

    /// The route re-validates every argument type: no draft, an empty draft, a
    /// non-string draft, a non-string destination and a non-string prompt are
    /// all 400s, and none of them opens anything.
    func testRouteArgumentRefusals() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let cases: [(label: String, object: [String: Any])] = [
            ("no draft", [:]),
            ("empty draft", ["draft": ""]),
            ("non-string draft", ["draft": 42]),
            ("non-string destination", ["draft": "hello", "destination": 5]),
            ("non-string prompt", ["draft": "hello", "prompt": 5]),
        ]
        for (label, object) in cases {
            let response = handle(site.handler, method: "POST", path: "/api/mcp/feedback",
                                  body: try body(object))
            XCTAssertEqual(response.status, 400, "\(label) is refused")
            let error = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertNotNil(error["error"], "\(label) answers a named error")
        }
        XCTAssertEqual(site.open.count, 0, "no refusal ever opened anything")
    }

    // MARK: - The tool (VAL-FB-010, 011, 013)

    /// The tool relays the app's whole answer over the control channel and the
    /// result passes the output guard; the planted secret never crosses back.
    func testToolRelaysAppAnswerThroughGuard() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let marker = "the user asked for MARKER-T2 output"
        let raw = "the \(site.plantedSecret) in the fb-proj project is the issue, about \(marker)"
        let result = try site.tools.call("send_feedback", arguments: [
            "draft": raw, "destination": "github", "prompt": marker,
        ])
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(site.log.count, 1, "one round trip, exactly one open beside it")
        XCTAssertEqual(site.open.count, 1)
        let answer = try payload(result)
        XCTAssertEqual(Set(answer.keys), ["scrubbed", "removed", "destination", "opened"])
        XCTAssertEqual(answer["destination"] as? String, "github")
        let scrubbed = answer["scrubbed"] as? String ?? ""
        XCTAssertFalse(scrubbed.contains(site.plantedSecret))
        XCTAssertFalse(scrubbed.contains("fb-proj"))
        XCTAssertTrue(scrubbed.contains("Keysrs \(ProductAnalyticsConfiguration.appVersion)"))
        let removed = answer["removed"] as! [String: Any]
        XCTAssertEqual(removed["vault_value"] as? Int, 1)
        XCTAssertEqual(removed["name"] as? Int, 1)
        XCTAssertEqual(removed["prompt_text"] as? Int, 1)

        // The result as a whole passes the production guard — the scrubbed
        // text contains no token shape by construction, defense in depth.
        let screened = MCPOutputGuard.production.screened(result)
        XCTAssertFalse(screened.isError, "the relayed answer passes the output guard")
    }

    /// Bad arguments are local refusals: no round trip (the site's request log
    /// stays empty), nothing opened, plain tool-error text.
    func testToolArgumentRefusalsAreLocal() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let cases: [(label: String, arguments: [String: Any], message: String)] = [
            ("no draft", [:], "draft is required"),
            ("empty draft", ["draft": ""], "draft"),
            ("non-string draft", ["draft": 42], "draft"),
            ("bad destination", ["draft": "hello", "destination": "carrier pigeon"], "destination"),
            ("non-string destination", ["draft": "hello", "destination": 5], "destination"),
            ("non-string prompt", ["draft": "hello", "prompt": 5], "prompt"),
        ]
        for (label, arguments, expected) in cases {
            let result = try served(site.tools, arguments)
            XCTAssertEqual(result.isError, true, "\(label) is a tool error result")
            let text = (result.content.first?["text"] as? String) ?? ""
            XCTAssertTrue(text.contains(expected), "\(label) names the argument: \(text)")
        }
        XCTAssertEqual(site.log.count, 0, "a refused call never reached the app")
        XCTAssertEqual(site.open.count, 0, "a refused call opened nothing")
    }

    /// With no app running (an unwritten control file), the tool answers the
    /// pinned not-running sentence as a tool error result — never a crash, and
    /// the sentence survives the error formatter and the output guard byte for
    /// byte, exactly as a client sees it.
    func testNotRunningSentence() throws {
        let dir = try TempDir.make()
        let tools = MCPFeedbackTools(control: dir.appendingPathComponent("control.json"), launch: .neverLaunching)
        let result = try served(tools, ["draft": "hello there"])
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual((result.content.first?["text"] as? String) ?? "", Self.notRunningSentence)
        // The guard passes the sentence unchanged: a not-running result IS an
        // error result, so what is pinned is byte-identity, not a false flag.
        let screened = MCPOutputGuard.production.screened(result)
        XCTAssertEqual((screened.content.first?["text"] as? String) ?? "", Self.notRunningSentence,
                       "the pinned sentence passes the output guard")
        XCTAssertEqual(screened.isError, true)
    }

    /// The structural belt under the spy: the tool and the route never name the
    /// AppKit opener themselves — the seam's production default lives in
    /// FeedbackDelivery, and unlike open_app's belt this file's route never
    /// mentions a browser or LaunchServices either.
    func testStructuralBelt() throws {
        for name in ["MCPFeedbackTools.swift", "HTTPServer.swift"] {
            let source = try String(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Sources/KeysCore/\(name)"), encoding: .utf8
            )
            XCTAssertFalse(source.contains("NSWorkspace"), "\(name): the opener is the injected seam")
            XCTAssertFalse(source.contains("LSOpen"), "\(name) never calls LaunchServices")
        }
    }

    // MARK: - The end-to-end proof (VAL-FB-012, 014, 015)

    /// A real `tools/call send_feedback` through the server's real dispatch
    /// (the in-process MCPSession rig — the same server loop, registry, app
    /// connection, route and output guard the binary serves) against the
    /// synthetic app, with a draft carrying a planted vault value, tokens, a
    /// path, names, an email and marked prompt text: the answer carries the
    /// scrubbed text and the per-category counts, and no planted value survives
    /// in the result frames (the server's whole captured stdout), the temp tree
    /// or the recorded opener URL. The flow consumes zero presence prompts and
    /// zero analytics transport calls.
    func testEndToEndNoPlantedSecretSurvives() throws {
        let plantedSecret = "fake-vault-" + String(repeating: "e2", count: 8)
        let grant = GrantToken.generate(id: "feed0020")
        let client = GatewayClientToken.generate()
        let plantedPath = "/Users/planted/" + "e2e-folder"
        let plantedEmail = "planted-" + "agent@example.com"
        let marker = "the user asked for MARKER-E5 output"

        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: plantedSecret)
        let folder = dir.appendingPathComponent("fb-e2e", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try service.resolveProject(folder: folder.path)

        // Sharing consented ON with a recording transport: if the feedback flow
        // recorded or sent anything, it lands here and fails the test.
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, transport: transport)
        try analytics.setEnabled(true, consentVersion: ProductAnalytics.consentVersion)
        service.analytics = analytics

        let open = OpenSpy()
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web, openFeedbackURL: { open.open($0) })
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        addTeardownBlock { server.stop() }

        // The real registry over the site's control file: every production group
        // wired to this synthetic world, exactly as `keys mcp` would find it.
        let registry = try MCPRoster.registry(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("the feedback e2e fetches no release") }
        )
        let raw = "Keysrs crashed while I used the \(plantedSecret) key named demo in the fb-e2e project. "
            + "The tokens \(grant) and \(client) landed in \(plantedPath) and I was mailed at "
            + "\(plantedEmail) about \(marker)."
        let arguments = String(decoding: try JSONValue.data(
            ["draft": raw, "destination": "email", "prompt": marker] as [String: Any]
        ), as: UTF8.self)
        let call = #"{"jsonrpc":"2.0","id":"fb","method":"tools/call","params":{"name":"send_feedback","arguments":\#(arguments)}}"#
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            call,
        ], registry: registry)
        XCTAssertEqual(stderr, [], "the roster registers cleanly")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 2, "initialize plus the one tools/call")
        let result = try MCPSession.assertResult(responses[1], id: "fb")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let answer = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]

        // The answer: scrubbed, counted, opened.
        XCTAssertEqual(Set(answer.keys), ["scrubbed", "removed", "destination", "opened"])
        XCTAssertEqual(answer["destination"] as? String, "email")
        XCTAssertEqual(answer["opened"] as? Bool, true)
        let removed = answer["removed"] as! [String: Any]
        XCTAssertEqual(removed["vault_value"] as? Int, 1)
        XCTAssertEqual(removed["token"] as? Int, 2)
        XCTAssertEqual(removed["path"] as? Int, 1)
        XCTAssertEqual(removed["name"] as? Int, 2, "the key name and the project label")
        XCTAssertEqual(removed["email"] as? Int, 1)
        XCTAssertEqual(removed["prompt_text"] as? Int, 1)
        XCTAssertEqual(Set(removed.keys),
                       ["vault_value", "token", "path", "name", "email", "prompt_text"],
                       "exactly the categories this draft planted")
        let scrubbed = answer["scrubbed"] as! String
        XCTAssertTrue(scrubbed.contains("Keysrs \(ProductAnalyticsConfiguration.appVersion)"),
                      "the version footer crossed the dispatch")

        // The one open: mailto, the scrubbed body, nothing planted.
        XCTAssertEqual(open.count, 1)
        let url = open.recorded.first
        XCTAssertEqual(url?.scheme, "mailto")
        let bodyValue = (try queryItems(of: url!) ?? []).first { $0.name == "body" }?.value
        XCTAssertEqual(bodyValue, scrubbed)

        // No planted value survives: not in the result frames (the server's
        // whole captured stdout), not in the recorded URL (decoded), not
        // anywhere in the temp tree (catalog and WAL included — the app never
        // writes the draft).
        let stdout = responses.joined(separator: "\n")
        let decodedURL = url?.absoluteString.removingPercentEncoding ?? ""
        let frameTargets = [plantedSecret, grant, client, plantedPath, plantedEmail, marker, "demo", "fb-e2e", raw]
        for planted in frameTargets {
            XCTAssertFalse(stdout.contains(planted), "\(planted) leaked into the server's stdout")
            XCTAssertFalse(decodedURL.contains(planted), "\(planted) leaked into the opened URL")
        }
        for planted in [plantedSecret, grant, client, plantedPath, plantedEmail, marker, raw] {
            assertNoSentinel(planted, in: dir)
        }

        // Zero presence prompts for the whole flow, zero analytics transport
        // activity, and exactly the one app round trip.
        XCTAssertEqual(gate.reasons, [], "the feedback flow never asks for Touch ID")
        XCTAssertEqual(transport.calls.count, 0, "no analytics report was attempted")
        XCTAssertEqual(transport.fetches.count, 0, "no benchmark fetch was attempted")
    }
}
