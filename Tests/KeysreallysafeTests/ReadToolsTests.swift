import Foundation
import SQLite3
import XCTest
@testable import KeysCore

/// VAL-TOOLS-001..010: the five read tools and the two `/api/mcp` routes the
/// app-bound pair needs. `list_keys` reads the local catalog (labels only, active
/// project-bound tokens only, never a key value); `gateway_info` relays the app's
/// one live payload over the control channel and fails as a whole with the exact
/// not-running sentence; `version` is the single version constant; `open_app`
/// drives the dedicated show path, never a browser; `check_update` is read-only
/// behind an injected fetcher. The app side is exercised in-process over a temp
/// catalog on an ephemeral port — never 12767, never the installed app, and no
/// Keychain, Touch ID or network anywhere.
final class ReadToolsTests: XCTestCase {

    private let fm = FileManager.default

    /// The repo checkout root, for the structural pins.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The exact not-running sentence, byte for byte (CONNECTION-002's constant).
    private static let notRunning = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    // MARK: - Rigs

    /// A counting stand-in for the app's window show. The route must drive exactly
    /// this seam and nothing else — no browser, no LaunchServices.
    private final class ShowSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func show() { lock.lock(); calls += 1; lock.unlock() }
    }

    /// One fresh catalog with a proxiable `demo` key, its host set, and the
    /// recording gate's service over it.
    @discardableResult
    private func makeVault() throws -> (service: KeysService, db: CatalogDB, dir: URL, gate: RecordingPresenceGate) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:1", updateHost: true)
        return (service, db, dir, gate)
    }

    /// The same vault, built inside an already-guarded world: the caller holds
    /// a temporary directory whose control URL, launch pair and secret store
    /// the isolation guard has already fail-closed-checked.
    @discardableResult
    private func makeVault(in dir: URL, catalog: URL, secrets: MemorySecretStore) throws -> (
        service: KeysService, db: CatalogDB, gate: RecordingPresenceGate
    ) {
        let db = try CatalogDB(path: catalog)
        let (service, gate) = makeGatedService(db: db, secrets: secrets)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: nil, host: "127.0.0.1:1", updateHost: true)
        return (service, db, gate)
    }

    /// A real folder under `dir`, which itself sits behind the `/var` →
    /// `/private/var` symlink, so every resolution also exercises that spelling.
    private func makeFolder(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The in-process app: a real `APIHandler` behind a loopback server on an
    /// ephemeral port, `control.json` beside the catalog naming it, and the
    /// read-tool group wired over that control file — exactly how `keys mcp`
    /// reaches the installed app (the ListCommandTests rig). The show spy stands
    /// in for the window controller so `open_app` never reaches AppKit from a test.
    private struct Site {
        let server: LoopbackHTTPServer
        let handler: APIHandler
        let service: KeysService
        let db: CatalogDB
        let dir: URL
        let control: URL
        let show: ShowSpy
        let tools: MCPReadTools
    }

    private func makeSite(show: ShowSpy = ShowSpy()) throws -> Site {
        // The guarded world first: the control URL beside the catalog, the fake
        // launch pair and the fake secret store, fail-closed-checked before any
        // fixture, file or socket operation.
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let (service, db, _) = try makeVault(in: dir, catalog: catalog, secrets: secrets)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web, showAppWindow: { show.show() })
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        let tools = MCPReadTools(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("the site rig fetches no release") },
            launch: .neverLaunching
        )
        return Site(
            server: server, handler: handler, service: service, db: db, dir: dir,
            control: control, show: show, tools: tools
        )
    }

    /// A read group whose app and catalog seams are deliberately unwired: the
    /// check_update tests exercise the release fetcher alone, and an accidental
    /// app or catalog call fails loudly instead of reaching the machine's real state.
    private func updateTools(fetch: @escaping () throws -> ReleaseInfo) throws -> MCPReadTools {
        let (_, _, control) = try AppConnectionIsolationGuard.makeWorld()
        return MCPReadTools(
            catalog: { throw AppError.usage("check_update reads no catalog") },
            control: control,
            fetchLatestRelease: fetch,
            launch: .neverLaunching
        )
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

    private func payloadText(_ result: MCPToolResult) -> String {
        (result.content.first?["text"] as? String) ?? ""
    }

    /// Raw sqlite surgery, the GatewayRetargetTests rig: a project row can be
    /// deleted only through SQL (no delete surface ships).
    @discardableResult
    private func rawExec(_ dbPath: URL, _ sql: String) -> Int32 {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(raw, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc
    }

    private func rawRows(_ dbPath: URL, _ sql: String) throws -> [[String]] {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<Int(sqlite3_column_count(stmt))).map {
                sqlite3_column_text(stmt, Int32($0)).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    // MARK: - VAL-TOOLS-001

    /// `list_keys` returns one entry per catalog row with exactly the reduced
    /// shape `{name, provider, kind, projects}` — no invented per-key field (the
    /// model has no per-key last-4 and no per-key expiry), an empty vault yielding
    /// an empty list as a success, and no secret value or token shape anywhere.
    func testListKeysShape() throws {
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let (service, db, _) = try makeVault(in: dir, catalog: catalog, secrets: secrets)
        try service.add(name: "second", provider: "anthropic", kind: "billing", notes: "", secret: fixtureSecret)
        let project = try service.resolveProject(folder: try makeFolder(dir, "shape-proj").path)
        _ = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)
        let tools = MCPReadTools(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("list_keys checks no release") },
            launch: .neverLaunching
        )

        let result = try tools.call("list_keys", arguments: [:])
        XCTAssertEqual(result.isError, false)
        let body = try payload(result)
        let keys = try XCTUnwrap(body["keys"] as? [[String: Any]], "the payload is {keys: [...]}")
        XCTAssertEqual(keys.count, 2, "one entry per catalog row")
        XCTAssertEqual(
            Set(keys.compactMap { $0["name"] as? String }),
            Set(try service.list().map(\.name)),
            "the name set matches service.list()"
        )

        let rows = Dictionary(uniqueKeysWithValues: try service.list().map { ($0.name, $0) })
        for entry in keys {
            let name = try XCTUnwrap(entry["name"] as? String)
            let row = try XCTUnwrap(rows[name])
            XCTAssertEqual(
                Set(entry.keys), ["name", "provider", "kind", "projects"],
                "exactly the reduced shape — the model has no per-key last-4 and no per-key expiry, so none is invented"
            )
            XCTAssertEqual(entry["provider"] as? String, row.provider)
            XCTAssertEqual(entry["kind"] as? String, row.kind)
            XCTAssertNotNil(entry["projects"] as? [Any], "projects is a list of labels")
        }
        let demo = try XCTUnwrap(keys.first { $0["name"] as? String == "demo" })
        XCTAssertEqual(demo["projects"] as? [String], [project.label], "labels only")

        // An empty vault is an empty list: a success, no prose error, no tool error.
        let (_, emptyCatalog, emptyControl) = try AppConnectionIsolationGuard.makeWorld()
        let emptyDB = try CatalogDB(path: emptyCatalog)
        let emptyTools = MCPReadTools(
            catalog: { emptyDB },
            control: emptyControl,
            fetchLatestRelease: { throw AppError.usage("list_keys checks no release") },
            launch: .neverLaunching
        )
        let empty = try emptyTools.call("list_keys", arguments: [:])
        XCTAssertEqual(empty.isError, false)
        XCTAssertEqual((try payload(empty)["keys"] as? [Any])?.count, 0)

        // No secret value and no token shape anywhere in the result.
        let text = payloadText(result)
        XCTAssertFalse(text.contains(fixtureSecret), "a key value never appears")
        XCTAssertFalse(text.range(of: MCPOutputGuard.tokenShapePattern, options: .regularExpression) != nil)
    }

    // MARK: - VAL-TOOLS-002

    /// In-use projects come from ACTIVE project-bound client tokens only: two
    /// active bound tokens (projects A and B) plus an active null-project token
    /// report exactly [labelA, labelB]; two active tokens for one project list it
    /// once; a project only a revoked token names disappears on the next read
    /// with no restart; an expired token's project is filtered at read time with
    /// the row itself untouched; a dangling reference is skipped without error.
    func testInUseProjects() throws {
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let (service, db, _) = try makeVault(in: dir, catalog: catalog, secrets: secrets)
        let projectA = try service.resolveProject(folder: try makeFolder(dir, "work").path)
        let projectB = try service.resolveProject(folder: try makeFolder(dir, "side").path)
        _ = try service.issueGatewayClient(name: "demo", label: "agent a", project: projectA.id)
        _ = try service.issueGatewayClient(name: "demo", label: "agent b", project: projectB.id)
        _ = try service.issueGatewayClient(name: "demo", label: "unbound")
        _ = try service.issueGatewayClient(name: "demo", label: "agent a2", project: projectA.id)

        let tools = MCPReadTools(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("list_keys checks no release") },
            launch: .neverLaunching
        )
        func projectsOfDemo() throws -> [String] {
            let body = try payload(try tools.call("list_keys", arguments: [:]))
            let demo = try XCTUnwrap((body["keys"] as? [[String: Any]])?.first { $0["name"] as? String == "demo" })
            return demo["projects"] as? [String] ?? []
        }
        XCTAssertEqual(
            try projectsOfDemo(), [projectA.label, projectB.label],
            "deduped active project labels in first-issue order; the null-project token contributes nothing"
        )

        // Revoked: the project only the revoked token referenced disappears on the
        // next read — same process, no restart.
        let bToken = try XCTUnwrap(try db.gatewayClients(keyName: "demo").first { $0.project == projectB.id })
        _ = try service.revokeGatewayClient(name: "demo", id: bToken.id)
        XCTAssertEqual(try projectsOfDemo(), [projectA.label])

        // Expired: minted with a clock three days past and a one-day TTL, so the
        // row reads expired at real now. Filtered at read time, row untouched.
        let stale = try service.issueGatewayClient(
            name: "demo", label: "agent b2", days: 1, project: projectB.id,
            now: Date().addingTimeInterval(-3 * 86_400)
        )
        XCTAssertEqual(try projectsOfDemo(), [projectA.label], "an expired token is not in use")
        let staleRow = try XCTUnwrap(try db.gatewayClients(keyName: "demo").first { $0.id == stale.client.id })
        XCTAssertNil(staleRow.revokedAt, "the expired row itself is untouched")
        XCTAssertFalse(staleRow.isActive(now: Date()), "it is expired, not revoked")

        // Dangling: the projects row gone (only raw SQL can do that — no delete
        // surface ships) is skipped without error.
        XCTAssertEqual(rawExec(dir.appendingPathComponent("catalog.db"), "DELETE FROM projects;"), SQLITE_OK)
        XCTAssertEqual(try projectsOfDemo(), [], "a dangling reference contributes nothing and never throws")
    }

    // MARK: - VAL-TOOLS-003

    /// `gateway_info` carries `base_url` (composed from `GatewayListener.port`,
    /// pinned against the constant, never hardcoded twice) and `docker_access`
    /// reflecting the catalog-meta preference `pref_docker_access`: false on a
    /// fresh catalog with no meta row written by the read, true on "on", false on
    /// "off", false once deleted. The route is a token-gated POST under `/api/`.
    func testGatewayInfoBaseAndDocker() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let dbPath = site.dir.appendingPathComponent("catalog.db")

        // The route is a token-gated POST: without the per-launch token it is a 403.
        let refused = handle(site.handler, method: "POST", path: "/api/mcp/gateway_info", token: false)
        XCTAssertEqual(refused.status, 403, "the route inherits the mutatingAPI origin-token gate")

        func readThroughTheTool() throws -> [String: Any] {
            let result = try site.tools.call("gateway_info", arguments: [:])
            XCTAssertEqual(result.isError, false)
            return try payload(result)
        }

        // Fresh catalog: false, and the read writes no meta row.
        let fresh = try readThroughTheTool()
        XCTAssertEqual(
            fresh["base_url"] as? String, "http://127.0.0.1:\(GatewayListener.port)",
            "derived from GatewayListener.port"
        )
        XCTAssertEqual(fresh["docker_access"] as? Bool, false)
        XCTAssertEqual(
            try rawRows(dbPath, "SELECT COUNT(*) FROM meta WHERE key = 'pref_docker_access';"), [["0"]],
            "a read writes no meta row"
        )

        // "on" → true, "off" → false, deleted → false — through the real route each time.
        try site.db.setMeta("pref_docker_access", "on")
        XCTAssertEqual(try readThroughTheTool()["docker_access"] as? Bool, true)
        try site.db.setMeta("pref_docker_access", "off")
        XCTAssertEqual(try readThroughTheTool()["docker_access"] as? Bool, false)
        try site.db.deleteMeta("pref_docker_access")
        XCTAssertEqual(try readThroughTheTool()["docker_access"] as? Bool, false)

        // Never hardcoded twice: the route composes the constant; it repeats no literal.
        let routeSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/HTTPServer.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            routeSource.contains("http://127.0.0.1:\\(GatewayListener.port)"),
            "base_url is composed from GatewayListener.port at the route"
        )
    }

    // MARK: - VAL-TOOLS-004

    /// `gateway_info` reports the grants the running app holds, read live over
    /// the control channel: a grant issued through the rig's own issue route
    /// appears (key, host, task, expires_at — never the token, which exists only
    /// in the issue response), and revoking it through the route drops it from
    /// the next read. No `ksf_` substring appears.
    func testGatewayInfoActiveGrants() throws {
        let site = try makeSite()
        defer { site.server.stop() }

        func grantsNow() throws -> [[String: Any]] {
            let body = try payload(try site.tools.call("gateway_info", arguments: [:]))
            return (body["grants"] as? [[String: Any]]) ?? []
        }
        XCTAssertEqual(try grantsNow().count, 0, "nothing issued yet")

        // Issue through the app's own route, exactly as a dashboard would.
        let issue = handle(
            site.handler, method: "POST", path: "/api/keys/demo/grants",
            body: try JSONValue.data(["task": "read tools test", "caller": "test"])
        )
        XCTAssertEqual(issue.status, 201)
        let issued = try XCTUnwrap(JSONSerialization.jsonObject(with: issue.body) as? [String: Any])
        let grantID = try XCTUnwrap(issued["id"] as? String)
        let grantToken = try XCTUnwrap(issued["token"] as? String)

        let grants = try grantsNow()
        XCTAssertEqual(grants.count, 1, "the live grant appears through the control channel")
        XCTAssertEqual(grants[0]["key"] as? String, "demo")
        XCTAssertEqual(grants[0]["task"] as? String, "read tools test")
        XCTAssertNotNil(grants[0]["host"] as? String)
        XCTAssertNotNil(grants[0]["expires_at"] as? String)
        XCTAssertNil(grants[0]["token"], "the token exists only in the issue response")

        let text = payloadText(try site.tools.call("gateway_info", arguments: [:]))
        XCTAssertFalse(text.contains("ksf_"), "no grant-token substring appears")
        XCTAssertFalse(text.contains(grantToken), "the issued token never appears")

        // Revoke through the route: dropped from the next read.
        let revoke = handle(site.handler, method: "DELETE", path: "/api/grants/\(grantID)")
        XCTAssertEqual(revoke.status, 200)
        XCTAssertEqual(try grantsNow().count, 0)
    }

    // MARK: - VAL-TOOLS-005

    /// `gateway_info` lists the ACTIVE project-bound client tokens by label with
    /// expiry and the last-4 `hint` (a by-design recognizer, never the token):
    /// two active tokens for the same project both appear; revoked and expired
    /// ones are excluded; no token value, no token hash and no project path
    /// appears anywhere.
    func testGatewayInfoProjectTokens() throws {
        let site = try makeSite()
        defer { site.server.stop() }
        let folder = try makeFolder(site.dir, "token-proj")
        let project = try site.service.resolveProject(folder: folder.path)
        let first = try site.service.issueGatewayClient(name: "demo", label: "agent one", project: project.id)
        let second = try site.service.issueGatewayClient(name: "demo", label: "agent two", project: project.id)
        _ = try site.service.issueGatewayClient(name: "demo", label: "unbound")
        _ = try site.service.issueGatewayClient(
            name: "demo", label: "expired", days: 1, project: project.id,
            now: Date().addingTimeInterval(-3 * 86_400)
        )
        let revoked = try site.service.issueGatewayClient(name: "demo", label: "revoked", project: project.id)
        _ = try site.service.revokeGatewayClient(name: "demo", id: revoked.client.id)

        let body = try payload(try site.tools.call("gateway_info", arguments: [:]))
        let tokens = try XCTUnwrap(body["project_tokens"] as? [[String: Any]])
        XCTAssertEqual(tokens.count, 2, "exactly the two active project-bound tokens — this is a token list, not the deduped project list")
        for entry in tokens {
            XCTAssertEqual(entry["label"] as? String, project.label, "labels, not paths, identify the projects")
            XCTAssertEqual(entry["key"] as? String, "demo")
            XCTAssertNotNil(UTC.parse(try XCTUnwrap(entry["expires_at"] as? String)), "expiry is an ISO timestamp")
        }
        XCTAssertEqual(
            Set(tokens.compactMap { $0["hint"] as? String }),
            Set([first.client.hint, second.client.hint]),
            "the client-token last-4 hint, never the token"
        )

        // Absence scans: no token value, no token hash, no path.
        let text = payloadText(try site.tools.call("gateway_info", arguments: [:]))
        XCTAssertFalse(text.contains("ksfc_"), "no client-token substring appears")
        for issued in [first, second, revoked] {
            XCTAssertFalse(text.contains(issued.token), "the token value never appears")
            XCTAssertFalse(text.contains(GatewayClientToken.hash(issued.token)), "the stored hash never appears")
        }
        XCTAssertFalse(text.contains(folder.path), "the project path never appears")
    }

    // MARK: - VAL-TOOLS-006

    /// With no live control file — even though the base URL, docker_access and the
    /// project tokens are all catalog-readable — `gateway_info` fails as a WHOLE:
    /// one isError result carrying the exact not-running sentence, no partial
    /// payload alongside it, and the session alive. "No grants" must not be
    /// indistinguishable from "cannot see grants".
    func testGatewayInfoWholeFail() throws {
        let secrets = MemorySecretStore()
        let (dir, catalog, control) = try AppConnectionIsolationGuard.makeWorld(secrets: secrets)
        let (service, db, _) = try makeVault(in: dir, catalog: catalog, secrets: secrets)
        let project = try service.resolveProject(folder: try makeFolder(dir, "whole-fail-proj").path)
        _ = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)
        try db.setMeta("pref_docker_access", "on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path), "no live site owns this catalog")
        let tools = MCPReadTools(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("gateway_info checks no release") },
            launch: .neverLaunching
        )

        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gateway_info"}}"#,
            #"{"jsonrpc":"2.0","id":"after","method":"ping"}"#,
        ], registry: MCPToolRegistry(groups: [MCPVersionTool(), tools]))
        XCTAssertEqual(frames.last, "")
        XCTAssertEqual(stderr, [], "a not-running read is a result, not a diagnostic")
        let responses = Array(frames.dropLast())
        let result = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(result["isError"] as? Bool, true, "the missing app is a tool result")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, Self.notRunning, "the exact sentence, byte for byte")

        // No partial result: none of the catalog-readable fields leak alongside it.
        let frame = responses[1]
        for field in ["base_url", "docker_access", "project_tokens", "grants", project.label, "127.0.0.1:12767"] {
            XCTAssertFalse(frame.contains(field), "no partial \(field) leaks with the not-running error")
        }
        // And the session survives to the next call.
        XCTAssertTrue((try MCPSession.assertResult(responses[2], id: "after")).isEmpty)
    }

    // MARK: - VAL-TOOLS-007

    /// `version` returns exactly the single version constant, needs no site and no
    /// app, equals `serverInfo.version` from initialize, and equals the one line
    /// `keys version --json` prints.
    func testVersionCoherence() throws {
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"version"}}"#,
        ], registry: .default)
        XCTAssertEqual(frames.last, "")
        let responses = Array(frames.dropLast())
        let opened = try MCPSession.assertResult(responses[0], id: "init")
        XCTAssertEqual(
            (opened["serverInfo"] as? [String: Any])?["version"] as? String,
            ProductAnalyticsConfiguration.appVersion, "serverInfo carries the same constant"
        )

        let result = try MCPSession.assertResult(responses[1], id: 1)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["version"], "exactly {version: \"<X.Y.Z>\"}")
        XCTAssertEqual(
            decoded["version"] as? String, ProductAnalyticsConfiguration.appVersion,
            "the constant, asserted against it at runtime — never a literal"
        )

        // The same one line `keys version --json` prints: sorted keys, compact.
        XCTAssertEqual(decoded as? [String: String], VersionCommand.jsonObject())
        XCTAssertEqual(text, String(decoding: try JSONValue.data(VersionCommand.jsonObject()), as: UTF8.self))
    }

    // MARK: - VAL-TOOLS-008

    /// `open_app` drives the app-side dedicated show path exactly once — the
    /// injected show closure, never `openDashboard()`'s browser fallback — answers
    /// 200 ok, and the MCP tool returns ok over the control channel. Neither the
    /// tool nor the route references NSWorkspace, LaunchServices or openDashboard
    /// (the structural belt under the spy). With no app the tool returns the exact
    /// not-running sentence and has no other side effect.
    func testOpenAppShowPath() throws {
        let show = ShowSpy()
        let site = try makeSite(show: show)
        defer { site.server.stop() }

        // The route: a token-gated POST that invokes the show seam exactly once.
        let refused = handle(site.handler, method: "POST", path: "/api/mcp/app/show", token: false)
        XCTAssertEqual(refused.status, 403, "the show route inherits the mutatingAPI origin-token gate")
        XCTAssertEqual(show.count, 0, "a refused call never shows the window")
        let response = handle(site.handler, method: "POST", path: "/api/mcp/app/show")
        XCTAssertEqual(response.status, 200)
        let shown = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(Set(shown.keys), ["ok"])
        XCTAssertEqual(shown["ok"] as? Bool, true)
        XCTAssertEqual(show.count, 1, "the dedicated show path, invoked exactly once")

        // The MCP tool over the control channel: ok.
        let result = try site.tools.call("open_app", arguments: [:])
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(try payload(result)["ok"] as? Bool, true)
        XCTAssertEqual(show.count, 2, "one tool call, one show")

        // The structural belt: the tool and the route never name the browser or
        // LaunchServices seams, and never reuse openDashboard.
        for name in ["MCPReadTools.swift", "HTTPServer.swift"] {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/\(name)"), encoding: .utf8
            )
            XCTAssertFalse(source.contains("NSWorkspace"), "\(name) never opens a browser")
            XCTAssertFalse(source.contains("LSOpen"), "\(name) never calls LaunchServices")
            XCTAssertFalse(source.contains("openDashboard"), "\(name) never reuses the browser fallback")
        }

        // With no app: the exact sentence as a tool result, and nothing else
        // happened.
        let (_, bareCatalog, bareControl) = try AppConnectionIsolationGuard.makeWorld()
        let bareDB = try CatalogDB(path: bareCatalog)
        let tools = MCPReadTools(
            catalog: { bareDB },
            control: bareControl,
            fetchLatestRelease: { throw AppError.usage("open_app checks no release") },
            launch: .neverLaunching
        )
        let (bareFrames, bareStderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_app"}}"#,
        ], registry: MCPToolRegistry(groups: [MCPVersionTool(), tools]))
        XCTAssertEqual(bareFrames.last, "")
        XCTAssertEqual(bareStderr, [])
        let bareResponses = Array(bareFrames.dropLast())
        let bare = try MCPSession.assertResult(bareResponses[1], id: 1)
        XCTAssertEqual(bare["isError"] as? Bool, true)
        let bareText = ((bare["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(bareText, Self.notRunning)
    }

    // MARK: - VAL-TOOLS-009

    /// `check_update` names the current version (the constant), the latest and an
    /// `update_available` boolean, derived read-only through the injected fetcher:
    /// true for a newer release, false for an equal one. It never installs: no
    /// file and no directory appears, and the tool's source names neither the
    /// installer nor a URL session.
    func testCheckUpdateReadOnly() throws {
        let tempRoot = FileManager.default.temporaryDirectory
        func keysrsEntries() throws -> Set<String> {
            Set(try fm.contentsOfDirectory(atPath: tempRoot.path).filter { $0.lowercased().contains("keys") })
        }
        let before = try keysrsEntries()

        func check(latest: String) throws -> (current: String, latest: String, available: Bool) {
            let tools = try updateTools {
                ReleaseInfo(
                    version: latest,
                    dmg: URL(string: "https://release.invalid/Keysrs-arm64.dmg")!,
                    checksum: nil, expectedBytes: nil, notes: nil
                )
            }
            let result = try tools.call("check_update", arguments: [:])
            XCTAssertEqual(result.isError, false)
            let body = try payload(result)
            return (
                try XCTUnwrap(body["current"] as? String),
                try XCTUnwrap(body["latest"] as? String),
                try XCTUnwrap(body["update_available"] as? Bool)
            )
        }

        let newer = try check(latest: "999.0.0")
        XCTAssertEqual(newer.current, ProductAnalyticsConfiguration.appVersion, "the current version is the constant")
        XCTAssertEqual(newer.latest, "999.0.0")
        XCTAssertEqual(newer.available, true, "a newer release reports true")

        let equal = try check(latest: ProductAnalyticsConfiguration.appVersion)
        XCTAssertEqual(equal.available, false, "an equal release reports false")

        // Never installs: nothing keysrs-named appeared in the temporary directory.
        XCTAssertEqual(try keysrsEntries(), before, "no download, no staging, nothing written")
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/KeysCore/MCPReadTools.swift"), encoding: .utf8
        )
        for symbol in ["UpdateInstaller", "installPlan", "AppUpdater", "URLSession"] {
            XCTAssertFalse(source.contains(symbol), "the installer path is not reachable from the tool: \(symbol)")
        }
    }

    // MARK: - VAL-TOOLS-010

    /// Each existing failure mode of the release check becomes a plain tool error
    /// whose message matches the existing updater wording — the non-200 refusal,
    /// a non-X.Y.Z tag and a missing asset driven through the real parser, and a
    /// transport failure — and the session survives every one of them.
    func testCheckUpdateFailureModes() throws {
        let modes: [(label: String, fetch: () throws -> ReleaseInfo, message: String)] = [
            ("non-200", { throw AppError.http("GitHub did not return a release.") },
             "GitHub did not return a release."),
            ("non-X.Y.Z tag", { try AppUpdater.parseRelease(Self.nightlyTagJSON) },
             "GitHub returned an unsupported version string."),
            ("missing asset", { try AppUpdater.parseRelease(Self.noAssetJSON) },
             "The latest release has no Keysrs-arm64.dmg download."),
            ("transport", { throw AppError.http("The Internet connection appears to be offline.") },
             "The Internet connection appears to be offline."),
        ]
        for mode in modes {
            let tools = try updateTools(fetch: mode.fetch)
            let (frames, _) = try MCPSession.run([
                MCPSession.initialize(),
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"check_update"}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"version"}}"#,
            ], registry: MCPToolRegistry(groups: [MCPVersionTool(), tools]))
            XCTAssertEqual(frames.last, "")
            let responses = Array(frames.dropLast())
            XCTAssertEqual(responses.count, 3, "\(mode.label): one response per request")

            let failure = try MCPSession.assertResult(responses[1], id: 1)
            XCTAssertEqual(failure["isError"] as? Bool, true, "\(mode.label): a plain tool error")
            let text = ((failure["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            XCTAssertEqual(text, mode.message, "\(mode.label): the existing updater wording")

            // The session survives: the next tool on the same session answers.
            let after = try MCPSession.assertResult(responses[2], id: 2)
            XCTAssertEqual(after["isError"] as? Bool, false, "\(mode.label): the session survives")
        }
    }

    /// A release whose tag is not X.Y.Z — the real parser must refuse it with the
    /// existing sentence.
    private static let nightlyTagJSON = Data(
        #"{"tag_name":"nightly-2026","assets":[{"name":"Keysrs-arm64.dmg","browser_download_url":"https://release.invalid/Keysrs-arm64.dmg"}]}"#.utf8
    )

    /// A release whose tag parses but whose asset list has no DMG.
    private static let noAssetJSON = Data(
        #"{"tag_name":"v9.9.9","assets":[{"name":"Source.zip","browser_download_url":"https://release.invalid/Source.zip"}]}"#.utf8
    )
}
