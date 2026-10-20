import Darwin
import Foundation

// `keys wrap <.env>`: swap provider keys in an env file for gateway client tokens.
// Wiring one key into an agent by hand took five steps (find the key, add it, turn the
// gateway on, issue a token, edit the file and add a base URL), and one missing trailing
// newline glued a token onto the next variable. The CLI half here parses and rewrites the
// file; the half that touches secrets runs in the process that owns the gateway
// (`KeysService.wrapPlan` / `wrapApply`), behind one presence prompt.

/// One value from the file that looks like a provider key. The value goes to the gateway
/// owner for comparison and never to a log or the terminal.
struct WrapCandidate: Sendable {
    var variable: String
    var value: String
    /// Provider guessed from the variable name, the key prefix or a base URL in the file.
    var provider: String?
    /// Short folder name the suggested key name may carry when the provider id is taken.
    var nameHint: String?
}

/// What wrap will do, names only. `skip` set means the variable is left as it is.
struct WrapPlan: Sendable {
    struct Item: Sendable, Equatable {
        var variable: String
        var key: String?
        var provider: String?
        var isNew: Bool
        var skip: String?
    }

    static let lifetime: TimeInterval = 300
    static let maxCandidates = 64

    var id: String
    var items: [Item]

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "expires_in_s": Int(Self.lifetime),
            "items": items.map { item -> [String: Any] in
                var o: [String: Any] = ["variable": item.variable, "new": item.isNew]
                if let k = item.key { o["key"] = k }
                if let p = item.provider { o["provider"] = p }
                if let s = item.skip { o["skip"] = s }
                return o
            },
        ]
    }

    init(id: String, items: [Item]) {
        self.id = id
        self.items = items
    }

    init(json obj: [String: Any]) throws {
        guard let id = JSONValue.string(obj["id"]), let raw = obj["items"] as? [Any] else {
            throw AppError.usage("the site returned no wrap plan")
        }
        self.id = id
        self.items = try raw.map { any in
            guard let o = JSONValue.object(any), let variable = JSONValue.string(o["variable"]) else {
                throw AppError.usage("the site returned a malformed wrap plan")
            }
            return Item(
                variable: variable, key: JSONValue.string(o["key"]), provider: JSONValue.string(o["provider"]),
                isNew: JSONValue.bool(o["new"]) ?? false, skip: JSONValue.string(o["skip"])
            )
        }
    }
}

struct WrapIssued: Sendable, Equatable {
    var key: String
    var token: String
    var clientID: Int64
    var isNew: Bool
}

enum WrapNames {
    /// The provider id, then `<provider>-<folder>`, then numbered; always a valid key name.
    static func suggest(provider: String, hint: String?, taken: Set<String>) -> String {
        let base = slug(provider).isEmpty ? "key" : slug(provider)
        if !taken.contains(base) { return base }
        if let hint, !slug(hint).isEmpty {
            let named = String((base + "-" + slug(hint)).prefix(100))
            if !taken.contains(named) { return named }
        }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    static func slug(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        while out.last == "-" { out.removeLast() }
        return String(out.prefix(60))
    }
}

// MARK: - The file

/// A dotenv file kept line for line. Only the value span of a rewritten assignment changes;
/// comments, blank lines, `export`, quotes, spacing and inline comments stay as written.
struct EnvFile: Equatable {
    struct Entry: Equatable {
        var name: String
        var value: String
        /// Everything before the value: indentation, `export `, name, `=`, spacing, opening quote.
        var head: String
        /// Everything after the value: closing quote, spacing, inline comment, a trailing CR.
        var tail: String
        var quote: Character?
        /// A quoted value spanning lines (a PEM block, say). Kept verbatim, never wrapped.
        var multiline: Bool

        var text: String { head + value + tail }
    }

    enum Line: Equatable {
        case raw(String)
        case entry(Entry)
    }

    var lines: [Line]
    var newline: String

    static func parse(_ text: String) -> EnvFile {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var physical = text.components(separatedBy: "\n")
        if physical.last == "" { physical.removeLast() }
        var lines: [Line] = []
        var i = 0
        while i < physical.count {
            let line = physical[i]
            guard var entry = parseAssignment(line) else {
                lines.append(.raw(line))
                i += 1
                continue
            }
            if entry.multiline {
                // Swallow lines up to the closing quote so a continuation that happens to read
                // NAME=value is not taken for an assignment.
                var joined = line
                var j = i + 1
                var closed = false
                while j < physical.count {
                    joined += "\n" + physical[j]
                    if let q = entry.quote, closes(physical[j], quote: q) {
                        closed = true
                        j += 1
                        break
                    }
                    j += 1
                }
                if closed {
                    entry = Entry(name: entry.name, value: "", head: joined, tail: "", quote: entry.quote, multiline: true)
                    lines.append(.entry(entry))
                } else {
                    // Never closed: keep everything as it was, unparsed.
                    for k in i..<j { lines.append(.raw(physical[k])) }
                }
                i = j
                continue
            }
            lines.append(.entry(entry))
            i += 1
        }
        return EnvFile(lines: lines, newline: newline)
    }

    /// The file's text, always ending in a newline: a missing one once glued a token onto
    /// the next variable appended by hand.
    func render() -> String {
        if lines.isEmpty { return "" }
        let body = lines.map { line -> String in
            switch line {
            case .raw(let s): return s
            case .entry(let e): return e.text
            }
        }
        // A CRLF file keeps its CR inside each line's tail, so joining with "\n" restores it.
        let joined = body.joined(separator: "\n")
        let cr = newline == "\r\n" && !joined.hasSuffix("\r") ? "\r" : ""
        return joined + cr + "\n"
    }

    var entries: [(index: Int, entry: Entry)] {
        lines.enumerated().compactMap { i, line in
            if case .entry(let e) = line { return (i, e) }
            return nil
        }
    }

    /// The value the last assignment of `name` gives, as dotenv loaders resolve duplicates.
    func value(of name: String) -> String? {
        entries.last { $0.entry.name == name && !$0.entry.multiline }?.entry.value
    }

    mutating func setValue(at index: Int, _ value: String) {
        guard case .entry(var e) = lines[index], !e.multiline else { return }
        e.value = value
        lines[index] = .entry(e)
    }

    /// Replaces every assignment of `name`, or appends one at the end.
    mutating func upsert(name: String, value: String) {
        let hits = entries.filter { $0.entry.name == name && !$0.entry.multiline }
        if hits.isEmpty {
            let cr = newline == "\r\n" ? "\r" : ""
            lines.append(.entry(Entry(name: name, value: value, head: "\(name)=", tail: cr, quote: nil, multiline: false)))
            return
        }
        for hit in hits { setValue(at: hit.index, value) }
    }

    private static func closes(_ line: String, quote: Character) -> Bool {
        var escaped = false
        for ch in line {
            if quote == "\"" && ch == "\\" && !escaped { escaped = true; continue }
            if ch == quote && !escaped { return true }
            escaped = false
        }
        return false
    }

    /// `[export ]NAME[ ]=[ ]value`, with the value bare, '…', "…" or `…`.
    static func parseAssignment(_ line: String) -> Entry? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i < chars.count, chars[i] == "#" { return nil }
        let exportWord = Array("export")
        if chars.count >= i + exportWord.count + 1, Array(chars[i..<(i + exportWord.count)]) == exportWord,
           chars[i + exportWord.count] == " " || chars[i + exportWord.count] == "\t"
        {
            var j = i + exportWord.count
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            i = j
        }
        let nameStart = i
        guard i < chars.count, chars[i] == "_" || (chars[i].isASCII && chars[i].isLetter) else { return nil }
        while i < chars.count, chars[i] == "_" || (chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber)) {
            i += 1
        }
        let name = String(chars[nameStart..<i])
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i < chars.count, chars[i] == "=" else { return nil }
        i += 1
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        // A CRLF file leaves a CR at the end of each line; it belongs to the tail.
        var end = chars.count
        var cr = ""
        if end > i, chars[end - 1] == "\r" { end -= 1; cr = "\r" }
        if i < end, let q = chars[i] as Character?, q == "\"" || q == "'" || q == "`" {
            let head = String(chars[0...i])
            var k = i + 1
            var escaped = false
            while k < end {
                if q == "\"" && chars[k] == "\\" && !escaped { escaped = true; k += 1; continue }
                if chars[k] == q && !escaped { break }
                escaped = false
                k += 1
            }
            if k >= end {
                return Entry(name: name, value: "", head: line, tail: "", quote: q, multiline: true)
            }
            return Entry(
                name: name, value: String(chars[(i + 1)..<k]), head: head,
                tail: String(chars[k..<end]) + cr, quote: q, multiline: false
            )
        }
        // Bare value: up to an inline comment (whitespace then #), trailing blanks to the tail.
        var k = i
        while k < end {
            if chars[k] == "#", k > i, chars[k - 1] == " " || chars[k - 1] == "\t" { break }
            k += 1
        }
        var valueEnd = k
        while valueEnd > i, chars[valueEnd - 1] == " " || chars[valueEnd - 1] == "\t" { valueEnd -= 1 }
        return Entry(
            name: name, value: String(chars[i..<valueEnd]), head: String(chars[0..<i]),
            tail: String(chars[valueEnd..<end]) + cr, quote: nil, multiline: false
        )
    }
}

// MARK: - Which values are keys

enum WrapDetect {
    /// Variable names whose provider is not simply the name minus `_API_KEY`.
    static let aliases: [String: String] = [
        "GEMINI": "google", "GOOGLE": "google", "GOOGLE_GENERATIVE_AI": "google", "GOOGLE_AI": "google",
        "GROK": "xai", "CO": "cohere", "KIMI": "moonshot", "PPLX": "perplexity", "HF": "huggingface",
        "HUGGINGFACE": "huggingface", "HUGGING_FACE": "huggingface", "HUGGINGFACEHUB_API": "huggingface",
        "AI_GATEWAY": "vercel-ai-gateway", "TOGETHERAI": "together", "TOGETHER_AI": "together",
        "GLM": "zhipu", "QWEN": "dashscope", "ELEVEN": "elevenlabs", "NVIDIA_NIM": "nvidia",
    ]

    static let nameSuffixes = ["_API_KEY", "_APIKEY", "_API_TOKEN", "_KEY", "_TOKEN"]

    /// Base-URL variable the SDK that reads a key variable also reads. Keyed by the key's
    /// variable, not its provider: OPENAI_API_KEY holding an OpenRouter key is still read by
    /// the OpenAI SDK, which takes its URL from OPENAI_BASE_URL.
    static let baseURLVariables: [String: String] = [
        "OPENAI_API_KEY": "OPENAI_BASE_URL",
        "ANTHROPIC_API_KEY": "ANTHROPIC_BASE_URL",
        "GROQ_API_KEY": "GROQ_BASE_URL",
    ]

    static func providerFromName(_ variable: String) -> String? {
        let upper = variable.uppercased()
        for suffix in nameSuffixes where upper.hasSuffix(suffix) && upper.count > suffix.count {
            let stem = String(upper.dropLast(suffix.count))
            if let id = aliases[stem], Providers.provider(id: id) != nil { return id }
            let id = stem.lowercased().replacingOccurrences(of: "_", with: "-")
            if Providers.provider(id: id) != nil { return id }
        }
        if upper == "HF_TOKEN" { return "huggingface" }
        return nil
    }

    /// The provider whose key prefix is the longest match, if exactly one provider has it.
    static func providerFromPrefix(_ value: String, records: [Providers.Record]) -> (id: String, length: Int)? {
        var best: (ids: Set<String>, length: Int) = ([], 0)
        for r in records {
            guard let p = r.keyPrefix, !p.isEmpty, value.hasPrefix(p) else { continue }
            if p.count > best.length { best = ([r.id], p.count) }
            else if p.count == best.length { best.ids.insert(r.id) }
        }
        guard best.ids.count == 1, let id = best.ids.first else { return nil }
        return (id, best.length)
    }

    static func providerFromURL(_ value: String, records: [Providers.Record]) -> String? {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return nil }
        return records.first { $0.host?.lowercased() == host }?.id
    }

    /// A secret-shaped value: one token of 16 to 512 printable characters, not a URL, not a
    /// shell reference and not already a Keysrs token.
    static func valueLooksLikeKey(_ value: String) -> Bool {
        guard (16...512).contains(value.count) else { return false }
        if value.hasPrefix(GatewayClientToken.prefix) || value.hasPrefix(GrantToken.prefix) { return false }
        if value.contains("://") || value.contains("$") || value.contains("\\") { return false }
        return value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    /// Candidates in file order, one per assignment line. Values without a provider guess
    /// still go, because an exact vault match needs none.
    static func candidates(in file: EnvFile, nameHint: String?) -> [(index: Int, candidate: WrapCandidate)] {
        let records = Providers.builtinList()
        var out: [(Int, WrapCandidate)] = []
        for (index, entry) in file.entries where !entry.multiline {
            let value = entry.value
            guard valueLooksLikeKey(value) else { continue }
            let byName = providerFromName(entry.name)
            let byPrefix = providerFromPrefix(value, records: records)
            let keyish = byName != nil || nameSuffixes.contains { entry.name.uppercased().hasSuffix($0) }
            // A long distinctive prefix (sk-ant-, gsk_, xai-) is evidence on its own; a short
            // one (sk-, sk_) only when the name already says key.
            guard keyish || (byPrefix?.length ?? 0) >= 4 else { continue }
            var provider = byName
            if let byPrefix {
                let nameLength = byName.flatMap { Providers.provider(id: $0)?.keyPrefix }
                    .map { value.hasPrefix($0) ? $0.count : 0 } ?? 0
                // STRIPE_SECRET_KEY=sk_live_… shares ElevenLabs' sk_; a short prefix alone
                // names no provider, so such a value can only match a key already in the vault.
                if byName == nil ? byPrefix.length >= 4 : byPrefix.length > nameLength { provider = byPrefix.id }
            }
            // OPENAI_API_KEY=sk-… beside OPENAI_BASE_URL=https://api.deepseek.com/v1 is a DeepSeek key.
            if let baseVar = baseURLVariables[entry.name], let url = file.value(of: baseVar),
               let byURL = providerFromURL(url, records: records),
               byPrefix == nil || byPrefix?.id == byURL
            {
                provider = byURL
            }
            out.append((index, WrapCandidate(variable: entry.name, value: value, provider: provider, nameHint: nameHint)))
        }
        return out
    }
}

// MARK: - Writing it back

enum EnvFileWriter {
    struct Result {
        var backup: URL
    }

    static func backupURL(for url: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".keysrs-backup-" + f.string(from: now))
    }

    /// Backs up `original` (0600, never overwriting), then swaps `text` in with one rename so a
    /// reader sees the old file or the new one, never half. The new file keeps the old mode.
    /// Refuses if the file changed since it was read.
    static func rewrite(_ url: URL, original: Data, text: String, now: Date = Date()) throws -> Result {
        let mode = try currentMode(url)
        var backup = backupURL(for: url, now: now)
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = URL(fileURLWithPath: backupURL(for: url, now: now).path + "-\(n)")
        }
        try writeNew(backup, data: original, mode: 0o600)
        guard let current = FileManager.default.contents(atPath: url.path), current == original else {
            throw AppError.usage("\(url.lastPathComponent) changed while keys wrap ran; nothing rewritten (backup kept at \(backup.path))")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).keysrs-\(Hex.encode(SecureRandom.bytes(6)))")
        do {
            try writeNew(temp, data: Data(text.utf8), mode: mode)
            guard Darwin.rename(temp.path, url.path) == 0 else {
                throw AppError.usage("could not replace \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return Result(backup: backup)
    }

    static func currentMode(_ url: URL) throws -> mode_t {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw AppError.usage("cannot read \(url.path): \(String(cString: strerror(errno)))")
        }
        return st.st_mode & 0o7777
    }

    /// O_EXCL so a file planted at the name is never followed or reused; fchmod after open
    /// because the umask trims the mode open() is given.
    private static func writeNew(_ url: URL, data: Data, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw AppError.usage("cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else {
            throw AppError.usage("cannot set permissions on \(url.path): \(String(cString: strerror(errno)))")
        }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AppError.usage("cannot write \(url.path): \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
        guard fsync(fd) == 0 else {
            throw AppError.usage("cannot sync \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - The command's steps

/// Where the plan and the tokens come from: the running app over its control API, or a
/// service in this process (tests).
protocol WrapBackend {
    func plan(file: String, candidates: [WrapCandidate]) throws -> WrapPlan
    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued]
    func cancel(id: String)
}

struct ServiceWrapBackend: WrapBackend {
    let service: KeysService
    func plan(file: String, candidates: [WrapCandidate]) throws -> WrapPlan {
        try service.wrapPlan(file: file, candidates: candidates)
    }
    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued] {
        try service.wrapApply(id: id, label: label, days: days, caller: "wrap")
    }
    func cancel(id: String) { service.wrapCancel(id: id) }
}

struct ControlWrapBackend: WrapBackend {
    /// Connects on first use, so a file with nothing to wrap needs no running app.
    let connect: () throws -> ControlClient

    func plan(file: String, candidates: [WrapCandidate]) throws -> WrapPlan {
        let body: [String: Any] = [
            "file": file,
            "candidates": candidates.map { c -> [String: Any] in
                var o: [String: Any] = ["variable": c.variable, "value": c.value]
                if let p = c.provider { o["provider"] = p }
                if let h = c.nameHint { o["name_hint"] = h }
                return o
            },
        ]
        return try WrapPlan(json: try Self.call { try connect().call(method: "POST", path: "/api/wrap", body: body, expect: 200) })
    }

    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued] {
        var body: [String: Any] = ["label": label]
        if let days { body["days"] = days }
        let obj = try Self.call { try connect().call(method: "POST", path: "/api/wrap/\(id)", body: body, expect: 201) }
        return ((obj["issued"] as? [Any]) ?? []).compactMap(JSONValue.object).compactMap { o in
            guard let key = JSONValue.string(o["key"]), let token = JSONValue.string(o["token"]) else { return nil }
            return WrapIssued(
                key: key, token: token, clientID: Int64(JSONValue.int(o["client_id"]) ?? 0), isNew: JSONValue.bool(o["new"]) ?? false
            )
        }
    }

    func cancel(id: String) {
        _ = try? connect().call(method: "DELETE", path: "/api/wrap/\(id)", expect: 200)
    }

    /// An app from before keys wrap answers 405 for the route; say what to do instead.
    private static func call(_ body: () throws -> [String: Any]) throws -> [String: Any] {
        do { return try body() } catch let error as AppError {
            if case .usage(let m) = error, m == "method_not_allowed" {
                throw AppError.usage("the running Keysrs.app predates keys wrap; update it (Check for Updates) and retry")
            }
            throw error
        }
    }
}

struct WrapRunner {
    struct Options {
        var file: URL
        var dryRun = false
        var yes = false
        /// Worker origin; base URLs then point at the relay instead of the loopback gateway.
        var relay: URL?
        var label = ""
        var days: Int?
        var port: UInt16 = GatewayListener.port
        var now = Date()
    }

    struct Summary: Equatable {
        var wrapped: [WrapPlan.Item] = []
        var baseURLs: [String: String] = [:]
        var backup: URL?
        var changed = false
    }

    var backend: any WrapBackend
    var out: (String) -> Void
    var confirm: () -> Bool

    func baseURL(key: String, options: Options) -> String {
        if let relay = options.relay { return RelayURL.baseURL(relay, key: key) }
        return "http://127.0.0.1:\(options.port)/\(key)"
    }

    func run(_ options: Options) throws -> Summary {
        let url = options.file.resolvingSymlinksInPath()
        let display = options.file.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AppError.notFound(options.file.path)
        }
        guard let original = FileManager.default.contents(atPath: url.path) else {
            throw AppError.usage("cannot read \(options.file.path)")
        }
        guard let text = String(data: original, encoding: .utf8) else {
            throw AppError.usage("\(display) is not UTF-8 text")
        }
        var file = EnvFile.parse(text)
        let hint = WrapNames.slug(url.deletingLastPathComponent().lastPathComponent)
        let found = WrapDetect.candidates(in: file, nameHint: hint.isEmpty ? nil : hint)
        if found.isEmpty {
            out("nothing to wrap in \(display): no value looks like a provider key")
            return Summary()
        }
        out("\(found.count) value\(found.count == 1 ? "" : "s") in \(display) look\(found.count == 1 ? "s" : "") like provider keys: "
            + found.map(\.candidate.variable).joined(separator: ", "))
        out("Touch ID in Keysrs to compare them with the vault…")
        let plan = try backend.plan(file: display, candidates: found.map(\.candidate))
        var applied = false
        defer { if !applied { backend.cancel(id: plan.id) } }
        guard plan.items.count == found.count else {
            throw AppError.usage("the site returned a plan for \(plan.items.count) of \(found.count) values; nothing changed")
        }

        let todo = plan.items.filter { $0.skip == nil && $0.key != nil }
        var baseURLs: [String: String] = [:]
        for item in todo {
            if let v = WrapDetect.baseURLVariables[item.variable], let key = item.key { baseURLs[v] = baseURL(key: key, options: options) }
        }
        out("plan for \(display):")
        for item in plan.items {
            if let skip = item.skip {
                out("  skip  \(item.variable)  (\(skip))")
            } else if let key = item.key {
                let provider = item.provider.flatMap { Providers.provider(id: $0)?.name } ?? item.provider ?? "?"
                out("  wrap  \(item.variable) -> \(key)  (\(item.isNew ? "new vault key" : "existing"), \(provider))")
            }
        }
        for (v, u) in baseURLs.sorted(by: { $0.key < $1.key }) {
            out("  set   \(v)=\(u)\(file.value(of: v) == nil ? "" : "  (replaces the current value)")")
        }
        if todo.isEmpty {
            out("nothing to wrap; \(display) is unchanged")
            return Summary()
        }
        out("each wrapped key gets a client token (POST and GET, \(options.days ?? GatewayClientToken.defaultDays) days) and the gateway turned on")
        if options.dryRun {
            out("dry run: no key added, no token issued, \(display) unchanged")
            return Summary(wrapped: todo, baseURLs: baseURLs)
        }
        if !options.yes, !confirm() {
            out("cancelled; \(display) is unchanged")
            return Summary()
        }

        applied = true
        let issued = try backend.apply(id: plan.id, label: options.label, days: options.days)
        let tokens = Dictionary(issued.map { ($0.key, $0.token) }, uniquingKeysWith: { a, _ in a })
        var wrapped: [WrapPlan.Item] = []
        // The plan has one item per candidate, in order, so a name assigned twice with two
        // different values still gets the right token on each line.
        for ((index, _), item) in zip(found, plan.items) {
            guard item.skip == nil, let key = item.key, let token = tokens[key] else { continue }
            file.setValue(at: index, token)
            if !wrapped.contains(item) { wrapped.append(item) }
        }
        let missing = todo.filter { tokens[$0.key ?? ""] == nil }.map(\.variable)
        if !missing.isEmpty {
            out("no token came back for \(missing.joined(separator: ", ")); those lines are unchanged")
        }
        for (v, u) in baseURLs where wrapped.contains(where: { WrapDetect.baseURLVariables[$0.variable] == v }) {
            file.upsert(name: v, value: u)
        }
        let result = try EnvFileWriter.rewrite(url, original: original, text: file.render(), now: options.now)
        out("wrapped \(wrapped.count) variable\(wrapped.count == 1 ? "" : "s") in \(display):")
        for item in wrapped {
            let client = issued.first { $0.key == item.key }.map { " client #\($0.clientID)" } ?? ""
            out("  \(item.variable) -> \(item.key ?? "")\(item.isNew ? " (added to the vault)" : "")\(client)")
        }
        for (v, _) in baseURLs.sorted(by: { $0.key < $1.key }) { out("  \(v) -> \(options.relay == nil ? "gateway" : "relay")") }
        out("backup with the original values: \(result.backup.path) (0600); delete it once the agent works")
        out("the gateway forgets keys when Keysrs quits; after a relaunch run keys gateway on <key> for each")
        return Summary(wrapped: wrapped, baseURLs: baseURLs, backup: result.backup, changed: true)
    }
}
