import Foundation

enum EnvVar {
    static func canonicalize(_ name: String) -> String {
        var s = name.trimmingCharacters(
            in: .whitespacesAndNewlines
                .union(.controlCharacters)
                .union(CharacterSet(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{FEFF}\u{202F}\u{2060}"))
        )
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"),
            ("“", "”"), ("‘", "’"),
        ]
        while s.count >= 2, let first = s.first, let last = s.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last })
        {
            s.removeFirst()
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    static func validate(_ name: String) throws {
        let trimmed = canonicalize(name)
        if trimmed.isEmpty {
            throw AppError.usage("environment variable name is missing (example: OPENAI_API_KEY)")
        }
        if trimmed.hasPrefix("$") {
            let bare = String(trimmed.drop(while: { $0 == "$" }))
            throw AppError.usage("use \(bare) not \(trimmed) — no dollar sign")
        }
        guard trimmed.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
            throw AppError.usage(
                "invalid environment variable \(trimmed.debugDescription) (letters, digits, underscore only, e.g. OPENAI_API_KEY)"
            )
        }
    }
}

protocol CommandRunner: Sendable {
    func run(argv: [String], extraEnv: [String: String]) throws -> Int32
}

struct FoundationCommandRunner: CommandRunner {
    func run(argv: [String], extraEnv: [String: String]) throws -> Int32 {
        guard !argv.isEmpty else { throw AppError.usage("missing command after --") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv {
            env[key] = value
        }
        process.environment = env
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw AppError.usage("could not run command")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
