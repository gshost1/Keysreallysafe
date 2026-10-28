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

        init(binary: URL, cwd: URL, catalog: URL, extraEnvironment: [String: String] = [:]) {
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
            // and nothing in `keys mcp` reads a real home. extraEnvironment is
            // for determinism pins (the onboarding flow's git config isolation).
            var environment = ProcessInfo.processInfo.environment
            environment["KEYS_CATALOG"] = catalog.path
            for (key, value) in extraEnvironment { environment[key] = value }
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
                                "request_grant", "grant_status", "scan_project", "check_exposure", "import_and_wrap",
                                "test_keys"],
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

    // MARK: - The onboarding rig

    /// The synthetic app for the onboarding flow: the same in-process app shape
    /// as `makeRig` (temp catalog, temp control file, blocking presence, memory
    /// secrets, consent-ON recording analytics) plus a gateway listener and a
    /// stub upstream, so the minted project token's acceptance is proven by a
    /// real loopback HTTP round trip — never the network. The two vault keys the
    /// flow "finds" are seeded with the env file's own fake values and their
    /// gateway hosts point at the stub: the scan's in_vault answer exercises the
    /// hash comparison over the pipe, the import's dedupe reuses the keys, and
    /// the one real gateway request stays offline.
    private struct OnboardingRig {
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let gate: BlockingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let requests: RequestLog
        let transport: ProductAnalyticsTests.Transport
        let stub: LoopbackHTTPServer
        let stubRequests: RequestLog
        let gateway: GatewayListener
        let project: URL
        let env: URL
    }

    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var openAIValue: String { "sk-" + fakeBody + "02" }
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }

    private func makeOnboardingRig() throws -> OnboardingRig {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
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

        // The stub upstream stands in for api.openai.com / api.anthropic.com:
        // both seeded keys' gateway hosts point at it, so the gateway's one real
        // request never leaves loopback.
        let stubRequests = RequestLog()
        let stub = try LoopbackHTTPServer(port: 0) { request in
            stubRequests.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        stub.start()
        let stubHost = "127.0.0.1:\(stub.boundPort)"
        try service.add(name: "openai", provider: "openai", kind: "runtime", notes: "", secret: openAIValue)
        try service.add(name: "anthropic", provider: "anthropic", kind: "runtime", notes: "", secret: anthropicValue)
        _ = try service.setGateway(name: "openai", enabled: true, host: stubHost, presenceChecked: true)
        _ = try service.setGateway(name: "anthropic", enabled: true, host: stubHost, presenceChecked: true)
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()

        // Sharing consented ON and the transport recording: any MCP path that
        // enrolled or sent anything lands here and fails the test.
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
        try assertNotProductionPath(control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        // The project the subprocess stands in: a real git repository that has
        // committed the env file, so check_exposure answers real facts.
        let project = dir.appendingPathComponent("e2eproj", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let env = project.appendingPathComponent(".env")
        try Data((originalEnv + "\n").utf8).write(to: env)
        try Data("FROM scratch\n".utf8).write(to: project.appendingPathComponent("Dockerfile"))
        try fixtureGit(["init", "-q"], in: project)
        try fixtureGit(["config", "user.email", "fixture@invalid"], in: project)
        try fixtureGit(["config", "user.name", "fixture"], in: project)
        try fixtureGit(["config", "commit.gpgsign", "false"], in: project)
        try fixtureGit(["config", "core.hooksPath", ""], in: project)
        // The exposure facts must not depend on the machine's global excludes.
        try fixtureGit(["config", "core.excludesFile", "/dev/null"], in: project)
        try fixtureGit(["add", ".env"], in: project)
        try fixtureGit(["commit", "-q", "-m", "fixture commits the env file"], in: project)

        addTeardownBlock {
            // No approval thread outlives the test, and the ephemeral ports close.
            gate.releaseAll(AppError.authCancelled)
            gateway.stop()
            stub.stop()
            server.stop()
        }
        return OnboardingRig(
            service: service, db: db, dir: dir, gate: gate, handler: handler,
            server: server, requests: requests, transport: transport,
            stub: stub, stubRequests: stubRequests, gateway: gateway,
            project: project, env: env
        )
    }

    /// The pre-wrap file: a comment, an exported-and-quoted line with an inline
    /// comment, a bare line and a pre-existing BASE_URL the wrap replaces — the
    /// shapes byte-for-byte restoration has to survive.
    private var originalEnv: String {
        """
        # top comment
        export OPENAI_API_KEY="\(openAIValue)" # inline
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_BASE_URL=https://api.example.internal/v1
        """
    }

    /// One fixture git command, expected to succeed, with the global and system
    /// config pinned out so the facts depend on the fixture repository alone.
    private func fixtureGit(
        _ arguments: [String], in root: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let binary = try XCTUnwrap(
            MCPOnboardingTools.gitOnPATH(), "git must be on PATH to build a fixture repo",
            file: file, line: line
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0, "fixture git \(arguments.first ?? "") failed",
            file: file, line: line
        )
    }

    /// The decoded payload of a result envelope's one text block.
    private func payload(
        _ result: [String: Any], name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
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

    /// One POST through the real gateway listener with a client token.
    private func postToGateway(_ url: URL, token: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gpt-4.1"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// The stub's headers are lowercased by the frame parser; look up
    /// case-insensitively so the assertion does not depend on that.
    private func header(_ request: HTTPRequest?, _ name: String) -> String? {
        request?.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    /// Fails if any file under `dir` holds `needle`, except the listed URLs: the
    /// env file and its wrap-time backup legitimately hold values (and, while
    /// wrapped, the token); everything else — the catalog and its WAL included —
    /// holds hashes at most.
    private func assertSentinelOnlyIn(
        _ needle: String, dir: URL, allowed: [URL],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let keep = Set(allowed.map { $0.resolvingSymlinksInPath().path })
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard !keep.contains(url.resolvingSymlinksInPath().path),
                  let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: Data(needle.utf8)),
                         "\(url.lastPathComponent) holds a sentinel", file: file, line: line)
        }
    }

    // MARK: - The onboarding done-criterion flow (VAL-CROSS-001, VAL-CROSS-002)

    /// The mission's done criterion over real pipes: a REAL `keys mcp` subprocess
    /// standing in the project folder runs initialize → tools/list → scan_project
    /// → check_exposure → import_and_wrap (one scripted approval, observed before
    /// it is released) against the synthetic app; the rewritten env file's one
    /// project token then authorizes a real gateway request for a member key; the
    /// app-side unwrap restores the file byte-for-byte and revokes the token,
    /// which the gateway then refuses. The sweeps close the loop: the transcript
    /// holds no value, no absolute project path and no token; the consent-ON
    /// analytics transport stays empty; and on disk the token and the values
    /// live only in the env file, its backup and the catalog's token hash.
    func testOnboardingDoneCriterionFlow() async throws {
        let binary = Self.repoRoot.appendingPathComponent(".build/debug/keys")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path),
                      "\(binary.path) must exist and be executable; run swift test to build it")
        let rig = try makeOnboardingRig()
        XCTAssertEqual(rig.gate.recordedReasons.count, 0, "setup spent no prompts")
        let originalData = try Data(contentsOf: rig.env)

        let client = PipeClient(
            binary: binary, cwd: rig.project, catalog: rig.db.path,
            extraEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        )
        try client.start()
        addTeardownBlock { client.halt() }

        // initialize: the handshake, with the frozen shape.
        try client.send(MCPSession.initialize())
        var responses = 1
        let initialize = try MCPSession.assertResult(try client.frame(), id: "init", "the handshake")
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18", "the client's version is echoed")
        XCTAssertTrue((initialize["instructions"] as? String)?.contains("Keysrs is the local API-key vault") ?? false,
                      "the instructions string is the frozen one")

        // notifications/initialized: answered by nothing; the frame count at the
        // end re-proves it.
        try client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        // tools/list: the whole mission roster, in the registry's order.
        try client.send(#"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#)
        responses += 1
        let roster = try MCPSession.toolNames(in: try client.frame(), id: "list")
        XCTAssertEqual(roster, ["version", "list_keys", "gateway_info", "open_app", "check_update",
                                "request_grant", "grant_status", "scan_project", "check_exposure", "import_and_wrap",
                                "test_keys"],
                       "the deterministic mission roster")

        // scan_project: no folder argument — the default is the subprocess's own
        // working directory, the project folder.
        let scan = try toolCall(client, id: "scan", name: "scan_project", arguments: [:])
        responses += 1
        XCTAssertEqual(scan["env_files"] as? [String], [".env"])
        XCTAssertEqual(scan["docker_files"] as? [String], ["Dockerfile"])
        XCTAssertEqual(scan["vault_check"] as? String, "app",
                       "the in-vault comparison reached the synthetic app by hash")
        let scanned = try XCTUnwrap(scan["variables"] as? [[String: Any]])
        XCTAssertEqual(scanned.count, 2)
        let expected: [(String, String, String)] = [
            ("OPENAI_API_KEY", "openai", String(openAIValue.suffix(4))),
            ("ANTHROPIC_API_KEY", "anthropic", String(anthropicValue.suffix(4))),
        ]
        for (index, (name, provider, last4)) in expected.enumerated() {
            let variable = scanned[index]
            XCTAssertEqual(variable["name"] as? String, name)
            XCTAssertEqual(variable["file"] as? String, ".env", "relative, never absolute")
            XCTAssertEqual(variable["provider"] as? String, provider)
            XCTAssertEqual(variable["category"] as? String, "provider_key")
            XCTAssertEqual(variable["last4"] as? String, last4, "at most the last 4 characters")
            XCTAssertEqual(variable["in_vault"] as? Bool, true, "the seeded value matched by hash")
            XCTAssertEqual(variable["proxyable"] as? Bool, true)
            XCTAssertEqual(variable["wrapped"] as? Bool, false)
        }

        // check_exposure: git facts, never contents — the committed .env is
        // tracked and in history, so it carries the rotation recommendation.
        let exposure = try toolCall(client, id: "exposure", name: "check_exposure", arguments: [:])
        responses += 1
        XCTAssertEqual(exposure["git"] as? String, "available")
        let exposed = try XCTUnwrap(exposure["files"] as? [[String: Any]])
        XCTAssertEqual(exposed.count, 1)
        XCTAssertEqual(exposed[0]["file"] as? String, ".env")
        XCTAssertEqual(exposed[0]["gitignored"] as? Bool, false)
        XCTAssertEqual(exposed[0]["tracked"] as? Bool, true)
        XCTAssertEqual(exposed[0]["in_history"] as? Bool, true)
        XCTAssertEqual(exposed[0]["recommendation"] as? String, "rotate the keys that were in this file")

        // import_and_wrap: the scripted approval observes the one prompt BEFORE
        // releasing it — exactly one prompt, naming the keys and the project
        // label, never a path, a value or a token.
        let importArguments = String(decoding: try JSONValue.data(["folder": rig.project.path]), as: UTF8.self)
        try client.send(
            #"{"jsonrpc":"2.0","id":"import","method":"tools/call","params":{"name":"import_and_wrap","arguments":\#(importArguments)}}"#
        )
        responses += 1
        XCTAssertTrue(rig.gate.waitPrompts(1, timeout: Self.frameBound),
                      "the import's one presence prompt went up")
        XCTAssertEqual(rig.gate.recordedReasons.count, 1, "exactly one recorded prompt for the whole import")
        let ask = rig.gate.recordedReasons[0]
        XCTAssertEqual(ask, "import and wrap 2 keys for project e2eproj: openai, anthropic",
                       "the prompt names the keys and the project label")
        XCTAssertFalse(ask.contains(rig.dir.path), "no absolute path in the prompt: \(ask)")
        XCTAssertFalse(ask.contains(fakeBody), "no value in the prompt: \(ask)")
        XCTAssertFalse(ask.contains("ksfc_"), "no token in the prompt: \(ask)")
        rig.gate.release()
        let importEnvelope = try MCPSession.assertResult(try client.frame(), id: "import", "the import answer")
        let imported = try payload(importEnvelope, name: "import_and_wrap")
        XCTAssertEqual(imported["project_label"] as? String, "e2eproj")
        XCTAssertNotNil(imported["expires_at"] as? String, "the one token's 30-day expiry")
        XCTAssertEqual(imported["docker_access"] as? Bool, false)
        XCTAssertEqual(imported["base_url_host"] as? String, "127.0.0.1")
        let outcomes = try XCTUnwrap(imported["variables"] as? [[String: Any]])
        XCTAssertEqual(outcomes.map { $0["variable"] as? String }, ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertEqual(outcomes.map { $0["status"] as? String }, ["wrapped", "wrapped"])
        XCTAssertEqual(outcomes.map { $0["new"] as? Bool }, [false, false],
                       "the dedupe reused the seeded keys, no duplicates")
        let keyA = try XCTUnwrap(outcomes[0]["key"] as? String)
        let keyB = try XCTUnwrap(outcomes[1]["key"] as? String)
        XCTAssertEqual(keyA, "openai")
        XCTAssertEqual(keyB, "anthropic")

        // The env file was rewritten by the app: one ksfc token on both lines,
        // the per-key gateway base URLs, no raw value, the 0600 backup beside it.
        let wrappedText = try String(contentsOf: rig.env, encoding: .utf8)
        XCTAssertFalse(wrappedText.contains(fakeBody), "the raw values are gone from the file")
        let wrappedFile = EnvFile.parse(wrappedText)
        let token = try XCTUnwrap(wrappedFile.value(of: "OPENAI_API_KEY"))
        XCTAssertTrue(token.hasPrefix("ksfc_"), "the wrapped line holds a client token")
        XCTAssertEqual(wrappedFile.value(of: "ANTHROPIC_API_KEY"), token,
                       "every wrapped line holds the ONE project token")
        XCTAssertEqual(wrappedFile.value(of: "OPENAI_BASE_URL"), "http://127.0.0.1:12767/\(keyA)")
        XCTAssertEqual(wrappedFile.value(of: "ANTHROPIC_BASE_URL"), "http://127.0.0.1:12767/\(keyB)")
        XCTAssertTrue(wrappedText.contains("export OPENAI_API_KEY=\"\(token)\""),
                      "export, quotes and the comment survive the rewrite")
        let backupNames = try fm.contentsOfDirectory(atPath: rig.project.path)
            .filter { $0.hasPrefix(".env.keysrs-backup-") }
        XCTAssertEqual(backupNames.count, 1, "the wrap wrote exactly one backup")
        let backup = rig.project.appendingPathComponent(backupNames[0])
        XCTAssertEqual(try Data(contentsOf: backup), originalData, "the backup holds the pre-wrap bytes")
        let backupMode = try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        XCTAssertEqual(backupMode, 0o600, "the backup is owner-only — it still holds the values")
        XCTAssertEqual(try rig.db.listWrappedFiles().count, 1, "the import recorded the wrapped file")

        // The gateway accepts the project token for a member key: a real
        // loopback request through the gateway listener reaches the stub
        // upstream carrying that member's own secret.
        let memberURL = URL(string: "http://127.0.0.1:\(rig.gateway.boundPort)/\(keyA)/v1/chat/completions")!
        let accepted = try await postToGateway(memberURL, token: token)
        XCTAssertEqual(accepted, 200, "the gateway accepts the project token for a member key")
        XCTAssertEqual(rig.stubRequests.count, 1)
        XCTAssertEqual(header(rig.stubRequests.last, "authorization"), "Bearer " + openAIValue,
                       "the member key's own secret went upstream")
        guard case .allowed = rig.service.authorizeGatewayClient(
            name: keyB, headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
        ) else {
            return XCTFail("the one project token serves the other member too")
        }

        // While wrapped, the token lives only in the env file and the values
        // only in the backup: the catalog keeps the token's hash, never it.
        assertSentinelOnlyIn(token, dir: rig.dir, allowed: [rig.env])
        assertSentinelOnlyIn(fakeBody, dir: rig.dir, allowed: [backup])

        // The app-side unwrap: one scripted approval, the file restored
        // byte-for-byte from the vault, the token revoked.
        rig.gate.release()
        let unwrapped = try rig.service.unwrap(file: rig.env.path, folder: nil)
        XCTAssertEqual(rig.gate.recordedReasons.count, 2, "the unwrap cost exactly one more prompt")
        let restoreAsk = rig.gate.recordedReasons[1]
        XCTAssertTrue(restoreAsk.contains("unwrap"), "the prompt says what the call does: \(restoreAsk)")
        XCTAssertTrue(restoreAsk.contains(".env"), "the prompt names the file: \(restoreAsk)")
        XCTAssertFalse(restoreAsk.contains(fakeBody), "no value in the prompt: \(restoreAsk)")
        XCTAssertFalse(restoreAsk.contains("ksfc_"), "no token in the prompt: \(restoreAsk)")
        XCTAssertEqual(try Data(contentsOf: rig.env), originalData,
                       "the unwrap restored the file byte-for-byte")
        let unwrappedFiles = try XCTUnwrap(unwrapped["files"] as? [[String: Any]])
        XCTAssertEqual(unwrappedFiles.count, 1)
        XCTAssertEqual(unwrappedFiles[0]["restored"] as? [String], ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertEqual((unwrappedFiles[0]["failed"] as? [Any])?.count, 0)
        XCTAssertEqual(try rig.db.listWrappedFiles().count, 0, "the record cleared with the unwrap")

        // The token is dead: the gateway refuses it and the authorization
        // decision says why.
        let refused = try await postToGateway(memberURL, token: token)
        XCTAssertEqual(refused, 401, "the revoked project token is refused")
        XCTAssertEqual(rig.stubRequests.count, 1, "a denied request never reaches the upstream")
        XCTAssertEqual(
            rig.service.authorizeGatewayClient(
                name: keyA, headers: ["authorization": "Bearer " + token], method: "POST", rest: "v1/x"
            ),
            .denied("revoked")
        )

        // After the unwrap the token is nowhere on disk — the file holds the
        // restored values again and the catalog kept only the hash.
        assertSentinelOnlyIn(token, dir: rig.dir, allowed: [])
        assertSentinelOnlyIn(fakeBody, dir: rig.dir, allowed: [rig.env, backup])

        // Nothing leaves the machine: the subprocess's whole control-channel
        // traffic is the one hash-only vault lookup and the one import call,
        // both origin-token gated, and no value or token ever crossed it.
        let requests = rig.requests.all
        XCTAssertEqual(requests.map { $0.path }, ["/api/mcp/vault_lookup", "/api/mcp/import_and_wrap"],
                       "the whole app traffic of the flow")
        for request in requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["x-ksf-token"], rig.handler.originToken, "origin-token gated")
            let body = String(decoding: request.body, as: UTF8.self)
            XCTAssertFalse(body.contains(fakeBody), "no value crossed the wire")
            XCTAssertFalse(body.contains(token), "no token crossed the wire")
        }
        // Analytics stays silent even with sharing consented ON.
        XCTAssertEqual(rig.transport.calls.count, 0, "no analytics report was attempted")
        XCTAssertEqual(rig.transport.fetches.count, 0, "no benchmark fetch was attempted")

        // Closing stdin is the documented shutdown: exit 0, within the bound.
        let exited = try client.closeAndWaitForExit()
        XCTAssertTrue(exited, "stdin EOF must exit within \(Self.shutdownBound) s")
        XCTAssertEqual(client.process.terminationReason, .exit, "the server was never killed")
        XCTAssertEqual(client.process.terminationStatus, 0, "stdin EOF exits 0")

        // Stdout carries only frames: exactly one compact sorted-key response per
        // request and zero for the notification — and the transcript holds no
        // key value, no absolute project path and no token, in either spelling
        // of the temp tree.
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
        XCTAssertFalse(transcript.contains(fakeBody), "no key value ever crosses the pipe")
        XCTAssertFalse(transcript.contains(token), "the token never appears in a tool result")
        XCTAssertFalse(transcript.contains("ksfc_"), "no token shape crosses the pipe at all")
        XCTAssertFalse(transcript.contains(rig.dir.path), "no project path crosses the pipe")
        XCTAssertFalse(transcript.contains(rig.dir.resolvingSymlinksInPath().path),
                       "no project path crosses the pipe in the resolved spelling either")
        for line in client.stderrText.split(separator: "\n", omittingEmptySubsequences: true) {
            XCTAssertFalse(line.contains("\"jsonrpc\""), "stderr is prose only, never frames: \(line)")
        }
    }
}
