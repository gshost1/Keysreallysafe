import AppKit
import ArgumentParser
import Darwin
import Foundation
import ServiceManagement

public struct KeysCLI: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Keysrs — local key vault and token spend meter.",
        // `--version` answers from the single version constant (the same one the
        // updater and share-to-compare report); the subcommand adds --json shape.
        version: ProductAnalyticsConfiguration.appVersion,
        subcommands: [
            AddCommand.self,
            ListCommand.self,
            GetCommand.self,
            CopyCommand.self,
            RmCommand.self,
            RotateCommand.self,
            IngestCommand.self,
            UsageCommand.self,
            SpendCommand.self,
            VersionCommand.self,
            StatusCommand.self,
            DoctorCommand.self,
            LogCommand.self,
            LoginItemStatusCommand.self,
            EnvCommand.self,
            GrantCommand.self,
            GrantsCommand.self,
            RevokeCommand.self,
            RenewCommand.self,
            ProfileCommand.self,
            TestCommand.self,
            ModelsCommand.self,
            DashboardCommand.self,
            MenubarCommand.self,
            AutostartCommand.self,
            ClientCommand.self,
            GatewayCommand.self,
            WrapCommand.self,
            ProvidersCommand.self,
            ProviderCommand.self,
            AgentCommand.self,
            McpCommand.self,
            SetupCommand.self,
            TunnelCommand.self,
            RelayCommand.self,
            PurgeCommand.self,
        ]
    )
}

public enum KeysMain {
    public static func main() {
        do {
            if CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().allSatisfy({ $0.hasPrefix("-psn_") }) {
                do { try AppRuntime.run() }
                catch {
                    runOnMainActor {
                        NSApplication.shared.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Keysrs Could Not Start"
                        alert.informativeText = String(describing: error)
                        alert.runModal()
                    }
                    throw error
                }
                return
            }
            var command = try KeysCLI.parseAsRoot()
            try command.run()
        } catch let error as AppError {
            // Own exit codes: 2 not found, 3 presence or Keychain, 4 ingest or catalog,
            // 6 no running site.
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            Darwin.exit(error.exitCode)
        } catch let error as ProfileError {
            // Profile refusals print their message like usage errors do.
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            Darwin.exit(1)
        } catch {
            KeysCLI.exit(withError: error)
        }
    }
}

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Store a secret in Keychain.")

    @Argument var name: String
    @Option var provider: String
    @Option var kind: String = "runtime"
    @Option var notes: String = ""
    @Flag var clipboard = false

    func run() throws {
        let secret = try SecretPrompt.read(fromClipboard: clipboard, confirm: true)
        let service = try AppFactory.makeService()
        try service.add(name: name, provider: provider, kind: kind, notes: notes, secret: secret, caller: "add")
        print("added \(name)")
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List key names (never values).")

    @Flag var json = false

    func run() throws {
        let service = try AppFactory.makeService()
        let rows = try service.list()
        if json {
            try JSONValue.printLine(Self.jsonRows(service: service))
            return
        }
        if rows.isEmpty {
            print("no keys")
            return
        }
        print("NAME\tPROVIDER\tKIND\tLAST_USED")
        for row in rows {
            let last = row.lastUsedAt ?? "-"
            print("\(row.name)\t\(row.provider)\t\(row.kind)\t\(last)")
        }
    }

    /// The gateway holds its keys in the running app's memory, so a CLI process built the
    /// list from its own empty cache and reported every key off while the app had them on.
    /// The app's list is the truth while it runs; without it no key is on, and the local
    /// rows say so correctly.
    static func jsonRows(service: KeysService) throws -> [[String: Any]] {
        if let client = try? ControlClient.connect(control: ControlFile.url(beside: service.catalog.path)),
           let obj = try? client.call(method: "GET", path: "/api/keys", expect: 200, timeout: 5),
           let keys = obj["keys"] as? [[String: Any]]
        {
            return keys
        }
        return try service.listJSONObject()
    }
}

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print a secret once (user presence).")

    @Argument var name: String

    func run() throws {
        let service = try AppFactory.makeService()
        let secret = try service.reveal(name: name, caller: "get")
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
    }
}

struct CopyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a secret to the clipboard and wipe after 20s (user presence)."
    )

    @Argument var name: String

    func run() throws {
        let service = try AppFactory.makeService()
        try service.copy(name: name, holdUntilWipe: true, caller: "copy")
        print("copied \(name); clipboard wiped after \(Int(ClipboardWipe.seconds))s")
    }
}

struct RmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a key.")

    @Argument var name: String
    @Flag var yes = false

    func run() throws {
        try KeyName.validate(name)
        if !yes {
            fputs("Delete key '\(name)'? [y/N] ", stderr)
            fflush(stderr)
            let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard answer == "y" || answer == "yes" else {
                print("cancelled")
                return
            }
        }
        let service = try AppFactory.makeService()
        try service.remove(name: name, caller: "rm")
        print("removed \(name)")
    }
}

struct RotateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Replace a secret under the same name (user presence)."
    )

    @Argument var name: String
    @Flag var clipboard = false

    func run() throws {
        let secret = try SecretPrompt.read(fromClipboard: clipboard, confirm: true)
        let service = try AppFactory.makeService()
        let row = try service.rotate(name: name, secret: secret, caller: "rotate")
        print("rotated \(name) version \(row.version)")
    }
}

struct IngestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ingest", abstract: "Scan local Grok, Claude Code, Codex, and Droid usage logs.")

    @Argument var source: String = "all"

    func run() throws {
        guard let parsed = Ingest.Source(rawValue: source) else {
            throw AppError.usage("ingest source must be all, grok, claude, openai, or droid")
        }
        let service = try AppFactory.makeService()
        let reports = try service.ingest(parsed)
        for (name, report) in reports {
            print("\(name): \(report.line)")
        }
    }
}

struct UsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Bring in usage recorded off this Mac.",
        subcommands: [UsageImportCommand.self]
    )
}

struct UsageImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a remote usage export (droid log lines, droid stream-json, Claude Code transcripts).",
        discussion: """
            Make the file where the usage happened with scripts/export-remote-usage.py, which keeps \
            only usage fields. Rows are stored as droid-remote and claude-remote and charted under Cloud. \
            Files dropped into the imports folder beside the catalog are imported on the next ingest.

            Every path is attempted, in order, and each prints one line: "<name>: <counts>" or \
            "<name>: <error>". The exit status is non-zero if any path failed (missing, not a regular \
            file, unreadable, over the size limit) or any file stored nothing while having lines it \
            could not read; an empty file or one with no usage lines is not a failure.
            """
    )

    @Argument(help: "Export files to import.") var files: [String]

    func run() throws {
        let service = try AppFactory.makeService()
        if UsageImportRun.run(paths: files, importer: { try service.importRemote($0) }, emit: { print($0) }) {
            throw ExitCode.failure
        }
    }
}

/// The per-path loop of `keys usage import`, apart from the command so a test can drive it.
/// A bad path never stops the ones after it; the result says whether any path failed.
enum UsageImportRun {
    static func run(paths: [String], importer: (URL) throws -> IngestReport, emit: (String) -> Void) -> Bool {
        var failed = false
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            do {
                let report = try importer(url)
                emit("\(name): \(report.line)")
                if report.parseErrors > 0 && report.handledRows == 0 { failed = true }
            } catch {
                // An AppError is already a sentence; anything else would print a type name.
                let reason = (error as? AppError)?.description ?? "could not be imported"
                emit("\(name): \(reason)")
                failed = true
            }
        }
        return failed
    }
}

struct SpendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "spend", abstract: "Show local token spend.")

    @Flag var month = false
    @Flag var week = false
    @Flag var json = false
    @Option var by: String = "model"

    func run() throws {
        if month && week { throw AppError.usage("choose --month or --week") }
        let range: SpendRange = week ? .week : .month
        guard let group = SpendGroup(rawValue: by), [.model, .session, .project].contains(group) else {
            throw AppError.usage("--by must be model, session, or project")
        }
        let service = try AppFactory.makeService()
        let source: SourceFilter = group == .project ? .claude : .all
        let report = try service.spend(range: range, by: group, source: source)
        if json {
            try JSONValue.printLine(report.jsonObject())
            return
        }
        printTable(report)
        print(report.caption)
        if report.totals.claudeUsdEstimate != nil {
            print("Claude USD is an estimate, not an invoice. Grok totals use costUsdTicks only.")
        }
    }

    /// A reported cost, else an estimate marked "est …*", else "-" for unknown.
    private func usdCell(_ row: SpendRow) -> String {
        if let v = row.usd { return String(format: "%.4f", v) }
        if let e = row.usdEstimate { return String(format: "est %.4f*", e) }
        return "-"
    }

    private func printTable(_ report: SpendReport) {
        switch report.by {
        case .model, .hour, .key, .provider:
            print("MODEL\tIN\tOUT\tCACHE_READ\tREASONING\tUSD\tCALLS")
            for row in report.rows {
                let usd = usdCell(row)
                print("\(row.model ?? "")\t\(row.inputTokens)\t\(row.outputTokens)\t\(row.cachedReadTokens)\t\(row.reasoningTokens)\t\(usd)\t\(row.modelCalls)")
            }
        case .session:
            print("SESSION\tCWD\tTITLE\tMODELS\tUSD")
            for row in report.rows {
                let usd = usdCell(row)
                let models = row.models.joined(separator: ",")
                print("\(row.sessionId ?? "")\t\(row.cwd ?? "")\t\(row.title ?? "")\t\(models)\t\(usd)")
            }
        case .project:
            print("PROJECT\tCWD\tIN\tOUT\tUSD")
            for row in report.rows {
                let usd = usdCell(row)
                print("\(row.project ?? "")\t\(row.cwd ?? "")\t\(row.inputTokens)\t\(row.outputTokens)\t\(usd)")
            }
        }
        print(String(format: "Grok $%.4f  Claude tokens %d  OpenAI tokens %d", report.totals.grokUsd, report.totals.claudeTokens, report.totals.openaiTokens))
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the Keysrs version."
    )

    @Flag var json = false

    func run() throws {
        if json {
            try JSONValue.printLine(Self.jsonObject())
            return
        }
        print(Self.humanLine())
    }

    static func humanLine() -> String {
        "Keysrs \(ProductAnalyticsConfiguration.appVersion)"
    }

    /// The one line, sorted keys, that every `--json` flag prints.
    static func jsonObject() -> [String: String] {
        ["version": ProductAnalyticsConfiguration.appVersion]
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Local plan windows: Grok, Claude, OpenAI/Codex, and other tools."
    )

    @Flag(help: "Print one JSON line, an entry per tool with its tracked state, for a script to read.")
    var json = false

    func run() throws {
        let service = try AppFactory.makeService()
        let status = try service.liveStatus()
        if json {
            try JSONValue.printLine(Self.jsonObject(plans: status.plans))
            return
        }
        for row in status.plans {
            for line in Self.humanLines(row) {
                print(line)
            }
        }
    }

    /// The one JSON line, sorted keys, that every `--json` flag prints: an entry per tool,
    /// every entry saying whether Keysrs tracks it. An untracked tool carries no usage
    /// numbers at all, so a script cannot mistake absence for a measured zero — the same
    /// no-fake-numbers rule the prose follows.
    static func jsonObject(plans: [ToolStatus], now: Date = Date()) -> [String: Any] {
        ["tools": plans.map { jsonEntry($0, now: now) }]
    }

    /// True when Keysrs holds a current measured usage figure for the tool. A percent whose
    /// window already reset is not one: it describes a window that closed, and printing it
    /// now would let a script read a stale number as if it described the current one, the
    /// reason every other reader nulls expired windows. A zero alone does not count either:
    /// an idle week is an absence, not a measurement (the Usage pane's rule), so a fresh
    /// machine reports every tool as not tracked.
    static func isTracked(_ row: ToolStatus, now: Date) -> Bool {
        if livePct(row.fiveHourPct, reset: row.fiveHourResetsAt, now: now) != nil { return true }
        if livePct(row.weeklyPct, reset: row.weeklyResetsAt, now: now) != nil { return true }
        if row.monthlyPct != nil { return true }
        if livePct(row.fablePct, reset: row.fableResetsAt, now: now) != nil { return true }
        if row.limitRemaining != nil || row.usageWeekly != nil { return true }
        if let usd = row.weeklyUsd, usd > 0 { return true }
        if let tokens = row.weeklyTokens, tokens > 0 { return true }
        if let tokens = row.fiveHourTokens, tokens > 0 { return true }
        if let tokens = row.monthlyTokens, tokens > 0 { return true }
        if let prompts = row.weeklyPrompts, prompts > 0 { return true }
        return false
    }

    private static func jsonEntry(_ row: ToolStatus, now: Date) -> [String: Any] {
        var entry: [String: Any] = [
            "source": row.source,
            "title": row.title,
            "kind": row.kind,
        ]
        let tracked = isTracked(row, now: now)
        entry["tracked"] = tracked
        if let note = row.usageNote {
            entry["usage_note"] = note
        }
        guard tracked else { return entry }
        // Only windows with something current in them appear, so a present key is a real
        // figure. An expired window's percent is left out with its reset time; the prose
        // hedges those with "(reset due)", a caveat a JSON number cannot carry inline.
        if let pct = livePct(row.fiveHourPct, reset: row.fiveHourResetsAt, now: now) {
            entry["five_hour_pct"] = pct
            if let reset = row.fiveHourResetsAt { entry["five_hour_resets_at"] = reset }
        }
        if let pct = livePct(row.weeklyPct, reset: row.weeklyResetsAt, now: now) {
            entry["weekly_pct"] = pct
            if let reset = row.weeklyResetsAt { entry["weekly_resets_at"] = reset }
        }
        if let pct = livePct(row.fablePct, reset: row.fableResetsAt, now: now) {
            entry["fable_pct"] = pct
            if let reset = row.fableResetsAt { entry["fable_resets_at"] = reset }
        }
        if let pct = row.monthlyPct {
            entry["monthly_pct"] = pct
        }
        // Token, spend and limit figures are counted per window, so the zeros that appear
        // here are real zeros, counted from records that exist.
        let measured: [(String, Any)] = [
            ("weekly_usd", row.weeklyUsd as Any? ?? NSNull()),
            ("weekly_tokens", row.weeklyTokens as Any? ?? NSNull()),
            ("weekly_prompts", row.weeklyPrompts as Any? ?? NSNull()),
            ("five_hour_tokens", row.fiveHourTokens as Any? ?? NSNull()),
            ("monthly_tokens", row.monthlyTokens as Any? ?? NSNull()),
            ("five_hour_limit", row.fiveHourLimit as Any? ?? NSNull()),
            ("weekly_limit", row.weeklyLimit as Any? ?? NSNull()),
            ("monthly_limit", row.monthlyLimit as Any? ?? NSNull()),
            ("limit", row.limit as Any? ?? NSNull()),
            ("limit_remaining", row.limitRemaining as Any? ?? NSNull()),
            ("usage_weekly", row.usageWeekly as Any? ?? NSNull()),
            ("plan", row.plan as Any? ?? NSNull()),
            ("snapshot_at", row.snapshotAt as Any? ?? NSNull()),
        ]
        for (key, value) in measured where !(value is NSNull) {
            entry[key] = value
        }
        if let period = row.period, row.weeklyUsd != nil || row.weeklyTokens != nil || row.weeklyPrompts != nil {
            entry["period"] = period.jsonObject()
        }
        return entry
    }

    /// A percent of a window that has not closed: no reset time, or one still in the future.
    /// A reset that cannot be parsed is treated as expired, the stricter rule the Claude
    /// usage cache already applies.
    private static func livePct(_ pct: Int?, reset: String?, now: Date) -> Int? {
        guard let pct else { return nil }
        if let reset {
            guard let date = UTC.parse(reset), date > now else { return nil }
        }
        return pct
    }

    /// The prose blocks the human path prints for one tool, pulled out so a test can pin
    /// them: `--json` grows beside this output, and it must not drift while it does.
    static func humanLines(_ row: ToolStatus, now: Date = Date()) -> [String] {
        var lines = [row.title]
        if row.source == "droid" {
            // Three catalog-backed windows, each with its optional limit. A limit prints the
            // percent it drives; an unlimited window prints the tokens alone.
            lines.append("  5 hour  \(droidWindow(row.fiveHourTokens, limit: row.fiveHourLimit))")
            lines.append("  weekly  \(droidWindow(row.weeklyTokens, limit: row.weeklyLimit))")
            lines.append("  month   \(droidWindow(row.monthlyTokens, limit: row.monthlyLimit))")
        } else {
            if let usd = row.weeklyUsd, row.weeklyTokens != nil {
                lines.append("  weekly  \(row.weeklyTokens ?? 0) tokens  ≈ \(String(format: "$%.2f", usd)) estimate")
            } else if let usd = row.weeklyUsd {
                lines.append("  weekly  \(String(format: "$%.2f", usd))  local spend")
            } else if row.weeklyTokens != nil {
                lines.append("  weekly  \(row.weeklyTokens ?? 0) tokens")
            } else if let prompts = row.weeklyPrompts {
                lines.append("  weekly  \(prompts) prompts sent · limit not tracked")
            }
            if row.fiveHourPct != nil || row.source == "claude" || row.source == "openai" {
                lines.append("  5 hour  \(pctLine(row.fiveHourPct, reset: row.fiveHourResetsAt, now: now))")
            }
            if row.weeklyPct != nil || row.source == "openai" {
                lines.append("  weekly  \(pctLine(row.weeklyPct, reset: row.weeklyResetsAt, now: now))")
            }
            if row.source == "claude" {
                lines.append("  Fable   \(pctLine(row.fablePct, reset: row.fableResetsAt, now: now))")
            }
        }
        if let note = row.usageNote {
            lines.append("  \(note)")
        }
        return lines
    }

    /// One Droid window: its tokens, and the percent of the limit when one is set.
    private static func droidWindow(_ tokens: Int?, limit: Int?) -> String {
        guard let tokens else { return "—" }
        var line = "\(tokens) tokens"
        if let limit {
            line += "  (\(DroidUsage.pct(tokens, limit: limit))% of \(limit) limit)"
        }
        return line
    }

    private static func pctLine(_ pct: Int?, reset: String?, now: Date) -> String {
        guard let pct else { return "—" }
        var s = "\(pct)%"
        if let reset, let extra = LiveStatus.formatResets(at: reset, now: now) {
            s += "  (\(extra))"
        }
        return s
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Show local sources, catalog, Keychain, gateway, the app install, its login item, and the command line link."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let report = try Doctor.report(service: service)
        print(report.printed)
    }
}

/// Reports the app's login item registration so a `keys doctor` run from outside the bundle can
/// ask the installed app. Hidden from help. Deliberately touches nothing but `SMAppService` and
/// one `print`: no service, catalog or Keychain, so an incidental run against an older installed
/// binary fails at argument parsing before anything else would.
struct LoginItemStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-item-status",
        abstract: "Print the app's login item state (internal).",
        shouldDisplay: false
    )

    func run() {
        print(LoginItemState(status: SMAppService.mainApp.status).statusWord)
    }
}

struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Run a command with vault secrets in its environment (one user presence check, no clipboard).",
        usage: "keys env <name> <variable> [<name> <variable> ...] -- <command> ...",
        discussion: """
            Unlocks the named keys under one Touch ID and sets each <variable> in the child only. \
            Every key is read before the command starts, so a missing one runs nothing. The \
            command stays in keys' process group, so Ctrl-C reaches it, and keys exits the way \
            it did. Put -- before the command so its flags are not parsed by keys. No secret \
            is copied to the clipboard.
            """
    )

    @Argument(help: "Vault key name.")
    var name: String

    @Argument(help: "Environment variable to set in the child.")
    var variable: String

    @Argument(parsing: .captureForPassthrough, help: ArgumentHelp("More <name> <variable> pairs, then -- and the command.", valueName: "more"))
    var rest: [String] = []

    /// The pairs before `--` and the command after it.
    func parsed() throws -> (pairs: [EnvPair], command: [String]) {
        try EnvPair.parse([name, variable] + rest)
    }

    func run() throws {
        let (pairs, command) = try parsed()
        let service = try AppFactory.makeService()
        try service.env(pairs: pairs, command: command, caller: "env").exitProcess()
    }
}

struct GrantCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant",
        abstract: "Temporary, scoped gateway access for one task (one Touch ID, no raw secret).",
        discussion: """
            Asks the running site to mint a grant token for <name>. Use the token as the API key \
            and point the SDK at the printed base URL; the gateway swaps in the real secret. \
            The grant expires, can be revoked, and dies with screen lock or a site restart, \
            on purpose: a grant is for a task you are around for. A job that must outlive a \
            screen lock needs a client token (keys client issue) instead. \
            Within its scope no further prompts are needed. With --profile the grant issues \
            within the saved profile's bounds and the prompt names the profile and the \
            effective scope; an ask outside them is refused before the prompt. \
            With --max-usd the spend is the \
            provider's reported cost where it gives one, else a list-price estimate; a call \
            that has neither ends the grant (429 grant_usd_unpriced), because the cap could \
            no longer be checked.
            """
    )

    @Argument(help: "Vault key name.")
    var name: String

    @Option(help: "What the access is for; shown in the Touch ID prompt and the audit log.")
    var task: String = ""

    @Option(help: "Lifetime in minutes (1-1440). Default \(Grant.defaultMinutes); with --profile, the profile's minutes.")
    var minutes: Int?

    @Option(help: "Comma-separated HTTP methods, e.g. GET or GET,POST. Default: all.")
    var methods: String = ""

    @Option(help: "Comma-separated path prefixes under the provider prefix, e.g. /models. Default: any.")
    var paths: String = ""

    @Option(name: .customLong("max-requests"), help: "Refuse further calls after this many.")
    var maxRequests: Int?

    @Option(name: .customLong("max-usd"), help: "Refuse further calls once the spend passes this (checked after each call); an unpriced call also ends the grant.")
    var maxUsd: Double?

    @Option(help: "Issue within this saved profile's bounds (keys profile list); the prompt names the profile and the effective scope.")
    var profile: String?

    @Flag(help: "Print the grant as JSON (token included) for a script to read once.")
    var json = false

    func run() throws {
        try KeyName.validate(name)
        let client = try ControlClient.connect()
        // Minutes ride only when said: with --profile an unset --minutes means the profile's
        // minutes, which only the site knows once the bounds are applied.
        var body: [String: Any] = ["task": task, "caller": "cli"]
        if let minutes { body["minutes"] = minutes }
        if let profile { body["profile"] = profile }
        let methodList = methods.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !methodList.isEmpty { body["methods"] = methodList }
        let pathList = paths.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !pathList.isEmpty { body["paths"] = pathList }
        if let maxRequests { body["max_requests"] = maxRequests }
        if let maxUsd { body["max_usd"] = maxUsd }
        fputs("Touch ID in the Keysrs site…\n", stderr)
        let obj = try client.call(method: "POST", path: "/api/keys/\(name)/grants", body: body, expect: 201)
        if json {
            try JSONValue.printLine(obj)
            return
        }
        let token = JSONValue.string(obj["token"]) ?? ""
        let id = JSONValue.string(obj["id"]) ?? ""
        let providerName = Providers.provider(id: JSONValue.string(obj["provider"]) ?? "")?.name
            ?? (JSONValue.string(obj["provider"]) ?? "")
        let host = JSONValue.string(obj["host"]) ?? ""
        let expires = JSONValue.string(obj["expires_at"]) ?? ""
        let methodsOut = (obj["methods"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ",") ?? "all"
        let pathsOut = (obj["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
        let base = JSONValue.string(obj["base_url"]) ?? ""
        let header = JSONValue.string(obj["auth_header"]) ?? "Authorization"
        print("grant \(id)  \(name) -> \(providerName) (\(host))")
        print("  task     \(JSONValue.string(obj["task"]) ?? "")")
        if let p = JSONValue.string(obj["profile"]) {
            print("  profile  \(p)\((JSONValue.bool(obj["unattended"]) ?? false) ? " · unattended" : "")")
        }
        let span = Self.effectiveMinutes(
            created: JSONValue.string(obj["created_at"]), expires: expires, asked: minutes
        )
        print("  expires  \(expires)\(span.isEmpty ? "" : "  (\(span))")")
        print("  scope    methods \(methodsOut.isEmpty ? "all" : methodsOut)  paths \(pathsOut.isEmpty ? "any" : pathsOut.joined(separator: ","))")
        if let n = JSONValue.int(obj["max_requests"]) { print("  limit    \(n) requests") }
        if let u = JSONValue.double(obj["max_usd"]) {
            print("  limit    $\(String(format: "%.2f", u)), enforced after each call; a call with no price ends the grant")
        }
        print("  base url \(base)")
        // Paths are scoped under the base URL; spelling out one full URL catches a
        // missing version segment before the first call is refused.
        if let first = pathsOut.first { print("  allows   \(base)\(first)") }
        print("  token    \(token)")
        print("  use the token as the API key (\(header)); the gateway swaps in the real secret")
        print("  renew    keys renew \(id)")
        print("  revoke   keys revoke \(id)")
    }

    /// The lifetime line for the grant printout. With --profile an unset --minutes means the
    /// profile's minutes, which only the site knows, so the span is read back from the issued
    /// grant instead of the flag.
    static func effectiveMinutes(created: String?, expires: String?, asked: Int?) -> String {
        if let asked { return "\(asked) min" }
        guard let c = created.flatMap(UTC.parse), let e = expires.flatMap(UTC.parse) else { return "" }
        return "\(Int((e.timeIntervalSince(c) / 60).rounded())) min"
    }
}

struct GrantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grants", abstract: "List active grants on the running site.")

    @Flag(help: "Include expired and revoked grants.")
    var all = false

    @Flag var json = false

    /// The table shape; the row seam builds against it, so the columns stay spelled out.
    static let header = "ID\tKEY\tHOST\tTASK\tSTATUS\tEXPIRES\tREQUESTS\tUSD\tPROFILE\tUNATTENDED"

    func run() throws {
        let client = try ControlClient.connect()
        let obj = try client.call(method: "GET", path: "/api/grants" + (all ? "?all=1" : ""), expect: 200)
        let grants = (obj["grants"] as? [Any])?.compactMap(JSONValue.object) ?? []
        if json {
            try JSONValue.printLine(grants)
            return
        }
        if grants.isEmpty {
            print(all ? "no grants" : "no active grants")
            return
        }
        print(Self.header)
        for g in grants {
            print(Self.row(g))
        }
    }

    /// One table row from one grant JSON. A profile-issued grant names its profile and carries
    /// the unattended badge (the same word the Touch ID prompt used); a plain grant shows a
    /// dash in both columns.
    static func row(_ g: [String: Any]) -> String {
        [
            JSONValue.string(g["id"]) ?? "", JSONValue.string(g["key"]) ?? "", JSONValue.string(g["host"]) ?? "",
            JSONValue.string(g["task"]) ?? "", JSONValue.string(g["status"]) ?? "",
            JSONValue.string(g["expires_at"]) ?? "", String(JSONValue.int(g["requests"]) ?? 0),
            usdCell(usd: JSONValue.double(g["usd"]) ?? 0, unpriced: JSONValue.int(g["unpriced_calls"]) ?? 0),
            JSONValue.string(g["profile"]) ?? "-",
            (JSONValue.bool(g["unattended"]) ?? false) ? "unattended" : "-",
        ].joined(separator: "\t")
    }

    /// An unpriced call is unknown money, so the sum of the priced ones is only a floor.
    static func usdCell(usd: Double, unpriced: Int) -> String {
        if unpriced == 0 { return String(format: "%.4f", usd) }
        let calls = "\(unpriced) call\(unpriced == 1 ? "" : "s")"
        if usd == 0 { return "unpriced (\(calls))" }
        return String(format: "≥%.4f", usd) + " + unpriced (\(calls))"
    }
}

struct RevokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Revoke a grant now (no Touch ID needed).")

    @Argument(help: "Grant id from keys grant, or omit with --all.")
    var id: String?

    @Flag(help: "Revoke every active grant.")
    var all = false

    @Option(help: "With --all, only grants for this key.")
    var key: String?

    func run() throws {
        let client = try ControlClient.connect()
        if all {
            var path = "/api/grants"
            if let key {
                try KeyName.validate(key)
                path += "?key=\(key)"
            }
            let obj = try client.call(method: "DELETE", path: path, expect: 200)
            let n = (obj["revoked"] as? [Any])?.count ?? 0
            print("revoked \(n) grant\(n == 1 ? "" : "s")")
            return
        }
        guard let id, !id.isEmpty else { throw AppError.usage("give a grant id, or --all") }
        _ = try client.call(method: "DELETE", path: "/api/grants/\(id)", expect: 200)
        print("revoked \(id)")
    }
}

struct RenewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renew",
        abstract: "Renew an active or expired grant in place (same key, host, scope and caps; one Touch ID).",
        discussion: """
            Re-approves the grant exactly as it is for another window of its original \
            lifetime: same id and same token, so a running agent keeps working, and the usage \
            counters start over. Renewal takes no scope knobs — for different bounds issue a \
            new grant with keys grant. A revoked grant is never renewable.
            """
    )

    @Argument(help: "Grant id from keys grants.")
    var id: String

    @Flag(help: "Print the renewed grant as JSON.")
    var json = false

    func run() throws {
        let client = try ControlClient.connect()
        fputs("Touch ID in the Keysrs site…\n", stderr)
        let obj = try client.call(method: "POST", path: "/api/grants/\(id)/renew", body: [:], expect: 200)
        if json {
            try JSONValue.printLine(obj)
            return
        }
        let provider = JSONValue.string(obj["provider"]) ?? ""
        let providerName = Providers.provider(id: provider)?.name ?? provider
        let key = JSONValue.string(obj["key"]) ?? ""
        let host = JSONValue.string(obj["host"]) ?? ""
        print("renewed \(id)  \(key) -> \(providerName) (\(host))")
        print("  task     \(JSONValue.string(obj["task"]) ?? "")")
        print("  expires  \(JSONValue.string(obj["expires_at"]) ?? "")")
        print("  renewals \(JSONValue.int(obj["renewals"]) ?? 0)")
        // No token line: the one printed at issuance keeps working and is never repeated.
    }
}

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Save, list or remove named grant bounds.",
        discussion: """
            A profile is issuance-time policy, not authority: keys grant <key> --profile <name> \
            issues within its bounds, each grant still costing one Touch ID whose prompt names \
            the effective scope, and a grant keeps its scope even if the profile is edited or \
            removed afterwards. Profiles hold no secrets, so these commands work straight off \
            the catalog — no running site, no Touch ID — and an unattended profile must carry a \
            hard cap (--max-requests or --max-usd), because an unwatched grant is pre-committed \
            to what it can do.
            """,
        subcommands: [ProfileAddCommand.self, ProfileListCommand.self, ProfileRemoveCommand.self],
        defaultSubcommand: ProfileListCommand.self
    )
}

struct ProfileAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Save a named bound on grants: keys, methods, paths, minutes, caps.",
        discussion: """
            Every value is a default-and-ceiling: a grant under this profile may tighten a \
            bound, never exceed it, and an out-of-bounds ask is refused before any prompt. \
            --unattended marks grants meant to run while you are away; it requires a hard cap. \
            An unattended grant still dies on screen lock, restart or revoke — a job that must \
            outlive a lock needs a client token (keys client issue) instead.
            """
    )

    @Argument(help: "Profile name: [a-z0-9][a-z0-9._-]*, unique.")
    var name: String

    @Option(help: "Comma-separated vault key names, e.g. router or router,spare.")
    var keys: String

    @Option(help: "Comma-separated HTTP methods, e.g. GET or GET,POST. Default: all.")
    var methods: String = ""

    @Option(help: "Comma-separated path prefixes under the provider prefix, e.g. /v1/messages. Default: any.")
    var paths: String = ""

    @Option(help: "Grant lifetime ceiling in minutes (1-1440). Default: \(Grant.defaultMinutes).")
    var minutes: Int = Grant.defaultMinutes

    @Option(name: .customLong("max-requests"), help: "Refuse further calls after this many, per grant.")
    var maxRequests: Int?

    @Option(name: .customLong("max-usd"), help: "Refuse further calls once a grant's spend passes this (checked after each call).")
    var maxUsd: Double?

    @Flag(help: "Grants under this profile are meant to run unattended (requires a cap).")
    var unattended = false

    @Flag(help: "Print the saved profile as JSON.")
    var json = false

    func run() throws {
        try run(service: AppFactory.makeService())
    }

    func run(service: KeysService) throws {
        let profile = try service.addProfile(
            ProfileRequest(
                name: name,
                keys: Self.list(keys),
                methods: methods.isEmpty ? Grant.allMethods : Set(Self.list(methods)),
                paths: Self.list(paths),
                minutes: minutes,
                maxRequests: maxRequests,
                maxUsd: maxUsd,
                unattended: unattended
            ),
            caller: "cli"
        )
        if json {
            try JSONValue.printLine(profile.jsonObject())
            return
        }
        print("profile \(profile.name) saved")
        print("  keys     \(profile.keys.joined(separator: ","))")
        let methodsOut = profile.methods == Grant.allMethods ? "all" : profile.methods.sorted().joined(separator: ",")
        print("  scope    methods \(methodsOut)  paths \(profile.paths.isEmpty ? "any" : profile.paths.joined(separator: ","))")
        print("  ceiling  \(Self.ceiling(profile))")
        print("  grant    keys grant <key> --profile \(profile.name)")
    }

    /// A comma-separated flag's items, trimmed, empties dropped.
    static func list(_ csv: String) -> [String] {
        csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The bounds in the audit-detail wording, so the same numbers read everywhere.
    static func ceiling(_ profile: Profile) -> String {
        var parts = ["\(profile.minutes) min"]
        if let n = profile.maxRequests { parts.append("max \(n) req") }
        if let u = profile.maxUsd { parts.append(String(format: "max $%.2f", u)) }
        if profile.unattended { parts.append("unattended") }
        return parts.joined(separator: " · ")
    }
}

struct ProfileListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved profiles.")

    @Flag(help: "Print the profiles as JSON, the same objects the dashboard serves.")
    var json = false

    func run() throws {
        try run(service: AppFactory.makeService())
    }

    func run(service: KeysService) throws {
        let profiles = try service.listProfiles()
        if json {
            try JSONValue.printLine(profiles.map { $0.jsonObject() })
            return
        }
        if profiles.isEmpty {
            print("no profiles")
            return
        }
        print("NAME\tKEYS\tSCOPE\tCEILING")
        for p in profiles {
            let methods = p.methods == Grant.allMethods ? "all" : p.methods.sorted().joined(separator: ",")
            let paths = p.paths.isEmpty ? "any" : p.paths.joined(separator: ",")
            print("\(p.name)\t\(p.keys.joined(separator: ","))\t\(methods) \(paths)\t\(ProfileAddCommand.ceiling(p))")
        }
    }
}

struct ProfileRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a saved profile (grants already issued keep their scope)."
    )

    @Argument(help: "Profile name from keys profile list.")
    var name: String

    func run() throws {
        try run(service: AppFactory.makeService())
    }

    func run(service: KeysService) throws {
        _ = try service.removeProfile(name: name, caller: "cli")
        print("removed profile \(name)")
    }
}

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Read-only connection check against the key's provider (user presence, no generation)."
    )

    @Argument var name: String
    @Flag var json = false

    func run() throws {
        let service = try AppFactory.makeService()
        let result = try service.checkProvider(name: name, caller: "test")
        if json {
            try JSONValue.printLine(result.jsonObject())
        } else {
            let providerName = Providers.provider(id: result.provider)?.name ?? result.provider
            print("\(result.ok ? "ok" : "FAIL")  \(name) -> \(providerName) (\(result.host))  \(result.summary)")
            print("checked \(result.checkedAt)" + (result.endpoint.map { "  GET \($0)" } ?? ""))
            if result.ok { print("models: keys models \(name) --cached") }
        }
        if !result.ok { Darwin.exit(result.outcome.cliExitCode) }
    }
}

struct ModelsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List the provider's model IDs for a key; --cached reuses the last check with no prompt."
    )

    @Argument var name: String
    @Option(help: "Only IDs containing this text (case-insensitive).")
    var grep: String?
    @Flag(help: "Reuse the last check instead of asking the provider again.")
    var cached = false
    @Flag var json = false

    func run() throws {
        let service = try AppFactory.makeService()
        let result: ProviderCheck.Result
        if cached {
            guard let last = try service.lastCheck(name: name) else {
                throw AppError.usage("no check recorded for \(name); run keys test \(name) or keys models \(name)")
            }
            result = last
        } else {
            result = try service.checkProvider(name: name, caller: "models")
        }
        var ids = result.models
        if let grep, !grep.isEmpty {
            ids = ids.filter { $0.localizedCaseInsensitiveContains(grep) }
        }
        if json {
            var obj = result.jsonObject()
            obj["models"] = ids
            obj["model_count"] = ids.count
            try JSONValue.printLine(obj)
            if !result.ok { Darwin.exit(5) }
            return
        }
        guard result.ok else {
            let providerName = Providers.provider(id: result.provider)?.name ?? result.provider
            print("FAIL  \(name) -> \(providerName) (\(result.host))  \(result.summary)")
            Darwin.exit(result.outcome.cliExitCode)
        }
        for id in ids { print(id) }
        fputs("\(ids.count) of \(result.models.count) models  checked \(result.checkedAt)\(cached ? " (cached)" : "")\n", stderr)
    }
}

struct DashboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dashboard",
        abstract: "Open the local Keysrs site on 127.0.0.1."
    )

    @Flag var month = false
    @Flag var week = false

    func run() throws {
        if month && week { throw AppError.usage("choose --month or --week") }
        let range = week ? "week" : "month"
        let service = try AppFactory.makeService()
        let server = try LoopbackSite.bind(service: service, preferredPort: LoginItem.dashboardPort)
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/?range=\(range)")!
        let line = "Keysrs  \(url.absoluteString)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        fflush(stdout)
        if !Paths.noOpenBrowser() {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.global(qos: .utility).async {
            _ = try? service.ingest(.all)
            try? service.pollOpenRouter()
        }
        IngestScheduler.scheduleRepeating(service: service)
        OpenRouterScheduler.schedule(service: service)
        RunLoop.main.run()
    }
}

struct MenubarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menubar",
        abstract: "Plan-window usage in the macOS menu bar."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let server = try LoopbackSite.bind(service: service, preferredPort: LoginItem.menubarPort)
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/?range=month")!
        let line = "Keysrs menubar  \(url.absoluteString)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        fflush(stdout)
        DispatchQueue.global(qos: .utility).async {
            _ = try? service.ingest(.all)
            try? service.pollOpenRouter()
        }
        runOnMainActor {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            IngestScheduler.scheduleRepeating(service: service)
            OpenRouterScheduler.schedule(service: service)
            let extra = MenubarExtra(service: service, server: server, url: url)
            MenubarRuntime.extra = extra
            app.delegate = extra
            app.run()
        }
    }
}

struct AutostartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autostart",
        abstract: "Remove a legacy login item; configure Start at Login inside Keysrs.app."
    )

    @Flag(name: [.customLong("remove"), .customLong("uninstall")], help: "Unload and delete the login item and its snapshot.")
    var remove = false

    func run() throws {
        if remove {
            try Installer.live.uninstall()
            print("removed login item \(LoginItem.label)")
            return
        }
        throw AppError.usage("Open Keysrs.app and choose Start at Login from the Keysrs menu. Use autostart --remove only to remove a legacy installation.")
    }
}

struct ClientCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "client",
        abstract: "Issue, list or revoke gateway client capabilities for a key.",
        subcommands: [ClientIssueCommand.self, ClientListCommand.self, ClientRevokeCommand.self],
        defaultSubcommand: ClientListCommand.self
    )
}

struct ClientIssueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issue",
        abstract: "Mint a revocable, expiring token an SDK presents to the gateway (user presence). Shown once."
    )

    @Argument(help: "Key name.") var name: String
    @Option(help: "What this client is, e.g. the app or script name.") var label: String = ""
    @Option(help: "Days until the token expires (1 to \(GatewayClientToken.maxDays)).") var days: Int = GatewayClientToken.defaultDays
    @Option(name: .customLong("method"), help: "Allowed HTTP method; repeat for more. Default POST.") var methods: [String] = []
    @Option(name: .customLong("path-prefix"), help: "Only this upstream path prefix, e.g. v1/messages.") var pathPrefix: String?

    func run() throws {
        try KeyName.validate(name)
        // A token is only useful once the gateway holds the key, and only the process that
        // owns the gateway can turn it on, so the running app issues it under one prompt.
        let token: String, id: Int64, scope: String, expires: String
        var note = ""
        if let control = try? ControlClient.connect() {
            fputs("Touch ID in Keysrs…\n", stderr)
            var body: [String: Any] = ["label": label, "days": days, "gateway": true, "caller": "cli"]
            if !methods.isEmpty { body["methods"] = methods }
            if let pathPrefix { body["path_prefix"] = pathPrefix }
            let obj = try control.call(method: "POST", path: "/api/keys/\(name)/clients", body: body, expect: 201)
            let client = JSONValue.object(obj["client"]) ?? [:]
            token = JSONValue.string(obj["token"]) ?? ""
            guard !token.isEmpty else { throw AppError.usage("the site returned no token") }
            id = Int64(JSONValue.int(client["id"]) ?? 0)
            scope = ((client["methods"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ",") ?? "")
                + " " + (JSONValue.string(client["path_prefix"]) ?? "*")
            expires = JSONValue.string(client["expires_at"]) ?? ""
            if JSONValue.bool(obj["gateway_enabled"]) != true {
                note = " The running Keysrs.app did not turn the gateway on; run: keys gateway on \(name)"
            }
        } else {
            let service = try AppFactory.makeService()
            let issued = try service.issueGatewayClient(
                name: name, label: label, days: days, methods: methods.isEmpty ? nil : methods,
                pathPrefix: pathPrefix, caller: "cli"
            )
            token = issued.token
            id = issued.client.id
            scope = issued.client.methods.joined(separator: ",") + " " + (issued.client.pathPrefix ?? "*")
            expires = issued.client.expiresAt
            note = " Keysrs is not running, so the gateway is off; open it, then run: keys gateway on \(name)"
        }
        print(token)
        FileHandle.standardError.write(Data(
            "client #\(id) for \(name), \(scope), expires \(expires). Put it where the SDK expects the API key; base URL http://127.0.0.1:\(GatewayListener.port)/\(name).\(note)\n".utf8
        ))
    }
}

struct ClientListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a key's gateway clients.")

    @Argument(help: "Key name.") var name: String

    func run() throws {
        let service = try AppFactory.makeService()
        let now = Date()
        for c in try service.gatewayClients(name: name) {
            let state = c.revokedAt != nil ? "revoked" : (c.isActive(now: now) ? "active" : "expired")
            print("#\(c.id)\t…\(c.hint)\t\(state)\t\(c.methods.joined(separator: ","))\t\(c.pathPrefix ?? "*")\texpires \(c.expiresAt)\tlast \(c.lastUsedAt ?? "-")\t\(c.label)")
        }
    }
}

struct ClientRevokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Revoke one gateway client.")

    @Argument(help: "Key name.") var name: String
    @Argument(help: "Client id from `keys client list`.") var id: Int64

    func run() throws {
        let service = try AppFactory.makeService()
        let c = try service.revokeGatewayClient(name: name, id: id, caller: "cli")
        print("revoked client #\(c.id) for \(name)")
    }
}

struct GatewayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gateway",
        abstract: "Turn the local gateway on or off for a key in the running Keysrs (on asks for Touch ID).",
        usage: "keys gateway on|off <key>, or keys gateway cheapest on|off <key>",
        discussion: """
            The gateway holds a key in the memory of the running app only, so it forgets every \
            key when Keysrs quits; client tokens stay valid but are refused until the key is \
            turned on again. Off also revokes the key's active grants.

            cheapest on makes the gateway ask an aggregator for its lowest-priced upstream \
            provider on each JSON call through this key (OpenRouter provider.sort "price", \
            Vercel AI Gateway providerOptions.gateway.sort "cost"), unless the call already \
            names a routing preference. Off by default; other providers refuse it.
            """
    )

    @Argument(help: "on, off or cheapest.") var state: String
    @Argument(help: "Key name (after cheapest: on or off).") var name: String
    @Argument(help: "After cheapest on|off: the key name.") var key: String?

    func run() throws {
        if state.lowercased() == "cheapest" {
            try runCheapest()
            return
        }
        let enabled: Bool
        switch state.lowercased() {
        case "on": enabled = true
        case "off": enabled = false
        default: throw AppError.usage("say on or off, e.g. keys gateway on \(name)")
        }
        if key != nil { throw AppError.usage("usage: keys gateway on|off <key>") }
        try KeyName.validate(name)
        let control = try ControlClient.connect()
        if enabled { fputs("Touch ID in Keysrs…\n", stderr) }
        let obj = try control.call(method: "POST", path: "/api/keys/\(name)/gateway", body: ["enabled": enabled], expect: 200)
        if enabled {
            print("gateway on for \(name): \(JSONValue.string(obj["gateway_url"]) ?? "http://127.0.0.1:\(GatewayListener.port)/\(name)")")
        } else {
            print("gateway off for \(name); its grants are revoked, client tokens are refused until it is on again")
        }
    }

    private func runCheapest() throws {
        let enabled: Bool
        switch name.lowercased() {
        case "on": enabled = true
        case "off": enabled = false
        default: throw AppError.usage("usage: keys gateway cheapest on|off <key>")
        }
        guard let key else { throw AppError.usage("usage: keys gateway cheapest on|off <key>") }
        try KeyName.validate(key)
        let control = try ControlClient.connect()
        _ = try control.call(method: "POST", path: "/api/keys/\(key)/cheapest", body: ["enabled": enabled], expect: 200)
        print(enabled
            ? "cheapest upstream on for \(key): calls that pick no provider ask for the lowest price"
            : "cheapest upstream off for \(key): calls go upstream as sent")
    }
}

struct WrapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrap",
        abstract: "Swap the provider keys in an env file for gateway client tokens (one Touch ID).",
        usage: "keys wrap <path-to-env-file> [--dry-run] [--yes] [--relay <worker url>] [--label <text>] [--days N]",
        discussion: """
            Finds values that look like provider keys, matches each to a vault key by comparing \
            secrets inside the running Keysrs (values are never printed), and offers to add the \
            ones the vault lacks under a suggested name. After you confirm the plan, each key \
            gets the gateway turned on and one client token, the value in the file becomes that \
            token, and OPENAI_BASE_URL, ANTHROPIC_BASE_URL or GROQ_BASE_URL is set to the \
            gateway (or to the relay with --relay) where the key's variable has one. The file is \
            backed up first beside itself (0600, holding the original values), replaced in one \
            rename with its permissions kept, and always ends with a newline. Comments, blank \
            lines, export and quotes stay as written. The Touch ID comes before the plan, because \
            telling an existing key from a new one means reading the vault; --dry-run stops after \
            the plan. Needs the running Keysrs.app, which owns the gateway.
            """
    )

    @Argument(help: "The env file to rewrite.") var path: String
    @Flag(name: .customLong("dry-run"), help: "Show the plan; add nothing, issue nothing, change nothing.") var dryRun = false
    @Flag(help: "Do not ask before applying the plan.") var yes = false
    @Option(help: "Your relay Worker's URL; base URLs then point at it instead of 127.0.0.1.") var relay: String?
    @Option(help: "Label for the client tokens. Default: keys wrap <file>.") var label: String = ""
    @Option(help: "Days until the tokens expire (1 to \(GatewayClientToken.maxDays)).") var days: Int = GatewayClientToken.defaultDays

    func run() throws {
        var options = WrapRunner.Options(file: URL(fileURLWithPath: path))
        options.dryRun = dryRun
        options.yes = yes
        options.relay = try relay.map(RelayURL.validate)
        options.label = label
        options.days = try GatewayClientToken.validateDays(days)
        if !dryRun, !yes, isatty(STDIN_FILENO) == 0 {
            throw AppError.usage("keys wrap asks before changing the file; pass --yes when stdin is not a terminal")
        }
        let runner = WrapRunner(
            backend: ControlWrapBackend(connect: { try ControlClient.connect() }),
            out: { print($0); fflush(stdout) },
            confirm: {
                fputs("Apply this plan? [y/N] ", stderr)
                fflush(stderr)
                let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return answer == "y" || answer == "yes"
            }
        )
        _ = try runner.run(options)
    }
}

struct PurgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Delete the catalog and every Keychain item for this app (user presence)."
    )

    func run() throws {
        fputs("Type purge to confirm: ", stderr)
        fflush(stderr)
        let answer = readLine(strippingNewline: true) ?? ""
        let service = try AppFactory.makeService()
        try service.purge(confirmation: answer)
        print("purged catalog and keychain service keysreallysafe")
    }
}

// MARK: - Providers (the catalog keys point at)

struct ProvidersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List the provider catalog: the shipped entries plus yours."
    )

    @Flag var json = false

    func run() throws {
        let service = try AppFactory.makeService()
        let listing = try service.providersJSONObject()
        if json {
            try JSONValue.printLine(listing)
            return
        }
        let providers = (listing["providers"] as? [Any])?.compactMap { JSONValue.object($0) } ?? []
        if providers.isEmpty {
            print("no providers loaded")
            return
        }
        print("ID\tNAME\tGROUP\tHOST\tGATEWAY\tSTATE")
        for p in providers {
            let id = JSONValue.string(p["id"]) ?? ""
            let name = JSONValue.string(p["name"]) ?? id
            let group = JSONValue.string(p["group"]) ?? "-"
            let host = JSONValue.string(p["host"]) ?? "-"
            let gateway = (JSONValue.bool(p["gateway"]) ?? true) ? "yes" : "no"
            let custom = JSONValue.bool(p["custom"]) ?? false
            let hidden = JSONValue.string(p["hidden"]) ?? ""
            let state = custom ? "yours" : (hidden.isEmpty ? "built-in" : hidden == "app" ? "retired" : "hidden")
            print("\(id)\t\(name)\t\(group)\t\(host)\t\(gateway)\t\(state)")
        }
    }
}

struct ProviderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Add, remove or hide a provider.",
        subcommands: [
            ProviderAddCommand.self,
            ProviderRmCommand.self,
            ProviderHideCommand.self,
            ProviderUnhideCommand.self,
        ]
    )
}

struct ProviderAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a provider to the catalog (routing metadata, never a secret).",
        usage: "keys provider add <id> --name <name> [--host <host>] [options]",
        discussion: """
            A provider is how the gateway forwards and prices a key. Yours live in the catalog \
            beside your keys and survive restarts; an id that matches a shipped entry wins over \
            it, which is how a wrong host gets fixed without waiting for a release. `api` picks \
            the usage parser: openai (chat-completions and responses), anthropic (messages), \
            gemini (generateContent) or other (requests are counted, tokens are not).
            """
    )

    @Argument(help: "Provider id: lowercase letters, digits and dashes, e.g. my-gateway.") var id: String
    @Option(help: "Display name.") var name: String
    @Option(help: "API host, e.g. api.example.com. Omit when each account has its own.") var host: String?
    @Option(help: "Usage parser: openai, anthropic, gemini or other. Default other.") var api: String = "other"
    @Option(name: .customLong("auth-header"), help: "Header the secret goes into. Default Authorization.") var authHeader: String = "Authorization"
    @Option(name: .customLong("auth-prefix"), help: "Prefix in front of the secret, e.g. \"Bearer \". Default \"Bearer \".") var authPrefix: String = "Bearer "
    @Option(name: .customLong("path-prefix"), help: "Prefix added to the client's path, e.g. v1.") var pathPrefix: String = ""
    @Option(name: .customLong("key-prefix"), help: "Secret prefix hint for the Add dialog, e.g. sk-.") var keyPrefix: String?
    @Option(help: "Shown when the provider asks for a per-account host.") var note: String?
    @Flag(name: .customLong("no-gateway"), help: "The vendor needs request signing or OAuth, so it cannot be proxied.") var noGateway = false

    func run() throws {
        let payload: [String: Any] = [
            "id": id,
            "name": name,
            "host": host as Any? ?? NSNull(),
            "api": api,
            "auth_header": authHeader,
            "auth_prefix": authPrefix,
            "path_prefix": pathPrefix,
            "key_prefix": keyPrefix as Any? ?? NSNull(),
            "note": note as Any? ?? NSNull(),
            "gateway": !noGateway,
        ]
        let service = try AppFactory.makeService()
        if let client = try? ControlClient.connect(),
           (try? client.call(method: "POST", path: "/api/providers", body: payload, expect: 201)) != nil {
            print("added provider \(id)")
            return
        }
        // A live site that answered with an error would have thrown above; either way the
        // direct write reports the real problem.
        _ = try service.addProvider(
            id: id, name: name, host: host, api: api, authHeader: authHeader, authPrefix: authPrefix,
            pathPrefix: pathPrefix, keyPrefix: keyPrefix, note: note, gateway: !noGateway
        )
        print("added provider \(id)")
        fputs("no Keysrs site is running; it takes effect when one next starts\n", stderr)
    }
}

struct ProviderRmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a provider you added. Built-in ones are hidden instead."
    )

    @Argument(help: "Provider id.") var id: String

    func run() throws {
        let service = try AppFactory.makeService()
        if let client = try? ControlClient.connect(),
           (try? client.call(method: "DELETE", path: "/api/providers/\(id)", expect: 200)) != nil {
            print("removed provider \(id)")
            return
        }
        try service.removeProvider(id: id)
        print("removed provider \(id)")
        fputs("no Keysrs site is running; it takes effect when one next starts\n", stderr)
    }
}

struct ProviderHideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Take a built-in provider out of the Add dialog. Keys using it keep working."
    )

    @Argument(help: "Provider id.") var id: String

    func run() throws {
        try ProviderHideCommand.setHidden(true, id: id)
    }

    /// A hide change goes through the running site when one is up, the same way grants do,
    /// so its view of the catalog changes with the database.
    static func setHidden(_ hidden: Bool, id: String) throws {
        let service = try AppFactory.makeService()
        if let client = try? ControlClient.connect(),
           (try? client.call(method: "PATCH", path: "/api/providers/\(id)", body: ["hidden": hidden], expect: 200)) != nil {
            print(hidden ? "hid provider \(id)" : "unhid provider \(id)")
            return
        }
        try service.setProviderHidden(id: id, hidden: hidden)
        print(hidden ? "hid provider \(id)" : "unhid provider \(id)")
    }
}

struct ProviderUnhideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unhide",
        abstract: "Put a hidden built-in provider back into the Add dialog."
    )

    @Argument(help: "Provider id.") var id: String

    func run() throws {
        try ProviderHideCommand.setHidden(false, id: id)
    }
}

// MARK: - Coding agents (setup and launch)

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Launch a coding agent with a vault key behind the local gateway (one Touch ID).",
        usage: "keys agent <agent> <key> [--minutes N] [--profile <name>] [--client] [--label <text>] [--] [args...]",
        discussion: """
            Claude Code, Codex, Grok and Droid are supported. One Touch ID mints a grant; the \
            agent gets the gateway's URL and the grant token where it expects an API key, and \
            the raw secret never leaves the vault. The grant is revoked when the agent exits, \
            and also dies on screen lock or expiry. Run `keys setup <agent> --key <key>` once \
            first for codex, grok and droid; Claude Code needs no setup. With --profile the \
            grant issues within the saved profile's bounds and the prompt names them; the \
            agent's methods (GET and POST) must sit inside the profile, so a mismatched one \
            is refused before any prompt.
            """
    )

    @Argument(help: "claude, codex, grok or droid.") var agent: String
    @Argument(help: "Vault key name.") var key: String
    @Option(help: "Grant life in minutes (1-1440). Default \(CodingAgent.grantMinutes); with --profile, the profile's minutes unless you set --minutes.") var minutes: Int?
    @Flag(help: "Mint a long-lived client token instead of a grant; it survives this launch (30 days).") var client = false
    @Option(help: "Issue the grant within this saved profile's bounds (keys profile list).") var profile: String?
    @Option(help: "Label for the client token with --client.") var label: String = ""
    @Argument(parsing: .remaining, help: "Arguments passed to the agent after --.") var args: [String] = []

    mutating func validate() throws {
        // A client token is long-lived and uncapped by design; --profile bounds grants only,
        // so naming both is a mistake to surface, not a flag to quietly ignore.
        if client, profile != nil {
            throw ValidationError("--client mints a client token, not a grant, so --profile does not apply; drop one of the two")
        }
    }

    func run() throws {
        let agent = try CodingAgent.parse(agent)
        try KeyName.validate(key)
        let service = try AppFactory.makeService()
        guard let row = try service.list().first(where: { $0.name == key }) else { throw AppError.notFound(key) }
        guard let provider = Providers.provider(id: row.provider) else {
            throw AppError.usage("unknown provider \(row.provider); edit the key and pick one from the list")
        }
        guard agent.supportedAPIs.contains(provider.api) else {
            throw AppError.usage(
                "\(agent.displayName) speaks the \(agent.supportedAPIs.sorted().joined(separator: "/")) wire; "
                    + "\(key) is a \(provider.name) key (\(provider.api)). "
                    + "Supported: \(CodingAgent.allCases.map(\.displayName).joined(separator: ", "))."
            )
        }
        if let home = agent.configHome {
            let problem: String?
            switch agent {
            case .codex: problem = CodexSetup.verify(home: home, key: key, port: GatewayListener.port)
            case .grok: problem = GrokSetup.verify(home: home, key: key, port: GatewayListener.port)
            case .droid: problem = DroidSetup.verify(home: home, key: key, port: GatewayListener.port)
            case .claude: problem = nil
            }
            if let problem { throw AppError.usage(problem) }
        }

        let token: String
        var grantID: String?
        if client {
            let issued = try service.issueGatewayClient(
                name: key,
                label: label.isEmpty ? "\(agent.displayName) on this Mac" : label,
                days: GatewayClientToken.defaultDays,
                methods: ["POST", "GET"],
                pathPrefix: nil,
                caller: "agent"
            )
            token = issued.token
            fputs(
                "client #\(issued.client.id) for \(key) expires \(issued.client.expiresAt); "
                    + "revoke with: keys client revoke \(key) \(issued.client.id)\n",
                stderr
            )
        } else {
            let control = try ControlClient.connect()
            fputs("Touch ID in the Keysrs site…\n", stderr)
            let obj = try control.call(
                method: "POST", path: "/api/keys/\(key)/grants",
                body: Self.grantBody(agent: agent, minutes: minutes, profile: profile),
                expect: 201
            )
            token = JSONValue.string(obj["token"]) ?? ""
            grantID = JSONValue.string(obj["id"])
            guard !token.isEmpty else { throw AppError.usage("the site returned no token") }
        }

        let env = agent.launchEnv(key: key, port: GatewayListener.port, token: token)
        fputs(
            "launching \(agent.executable) with \(key) (\(provider.name)) behind http://127.0.0.1:\(GatewayListener.port)/\(key)\n",
            stderr
        )
        let ended = try Self.launch(runner: service.runner, argv: [agent.executable] + args, env: env) {
            guard let grantID else { return }
            // The session is over; nothing should keep the token alive. A short timeout, since
            // keys ignores Ctrl-C until it exits.
            if let control = try? ControlClient.connect() {
                _ = try? control.call(method: "DELETE", path: "/api/grants/\(grantID)", expect: 200, timeout: 10)
            }
        }
        ended.exitProcess()
    }

    /// Runs the agent, then `cleanup` however it ended: a normal exit, a signal (Ctrl-C, a
    /// closed terminal), or a launch that never started, so the grant does not outlive it.
    static func launch(
        runner: any CommandRunner, argv: [String], env: [String: String], cleanup: () -> Void
    ) throws -> ChildExit {
        defer { cleanup() }
        return try runner.run(argv: argv, extraEnv: env)
    }

    /// The grant ask the agent path sends to the site. Methods are the agent's functional
    /// needs (model lists and completions), named explicitly so a profile that lacks them is
    /// refused before the prompt instead of launching an agent whose calls would all fail.
    /// Minutes ride only when --minutes was given, so under a profile the profile's lifetime
    /// is the default; without one the agent's long default stays, as before.
    static func grantBody(agent: CodingAgent, minutes: Int?, profile: String?) -> [String: Any] {
        var body: [String: Any] = ["task": agent.task, "methods": ["GET", "POST"], "caller": "agent"]
        if let minutes {
            body["minutes"] = minutes
        } else if profile == nil {
            body["minutes"] = CodingAgent.grantMinutes
        }
        if let profile { body["profile"] = profile }
        return body
    }
}

struct McpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the Keysrs tools to an MCP client over stdio until stdin closes."
    )

    func run() throws {
        MCPRun.runStdio()
    }
}

/// The stdio wiring of `keys mcp`: real stdin/stdout/stderr and the shutdown
/// handlers. Everything testable lives in `MCPServer` behind the injected seam;
/// this holds no logic (the `UsageImportRun.run` precedent).
enum MCPRun {
    static func runStdio() -> Never {
        // Writing to a closed stdout must fail quietly, not kill the process.
        signal(SIGPIPE, SIG_IGN)
        // SIGINT and SIGTERM end the session the documented way: exit 0 (the
        // RelayRunCommand precedent). The handlers fire from their own queue while
        // the main thread is blocked reading stdin.
        let signals: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
            source.setEventHandler { Darwin.exit(0) }
            source.resume()
            return source
        }
        // `availableData` returns whatever has arrived (empty at EOF); `read(upToCount:)`
        // would block on a pipe until the full count or EOF, and a live client keeps
        // stdin open, so the server would never see its lines.
        var lines = MCPLineSource(read: {
            let chunk = FileHandle.standardInput.availableData
            return chunk.isEmpty ? nil : chunk
        })
        var server = MCPServer(
            write: { FileHandle.standardOutput.write($0) },
            note: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            registry: MCPToolRegistry.default
        )
        withExtendedLifetime(signals) {
            server.run(next: { lines.next() })
        }
        // stdin EOF is the primary graceful shutdown: flush and exit 0.
        Darwin.exit(0)
    }
}

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Write a coding agent's config so it runs on a vault key through the local gateway.",
        usage: "keys setup <agent> [--key <name>] [--model <id>] [--display-name <text>] [--wire <kind>] [--set-default] [--json]",
        discussion: """
            Writes the agent's own config file, with a backup beside it: the gateway base URL \
            for the key and the name of the environment variable `keys agent` fills with a \
            fresh token at launch. No secret is ever written to a file. Droid gets a customModels \
            entry in ~/.factory/settings.json, Codex a model_providers.keysrs block in \
            ~/.codex/config.toml, Grok a model.keysrs block in ~/.grok/config.toml. Claude Code \
            reads its base URL and token from the environment, so it needs no file.
            """
    )

    @Argument(help: "claude, codex, grok or droid.") var agent: String
    @Option(help: "Vault key name; defaults to the only key when there is exactly one.") var key: String?
    @Option(help: "Model id the agent requests. Defaults to claude-sonnet-4-5-20250929 for Anthropic keys.") var model: String?
    @Option(name: .customLong("display-name"), help: "Name the agent's model picker shows. Default: Keysrs <key>.") var displayName: String?
    @Option(help: "Wire format override (droid: anthropic|openai|generic-chat-completion-api, codex: chat|responses).") var wire: String?
    @Flag(name: .customLong("set-default"), help: "Codex only: also make keysrs the default provider and set the model.") var setDefault = false
    @Flag(help: "Print one JSON line naming the config written, the token variable and the gateway URL, for a script to read.")
    var json = false

    func run() throws {
        let agent = try CodingAgent.parse(agent)
        let service = try AppFactory.makeService()
        let rows = try service.list()
        let row: CatalogRow
        if let key {
            try KeyName.validate(key)
            guard let found = rows.first(where: { $0.name == key }) else { throw AppError.notFound(key) }
            row = found
        } else if rows.count == 1 {
            row = rows[0]
        } else if rows.isEmpty {
            throw AppError.usage("no keys in the vault yet; add one first: keys add <name> --provider <provider>")
        } else {
            throw AppError.usage("name the key with --key (\(rows.map(\.name).joined(separator: ", ")))")
        }
        guard let provider = Providers.provider(id: row.provider) else {
            throw AppError.usage("unknown provider \(row.provider); edit the key and pick one from the list")
        }
        guard agent.supportedAPIs.contains(provider.api) else {
            throw AppError.usage(
                "\(agent.displayName) speaks the \(agent.supportedAPIs.sorted().joined(separator: "/")) wire; "
                    + "\(row.name) is a \(provider.name) key (\(provider.api))"
            )
        }
        let model = try resolveModel(agent: agent, provider: provider, keyName: row.name)

        switch agent {
        case .claude:
            if json {
                try JSONValue.printLine(Self.jsonObject(Report(agent: agent, key: row.name)))
                return
            }
            let base = "http://127.0.0.1:\(GatewayListener.port)/\(row.name)"
            print("Claude Code needs no config file; it reads two variables at launch.")
            print("Either launch it through the vault (recommended, one Touch ID, no secret in the environment file):")
            print("  keys agent claude \(row.name)")
            print("Or export and run claude yourself with a token from: keys grant \(row.name)")
            print("  export ANTHROPIC_BASE_URL=\(base)")
            print("  export ANTHROPIC_AUTH_TOKEN=<grant or client token>")
        case .codex:
            let kind = try CodingAgent.codexWire(for: provider, override: wire)
            let home = agent.configHome!
            try CodexSetup.upsert(
                home: home, key: row.name, port: GatewayListener.port, wire: kind,
                setDefault: setDefault, model: setDefault ? model : nil
            )
            let url = CodexSetup.configURL(home: home)
            if json {
                try JSONValue.printLine(Self.jsonObject(Report(
                    agent: agent, key: row.name, configPath: url.path,
                    model: setDefault ? model : nil, wire: kind, setDefault: setDefault
                )))
                return
            }
            print("wrote [\(CodexSetup.section)] in \(url.path)")
            print(SetupCommand.backupNote(for: url))
            if setDefault {
                print("keysrs is now the default provider, model \(model)")
            } else {
                print("make it the default with: keys setup codex --key \(row.name) --model \(model) --set-default")
            }
            print("launch with: keys agent codex \(row.name) -- codex")
        case .grok:
            let home = agent.configHome!
            try GrokSetup.upsert(home: home, key: row.name, port: GatewayListener.port, model: model)
            let url = GrokSetup.configURL(home: home)
            if json {
                try JSONValue.printLine(Self.jsonObject(Report(
                    agent: agent, key: row.name, configPath: url.path, model: model
                )))
                return
            }
            print("wrote [\(GrokSetup.section)] in \(url.path)")
            print(SetupCommand.backupNote(for: url))
            print("pick the model \"\(displayName ?? "Keysrs gateway")\" in grok (grok models lists it)")
            print("launch with: keys agent grok \(row.name) -- grok")
        case .droid:
            let kind = try CodingAgent.droidProviderKind(for: provider, override: wire)
            let name = displayName ?? "Keysrs \(row.name)"
            try DroidSetup.upsert(
                home: agent.configHome!, key: row.name, port: GatewayListener.port, model: model,
                displayName: name, providerKind: kind, liveKeyNames: Set(rows.map(\.name))
            )
            let url = DroidSetup.settingsURL(home: agent.configHome!)
            if json {
                try JSONValue.printLine(Self.jsonObject(Report(
                    agent: agent, key: row.name, configPath: url.path,
                    model: model, wire: kind, displayName: name
                )))
                return
            }
            print("wrote a customModels entry in \(url.path)")
            print(SetupCommand.backupNote(for: url))
            print("launch with: keys agent droid \(row.name) -- droid, then pick \"\(name)\" with /model")
            print("unattended (headless droid exec): keys client issue \(row.name) --label droid --days 90, then export \(CodingAgent.droid.tokenVar!)=…")
        }
    }

    /// A first write has no previous file to keep; the promise of a backup starts with the second.
    static func backupNote(for url: URL) -> String {
        FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path)
            ? "your previous file is kept beside it as a .bak"
            : "edits from here on keep a .bak beside it"
    }

    /// What one setup wrote, gathered so both output paths report the same step. A field
    /// the agent's config does not carry stays nil, and the JSON leaves it out rather
    /// than guessing — a present key is a fact, the same rule the status JSON follows.
    struct Report {
        let agent: CodingAgent
        let key: String
        var port: UInt16 = GatewayListener.port
        var configPath: String?
        var model: String?
        var wire: String?
        var displayName: String?
        var setDefault: Bool?
    }

    /// The one JSON line, sorted keys, that every `--json` flag prints: the file that was
    /// written, the environment variable the launcher fills with a token, and the gateway
    /// URL — what a script needs to verify the step without parsing prose. Claude Code
    /// writes no file, so its `config_path` is null and the two variables it reads at
    /// launch stand in for it. Codex's model appears only under `--set-default`, the one
    /// case that writes it.
    static func jsonObject(_ report: Report) -> [String: Any] {
        var entry: [String: Any] = [
            "agent": report.agent.rawValue,
            "base_url": "http://127.0.0.1:\(report.port)/\(report.key)",
            "config_path": report.configPath ?? NSNull(),
            // Claude Code reads its token from ANTHROPIC_AUTH_TOKEN, its own variable;
            // the other agents get a Keysrs one named in their config.
            "token_env": report.agent.tokenVar ?? "ANTHROPIC_AUTH_TOKEN",
        ]
        if report.agent == .claude {
            entry["base_url_env"] = "ANTHROPIC_BASE_URL"
        }
        if let model = report.model { entry["model"] = model }
        if let wire = report.wire { entry["wire"] = wire }
        if let displayName = report.displayName { entry["display_name"] = displayName }
        if let setDefault = report.setDefault { entry["set_default"] = setDefault }
        return entry
    }

    private func resolveModel(agent: CodingAgent, provider: Providers.Record, keyName: String) throws -> String {
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.trimmingCharacters(in: .whitespaces)
        }
        if let fallback = CodingAgent.defaultModel(for: provider) {
            return fallback
        }
        throw AppError.usage("give --model for \(keyName) (\(provider.name)); list what the provider offers with: keys models \(keyName) --cached")
    }
}

struct TunnelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tunnel",
        abstract: "Forward the local gateway to a remote machine so an agent there can use the vault.",
        usage: "keys tunnel <user@host> [--remote-port N] [--key <name>] [--print]",
        discussion: """
            Runs ssh with a reverse forward: 127.0.0.1:<remote-port> on the remote host becomes \
            the gateway on this Mac. Nothing new listens on this Mac and the gateway keeps its \
            loopback bind; the ssh session is the trust boundary, and the remote still needs a \
            client token as its API key. Point the agent at http://127.0.0.1:<remote-port>/<key>. \
            Ctrl-C stops the tunnel.
            """
    )

    @Argument(help: "user@host to forward to, e.g. user@server.example.com.") var userHost: String
    @Option(name: .customLong("remote-port"), help: "Port on the remote host. Default \(GatewayListener.port).") var remotePort: Int = Int(GatewayListener.port)
    @Option(help: "Key the printed instructions should mention.") var key: String?
    @Flag(help: "Print the ssh command instead of running it.") var printOnly = false

    func run() throws {
        if let key { try KeyName.validate(key) }
        let argv = try Tunnel.argv(
            userHost: userHost, remotePort: remotePort, localPort: Int(GatewayListener.port)
        )
        try requireGatewayUp()
        let text = Tunnel.instructions(key: key, userHost: userHost, remotePort: remotePort, localPort: GatewayListener.port)
        if printOnly {
            print(argv.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
            print(text)
            return
        }
        fputs(text + "\nssh is running; Ctrl-C stops the tunnel.\n", stderr)
        let service = try AppFactory.makeService()
        try service.runner.run(argv: argv, extraEnv: [:]).exitProcess()
    }

    /// A tunnel to a closed port fails only when the remote side first uses it; refuse here
    /// instead, with the fix in the message.
    private func requireGatewayUp() throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(GatewayListener.port)/")!)
        req.timeoutInterval = 3
        do {
            _ = try BlockingHTTP.send(req, timeout: 3)
        } catch {
            throw Self.gatewayDown()
        }
    }

    /// The gateway-not-up failure, in one place so the wording and its exit code (6, like
    /// every other "no running site") are pinned by a test.
    static func gatewayDown() -> AppError {
        .siteUnavailable(
            "the gateway is not listening on 127.0.0.1:\(GatewayListener.port); "
                + "open Keysrs.app (or run keys dashboard) and turn the gateway on for the key first"
        )
    }
}

struct RelayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relay",
        abstract: "Reach the gateway from a managed cloud agent through a Worker you deploy yourself.",
        discussion: """
            Opens one outbound WebSocket from this Mac to the relay Worker in your own \
            Cloudflare account (Relay/ in the repository, docs/relay.md). The Worker frames \
            each agent request back here and keys relay replays it against the gateway on \
            127.0.0.1:\(GatewayListener.port), so every grant check, key swap and usage row \
            happens on this Mac exactly as for a local caller. The Worker never sees a key. \
            The agent calls https://<your worker>/<key name>/… with its ksfc_/ksf_ token. \
            keys relay on runs the relay inside Keysrs.app (also in its menu and in \
            Settings), where it lasts until turned off or the app quits; keys relay alone \
            runs it in this Terminal until Ctrl-C. Only one of them at a time: the Worker \
            keeps a single Mac connection.
            """,
        subcommands: [
            RelaySetupCommand.self, RelayRunCommand.self, RelayOnCommand.self, RelayOffCommand.self,
            RelayStatusCommand.self, RelayResetCommand.self, RelayPairCommand.self,
        ],
        defaultSubcommand: RelayRunCommand.self
    )

    /// The app's relay as the control socket reports it, in one line.
    static func appLine(_ obj: [String: Any]) -> String {
        guard JSONValue.bool(obj["on"]) == true else { return "off" }
        let host = JSONValue.string(obj["url"]).flatMap { URL(string: $0)?.host } ?? "the Worker"
        var line: String
        switch JSONValue.string(obj["state"]) {
        case "connected":
            line = "on, connected to \(host) since \(JSONValue.string(obj["connected_since"]) ?? "now")"
            let open = JSONValue.int(obj["inflight"]) ?? 0
            if open > 0 { line += ", \(open) call\(open == 1 ? "" : "s") open" }
        case "connecting":
            line = "on, connecting to \(host)"
        default:
            line = "on, not connected; retrying"
            if let error = JSONValue.string(obj["last_error"]) { line += " (\(error))" }
        }
        if JSONValue.bool(obj["awake"]) == true { line += ", keeping the Mac awake" }
        return line
    }

    /// The `pairing` line of `keys relay status`: the mode and the live count.
    static func pairingLine(required: Bool, active: Int) -> String {
        "\(required ? "required" : "off"), \(active) active"
    }
}

struct RelayPairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair remote agents with the relay: issue, list or revoke a pairing, or require pairing.",
        subcommands: [
            RelayPairIssueCommand.self, RelayPairListCommand.self,
            RelayPairRevokeCommand.self, RelayPairRequireCommand.self,
        ]
    )

    // No default verb: a bare `keys relay pair` is a usage error, never a connection attempt.
    func run() throws {
        throw AppError.usage("usage: keys relay pair issue|list|revoke|require … (see keys relay pair --help)")
    }
}

struct RelayPairIssueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issue",
        abstract: "Pair a remote agent with this Mac's relay (one Touch ID). The credential is shown once."
    )

    @Argument(help: "What this agent is, e.g. \"github actions\".") var label: String
    @Option(name: .customLong("key"), help: "Key the pairing may reach; repeat for more. Default: every key.") var keys: [String] = []
    @Option(help: "Days until the pairing expires (1 to \(RelayPairing.maxDays)). Default \(RelayPairing.defaultDays).") var days: Int = RelayPairing.defaultDays

    /// Bad arguments are refused here, so a mistyped command is answered before any app contact.
    func validate() throws {
        _ = try RelayPairing.validateDays(days)
        for key in keys { try KeyName.validate(key) }
    }

    func run() throws {
        let credential: String, hint: String, scope: [String], expires: String
        if let control = try? ControlClient.connect() {
            // The running app mints it under one Touch ID there, exactly like keys client issue.
            fputs("Touch ID in Keysrs…\n", stderr)
            var body: [String: Any] = ["label": label, "days": days]
            if !keys.isEmpty { body["keys"] = keys }
            let obj = try control.call(method: "POST", path: "/api/relay/pairings", body: body, expect: 201)
            credential = JSONValue.string(obj["credential"]) ?? ""
            guard !credential.isEmpty else { throw AppError.usage("the site returned no credential") }
            let pairing = JSONValue.object(obj["pairing"]) ?? [:]
            hint = JSONValue.string(pairing["hint"]) ?? ""
            scope = (pairing["keys"] as? [Any])?.compactMap { $0 as? String } ?? []
            expires = JSONValue.string(pairing["expires_at"]) ?? ""
        } else {
            let service = try AppFactory.makeService()
            let issued = try service.issueRelayPairing(label: label, keys: keys, days: days)
            credential = issued.credential
            hint = issued.pairing.hint
            scope = issued.pairing.keys
            expires = issued.pairing.expiresAt ?? ""
        }
        print(credential)
        FileHandle.standardError.write(Data(("""
        pairing "\(label)" (…\(hint)), \(scope.isEmpty ? "all keys" : "keys: " + scope.joined(separator: ", ")), expires \(expires).
        The credential is shown once; the agent sends it on every relayed request as a header:
          X-KSF-Pair: <credential>
        Refusals only bite while pairing is required: keys relay pair require on

        """).utf8))
    }
}

struct RelayPairListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List relay pairings: label, hint, key scope, expiry, state. Never the credential."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let now = Date()
        for pairing in try service.relayPairings() {
            let state = pairing.revokedAt != nil ? "revoked" : (pairing.isActive(now: now) ? "active" : "expired")
            let scope = pairing.keys.isEmpty ? "all keys" : pairing.keys.joined(separator: ",")
            print("#\(pairing.id)\t…\(pairing.hint)\t\(state)\t\(scope)\texpires \(pairing.expiresAt ?? "-")\tlast \(pairing.lastUsedAt ?? "-")\t\(pairing.label)")
        }
    }
}

struct RelayPairRevokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke one relay pairing by label or by its last-4 hint."
    )

    @Argument(help: "Pairing label or hint from `keys relay pair list`.") var labelOrHint: String

    func run() throws {
        let service = try AppFactory.makeService()
        let pairing = try service.revokeRelayPairing(labelOrHint)
        print("revoked pairing \"\(pairing.label)\" (…\(pairing.hint)); its credential is refused from now on")
    }
}

struct RelayPairRequireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "require",
        abstract: "Require every relayed request to carry a pairing credential (on), or not (off, the default)."
    )

    @Argument(help: "on or off.") var state: String

    func run() throws {
        let required: Bool
        switch state.lowercased() {
        case "on": required = true
        case "off": required = false
        default: throw AppError.usage("usage: keys relay pair require on|off")
        }
        if let control = try? ControlClient.connect() {
            // The running site owns the catalog and asks for the one Touch ID the off-toggle
            // costs there, exactly like the mint in the issue verb.
            if !required { fputs("Touch ID in Keysrs…\n", stderr) }
            _ = try control.call(
                method: "POST", path: "/api/relay/pairings/required", body: ["required": required], expect: 200
            )
        } else {
            let service = try AppFactory.makeService()
            try service.setRelayPairingRequired(required)
        }
        // The running relay reads the flag from the catalog per request, so this applies
        // without a restart.
        print(required
            ? "relay pairing required: requests without a valid pairing credential are refused before they reach the gateway"
            : "relay pairing off: relayed requests need only a client token, as before")
    }
}

struct RelaySetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Mint the relay secret for your Worker URL (one Touch ID). Shown once."
    )

    @Option(help: "Your Worker's URL, e.g. https://keysrs-relay.<your-subdomain>.workers.dev.") var url: String

    func run() throws {
        let service = try AppFactory.makeService()
        let (origin, secret) = try service.setupRelay(url: url, caller: "cli")
        print(secret)
        FileHandle.standardError.write(Data("""
        relay secret for \(origin.absoluteString) (…\(RelaySecret.hint(secret))), stored in this Mac's Keychain.
        Give the Worker the same value, pasting it when asked:
          cd Relay && npx wrangler secret put RELAY_SECRET
        Then connect with: keys relay on (in Keysrs.app), or keys relay (in this Terminal)
        Agents use \(RelayURL.baseURL(origin, key: "<key name>")) as the base URL with a token from: keys client issue <key name>

        """.utf8))
        // A relay that is on keeps the secret it started with.
        if let held = RelayLock.holder(at: service.relayLockURL) {
            let note = held.isApp(control: ControlFile.url(beside: service.catalog.path))
                ? "The Keysrs app's relay is on with the previous secret; once the Worker has the new one, run keys relay off, then keys relay on."
                : "The keys relay already running uses the previous secret; once the Worker has the new one, stop it with Ctrl-C and start it again."
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
    }
}

struct RelayRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Connect to the Worker and relay its requests to the local gateway until Ctrl-C."
    )

    @Option(help: "Override the stored Worker URL for this run.") var url: String?

    func run() throws {
        let service = try AppFactory.makeService()
        // Before Touch ID: a second relay would only take the Worker's one Mac connection from
        // the first on every redial.
        let held: RelayLock
        do {
            held = try RelayLock(at: service.relayLockURL)
        } catch let busy as RelayLock.Held {
            throw AppError.usage(busy.terminalRefusal(control: ControlFile.url(beside: service.catalog.path)))
        }
        try requireGatewayUp()
        let (origin, secret) = try service.relayCredentials(urlOverride: url)
        var options = RelayClient.Options(url: origin, secret: secret)
        // Pairing is enforced when the catalog flag is on; the verifier reads hashes only,
        // so a relayed request never prompts here either.
        options.pairing = service.relayPairingVerifier()
        let client = RelayClient(
            options: options,
            log: { line in
                FileHandle.standardError.write(Data("relay  \(line)\n".utf8))
            }
        )
        FileHandle.standardError.write(Data(
            "relay  agents reach the gateway at \(RelayURL.baseURL(origin, key: "<key name>")) with a client token; Ctrl-C stops the relay\n".utf8
        ))
        let task = Task { await client.run() }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            task.cancel()
            FileHandle.standardError.write(Data("relay  stopped\n".utf8))
            Darwin.exit(0)
        }
        source.resume()
        // The lock is released when `held` goes, which must not be before the process does.
        withExtendedLifetime(held) { RunLoop.main.run() }
    }

    /// The same gateway-not-up failure as `keys tunnel`: `keys relay run` hits the identical
    /// condition, so it shares that helper — same wording, same exit code (6, like every other
    /// "no running site").
    static func gatewayDown() -> AppError { TunnelCommand.gatewayDown() }

    /// A relay to a closed gateway would only fail on the first agent call; say so here.
    private func requireGatewayUp() throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(GatewayListener.port)/")!)
        req.timeoutInterval = 3
        do {
            _ = try BlockingHTTP.send(req, timeout: 3)
        } catch {
            throw Self.gatewayDown()
        }
    }
}

struct RelayOnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Run the relay inside the running Keysrs app (one Touch ID there) until off or quit."
    )

    func run() throws {
        let control = try ControlClient.connect()
        fputs("Touch ID in Keysrs…\n", stderr)
        var obj = try control.call(method: "POST", path: "/api/relay", body: ["enabled": true], expect: 200)
        // The first dial says whether the Worker takes the secret; wait for it, briefly.
        let deadline = Date().addingTimeInterval(10)
        while JSONValue.string(obj["state"]) == "connecting", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            obj = try control.call(method: "GET", path: "/api/relay", expect: 200, timeout: 5)
        }
        print("relay \(RelayCommand.appLine(obj)); it stays on until keys relay off or Keysrs quits, and logs to menubar.log")
    }
}

struct RelayOffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn off the relay inside the running Keysrs app.")

    func run() throws {
        let control = try ControlClient.connect()
        _ = try control.call(method: "POST", path: "/api/relay", body: ["enabled": false], expect: 200)
        print("relay off in Keysrs; agents get 503 mac_offline (after the Worker's wait) until it is on again")
    }
}

struct RelayStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the stored Worker URL, whether a secret exists and which relay is running.")

    func run() throws {
        let service = try AppFactory.makeService()
        let status = service.relayStatus()
        print("url     \(status.url?.absoluteString ?? "not set")")
        print("secret  \(status.secretHint.map { "stored (…\($0))" } ?? "none")")
        let pairings = (try? service.relayPairings()) ?? []
        let now = Date()
        print("pairing \(RelayCommand.pairingLine(required: service.relayPairingRequired(), active: pairings.filter { $0.isActive(now: now) }.count))")
        if !status.configured {
            print("set up with: keys relay setup --url https://<your worker>.workers.dev")
        }
        let control = ControlFile.url(beside: service.catalog.path)
        if let client = try? ControlClient.connect(control: control),
           let obj = try? client.call(method: "GET", path: "/api/relay", expect: 200, timeout: 5)
        {
            print("app     \(RelayCommand.appLine(obj))")
        }
        if let held = RelayLock.holder(at: service.relayLockURL), !held.isApp(control: control) {
            print("shell   keys relay is running\(held.pid.map { " (process \($0))" } ?? "")")
        }
    }
}

struct RelayResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Forget the Worker URL and delete the relay secret from the Keychain.")

    func run() throws {
        let service = try AppFactory.makeService()
        // The app's relay holds the secret in memory; forgetting it must not leave that running.
        if let client = try? ControlClient.connect(control: ControlFile.url(beside: service.catalog.path)),
           let obj = try? client.call(method: "GET", path: "/api/relay", expect: 200, timeout: 5),
           JSONValue.bool(obj["on"]) == true
        {
            _ = try client.call(method: "POST", path: "/api/relay", body: ["enabled": false], expect: 200)
            print("turned off the relay in Keysrs")
        }
        try service.resetRelay()
        print("relay forgotten on this Mac; on the Cloudflare side run: cd Relay && npx wrangler secret delete RELAY_SECRET (or npx wrangler delete)")
    }
}
