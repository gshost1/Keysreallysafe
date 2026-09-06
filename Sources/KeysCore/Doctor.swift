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
    var loginItemBinaryMtime: String?
    var debugBinaryMtime: String?
    var loginItemBinarySHA256: String?
    var debugBinarySHA256: String?
    var binaryNote: String
    var gatewayOwnerPid: pid_t? = nil
    var gatewayOwned: Bool = false
    var activeGrants: Int = 0
    var controlFile: String? = nil

    func jsonObject() -> [String: Any] {
        [
            "sources": sources.map { $0.jsonObject() },
            "catalog_path": catalogPath,
            "catalog_size": catalogSize as Any? ?? NSNull(),
            "keychain_service": keychainService,
            "keychain_reachable": keychainReachable,
            "gateway_listening": gatewayListening,
            "gateway_port": Int(gatewayPort),
            "autostart_plist": autostartPlist,
            "autostart_plist_path": autostartPlistPath,
            "login_item_binary_mtime": loginItemBinaryMtime as Any? ?? NSNull(),
            "debug_binary_mtime": debugBinaryMtime as Any? ?? NSNull(),
            "login_item_binary_sha256": loginItemBinarySHA256 as Any? ?? NSNull(),
            "debug_binary_sha256": debugBinarySHA256 as Any? ?? NSNull(),
            "binary": binaryNote,
            "gateway_owner_pid": gatewayOwnerPid.map { Int($0) } as Any? ?? NSNull(),
            "gateway_owned": gatewayOwned,
            "active_grants": activeGrants,
            "control_file": controlFile as Any? ?? NSNull(),
        ]
    }

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
        lines.append(
            "grants  \(activeGrants) active in this process  control=\(controlFile ?? "none (no running site)")"
        )
        lines.append(
            "autostart  \(autostartPlistPath)  \(autostartPlist ? "present" : "missing")"
        )
        lines.append(
            "binary  login-item sha256=\(loginItemBinarySHA256 ?? "missing")  debug sha256=\(debugBinarySHA256 ?? "missing")  \(binaryNote)"
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

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "path": path,
            "state": state,
            "mtime": mtime as Any? ?? NSNull(),
            "newest_event": newestEvent as Any? ?? NSNull(),
            "strip": strip,
            "empty_reason": emptyReason as Any? ?? NSNull(),
        ]
    }
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
                emptyReason: emptyGrokSpend(status)
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
        let hudExists = FileManager.default.isReadableFile(atPath: claudeHud.path)
            || FileManager.default.isReadableFile(atPath: claudePlan.path)
        let hudPath = FileManager.default.isReadableFile(atPath: claudeHud.path) ? claudeHud : claudePlan
        sources.append(
            source(
                id: "claude-hud",
                path: hudPath,
                directory: false,
                newestEvent: status.claude?.snapshotAt,
                strip: "Claude 5h / weekly %",
                emptyReason: emptyClaudeHud(status, exists: hudExists)
            )
        )
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
        let loginMtime = isoMtime(LoginItem.installedBinary)
        let debugURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/keys")
        let debugMtime = isoMtime(debugURL)
        // The installed copy is re-signed, so hash the sidecar autostart wrote from the source binary.
        let loginSHA = fileSHA256(LoginItem.installedBinary)
        let loginSourceSHA = (try? String(contentsOf: LoginItem.installedSourceHash, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let debugSHA = fileSHA256(debugURL)
        let binaryNote = Self.binaryNote(installed: loginSHA, installedSource: loginSourceSHA, debug: debugSHA)

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
            loginItemBinaryMtime: loginMtime,
            debugBinaryMtime: debugMtime,
            loginItemBinarySHA256: loginSHA,
            debugBinarySHA256: debugSHA,
            binaryNote: binaryNote,
            gatewayOwnerPid: service.gatewayOwnerPid(),
            gatewayOwned: service.thisProcessOwnsGateway(),
            activeGrants: service.listGrants().count,
            controlFile: ControlFile.live().map { "127.0.0.1:\($0.port) pid \($0.pid)" }
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

    private static func emptyGrokSpend(_ status: LiveStatus) -> String? {
        if (status.grok?.weeklyUsd ?? 0) > 0 { return nil }
        return nil
    }

    private static func emptyGrokPct(_ status: LiveStatus, path: URL) -> String? {
        if status.grok?.weeklyPct != nil { return nil }
        if !FileManager.default.isReadableFile(atPath: path.path) { return "missing file" }
        if let note = status.grok?.usageNote, note.contains("Quota resets") {
            return "reset passed"
        }
        return "no rate_limits yet"
    }

    private static func emptyClaudeHud(_ status: LiveStatus, exists: Bool) -> String? {
        if status.claude?.fiveHourPct != nil || status.claude?.weeklyPct != nil { return nil }
        if !exists { return "claude-hud not writing" }
        return "claude-hud not writing"
    }

    private static func emptyCodex(_ status: LiveStatus, path: URL) -> String? {
        let openai = status.plans.first { $0.source == "openai" }
        if openai?.weeklyPct != nil || openai?.fiveHourPct != nil { return nil }
        if !FileManager.default.fileExists(atPath: path.path) { return "missing file" }
        if openai?.fiveHourPct == nil && openai?.weeklyPct == nil {
            return "no rate_limits yet"
        }
        return nil
    }

    private static func isoMtime(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return UTC.iso(date)
    }

    static func binaryNote(installed: String?, installedSource: String?, debug: String?) -> String {
        if installed == nil && debug == nil { return "missing" }
        if installed == nil { return "login item binary missing" }
        if debug == nil { return "debug binary missing" }
        guard let source = installedSource, !source.isEmpty else { return "unknown (re-run keys autostart to record the source hash)" }
        return source == debug ? "match" : "stale"
    }

    static func fileSHA256(_ url: URL) -> String? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
