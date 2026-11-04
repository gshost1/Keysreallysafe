import ArgumentParser
import Foundation

// Commands for the dashboard actions the CLI had no spelling for: editing a key's
// metadata, a key's audit trail, the persisted app preferences, expiring client
// tokens, the release check and quitting the app. Each one goes through the same
// route or service call the dashboard uses, so the two surfaces cannot disagree.

struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change a key's provider, kind, notes or gateway host (never the name or secret).",
        discussion: """
            The same edit the dashboard's Edit dialog makes. No Touch ID: it moves metadata only. \
            Changing the provider or host turns the key's gateway off, so the next keys gateway on \
            shows the new destination in its prompt. --clear-host drops a per-key host and falls \
            back to the provider's own.
            """
    )

    @Argument(help: "Key name.") var name: String
    @Option(help: "Provider id (keys providers lists them).") var provider: String?
    @Option(help: "runtime, build, or another kind keys add accepts.") var kind: String?
    @Option(help: "Replace the notes. An empty string clears them.") var notes: String?
    @Option(help: "Per-key gateway host, e.g. api.example.com.") var host: String?
    @Flag(name: .customLong("clear-host"), help: "Remove the per-key gateway host.") var clearHost = false

    func run() throws {
        try KeyName.validate(name)
        if host != nil && clearHost { throw ValidationError("use --host or --clear-host, not both") }
        if let host, host.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError("--host is empty; use --clear-host to drop the per-key host")
        }
        if provider == nil && kind == nil && notes == nil && host == nil && !clearHost {
            throw ValidationError("nothing to change; pass --provider, --kind, --notes, --host or --clear-host")
        }
        if let provider { try GuidedAdd.validateExplicitProvider(provider) }

        var body: [String: Any] = [:]
        if let provider { body["provider"] = provider }
        if let kind { body["kind"] = kind }
        if let notes { body["notes"] = notes }
        if let host { body["host"] = host }
        if clearHost { body["host"] = NSNull() }

        // A live site owns the in-memory gateway state, so its answer is final: a refusal
        // is reported as it is, never retried as a direct write behind its back.
        if let client = try? ControlClient.connect() {
            _ = try client.call(method: "PATCH", path: "/api/keys/\(name)", body: body, expect: 200)
            print("edited \(name)")
            return
        }
        let service = try AppFactory.makeService()
        _ = try service.patch(
            name: name, provider: provider, kind: kind, notes: notes,
            host: host, updateHost: host != nil || clearHost
        )
        print("edited \(name)")
        fputs("no Keysrs site is running; it takes effect when one next starts\n", stderr)
    }
}

/// Tab-separated output must stay one row per record, whatever a label or detail holds.
func tsvCell(_ s: String) -> String {
    s.map { $0 == "\t" || $0.isNewline ? " " : String($0) }.joined()
}

struct EventsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Show a key's audit trail (adds, checks, grants, edits). Never values."
    )

    @Argument(help: "Key name.") var name: String
    @Option(help: "Most recent events to show. Default 50.") var limit: Int = 50
    @Flag var json = false

    func run() throws {
        try KeyName.validate(name)
        guard (1...500).contains(limit) else { throw ValidationError("--limit must be 1 to 500") }
        let service = try AppFactory.makeService()
        let rows = try service.keyEvents(name: name, limit: limit)
        if json {
            try JSONValue.printLine(rows.map { row -> [String: Any] in
                [
                    "id": row.id, "ts": row.ts, "name": row.name, "action": row.action,
                    "caller": row.caller as Any? ?? NSNull(), "detail": row.detail as Any? ?? NSNull(),
                ]
            })
            return
        }
        if rows.isEmpty {
            print("no events for \(name)")
            return
        }
        print("TS\tACTION\tCALLER\tDETAIL")
        for row in rows {
            print([row.ts, row.action, row.caller ?? "-", row.detail ?? "-"].map(tsvCell).joined(separator: "\t"))
        }
    }
}

struct PrefsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefs",
        abstract: "Show or change the app's saved choices (menu bar item, update checks).",
        subcommands: [PrefsShowCommand.self, PrefsSetCommand.self],
        defaultSubcommand: PrefsShowCommand.self
    )
}

/// A read that never launches the app: no live site means nothing to read, said plainly.
func liveClientOrNil() throws -> ControlClient? {
    try? ControlClient.connect()
}

struct PrefsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print the saved choices (needs the app running; never launches it)."
    )
    @Flag var json = false

    func run() throws {
        guard let client = try liveClientOrNil() else {
            throw AppError.siteUnavailable(AppConnection.notRunningMessage)
        }
        let obj = try client.call(method: "GET", path: "/api/preferences", expect: 200)
        if json {
            try JSONValue.printLine(obj)
            return
        }
        // Every boolean the site reports, so a preference it grows shows up here too.
        for field in obj.keys.sorted() {
            guard let on = JSONValue.bool(obj[field]) else { continue }
            print("\(field.replacingOccurrences(of: "_", with: "-"))\t\(on ? "on" : "off")")
        }
    }
}

struct PrefsSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Turn a saved choice on or off.",
        usage: "keys prefs set menubar-item|update-checks on|off"
    )

    /// CLI name -> the field /api/preferences reports. The route path is the CLI name.
    static let names = ["menubar-item": "menubar_item", "update-checks": "update_checks"]

    @Argument(help: "menubar-item or update-checks.") var preference: String
    @Argument(help: "on or off.") var state: String

    func run() throws {
        guard Self.names[preference] != nil else {
            throw AppError.usage("unknown preference \(preference); use menubar-item or update-checks")
        }
        let on: Bool
        switch state.lowercased() {
        case "on": on = true
        case "off": on = false
        default: throw AppError.usage("say on or off, e.g. keys prefs set \(preference) on")
        }
        let client = try AppConnection.connect().controlClient
        _ = try client.call(method: "POST", path: "/api/preferences/\(preference)", body: ["on": on], expect: 200)
        print("\(preference) \(on ? "on" : "off")")
    }
}

struct ExpiringCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expiring",
        abstract: "List gateway client tokens close to expiry (labels and dates, never tokens)."
    )
    @Flag var json = false

    func run() throws {
        guard let client = try liveClientOrNil() else {
            throw AppError.siteUnavailable(AppConnection.notRunningMessage)
        }
        let obj = try client.call(method: "POST", path: "/api/expiring_tokens", body: [:], expect: 200)
        let tokens = (obj["tokens"] as? [Any])?.compactMap(JSONValue.object) ?? []
        if json {
            try JSONValue.printLine(tokens)
            return
        }
        if tokens.isEmpty {
            print("no tokens near expiry")
            return
        }
        print("LABEL\tKEYS\tEXPIRES")
        for t in tokens {
            let keys = (t["keys"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ",") ?? ""
            print([JSONValue.string(t["label"]) ?? "", keys, JSONValue.string(t["expires_at"]) ?? ""].map(tsvCell).joined(separator: "\t"))
        }
    }
}

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check GitHub for a newer release. The app installs updates itself when idle.",
        discussion: "Read-only: one request for the latest release. Exit 0 either way; --json for scripts."
    )
    @Flag var json = false

    func run() throws {
        let latest = try UpdateCheck.latestReleaseSync()
        let current = AppVersion.current
        let newer = UpdateCheck.isNewer(latest.version, than: current)
        if json {
            try JSONValue.printLine(["current": current, "latest": latest.version, "update_available": newer] as [String: Any])
            return
        }
        print(newer ? "update available: \(current) -> \(latest.version)" : "up to date (\(current))")
    }
}

struct QuitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit",
        abstract: "Quit the running Keysrs app (what Settings > Quit does). Never launches it."
    )

    func run() throws {
        let client: ControlClient
        do {
            client = try ControlClient.connect()
        } catch {
            // No control file at all is the one case that means "not running"; a file that
            // exists but cannot be used is a failure, so a script never swaps a live app.
            if let url = try? ControlFile.url(), !FileManager.default.fileExists(atPath: url.path) {
                print("Keysrs is not running")
                return
            }
            throw error
        }
        _ = try client.call(method: "POST", path: "/api/app/quit", body: [:], expect: 200)
        print("Keysrs is quitting")
    }
}
