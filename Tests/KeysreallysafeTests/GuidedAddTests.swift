import XCTest
@testable import KeysCore

/// Guided `keys add`: provider-first picker, unique suggested name, hidden confirmed
/// secret, non-TTY usage error and unknown-provider suggestions. Every secret here is
/// generated at runtime; none is a fixed key-shaped literal.
final class GuidedAddTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    /// Runtime-generated synthetic value: never committed, never printed by the flow.
    private func syntheticSecret() -> String {
        "guided-\(UUID().uuidString.lowercased())"
    }

    /// The scripted terminal: answers the provider and name prompts and records the order.
    private final class FakeUI: GuidedAddInteracting {
        var providerAnswer: String??
        var nameAnswer: String??
        private(set) var calls: [String] = []
        private(set) var candidatesSeen: [String] = []
        private(set) var suggestionSeen: String?

        func pickProvider(candidates: [Providers.Record]) -> String? {
            calls.append("provider")
            candidatesSeen = candidates.map(\.id)
            return providerAnswer ?? nil
        }

        func promptName(suggestion: String) -> String? {
            calls.append("name")
            suggestionSeen = suggestion
            return nameAnswer ?? nil
        }
    }

    private struct Rig {
        let service: KeysService
        let secrets: MemorySecretStore
        let ui: FakeUI
        var secretCalls: [(clipboard: Bool, confirm: Bool)] = []
        var emitted: [String] = []
        var secret: String = ""
    }

    private func makeRig() throws -> Rig {
        let (db, _) = try makeDB()
        let (service, secrets, _) = makeService(db: db)
        return Rig(service: service, secrets: secrets, ui: FakeUI())
    }

    /// Runs the guided engine against the rig with the fake terminal and a recording
    /// secret reader that hands back a runtime-generated synthetic value.
    private func runGuided(_ rig: inout Rig, isTTY: Bool = true) throws -> String? {
        let secret = syntheticSecret()
        rig.secret = secret
        return try GuidedAdd.run(
            service: rig.service,
            isTTY: isTTY,
            kind: "runtime",
            notes: "",
            clipboard: false,
            ui: rig.ui,
            readSecret: { clipboard, confirm in
                rig.secretCalls.append((clipboard, confirm))
                return secret
            },
            emit: { rig.emitted.append($0) }
        )
    }

    // VAL-ADD-001: provider first, then the suggested name, then the hidden confirmed
    // secret; exactly one row is written and the secret never reaches the output.
    func testGuidedFlowAsksProviderNameThenConfirmedSecret() throws {
        var rig = try makeRig()
        rig.ui.providerAnswer = "openrouter"
        rig.ui.nameAnswer = ""
        let added = try runGuided(&rig)
        XCTAssertEqual(added, "openrouter")
        XCTAssertEqual(rig.ui.calls, ["provider", "name"])
        XCTAssertEqual(rig.ui.suggestionSeen, "openrouter")
        XCTAssertEqual(rig.secretCalls.count, 1)
        XCTAssertEqual(rig.secretCalls.first?.clipboard, false)
        XCTAssertEqual(rig.secretCalls.first?.confirm, true, "the hidden prompt stays confirmed")
        let rows = try rig.service.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "openrouter")
        XCTAssertEqual(rows[0].provider, "openrouter")
        XCTAssertEqual(rows[0].kind, "runtime")
        XCTAssertEqual(rows[0].notes, "")
        XCTAssertEqual(try rig.secrets.get(name: "openrouter"), rig.secret)
        XCTAssertEqual(rig.emitted, ["added openrouter"])
        XCTAssertFalse(rig.emitted.joined(separator: "\n").contains(rig.secret))
    }

    // VAL-ADD-002: typing "o" leads with OpenAI, OpenRouter, Ollama even though the
    // shipped OpenAI row is hidden; the catalog flag itself is untouched.
    func testTypeAheadRanksOpenAIFirstForO() throws {
        let entries = GuidedProviders.pickerEntries(userHidden: [])
        XCTAssertTrue(entries.contains { $0.id == "openai" }, "the approved picker exception")
        XCTAssertEqual(Providers.provider(id: "openai")?.hidden, true, "the catalog row stays hidden")
        // No other hidden shipped record leaks into the picker.
        XCTAssertFalse(entries.contains { $0.hidden && $0.id != GuidedProviders.pickerHiddenException })
        let ranked = GuidedProviders.rank("o", in: entries)
        XCTAssertEqual(Array(ranked.prefix(3).map(\.id)), ["openai", "openrouter", "ollama"])
    }

    // VAL-ADD-002: arrows and Tab move the selection; Enter accepts the current match,
    // which is the top match when the user never navigated.
    func testPickerArrowTabAndEnterSelection() throws {
        let entries = GuidedProviders.pickerEntries(userHidden: [])
        var picker = ProviderPicker(candidates: entries)
        picker.handle(.char("o"))
        XCTAssertEqual(picker.matches.prefix(3).map(\.id), ["openai", "openrouter", "ollama"])
        XCTAssertEqual(picker.accept(), "openai", "Enter accepts the top match")
        picker.handle(.down)
        XCTAssertEqual(picker.accept(), "openrouter")
        picker.handle(.tab)
        XCTAssertEqual(picker.accept(), "ollama", "Tab moves like Down")
        picker.handle(.up)
        picker.handle(.up)
        XCTAssertEqual(picker.accept(), "openai", "Up climbs back, clamped at the top")
        picker.handle(.backspace)
        XCTAssertEqual(picker.query, "")
        picker.handle(.char("x"))
        XCTAssertEqual(picker.matches.first?.id, "xai")
    }

    // VAL-ADD-002: a provider the user added (the overlay) is a picker candidate too.
    func testOverlayProvidersAreSelectable() throws {
        var rig = try makeRig()
        try rig.service.addProvider(id: "ollamacorp", name: "Ollama Corp", host: "ollama.corp.test", api: "openai")
        let entries = GuidedProviders.pickerEntries(userHidden: [])
        XCTAssertTrue(entries.contains { $0.id == "ollamacorp" })
        XCTAssertEqual(GuidedProviders.rank("ollamac", in: entries).first?.id, "ollamacorp")

        rig.ui.providerAnswer = "ollamacorp"
        rig.ui.nameAnswer = ""
        let added = try runGuided(&rig)
        XCTAssertEqual(added, "ollamacorp")
        XCTAssertEqual(try rig.service.list().first?.provider, "ollamacorp")
    }

    // VAL-ADD-002: a provider the user hid stays out of the guided picker.
    func testUserHiddenProviderStaysOutOfThePicker() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.setProviderHidden(id: "groq", hidden: true)
        let hidden = try db.hiddenProviderIds()
        let entries = GuidedProviders.pickerEntries(userHidden: hidden)
        XCTAssertFalse(entries.contains { $0.id == "groq" })
        XCTAssertTrue(entries.contains { $0.id == "openai" }, "the picker exception is unaffected")
    }

    // VAL-ADD-003: the suggestion comes from the provider id, is valid, and steps aside
    // for names already taken.
    func testSuggestedNameIsProviderDerivedValidAndUnique() throws {
        XCTAssertEqual(GuidedAdd.suggestedName(provider: "openrouter", taken: []), "openrouter")
        XCTAssertEqual(GuidedAdd.suggestedName(provider: "openrouter", taken: ["openrouter"]), "openrouter-2")
        XCTAssertEqual(
            GuidedAdd.suggestedName(provider: "openrouter", taken: ["openrouter", "openrouter-2"]),
            "openrouter-3"
        )
        for taken in [Set<String>(), ["openrouter"], ["openrouter", "openrouter-2"]] {
            XCTAssertNoThrow(try KeyName.validate(GuidedAdd.suggestedName(provider: "openrouter", taken: taken)))
        }
    }

    // VAL-ADD-003: an edited name is validated and stored as typed.
    func testEditedNameIsStored() throws {
        var rig = try makeRig()
        rig.ui.providerAnswer = "xai"
        rig.ui.nameAnswer = "my-grok"
        let added = try runGuided(&rig)
        XCTAssertEqual(added, "my-grok")
        XCTAssertEqual(try rig.service.list().map(\.name), ["my-grok"])
        XCTAssertEqual(try rig.secrets.get(name: "my-grok"), rig.secret)
    }

    // VAL-ADD-003: a collision with an existing row bumps the suggestion.
    func testSuggestionDisambiguatesAgainstExistingNames() throws {
        var rig = try makeRig()
        try rig.service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: syntheticSecret())
        rig.ui.providerAnswer = "xai"
        rig.ui.nameAnswer = ""
        let added = try runGuided(&rig)
        XCTAssertEqual(rig.ui.suggestionSeen, "xai-2")
        XCTAssertEqual(added, "xai-2")
        XCTAssertEqual(try rig.service.list().count, 2)
    }

    // VAL-ADD-004: cancelling at the provider prompt or the name prompt writes nothing
    // and never asks for a secret.
    func testCancelAtProviderOrNameAddsNothing() throws {
        var rig = try makeRig()
        rig.ui.providerAnswer = nil
        XCTAssertNil(try runGuided(&rig))
        XCTAssertEqual(rig.ui.calls, ["provider"])
        XCTAssertTrue(rig.secretCalls.isEmpty)
        XCTAssertTrue(try rig.service.list().isEmpty)
        XCTAssertEqual(rig.emitted, ["cancelled"])

        var rig2 = try makeRig()
        rig2.ui.providerAnswer = "xai"
        rig2.ui.nameAnswer = nil
        XCTAssertNil(try runGuided(&rig2))
        XCTAssertEqual(rig2.ui.calls, ["provider", "name"])
        XCTAssertTrue(rig2.secretCalls.isEmpty)
        XCTAssertTrue(try rig2.service.list().isEmpty)
        XCTAssertEqual(rig2.emitted, ["cancelled"])
    }

    // VAL-ADD-004: a confirmation mismatch surfaces the error and writes no row and no
    // secret.
    func testSecretMismatchAddsNothing() throws {
        let (db, _) = try makeDB()
        let (service, secrets, _) = makeService(db: db)
        let ui = FakeUI()
        ui.providerAnswer = "xai"
        ui.nameAnswer = ""
        XCTAssertThrowsError(try GuidedAdd.run(
            service: service,
            isTTY: true,
            kind: "runtime",
            notes: "",
            clipboard: false,
            ui: ui,
            readSecret: { _, _ in throw AppError.usage("secrets do not match") },
            emit: { _ in }
        )) { error in
            XCTAssertEqual((error as? AppError)?.description, "secrets do not match")
        }
        XCTAssertTrue(try service.list().isEmpty)
        XCTAssertThrowsError(try secrets.get(name: "xai"))
    }

    // VAL-ADD-005: without a TTY the no-argument form is a clear usage error; the picker
    // and the hidden prompt are never invoked.
    func testNoTTYNoArgumentsIsAClearUsageError() throws {
        var rig = try makeRig()
        XCTAssertThrowsError(try runGuided(&rig, isTTY: false)) { error in
            let text = (error as? AppError)?.description ?? ""
            XCTAssertTrue(text.contains("interactive terminal"), text)
            XCTAssertTrue(text.contains("--provider"), text)
        }
        XCTAssertTrue(rig.ui.calls.isEmpty, "the picker never ran")
        XCTAssertTrue(rig.secretCalls.isEmpty, "no hidden prompt and no store call")
        XCTAssertTrue(try rig.service.list().isEmpty)
    }

    // VAL-ADD-006: an unknown explicit provider fails with resolvable suggestions and
    // stores nothing; known ids, hidden ones included, pass.
    func testUnknownProviderFailsWithDidYouMean() throws {
        XCTAssertThrowsError(try GuidedAdd.validateExplicitProvider("opena")) { error in
            let text = (error as? AppError)?.description ?? ""
            XCTAssertTrue(text.contains("unknown provider opena"), text)
            XCTAssertTrue(text.contains("did you mean"), text)
            XCTAssertTrue(text.contains("openai"), text)
        }
        XCTAssertThrowsError(try GuidedAdd.validateExplicitProvider("olama")) { error in
            let text = (error as? AppError)?.description ?? ""
            XCTAssertTrue(text.contains("ollama"), text)
        }
        // Every suggestion resolves to a known provider.
        for suggestion in GuidedProviders.didYouMean("opena") {
            XCTAssertNotNil(Providers.provider(id: suggestion), suggestion)
        }
        // Known ids pass, including the retired-but-resolvable hidden OpenAI row.
        XCTAssertNoThrow(try GuidedAdd.validateExplicitProvider("openai"))
        XCTAssertNoThrow(try GuidedAdd.validateExplicitProvider("xai"))
        XCTAssertThrowsError(try GuidedAdd.validateExplicitProvider("  ")) { error in
            XCTAssertEqual((error as? AppError)?.description, "provider is required")
        }
    }

    // VAL-ADD-006: overlay ids are valid explicit providers and suggestion sources.
    func testOverlayProviderIsAValidExplicitChoice() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", api: "openai")
        XCTAssertNoThrow(try GuidedAdd.validateExplicitProvider("acme"))
        XCTAssertTrue(GuidedProviders.didYouMean("acme2").contains("acme"))
    }

    // VAL-ADD-007: the flagged form parses exactly as before, the bare form now parses
    // into the guided path, and invalid options still fail at parse time.
    func testExistingFlagsStillParse() throws {
        let explicit = try XCTUnwrap(
            try KeysCLI.parseAsRoot(["add", "n", "--provider", "xai", "--kind", "billing", "--notes", "hi", "--clipboard"])
                as? AddCommand
        )
        XCTAssertEqual(explicit.name, "n")
        XCTAssertEqual(explicit.provider, "xai")
        XCTAssertEqual(explicit.kind, "billing")
        XCTAssertEqual(explicit.notes, "hi")
        XCTAssertTrue(explicit.clipboard)

        let bare = try XCTUnwrap(try KeysCLI.parseAsRoot(["add"]) as? AddCommand)
        XCTAssertNil(bare.name)
        XCTAssertNil(bare.provider)
        XCTAssertEqual(bare.kind, "runtime")

        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["add", "--bogus"]))
        // --help leaves the parser through ArgumentParser's help path, not AddCommand.
        XCTAssertFalse(try KeysCLI.parseAsRoot(["add", "--help"]) is AddCommand)
    }
}
