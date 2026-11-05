import Foundation
import XCTest
@testable import KeysCore

/// A renewal re-opens a grant's window; it does not forgive spending.
///
/// A call authorized before a renewal can finish minutes later (the upstream limit is 900 s,
/// and the renewal's Touch ID prompt sits in between). Charging that completion to the window
/// it was authorized under looks tidier, but it lets real spend escape `maxUsd` entirely and
/// throws away the unpriced strike that keeps a capped grant fail-closed — a caller could renew
/// its way out of its own overspend. So the charge lands on the CURRENT window, as it always
/// did before the renewal plumbing existed, and these tests pin that.
final class GrantRenewalChargeTests: XCTestCase {
    private func grant(
        _ store: GrantStore,
        maxUsd: Double? = nil,
        maxRequests: Int? = nil,
        at now: Date = Date()
    ) throws -> (grant: Grant, token: String) {
        store.issue(
            key: "demo", provider: "openai", host: "h",
            request: try GrantRequest(
                task: "x", minutes: 10, methods: ["POST"],
                paths: [], maxRequests: maxRequests, maxUsd: maxUsd
            ).validated(),
            now: now
        )
    }

    private func authorize(
        _ store: GrantStore, _ issued: (grant: Grant, token: String), at now: Date = Date()
    ) throws -> Grant {
        try store.authorize(
            token: issued.token, key: "demo", host: "h", method: "POST",
            rest: "chat", providerPrefix: "", now: now
        ).get()
    }

    // MARK: - store

    /// The money was spent. A completion that straddles a renewal is charged to the current
    /// window, so the renewed window cannot show less spend than the grant actually made.
    func testAChargeThatStraddlesARenewalLandsOnTheCurrentWindow() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let issued = try grant(store, maxUsd: 1, at: t0)
        _ = try authorize(store, issued, at: t0)

        let t1 = t0.addingTimeInterval(3600)
        let renewed = try store.renew(id: issued.grant.id, now: t1)
        store.charge(id: renewed.id, usd: 0.75)

        let after = try XCTUnwrap(store.grant(id: issued.grant.id))
        XCTAssertEqual(after.usd, 0.75, "the call was really made and really billed; the renewal does not forgive it")
        XCTAssertEqual(after.renewals, 1)
        XCTAssertEqual(after.requests, 0, "the renewed window's request count still starts at zero")

        // And the cap the renewal re-opened still binds against that spend.
        store.charge(id: renewed.id, usd: 0.5)
        XCTAssertEqual(store.grant(id: issued.grant.id)?.usd, 1.25)
        XCTAssertEqual(
            store.authorize(
                token: issued.token, key: "demo", host: "h", method: "POST",
                rest: "chat", providerPrefix: "", now: t1
            ),
            .failure(.usdLimit),
            "a straddling charge counts against maxUsd rather than hiding outside it"
        )
    }

    /// An unpriced completion is the fail-closed strike. Dropping the straddling one would let
    /// a capped grant keep authorizing with spend it can no longer measure.
    func testAnUnpricedCompletionThatStraddlesARenewalStillBlocksTheGrant() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let issued = try grant(store, maxUsd: 1, at: t0)
        _ = try authorize(store, issued, at: t0)

        let t1 = t0.addingTimeInterval(3600)
        _ = try store.renew(id: issued.grant.id, now: t1)
        store.charge(id: issued.grant.id, usd: nil)

        XCTAssertEqual(store.grant(id: issued.grant.id)?.unpricedCalls, 1)
        XCTAssertEqual(
            store.authorize(
                token: issued.token, key: "demo", host: "h", method: "POST",
                rest: "chat", providerPrefix: "", now: t1
            ),
            .failure(.usdUnpriced),
            "an unpriced call on a capped grant keeps it fail-closed across a renewal"
        )
    }

    /// A non-billable completion (a GET, an error answer) is not a strike either way.
    func testANonBillableCompletionIsNotAStrikeAfterARenewal() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let issued = try grant(store, maxUsd: 1, at: t0)
        _ = try authorize(store, issued, at: t0)
        _ = try store.renew(id: issued.grant.id, now: t0.addingTimeInterval(3600))
        store.charge(id: issued.grant.id, usd: nil, billable: false)
        XCTAssertEqual(store.grant(id: issued.grant.id)?.unpricedCalls, 0)
    }

    /// The request cap is unchanged: a call authorized before the renewal counted against the
    /// window that admitted it, and the renewed window starts at zero.
    func testTheRequestCapIsUnchangedByRenewal() throws {
        let store = GrantStore()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let issued = try grant(store, maxRequests: 1, at: t0)
        _ = try authorize(store, issued, at: t0)
        XCTAssertEqual(
            store.authorize(
                token: issued.token, key: "demo", host: "h", method: "POST",
                rest: "chat", providerPrefix: "", now: t0
            ),
            .failure(.requestLimit)
        )
        _ = try store.renew(id: issued.grant.id, now: t0.addingTimeInterval(60))
        XCTAssertNoThrow(try authorize(store, issued, at: t0.addingTimeInterval(61)))
    }

    // MARK: - the gateway call site

    /// The gateway charges through `recordGatewayUsage`; a completion recorded after the
    /// renewal moves the current window's counters, because that is where the money went.
    func testGatewayRecordsACompletionAfterARenewalAgainstTheCurrentWindow() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let issued = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x", minutes: 10, methods: ["POST"], maxUsd: 1).validated(),
            now: Date()
        )
        _ = try XCTUnwrap(try? service.grants.authorize(
            token: issued.token, key: "demo", host: "api.openai.com", method: "POST",
            rest: "chat", providerPrefix: "/v1"
        ).get())
        _ = try service.grants.renew(id: issued.grant.id)

        let row = GatewayUsageRow(
            ts: UTC.iso(Date()), key: "demo", provider: "openai", model: "gpt-4.1",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0,
            status: 200, durationMs: 5, requestId: nil, reportedCostUsdTicks: Int64(Ticks.perUSD / 2),
            via: nil, upstreamHost: "api.openai.com", reason: "upstream_status"
        )
        try service.recordGatewayUsage(row, grantId: issued.grant.id)
        XCTAssertEqual(
            service.grants.grant(id: issued.grant.id)?.usd, 0.5,
            "the completion is charged to the current window, not dropped"
        )
    }
}
