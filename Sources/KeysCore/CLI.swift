import AppKit
import ArgumentParser
import Darwin
import Foundation

public struct KeysCLI: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Keysreallysafe — local key vault and token spend meter.",
        subcommands: [
            AddCommand.self,
            ListCommand.self,
            GetCommand.self,
            CopyCommand.self,
            RmCommand.self,
            RotateCommand.self,
            IngestCommand.self,
            SpendCommand.self,
            StatusCommand.self,
            DoctorCommand.self,
            EnvCommand.self,
            DashboardCommand.self,
            MenubarCommand.self,
            AutostartCommand.self,
            ClientCommand.self,
            PurgeCommand.self,
        ]
    )
}

public enum KeysMain {
    public static func main() {
        do {
            var command = try KeysCLI.parseAsRoot()
            try command.run()
        } catch let error as AppError {
            let msg = error.description + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            Darwin.exit(error.exitCode)
        } catch {
            let message = KeysCLI.message(for: error)
            if !message.isEmpty {
                FileHandle.standardError.write(Data(message.utf8))
            }
            switch KeysCLI.exitCode(for: error) {
            case .success:
                Darwin.exit(0)
            default:
                Darwin.exit(1)
            }
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
            let data = try JSONValue.data(service.listJSONObject())
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
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
}

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print a secret once (user presence).")

    @Argument var name: String

    func run() throws {
        let service = try AppFactory.makeService()
        let secret = try service.get(name: name)
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
    static let configuration = CommandConfiguration(commandName: "ingest", abstract: "Scan local Grok, Claude Code, and Codex usage logs.")

    @Argument var source: String = "all"

    func run() throws {
        guard let parsed = Ingest.Source(rawValue: source) else {
            throw AppError.usage("ingest source must be all, grok, claude, or openai")
        }
        let service = try AppFactory.makeService()
        let reports = try service.ingest(parsed)
        for (name, report) in reports {
            print("\(name): \(report.line)")
        }
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
        guard let group = SpendGroup(rawValue: by), group != .hour else {
            throw AppError.usage("--by must be model, session, or project")
        }
        let service = try AppFactory.makeService()
        let source: SourceFilter = group == .project ? .claude : .all
        let report = try service.spend(range: range, by: group, source: source)
        if json {
            let data = try JSONValue.data(report.jsonObject())
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        printTable(report)
        print(report.caption)
        if report.totals.claudeUsdEstimate != nil {
            print("Claude USD is an estimate, not an invoice. Grok totals use costUsdTicks only.")
        }
    }

    private func printTable(_ report: SpendReport) {
        switch report.by {
        case .model, .hour:
            print("MODEL\tIN\tOUT\tCACHE_READ\tREASONING\tUSD\tCALLS")
            for row in report.rows {
                let usd: String
                if let v = row.usd {
                    usd = String(format: "%.4f", v)
                } else if let e = row.usdEstimate {
                    usd = String(format: "est %.4f*", e)
                } else {
                    usd = "-"
                }
                print("\(row.model ?? "")\t\(row.inputTokens)\t\(row.outputTokens)\t\(row.cachedReadTokens)\t\(row.reasoningTokens)\t\(usd)\t\(row.modelCalls)")
            }
        case .session:
            print("SESSION\tCWD\tTITLE\tMODELS\tUSD")
            for row in report.rows {
                let usd: String
                if let v = row.usd {
                    usd = String(format: "%.4f", v)
                } else if let e = row.usdEstimate {
                    usd = String(format: "est %.4f*", e)
                } else {
                    usd = "-"
                }
                let models = row.models.joined(separator: ",")
                print("\(row.sessionId ?? "")\t\(row.cwd ?? "")\t\(row.title ?? "")\t\(models)\t\(usd)")
            }
        case .project:
            print("PROJECT\tCWD\tIN\tOUT\tUSD")
            for row in report.rows {
                let usd: String
                if let v = row.usd {
                    usd = String(format: "%.4f", v)
                } else if let e = row.usdEstimate {
                    usd = String(format: "est %.4f*", e)
                } else {
                    usd = "-"
                }
                print("\(row.project ?? "")\t\(row.cwd ?? "")\t\(row.inputTokens)\t\(row.outputTokens)\t\(usd)")
            }
        }
        print(String(format: "Grok $%.4f  Claude tokens %d  OpenAI tokens %d", report.totals.grokUsd, report.totals.claudeTokens, report.totals.openaiTokens))
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Local plan windows: Grok, Claude, OpenAI/Codex, and other tools."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let status = try service.liveStatus()
        let rows = status.plans.isEmpty
            ? [status.grok, status.claude].compactMap { $0 }
            : status.plans
        for row in rows {
            printPlan(row)
        }
    }

    private func printPlan(_ row: ToolStatus) {
        print(row.title)
        if let usd = row.weeklyUsd, row.weeklyTokens != nil {
            print("  weekly  \(row.weeklyTokens ?? 0) tokens  ≈ \(String(format: "$%.2f", usd)) estimate")
        } else if let usd = row.weeklyUsd {
            print("  weekly  \(String(format: "$%.2f", usd))  local spend")
        } else if row.weeklyTokens != nil {
            print("  weekly  \(row.weeklyTokens ?? 0) tokens")
        }
        if row.fiveHourPct != nil || row.source == "claude" || row.source == "openai" {
            print("  5 hour  \(pctLine(row.fiveHourPct, reset: row.fiveHourResetsAt))")
        }
        if row.weeklyPct != nil || row.source == "openai" {
            print("  weekly  \(pctLine(row.weeklyPct, reset: row.weeklyResetsAt))")
        }
        if let note = row.usageNote {
            print("  \(note)")
        }
    }

    private func pctLine(_ pct: Int?, reset: String?) -> String {
        guard let pct else { return "—" }
        var s = "\(pct)%"
        if let reset, let extra = LiveStatus.formatResets(at: reset, now: Date()) {
            s += "  (\(extra))"
        }
        return s
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Show local sources, catalog, Keychain, gateway, and autostart."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let report = try Doctor.report(service: service)
        print(report.printed)
    }
}

struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Run a command with a vault secret in the environment (user presence, no clipboard).",
        usage: "keys env <name> <variable> -- <command> ...",
        discussion: "Unlocks the named key, sets <variable> in the child only, and execs the command. Put -- before the command so its flags are not parsed by keys. The secret is not copied to the clipboard."
    )

    @Argument(help: "Vault key name.")
    var name: String

    @Argument(help: "Environment variable to set in the child.")
    var variable: String

    @Argument(parsing: .remaining, help: "Command after --.")
    var command: [String]

    func run() throws {
        do {
            let service = try AppFactory.makeService()
            let code = try service.env(name: name, variable: variable, command: command, caller: "env")
            Darwin.exit(code)
        } catch let error as AppError {
            if case .usage = error {
                let dump =
                    "parsed name=\(name.debugDescription) variable=\(variable.debugDescription) command=\(command)\n"
                FileHandle.standardError.write(Data(dump.utf8))
            }
            throw error
        }
    }
}

struct DashboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dashboard",
        abstract: "Open the local Keysreallysafe site on 127.0.0.1."
    )

    @Flag var month = false
    @Flag var week = false

    func run() throws {
        if month && week { throw AppError.usage("choose --month or --week") }
        let range = week ? "week" : "month"
        let service = try AppFactory.makeService()
        let server = try LoopbackSite.bind(service: service, preferredPort: LoginItem.dashboardPort)
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/?range=\(range)")!
        let line = "Keysreallysafe  \(url.absoluteString)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        fflush(stdout)
        NSWorkspace.shared.open(url)
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
        abstract: "Always-on spend sparkline in the macOS menu bar."
    )

    func run() throws {
        let service = try AppFactory.makeService()
        let server = try LoopbackSite.bind(service: service, preferredPort: LoginItem.menubarPort)
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/?range=month")!
        let line = "Keysreallysafe menubar  \(url.absoluteString)\n"
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
        abstract: "Start the local site at login (loopback menubar, not a public host)."
    )

    @Flag(name: [.customLong("remove"), .customLong("uninstall")], help: "Unload and delete the login item and its snapshot.")
    var remove = false

    func run() throws {
        if remove {
            try LoginItem.uninstall()
            print("removed login item \(LoginItem.label)")
            return
        }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let web = try WebRoot.find()
        try LoginItem.install(fromBinary: binary, webRoot: web)
        print("starts at login  \(LoginItem.bookmarkURL.absoluteString)")
        print("menu bar Open Keysreallysafe  (loopback only, not Vercel)")
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
        let service = try AppFactory.makeService()
        let issued = try service.issueGatewayClient(
            name: name,
            label: label,
            days: days,
            methods: methods.isEmpty ? nil : methods,
            pathPrefix: pathPrefix,
            caller: "cli"
        )
        print(issued.token)
        let scope = issued.client.methods.joined(separator: ",") + " " + (issued.client.pathPrefix ?? "*")
        FileHandle.standardError.write(Data(
            "client #\(issued.client.id) for \(name), \(scope), expires \(issued.client.expiresAt). Put it where the SDK expects the API key; base URL http://127.0.0.1:\(GatewayListener.port)/\(name)\n".utf8
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
