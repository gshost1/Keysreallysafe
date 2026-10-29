import Foundation
import XCTest
@testable import KeysCore

/// VAL-GRANT-001..022 and VAL-G-001/002: grants over MCP. The app is the only
/// issuer — `request_grant` creates a pending ask and answers
/// `{status:"pending", id, secret}` while the one Touch ID prompt is up;
/// `grant_status` polls it — proving the ask with its poll secret — and hands
/// the token over exactly once. Every synchronous refusal lands before any
/// prompt; profile bounds tighten and never widen; there is no host input;
/// nothing token-shaped is persisted.
///
/// The whole suite drives the real surfaces: the app-side routes through a real
/// `APIHandler` behind a loopback server on an ephemeral port, and the tools through
/// a real `MCPSession` whose registry is wired over the site's `control.json` — so
/// the JSON asserted on is the JSON the wire carries, formatter and output guard
/// included. Presence is the blocking double (no Touch ID), secrets are in memory,
/// and every TTL decision reads the injected clock, so no test sleeps past a bound.
final class MCPGrantTests: XCTestCase {

    private let fm = FileManager.default

    // MARK: - Rigs

    /// The one clock the store reads: tests move it, they never wait for it. The
    /// `expireAfterReads` seam is the expiry-window probe: once armed, the first
    /// `hold` reads answer the held instant and every read after answers one past
    /// the pending TTL, so the approval thread's live check and its approve flip
    /// land on opposite sides of an ask's expiry — deterministically, with no
    /// sleeping and no racing the mint.
    private final class Clock {
        private let lock = NSLock()
        private var instant: Date
        private var holdReads: Int?
        private var flippedTo: Date?
        private var reads = 0
        init(_ start: Date = Date(timeIntervalSinceReferenceDate: 700_000_000)) { instant = start }
        var current: Date {
            get {
                lock.lock(); defer { lock.unlock() }
                if let hold = holdReads {
                    reads += 1
                    return reads <= hold ? instant : flippedTo!
                }
                return instant
            }
            set { lock.lock(); instant = newValue; lock.unlock() }
        }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
        func expireAfterReads(_ hold: Int) {
            lock.lock()
            holdReads = hold
            flippedTo = instant.addingTimeInterval(MCPPendingGrants.ttl + 1)
            reads = 0
            lock.unlock()
        }
    }

    /// The in-process app: a real `APIHandler` over a temp catalog behind a loopback
    /// server on an ephemeral port, `control.json` beside the catalog naming it, and
    /// the grants tool group wired over that control file — exactly how `keys mcp`
    /// reaches the installed app (the ReadToolsTests rig). The blocking gate stands
    /// in for Touch ID; pre-releasing outcomes turns it into a scripted one, and its
    /// FIFO queue maps outcomes to prompts in create order because the create route
    /// answers only once its prompt has fired.
    private struct Site {
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let gate: BlockingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let control: URL
        let clock: Clock

        /// The site-wired roster: every production group over THIS site's control
        /// file, so the tools answer from THIS catalog and service. Building it
        /// runs the shared isolation guard first (inside `MCPRoster.registry`).
        func registry() throws -> MCPToolRegistry {
            try MCPRoster.registry(
                catalog: { db },
                control: control,
                fetchLatestRelease: { throw AppError.usage("the grant rig fetches no release") },
                projectFolder: { dir.path }
            )
        }
    }

    private func makeSite(
        gate: BlockingPresenceGate = BlockingPresenceGate(),
        clock: Clock = Clock(),
        gatewayOn: Bool = true
    ) throws -> Site {
        // The guarded world first: the control URL beside the catalog, with the
        // rig's fake secret stores, fail-closed-checked before any fixture, file
        // or socket operation runs.
        let secrets = MemorySecretStore()
        let relaySecrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let db = try CatalogDB(path: catalog)
        let service = KeysService(
            catalog: db,
            secrets: secrets,
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true),
            openRouter: OpenRouterHTTP(),
            relaySecrets: relaySecrets
        )
        service.mcpPendingGrants.inject(now: { clock.current })
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        if gatewayOn {
            // The gateway target cached, so a grant's prompt is the grant itself; the
            // fold path (gateway off) has its own variant below.
            _ = try service.setGateway(name: "demo", enabled: true, host: nil, presenceChecked: true)
        }
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        let site = Site(
            service: service, db: db, dir: dir, gate: gate, handler: handler,
            server: server, control: control, clock: clock
        )
        addTeardownBlock {
            gate.releaseAll(AppError.authCancelled)
            server.stop()
        }
        return site
    }

    /// A real folder under `dir`, which itself sits behind the `/var` →
    /// `/private/var` symlink, so every resolution exercises that spelling too.
    private func makeFolder(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One create through the real route, token-gated exactly as the app serves it.
    private func create(_ site: Site, _ body: [String: Any], token: Bool = true) throws -> HTTPResponse {
        handle(site.handler, method: "POST", path: "/api/mcp/grants", body: try JSONValue.data(body), token: token)
    }

    /// One poll of the app's status route as a caller that may or may not hold
    /// the ask's poll secret. The control token is always the site's own: the
    /// secret, not the token, is what separates the ask's creator from any other
    /// same-user process.
    private func poll(_ site: Site, _ id: String, secret: String = "", token: Bool = true) throws -> HTTPResponse {
        handle(site.handler, method: "POST", path: "/api/mcp/grants/\(id)/status",
               body: try JSONValue.data(["secret": secret]), token: token)
    }

    /// The no-id status listing, carrying the poll secrets the caller can prove.
    private func statusList(_ site: Site, secrets: [String] = []) throws -> HTTPResponse {
        handle(site.handler, method: "POST", path: "/api/mcp/grants/status",
               body: try JSONValue.data(["secrets": secrets]))
    }

    /// A random, secret-shaped wrong guess — runtime-built, never a committed
    /// literal, and never (statistically) the minted secret of any ask.
    private var wrongSecret: String { Hex.encode(SecureRandom.bytes(16)) }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    /// A well-formed create body over `site`'s own folder; `overrides` win.
    private func ask(_ site: Site, _ overrides: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "key": "demo", "task": "ship it", "minutes": 5, "methods": ["GET"],
            "paths": ["/v1/messages"], "folder": site.dir.path,
        ]
        for (key, value) in overrides { body[key] = value }
        return body
    }

    /// One tools/call through the real server frames — the surface the model sees,
    /// scrubber and output guard included.
    private func callTool(
        _ site: Site, name: String, arguments: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"\#(name)","arguments":\#(argumentsJSON)}}"#,
        ], registry: try site.registry())
        XCTAssertEqual(frames.last, "", file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    private func callToolJSON(
        _ site: Site, name: String, arguments: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let (isError, text) = try callTool(site, name: name, arguments: arguments, file: file, line: line)
        XCTAssertFalse(isError, "an unexpected tool error: \(text)", file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    /// Bounded wait for the store to settle `id` out of pending — the approval thread
    /// runs on a real queue, so the test watches the state instead of sleeping.
    private func waitSettled(_ site: Site, _ id: String, timeout: TimeInterval = 5) -> MCPPendingGrants.Record {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = site.service.mcpPendingGrants.snapshot(id: id) {
                if case .pending = record.resolution { Thread.sleep(forTimeInterval: 0.01); continue }
                return record
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("the request \(id) never settled")
        return site.service.mcpPendingGrants.snapshot(id: id)
            ?? MCPPendingGrants.Record(id: id, key: "", secret: "", createdAt: Date(), expiresAt: Date(),
                                       resolution: .expired, resolvedAt: Date(), deliveredAt: nil)
    }

    private func events(_ site: Site) throws -> [CatalogDB.KeyEventRow] {
        try site.db.keyEvents(name: "demo", limit: 50)
    }

    @discardableResult
    private func saveProfile(
        _ service: KeysService, name: String = "evals", keys: [String] = ["demo"],
        methods: Set<String> = ["GET", "POST"], paths: [String] = ["/v1/messages"],
        minutes: Int = 480, maxRequests: Int? = 500, maxUsd: Double? = 2.5, unattended: Bool = false
    ) throws -> Profile {
        try service.addProfile(ProfileRequest(
            name: name, keys: keys, methods: methods, paths: paths, minutes: minutes,
            maxRequests: maxRequests, maxUsd: maxUsd, unattended: unattended
        ))
    }

    /// A refusal's whole contract: no prompt consumed, no pending record left, no
    /// grant issued, no grant event audited.
    private func assertRefusalLeftNothing(
        _ site: Site, prompts: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(site.gate.recordedReasons.count, prompts, "a refusal consumed no prompt", file: file, line: line)
        XCTAssertTrue(site.service.mcpPendingGrants.statuses().isEmpty, "a refusal left no pending record", file: file, line: line)
        XCTAssertTrue(site.service.listGrants(includeInactive: true).isEmpty, "a refusal issued nothing", file: file, line: line)
        XCTAssertTrue(try site.db.keyEvents(name: "demo", limit: 50).filter { $0.action == "grant" }.isEmpty,
                      "a refusal audited nothing", file: file, line: line)
    }

    // MARK: VAL-GRANT-001 — pending immediately, tokenless, unique id

    /// With the presence gate blocking, `request_grant` answers within a bounded
    /// wait while the gate's `require` is entered and has not returned: pending,
    /// tokenless, an 8-hex id; three polls while approval is in flight all read
    /// pending with no state change.
    func testPendingImmediateAndTokenless() throws {
        let site = try makeSite()
        let started = Date()
        let answer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the call is bounded, never a hang")

        XCTAssertEqual(answer["status"] as? String, "pending")
        let id = answer["id"] as! String
        XCTAssertEqual(id.count, 8, "the id is the 8-hex convention")
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
        let secret = answer["secret"] as? String
        XCTAssertNotNil(secret, "the answer carries the ask's poll secret to its creator alone")
        XCTAssertEqual(Set(answer.keys), ["status", "id", "secret"], "the pending payload carries the ask and its proof, nothing else")
        XCTAssertFalse(String(decoding: try JSONValue.data(answer), as: UTF8.self).contains("ksf_"))
        XCTAssertEqual(site.gate.recordedReasons.count, 1, "the prompt went up before the answer")

        // Three polls while the prompt is still up: pending, tokenless, no change.
        for _ in 0..<3 {
            let pollAnswer = try callToolJSON(site, name: "grant_status",
                                              arguments: ["id": id, "secret": secret ?? ""])
            XCTAssertEqual(pollAnswer["status"] as? String, "pending")
            XCTAssertEqual(pollAnswer["id"] as? String, id)
            XCTAssertEqual(Set(pollAnswer.keys), ["status", "id"], "pending polls stay tokenless")
        }
        // Release only now: everything above held while require had not returned.
        site.gate.release()
        let settled = waitSettled(site, id)
        if case .approved = settled.resolution {} else {
            return XCTFail("the released prompt approved: \(settled.resolution)")
        }
    }

    // MARK: VAL-GRANT-002 — the create body carries the folder; the app owns the row

    /// The app canonicalizes the body's folder (symlinks resolved), derives the label
    /// and get-or-creates the projects row — including when the request is later
    /// denied. The MCP process never writes the row. (The tool surface always sends
    /// its own folder seam, so the folder-carrying body is driven at the route.)
    func testFolderCreatesProjectRow() throws {
        let site = try makeSite()
        let real = try makeFolder(site.dir, "realproj")
        let alias = site.dir.appendingPathComponent("aliasproj")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        site.gate.release()

        let created = try create(site, ask(site, ["folder": alias.path]))
        XCTAssertEqual(created.status, 200)
        let answer = try json(created)
        XCTAssertEqual(answer["status"] as? String, "pending")
        _ = waitSettled(site, answer["id"] as! String)

        let rows = try site.db.projects()
        XCTAssertEqual(rows.count, 1, "the create wrote exactly one project row")
        XCTAssertTrue(rows[0].path.hasPrefix("/private/var/"), "the /var spelling was canonicalized")
        XCTAssertNotEqual(rows[0].path, alias.path, "the alias spelling is never stored")
        XCTAssertEqual(rows[0].label, "realproj", "the label is the folder name")
        XCTAssertEqual(rows[0].path, try Project.canonicalFolder(real.path),
                       "the alias and the real path resolve to the one row")

        // The tool surface names its own project: a create through the frames leaves
        // the row the seam's folder resolves to, never one this process wrote itself.
        site.gate.release()
        let toolAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site, ["folder": alias.path]))
        _ = waitSettled(site, toolAnswer["id"] as! String)
        let after = try site.db.projects()
        XCTAssertEqual(after.count, 2, "the tool's own folder became the second row")
        XCTAssertEqual(after.last?.label, site.dir.lastPathComponent, "the seam's folder, not the body's")

        // The denied variant: the row exists even though the user said no.
        let deniedSite = try makeSite()
        deniedSite.gate.release(AppError.authCancelled)
        let denied = try create(deniedSite, ask(deniedSite, ["folder": alias.path]))
        XCTAssertEqual(try json(denied)["status"] as? String, "pending")
        let record = waitSettled(deniedSite, (try json(denied))["id"] as! String)
        if case .denied = record.resolution {} else {
            return XCTFail("the cancelled prompt denied the request: \(record.resolution)")
        }
        XCTAssertEqual(try deniedSite.db.projects().count, 1, "the projects row outlives the denial")
    }

    // MARK: VAL-GRANT-003 — the prompt names key, host and label, nothing else

    /// The recorded reason carries the key, the resolved host and the project's
    /// LABEL — the parent-qualified form on a collision, each flow showing its own
    /// project — and no absolute path, no token, no key value, and none of the
    /// decoys a caller can plant in the create body.
    func testPromptContent() throws {
        let site = try makeSite()
        let first = try makeFolder(site.dir, "A/proj")
        let second = try makeFolder(site.dir, "B/proj")
        site.gate.release()
        site.gate.release()

        let decoys: [String: Any] = ["label": "trust me", "host": "evil.example", "emoji": "🚀", "project": "/etc"]
        // The body carries the folders here (the tool seam always sends its own), so
        // the app's label derivation is what the reason shows.
        func askWithDecoys(_ folder: URL) -> [String: Any] {
            ask(site, ["folder": folder.path].merging(decoys) { current, _ in current })
        }
        let one = try json(create(site, askWithDecoys(first)))
        XCTAssertEqual(one["status"] as? String, "pending")
        _ = waitSettled(site, one["id"] as! String)
        let two = try json(create(site, askWithDecoys(second)))
        XCTAssertEqual(two["status"] as? String, "pending")
        _ = waitSettled(site, two["id"] as! String)

        let reasons = site.gate.recordedReasons
        XCTAssertEqual(reasons.count, 2, "one reason per request")
        for (reason, label) in zip(reasons, ["proj", "proj (B)"]) {
            XCTAssertTrue(reason.contains("the key demo"), "the reason names the key: \(reason)")
            XCTAssertTrue(reason.contains("api.openai.com"), "the reason names the resolved host: \(reason)")
            XCTAssertTrue(reason.contains("project \(label)"), "the reason names this flow's own label: \(reason)")
            XCTAssertFalse(reason.contains(site.dir.path), "no absolute project path: \(reason)")
            XCTAssertFalse(reason.contains("/Users/"), "no path fragments: \(reason)")
            XCTAssertFalse(reason.contains("ksf_"), "no token: \(reason)")
            XCTAssertFalse(reason.contains(fixtureSecret), "no key value: \(reason)")
            for decoy in ["trust me", "evil.example", "🚀"] {
                XCTAssertFalse(reason.contains(decoy), "a body decoy never reaches the prompt: \(reason)")
            }
            XCTAssertTrue(reason.contains("ship it"), "the agent's own task string does appear, by design")
        }
        XCTAssertFalse(reasons[0].contains("(B)"), "the first flow shows the unqualified label: \(reasons[0])")
    }

    // MARK: VAL-GRANT-004 — exactly one prompt per request, in every variant

    /// Create, approve, poll until approved, poll again: exactly one recorded
    /// reason — including when the gateway starts off and the prompt folds the
    /// enable in (gateway on afterwards, grant on the resolved host), under an
    /// unattended profile (one reason, the grant flagged), and for a denial.
    func testOnePromptPerRequest() throws {
        // Happy: polls and delivery never prompt.
        let happy = try makeSite()
        happy.gate.release()
        let happyAnswer = try callToolJSON(happy, name: "request_grant", arguments: ask(happy))
        let id = happyAnswer["id"] as! String
        let secret = happyAnswer["secret"] as? String ?? ""
        _ = waitSettled(happy, id)
        _ = try callToolJSON(happy, name: "grant_status", arguments: ["id": id, "secret": secret])
        _ = try callToolJSON(happy, name: "grant_status", arguments: ["id": id, "secret": secret])
        _ = try callToolJSON(happy, name: "grant_status", arguments: ["id": id, "secret": secret])
        XCTAssertEqual(happy.gate.recordedReasons.count, 1, "one prompt for the whole happy flow")

        // Gateway off: the one prompt turns it on and issues, same count.
        let folded = try makeSite(gatewayOn: false)
        folded.gate.release()
        let foldedAnswer = try callToolJSON(folded, name: "request_grant", arguments: ask(folded))
        let foldedRecord = waitSettled(folded, foldedAnswer["id"] as! String)
        XCTAssertEqual(folded.gate.recordedReasons.count, 1, "the enable folded into the one prompt")
        XCTAssertNotNil(folded.service.lookupGateway(name: "demo"), "the gateway is on afterwards")
        guard case .approved(_, let grant) = foldedRecord.resolution else {
            return XCTFail("the folded flow approved")
        }
        XCTAssertEqual(grant.host, "api.openai.com", "the grant targets the resolved host")

        // Unattended profile: one reason, and the issued grant is flagged.
        let unattended = try makeSite()
        try saveProfile(unattended.service, unattended: true)
        unattended.gate.release()
        let unattendedAnswer = try callToolJSON(unattended, name: "request_grant", arguments: ask(unattended, ["profile": "evals"]))
        let unattendedRecord = waitSettled(unattended, unattendedAnswer["id"] as! String)
        XCTAssertEqual(unattended.gate.recordedReasons.count, 1)
        guard case .approved(_, let unattendedGrant) = unattendedRecord.resolution else {
            return XCTFail("the unattended flow approved")
        }
        XCTAssertTrue(unattendedGrant.unattended, "the grant reports the profile's flag")

        // Denial: one prompt, and later polls add none.
        let denied = try makeSite()
        denied.gate.release(AppError.authCancelled)
        let deniedAnswer = try callToolJSON(denied, name: "request_grant", arguments: ask(denied))
        let deniedRecord = waitSettled(denied, deniedAnswer["id"] as! String)
        if case .denied("cancelled") = deniedRecord.resolution {} else {
            return XCTFail("the cancelled prompt denied the request")
        }
        let deniedArguments = ["id": deniedAnswer["id"] as! String, "secret": deniedAnswer["secret"] as? String ?? ""]
        _ = try callToolJSON(denied, name: "grant_status", arguments: deniedArguments)
        _ = try callToolJSON(denied, name: "grant_status", arguments: deniedArguments)
        XCTAssertEqual(denied.gate.recordedReasons.count, 1, "a denial consumed exactly one prompt")
    }

    // MARK: VAL-GRANT-005 — approved payload parity with keysGrant

    /// The approved poll carries the grant fields plus the connection fields in the
    /// exact `keysGrant` formats, field-compatible with a `keysGrant` body for the
    /// same ask.
    func testApprovedPayloadParity() throws {
        let site = try makeSite()
        site.gate.release()
        site.gate.release()
        let ask = ask(site, ["max_requests": 3])

        let answer = try callToolJSON(site, name: "request_grant", arguments: ask)
        let id = answer["id"] as! String
        let secret = answer["secret"] as? String ?? ""
        _ = waitSettled(site, id)
        let approved = try callToolJSON(site, name: "grant_status", arguments: ["id": id, "secret": secret])
        XCTAssertEqual(approved["status"] as? String, "approved")
        let token = approved["token"] as! String
        XCTAssertTrue(GrantToken.looksLikeToken(token))
        XCTAssertEqual(approved["base_url"] as? String, "http://127.0.0.1:12767/demo/v1")
        XCTAssertEqual(approved["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
        XCTAssertEqual(approved["auth_header"] as? String, "Authorization")
        let source = approved["response_source"] as? String ?? ""
        XCTAssertTrue(source.contains(GatewayListener.sourceHeader), source)
        XCTAssertTrue(source.contains("upstream") && source.contains("not that the grant was refused"), source)

        // The same ask through the dashboard route, for parity.
        let dashBody: [String: Any] = ["task": "ship it", "minutes": 5, "methods": ["GET"], "paths": ["/v1/messages"], "max_requests": 3]
        let dash = handle(site.handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(dashBody))
        XCTAssertEqual(dash.status, 201)
        let dashJSON = try json(dash)

        for field in ["key", "provider", "host", "task", "methods", "paths", "max_requests",
                      "max_usd", "profile", "unattended", "window_minutes", "base_url", "gateway_url", "auth_header"] {
            let approvedValue = approved[field] ?? NSNull()
            let dashValue = dashJSON[field] ?? NSNull()
            XCTAssertEqual("\(approvedValue)", "\(dashValue)", "\(field) matches the keysGrant body")
        }
        XCTAssertEqual(approved["window_minutes"] as? Int, 5)
        XCTAssertNotEqual(approved["id"] as? String, dashJSON["id"] as? String, "each issuance is its own grant")
    }

    // MARK: VAL-GRANT-006 — the token is delivered on exactly one poll, then dropped

    /// The first approved poll carries the token (and the guard's one handover lets
    /// it through); every later poll reports approved with delivered:true and no
    /// token key; the store's record holds no token after delivery.
    func testTokenDeliveredOnce() throws {
        let site = try makeSite()
        site.gate.release()
        let created = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let id = created["id"] as! String
        let secret = created["secret"] as? String ?? ""
        _ = waitSettled(site, id)

        // The first claim — through the real tool frames, guard included: the token
        // is on the wire exactly here.
        let first = try callTool(site, name: "grant_status", arguments: ["id": id, "secret": secret])
        XCTAssertFalse(first.isError, first.text)
        let approved = try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as! [String: Any]
        XCTAssertEqual(approved["status"] as? String, "approved")
        let token = approved["token"] as! String
        XCTAssertTrue(GrantToken.looksLikeToken(token))

        // Every later poll: the pinned tokenless shape.
        var tokenBearers = 1
        for _ in 0..<3 {
            let later = try callToolJSON(site, name: "grant_status", arguments: ["id": id, "secret": secret])
            XCTAssertEqual(later["status"] as? String, "approved")
            XCTAssertEqual(later["delivered"] as? Bool, true)
            XCTAssertEqual(Set(later.keys), ["status", "id", "delivered"], "no token, no stale connection fields")
            if later.keys.contains("token") { tokenBearers += 1 }
        }
        XCTAssertEqual(tokenBearers, 1, "exactly one poll was token-bearing")

        // White-box: the stored entry carries no token after the delivery.
        let record = site.service.mcpPendingGrants.snapshot(id: id)!
        if case .delivered = record.resolution {} else {
            return XCTFail("the record is delivered, not token-holding: \(record.resolution)")
        }
        // And the delivered state's own listing entry carries no token either.
        let listing = try json(statusList(site, secrets: [secret]))
        let entry = (listing["requests"] as! [[String: Any]]).first { $0["id"] as? String == id }
        XCTAssertNotNil(entry, "the proven listing still names the delivered ask")
        XCTAssertNil(entry?["token"], "a delivered ask never lists a token")
    }

    // MARK: VAL-GRANT-007 — the delivered token works on the gateway

    /// The token from the approved poll authorizes like any grant token: in-scope
    /// 200s, out-of-scope refusals, caps enforcing — all through the unchanged
    /// `GrantStore.authorize` path.
    func testDeliveredTokenWorks() async throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key("demo", provider: "openai")
        let web = rig.dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: rig.service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        addTeardownBlock { server.stop() }
        let control = ControlFile.url(beside: rig.db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control, launch: .neverLaunching)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let created = handle(handler, method: "POST", path: "/api/mcp/grants", body: try JSONValue.data(
            ["key": "demo", "task": "calls", "methods": ["GET"], "paths": ["/models"], "max_requests": 2,
             "folder": rig.dir.path]
        ))
        XCTAssertEqual(created.status, 200)
        let createdAnswer = try json(created)
        let id = createdAnswer["id"] as! String
        let secret = createdAnswer["secret"] as? String ?? ""
        let deadline = Date().addingTimeInterval(5)
        var approved = [String: Any]()
        while Date() < deadline {
            approved = try json(handle(handler, method: "POST", path: "/api/mcp/grants/\(id)/status",
                                          body: try JSONValue.data(["secret": secret])))
            if approved["status"] as? String == "approved" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(approved["status"] as? String, "approved")
        let token = approved["token"] as! String

        func call(_ path: String, method: String = "GET") async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rig.gateway.boundPort)\(path)")!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }

        let (inScope, _) = try await call("/demo/v1/models")
        XCTAssertEqual(inScope, 200, "an in-scope call passes")
        let (inScope2, _) = try await call("/demo/v1/models")
        XCTAssertEqual(inScope2, 200)
        let (capped, capBody) = try await call("/demo/v1/models")
        XCTAssertEqual(capped, 429, "the request cap enforces like any grant")
        XCTAssertEqual(capBody["error"] as? String, "grant_request_limit")
        let (badMethod, methodBody) = try await call("/demo/v1/models", method: "POST")
        XCTAssertEqual(badMethod, 403)
        XCTAssertEqual(methodBody["error"] as? String, "grant_method_not_allowed")
        let (badPath, pathBody) = try await call("/demo/v1/chat")
        XCTAssertEqual(badPath, 403)
        XCTAssertEqual(pathBody["error"] as? String, "grant_path_not_allowed")
    }

    // MARK: VAL-GRANT-008 — denied states and reasons

    /// Cancelled, failed and unavailable presence each end the request denied with
    /// its reason, terminal and tokenless, with no grant row; polls keep the state.
    func testDeniedMapping() throws {
        let site = try makeSite()
        site.gate.release(AppError.authCancelled)
        site.gate.release(AppError.authFailed)
        site.gate.release(AppError.authUnavailable("no Touch ID session"))

        var asks = [(id: String, secret: String)]()
        for _ in 0..<3 {
            let answer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
            XCTAssertEqual(answer["status"] as? String, "pending")
            asks.append((answer["id"] as! String, answer["secret"] as? String ?? ""))
        }
        let expected = zip(asks, ["cancelled", "failed", "unavailable"])
        for (ask, reason) in expected {
            let record = waitSettled(site, ask.id)
            if case .denied(let got) = record.resolution {
                XCTAssertEqual(got, reason)
            } else {
                return XCTFail("the request \(ask.id) denied: \(record.resolution)")
            }
            for _ in 0..<2 {
                let pollAnswer = try callToolJSON(site, name: "grant_status",
                                                   arguments: ["id": ask.id, "secret": ask.secret])
                XCTAssertEqual(pollAnswer["status"] as? String, "denied")
                XCTAssertEqual(pollAnswer["reason"] as? String, reason)
                XCTAssertEqual(Set(pollAnswer.keys), ["status", "id", "reason"], "the denial is tokenless and final")
            }
        }
        XCTAssertTrue(site.service.listGrants(includeInactive: true).isEmpty, "no grant row was minted")
    }

    // MARK: VAL-GRANT-009 — the 300 s TTL, the injected clock, expiry fails closed

    /// The TTL is one constant (300 s) off the injected clock; the grant's own
    /// minutes ride independently; an expired ask reports expired with no grant row
    /// and no event, and an approval that lands after the TTL never issues.
    func testTTLCluster() throws {
        // The constant and the record's arithmetic.
        let site = try makeSite()
        site.gate.release()
        let id = (try callToolJSON(site, name: "request_grant", arguments: ask(site)))["id"] as! String
        let record = site.service.mcpPendingGrants.snapshot(id: id)!
        XCTAssertEqual(record.expiresAt.timeIntervalSince(record.createdAt), MCPPendingGrants.ttl)
        XCTAssertEqual(MCPPendingGrants.ttl, 300, "the pending TTL is the one pinned constant")
        _ = waitSettled(site, id)
        guard case .approved(_, let grant) = site.service.mcpPendingGrants.snapshot(id: id)!.resolution else {
            return XCTFail("the ask approved")
        }
        XCTAssertEqual(grant.windowMinutes, 5, "minutes: 5 yields a 5-minute grant")

        // The grant window is independent of the pending TTL, at both ends. The ask
        // without minutes defaults to the model's 30.
        var defaulted = ask(site)
        defaulted.removeValue(forKey: "minutes")
        let windowAsks: [([String: Any], Int)] = [(ask(site, ["minutes": 1440]), 1440), (defaulted, 30)]
        for (askBody, expected) in windowAsks {
            site.gate.release()
            let answer = try callToolJSON(site, name: "request_grant", arguments: askBody)
            let settled = waitSettled(site, answer["id"] as! String)
            guard case .approved(_, let wide) = settled.resolution else {
                return XCTFail("the \(expected)-minute ask approved")
            }
            XCTAssertEqual(wide.windowMinutes, expected,
                           "the grant window follows the ask, the pending TTL stays 300 s")
            _ = try callToolJSON(site, name: "grant_status",
                                 arguments: ["id": answer["id"] as! String, "secret": answer["secret"] as? String ?? ""])
        }

        // Expiry fails closed: expired, tokenless, no row, no grant event.
        let expiring = try makeSite()
        let expiringAnswer = try callToolJSON(expiring, name: "request_grant", arguments: ask(expiring))
        XCTAssertEqual(expiringAnswer["status"] as? String, "pending")
        expiring.clock.advance(MCPPendingGrants.ttl + 1)
        let expired = try callToolJSON(expiring, name: "grant_status",
                                       arguments: ["id": expiringAnswer["id"] as! String,
                                                   "secret": expiringAnswer["secret"] as? String ?? ""])
        XCTAssertEqual(expired["status"] as? String, "expired")
        XCTAssertEqual(Set(expired.keys), ["status", "id"], "the expired answer is tokenless")
        XCTAssertTrue(expiring.service.listGrants(includeInactive: true).isEmpty, "no GrantStore row")
        XCTAssertTrue(try expiring.db.keyEvents(name: "demo", limit: 50).filter { $0.action == "grant" }.isEmpty,
                     "no grant event")

        // Approving after the TTL never issues: the prompt is still up when the ask
        // expires, and its late approval changes nothing.
        expiring.gate.release()
        let late = waitSettled(expiring, expiringAnswer["id"] as! String)
        if case .expired = late.resolution {} else {
            return XCTFail("the late approval did not mint and the state stayed expired: \(late.resolution)")
        }
        let after = try callToolJSON(expiring, name: "grant_status",
                                     arguments: ["id": expiringAnswer["id"] as! String,
                                                 "secret": expiringAnswer["secret"] as? String ?? ""])
        XCTAssertEqual(after["status"] as? String, "expired", "never approved, never a token")
        XCTAssertTrue(expiring.service.listGrants(includeInactive: true).isEmpty)
        XCTAssertTrue(try expiring.db.keyEvents(name: "demo", limit: 50).filter { $0.action == "grant" }.isEmpty)
    }

    // MARK: VAL-GRANT-010 — unknown ids and the no-id form

    /// An unknown, malformed or pruned id is the house not-found; the no-id form is
    /// the status-only listing, never a token in any state.
    func testGrantStatusInputs() throws {
        let site = try makeSite()
        site.gate.release()
        site.gate.release(AppError.authCancelled)

        // Unknown id at the tool surface: the house not-found, scrubbed. The poll
        // carries a secret — any secret — because the id's existence is the app's
        // to answer, and only a proven ask could read a real state.
        let unknown = try callTool(site, name: "grant_status",
                                   arguments: ["id": "0badf00d", "secret": wrongSecret])
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.text, "not found: pending grant request 0badf00d")
        // Malformed: the tool refuses without building a broken path.
        let malformed = try callTool(site, name: "grant_status", arguments: ["id": "zz"])
        XCTAssertTrue(malformed.isError)
        XCTAssertEqual(malformed.text, "grant_status takes the request's 8-character id")
        // The route's own shape.
        let missing = try poll(site, "0badf00d")
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(try json(missing)["error"] as? String, "not_found")

        // Two settled requests: one approved (delivered by the poll below), one denied.
        let approvedAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let approvedRecord = waitSettled(site, approvedAnswer["id"] as! String)
        guard case .approved = approvedRecord.resolution else { return XCTFail("the first ask approved") }
        _ = try callToolJSON(site, name: "grant_status",
                             arguments: ["id": approvedAnswer["id"] as! String,
                                         "secret": approvedAnswer["secret"] as? String ?? ""])
        let deniedAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        _ = waitSettled(site, deniedAnswer["id"] as! String)

        // The no-id form across states, seen by a caller holding both secrets:
        // never a token, in any state.
        let listing = try callToolJSON(site, name: "grant_status", arguments: [
            "secrets": [approvedAnswer["secret"] as? String ?? "", deniedAnswer["secret"] as? String ?? ""],
        ])
        let requests = listing["requests"] as! [[String: Any]]
        XCTAssertEqual(requests.count, 2, "the listing shows both proven requests")
        var states = Set<String>()
        for entry in requests {
            states.insert(entry["status"] as! String)
            XCTAssertNotNil(entry["id"], "each entry names its request")
            XCTAssertNotNil(entry["key"], "each entry names its key")
            XCTAssertFalse(entry.keys.contains("token"), "the listing never carries a token")
            if let delivered = entry["delivered"] as? Bool { XCTAssertTrue(delivered) }
            if let reason = entry["reason"] as? String { XCTAssertEqual(reason, "cancelled") }
        }
        XCTAssertEqual(states, ["approved", "denied"], "the two settled requests show their states")
        let frame = String(decoding: try JSONValue.data(listing), as: UTF8.self)
        XCTAssertFalse(frame.contains("ksf_"), "no token shape anywhere in the listing")

        // A consumed-then-pruned id: retention passes, the honest not_found —
        // the poll carries its own secret, so the prune is the only reason.
        site.clock.advance(MCPPendingGrants.retention + 1)
        let pruned = try poll(site, approvedAnswer["id"] as! String,
                              secret: approvedAnswer["secret"] as? String ?? "")
        XCTAssertEqual(pruned.status, 404, "a pruned id is not_found, never a zombie state")
    }

    // MARK: VAL-G-002 — a lapsed approval revokes what it minted

    /// An approval that lands in the window between issuance's last live check
    /// and the record's flip must not strand the just-minted grant: `approve`
    /// re-checks the ask's expiry under its lock, settles the ask expired exactly
    /// as a poll would, and the approval thread revokes the grant it just minted
    /// through the house revoke path. The armed fake clock lands the approval
    /// thread's two reads on opposite sides of the expiry — the mint still
    /// happens, the flip lands past the TTL.
    func testApprovalLandingPastTheAskExpiryRevokesTheMintedGrantInsteadOfStrandingIt() throws {
        let site = try makeSite()
        // The ask is created while the clock reads its held instant, and the
        // approval thread is parked inside its prompt.
        let created = try json(create(site, ask(site)))
        XCTAssertEqual(created["status"] as? String, "pending")
        let id = created["id"] as! String
        let secret = created["secret"] as! String

        // Arm the window: the approval thread's first read after the release is
        // issuance's live check — still live at the held instant — and every
        // read after, approve's flip among them, answers one past the ask's TTL.
        site.clock.expireAfterReads(1)
        site.gate.release()

        // The mint's audit row is the signal that issuance's live check passed:
        // it is awaited without touching the store's clock, so the armed flip is
        // left for the flip itself (approve's, or a poll's — both are the fix's).
        let mintDeadline = Date().addingTimeInterval(5)
        var minted = false
        while Date() < mintDeadline {
            minted = try site.db.keyEvents(name: "demo", limit: 50).contains { $0.action == "grant" }
            if minted { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(minted, "the lapsed ask still minted — issuance's live check read the held instant")

        let settled = waitSettled(site, id)
        if case .expired = settled.resolution {} else {
            return XCTFail("the ask that lapsed at its approval reads expired: \(settled.resolution)")
        }

        // The just-minted grant is the approval thread's to revoke: a bounded
        // wait for the revoke, then the pinned state — not a live row living out
        // its window on the dashboard with no caller left who may claim it.
        let deadline = Date().addingTimeInterval(5)
        var row: Grant?
        while Date() < deadline {
            row = site.service.listGrants(includeInactive: true).first
            if row?.revokeReason != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(row?.revokeReason, "revoked", "the just-minted grant is revoked, not stranded")
        XCTAssertTrue(site.service.listGrants().isEmpty, "nothing stays live from a lapsed ask")

        // The revoke went through the house path: the mint and the revoke are
        // each audited exactly once, the caller pinned to mcp.
        let events = try site.db.keyEvents(name: "demo", limit: 50)
        XCTAssertEqual(events.filter { $0.action == "grant" }.count, 1, "the mint is audited once")
        let revokes = events.filter { $0.action == "grant_revoke" }
        XCTAssertEqual(revokes.count, 1, "the revoke of the lapsed ask's grant is audited")
        XCTAssertEqual(revokes.first?.caller, "mcp", "the caller is pinned to mcp")

        // And the claim still answers the honest expired state, tokenless.
        let answer = try json(poll(site, id, secret: secret))
        XCTAssertEqual(answer["status"] as? String, "expired")
        XCTAssertEqual(Set(answer.keys), ["status", "id"], "the expired answer is tokenless")
    }

    // MARK: VAL-G-001 — the poll secret binds the claim to the creator

    /// The create answer carries a random poll secret, and only its creator can
    /// collect the token: a second client that holds the control token and the
    /// ask's id but not the secret reads the house not-found in every state —
    /// pending and approved alike — and its polls never consume the claim, so
    /// the creator still receives the token. The secret reaches no notification
    /// and no file under the site's own directory.
    func testSecondClientWithoutThePollSecretGetsNoTokenAndTheCreatorStillReceivesIt() throws {
        let site = try makeSite()
        // The pending-ask warning is delivered for real, so the secret's absence
        // from the notification surface is asserted on the exact payload.
        let delivery = RecordingNotificationDelivery()
        site.service.notifications = AppNotifier(
            preferences: AppPreferences(catalog: site.db),
            authorizer: RecordingNotificationAuthorizer(),
            delivery: delivery,
            clock: { Date() }
        )

        // The creator's ask: pending immediately, carrying the poll secret.
        let created = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        XCTAssertEqual(created["status"] as? String, "pending")
        let id = created["id"] as! String
        let secret = created["secret"] as? String
        XCTAssertNotNil(secret, "the create answer carries the ask's poll secret")
        let pollSecret = secret ?? ""
        XCTAssertNotEqual(pollSecret, id, "the secret is not the id restated")
        XCTAssertEqual(pollSecret.count, 32, "the secret is the 32-hex shape")
        XCTAssertTrue(pollSecret.allSatisfy { $0.isHexDigit }, "the secret is hex, like the ids")
        XCTAssertEqual(Set(created.keys), ["status", "id", "secret"], "the pending payload carries the ask and its proof")

        // While the prompt is still up: a second client — same control token,
        // the id, no secret — reads the house not-found, not a pending state.
        let blind = try poll(site, id)
        XCTAssertEqual(blind.status, 404, "a poll without the secret learns nothing, not even that the id exists")
        XCTAssertEqual(try json(blind)["error"] as? String, "not_found")
        let guessed = try poll(site, id, secret: wrongSecret)
        XCTAssertEqual(guessed.status, 404, "a wrong secret reads the same not-found")
        XCTAssertEqual(try json(guessed)["error"] as? String, "not_found")
        // The tool surface refuses the same client before any round trip.
        let refused = try callTool(site, name: "grant_status", arguments: ["id": id])
        XCTAssertTrue(refused.isError, "a poll that cannot prove its ask is a tool error")
        XCTAssertEqual(refused.text, "grant_status takes the poll secret from the request_grant answer")
        // The creator still reads the real state.
        let own = try json(poll(site, id, secret: pollSecret))
        XCTAssertEqual(own["status"] as? String, "pending")
        XCTAssertEqual(Set(own.keys), ["status", "id"], "pending polls stay tokenless")

        // Approve, then the second client polls the approved id first: no
        // token, no consumption.
        site.gate.release()
        let settled = waitSettled(site, id)
        guard case .approved = settled.resolution else {
            return XCTFail("the released prompt approved: \(settled.resolution)")
        }
        let blindApproved = try poll(site, id)
        XCTAssertEqual(blindApproved.status, 404, "an approved id without the secret still answers not-found")
        let guessedApproved = try poll(site, id, secret: wrongSecret)
        XCTAssertEqual(guessedApproved.status, 404, "a wrong secret on the approved id answers not-found")
        let afterGuess = site.service.mcpPendingGrants.snapshot(id: id)!
        if case .approved = afterGuess.resolution {} else {
            return XCTFail("the unproven polls never consumed the claim: \(afterGuess.resolution)")
        }

        // The creator still receives the token — through the real tool frames,
        // guard included — and a later poll reads the pinned delivered shape.
        let first = try callTool(site, name: "grant_status", arguments: ["id": id, "secret": pollSecret])
        XCTAssertFalse(first.isError, first.text)
        let approved = try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as! [String: Any]
        XCTAssertEqual(approved["status"] as? String, "approved")
        let token = approved["token"] as? String
        XCTAssertNotNil(token, "the creator's poll is the one that collects")
        XCTAssertTrue(token.map(GrantToken.looksLikeToken) ?? false, "the gateway's own token shape")
        let later = try json(poll(site, id, secret: pollSecret))
        XCTAssertEqual(later["status"] as? String, "approved")
        XCTAssertEqual(later["delivered"] as? Bool, true)
        XCTAssertEqual(Set(later.keys), ["status", "id", "delivered"], "the token never crosses twice")

        // The secret reaches no notification payload and no file on disk.
        if let pollSecret = secret {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, delivery.count < 1 { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertEqual(delivery.notifications.map(\.kind), [.pendingGrant], "the pending ask warned once")
            for note in delivery.notifications {
                let payload = "\(note.identifier)\n\(note.title)\n\(note.body)"
                XCTAssertFalse(payload.contains(pollSecret), "the notification payload carries no poll secret")
            }
            assertNoSentinel(pollSecret, in: site.dir)
        }
    }

    /// The no-id listing returns only the ids the request body proves with their
    /// poll secrets — a caller that proves nothing lists nothing, a caller that
    /// proves one secret sees one ask — and never carries a secret of its own.
    func testNoIdListingReturnsOnlyIdsTheCallerProvesAndLeaksNeitherIdsNorSecrets() throws {
        let site = try makeSite()
        site.gate.release()
        site.gate.release(AppError.authCancelled)

        // Two asks from two creators: one approved, one denied.
        let firstAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let firstID = firstAnswer["id"] as! String
        let firstSecret = firstAnswer["secret"] as? String
        XCTAssertNotNil(firstSecret, "the create answer carries the secret")
        _ = waitSettled(site, firstID)
        let secondAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let secondID = secondAnswer["id"] as! String
        let secondSecret = secondAnswer["secret"] as? String
        XCTAssertNotNil(secondSecret, "the create answer carries the secret")
        _ = waitSettled(site, secondID)
        let provenFirst = firstSecret ?? ""
        let provenSecond = secondSecret ?? ""

        // A caller that proves nothing lists nothing — at the route and the tool.
        let emptyRoute = try json(statusList(site))
        XCTAssertEqual((emptyRoute["requests"] as? [[String: Any]])?.count, 0, "an unproving listing is empty")
        let emptyTool = try callToolJSON(site, name: "grant_status", arguments: [:])
        XCTAssertEqual((emptyTool["requests"] as? [[String: Any]])?.count, 0, "the tool's unproving listing is empty")
        let wrong = try callToolJSON(site, name: "grant_status", arguments: ["secrets": [wrongSecret]])
        XCTAssertEqual((wrong["requests"] as? [[String: Any]])?.count, 0, "a wrong secret proves nothing")

        // The first creator's secret lists exactly the first ask — the second
        // id never crosses, and no secret crosses in either direction.
        let listing = try callToolJSON(site, name: "grant_status", arguments: ["secrets": [provenFirst]])
        let requests = listing["requests"] as! [[String: Any]]
        XCTAssertEqual(requests.map { $0["id"] as! String }, [firstID], "only the proven ask is listed")
        XCTAssertEqual(requests[0]["status"] as? String, "approved")
        XCTAssertFalse(requests[0].keys.contains("secret"), "a listing entry never carries a secret")
        let frame = String(decoding: try JSONValue.data(listing), as: UTF8.self)
        XCTAssertFalse(frame.contains(provenFirst), "the listing answer leaks no secret")
        XCTAssertFalse(frame.contains(provenSecond), "the listing answer leaks no secret")
        XCTAssertFalse(frame.contains("ksf_"), "no token shape anywhere in the listing")

        // The second creator's secret lists exactly the denied ask, reason and all.
        let deniedListing = try json(statusList(site, secrets: [provenSecond]))
        let deniedRequests = deniedListing["requests"] as! [[String: Any]]
        XCTAssertEqual(deniedRequests.map { $0["id"] as! String }, [secondID])
        XCTAssertEqual(deniedRequests[0]["status"] as? String, "denied")
        XCTAssertEqual(deniedRequests[0]["reason"] as? String, "cancelled")
        // And a caller holding both secrets lists both, states only.
        let both = try json(statusList(site, secrets: [provenFirst, provenSecond]))
        let bothIDs = ((both["requests"] as? [[String: Any]])?.map { $0["id"] as! String }) ?? []
        XCTAssertEqual(bothIDs.sorted(), [firstID, secondID].sorted(), "both proven asks list")
    }

    // MARK: VAL-GRANT-011 — nothing token-shaped is ever persisted

    /// After the full flow — create, approve, deliver, extra polls, plus the denial
    /// and expiry variants — a recursive byte scan of the catalog directory finds
    /// zero occurrences of the delivered token's bytes, and of the poll secret's.
    func testNothingTokenShapedPersisted() throws {
        let site = try makeSite()
        site.gate.release()
        site.gate.release(AppError.authCancelled)

        let created = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let id = created["id"] as! String
        let secret = try XCTUnwrap(created["secret"] as? String, "the create answer carries the poll secret")
        _ = waitSettled(site, id)
        let approved = try callToolJSON(site, name: "grant_status", arguments: ["id": id, "secret": secret])
        let token = approved["token"] as! String
        _ = try callToolJSON(site, name: "grant_status", arguments: ["id": id, "secret": secret])

        // A denial variant on the same catalog.
        let denied = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        _ = waitSettled(site, denied["id"] as! String)

        // An expiry variant on the same catalog: no third prompt is queued, so the
        // ask expires with its prompt still up, exactly the honest edge.
        let expiring = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        site.clock.advance(MCPPendingGrants.ttl + 1)
        let expired = try callToolJSON(site, name: "grant_status",
                                       arguments: ["id": expiring["id"] as! String,
                                                   "secret": expiring["secret"] as? String ?? ""])
        XCTAssertEqual(expired["status"] as? String, "expired")

        assertNoSentinel(token, in: site.dir)
        assertNoSentinel(secret, in: site.dir)
    }

    // MARK: VAL-GRANT-012 — the audit trail: caller "mcp", no phantom events

    /// An approved MCP issuance records exactly one grant event with the dashboard's
    /// detail shape and the caller pinned to "mcp"; a denial, an expiry and a
    /// synchronous refusal each leave the table alone. Neither the token nor the
    /// ask's poll secret ever reaches the detail.
    func testAuditTrail() throws {
        let site = try makeSite()
        XCTAssertTrue(try events(site).filter { $0.action == "grant" }.isEmpty)

        site.gate.release()
        let created = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let id = created["id"] as! String
        let secret = try XCTUnwrap(created["secret"] as? String, "the create answer carries the poll secret")
        let settled = waitSettled(site, id)
        guard case .approved(let token, let grant) = settled.resolution else {
            return XCTFail("the ask approved")
        }
        let rows = try events(site).filter { $0.action == "grant" }
        XCTAssertEqual(rows.count, 1, "exactly one grant event, no phantom rows")
        XCTAssertEqual(rows[0].action, "grant")
        XCTAssertEqual(rows[0].caller, "mcp", "the caller is pinned to mcp")
        XCTAssertEqual(rows[0].detail, KeysService.grantDetail(grant), "the dashboard detail shape")
        XCTAssertNil(rows[0].detail?.range(of: token), "the token never reaches the events table")
        XCTAssertNil(rows[0].detail?.range(of: secret), "the poll secret never reaches the events table")

        // A denial, an expiry and a synchronous refusal: no further rows.
        site.gate.release(AppError.authCancelled)
        let denied = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        _ = waitSettled(site, denied["id"] as! String)
        let expiring = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        site.clock.advance(MCPPendingGrants.ttl + 1)
        _ = try callToolJSON(site, name: "grant_status",
                             arguments: ["id": expiring["id"] as! String,
                                         "secret": expiring["secret"] as? String ?? ""])
        let refused = try callTool(site, name: "request_grant", arguments: ask(site, ["key": "nope"]))
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(try events(site).filter { $0.action == "grant" }.count, 1, "nothing else audited")
    }

    // MARK: VAL-GRANT-013 — synchronous refusals: key, provider, host

    /// Unknown key, a gateway:false provider and an unresolvable host each come back
    /// from `request_grant` itself as a plain tool error, with no prompt, no pending
    /// record, no grant and no event.
    func testRefusalsKeyProviderHost() throws {
        let site = try makeSite()
        try site.service.add(name: "bedrock-key", provider: "bedrock", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try site.service.addProvider(id: "mycustom", name: "My Custom", host: nil, api: "other")
        try site.service.add(name: "myhostless", provider: "mycustom", kind: "runtime", notes: "", secret: fixtureSecret)

        let cases: [(String, [String: Any], String)] = [
            ("unknown key", ask(site, ["key": "nope"]), "not found: nope"),
            ("non-proxiable provider", ask(site, ["key": "bedrock-key"]),
             "gateway is not available for provider bedrock; a grant cannot be issued"),
            ("unresolvable host", ask(site, ["key": "myhostless"]),
             "set a gateway host for myhostless first (this provider has one host per account)"),
        ]
        for (label, body, message) in cases {
            let (isError, text) = try callTool(site, name: "request_grant", arguments: body)
            XCTAssertTrue(isError, "\(label) is a plain tool error")
            XCTAssertEqual(text, message, "\(label) carries the house wording")
            try assertRefusalLeftNothing(site, prompts: 0)
        }
    }

    // MARK: VAL-GRANT-014 — synchronous refusals: request validation

    /// Minutes out of range (and non-integer), empty or unknown methods, invalid
    /// paths (the raw quoted back through the scrubber), bad caps and an over-long
    /// task all refuse before any prompt; an empty task defaults and issues.
    func testRefusalsRequestValidation() throws {
        let site = try makeSite()
        let cases: [(String, [String: Any], String)] = [
            ("minutes 0", ["minutes": 0], "minutes must be between 1 and 1440"),
            ("minutes negative", ["minutes": -5], "minutes must be between 1 and 1440"),
            ("minutes over", ["minutes": 1441], "minutes must be between 1 and 1440"),
            ("minutes non-integer", ["minutes": "five"], "minutes must be between 1 and 1440"),
            ("no methods", ["methods": []], "at least one method is required"),
            ("unknown method", ["methods": ["FOO"]], "unknown method FOO"),
            ("query path", ["paths": ["/a?b"]], "invalid path /a?b"),
            ("dot-segment path", ["paths": ["v1/../x"]], "invalid path v1/../x"),
            ("space path", ["paths": ["/v1 two words"]], "invalid path /v1 two words"),
            ("zero cap", ["max_requests": 0], "max requests must be at least 1"),
            ("zero usd", ["max_usd": 0], "max usd must be positive"),
            ("negative usd", ["max_usd": -1], "max usd must be positive"),
            ("long task", ["task": String(repeating: "t", count: 121)], "task is too long (120 characters)"),
        ]
        for (label, override, message) in cases {
            let (isError, text) = try callTool(site, name: "request_grant", arguments: ask(site, override))
            XCTAssertTrue(isError, "\(label) is a plain tool error")
            XCTAssertEqual(text, message, "\(label) carries the house wording")
            try assertRefusalLeftNothing(site, prompts: 0)
        }

        // An empty task is not a refusal: it defaults and issues on approval — at the
        // tool surface (which drops the empty field) and at the route's raw body.
        site.gate.release()
        site.gate.release()
        let toolAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site, ["task": ""]))
        let toolSettled = waitSettled(site, toolAnswer["id"] as! String)
        guard case .approved(_, let granted) = toolSettled.resolution else {
            return XCTFail("the empty task issued")
        }
        XCTAssertEqual(granted.task, "agent task", "the default task the model pins")
        let routeCreated = try create(site, ask(site, ["task": ""]))
        XCTAssertEqual(routeCreated.status, 200)
        let routeSettled = waitSettled(site, (try json(routeCreated))["id"] as! String)
        guard case .approved(_, let routeGranted) = routeSettled.resolution else {
            return XCTFail("the route's empty task issued")
        }
        XCTAssertEqual(routeGranted.task, "agent task")
        XCTAssertEqual(site.gate.recordedReasons.count, 2)
    }

    // MARK: VAL-GRANT-015 — synchronous refusals: every profile over-ceiling case

    /// Unknown profile, key not in it, methods or paths outside, minutes and caps
    /// over the ceilings — each refuses before any prompt, while the at-boundary
    /// and at-or-below asks issue.
    func testRefusalsProfiles() throws {
        let site = try makeSite()
        try site.service.add(name: "second", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try saveProfile(site.service, methods: ["GET", "POST"], paths: ["/v1/messages"], minutes: 60,
                        maxRequests: 100, maxUsd: 2.5)
        try saveProfile(site.service, name: "other", keys: ["second"], methods: ["GET"], paths: [], minutes: 30)

        let cases: [(String, [String: Any], String)] = [
            ("unknown profile", ["profile": "ghost"], "no profile named ghost"),
            ("key not in profile", ["profile": "other"],
             "key demo is not in profile other; its keys: second"),
            ("method outside", ["profile": "evals", "methods": ["DELETE"]],
             "method DELETE is outside profile evals (allows GET,POST)"),
            ("path outside", ["profile": "evals", "paths": ["/v1/models"]],
             "path /v1/models is outside profile evals (allows /v1/messages)"),
            ("empty request vs scoped profile", ["profile": "evals", "paths": []],
             "path any path is outside profile evals (allows /v1/messages)"),
            ("minutes over", ["profile": "evals", "minutes": 61],
             "minutes 61 is above profile evals's ceiling of 60 min"),
            ("request cap over", ["profile": "evals", "max_requests": 101],
             "max requests 101 is above profile evals's ceiling of 100"),
            ("usd cap over", ["profile": "evals", "max_usd": 3],
             "max usd 3.0 is above profile evals's ceiling of $2.50"),
        ]
        for (label, override, message) in cases {
            let (isError, text) = try callTool(site, name: "request_grant", arguments: ask(site, override))
            XCTAssertTrue(isError, "\(label) is a plain tool error")
            XCTAssertEqual(text, message, "\(label) carries the named error")
            try assertRefusalLeftNothing(site, prompts: 0)
        }

        // At the ceiling it issues; at-or-below the caps it issues the tighter value.
        site.gate.release()
        site.gate.release()
        let atCeiling = try callToolJSON(site, name: "request_grant", arguments: ask(site, [
            "profile": "evals", "minutes": 60, "max_requests": 100, "max_usd": 2.5,
        ]))
        let ceilingRecord = waitSettled(site, atCeiling["id"] as! String)
        guard case .approved(_, let ceilingGrant) = ceilingRecord.resolution else {
            return XCTFail("the at-ceiling ask issued")
        }
        XCTAssertEqual(ceilingGrant.windowMinutes, 60, "at the ceiling it issues with exactly the ceiling")
        XCTAssertEqual(ceilingGrant.maxRequests, 100)
        let tighter = try callToolJSON(site, name: "request_grant", arguments: ask(site, [
            "profile": "evals", "max_requests": 50,
        ]))
        let tighterRecord = waitSettled(site, tighter["id"] as! String)
        guard case .approved(_, let tighterGrant) = tighterRecord.resolution else {
            return XCTFail("the tighter-cap ask issued")
        }
        XCTAssertEqual(tighterGrant.maxRequests, 50, "at-or-below issues the requested tighter value")
        XCTAssertEqual(site.gate.recordedReasons.count, 2)
    }

    // MARK: VAL-GRANT-016 — profile bounds default and tighten, never widen

    /// Under a profile, unspecified bounds take the profile's values in both the
    /// grant and the prompt's effective scope; named bounds inside it issue as the
    /// narrower requested values, visible the same way.
    func testProfileTightenNeverWiden() throws {
        let site = try makeSite()
        try saveProfile(site.service, methods: ["GET", "POST"], paths: ["/v1/messages"],
                        minutes: 480, maxRequests: 500, maxUsd: 2.5)
        site.gate.release()

        // The default-everything ask: no bounds named at all, so the profile's values
        // are the grant's and the prompt's effective scope.
        let defaultedAsk: [String: Any] = ["key": "demo", "task": "night evals", "profile": "evals",
                                           "folder": site.dir.path]
        let defaulted = try callToolJSON(site, name: "request_grant", arguments: defaultedAsk)
        let defaultedRecord = waitSettled(site, defaulted["id"] as! String)
        guard case .approved(_, let defaultedGrant) = defaultedRecord.resolution else {
            return XCTFail("the defaulted ask issued")
        }
        XCTAssertEqual(defaultedGrant.methods, ["GET", "POST"], "unspecified methods take the profile's")
        XCTAssertEqual(defaultedGrant.paths, ["/v1/messages"])
        XCTAssertEqual(defaultedGrant.windowMinutes, 480)
        XCTAssertEqual(defaultedGrant.maxRequests, 500)
        XCTAssertEqual(defaultedGrant.maxUsd, 2.5)
        let defaultedReason = site.gate.recordedReasons[0]
        XCTAssertTrue(defaultedReason.contains("profile evals"), "the prompt names the profile: \(defaultedReason)")
        XCTAssertTrue(defaultedReason.contains("/v1/messages"), "the prompt spells the effective scope: \(defaultedReason)")
        XCTAssertTrue(defaultedReason.contains("max 500 req"), "the prompt spells the effective cap: \(defaultedReason)")
        XCTAssertTrue(defaultedReason.contains("max $2.50"), "\(defaultedReason)")

        // Named bounds inside the profile issue as the narrower requested values.
        site.gate.release()
        let tightened = try callToolJSON(site, name: "request_grant", arguments: ask(site, [
            "profile": "evals", "minutes": 60, "methods": ["GET"],
            "paths": ["/v1/messages/count_tokens"], "max_requests": 10, "max_usd": 1,
        ]))
        let tightenedRecord = waitSettled(site, tightened["id"] as! String)
        guard case .approved(_, let tightenedGrant) = tightenedRecord.resolution else {
            return XCTFail("the tightened ask issued")
        }
        XCTAssertEqual(tightenedGrant.methods, ["GET"])
        XCTAssertEqual(tightenedGrant.paths, ["/v1/messages/count_tokens"])
        XCTAssertEqual(tightenedGrant.windowMinutes, 60)
        XCTAssertEqual(tightenedGrant.maxRequests, 10)
        XCTAssertEqual(tightenedGrant.maxUsd, 1)
        let tightenedReason = site.gate.recordedReasons[1]
        XCTAssertTrue(tightenedReason.contains("/v1/messages/count_tokens"),
                      "the prompt shows the requested narrower scope: \(tightenedReason)")
        XCTAssertTrue(tightenedReason.contains("max 10 req"), "\(tightenedReason)")
        XCTAssertFalse(tightenedReason.contains("max 500"), "never the profile's wider cap: \(tightenedReason)")
    }

    // MARK: VAL-GRANT-017 — no host input; grants untouched

    /// The schema names exactly the eight ask fields and no host; the grant lands on
    /// the key's resolved host with the row untouched; an existing grant is
    /// field-for-field unchanged; a repeat ask is a new request and a new grant.
    func testNoHostInputGrantsUntouched() throws {
        // The schema: exactly the pinned property set, host absent. Even a
        // schema-only construction runs behind the guard: an explicit temporary
        // control URL and the never-launching pair, never the production
        // defaults a bare MCPGrantTools() would carry.
        let (_, _, schemaControl) = try AppConnectionIsolationGuard.makeWorld()
        let schema = (MCPGrantTools(control: schemaControl, launch: .neverLaunching)
            .tools().first { $0.name == "request_grant" })!.inputSchema
        let properties = schema["properties"] as! [String: Any]
        XCTAssertEqual(Set(properties.keys),
                       ["key", "task", "methods", "paths", "minutes", "max_requests", "max_usd", "profile"],
                       "the ask's fields, and nothing else")
        XCTAssertFalse(properties.keys.contains("host"), "there is no host input")
        XCTAssertEqual(schema["required"] as? [String], ["key"])

        let site = try makeSite()
        site.gate.release()
        site.gate.release()
        site.gate.release()
        site.gate.release()

        // An existing grant A, through the dashboard route, captured typed.
        let dashBody: [String: Any] = ["task": "calls", "minutes": 30, "methods": ["POST"],
                                       "paths": ["/v1/chat/completions"], "max_requests": 7]
        let dash = handle(site.handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data(dashBody))
        XCTAssertEqual(dash.status, 201)
        let grantAID = (try json(dash))["id"] as! String
        let grantA = site.service.listGrants(includeInactive: true).first { $0.id == grantAID }!
        let hostBefore = try site.db.catalogRow(name: "demo")?.gatewayHost

        // A full MCP ask with different inputs, approved and delivered.
        let mcpAnswer = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        let id = mcpAnswer["id"] as! String
        _ = waitSettled(site, id)
        let approved = try callToolJSON(site, name: "grant_status",
                                        arguments: ["id": id, "secret": mcpAnswer["secret"] as? String ?? ""])
        XCTAssertEqual(approved["host"] as? String, "api.openai.com", "the grant targets the key's resolved host")
        XCTAssertEqual(try site.db.catalogRow(name: "demo")?.gatewayHost, hostBefore,
                      "the key row's host is byte-identical")

        // A is untouched, field for field.
        let stillA = site.service.listGrants(includeInactive: true).first { $0.id == grantAID }!
        XCTAssertEqual(stillA, grantA, "an existing grant is unchanged by a new request")

        // A second, identical MCP ask: a new pending id and a new grant id.
        let second = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        XCTAssertNotEqual(second["id"] as! String, id, "a repeat ask is a new pending record")
        let secondRecord = waitSettled(site, second["id"] as! String)
        guard case .approved(_, let secondGrant) = secondRecord.resolution else {
            return XCTFail("the repeat ask issued")
        }
        XCTAssertNotEqual(secondGrant.id, grantAID)
        let stillA2 = site.service.listGrants(includeInactive: true).first { $0.id == grantAID }!
        XCTAssertEqual(stillA2.expiresAt, stillA.expiresAt, "no expiry bump on A")
        XCTAssertEqual(stillA2.requests, 0, "no counter reset on A")

        // A revoked grant stays revoked: nothing revives, and its death timestamp is
        // exactly the revoke's own.
        let revokedA = try site.service.revokeGrant(id: grantAID)
        XCTAssertEqual(revokedA.revokeReason, "revoked")
        site.gate.release()
        let third = try callToolJSON(site, name: "request_grant", arguments: ask(site))
        _ = waitSettled(site, third["id"] as! String)
        let deadA = site.service.listGrants(includeInactive: true).first { $0.id == grantAID }!
        XCTAssertEqual(deadA.revokeReason, "revoked", "a new request never revives a dead grant")
        XCTAssertEqual(deadA.revokedAt, revokedA.revokedAt, "the revoke itself is the only death")
    }

    // MARK: VAL-GRANT-018 — both routes are POST and explicitly token-gated

    /// With no token or a wrong one, both routes answer 403 and create nothing; the
    /// wrong methods answer 405; a foreign Host is refused before any handler logic
    /// — and the gate holds across pending and approved states alike.
    func testEndpointsTokenGated() throws {
        let site = try makeSite()

        func gateCheck(_ response: HTTPResponse, _ label: String, line: UInt = #line) throws {
            XCTAssertEqual(response.status, 403, label, line: line)
            XCTAssertEqual(try json(response)["error"] as? String, "missing or bad token", label, line: line)
        }

        // No token: both routes, nothing created, nothing leaked.
        try gateCheck(create(site, ask(site), token: false), "create without a token")
        try gateCheck(poll(site, "00000000", token: false), "poll without a token")
        try gateCheck(handle(site.handler, method: "POST", path: "/api/mcp/grants/status",
                              body: Data(), token: false),
                      "listing without a token")
        XCTAssertTrue(site.service.mcpPendingGrants.statuses().isEmpty)

        // A wrong token is the same refusal.
        let wrong = ["x-ksf-token": "wrong-token"]
        try gateCheck(handle(site.handler, method: "POST", path: "/api/mcp/grants",
                              headers: wrong, body: try JSONValue.data(ask(site))), "create with a wrong token")
        try gateCheck(handle(site.handler, method: "POST", path: "/api/mcp/grants/00000000/status",
                              headers: wrong, body: Data()), "poll with a wrong token")

        // Wrong methods: 405, nothing created.
        for path in ["/api/mcp/grants", "/api/mcp/grants/00000000/status", "/api/mcp/grants/status"] {
            let get = handle(site.handler, method: "GET", path: path)
            XCTAssertEqual(get.status, 405, "a GET is refused on \(path)")
            XCTAssertEqual(try json(get)["error"] as? String, "method_not_allowed")
        }
        XCTAssertTrue(site.service.mcpPendingGrants.statuses().isEmpty, "no route created anything yet")

        // A foreign Host is refused before any handler logic, on both routes.
        let foreign = ["host": "evil.example:12765"]
        XCTAssertEqual(handle(site.handler, method: "POST", path: "/api/mcp/grants",
                               headers: foreign, body: try JSONValue.data(ask(site))).status, 403)
        XCTAssertEqual(handle(site.handler, method: "POST", path: "/api/mcp/grants/00000000/status",
                               headers: foreign, body: Data()).status, 403)

        // Across states: a pending and then an approved request stay gated the same.
        site.gate.release()
        let created = try create(site, ask(site))
        XCTAssertEqual(created.status, 200)
        let id = (try json(created))["id"] as! String
        try gateCheck(poll(site, id, token: false), "a pending request stays token-gated")
        _ = waitSettled(site, id)
        try gateCheck(poll(site, id, token: false), "an approved request stays token-gated")
    }

    // MARK: VAL-GRANT-019 — concurrency

    /// Two concurrent creates get distinct ids and resolve independently; a storm of
    /// creates, polls and expiries completes without crash or lost entries; two
    /// racing polls across an approval see exactly one token between them.
    func testConcurrency() throws {
        let site = try makeSite()
        let lock = NSLock()

        // Two concurrent creates while the gate blocks: both pending, distinct ids.
        var created: [[String: Any]] = []
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            if let body = try? JSONValue.data(ask(site)) {
                let response = handle(site.handler, method: "POST", path: "/api/mcp/grants", body: body)
                if let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] {
                    lock.lock(); created.append(object); lock.unlock()
                }
            }
        }
        XCTAssertEqual(created.count, 2)
        let ids = created.map { $0["id"] as! String }
        XCTAssertEqual(Set(ids).count, 2, "distinct ids for concurrent asks")
        for answer in created { XCTAssertEqual(answer["status"] as? String, "pending") }
        XCTAssertTrue(site.gate.waitPrompts(2), "both prompts went up")

        // Independent resolution: one approves, one denies — each id per its own prompt.
        site.gate.release()
        site.gate.release(AppError.authCancelled)
        let outcomes = ids.map { waitSettled(site, $0) }
        var deniedReasons = Set<String>()
        var approvedAsk: (id: String, secret: String)?
        for (id, record) in zip(ids, outcomes) {
            switch record.resolution {
            case .approved:
                let answer = created.first { $0["id"] as? String == id }!
                approvedAsk = (id, answer["secret"] as? String ?? "")
            case .denied(let reason): deniedReasons.insert(reason)
            default: XCTFail("each id resolved on its own: \(id) → \(record.resolution)")
            }
        }
        XCTAssertEqual(deniedReasons, ["cancelled"])
        let winner = try callToolJSON(site, name: "grant_status",
                                      arguments: ["id": approvedAsk!.id, "secret": approvedAsk!.secret])
        let token = winner["token"] as! String
        XCTAssertEqual(GrantToken.idOf(token), winner["id"] as? String,
                       "the token belongs to this request's own grant, no cross-talk")

        // The storm: creates to the cap, concurrent polls, a concurrent expiry sweep,
        // concurrent approvals — every id retrievable and distinct at each phase.
        var stormAsks = [String: String]()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if let body = try? JSONValue.data(ask(site)) {
                let response = handle(site.handler, method: "POST", path: "/api/mcp/grants", body: body)
                if let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
                   object["status"] as? String == "pending" {
                    lock.lock(); stormAsks[object["id"] as! String] = object["secret"] as? String ?? ""; lock.unlock()
                }
            }
        }
        XCTAssertEqual(stormAsks.count, MCPPendingGrants.liveCap, "the storm filled the cap, no more")
        XCTAssertTrue(site.gate.waitPrompts(MCPPendingGrants.liveCap))
        let storm = Array(stormAsks.keys)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let id = storm[index % storm.count]
            if let body = try? JSONValue.data(["secret": stormAsks[id] ?? ""]) {
                _ = handle(site.handler, method: "POST", path: "/api/mcp/grants/\(id)/status", body: body)
            }
        }
        site.clock.advance(MCPPendingGrants.ttl + 1)
        DispatchQueue.concurrentPerform(iterations: storm.count) { index in
            let id = storm[index]
            guard let body = try? JSONValue.data(["secret": stormAsks[id] ?? ""]) else { return }
            let response = handle(site.handler, method: "POST", path: "/api/mcp/grants/\(id)/status", body: body)
            guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
                return XCTFail("every id stays retrievable through the sweep")
            }
            XCTAssertEqual(object["status"] as? String, "expired")
        }
        // The storm's prompts are still up: their late answers change nothing, and
        // they must not eat the credit the racing ask below needs.
        site.gate.releaseAll(AppError.authCancelled)

        // Racing polls across an approval: exactly one token between them — every
        // racer holds the ask's own secret, so the race is about delivery, not proof.
        let racing = try create(site, ask(site))
        let racingAnswer = try json(racing)
        let racingID = racingAnswer["id"] as! String
        let racingSecret = racingAnswer["secret"] as? String ?? ""
        site.gate.release()
        _ = waitSettled(site, racingID)
        var tokens = 0
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            guard let body = try? JSONValue.data(["secret": racingSecret]) else { return }
            let response = handle(site.handler, method: "POST", path: "/api/mcp/grants/\(racingID)/status", body: body)
            if let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] {
                if object.keys.contains("token") {
                    lock.lock(); tokens += 1; lock.unlock()
                } else {
                    XCTAssertEqual(object["status"] as? String, "approved")
                    XCTAssertEqual(object["delivered"] as? Bool, true, "the loser gets the pinned tokenless shape")
                }
            }
        }
        XCTAssertEqual(tokens, 1, "consume-once under racing polls")
    }

    // MARK: VAL-GRANT-020 — live pending requests are capped at 8

    /// The 9th live request is refused synchronously with no prompt and no record;
    /// slots freed by expiry or by resolution let new asks through again.
    func testLivePendingCap() throws {
        let site = try makeSite()
        XCTAssertEqual(MCPPendingGrants.liveCap, 8, "the cap is the one pinned constant")

        // Eight live asks while the gate blocks; the ninth is a plain refusal.
        for _ in 0..<8 {
            let answer = try json(create(site, ask(site)))
            XCTAssertEqual(answer["status"] as? String, "pending")
        }
        XCTAssertEqual(site.service.mcpPendingGrants.statuses().count, 8)
        let ninth = try create(site, ask(site))
        XCTAssertEqual(ninth.status, 400)
        XCTAssertEqual(try json(ninth)["error"] as? String,
                       "too many grant requests are waiting; wait for one to resolve or expire, then ask again")
        XCTAssertEqual(site.gate.recordedReasons.count, 8, "the ninth consumed no prompt")
        XCTAssertEqual(site.service.mcpPendingGrants.statuses().count, 8, "the ninth left no record")

        // Expiry frees every slot. The first batch's prompts are still up — unpark
        // them first, so they cannot eat the later phases' outcomes.
        site.clock.advance(MCPPendingGrants.ttl + 1)
        site.gate.releaseAll(AppError.authCancelled)
        for _ in 0..<8 {
            let answer = try json(create(site, ask(site)))
            XCTAssertEqual(answer["status"] as? String, "pending", "expired slots are free")
        }
        XCTAssertTrue(site.gate.waitPrompts(8), "the fresh asks' prompts all went up")

        // Resolution frees one too: one approval, and the next ask fits again.
        site.gate.release()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let pending = site.service.mcpPendingGrants.statuses()
                .filter { if case .pending = $0.resolution { return true }; return false }.count
            if pending == 7 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(site.service.mcpPendingGrants.statuses()
            .filter { if case .pending = $0.resolution { return true }; return false }.count, 7,
                       "one resolution freed one slot")
        let afterFree = try json(create(site, ask(site)))
        XCTAssertEqual(afterFree["status"] as? String, "pending", "a freed slot admits the next ask")
    }

    // MARK: VAL-GRANT-021 — the owner check runs at create time

    /// With a second live site owning the gateway, `request_grant` refuses
    /// immediately with the clear gateway-owned wording — no prompt, no record,
    /// no grant — at both the route and the tool surface.
    func testOwnerCheckAtCreate() throws {
        let site = try makeSite()
        // A second live site owns the gateway: the control file still reaches this
        // site, but it names another live process as the owner. The guard runs
        // before the site's control file is rewritten.
        try AppConnectionIsolationGuard.assertIsolated(control: site.control, launch: .neverLaunching)
        let other = getppid()
        try ControlFile.write(port: site.server.boundPort, token: site.handler.originToken, pid: other, to: site.control)

        let refusal = try create(site, ask(site))
        XCTAssertEqual(refusal.status, 409)
        XCTAssertEqual(try json(refusal)["error"] as? String, "gateway owned by another process")

        let (isError, text) = try callTool(site, name: "request_grant", arguments: ask(site))
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("is managing your keys right now"), "the existing wording: \(text)")
        XCTAssertFalse(text.contains(String(other)), "the pid is scrubbed: \(text)")

        XCTAssertEqual(site.gate.recordedReasons.count, 0, "no prompt was consumed")
        XCTAssertTrue(site.service.mcpPendingGrants.statuses().isEmpty, "no pending record")
        XCTAssertTrue(site.service.listGrants(includeInactive: true).isEmpty, "no grant")
    }

    // MARK: VAL-GRANT-022 — app lifecycle edges

    /// A restart drops pending (not_found, no token, no grant row on the fresh
    /// service); screen lock during a pending request fails it closed while the
    /// existing grants are revoked as today; with no app running, the exact
    /// not-running sentence.
    func testAppLifecycleEdges() throws {
        // Restart drops pending: a fresh service and handler over the SAME catalog.
        let site = try makeSite()
        let pending = try json(create(site, ask(site)))
        let id = pending["id"] as! String

        let reopened = try CatalogDB(path: site.db.path)
        let restarted = KeysService(
            catalog: reopened, secrets: MemorySecretStore(), presence: BlockingPresenceGate(),
            clipboard: FakeClipboard(), grokHome: Fixtures.grokHome, claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome, droidHome: Fixtures.droidHome,
            runner: SpawnCommandRunner(restoresHandlers: true), openRouter: OpenRouterHTTP(),
            relaySecrets: MemorySecretStore()
        )
        let web2 = site.dir.appendingPathComponent("Web2", isDirectory: true)
        try fm.createDirectory(at: web2, withIntermediateDirectories: true)
        let handler2 = APIHandler(service: restarted, webRoot: web2)
        let after = handle(handler2, method: "POST", path: "/api/mcp/grants/\(id)/status", body: Data())
        XCTAssertEqual(after.status, 404, "the restarted app answers not_found for the old id")
        XCTAssertEqual(try json(after)["error"] as? String, "not_found")
        XCTAssertTrue(restarted.listGrants(includeInactive: true).isEmpty, "no grant row and no token survived")

        // Screen lock fails a pending request closed, and revokes the live grants.
        let locked = try makeSite()
        locked.gate.release()
        locked.gate.release(AppError.authCancelled)
        let dash = handle(locked.handler, method: "POST", path: "/api/keys/demo/grants",
                          body: try JSONValue.data(["task": "live grant"]))
        XCTAssertEqual(dash.status, 201)
        let liveGrantID = (try json(dash))["id"] as! String
        let lockedPending = try json(create(locked, ask(locked)))
        // The lock fires, then the system cancels the prompt (.systemCancel → authCancelled).
        locked.service.handleScreenLock()
        let record = waitSettled(locked, lockedPending["id"] as! String)
        if case .denied("cancelled") = record.resolution {} else {
            return XCTFail("the lock failed the request closed: \(record.resolution)")
        }
        XCTAssertEqual(locked.service.listGrants(includeInactive: true)
            .first { $0.id == liveGrantID }?.revokeReason, "screen_lock",
            "the existing grant is revoked as today")
        XCTAssertTrue(locked.service.listGrants().isEmpty, "nothing is live after the lock")

        // No app running: the exact sentence, byte for byte. The nowhere world is
        // guarded before the grant group is built over it.
        let (_, _, nowhereControl) = try AppConnectionIsolationGuard.makeWorld()
        let tools = MCPGrantTools(
            control: nowhereControl,
            launch: .neverLaunching
        )
        XCTAssertThrowsError(try tools.call("request_grant", arguments: ["key": "demo"])) { error in
            XCTAssertEqual((error as? AppError)?.description, AppConnection.notRunningMessage)
        }
    }

    // MARK: VAL-INT-004 — the grant_issue onboarding counter

    /// A grant issued through the MCP `request_grant` flow records the onboarding
    /// `grant_issue` counter — and records nothing while analytics sharing is off
    /// (the opt-in gate). The dashboard's own issuance stays on `grant_create`, so
    /// this onboarding counter is produced by the MCP flow alone.
    func testRequestGrantRecordsGrantIssueOnlyWhenSharingIsOn() throws {
        let site = try makeSite()
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: site.db, transport: transport)
        site.service.analytics = analytics

        func counts() throws -> [String: Int]? {
            (((try analytics.status()["preview"] as? [String: Any])?["reports"] as? [[String: Any]])?
                .first?["counts"] as? [String: Int])
        }
        func issue() throws {
            site.gate.release()
            let id = (try callToolJSON(site, name: "request_grant", arguments: ask(site)))["id"] as! String
            _ = waitSettled(site, id)
        }

        try issue()
        XCTAssertNil(try counts(), "sharing is off: the issue records nothing")

        try analytics.setEnabled(true, consentVersion: 2)
        try issue()
        let counts = try XCTUnwrap(try counts(), "the issue recorded a counter")
        XCTAssertEqual(counts["grant_issue"], 1, "the MCP issue records one grant_issue")
    }
}
