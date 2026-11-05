import Foundation
import XCTest
@testable import KeysCore

/// Three regressions the generation rework introduced, each pinned at the interleaving that
/// produced it: a grant outliving `keys rm` once the cached target was already gone, a rotation
/// read mid-way by a lookup as a changed target, and an enable that lost its key to another
/// provider during the prompt but still rewrote the stored host.
final class GatewayRaceRegressionTests: XCTestCase {
    private func request() throws -> GrantRequest {
        try GrantRequest(task: "x", methods: ["GET"], paths: ["/models"]).validated()
    }

    /// Delete revokes every grant on the key, armed or not, and the audit row names the caller.
    func testDeleteRevokesAGrantWhoseTargetWasAlreadyGone() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        // The grant exists but no target is cached: the window between an enable's publish and
        // a gateway-off that ran before the grant was minted.
        let (grant, _) = service.grants.issue(key: "demo", provider: "openai", host: "api.openai.com", request: try request())
        XCTAssertFalse(service.isGatewayEnabled("demo"))

        try service.remove(name: "demo", caller: "cli")

        XCTAssertTrue(try XCTUnwrap(service.grants.grant(id: grant.id)).isRevoked, "a grant must not outlive its key")
        let revoke = try db.keyEvents(name: "demo", limit: 50).first { $0.action == "grant_revoke" }
        XCTAssertEqual(revoke?.caller, "cli")
    }

    /// Gateway off revokes the key's grants even when no target is cached, with the caller.
    func testGatewayOffRevokesWithTheCaller() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let (grant, _) = service.grants.issue(key: "demo", provider: "openai", host: "api.openai.com", request: try request())

        _ = try service.setGateway(name: "demo", enabled: false, host: nil, caller: "mcp")

        XCTAssertTrue(try XCTUnwrap(service.grants.grant(id: grant.id)).isRevoked)
        let revoke = try db.keyEvents(name: "demo", limit: 50).first { $0.action == "grant_revoke" }
        XCTAssertEqual(revoke?.caller, "mcp")
    }

    /// A lookup that lands between rotate's version bump and its cache update sees the new
    /// catalog version against the cached old one. That is the rotation, not a target change:
    /// the gateway stays armed and serves the new secret afterwards.
    func testALookupDuringRotationDoesNotTurnTheGatewayOff() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "old-synthetic")
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)

        final class Box: @unchecked Sendable { var mid: GatewayTarget?? }
        let box = Box()
        service.afterRotateVersionBump = { s in box.mid = .some(s.lookupGateway(name: "demo")) }
        _ = try service.rotate(name: "demo", secret: "new-synthetic")
        service.afterRotateVersionBump = nil

        XCTAssertEqual(box.mid.map { $0 == nil }, true, "mid-rotation the gateway answers not-now, never the old secret")
        XCTAssertTrue(service.isGatewayEnabled("demo"), "a rotation must not turn the gateway off")
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "new-synthetic")
    }

    /// The key moved to another provider while the enable prompt was up: nothing is written.
    func testAnEnableWhoseKeyChangedProviderLeavesTheHostAlone() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let before = try XCTUnwrap(db.catalogRow(name: "demo"))

        final class SwitchingGate: PresenceGate, @unchecked Sendable {
            let db: CatalogDB
            init(db: CatalogDB) { self.db = db }
            func require(reason: String) throws {
                _ = try db.updateCatalog(name: "demo", provider: "anthropic", kind: nil, notes: nil)
            }
        }
        XCTAssertThrowsError(
            try service.setGateway(name: "demo", enabled: true, host: nil, gate: SwitchingGate(db: db))
        )

        let after = try XCTUnwrap(db.catalogRow(name: "demo"))
        XCTAssertEqual(after.provider, "anthropic")
        XCTAssertEqual(after.gatewayHost, before.gatewayHost, "the old provider's host must not be written over the new one")
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }
}
