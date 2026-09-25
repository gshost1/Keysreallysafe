import Foundation
import XCTest
@testable import KeysCore

final class GatewayEvaluationTests: XCTestCase {
    func testEvaluationUsageUsesHeaderModelAndPreservesZeroOutput() {
        let result = GatewayUsageParser.parse(
            api: "vercel-evaluation",
            requestBody: Data(#"{"state":"private context","questions":{}}"#.utf8),
            responseBody: Data(#"{"answers":{},"usage":{"inputTokens":1234,"outputTokens":0}}"#.utf8),
            contentType: "application/json",
            requestModel: "typesafe-ai/jev"
        )
        XCTAssertEqual(result.model, "typesafe-ai/jev")
        XCTAssertEqual(result.inputTokens, 1234)
        XCTAssertEqual(result.outputTokens, 0)
        XCTAssertNil(result.cacheReadTokens)
        XCTAssertNil(result.cacheWriteTokens)
    }

    func testMissingAndInvalidEvaluationUsageStaysUnknown() {
        for response in [
            #"{"error":"upstream unavailable"}"#,
            #"{"answers":{},"usage":{"inputTokens":null}}"#,
            #"{"answers":{},"usage":{"inputTokens":-1,"outputTokens":true}}"#,
            #"{"answers":{},"usage":{"inputTokens":2.5,"outputTokens":"0"}}"#,
            #"{"answers":{},"usage":{"inputTokens":1e100}}"#,
        ] {
            let result = GatewayUsageParser.parse(
                api: "vercel-evaluation", requestBody: Data(),
                responseBody: Data(response.utf8), contentType: "application/json",
                requestModel: "typesafe-ai/jev"
            )
            XCTAssertEqual(result.model, "typesafe-ai/jev")
            XCTAssertNil(result.inputTokens, response)
            XCTAssertNil(result.outputTokens, response)
        }
    }

    func testEvaluationModelHeaderCannotOverrideOtherProtocols() {
        let result = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(#"{"model":"gpt-4.1"}"#.utf8),
            responseBody: Data(#"{"usage":{"inputTokens":100,"outputTokens":0}}"#.utf8),
            contentType: "application/json", requestModel: "typesafe-ai/jev"
        )
        XCTAssertEqual(result.model, "gpt-4.1")
        XCTAssertNil(result.inputTokens)
    }

    func testReportedCostAcceptsZeroButRejectsMalformedValues() {
        for (value, expected): (String, Int64?) in [
            (#""0.000051828""#, 518_280), ("0.000051828", 518_280),
            (#""0""#, 0), ("0", 0), ("null", nil), ("true", nil),
            (#""NaN""#, nil), (#""Infinity""#, nil), ("-1", nil),
            (#""not a price""#, nil), ("1e100", nil),
        ] {
            let response = "{\"providerMetadata\":{\"gateway\":{\"cost\":\(value)}}}"
            let result = GatewayUsageParser.parse(
                api: "vercel-evaluation", requestBody: Data(), responseBody: Data(response.utf8),
                contentType: "application/json", requestModel: "typesafe-ai/jev"
            )
            XCTAssertEqual(result.reportedCostUsdTicks, expected, value)
        }
    }

    func testMissingReportedCostIsUnpricedAndExplicitZeroIsPriced() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "evaluation", provider: "vercel-ai-gateway", kind: "runtime", notes: "", secret: "synthetic")
        var row = GatewayUsageRow(
            ts: UTC.iso(Date()), key: "evaluation", provider: "vercel-ai-gateway", model: "typesafe-ai/jev",
            inputTokens: 100, outputTokens: 0, status: 200, durationMs: 1
        )
        try service.recordGatewayUsage(row)
        var month = try XCTUnwrap(try service.monthGatewayByKey()["evaluation"])
        XCTAssertNil(month.usd)
        XCTAssertEqual(month.kind, "unknown")

        row.reportedCostUsdTicks = 0
        try service.recordGatewayUsage(row)
        month = try XCTUnwrap(try service.monthGatewayByKey()["evaluation"])
        XCTAssertEqual(month.usd, 0)
        XCTAssertEqual(month.kind, "partial")
        XCTAssertEqual(month.pricedCalls, 1)
        XCTAssertEqual(month.unpricedCalls, 1)

        let reopened = try CatalogDB(path: db.path)
        let saved = try reopened.gatewayEvents()
        XCTAssertEqual(Set(saved.map(\.costUsdTicks)), [nil, 0])
    }

    func testReportedCostOverridesListPrice() {
        let row = GatewayUsageRow(
            ts: UTC.iso(Date()), key: "evaluation", provider: "vercel-ai-gateway", model: "gpt-4.1",
            inputTokens: 1_000_000, outputTokens: 0, status: 200, durationMs: 1,
            reportedCostUsdTicks: 0
        )
        XCTAssertNotNil(ModelPrices.lookup("gpt-4.1"))
        XCTAssertEqual(SpendQueries.gatewayUsd(row.usageEvent()), 0)
    }

    func testFailedEvaluationDoesNotRecordReportedCost() async throws {
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { _ in
            HTTPResponse.json(503, ["error": "unavailable", "providerMetadata": ["gateway": ["cost": "1.25"]]])
        }
        stub.start()
        defer { stub.stop() }
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "evaluation", provider: "vercel-ai-gateway", kind: "runtime", notes: "", secret: "synthetic")
        _ = try service.setGateway(name: "evaluation", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let token = try grantFor(service, "evaluation")
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/evaluation/v4/ai/evaluation-model")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("typesafe-ai/jev", forHTTPHeaderField: "ai-model-id")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        var rows: [UsageEvent] = []
        for _ in 0..<200 where rows.isEmpty {
            rows = try db.gatewayEvents()
            if rows.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.httpStatus, 503)
        XCTAssertNil(row.costUsdTicks)
        XCTAssertNil(SpendQueries.gatewayUsd(row))
    }

    func testEvaluationRoundTripRemainsScopedAndStoresOnlyUsage() async throws {
        let sentinel = "PRIVATE-EVAL-CONTEXT-bc7683"
        let capture = EvaluationCapture()
        let responseBody = Data("""
            {"answers":{"keep":{"type":"boolean","probability":0.8}},
            "usage":{"inputTokens":1234,"outputTokens":0},"private":"\(sentinel)",
            "providerMetadata":{"gateway":{"cost":"0.000051828"}}}
            """.utf8)
        let stub = try LoopbackHTTPServer(host: "127.0.0.1", port: 0) { request in
            capture.record(request)
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json", "x-request-id": "evaluation-req-1"],
                body: responseBody
            )
        }
        stub.start()
        defer { stub.stop() }

        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "evaluation", provider: "vercel-ai-gateway", kind: "runtime", notes: "", secret: "synthetic-upstream-key")
        _ = try service.setGateway(name: "evaluation", enabled: true, host: "127.0.0.1:\(stub.boundPort)")
        let token = try service.issueGrant(
            name: "evaluation",
            request: GrantRequest(task: "compact context", methods: ["POST"], paths: ["/v4/ai/evaluation-model"], maxRequests: 1)
        ).token
        let gateway = try GatewayListener(service: service, port: 0)
        gateway.start()
        defer { gateway.stop() }

        func request(_ path: String, method: String = "POST", credential: String? = nil) -> URLRequest {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/evaluation/\(path)")!)
            r.httpMethod = method
            r.setValue("Bearer \(credential ?? token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("typesafe-ai/jev", forHTTPHeaderField: "ai-model-id")
            r.setValue("4", forHTTPHeaderField: "ai-evaluation-model-specification-version")
            r.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
            r.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
            if method == "POST" {
                r.httpBody = Data("{\"state\":\"\(sentinel)\",\"questions\":{}}".utf8)
            }
            return r
        }

        let (_, deniedPath) = try await URLSession.shared.data(for: request("v1/chat/completions"))
        XCTAssertEqual((deniedPath as? HTTPURLResponse)?.statusCode, 403)
        let (_, deniedMethod) = try await URLSession.shared.data(for: request("v4/ai/evaluation-model", method: "GET"))
        XCTAssertEqual((deniedMethod as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(capture.count, 0)

        // Long-lived client capabilities retain their own method/path constraints too.
        let client = try service.issueGatewayClient(
            name: "evaluation", label: "evaluation only", methods: ["POST"], pathPrefix: "/v4/ai/evaluation-model"
        ).token
        let (_, deniedClient) = try await URLSession.shared.data(for: request("v1/chat/completions", credential: client))
        XCTAssertEqual((deniedClient as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(capture.count, 0)

        let evaluationRequest = request("v4/ai/evaluation-model")
        let (body, response) = try await URLSession.shared.data(for: evaluationRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, responseBody)
        let upstream = try XCTUnwrap(capture.last)
        XCTAssertEqual(upstream.path, "/v4/ai/evaluation-model")
        XCTAssertEqual(upstream.body, evaluationRequest.httpBody)
        XCTAssertEqual(upstream.headers["authorization"], "Bearer synthetic-upstream-key")
        XCTAssertEqual(upstream.headers["ai-model-id"], "typesafe-ai/jev")
        XCTAssertEqual(upstream.headers["ai-evaluation-model-specification-version"], "4")
        XCTAssertEqual(upstream.headers["ai-gateway-protocol-version"], "0.0.1")
        XCTAssertEqual(upstream.headers["ai-gateway-auth-method"], "api-key")
        XCTAssertFalse(upstream.headers.values.contains { $0.contains(token) })

        let (_, exhausted) = try await URLSession.shared.data(for: evaluationRequest)
        XCTAssertEqual((exhausted as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(capture.count, 1)

        var rows: [UsageEvent] = []
        for _ in 0..<200 where rows.isEmpty {
            rows = try db.gatewayEvents()
            if rows.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.provider, "vercel-ai-gateway")
        XCTAssertEqual(row.model, "typesafe-ai/jev")
        XCTAssertEqual(row.inputTokens, 1234)
        XCTAssertEqual(row.outputTokens, 0)
        XCTAssertEqual(row.promptId, "evaluation-req-1")
        XCTAssertEqual(row.httpStatus, 200)

        XCTAssertEqual(row.costUsdTicks, 518_280)
        XCTAssertEqual(try XCTUnwrap(service.listGrants().first?.usd), 0.000051828, accuracy: 1e-12)

        // Provider-reported cost does not depend on a current/historical price fixture.
        let month = try XCTUnwrap(try service.monthGatewayByKey()["evaluation"])
        XCTAssertEqual(try XCTUnwrap(month.usd), 0.000051828, accuracy: 1e-12)
        XCTAssertEqual(month.kind, "estimate")
        let report = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .all, now: Date(), timeZone: .current, key: "evaluation"
        )
        XCTAssertEqual(report.totals.gatewayCalls, 1)
        XCTAssertEqual(report.totals.gatewayTokens, 1234)
        XCTAssertEqual(report.totals.gatewayUnpricedModels, [])
        XCTAssertEqual(try XCTUnwrap(report.totals.gatewayUsdEstimate), 0.000051828, accuracy: 1e-12)
        XCTAssertNil(report.daily.first?.usd, "gateway cost must not also enter the local reported-cost ledger")
        XCTAssertEqual(try XCTUnwrap(report.daily.first?.usdEstimate), 0.000051828, accuracy: 1e-12)

        let needle = Data(sentinel.utf8)
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if let contents = try? Data(contentsOf: url) {
                XCTAssertNil(contents.range(of: needle), "evaluation content persisted in \(url.path)")
            }
        }
    }
}

// Direct TypeSafe SystemOne traffic through an ordinary scoped grant: the gateway
// forwards only the granted route and stores usage, never the request context.
extension GatewayEvaluationTests {
    func testDirectGatewayRoundTripKeepsGrantScopedAndStoresOnlyUsage() async throws {
        let capture = EvaluationCapture()
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
        var rows: [UsageEvent] = []
        for _ in 0..<200 where rows.isEmpty {
            rows = try db.gatewayEvents()
            if rows.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.model, "jev-1.13.0")
        XCTAssertEqual(row.inputTokens, 55)
        XCTAssertEqual(row.outputTokens, 0)
        XCTAssertNil(SpendQueries.gatewayUsd(row))
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
}

private final class EvaluationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var last: HTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func record(_ request: HTTPRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
