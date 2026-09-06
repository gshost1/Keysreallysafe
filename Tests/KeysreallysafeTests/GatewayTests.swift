import XCTest
@testable import KeysCore

final class GatewayTests: XCTestCase {
    private let pelican = "PELICAN-7f3a"

    func testProviderRegistryLoadsFixture() throws {
        Providers.loadAtStartup()
        XCTAssertEqual(Providers.provider(id: "openai")?.host, "api.openai.com")
        XCTAssertEqual(Providers.provider(id: "anthropic")?.authHeader, "x-api-key")
        XCTAssertEqual(Providers.provider(id: "google")?.api, "gemini")
        XCTAssertEqual(Providers.provider(id: "azure-openai")?.host, nil)
        XCTAssertEqual(Providers.provider(id: "azure-openai")?.gateway, true)
        XCTAssertEqual(Providers.provider(id: "bedrock")?.gateway, false)
        let root = try JSONSerialization.jsonObject(with: Providers.rawJSON()) as! [String: Any]
        let list = root["providers"] as! [Any]
        XCTAssertEqual(list.count, 53)
    }

    func testPathJoinDoesNotDoublePrefix() {
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "chat/completions"), "/v1/chat/completions")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "v1/chat/completions"), "/v1/chat/completions")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1beta", rest: "models/x"), "/v1beta/models/x")
        XCTAssertEqual(GatewayPath.join(prefix: "", rest: "v1/models"), "/v1/models")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: ""), "/v1")
    }

    func testUsageParserOpenAIChatAndResponses() throws {
        let chat = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let parsedChat = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: chat, contentType: "application/json"
        )
        XCTAssertEqual(parsedChat.model, "gpt-4.1")
        XCTAssertEqual(parsedChat.inputTokens, 11)
        XCTAssertEqual(parsedChat.outputTokens, 7)
        XCTAssertEqual(parsedChat.cacheReadTokens, 3)

        let responses = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-responses.json"))
        let parsedResp = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: responses, contentType: "application/json"
        )
        XCTAssertEqual(parsedResp.inputTokens, 20)
        XCTAssertEqual(parsedResp.outputTokens, 5)
        XCTAssertEqual(parsedResp.cacheReadTokens, 4)
    }

    func testUsageParserOpenAISSELastUsageEvent() throws {
        let sse = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.sse"))
        let parsed = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: sse, contentType: "text/event-stream"
        )
        XCTAssertEqual(parsed.model, "gpt-4.1")
        XCTAssertEqual(parsed.inputTokens, 9)
        XCTAssertEqual(parsed.outputTokens, 2)
        XCTAssertEqual(parsed.cacheReadTokens, 1)

        let completed = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-response.sse"))
        let parsedCompleted = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: completed, contentType: "text/event-stream"
        )
        XCTAssertEqual(parsedCompleted.model, "gpt-4.1")
        XCTAssertEqual(parsedCompleted.inputTokens, 15)
        XCTAssertEqual(parsedCompleted.outputTokens, 3)
        XCTAssertEqual(parsedCompleted.cacheReadTokens, 2)
    }

    func testUsageParserAnthropicStreamedAndGemini() throws {
        let json = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/anthropic.json"))
        let parsed = GatewayUsageParser.parse(
            api: "anthropic", requestBody: Data(), responseBody: json, contentType: "application/json"
        )
        XCTAssertEqual(parsed.model, "claude-sonnet-5")
        XCTAssertEqual(parsed.inputTokens, 12)
        XCTAssertEqual(parsed.outputTokens, 8)
        XCTAssertEqual(parsed.cacheReadTokens, 2)
        XCTAssertEqual(parsed.cacheWriteTokens, 1)

        let sse = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/anthropic.sse"))
        let streamed = GatewayUsageParser.parse(
            api: "anthropic", requestBody: Data(), responseBody: sse, contentType: "text/event-stream"
        )
        XCTAssertEqual(streamed.model, "claude-sonnet-5")
        XCTAssertEqual(streamed.inputTokens, 10)
        XCTAssertEqual(streamed.outputTokens, 6)
        XCTAssertEqual(streamed.cacheReadTokens, 1)
        XCTAssertEqual(streamed.cacheWriteTokens, 2)

        let gemini = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/gemini.json"))
        let g = GatewayUsageParser.parse(
            api: "gemini",
            requestBody: Data("{\"model\":\"from-request\"}".utf8),
            responseBody: gemini,
            contentType: "application/json"
        )
        XCTAssertEqual(g.model, "gemini-2.0-flash")
        XCTAssertEqual(g.inputTokens, 14)
        XCTAssertEqual(g.outputTokens, 4)
        XCTAssertEqual(g.cacheReadTokens, 2)

        let other = GatewayUsageParser.parse(
            api: "other",
            requestBody: Data("{\"model\":\"x\"}".utf8),
            responseBody: Data("{\"usage\":{\"prompt_tokens\":99}}".utf8),
            contentType: "application/json"
        )
        XCTAssertEqual(other.model, "x")
        XCTAssertNil(other.inputTokens)
    }

    func testEnableRequiresPresenceAndRejectsNoGatewayProvider() throws {
        let (db, _) = try makeDB()
        let inner = MemorySecretStore()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: inner, presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(gate.reasons, [])
        let enabled = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertTrue(service.isGatewayEnabled("demo"))
        XCTAssertEqual(gate.reasons, ["Unlock demo"])
        XCTAssertEqual(enabled.gatewayEnabled, true)

        try service.add(name: "bedrock-key", provider: "bedrock", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.setGateway(name: "bedrock-key", enabled: true, host: "example.com")) { error in
            guard let app = error as? AppError, case .usage = app else {
                return XCTFail("expected usage, got \(error)")
            }
        }
        XCTAssertFalse(service.isGatewayEnabled("bedrock-key"))

        try service.add(name: "azure", provider: "azure-openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.setGateway(name: "azure", enabled: true, host: nil))
        _ = try service.setGateway(name: "azure", enabled: true, host: "myres.openai.azure.com")
        XCTAssertTrue(service.isGatewayEnabled("azure"))
        XCTAssertEqual(try service.catalog.catalogRow(name: "azure")?.gatewayHost, "myres.openai.azure.com")

        _ = try service.setGateway(name: "demo", enabled: false, host: nil)
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }

    func testRestartClearsEnabledButKeepsHost() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        do {
            let db = try CatalogDB(path: path)
            let (service, _, _) = makeService(db: db)
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:9")
            XCTAssertTrue(service.isGatewayEnabled("demo"))
        }
        let db2 = try CatalogDB(path: path)
        let (service2, _, _) = makeService(db: db2)
        XCTAssertFalse(service2.isGatewayEnabled("demo"))
        let row = try XCTUnwrap(try db2.catalogRow(name: "demo"))
        XCTAssertFalse(row.gatewayEnabled)
        XCTAssertEqual(row.gatewayHost, "127.0.0.1:9")
    }

    func testUnknownKeyIs401WithoutClientAndDoesNotCallUpstream() async throws {
        let hits = HitCounter()
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            hits.bump()
            return HTTPResponse.json(200, ["ok": true])
        }
        stub.start()
        defer { stub.stop() }

        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        // Authentication comes before key lookup, so an unauthenticated caller cannot learn
        // which names have the gateway on.
        let url = URL(string: "http://127.0.0.1:\(gateway.boundPort)/nosuch/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("client_required"))
        XCTAssertEqual(hits.count, 0)
        // A client bound to another key does not turn a missing key into a 404 either.
        try service.add(name: "real", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let token = try service.issueGatewayClient(name: "real", label: "t", methods: ["GET"]).token
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, second) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((second as? HTTPURLResponse)?.statusCode, 401)
        // The right client, but the key has the gateway off: now 404.
        var own = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/real/v1/models")!)
        own.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, third) = try await URLSession.shared.data(for: own)
        XCTAssertEqual((third as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("not_found"))
        XCTAssertEqual(hits.count, 0)
        _ = dir
    }

    func testRoundTripStripsClientAuthInjectsSecretAndOmitsSentinelFromCatalog() async throws {
        let captured = HeaderBox()
        let stubBody = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { request in
            captured.headers = request.headers
            captured.body = request.body
            captured.path = request.path
            return HTTPResponse.data(200, stubBody, type: "application/json")
        }
        stub.start()
        defer { stub.stop() }

        let (db, dir) = try makeDB()
        let inner = MemorySecretStore()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: inner, presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-test-secret")
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        XCTAssertEqual(gate.reasons, ["Unlock demo"])
        let client = try service.issueGatewayClient(name: "demo", label: "sdk").token
        XCTAssertEqual(gate.reasons, ["Unlock demo", "Issue gateway client for demo"])

        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(client)", forHTTPHeaderField: "Authorization")
        req.setValue("leaked-api-key", forHTTPHeaderField: "x-api-key")
        req.setValue("leaked-google", forHTTPHeaderField: "x-goog-api-key")
        req.setValue("leaked-azure", forHTTPHeaderField: "api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"model\":\"gpt-4.1\",\"messages\":[{\"role\":\"user\",\"content\":\"\(pelican)\"}]}".utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, stubBody)
        XCTAssertEqual(captured.headers["authorization"], "Bearer sk-test-secret")
        XCTAssertNil(captured.headers["x-ksf-client"])
        XCTAssertFalse(captured.headers.values.contains { $0.contains(client) }, "the client token never reaches upstream")
        XCTAssertNotEqual(captured.headers["x-api-key"], "leaked-api-key")
        XCTAssertNil(captured.headers["x-api-key"])
        XCTAssertNil(captured.headers["x-goog-api-key"])
        XCTAssertNil(captured.headers["api-key"])
        XCTAssertEqual(captured.path, "/v1/chat/completions")

        // The gateway finishes the client response before it records usage; wait for the row.
        var usage: [GatewayUsageRow] = []
        for _ in 0..<200 where usage.isEmpty {
            usage = try db.gatewayUsage(from: "1970-01-01T00:00:00Z", to: "2099-01-01T00:00:00Z")
            if usage.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        XCTAssertEqual(usage.count, 1)
        let row = try XCTUnwrap(usage.first)
        XCTAssertEqual(row.key, "demo")
        XCTAssertEqual(row.provider, "openai")
        XCTAssertEqual(row.model, "gpt-4.1")
        XCTAssertEqual(row.inputTokens, 11)
        XCTAssertEqual(row.outputTokens, 7)
        XCTAssertEqual(row.cacheReadTokens, 3)
        XCTAssertEqual(row.status, 200)

        try assertNoSentinel(in: dir, catalog: db.path)

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let listed = handler.handle(HTTPRequest(
            method: "GET", path: "/api/keys", query: [:],
            headers: ["host": "127.0.0.1:12765"], body: Data(), serverPort: 12765
        ))
        XCTAssertEqual(listed.status, 200)
        let listObj = try JSONSerialization.jsonObject(with: listed.body) as! [String: Any]
        XCTAssertEqual(listObj["gateway_resets_on_restart"] as? Bool, true)
        let keys = listObj["keys"] as! [[String: Any]]
        XCTAssertEqual(keys[0]["gateway_enabled"] as? Bool, true)
        XCTAssertEqual(keys[0]["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
        XCTAssertNotNil(keys[0]["usd_month"])
        XCTAssertFalse(String(data: listed.body, encoding: .utf8)!.contains("sk-test-secret"))
        XCTAssertFalse(String(data: listed.body, encoding: .utf8)!.contains(pelican))

        let spend = handler.handle(HTTPRequest(
            method: "GET", path: "/api/spend", query: ["key": "demo", "range": "month"],
            headers: ["host": "127.0.0.1:12765"], body: Data(), serverPort: 12765
        ))
        XCTAssertEqual(spend.status, 200)
        let spendObj = try JSONSerialization.jsonObject(with: spend.body) as! [String: Any]
        let rows = spendObj["rows"] as! [[String: Any]]
        XCTAssertEqual(rows.first?["key"] as? String, "demo")
        XCTAssertEqual(rows.first?["model"] as? String, "gpt-4.1")
        XCTAssertGreaterThan(spendObj["catalog_version"] as? Int ?? 0, 0)
    }

    func testDoesNotFollowRedirects() async throws {
        let secondHits = HitCounter()
        let second = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            secondHits.bump()
            return HTTPResponse.json(200, ["should": "not"])
        }
        second.start()
        defer { second.stop() }

        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            HTTPResponse(
                status: 302,
                headers: [
                    "Content-Type": "text/plain",
                    "Location": "http://127.0.0.1:\(second.boundPort)/secret",
                ],
                body: Data("moved".utf8)
            )
        }
        stub.start()
        defer { stub.stop() }

        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        let token = try service.issueGatewayClient(name: "demo", label: "t", methods: ["GET"]).token
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/models")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await noRedirectSession.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertEqual(String(data: data, encoding: .utf8), "moved")
        XCTAssertEqual(secondHits.count, 0)
    }

    func testBodyOver8MBIs413() async throws {
        let hits = HitCounter()
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            hits.bump()
            return HTTPResponse.json(200, ["ok": true])
        }
        stub.start()
        defer { stub.stop() }
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(repeating: UInt8(ascii: "x"), count: GatewayListener.bodyCap + 1)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 413)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("payload too large"))
        XCTAssertEqual(hits.count, 0)
    }

    func testGetProvidersReturnsFixtureVerbatim() throws {
        let (handler, _, _) = try makeAPIHandler()
        let response = handler.handle(HTTPRequest(
            method: "GET", path: "/api/providers", query: [:],
            headers: ["host": "127.0.0.1:12765"], body: Data(), serverPort: 12765
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Providers.rawJSON())
        let root = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertEqual((root["providers"] as? [Any])?.count, 53)
    }

    func testGatewayEnableRouteNeedsTokenAndTouchID() throws {
        let (handler, service, _) = try makeAPIHandler()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let without = handler.handle(HTTPRequest(
            method: "POST",
            path: "/api/keys/demo/gateway",
            query: [:],
            headers: ["host": "127.0.0.1:12765"],
            body: try JSONValue.data(["enabled": true]),
            serverPort: 12765
        ))
        XCTAssertEqual(without.status, 403)

        let with = handler.handle(HTTPRequest(
            method: "POST",
            path: "/api/keys/demo/gateway",
            query: [:],
            headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken],
            body: try JSONValue.data(["enabled": true]),
            serverPort: 12765
        ))
        XCTAssertEqual(with.status, 200)
        let obj = try JSONSerialization.jsonObject(with: with.body) as! [String: Any]
        XCTAssertEqual(obj["gateway_enabled"] as? Bool, true)
        XCTAssertEqual(obj["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
    }

    private func makeAPIHandler() throws -> (APIHandler, KeysService, URL) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html></html>".write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return (APIHandler(service: service, webRoot: web), service, dir)
    }

    private func assertNoSentinel(in dir: URL, catalog: URL) throws {
        let needle = Data(pelican.utf8)
        var urls = [catalog]
        urls.append(URL(fileURLWithPath: catalog.path + "-wal"))
        urls.append(URL(fileURLWithPath: catalog.path + "-shm"))
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                urls.append(url)
            }
        }
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            XCTAssertNil(data.range(of: needle), "sentinel found in \(url.path)")
        }
    }
}

private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }
}

private final class HeaderBox: @unchecked Sendable {
    var headers: [String: String] = [:]
    var body: Data = Data()
    var path: String = ""
}

private final class DenyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private let noRedirectSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    return URLSession(configuration: config, delegate: DenyRedirects(), delegateQueue: nil)
}()
