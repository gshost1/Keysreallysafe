import Foundation

struct ToolStatus: Equatable {
    var source: String
    var title: String
    var kind: String = "local"
    var contextPct: Int?
    var contextUsed: Int?
    var contextWindow: Int?
    var durationSeconds: Int?
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
    var onDemandUsed: Int? = nil
    var onDemandCap: Int? = nil
    var limitReached: String? = nil
    var limit: Double? = nil
    var limitRemaining: Double? = nil
    var usageWeekly: Double? = nil

    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "source": source,
            "title": title,
            "kind": kind,
            "five_hour_pct": fiveHourPct as Any? ?? NSNull(),
            "five_hour_resets_at": fiveHourResetsAt as Any? ?? NSNull(),
            "weekly_pct": weeklyPct as Any? ?? NSNull(),
            "weekly_resets_at": weeklyResetsAt as Any? ?? NSNull(),
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
        if let onDemandCap, onDemandCap > 0 {
            obj["on_demand_cap"] = onDemandCap
            obj["on_demand_used"] = onDemandUsed as Any? ?? NSNull()
        }
        if let limitReached {
            obj["limit_reached"] = limitReached
        }
        return obj
    }
}

enum PlanCatalog {
    static let providers = [
        "openai", "anthropic", "xai", "grok", "openrouter", "google", "gemini",
        "cursor", "copilot", "perplexity", "groq", "mistral", "deepseek",
        "together", "fireworks", "azure-openai", "huggingface",
    ]

    static func rows(
        grok: ToolStatus,
        claude: ToolStatus,
        openaiWeekTokens: Int,
        openaiWeekUsdEstimate: Double?,
        codexHome: URL,
        weekPeriod: SpendPeriod? = nil,
        openaiLimits: CodexRateSnapshot? = nil
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
        if let limits = openaiLimits {
            openai.fiveHourPct = limits.fiveHourPct
            openai.fiveHourResetsAt = limits.fiveHourResetsAt
            openai.weeklyPct = limits.weeklyPct
            openai.weeklyResetsAt = limits.weeklyResetsAt
            openai.plan = limits.plan
            openai.snapshotAt = limits.snapshotAt
            openai.limitReached = limits.limitReached
            openai.usageNote = limits.usageNote
        }
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
                source: "codex",
                title: "Codex",
                kind: "local",
                weeklyTokens: openaiWeekTokens,
                usageNote: hasCodexSessions || openaiWeekTokens > 0
                    ? nil
                    : "No ~/.codex/sessions on this Mac.",
                period: weekPeriod
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

struct CodexRateSnapshot: Equatable {
    var fiveHourPct: Int?
    var fiveHourResetsAt: String?
    var weeklyPct: Int?
    var weeklyResetsAt: String?
    var plan: String?
    var snapshotAt: String?
    var limitReached: String?
    var usageNote: String
}

struct LiveStatus: Equatable {
    var grok: ToolStatus?
    var claude: ToolStatus?
    var plans: [ToolStatus] = []
    var lastIngestAt: String? = nil
    var catalogVersion: Int = 0

    func jsonObject() -> [String: Any] {
        [
            "grok": grok?.jsonObject() as Any? ?? NSNull(),
            "claude": claude?.jsonObject() as Any? ?? NSNull(),
            "plans": plans.map { $0.jsonObject() },
            "providers": PlanCatalog.providers,
            "caption": "Plan % only when cached locally. Dollars and tokens are local logs, not a remaining bar. We do not scrape provider websites.",
            "last_ingest_at": lastIngestAt as Any? ?? NSNull(),
            "catalog_version": catalogVersion,
        ]
    }

    static func scan(
        grokHome: URL,
        claudeHome: URL,
        grokWeekUsd: Double,
        claudePlan: URL = Paths.appSupport.appendingPathComponent("claude-plan.json"),
        openaiWeekTokens: Int = 0,
        openaiWeekUsdEstimate: Double? = nil,
        codexHome: URL = Paths.codexHome,
        weekPeriod: SpendPeriod? = nil,
        now: Date = Date()
    ) throws -> LiveStatus {
        let grok = grokRow(weekUsd: grokWeekUsd, period: weekPeriod, home: grokHome, now: now)
        let claude = readClaudePlan(home: claudeHome, extra: claudePlan)
        let openaiLimits = readCodexLimits(home: codexHome, now: now)
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
                openaiLimits: openaiLimits
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
        guard let snap = readGrokCredits(home: home, now: now) else { return row }
        row.weeklyPct = snap.weeklyPct
        row.weeklyResetsAt = snap.weeklyResetsAt
        row.plan = snap.plan
        row.snapshotAt = snap.snapshotAt
        row.usageNote = snap.usageNote
        row.onDemandUsed = snap.onDemandUsed
        row.onDemandCap = snap.onDemandCap
        return row
    }

    private static func readClaudePlan(home: URL, extra: URL) -> ToolStatus {
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

    private struct FileStamp: Equatable {
        var path: String
        var size: Int64
        var mtimeMs: Int64
    }

    private struct GrokCreditsRaw: Equatable {
        var creditUsagePercent: Int?
        var periodType: String?
        var periodEnd: String?
        var plan: String?
        var snapshotAt: String?
        var onDemandUsed: Int?
        var onDemandCap: Int?
    }

    private struct GrokCreditsSnapshot {
        var weeklyPct: Int?
        var weeklyResetsAt: String?
        var plan: String?
        var snapshotAt: String?
        var usageNote: String?
        var onDemandUsed: Int?
        var onDemandCap: Int?
    }

    private struct CodexWindowRaw: Equatable {
        var pct: Int?
        var resetsAtUnix: Int64?
    }

    private struct CodexRateRaw: Equatable {
        var fiveHour: CodexWindowRaw?
        var weekly: CodexWindowRaw?
        var planType: String?
        var snapshotAt: String?
        var limitReached: String?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var grokCache: (FileStamp, GrokCreditsRaw)?
    nonisolated(unsafe) private static var openaiCache: (FileStamp, CodexRateRaw)?

    private static func readGrokCredits(home: URL, now: Date) -> GrokCreditsSnapshot? {
        let url = home.appendingPathComponent("logs/unified.jsonl")
        guard let stamp = fileStamp(url),
              let raw = grokRaw(url: url, stamp: stamp)
        else { return nil }
        return applyGrok(raw, now: now)
    }

    private static func grokRaw(url: URL, stamp: FileStamp) -> GrokCreditsRaw? {
        cacheLock.lock()
        if let cached = grokCache, cached.0 == stamp {
            let raw = cached.1
            cacheLock.unlock()
            return raw
        }
        cacheLock.unlock()
        guard let text = tailText(url: url),
              let line = lastLine(in: text, containing: "billing: fetched credits config"),
              let raw = parseGrokBilling(line)
        else { return nil }
        cacheLock.lock()
        grokCache = (stamp, raw)
        cacheLock.unlock()
        return raw
    }

    private static func parseGrokBilling(_ line: String) -> GrokCreditsRaw? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              JSONValue.string(obj["msg"]) == "billing: fetched credits config"
        else { return nil }
        let ctx = JSONValue.object(obj["ctx"]) ?? [:]
        let config = JSONValue.object(ctx["config"]) ?? [:]
        let period = JSONValue.object(config["currentPeriod"]) ?? [:]
        let cap = wrappedVal(config["onDemandCap"])
        let used = wrappedVal(config["onDemandUsed"])
        return GrokCreditsRaw(
            creditUsagePercent: percent(config["creditUsagePercent"]),
            periodType: JSONValue.string(period["type"]),
            periodEnd: JSONValue.string(period["end"]),
            plan: JSONValue.string(ctx["subscriptionTier"])
                ?? JSONValue.string(config["subscriptionTier"]),
            snapshotAt: JSONValue.string(obj["ts"]),
            onDemandUsed: used,
            onDemandCap: cap
        )
    }

    private static func applyGrok(_ raw: GrokCreditsRaw, now: Date) -> GrokCreditsSnapshot {
        var snap = GrokCreditsSnapshot(
            plan: raw.plan,
            snapshotAt: raw.snapshotAt
        )
        if let cap = raw.onDemandCap, cap > 0 {
            snap.onDemandCap = cap
            snap.onDemandUsed = raw.onDemandUsed
        }
        if let end = raw.periodEnd {
            snap.weeklyResetsAt = isoNormalize(end) ?? end
        }
        guard raw.periodType == "USAGE_PERIOD_TYPE_WEEKLY" else {
            snap.usageNote = raw.periodType
            return snap
        }
        if let end = raw.periodEnd, let date = UTC.parse(end), date <= now {
            snap.weeklyPct = nil
            snap.usageNote = "Quota resets happened since the last Grok prompt; run a Grok prompt to refresh."
            return snap
        }
        snap.weeklyPct = raw.creditUsagePercent
        return snap
    }

    static func readCodexLimits(home: URL, now: Date) -> CodexRateSnapshot? {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let url = newestRollout(in: sessions),
              let stamp = fileStamp(url),
              let raw = openaiRaw(url: url, stamp: stamp)
        else { return nil }
        return applyCodex(raw, now: now)
    }

    private static func openaiRaw(url: URL, stamp: FileStamp) -> CodexRateRaw? {
        cacheLock.lock()
        if let cached = openaiCache, cached.0 == stamp {
            let raw = cached.1
            cacheLock.unlock()
            return raw
        }
        cacheLock.unlock()
        guard let text = tailText(url: url) else { return nil }
        // Last line with a 300/10080 window. Codex often appends a later
        // `premium` rate_limits object with null primary/secondary; skip those.
        var fallback: CodexRateRaw?
        var chosen: CodexRateRaw?
        var end = text.endIndex
        while end > text.startIndex {
            let slice = text[..<end]
            let start: String.Index
            if let nl = slice.lastIndex(of: "\n") {
                start = text.index(after: nl)
            } else {
                start = text.startIndex
            }
            let line = text[start..<end]
            if line.contains("\"rate_limits\""),
               let raw = parseCodexLimits(String(line))
            {
                if raw.fiveHour != nil || raw.weekly != nil {
                    chosen = raw
                    break
                }
                if fallback == nil { fallback = raw }
            }
            if start == text.startIndex { break }
            end = text.index(before: start)
        }
        guard let raw = chosen ?? fallback else { return nil }
        cacheLock.lock()
        openaiCache = (stamp, raw)
        cacheLock.unlock()
        return raw
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
        let reached = scalar(limits["rate_limit_reached_type"])
        return CodexRateRaw(
            fiveHour: five,
            weekly: week,
            planType: JSONValue.string(limits["plan_type"]),
            snapshotAt: JSONValue.string(obj["timestamp"]),
            limitReached: reached
        )
    }

    private static func applyCodex(_ raw: CodexRateRaw, now: Date) -> CodexRateSnapshot {
        let planType = raw.planType
        let plan = planType.map { "ChatGPT \($0.capitalized)" }
        let planForNote = plan ?? "ChatGPT Plus"
        let five = liveWindow(raw.fiveHour, now: now)
        let week = liveWindow(raw.weekly, now: now)
        return CodexRateSnapshot(
            fiveHourPct: five.pct,
            fiveHourResetsAt: five.resetsAt,
            weeklyPct: week.pct,
            weeklyResetsAt: week.resetsAt,
            plan: plan,
            snapshotAt: raw.snapshotAt,
            limitReached: raw.limitReached,
            usageNote: "Codex limits on the \(planForNote) plan. Chat message caps are not in local files."
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

    private static func fileStamp(_ url: URL) -> FileStamp? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let size = Int64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate ?? Date.distantPast
        let mtimeMs = Int64((mtime.timeIntervalSince1970 * 1000.0).rounded())
        return FileStamp(path: url.standardizedFileURL.path, size: size, mtimeMs: mtimeMs)
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

    private static func lastLine(in text: String, containing needle: String) -> String? {
        var end = text.endIndex
        while end > text.startIndex {
            let slice = text[..<end]
            let start: String.Index
            if let nl = slice.lastIndex(of: "\n") {
                start = text.index(after: nl)
            } else {
                start = text.startIndex
            }
            let line = text[start..<end]
            if line.contains(needle) {
                return String(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if start == text.startIndex { break }
            end = text.index(before: start)
        }
        return nil
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

    private static func wrappedVal(_ any: Any?) -> Int? {
        if let obj = JSONValue.object(any) {
            return percent(obj["val"]) ?? JSONValue.int(obj["val"])
        }
        return JSONValue.int(any)
    }

    private static func scalar(_ any: Any?) -> String? {
        if any == nil || any is NSNull { return nil }
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let n = any as? NSNumber { return n.stringValue }
        if let b = any as? Bool { return b ? "true" : "false" }
        return nil
    }

    private static func isoNormalize(_ string: String) -> String? {
        UTC.parse(string).map(UTC.iso)
    }
}
