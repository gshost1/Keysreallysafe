import Foundation

/// The pure text core of `send_feedback`: removes from a feedback draft
/// everything that must never leave this Mac, and reports how much it removed
/// per category. It holds no seam, no store and no I/O — the app-side route
/// hands it the forbidden values it enumerated in memory (the vault values, the
/// catalog key names, the project labels, the provider records) and the marked
/// prompt text, and gets back `(scrubbed, removed)`. The mask is `Redact.mask`
/// (`[redacted]`) everywhere.
///
/// The rules, in the order they run (the order is the contract: exact matches
/// first, the cap LAST — scrub-then-cap, because a cut landing inside an
/// echoed secret would leave a prefix the whole-secret match no longer finds,
/// the `ProviderCheck` rule):
///
/// 1. `vault_value` — exact-substring removal of every vault value, the
///    `Redact.scrub` loop including its 4-character floor (a 3-character needle
///    is not evidence).
/// 2. `prompt_text` — the exact text of the `prompt` argument, whatever the
///    agent marked with it. This runs IMMEDIATELY after vault_value and before
///    every rewriting rule: once a rewriting rule has masked a part of the
///    prompt the exact match finds nothing and the rest of the prompt leaks,
///    so the prompt must be claimed before any rewriting rule can touch it.
/// 3. `token` — every Keysrs token family's runs, from the full minted shapes
///    down to a bare `ksf_`: `ksfp_`, `ksfc_`, `ksf_`, `ksfr_` followed by any
///    run of token characters. Deliberately stricter than the output guard,
///    whose length floors would let a short run through — the scrubber removes
///    the prefix itself, so nothing Keysrs-shaped can survive into a result
///    the guard would then have to reject.
/// 4. `key_shape` header forms — `Bearer <value>` and the
///    `x-api-key`/`x-goog-api-key`/`api-key`/`authorization: <value>` shapes
///    from `Redact.scrub`, prefix kept, value masked.
/// 5. `path` — a path anywhere in the text (after a quote, a paren, a backtick,
///    `cwd:`, `path=`, `file://`, or a plain boundary), removed without
///    corroboration: feedback leaves the Mac, so a leading slash is always a
///    path. http(s) URLs are lifted out first, so a URL's own slashes are never
///    read as a path and the pinned survivors stay.
/// 6. `email` — email-shaped strings except `support@keysrs.com` (the address
///    the feedback is going to); the fullwidth `＠` (U+FF20) counts as an `@`.
/// 7. `key_shape` token forms — provider-key-shaped tokens: a long distinctive
///    provider prefix (`sk-ant-`, `AIza`, `xai-`, `gsk_` — 4+ characters, one
///    owner in the catalog) is evidence on its own, exactly as `WrapDetect`
///    treats it; a short shared prefix (`sk-`) is corroborated only by the
///    token being otherwise key-shaped, and a plain 16–512 printable
///    single-token string is removed by shape alone.
/// 8. `name` — every catalog key name and project label, word-boundary aware
///    (so "demographic" keeps a key named "demo" embedded inside it),
///    case-insensitive and escaped (a label is data, never a pattern).
/// 9. `length` — the cap on the scrubbed text (10,000 characters). The count
///    is the character count the cap removed, not an occurrence count.
///
/// Only non-zero counts appear in `removed`, so the answer names exactly what
/// was taken out.
struct FeedbackScrubber {
    /// The scrub-then-cap bound on the scrubbed text, characters.
    static let defaultCap = 10_000

    // The JSON category keys the route answers with and the tests pin.
    static let vaultValue = "vault_value"
    static let token = "token"
    static let keyShape = "key_shape"
    static let path = "path"
    static let name = "name"
    static let email = "email"
    static let promptText = "prompt_text"
    static let length = "length"

    /// The one email address the email rule must leave alone: it is where the
    /// feedback is going.
    private static let supportAddress = "support@keysrs.com"

    /// One scrub request. `vaultValues`, `names` and `records` are what the
    /// app enumerated; a direct caller (a test) supplies its own fakes.
    struct Request {
        var draft: String
        var prompt: String?
        var vaultValues: [String]
        var names: [String]
        var records: [Providers.Record]
        var cap: Int

        init(
            draft: String,
            prompt: String? = nil,
            vaultValues: [String] = [],
            names: [String] = [],
            records: [Providers.Record] = [],
            cap: Int = FeedbackScrubber.defaultCap
        ) {
            self.draft = draft
            self.prompt = prompt
            self.vaultValues = vaultValues
            self.names = names
            self.records = records
            self.cap = cap
        }
    }

    static func scrub(_ request: Request) -> (scrubbed: String, removed: [String: Int]) {
        var removed: [String: Int] = [:]
        func bump(_ category: String, by count: Int) {
            guard count > 0 else { return }
            removed[category, default: 0] += count
        }

        var text = request.draft

        // 1. vault_value — the Redact loop, exact and whole, 4-character floor.
        for value in request.vaultValues where value.count >= 4 {
            bump(vaultValue, by: replaceLiteral(&text, value))
        }

        // 2. prompt_text — the marked text, exact and whole, BEFORE any
        //    rewriting rule: a rewriting rule that masks part of the prompt
        //    would leave the exact match with nothing to find.
        if let prompt = request.prompt, !prompt.isEmpty {
            bump(promptText, by: replaceLiteral(&text, prompt))
        }

        // 3. token — every Keysrs family's runs, full shape to bare prefix.
        bump(token, by: replaceRegex(&text, tokenRunPattern, with: Redact.mask))

        // 4. key_shape, header forms — prefix kept, value masked (Redact's two).
        bump(keyShape, by: replaceRegex(
            &text, #"(?i)(bearer\s+)[A-Za-z0-9._\-~+/=]{8,}"#, with: "$1" + Redact.mask
        ))
        bump(keyShape, by: replaceRegex(
            &text, #"(?i)(x-api-key|x-goog-api-key|api-key|authorization)(\s*[:=]\s*)\S+"#,
            with: "$1$2" + Redact.mask
        ))

        // 5. path — tokens starting / or ~, removed whole without corroboration.
        bump(path, by: scrubTokens(&text) { $0.hasPrefix("/") || $0.hasPrefix("~") })

        // 6. email — every email-shaped string except the support address.
        bump(email, by: replaceRegex(
            &text, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, with: Redact.mask,
            except: supportAddress
        ))

        // 7. key_shape, token forms — provider-prefix evidence and key shape.
        //    Path- and email-shaped tokens are the other rules' (rules 5 and 6
        //    claimed theirs; the spared support address is email-shaped and
        //    stays), so the shape scan judges only what is left.
        let records = request.records
        bump(keyShape, by: scrubTokens(&text) { token in
            guard !token.hasPrefix("/"), !token.hasPrefix("~"), !token.contains("@") else { return false }
            if let byPrefix = WrapDetect.providerFromPrefix(token, records: records), byPrefix.length >= 4 {
                return true
            }
            // No long distinctive prefix: the token must be key-shaped on its
            // own — the corroboration a short shared prefix needs, and the rule
            // that removes generic key-shaped strings.
            return WrapDetect.valueLooksLikeKey(token)
        })

        // 8. name — key names and project labels, whole words only.
        for needle in request.names where !needle.isEmpty {
            bump(name, by: replaceRegex(
                &text, #"(?<![A-Za-z0-9])\Q"# + needle + #"\E(?![A-Za-z0-9])"#, with: Redact.mask
            ))
        }

        // 9. length — the cap, LAST, on the scrubbed text (never mid-secret:
        //    every secret was already replaced above).
        if text.count > request.cap {
            bump(length, by: text.count - request.cap)
            text = String(text.prefix(request.cap))
        }

        return (text, removed)
    }

    /// The token-run pattern: each Keysrs family's prefix plus any run of
    /// token characters, which covers the full minted shapes, shorter runs and
    /// the bare prefixes in one rule per family. The families' prefixes are
    /// mutually exclusive (`ksf_` never prefixes `ksfc_`), so alternation order
    /// cannot change what matches. Unanchored, like the output guard's own
    /// scan: a run embedded in a bigger token is still a run.
    private static let tokenRunPattern = [
        RelayPairing.prefix, GatewayClientToken.prefix, GrantToken.prefix, RelaySecret.prefix,
    ]
    .map { NSRegularExpression.escapedPattern(for: $0) + "[A-Za-z0-9_\\-]*" }
    .joined(separator: "|")

    /// Replaces every non-overlapping literal occurrence of `needle` with the
    /// mask and returns how many it replaced. The search resumes after each
    /// inserted mask, so a needle that happens to be a substring of the mask
    /// itself can never re-match its own output.
    private static func replaceLiteral(_ text: inout String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
            text.replaceSubrange(found, with: Redact.mask)
            count += 1
            // The mask now occupies found.lowerBound..+9; continue past it.
            let maskEnd = text.index(found.lowerBound, offsetBy: Redact.mask.count)
            searchStart = maskEnd >= text.endIndex ? text.endIndex : maskEnd
        }
        return count
    }

    /// Replaces every match of `pattern` with `template` (an NSRegularExpression
    /// template: "$1" + mask keeps a prefix) and returns how many matches it
    /// replaced. Matches are collected against the original text and replaced
    /// back-to-front, so earlier ranges stay valid and no match is ever
    /// re-scanned. `except` spares one exact match, case-insensitive (the
    /// support address).
    private static func replaceRegex(
        _ text: inout String,
        _ pattern: String,
        with template: String,
        except spared: String? = nil
    ) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let source = text
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var replaced = 0
        for match in matches.reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            if let spared, String(source[range]).lowercased() == spared.lowercased() { continue }
            let replacement = regex.replacementString(for: match, in: source, offset: 0, template: template)
            text.replaceSubrange(range, with: replacement)
            replaced += 1
        }
        return replaced
    }

    /// Splits `text` into whitespace-delimited tokens, hands each to `claim`
    /// and replaces the claimed tokens with the mask, returning how many were
    /// claimed. Ranges are collected first and replaced back-to-front, so one
    /// pass over the original text classifies every token exactly once — a
    /// token never changes category mid-scan.
    private static func scrubTokens(_ text: inout String, claim: (String) -> Bool) -> Int {
        let source = text
        var claimed: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = source.startIndex
        while true {
            let atEnd = index == source.endIndex
            if atEnd || source[index].isWhitespace {
                if let start = tokenStart {
                    if claim(String(source[start..<index])) { claimed.append(start..<index) }
                    tokenStart = nil
                }
                if atEnd { break }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = source.index(after: index)
        }
        for range in claimed.reversed() {
            text.replaceSubrange(range, with: Redact.mask)
        }
        return claimed.count
    }
}
