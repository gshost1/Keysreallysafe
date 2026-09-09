import Foundation

/// Claude Code writes the authenticated /usage response here. Read only the usage
/// cache, and reject a cache from a different signed-in account.
enum ClaudeUsageCache {
    static let maxAge: TimeInterval = 60 * 60

    static func configURL(home: URL, hasConfigOverride: Bool = !(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty) -> URL {
        let user = FileManager.default.homeDirectoryForCurrentUser
        if !hasConfigOverride && home.standardizedFileURL == user.appendingPathComponent(".claude").standardizedFileURL {
            return user.appendingPathComponent(".claude.json")
        }
        return home.appendingPathComponent(".claude.json")
    }

    static func read(home: URL, now: Date) -> ToolStatus? {
        guard let data = try? Data(contentsOf: configURL(home: home)),
              let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let account = JSONValue.object(obj["oauthAccount"]),
              let accountID = JSONValue.string(account["accountUuid"]),
              let cache = JSONValue.object(obj["cachedUsageUtilization"]),
              JSONValue.string(cache["accountUuid"]) == accountID,
              let fetchedMs = JSONValue.double(cache["fetchedAtMs"]), fetchedMs.isFinite,
              let usage = JSONValue.object(cache["utilization"])
        else { return nil }
        let fetched = Date(timeIntervalSince1970: fetchedMs / 1000)
        guard (0...maxAge).contains(now.timeIntervalSince(fetched)) else { return nil }
        let five = window(JSONValue.object(usage["five_hour"]), key: "utilization", now: now)
        let week = window(JSONValue.object(usage["seven_day"]), key: "utilization", now: now)
        let fableRaw = (usage["limits"] as? [[String: Any]])?.first { limit in
            guard JSONValue.string(limit["kind"]) == "weekly_scoped",
                  let scope = JSONValue.object(limit["scope"]),
                  let model = JSONValue.object(scope["model"])
            else { return false }
            return JSONValue.string(model["display_name"])?.lowercased() == "fable"
        }
        let fable = window(fableRaw, key: "percent", now: now)
        guard five.pct != nil || week.pct != nil || fable.pct != nil else { return nil }
        return ToolStatus(
            source: "claude", title: "Claude",
            fiveHourPct: five.pct, fiveHourResetsAt: five.reset,
            weeklyPct: week.pct, weeklyResetsAt: week.reset,
            snapshotAt: UTC.iso(fetched), fablePct: fable.pct, fableResetsAt: fable.reset
        )
    }

    private static func window(_ obj: [String: Any]?, key: String, now: Date) -> (pct: Int?, reset: String?) {
        guard let obj, let number = obj[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue)
        else { return (nil, nil) }
        let reset = JSONValue.string(obj["resets_at"])
        if let reset {
            guard let date = UTC.parse(reset), date > now else { return (nil, nil) }
        }
        return (Int(number.doubleValue.rounded()), reset)
    }

    static func merge(_ cached: ToolStatus?, into hud: ToolStatus) -> ToolStatus {
        guard let cached else { return hud }
        var row = hud
        let cacheDate = cached.snapshotAt.flatMap(UTC.parse) ?? .distantPast
        let hudDate = hud.snapshotAt.flatMap(UTC.parse) ?? .distantPast
        var usedCache = false
        if let pct = cached.fiveHourPct, hud.fiveHourPct == nil || cacheDate >= hudDate {
            row.fiveHourPct = pct; row.fiveHourResetsAt = cached.fiveHourResetsAt; usedCache = true
        }
        if let pct = cached.weeklyPct, hud.weeklyPct == nil || cacheDate >= hudDate {
            row.weeklyPct = pct; row.weeklyResetsAt = cached.weeklyResetsAt; usedCache = true
        }
        if let pct = cached.fablePct, hud.fablePct == nil || cacheDate >= hudDate {
            row.fablePct = pct; row.fableResetsAt = cached.fableResetsAt; usedCache = true
        }
        if usedCache {
            // When combining sources, show the older observation time, never imply
            // that an older Fable reading was refreshed by a newer generic HUD update.
            row.snapshotAt = hud.snapshotAt == nil ? cached.snapshotAt : UTC.iso(min(cacheDate, hudDate))
            if cacheDate >= hudDate && row.fiveHourPct == cached.fiveHourPct && row.weeklyPct == cached.weeklyPct && row.fablePct == cached.fablePct {
                row.snapshotAt = cached.snapshotAt
            }
            row.usageNote = nil
        }
        return row
    }
}

/// Refresh through Claude's built-in local /usage command, which handles its own
/// login and token refresh. No model prompt, hooks, tools, or credential copying.
enum ClaudeUsageRefresh {
    static let interval: TimeInterval = 5 * 60
    static let arguments = ["--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--tools", "", "--no-session-persistence", "-p", "/usage"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running = false
    nonisolated(unsafe) private static var lastAttempt: Date?

    static func enqueue(home: URL, completion: @escaping @Sendable () -> Void) {
        let now = Date()
        lock.lock()
        guard !running, lastAttempt.map({ now.timeIntervalSince($0) >= interval }) ?? true else {
            lock.unlock(); return
        }
        running = true
        lastAttempt = now
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock(); running = false; lock.unlock()
                completion()
            }
            let user = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [user.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = home
            var env = ProcessInfo.processInfo.environment
            if (env["CLAUDE_CONFIG_DIR"] ?? "").isEmpty && home.standardizedFileURL == user.appendingPathComponent(".claude").standardizedFileURL {
                env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            } else {
                env["CLAUDE_CONFIG_DIR"] = home.path
            }
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            do { try process.run() } catch { return }
            if ended.wait(timeout: .now() + 45) == .timedOut {
                process.terminate()
                if ended.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 2)
                }
            }
        }
    }
}
