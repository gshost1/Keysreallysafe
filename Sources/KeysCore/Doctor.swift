import CryptoKit
import Darwin
import Foundation
import Security

struct DoctorReport: Equatable {
    var sources: [DoctorSource]
    var catalogPath: String
    var catalogSize: Int64?
    var keychainService: String
    var keychainReachable: Bool
    var gatewayListening: Bool
    var gatewayPort: UInt16
    var install: DoctorInstall
    var controlFile: String? = nil
    /// The latest failures on the gateway's side of the provider (`GatewayLogFilter.gatewaySide`).
    var gatewayFailures: [GatewayLogEntry] = []

    var printed: String {
        var lines: [String] = []
        for src in sources {
            var line =
                "\(src.id)  \(src.path)  \(src.state)"
            if let mtime = src.mtime { line += "  mtime=\(mtime)" }
            if let newest = src.newestEvent { line += "  newest_event=\(newest)" }
            line += "  strip=\(src.strip)"
            if let why = src.emptyReason { line += "  why=\(why)" }
            lines.append(line)
        }
        let size = catalogSize.map(String.init) ?? "missing"
        lines.append("catalog  \(catalogPath)  size=\(size)")
        lines.append(
            "keychain  \(keychainService)  \(keychainReachable ? "reachable" : "unreachable")"
        )
        lines.append(
            "gateway  127.0.0.1:\(gatewayPort)  \(gatewayListening ? "listening" : "not listening")"
        )
        lines.append(contentsOf: Doctor.gatewayLines(failures: gatewayFailures, timeZone: .current))
        lines.append("site  control=\(controlFile ?? "none (no running site)")")
        lines.append(contentsOf: Doctor.installLines(install))
        return lines.joined(separator: "\n")
    }
}

struct DoctorSource: Equatable {
    var id: String
    var path: String
    var state: String
    var mtime: String?
    var newestEvent: String?
    var strip: String
    var emptyReason: String?
}

enum Doctor {
    static func report(
        service: KeysService, probeListener: Bool = true, probeAgent: Bool = true, install: DoctorInstall? = nil
    ) throws -> DoctorReport {
        let status = try service.liveStatus()
        let grokSessions = service.grokHome.appendingPathComponent("sessions", isDirectory: true)
        let grokLog = service.grokHome.appendingPathComponent("logs/unified.jsonl")
        let claudeProjects = service.claudeHome.appendingPathComponent("projects", isDirectory: true)
        let claudeHud = service.claudeHome.appendingPathComponent("plugins/claude-hud/usage.json")
        let claudePlan = service.claudePlanFile
        let codexSessions = service.codexHome.appendingPathComponent("sessions", isDirectory: true)

        var sources: [DoctorSource] = []
        sources.append(
            source(
                id: "grok-sessions",
                path: grokSessions,
                directory: true,
                newestEvent: try service.catalog.newestUsage(source: "grok-local"),
                strip: "Grok weekly $",
                emptyReason: nil
            )
        )
        sources.append(
            source(
                id: "grok-quota",
                path: grokLog,
                directory: false,
                newestEvent: status.grok?.snapshotAt,
                strip: "Grok weekly %",
                emptyReason: emptyGrokPct(status, path: grokLog)
            )
        )
        sources.append(
            source(
                id: "claude-projects",
                path: claudeProjects,
                directory: true,
                newestEvent: try service.catalog.newestUsage(source: "claude-local"),
                strip: "Claude tokens / estimate",
                emptyReason: FileManager.default.fileExists(atPath: claudeProjects.path)
                    ? nil
                    : "missing file"
            )
        )
        let hudPath = FileManager.default.isReadableFile(atPath: claudeHud.path) ? claudeHud : (claudePlan ?? claudeHud)
        let hudStatus = LiveStatus.readClaudePlan(home: service.claudeHome, extra: claudePlan)
        sources.append(
            source(
                id: "claude-hud",
                path: hudPath,
                directory: false,
                newestEvent: hudStatus.snapshotAt,
                strip: "Claude 5h / weekly %",
                emptyReason: hudStatus.fiveHourPct != nil || hudStatus.weeklyPct != nil ? nil : "claude-hud not writing"
            )
        )
        let claudeCache = ClaudeUsageCache.read(home: service.claudeHome, now: Date())
        sources.append(source(
            id: "claude-usage-cache",
            path: ClaudeUsageCache.configURL(home: service.claudeHome),
            directory: false,
            newestEvent: claudeCache?.snapshotAt,
            strip: "Claude Fable / 5h / weekly %",
            emptyReason: claudeCache?.fablePct == nil
                ? "No current Fable reading for this account; run Claude /usage (the menu-bar app refreshes every 5 minutes)."
                : nil
        ))
        sources.append(
            source(
                id: "codex-sessions",
                path: codexSessions,
                directory: true,
                newestEvent: try service.catalog.newestUsage(source: "codex-local"),
                strip: "OpenAI · Codex weekly % / tokens",
                emptyReason: emptyCodex(status, path: codexSessions)
            )
        )

        let catalogPath = service.catalog.path
        let catalogSize = fileSize(catalogPath)

        let listening = service.isGatewayRunning()
            || (probeListener && portOpen(host: BindPolicy.loopback, port: GatewayListener.port))
        let failures = (try? service.catalog.gatewayLog(
            through: service.catalog.gatewayLogCursor(), filter: .gatewaySide, limit: gatewayFailureCount
        )) ?? []

        return DoctorReport(
            sources: sources,
            catalogPath: catalogPath.path,
            catalogSize: catalogSize,
            keychainService: "keysreallysafe",
            keychainReachable: keychainReachable(service: "keysreallysafe"),
            gatewayListening: listening,
            gatewayPort: GatewayListener.port,
            install: install ?? DoctorInstall.live(probeAgent: probeAgent),
            controlFile: ControlFile.live(at: ControlFile.url(beside: service.catalog.path)).map { "127.0.0.1:\($0.port) pid \($0.pid)" },
            gatewayFailures: failures
        )
    }

    static let gatewayFailureCount = 5

    /// The limits the gateway enforces, from the constants it runs with, and the latest failures
    /// on its side of the provider. Pure, so the lines can be asserted in tests. There is no
    /// separate connect timeout to print: a 30 s one cut off calls whose head takes minutes, so
    /// the request timeout covers connecting too.
    static func gatewayLines(failures: [GatewayLogEntry], timeZone: TimeZone) -> [String] {
        let mib = GatewayListener.bodyCap / (1024 * 1024)
        var lines = [
            "gateway limits  request_timeout=\(Int(GatewayListener.resourceTimeout))s (idle and whole call)"
                + "  connect_timeout=none (the request timeout covers it)  body_cap=\(mib)MiB"
                + "  max_connections=\(GatewayListener.maxConcurrent)  caller_io_timeout=\(GatewayListener.ioTimeoutSeconds)s",
            "gateway breaker  \(GatewayBreaker.threshold) upstream 401/403 in a row pause a key's calls for "
                + "\(Int(GatewayBreaker.cooldown))s (503 \(GatewayBreaker.code))",
        ]
        guard !failures.isEmpty else {
            lines.append("gateway failures  none recorded")
            return lines
        }
        lines.append("gateway failures  last \(failures.count) on this side of the provider, newest last (token refusals: keys log --failed)")
        lines.append(contentsOf: GatewayLogFormat.table(failures, timeZone: timeZone).map { "  " + $0 })
        return lines
    }

    /// Formats the install block. Pure: it reads only the gathered `DoctorInstall`, never the
    /// file system, so the same lines can be asserted in tests.
    static func installLines(_ i: DoctorInstall) -> [String] {
        if let app = i.appBundle {
            var lines = [
                "app  \(app.path)  sha256=\(i.bundleBinarySHA256 ?? "missing")",
                "login  \(loginDescription(i.loginItem))",
                commandLine(i),
                runningLine(i),
            ]
            if i.legacyPlistExists || i.legacyBinaryExists || i.legacyAgentLoaded == true {
                lines.append(legacyLine(i))
            }
            return lines
        }
        if i.legacyPlistExists || i.legacyBinaryExists {
            let installed = i.legacyBinarySHA256
            let running = i.runningBinarySHA256
            let same = installed != nil && installed == running
            return [
                "autostart  \(i.legacyPlist.path)  \(i.legacyPlistExists ? "present" : "missing")",
                "binary  installed sha256=\(installed ?? "missing")  running sha256=\(running ?? "missing")  \(same ? "match" : "differs")",
            ]
        }
        return ["app  not installed (running from \(i.runningExecutable?.path ?? "unknown"))"]
    }

    private static func loginDescription(_ state: LoginItemState) -> String {
        switch state {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        case .notQueried: return "not queried (open Keysrs to see Start at Login)"
        }
    }

    private static func commandLine(_ i: DoctorInstall) -> String {
        guard let command = i.commandOnPath else {
            return "command  keys not on PATH (Install Command Line Tool… in the Keysrs menu)"
        }
        var line = "command  \(command.path)"
        if let target = i.commandTarget { line += " -> \(target)" }
        let verdict: String
        if i.commandSHA256 == nil { verdict = "missing" }
        else if i.commandSHA256 == i.bundleBinarySHA256 { verdict = "match" }
        else { verdict = "differs" }
        line += "  sha256=\(i.commandSHA256 ?? "missing")  \(verdict)"
        return line
    }

    private static func runningLine(_ i: DoctorInstall) -> String {
        let same = i.runningBinarySHA256 != nil && i.runningBinarySHA256 == i.bundleBinarySHA256
        return "running  \(i.runningExecutable?.path ?? "unknown")  sha256=\(i.runningBinarySHA256 ?? "missing")  \(same ? "match" : "differs")"
    }

    private static func legacyLine(_ i: DoctorInstall) -> String {
        let agent: String
        switch i.legacyAgentLoaded {
        case .some(true): agent = "loaded"
        case .some(false): agent = "not loaded"
        case .none: agent = "not probed"
        }
        return "legacy  plist \(i.legacyPlistExists ? "present" : "absent")  bin \(i.legacyBinaryExists ? "present" : "absent")  agent \(agent)  remove with: keys autostart --remove"
    }

    private static func source(
        id: String,
        path: URL,
        directory: Bool,
        newestEvent: String?,
        strip: String,
        emptyReason: String?
    ) -> DoctorSource {
        let exists = directory
            ? FileManager.default.fileExists(atPath: path.path)
            : FileManager.default.isReadableFile(atPath: path.path)
        return DoctorSource(
            id: id,
            path: path.path,
            state: exists ? "found" : "missing",
            mtime: exists ? isoMtime(path) : nil,
            newestEvent: newestEvent,
            strip: strip,
            emptyReason: exists ? emptyReason : "missing file"
        )
    }

    private static func emptyGrokPct(_ status: LiveStatus, path: URL) -> String? {
        if status.grok?.weeklyPct != nil { return nil }
        if !FileManager.default.isReadableFile(atPath: path.path) { return "missing file" }
        if let note = status.grok?.usageNote, note.contains("Quota resets") {
            return "reset passed"
        }
        return "no rate_limits yet"
    }

    private static func emptyCodex(_ status: LiveStatus, path: URL) -> String? {
        let openai = status.plans.first { $0.source == "openai" }
        if openai?.weeklyPct != nil || openai?.fiveHourPct != nil { return nil }
        return FileManager.default.fileExists(atPath: path.path) ? "no rate_limits yet" : "missing file"
    }

    private static func isoMtime(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return UTC.iso(date)
    }

    static func fileSHA256(_ url: URL) -> String? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return Hex.encode(SHA256.hash(data: data))
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int64(size)
    }

    static func keychainReachable(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func portOpen(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(host))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}
