import XCTest
@testable import KeysCore

final class GatewayTests: XCTestCase {
    private let pelican = "PELICAN-7f3a"

    func testProviderRegistryLoadsFixture() throws {
        XCTAssertEqual(Providers.provider(id: "openai")?.host, "api.openai.com")
        XCTAssertEqual(Providers.provider(id: "anthropic")?.authHeader, "x-api-key")
        XCTAssertEqual(Providers.provider(id: "google")?.api, "gemini")
        XCTAssertEqual(Providers.provider(id: "azure-openai")?.host, nil)
        XCTAssertEqual(Providers.provider(id: "azure-openai")?.gateway, true)
        XCTAssertEqual(Providers.provider(id: "bedrock")?.gateway, false)
        let root = try JSONSerialization.jsonObject(with: Providers.rawJSON()) as! [String: Any]
        let list = root["providers"] as! [Any]
        XCTAssertEqual(list.count, 55)
        XCTAssertEqual(Providers.provider(id: "typesafe")?.host, "api.typesafe.ai")
        XCTAssertEqual(Providers.provider(id: "typesafe")?.pathPrefix, "")
    }

    func testPathJoinDoesNotDoublePrefix() {
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "chat/completions"), "/v1/chat/completions")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "v1/chat/completions"), "/v1/chat/completions")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1beta", rest: "models/x"), "/v1beta/models/x")
        XCTAssertEqual(GatewayPath.join(prefix: "", rest: "v1/models"), "/v1/models")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: ""), "/v1")
        // A client-named API version wins over a version-only fixture prefix.
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "v4/ai/evaluation-model"), "/v4/ai/evaluation-model")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1beta", rest: "v1/models"), "/v1/models")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "v1beta/models"), "/v1beta/models")
        // A real path prefix still applies, and a non-version first segment is not a version.
        XCTAssertEqual(GatewayPath.join(prefix: "/api/gateway", rest: "v1/chat/completions"), "/api/gateway/v1/chat/completions")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "vendor/x"), "/v1/vendor/x")
        XCTAssertEqual(GatewayPath.join(prefix: "/v1", rest: "v/x"), "/v1/v/x")
        // A versioned multi-segment prefix (DeepInfra /v1/openai, Novita /v3/openai)
        // is a real path, not a version, so the client's version must not drop it.
        XCTAssertEqual(
            GatewayPath.join(prefix: "/v1/openai", rest: "v1/chat/completions"),
            "/v1/openai/v1/chat/completions"
        )
        XCTAssertEqual(
            GatewayPath.join(prefix: "/v3/openai", rest: "v1/chat/completions"),
            "/v3/openai/v1/chat/completions"
        )
        XCTAssertEqual(
            GatewayPath.join(prefix: "/v1/openai", rest: "chat/completions"),
            "/v1/openai/chat/completions"
        )
        XCTAssertEqual(
            GatewayPath.join(prefix: "/v1/openai", rest: "v1/openai/models"),
            "/v1/openai/models"
        )
    }

    /// A fixture stream fed through the gateway's tee in small chunks, as the proxy sees it.
    private func streamed(_ api: String, _ fixture: String) throws -> GatewayParsedUsage {
        let data = try Data(contentsOf: Fixtures.root.appendingPathComponent(fixture))
        let tee = GatewayTee(api: api)
        tee.setContentType("text/event-stream")
        var rest = data[...]
        while !rest.isEmpty {
            tee.append(Data(rest.prefix(37)))
            rest = rest.dropFirst(37)
        }
        return tee.result(requestBody: Data())
    }

    func testUsageParserOpenAIChatAndResponses() throws {
        let chat = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let parsedChat = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: chat
        )
        XCTAssertEqual(parsedChat.model, "gpt-4.1")
        XCTAssertEqual(parsedChat.inputTokens, 11)
        XCTAssertEqual(parsedChat.outputTokens, 7)
        XCTAssertEqual(parsedChat.cacheReadTokens, 3)

        let responses = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-responses.json"))
        let parsedResp = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(), responseBody: responses
        )
        XCTAssertEqual(parsedResp.inputTokens, 20)
        XCTAssertEqual(parsedResp.outputTokens, 5)
        XCTAssertEqual(parsedResp.cacheReadTokens, 4)
    }

    func testUsageParserOpenAISSELastUsageEvent() throws {
        let parsed = try streamed("openai", "gateway/openai-chat.sse")
        XCTAssertEqual(parsed.model, "gpt-4.1")
        XCTAssertEqual(parsed.inputTokens, 9)
        XCTAssertEqual(parsed.outputTokens, 2)
        XCTAssertEqual(parsed.cacheReadTokens, 1)

        let parsedCompleted = try streamed("openai", "gateway/openai-response.sse")
        XCTAssertEqual(parsedCompleted.model, "gpt-4.1")
        XCTAssertEqual(parsedCompleted.inputTokens, 15)
        XCTAssertEqual(parsedCompleted.outputTokens, 3)
        XCTAssertEqual(parsedCompleted.cacheReadTokens, 2)
    }

    func testUsageParserAnthropicStreamedAndGemini() throws {
        let json = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/anthropic.json"))
        let parsed = GatewayUsageParser.parse(
            api: "anthropic", requestBody: Data(), responseBody: json
        )
        XCTAssertEqual(parsed.model, "claude-sonnet-5")
        XCTAssertEqual(parsed.inputTokens, 12)
        XCTAssertEqual(parsed.outputTokens, 8)
        XCTAssertEqual(parsed.cacheReadTokens, 2)
        XCTAssertEqual(parsed.cacheWriteTokens, 1)

        let stream = try streamed("anthropic", "gateway/anthropic.sse")
        XCTAssertEqual(stream.model, "claude-sonnet-5")
        XCTAssertEqual(stream.inputTokens, 10)
        XCTAssertEqual(stream.outputTokens, 6)
        XCTAssertEqual(stream.cacheReadTokens, 1)
        XCTAssertEqual(stream.cacheWriteTokens, 2)

        // An unlabelled stream whose first chunk is too short to recognise is still a stream.
        let sse = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/anthropic.sse"))
        let tee = GatewayTee(api: "anthropic")
        tee.append(sse.prefix(3))
        tee.append(sse.dropFirst(3))
        XCTAssertEqual(tee.result(requestBody: Data()), stream)

        let gemini = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/gemini.json"))
        let g = GatewayUsageParser.parse(
            api: "gemini",
            requestBody: Data("{\"model\":\"from-request\"}".utf8),
            responseBody: gemini
        )
        XCTAssertEqual(g.model, "gemini-2.0-flash")
        XCTAssertEqual(g.inputTokens, 14)
        XCTAssertEqual(g.outputTokens, 4)
        XCTAssertEqual(g.cacheReadTokens, 2)

        let other = GatewayUsageParser.parse(
            api: "other",
            requestBody: Data("{\"model\":\"x\"}".utf8),
            responseBody: Data("{\"usage\":{\"prompt_tokens\":99}}".utf8)
        )
        XCTAssertEqual(other.model, "x")
        XCTAssertNil(other.inputTokens)
    }

    func testEnableRequiresPresenceAndRejectsNoGatewayProvider() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(gate.reasons, [])
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertTrue(service.isGatewayEnabled("demo"))
        XCTAssertEqual(gate.reasons, ["Unlock demo"])

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
        XCTAssertEqual(row.gatewayHost, "127.0.0.1:9")
    }

    func testUnknownKeyIs401WithoutClientAndDoesNotCallUpstream() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        let (service, gateway) = (rig.service, rig.gateway)

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
    }

    /// A caller's own copy of a non-Authorization auth header must not replace the vault secret.
    func testUpstreamRequestAuthHeaderWinsOverCallerCopy() throws {
        let elevenlabs = try XCTUnwrap(Providers.provider(id: "elevenlabs"))
        XCTAssertEqual(elevenlabs.authHeader, "xi-api-key")
        for callerName in ["xi-api-key", "XI-API-KEY", "Xi-Api-Key"] {
            let req = try XCTUnwrap(elevenlabs.upstreamRequest(
                host: "api.elevenlabs.io", path: "/v1/voices", method: "GET",
                headers: [callerName: "caller-supplied", "Accept-Encoding": "gzip", "X-Trace": "1"],
                secret: "vault-secret", timeout: 5
            ))
            XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "vault-secret", callerName)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Trace"), "1")
            XCTAssertEqual(req.url?.absoluteString, "https://api.elevenlabs.io/v1/voices")
        }
        let local = try XCTUnwrap(elevenlabs.upstreamRequest(
            host: "127.0.0.1:9", path: "/v1/x", query: "a=1", method: "POST", headers: [:], secret: "s", timeout: 5
        ))
        XCTAssertEqual(local.url?.absoluteString, "http://127.0.0.1:9/v1/x?a=1")
    }

    func testRoundTripStripsClientAuthInjectsSecretAndOmitsSentinelFromCatalog() async throws {
        let captured = RequestLog()
        let stubBody = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let rig = try GatewayRig { request in
            captured.record(request)
            return HTTPResponse.data(200, stubBody, type: "application/json")
        }
        defer { rig.stop() }
        let (dir, service, gate, stub) = (rig.dir, rig.service, rig.gate, rig.stub)
        try rig.key(secret: "sk-test-secret")
        XCTAssertEqual(gate.reasons, ["Unlock demo"])
        // Gateway already on: the grant costs one more prompt, naming task, provider and host.
        let token = try grantFor(service, "demo", task: "unit round trip")
        XCTAssertEqual(gate.reasons.count, 2)
        XCTAssertTrue(gate.reasons[1].contains("unit round trip"), gate.reasons[1])
        XCTAssertTrue(gate.reasons[1].contains("OpenAI"), gate.reasons[1])
        XCTAssertTrue(gate.reasons[1].contains("127.0.0.1:\(stub.boundPort)"), gate.reasons[1])

        var req = URLRequest(url: rig.url("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(token, forHTTPHeaderField: "X-KSF-Grant")
        req.setValue("leaked-api-key", forHTTPHeaderField: "x-api-key")
        req.setValue("leaked-google", forHTTPHeaderField: "x-goog-api-key")
        req.setValue("leaked-azure", forHTTPHeaderField: "api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"model\":\"gpt-4.1\",\"messages\":[{\"role\":\"user\",\"content\":\"\(pelican)\"}]}".utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, stubBody)
        let upstream = try XCTUnwrap(captured.last)
        XCTAssertEqual(upstream.headers["authorization"], "Bearer sk-test-secret")
        XCTAssertNil(upstream.headers["x-ksf-client"])
        XCTAssertNil(upstream.headers["x-ksf-grant"])
        XCTAssertFalse(upstream.headers.values.contains { $0.contains(token) }, "the grant token never reaches upstream")
        XCTAssertNotEqual(upstream.headers["x-api-key"], "leaked-api-key")
        XCTAssertNil(upstream.headers["x-api-key"])
        XCTAssertNil(upstream.headers["x-goog-api-key"])
        XCTAssertNil(upstream.headers["api-key"])
        XCTAssertEqual(upstream.path, "/v1/chat/completions")

        let usage = try await rig.usageRows()
        XCTAssertEqual(usage.count, 1)
        let row = try XCTUnwrap(usage.first)
        XCTAssertEqual(row.keyName, "demo")
        XCTAssertEqual(row.provider, "openai")
        XCTAssertEqual(row.model, "gpt-4.1")
        XCTAssertEqual(row.inputTokens, 11)
        XCTAssertEqual(row.outputTokens, 7)
        XCTAssertEqual(row.cachedReadTokens, 3)
        XCTAssertEqual(row.httpStatus, 200)

        assertNoSentinel(pelican, in: dir)

        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let listed = handle(handler, method: "GET", path: "/api/keys")
        XCTAssertEqual(listed.status, 200)
        let listObj = try JSONSerialization.jsonObject(with: listed.body) as! [String: Any]
        let keys = listObj["keys"] as! [[String: Any]]
        XCTAssertEqual(keys[0]["gateway_enabled"] as? Bool, true)
        XCTAssertEqual(keys[0]["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
        XCTAssertNotNil(keys[0]["usd_month"])
        XCTAssertFalse(String(data: listed.body, encoding: .utf8)!.contains("sk-test-secret"))
        XCTAssertFalse(String(data: listed.body, encoding: .utf8)!.contains(pelican))

        let spend = handle(handler, method: "GET", path: "/api/spend", query: ["key": "demo", "range": "month"])
        XCTAssertEqual(spend.status, 200)
        let spendObj = try JSONSerialization.jsonObject(with: spend.body) as! [String: Any]
        let rows = spendObj["rows"] as! [[String: Any]]
        XCTAssertEqual(rows.first?["key"] as? String, "demo")
        XCTAssertEqual(rows.first?["model"] as? String, "gpt-4.1")
        XCTAssertGreaterThan(spendObj["catalog_version"] as? Int ?? 0, 0)
    }

    func testEveryQueryGrantTokenIsStrippedEvenWhenAHeaderCarriesOne() {
        let header = GrantToken.generate(id: "0a0b0c0d")
        let query = GrantToken.generate(id: "01020304")
        let (fromHeader, rest) = GatewayListener.extractGrantToken(
            headers: ["authorization": "Bearer \(header)"], rawQuery: "alt=sse&key=\(query)"
        )
        XCTAssertEqual(fromHeader, header)
        XCTAssertEqual(rest, "alt=sse")

        let (fromQuery, kept) = GatewayListener.extractGrantToken(headers: [:], rawQuery: "key=\(query)&key=AIza-real")
        XCTAssertEqual(fromQuery, query)
        XCTAssertEqual(kept, "key=AIza-real")

        let (encoded, stripped) = GatewayListener.extractGrantToken(headers: [:], rawQuery: "%6Bey=\(query)&KEY=\(header)&alt=sse")
        XCTAssertNotNil(encoded)
        XCTAssertEqual(stripped, "alt=sse")

        let (retired, _) = GatewayListener.extractGrantToken(headers: ["x-ksf-grant": header], rawQuery: "")
        XCTAssertNil(retired, "the X-KSF-Grant alias is retired")

        let (none, untouched) = GatewayListener.extractGrantToken(headers: [:], rawQuery: "alt=sse")
        XCTAssertNil(none)
        XCTAssertEqual(untouched, "alt=sse")
    }

    func testDoesNotFollowRedirects() async throws {
        let secondHits = RequestLog()
        let second = try LoopbackHTTPServer(port: 0) { request in
            secondHits.record(request)
            return HTTPResponse.json(200, ["should": "not"])
        }
        second.start()
        defer { second.stop() }

        let rig = try GatewayRig { _ in
            HTTPResponse(
                status: 302,
                headers: [
                    "Content-Type": "text/plain",
                    "Location": "http://127.0.0.1:\(second.boundPort)/secret",
                ],
                body: Data("moved".utf8)
            )
        }
        defer { rig.stop() }
        try rig.key()
        let token = try grantFor(rig.service, "demo")

        var redirected = URLRequest(url: rig.url("v1/models"))
        redirected.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await noRedirectSession.data(for: redirected)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertEqual(String(data: data, encoding: .utf8), "moved")
        XCTAssertEqual(secondHits.count, 0)
    }

    func testBodyOver8MBIs413() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()

        var req = URLRequest(url: rig.url("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(repeating: UInt8(ascii: "x"), count: GatewayListener.bodyCap + 1)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 413)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("payload too large"))
        XCTAssertEqual(hits.count, 0)
    }

    func testGatewayEnableRouteNeedsTokenAndTouchID() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let without = handle(
            handler, method: "POST", path: "/api/keys/demo/gateway", body: try JSONValue.data(["enabled": true]), token: false
        )
        XCTAssertEqual(without.status, 403)

        let with = handle(handler, method: "POST", path: "/api/keys/demo/gateway", body: try JSONValue.data(["enabled": true]))
        XCTAssertEqual(with.status, 200)
        let obj = try JSONSerialization.jsonObject(with: with.body) as! [String: Any]
        XCTAssertEqual(obj["gateway_enabled"] as? Bool, true)
        XCTAssertEqual(obj["gateway_url"] as? String, "http://127.0.0.1:12767/demo")
    }
}

private let noRedirectSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    return URLSession(configuration: config, delegate: DenyRedirects(), delegateQueue: nil)
}()
