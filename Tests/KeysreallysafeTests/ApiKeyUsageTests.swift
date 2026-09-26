import Foundation
import XCTest
@testable import KeysCore

/// `source=keys` is the gateway's own ledger: every call this Mac routed through a vault key,
/// named by key, counted as requests, and honest about a cost the provider never reported.
/// Every secret and every row below is invented here; nothing reaches a provider.
final class ApiKeyUsageTests: XCTestCase {
    private let now = UTC.parse("2026-09-05T18:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func report(
        _ db: CatalogDB,
        source: SourceFilter = .keys,
        by: SpendGroup = .model,
        range: SpendRange = .month,
        key: String? = nil,
        provider: String? = nil
    ) throws -> SpendReport {
        try SpendQueries(db: db).report(
            range: range, by: by, source: source, now: now, timeZone: utc, key: key, provider: provider
        )
    }

    private func service(_ db: CatalogDB, keys: [(String, String)]) throws -> KeysService {
        let (service, _, _) = makeService(db: db)
        for (name, provider) in keys {
            try service.add(name: name, provider: provider, kind: "runtime", notes: "", secret: "synthetic-\(name)")
        }
        return service
    }

    private func gatewayRow(
        key: String,
        provider: String = "anthropic",
        model: String? = "claude-sonnet-5",
        at ts: String = "2026-09-05T12:00:00Z",
        requestId: String? = nil,
        input: Int? = 100,
        output: Int? = 50
    ) -> GatewayUsageRow {
        GatewayUsageRow(
            ts: ts, key: key, provider: provider, model: model,
            inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0,
            status: 200, durationMs: 12, requestId: requestId
        )
    }

    private let claudeLine = #"{"type":"assistant","sessionId":"same-call","requestId":"req_shared","timestamp":"2026-09-05T12:00:00Z","message":{"id":"msg-1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50}}}"#

    /// The gateway ledger is complete on its own terms: a call a local log also recorded is
    /// still a call this key paid for, so `source=keys` keeps it. The local scope still drops
    /// that copy, which is what stops one upstream call being counted twice there.
    func testKeysSourceKeepsCorrelatedCallsThatTheLocalScopeDrops() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("alpha", "anthropic")])
        _ = try db.insertUsage(try XCTUnwrap(ClaudeIngest.parseLine(claudeLine)))
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "req_shared"))
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "req_other"))

        let keys = try report(db)
        XCTAssertEqual(keys.totals.gatewayCalls, 2, "the gateway ledger keeps the correlated call")
        XCTAssertEqual(keys.totals.gatewayCorrelatedCalls, 0)
        XCTAssertEqual(keys.totals.gatewayTokens, 300)
        XCTAssertEqual(keys.rows.reduce(0) { $0 + $1.modelCalls }, 2)
        XCTAssertTrue(keys.rows.allSatisfy { $0.key == "alpha" }, "every row names the key it went through")

        let local = try report(db, source: .all)
        XCTAssertEqual(local.totals.gatewayCorrelatedCalls, 1, "the local scope still drops the duplicate")
        XCTAssertEqual(local.totals.gatewayCalls, 1)
        XCTAssertEqual(local.totals.tokens, 150, "gateway tokens must not enter the local headline")
        XCTAssertTrue(local.rows.allSatisfy { $0.key == nil }, "an unkeyed local report charts local rows only")
        XCTAssertEqual(local.rows.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, local.totals.tokens, "rows agree with the headline")
        XCTAssertEqual(local.daily.reduce(0) { $0 + $1.tokens }, local.totals.tokens)

        // A keyed report is the gateway's own ledger even from the local scope, and a proxy that
        // repeats request ids must not collapse two calls into one.
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "req_other"))
        let keyed = try report(db, source: .all, key: "alpha")
        XCTAssertEqual(keyed.totals.gatewayCalls, 3)
        XCTAssertEqual(keyed.totals.gatewayCorrelatedCalls, 0)
        XCTAssertEqual(keyed.totals.gatewayTokens, 450)
        XCTAssertEqual(keyed.rows.first?.key, "alpha", "a keyed report is the gateway ledger and still charts")
    }

    /// Switching to the API keys source must not quietly add the gateway to the local ledger,
    /// nor drop local usage from it.
    func testLocalScopeIsUnchangedByTheKeysSource() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("alpha", "anthropic")])
        _ = try db.insertUsage(try XCTUnwrap(ClaudeIngest.parseLine(claudeLine)))
        let before = try report(db, source: .all)
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "req_unrelated"))
        // The same call seen with no request id cannot be proved a duplicate, so it never correlates.
        try service.recordGatewayUsage(gatewayRow(key: "alpha"))
        let after = try report(db, source: .all)
        XCTAssertEqual(after.totals.tokens, before.totals.tokens)
        XCTAssertEqual(after.totals.usdEstimate ?? -1, before.totals.usdEstimate ?? -1, accuracy: 1e-12)
        XCTAssertEqual(after.rows.count, before.rows.count, "a gateway call adds no row to the local ledger")
        XCTAssertEqual(after.totals.gatewayCalls, 2)
        XCTAssertEqual(after.totals.gatewayCorrelatedCalls, 0)
        XCTAssertEqual(after.totals.gatewayTokens, 300)
        XCTAssertNotNil(after.totals.gatewayUsdEstimate)
        XCTAssertEqual((after.jsonObject()["totals"] as? [String: Any])?["gateway_calls"] as? Int, 2)
    }

    /// A key's month is "none" before any call, "unknown" (null, never $0) when no call could be
    /// priced, and "partial" once some can.
    func testKeyMonthIsNoneThenUnknownThenPartial() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("probe", "anthropic")])
        let row = try XCTUnwrap(db.catalogRow(name: "probe"))
        let idle = try service.keyJSONObject(row)
        XCTAssertEqual(idle["usd_month_kind"] as? String, "none")
        XCTAssertTrue(idle["usd_month"] is NSNull)
        XCTAssertEqual(idle["gateway_month_calls"] as? Int, 0)

        try service.recordGatewayUsage(gatewayRow(key: "probe", model: nil, requestId: "r1"))
        let month = try XCTUnwrap(try service.monthGatewayByKey(now: now, timeZone: utc)["probe"])
        XCTAssertNil(month.usd)
        XCTAssertEqual(month.kind, "unknown")
        XCTAssertEqual(month.unpricedCalls, 1)
        let obj = service.keyJSONObject(row, month: month)
        XCTAssertTrue(obj["usd_month"] is NSNull)
        XCTAssertEqual(obj["usd_month_kind"] as? String, "unknown")
        XCTAssertEqual(obj["gateway_month_unpriced_calls"] as? Int, 1)

        try service.recordGatewayUsage(gatewayRow(key: "probe", requestId: "r2"))
        let partial = try XCTUnwrap(try service.monthGatewayByKey(now: now, timeZone: utc)["probe"])
        XCTAssertEqual(partial.kind, "partial")
        XCTAssertNotNil(partial.usd)
        XCTAssertEqual(partial.calls, 2)
        let totals = try report(db, source: .all, key: "probe").totals
        XCTAssertEqual(totals.gatewayUnpricedCalls, 1)
        XCTAssertEqual(totals.gatewayUnpricedTokens, 150)
        XCTAssertEqual(totals.gatewayUnpricedModels, ["unknown"])
    }

    func testKeyFilterNarrowsToOneKeyAndAllKeysIsTheirSum() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("alpha", "anthropic"), ("bravo", "anthropic")])
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "a1"))
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "a2"))
        try service.recordGatewayUsage(gatewayRow(key: "bravo", requestId: "b1"))

        let all = try report(db)
        XCTAssertEqual(all.totals.gatewayCalls, 3)
        XCTAssertEqual(Set(all.rows.compactMap(\.key)), ["alpha", "bravo"])

        let alpha = try report(db, key: "alpha")
        XCTAssertEqual(alpha.totals.gatewayCalls, 2)
        XCTAssertEqual(alpha.totals.gatewayTokens, 300)
        XCTAssertEqual(Set(alpha.rows.compactMap(\.key)), ["alpha"])
        let bravo = try report(db, key: "bravo")
        XCTAssertEqual(bravo.totals.gatewayCalls, 1)
        XCTAssertEqual(
            alpha.totals.gatewayCalls + bravo.totals.gatewayCalls,
            all.totals.gatewayCalls,
            "per-key reports partition the all-keys one"
        )
        XCTAssertEqual(alpha.totals.gatewayTokens + bravo.totals.gatewayTokens, all.totals.gatewayTokens)
    }

    /// TypeSafe's System One protocol reports no cost receipt, and its model names must not pick
    /// up an unrelated catalog price. The requests are still countable, so they are still charted.
    func testTypeSafeCostStaysUnknownWhileRequestsStillChart() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("systemone", "typesafe")])
        try service.recordGatewayUsage(gatewayRow(
            key: "systemone", provider: "typesafe", model: "system-one", requestId: "t1", input: nil, output: nil
        ))
        try service.recordGatewayUsage(gatewayRow(
            key: "systemone", provider: "typesafe", model: "system-one",
            at: "2026-09-05T13:00:00Z", requestId: "t2", input: nil, output: nil
        ))

        let keys = try report(db)
        XCTAssertNil(keys.totals.gatewayUsdEstimate, "an unknown cost is unknown, never zero")
        XCTAssertEqual(keys.totals.gatewayCalls, 2)
        XCTAssertEqual(keys.totals.gatewayUnpricedCalls, 2)
        XCTAssertEqual(keys.totals.gatewayTokens, 0)
        XCTAssertEqual(keys.totals.gatewayUnpricedModels, ["system-one"])
        let row = try XCTUnwrap(keys.rows.first)
        XCTAssertEqual(row.model, "system-one")
        XCTAssertEqual(row.modelCalls, 2, "requests are countable with no tokens and no price")
        XCTAssertNil(row.usd)
        XCTAssertNil(row.usdEstimate)
        XCTAssertEqual(keys.daily.reduce(0) { $0 + $1.modelCalls }, 2, "the daily chart can plot requests")
        XCTAssertTrue(keys.daily.allSatisfy { $0.usdEstimate == nil && $0.tokens == 0 })

        let obj = keys.jsonObject()
        let totals = obj["totals"] as! [String: Any]
        XCTAssertTrue(totals["gateway_usd_estimate"] is NSNull)
        XCTAssertTrue(totals["usd_estimate"] is NSNull, "there is no local figure to headline here")
        let daily = obj["daily"] as! [[String: Any]]
        XCTAssertEqual(daily.reduce(0) { $0 + ($1["model_calls"] as? Int ?? 0) }, 2)
    }

    /// A call whose response carried no usage and no cost receipt must stay unknown even when its
    /// request named a model the price table knows. The recorder normalizes absent token counts to
    /// zero, and pricing those zeros would publish $0.00 as a known cost.
    func testMissingUsageReceiptIsUnknownNotAPricedZero() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("vercel", "vercel-ai-gateway")])
        let row = GatewayUsageRow(
            ts: "2026-09-05T12:00:00Z", key: "vercel", provider: "vercel-ai-gateway",
            model: "openai/gpt-4.1", inputTokens: nil, outputTokens: nil,
            cacheReadTokens: nil, cacheWriteTokens: nil, status: 200, durationMs: 7, requestId: "v1"
        )
        XCTAssertNil(SpendQueries.gatewayUsd(row.usageEvent()), "no receipt and no usage: unknown, not zero")
        try service.recordGatewayUsage(row)

        let keys = try report(db)
        XCTAssertEqual(keys.totals.gatewayCalls, 1, "the call is still visible")
        XCTAssertEqual(keys.rows.first?.modelCalls, 1)
        XCTAssertNil(keys.totals.gatewayUsdEstimate)
        XCTAssertEqual(keys.totals.gatewayUnpricedCalls, 1)
        XCTAssertNil(keys.rows.first?.usdEstimate)
        XCTAssertNil(keys.daily.first?.usdEstimate)
        let month = try XCTUnwrap(try service.monthGatewayByKey(now: now, timeZone: utc)["vercel"])
        XCTAssertNil(month.usd)
        XCTAssertEqual(month.kind, "unknown")

        // An explicitly reported zero is a known zero and keeps its meaning.
        var free = row
        free.requestId = "v2"
        free.inputTokens = 0
        free.outputTokens = 0
        free.reportedCostUsdTicks = 0
        XCTAssertEqual(SpendQueries.gatewayUsd(free.usageEvent()), 0)
        try service.recordGatewayUsage(free)
        let both = try report(db)
        XCTAssertEqual(both.totals.gatewayCalls, 2)
        XCTAssertEqual(both.totals.gatewayUsdEstimate ?? -1, 0, accuracy: 1e-12, "a reported zero is known")
        XCTAssertEqual(both.totals.gatewayUnpricedCalls, 1, "only the receiptless call is unpriced")
    }

    /// A partly priced range is a floor, not a total: the priced calls are reported and the
    /// unpriced ones are named as left out.
    func testMixedPricedAndUnpricedCallsReportBoth() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("mixed", "anthropic")])
        try service.recordGatewayUsage(gatewayRow(key: "mixed", requestId: "priced"))
        try service.recordGatewayUsage(gatewayRow(
            key: "mixed", provider: "typesafe", model: "system-one", requestId: "unpriced", input: nil, output: nil
        ))
        let keys = try report(db)
        XCTAssertEqual(keys.totals.gatewayCalls, 2)
        XCTAssertEqual(keys.totals.gatewayUnpricedCalls, 1)
        XCTAssertNotNil(keys.totals.gatewayUsdEstimate)
        XCTAssertEqual(keys.totals.gatewayPricedTokens, 150)
        XCTAssertEqual(keys.totals.gatewayUnpricedTokens, 0)
        XCTAssertEqual(keys.rows.count, 2)
        XCTAssertEqual(keys.rows.filter { $0.usdEstimate == nil }.map(\.model), ["system-one"])
    }

    func testNoGatewayCallsIsAnEmptyLedgerNotAZeroOne() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("idle", "anthropic")])
        // A local session in the same range must not leak into the API keys view.
        _ = try db.insertUsage(try XCTUnwrap(ClaudeIngest.parseLine(claudeLine)))
        _ = service

        let keys = try report(db)
        XCTAssertTrue(keys.rows.isEmpty, "only routed requests are recorded, so there is nothing to show")
        XCTAssertTrue(keys.daily.isEmpty)
        XCTAssertEqual(keys.totals.gatewayCalls, 0)
        XCTAssertNil(keys.totals.gatewayUsdEstimate)
        XCTAssertEqual(keys.totals.gatewayTokens, 0)
        let totals = keys.jsonObject()["totals"] as! [String: Any]
        XCTAssertTrue(totals["usd_estimate"] is NSNull)

        let filtered = try report(db, key: "idle")
        XCTAssertTrue(filtered.rows.isEmpty)
        XCTAssertEqual(filtered.totals.gatewayCalls, 0)
    }

    /// Hourly buckets carry the same request counts, so the today view can chart requests too.
    func testHourlyBucketsCountRequests() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("alpha", "anthropic")])
        try service.recordGatewayUsage(gatewayRow(key: "alpha", at: "2026-09-05T12:00:00Z", requestId: "h1"))
        try service.recordGatewayUsage(gatewayRow(key: "alpha", at: "2026-09-05T12:30:00Z", requestId: "h2"))
        try service.recordGatewayUsage(gatewayRow(key: "alpha", at: "2026-09-05T14:00:00Z", requestId: "h3"))
        let today = try report(db, by: .hour, range: .today)
        XCTAssertEqual(today.points.map(\.hour), ["2026-09-05T12:00", "2026-09-05T14:00"])
        XCTAssertEqual(today.points.first?.modelCalls, 2)
        XCTAssertEqual(today.points.reduce(0) { $0 + $1.modelCalls }, today.totals.gatewayCalls)
    }

    /// Provider is the axis above the key: TypeSafe and the Vercel AI Gateway are both API-key
    /// billing, and the same workload model can run on either. Filtering by provider partitions
    /// the all-providers report the way filtering by key partitions it, and the two combine.
    func testProviderFilterPartitionsTheLedgerAndCombinesWithAKeyFilter() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("direct-typesafe", "typesafe"), ("direct-vercel", "vercel-ai-gateway")])
        try service.recordGatewayUsage(gatewayRow(
            key: "direct-typesafe", provider: "typesafe", model: "system-one", requestId: "t1", input: nil, output: nil
        ))
        try service.recordGatewayUsage(gatewayRow(
            key: "direct-typesafe", provider: "typesafe", model: "system-one",
            at: "2026-09-05T13:00:00Z", requestId: "t2", input: nil, output: nil
        ))
        try service.recordGatewayUsage(gatewayRow(
            key: "direct-vercel", provider: "vercel-ai-gateway", model: "openai/gpt-4.1", requestId: "v1"
        ))

        let all = try report(db)
        XCTAssertEqual(all.totals.gatewayCalls, 3)
        XCTAssertEqual(Set(all.rows.compactMap(\.provider)), ["typesafe", "vercel-ai-gateway"],
                       "every gateway row names the provider it was routed to")

        let typesafe = try report(db, provider: "typesafe")
        XCTAssertEqual(typesafe.totals.gatewayCalls, 2)
        XCTAssertEqual(Set(typesafe.rows.compactMap(\.provider)), ["typesafe"])
        XCTAssertNil(typesafe.totals.gatewayUsdEstimate, "TypeSafe reports no cost: unknown, not zero")
        XCTAssertEqual(typesafe.totals.gatewayUnpricedCalls, 2)

        let vercel = try report(db, provider: "vercel-ai-gateway")
        XCTAssertEqual(vercel.totals.gatewayCalls, 1)
        XCTAssertEqual(Set(vercel.rows.compactMap(\.provider)), ["vercel-ai-gateway"])
        XCTAssertNotNil(vercel.totals.gatewayUsdEstimate)
        XCTAssertEqual(vercel.totals.gatewayUnpricedCalls, 0, "nothing in this narrower view is unpriced")

        XCTAssertEqual(typesafe.totals.gatewayCalls + vercel.totals.gatewayCalls, all.totals.gatewayCalls,
                       "per-provider reports partition the all-providers one")
        XCTAssertEqual(typesafe.totals.gatewayTokens + vercel.totals.gatewayTokens, all.totals.gatewayTokens)

        // Provider and key are the same path: a key of another provider yields nothing, its own
        // key yields that provider's calls.
        XCTAssertEqual(try report(db, key: "direct-vercel", provider: "typesafe").totals.gatewayCalls, 0)
        XCTAssertEqual(try report(db, key: "direct-typesafe", provider: "typesafe").totals.gatewayCalls, 2)

        // And the filter is applied before aggregation, so buckets agree with the totals.
        XCTAssertEqual(typesafe.daily.reduce(0) { $0 + $1.modelCalls }, 2)
        let json = String(data: try JSONValue.data(all.jsonObject()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"provider\":\"typesafe\""))
        XCTAssertTrue(json.contains("\"provider\":\"vercel-ai-gateway\""))
    }

    /// A workload is a model under a provider, not a billing source of its own: the same model
    /// recorded on two providers stays one model, and each provider's view keeps its own share.
    func testOneWorkloadModelOnTwoProvidersStaysOneModel() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("direct-typesafe", "typesafe"), ("direct-vercel", "vercel-ai-gateway")])
        try service.recordGatewayUsage(gatewayRow(
            key: "direct-typesafe", provider: "typesafe", model: "system-one", requestId: "t1", input: nil, output: nil
        ))
        try service.recordGatewayUsage(gatewayRow(
            key: "direct-vercel", provider: "vercel-ai-gateway", model: "system-one", requestId: "v1"
        ))

        let all = try report(db)
        XCTAssertEqual(Set(all.rows.compactMap(\.model)), ["system-one"], "one model, two providers")
        XCTAssertEqual(all.daily.map(\.model), ["system-one"], "and one series in the chart")
        XCTAssertEqual(all.totals.gatewayCalls, 2)
        // Neither half is priced: TypeSafe by its API guard, and the Vercel half because this
        // workload name is in no price table. A borrowed price is not invented for either.
        XCTAssertEqual(all.totals.gatewayUnpricedCalls, 2)
        XCTAssertNil(all.totals.gatewayUsdEstimate)
        XCTAssertEqual(all.totals.gatewayTokens, 150, "the Vercel half did report tokens")

        XCTAssertEqual(try report(db, provider: "typesafe").totals.gatewayCalls, 1)
        XCTAssertEqual(try report(db, provider: "vercel-ai-gateway").totals.gatewayCalls, 1)
    }

    /// The provider column belongs to gateway rows. Local log rows must not acquire one, or a
    /// model's local row would split in the existing All view.
    func testLocalRowsCarryNoProviderAndAreNotSplitByIt() throws {
        let (db, _) = try makeDB()
        _ = try db.insertUsage(try XCTUnwrap(ClaudeIngest.parseLine(claudeLine)))
        let local = try report(db, source: .all)
        XCTAssertFalse(local.rows.isEmpty)
        XCTAssertTrue(local.rows.allSatisfy { $0.provider == nil })
        let json = String(data: try JSONValue.data(local.jsonObject()), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"provider\""), "a local row has no provider to name")
    }

    /// The wire shape the chart reads for two facts it cannot guess: a call the provider priced at
    /// exactly zero, and a call nobody named a model for. A zero cost is knowledge and must not
    /// arrive as an absent one; an unnamed model is still a request and must keep a bucket of its
    /// own in the rows, the days and the hours the chart draws from.
    func testKnownZeroCostAndUnnamedModelKeepTheirOwnBuckets() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("vercel", "vercel-ai-gateway")])
        var zero = gatewayRow(
            key: "vercel", provider: "vercel-ai-gateway", model: "openai/gpt-4.1",
            requestId: "z1", input: 0, output: 0
        )
        zero.reportedCostUsdTicks = 0
        try service.recordGatewayUsage(zero)
        // The gateway records no model name when the request named none and the response
        // reported none. That is a real call, not a malformed one.
        try service.recordGatewayUsage(gatewayRow(
            key: "vercel", provider: "vercel-ai-gateway", model: nil,
            at: "2026-09-05T13:00:00Z", requestId: "m1", input: nil, output: nil
        ))

        let keys = try report(db)
        XCTAssertEqual(keys.totals.gatewayCalls, 2)
        XCTAssertEqual(keys.totals.gatewayUsdEstimate ?? -1, 0, accuracy: 1e-12, "a reported zero is known")
        XCTAssertEqual(keys.totals.gatewayUnpricedCalls, 1, "only the receiptless call is unpriced")
        let priced = try XCTUnwrap(keys.rows.first { $0.model == "openai/gpt-4.1" })
        XCTAssertEqual(priced.usdEstimate ?? -1, 0, accuracy: 1e-12, "zero, not nil: the receipt said so")
        let unnamed = try XCTUnwrap(keys.rows.first { ($0.model ?? "").isEmpty })
        XCTAssertEqual(unnamed.modelCalls, 1, "a request with no model name is still a request")
        XCTAssertNil(unnamed.usdEstimate, "and its cost is unknown, which is not zero")

        // The chart draws the buckets, not the rows, so the same two facts have to survive into
        // both bucketings — day and hour — or a request would vanish between the two.
        let day = try XCTUnwrap(keys.daily.first { $0.model.isEmpty })
        XCTAssertEqual(day.modelCalls, 1)
        XCTAssertEqual(keys.daily.reduce(0) { $0 + $1.modelCalls }, keys.totals.gatewayCalls)
        let today = try report(db, by: .hour, range: .today)
        XCTAssertEqual(today.points.reduce(0) { $0 + $1.modelCalls }, today.totals.gatewayCalls)
        XCTAssertEqual(today.points.filter { $0.model.isEmpty }.reduce(0) { $0 + $1.modelCalls }, 1)

        let json = String(data: try JSONValue.data(keys.jsonObject()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"model\":\"\""), "the empty model name reaches the page as it is")
        XCTAssertTrue(json.contains("\"usd_estimate\":0"), "a known zero is serialized, not omitted")
    }

    /// The row a key is named in is the key's name, never its value.
    func testReportNamesKeysAndNeverTheirSecrets() throws {
        let (db, _) = try makeDB()
        let service = try service(db, keys: [("alpha", "anthropic")])
        try service.recordGatewayUsage(gatewayRow(key: "alpha", requestId: "s1"))
        let json = String(data: try JSONValue.data(try report(db).jsonObject()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"key\":\"alpha\""))
        XCTAssertFalse(json.contains("synthetic-alpha"))
    }
}
