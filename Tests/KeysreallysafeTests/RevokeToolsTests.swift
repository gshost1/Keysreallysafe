import Foundation
import XCTest
@testable import KeysCore

/// F3 VAL-RV-001..008: the revocation kill switches — the combined app route
/// (`POST /api/mcp/revoke_all`), the project route (`POST /api/mcp/revoke_project`)
/// and the two tools over them. Grants live only in the app process's memory and
/// client tokens are catalog rows the gateway re-reads per request, so both
/// revocations happen in the app; the route tests drive a real `APIHandler`
/// behind a loopback server on an ephemeral port (never the installed app, never
/// its ports), the tool tests drive the real `MCPSession` dispatch over that
/// site, and the CLI class below drives the built binary one-shot in a temp
/// home. No Touch ID anywhere on a revoke path — revocation only removes access
/// — and every test here pins the presence gate at its setup count.
final class RevokeToolsTests: XCTestCase {

    /// The contract's pinned not-running sentence, byte for byte.
    private static let notRunningSentence = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    private let fm = FileManager.default

    // MARK: - The rig

    /// The in-process app: two vault keys, a real `APIHandler` behind a loopback
    /// server on an ephemeral port, `control.json` beside the catalog naming it,
    /// and the revoke tool group wired over that control file — exactly how
    /// `keys mcp` reaches the running app. The recording gate counts the setup
    /// prompts (client issuance takes one each); no revoke path may add any.
    private struct Site {
        let server: LoopbackHTTPServer
        let handler: APIHandler
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let control: URL
        let gate: RecordingPresenceGate
        let tools: MCPRevokeTools
        let requests: RequestLog

        /// The full production roster wired over this site, so the tool tests run
        /// through the real registry the server builds.
        var registry: MCPToolRegistry {
            MCPRoster.registry(
                catalog: { db },
                control: control,
                fetchLatestRelease: { throw AppError.usage("the revoke rig fetches no release") },
                projectFolder: { dir.path }
            )
        }
    }

    private func makeSite() throws -> Site {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        // The gateway target cached, so client issuance needs no extra prompt and
        // the grants' host is the provider default, as the app holds it.
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)
        _ = try service.setGateway(name: "other", enabled: true, host: nil, presenceChecked: true)
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
        return Site(
            server: server, handler: handler, service: service, db: db, dir: dir,
            control: control, gate: gate, tools: MCPRevokeTools(control: control), requests: requests
        )
    }

    /// One dashboard-style request to a route, carrying the origin token.
    private func post(_ site: Site, _ path: String, _ body: Any) throws -> HTTPResponse {
        handle(site.handler, method: "POST", path: path, body: try JSONValue.data(body))
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    /// A grant issued straight into the store — no prompt, the ServerTests
    /// renewal precedent — returns its id and token.
    private func grant(_ service: KeysService, key: String, task: String) throws -> (id: String, token: String) {
        let issued = service.grants.issue(
            key: key, provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: task, minutes: 30, methods: ["GET"], paths: ["/v1/messages"]).validated()
        )
        return (issued.grant.id, issued.token)
    }

    /// A client token issued through the real service path (one presence prompt,
    /// the setup's own — counted before every revoke assertion below).
    private func token(
        _ service: KeysService, key: String, label: String, project: String? = nil
    ) throws -> (id: Int64, token: String) {
        let issued = try service.issueGatewayClient(name: key, label: label, methods: ["GET"], project: project)
        return (issued.client.id, issued.token)
    }

    /// A resolved project row for a real folder under the site's temp dir.
    private func project(_ site: Site, _ name: String) throws -> CatalogDB.ProjectRow {
        let folder = site.dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return try site.service.resolveProject(folder: folder.path)
    }

    /// The gateway's own grant decision for one token.
    private func authorizeGrant(_ site: Site, _ token: String, key: String) -> Result<Grant, GrantDenial> {
        site.service.grants.authorize(
            token: token, key: key, host: "api.openai.com", method: "GET",
            rest: "v1/messages", providerPrefix: "/v1"
        )
    }

    /// The gateway's own client-token decision for one token.
    private func authorizeClient(_ site: Site, _ token: String, key: String) -> GatewayClientDecision {
        site.service.authorizeGatewayClient(
            name: key, headers: ["authorization": "Bearer " + token], method: "GET", rest: "v1/messages"
        )
    }

    /// One tools/call through the real server frames — the surface the model
    /// sees, error formatter and output guard included.
    private func callTool(
        _ site: Site, name: String, arguments: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let encoded = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"\#(name)","arguments":\#(encoded)}}"#,
        ], registry: site.registry)
        XCTAssertEqual(frames.last, "", file: file, line: line)
        XCTAssertEqual(stderr, [], file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    /// One tool call answered as the server would answer it: a throw becomes the
    /// isError result `MCPServer.serveToolsCall` makes of it, so the refusal
    /// wording is asserted exactly as a client sees it.
    private func served(_ tools: MCPRevokeTools, _ name: String, _ arguments: [String: Any]) -> MCPToolResult {
        do {
            return try tools.call(name, arguments: arguments)
        } catch {
            return MCPToolResult.failure(MCPToolErrorFormatter.message(for: error))
        }
    }

    private func text(_ result: MCPToolResult) -> String {
        (result.content.first?["text"] as? String) ?? ""
    }

    /// The counts a tool answered, as JSON.
    private func counts(_ call: (isError: Bool, text: String)) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(call.text.utf8)) as? [String: Any] ?? [:]
    }

    // MARK: - The combined route (VAL-RV-001, 002, 003, 007)

    /// One route revokes grants AND client tokens, answers both counts, and both
    /// kinds are refused afterwards — the grant table no longer knows the token,
    /// and the gateway's own decision denies the client token. One grant_revoke
    /// row per grant and one client_revoke row per key land in the audit log, the
    /// caller names the surface that asked, and the second call answers zeros:
    /// the counts mean "was live, now dead", never "rows seen".
    func testRevokeAllRouteKillsGrantsAndClientTokensWithCounts() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let g1 = try grant(site.service, key: "demo", task: "one")
        let g2 = try grant(site.service, key: "demo", task: "two")
        let g3 = try grant(site.service, key: "other", task: "three")
        let c1 = try token(site.service, key: "demo", label: "agent a")
        let c2 = try token(site.service, key: "demo", label: "agent b")
        let c3 = try token(site.service, key: "other", label: "agent c")

        let prompts = site.gate.reasons.count
        let answer = try post(site, "/api/mcp/revoke_all", [:])
        XCTAssertEqual(answer.status, 200, String(decoding: answer.body, as: UTF8.self))
        let body = try json(answer)
        XCTAssertEqual(body["revoked_grants"] as? Int, 3)
        XCTAssertEqual(body["revoked_clients"] as? Int, 3)
        XCTAssertEqual(Set(body.keys), ["revoked_grants", "revoked_clients"], "the answer is exactly the two counts")
        XCTAssertEqual(site.gate.reasons.count, prompts, "no Touch ID on the revoke path")

        // Both kinds are refused afterwards.
        XCTAssertEqual(authorizeGrant(site, g1.token, key: "demo"), .failure(.revoked))
        XCTAssertEqual(authorizeGrant(site, g2.token, key: "demo"), .failure(.revoked))
        XCTAssertEqual(authorizeGrant(site, g3.token, key: "other"), .failure(.revoked))
        for dead in [(c1, "demo"), (c2, "demo"), (c3, "other")] {
            guard case .denied("revoked") = authorizeClient(site, dead.0.token, key: dead.1) else {
                return XCTFail("the revoked client token is refused")
            }
        }

        // The audit trail: one grant_revoke row per grant, one client_revoke row
        // per affected key naming the revoked ids, and the caller on every row.
        let demo = try site.service.keyEvents(name: "demo")
        XCTAssertEqual(demo.filter { $0.action == "grant_revoke" }.count, 2)
        let demoRevokes = demo.filter { $0.action == "client_revoke" }
        XCTAssertEqual(demoRevokes.count, 1, "one client_revoke row per affected key")
        XCTAssertEqual(demoRevokes.first?.detail, "#\(c1.id) #\(c2.id)")
        XCTAssertEqual(demoRevokes.first?.caller, "mcp", "the route's caller names the surface that asked")
        let other = try site.service.keyEvents(name: "other")
        XCTAssertEqual(other.filter { $0.action == "grant_revoke" }.count, 1)
        XCTAssertEqual(other.filter { $0.action == "client_revoke" }.count, 1)

        // Idempotent: the second call answers zeros, exit-0 counts for the CLI.
        let again = try post(site, "/api/mcp/revoke_all", [:])
        XCTAssertEqual(again.status, 200)
        let zeros = try json(again)
        XCTAssertEqual(zeros["revoked_grants"] as? Int, 0)
        XCTAssertEqual(zeros["revoked_clients"] as? Int, 0)
        XCTAssertEqual(site.gate.reasons.count, prompts, "the zero-count call prompted nothing either")
    }

    /// A key-scoped revoke_all touches only that key's grants and tokens; the
    /// other key's survive and keep authorizing, and no audit row exists for a
    /// key that lost nothing.
    func testRevokeAllRouteScopesByKeyAndOtherKeysKeepWorking() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let doomedGrant = try grant(site.service, key: "demo", task: "doomed")
        let liveGrant = try grant(site.service, key: "other", task: "live")
        let doomedToken = try token(site.service, key: "demo", label: "agent a")
        let liveToken = try token(site.service, key: "other", label: "agent c")

        let prompts = site.gate.reasons.count
        let answer = try post(site, "/api/mcp/revoke_all", ["key": "demo"])
        XCTAssertEqual(answer.status, 200, String(decoding: answer.body, as: UTF8.self))
        let body = try json(answer)
        XCTAssertEqual(body["revoked_grants"] as? Int, 1)
        XCTAssertEqual(body["revoked_clients"] as? Int, 1)
        XCTAssertEqual(site.gate.reasons.count, prompts, "no Touch ID on the scoped revoke path")

        XCTAssertEqual(authorizeGrant(site, doomedGrant.token, key: "demo"), .failure(.revoked))
        guard case .denied("revoked") = authorizeClient(site, doomedToken.token, key: "demo") else {
            return XCTFail("the scoped token is dead")
        }
        XCTAssertNoThrow(try authorizeGrant(site, liveGrant.token, key: "other").get(), "the other key's grant keeps working")
        guard case .allowed = authorizeClient(site, liveToken.token, key: "other") else {
            return XCTFail("the other key's token keeps working")
        }
        XCTAssertEqual(
            try site.service.keyEvents(name: "other").filter { $0.action == "client_revoke" }.count, 0,
            "no audit row for a key that lost nothing"
        )
    }

    /// The route re-validates the caller's types, the shape the tool and the CLI
    /// both enforce one hop earlier: a non-string or malformed key name is a
    /// usage refusal and revokes nothing, and unknown body fields are ignored.
    func testRevokeAllRouteRefusesABadKeyShape() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        _ = try grant(site.service, key: "demo", task: "alive")
        _ = try token(site.service, key: "demo", label: "agent a")

        for body in [["key": 3] as [String: Any], ["key": "BAD NAME!"], ["key": ""]] {
            let refused = try post(site, "/api/mcp/revoke_all", body)
            XCTAssertEqual(refused.status, 400, "\(body)")
        }
        XCTAssertEqual(site.service.listGrants().count, 1, "a refused call revoked nothing")
        XCTAssertEqual(try site.service.gatewayClients(name: "demo").filter { $0.revokedAt == nil }.count, 1,
                       "a refused call killed no client token")

        // Unknown fields are ignored (the mcpGrantAsk rule): a decoy key planted
        // beside a real one changes nothing.
        let answered = try post(site, "/api/mcp/revoke_all", ["key": "demo", "decoy": 1])
        XCTAssertEqual(answered.status, 200)
        let body = try json(answered)
        XCTAssertEqual(body["revoked_grants"] as? Int, 1)
        XCTAssertEqual(body["revoked_clients"] as? Int, 1)
    }

    /// VAL-RV-003, the literal pin: a revoke path that starts from an empty
    /// presence gate ends with it still empty. Setup mints nothing through a
    /// presence-gated surface — the grant goes straight into the store and the
    /// client token through the catalog primitive `mintGatewayClient` itself
    /// calls — so `gate.reasons == []` is the whole story, exactly the shape the
    /// contract pins for every new revoke path.
    func testRevokeAllRouteConsumesZeroPresencePromptsLiterally() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        _ = site.service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "no prompt anywhere", minutes: 30, methods: ["GET"]).validated()
        )
        let minted = GatewayClientToken.generate()
        _ = try site.db.insertGatewayClient(
            keyName: "demo", label: "agent", tokenHash: GatewayClientToken.hash(minted),
            hint: GatewayClientToken.hint(minted), methods: ["GET"], pathPrefix: nil,
            host: "api.openai.com", createdAt: UTC.iso(Date()),
            expiresAt: UTC.iso(Date().addingTimeInterval(30 * 86_400)), project: nil
        )
        XCTAssertEqual(site.gate.reasons, [], "setup minted nothing through a presence-gated surface")

        let answer = try post(site, "/api/mcp/revoke_all", [:])
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(try json(answer)["revoked_grants"] as? Int, 1)
        XCTAssertEqual(try json(answer)["revoked_clients"] as? Int, 1)
        XCTAssertEqual(site.gate.reasons, [], "the whole revoke path consumed zero presence prompts")

        guard case .denied("revoked") = authorizeClient(site, minted, key: "demo") else {
            return XCTFail("the catalog-minted token died with the grant")
        }
        XCTAssertEqual(try site.service.keyEvents(name: "demo").filter { $0.action == "client_revoke" }.count, 1,
                       "the audit row exists for the catalog-minted client too")
    }

    // MARK: - The project route (VAL-RV-006, 007)

    /// revoke_project resolves the exact label, revokes that project's active
    /// client tokens with one client_revoke row per affected key, leaves grants
    /// and other projects' and unbound tokens alone, answers zero for a known
    /// label with nothing active, and 404s an unknown label with the not-found
    /// shape revokeGrant gives an unknown id.
    func testRevokeProjectRouteByLabel() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let alpha = try project(site, "alpha")
        let beta = try project(site, "beta")
        let gamma = try project(site, "gamma")
        let a1 = try token(site.service, key: "demo", label: "alpha agent", project: alpha.id)
        let a2 = try token(site.service, key: "other", label: "alpha agent", project: alpha.id)
        let b1 = try token(site.service, key: "demo", label: "beta agent", project: beta.id)
        let plain = try token(site.service, key: "demo", label: "unbound")
        let liveGrant = try grant(site.service, key: "demo", task: "untouched")

        let prompts = site.gate.reasons.count
        let answer = try post(site, "/api/mcp/revoke_project", ["label": alpha.label])
        XCTAssertEqual(answer.status, 200, String(decoding: answer.body, as: UTF8.self))
        let body = try json(answer)
        XCTAssertEqual(body["revoked_clients"] as? Int, 2)
        XCTAssertEqual(Set(body.keys), ["revoked_clients"], "client tokens only, one count")
        XCTAssertEqual(site.gate.reasons.count, prompts, "no Touch ID on the project revoke path")

        guard case .denied("revoked") = authorizeClient(site, a1.token, key: "demo") else {
            return XCTFail("the alpha-bound token is dead")
        }
        guard case .denied("revoked") = authorizeClient(site, a2.token, key: "other") else {
            return XCTFail("the other key's alpha token is dead too")
        }
        guard case .allowed = authorizeClient(site, b1.token, key: "demo") else {
            return XCTFail("the beta-bound token survives")
        }
        guard case .allowed = authorizeClient(site, plain.token, key: "demo") else {
            return XCTFail("the unbound token survives")
        }
        XCTAssertNoThrow(try authorizeGrant(site, liveGrant.token, key: "demo").get(),
                         "grants carry no project; the project revoke never touches them")

        // One client_revoke row per affected key, naming the revoked id.
        let demo = try site.service.keyEvents(name: "demo").filter { $0.action == "client_revoke" }
        XCTAssertEqual(demo.count, 1)
        XCTAssertEqual(demo.first?.detail, "#\(a1.id)")
        XCTAssertEqual(demo.first?.caller, "mcp")
        XCTAssertEqual(try site.service.keyEvents(name: "other").filter { $0.action == "client_revoke" }.count, 1)

        // A known label with nothing active answers zero, not an error.
        let empty = try post(site, "/api/mcp/revoke_project", ["label": gamma.label])
        XCTAssertEqual(empty.status, 200)
        XCTAssertEqual(try json(empty)["revoked_clients"] as? Int, 0)

        // An unknown label is the not-found shape; a missing label is usage.
        let unknown = try post(site, "/api/mcp/revoke_project", ["label": "no-such-project"])
        XCTAssertEqual(unknown.status, 404)
        let unknownBody = try json(unknown)
        XCTAssertEqual(unknownBody["error"] as? String, "not_found")
        XCTAssertEqual(unknownBody["detail"] as? String, "no-such-project")
        XCTAssertEqual(try post(site, "/api/mcp/revoke_project", [:]).status, 400, "a missing label is refused")
        XCTAssertEqual(try post(site, "/api/mcp/revoke_project", ["label": 3]).status, 400)
    }

    // MARK: - The tools over the real dispatch (VAL-RV-001, 002, 006, 007)

    /// Both tools over the real `MCPSession` dispatch against the site: the same
    /// counts the route answers, scoped by key, with the whole result screened by
    /// the output guard on the way out.
    func testRevokeAllToolCountsAndScopeOverTheDispatch() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        _ = try grant(site.service, key: "demo", task: "doomed")
        let survivorGrant = try grant(site.service, key: "other", task: "live")
        _ = try token(site.service, key: "demo", label: "doomed agent")
        let survivorToken = try token(site.service, key: "other", label: "live agent")

        let prompts = site.gate.reasons.count
        let scoped = try callTool(site, name: "revoke_all", arguments: ["key": "demo"])
        XCTAssertEqual(scoped.isError, false, scoped.text)
        var body = try counts(scoped)
        XCTAssertEqual(body["revoked_grants"] as? Int, 1)
        XCTAssertEqual(body["revoked_clients"] as? Int, 1)
        XCTAssertEqual(Set(body.keys), ["revoked_grants", "revoked_clients"])
        XCTAssertNoThrow(try authorizeGrant(site, survivorGrant.token, key: "other").get(),
                         "the named-out key's grant survives the scoped tool call")
        guard case .allowed = authorizeClient(site, survivorToken.token, key: "other") else {
            return XCTFail("the named-out key's token survives")
        }

        let all = try callTool(site, name: "revoke_all", arguments: [:])
        XCTAssertEqual(all.isError, false, all.text)
        body = try counts(all)
        XCTAssertEqual(body["revoked_grants"] as? Int, 1, "only the survivor grant was still live")
        XCTAssertEqual(body["revoked_clients"] as? Int, 1)
        XCTAssertEqual(authorizeGrant(site, survivorGrant.token, key: "other"), .failure(.revoked))
        guard case .denied("revoked") = authorizeClient(site, survivorToken.token, key: "other") else {
            return XCTFail("the survivor token died on the full revoke")
        }
        XCTAssertEqual(site.gate.reasons.count, prompts, "the tool calls consumed no presence prompt")
    }

    /// The project tool resolves the label through the app, answers the one
    /// count, and an unknown label is a tool error naming not-found.
    func testRevokeProjectToolByLabelAndUnknown() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let alpha = try project(site, "alpha")
        let alphabet = try project(site, "alphabet")
        let bound = try token(site.service, key: "demo", label: "alpha agent", project: alpha.id)
        let cousin = try token(site.service, key: "demo", label: "alphabet agent", project: alphabet.id)
        let free = try token(site.service, key: "demo", label: "unbound")

        let prompts = site.gate.reasons.count
        let answered = try callTool(site, name: "revoke_project", arguments: ["label": alpha.label])
        XCTAssertEqual(answered.isError, false, answered.text)
        let body = try counts(answered)
        XCTAssertEqual(body["revoked_clients"] as? Int, 1)
        XCTAssertEqual(Set(body.keys), ["revoked_clients"])
        guard case .denied("revoked") = authorizeClient(site, bound.token, key: "demo") else {
            return XCTFail("the alpha-bound token is dead")
        }
        guard case .allowed = authorizeClient(site, cousin.token, key: "demo") else {
            return XCTFail("the exact label match is not a prefix match: alphabet survives")
        }
        guard case .allowed = authorizeClient(site, free.token, key: "demo") else {
            return XCTFail("the unbound token survives")
        }
        XCTAssertEqual(site.gate.reasons.count, prompts)

        let unknown = try callTool(site, name: "revoke_project", arguments: ["label": "no-such-project"])
        XCTAssertEqual(unknown.isError, true)
        XCTAssertTrue(unknown.text.contains("not found"), unknown.text)
    }

    /// Local argument refusal: a wrong-typed or malformed key, and a missing or
    /// wrong-typed label, never reach the site — the request log proves no round
    /// trip — and the refusals name the argument.
    func testBothToolsRefuseBadArgumentsLocallyWithNoRoundTrip() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let requestsBefore = site.requests.count
        let prompts = site.gate.reasons.count
        let cases: [(name: String, arguments: [String: Any], expected: String)] = [
            ("revoke_all", ["key": 3], "key must be a string"),
            ("revoke_all", ["key": "BAD NAME!"], "invalid name"),
            ("revoke_all", ["key": ""], "invalid name"),
            ("revoke_project", [:], "label is required"),
            ("revoke_project", ["label": ""], "label is required"),
            ("revoke_project", ["label": 3], "label is required"),
        ]
        for c in cases {
            let result = served(site.tools, c.name, c.arguments)
            XCTAssertEqual(result.isError, true, "\(c.name) \(c.arguments)")
            XCTAssertTrue(text(result).contains(c.expected), "\(c.name): \(text(result))")
        }
        XCTAssertEqual(site.requests.count, requestsBefore, "a refused argument made no round trip")
        XCTAssertEqual(site.gate.reasons.count, prompts, "a refused argument prompted nothing")
        XCTAssertEqual(site.service.listGrants(includeInactive: true).count, 0, "nothing was revoked")
    }

    /// VAL-RV-007: with no app running (an unwritten control file), both tools
    /// answer the pinned sentence as a tool error result, byte for byte through
    /// the output guard.
    func testNotRunningSentenceForBothTools() throws {
        let dir = try TempDir.make()
        let tools = MCPRevokeTools(control: dir.appendingPathComponent("control.json"))
        for (name, arguments) in [("revoke_all", [:] as [String: Any]), ("revoke_project", ["label": "any"])] {
            let result = served(tools, name, arguments)
            XCTAssertEqual(result.isError, true, name)
            XCTAssertEqual(text(result), Self.notRunningSentence, name)
            let screened = MCPOutputGuard.production.screened(result)
            XCTAssertEqual((screened.content.first?["text"] as? String) ?? "", Self.notRunningSentence,
                           "\(name): the pinned sentence passes the output guard")
            XCTAssertEqual(screened.isError, true, name)
        }
    }
}

/// VAL-RV-004: `keys revoke --all` over the built binary — the combined route,
/// both counts in the house singular/plural style, and the pinned exit codes
/// (0 at any counts, 6 with the site down, 1 for an invalid --key, and the
/// single-id path unchanged). The site is the same in-process rig (an
/// `APIHandler` behind an ephemeral loopback port, `control.json` beside a
/// temp catalog), pointed at by `KEYS_CATALOG`, so the CLI's one-shots run
/// against a real site — never the installed app or its ports.
final class RevokeCLIPathTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Site {
        let server: LoopbackHTTPServer
        let handler: APIHandler
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let gate: RecordingPresenceGate
    }

    private func makeSite() throws -> Site {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)
        _ = try service.setGateway(name: "other", enabled: true, host: nil, presenceChecked: true)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return Site(server: server, handler: handler, service: service, db: db, dir: dir, gate: gate)
    }

    /// A grant issued straight into the store — the app's in-memory table the
    /// CLI's calls reach through the site.
    private func grant(_ service: KeysService, key: String, task: String) throws -> (id: String, token: String) {
        let issued = service.grants.issue(
            key: key, provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: task, minutes: 30, methods: ["GET"], paths: ["/v1/messages"]).validated()
        )
        return (issued.grant.id, issued.token)
    }

    private func authorizeGrant(_ site: Site, _ token: String, key: String) -> Result<Grant, GrantDenial> {
        site.service.grants.authorize(
            token: token, key: key, host: "api.openai.com", method: "GET",
            rest: "v1/messages", providerPrefix: "/v1"
        )
    }

    private func authorizeClient(_ site: Site, _ token: String, key: String) -> GatewayClientDecision {
        site.service.authorizeGatewayClient(
            name: key, headers: ["authorization": "Bearer " + token], method: "GET", rest: "v1/messages"
        )
    }

    /// One CLI one-shot of the built binary, with `KEYS_CATALOG` pointing at the
    /// site's temp catalog (its control file names the site, so the CLI finds
    /// it exactly as it finds the installed app). `site` nil means no site and
    /// no catalog: the app-down shapes.
    private func runCLI(
        _ site: Site?, _ arguments: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws -> (exit: Int32, out: String, err: String) {
        let binary = Self.repoRoot.appendingPathComponent(".build/debug/keys")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "\(binary.path) must exist and be executable; run swift test to build it", file: file, line: line
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let cwd = try TempDir.make()
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment["KEYS_CATALOG"] = site?.db.path.path ?? cwd.appendingPathComponent("catalog.db").path
        process.environment = environment
        try process.run()
        let outData = try out.fileHandleForReading.readToEnd() ?? Data()
        let errData = try err.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    /// `keys revoke --all` prints BOTH counts, exits 0 at real counts and at
    /// zero, and the revocations actually happened — the grant is refused and
    /// the client token is denied after the one-shot.
    func testRevokeAllPrintsBothCountsAndExitsZero() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let doomed = try grant(site.service, key: "demo", task: "doomed")
        let doomedClient = try site.service.issueGatewayClient(name: "demo", label: "agent", methods: ["GET"])
        let prompts = site.gate.reasons.count

        let first = try runCLI(site, ["revoke", "--all"])
        XCTAssertEqual(first.exit, 0, first.err)
        XCTAssertEqual(first.out, "revoked 1 grant and 1 client token\n")
        XCTAssertEqual(site.gate.reasons.count, prompts, "the CLI's --all path consumed no presence prompt")
        XCTAssertEqual(authorizeGrant(site, doomed.token, key: "demo"), .failure(.revoked))
        guard case .denied("revoked") = authorizeClient(site, doomedClient.token, key: "demo") else {
            return XCTFail("the client token died with the grant")
        }

        let zero = try runCLI(site, ["revoke", "--all"])
        XCTAssertEqual(zero.exit, 0, zero.err)
        XCTAssertEqual(zero.out, "revoked 0 grants and 0 client tokens\n")

        // The house plural style names both counts.
        _ = try grant(site.service, key: "demo", task: "pair one")
        _ = try grant(site.service, key: "demo", task: "pair two")
        _ = try site.service.issueGatewayClient(name: "demo", label: "another", methods: ["GET"])
        let plural = try runCLI(site, ["revoke", "--all"])
        XCTAssertEqual(plural.exit, 0, plural.err)
        XCTAssertEqual(plural.out, "revoked 2 grants and 1 client token\n")
    }

    /// `--key` scopes the CLI's revoke-all to one key, and the single-id path is
    /// unchanged: one grant id, the old sentence.
    func testRevokeAllKeyScopesAndTheSingleIdPathIsUnchanged() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        _ = try grant(site.service, key: "demo", task: "doomed")
        let survivor = try grant(site.service, key: "other", task: "live")
        _ = try site.service.issueGatewayClient(name: "demo", label: "agent", methods: ["GET"])
        _ = try site.service.issueGatewayClient(name: "other", label: "agent", methods: ["GET"])

        let scoped = try runCLI(site, ["revoke", "--all", "--key", "demo"])
        XCTAssertEqual(scoped.exit, 0, scoped.err)
        XCTAssertEqual(scoped.out, "revoked 1 grant and 1 client token\n")
        XCTAssertNoThrow(try authorizeGrant(site, survivor.token, key: "other").get(),
                         "the named-out key keeps working")
        XCTAssertEqual(try site.service.keyEvents(name: "demo").filter { $0.action == "client_revoke" }.count, 1)

        // The single-id path is unchanged: DELETE /api/grants/<id>, the old answer.
        let single = try grant(site.service, key: "other", task: "single")
        let revoked = try runCLI(site, ["revoke", single.id])
        XCTAssertEqual(revoked.exit, 0, revoked.err)
        XCTAssertEqual(revoked.out, "revoked \(single.id)\n")
        XCTAssertEqual(authorizeGrant(site, single.token, key: "other"), .failure(.revoked),
                       "the single-id path revoked the one grant it named, grants only")
        XCTAssertNoThrow(try authorizeGrant(site, survivor.token, key: "other").get(),
                         "the single-id path never touches another grant")
    }

    /// With no site running, exit is 6 — including when the key is also wrong,
    /// because the connect happens before the arguments are judged, exactly as
    /// before the route switch.
    func testRevokeAllAppDownExits6() throws {
        let down = try runCLI(nil, ["revoke", "--all"])
        XCTAssertEqual(down.exit, 6, down.err)
        XCTAssertTrue(down.err.contains("no running Keysrs site"), down.err)
        XCTAssertEqual(down.out, "", "the app-down path prints nothing on stdout")

        let badKeyDown = try runCLI(nil, ["revoke", "--all", "--key", "BAD NAME!"])
        XCTAssertEqual(badKeyDown.exit, 6, badKeyDown.err)
    }

    /// An invalid `--key` name is still exit 1 with the named refusal, when the
    /// site is up.
    func testRevokeAllInvalidKeyExits1() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let invalid = try runCLI(site, ["revoke", "--all", "--key", "BAD NAME!"])
        XCTAssertEqual(invalid.exit, 1, invalid.out + invalid.err)
        XCTAssertTrue(invalid.err.contains("invalid name"), invalid.err)
        XCTAssertEqual(site.service.listGrants(includeInactive: true).count, 0, "a refused call revoked nothing")
    }
}
