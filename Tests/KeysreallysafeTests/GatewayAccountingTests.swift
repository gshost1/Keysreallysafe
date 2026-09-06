import Foundation
import XCTest
@testable import KeysCore

/// One upstream call must be counted once, and an unknown cost must never read as zero.
final class GatewayAccountingTests: XCTestCase {
    private let now = UTC.parse("2026-09-05T18:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func report(_ db: CatalogDB, key: String? = nil) throws -> SpendReport {
        try SpendQueries(db: db).report(range: .month, by: .model, source: .all, now: now, timeZone: utc, key: key)
    }

    private func gatewayRow(requestId: String?, model: String? = "claude-sonnet-5", provider: String = "anthropic") -> GatewayUsageRow {
        GatewayUsageRow(
            ts: "2026-09-05T12:00:00Z", key: "probe", provider: provider, model: model,
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
            status: 200, durationMs: 1, requestId: requestId
        )
    }

    func testGatewayDollarsAreNotAddedToTheLocalEstimate() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "probe", provider: "anthropic", kind: "runtime", notes: "", secret: "synthetic")
        let line = #"{"type":"assistant","sessionId":"same-call","requestId":"req_1","timestamp":"2026-09-05T12:00:00Z","message":{"id":"msg-1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let local = try XCTUnwrap(ClaudeIngest.parseLine(line))
        _ = try db.insertUsage(local)
        let before = try report(db)
        // The gateway saw the same call but no request id was available to prove it.
        try service.recordGatewayUsage(gatewayRow(requestId: nil))
        let after = try report(db)
        XCTAssertEqual(after.totals.tokens, before.totals.tokens, "gateway tokens must not inflate the local token total")
        XCTAssertEqual(after.totals.usdEstimate ?? -1, before.totals.usdEstimate ?? -1, accuracy: 1e-12)
        XCTAssertEqual(after.totals.gatewayCalls, 1)
        XCTAssertEqual(after.totals.gatewayTokens, 150)
        XCTAssertNotNil(after.totals.gatewayUsdEstimate)
        XCTAssertEqual(after.totals.gatewayCorrelatedCalls, 0)
        let json = after.jsonObject()["totals"] as! [String: Any]
        XCTAssertEqual(json["usd_estimate_scope"] as? String, SpendTotals.localScope)
        XCTAssertEqual(json["gateway_calls"] as? Int, 1)
    }

    func testMatchingRequestIdDropsTheGatewayCopy() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "probe", provider: "anthropic", kind: "runtime", notes: "", secret: "synthetic")
        let line = #"{"type":"assistant","sessionId":"same-call","requestId":"req_abc","timestamp":"2026-09-05T12:00:00Z","message":{"id":"msg-1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
        _ = try db.insertUsage(try XCTUnwrap(ClaudeIngest.parseLine(line)))
        try service.recordGatewayUsage(gatewayRow(requestId: "req_abc"))
        try service.recordGatewayUsage(gatewayRow(requestId: "req_other"))
        let all = try report(db)
        XCTAssertEqual(all.totals.gatewayCorrelatedCalls, 1)
        XCTAssertEqual(all.totals.gatewayCalls, 1)
        XCTAssertEqual(all.rows.filter { $0.key == "probe" }.count, 1, "only the uncorrelated gateway call remains as a keyed row")
        // Per-key view is the gateway's own ledger; nothing local carries a key, so nothing is dropped.
        let keyed = try report(db, key: "probe")
        XCTAssertEqual(keyed.totals.gatewayCalls, 2)
        XCTAssertEqual(keyed.totals.gatewayCorrelatedCalls, 0)
        // A retry with the same upstream id is one usage row, not two.
        try service.recordGatewayUsage(gatewayRow(requestId: "req_other"))
        XCTAssertEqual(try report(db, key: "probe").totals.gatewayCalls, 2)
    }

    func testUnknownGatewayCostIsNullNotZero() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "probe", provider: "anthropic", kind: "runtime", notes: "", secret: "synthetic")
        try service.recordGatewayUsage(gatewayRow(requestId: "r1", model: nil))
        let months = try service.monthGatewayByKey(now: now, timeZone: utc)
        let month = try XCTUnwrap(months["probe"])
        XCTAssertNil(month.usd)
        XCTAssertEqual(month.kind, "unknown")
        XCTAssertEqual(month.unpricedCalls, 1)
        XCTAssertEqual(month.unpricedTokens, 150)
        let row = try XCTUnwrap(db.catalogRow(name: "probe"))
        let obj = service.keyJSONObject(row, month: month)
        XCTAssertTrue(obj["usd_month"] is NSNull)
        XCTAssertEqual(obj["usd_month_kind"] as? String, "unknown")
        XCTAssertEqual(obj["gateway_month_unpriced_calls"] as? Int, 1)

        try service.recordGatewayUsage(gatewayRow(requestId: "r2"))
        let partial = try XCTUnwrap(try service.monthGatewayByKey(now: now, timeZone: utc)["probe"])
        XCTAssertEqual(partial.kind, "partial")
        XCTAssertNotNil(partial.usd)
        XCTAssertEqual(partial.calls, 2)

        let totals = try report(db, key: "probe").totals
        XCTAssertEqual(totals.gatewayUnpricedCalls, 1)
        XCTAssertEqual(totals.gatewayUnpricedTokens, 150)
        XCTAssertEqual(totals.gatewayUnpricedModels, ["unknown"])
        let json = try report(db, key: "probe").jsonObject()["totals"] as! [String: Any]
        XCTAssertEqual(json["gateway_usd_estimate_label"] as? String, EstimateLabel.text(unpricedCount: 1))
    }

    func testNoCallsIsNoneAndZeroDollarsStaysExplicit() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "idle", provider: "anthropic", kind: "runtime", notes: "", secret: "synthetic")
        let obj = try service.keyJSONObject(try XCTUnwrap(db.catalogRow(name: "idle")))
        XCTAssertEqual(obj["usd_month_kind"] as? String, "none")
        XCTAssertTrue(obj["usd_month"] is NSNull)
        XCTAssertEqual(obj["gateway_month_calls"] as? Int, 0)
    }
}
