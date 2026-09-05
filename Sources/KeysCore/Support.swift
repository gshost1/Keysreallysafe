import CryptoKit
import Darwin
import Foundation

enum AppError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case authFailed
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
        case .authFailed, .keychain:
            return 3
        case .ingestIO, .sqlite:
            return 4
        }
    }

    var description: String {
        switch self {
        case .usage(let m), .ingestIO(let m), .keychain(let m), .sqlite(let m), .http(let m):
            return m
        case .notFound(let name):
            return "not found: \(name)"
        case .authFailed:
            return "keychain authorization failed or cancelled"
        case .alreadyExists(let name):
            return "already exists: \(name)"
        case .gatewayOwned(let pid):
            return "gateway owned by another process (\(pid))"
        case .refusedBind(let host):
            return "refusing to bind \(host) (loopback 127.0.0.1 only)"
        }
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
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Keysreallysafe", isDirectory: true)
    }

    static var catalogDB: URL {
        if let override = ProcessInfo.processInfo.environment["KEYS_CATALOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return appSupport.appendingPathComponent("catalog.db")
    }

    static var grokHome: URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var codexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

enum FixturePath {
    static func resolve(fileName: String, envKey: String, testURL: URL?) -> URL? {
        if let testURL { return testURL }
        if let override = ProcessInfo.processInfo.environment[envKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let web = try? WebRoot.find() {
            let sibling = web.deletingLastPathComponent().appendingPathComponent("Fixtures/\(fileName)")
            if FileManager.default.isReadableFile(atPath: sibling.path) { return sibling }
            let fromWeb = web.appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: fromWeb.path) { return fromWeb }
        }
        let installed = Paths.appSupport.appendingPathComponent("Fixtures/\(fileName)")
        if FileManager.default.isReadableFile(atPath: installed.path) { return installed }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/\(fileName)")
        if FileManager.default.isReadableFile(atPath: cwd.path) { return cwd }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Fixtures/\(fileName)")
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

enum WebRoot {
    static func find() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["KEYS_WEB_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
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

    static func allowBind(host: String) -> Bool {
        host == loopback
    }

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

enum PromptHash {
    static func syntheticPromptId(
        sessionId: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> String {
        let material = sessionId + timestamp + model + String(inputTokens) + String(outputTokens)
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
