import Foundation

struct ToolStatus: Equatable {
    var source: String
    var title: String
    var kind: String = "local"
    var fiveHourPct: Int?
    var fiveHourResetsAt: String?
    var weeklyPct: Int?
    var weeklyResetsAt: String?
    var weeklyUsd: Double?
    var weeklyTokens: Int?
    var usageNote: String?
    var period: SpendPeriod?
    var plan: String? = nil
    var snapshotAt: String? = nil
    var limit: Double? = nil
    var limitRemaining: Double? = nil
    var usageWeekly: Double? = nil
    var fablePct: Int? = nil
    var fableResetsAt: String? = nil

    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "source": source,
            "title": title,
            "kind": kind,
            "five_hour_pct": fiveHourPct as Any? ?? NSNull(),
            "five_hour_resets_at": fiveHourResetsAt as Any? ?? NSNull(),
            "weekly_pct": weeklyPct as Any? ?? NSNull(),
            "weekly_resets_at": weeklyResetsAt as Any? ?? NSNull(),
            "fable_pct": fablePct as Any? ?? NSNull(),
            "fable_resets_at": fableResetsAt as Any? ?? NSNull(),
            "weekly_usd": weeklyUsd as Any? ?? NSNull(),
            "weekly_tokens": weeklyTokens as Any? ?? NSNull(),
            "usage_note": usageNote as Any? ?? NSNull(),
            "plan": plan as Any? ?? NSNull(),
            "snapshot_at": snapshotAt as Any? ?? NSNull(),
            "limit": limit as Any? ?? NSNull(),
            "limit_remaining": limitRemaining as Any? ?? NSNull(),
            "usage_weekly": usageWeekly as Any? ?? NSNull(),
        ]
        if weeklyUsd != nil || weeklyTokens != nil, let period {
            obj["period"] = period.jsonObject()
        }
        return obj
    }
}

enum PlanCatalog {
    static func rows(
        grok: ToolStatus,
        claude: ToolStatus,
        openaiWeekTokens: Int,
        openaiWeekUsdEstimate: Double?,
        codexHome: URL,
        weekPeriod: SpendPeriod? = nil,
        now: Date
    ) -> [ToolStatus] {
        let hasCodexSessions = FileManager.default.fileExists(
            atPath: codexHome.appendingPathComponent("sessions", isDirectory: true).path
        )
        var openaiNote: String
        if openaiWeekTokens > 0 {
            openaiNote = "Codex local tokens this week. ChatGPT Plus 5-hour is not in local files. API console pull needs a billing key."
        } else if hasCodexSessions {
            openaiNote = "No Codex usage this week. ChatGPT Plus 5-hour is not in local files. API console pull needs a billing key."
        } else {
            openaiNote = "No Codex sessions on this Mac. ChatGPT Plus 5-hour is not in local files. API console pull needs a billing key."
        }
        var openai = ToolStatus(
            source: "openai",
            title: "OpenAI · Codex",
            kind: "api",
            weeklyUsd: openaiWeekUsdEstimate,
            weeklyTokens: openaiWeekTokens,
            usageNote: openaiNote,
            period: weekPeriod
        )
        LiveStatus.applyCodexLimits(to: &openai, home: codexHome, now: now)
        return [
            grok,
            claude,
            openai,
            ToolStatus(
                source: "chatgpt",
                title: "ChatGPT",
                kind: "subscription",
                usageNote: "Covered by the OpenAI · Codex row above; chat message caps are not in local files."
            ),
            ToolStatus(
                source: "cursor",
                title: "Cursor",
                kind: "subscription",
                usageNote: "Plan remaining is not in local files. We do not read Cursor cookies."
            ),
            ToolStatus(
                source: "gemini",
                title: "Gemini",
                kind: "subscription",
                usageNote: "Google AI Pro/Ultra remaining is not in local files."
            ),
            ToolStatus(
                source: "copilot",
                title: "GitHub Copilot",
                kind: "subscription",
                usageNote: "Copilot quota is not in local files."
            ),
            ToolStatus(
                source: "perplexity",
                title: "Perplexity",
                kind: "subscription",
                usageNote: "Pro remaining is not in local files."
            ),
            ToolStatus(
                source: "openrouter",
                title: "OpenRouter",
                kind: "api",
                usageNote: "enable the gateway for this key to poll"
            ),
            ToolStatus(
                source: "xai-api",
                title: "xAI API",
                kind: "api",
                usageNote: "Grok TUI spend is the Grok row. Console API pull needs a billing key."
            ),
        ]
    }
}

struct LiveStatus: Equatable {
    var grok: ToolStatus?
    var claude: ToolStatus?
    var plans: [ToolStatus] = []
    var lastIngestAt: String? = nil
    var catalogVersion: Int = 0

    func jsonObject() -> [String: Any] {
        [
            "plans": plans.map { $0.jsonObject() },
            "last_ingest_at": lastIngestAt as Any? ?? NSNull(),
            "catalog_version": catalogVersion,
        ]
    }

    static func scan(
        grokHome: URL,
        claudeHome: URL,
        grokWeekUsd: Double,
        claudePlan: URL,
        openaiWeekTokens: Int = 0,
        openaiWeekUsdEstimate: Double? = nil,
        codexHome: URL,
        weekPeriod: SpendPeriod? = nil,
        now: Date = Date()
    ) -> LiveStatus {
        let grok = grokRow(weekUsd: grokWeekUsd, period: weekPeriod, home: grokHome, now: now)
        let claude = ClaudeUsageCache.merge(
            ClaudeUsageCache.read(home: claudeHome, now: now),
            into: readClaudePlan(home: claudeHome, extra: claudePlan)
        )
        return LiveStatus(
            grok: grok,
            claude: claude,
            plans: PlanCatalog.rows(
                grok: grok,
                claude: claude,
                openaiWeekTokens: openaiWeekTokens,
                openaiWeekUsdEstimate: openaiWeekUsdEstimate,
                codexHome: codexHome,
                weekPeriod: weekPeriod,
                now: now
            )
        )
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }

    static func formatResets(at iso: String, now: Date) -> String? {
        guard let date = UTC.parse(iso) else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "reset due" }
        return "resets in \(formatDuration(seconds))"
    }

    private static func grokRow(
        weekUsd: Double,
        period: SpendPeriod? = nil,
        home: URL,
        now: Date
    ) -> ToolStatus {
        var row = ToolStatus(
            source: "grok",
            title: "Grok",
            kind: "local",
            weeklyUsd: weekUsd,
            period: period
        )
        let marker = "billing: fetched credits config"
        guard let text = tailText(url: home.appendingPathComponent("logs/unified.jsonl")),
              let line = text.split(separator: "\n").last(where: { $0.contains(marker) }),
              let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))).flatMap(JSONValue.object),
              JSONValue.string(obj["msg"]) == marker
        else { return row }
        let ctx = JSONValue.object(obj["ctx"]) ?? [:]
        let config = JSONValue.object(ctx["config"]) ?? [:]
        let period = JSONValue.object(config["currentPeriod"]) ?? [:]
        row.plan = JSONValue.string(ctx["subscriptionTier"]) ?? JSONValue.string(config["subscriptionTier"])
        row.snapshotAt = JSONValue.string(obj["ts"])
        let end = JSONValue.string(period["end"])
        if let end { row.weeklyResetsAt = UTC.parse(end).map(UTC.iso) ?? end }
        let type = JSONValue.string(period["type"])
        guard type == "USAGE_PERIOD_TYPE_WEEKLY" else {
            row.usageNote = type
            return row
        }
        if let end, let date = UTC.parse(end), date <= now {
            row.usageNote = "Quota resets happened since the last Grok prompt; run a Grok prompt to refresh."
            return row
        }
        row.weeklyPct = percent(config["creditUsagePercent"])
        return row
    }

    static func readClaudePlan(home: URL, extra: URL) -> ToolStatus {
        let empty = ToolStatus(
            source: "claude",
            title: "Claude",
            usageNote: "5-hour and weekly bars are not in local files"
        )
        let candidates = [
            home.appendingPathComponent("plugins/claude-hud/usage.json"),
            extra,
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object)
            else { continue }
            let five = JSONValue.object(obj["five_hour"])
            let week = JSONValue.object(obj["seven_day"])
            let fivePct = five.flatMap { JSONValue.int($0["used_percentage"]) }
            let weekPct = week.flatMap { JSONValue.int($0["used_percentage"]) }
            if fivePct == nil && weekPct == nil { continue }
            return ToolStatus(
                source: "claude",
                title: "Claude",
                fiveHourPct: fivePct,
                fiveHourResetsAt: five.flatMap { JSONValue.string($0["resets_at"]) },
                weeklyPct: weekPct,
                weeklyResetsAt: week.flatMap { JSONValue.string($0["resets_at"]) },
                snapshotAt: JSONValue.string(obj["updated_at"])
            )
        }
        return empty
    }
}

// MARK: - Local quota snapshots (log tails only; never auth.json, never network)

extension LiveStatus {
    static let tailMaxBytes = 256 * 1024

    private struct CodexWindowRaw: Equatable {
        var pct: Int?
        var resetsAtUnix: Int64?
    }

    private struct CodexRateRaw: Equatable {
        var fiveHour: CodexWindowRaw?
        var weekly: CodexWindowRaw?
        var planType: String?
        var snapshotAt: String?
    }

    /// Fills the OpenAI · Codex row from the newest rollout's last rate_limits line
    /// that has a 300- or 10080-minute window. Codex often appends a later `premium`
    /// rate_limits object with null windows; that one is used only if nothing else is.
    static func applyCodexLimits(to row: inout ToolStatus, home: URL, now: Date) {
        guard let url = newestRollout(in: home.appendingPathComponent("sessions", isDirectory: true)),
              let text = tailText(url: url)
        else { return }
        var fallback: CodexRateRaw?
        var chosen: CodexRateRaw?
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let raw = parseCodexLimits(String(line)) else { continue }
            if raw.fiveHour != nil || raw.weekly != nil { chosen = raw; break }
            if fallback == nil { fallback = raw }
        }
        guard let raw = chosen ?? fallback else { return }
        let plan = raw.planType.map { "ChatGPT \($0.capitalized)" }
        (row.fiveHourPct, row.fiveHourResetsAt) = liveWindow(raw.fiveHour, now: now)
        (row.weeklyPct, row.weeklyResetsAt) = liveWindow(raw.weekly, now: now)
        row.plan = plan
        row.snapshotAt = raw.snapshotAt
        row.usageNote = "Codex limits on the \(plan ?? "ChatGPT Plus") plan. Chat message caps are not in local files."
    }

    private static func parseCodexLimits(_ line: String) -> CodexRateRaw? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object)
        else { return nil }
        let payload = JSONValue.object(obj["payload"]) ?? [:]
        guard let limits = JSONValue.object(payload["rate_limits"])
                ?? JSONValue.object(obj["rate_limits"])
        else { return nil }
        var five: CodexWindowRaw?
        var week: CodexWindowRaw?
        for (_, value) in limits {
            guard let win = JSONValue.object(value),
                  let minutes = JSONValue.int(win["window_minutes"]) ?? percent(win["window_minutes"])
            else { continue }
            let raw = CodexWindowRaw(
                pct: percent(win["used_percent"]),
                resetsAtUnix: JSONValue.int64(win["resets_at"])
            )
            if minutes == 300 { five = raw }
            else if minutes == 10080 { week = raw }
        }
        return CodexRateRaw(
            fiveHour: five,
            weekly: week,
            planType: JSONValue.string(limits["plan_type"]),
            snapshotAt: JSONValue.string(obj["timestamp"])
        )
    }

    private static func liveWindow(
        _ raw: CodexWindowRaw?,
        now: Date
    ) -> (pct: Int?, resetsAt: String?) {
        guard let raw else { return (nil, nil) }
        guard let unix = raw.resetsAtUnix else {
            return (raw.pct, nil)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        if date <= now { return (nil, nil) }
        return (raw.pct, UTC.iso(date))
    }

    private static func newestRollout(in sessions: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessions.path),
              let enumerator = fm.enumerator(
                at: sessions,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }
        var best: (url: URL, mtime: Date)?
        while let item = enumerator.nextObject() as? URL {
            if item.path.contains("/archived_sessions/") { continue }
            let name = item.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), !name.hasSuffix(".jsonl.zst")
            else { continue }
            let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if let current = best {
                if mtime > current.mtime || (mtime == current.mtime && item.path > current.url.path) {
                    best = (item, mtime)
                }
            } else {
                best = (item, mtime)
            }
        }
        return best?.url
    }

    /// Last `maxBytes` of a jsonl file. If the file is larger, the first (possibly
    /// mid-line) chunk is dropped so we never parse a split line or the whole file.
    static func tailText(url: URL, maxBytes: Int = tailMaxBytes) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let truncated = size > maxBytes
        let start: UInt64 = truncated ? UInt64(size - maxBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        let data = (try? handle.readToEnd()) ?? Data()
        if truncated, let nl = data.firstIndex(of: 0x0A) {
            let next = data.index(after: nl)
            return String(decoding: data[next...], as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func percent(_ any: Any?) -> Int? {
        if any == nil || any is NSNull { return nil }
        if let n = any as? NSNumber {
            return Int(n.doubleValue.rounded())
        }
        if let d = any as? Double {
            return Int(d.rounded())
        }
        return JSONValue.int(any)
    }
}
