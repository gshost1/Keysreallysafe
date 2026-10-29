import Foundation
import XCTest
@testable import KeysCore

/// F1 VAL-FB-001..008: the pure scrubber, one case per removal category. Every
/// fake key-shaped string is built at runtime (prefix + repeated pattern), so no
/// committed literal looks like a secret, and the "vault values" are plain
/// in-memory inputs — the scrubber takes them as strings, never from a store.
final class FeedbackScrubberTests: XCTestCase {

    /// The shipped provider catalog, pinned to the prefixes these tests lean on:
    /// a providers.json change fails naming the prefix, not the rule.
    private func records() throws -> [Providers.Record] {
        let list = Providers.builtinList()
        let prefixes = Set(list.compactMap(\.keyPrefix))
        for prefix in ["sk-ant-", "AIza", "xai-", "gsk_"] {
            XCTAssertTrue(prefixes.contains(prefix), "the shipped catalog still pins \(prefix)")
        }
        return list
    }

    @discardableResult
    private func scrub(
        _ draft: String,
        prompt: String? = nil,
        vaultValues: [String] = [],
        names: [String] = [],
        records: [Providers.Record]? = nil,
        cap: Int = FeedbackScrubber.defaultCap
    ) throws -> (scrubbed: String, removed: [String: Int]) {
        try FeedbackScrubber.scrub(.init(
            draft: draft,
            prompt: prompt,
            vaultValues: vaultValues,
            names: names,
            records: try records ?? self.records(),
            cap: cap
        ))
    }

    // MARK: - vault_value (VAL-FB-001)

    /// A planted vault value is removed by exact match and counted under
    /// vault_value, every occurrence; a value shorter than Redact's 4-character
    /// floor is left alone, exactly like `Redact.scrub`'s loop.
    func testVaultValueExactMatchRemovedAndCounted() throws {
        let fakeVault = "fake-vault-" + String(repeating: "v3", count: 8)
        var out = try scrub("the key \(fakeVault) broke, twice: \(fakeVault)", vaultValues: [fakeVault])
        XCTAssertTrue(out.scrubbed.contains("[redacted]"), "the mask is Redact's: \(out.scrubbed)")
        XCTAssertFalse(out.scrubbed.contains(fakeVault))
        XCTAssertEqual(out.scrubbed, "the key [redacted] broke, twice: [redacted]")
        XCTAssertEqual(out.removed[FeedbackScrubber.vaultValue], 2, "one count per occurrence")

        // The floor: a 3-character value is not a needle (Redact's rule), and a
        // value absent from the draft counts nothing.
        out = try scrub("abc and xyz", vaultValues: ["xyz", "not-present-1234"])
        XCTAssertEqual(out.scrubbed, "abc and xyz", "the 3-character needle is under Redact's floor")
        XCTAssertNil(out.removed[FeedbackScrubber.vaultValue], "nothing was removed")
        XCTAssertNil(out.removed[FeedbackScrubber.keyShape], "no shape rule touched the prose")
    }

    /// VAL-F-004. Obfuscated vault values and split tokens are caught: a value
    /// with whitespace or zero-width characters inserted, its percent-encoded
    /// form, its base64 form and a Keysrs token split across a line break are
    /// all removed — zero-width characters are normalized away before matching,
    /// the encoded variants are enumerated as needles, and a split token is
    /// matched through the break. Every obfuscated form is shaped so the
    /// key-shape rule cannot backstop it (each piece is under its 16-character
    /// floor), so each one leaks unless the vault/token rules handle it.
    func testObfuscatedVaultValuesAndSplitTokensRemoved() throws {
        let fakeVault = "fake vault " + String(repeating: "s3", count: 5)
        let inserted = "fake  vault " + String(repeating: "s3", count: 5)
        let zeroWidth = "fake\u{200B}vault\u{200B}" + String(repeating: "s3", count: 5)
        let percentEncoded = FeedbackDelivery.queryValue(fakeVault)
        let base64 = Data(fakeVault.utf8).base64EncodedString()
        XCTAssertNotEqual(percentEncoded, fakeVault, "the value must actually percent-encode")

        // A real token split so the tail is under the shape rule's floor.
        let token = GatewayClientToken.generate()
        let head = String(token.prefix(40))
        let tail = String(token.dropFirst(40))
        XCTAssertLessThan(tail.count, 16, "the second half is under the shape rule's floor")

        let draft = [
            "plain \(fakeVault)",
            "spaced \(inserted)",
            "zero \(zeroWidth)",
            "encoded \(percentEncoded)",
            "b64 \(base64)",
            "split \(head)\n\(tail)",
        ].joined(separator: " ")
        let out = try scrub(draft, vaultValues: [fakeVault])
        XCTAssertFalse(out.scrubbed.contains(fakeVault), "the plain value is gone")
        XCTAssertFalse(out.scrubbed.contains(inserted),
                       "the whitespace-inserted value is gone: \(out.scrubbed)")
        XCTAssertFalse(out.scrubbed.contains(zeroWidth),
                       "the zero-width value is gone: \(out.scrubbed)")
        XCTAssertFalse(out.scrubbed.contains(percentEncoded), "the percent-encoded value is gone")
        XCTAssertFalse(out.scrubbed.contains(base64), "the base64 value is gone")
        XCTAssertFalse(out.scrubbed.contains(tail), "the split token's tail is gone: \(out.scrubbed)")
        XCTAssertEqual(out.removed[FeedbackScrubber.vaultValue], 5,
                       "the plain, inserted, zero-width, percent-encoded and base64 forms are all vault_value")
    }

    // MARK: - token (VAL-FB-003)

    /// Full Keysrs token shapes, prefix-bearing short runs and the bare prefixes
    /// are all removed and counted under token — the scrubber is deliberately
    /// stricter than the output guard, whose length floors would let a short run
    /// through. The scrubbed text then passes the guard unchanged.
    func testKeysrsTokenShapesAndPrefixesRemoved() throws {
        let grant = GrantToken.generate(id: "feed0001")
        let client = GatewayClientToken.generate()
        let pairing = RelayPairing.generate()
        let relay = RelaySecret.generate()
        let shortRun = GatewayClientToken.prefix + "0a1b2c3d"
        let draft = [
            "grant \(grant), client \(client), pairing \(pairing), relay \(relay)",
            "short \(shortRun), bare \(GrantToken.prefix) \(GatewayClientToken.prefix)",
            "\(RelayPairing.prefix) \(RelaySecret.prefix)",
        ].joined(separator: "\n")
        let out = try scrub(draft)
        for planted in [grant, client, pairing, relay, shortRun] {
            XCTAssertFalse(out.scrubbed.contains(planted), "no token survives: \(out.scrubbed)")
        }
        XCTAssertFalse(out.scrubbed.contains("ksfp_"))
        XCTAssertFalse(out.scrubbed.contains("ksfr_"))
        XCTAssertEqual(out.removed[FeedbackScrubber.token], 9, "four shapes, one short run, four bare prefixes")

        // The guard's own pattern has length floors; the scrubber must be
        // stricter, and the scrubbed text must pass the guard unchanged.
        XCTAssertTrue(grant.range(of: MCPOutputGuard.tokenShapePattern, options: .regularExpression) != nil)
        XCTAssertFalse(shortRun.range(of: MCPOutputGuard.tokenShapePattern, options: .regularExpression) != nil,
                        "the short run is under the guard's floor — the scrubber catches it anyway")
        let screened = MCPOutputGuard.production.screened(MCPToolResult.text(out.scrubbed))
        XCTAssertFalse(screened.isError, "the scrubbed text passes the output guard")
    }

    // MARK: - key_shape (VAL-FB-002)

    /// Long distinctive provider prefixes are evidence on their own; generic
    /// 16–512 printable tokens are removed by shape; a short prefix alone is
    /// not proof; Bearer and api-key header shapes count here too.
    func testProviderKeyShapesRemovedByShape() throws {
        let anthropic = "sk-ant-" + String(repeating: "aB", count: 10)
        let google = "AIza" + String(repeating: "Sy", count: 15)
        let xai = "xai-" + String(repeating: "x9", count: 10)
        let groq = "gsk_" + String(repeating: "g5", count: 10)
        let generic = String(repeating: "q7", count: 16)
        let draft = "keys: \(anthropic) \(google) \(xai) \(groq) and a bare \(generic)"
        var out = try scrub(draft)
        for planted in [anthropic, google, xai, groq, generic] {
            XCTAssertFalse(out.scrubbed.contains(planted), "no key shape survives: \(out.scrubbed)")
        }
        XCTAssertEqual(out.removed[FeedbackScrubber.keyShape], 5, "one count per key-shaped token")

        // A long prefix is evidence on its own, even when the rest is short.
        out = try scrub("the prefix sk-ant- alone")
        XCTAssertFalse(out.scrubbed.contains("sk-ant-"))
        XCTAssertEqual(out.removed[FeedbackScrubber.keyShape], 1)

        // A short common prefix (sk-) names no provider (several share it) and
        // is not key-shaped alone: corroborated or left alone.
        out = try scrub("the prefix sk- alone is not a key")
        XCTAssertTrue(out.scrubbed.contains("sk-"), "a short prefix alone survives corroboration")
        XCTAssertNil(out.removed[FeedbackScrubber.keyShape])
        let longShortPrefix = "sk-" + String(repeating: "c4", count: 12)
        out = try scrub("the key \(longShortPrefix) is shaped")
        XCTAssertFalse(out.scrubbed.contains(longShortPrefix),
                       "a short prefix on an otherwise key-shaped token is corroborated")
        XCTAssertEqual(out.removed[FeedbackScrubber.keyShape], 1)

        // Header shapes from Redact.scrub count here, prefix kept, value masked.
        let header = String(repeating: "h8", count: 8)
        out = try scrub("Bearer \(header) and api-key: \(header) and x-api-key: \(header)")
        XCTAssertTrue(out.scrubbed.contains("Bearer [redacted]"))
        XCTAssertTrue(out.scrubbed.contains("api-key: [redacted]"))
        XCTAssertTrue(out.scrubbed.contains("x-api-key: [redacted]"))
        XCTAssertFalse(out.scrubbed.contains(header))
        XCTAssertEqual(out.removed[FeedbackScrubber.keyShape], 3)
    }

    // MARK: - path (VAL-FB-004)

    /// Whitespace-delimited tokens starting / or ~ are removed without
    /// corroboration; URLs start with a scheme and never match.
    func testPathsRemovedURLsSurvive() throws {
        let draft = "config at /usr/local/etc/keys and ~/Documents/report.pdf, home ~ too, "
            + "but https://github.com/gshost1/Keysreallysafe/issues and http://127.0.0.1:12767/demo stay"
        let out = try scrub(draft)
        XCTAssertFalse(out.scrubbed.contains("/usr/local/etc/keys"))
        XCTAssertFalse(out.scrubbed.contains("~/Documents/report.pdf"))
        XCTAssertFalse(out.scrubbed.contains("~ too"), "the bare tilde is a path token")
        XCTAssertTrue(out.scrubbed.contains("https://github.com/gshost1/Keysreallysafe/issues"))
        XCTAssertTrue(out.scrubbed.contains("http://127.0.0.1:12767/demo"))
        XCTAssertEqual(out.removed[FeedbackScrubber.path], 3)
        XCTAssertNil(out.removed[FeedbackScrubber.keyShape], "URLs are not key-shaped")
    }

    /// VAL-F-002. A path is caught anywhere in the text, not only as a
    /// whitespace-delimited token starting with `/` or `~`: quoted,
    /// parenthesised, backticked, `cwd:`-prefixed, `path=`-prefixed and
    /// `file://` forms all leak under the old whole-token rule because none of
    /// them is a bare token starting with the slash. The pinned http(s) URL
    /// survivors still survive.
    func testPathsRemovedInEveryQuotedContext() throws {
        let draft = #"see "/Users/planted/quoted" and (/Users/planted/paren) "#
            + "and `~/planted/backtick` and cwd:/Users/planted/cwd and "
            + "file:///Users/planted/file and path=/Users/planted/eq and \"/x\", "
            + "then https://github.com/gshost1/Keysreallysafe/issues stays"
        let out = try scrub(draft)
        for planted in ["/Users/planted/quoted", "/Users/planted/paren", "~/planted/backtick",
                        "/Users/planted/cwd", "/Users/planted/file", "/Users/planted/eq", "/x"] {
            XCTAssertFalse(out.scrubbed.contains(planted), "\(planted) survived: \(out.scrubbed)")
        }
        XCTAssertTrue(out.scrubbed.contains("https://github.com/gshost1/Keysreallysafe/issues"),
                      "the pinned http(s) survivor stays")
        XCTAssertEqual(out.removed[FeedbackScrubber.path], 7, "one count per path form")
    }

    // MARK: - name (VAL-FB-005)

    /// Catalog key names and project labels are removed as whole words; an
    /// embedded occurrence inside a longer word stays (word-boundary aware).
    func testNamesAndLabelsRemoved() throws {
        let draft = "the demo key in the e2e-proj project, also work-anthropic; demographic stays"
        let out = try scrub(draft, names: ["demo", "e2e-proj", "work-anthropic"])
        XCTAssertFalse(out.scrubbed.contains("demo key"), "the name is gone: \(out.scrubbed)")
        XCTAssertFalse(out.scrubbed.contains("e2e-proj"))
        XCTAssertFalse(out.scrubbed.contains("work-anthropic"))
        XCTAssertTrue(out.scrubbed.contains("demographic"), "word boundaries keep embedded text")
        XCTAssertEqual(out.removed[FeedbackScrubber.name], 3)
    }

    /// VAL-F-003. Key names and project labels match case-insensitively, and a
    /// label is escaped data, never a pattern. The old `\Q…\E` form was
    /// terminated by a literal `\E` inside a label, which made the pattern
    /// invalid and the whole rule was silently skipped (the `try?`), so both
    /// names leaked; a name in the wrong case leaked too because the match was
    /// case-sensitive.
    func testNamesAndLabelsRemovedCaseInsensitivelyAndEscaped() throws {
        let label = "proj" + "\\Eevil"
        let draft = "the DEMO key in the \(label) project"
        let out = try scrub(draft, names: ["demo", label])
        XCTAssertFalse(out.scrubbed.contains("DEMO"), "case-insensitive: \(out.scrubbed)")
        XCTAssertFalse(out.scrubbed.contains(label),
                       "the \\E label is escaped, not a pattern: \(out.scrubbed)")
        XCTAssertEqual(out.removed[FeedbackScrubber.name], 2)
    }

    // MARK: - fail closed (VAL-F-003)

    /// VAL-F-003. `replaceRegex` fails CLOSED on a pattern that will not
    /// compile: it throws rather than the old `try?` that silently returned 0
    /// and skipped the whole rule. The text is left untouched, so the caller
    /// (the feedback route) sees the error and opens nothing instead of sending
    /// text a rule never ran on.
    func testReplaceRegexFailsClosedOnInvalidPattern() throws {
        var text = "the DEMO key survives"
        XCTAssertThrowsError(
            try FeedbackScrubber.replaceRegex(&text, "(unterminated", with: Redact.mask)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("pattern"),
                          "the refusal names the pattern: \(error)")
        }
        XCTAssertEqual(text, "the DEMO key survives", "a failed compile leaves the text untouched")
    }

    // MARK: - email (VAL-FB-006)

    /// Email-shaped strings are removed except support@keysrs.com.
    func testEmailsRemovedExceptSupport() throws {
        let draft = "write joe@example.com or Support+tag@Example.co.uk, not support@keysrs.com"
        let out = try scrub(draft)
        XCTAssertFalse(out.scrubbed.contains("joe@example.com"))
        XCTAssertFalse(out.scrubbed.contains("Support+tag@Example.co.uk"))
        XCTAssertTrue(out.scrubbed.contains("support@keysrs.com"), "the support address survives")
        XCTAssertEqual(out.removed[FeedbackScrubber.email], 2)
    }

    /// VAL-F-006. An email using the fullwidth `＠` (U+FF20) is redacted like an
    /// ASCII one — the ASCII-only pattern missed it and the shape rule rejected
    /// the non-ASCII scalar — while `support@keysrs.com` stays exempt.
    func testFullwidthAtEmailsRemoved() throws {
        let draft = "write to user\u{FF20}example.com or support@keysrs.com please"
        let out = try scrub(draft)
        XCTAssertFalse(out.scrubbed.contains("user\u{FF20}example.com"),
                       "the fullwidth-＠ email is gone: \(out.scrubbed)")
        XCTAssertTrue(out.scrubbed.contains("support@keysrs.com"), "the support address survives")
        XCTAssertEqual(out.removed[FeedbackScrubber.email], 1)
    }

    // MARK: - prompt_text (VAL-FB-007)

    /// The prompt argument's exact text is removed and counted; without the
    /// argument nothing is removed on that account. The rule runs immediately
    /// after vault_value and before every rewriting rule (F1), so the prompt is
    /// claimed whole even when a path, an email or a key shape inside it would
    /// otherwise be masked first and the exact match would then find nothing.
    func testPromptTextRemoved() throws {
        let marker = "the user asked for MARKER-Q7 output"
        let draft = "the user said \(marker) and it repeated \(marker) later"
        var out = try scrub(draft, prompt: marker)
        XCTAssertFalse(out.scrubbed.contains(marker))
        XCTAssertEqual(out.removed[FeedbackScrubber.promptText], 2)

        out = try scrub(draft)
        XCTAssertTrue(out.scrubbed.contains(marker), "no prompt argument, no prompt_text removal")
        XCTAssertNil(out.removed[FeedbackScrubber.promptText])
    }

    /// VAL-F-001. A prompt whose text carries what the rewriting rules would
    /// mask — a path and an email — is removed WHOLE: the prompt_text rule runs
    /// right after vault_value, so no rewriting rule has a chance to rewrite a
    /// part of the prompt first and leave the exact match with nothing to find
    /// (the pre-fix leak: the path and email were masked, then the exact
    /// prompt match missed and the rest of the prompt stayed in the draft).
    func testPromptTextRemovedBeforeRewritingRules() throws {
        let marker = "the user asked about /Users/planted/secret and joe@example.com please"
        let draft = "intro \(marker) outro"
        let out = try scrub(draft, prompt: marker)
        XCTAssertFalse(out.scrubbed.contains(marker))
        XCTAssertFalse(out.scrubbed.contains("the user asked about"),
                       "the whole prompt is gone, not just the parts a rewriting rule would have masked")
        XCTAssertEqual(out.removed[FeedbackScrubber.promptText], 1)
    }

    /// I4. The prompt is zero-width-normalized like the draft: a zero-width
    /// character inside the prompt argument would otherwise make the exact match
    /// miss the already-stripped draft, and the whole prompt would stay in it.
    /// Failed pre-fix: the match missed and the prompt text survived.
    func testAPromptCarryingZeroWidthCharactersIsStillRemoved() throws {
        let marker = "please look at my private project notes"
        let spiked = "please look at my\u{200B} private\u{2060} project notes"
        let out = try scrub("intro \(spiked) outro", prompt: spiked)
        XCTAssertFalse(out.scrubbed.contains(marker), "the prompt is gone from the draft")
        XCTAssertFalse(out.scrubbed.contains("private project"))
        XCTAssertEqual(out.removed[FeedbackScrubber.promptText], 1)
    }

    // MARK: - length (VAL-FB-008)

    /// The cap runs AFTER scrubbing, so a secret straddling the 10,000-character
    /// cut is masked whole first and no prefix of it survives the cut.
    func testLengthCapRunsAfterScrubbing() throws {
        let fakeVault = "fake-vault-" + String(repeating: "b2", count: 8)
        let filler1 = String(repeating: "word ", count: 1_998) // exactly 9,990 characters
        let filler2 = String(repeating: "tail ", count: 600)
        let draft = filler1 + fakeVault + filler2 // the value straddles the 10,000 cut
        let out = try scrub(draft, vaultValues: [fakeVault])

        XCTAssertEqual(out.scrubbed.count, FeedbackScrubber.defaultCap, "the cap is exactly 10,000")
        XCTAssertFalse(out.scrubbed.contains(fakeVault))
        XCTAssertFalse(out.scrubbed.contains(String(fakeVault.prefix(10))),
                       "scrub-then-cap: the cut never lands inside a secret")
        XCTAssertTrue(out.scrubbed.contains("[redacted]"), "the whole value was masked before the cut")
        XCTAssertEqual(out.removed[FeedbackScrubber.vaultValue], 1)
        // The length count is the character count removed by the cap: the
        // scrubbed-before-cap text lost exactly the value-minus-mask difference.
        let scrubbedBeforeCap = draft.count - fakeVault.count + "[redacted]".count
        XCTAssertEqual(out.removed[FeedbackScrubber.length], scrubbedBeforeCap - FeedbackScrubber.defaultCap)

        // Under the cap: no length entry at all.
        let short = try scrub("short text", vaultValues: [fakeVault])
        XCTAssertNil(short.removed[FeedbackScrubber.length])
    }

    // MARK: - the combined shape

    /// One draft carrying every category: each removal lands in its own bucket,
    /// the JSON keys are the pinned eight, and nothing planted survives.
    func testMixedDraftCountsEveryCategory() throws {
        let fakeVault = "fake-vault-" + String(repeating: "m1", count: 8)
        let grant = GrantToken.generate(id: "feed0002")
        let anthropic = "sk-ant-" + String(repeating: "aB", count: 10)
        let marker = "the user asked for MARKER-Z3 output"
        let draft = "the \(fakeVault) leaked with \(grant) and \(anthropic) from /Users/planted/folder "
            + "in the demo project fb-e2e, mailed to agent@example.com about \(marker)"
        let out = try scrub(draft, prompt: marker, vaultValues: [fakeVault], names: ["demo", "fb-e2e"])

        XCTAssertEqual(out.removed[FeedbackScrubber.vaultValue], 1)
        XCTAssertEqual(out.removed[FeedbackScrubber.token], 1)
        XCTAssertEqual(out.removed[FeedbackScrubber.keyShape], 1)
        XCTAssertEqual(out.removed[FeedbackScrubber.path], 1)
        XCTAssertEqual(out.removed[FeedbackScrubber.name], 2)
        XCTAssertEqual(out.removed[FeedbackScrubber.email], 1)
        XCTAssertEqual(out.removed[FeedbackScrubber.promptText], 1)
        XCTAssertEqual(
            Set(out.removed.keys),
            Set([FeedbackScrubber.vaultValue, FeedbackScrubber.token, FeedbackScrubber.keyShape,
                 FeedbackScrubber.path, FeedbackScrubber.name, FeedbackScrubber.email,
                 FeedbackScrubber.promptText]),
            "the pinned category keys, nothing else"
        )
        for planted in [fakeVault, grant, anthropic, "/Users/planted/folder", "agent@example.com", marker, "demo", "fb-e2e"] {
            XCTAssertFalse(out.scrubbed.contains(planted), "\(planted) survived: \(out.scrubbed)")
        }
        // The prose a human still needs to read stays readable.
        XCTAssertTrue(out.scrubbed.contains("leaked with"))
        XCTAssertTrue(out.scrubbed.contains("mailed to"))
    }
}
