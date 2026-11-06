import CryptoKit
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
        /// Where the gateway will send this key. Shown in the plan because the user's yes to it
        /// stands in for the per-key prompt that names the host, and apply refuses if it moved.
        var host: String? = nil
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
                if let h = item.host { o["host"] = h }
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
                isNew: JSONValue.bool(o["new"]) ?? false, skip: JSONValue.string(o["skip"]),
                host: JSONValue.string(o["host"])
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

    /// One file's rewrite, prepared but not committed: the backup of the pre-image's
    /// companion lines is on disk, the new bytes are in a temp beside the target (same
    /// directory, the file's own mode, one `rename` away) and the target itself has not
    /// moved. The split exists so a batch of files can be made all-or-nothing: every
    /// file is prepared first, and only a batch whose every temp exists commits.
    /// `discard` removes the temps and the backups, `commit` renames the temps home,
    /// `restore` puts an already-renamed file back.
    struct Prepared {
        var url: URL
        var backup: URL
        var temp: URL
        /// The bytes the target held when this was prepared: `commit` proves they are
        /// still there before the rename, so the refuse-if-changed guarantee covers the
        /// whole window (for `keys wrap`, all the way across the plan's apply), and
        /// `restore` puts exactly these back — from memory, because the backup on disk
        /// keeps only the companion lines.
        var original: Data
        /// The new bytes this call put in the temp: `restore` proves the file still
        /// holds exactly these before it overwrites them, so a user edit made in the
        /// rollback window is never discarded.
        var text: Data
        var mode: mode_t
        /// Last path component, for the messages (never the path).
        var name: String { url.lastPathComponent }
    }

    /// Test-only seams, nil in production: a closure that fires after every temp of a
    /// batch exists and before the first rename (phase A is complete, nothing moved),
    /// and one that fires before each rename by index (to fail phase B mid-batch).
    /// Nothing in the production path reads them.
    struct TestHooks: @unchecked Sendable {
        var beforeCommit: (() throws -> Void)?
        var beforeRename: ((Int) throws -> Void)?
    }
    nonisolated(unsafe) static var testHooks: TestHooks?

    /// Why a prepared batch did not land, and exactly what it left behind. `reason`
    /// names the file by its last component and the system error, never a path: the
    /// sentence it ends up in is a tool result or a Terminal line.
    struct BatchFailure: Error {
        /// Whether anything on disk moved: `.prepared` means no file changed,
        /// `.committed` means some renames may have happened and were undone.
        enum Phase { case prepared, committed }
        var phase: Phase
        var reason: String
        /// Files put back from the backups this batch took, by name.
        var restored: [String] = []
        /// Files that could NOT be put back; they still hold the new bytes.
        var stuck: [String] = []
    }

    /// Where wrap-time backups live: beside the CATALOG, like control.json and
    /// relay.lock — never inside the project (VAL-O-002), where one `git add -A`
    /// commits it, `git clean` eats it, and an agent can plant one. A backup keeps
    /// only the base URL companion lines (`backupContent`); key values come back
    /// from the vault. Derived from the catalog location each call, never a bare
    /// `Paths.appSupport`, so `KEYS_CATALOG` keeps every writer and reader on the
    /// same tree.
    static func backupsRoot(beside catalog: URL) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    /// The root for a caller with no catalog in hand: this process's own catalog
    /// location (`keys wrap` in a Terminal; the app's catalog IS the default),
    /// resolved at CALL time through the tripwire-checked resolver — a test that
    /// forgets to inject a `backupRoot` fails closed instead of writing into
    /// the real Application Support (VAL-H-001). Injectable through the
    /// `rewrite` parameter so tests point at their temp catalog and never at the
    /// real Application Support.
    static func defaultBackupsRoot() throws -> URL {
        backupsRoot(beside: try Paths.resolvingCatalog())
    }

    /// What a wrap-time backup keeps of the original file: only the assignments of
    /// the base URL companion variables a wrap rewrites — the one thing unwrap reads
    /// from it. Unwrap restores key values from the vault, so a byte copy of the file
    /// would only park live keys at a predictable path beside the catalog, readable
    /// by any process running as the user (the agent the wrap moves keys away from
    /// included) with no Touch ID, until something deleted it — and nothing did.
    /// Comments, other variables and multi-line values are dropped; bytes that are
    /// not UTF-8 keep nothing.
    static func backupContent(of original: Data) -> Data {
        guard let text = String(data: original, encoding: .utf8) else { return Data() }
        let parsed = EnvFile.parse(text)
        let companions = Set(WrapDetect.baseURLVariables.values)
        let kept = parsed.lines.filter {
            guard case let .entry(entry) = $0 else { return false }
            return !entry.multiline && companions.contains(entry.name)
        }
        return Data(EnvFile(lines: kept, newline: parsed.newline).render().utf8)
    }

    /// Creates the file's hashed backup folder (0700) and marks the backups root
    /// excluded from Time Machine, every time: a root made by an older build has no
    /// mark yet, and the backups have no reason to be on a backup disk.
    private static func makeBackupDirectory(_ dir: URL, root: URL) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = root
        // Best effort: the backups hold no key value, so a volume that refuses the
        // mark is not worth refusing the wrap over.
        try? marked.setResourceValues(values)
    }

    /// Cuts every backup under `root` down to its companion lines (`backupContent`).
    /// Backups written by 0.14 and 0.15 are byte copies of the original file, so rm
    /// and rotate call this: the value they remove or replace must not stay on disk
    /// beside the catalog. Idempotent; a backup already in the new form is left
    /// alone, and symlinks and anything not named like a backup are never touched.
    /// Each cut goes through a temp and one rename, so a crash leaves the old file
    /// or the new one. Throws when a backup that still needs cutting cannot be cut,
    /// so the caller never reports a clean tree that is not.
    static func scrubBackups(under root: URL) throws {
        let fm = FileManager.default
        guard isRegular(root, directory: true) else { return }
        let unreadable = { (name: String) in AppError.usage("cannot read the wrap-time backup \(name)") }
        guard let folders = try? fm.contentsOfDirectory(atPath: root.path) else { throw unreadable("folder") }
        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard isRegular(dir, directory: true) else { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { throw unreadable("folder") }
            for name in names where isBackupName(name) {
                let file = dir.appendingPathComponent(name)
                guard isRegular(file, directory: false) else { continue }
                guard let data = fm.contents(atPath: file.path) else { throw unreadable(name) }
                let cut = backupContent(of: data)
                guard cut != data else { continue }
                let temp = dir.appendingPathComponent(".\(name).keysrs-\(Hex.encode(SecureRandom.bytes(6)))")
                do {
                    try writeNew(temp, data: cut, mode: 0o600)
                    guard Darwin.rename(temp.path, file.path) == 0 else {
                        throw AppError.usage("could not replace \(name): \(String(cString: strerror(errno)))")
                    }
                } catch {
                    try? fm.removeItem(at: temp)
                    throw AppError.usage("cannot clean the wrap-time backup \(name): \(Self.systemReason(error))")
                }
            }
        }
    }

    /// Removes the App Support backups of one file — its own names in its hashed
    /// folder, never a sibling file's — and the folder once it is empty. Unwrap calls
    /// it after every line came back: nothing reads them after that.
    /// Answers false when one could not be removed, so the caller does not report
    /// it gone. A scrub temp a crash left behind (`.<backup>.keysrs-<hex>`) goes too.
    @discardableResult
    static func removeBackups(of url: URL, under root: URL) -> Bool {
        guard let dir = backupDirectory(for: url, under: root) else { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return !FileManager.default.fileExists(atPath: dir.path)
        }
        let prefix = url.lastPathComponent + ".keysrs-backup-"
        var clean = true
        for name in names where name.hasPrefix(prefix) || name.hasPrefix("." + prefix) {
            do { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) } catch { clean = false }
        }
        // rmdir refuses a folder that still holds a sibling's backup.
        _ = Darwin.rmdir(dir.path)
        return clean
    }

    /// A backup's own name ends in its timestamp (`.keysrs-backup-<ts>`, maybe `-n`);
    /// a scratch temp of one ends in `.keysrs-<hex>` after it.
    private static func isBackupName(_ name: String) -> Bool {
        guard let mark = name.range(of: ".keysrs-backup-", options: .backwards) else { return false }
        return !name[mark.upperBound...].contains(".")
    }

    /// lstat's answer: a real directory or regular file, never a symlink to one.
    private static func isRegular(_ url: URL, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
    }

    /// The per-file folder inside the backups root, keyed by the SHA-256 of the
    /// file's canonical (POSIX realpath) PARENT directory — the one key both sides
    /// can compute with nothing but the file in hand: `keys wrap` has no catalog,
    /// and unwrap reads the recorded canonical path. Two files with the same name
    /// can never share a folder, because the same name in the same parent is one
    /// file.
    static func backupDirectory(for url: URL, under root: URL) -> URL? {
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        let key = Hex.encode(SHA256.hash(data: Data(String(cString: parent).utf8)))
        return root.appendingPathComponent(key, isDirectory: true)
    }

    /// The backup's file name inside its folder: the wrapped file's own name plus
    /// the `.keysrs-backup-<ts>` suffix. The timestamp sorts lexically and the
    /// `-2`/`-3` collision suffixes sort after their base, so the lexical maximum
    /// is the most recent wrap — the property unwrap's restore relies on.
    static func backupName(of url: URL, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return url.lastPathComponent + ".keysrs-backup-" + f.string(from: now)
    }

    /// Backs up `original`'s companion lines (0600, never overwriting) under the
    /// catalog-sibling backups tree — never beside the file — then swaps `text` in with
    /// one rename so a reader sees the old file or the new one, never half. The new
    /// file keeps the old mode. Refuses if the file changed since it was read, naming
    /// no absolute path: the refusal is user-facing (a tool result, a Terminal line).
    /// This is the ONE-file case of the batch `commit`; the batch paths (the import and
    /// `keys wrap`) prepare every file first and rename them together.
    static func rewrite(
        _ url: URL, original: Data, text: String, now: Date = Date(),
        backupRoot: URL? = nil
    ) throws -> Result {
        // The default root resolves first, inside the body (a Swift default
        // argument cannot throw), so the tripwire's refusal comes before any
        // read or write — a forgotten injection fails closed with nothing done.
        let backupRoot = try backupRoot ?? EnvFileWriter.defaultBackupsRoot()
        let prepared = try prepare(url, original: original, text: text, now: now, backupRoot: backupRoot)
        do {
            try commit(prepared)
        } catch {
            // A rename that got through and then failed further up must not leave the
            // new bytes behind: put the original back, then drop the scratch files.
            // When the original cannot go back, the backup stays: it holds the
            // companion lines unwrap needs to undo the file by hand.
            do {
                try restore(prepared)
                discard([prepared])
            } catch {
                try? FileManager.default.removeItem(at: prepared.temp)
            }
            throw error
        }
        return Result(backup: prepared.backup)
    }

    /// Phase A for one file: the refuse-if-changed check, the pre-wrap backup of the
    /// companion lines (outside the project) and the new bytes in a temp beside the
    /// target — the target itself untouched. The check runs FIRST, before a backup or a
    /// temp exists: an edited file must leave no trace at all, and a backup taken just
    /// before a refusal used to linger as a pre-image nobody asked for. A failure after
    /// that removes whatever this call created.
    static func prepare(
        _ url: URL, original: Data, text: String, now: Date = Date(), backupRoot: URL
    ) throws -> Prepared {
        let mode = try currentMode(url)
        guard let current = FileManager.default.contents(atPath: url.path), current == original else {
            throw AppError.usage("\(url.lastPathComponent) changed while keys wrap ran; nothing was rewritten")
        }
        guard let dir = backupDirectory(for: url, under: backupRoot) else {
            throw AppError.usage("cannot decide where to keep the backup for \(url.lastPathComponent); nothing was rewritten")
        }
        do {
            try makeBackupDirectory(dir, root: backupRoot)
        } catch {
            throw AppError.usage("cannot create the backup folder for \(url.lastPathComponent); nothing was rewritten")
        }
        var backup = dir.appendingPathComponent(backupName(of: url, now: now))
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = dir.appendingPathComponent(backupName(of: url, now: now) + "-\(n)")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).keysrs-\(Hex.encode(SecureRandom.bytes(6)))")
        do {
            try writeNew(temp, data: Data(text.utf8), mode: mode)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AppError.usage("cannot write \(url.lastPathComponent): \(Self.systemReason(error))")
        }
        do {
            try writeNew(backup, data: backupContent(of: original), mode: 0o600)
        } catch {
            // writeNew may have created the backup before the write failed: a
            // truncated pre-image would later read as the newest wrap.
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: temp)
            throw AppError.usage("cannot back up \(url.lastPathComponent): \(Self.systemReason(error))")
        }
        return Prepared(url: url, backup: backup, temp: temp, original: original, text: Data(text.utf8), mode: mode)
    }

    /// A write failure's reason without the temp's invented name: the caller's message
    /// names the real file and the system error, never a scratch path.
    private static func systemReason(_ error: Error) -> String {
        guard case let AppError.usage(message) = error, let colon = message.firstIndex(of: ":") else {
            return (error as? AppError)?.description ?? error.localizedDescription
        }
        return String(message[message.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// The refuse-if-changed check and the backup location, with nothing written:
    /// what `keys wrap` runs before the plan is applied, so an edited file costs no
    /// key or token. The temp and the backup are only made after the apply, by
    /// `rewrite` — a temp made now would hold the raw secrets inside the project for
    /// the whole apply round trip, and outlive a crash there.
    static func precheck(_ url: URL, original: Data, backupRoot: URL) throws {
        _ = try currentMode(url)
        guard let current = FileManager.default.contents(atPath: url.path), current == original else {
            throw AppError.usage("\(url.lastPathComponent) changed while keys wrap ran; nothing was rewritten")
        }
        guard let dir = backupDirectory(for: url, under: backupRoot) else {
            throw AppError.usage("cannot decide where to keep the backup for \(url.lastPathComponent); nothing was rewritten")
        }
        // The folder holds no secret yet; making it now is what proves the backup
        // can be taken before any key or token exists.
        do {
            try makeBackupDirectory(dir, root: backupRoot)
        } catch {
            throw AppError.usage("cannot create the backup folder for \(url.lastPathComponent); nothing was rewritten")
        }
    }

    /// Phase B for one file: prove the target still holds the bytes this was prepared
    /// from, then one rename over it. A reader sees the old bytes or the new ones,
    /// never half, and the mode the temp was created with carries. The byte check is
    /// the refuse-if-changed guarantee for the gap between `prepare` and here — for
    /// `keys wrap` that gap spans the whole plan apply, so an edit under the prompt
    /// refuses instead of being overwritten.
    static func commit(_ prepared: Prepared) throws {
        guard let current = FileManager.default.contents(atPath: prepared.url.path),
              current == prepared.original else {
            throw AppError.usage("\(prepared.name) changed while the wrap ran; nothing was rewritten")
        }
        guard Darwin.rename(prepared.temp.path, prepared.url.path) == 0 else {
            throw AppError.usage("could not replace \(prepared.name): \(String(cString: strerror(errno)))")
        }
    }

    /// Undoes a batch that will not commit: the temps go, and so do the backups this
    /// batch itself took — they hold a pre-image of files that never changed, so a
    /// later unwrap has no reason to find them. Best effort: a leftover is not worth
    /// failing over, and the message the caller shows already says nothing changed.
    static func discard(_ prepared: [Prepared]) {
        for one in prepared {
            try? FileManager.default.removeItem(at: one.temp)
            try? FileManager.default.removeItem(at: one.backup)
        }
    }

    /// Puts one already-committed file back from the backup this batch took, through
    /// the same temp-and-rename so a reader never sees half a file. It refuses when the
    /// file no longer holds the bytes this batch wrote — someone edited it in the
    /// rollback window, and their edit wins over the rollback, which then reports that
    /// file as stuck instead of quietly discarding their work.
    static func restore(_ prepared: Prepared) throws {
        guard let committed = FileManager.default.contents(atPath: prepared.url.path),
              committed == prepared.text else {
            // Nothing to undo is not a failure: an earlier rollback step (or the caller's
            // own cleanup) may already have put the original back.
            if let current = FileManager.default.contents(atPath: prepared.url.path),
               current == prepared.original {
                return
            }
            throw AppError.usage("\(prepared.name) changed again after the wrap wrote it")
        }
        let temp = prepared.url.deletingLastPathComponent()
            .appendingPathComponent(".\(prepared.name).keysrs-\(Hex.encode(SecureRandom.bytes(6)))")
        do {
            try writeNew(temp, data: prepared.original, mode: prepared.mode)
            guard Darwin.rename(temp.path, prepared.url.path) == 0 else {
                throw AppError.usage("could not restore \(prepared.name): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Runs a whole batch as one transaction over the files: prepare every file (in
    /// the order given), then — only when every temp exists — commit them in that
    /// same order. A failure while preparing deletes every temp and backup and throws
    /// `BatchFailure(.prepared)`: no file moved, so the caller only has to undo what
    /// IT did before the files (the vault keys, the token). A failure mid-commit
    /// puts the files already renamed back from the originals held in memory, deletes
    /// the remaining temps, then throws `BatchFailure(.committed)` naming what went back
    /// and what could not. `afterCommit` runs once, between the last rename and the
    /// caller's own bookkeeping; a throw there rolls the files back the same way.
    @discardableResult
    static func commitBatch(
        _ files: [(url: URL, original: Data, text: String)],
        now: Date = Date(),
        backupRoot: URL,
        verify: ((URL) throws -> Void)? = nil,
        afterCommit: (() throws -> Void)? = nil
    ) throws -> [Result] {
        var prepared: [Prepared] = []
        do {
            for file in files {
                // The caller's containment re-check runs right before each file's
                // temp is written and again before its rename: a batch is longer
                // than one write, and a parent directory swapped for a symlink in
                // between must not carry the write outside the project.
                try verify?(file.url)
                prepared.append(try prepare(
                    file.url, original: file.original, text: file.text, now: now, backupRoot: backupRoot
                ))
            }
            try testHooks?.beforeCommit?()
        } catch {
            discard(prepared)
            throw BatchFailure(phase: .prepared, reason: Self.reason(error))
        }

        var committed = 0
        do {
            for (index, one) in prepared.enumerated() {
                try testHooks?.beforeRename?(index)
                try verify?(one.url)
                try commit(one)
                committed += 1
            }
            try afterCommit?()
        } catch {
            // Undo in reverse: the last file renamed is the one most likely to still
            // match its backup, and the order keeps the report readable.
            var restored: [String] = []
            var stuck: [String] = []
            for one in prepared.prefix(committed).reversed() {
                do {
                    try restore(one)
                    restored.append(one.name)
                    // Back to its original bytes: the pre-image would only make a
                    // later unwrap think this file was wrapped.
                    try? FileManager.default.removeItem(at: one.backup)
                } catch {
                    // Still holds the new bytes. The values it held are in the vault
                    // (the caller keeps them) and its companions in the backup, so
                    // keys unwrap is the way back.
                    stuck.append(one.name)
                }
            }
            discard(Array(prepared.dropFirst(committed)))
            throw BatchFailure(phase: .committed, reason: Self.reason(error), restored: restored, stuck: stuck)
        }
        return prepared.map { Result(backup: $0.backup) }
    }

    /// A failure's sentence without its path: `AppError`'s own text already names
    /// files by last component, and anything else (a POSIX error, a thrown sentinel)
    /// is passed through as its description.
    private static func reason(_ error: Error) -> String {
        (error as? AppError)?.description ?? error.localizedDescription
    }

    /// Unwrap's half of the swap: the same refuse-if-changed, one-rename replace as
    /// `rewrite`, minus the backup. The wrap-time backup (outside the project since
    /// VAL-O-002) is the restore's source for companion lines and unwrap removes it
    /// once every line came back; a fresh one would archive the token unwrap exists
    /// to revoke — a dead capability parked on disk for no reason.
    static func swap(_ url: URL, original: Data, text: String) throws {
        let mode = try currentMode(url)
        guard let current = FileManager.default.contents(atPath: url.path), current == original else {
            throw AppError.usage("\(url.lastPathComponent) changed while keys unwrap ran; nothing rewritten")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).keysrs-\(Hex.encode(SecureRandom.bytes(6)))")
        do {
            try writeNew(temp, data: Data(text.utf8), mode: mode)
            guard Darwin.rename(temp.path, url.path) == 0 else {
                throw AppError.usage("could not replace \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// The messages below name the file's last component, never its path: they are
    /// user- and agent-facing (a tool result, a Terminal line), and a bare file name
    /// identifies the file without telling a reader of the error where on disk to
    /// look (VAL-O-007).
    static func currentMode(_ url: URL) throws -> mode_t {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw AppError.usage("cannot read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return st.st_mode & 0o7777
    }

    /// O_EXCL so a file planted at the name is never followed or reused; fchmod after open
    /// because the umask trims the mode open() is given.
    private static func writeNew(_ url: URL, data: Data, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw AppError.usage("cannot create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else {
            throw AppError.usage("cannot set permissions on \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        try writeAll(fd, data, name: url.lastPathComponent)
        guard fsync(fd) == 0 else {
            throw AppError.usage("cannot sync \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// The whole buffer, retrying a short or interrupted write. The name is the last
    /// path component only: every message here can reach a terminal or a tool result.
    private static func writeAll(_ fd: Int32, _ data: Data, name: String) throws {
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AppError.usage("cannot write \(name): \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }
}

// MARK: - The command's steps

/// Where the plan and the tokens come from: the running app over its control API, or a
/// service in this process (tests). `path` in `plan` is the file's absolute path, kept
/// for the apply point's `wrapped_files` record — `file` stays the display name prompts
/// and labels show.
///
/// `compensate` is the take-back for a file swap that could not land: the swap is the
/// LAST step of `keys wrap`, so a failure there has to revoke the tokens the apply
/// point just minted instead of leaving a live capability behind a file that still
/// holds the raw secrets.
protocol WrapBackend {
    func plan(file: String, path: String?, candidates: [WrapCandidate]) throws -> WrapPlan
    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued]
    func cancel(id: String)
    /// True when every issued token was revoked; the message must not claim a
    /// revocation that did not happen.
    func compensate(_ issued: [WrapIssued], path: String) -> Bool
}

struct ServiceWrapBackend: WrapBackend {
    let service: KeysService
    func plan(file: String, path: String?, candidates: [WrapCandidate]) throws -> WrapPlan {
        try service.wrapPlan(file: file, candidates: candidates, path: path)
    }
    func apply(id: String, label: String, days: Int?) throws -> [WrapIssued] {
        try service.wrapApply(id: id, label: label, days: days, caller: "wrap")
    }
    func cancel(id: String) { service.wrapCancel(id: id) }
    func compensate(_ issued: [WrapIssued], path: String) -> Bool {
        var all = true
        for one in issued {
            do { try service.revokeGatewayClient(name: one.key, id: one.clientID, caller: "wrap") }
            catch { all = false }
        }
        return all
    }
}

struct ControlWrapBackend: WrapBackend {
    /// Connects on first use, so a file with nothing to wrap needs no running app.
    let connect: () throws -> ControlClient

    func plan(file: String, path: String?, candidates: [WrapCandidate]) throws -> WrapPlan {
        var body: [String: Any] = [
            "file": file,
            "candidates": candidates.map { c -> [String: Any] in
                var o: [String: Any] = ["variable": c.variable, "value": c.value]
                if let p = c.provider { o["provider"] = p }
                if let h = c.nameHint { o["name_hint"] = h }
                return o
            },
        ]
        // The control channel is the wrap flow's own wire (it carries the values), so
        // the file's absolute path rides it to the apply point's wrapped_files record.
        if let path { body["path"] = path }
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

    /// Compensates a failed file swap: each minted token is revoked through the same
    /// per-client route the dashboard uses. Best effort, like every rollback — the
    /// swap's own refusal is the error the caller sees. The file's `wrapped_files`
    /// record stays, as it does in-process (see `WrapBackend`).
    func compensate(_ issued: [WrapIssued], path: String) -> Bool {
        var all = true
        for one in issued where one.clientID > 0 {
            do {
                _ = try connect().call(
                    method: "DELETE", path: "/api/keys/\(one.key)/clients/\(one.clientID)", expect: 200
                )
            } catch { all = false }
        }
        return all
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
        /// Where the rewrite keeps the pre-wrap backup: the catalog-sibling backups
        /// tree by default (VAL-O-002), injectable so tests point at their temp
        /// catalog and never at the real Application Support.
        var backupRoot: URL? = nil
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
        let plan = try backend.plan(file: display, path: url.path, candidates: found.map(\.candidate))
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
                out("  wrap  \(item.variable) -> \(key)  (\(item.isNew ? "new vault key" : "existing"), \(provider) at \(item.host ?? "?"))")
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

        // The refuse-if-changed check before the plan is applied, with nothing written:
        // it is the only part of the file phase that fails for an ordinary reason (the
        // file was edited under the prompt), so checking here means keys, tokens and
        // the wrapped_files record are never committed for a file that cannot be
        // written. The rewrite itself re-checks right before its rename.
        let backupRoot = try options.backupRoot ?? EnvFileWriter.defaultBackupsRoot()
        do {
            try EnvFileWriter.precheck(url, original: original, backupRoot: backupRoot)
        } catch {
            out("\(display) is unchanged; no key was added and no token was issued")
            throw error
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

        // The tokens exist now, so the file is rewritten with them: backup, temp and
        // one rename. A failure here must not leave live tokens behind a file that
        // never changed: revoke what was just issued and say exactly what state
        // remains (the keys and the gateway toggles stay in the vault, so a retry
        // reuses them).
        let result: EnvFileWriter.Result
        do {
            result = try EnvFileWriter.rewrite(
                url, original: original, text: file.render(), now: options.now, backupRoot: backupRoot
            )
        } catch {
            let revoked = backend.compensate(issued, path: url.path)
            let reason = (error as? AppError)?.description ?? error.localizedDescription
            let one = issued.count == 1
            let tokens = issued.isEmpty
                ? "no token was issued"
                : revoked
                    ? "the \(one ? "token" : "tokens") just issued \(one ? "was" : "were") revoked"
                    : "the \(one ? "token" : "tokens") just issued could not all be revoked; "
                        + "revoke \(one ? "it" : "them") in the Keysrs dashboard (Keys, clients)"
            let added = issued.filter(\.isNew).count
            let keys = added == 0 ? ""
                : "; \(added) new key\(added == 1 ? " was" : "s were") added to the vault and "
                    + "\(added == 1 ? "stays" : "stay"), so a retry reuses \(added == 1 ? "it" : "them")"
            throw AppError.usage("\(reason); \(display) was not changed and \(tokens)\(keys)")
        }
        out("wrapped \(wrapped.count) variable\(wrapped.count == 1 ? "" : "s") in \(display):")
        for item in wrapped {
            let client = issued.first { $0.key == item.key }.map { " client #\($0.clientID)" } ?? ""
            out("  \(item.variable) -> \(item.key ?? "")\(item.isNew ? " (added to the vault)" : "")\(client)")
        }
        for (v, _) in baseURLs.sorted(by: { $0.key < $1.key }) { out("  \(v) -> \(options.relay == nil ? "gateway" : "relay")") }
        out("the original values stay in the vault and keys unwrap restores them; base URL lines are backed up outside the project (0600)")
        out("the gateway forgets keys when Keysrs quits; after a relaunch run keys gateway on <key> for each")
        return Summary(wrapped: wrapped, baseURLs: baseURLs, backup: result.backup, changed: true)
    }
}
