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
    var autostartPlist: Bool
    var autostartPlistPath: String
    var installedBinarySHA256: String?
    var runningBinarySHA256: String?
    var controlFile: String? = nil

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
        lines.append("site  control=\(controlFile ?? "none (no running site)")")
        lines.append(
            "autostart  \(autostartPlistPath)  \(autostartPlist ? "present" : "missing")"
        )
        let same = installedBinarySHA256 != nil && installedBinarySHA256 == runningBinarySHA256
        lines.append(
            "binary  installed sha256=\(installedBinarySHA256 ?? "missing")  running sha256=\(runningBinarySHA256 ?? "missing")  \(same ? "match" : "differs")"
        )
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
    static func report(service: KeysService, probeListener: Bool = true) throws -> DoctorReport {
        let status = try service.liveStatus()
        let grokSessions = service.grokHome.appendingPathComponent("sessions", isDirectory: true)
        let grokLog = service.grokHome.appendingPathComponent("logs/unified.jsonl")
        let claudeProjects = service.claudeHome.appendingPathComponent("projects", isDirectory: true)
        let claudeHud = service.claudeHome.appendingPathComponent("plugins/claude-hud/usage.json")
        let claudePlan = Paths.appSupport.appendingPathComponent("claude-plan.json")
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
        let hudPath = FileManager.default.isReadableFile(atPath: claudeHud.path) ? claudeHud : claudePlan
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
        let plist = LoginItem.agentPlist
        // Bundle.main, not argv[0]: run from PATH, argv[0] is just "keys".
        let running = Bundle.main.executableURL.flatMap(fileSHA256)

        let listening = service.isGatewayRunning()
            || (probeListener && portOpen(host: BindPolicy.loopback, port: GatewayListener.port))

        return DoctorReport(
            sources: sources,
            catalogPath: catalogPath.path,
            catalogSize: catalogSize,
            keychainService: "keysreallysafe",
            keychainReachable: keychainReachable(service: "keysreallysafe"),
            gatewayListening: listening,
            gatewayPort: GatewayListener.port,
            autostartPlist: FileManager.default.fileExists(atPath: plist.path),
            autostartPlistPath: plist.path,
            installedBinarySHA256: fileSHA256(Installer.live.binary),
            runningBinarySHA256: running,
            controlFile: ControlFile.live(at: ControlFile.url(beside: service.catalog.path)).map { "127.0.0.1:\($0.port) pid \($0.pid)" }
        )
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
