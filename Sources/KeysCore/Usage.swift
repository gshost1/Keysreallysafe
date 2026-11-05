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
    var modelCalls: Int?
    var inputTokens: Int
    var outputTokens: Int
    var cachedReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var reasoningTokens: Int = 0
    var costUsdTicks: Int64?
    var keyName: String? = nil
    /// Upstream HTTP status of a gateway call; nil for local events.
    var httpStatus: Int? = nil
    /// Gateway calls only: how long the call took, the host it went to and why it ended
    /// (`GatewayReason`). Nil for local events and for gateway rows stored before they were kept.
    var durationMs: Int? = nil
    var upstreamHost: String? = nil
    var reason: String? = nil

    var tokenCount: Int {
        inputTokens.saturatingAdding(outputTokens).saturatingAdding(cachedReadTokens)
            .saturatingAdding(cacheCreationTokens).saturatingAdding(reasoningTokens)
    }
}

struct CatalogRow: Equatable {
    var name: String
    var provider: String
    var kind: String
    var notes: String
    var createdAt: String
    var lastUsedAt: String?
    var gatewayHost: String? = nil
    var version: Int = 1
    /// Ask an aggregator for its cheapest upstream (`CheapestRouting`). Off unless turned on.
    var gatewayCheapest: Bool = false
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

enum SpendGroup: String {
    case model
    case hour
    /// One row per vault key, or per provider the keys route to.
    case key
    case provider
}

/// The gateway ledger's totals: calls this Mac routed through a key in the vault. Token
/// totals count every call; dollars only the ones with a receipt or a list price, so an
/// unpriced call never reads as $0.
struct SpendTotals: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var reasoningTokens: Int = 0
    var tokens: Int = 0
    var gatewayUsdEstimate: Double?
    var gatewayTokens: Int = 0
    var gatewayCalls: Int = 0
    var gatewayPricedTokens: Int = 0
    var gatewayUnpricedTokens: Int = 0
    var gatewayUnpricedCalls: Int = 0
    var gatewayUnpricedModels: [String] = []
}

struct SpendRow: Equatable {
    var model: String?
    var models: [String] = []
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var reasoningTokens: Int = 0
    var modelCalls: Int = 0
    /// The row's tokens counted under each call's provider rule (`TokenTotals.normalized`),
    /// summed as calls are added, so the chart never re-derives a rule from the model name.
    var countedTokens: Int = 0
    var usd: Double?
    var usdEstimate: Double?
    var key: String? = nil
    /// The provider the vault key routes to (`typesafe`, `vercel-ai-gateway`, …).
    var provider: String? = nil
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
    /// Gateway requests in this bucket. Lets a chart show requests when tokens are unknown.
    var modelCalls: Int = 0
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
    /// Upstream calls in this bucket; see `DailyPoint.modelCalls`.
    var modelCalls: Int = 0
}

struct SpendReport: Equatable {
    var range: SpendRange
    var by: SpendGroup
    var caption: String = SpendReport.captionText
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
    var catalogVersion: Int = 0

    static let captionText = "API-key calls through the local gateway — dollars are receipts or list-price estimates"

    func jsonObject() -> [String: Any] {
        let totalsObj: [String: Any] = [
            "input_tokens": totals.inputTokens,
            "output_tokens": totals.outputTokens,
            "cached_read_tokens": totals.cachedReadTokens,
            "reasoning_tokens": totals.reasoningTokens,
            "tokens": totals.tokens,
            "gateway_usd_estimate": totals.gatewayUsdEstimate as Any? ?? NSNull(),
            "gateway_tokens": totals.gatewayTokens,
            "gateway_calls": totals.gatewayCalls,
            "gateway_priced_tokens": totals.gatewayPricedTokens,
            "gateway_unpriced_tokens": totals.gatewayUnpricedTokens,
            "gateway_unpriced_calls": totals.gatewayUnpricedCalls,
            "gateway_unpriced_models": totals.gatewayUnpricedModels,
        ]
        return [
            "range": range.rawValue,
            "by": by.rawValue,
            "caption": caption,
            "start": UTC.iso(start),
            "end": UTC.iso(end),
            "start_day": startDay,
            "end_day": endDay,
            "catalog_version": catalogVersion,
            "totals": totalsObj,
            "rows": rows.map { $0.jsonObject() },
            "daily": daily.map { point -> [String: Any] in
                [
                    "day": point.day,
                    "model": point.model,
                    "usd": point.usd as Any? ?? NSNull(),
                    "tokens": point.tokens,
                    "input_tokens": point.inputTokens,
                    "output_tokens": point.outputTokens,
                    "cached_read_tokens": point.cachedReadTokens,
                    "cache_creation_tokens": point.cacheCreationTokens,
                    "usd_estimate": point.usdEstimate as Any? ?? NSNull(),
                    "model_calls": point.modelCalls,
                ]
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
                    "model_calls": point.modelCalls,
                ]
            },
        ]
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
            "counted_tokens": countedTokens,
            "model_calls": modelCalls,
            "usd": usd as Any? ?? NSNull(),
            "usd_estimate": usdEstimate as Any? ?? NSNull(),
        ]
        if let model { obj["model"] = model }
        if let key { obj["key"] = key }
        if let provider { obj["provider"] = provider }
        if !models.isEmpty { obj["models"] = models }
        return obj
    }
}
