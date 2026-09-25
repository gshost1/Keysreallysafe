import Foundation

enum OpenAIEstimate {
    /// Input already includes cached reads; reasoning is billed as output.
    static func usd(model: String, input: Int, output: Int, cacheRead: Int, reasoning: Int) -> Double? {
        ModelPrices.usd(model: model, input: input, output: output + reasoning, cacheRead: cacheRead, cacheWrite: 0,
                        inputIncludesCacheRead: true)
    }
}

enum ClaudeEstimate {
    /// Cache reads and writes are billed on top of input; writes at 1.25x input.
    static func usd(model: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double? {
        ModelPrices.usd(model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheCreate,
                        inputIncludesCacheRead: false)
    }
}

enum TokenTotals {
    /// Claude includes cache tokens; Codex and Grok exclude cached reads and include reasoning;
    /// a gateway call follows its provider's API.
    static func normalized(_ event: UsageEvent) -> Int {
        switch event.source {
        case "claude-local":
            return event.inputTokens + event.outputTokens
                + event.cachedReadTokens + event.cacheCreationTokens
        case "codex-local", "grok-local":
            return event.inputTokens + event.outputTokens + event.reasoningTokens
        case "gateway":
            if Providers.provider(id: event.provider)?.api == "anthropic" {
                return event.inputTokens + event.outputTokens
                    + event.cachedReadTokens + event.cacheCreationTokens
            }
            return event.inputTokens + event.outputTokens + event.reasoningTokens
        default:
            return event.inputTokens + event.outputTokens
                + event.cachedReadTokens + event.cacheCreationTokens + event.reasoningTokens
        }
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
        let billedInput = inputIncludesCacheRead ? max(0, input - cacheRead) : input
        return (Double(billedInput) / m) * price.inputPerMTok
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
        source: SourceFilter,
        now: Date,
        timeZone: TimeZone,
        key: String? = nil,
        provider: String? = nil
    ) throws -> SpendReport {
        let (start, end) = range.interval(now: now, timeZone: timeZone)
        let events = try db.usageEvents(
            from: UTC.iso(start), to: UTC.iso(end), source: source, key: key, provider: provider
        )
        var assembled = Self.assemble(
            events: events,
            range: range,
            by: by,
            source: source,
            start: start,
            end: end,
            now: now,
            timeZone: timeZone,
            keyed: key != nil
        )
        assembled.lastIngestAt = try db.lastIngestAt()
        assembled.catalogVersion = try db.catalogVersion()
        return assembled
    }

    static func assemble(
        events allEvents: [UsageEvent],
        range: SpendRange,
        by: SpendGroup,
        source: SourceFilter,
        start: Date,
        end: Date,
        now: Date,
        timeZone: TimeZone,
        keyed: Bool = false
    ) -> SpendReport {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        var totals = SpendTotals()
        // `source=keys` is the gateway's own ledger, so a gateway call stays in it even when a
        // local log recorded the same upstream request. Dropping the correlated copy is how the
        // local scope avoids counting one call twice; here there is no local figure to protect.
        let keysMode = source == .keys
        let (events, correlated) = keysMode ? (allEvents, 0) : dropCorrelatedGatewayEvents(allEvents)
        totals.gatewayCorrelatedCalls = correlated
        // Rows, daily buckets and hourly points follow the headline: without a key filter they
        // are the local ledger, and gateway calls appear only in the gateway totals. A keyed
        // report is the gateway's own ledger (local events carry no key), so everything shows.
        let charted = keyed || keysMode ? events : events.filter { $0.source != "gateway" }
        var grokTicks: Int64 = 0
        var claudeEstimate: Double = 0
        var hasClaudeEstimate = false
        var openaiEstimate: Double = 0
        var hasOpenAIEstimate = false
        var claudeUnpriced = Set<String>()
        var openaiUnpriced = Set<String>()
        var gatewayEstimate: Double = 0
        var hasGatewayEstimate = false

        var gatewayUnpriced = Set<String>()
        for event in events {
            if event.source == "gateway" {
                // Separate ledger. See SpendTotals.usdEstimate.
                let tok = TokenTotals.normalized(event)
                totals.gatewayTokens += tok
                totals.gatewayCalls += 1
                if keysMode {
                    // This report is the gateway ledger, so its token totals are the headline
                    // ones and agree with the rows and buckets below. Dollars stay in the
                    // gateway fields: unpriced calls must not read as zero.
                    totals.inputTokens += event.inputTokens
                    totals.outputTokens += event.outputTokens
                    totals.cachedReadTokens += event.cachedReadTokens
                    totals.reasoningTokens += event.reasoningTokens
                    totals.tokens += tok
                }
                if let est = gatewayUsd(event) {
                    gatewayEstimate += est
                    hasGatewayEstimate = true
                    totals.gatewayPricedTokens += tok
                } else {
                    gatewayUnpriced.insert(event.model.isEmpty ? "unknown" : event.model)
                    totals.gatewayUnpricedTokens += tok
                    totals.gatewayUnpricedCalls += 1
                }
                continue
            }
            totals.inputTokens += event.inputTokens
            totals.outputTokens += event.outputTokens
            totals.cachedReadTokens += event.cachedReadTokens
            totals.reasoningTokens += event.reasoningTokens
            totals.tokens += TokenTotals.normalized(event)
            if event.source == "grok-local", let ticks = event.costUsdTicks {
                grokTicks += ticks
            }
            if event.source == "claude-local" {
                let tok = TokenTotals.normalized(event)
                totals.claudeTokens += tok
                if let est = ClaudeEstimate.usd(
                    model: event.model,
                    input: event.inputTokens,
                    output: event.outputTokens,
                    cacheCreate: event.cacheCreationTokens,
                    cacheRead: event.cachedReadTokens
                ) {
                    claudeEstimate += est
                    hasClaudeEstimate = true
                    totals.claudePricedTokens += tok
                } else {
                    claudeUnpriced.insert(event.model)
                    totals.claudeUnpricedTokens += tok
                }
            }
            if event.source == "codex-local" {
                let tok = TokenTotals.normalized(event)
                totals.openaiTokens += tok
                if let est = OpenAIEstimate.usd(
                    model: event.model,
                    input: event.inputTokens,
                    output: event.outputTokens,
                    cacheRead: event.cachedReadTokens,
                    reasoning: event.reasoningTokens
                ) {
                    openaiEstimate += est
                    hasOpenAIEstimate = true
                    totals.openaiPricedTokens += tok
                } else {
                    openaiUnpriced.insert(event.model)
                    totals.openaiUnpricedTokens += tok
                }
            }
        }
        totals.grokUsd = Ticks.usd(grokTicks)
        totals.claudeUsdEstimate = hasClaudeEstimate ? claudeEstimate : nil
        totals.openaiUsdEstimate = hasOpenAIEstimate ? openaiEstimate : nil
        totals.gatewayUsdEstimate = hasGatewayEstimate ? gatewayEstimate : nil
        totals.claudeUnpricedModels = claudeUnpriced.sorted()
        totals.openaiUnpricedModels = openaiUnpriced.sorted()
        totals.gatewayUnpricedModels = gatewayUnpriced.sorted()
        var grand = totals.grokUsd
        if let est = totals.claudeUsdEstimate { grand += est }
        if let est = totals.openaiUsdEstimate { grand += est }
        // Gateway dollars stay in gatewayUsdEstimate. Adding them here double-counted every
        // Claude Code or Codex call that went through the gateway.
        totals.usdEstimate = keysMode ? nil : grand

        let rows: [SpendRow]
        switch by {
        case .model, .hour:
            rows = groupByModel(charted)
        case .session:
            rows = groupBySession(charted)
        case .project:
            rows = groupByProject(charted)
        }

        let daily = dailyPoints(charted, calendar: cal, byProject: by == .project)
        let points = by == .hour
            ? hourlyPoints(charted, now: now, timeZone: timeZone)
            : []
        return SpendReport(
            range: range,
            by: by,
            source: source,
            caption: SpendReport.captionText,
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

    /// A gateway event whose prompt id equals a local event's prompt id is the same upstream
    /// call (the gateway stores the provider's request id; Claude Code stores it as
    /// `requestId`). The local event is authoritative, so the gateway copy is dropped.
    /// Only exact ids match; nothing is merged by time or model.
    static func dropCorrelatedGatewayEvents(_ events: [UsageEvent]) -> ([UsageEvent], Int) {
        var localIds = Set<String>()
        for event in events where event.source != "gateway" && !event.promptId.isEmpty {
            localIds.insert(event.promptId)
        }
        if localIds.isEmpty { return (events, 0) }
        var dropped = 0
        let kept = events.filter { event in
            if event.source == "gateway", localIds.contains(event.promptId) {
                dropped += 1
                return false
            }
            return true
        }
        return (kept, dropped)
    }

    /// What one event cost: `usd` from the tool's own receipt (Grok logs its charge), or
    /// `estimate` from list prices. Nil means unknown, never zero.
    static func cost(_ event: UsageEvent) -> (usd: Double?, estimate: Double?) {
        switch event.source {
        case "grok-local":
            return (event.costUsdTicks.map(Ticks.usd), nil)
        case "claude-local":
            return (nil, ClaudeEstimate.usd(model: event.model, input: event.inputTokens, output: event.outputTokens,
                                            cacheCreate: event.cacheCreationTokens, cacheRead: event.cachedReadTokens))
        case "codex-local":
            return (nil, OpenAIEstimate.usd(model: event.model, input: event.inputTokens, output: event.outputTokens,
                                            cacheRead: event.cachedReadTokens, reasoning: event.reasoningTokens))
        default:
            return (nil, gatewayUsd(event))
        }
    }

    static func gatewayUsd(_ event: UsageEvent) -> Double? {
        guard event.source == "gateway" else { return nil }
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

    private static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func byTotal(_ lhs: SpendRow, _ rhs: SpendRow) -> Bool? {
        let lu = lhs.usd ?? lhs.usdEstimate ?? 0
        let ru = rhs.usd ?? rhs.usdEstimate ?? 0
        return lu != ru ? lu > ru : nil
    }

    private static func groupByProject(_ events: [UsageEvent]) -> [SpendRow] {
        var acc: [String: SpendRow] = [:]
        for event in events {
            let cwd = event.cwd ?? ""
            acc[cwd, default: SpendRow(cwd: event.cwd, project: projectName(event.cwd))].add(event)
        }
        return acc.values.sorted { lhs, rhs in
            if let order = byTotal(lhs, rhs) { return order }
            if (lhs.project ?? "") != (rhs.project ?? "") { return (lhs.project ?? "") < (rhs.project ?? "") }
            return (lhs.cwd ?? "") < (rhs.cwd ?? "")
        }
    }

    private static func groupByModel(_ events: [UsageEvent]) -> [SpendRow] {
        struct AccKey: Hashable { var model: String; var key: String? }
        var acc: [AccKey: SpendRow] = [:]
        for event in events {
            let accKey = AccKey(model: event.model, key: event.keyName)
            var row = acc[accKey] ?? SpendRow(model: event.model, key: event.keyName)
            // Only a gateway call has a vault key and therefore a provider to name. Local rows
            // keep provider nil so that adding this field does not split any existing grouping.
            if event.source == "gateway", !event.provider.isEmpty { row.provider = event.provider }
            row.add(event)
            acc[accKey] = row
        }
        return acc.values.sorted { lhs, rhs in
            if let order = byTotal(lhs, rhs) { return order }
            if (lhs.model ?? "") != (rhs.model ?? "") { return (lhs.model ?? "") < (rhs.model ?? "") }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }
    }

    private static func groupBySession(_ events: [UsageEvent]) -> [SpendRow] {
        struct Key: Hashable { var source: String; var session: String }
        var acc: [Key: SpendRow] = [:]
        var models: [Key: Set<String>] = [:]
        for event in events {
            let key = Key(source: event.source, session: event.sessionId)
            var row = acc[key] ?? SpendRow(sessionId: event.sessionId, source: event.source)
            if row.cwd == nil { row.cwd = event.cwd }
            if row.title == nil { row.title = event.sessionTitle }
            row.add(event)
            if let keyName = event.keyName { row.key = keyName }
            acc[key] = row
            models[key, default: []].insert(event.model)
        }
        return acc.keys.sorted { $0.session < $1.session }.map { key in
            var row = acc[key]!
            row.models = (models[key] ?? []).sorted()
            return row
        }
    }

    /// Chart buckets: one per (bucket, series), sorted by both. `bucket` returns nil to skip an event.
    private static func points(
        _ events: [UsageEvent], bucket: (Date) -> String?, series: (UsageEvent) -> String
    ) -> [(bucket: String, series: String, row: SpendRow, tokens: Int)] {
        struct Key: Hashable { var bucket: String; var series: String }
        var acc: [Key: (row: SpendRow, tokens: Int)] = [:]
        for event in events {
            guard let date = UTC.parse(event.occurredAt), let b = bucket(date) else { continue }
            let key = Key(bucket: b, series: series(event))
            var cur = acc[key] ?? (SpendRow(), 0)
            cur.row.add(event)
            cur.tokens += TokenTotals.normalized(event)
            acc[key] = cur
        }
        return acc.keys.sorted { ($0.bucket, $0.series) < ($1.bucket, $1.series) }.map { key in
            let v = acc[key]!
            return (key.bucket, key.series, v.row, v.tokens)
        }
    }

    private static func dailyPoints(_ events: [UsageEvent], calendar: Calendar, byProject: Bool) -> [DailyPoint] {
        let day = { (date: Date) -> String? in SpendRange.localDay(date, timeZone: calendar.timeZone) }
        return points(events, bucket: day, series: { byProject ? ($0.cwd ?? "") : $0.model }).map { point in
            let project = byProject ? projectName(point.series) : nil
            return DailyPoint(
                day: point.bucket,
                model: project ?? point.series,
                usd: point.row.usd,
                tokens: point.tokens,
                inputTokens: point.row.inputTokens,
                outputTokens: point.row.outputTokens,
                cachedReadTokens: point.row.cachedReadTokens,
                cacheCreationTokens: point.row.cacheCreationTokens,
                usdEstimate: point.row.usdEstimate,
                project: project,
                cwd: byProject && !point.series.isEmpty ? point.series : nil,
                modelCalls: point.row.modelCalls
            )
        }
    }

    /// One point per (elapsed local hour, model). Hours after `now` are dropped.
    private static func hourlyPoints(_ events: [UsageEvent], now: Date, timeZone: TimeZone) -> [HourlyPoint] {
        let today = SpendRange.localDay(now, timeZone: timeZone)
        let currentHour = SpendRange.localHour(now, timeZone: timeZone)
        let hour = { (date: Date) -> String? in
            guard SpendRange.localDay(date, timeZone: timeZone) == today else { return nil }
            let hour = SpendRange.localHour(date, timeZone: timeZone)
            return hour <= currentHour ? hour : nil
        }
        return points(events, bucket: hour, series: \.model).map { point in
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
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cachedReadTokens += event.cachedReadTokens
        cacheCreationTokens += event.cacheCreationTokens
        reasoningTokens += event.reasoningTokens
        modelCalls += event.modelCalls ?? 0
        let cost = SpendQueries.cost(event)
        if let usd = cost.usd { self.usd = (self.usd ?? 0) + usd }
        if let estimate = cost.estimate { usdEstimate = (usdEstimate ?? 0) + estimate }
    }
}
