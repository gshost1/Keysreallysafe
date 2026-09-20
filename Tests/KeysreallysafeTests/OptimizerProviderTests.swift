import Foundation
import XCTest
@testable import KeysCore

extension OptimizerAPITests {
    func testCompatibleKeyDiscoveryReadsOnlyMetadataAndRejectsWrongHosts() throws {
        let h = try harness()
        for (name, provider) in [("direct", "typesafe"), ("gateway", "vercel-ai-gateway"),
                                 ("other", "openai"), ("wrong-host", "typesafe")] {
            try h.service.add(name: name, provider: provider, kind: "runtime", notes: "private note sentinel", secret: "synthetic-secret-sentinel")
        }
        _ = try h.service.catalog.updateGateway(name: "wrong-host", enabled: false, host: "api.typesafe.ai.attacker.invalid")
        h.presence.error = .authCancelled
        let count = h.presence.reasons.count
        let result = try h.optimizer.compatibleKeys(service: h.service)
        let keys = try XCTUnwrap(result["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.compactMap { $0["name"] as? String }, ["direct", "gateway"])
        XCTAssertEqual(keys.first?["model_id"] as? String, "jev-latest")
        XCTAssertEqual(h.presence.reasons.count, count)
        XCTAssertTrue(h.service.listGrants().isEmpty)
        XCTAssertFalse(h.optimizer.store.isUnlocked)
        let json = String(decoding: try JSONValue.data(result), as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic-secret-sentinel"))
        XCTAssertFalse(json.contains("private note sentinel"))
        XCTAssertFalse(json.contains("api.typesafe.ai.attacker.invalid"))
        for item in keys {
            XCTAssertEqual(Set(item.keys), ["name", "provider", "label", "model_id", "features"])
        }
    }

    func testDirectTypeSafeUnlockUsesScopedGrantAndAttributesUnknownCost() throws {
        let capture = ProviderEngineCapture()
        let h = try harness(engine: { _, environment in
            capture.record(environment)
            return ["ok": true, "status": "suggested", "applied": false,
                    "usage": ["requests": 1, "cache_hits": 0, "actual_input_tokens": 30, "actual_output_tokens": 0]]
        })
        let admin = try unlock(h), project = try addProject(h, admin, provider: true)
        try h.service.add(name: "direct", provider: "typesafe", kind: "runtime", notes: "", secret: "synthetic-direct-secret")
        let before = h.presence.reasons.count
        let response = try request(h, path: "/api/optimizer/unlock", body: ["project_id": project, "jev_key": "direct", "writable": false])
        XCTAssertEqual(response.0, 200, "\(response.1)")
        XCTAssertEqual(h.presence.reasons.count, before + 1)
        let token = try XCTUnwrap(response.1["token"] as? String)
        let grant = try XCTUnwrap(h.service.listGrants().first)
        XCTAssertEqual(grant.provider, "typesafe")
        XCTAssertEqual(grant.host, "api.typesafe.ai")
        XCTAssertEqual(grant.paths, ["/v1/systemone"])
        XCTAssertEqual(grant.methods, ["POST"])
        XCTAssertEqual(grant.maxRequests, 100)
        XCTAssertEqual(grant.jevProvider, "typesafe")
        XCTAssertEqual(grant.jsonObject()["exact_paths"] as? Bool, true)
        XCTAssertEqual(try rpc(h, token, "assess_memory", ["project_id": project, "request_text": "Use fixture tests", "proposed_memory": "Run tests"]).0, 200)
        XCTAssertEqual(capture.environment["KEYS_JEV_PROVIDER"], "typesafe")
        XCTAssertEqual(capture.environment["AI_GATEWAY_BASE_URL"], "http://127.0.0.1:12767/direct/v1/systemone")
        XCTAssertTrue(capture.environment["AI_GATEWAY_API_KEY"]?.hasPrefix("ksf_") == true)
        XCTAssertFalse(capture.environment.values.contains("synthetic-direct-secret"))
        let events = try rpc(h, token, "event_list", ["project_id": project]).1["events"] as? [[String: Any]]
        let event = try XCTUnwrap(events?.first)
        XCTAssertEqual(event["model"] as? String, "jev-latest")
        XCTAssertEqual(event["input_tokens"] as? Int, 30)
        XCTAssertNil(event["reported_cost_usd"] as? Double)
        _ = try request(h, path: "/api/optimizer/close", token: token)
        XCTAssertTrue(h.service.grants.grant(id: grant.id)?.isRevoked == true)
    }

    func testUnsupportedAndMismatchedProviderKeysFailBeforePresence() throws {
        let h = try harness()
        for (name, provider, host) in [("other", "openai", "api.typesafe.ai"),
                                       ("direct-wrong", "typesafe", "ai-gateway.vercel.sh"),
                                       ("gateway-wrong", "vercel-ai-gateway", "api.typesafe.ai")] {
            try h.service.add(name: name, provider: provider, kind: "runtime", notes: "", secret: "synthetic")
            _ = try h.service.catalog.updateGateway(name: name, enabled: false, host: host)
            let count = h.presence.reasons.count
            XCTAssertEqual(try request(h, path: "/api/optimizer/unlock", body: ["jev_key": name]).0, 400)
            XCTAssertEqual(h.presence.reasons.count, count)
        }
        XCTAssertTrue(h.service.listGrants().isEmpty)
    }

    func testLauncherGrantEndpointRejectsMutatedProviderMetadataBeforePresence() throws {
        let h = try harness()
        try h.service.add(name: "direct", provider: "typesafe", kind: "runtime", notes: "", secret: "synthetic")
        let original = Providers.testFixtureURL
        let baseline = try JSONSerialization.jsonObject(with: Providers.rawJSON()) as! [String: Any]
        let fixture = h.directory.appendingPathComponent("provider-fixture.json")
        defer { Providers.testFixtureURL = original; Providers.resetCache() }
        for (field, value) in [("auth_header", "x-api-key"), ("auth_prefix", "Token "),
                               ("api", "openai"), ("path_prefix", "/v1"), ("host", "other.invalid")] {
            var changed = baseline
            changed["providers"] = (baseline["providers"] as! [[String: Any]]).map { entry in
                var entry = entry
                if entry["id"] as? String == "typesafe" { entry[field] = value }
                return entry
            }
            try JSONValue.data(changed).write(to: fixture)
            Providers.testFixtureURL = fixture; Providers.resetCache()
            let count = h.presence.reasons.count
            let response = try request(h, path: "/api/keys/direct/grants", body: [
                "task": "fixture", "methods": ["POST"], "paths": ["/v1/systemone"], "jev_provider": "typesafe",
            ])
            XCTAssertEqual(response.0, 400, field)
            XCTAssertEqual(h.presence.reasons.count, count, field)
            XCTAssertTrue(h.service.listGrants().isEmpty)
        }
    }

    func testLauncherGrantResponseConfirmsReviewedRouteMetadata() throws {
        let h = try harness()
        for adapter in OptimizerProvider.supported {
            try h.service.add(name: adapter.id, provider: adapter.id, kind: "runtime", notes: "", secret: "synthetic")
            let response = try request(h, path: "/api/keys/\(adapter.id)/grants", body: [
                "task": "fixture", "methods": ["POST"], "paths": [adapter.path], "jev_provider": adapter.id,
            ])
            XCTAssertEqual(response.0, 201, "\(response.1)")
            XCTAssertEqual(response.1["jev_provider"] as? String, adapter.id)
            XCTAssertEqual(response.1["exact_paths"] as? Bool, true)
            XCTAssertEqual(response.1["base_url"] as? String, "http://127.0.0.1:12767/\(adapter.id)\(adapter.pathPrefix)")
            XCTAssertEqual(response.1["auth_header"] as? String, "Authorization")
            XCTAssertEqual(response.1["paths"] as? [String], [adapter.path])
        }
    }
}

final class TypeSafeUsageTests: XCTestCase {
    func testReviewedGrantsUseExactPathsAndOrdinaryGrantsKeepPrefixes() throws {
        for adapter in OptimizerProvider.supported {
            let store = GrantStore()
            let issued = store.issue(key: "key", provider: adapter.id, host: adapter.host,
                request: try GrantRequest(task: "fixture", methods: ["POST"], paths: [adapter.path], maxRequests: 1, jevProvider: adapter.id).validated())
            for rest in [String(adapter.path.dropFirst()) + "/anything", String(adapter.path.dropFirst()) + "-other",
                         String(adapter.path.dropFirst()) + "%2fanything", "/" + String(adapter.path.dropFirst())] {
                guard case .failure(.path) = store.authorize(token: issued.token, key: "key", host: adapter.host,
                    method: "POST", rest: rest, providerPrefix: adapter.pathPrefix) else { return XCTFail("accepted \(rest)") }
            }
            guard case .success(let grant) = store.authorize(token: issued.token, key: "key", host: adapter.host,
                method: "POST", rest: String(adapter.path.dropFirst()), providerPrefix: adapter.pathPrefix) else { return XCTFail("exact route denied") }
            XCTAssertEqual(grant.requests, 1)
        }
        let store = GrantStore()
        let ordinary = store.issue(key: "key", provider: "openai", host: "api.openai.com",
            request: GrantRequest(task: "ordinary", methods: ["GET"], paths: ["/models"]))
        guard case .success = store.authorize(token: ordinary.token, key: "key", host: "api.openai.com",
            method: "GET", rest: "v1/models/example", providerPrefix: "/v1") else { return XCTFail("ordinary prefix semantics changed") }
    }

    func testMetadataChangedDuringPresenceFailsBeforeSecretRead() throws {
        let (db, directory) = try makeDB()
        let secrets = PresenceMutationSecrets()
        let service = KeysService(catalog: db, secrets: secrets, clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome, claudeHome: Fixtures.claudeHome, codexHome: Fixtures.codexHome)
        try service.add(name: "direct", provider: "typesafe", kind: "runtime", notes: "", secret: "synthetic")
        let original = Providers.testFixtureURL
        var fixture = try JSONSerialization.jsonObject(with: Providers.rawJSON()) as! [String: Any]
        fixture["providers"] = (fixture["providers"] as! [[String: Any]]).map { entry in
            var entry = entry
            if entry["id"] as? String == "typesafe" { entry["auth_prefix"] = "Token " }
            return entry
        }
        let url = directory.appendingPathComponent("changed-provider.json")
        try JSONValue.data(fixture).write(to: url)
        defer { Providers.testFixtureURL = original; Providers.resetCache() }
        secrets.onPresence = { Providers.testFixtureURL = url; Providers.resetCache() }
        XCTAssertThrowsError(try service.issueGrant(name: "direct", request: GrantRequest(task: "fixture",
            methods: ["POST"], paths: ["/v1/systemone"], jevProvider: "typesafe")))
        XCTAssertEqual(secrets.reads, 0)
        XCTAssertTrue(service.listGrants().isEmpty)
        XCTAssertNil(service.lookupGateway(name: "direct"))
    }

    func testDirectGatewayRoundTripKeepsGrantScopedAndStoresOnlyUsage() async throws {
        let capture = DirectGatewayCapture()
        let sentinel = "synthetic-private-context-4e8a"
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { request in
            capture.record(request)
            return HTTPResponse.json(200, ["model": "jev-1.13.0", "answers": ["keep": ["type": "noul", "noul": 0.9]],
                "usage": ["input_tokens": 55, "output_tokens": 0], "private": sentinel])
        }
        stub.start()
        defer { stub.stop() }
        let (db, directory) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "direct", provider: "typesafe", kind: "runtime", notes: "", secret: "synthetic-upstream-secret")
        _ = try service.setGateway(name: "direct", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let grant = try service.issueGrant(name: "direct", request: GrantRequest(task: "fixture", methods: ["POST"], paths: ["/v1/systemone"], maxRequests: 1))
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }
        func request(_ path: String, method: String = "POST") -> URLRequest {
            var value = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/direct\(path)")!)
            value.httpMethod = method
            value.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
            if method == "POST" { value.httpBody = try? JSONValue.data(["model": "jev-latest", "state": sentinel, "questions": [:]]) }
            return value
        }
        for denied in [request("/v1/models", method: "GET"), request("/v4/ai/evaluation-model"), request("/v1/systemone", method: "GET")] {
            let (_, response) = try await URLSession.shared.data(for: denied)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        }
        XCTAssertEqual(capture.count, 0)
        let (_, response) = try await URLSession.shared.data(for: request("/v1/systemone"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let upstream = try XCTUnwrap(capture.last)
        XCTAssertEqual(upstream.path, "/v1/systemone")
        XCTAssertEqual(upstream.headers["authorization"], "Bearer synthetic-upstream-secret")
        XCTAssertFalse(upstream.headers.values.contains { $0.contains(grant.token) })
        let (_, exhausted) = try await URLSession.shared.data(for: request("/v1/systemone"))
        XCTAssertEqual((exhausted as? HTTPURLResponse)?.statusCode, 429)
        var rows: [GatewayUsageRow] = []
        for _ in 0..<200 where rows.isEmpty {
            rows = try db.gatewayUsage(from: "1970-01-01T00:00:00Z", to: "2099-01-01T00:00:00Z")
            if rows.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.model, "jev-1.13.0")
        XCTAssertEqual(row.inputTokens, 55)
        XCTAssertEqual(row.outputTokens, 0)
        XCTAssertNil(row.usd)
        XCTAssertEqual(try service.monthGatewayByKey()["direct"]?.kind, "unknown")
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if let bytes = try? Data(contentsOf: url) { XCTAssertNil(bytes.range(of: Data(sentinel.utf8))) }
        }
    }

    func testDirectUsageUsesSnakeCaseAndNeverAssumesVercelCost() throws {
        let result = GatewayUsageParser.parse(api: "typesafe-systemone",
            requestBody: Data(#"{"model":"jev-latest"}"#.utf8),
            responseBody: Data(#"{"model":"jev-1.13.0","answers":{},"usage":{"input_tokens":123,"output_tokens":0,"inputTokens":999},"providerMetadata":{"gateway":{"cost":"1.00"}}}"#.utf8),
            contentType: "application/json", requestModel: "forged-header")
        XCTAssertEqual(result.model, "jev-1.13.0")
        XCTAssertEqual(result.inputTokens, 123)
        XCTAssertEqual(result.outputTokens, 0)
        XCTAssertNil(result.reportedCostUsdTicks)
        XCTAssertNil(GatewayEstimate.usd(model: "gpt-4.1", input: 1_000_000, output: 1, cacheRead: 0, cacheWrite: 0, api: "typesafe-systemone"))
        for value in ["true", "-1", "1.5", "1e100", "null", #""3""#] {
            let invalid = GatewayUsageParser.parse(api: "typesafe-systemone", requestBody: Data(#"{"model":"jev-latest"}"#.utf8),
                responseBody: Data("{\"usage\":{\"input_tokens\":\(value),\"output_tokens\":\(value)}}".utf8), contentType: "application/json")
            XCTAssertNil(invalid.inputTokens)
            XCTAssertNil(invalid.outputTokens)
            XCTAssertEqual(invalid.model, "jev-latest")
        }
    }

    func testAdapterRejectsChangedAuthenticationOrPathPrefix() throws {
        let adapter = try XCTUnwrap(OptimizerProvider.supported.first { $0.id == "typesafe" })
        var record = try XCTUnwrap(Providers.provider(id: "typesafe"))
        XCTAssertTrue(adapter.accepts(record))
        record.authHeader = "x-api-key"
        XCTAssertFalse(adapter.accepts(record))
        record.authHeader = "Authorization"
        record.pathPrefix = "/unreviewed/proxy"
        XCTAssertFalse(adapter.accepts(record))
    }
}

private final class ProviderEngineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String] = [:]
    var environment: [String: String] { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ environment: [String: String]) { lock.lock(); value = environment; lock.unlock() }
}

private final class DirectGatewayCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    var last: HTTPRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    func record(_ request: HTTPRequest) { lock.lock(); requests.append(request); lock.unlock() }
}

private final class PresenceMutationSecrets: SecretStore, @unchecked Sendable {
    var onPresence: (() -> Void)?
    private(set) var reads = 0
    func add(name: String, secret: String) throws {}
    func delete(name: String) throws {}
    func get(name: String) throws -> String { reads += 1; return "synthetic" }
    func confirmPresence(reason: String) throws { onPresence?() }
}
