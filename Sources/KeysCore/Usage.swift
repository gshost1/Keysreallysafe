import Foundation

struct UsageEvent: Equatable {
    var source: String
    var sessionId: String
    var promptId: String
    var model: String
    var occurredAt: String
    var provider: String
    var cwd: String?
    var sessionTitle: String?
    var agentName: String?
    var stopReason: String?
    var modelCalls: Int?
    var apiDurationMs: Int?
    var inputTokens: Int
    var outputTokens: Int
    var cachedReadTokens: Int
    var cacheCreationTokens: Int
    var reasoningTokens: Int
    var costUsdTicks: Int64?
    var keyName: String? = nil

    var tokenCount: Int {
        inputTokens + outputTokens + cachedReadTokens + cacheCreationTokens + reasoningTokens
    }

    var hasUsage: Bool {
        tokenCount != 0 || (costUsdTicks ?? 0) != 0
    }
}

struct CatalogRow: Equatable {
    var name: String
    var provider: String
    var kind: String
    var notes: String
    var createdAt: String
    var lastUsedAt: String?
    var gatewayEnabled: Bool = false
    var gatewayHost: String? = nil
    var version: Int = 1
}

struct IngestReport: Equatable {
    var filesScanned: Int = 0
    var rowsInserted: Int = 0
    var rowsUpdated: Int = 0
    var skippedDupes: Int = 0
    var parseErrors: Int = 0

    var line: String {
        "files=\(filesScanned) inserted=\(rowsInserted) updated=\(rowsUpdated) skipped=\(skippedDupes) errors=\(parseErrors)"
    }
}

enum SourceFilter: String {
    case all
    case grok
    case claude
    case openai

    var sqlValues: [String]? {
        switch self {
        case .all: return nil
        case .grok: return ["grok-local"]
        case .claude: return ["claude-local"]
        case .openai: return ["codex-local", "openai-api"]
        }
    }
}

enum SpendRange: String {
    case month
    case week
    case today

    /// Inclusive start, exclusive end, in `timeZone`.
    /// Week is the locale calendar week (`weekOfYear`), which may begin in the previous month.
    func interval(now: Date, timeZone: TimeZone) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        switch self {
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps)!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .week:
            let interval = cal.dateInterval(of: .weekOfYear, for: now)!
            return (interval.start, interval.end)
        case .today:
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        }
    }

    static func localDay(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Local hour bucket `YYYY-MM-DDTHH:00` in `timeZone`.
    static func localHour(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:00",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0,
            comps.hour ?? 0
        )
    }

    /// Inclusive local YYYY-MM-DD of the last instant in `[start, end)`.
    static func inclusiveEndDay(end: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let last = cal.date(byAdding: .second, value: -1, to: end) ?? end
        return localDay(last, timeZone: timeZone)
    }
}

struct SpendPeriod: Equatable {
    var startDay: String
    var endDay: String
    var label: String

    func jsonObject() -> [String: Any] {
        [
            "start_day": startDay,
            "end_day": endDay,
            "label": label,
        ]
    }

    static func calendarWeek(now: Date, timeZone: TimeZone) -> SpendPeriod {
        let (start, end) = SpendRange.week.interval(now: now, timeZone: timeZone)
        return SpendPeriod(
            startDay: SpendRange.localDay(start, timeZone: timeZone),
            endDay: SpendRange.inclusiveEndDay(end: end, timeZone: timeZone),
            label: label(start: start, endExclusive: end, timeZone: timeZone)
        )
    }

    static func label(start: Date, endExclusive: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let last = cal.date(byAdding: .second, value: -1, to: endExclusive) ?? endExclusive
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "EEE MMM d"
        return "\(df.string(from: start)) – \(df.string(from: last))"
    }
}

enum SpendGroup: String {
    case model
    case session
    case hour
    case project
}

struct SpendTotals: Equatable {
    var grokUsd: Double = 0
    var claudeTokens: Int = 0
    var claudeUsdEstimate: Double?
    var openaiTokens: Int = 0
    var openaiUsdEstimate: Double?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var reasoningTokens: Int = 0
    var claudeUnpricedModels: [String] = []
    var claudePricedTokens: Int = 0
    var claudeUnpricedTokens: Int = 0
    var openaiUnpricedModels: [String] = []
    var openaiPricedTokens: Int = 0
    var openaiUnpricedTokens: Int = 0
    var gatewayUsdEstimate: Double?
    var usdEstimate: Double?
    var tokens: Int = 0
    var tokenRule: String = TokenTotals.rule
}

struct SpendRow: Equatable {
    var model: String?
    var sessionId: String?
    var source: String?
    var cwd: String?
    var title: String?
    var models: [String] = []
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var reasoningTokens: Int = 0
    var modelCalls: Int = 0
    var usd: Double?
    var usdEstimate: Double?
    var key: String? = nil
    var project: String? = nil
}

struct DailyPoint: Equatable {
    var day: String
    var model: String
    var usd: Double?
    var tokens: Int
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var usdEstimate: Double?
    var project: String? = nil
    var cwd: String? = nil
}

struct HourlyPoint: Equatable {
    var hour: String
    var model: String
    var usd: Double?
    var tokens: Int
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var usdEstimate: Double?
}

struct SpendReport: Equatable {
    var range: SpendRange
    var by: SpendGroup
    var source: SourceFilter
    var caption: String
    var totals: SpendTotals
    var rows: [SpendRow]
    var daily: [DailyPoint]
    /// Hourly buckets for `range=today&by=hour`. Same fields as `daily` with `day` → `hour`.
    var points: [HourlyPoint] = []
    /// Inclusive interval start used in the usage query (`occurred_at >= start`).
    var start: Date = .distantPast
    /// Exclusive interval end used in the usage query (`occurred_at < end`).
    var end: Date = .distantFuture
    /// Local calendar day of `start` (YYYY-MM-DD).
    var startDay: String = ""
    /// Inclusive local calendar day of the last instant in `[start, end)`.
    var endDay: String = ""
    var lastIngestAt: String? = nil
    var catalogVersion: Int = 0

    static let captionText = "local tool spend on this Mac — not a subscription remaining bar"

    func jsonObject() -> [String: Any] {
        var totalsObj: [String: Any] = [
            "grok_usd": totals.grokUsd,
            "claude_tokens": totals.claudeTokens,
            "openai_tokens": totals.openaiTokens,
            "input_tokens": totals.inputTokens,
            "output_tokens": totals.outputTokens,
            "cached_read_tokens": totals.cachedReadTokens,
            "reasoning_tokens": totals.reasoningTokens,
            "claude_unpriced_models": totals.claudeUnpricedModels,
            "claude_priced_tokens": totals.claudePricedTokens,
            "claude_unpriced_tokens": totals.claudeUnpricedTokens,
            "openai_unpriced_models": totals.openaiUnpricedModels,
            "openai_priced_tokens": totals.openaiPricedTokens,
            "openai_unpriced_tokens": totals.openaiUnpricedTokens,
            "gateway_usd_estimate": totals.gatewayUsdEstimate as Any? ?? NSNull(),
            "usd_estimate": totals.usdEstimate as Any? ?? NSNull(),
            "tokens": totals.tokens,
            "token_rule": totals.tokenRule,
        ]
        if let est = totals.claudeUsdEstimate {
            totalsObj["claude_usd_estimate"] = est
        } else {
            totalsObj["claude_usd_estimate"] = NSNull()
        }
        if totals.claudeTokens > 0 || !totals.claudeUnpricedModels.isEmpty {
            totalsObj["claude_usd_estimate_label"] = EstimateLabel.text(
                unpricedCount: totals.claudeUnpricedModels.count
            )
        }
        if let est = totals.openaiUsdEstimate {
            totalsObj["openai_usd_estimate"] = est
        } else {
            totalsObj["openai_usd_estimate"] = NSNull()
        }
        if totals.openaiTokens > 0 || !totals.openaiUnpricedModels.isEmpty {
            totalsObj["openai_usd_estimate_label"] = EstimateLabel.text(
                unpricedCount: totals.openaiUnpricedModels.count
            )
        }
        return [
            "range": range.rawValue,
            "by": by.rawValue,
            "source": source.rawValue,
            "caption": caption,
            "start": UTC.iso(start),
            "end": UTC.iso(end),
            "start_day": startDay,
            "end_day": endDay,
            "last_ingest_at": lastIngestAt as Any? ?? NSNull(),
            "catalog_version": catalogVersion,
            "totals": totalsObj,
            "rows": rows.map { $0.jsonObject() },
            "daily": daily.map { point -> [String: Any] in
                var obj: [String: Any] = [
                    "day": point.day,
                    "model": point.model,
                    "usd": point.usd as Any? ?? NSNull(),
                    "tokens": point.tokens,
                    "input_tokens": point.inputTokens,
                    "output_tokens": point.outputTokens,
                    "cached_read_tokens": point.cachedReadTokens,
                    "cache_creation_tokens": point.cacheCreationTokens,
                    "usd_estimate": point.usdEstimate as Any? ?? NSNull(),
                ]
                if let project = point.project { obj["project"] = project }
                if let cwd = point.cwd { obj["cwd"] = cwd }
                return obj
            },
            "points": points.map { point -> [String: Any] in
                [
                    "hour": point.hour,
                    "model": point.model,
                    "usd": point.usd as Any? ?? NSNull(),
                    "tokens": point.tokens,
                    "input_tokens": point.inputTokens,
                    "output_tokens": point.outputTokens,
                    "cached_read_tokens": point.cachedReadTokens,
                    "cache_creation_tokens": point.cacheCreationTokens,
                    "usd_estimate": point.usdEstimate as Any? ?? NSNull(),
                ]
            },
        ]
    }
}

enum EstimateLabel {
    static func text(unpricedCount: Int) -> String {
        if unpricedCount <= 0 { return "estimate, not invoice" }
        let noun = unpricedCount == 1 ? "model" : "models"
        return "estimate, not invoice; \(unpricedCount) \(noun) unpriced"
    }
}

extension SpendRow {
    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cached_read_tokens": cachedReadTokens,
            "cache_creation_tokens": cacheCreationTokens,
            "reasoning_tokens": reasoningTokens,
            "model_calls": modelCalls,
            "usd": usd as Any? ?? NSNull(),
            "usd_estimate": usdEstimate as Any? ?? NSNull(),
        ]
        if let model { obj["model"] = model }
        if let sessionId { obj["session_id"] = sessionId }
        if let source { obj["source"] = source }
        if let cwd { obj["cwd"] = cwd }
        if let title { obj["title"] = title }
        if let key { obj["key"] = key }
        if let project { obj["project"] = project }
        if !models.isEmpty { obj["models"] = models }
        return obj
    }
}
