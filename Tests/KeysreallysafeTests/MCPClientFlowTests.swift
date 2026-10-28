import Foundation
import XCTest
@testable import KeysCore

/// VAL-CROSS-001 — the mission's done criterion: a REAL `keys mcp` subprocess,
/// spawned from the built `.build/debug/keys` with `KEYS_CATALOG` pointing at a
/// temp catalog, completes the whole protocol end to end over its pipes against
/// a synthetic app — an in-process `APIHandler` behind a `LoopbackHTTPServer` on
/// an ephemeral port (never 12767), `control.json` written beside that same
/// catalog, a blocking presence gate standing in for Touch ID and a memory secret
/// store standing in for the Keychain.
///
/// The flow is the one a real agent client runs: initialize →
/// notifications/initialized → tools/list → list_keys → request_grant →
/// grant_status polls while the synthetic app's faked presence approval lands →
/// the approved handover (the only payload that ever carries a token) → the
/// delivered poll. Everything between the pipes is production code: the server
/// loop, the tool registry, the app connection, the app's routes, the pending
/// store, the formatter and the output guard. Nothing leaves the machine — the
/// request log proves every byte the subprocess sent landed on the loopback
/// control channel, and the recording analytics transport (consent explicitly
/// ON) stays empty, so this test is VAL-CROSS-003's subprocess-level
/// confirmation as well.
final class MCPClientFlowTests: XCTestCase {

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The subprocess answers each request promptly; this bound only catches a
    /// wedged server, it never races the flow.
    private static let frameBound: TimeInterval = 10
    /// The documented shutdown bound: stdin EOF exits within this, or the test
    /// failed it (LIFECYCLE-008).
    private static let shutdownBound: TimeInterval = 2

    private let fm = FileManager.default

    // MARK: - The synthetic app

    /// The in-process app plus everything the flow asserts against. The service
    /// is the only writer of the catalog the subprocess reads, so the two
    /// processes see one vault — exactly the real `keys mcp` / Keysrs.app split.
    private struct Rig {
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let gate: BlockingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        /// Every request that reached the loopback server — what the subprocess
        /// actually sent, as observed, never inferred.
        let requests: RequestLog
        let analytics: ProductAnalytics
        let transport: ProductAnalyticsTests.Transport
        /// The folder the subprocess runs in: its project folder.
        let agentCwd: URL
    }

    private func makeRig() throws -> Rig {
        let (db, dir) = try makeDB()
        let gate = BlockingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true),
            openRouter: OpenRouterHTTP(),
            relaySecrets: MemorySecretStore()
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        // The gateway target cached, so the grant's prompt is the grant itself.
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)

        // One active project-bound client token, so list_keys has a label to
        // carry — the project-identity seam crossing the pipe.
        let projectFolder = try makeFolder(dir, "e2e-proj")
        let project = try service.resolveProject(folder: projectFolder.path)
        // Pre-released: the client issuance takes its prompt instantly, leaving
        // the gate free for the grant's one real (parkable) prompt.
        gate.release()
        _ = try service.issueGatewayClient(name: "demo", label: "router", project: project.id)
        XCTAssertEqual(gate.recordedReasons.count, 1, "setup spent exactly one prompt")

        // Sharing consented ON and the transport recording: if any MCP path
        // enrolled or sent anything, it lands here and fails the test.
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, transport: transport)
        try analytics.setEnabled(true, consentVersion: ProductAnalytics.consentVersion)
        service.analytics = analytics
        analytics.start()

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let requests = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            requests.record(request)
            return handler.handle(request)
        }
        server.start()
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let agentCwd = try makeFolder(dir, "agent-cwd")
        addTeardownBlock {
            // No approval thread outlives the test, and the ephemeral port closes.
            gate.releaseAll(AppError.authCancelled)
            server.stop()
        }
        return Rig(
            service: service, db: db, dir: dir, gate: gate, handler: handler,
            server: server, requests: requests, analytics: analytics,
            transport: transport, agentCwd: agentCwd
        )
    }

    private func makeFolder(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The pipe client

    /// One real `keys mcp` subprocess over pipes. Reader threads drain stdout
    /// and stderr as they arrive — a whole frame is written in one write, so a
    /// ready read means complete lines — and `frame(_:)` pulls one line out under
    /// a deadline, so a silent server fails the test in bounded time instead of
    /// hanging it. @unchecked: the buffers sit behind the lock and nothing else
    /// is shared across the reader threads.
    private final class PipeClient: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [UInt8] = []
        private var stderrLog: [UInt8] = []
        private var stdoutLog: [UInt8] = []
        private var stdoutClosed = false
        private var stderrClosed = false
        let process = Process()

        private var stdinWrite: FileHandle?
        private var stdoutRead: FileHandle?
        private var stderrRead: FileHandle?

        /// The whole stdout stream as text — the transcript the framing
        /// assertions sweep at the end.
        var rawStdoutText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stdoutLog, as: UTF8.self)
        }

        var stderrText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stderrLog, as: UTF8.self)
        }

        init(binary: URL, cwd: URL, catalog: URL) {
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            stdinWrite = stdin.fileHandleForWriting
            stdoutRead = stdout.fileHandleForReading
            stderrRead = stderr.fileHandleForReading
            process.executableURL = binary
            process.arguments = ["mcp"]
            process.currentDirectoryURL = cwd
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            // Only the catalog is redirected: the control file follows it, so
            // the subprocess finds the synthetic app exactly as the real one
            // finds the installed Keysrs.app. Everything else is inherited,
            // and nothing in `keys mcp` reads a real home.
            var environment = ProcessInfo.processInfo.environment
            environment["KEYS_CATALOG"] = catalog.path
            process.environment = environment
        }

        func start() throws {
            try process.run()
            // Drain both pipes in the background; the reads block until bytes
            // or EOF arrive, which is exactly what these threads are for.
            Thread.detachNewThread { [stdoutRead, self] in
                guard let stdoutRead else { return }
                while true {
                    let chunk = stdoutRead.availableData
                    self.lock.lock()
                    if chunk.isEmpty { stdoutClosed = true } else {
                        stdoutLog.append(contentsOf: chunk)
                        pending.append(contentsOf: chunk)
                    }
                    self.lock.unlock()
                    if chunk.isEmpty { return }
                }
            }
            Thread.detachNewThread { [stderrRead, self] in
                guard let stderrRead else { return }
                while true {
                    let chunk = stderrRead.availableData
                    self.lock.lock()
                    if chunk.isEmpty { stderrClosed = true } else { stderrLog.append(contentsOf: chunk) }
                    self.lock.unlock()
                    if chunk.isEmpty { return }
                }
            }
        }

        /// Writes one JSON-RPC line to the subprocess's stdin.
        func send(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            guard let stdinWrite else { return }
            try stdinWrite.write(contentsOf: Data((message + "\n").utf8))
        }

        /// One complete stdout frame within the bound, or the test fails. The
        /// deadline is the failure signal — the server must never need it.
        func frame(
            timeout: TimeInterval = MCPClientFlowTests.frameBound,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> String {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                if let index = pending.firstIndex(of: 0x0A) {
                    let text = String(decoding: pending[0..<index], as: UTF8.self)
                    pending.removeFirst(index + 1)
                    lock.unlock()
                    return text
                }
                let closed = stdoutClosed
                lock.unlock()
                if closed {
                    throw AppError.usage("the mcp subprocess closed stdout before answering")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw AppError.usage("the mcp subprocess did not answer within \(timeout) s")
        }

        /// The reader threads need a moment after exit to flush the last bytes.
        func waitForDrain(timeout: TimeInterval = MCPClientFlowTests.shutdownBound) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let closed = stdoutClosed && stderrClosed
                lock.unlock()
                if closed { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        /// Closes stdin, waits for the documented clean exit, and returns
        /// whether the process managed it inside the bound. A wedged subprocess
        /// is killed rather than left behind, and the caller asserts on the
        /// outcome.
        @discardableResult
        func closeAndWaitForExit(within limit: TimeInterval = MCPClientFlowTests.shutdownBound) throws -> Bool {
            try stdinWrite?.close()
            stdinWrite = nil
            let exited = waitForExit(within: limit)
            if !exited {
                process.terminate()
                if !waitForExit(within: limit) {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                return false
            }
            process.waitUntilExit()
            waitForDrain()
            return true
        }

        /// The teardown path: never leave a spawned server behind a failed
        /// assertion, whatever state the flow died in.
        func halt() {
            if process.isRunning {
                try? stdinWrite?.close()
                if !waitForExit(within: MCPClientFlowTests.shutdownBound) {
                    process.terminate()
                    if !waitForExit(within: MCPClientFlowTests.shutdownBound) {
                        kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }
                }
            }
        }

        private func waitForExit(within limit: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            return !process.isRunning
        }
    }

    // MARK: - The flow helpers

    /// One tools/call whose result envelope is asserted and whose payload is
    /// the decoded JSON of the one text block.
    private func toolCall(
        _ client: PipeClient, id: String, name: String, arguments: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        try client.send(
            #"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(name)","arguments":\#(argumentsJSON)}}"#,
            file: file, line: line
        )
        let result = try MCPSession.assertResult(try client.frame(file: file, line: line), id: id,
                                                 "the tools/call answer", file: file, line: line)
        guard let content = result["content"] as? [[String: Any]], content.count == 1,
              content[0]["type"] as? String == "text",
              let text = content[0]["text"] as? String else {
            XCTFail("the \(name) result is not one text block", file: file, line: line)
            return [:]
        }
        XCTAssertFalse(result["isError"] as? Bool ?? false, "an unexpected \(name) error: \(text)",
                       file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    // MARK: - The done-criterion flow

    func testDoneCriterionFlow() throws {
        let binary = Self.repoRoot.appendingPathComponent(".build/debug/keys")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path),
                      "\(binary.path) must exist and be executable; run swift test to build it")
        let rig = try makeRig()

        let client = PipeClient(binary: binary, cwd: rig.agentCwd, catalog: rig.db.path)
        try client.start()
        addTeardownBlock { client.halt() }

        // initialize: the handshake, with the frozen shape.
        try client.send(MCPSession.initialize())
        var responses = 1
        let initialize = try MCPSession.assertResult(try client.frame(), id: "init", "the handshake")
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18", "the client's version is echoed")
        let capabilities = initialize["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?.count, 1, "capabilities declares tools only")
        XCTAssertEqual((capabilities?["tools"] as? [String: Any])?.count, 0)
        let serverInfo = initialize["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "keysrs")
        XCTAssertEqual(serverInfo?["version"] as? String, ProductAnalyticsConfiguration.appVersion,
                       "serverInfo.version is the single version constant")
        XCTAssertTrue((initialize["instructions"] as? String)?.contains("Keysrs is the local API-key vault") ?? false,
                      "the instructions string is the frozen one")

        // notifications/initialized: a notification, answered by nothing — the
        // next frame proves it, and the frame count at the end re-proves it.
        try client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        // tools/list: the whole mission roster, in the registry's order.
        try client.send(#"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#)
        responses += 1
        let roster = try MCPSession.toolNames(in: try client.frame(), id: "list")
        XCTAssertEqual(roster, ["version", "list_keys", "gateway_info", "open_app", "check_update",
                                "request_grant", "grant_status", "scan_project", "check_exposure", "import_and_wrap"],
                       "the deterministic mission roster")

        // tools/call list_keys: the catalog the subprocess opened itself, no app
        // needed — the label is the only project fact that crosses the pipe.
        let listed = try toolCall(client, id: "lk", name: "list_keys", arguments: [:])
        responses += 1
        let keys = listed["keys"] as? [[String: Any]] ?? []
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0]["name"] as? String, "demo")
        XCTAssertEqual(keys[0]["provider"] as? String, "openai")
        XCTAssertEqual(keys[0]["kind"] as? String, "runtime")
        XCTAssertEqual(keys[0]["projects"] as? [String], ["e2e-proj"],
                       "the active project-bound token's label, by label only")

        // tools/call request_grant: pending immediately, tokenless, while the
        // app's one Touch ID prompt stands in behind the blocking gate.
        let pending = try toolCall(client, id: "rg", name: "request_grant", arguments: [
            "key": "demo", "task": "run the e2e flow", "methods": ["GET"],
            "paths": ["/v1/messages"], "minutes": 5,
        ])
        responses += 1
        XCTAssertEqual(pending["status"] as? String, "pending")
        let id = pending["id"] as! String
        XCTAssertEqual(id.count, 8, "the id is the 8-hex convention")
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(Set(pending.keys), ["status", "id"], "the pending payload carries nothing else")
        XCTAssertEqual(rig.gate.recordedReasons.count, 2,
                       "exactly one prompt for the ask, after the setup's client issuance")

        // Polls while the prompt is provably still up: pending, tokenless.
        for (index, requestID) in ["p1", "p2"].enumerated() {
            let poll = try toolCall(client, id: requestID, name: "grant_status", arguments: ["id": id])
            responses += 1
            XCTAssertEqual(poll["status"] as? String, "pending", "poll \(index) while the prompt is up")
            XCTAssertEqual(poll["id"] as? String, id)
            XCTAssertEqual(Set(poll.keys), ["status", "id"], "a pending poll stays tokenless")
        }

        // The faked presence approval: the user touched the sensor.
        rig.gate.release()

        // Polls until the handover lands. The approval settles on the app's own
        // thread, so a bounded retry — never a sleep-past-the-bound.
        var approved: [String: Any] = [:]
        var approvedPolls = 0
        for attempt in 0..<200 {
            approvedPolls += 1
            responses += 1
            let poll = try toolCall(client, id: "a\(attempt)", name: "grant_status", arguments: ["id": id])
            let status = poll["status"] as? String
            if status == "pending" { continue }
            if status == "approved" { approved = poll; break }
            XCTFail("the released prompt did not approve: \(poll)")
            break
        }
        let token = approved["token"] as? String
        XCTAssertEqual(approved["status"] as? String, "approved")
        XCTAssertNotNil(token, "the approved payload carries the token: \(approved)")
        XCTAssertTrue(token?.hasPrefix("ksf_") ?? false, "the gateway's own token shape")
        XCTAssertEqual(approved["base_url"] as? String, "http://127.0.0.1:12767/demo/v1",
                       "the handover carries the base URL")
        XCTAssertEqual(approved["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
        XCTAssertEqual(approved["auth_header"] as? String, "Authorization")

        // The next poll reports the delivery, never the token again.
        let later = try toolCall(client, id: "d1", name: "grant_status", arguments: ["id": id])
        responses += 1
        XCTAssertEqual(later["status"] as? String, "approved")
        XCTAssertEqual(later["delivered"] as? Bool, true)
        XCTAssertEqual(later["id"] as? String, id)
        XCTAssertEqual(Set(later.keys), ["status", "id", "delivered"], "the token never crosses twice")

        // The prompt count is still exactly the one ask: polls and the handover
        // never prompt, and the one reason names the key, the resolved host and
        // the project LABEL — never a path, a token or a key value.
        XCTAssertEqual(rig.gate.recordedReasons.count, 2)
        let reason = rig.gate.recordedReasons[1]
        XCTAssertTrue(reason.contains("the key demo"), "the reason names the key: \(reason)")
        XCTAssertTrue(reason.contains("api.openai.com"), "the reason names the resolved host: \(reason)")
        XCTAssertTrue(reason.contains("project agent-cwd"), "the reason names the project label: \(reason)")
        XCTAssertFalse(reason.contains(rig.dir.path), "no absolute project path: \(reason)")

        // The app side of the same flow: the one grant, audited as the MCP caller.
        let grants = rig.service.listGrants(includeInactive: true)
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants[0].key, "demo")
        let grantEvents = try rig.db.keyEvents(name: "demo", limit: 50).filter { $0.action == "grant" }
        XCTAssertEqual(grantEvents.count, 1, "no phantom events")
        XCTAssertEqual(grantEvents[0].caller, "mcp")

        // Nothing leaves the machine: every request the subprocess sent landed
        // on this loopback server, on the MCP routes, and nothing else was sent.
        let requests = rig.requests.all
        XCTAssertEqual(requests.count, 1 + 2 + approvedPolls + 1,
                       "one create plus every poll — list_keys never called the app")
        for request in requests {
            XCTAssertTrue(request.path.hasPrefix("/api/mcp/grants"),
                          "the control channel serves the MCP routes and nothing else: \(request.path)")
        }
        // Analytics stays silent even with sharing consented ON: an MCP session
        // must never silently enroll the user in share-to-compare.
        XCTAssertEqual(rig.transport.calls.count, 0, "no analytics report was attempted")
        XCTAssertEqual(rig.transport.fetches.count, 0, "no benchmark fetch was attempted")

        // The delivered token never touched disk — the store keeps hashes only.
        assertNoSentinel(token!, in: rig.dir)

        // Closing stdin is the documented shutdown: exit 0, within the bound.
        let exited = try client.closeAndWaitForExit()
        XCTAssertTrue(exited, "stdin EOF must exit within \(Self.shutdownBound) s")
        XCTAssertEqual(client.process.terminationReason, .exit, "the server was never killed")
        XCTAssertEqual(client.process.terminationStatus, 0, "stdin EOF exits 0")

        // Stdout carries only frames: every non-empty line of the whole session
        // is one complete compact response, re-serializing byte-identically,
        // and there is exactly one response per request and zero for the
        // notification. Diagnostics, had there been any, stayed on stderr —
        // prose there, never frames.
        let transcript = client.rawStdoutText
        let chunks = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(chunks.last, "", "the stream ends on the frame terminator")
        let frames = chunks.dropLast()
        XCTAssertEqual(frames.count, responses,
                       "exactly one response per request-bearing line, none for the notification")
        for frame in frames {
            let object = try MCPSession.object(frame)
            XCTAssertNil(object["method"], "only responses, never requests or notifications")
            XCTAssertNotNil(object["id"])
            XCTAssertEqual(Data(frame.utf8), try JSONValue.data(object),
                           "frames must be compact sorted-key JSON: \(frame)")
        }
        XCTAssertFalse(transcript.contains(fixtureSecret), "the vault secret never crosses the pipe")
        XCTAssertFalse(transcript.contains(rig.dir.path), "no project path crosses the pipe")
        XCTAssertEqual(transcript.components(separatedBy: token!).count - 1, 1,
                       "the token crossed exactly once, on the one approved handover")
        for line in client.stderrText.split(separator: "\n", omittingEmptySubsequences: true) {
            XCTAssertFalse(line.contains("\"jsonrpc\""), "stderr is prose only, never frames: \(line)")
        }
    }
}
