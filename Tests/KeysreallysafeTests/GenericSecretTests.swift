import XCTest
@testable import KeysCore

/// `--provider other`: a secret that belongs to no API provider (an Infisical
/// machine-identity client ID, say) is a shipped catalog row with the gateway off, so
/// the explicit form, the guided picker and keys stored under `other` by older versions
/// all resolve through the same record. Every secret here is generated at runtime.
final class GenericSecretTests: XCTestCase {
    private func syntheticSecret() -> String {
        "generic-\(UUID().uuidString.lowercased())"
    }

    private final class PickOther: GuidedAddInteracting {
        private(set) var candidatesSeen: [String] = []
        private(set) var suggestionSeen: String?
        let name: String

        init(name: String) { self.name = name }

        func pickProvider(candidates: [Providers.Record]) -> String? {
            candidatesSeen = candidates.map(\.id)
            return GuidedAdd.genericProvider
        }

        func promptName(suggestion: String) -> String? {
            suggestionSeen = suggestion
            return name
        }
    }

    func testOtherIsAShippedNonGatewayRow() throws {
        let record = try XCTUnwrap(Providers.provider(id: "other"))
        XCTAssertFalse(record.gateway, "never proxied")
        XCTAssertNil(record.host)
        XCTAssertFalse(record.hidden, "offered for new keys")
        XCTAssertNil(record.keyPrefix, "guesses no provider from a value")
        XCTAssertEqual(record.api, "other", "no usage parser")
        XCTAssertEqual(GuidedAdd.genericProvider, record.id)
    }

    func testKeysProvidersListsOther() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let listing = try service.providersJSONObject()
        let rows = (listing["providers"] as? [Any])?.compactMap { JSONValue.object($0) } ?? []
        let other = try XCTUnwrap(rows.first { JSONValue.string($0["id"]) == "other" })
        XCTAssertEqual(JSONValue.bool(other["gateway"]), false)
        XCTAssertTrue(other["hidden"] is NSNull)
    }

    func testExplicitOtherPassesAndUnknownProvidersPointAtIt() throws {
        XCTAssertNoThrow(try GuidedAdd.validateExplicitProvider("other"))
        for unknown in ["infisical", "zzzzqqqq"] {
            XCTAssertThrowsError(try GuidedAdd.validateExplicitProvider(unknown)) { error in
                let text = (error as? AppError)?.description ?? ""
                XCTAssertTrue(text.contains("unknown provider \(unknown)"), text)
                XCTAssertTrue(text.contains("--provider other"), text)
            }
        }
        let parsed = try XCTUnwrap(
            try KeysCLI.parseAsRoot(["add", "vps-ci-infisical-client-id", "--provider", "other", "--notes", "ci"])
                as? AddCommand
        )
        XCTAssertEqual(parsed.provider, "other")
    }

    func testStoredOtherKeyReadsBackAndNeverReachesTheGateway() throws {
        let (db, _) = try makeDB()
        let (service, secrets, clipboard) = makeService(db: db)
        let secret = syntheticSecret()
        try service.add(name: "vps-ci-infisical-client-secret", provider: "other", kind: "runtime",
                        notes: "Infisical ci-agent", secret: secret, caller: "add")
        XCTAssertEqual(try secrets.get(name: "vps-ci-infisical-client-secret"), secret)
        XCTAssertEqual(try service.get(name: "vps-ci-infisical-client-secret"), secret)
        try service.copy(name: "vps-ci-infisical-client-secret", holdUntilWipe: false)
        XCTAssertEqual(clipboard.value, secret)

        XCTAssertThrowsError(try service.issueGrant(
            name: "vps-ci-infisical-client-secret",
            request: GrantRequest(task: "fixture", methods: ["GET"], paths: ["/"], maxRequests: 1)
        )) { error in
            XCTAssertEqual((error as? AppError)?.description,
                           "gateway is not available for provider other; a grant cannot be issued")
        }
        XCTAssertThrowsError(try service.setGateway(name: "vps-ci-infisical-client-secret", enabled: true, host: nil)) { error in
            XCTAssertEqual((error as? AppError)?.description, "gateway is not available for this provider")
        }
        XCTAssertNil(service.lookupGateway(name: "vps-ci-infisical-client-secret"))
    }

    /// A row older versions wrote with `other` (before it was a catalog row) is just a
    /// catalog row; it now resolves and reads back the same way.
    func testPreexistingOtherRowKeepsWorking() throws {
        let (db, _) = try makeDB()
        let (service, secrets, _) = makeService(db: db)
        let secret = syntheticSecret()
        try secrets.add(name: "legacy-other", secret: secret)
        try db.insertCatalog(CatalogRow(name: "legacy-other", provider: "other", kind: "runtime", notes: "",
                                        createdAt: "2026-09-01T00:00:00Z", lastUsedAt: nil))
        XCTAssertEqual(try service.list().map(\.provider), ["other"])
        XCTAssertEqual(try service.get(name: "legacy-other"), secret)
        let json = try service.listJSONObject()
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(try service.checkTarget(name: "legacy-other").provider.id, "other")
    }

    func testGuidedPickerOffersOtherAndStoresIt() throws {
        let entries = GuidedProviders.pickerEntries(userHidden: [])
        XCTAssertTrue(entries.contains { $0.id == "other" })
        XCTAssertEqual(GuidedProviders.rank("other", in: entries).first?.id, "other")
        XCTAssertEqual(GuidedProviders.rank("secret", in: entries).first?.id, "other", "found by its name too")
        // The approved "o" ordering is untouched.
        XCTAssertEqual(Array(GuidedProviders.rank("o", in: entries).prefix(3).map(\.id)), ["openai", "openrouter", "ollama"])

        let (db, _) = try makeDB()
        let (service, secrets, _) = makeService(db: db)
        let ui = PickOther(name: "vps-ci-infisical-client-id")
        let secret = syntheticSecret()
        var emitted: [String] = []
        let added = try GuidedAdd.run(
            service: service, isTTY: true, kind: "runtime", notes: "", clipboard: false, ui: ui,
            readSecret: { _, confirm in
                XCTAssertTrue(confirm)
                return secret
            },
            emit: { emitted.append($0) }
        )
        XCTAssertEqual(added, "vps-ci-infisical-client-id")
        XCTAssertTrue(ui.candidatesSeen.contains("other"))
        XCTAssertEqual(ui.suggestionSeen, "other")
        XCTAssertEqual(try service.list().map(\.provider), ["other"])
        XCTAssertEqual(try secrets.get(name: "vps-ci-infisical-client-id"), secret)
        XCTAssertEqual(emitted, ["added vps-ci-infisical-client-id"])
    }
}
