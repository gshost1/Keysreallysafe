import Darwin
import Foundation
import XCTest
@testable import KeysCore

/// The contract's pinned not-running sentence, copied verbatim from the validation
/// contract so any drift in `AppConnection.notRunningMessage` fails these tests.
private let notRunningSentence = "Keysrs isn't running. Open Keysrs from Applications, then try again."

/// One app-bound tool, the exact shape the read and grant tools will take: every
/// call goes through `AppConnection.connect()` fresh — the control file is re-read
/// per call and nothing is cached — and one token-gated mutation round-trips to the
/// app, so the site's origin-token gate is on the probe's path.
struct AppConnectionProbeGroup: MCPToolGroup {
    static let groupName = "appprobe"

    let control: URL

    init(control: URL) { self.control = control }

    func tools() -> [MCPTool] {
        [MCPTool(
            name: "needs_app",
            title: "App-bound probe",
            description: "Test-only: one round trip through the app-connection seam.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        )]
    }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        let app = try AppConnection.connect(control: control)
        let answer = try app.call(
            method: "POST", path: "/api/preferences/hidden-usage", body: ["hidden": [] as [String]], expect: 200
        )
        return try MCPToolResult.json(answer)
    }
}

/// A loopback socket stub that accepts connections and never answers — the hung
/// site. The port is real (TCP connect succeeds), the response never comes, so only
/// the app-call timeout can end a call against it.
final class HungSiteStub: @unchecked Sendable {
    private let listenFD: Int32
    private let lock = NSLock()
    private var held: [Int32] = []
    private var stopped = false
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw AppError.http("stub socket failed") }
        listenFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(BindPolicy.loopback))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw AppError.http("stub bind/listen failed")
        }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &len)
            }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            throw AppError.http("stub getsockname failed")
        }
        port = UInt16(bigEndian: local.sin_port)
        // Accept and hold every connection open; nothing is ever written back.
        DispatchQueue(label: "test.hung-site.accept").async { [weak self] in
            guard let self else { return }
            while !self.checkStopped() {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                self.hold(client)
            }
        }
    }

    deinit { stop() }

    private func checkStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func hold(_ fd: Int32) {
        lock.lock()
        held.append(fd)
        lock.unlock()
    }

    /// Closes the listener and every held connection.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let heldFDs = held
        held = []
        lock.unlock()
        guard !alreadyStopped else { return }
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        for fd in heldFDs { Darwin.close(fd) }
    }
}

/// VAL-MCP-CONNECTION-001..005: the one app-connection seam every app-bound tool
/// routes through. `AppConnection.connect()` wraps `ControlClient.connect()` and
/// translates the failure into exactly the pinned sentence (never the legacy CLI
/// wording), the not-running condition is a tool result and never a process exit,
/// the app-call timeout is 10 s so a hung site cannot hang the server, and the
/// connection is lazy: the server starts and answers with no app present.
final class MCPAppConnectionTests: XCTestCase {

    /// The repo checkout root, for the seam's source-level pins.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The first text block's text of a tools result.
    private static func resultText(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    // MARK: - The app-bound roster loop

    /// The app-bound tools of the mission roster, by name — the contract's own
    /// list. The loops below drive whichever are registered in the production
    /// roster, so the pinned sentence is enforced roster-wide: a tool that lands
    /// later is swept by default.
    private static let appBoundToolNames = ["gateway_info", "open_app", "request_grant", "grant_status"]

    /// The safe offline argument row each app-bound tool is driven with. A
    /// registered app-bound tool with no row fails the loops by name — add its row
    /// when it lands. The grant tools name only a key: against every shape these
    /// loops drive, the connect fails or the call hangs before the app ever
    /// validates the ask, so no catalog row is needed.
    private static var appBoundArgumentRows: [String: [String: Any]] { [
        "gateway_info": [:],
        "open_app": [:],
        "request_grant": ["key": "demo"],
        "grant_status": [:],
    ] }

    /// The production roster with its app-bound tools wired over `control`: the
    /// loops drive the REAL tool groups against THIS test's site shape, never the
    /// machine's installed app (which the groups' default control URL would find,
    /// since the real app is running on this machine). The unwired seams fail
    /// loudly if a loop ever strays off the app-bound names.
    private static func appBoundRoster(control: URL) -> MCPToolRegistry {
        let unwiredCatalog: () throws -> CatalogDB = {
            throw AppError.usage("the app-bound loop reads no catalog")
        }
        let unwiredFetch: () throws -> ReleaseInfo = {
            throw AppError.usage("the app-bound loop fetches no release")
        }
        return MCPToolRegistry(groups: MCPRoster.groups(
            catalog: unwiredCatalog,
            control: control,
            fetchLatestRelease: unwiredFetch
        ))
    }

    /// The app-bound tools registered in the production roster, each with its
    /// argument row serialized for a tools/call line. Empty until those tools land.
    private static func registeredAppBoundRows() throws -> [(name: String, arguments: String)] {
        let roster = MCPToolRegistry.default.tools.map { $0.name }
        var rows: [(name: String, arguments: String)] = []
        for name in appBoundToolNames where roster.contains(name) {
            guard let row = appBoundArgumentRows[name] else {
                XCTFail("no argument row for the registered app-bound tool \"\(name)\"; add one in appBoundArgumentRows")
                continue
            }
            rows.append((name, String(decoding: try JSONValue.data(row), as: UTF8.self)))
        }
        return rows
    }

    /// A live child standing in for the app process named by the control file, so
    /// the "site" can die mid-session on demand like a quit Keysrs.app.
    private static func liveChild() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try child.run()
        return child
    }

    /// A child that exited and was reaped: kill(pid, 0) answers ESRCH, exactly the
    /// shape of a Keysrs.app that quit.
    private static func reapedChildPID() throws -> pid_t {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0"]
        try child.run()
        child.waitUntilExit()
        return child.processIdentifier
    }

    /// A real site over a temp catalog — an APIHandler behind a loopback server on
    /// an ephemeral port, with the request log the token assertions read (the
    /// `ListCommandTests` rig).
    private static func makeSite() throws -> (server: LoopbackHTTPServer, handler: APIHandler, log: RequestLog, control: URL) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        return (server, handler, log, ControlFile.url(beside: db.path))
    }

    /// Every control-file shape that reads as "no live site" — the contract's list:
    /// the file absent, its owning process gone, and each body `ControlFile.read`
    /// rejects (invalid JSON, port 0, port 70000, pid 0, negative pid).
    private static func notRunningControls() throws -> [(label: String, control: URL)] {
        var shapes: [(label: String, control: URL)] = []
        // Absent: the parent directory itself does not exist, like a fresh machine.
        let absent = try TempDir.make().appendingPathComponent("never-created").appendingPathComponent("control.json")
        shapes.append(("file absent", absent))
        // A dead owning pid: a child that exited and was reaped, like a quit app.
        let dead = try TempDir.make().appendingPathComponent("control.json")
        try ControlFile.write(port: 443, token: "dead-owner", pid: reapedChildPID(), to: dead)
        shapes.append(("dead pid", dead))
        // Malformed bodies, written raw so ControlFile.write's own validation is bypassed.
        for (label, body) in [
            ("invalid json", #"not json at all"#),
            ("port 0", #"{"port":0,"pid":999,"token":"t"}"#),
            ("port 70000", #"{"port":70000,"pid":999,"token":"t"}"#),
            ("pid 0", #"{"port":443,"pid":0,"token":"t"}"#),
            ("pid negative", #"{"port":443,"pid":-1,"token":"t"}"#),
        ] {
            let url = try TempDir.make().appendingPathComponent("control.json")
            try Data(body.utf8).write(to: url)
            shapes.append((label, url))
        }
        return shapes
    }

    // MARK: - CONNECTION-001

    /// A live site round trip succeeds and carries the per-launch `X-KSF-Token` from
    /// control.json on every call, asserted through the rig's request log; the
    /// token-gated mutation proves the site would have refused the call without it.
    func testLiveRoundTripTokenOnEveryCall() throws {
        let (server, handler, log, control) = try Self.makeSite()
        defer { server.stop() }
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        // The one decision: connect() succeeds against a live site.
        let app = try AppConnection.connect(control: control)

        // A read round-trips (GET /api/grants → 200)…
        let grants = try app.call(method: "GET", path: "/api/grants", expect: 200)
        XCTAssertNotNil(grants["grants"] as? [Any])
        // …and so does a token-gated mutation: the origin-token check would have
        // refused it (403) if the per-launch token were missing or wrong.
        let hidden = try app.call(
            method: "POST", path: "/api/preferences/hidden-usage", body: ["hidden": [] as [String]], expect: 200
        )
        XCTAssertEqual((hidden["hidden"] as? [Any])?.count, 0)

        // Every AppConnection call carried the control file's per-launch token.
        XCTAssertEqual(log.count, 2, "one request per call, no retries")
        for request in log.all {
            XCTAssertEqual(request.headers["x-ksf-token"] ?? "", handler.originToken,
                           "X-KSF-Token from control.json on every call")
        }
    }

    // MARK: - CONNECTION-002

    /// With the control file missing, stale (dead pid) or malformed, EVERY
    /// app-dependent roster tool returns a tools/call isError result whose text is
    /// exactly the pinned sentence — byte-for-byte, never the legacy ControlClient
    /// wording, never a JSON-RPC error — and the server serves the next ping. The
    /// loop is roster-derived, so a tool that bypasses `AppConnection.connect()` and
    /// leaks the legacy wording fails it.
    func testNotRunningSentenceEverywhere() throws {
        XCTAssertEqual(AppConnection.notRunningMessage, notRunningSentence,
                       "the seam's constant is the contract's sentence, byte for byte")
        let appBound = try Self.registeredAppBoundRows()

        for (label, control) in try Self.notRunningControls() {
            // The probe rides beside the control-wired production roster, so the
            // session drives the same sentence through both the seam itself and
            // every registered app-bound tool.
            let registry = MCPToolRegistry(
                groups: Self.appBoundRoster(control: control).groups + [AppConnectionProbeGroup(control: control)]
            )
            var lines = [MCPSession.initialize(id: "open")]
            lines.append(#"{"jsonrpc":"2.0","id":"probe","method":"tools/call","params":{"name":"needs_app"}}"#)
            for (index, tool) in appBound.enumerated() {
                lines.append(#"{"jsonrpc":"2.0","id":"tool\#(index)","method":"tools/call","params":{"name":"\#(tool.name)","arguments":\#(tool.arguments)}}"#)
            }
            lines.append(#"{"jsonrpc":"2.0","id":"after","method":"ping"}"#)

            let (frames, stderr) = try MCPSession.run(lines, registry: registry)
            XCTAssertEqual(frames.last, "")
            XCTAssertEqual(stderr, [], "\(label): a not-running tool call is a result, not a diagnostic")
            let responses = Array(frames.dropLast())
            XCTAssertEqual(responses.count, 3 + appBound.count, "\(label): one response per request")

            let opened = try MCPSession.assertResult(responses[0], id: "open")
            XCTAssertEqual(opened["protocolVersion"] as? String, "2025-06-18",
                           "\(label): the session opened normally")

            // The not-running condition is a RESULT carrying the exact sentence.
            let probe = try MCPSession.assertResult(responses[1], id: "probe")
            XCTAssertEqual(probe["isError"] as? Bool, true, "\(label): the not-running condition is a tool result")
            XCTAssertEqual(Self.resultText(probe), notRunningSentence, "\(label): the exact sentence, byte for byte")
            XCTAssertFalse(Self.resultText(probe).contains("no running Keysrs site owns the gateway"),
                           "\(label): the legacy ControlClient wording never reaches a result")

            for (index, tool) in appBound.enumerated() {
                let result = try MCPSession.assertResult(responses[2 + index], id: "tool\(index)")
                XCTAssertEqual(result["isError"] as? Bool, true, "\(label): \(tool.name) is a tool result")
                XCTAssertEqual(Self.resultText(result), notRunningSentence,
                               "\(label): \(tool.name) carries the same exact sentence")
            }

            // And the server serves the next ping after every failure.
            XCTAssertTrue((try MCPSession.assertResult(responses[responses.count - 1], id: "after")).isEmpty,
                          "\(label): the ping after the failures answers {}")
        }
    }

    // MARK: - CONNECTION-003

    /// Mid-session site loss surfaces bounded plain errors and never a hang or a
    /// cached success: removing control.json makes the next call the exact sentence,
    /// a stale per-launch token is a plain refusal with no status text and no token
    /// in the message while the app keeps serving, and a site that dies between
    /// calls fails promptly through the connect path.
    func testMidSessionSiteLoss() throws {
        let (server, handler, _, control) = try Self.makeSite()
        defer { server.stop() }
        // The control file names a live stand-in process as its pid, so the site
        // can die mid-session exactly like a quit Keysrs.app.
        let sitter = try Self.liveChild()
        defer {
            if sitter.isRunning { sitter.terminate() }
            sitter.waitUntilExit()
        }
        try ControlFile.write(port: server.boundPort, token: handler.originToken, pid: sitter.processIdentifier, to: control)
        // The probe beside the control-wired production roster: this loop drives
        // the seam, and the roster stays pointed at THIS site should a later edit
        // add a registered-tool call.
        let registry = MCPToolRegistry(
            groups: Self.appBoundRoster(control: control).groups + [AppConnectionProbeGroup(control: control)]
        )

        func probe(_ id: String) throws -> (isError: Bool, text: String) {
            let (frames, _) = try MCPSession.run([
                MCPSession.initialize(id: "open"),
                #"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"needs_app"}}"#,
            ], registry: registry)
            XCTAssertEqual(frames.last, "")
            let responses = Array(frames.dropLast())
            XCTAssertEqual(responses.count, 2)
            let result = try MCPSession.assertResult(responses[1], id: id)
            return (result["isError"] as? Bool ?? false, Self.resultText(result))
        }

        /// Each failure below is timed: every one of them must come back inside the
        /// app-call timeout — bounded, never a hang.
        func timed(_ body: () throws -> Void) rethrows -> TimeInterval {
            let started = Date()
            try body()
            return Date().timeIntervalSince(started)
        }

        // Live: the probe round-trips 200 through the token gate.
        let live = try probe("live")
        XCTAssertEqual(live.isError, false)
        XCTAssertFalse(live.text.isEmpty, "the probe answered the site's JSON")

        // The control file disappears (what the app's own exit cleanup does): the
        // NEXT call is the exact sentence — no cached connection outlives the site.
        let goneElapsed = try timed {
            try FileManager.default.removeItem(at: control)
            let gone = try probe("gone")
            XCTAssertEqual(gone.isError, true)
            XCTAssertEqual(gone.text, notRunningSentence)
        }
        XCTAssertLessThan(goneElapsed, AppConnection.appCallTimeout)

        // A stale per-launch token: the site is up and the pid alive, but the site
        // refuses the call — a plain error, no status text, no token, no path.
        let refusedElapsed = try timed {
            try ControlFile.write(port: server.boundPort, token: "stale-launch-token", pid: sitter.processIdentifier, to: control)
            let refused = try probe("refused")
            XCTAssertEqual(refused.isError, true)
            XCTAssertNotEqual(refused.text, notRunningSentence,
                              "the app IS running; it refused the call, it did not vanish")
            XCTAssertFalse(refused.text.contains("403"), "no raw status text in the message")
            XCTAssertFalse(refused.text.contains("stale-launch-token"), "no token in the message")
            XCTAssertFalse(refused.text.contains("/"), "no path in the message")
        }
        XCTAssertLessThan(refusedElapsed, AppConnection.appCallTimeout)

        // The site dies between calls: server stopped, stand-in reaped, the control
        // file still holding the good token — the next call fails through the
        // connect path's pid check, promptly, with the exact sentence.
        let deadElapsed = try timed {
            server.stop()
            sitter.terminate()
            sitter.waitUntilExit()
            let dead = try probe("dead")
            XCTAssertEqual(dead.isError, true)
            XCTAssertEqual(dead.text, notRunningSentence)
        }
        XCTAssertLessThan(deadElapsed, AppConnection.appCallTimeout,
                           "the connect path answers promptly — no hang, no infinite pending loop")

        // The MCP server kept serving through every one of the losses.
        let (after, _) = try MCPSession.run([
            MCPSession.initialize(id: "open"),
            #"{"jsonrpc":"2.0","id":"after","method":"ping"}"#,
        ], registry: registry)
        XCTAssertEqual(after.last, "")
        let responses = Array(after.dropLast())
        XCTAssertEqual(responses.count, 2)
        XCTAssertTrue((try MCPSession.assertResult(responses[1], id: "after")).isEmpty)
    }

    // MARK: - CONNECTION-004

    /// A hung site cannot hang the server: against a socket stub that accepts and
    /// never responds, each app-dependent call comes back inside the app-call
    /// timeout (overriding ControlClient's 180 s default) as an isError result, and
    /// the server keeps serving.
    func testHungSiteBounded() throws {
        XCTAssertEqual(AppConnection.appCallTimeout, 10, "the contract's 10 s app-call timeout")
        let stub = try HungSiteStub()
        defer { stub.stop() }
        let control = try TempDir.make().appendingPathComponent("control.json")
        try ControlFile.write(port: stub.port, token: "hung-site", pid: ProcessInfo.processInfo.processIdentifier, to: control)
        // The app-bound production tools wired over the HUNG site's control file,
        // so the bound below drives the real groups against the stub, never the
        // machine's installed app.
        let registry = MCPToolRegistry(
            groups: Self.appBoundRoster(control: control).groups + [AppConnectionProbeGroup(control: control)]
        )

        // The probe call sits out the whole 10 s app-call timeout and comes back.
        let started = Date()
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(id: "open"),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"needs_app"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ], registry: registry)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 3)
        _ = try MCPSession.assertResult(responses[0], id: "open")
        let hung = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(hung["isError"] as? Bool, true)
        XCTAssertFalse(Self.resultText(hung).isEmpty, "a bounded plain error, not a hang")
        XCTAssertFalse(Self.resultText(hung).contains("hung-site"), "the control token never enters the message")
        XCTAssertGreaterThanOrEqual(elapsed, 9, "the call sat out the 10 s app-call timeout")
        XCTAssertLessThanOrEqual(elapsed, 12, "the 10 s app-call timeout overrides the 180 s default")
        XCTAssertTrue((try MCPSession.assertResult(responses[2], id: 2)).isEmpty,
                      "the server keeps serving after the timed-out call")

        // The same bound holds for every registered app-bound production tool: each
        // call comes back inside the timeout as an isError result.
        for tool in try Self.registeredAppBoundRows() {
            let toolStarted = Date()
            let (toolFrames, _) = try MCPSession.run([
                MCPSession.initialize(id: "open"),
                #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"\#(tool.name)","arguments":\#(tool.arguments)}}"#,
                #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#,
            ], registry: registry)
            let toolElapsed = Date().timeIntervalSince(toolStarted)
            XCTAssertEqual(toolFrames.last, "")
            let toolResponses = Array(toolFrames.dropLast())
            XCTAssertEqual(toolResponses.count, 3)
            let result = try MCPSession.assertResult(toolResponses[1], id: "t")
            XCTAssertEqual(result["isError"] as? Bool, true, "\(tool.name) is a tool result")
            XCTAssertLessThanOrEqual(toolElapsed, 12, "\(tool.name) comes back inside the app-call timeout")
            XCTAssertTrue((try MCPSession.assertResult(toolResponses[2], id: "p")).isEmpty,
                          "\(tool.name): the server keeps serving")
        }
    }

    // MARK: - CONNECTION-005

    /// With no control.json anywhere and no catalog, the server starts and answers
    /// initialize, tools/list and ping; the app is contacted per tool call only —
    /// the FIRST contact of the run is the app-bound tool call, and it is a tool
    /// result (the exact sentence), never an exit. The process half (exit 0 at EOF
    /// with no app) is `scripts/tests/test_keys_mcp_stdio.py` plus the spawned check.
    func testServerServesWithoutApp() throws {
        // An empty directory is the whole world: no catalog, no control file.
        let empty = try TempDir.make()
        let control = empty.appendingPathComponent("control.json")
        // The control-wired production roster, so even this test's roster can only
        // ever see the app-less world.
        let registry = MCPToolRegistry(
            groups: Self.appBoundRoster(control: control).groups + [AppConnectionProbeGroup(control: control)]
        )

        // Construction and the handshake never touch the app: had anything tried
        // to connect here, the throw would have ended this run before a frame.
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(id: "open"),
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"needs_app"}}"#,
            #"{"jsonrpc":"2.0","id":"late","method":"ping"}"#,
        ], registry: registry)
        XCTAssertEqual(frames.last, "")
        XCTAssertEqual(stderr, [], "a clean app-less session writes no diagnostics")
        let responses = Array(frames.dropLast())
        XCTAssertEqual(responses.count, 5)

        let opened = try MCPSession.assertResult(responses[0], id: "open")
        XCTAssertEqual(opened["protocolVersion"] as? String, "2025-06-18", "initialize answers with no app present")
        let roster = try MCPSession.toolNames(in: responses[1], id: "list")
        XCTAssertTrue(roster.contains("version"), "tools/list answers the roster")
        XCTAssertTrue(roster.contains("needs_app"), "the app-bound probe is listed")
        XCTAssertTrue((try MCPSession.assertResult(responses[2], id: "ping")).isEmpty, "ping answers {}")

        // The first app contact is this tool call, and it is a tool result.
        let probe = try MCPSession.assertResult(responses[3], id: 9)
        XCTAssertEqual(probe["isError"] as? Bool, true)
        XCTAssertEqual(Self.resultText(probe), notRunningSentence)
        // The session served past the failure, to EOF.
        XCTAssertTrue((try MCPSession.assertResult(responses[4], id: "late")).isEmpty,
                      "the server keeps serving after the not-running result")

        // Nothing in the app-less world was created: no catalog, no control file.
        let created = (try? FileManager.default.contentsOfDirectory(at: empty, includingPropertiesForKeys: nil)) ?? [control]
        XCTAssertTrue(created.isEmpty, "the server creates nothing at startup: no catalog, no control file")
    }

    // MARK: - The structural belt

    /// The structural belt under CONNECTION-002's roster loop: no MCP tool source
    /// names the raw control client — `AppConnection` is the only seam between a
    /// tool and the app, so the legacy `ControlClient` wording has no path into a
    /// tool result. `AppConnection.swift` itself is the wrapper and names it; future
    /// tool groups land as MCP-prefixed files, which this scan picks up automatically.
    func testNoMCPToolSourceNamesTheControlClient() throws {
        let sources = try FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/KeysCore"), includingPropertiesForKeys: nil
        )
        var scanned = 0
        for url in sources where url.lastPathComponent.hasPrefix("MCP") {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("ControlClient"),
                           "\(url.lastPathComponent): route app calls through AppConnection, never the raw control client")
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 0, "the scan found the MCP sources")
    }
}
