import XCTest
@testable import KeysCore

/// Custom providers, the merged catalog listing and the hide flag. The overlay is
/// process-wide, so every test resets it when it is done.
final class ProviderCatalogTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    private func listing(_ service: KeysService) throws -> [[String: Any]] {
        let object = try service.providersJSONObject()
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        return providers
    }

    func testAddCustomProviderResolvesAndLists() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let record = try service.addProvider(
            id: "acme", name: "Acme", host: "api.acme.dev", api: "openai",
            authHeader: "x-acme-key", authPrefix: "Token ", pathPrefix: "v1", keyPrefix: "acme_",
            note: "Acme corp gateway", gateway: true
        )
        XCTAssertEqual(record.custom, true)
        XCTAssertEqual(record.host, "api.acme.dev")
        // Normalized to the shipped shape: a leading slash on the path prefix.
        XCTAssertEqual(record.pathPrefix, "/v1")
        XCTAssertEqual(record.authPrefix, "Token ")

        // The overlay wins over the shipped file, so gateway lookups resolve it.
        let resolved = try XCTUnwrap(Providers.provider(id: "acme"))
        XCTAssertEqual(resolved.host, "api.acme.dev")
        XCTAssertEqual(resolved.api, "openai")

        let rows = try listing(service)
        let mine = try XCTUnwrap(rows.first { $0["id"] as? String == "acme" })
        XCTAssertEqual(mine["custom"] as? Bool, true)
        XCTAssertEqual(mine["group"] as? String, "yours")
        XCTAssertEqual(mine["host"] as? String, "api.acme.dev")
        let groups = try XCTUnwrap(try service.providersJSONObject()["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["id"] as? String, "yours", "yours comes first in the listing")
    }

    func testCustomProviderSurvivesRestartAndCarriesAGatewayKey() throws {
        let (db, dir) = try makeDB()
        let (service, secrets, _) = makeService(db: db)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", api: "openai")
        try service.add(name: "acme-key", provider: "acme", kind: "runtime", notes: "", secret: "ACME-secret-1")
        let enabled = try service.setGateway(name: "acme-key", enabled: true, host: nil)
        XCTAssertEqual(enabled.gatewayHost, "api.acme.dev")
        XCTAssertEqual(try secrets.get(name: "acme-key"), "ACME-secret-1")

        // A second service over the same catalog is a restart; the overlay must come back.
        let (service2, _, _) = makeService(db: try CatalogDB(path: dir.appendingPathComponent("catalog.db")))
        XCTAssertNotNil(Providers.provider(id: "acme"))
        let target = service2.lookupGateway(name: "acme-key")
        XCTAssertNil(target, "gateway memory is per process; the catalog row is what persists")
        let row = try XCTUnwrap(try service2.list().first { $0.name == "acme-key" })
        XCTAssertEqual(row.gatewayHost, "api.acme.dev")
    }

    func testRemoveProviderRefusesWhileAKeyUsesIt() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", api: "openai")
        try service.add(name: "acme-key", provider: "acme", kind: "runtime", notes: "", secret: "ACME-secret-1")
        XCTAssertThrowsError(try service.removeProvider(id: "acme")) { error in
            XCTAssertEqual((error as? AppError)?.description.contains("acme-key"), true)
        }
        try service.remove(name: "acme-key", caller: "test")
        XCTAssertNoThrow(try service.removeProvider(id: "acme"))
        XCTAssertNil(Providers.provider(id: "acme"))
        XCTAssertFalse(try db.customProviderExists(id: "acme"))
    }

    func testRemoveProviderRefusesBuiltinsAndPointsAtHide() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        XCTAssertThrowsError(try service.removeProvider(id: "anthropic")) { error in
            let text = (error as? AppError)?.description ?? ""
            XCTAssertEqual(text.contains("hide it instead"), true)
        }
        XCTAssertThrowsError(try service.removeProvider(id: "no-such-provider")) { error in
            XCTAssertEqual((error as? AppError)?.description.contains("no-such-provider"), true)
        }
    }

    func testHideMarksTheListingButTheRecordStillResolves() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.setProviderHidden(id: "groq", hidden: true)
        var rows = try listing(service)
        let groq = try XCTUnwrap(rows.first { $0["id"] as? String == "groq" })
        XCTAssertEqual(groq["hidden"] as? String, "user")
        // Hidden is a listing concern; the gateway, checks and names still resolve.
        XCTAssertEqual(Providers.provider(id: "groq")?.host, "api.groq.com")

        try service.setProviderHidden(id: "groq", hidden: false)
        rows = try listing(service)
        let back = try XCTUnwrap(rows.first { $0["id"] as? String == "groq" })
        XCTAssertEqual(back["hidden"] as? NSNull, NSNull())

        // The retired shipped entry carries the app reason, not the user one.
        let openai = try XCTUnwrap(rows.first { $0["id"] as? String == "openai" })
        XCTAssertEqual(openai["hidden"] as? String, "app")
        // Hiding a user-added provider is refused; removal is the answer there.
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev")
        XCTAssertThrowsError(try service.setProviderHidden(id: "acme", hidden: true))
    }

    func testCustomEntryOverridesABuiltInUntilRemoved() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        XCTAssertEqual(Providers.provider(id: "anthropic")?.host, "api.anthropic.com")
        try service.addProvider(id: "anthropic", name: "Anthropic (fixed)", host: "api.anthropic-fixed.com", api: "anthropic")
        XCTAssertEqual(Providers.provider(id: "anthropic")?.host, "api.anthropic-fixed.com")
        var rows = try listing(service)
        // The override replaces the shipped record in the listing, so there is exactly one.
        XCTAssertEqual(rows.filter { ($0["id"] as? String) == "anthropic" }.count, 1)
        XCTAssertEqual(rows.first { ($0["id"] as? String) == "anthropic" }?["custom"] as? Bool, true)
        try service.removeProvider(id: "anthropic")
        XCTAssertEqual(Providers.provider(id: "anthropic")?.host, "api.anthropic.com")
        rows = try listing(service)
        XCTAssertEqual((rows.first { ($0["id"] as? String) == "anthropic" }?["custom"] as? Bool), false)
    }

    func testAddProviderValidatesEveryField() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        XCTAssertThrowsError(try service.addProvider(id: "Acme", name: "Acme")) { error in
            XCTAssertEqual((error as? AppError)?.description.contains("lowercase"), true)
        }
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", api: "grpc"))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", authHeader: "x api key"))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", authPrefix: String(repeating: "y", count: 40)))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", pathPrefix: "v1/../etc"))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", note: "two\nlines"))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: "x", host: "https://api.acme.dev/path"))
        XCTAssertThrowsError(try service.addProvider(id: "", name: "x"))
        XCTAssertThrowsError(try service.addProvider(id: "a", name: ""))
        XCTAssertFalse(try db.customProviderExists(id: "a"))
    }

    func testProviderAPIRoutesServeAndGuardTheCatalog() throws {
        let (handler, service, _) = try makeHandler()
        let list = handle(handler, method: "GET", path: "/api/providers")
        XCTAssertEqual(list.status, 200)
        let object = try XCTUnwrap((try? JSONSerialization.jsonObject(with: list.body)).flatMap(JSONValue.object))
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.isEmpty, false)

        let body = try JSONValue.data([
            "id": "acme", "name": "Acme", "host": "api.acme.dev", "api": "openai",
            "auth_header": "x-acme-key", "auth_prefix": "Token ", "path_prefix": "v1",
        ])
        let added = handle(handler, method: "POST", path: "/api/providers", body: body)
        XCTAssertEqual(added.status, 201)
        XCTAssertNotNil(Providers.provider(id: "acme"))

        let hidden = try JSONValue.data(["hidden": true])
        let patched = handle(handler, method: "PATCH", path: "/api/providers/groq", body: hidden)
        XCTAssertEqual(patched.status, 200)
        let groq = try XCTUnwrap(try listing(service).first { $0["id"] as? String == "groq" })
        XCTAssertEqual(groq["hidden"] as? String, "user")

        let removed = handle(handler, method: "DELETE", path: "/api/providers/acme")
        XCTAssertEqual(removed.status, 200)
        XCTAssertNil(Providers.provider(id: "acme"))

        // Mutations stay behind the per-launch token like every other write.
        let guardResponse = handle(handler, method: "POST", path: "/api/providers", body: body, token: false)
        XCTAssertEqual(guardResponse.status, 403)
    }
}
