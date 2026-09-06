import XCTest
@testable import KeysCore

/// Read-only connection and model checks with actionable, secret-free errors.
final class ProviderCheckTests: XCTestCase {
    private final class FakeFetcher: ProviderCheckFetching, @unchecked Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: Error?
        private(set) var requests: [URLRequest] = []
        func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let error { throw error }
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, http)
        }
    }

    private func service(with fetcher: FakeFetcher) throws -> (KeysService, RecordingPresenceGate, CatalogDB) {
        let (db, _) = try makeDB()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: MemorySecretStore(), presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        service.checker = fetcher
        return (service, gate, db)
    }

    func testEndpointsAreReadOnlyAndProviderSpecific() throws {
        XCTAssertEqual(ProviderCheck.endpoint(for: Providers.provider(id: "openai")!)?.path, "/v1/models")
        XCTAssertEqual(ProviderCheck.endpoint(for: Providers.provider(id: "groq")!)?.path, "/openai/v1/models")
        let anthropic = try XCTUnwrap(ProviderCheck.endpoint(for: Providers.provider(id: "anthropic")!))
        XCTAssertEqual(anthropic.path, "/v1/models")
        XCTAssertEqual(anthropic.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(ProviderCheck.endpoint(for: Providers.provider(id: "google")!)?.path, "/v1beta/models")
        XCTAssertNil(ProviderCheck.endpoint(for: Providers.provider(id: "elevenlabs")!), "api=other: never probe")
        XCTAssertNil(ProviderCheck.endpoint(for: Providers.provider(id: "bedrock")!))
    }

    func testParsersForThreeShapes() {
        let openai = Data(#"{"object":"list","data":[{"id":"gpt-4.1"},{"id":"o3"},{"id":"gpt-4.1"}]}"#.utf8)
        XCTAssertEqual(ProviderCheck.parseModels(api: "openai", data: openai), ["gpt-4.1", "o3"])
        let anthropic = Data(#"{"data":[{"type":"model","id":"claude-sonnet-5"}],"has_more":false}"#.utf8)
        XCTAssertEqual(ProviderCheck.parseModels(api: "anthropic", data: anthropic), ["claude-sonnet-5"])
        let gemini = Data(#"{"models":[{"name":"models/gemini-2.0-flash"},{"name":"models/embedding-001"}]}"#.utf8)
        XCTAssertEqual(ProviderCheck.parseModels(api: "gemini", data: gemini), ["embedding-001", "gemini-2.0-flash"])
        XCTAssertEqual(ProviderCheck.parseModels(api: "openai", data: Data("not json".utf8)), [])
    }

    func testOkCheckUsesCachedGatewaySecretAndPersistsCompactResult() throws {
        let fetcher = FakeFetcher()
        fetcher.body = Data(#"{"data":[{"id":"gpt-4.1"},{"id":"o3"}]}"#.utf8)
        fetcher.headers = ["x-request-id": "req_123"]
        let (service, gate, db) = try service(with: fetcher)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-secret-value")

        let first = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertEqual(gate.reasons[0], "Check demo against OpenAI at api.openai.com (read-only)")
        XCTAssertEqual(first.outcome, .ok)
        XCTAssertEqual(first.models, ["gpt-4.1", "o3"])
        XCTAssertEqual(first.requestId, "req_123")
        XCTAssertEqual(first.host, "api.openai.com")
        let req = try XCTUnwrap(fetcher.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret-value")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")

        // Reuse within the task: no second unlock, no second request.
        let cached = try XCTUnwrap(try service.lastCheck(name: "demo"))
        XCTAssertEqual(cached, first)
        XCTAssertEqual(gate.reasons.count, 1)
        XCTAssertEqual(fetcher.requests.count, 1)

        // With the gateway on, the in-memory secret is used: no prompt at all.
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertEqual(gate.reasons.count, 2)
        _ = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(gate.reasons.count, 2)
        XCTAssertEqual(fetcher.requests.count, 2)

        // Nothing secret in the catalog or the audit log.
        let raw = try Data(contentsOf: db.path)
        XCTAssertNil(raw.range(of: Data("sk-secret-value".utf8)))
        let events = try service.keyEvents(name: "demo")
        XCTAssertEqual(events.first?.action, "check")
        XCTAssertTrue(events.first?.detail?.contains("2 models") == true, events.first?.detail ?? "")
    }

    func testErrorsAreDistinctAndScrubbed() throws {
        let fetcher = FakeFetcher()
        let (service, _, _) = try service(with: fetcher)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-secret-value")

        fetcher.status = 401
        fetcher.body = Data(#"{"error":{"message":"Incorrect API key provided: sk-secret-value","type":"invalid_request_error"}}"#.utf8)
        let unauth = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(unauth.outcome, .providerAuthFailed)
        XCTAssertEqual(unauth.httpStatus, 401)
        XCTAssertFalse(unauth.message!.contains("sk-secret-value"))
        XCTAssertTrue(unauth.message!.contains("[redacted]"))

        fetcher.status = 403
        fetcher.headers = ["cf-ray": "abc-SJC"]
        fetcher.body = Data(#"{"error":"access denied for this key"}"#.utf8)
        let refused = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(refused.outcome, .providerRefused, "403 is not 'invalid key'")
        XCTAssertEqual(refused.requestId, "abc-SJC")
        XCTAssertEqual(refused.message, "access denied for this key")
        XCTAssertTrue(refused.summary.contains("recognised but not allowed"), refused.summary)

        fetcher.status = 308
        fetcher.headers = ["Location": "https://app.router.com/v1/models"]
        fetcher.body = Data()
        let moved = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(moved.outcome, .redirect)
        XCTAssertEqual(moved.message, "api.openai.com redirects to app.router.com; the key was not sent there")
        XCTAssertTrue(moved.summary.contains("host moved"), moved.summary)
        fetcher.headers = [:]

        fetcher.status = 500
        fetcher.body = Data("<html>boom</html>".utf8)
        let err = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(err.outcome, .providerError)
        XCTAssertNil(err.message, "HTML bodies are never echoed")

        fetcher.status = 200
        fetcher.body = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertEqual(try service.checkProvider(name: "demo", caller: "test").outcome, .malformed)

        fetcher.error = URLError(.cannotConnectToHost)
        let net = try service.checkProvider(name: "demo", caller: "test")
        XCTAssertEqual(net.outcome, .network)
        XCTAssertNil(net.httpStatus)

        // No endpoint: nothing sent, nothing billed.
        fetcher.error = nil
        let before = fetcher.requests.count
        try service.add(name: "voice", provider: "elevenlabs", kind: "runtime", notes: "", secret: "el-secret")
        let none = try service.checkProvider(name: "voice", caller: "test")
        XCTAssertEqual(none.outcome, .noCheckEndpoint)
        XCTAssertEqual(fetcher.requests.count, before)

        // Host required for per-account providers.
        try service.add(name: "az", provider: "azure-openai", kind: "runtime", notes: "", secret: "az-secret")
        XCTAssertThrowsError(try service.checkProvider(name: "az", caller: "test"))
    }

    func testAuthErrorsAreDistinctInCLIAndAPI() throws {
        XCTAssertEqual(AppError.authCancelled.exitCode, 3)
        XCTAssertEqual(AppError.authUnavailable("x").exitCode, 3)
        XCTAssertTrue(AppError.authCancelled.description.contains("cancelled"))
        XCTAssertTrue(AppError.authUnavailable("no interactive session").description.contains("no interactive session"))
        if case .authCancelled = LocalPresenceGate.map(LAErrorShim.make(.userCancel)) {} else { XCTFail("userCancel") }
        if case .authFailed = LocalPresenceGate.map(LAErrorShim.make(.authenticationFailed)) {} else { XCTFail("authenticationFailed") }
        if case .authUnavailable = LocalPresenceGate.map(LAErrorShim.make(.notInteractive)) {} else {
            XCTFail("notInteractive should be unavailable")
        }

        let (db, dir) = try makeDB()
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        for (error, status, code) in [
            (AppError.authCancelled, 403, "auth_cancelled"),
            (AppError.authUnavailable("sandbox"), 503, "auth_unavailable"),
            (AppError.authFailed, 403, "auth_failed"),
        ] {
            let service = KeysService(
                catalog: db, secrets: ThrowingSecretStore(error), clipboard: FakeClipboard(),
                grokHome: Fixtures.grokHome, claudeHome: Fixtures.claudeHome, codexHome: Fixtures.codexHome
            )
            try? db.insertCatalog(CatalogRow(name: "demo", provider: "openai", kind: "runtime", notes: "", createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil))
            let handler = APIHandler(service: service, webRoot: web)
            let r = handler.handle(HTTPRequest(
                method: "POST", path: "/api/keys/demo/reveal", query: [:],
                headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken], body: Data(), serverPort: 12765
            ))
            XCTAssertEqual(r.status, status, code)
            let obj = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
            XCTAssertEqual(obj["error"] as? String, code)
            XCTAssertNotNil(obj["message"])
        }
    }

    func testCheckRoutes() throws {
        let fetcher = FakeFetcher()
        fetcher.body = Data(#"{"data":[{"id":"gpt-4.1"}]}"#.utf8)
        let (service, _, _) = try service(with: fetcher)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "sk-secret-value")
        let web = try TempDir.make()
        let handler = APIHandler(service: service, webRoot: web)
        let host = ["host": "127.0.0.1:12765"]
        let authed = ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken]

        let none = handler.handle(HTTPRequest(method: "GET", path: "/api/keys/demo/check", query: [:], headers: host, body: Data(), serverPort: 12765))
        XCTAssertEqual(none.status, 404)
        let run = handler.handle(HTTPRequest(method: "POST", path: "/api/keys/demo/check", query: [:], headers: authed, body: Data(), serverPort: 12765))
        XCTAssertEqual(run.status, 200)
        let obj = try JSONSerialization.jsonObject(with: run.body) as! [String: Any]
        XCTAssertEqual(obj["outcome"] as? String, "ok")
        XCTAssertEqual(obj["models"] as? [String], ["gpt-4.1"])
        XCTAssertFalse(String(data: run.body, encoding: .utf8)!.contains("sk-secret-value"))
        let again = handler.handle(HTTPRequest(method: "GET", path: "/api/keys/demo/check", query: [:], headers: host, body: Data(), serverPort: 12765))
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(fetcher.requests.count, 1)
        let keys = handler.handle(HTTPRequest(method: "GET", path: "/api/keys", query: [:], headers: host, body: Data(), serverPort: 12765))
        let row = ((try JSONSerialization.jsonObject(with: keys.body) as! [String: Any])["keys"] as! [[String: Any]])[0]
        XCTAssertEqual((row["last_check"] as? [String: Any])?["model_count"] as? Int, 1)
    }
}

import LocalAuthentication

enum LAErrorShim {
    static func make(_ code: LAError.Code) -> LAError {
        LAError(_nsError: NSError(domain: LAError.errorDomain, code: code.rawValue))
    }
}
