import CryptoKit
import Darwin
import Foundation
import Security

enum AppError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case authFailed
    case authCancelled
    case authUnavailable(String)
    case ingestIO(String)
    case alreadyExists(String)
    case gatewayOwned(pid_t)
    case keychain(String)
    case refusedBind(String)
    case sqlite(String)
    case http(String)

    var exitCode: Int32 {
        switch self {
        case .usage, .alreadyExists, .gatewayOwned, .refusedBind, .http:
            return 1
        case .notFound:
            return 2
        case .authFailed, .authCancelled, .authUnavailable, .keychain:
            return 3
        case .ingestIO, .sqlite:
            return 4
        }
    }

    /// HTTP status and `error` code on the local API. The codes are what the dashboard's
    /// friendly() and the control client match on, so they must not change.
    var wire: (status: Int, code: String) {
        switch self {
        case .usage(let m): return (400, m)
        case .notFound: return (404, "not_found")
        case .alreadyExists: return (409, "already_exists")
        case .gatewayOwned: return (409, "gateway owned by another process")
        case .authFailed: return (403, "auth_failed")
        case .authCancelled: return (403, "auth_cancelled")
        case .authUnavailable: return (503, "auth_unavailable")
        case .keychain: return (500, "keychain")
        default: return (400, description)
        }
    }

    /// The bare value inside the error, without the description's prefix.
    var detail: String {
        switch self {
        case .usage(let m), .notFound(let m), .alreadyExists(let m), .authUnavailable(let m), .keychain(let m),
             .ingestIO(let m), .sqlite(let m), .http(let m), .refusedBind(let m):
            return m
        case .gatewayOwned(let pid): return String(pid)
        case .authFailed, .authCancelled: return description
        }
    }

    /// Rebuilds the error an API response carries, so the CLI reports it as if raised locally.
    init(wireCode code: String, status: Int, body: [String: Any]) {
        let detail = JSONValue.string(body["detail"]) ?? JSONValue.string(body["message"]) ?? code
        switch code {
        case "auth_failed": self = .authFailed
        case "auth_cancelled": self = .authCancelled
        case "auth_unavailable": self = .authUnavailable(detail)
        case "not_found": self = .notFound(detail)
        case "already_exists": self = .alreadyExists(detail)
        case "keychain": self = .keychain(detail)
        case "gateway owned by another process":
            self = .gatewayOwned(pid_t(JSONValue.int(body["gateway_owner_pid"]) ?? 0))
        default:
            // A 403 without an AppError behind it is the site refusing a stale launch token.
            self = .usage(status == 403
                ? "site refused the request (\(JSONValue.string(body["message"]) ?? code)); restart the site and retry"
                : detail)
        }
    }

    var description: String {
        switch self {
        case .usage(let m), .ingestIO(let m), .keychain(let m), .sqlite(let m), .http(let m):
            return m
        case .notFound(let name):
            return "not found: \(name)"
        case .authFailed:
            return "Mac authentication failed (Touch ID or password not accepted)"
        case .authCancelled:
            return "Mac authentication cancelled"
        case .authUnavailable(let m):
            return "Mac authentication unavailable: \(m)"
        case .alreadyExists(let name):
            return "already exists: \(name)"
        case .gatewayOwned(let pid):
            return "the Keysrs menu bar app (process \(pid)) is managing your keys right now; do this from the dashboard (menu bar → Open Keysrs → Keys), or quit the menu bar app first"
        case .refusedBind(let host):
            return "refusing to bind \(host) (loopback 127.0.0.1 only)"
        }
    }
}

/// Strips credential values from text that may be printed or stored.
enum Redact {
    static let mask = "[redacted]"

    static func scrub(_ text: String, secrets: [String]) -> String {
        var out = text
        for secret in secrets where secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: mask)
        }
        // Authorization-style values and grant tokens, wherever they appear.
        out = out.replacingOccurrences(
            of: #"(?i)(bearer\s+)[A-Za-z0-9._\-~+/=]{8,}"#, with: "$1" + mask, options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"ksf_[A-Za-z0-9]+_[A-Za-z0-9_\-]+"#, with: mask, options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"(?i)(x-api-key|x-goog-api-key|api-key|authorization)(\s*[:=]\s*)\S+"#,
            with: "$1$2" + mask, options: .regularExpression
        )
        return out
    }
}

enum KeyName {
    static func validate(_ name: String) throws {
        guard name.count <= 128 else {
            throw AppError.usage("name too long")
        }
        guard name.wholeMatch(of: /^[a-z0-9][a-z0-9._-]*$/) != nil else {
            throw AppError.usage("invalid name \(name) (expected [a-z0-9][a-z0-9._-]*)")
        }
    }
}

enum KeyKind {
    static func validate(_ kind: String) throws {
        guard kind == "runtime" || kind == "billing" else {
            throw AppError.usage("kind must be runtime or billing")
        }
    }
}

enum Paths {
    /// A non-empty path from the environment, or nil.
    static func env(_ key: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Keysreallysafe", isDirectory: true)
    }

    static var catalogDB: URL { env("KEYS_CATALOG") ?? appSupport.appendingPathComponent("catalog.db") }

    static var grokHome: URL {
        env("GROK_HOME") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    static var claudeHome: URL {
        env("CLAUDE_CONFIG_DIR") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var codexHome: URL {
        env("CODEX_HOME") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

enum FixturePath {
    /// The checkout's or install's Web/ and the Fixtures/ beside it, then the installed copy
    /// under Application Support, so a `keys` found on PATH still finds its catalogs.
    static func resolve(fileName: String, envKey: String, testURL: URL?) -> URL? {
        if let testURL { return testURL }
        if let override = Paths.env(envKey) { return override }
        var roots: [URL] = []
        if let web = try? WebRoot.find() {
            roots += [web, web.deletingLastPathComponent().appendingPathComponent("Fixtures")]
        }
        roots += [Paths.appSupport.appendingPathComponent("Web"), Paths.appSupport.appendingPathComponent("Fixtures")]
        return roots.map { $0.appendingPathComponent(fileName) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }
}

/// A catalog file parsed once per process. Tests point `testURL` at a temp file, which
/// drops the cached value; a missing or unusable file is logged once and gives `fallback`.
final class FixtureCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fileName: String
    private let envKey: String
    private let missing: String
    private let fallback: Value
    private let parse: @Sendable (Data) -> Value?
    private var cached: Value?
    private var loggedMissing = false
    private var overrideURL: URL?

    init(fileName: String, envKey: String, missing: String, fallback: Value, parse: @escaping @Sendable (Data) -> Value?) {
        self.fileName = fileName
        self.envKey = envKey
        self.missing = missing
        self.fallback = fallback
        self.parse = parse
    }

    var testURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return overrideURL }
        set { lock.lock(); overrideURL = newValue; cached = nil; loggedMissing = false; lock.unlock() }
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = FixturePath.resolve(fileName: fileName, envKey: envKey, testURL: overrideURL)
        let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap(parse)
        if loaded == nil, !loggedMissing {
            loggedMissing = true
            FileHandle.standardError.write(Data((missing + "\n").utf8))
        }
        let result = loaded ?? fallback
        cached = result
        return result
    }
}

enum WebRoot {
    static func find() throws -> URL {
        if let override = Paths.env("KEYS_WEB_ROOT") { return override }
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Web"))
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<12 {
            candidates.append(dir.appendingPathComponent("Web"))
            dir.deleteLastPathComponent()
        }
        for web in candidates {
            if fm.isReadableFile(atPath: web.appendingPathComponent("index.html").path) {
                return web
            }
        }
        throw AppError.usage("Web/ not found; set KEYS_WEB_ROOT")
    }
}

enum UTC {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return internet.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = internet.date(from: string) { return d }
        if let d = fractional.date(from: string) { return d }
        let trimmed = trimFractionalSeconds(string)
        if trimmed != string {
            if let d = internet.date(from: trimmed) { return d }
            if let d = fractional.date(from: trimmed) { return d }
        }
        return nil
    }

    /// A log timestamp as canonical ISO: epoch seconds (a number or numeric string) or an ISO
    /// string. A string that does not parse is kept as written.
    static func normalize(_ any: Any?) -> String? {
        if let seconds = JSONValue.int64(any) { return iso(Date(timeIntervalSince1970: TimeInterval(seconds))) }
        guard let string = JSONValue.string(any) else { return nil }
        return parse(string).map(iso) ?? string
    }

    /// ISO8601DateFormatter rejects >3 fractional digits (`…26.160272+00:00`).
    private static func trimFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var i = string.index(after: dot)
        var digits = 0
        while i < string.endIndex, string[i].isNumber {
            digits += 1
            i = string.index(after: i)
        }
        guard digits > 3 else { return string }
        let keep = string.index(dot, offsetBy: 4)
        return String(string[..<keep]) + String(string[i...])
    }
}

enum JSONValue {
    static func object(_ any: Any?) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let d = any as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d {
                if let ks = k as? String { out[ks] = v }
            }
            return out
        }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func int64(_ any: Any?) -> Int64? {
        if any is NSNull { return nil }
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? NSNumber { return n.int64Value }
        if let d = any as? Double { return Int64(d) }
        if let s = any as? String { return Int64(s) }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if any is NSNull { return nil }
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let n = any as? Int64 { return Double(n) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// One jsonl line as an object. Throws on bad UTF-8 or JSON; nil when it is not an object.
    static func line(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { throw AppError.ingestIO("utf8") }
        do {
            return object(try JSONSerialization.jsonObject(with: data))
        } catch {
            throw AppError.ingestIO("json")
        }
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        return nil
    }

    static func bool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue
        }
        return nil
    }

    static func data(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}

enum BindPolicy {
    static let loopback = "127.0.0.1"

    static func isLoopbackHostname(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost"
    }
}

enum Ticks {
    static let perUSD: Double = 10_000_000_000

    static func usd(_ ticks: Int64) -> Double {
        Double(ticks) / perUSD
    }
}

enum SecureRandom {
    /// CSPRNG bytes for tokens and ids. arc4random_buf, also a CSPRNG on macOS, covers the
    /// case where SecRandomCopyBytes reports a failure.
    static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, count)
        }
        return bytes
    }
}

enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    /// Lowercase, two digits per byte. Stored client token hashes, tail digests, synthetic
    /// prompt ids and grant ids are in this exact form, so it must never change.
    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

enum ConstantTime {
    /// Compares every byte whatever the first difference, so timing reveals only the length.
    static func equal<A: Collection, B: Collection>(_ a: A, _ b: B) -> Bool
    where A.Element == UInt8, B.Element == UInt8 {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

enum PromptHash {
    static func syntheticPromptId(
        sessionId: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> String {
        let material = sessionId + timestamp + model + String(inputTokens) + String(outputTokens)
        return Hex.encode(SHA256.hash(data: Data(material.utf8)))
    }
}

enum SecretPrompt {
    static func read(fromClipboard: Bool, confirm: Bool) throws -> String {
        if fromClipboard {
            return try AppKitClipboard.readFromPasteboard()
        }
        if isatty(STDIN_FILENO) == 0 {
            guard let line = readLine(strippingNewline: true) else {
                throw AppError.usage("expected secret on stdin")
            }
            if line.isEmpty { throw AppError.usage("empty secret") }
            return line
        }
        let first = try readPass("Secret: ")
        if confirm {
            let second = try readPass("Again: ")
            if first != second {
                throw AppError.usage("secrets do not match")
            }
        }
        return first
    }

    private static func readPass(_ prompt: String) throws -> String {
        var buf = [CChar](repeating: 0, count: 8192)
        guard readpassphrase(prompt, &buf, buf.count, 0) != nil else {
            throw AppError.usage("failed to read secret")
        }
        let length = buf.firstIndex(of: 0) ?? buf.count
        let value = String(decoding: buf.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        for i in buf.indices { buf[i] = 0 }
        if value.isEmpty { throw AppError.usage("empty secret") }
        return value
    }
}
