import Foundation
import XCTest
@testable import KeysCore

/// The armed gateway's in-memory target is a snapshot of the catalog plus the provider record.
/// Three ways it used to drift: a lookup that read the catalog outside the cache lock could
/// hand out (or re-insert) the pre-rotation target after `rotate` had published the new
/// secret; an edit to a provider record left the armed target pointing the approved secret at a
/// request shape the user never saw; and a rename of that record revoked every grant for a
/// field that changes nothing about the request.
final class GatewayCacheFreshnessTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    /// Runs `body` once, inside the next catalog read of a lookup.
    private func once(_ body: @escaping @Sendable (KeysService) -> Void) -> @Sendable (KeysService) -> Void {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func take() -> Bool { lock.withLock {
                defer { fired = true }
                return !fired
            } }
        }
        let flag = Flag()
        return { service in
            if flag.take() { body(service) }
        }
    }

    /// A provider override that keeps the id and the host but changes the auth prefix: the
    /// armed target is a copy of the old record, so the approved secret would go out on a
    /// request shape the user never saw. The old comparison was id + host + catalog version,
    /// and none of those moved.
    func testAProviderRecordEditDropsTheArmedTarget() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertEqual(try XCTUnwrap(service.lookupGateway(name: "demo")).provider.authPrefix, "Bearer ")

        // `keys provider add openai …` overrides the shipped record without touching the key.
        try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com",
                                api: "openai", authPrefix: "Token ", pathPrefix: "v1")

        XCTAssertNil(
            service.lookupGateway(name: "demo"),
            "a changed provider record must not keep serving the approved secret on the old shape"
        )
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }

    /// The request shape is compared field by field, not the whole record: a change that keeps
    /// the id, the host and the catalog version still drops the armed target.
    func testTheProviderRequestShapeIsCompared() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.test", api: "openai", pathPrefix: "v1")
        try service.add(name: "demo", provider: "acme", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)

        var changed = try XCTUnwrap(Providers.provider(id: "acme"))
        changed.authHeader = "x-forward-to"
        Providers.setOverlay(["acme": changed])

        XCTAssertNil(service.lookupGateway(name: "demo"))
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }

    /// A cosmetic edit — a rename, a new note, another group or key-prefix hint, a hide in the
    /// picker — is not a request-shape change. Disowning the gateway for one of those revoked
    /// every grant on the key and turned a working gateway off for a label.
    func testACosmeticProviderEditKeepsTheArmedTarget() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.test", api: "openai", pathPrefix: "v1")
        try service.add(name: "demo", provider: "acme", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        let grant = try grantFor(service, "demo")

        var renamed = try XCTUnwrap(Providers.provider(id: "acme"))
        renamed.name = "Acme Gateway"
        renamed.note = "our own endpoint"
        renamed.group = "yours"
        renamed.keyPrefix = "acme-"
        renamed.hidden = true
        Providers.setOverlay(["acme": renamed])

        let armed = try XCTUnwrap(
            service.lookupGateway(name: "demo"),
            "a rename must not disown the gateway"
        )
        XCTAssertEqual(armed.provider.name, "Acme Gateway", "the refreshed record is carried")
        XCTAssertEqual(armed.host, "api.acme.test")
        XCTAssertNotNil(service.grants.grant(id: GrantToken.idOf(grant) ?? ""), "the grant survives")
    }

    /// A lookup that read the catalog row before a rotation committed must never answer with
    /// (or publish) the pre-rotation target: the rotation wins and the lookup re-reads.
    func testALookupNeverPublishesThePreRotationTarget() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "old-synthetic")
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)

        // The rotation lands between this lookup's catalog read and its cache publish.
        service.afterGatewayCatalogRead = once { service in
            _ = try? service.rotate(name: "demo", secret: "new-synthetic")
        }
        let result = service.lookupGateway(name: "demo")
        service.afterGatewayCatalogRead = nil

        let target = try XCTUnwrap(result, "the lookup re-reads and sees the rotation")
        XCTAssertEqual(target.secret, "new-synthetic", "never the value the rotation retired")
        XCTAssertEqual(target.version, try db.catalogRow(name: "demo")?.version)
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "new-synthetic")
    }

    /// A disable that lands while a lookup is reading the catalog wins: the lookup must not
    /// hand the caller a target for a gateway that is now off.
    func testAConcurrentDisableIsNotUndoneByALookup() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "api.openai.com")

        service.afterGatewayCatalogRead = once { service in
            _ = try? service.setGateway(name: "demo", enabled: false, host: nil)
        }
        let result = service.lookupGateway(name: "demo")
        service.afterGatewayCatalogRead = nil

        XCTAssertNil(result, "the disable is the newer state and the lookup honours it")
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }

    /// The rotation must survive a lookup that was already past the cache read: the enable
    /// reports the row it wrote and the cache holds the new secret, not the one it replaced.
    func testARotationStaysInForceAfterAConcurrentLookup() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "old-synthetic")
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)

        service.afterGatewayCatalogRead = once { service in
            _ = try? service.rotate(name: "demo", secret: "new-synthetic")
        }
        _ = service.lookupGateway(name: "demo")
        service.afterGatewayCatalogRead = nil

        let armed = try XCTUnwrap(service.lookupGateway(name: "demo"))
        XCTAssertEqual(armed.secret, "new-synthetic")
        XCTAssertEqual(armed.version, try db.catalogRow(name: "demo")?.version)
    }

    /// SECURITY: `setGateway` reads its secret and its generation in an order that used to let a
    /// rotation in between slip through. It read the secret, then (inside the retry loop) the
    /// generation; a rotate landing in that window replaced the value, bumped the version and
    /// the generation, and the publish then wrote the RETIRED secret back into the cache under
    /// the NEW version. `lookupGateway` compared versions, found them equal, and handed agents
    /// the pre-rotation value — the exact value the user rotated away from.
    ///
    /// The rotation is landed on `afterGatewaySetRowRead`, i.e. after the row this publish will
    /// use was read and before the secret is taken: no sleeps, and it fails on 9015b22.
    func testSetGatewayNeverPublishesThePreRotationSecret() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "old-synthetic")
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "old-synthetic")

        // Turning the gateway on again, with the rotation landing in the publish window.
        service.beforeGatewaySetRowRead = once { service in
            _ = try? service.rotate(name: "demo", secret: "new-synthetic")
        }
        let row = try service.setGateway(name: "demo", enabled: true, host: nil)
        service.beforeGatewaySetRowRead = nil

        let armed = try XCTUnwrap(service.lookupGateway(name: "demo"))
        XCTAssertEqual(armed.secret, "new-synthetic", "the rotation's value is what the gateway sends")
        XCTAssertEqual(armed.version, row.version)
        XCTAssertEqual(armed.version, try db.catalogRow(name: "demo")?.version)

        // And it stays that way for the next lookup, i.e. the retired value was not re-published.
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "new-synthetic")
    }

    /// The same rotation landed one step later: after the row this attempt would publish from
    /// was read, and before its secret. The secret read must still agree with that row, so the
    /// publish is either refused (the next attempt re-reads) or made with the new value — never
    /// the old secret under the new row's version.
    func testSetGatewayDoesNotPairAStaleSecretWithAFreshRow() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: "old-synthetic")
        _ = try service.setGateway(name: "demo", enabled: true, host: nil)

        service.afterGatewaySetRowRead = once { service in
            _ = try? service.rotate(name: "demo", secret: "new-synthetic")
        }
        let row = try service.setGateway(name: "demo", enabled: true, host: nil)
        service.afterGatewaySetRowRead = nil

        let armed = try XCTUnwrap(service.lookupGateway(name: "demo"))
        XCTAssertEqual(armed.secret, "new-synthetic", "never the retired value")
        XCTAssertEqual(armed.version, row.version)
    }

    /// The per-key generation must not make one key's change disown another's target. A single
    /// global counter meant a provider edit or a disable for one key made every other key's
    /// lookup retry, and after three attempts answer nil — a 404 and a gateway-off denial for a
    /// key nobody touched.
    func testOneKeysChangeDoesNotDisownAnotherKeysTarget() throws {
        let (db, _) = try makeDB()
        let (service, _) = try makeGatedService(db: db)
        try service.add(name: "alpha", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "bravo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "alpha", enabled: true, host: nil)
        _ = try service.setGateway(name: "bravo", enabled: true, host: nil)

        // Rotate one key: only its own generation moves.
        _ = try service.rotate(name: "alpha", secret: "rotated-synthetic")

        XCTAssertEqual(service.lookupGateway(name: "bravo")?.secret, fixtureSecret, "bravo is untouched")
        XCTAssertEqual(service.lookupGateway(name: "alpha")?.secret, "rotated-synthetic")

        // A provider edit that touches neither key's request shape leaves both armed.
        try service.addProvider(id: "unrelated", name: "Unrelated", host: "api.unrelated.test")
        XCTAssertNotNil(service.lookupGateway(name: "alpha"))
        XCTAssertNotNil(service.lookupGateway(name: "bravo"))

        // Disabling one key leaves the other's target alone.
        _ = try service.setGateway(name: "alpha", enabled: false, host: nil)
        XCTAssertNil(service.lookupGateway(name: "alpha"))
        XCTAssertNotNil(service.lookupGateway(name: "bravo"))
    }
}
