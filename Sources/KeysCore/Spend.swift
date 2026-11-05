import Foundation

extension Int {
    /// `self + other`, held at Int.max or Int.min instead of trapping. A stored row can carry any
    /// count a buggy or hostile source wrote, and one of them must not take `keys spend` or the
    /// dashboard down for good.
    func saturatingAdding(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? Int.max : Int.min) : sum
    }

    mutating func saturatingAdd(_ other: Int) { self = saturatingAdding(other) }
}

enum TokenTotals {
    /// A gateway call counts tokens the way its provider's API reports them: Anthropic's
    /// cache buckets sit beside input, OpenAI-style input already includes cached reads.
    static func normalized(_ event: UsageEvent) -> Int {
        func sum(_ parts: Int...) -> Int { parts.reduce(0) { $0.saturatingAdding($1) } }
        let (i, o, r, w, t) = (event.inputTokens, event.outputTokens, event.cachedReadTokens,
                               event.cacheCreationTokens, event.reasoningTokens)
        if Providers.provider(id: event.provider)?.api == "anthropic" {
            return sum(i, o, r, w)
        }
        return sum(i, o, t)
    }
}

enum ModelPrices {
    struct ListPrice: Equatable, Sendable {
        var inputPerMTok: Double
        var outputPerMTok: Double
        var cacheReadPerMTok: Double
    }

    /// Rows from models.json keyed by lowercased id and provider-stripped id.
    static let cache = FixtureCache<[String: ListPrice]>(
        fileName: "models.json", envKey: "KEYS_MODELS_JSON",
        missing: "models.json missing or empty; using hand price rows only", fallback: [:], parse: parseFixture
    )

    /// Frozen local list prices, checked before models.json on an exact id and alone by
    /// prefix, longest prefix first within each family. Output is always an estimate.
    static let hand: [(prefix: String, price: ListPrice)] = [
        ("claude-fable-5-1", ListPrice(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 0.25)),
        ("claude-fable-5", ListPrice(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 1.00)),
        ("claude-mythos-5", ListPrice(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 0.25)),
        ("claude-opus-5", ListPrice(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.50)),
        ("claude-opus-4-8", ListPrice(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.50)),
        ("claude-opus-4-7", ListPrice(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.50)),
        ("claude-opus-4-6", ListPrice(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.50)),
        ("claude-opus-4-5", ListPrice(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.50)),
        ("claude-sonnet-5", ListPrice(inputPerMTok: 2, outputPerMTok: 10, cacheReadPerMTok: 0.20)),
        ("claude-sonnet-4-6", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("claude-haiku-4-5", ListPrice(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.10)),
        ("claude-opus-4", ListPrice(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50)),
        ("claude-sonnet-4", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("claude-3-7-sonnet", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("claude-3-5-sonnet", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("claude-3-5-haiku", ListPrice(inputPerMTok: 0.80, outputPerMTok: 4, cacheReadPerMTok: 0.080)),
        ("claude-haiku-3.5", ListPrice(inputPerMTok: 0.80, outputPerMTok: 4, cacheReadPerMTok: 0.080)),
        ("claude-3-opus", ListPrice(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50)),
        ("claude-3-sonnet", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("claude-3-haiku", ListPrice(inputPerMTok: 0.25, outputPerMTok: 1.25, cacheReadPerMTok: 0.025)),
        ("claude-haiku", ListPrice(inputPerMTok: 0.80, outputPerMTok: 4, cacheReadPerMTok: 0.080)),
        ("claude-opus", ListPrice(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50)),
        ("claude-sonnet", ListPrice(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.30)),
        ("gpt-5.4", ListPrice(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125)),
        ("gpt-5.3", ListPrice(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125)),
        ("gpt-5", ListPrice(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125)),
        ("gpt-4.1", ListPrice(inputPerMTok: 2, outputPerMTok: 8, cacheReadPerMTok: 0.5)),
        ("gpt-4o-mini", ListPrice(inputPerMTok: 0.15, outputPerMTok: 0.6, cacheReadPerMTok: 0.075)),
        ("gpt-4o", ListPrice(inputPerMTok: 2.5, outputPerMTok: 10, cacheReadPerMTok: 1.25)),
        ("o4-mini", ListPrice(inputPerMTok: 1.1, outputPerMTok: 4.4, cacheReadPerMTok: 0.275)),
        ("o3-mini", ListPrice(inputPerMTok: 1.1, outputPerMTok: 4.4, cacheReadPerMTok: 0.275)),
        ("o3", ListPrice(inputPerMTok: 2, outputPerMTok: 8, cacheReadPerMTok: 0.5)),
        ("codex", ListPrice(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125)),
    ]
    private static let handExact = Dictionary(hand.map { ($0.prefix, $0.price) }, uniquingKeysWith: { first, _ in first })

    static func loadAtStartup() {
        _ = cache.value
    }

    static func lookup(_ model: String) -> ListPrice? {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        let stripped = stripProvider(lower)
        let fixture = cache.value
        if let price = handExact[stripped] ?? handExact[lower] ?? fixture[stripped] ?? fixture[lower] {
            return price
        }
        return hand.first { stripped.hasPrefix($0.prefix) || lower.hasPrefix($0.prefix) }?.price
    }

    /// One list-price formula. When `inputIncludesCacheRead` (OpenAI-style usage), cached reads
    /// are taken out of input before billing it; cache writes cost 1.25x input either way.
    static func usd(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
                    inputIncludesCacheRead: Bool) -> Double? {
        guard let price = lookup(model) else { return nil }
        let m = 1_000_000.0
        let billedInput = inputIncludesCacheRead ? max(0, Double(input) - Double(cacheRead)) : Double(input)
        return (billedInput / m) * price.inputPerMTok
            + (Double(output) / m) * price.outputPerMTok
            + (Double(cacheWrite) / m) * price.inputPerMTok * 1.25
            + (Double(cacheRead) / m) * price.cacheReadPerMTok
    }

    static func stripProvider(_ model: String) -> String {
        if let idx = model.firstIndex(of: "/"), idx != model.startIndex {
            return String(model[model.index(after: idx)...])
        }
        return model
    }

    /// An empty models array counts as missing, so the hand rows alone are used.
    private static func parseFixture(_ data: Data) -> [String: ListPrice]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let models = root["models"] as? [Any], !models.isEmpty
        else { return nil }
        var fixture: [String: ListPrice] = [:]
        for item in models {
            guard let obj = JSONValue.object(item),
                  let id = JSONValue.string(obj["id"])
            else { continue }
            guard let input = JSONValue.double(obj["input_per_mtok"]),
                  let output = JSONValue.double(obj["output_per_mtok"])
            else { continue }
            let cacheRead = JSONValue.double(obj["cache_read_per_mtok"]) ?? 0
            let price = ListPrice(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: cacheRead
            )
            let lowerId = id.lowercased()
            let stripped = stripProvider(lowerId)
            fixture[lowerId] = price
            fixture[stripped] = price
        }
        return fixture
    }
}

struct SpendQueries {
    let db: CatalogDB

    func report(
        range: SpendRange,
        by: SpendGroup,
        now: Date,
        timeZone: TimeZone,
        key: String? = nil,
        provider: String? = nil
    ) throws -> SpendReport {
        let (start, end) = range.interval(now: now, timeZone: timeZone)
        let events = try db.usageEvents(from: UTC.iso(start), to: UTC.iso(end), key: key, provider: provider)
        var assembled = Self.assemble(
            events: events, range: range, by: by, start: start, end: end, now: now, timeZone: timeZone
        )
        assembled.catalogVersion = try db.catalogVersion()
        return assembled
    }

    static func assemble(
        events: [UsageEvent],
        range: SpendRange,
        by: SpendGroup,
        start: Date,
        end: Date,
        now: Date,
        timeZone: TimeZone
    ) -> SpendReport {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        var totals = SpendTotals()
        var estimate: Double = 0
        var hasEstimate = false
        var unpriced = Set<String>()
        for event in events {
            let tok = TokenTotals.normalized(event)
            totals.inputTokens.saturatingAdd(event.inputTokens)
            totals.outputTokens.saturatingAdd(event.outputTokens)
            totals.cachedReadTokens.saturatingAdd(event.cachedReadTokens)
            totals.reasoningTokens.saturatingAdd(event.reasoningTokens)
            totals.tokens.saturatingAdd(tok)
            totals.gatewayTokens.saturatingAdd(tok)
            totals.gatewayCalls.saturatingAdd(1)
            // Dollars stay apart from tokens: an unpriced call must not read as zero.
            if let est = gatewayUsd(event) {
                estimate += est
                hasEstimate = true
                totals.gatewayPricedTokens.saturatingAdd(tok)
            } else {
                unpriced.insert(event.model.isEmpty ? "unknown" : event.model)
                totals.gatewayUnpricedTokens.saturatingAdd(tok)
                totals.gatewayUnpricedCalls.saturatingAdd(1)
            }
        }
        totals.gatewayUsdEstimate = hasEstimate ? estimate : nil
        totals.gatewayUnpricedModels = unpriced.sorted()

        let rows: [SpendRow]
        switch by {
        case .model, .hour:
            rows = groupByModel(events)
        case .key:
            rows = groupByRoute(events, label: Self.keyLabel)
        case .provider:
            rows = groupByRoute(events, label: Self.providerLabel)
        }

        let series: (UsageEvent) -> String = switch by {
        case .key: Self.keyLabel
        case .provider: Self.providerLabel
        default: \.model
        }
        let daily = dailyPoints(events, calendar: cal, series: series)
        // Today draws hourly points; a by=key or by=provider report over today carries them too,
        // stacked by the same series as its rows.
        let points = by == .hour || (range == .today && (by == .key || by == .provider))
            ? hourlyPoints(events, now: now, timeZone: timeZone, series: series)
            : []
        return SpendReport(
            range: range,
            by: by,
            totals: totals,
            rows: rows,
            daily: daily,
            points: points,
            start: start,
            end: end,
            startDay: SpendRange.localDay(start, timeZone: timeZone),
            endDay: SpendRange.inclusiveEndDay(end: end, timeZone: timeZone)
        )
    }

    /// What one call cost: the provider's receipt, else a list-price estimate. Nil means
    /// unknown, never zero.
    static func gatewayUsd(_ event: UsageEvent) -> Double? {
        // A reported zero is a known zero; only an absent receipt is unknown.
        if let ticks = event.costUsdTicks { return Ticks.usd(ticks) }
        // The recorder normalizes absent token counts to zero, so a call whose provider reported
        // no usage at all arrives here as all-zero counters. Pricing those would publish $0.00 as
        // a known cost for a call nothing is known about. A genuine zero-token call with no cost
        // receipt is treated as unknown too, which is the conservative direction.
        guard event.tokenCount > 0 else { return nil }
        let model = event.model.isEmpty ? nil : event.model
        return GatewayEstimate.usd(
            model: model,
            input: event.inputTokens,
            output: event.outputTokens,
            cacheRead: event.cachedReadTokens,
            cacheWrite: event.cacheCreationTokens,
            api: Providers.provider(id: event.provider)?.api
        )
    }

    private static func byTotal(_ lhs: SpendRow, _ rhs: SpendRow) -> Bool? {
        let lu = lhs.usd ?? lhs.usdEstimate ?? 0
        let ru = rhs.usd ?? rhs.usdEstimate ?? 0
        return lu != ru ? lu > ru : nil
    }

    private static func groupByModel(_ events: [UsageEvent]) -> [SpendRow] {
        struct AccKey: Hashable { var model: String; var key: String? }
        var acc: [AccKey: SpendRow] = [:]
        for event in events {
            let accKey = AccKey(model: event.model, key: event.keyName)
            var row = acc[accKey] ?? SpendRow(model: event.model, key: event.keyName)
            if !event.provider.isEmpty { row.provider = event.provider }
            row.add(event)
            acc[accKey] = row
        }
        return acc.values.sorted { lhs, rhs in
            if let order = byTotal(lhs, rhs) { return order }
            if (lhs.model ?? "") != (rhs.model ?? "") { return (lhs.model ?? "") < (rhs.model ?? "") }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }
    }

    /// The series name a by=key or by=provider row and its daily points share. Rows carry it
    /// in `model` so the chart, the list and click-to-isolate work unchanged.
    static func keyLabel(_ event: UsageEvent) -> String { event.keyName ?? "" }
    static func providerLabel(_ event: UsageEvent) -> String {
        Providers.provider(id: event.provider)?.name ?? event.provider
    }

    private static func groupByRoute(_ events: [UsageEvent], label: (UsageEvent) -> String) -> [SpendRow] {
        var acc: [String: SpendRow] = [:]
        var models: [String: Set<String>] = [:]
        for event in events {
            let name = label(event)
            var row = acc[name] ?? SpendRow(model: name)
            if row.key == nil, event.keyName == name { row.key = name }
            if row.provider == nil, !event.provider.isEmpty, Self.providerLabel(event) == name || row.key != nil {
                row.provider = event.provider
            }
            row.add(event)
            acc[name] = row
            if !event.model.isEmpty { models[name, default: []].insert(event.model) }
        }
        for (name, set) in models { acc[name]?.models = set.sorted() }
        return acc.values.sorted { lhs, rhs in
            if let order = byTotal(lhs, rhs) { return order }
            return (lhs.model ?? "") < (rhs.model ?? "")
        }
    }

    /// Chart buckets: one per (bucket, series), sorted by both. `bucket` returns nil to skip an event.
    /// Each bucket's token total is the row's own counted total, so a bar and a legend row
    /// cannot disagree about the same records.
    private static func points(
        _ events: [UsageEvent], bucket: (Date) -> String?, series: (UsageEvent) -> String
    ) -> [(bucket: String, series: String, row: SpendRow, tokens: Int)] {
        struct Key: Hashable { var bucket: String; var series: String }
        var acc: [Key: SpendRow] = [:]
        for event in events {
            guard let date = UTC.parse(event.occurredAt), let b = bucket(date) else { continue }
            let key = Key(bucket: b, series: series(event))
            var row = acc[key] ?? SpendRow()
            row.add(event)
            acc[key] = row
        }
        return acc.keys.sorted { ($0.bucket, $0.series) < ($1.bucket, $1.series) }.map { key in
            let row = acc[key]!
            return (key.bucket, key.series, row, row.countedTokens)
        }
    }

    private static func dailyPoints(
        _ events: [UsageEvent], calendar: Calendar, series: @escaping (UsageEvent) -> String = \.model
    ) -> [DailyPoint] {
        let day = { (date: Date) -> String? in SpendRange.localDay(date, timeZone: calendar.timeZone) }
        return points(events, bucket: day, series: series).map { point in
            DailyPoint(
                day: point.bucket,
                model: point.series,
                usd: point.row.usd,
                tokens: point.tokens,
                inputTokens: point.row.inputTokens,
                outputTokens: point.row.outputTokens,
                cachedReadTokens: point.row.cachedReadTokens,
                cacheCreationTokens: point.row.cacheCreationTokens,
                usdEstimate: point.row.usdEstimate,
                modelCalls: point.row.modelCalls
            )
        }
    }

    /// One point per (elapsed local hour, model). Hours after `now` are dropped.
    private static func hourlyPoints(
        _ events: [UsageEvent], now: Date, timeZone: TimeZone, series: @escaping (UsageEvent) -> String = \.model
    ) -> [HourlyPoint] {
        let today = SpendRange.localDay(now, timeZone: timeZone)
        let currentHour = SpendRange.localHour(now, timeZone: timeZone)
        let hour = { (date: Date) -> String? in
            guard SpendRange.localDay(date, timeZone: timeZone) == today else { return nil }
            let hour = SpendRange.localHour(date, timeZone: timeZone)
            return hour <= currentHour ? hour : nil
        }
        return points(events, bucket: hour, series: series).map { point in
            HourlyPoint(
                hour: point.bucket,
                model: point.series,
                usd: point.row.usd,
                tokens: point.tokens,
                inputTokens: point.row.inputTokens,
                outputTokens: point.row.outputTokens,
                cachedReadTokens: point.row.cachedReadTokens,
                cacheCreationTokens: point.row.cacheCreationTokens,
                usdEstimate: point.row.usdEstimate,
                modelCalls: point.row.modelCalls
            )
        }
    }
}

extension SpendRow {
    /// Adds one event's tokens and cost. `usd` and `usdEstimate` stay nil until a priced event
    /// arrives, so an unpriced row reads as unknown rather than $0.
    mutating func add(_ event: UsageEvent) {
        inputTokens.saturatingAdd(event.inputTokens)
        outputTokens.saturatingAdd(event.outputTokens)
        cachedReadTokens.saturatingAdd(event.cachedReadTokens)
        cacheCreationTokens.saturatingAdd(event.cacheCreationTokens)
        reasoningTokens.saturatingAdd(event.reasoningTokens)
        modelCalls.saturatingAdd(event.modelCalls ?? 0)
        // The row's counted total is stated once, here, under the provider's own rule, so no
        // reader has to guess one from the model name.
        countedTokens.saturatingAdd(TokenTotals.normalized(event))
        if let estimate = SpendQueries.gatewayUsd(event) { usdEstimate = (usdEstimate ?? 0) + estimate }
    }
}
