import Darwin
import Foundation

/// The guided no-argument `keys add`: a provider-first picker over the merged shipped
/// catalog and user overlay, a provider-derived unique name suggestion, then the existing
/// hidden, confirmed `SecretPrompt`. The picker and prompts never see the secret; the
/// value enters only through the injected reader, which is `SecretPrompt.read` in the
/// real command and a recording fake in tests.

/// Providers the guided picker offers: the shipped catalog with the user overlay merged
/// on top. The one approved exception is the retired shipped OpenAI row, which the owner
/// approved for this picker only ("o" → OpenAI, OpenRouter, Ollama); its catalog flag and
/// the dashboard picker are untouched.
enum GuidedProviders {
    static let pickerHiddenException = "openai"

    /// Overlay (custom) records first, then the shipped ones in file order, skipping
    /// overridden ids, user-hidden ids and shipped-hidden records other than the one
    /// approved exception.
    static func pickerEntries(userHidden: Set<String>) -> [Providers.Record] {
        let custom = Providers.overlayRecords()
        var covered = Set<String>()
        var out: [Providers.Record] = []
        for record in custom.sorted(by: { $0.id < $1.id }) where !userHidden.contains(record.id) {
            out.append(record)
            covered.insert(record.id)
        }
        for record in Providers.builtinList() {
            guard !covered.contains(record.id), !userHidden.contains(record.id) else { continue }
            if record.hidden, record.id != pickerHiddenException { continue }
            out.append(record)
        }
        return out
    }

    /// Type-ahead ranking: id prefix beats name prefix beats substring, with the candidate
    /// order kept inside each tier, so "o" over the shipped catalog is OpenAI, OpenRouter,
    /// Ollama. An empty query is the whole list in picker order.
    static func rank(_ query: String, in candidates: [Providers.Record]) -> [Providers.Record] {
        let q = query.lowercased()
        guard !q.isEmpty else { return candidates }
        func tier(_ record: Providers.Record) -> Int? {
            if record.id.hasPrefix(q) { return 0 }
            if record.name.lowercased().hasPrefix(q) { return 1 }
            if record.id.contains(q) || record.name.lowercased().contains(q) { return 2 }
            return nil
        }
        return candidates
            .enumerated()
            .compactMap { index, record in tier(record).map { (index, record, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    /// Every resolvable id, hidden shipped ones included, for did-you-mean suggestions.
    static func allKnownIDs() -> [String] {
        var ids = Providers.builtinList().map(\.id)
        let known = Set(ids)
        for record in Providers.overlayRecords() where !known.contains(record.id) {
            ids.append(record.id)
        }
        return ids
    }

    /// Up to `limit` known ids near the mistyped one: prefix first, then substring, then
    /// edit distance. Every returned id resolves through `Providers.provider(id:)`.
    static func didYouMean(_ input: String, limit: Int = 3) -> [String] {
        let q = input.lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(id: String, score: Int)] = []
        for id in allKnownIDs() where id != q {
            let score: Int
            if id.hasPrefix(q) {
                score = 0
            } else if id.contains(q) {
                score = 1
            } else {
                let distance = levenshtein(q, id)
                guard distance <= max(2, q.count / 2) else { continue }
                score = 2 + distance
            }
            scored.append((id, score))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.id < $1.id }
            .prefix(limit)
            .map(\.id)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = above
            }
        }
        return row[b.count]
    }
}

/// The pure half of the provider picker: a query, the ranked matches and the selection.
/// The terminal driver and the tests feed it the same key sequence, so the ranking and
/// selection the user sees are exactly what the tests pin.
struct ProviderPicker {
    enum Key: Equatable {
        case char(Character)
        case backspace
        case up
        case down
        case tab
    }

    let candidates: [Providers.Record]
    private(set) var query = ""
    private(set) var matches: [Providers.Record]
    private(set) var selected = 0

    init(candidates: [Providers.Record]) {
        self.candidates = candidates
        self.matches = candidates
    }

    mutating func handle(_ key: Key) {
        switch key {
        case .char(let c):
            query.append(c)
            rerank()
        case .backspace:
            if !query.isEmpty {
                query.removeLast()
                rerank()
            }
        case .up:
            if selected > 0 { selected -= 1 }
        case .down, .tab:
            if selected < matches.count - 1 { selected += 1 }
        }
    }

    /// Enter: the current match, which is the top one when the user never navigated.
    /// Nil (no matches) leaves the picker running.
    func accept() -> String? {
        guard selected < matches.count else { return nil }
        return matches[selected].id
    }

    private mutating func rerank() {
        matches = GuidedProviders.rank(query, in: candidates)
        selected = 0
    }
}

/// The interactive half of the guided flow, so tests can script it.
protocol GuidedAddInteracting {
    /// The chosen provider id, or nil when the user cancels.
    func pickProvider(candidates: [Providers.Record]) -> String?
    /// The chosen name ("" accepts the suggestion), or nil when the user cancels.
    func promptName(suggestion: String) -> String?
}

enum GuidedAdd {
    /// The no-argument form without a terminal: an error, not a hidden prompt on /dev/tty.
    static let nonTTYUsage = "keys add with no arguments needs an interactive terminal; "
        + "use keys add <name> --provider <id> instead (see keys add --help)"

    /// A name the provider id derives, unique against the stored names.
    static func suggestedName(provider: String, taken: Set<String>) -> String {
        WrapNames.suggest(provider: provider, hint: nil, taken: taken)
    }

    /// The explicit `--provider` gate: the id must resolve through the merged catalog and
    /// overlay (hidden shipped rows still resolve, so retired ids stay valid). Unknown ids
    /// fail with the nearest known ids and nothing is stored.
    static func validateExplicitProvider(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.usage("provider is required") }
        guard Providers.provider(id: trimmed) == nil else { return }
        let near = GuidedProviders.didYouMean(trimmed)
        if near.isEmpty {
            throw AppError.usage("unknown provider \(trimmed); keys providers lists the valid ids")
        }
        throw AppError.usage("unknown provider \(trimmed); did you mean \(near.joined(separator: ", "))?")
    }

    /// The fixed refusal every secret-shaped name gets. It names no value, so the
    /// pasted key is neither echoed back nor logged (VAL-H-007).
    static let secretShapedNameMessage =
        "that looks like a pasted key rather than a name; name the key briefly, "
        + "and paste the key itself at the hidden prompt that follows"

    /// A name that looks like a secret is a paste aimed at the wrong prompt: the
    /// provider was picked first, and the hidden prompt that follows is where the
    /// key itself goes. The known shapes go first — the shipped providers' key
    /// prefixes (the same builtinList wrap detection reads, with wrap's key-shape
    /// length floor so the flow's own short provider-derived suggestions never
    /// trip it) and every Keysrs token prefix — then the shapeless remainder: a
    /// long run that is hex-only or digit-heavy is what a random secret looks
    /// like, and word-like names never are. Whitespace around a paste does not
    /// hide it. Refused before the secret prompt, the store and any emit, so a
    /// pasted key is never stored as a name and never printed (VAL-H-007).
    static func rejectSecretShapedName(
        _ name: String,
        records: [Providers.Record] = Providers.builtinList() + Providers.overlayRecords()
    ) throws {
        let pasted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerShaped = pasted.count >= 16
            && records.contains(where: { $0.keyPrefix.map(pasted.hasPrefix) ?? false })
        if providerShaped
            || [GrantToken.prefix, GatewayClientToken.prefix, RelaySecret.prefix, RelayPairing.prefix]
                .contains(where: { pasted.hasPrefix($0) })
            || looksLikeARandomRun(pasted) {
            throw AppError.usage(secretShapedNameMessage)
        }
    }

    /// The character-distribution half of the shape: names are words spread across
    /// the alphabet with digits rare; a pasted secret that carries no known prefix
    /// is a long run of hex (either case), of digits, or of mixed-case base62. 32
    /// sits past every honest name and at the short end of real secrets; a
    /// separator-free run that mixes upper case, lower case and digits is no name
    /// a person types, so it is caught from 24 (Mistral- and Cohere-style keys
    /// carry no prefix and only a sprinkling of digits).
    static func looksLikeARandomRun(_ name: String) -> Bool {
        let digits = name.filter(\.isASCIIDigit).count
        if name.count >= 24,
           !name.contains(where: { "-._ ".contains($0) }),
           name.contains(where: \.isASCIIUppercase),
           name.contains(where: \.isASCIILowercase),
           digits > 0 {
            return true
        }
        guard name.count >= 32 else { return false }
        if name.allSatisfy({ "0123456789abcdef-._".contains($0) }) { return true }
        if name.allSatisfy({ "0123456789ABCDEF-._".contains($0) }) { return true }
        return digits * 5 >= name.count * 2
    }

    /// The no-argument flow. Returns the stored name, or nil when the user cancelled.
    /// The write happens only after the hidden secret prompt confirmed.
    @discardableResult
    static func run(
        service: KeysService,
        isTTY: Bool,
        kind: String,
        notes: String,
        clipboard: Bool,
        ui: any GuidedAddInteracting = TerminalGuidedAddUI(),
        readSecret: (Bool, Bool) throws -> String = SecretPrompt.read,
        emit: (String) -> Void = { print($0) }
    ) throws -> String? {
        guard isTTY else { throw AppError.usage(nonTTYUsage) }
        let userHidden = (try? service.catalog.hiddenProviderIds()) ?? []
        let candidates = GuidedProviders.pickerEntries(userHidden: userHidden)
        guard !candidates.isEmpty else { throw AppError.usage("no providers to pick from") }
        guard let providerID = ui.pickProvider(candidates: candidates) else {
            emit("cancelled")
            return nil
        }
        let taken = Set(try service.list().map(\.name))
        let suggestion = suggestedName(provider: providerID, taken: taken)
        guard let answer = ui.promptName(suggestion: suggestion) else {
            emit("cancelled")
            return nil
        }
        let name = answer.isEmpty ? suggestion : answer
        // Refused here, not inside service.add: the store's own shape error would
        // echo the pasted value back, and the add would happen first (VAL-H-007).
        try Self.rejectSecretShapedName(name)
        let secret = try readSecret(clipboard, true)
        try service.add(name: name, provider: providerID, kind: kind, notes: notes, secret: secret, caller: "add")
        emit("added \(name)")
        return name
    }
}

/// The real-terminal half of the picker: raw-mode key decoding with prompts on stderr,
/// the terminal restored on every exit. It renders provider ids and names only — the
/// secret still enters through `SecretPrompt` after the picker returns.
final class TerminalGuidedAddUI: GuidedAddInteracting {
    private static let visibleCount = 9
    private var renderedLines = 0

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func pickProvider(candidates: [Providers.Record]) -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }

        var picker = ProviderPicker(candidates: candidates)
        redraw(picker)
        while true {
            guard let byte = readByte() else {
                clearFrame()
                return nil
            }
            switch byte {
            case 0x0D, 0x0A:
                if let chosen = picker.accept() {
                    let record = picker.matches.first { $0.id == chosen }
                    settle("Provider: \(record?.name ?? chosen) (\(chosen))")
                    return chosen
                }
            case 0x09:
                picker.handle(.tab)
                redraw(picker)
            case 0x7F, 0x08:
                picker.handle(.backspace)
                redraw(picker)
            case 0x03:
                // Ctrl-C with ISIG off: cancel like Esc, never leave the terminal raw.
                clearFrame()
                return nil
            case 0x1B:
                switch decodeEscape() {
                case .key(let key):
                    picker.handle(key)
                    redraw(picker)
                case .cancel:
                    clearFrame()
                    return nil
                case .ignore:
                    break
                }
            case 0x20...0x7E:
                picker.handle(.char(Character(Unicode.Scalar(byte))))
                redraw(picker)
            default:
                break
            }
        }
    }

    func promptName(suggestion: String) -> String? {
        // Back in canonical mode, so the edited name echoes like any readLine prompt.
        write("Name [\(suggestion)]: ")
        guard let line = readLine(strippingNewline: true) else { return nil }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Escape {
        case key(ProviderPicker.Key)
        case cancel
        case ignore
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }

    /// Arrows arrive as ESC [ A/B; a bare Esc cancels. A short poll tells the two apart.
    private func decodeEscape() -> Escape {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 25) > 0,
              readByte() == UInt8(ascii: "["),
              let final = readByte()
        else { return .cancel }
        switch final {
        case UInt8(ascii: "A"): return .key(.up)
        case UInt8(ascii: "B"): return .key(.down)
        default: return .ignore
        }
    }

    private func frame(_ picker: ProviderPicker) -> [String] {
        var lines = ["Provider: \(picker.query)"]
        if picker.matches.isEmpty {
            lines.append("  (no matches)")
            return lines
        }
        let selected = min(picker.selected, picker.matches.count - 1)
        let start = selected >= Self.visibleCount ? selected - Self.visibleCount + 1 : 0
        for (offset, record) in picker.matches[start...].prefix(Self.visibleCount).enumerated() {
            let cursor = start + offset == selected ? "❯" : " "
            lines.append("\(cursor) \(record.name) (\(record.id))")
        }
        return lines
    }

    private func redraw(_ picker: ProviderPicker) {
        clearFrame()
        let lines = frame(picker)
        write(lines.joined(separator: "\r\n") + "\r\n")
        renderedLines = lines.count
    }

    /// Clears the frame; the cursor sits on the first column of the line below it.
    private func clearFrame() {
        guard renderedLines > 0 else { return }
        write("\u{1B}[\(renderedLines)A\r\u{1B}[J")
        renderedLines = 0
    }

    private func settle(_ line: String) {
        clearFrame()
        write(line + "\r\n")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIUppercase: Bool { isASCII && isUppercase }
    var isASCIILowercase: Bool { isASCII && isLowercase }
}
