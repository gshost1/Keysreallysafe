import Foundation
import XCTest
@testable import KeysCore

/// Vercel cost receipts on every path, grants that fail closed when a call has no price, and
/// the per-key cheapest-upstream field. All values are synthetic.
final class VercelCostCheapestTests: XCTestCase {
    // MARK: parsing

    func testNativeLanguageModelResultReadsV4UsageModelAndCost() {
        let response = #"""
            {"content":[{"type":"text","text":"hi"}],"finishReason":"stop",
             "usage":{"inputTokens":{"total":1200,"noCache":200,"cacheRead":1000,"cacheWrite":0},
                      "outputTokens":{"total":80,"text":70,"reasoning":10}},
             "response":{"id":"gen_1","modelId":"anthropic/claude-haiku-5.5"},
             "providerMetadata":{"gateway":{"cost":"0.0021","marketCost":"0.0021"}}}
            """#
        let r = GatewayUsageParser.parse(
            api: GatewayUsageParser.vercelAPI(path: "/v4/ai/language-model"),
            requestBody: Data(#"{"prompt":[]}"#.utf8), responseBody: Data(response.utf8)
        )
        XCTAssertEqual(r.model, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(r.inputTokens, 1200)
        XCTAssertEqual(r.cacheReadTokens, 1000)
        XCTAssertEqual(r.outputTokens, 80)
        XCTAssertEqual(r.reportedCostUsdTicks, Int64((0.0021 * Ticks.perUSD).rounded()))
    }

    func testSpecV2FlatUsageAndHeaderModel() {
        let r = GatewayUsageParser.parse(
            api: "vercel", requestBody: Data(#"{"prompt":[]}"#.utf8),
            responseBody: Data(#"{"usage":{"inputTokens":10,"outputTokens":5,"cachedInputTokens":4},"providerMetadata":{"gateway":{"cost":"0.5"}}}"#.utf8),
            requestModel: "openai/gpt-5-mini"
        )
        XCTAssertEqual(r.model, "openai/gpt-5-mini")
        XCTAssertEqual(r.inputTokens, 10)
        XCTAssertEqual(r.cacheReadTokens, 4)
        XCTAssertEqual(r.outputTokens, 5)
        XCTAssertEqual(r.reportedCostUsdTicks, Int64(0.5 * Ticks.perUSD))
    }

    func testOpenAICompatibleChatReadsUsageCostAndChoiceMetadata() {
        let viaUsage = GatewayUsageParser.parse(
            api: "vercel", requestBody: Data(#"{"model":"openai/gpt-4o-mini"}"#.utf8),
            responseBody: Data(#"{"model":"openai/gpt-4o-mini","usage":{"prompt_tokens":12,"completion_tokens":3,"cost":0.00042}}"#.utf8)
        )
        XCTAssertEqual(viaUsage.inputTokens, 12)
        XCTAssertEqual(viaUsage.outputTokens, 3)
        XCTAssertEqual(viaUsage.reportedCostUsdTicks, Int64((0.00042 * Ticks.perUSD).rounded()))

        let viaChoice = GatewayUsageParser.parse(
            api: "vercel", requestBody: Data(),
            responseBody: Data(#"{"choices":[{"message":{"content":"x","provider_metadata":{"gateway":{"cost":"0.25"}}}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        )
        XCTAssertEqual(viaChoice.reportedCostUsdTicks, Int64(0.25 * Ticks.perUSD))
    }

    func testMessagesShapeCountsCacheIntoInputLikeTheCatalogEntry() {
        let r = GatewayUsageParser.parse(
            api: GatewayUsageParser.vercelAPI(path: "/v1/messages"), requestBody: Data(),
            responseBody: Data(#"{"type":"message","model":"anthropic/claude-sonnet-4.5","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":90}}"#.utf8)
        )
        XCTAssertEqual(r.inputTokens, 100)
        XCTAssertEqual(r.cacheReadTokens, 90)
        XCTAssertEqual(r.outputTokens, 2)
    }

    func testNativeStreamTakesUsageAndCostFromTheFinishPart() {
        let tee = GatewayTee(api: "vercel")
        tee.setContentType("text/event-stream")
        let stream = """
            data: {"type":"stream-start","warnings":[]}

            data: {"type":"response-metadata","id":"gen_2","modelId":"anthropic/claude-haiku-5.5"}

            data: {"type":"text-delta","id":"0","delta":"hello"}

            data: {"type":"finish","finishReason":"stop","usage":{"inputTokens":{"total":300},"outputTokens":{"total":40}},"providerMetadata":{"gateway":{"cost":"0.0125"}}}


            """
        // Split mid-event, as the network would.
        let bytes = Data(stream.utf8)
        tee.append(bytes.prefix(70))
        tee.append(bytes.dropFirst(70))
        let r = tee.result(requestBody: Data())
        XCTAssertEqual(r.model, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(r.inputTokens, 300)
        XCTAssertEqual(r.outputTokens, 40)
        XCTAssertEqual(r.reportedCostUsdTicks, Int64((0.0125 * Ticks.perUSD).rounded()))
    }

    func testOtherProvidersIgnoreVercelReceipts() {
        let r = GatewayUsageParser.parse(
            api: "openai", requestBody: Data(),
            responseBody: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1,"cost":9},"providerMetadata":{"gateway":{"cost":"9"}}}"#.utf8)
        )
        XCTAssertNil(r.reportedCostUsdTicks)
    }

    // MARK: grants through the gateway

    private func capped(_ rig: GatewayRig, maxUsd: Double = 1) throws -> String {
        try rig.service.issueGrant(
            name: "jev", request: GrantRequest(task: "bench", methods: ["POST", "GET"], paths: ["/v4/ai"], maxUsd: maxUsd),
            caller: "test"
        ).token
    }

    private func post(_ rig: GatewayRig, _ token: String, path: String = "v4/ai/language-model") -> URLRequest {
        var r = URLRequest(url: rig.url(path, key: "jev"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("anthropic/claude-haiku-5.5", forHTTPHeaderField: "ai-language-model-id")
        r.httpBody = Data(#"{"prompt":[{"role":"user","content":[{"type":"text","text":"PRIVATE-BENCH-PROMPT"}]}]}"#.utf8)
        return r
    }

    private func status(_ request: URLRequest) async throws -> (Int, Data) {
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    private func waitForRows(_ rig: GatewayRig, _ n: Int) async throws {
        for _ in 0..<200 where try rig.db.gatewayEvents().count < n {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(try rig.db.gatewayEvents().count, n)
    }

    func testNonStreamingCostReplayMovesGrantSpendAndTripsTheCap() async throws {
        let rig = try GatewayRig { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(
                #"{"content":[],"usage":{"inputTokens":{"total":100},"outputTokens":{"total":10}},"providerMetadata":{"gateway":{"cost":"0.6"}}}"#.utf8
            ))
        }
        defer { rig.stop() }
        try rig.key("jev", provider: "vercel-ai-gateway", secret: "synthetic-vck")
        let token = try capped(rig)

        let first = try await status(post(rig, token))
        XCTAssertEqual(first.0, 200)
        try await waitForRows(rig, 1)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).usd, 0.6, accuracy: 1e-9)

        let second = try await status(post(rig, token))
        XCTAssertEqual(second.0, 200)
        try await waitForRows(rig, 2)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).usd, 1.2, accuracy: 1e-9)

        let third = try await status(post(rig, token))
        XCTAssertEqual(third.0, 429)
        let denial = try XCTUnwrap(JSONSerialization.jsonObject(with: third.1) as? [String: Any])
        XCTAssertEqual(denial["error"] as? String, "grant_usd_limit")

        // The receipt is the stored spend, and the prompt never reached the catalog.
        let rows = try rig.db.gatewayEvents()
        XCTAssertEqual(Set(rows.map(\.costUsdTicks)), [Int64(0.6 * Ticks.perUSD)])
        XCTAssertEqual(Set(rows.map(\.model)), ["anthropic/claude-haiku-5.5"])
        assertNoSentinel("PRIVATE-BENCH-PROMPT", in: rig.dir)
    }

    func testStreamingCostReplayMovesGrantSpendAndTripsTheCap() async throws {
        let stream = """
            data: {"type":"response-metadata","modelId":"anthropic/claude-haiku-5.5"}

            data: {"type":"text-delta","id":"0","delta":"x"}

            data: {"type":"finish","finishReason":"stop","usage":{"inputTokens":{"total":50},"outputTokens":{"total":5}},"providerMetadata":{"gateway":{"cost":"1.5"}}}


            """
        let rig = try GatewayRig { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(stream.utf8))
        }
        defer { rig.stop() }
        try rig.key("jev", provider: "vercel-ai-gateway", secret: "synthetic-vck")
        let token = try capped(rig)

        let first = try await status(post(rig, token))
        XCTAssertEqual(first.0, 200)
        try await waitForRows(rig, 1)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).usd, 1.5, accuracy: 1e-9)
        let row = try XCTUnwrap(rig.db.gatewayEvents().first)
        XCTAssertEqual(row.inputTokens, 50)
        XCTAssertEqual(row.outputTokens, 5)

        let second = try await status(post(rig, token))
        XCTAssertEqual(second.0, 429)
    }

    func testUnpricedCallOnCappedGrantRefusesTheNextOne() async throws {
        // The shape the bench saw: a 200 with nothing the gateway can price.
        let rig = try GatewayRig { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"content":[]}"#.utf8))
        }
        defer { rig.stop() }
        try rig.key("jev", provider: "vercel-ai-gateway", secret: "synthetic-vck")
        let token = try capped(rig, maxUsd: 5)

        // A read is not billable, so it does not end the grant.
        var read = URLRequest(url: rig.url("v4/ai/config", key: "jev"))
        read.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let readStatus = try await status(read)
        XCTAssertEqual(readStatus.0, 200)
        try await waitForRows(rig, 1)
        XCTAssertEqual(try XCTUnwrap(rig.service.grants.list().first).unpricedCalls, 0)

        let first = try await status(post(rig, token))
        XCTAssertEqual(first.0, 200)
        try await waitForRows(rig, 2)
        let grant = try XCTUnwrap(rig.service.grants.list().first)
        XCTAssertEqual(grant.unpricedCalls, 1)
        XCTAssertEqual(grant.jsonObject()["unpriced_calls"] as? Int, 1)

        let second = try await status(post(rig, token))
        XCTAssertEqual(second.0, 429)
        let denial = try XCTUnwrap(JSONSerialization.jsonObject(with: second.1) as? [String: Any])
        XCTAssertEqual(denial["error"] as? String, "grant_usd_unpriced")
        XCTAssertEqual(try rig.db.gatewayEvents().count, 2)
    }

    func testUncappedGrantKeepsGoingAfterUnpricedCalls() {
        let store = GrantStore()
        let (grant, token) = store.issue(key: "k", provider: "openai", host: "h", request: GrantRequest(task: "t"))
        store.charge(id: grant.id, usd: nil)
        XCTAssertEqual(store.grant(id: grant.id)?.unpricedCalls, 1)
        guard case .success = store.authorize(token: token, key: "k", host: "h", method: "POST", rest: "x", providerPrefix: "") else {
            return XCTFail("an uncapped grant must not stop on an unpriced call")
        }
    }

    func testErrorsAndReadsAreNotBillable() {
        XCTAssertTrue(GrantStore.billable(method: "POST", status: 200))
        XCTAssertFalse(GrantStore.billable(method: "POST", status: 429))
        XCTAssertFalse(GrantStore.billable(method: "GET", status: 200))
        let store = GrantStore()
        let (grant, token) = store.issue(key: "k", provider: "openai", host: "h", request: GrantRequest(task: "t", maxUsd: 1))
        store.charge(id: grant.id, usd: nil, billable: false)
        guard case .success = store.authorize(token: token, key: "k", host: "h", method: "POST", rest: "x", providerPrefix: "") else {
            return XCTFail("a failed call must not end the grant")
        }
    }

    func testGrantsListShowsUnpricedInsteadOfZero() {
        XCTAssertEqual(GrantsCommand.usdCell(usd: 0, unpriced: 0), "0.0000")
        XCTAssertEqual(GrantsCommand.usdCell(usd: 0, unpriced: 84), "unpriced (84 calls)")
        XCTAssertEqual(GrantsCommand.usdCell(usd: 0.5, unpriced: 1), "≥0.5000 + unpriced (1 call)")
    }

    // MARK: cheapest upstream

    private let json = ["content-type": "application/json"]

    private func injected(_ body: String, provider: String, path: String, headers: [String: String]? = nil) -> [String: Any]? {
        CheapestRouting.apply(Data(body.utf8), provider: provider, path: path, method: "POST", headers: headers ?? json)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testCheapestIsAddedWhenAbsent() throws {
        let openrouter = try XCTUnwrap(injected(#"{"model":"deepseek/deepseek-v3","messages":[]}"#, provider: "openrouter", path: "/api/v1/chat/completions"))
        XCTAssertEqual((openrouter["provider"] as? [String: Any])?["sort"] as? String, "price")
        XCTAssertEqual(openrouter["model"] as? String, "deepseek/deepseek-v3")

        let vercel = try XCTUnwrap(injected(#"{"prompt":[]}"#, provider: "vercel-ai-gateway", path: "/v4/ai/language-model"))
        let gateway = (vercel["providerOptions"] as? [String: Any])?["gateway"] as? [String: Any]
        XCTAssertEqual(gateway?["sort"] as? String, "cost")

        // Into objects the caller already sent, keeping what is in them, byte for byte elsewhere.
        let body = #"{ "prompt": [1.10, "a,}"], "providerOptions": { "gateway": { "tags": ["x"] }, "anthropic": {} } }"#
        let out = try XCTUnwrap(CheapestRouting.apply(Data(body.utf8), provider: "vercel-ai-gateway", path: "/v1/chat/completions", method: "POST", headers: json))
        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        XCTAssertEqual(text, #"{ "prompt": [1.10, "a,}"], "providerOptions": { "gateway": {"sort":"cost", "tags": ["x"] }, "anthropic": {} } }"#)

        let emptyOptions = try XCTUnwrap(injected(#"{"providerOptions":{}}"#, provider: "vercel-ai-gateway", path: "/v1/responses"))
        XCTAssertEqual(((emptyOptions["providerOptions"] as? [String: Any])?["gateway"] as? [String: Any])?["sort"] as? String, "cost")
    }

    func testCheapestLeavesAnExplicitChoiceAlone() {
        for body in [
            #"{"provider":{"order":["deepinfra"]}}"#,
            #"{"provider":{"only":["together"]}}"#,
            #"{"provider":{"sort":"throughput"}}"#,
            #"{"model":"meta-llama/llama-3.3-70b:nitro"}"#,
            #"{"model":"meta-llama/llama-3.3-70b:floor"}"#,
            #"{"provider":"deepinfra"}"#,
        ] {
            XCTAssertNil(CheapestRouting.apply(Data(body.utf8), provider: "openrouter", path: "/api/v1/chat/completions", method: "POST", headers: json), body)
        }
        for body in [
            #"{"providerOptions":{"gateway":{"order":["bedrock"]}}}"#,
            #"{"providerOptions":{"gateway":{"only":["anthropic"]}}}"#,
            #"{"providerOptions":{"gateway":{"sort":"ttft"}}}"#,
            #"{"provider":{"sort":"tps"}}"#,
            #"{"providerOptions":"bad"}"#,
            // Spelled with an escape, or twice: an upstream parser might read it differently.
            "{\"provider" + "\\" + "u004fptions\":{}}",
            #"{"providerOptions":{},"providerOptions":{}}"#,
        ] {
            XCTAssertNil(CheapestRouting.apply(Data(body.utf8), provider: "vercel-ai-gateway", path: "/v1/chat/completions", method: "POST", headers: json), body)
        }
    }

    func testCheapestSkipsUnsupportedProvidersNonJSONAndOtherEndpoints() {
        let body = Data(#"{"model":"m","messages":[]}"#.utf8)
        for provider in ["haimaker", "ramp-router", "requesty", "portkey", "helicone", "kilo", "openai"] {
            XCTAssertFalse(CheapestRouting.supports(provider: provider), provider)
            XCTAssertNil(CheapestRouting.apply(body, provider: provider, path: "/v1/chat/completions", method: "POST", headers: json), provider)
        }
        let path = "/api/v1/chat/completions"
        XCTAssertNil(CheapestRouting.apply(body, provider: "openrouter", path: path, method: "POST", headers: ["content-type": "text/plain"]))
        XCTAssertNil(CheapestRouting.apply(body, provider: "openrouter", path: path, method: "POST", headers: [:]))
        XCTAssertNil(CheapestRouting.apply(body, provider: "openrouter", path: path, method: "POST", headers: ["content-type": "application/json", "content-encoding": "gzip"]))
        XCTAssertNil(CheapestRouting.apply(Data("[1,2]".utf8), provider: "openrouter", path: path, method: "POST", headers: json))
        XCTAssertNil(CheapestRouting.apply(Data("{not json".utf8), provider: "openrouter", path: path, method: "POST", headers: json))
        XCTAssertNil(CheapestRouting.apply(body, provider: "openrouter", path: path, method: "GET", headers: json))
        XCTAssertNil(CheapestRouting.apply(body, provider: "openrouter", path: "/api/v1/embeddings", method: "POST", headers: json))
        XCTAssertNil(CheapestRouting.apply(body, provider: "vercel-ai-gateway", path: "/v4/ai/evaluation-model", method: "POST", headers: json))
    }

    func testCheapestIsPerKeyOffByDefaultAndOnlyRewritesTheUpstreamCopy() async throws {
        let capture = RequestLog()
        let rig = try GatewayRig { request in
            capture.record(request)
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8))
        }
        defer { rig.stop() }
        try rig.key("router", provider: "openrouter", secret: "synthetic-or")
        try rig.key("plain", provider: "haimaker", secret: "synthetic-hm")
        XCTAssertFalse(try XCTUnwrap(rig.db.catalogRow(name: "router")).gatewayCheapest)
        XCTAssertThrowsError(try rig.service.setGatewayCheapest(name: "plain", enabled: true))

        let body = Data(#"{"model":"deepseek/deepseek-v3","messages":[{"role":"user","content":"PRIVATE-ROUTE-PROMPT"}]}"#.utf8)
        func send() async throws -> HTTPRequest {
            var r = URLRequest(url: rig.url("api/v1/chat/completions", key: "router"))
            r.httpMethod = "POST"
            r.setValue("Bearer \(try grantFor(rig.service, "router"))", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            _ = try await URLSession.shared.data(for: r)
            return try XCTUnwrap(capture.last)
        }

        let off = try await send()
        XCTAssertEqual(off.body, body)

        let row = try rig.service.setGatewayCheapest(name: "router", enabled: true, caller: "test")
        XCTAssertTrue(row.gatewayCheapest)
        XCTAssertEqual(try rig.service.keyJSONObject(row)["gateway_cheapest"] as? Bool, true)
        let on = try await send()
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: on.body) as? [String: Any])
        XCTAssertEqual((sent["provider"] as? [String: Any])?["sort"] as? String, "price")
        XCTAssertEqual(on.headers["content-length"], String(on.body.count))

        _ = try rig.service.setGatewayCheapest(name: "router", enabled: false, caller: "test")
        let offAgain = try await send()
        XCTAssertEqual(offAgain.body, body)
        try await waitForRows(rig, 3)
        assertNoSentinel("PRIVATE-ROUTE-PROMPT", in: rig.dir)
    }
}
