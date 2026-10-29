import CryptoKit
import Foundation
import XCTest
@testable import KeysCore

/// VAL-SCAN-007..010: the scan_project MCP tool, driven through real server frames
/// (error formatter and output guard included), and its app-side vault_lookup route,
/// driven through the real APIHandler. The tool parses env files inside the MCP
/// process and answers from them alone: names, relative paths, providers,
/// categories, last-4 hints and booleans. The only thing that ever crosses to the
/// app is the SHA-256 hex of a parsed value, and the app answers with matching key
/// NAMES, never a value. Without the app the scan still answers, reporting the
/// vault as honestly unchecked. Every value is an obviously fake body built at
/// runtime; no Keychain, no Touch ID, no network beyond the in-process loopback
/// rig, and no test ever touches the machine's real catalog or installed app.
final class ScanProjectToolTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var groqValue: String { "gsk_" + fakeBody + "03" }
    private var plainValue: String { "sk-" + fakeBody + "04" }
    private var awsAccessValue: String { "AKIA" + fakeBody + "05" }
    private var awsSecretValue: String { fakeBody + "AWSSECRET06" }
    private var vertexValue: String { "vt-" + fakeBody + "07" }
    private var stripeValue: String { "sk_" + fakeBody + "08" }
    private var overlayValue: String { "mk_" + fakeBody + "10" }
    private var clientTokenValue: String { GatewayClientToken.prefix + String(repeating: "a", count: 48) }

    /// The provider overlay is process-wide; every test leaves it empty behind it.
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    // MARK: - Rigs

    /// The in-process app: a real APIHandler over a temp catalog behind a recording
    /// loopback server on an ephemeral port, `control.json` written beside that
    /// catalog — exactly the shape `keys mcp` reaches the installed app through.
    /// The request log holds the wire bytes the in-vault comparison sends; the
    /// recording gate proves that comparison never spends a presence prompt.
    private struct Site {
        let service: KeysService
        let db: CatalogDB
        let gate: RecordingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let log: RequestLog
        let control: URL
    }

    private func makeSite() throws -> Site {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let web = db.path.deletingLastPathComponent().appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return handler.handle(request)
        }
        server.start()
        addTeardownBlock { server.stop() }
        return Site(
            service: service, db: db, gate: gate, handler: handler, server: server, log: log,
            control: ControlFile.url(beside: db.path)
        )
    }

    /// A control URL no live site answers: a fresh temp dir with no control.json in
    /// it, the shape an installed app leaves behind by never having been started.
    private func deadControl() throws -> URL {
        ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
    }

    /// The onboarding group wired over injected seams, never the machine's real
    /// catalog or installed app.
    private func roster(
        control: URL,
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath }
    ) -> MCPToolRegistry {
        MCPToolRegistry(groups: [MCPOnboardingTools(control: control, projectFolder: projectFolder, launch: .neverLaunching)])
    }

    /// One tools/call through real server frames — the surface the model sees.
    private func call(
        _ registry: MCPToolRegistry,
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"scan_project","arguments":\#(argumentsJSON)}}"#,
        ], registry: registry, file: file, line: line)
        XCTAssertEqual(frames.last, "", file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    private func callJSON(
        _ registry: MCPToolRegistry,
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (isError, text) = try call(registry, arguments: arguments, file: file, line: line)
        XCTAssertFalse(isError, "an unexpected tool error: \(text)", file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    /// SHA-256 hex of a value, the form the tool sends and the route compares.
    private func digest(_ value: String) -> String {
        Hex.encode(SHA256.hash(data: Data(value.utf8)))
    }

    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - VAL-SCAN-007 (folder input)

    /// The omitted folder is the projectFolder seam — the process working directory
    /// in production. The seam is pinned with the production default live: the
    /// process cwd IS the scanned root, and a supplied folder wins over it.
    func testOmittedFolderScansTheProcessWorkingDirectory() throws {
        let folder = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: folder)

        // The production default seam: no folder argument, the process cwd moved to
        // the folder the test built. The control seam stays dead, so nothing probes
        // the machine's installed app.
        let saved = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(folder.path))
        defer { fm.changeCurrentDirectoryPath(saved) }
        let result = try callJSON(roster(control: deadControl()), arguments: [:])
        XCTAssertEqual(result["env_files"] as? [String], [".env"], "the cwd is the scanned root")
        XCTAssertEqual(result["vault_check"] as? String, "unavailable", "no app is up")
        let variables = result["variables"] as! [[String: Any]]
        XCTAssertEqual(variables.count, 1)
        XCTAssertEqual(variables[0]["name"] as? String, "ANTHROPIC_API_KEY")
    }

    /// A wired seam stands in for the process cwd the way `MCPRoster` wires it, and
    /// an explicit folder argument beats both.
    func testSuppliedFolderWinsOverTheDefault() throws {
        let seamFolder = try TempDir.make()
        try write("SEAM_ONLY=\(anthropicValue)\n", to: ".env", under: seamFolder)
        let askedFolder = try TempDir.make()
        try write("GROQ_API_KEY=\(groqValue)\n", to: "nested/.env", under: askedFolder)

        let bySeam = try callJSON(roster(control: deadControl(), projectFolder: { seamFolder.path }), arguments: [:])
        XCTAssertEqual(bySeam["env_files"] as? [String], [".env"], "the seam answers when no folder came")

        let byArgument = try callJSON(
            roster(control: deadControl(), projectFolder: { seamFolder.path }),
            arguments: ["folder": askedFolder.path]
        )
        XCTAssertEqual(byArgument["env_files"] as? [String], ["nested/.env"], "the argument wins over the seam")
        let variables = byArgument["variables"] as! [[String: Any]]
        XCTAssertEqual(variables.count, 1)
        XCTAssertEqual(variables[0]["file"] as? String, "nested/.env")
    }

    /// A nonexistent folder, a plain file and a non-string are plain tool errors,
    /// and the messages carry no path.
    func testUnusableFoldersArePathFreeToolErrors() throws {
        let dir = try TempDir.make()
        let missing = dir.appendingPathComponent("no-such-\(UUID().uuidString)").path
        let file = dir.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)

        let control = try deadControl()
        for (label, arguments, message, path) in [
            ("missing folder", ["folder": missing], "that project folder does not exist", missing),
            ("a plain file", ["folder": file.path], "the project folder is not a folder", file.path),
            ("not a string", ["folder": 42] as [String: Any], "folder must be a string", ""),
        ] {
            let (isError, text) = try call(roster(control: control), arguments: arguments)
            XCTAssertTrue(isError, "\(label): a plain refusal, not a scan")
            XCTAssertEqual(text, message, "\(label): the exact path-free message")
            XCTAssertFalse(text.contains(path), "\(label): the message carries no path")
            XCTAssertFalse(text.contains("/"), "\(label): the message carries no filesystem tell")
        }
    }

    // MARK: - VAL-SCAN-008 (result shape)

    /// The exact result: the four top-level keys, the eight per-variable keys,
    /// relative POSIX paths only, and every category the scan classifies.
    func testResultShapeIsExact() throws {
        Providers.setOverlay([
            "my-gw": Providers.Record(
                id: "my-gw", name: "My Gateway", host: nil, api: "other",
                authHeader: "Authorization", authPrefix: "Bearer ", pathPrefix: "",
                gateway: true, keyPrefix: "mk_"
            ),
        ])
        let root = try TempDir.make()
        try write("""
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_API_KEY=\(plainValue)
        MY_GW_API_KEY=\(overlayValue)
        VERTEX_API_KEY=\(vertexValue)
        STRIPE_SECRET_KEY=\(stripeValue)
        AWS_ACCESS_KEY_ID=\(awsAccessValue)
        AWS_SECRET_ACCESS_KEY=\(awsSecretValue)
        DATABASE_URL=postgres://u:p@h/db
        ALREADY_WRAPPED=\(clientTokenValue)
        DEBUG=true
        """, to: ".env", under: root)
        try write("GROQ_API_KEY=\(groqValue)\n", to: "sub/.env.local", under: root)
        try write("services:\n", to: "docker-compose.yml", under: root)
        try write("FROM scratch\n", to: "Dockerfile", under: root)

        let result = try callJSON(roster(control: deadControl(), projectFolder: { root.path }), arguments: [:])
        XCTAssertEqual(Set(result.keys), ["env_files", "docker_files", "vault_check", "variables"],
                       "exactly the four top-level keys")
        XCTAssertEqual(result["env_files"] as? [String], [".env", "sub/.env.local"])
        XCTAssertEqual(result["docker_files"] as? [String], ["docker-compose.yml", "Dockerfile"],
                      "root files only, in the pinned order")
        XCTAssertEqual(result["vault_check"] as? String, "unavailable", "no app is up")

        let variables = result["variables"] as! [[String: Any]]
        XCTAssertEqual(variables.map { $0["name"] as? String }, [
            "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "MY_GW_API_KEY", "VERTEX_API_KEY",
            "STRIPE_SECRET_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
            "DATABASE_URL", "ALREADY_WRAPPED", "GROQ_API_KEY",
        ], "files sorted by path, then line order within a file")
        for variable in variables {
            XCTAssertEqual(
                Set(variable.keys),
                ["name", "file", "provider", "category", "last4", "in_vault", "proxyable", "wrapped"],
                "exactly the eight per-variable keys"
            )
            let path = variable["file"] as! String
            XCTAssertFalse(path.hasPrefix("/"), "a result path is relative")
            XCTAssertFalse(path.contains(root.path), "the canonical root never appears in a result path")
        }

        let byName = Dictionary(variables.map { ($0["name"] as! String, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?["provider"] as? String, "anthropic")
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?["category"] as? String, "provider_key")
        XCTAssertEqual(byName["OPENAI_API_KEY"]?["provider"] as? String, "openai")
        XCTAssertEqual(byName["MY_GW_API_KEY"]?["provider"] as? String, "my-gw",
                       "custom overlay providers resolve")
        XCTAssertEqual(byName["VERTEX_API_KEY"]?["provider"] as? String, "vertex")
        XCTAssertEqual(byName["STRIPE_SECRET_KEY"]?["provider"] as? NSNull, NSNull(),
                       "no rule names it: provider null, the line still reported")
        XCTAssertEqual(byName["AWS_ACCESS_KEY_ID"]?["category"] as? String, "aws_pair")
        XCTAssertEqual(byName["AWS_SECRET_ACCESS_KEY"]?["category"] as? String, "aws_pair")
        XCTAssertEqual(byName["DATABASE_URL"]?["category"] as? String, "credential_url")
        XCTAssertEqual(byName["ALREADY_WRAPPED"]?["category"] as? String, "wrapped")
        XCTAssertEqual(byName["ALREADY_WRAPPED"]?["wrapped"] as? Bool, true)
        XCTAssertEqual(byName["GROQ_API_KEY"]?["wrapped"] as? Bool, false)
        XCTAssertEqual(byName["GROQ_API_KEY"]?["file"] as? String, "sub/.env.local")
        XCTAssertNil(byName["DEBUG"], "a plain flag is not a candidate")
    }

    /// proxyable is the wrapPlan rule seen from the scan: a recognized provider the
    /// gateway actually proxies (gateway on and a host it could reach), never a
    /// token, and never the categories the gateway cannot serve by construction.
    func testProxyableFollowsTheWrapPlanRule() throws {
        Providers.setOverlay([
            "my-gw": Providers.Record(
                id: "my-gw", name: "My Gateway", host: nil, api: "other",
                authHeader: "Authorization", authPrefix: "Bearer ", pathPrefix: "",
                gateway: true, keyPrefix: "mk_"
            ),
        ])
        let root = try TempDir.make()
        try write("""
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_API_KEY=\(plainValue)
        MY_GW_API_KEY=\(overlayValue)
        VERTEX_API_KEY=\(vertexValue)
        STRIPE_SECRET_KEY=\(stripeValue)
        AWS_ACCESS_KEY_ID=\(awsAccessValue)
        AWS_SECRET_ACCESS_KEY=\(awsSecretValue)
        DATABASE_URL=postgres://u:p@h/db
        ALREADY_WRAPPED=\(clientTokenValue)
        """, to: ".env", under: root)

        let result = try callJSON(roster(control: deadControl(), projectFolder: { root.path }), arguments: [:])
        let byName = Dictionary(
            (result["variables"] as! [[String: Any]]).map { ($0["name"] as! String, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?["proxyable"] as? Bool, true,
                       "a recognized gateway provider with a host")
        XCTAssertEqual(byName["OPENAI_API_KEY"]?["proxyable"] as? Bool, true)
        XCTAssertEqual(byName["MY_GW_API_KEY"]?["proxyable"] as? Bool, false,
                       "a gateway provider with no effective host is not proxyable")
        XCTAssertEqual(byName["VERTEX_API_KEY"]?["proxyable"] as? Bool, false,
                       "the gateway does not proxy vertex")
        XCTAssertEqual(byName["STRIPE_SECRET_KEY"]?["proxyable"] as? Bool, false,
                       "no recognized provider")
        XCTAssertEqual(byName["AWS_ACCESS_KEY_ID"]?["proxyable"] as? Bool, false,
                       "an AWS SigV4 pair is not proxyable by construction")
        XCTAssertEqual(byName["AWS_SECRET_ACCESS_KEY"]?["proxyable"] as? Bool, false)
        XCTAssertEqual(byName["DATABASE_URL"]?["proxyable"] as? Bool, false,
                       "a credential URL is not proxyable by construction")
        XCTAssertEqual(byName["ALREADY_WRAPPED"]?["proxyable"] as? Bool, false,
                       "a wrapped token line is not proxyable")
    }

    // MARK: - VAL-SCAN-010 (last 4 only)

    /// No result byte carries more than the last 4 characters of any value: last4 is
    /// exactly the value's tail, and neither any full value nor the fake body the
    /// values share appears anywhere in the tool's text.
    func testNeverMoreThanTheLastFourCharacters() throws {
        let root = try TempDir.make()
        let values = [
            "ANTHROPIC_API_KEY": anthropicValue,
            "GROQ_API_KEY": groqValue,
            "AWS_ACCESS_KEY_ID": awsAccessValue,
            "DATABASE_URL": "postgres://u:p@h/db",
        ]
        try write(
            values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n",
            to: ".env", under: root
        )

        let (isError, text) = try call(roster(control: deadControl(), projectFolder: { root.path }), arguments: [:])
        XCTAssertFalse(isError)
        let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let variables = result["variables"] as! [[String: Any]]
        XCTAssertEqual(variables.count, values.count)
        for variable in variables {
            let name = variable["name"] as! String
            let last4 = variable["last4"] as! String
            XCTAssertEqual(last4, String(values[name]!.suffix(4)), "\(name): exactly the last 4 characters")
            XCTAssertLessThanOrEqual(last4.count, 4)
        }
        for value in values.values + [fakeBody] {
            XCTAssertFalse(text.contains(value), "the full value appears nowhere in the result")
        }
        XCTAssertFalse(text.contains("ksfc_"), "no token shape appears either")
    }

    // MARK: - VAL-SCAN-009 (in-vault comparison)

    /// With the app up, in_vault comes from one app call whose body carries the
    /// SHA-256 hex of each parsed value and nothing else, answered by key name; the
    /// scan reports true for the matched value and false for the rest, and the
    /// comparison spends no presence prompt.
    func testVaultLookupCarriesHashesOnlyAndAnswersByMatch() throws {
        let site = try makeSite()
        try site.service.add(name: "existing", provider: "anthropic", kind: "runtime", notes: "", secret: anthropicValue)
        let prompts = site.gate.reasons.count
        let folder = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\nGROQ_API_KEY=\(groqValue)\n", to: ".env", under: folder)
        try ControlFile.write(port: site.server.boundPort, token: site.handler.originToken, to: site.control)

        let result = try callJSON(roster(control: site.control, projectFolder: { folder.path }), arguments: [:])
        XCTAssertEqual(result["vault_check"] as? String, "app")
        let byName = Dictionary(
            (result["variables"] as! [[String: Any]]).map { ($0["name"] as! String, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?["in_vault"] as? Bool, true,
                       "the value the vault already stores reports in_vault")
        XCTAssertEqual(byName["GROQ_API_KEY"]?["in_vault"] as? Bool, false, "an unknown value reports false")

        // The wire: exactly one vault_lookup, hashes only, the per-launch token on it.
        let lookups = site.log.all.filter { $0.path == "/api/mcp/vault_lookup" }
        XCTAssertEqual(lookups.count, 1, "one comparison call per scan")
        XCTAssertEqual(lookups[0].method, "POST", "a POST, never a state-carrying GET")
        XCTAssertEqual(lookups[0].headers["x-ksf-token"], site.handler.originToken, "origin-token gated")
        let body = String(decoding: lookups[0].body, as: UTF8.self)
        let sent = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        XCTAssertEqual(Set(sent.keys), ["hashes"], "the body carries one field")
        XCTAssertEqual(
            sent["hashes"] as? [String],
            [digest(anthropicValue), digest(groqValue)],
            "the SHA-256 hex of the parsed values, in candidate order"
        )
        for value in [anthropicValue, groqValue, fakeBody] {
            XCTAssertFalse(body.contains(value), "no value crosses the wire: \(value.suffix(4))")
        }

        // And the comparison is not a presence-gated read.
        XCTAssertEqual(site.gate.reasons.count, prompts, "the lookup spends no presence prompt")
    }

    /// The route answers matched KEY NAMES (never a value), one entry per requested
    /// hash in request order, and refuses any request without the origin token.
    func testVaultLookupRouteAnswersNamesAndIsTokenGated() throws {
        let site = try makeSite()
        try site.service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: anthropicValue)
        let prompts = site.gate.reasons.count
        let body = try JSONValue.data(["hashes": [digest(anthropicValue), digest(groqValue)] as [Any]])

        let ok = handle(site.handler, method: "POST", path: "/api/mcp/vault_lookup", body: body)
        XCTAssertEqual(ok.status, 200)
        let payload = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
        let matches = payload["matches"] as! [[String: Any]]
        XCTAssertEqual(matches.count, 2, "one entry per requested hash, in order")
        XCTAssertEqual(matches[0]["hash"] as? String, digest(anthropicValue))
        XCTAssertEqual(matches[0]["key"] as? String, "demo", "a match reports the existing key's name")
        XCTAssertEqual(matches[1]["hash"] as? String, digest(groqValue))
        XCTAssertTrue(matches[1]["key"] is NSNull, "no match answers null, never a value")
        let wire = String(decoding: ok.body, as: UTF8.self)
        XCTAssertFalse(wire.contains(anthropicValue), "the answer carries no value")
        XCTAssertFalse(wire.contains(fakeBody), "not even a fragment of one")

        // Without the origin token the route is 403, wrong token included.
        XCTAssertEqual(
            handle(site.handler, method: "POST", path: "/api/mcp/vault_lookup", body: body, token: false).status,
            403, "no token"
        )
        XCTAssertEqual(
            handle(
                site.handler, method: "POST", path: "/api/mcp/vault_lookup",
                headers: ["x-ksf-token": "not-the-token"], body: body, token: false
            ).status,
            403, "a wrong token"
        )

        // Malformed bodies are the house 400 envelope; a GET never carries state.
        for bad in [["hashes": "not-a-list"] as [String: Any], ["hashes": [42] as [Any]], ["other": []], [:]] {
            let response = handle(site.handler, method: "POST", path: "/api/mcp/vault_lookup",
                                 body: try JSONValue.data(bad))
            XCTAssertEqual(response.status, 400, "refused: \(bad)")
            let envelope = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            XCTAssertEqual(envelope["error"] as? String, "hashes must be a list of SHA-256 hex strings")
        }
        let notHex = try JSONValue.data(["hashes": ["zz"] as [Any]])
        let badHex = handle(site.handler, method: "POST", path: "/api/mcp/vault_lookup", body: notHex)
        XCTAssertEqual(badHex.status, 400, "a non-hex hash is refused")
        XCTAssertEqual(
            handle(site.handler, method: "GET", path: "/api/mcp/vault_lookup").status,
            405, "the route is a POST"
        )
        XCTAssertEqual(site.gate.reasons.count, prompts, "the route never prompts")
    }

    /// Without the app the scan still answers everything it can, fast, and reports
    /// the vault as honestly unchecked: in_vault is null and vault_check says
    /// unavailable — for every control-file shape that reads as "no live site",
    /// and never as the not-running crash.
    func testScanDegradesHonestlyWithoutTheApp() throws {
        let folder = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: folder)
        try write("FROM scratch\n", to: "Dockerfile", under: folder)

        // Absent, malformed and dead-owner control files: the contract's "no app" shapes.
        var controls: [(label: String, url: URL)] = [("absent", try deadControl())]
        for (label, text) in [("invalid json", #"not json"#), ("pid 0", #"{"port":443,"pid":0,"token":"t"}"#)] {
            let dir = try TempDir.make()
            let url = dir.appendingPathComponent("control.json")
            try Data(text.utf8).write(to: url)
            controls.append((label, url))
        }

        for control in controls {
            let started = Date()
            let (isError, text) = try call(
                roster(control: control.url, projectFolder: { folder.path }), arguments: [:]
            )
            XCTAssertLessThanOrEqual(
                Date().timeIntervalSince(started), 2,
                "\(control.label): the scan answers within the sweep's 2 s bound"
            )
            XCTAssertFalse(isError, "\(control.label): the scan still succeeds")
            XCTAssertNotEqual(text, AppConnection.notRunningMessage,
                              "\(control.label): the not-running sentence is no crash here")
            let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            XCTAssertEqual(result["vault_check"] as? String, "unavailable", "\(control.label)")
            XCTAssertEqual(result["env_files"] as? [String], [".env"], "\(control.label): the scan itself answered")
            XCTAssertEqual(result["docker_files"] as? [String], ["Dockerfile"])
            let variables = result["variables"] as! [[String: Any]]
            XCTAssertEqual(variables.count, 1)
            XCTAssertTrue(variables[0]["in_vault"] is NSNull,
                          "\(control.label): honestly unknown, never guessed")
            XCTAssertEqual(variables[0]["name"] as? String, "ANTHROPIC_API_KEY")
            XCTAssertEqual(variables[0]["last4"] as? String, String(anthropicValue.suffix(4)))
        }
    }

    // MARK: - VAL-INT-004 (the scan_run onboarding counter)

    /// The app side of a scan records the onboarding `scan_run` counter once per
    /// scan — the vault comparison is the scan's only app touchpoint — and records
    /// nothing at all while analytics sharing is off (the opt-in gate).
    func testScanProjectRecordsScanRunOnlyWhenSharingIsOn() throws {
        let site = try makeSite()
        let transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: site.db, transport: transport)
        site.service.analytics = analytics
        let folder = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: folder)
        try ControlFile.write(port: site.server.boundPort, token: site.handler.originToken, to: site.control)
        let registry = roster(control: site.control, projectFolder: { folder.path })

        func counts() throws -> [String: Int]? {
            (((try analytics.status()["preview"] as? [String: Any])?["reports"] as? [[String: Any]])?
                .first?["counts"] as? [String: Int])
        }

        _ = try callJSON(registry, arguments: [:])
        XCTAssertNil(try counts(), "sharing is off: the scan records nothing")

        try analytics.setEnabled(true, consentVersion: 2)
        _ = try callJSON(registry, arguments: [:])
        XCTAssertEqual(try counts(), ["scan_run": 1], "one scan records one scan_run")
    }
}
