import Foundation
import XCTest
@testable import KeysCore

/// VAL-TKEY-001..006: the test_keys flow — the app-side service behind
/// POST /api/mcp/test_keys, the origin-token-gated route, and the MCP tool that
/// relays it. The confirm gate is the whole design: an unconfirmed call sends
/// nothing and prompts no one, and a confirmed call never rides a remembered yes —
/// exactly one prompt per call, every call. Every rig is a temp catalog beside a
/// temp control file with a fake presence gate, a fake secret store and an
/// injected provider-check fetcher (owner directive 2026-10-28: the fail-closed
/// guard aborts the test before a single byte moves if a path under test resolves
/// to the real Keysrs location), every "secret" is an obviously fake body built at
/// runtime, and "nothing was sent" is a counted fact — the fetcher records every
/// request it would have made.
final class TestKeysToolTests: XCTestCase {
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var openaiSecret: String { "sk-" + fakeBody + "01" }
    private var groqSecret: String { "gsk_" + fakeBody + "02" }
    private var voiceSecret: String { fakeBody + "03" }

    /// The injected `ProviderCheckFetching` seam: every request is recorded, so a
    /// test proves "nothing was sent" by count and proves each probe's shape by
    /// inspection — URL, method, and which secret rode which request.
    private final class FakeChecker: ProviderCheckFetching, @unchecked Sendable {
        var status = 200
        var body = Data(#"{"data":[{"id":"gpt-4.1"},{"id":"o3"}]}"#.utf8)
        var headers: [String: String] = [:]
        var error: Error?
        private(set) var requests: [URLRequest] = []
        func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let error { throw error }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    // MARK: - Rigs

    /// The in-process app: a real APIHandler over a temp catalog behind a recording
    /// loopback server on an ephemeral port, `control.json` beside that same
    /// catalog, fake presence, a fake secret store and an injected checker — the
    /// shape the test_keys tool reaches, guarded against production paths like
    /// every control-channel rig (owner directive 2026-10-28).
    private struct Site {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let checker: FakeChecker
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let log: RequestLog
        let control: URL
        let dir: URL
    }

    private func makeSite(checker: FakeChecker = FakeChecker()) throws -> Site {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db)
        service.checker = checker
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        addTeardownBlock { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try assertNotProductionPath(control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(
            service: service, db: db, gate: gate, checker: checker, handler: handler,
            server: server, log: log, control: control, dir: dir
        )
    }

    /// A control URL no live site answers: a fresh temp tree with no control.json
    /// in it — guarded like every other control-channel path.
    private func deadControl() throws -> URL {
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try assertNotProductionPath(control)
        return control
    }

    /// The onboarding group wired over injected seams, never the machine's real
    /// catalog or installed app.
    private func roster(control: URL) -> MCPToolRegistry {
        MCPToolRegistry(groups: [MCPOnboardingTools(control: control, launch: .neverLaunching)])
    }

    /// One test_keys tools/call through real server frames — the surface the model
    /// sees, output guard included.
    private func callTool(
        _ registry: MCPToolRegistry,
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"test_keys","arguments":\#(argumentsJSON)}}"#,
        ], registry: registry, file: file, line: line)
        XCTAssertEqual(frames.last, "", file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    /// The rows a call answered with, as dictionaries, in answer order.
    private func rows(_ payload: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(payload["results"] as? [[String: Any]], "the payload carries per-key results")
    }

    /// One POST to the route through the dashboard rig, with the origin token.
    @discardableResult
    private func post(
        _ site: Site, body: [String: Any], token: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> HTTPResponse {
        let response = handle(site.handler, method: "POST", path: "/api/mcp/test_keys",
                               body: try JSONValue.data(body), token: token)
        if response.status == 500 {
            XCTFail("the route threw an unexpected error: \(String(decoding: response.body, as: UTF8.self))",
                    file: file, line: line)
        }
        return response
    }

    // MARK: - VAL-TKEY-001 (no confirm: no network, no prompt)

    /// Confirm absent and confirm false are the same call: zero fetcher requests,
    /// zero presence prompts, and a per-key row that states nothing was sent and
    /// that the user must be asked before the caller confirms.
    func testUnconfirmedCallSendsNothingPromptsNoOneAndSaysSo() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)
        try site.service.add(name: "router", provider: "groq", kind: "runtime", notes: "", secret: groqSecret)

        for (label, body) in [
            ("confirm absent", ["keys": ["demo", "router"]] as [String: Any]),
            ("confirm false", ["keys": ["demo", "router"], "confirm": false] as [String: Any]),
        ] {
            let response = try post(site, body: body)
            XCTAssertEqual(response.status, 200, label)
            let payload = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertEqual(Set(payload.keys), ["results"], "the payload carries the per-key rows and nothing else: \(label)")
            let rows = try rows(payload)
            XCTAssertEqual(rows.map { $0["key"] as? String }, ["demo", "router"], "one row per key, in request order: \(label)")
            for row in rows {
                XCTAssertEqual(row["outcome"] as? String, "not_confirmed", label)
                XCTAssertEqual(row["confirmed"] as? Bool, false, label)
                XCTAssertEqual(row["ok"] as? Bool, false, label)
                let summary = row["summary"] as? String ?? ""
                XCTAssertTrue(summary.contains("nothing was sent"), "the row says nothing was sent: \(label)")
                XCTAssertTrue(summary.contains("ask the user"), "the row says the user must be asked: \(label)")
            }
            XCTAssertEqual(site.checker.requests.count, 0, "no provider request: \(label)")
            XCTAssertEqual(site.gate.reasons.count, 0, "no presence prompt: \(label)")
        }

        // No check was recorded or audited: nothing happened, and the catalog says so.
        XCTAssertNil(try site.service.lastCheck(name: "demo"))
        XCTAssertNil(try site.service.lastCheck(name: "router"))
        let checks = try site.db.keyEvents(name: "demo", limit: 10).filter { $0.action == "check" }
        XCTAssertTrue(checks.isEmpty, "an unconfirmed call is not audited as a check")
    }

    // MARK: - VAL-TKEY-002 (confirm: one prompt per call, read-only probes)

    /// A confirmed call pays exactly one prompt naming the keys it will probe, then
    /// sends one read-only GET per probeable key — each with its own secret — and
    /// answers with the keys-test rows marked confirmed. The second call prompts
    /// again: nothing is remembered.
    func testConfirmedCallPromptsOncePerCallAndProbesEveryProbeableKey() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)
        try site.service.add(name: "router", provider: "groq", kind: "runtime", notes: "", secret: groqSecret)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let payload = try site.service.testKeys(keys: ["demo", "router"], confirm: true, caller: "mcp", now: now)

        XCTAssertEqual(site.gate.reasons, ["test 2 keys read-only: demo, router"],
                       "exactly one prompt, naming the keys it will probe")
        XCTAssertEqual(site.checker.requests.count, 2, "one read-only GET per probeable key")
        let requests = site.checker.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET"], "read-only probes only")
        XCTAssertEqual(requests.map { $0.url?.absoluteString },
                       ["https://api.openai.com/v1/models", "https://api.groq.com/openai/v1/models"])
        for (request, secret) in zip(requests, [openaiSecret, groqSecret]) {
            let header = request.allHTTPHeaderFields?.values.joined(separator: " ") ?? ""
            XCTAssertTrue(header.contains(secret), "each key's own secret rode its own probe")
        }

        let rows = try rows(payload)
        XCTAssertEqual(rows.map { $0["key"] as? String }, ["demo", "router"])
        for row in rows {
            XCTAssertEqual(row["confirmed"] as? Bool, true)
            XCTAssertEqual(row["ok"] as? Bool, true)
            XCTAssertEqual(row["outcome"] as? String, "ok")
            XCTAssertEqual(row["checked_at"] as? String, UTC.iso(now), "the app-side now stamps the row")
            XCTAssertEqual(row["models"] as? [String], ["gpt-4.1", "o3"])
        }

        // The second confirmed call prompts again: no approval is ever remembered.
        _ = try site.service.testKeys(keys: ["demo", "router"], confirm: true, caller: "mcp", now: now)
        XCTAssertEqual(site.gate.reasons.count, 2, "the second call prompts again")
        XCTAssertEqual(site.checker.requests.count, 4, "the second call probes again")
    }

    /// The one place the flow could cheat — the gateway's unlocked in-memory secret,
    /// which `keys test` reuses without a prompt — is deliberately not consulted:
    /// with the key's secret unlocked in the gateway cache, a confirmed call still
    /// pays its own prompt and sends a fresh read.
    func testConfirmedCallIgnoresTheUnlockedGatewaySecret() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)
        _ = try site.service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertEqual(site.gate.reasons.count, 1, "the gateway's own unlock prompt")

        _ = try site.service.testKeys(keys: ["demo"], confirm: true, caller: "mcp")
        XCTAssertEqual(site.gate.reasons, [site.gate.reasons[0], "test 1 key read-only: demo"],
                       "the check prompts even with the secret unlocked in memory")
        XCTAssertEqual(site.checker.requests.count, 1)
    }

    /// A key named twice is one key: one row, one probe, one name in the prompt.
    func testAKeyNamedTwiceIsOneProbe() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        let payload = try site.service.testKeys(keys: ["demo", "demo"], confirm: true, caller: "mcp")

        XCTAssertEqual(site.gate.reasons, ["test 1 key read-only: demo"])
        XCTAssertEqual(site.checker.requests.count, 1)
        XCTAssertEqual(try rows(payload).count, 1)
    }

    // MARK: - VAL-TKEY-003 (no check endpoint: nothing sent)

    /// A key whose provider has no read-only endpoint reports no_check_endpoint
    /// with nothing sent, and is not named in the prompt; a call with no probeable
    /// key at all prompts no one.
    func testUnprobeableProviderSendsNothingAndPromptsNoOneWhenNothingProbes() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)
        try site.service.add(name: "voice", provider: "elevenlabs", kind: "runtime", notes: "", secret: voiceSecret)

        let mixed = try site.service.testKeys(keys: ["demo", "voice"], confirm: true, caller: "mcp")
        XCTAssertEqual(site.gate.reasons, ["test 1 key read-only: demo"],
                       "the prompt names only the keys it will probe")
        XCTAssertEqual(site.checker.requests.count, 1, "the unprobeable key sent nothing")
        let mixedRows = try rows(mixed)
        XCTAssertEqual(mixedRows[1]["key"] as? String, "voice")
        XCTAssertEqual(mixedRows[1]["outcome"] as? String, "no_check_endpoint")
        XCTAssertEqual(mixedRows[1]["confirmed"] as? Bool, true)
        XCTAssertTrue((mixedRows[1]["message"] as? String ?? "").contains("nothing was sent"))
        XCTAssertEqual((mixedRows[1]["message"] as? String ?? "").contains("ElevenLabs"), true,
                       "the provider is named")

        let none = try site.service.testKeys(keys: ["voice"], confirm: true, caller: "mcp")
        XCTAssertEqual(site.gate.reasons.count, 1, "a call with no probeable key prompts no one")
        XCTAssertEqual(site.checker.requests.count, 1, "still nothing sent for the unprobeable key")
        let noneRows = try rows(none)
        XCTAssertEqual(noneRows[0]["outcome"] as? String, "no_check_endpoint")
        XCTAssertEqual(noneRows[0]["confirmed"] as? Bool, true)
    }

    // MARK: - VAL-TKEY-004 (the keys-test shape, secret-free)

    /// Each row is the existing ProviderCheck result JSON — the exact key set
    /// `keys test` answers with — plus the confirmed flag; provider error text is
    /// scrubbed against the secret, and no value or token shape appears anywhere
    /// in the payload. The result persists and audits the way a keys test does.
    func testConfirmedResultIsTheKeysTestShapeAndSecretFree() throws {
        let site = try makeSite()
        site.checker.status = 401
        site.checker.body = Data(
            #"{"error":{"message":"Incorrect API key provided: \#(openaiSecret)","type":"invalid_request_error"}}"#.utf8
        )
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        let payload = try site.service.testKeys(keys: ["demo"], confirm: true, caller: "mcp")

        let row = try rows(payload)[0]
        XCTAssertEqual(Set(row.keys),
                       ["key", "provider", "host", "checked_at", "outcome", "ok", "http_status", "model_count",
                        "models", "request_id", "message", "endpoint", "summary", "confirmed"],
                       "the keys-test shape plus confirmed, nothing else")
        XCTAssertEqual(row["outcome"] as? String, "provider_auth_failed")
        XCTAssertEqual(row["http_status"] as? Int, 401)
        XCTAssertEqual(row["confirmed"] as? Bool, true)
        let message = row["message"] as? String ?? ""
        XCTAssertTrue(message.contains("[redacted]"), "the provider's echoed secret is scrubbed: \(message)")
        XCTAssertFalse(message.contains(openaiSecret))

        let wire = String(decoding: try JSONValue.data(payload), as: UTF8.self)
        XCTAssertFalse(wire.contains(openaiSecret), "no key value in the payload")
        XCTAssertFalse(wire.contains("ksf_"), "no gateway token shape in the payload")
        XCTAssertFalse(wire.contains("ksfc_"), "no client token shape in the payload")
        XCTAssertFalse(wire.contains("ksfp_"), "no project token shape in the payload")

        // The keys-test persistence and audit, exactly as `keys test` leaves them.
        let stored = try XCTUnwrap(try site.service.lastCheck(name: "demo"))
        XCTAssertEqual(stored.outcome, .providerAuthFailed)
        XCTAssertEqual(stored.key, "demo")
        let checkEvents = try site.db.keyEvents(name: "demo", limit: 10).filter { $0.action == "check" }
        XCTAssertEqual(checkEvents.count, 1, "the probe is audited as one check")
        XCTAssertEqual(checkEvents.first?.caller, "mcp")
    }

    // MARK: - VAL-TKEY-005 (refusals)

    /// An unknown key name refuses the whole call before any prompt or probe —
    /// confirmed or not, the validation is uniform.
    func testUnknownKeyRefusesTheWholeCallBeforeAnyPromptOrProbe() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        for (label, body) in [
            ("confirmed", ["keys": ["demo", "ghost"], "confirm": true] as [String: Any]),
            ("not confirmed", ["keys": ["ghost"]] as [String: Any]),
        ] {
            let response = try post(site, body: body)
            XCTAssertEqual(response.status, 404, "the named not-found refusal: \(label)")
            let envelope = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertEqual(envelope["error"] as? String, "not_found", label)
            XCTAssertEqual(site.checker.requests.count, 0, "nothing was sent: \(label)")
            XCTAssertEqual(site.gate.reasons.count, 0, "no prompt was spent on a typo: \(label)")
        }

        // A probeable key with no host refuses the way `keys test` does — also
        // before the prompt, so no Touch ID is spent on a call that cannot run.
        try site.service.add(name: "az", provider: "azure-openai", kind: "runtime", notes: "", secret: voiceSecret)
        XCTAssertThrowsError(try site.service.testKeys(keys: ["az"], confirm: true, caller: "mcp")) { error in
            XCTAssertEqual((error as? AppError)?.description,
                           "set a gateway host for az first (this provider has one host per account)")
        }
        XCTAssertEqual(site.gate.reasons.count, 0)
        XCTAssertEqual(site.checker.requests.count, 0)
    }

    /// Without the app the whole call fails with the pinned not-running sentence —
    /// never a partial answer — within the sweep's bound.
    func testAppDownFailsTheWholeCallWithThePinnedSentence() throws {
        let started = Date()
        let (isError, text) = try callTool(roster(control: try deadControl()), arguments: ["keys": ["demo"]])
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2, "within the sweep's 2 s bound")
        XCTAssertTrue(isError, "the whole call fails, never a partial answer")
        XCTAssertEqual(text, AppConnection.notRunningMessage, "the pinned sentence, byte for byte")
        XCTAssertFalse(text.contains("results"), "no partial payload rides the failure")
    }

    // MARK: - the route

    /// The route is origin-token gated, validates the body with the named refusals,
    /// relays the service payload verbatim, and is never a GET.
    func testRouteIsTokenGatedAndValidatesTheBody() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        XCTAssertEqual(
            handle(site.handler, method: "POST", path: "/api/mcp/test_keys",
                   body: try JSONValue.data(["keys": ["demo"]] as [String: Any]), token: false).status,
            403, "no origin token, no key test"
        )

        let ok = try post(site, body: ["keys": ["demo"], "confirm": true])
        XCTAssertEqual(ok.status, 200)
        let payload = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
        XCTAssertEqual(try rows(payload).count, 1, "the route relays the flow's payload")

        for (label, bad) in [
            ("keys missing", ["confirm": true] as [String: Any]),
            ("keys not a list", ["keys": "demo"] as [String: Any]),
            ("keys empty", ["keys": [] as [Any]] as [String: Any]),
            ("keys not strings", ["keys": [42] as [Any]] as [String: Any]),
            ("confirm not a boolean", ["keys": ["demo"], "confirm": "yes"] as [String: Any]),
        ] {
            let response = try post(site, body: bad)
            XCTAssertEqual(response.status, 400, "refused: \(label)")
            let envelope = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertNotNil(envelope["error"] as? String, "the house envelope names the refusal: \(label)")
        }
        XCTAssertEqual(site.checker.requests.count, 1, "only the one confirmed call probed")
        XCTAssertEqual(handle(site.handler, method: "GET", path: "/api/mcp/test_keys").status, 405,
                       "the route is a POST, never a state-carrying GET")
    }

    // MARK: - the tool surface

    /// The tool relays names and the flag only, with the presence bound in play for
    /// the confirmed call, and the answer is the app's payload — the wire carrying
    /// no secret and the app having prompted exactly once.
    func testToolRelaysNamesAndFlagOverTheWire() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        let (isError, text) = try callTool(
            roster(control: site.control),
            arguments: ["keys": ["demo"], "confirm": true]
        )
        XCTAssertFalse(isError)
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(try rows(payload).count, 1)
        XCTAssertEqual(try rows(payload)[0]["confirmed"] as? Bool, true)
        XCTAssertFalse(text.contains(openaiSecret), "no key value crossed the wire")
        XCTAssertEqual(site.gate.reasons, ["test 1 key read-only: demo"], "the one prompt, app-side")

        let sent = try JSONSerialization.jsonObject(
            with: Data(String(decoding: site.log.all.last { $0.path == "/api/mcp/test_keys" }!.body, as: UTF8.self).utf8)
        ) as! [String: Any]
        XCTAssertEqual(Set(sent.keys), ["keys", "confirm"], "the names and the flag crossed, nothing else")
        XCTAssertEqual(sent["keys"] as? [String], ["demo"])
        XCTAssertEqual(sent["confirm"] as? Bool, true)
    }

    /// The tool refuses malformed arguments itself, before the app is contacted:
    /// keys is required and must be a non-empty list of names, confirm a boolean.
    func testToolValidatesArgumentsBeforeTheAppIsCalled() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: openaiSecret)

        for (label, arguments) in [
            ("keys missing", ["confirm": true] as [String: Any]),
            ("keys not a list", ["keys": "demo"] as [String: Any]),
            ("keys empty", ["keys": [] as [Any]] as [String: Any]),
            ("keys not strings", ["keys": [42] as [Any]] as [String: Any]),
            ("confirm not a boolean", ["keys": ["demo"], "confirm": "yes"] as [String: Any]),
        ] {
            let (isError, text) = try callTool(roster(control: site.control), arguments: arguments)
            XCTAssertTrue(isError, "refused: \(label)")
            XCTAssertFalse(text.contains("Keysrs isn't running"),
                           "a malformed argument is the caller's own refusal, not an app-down one: \(label)")
            XCTAssertFalse(site.log.all.contains { $0.path == "/api/mcp/test_keys" },
                           "the app was never contacted: \(label)")
        }
        XCTAssertEqual(site.checker.requests.count, 0)
        XCTAssertEqual(site.gate.reasons.count, 0)
    }

    // MARK: - VAL-TKEY-006 (the tool description pins the per-call ask)

    /// The registered description tells the caller to ask the user in that same
    /// call before passing confirm true, and never to remember a yes — and the
    /// schema pins keys as the one required input.
    func testToolDescriptionPinsThePerCallAsk() throws {
        let tool = try XCTUnwrap(
            MCPToolRegistry.default.tools.first { $0.name == "test_keys" },
            "test_keys is registered in the production roster"
        )
        XCTAssertTrue(tool.description.contains("ask the user in this same call"), tool.description)
        XCTAssertTrue(tool.description.contains("only after they say yes"), tool.description)
        XCTAssertTrue(tool.description.contains("never remember an earlier yes"), tool.description)
        XCTAssertFalse(tool.description.contains("\n"), "one description paragraph")

        let schema = tool.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["keys"], "keys is the one required input")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["keys"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((properties["confirm"] as? [String: Any])?["type"] as? String, "boolean")
    }

    // MARK: - the per-call bound

    /// One outcome slot a concurrent caller fills under a lock — the two calls run
    /// side by side, so the shared holders are one @unchecked box, never captured vars.
    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ value: T) {
            lock.lock(); self.value = value; lock.unlock()
        }
        func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> T {
            lock.lock(); defer { lock.unlock() }
            return try XCTUnwrap(value, file: file, line: line)
        }
    }

    /// The bound is the presence bound exactly when the call is confirmed: against
    /// a site that answers after 10.6 s — past the 10 s default, well inside the
    /// 120 s presence bound — the confirmed call waits the slow answer out and
    /// relays it, while the unconfirmed call ends at the default instead of
    /// hanging. Both run concurrently against the same slow site, so the pair
    /// costs one slow answer, not two.
    func testConfirmedCallOutlastsTheDefaultUnconfirmedKeepsIt() throws {
        let slow = try LoopbackHTTPServer(port: 0) { _ in
            Thread.sleep(forTimeInterval: 10.6)
            return HTTPResponse.json(200, ["results": [] as [String]])
        }
        slow.start()
        addTeardownBlock { slow.stop() }
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try assertNotProductionPath(control)
        try ControlFile.write(
            port: slow.boundPort, token: "slow-site",
            pid: ProcessInfo.processInfo.processIdentifier, to: control
        )

        let group = MCPOnboardingTools(control: control, launch: .neverLaunching)
        let confirmed = Slot<(elapsed: TimeInterval, result: MCPToolResult?)>()
        let unconfirmed = Slot<(elapsed: TimeInterval, failure: String?)>()
        let done = DispatchGroup()

        done.enter()
        DispatchQueue.global().async {
            let started = Date()
            let result = try? group.call("test_keys", arguments: ["keys": ["demo"], "confirm": true] as [String: Any])
            confirmed.set((Date().timeIntervalSince(started), result))
            done.leave()
        }
        done.enter()
        DispatchQueue.global().async {
            let started = Date()
            var failure: String?
            do {
                _ = try group.call("test_keys", arguments: ["keys": ["demo"]] as [String: Any])
            } catch {
                failure = (error as? AppError)?.description ?? "\(error)"
            }
            unconfirmed.set((Date().timeIntervalSince(started), failure))
            done.leave()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 90), .success, "both calls come back on their own bound")

        let confirmedOutcome = try confirmed.unwrap()
        XCTAssertNotNil(confirmedOutcome.result, "the presence bound held the call and the site's answer came back")
        XCTAssertLessThanOrEqual(confirmedOutcome.elapsed, 30)
        XCTAssertGreaterThanOrEqual(confirmedOutcome.elapsed, 10.2,
                                    "the confirmed call sat out the 10 s default: the presence bound is in play")

        let unconfirmedOutcome = try unconfirmed.unwrap()
        XCTAssertNotNil(unconfirmedOutcome.failure, "the default bound ends the unconfirmed call, never a 120 s hang")
        XCTAssertTrue(unconfirmedOutcome.failure?.contains("could not reach the local site") ?? false,
                      "the failure is the site-unreachable error: \(unconfirmedOutcome.failure ?? "")")
        XCTAssertGreaterThanOrEqual(unconfirmedOutcome.elapsed, 9.0,
                                    "it was the bound that ended the call, not a fast failure")
        XCTAssertLessThanOrEqual(unconfirmedOutcome.elapsed, 13.0)
    }

    // MARK: - the sweep's offline row

    /// The sweep's argument row is safe offline: against the unwritten control
    /// file the tool answers its not-running result, appends no prompt and stays
    /// inside the bound — the shape MCPOutputGuardSweepTests drives roster-wide.
    func testSweepRowIsSafeOffline() throws {
        let rig = try MCPSweepRig.make()
        let arguments = try XCTUnwrap(MCPSweepRig.argumentRows["test_keys"],
                                      "the sweep row for test_keys exists")
        let promptsBefore = rig.gate.reasons.count
        let started = Date()
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"test_keys","arguments":\#(String(decoding: try JSONValue.data(arguments), as: UTF8.self))}}"#,
        ], registry: try rig.registry())
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2)
        let result = try MCPSession.assertResult(frames[1], id: "t")
        XCTAssertTrue(result["isError"] as? Bool ?? false, "no app means the not-running result")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, AppConnection.notRunningMessage)
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "an offline call prompts no one")
    }
}
