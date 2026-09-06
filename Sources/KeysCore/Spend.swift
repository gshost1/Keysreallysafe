import Foundation

enum OpenAIEstimate {
    struct Price {
        var inputPerMTok: Double
        var outputPerMTok: Double
        var cachedPerMTok: Double
    }

    /// Frozen local list prices. Output is always labeled estimate, not invoice.
    static let table: [(prefix: String, price: Price)] = [
        ("gpt-5.4", Price(inputPerMTok: 1.25, outputPerMTok: 10, cachedPerMTok: 0.125)),
        ("gpt-5.3", Price(inputPerMTok: 1.25, outputPerMTok: 10, cachedPerMTok: 0.125)),
        ("gpt-5", Price(inputPerMTok: 1.25, outputPerMTok: 10, cachedPerMTok: 0.125)),
        ("gpt-4.1", Price(inputPerMTok: 2, outputPerMTok: 8, cachedPerMTok: 0.5)),
        ("gpt-4o-mini", Price(inputPerMTok: 0.15, outputPerMTok: 0.6, cachedPerMTok: 0.075)),
        ("gpt-4o", Price(inputPerMTok: 2.5, outputPerMTok: 10, cachedPerMTok: 1.25)),
        ("o4-mini", Price(inputPerMTok: 1.1, outputPerMTok: 4.4, cachedPerMTok: 0.275)),
        ("o3-mini", Price(inputPerMTok: 1.1, outputPerMTok: 4.4, cachedPerMTok: 0.275)),
        ("o3", Price(inputPerMTok: 2, outputPerMTok: 8, cachedPerMTok: 0.5)),
        ("codex", Price(inputPerMTok: 1.25, outputPerMTok: 10, cachedPerMTok: 0.125)),
    ]

    static func price(for model: String) -> Price? {
        guard let found = ModelPrices.lookup(model) else { return nil }
        return Price(
            inputPerMTok: found.inputPerMTok,
            outputPerMTok: found.outputPerMTok,
            cachedPerMTok: found.cacheReadPerMTok
        )
    }

    static func usd(model: String, input: Int, output: Int, cacheRead: Int, reasoning: Int) -> Double? {
        guard let price = price(for: model) else { return nil }
        let m = 1_000_000.0
        let billedInput = max(0, input - cacheRead)
        return (Double(billedInput) / m) * price.inputPerMTok
            + (Double(output + reasoning) / m) * price.outputPerMTok
            + (Double(cacheRead) / m) * price.cachedPerMTok
    }
}

enum ClaudeEstimate {
    struct Price {
        var inputPerMTok: Double
        var outputPerMTok: Double
        var cachedPerMTok: Double
    }

    /// Frozen local list prices. Longest prefix first. Cache write is 1.25× input.
    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(inputPerMTok: 10, outputPerMTok: 50, cachedPerMTok: 0.25)),
        ("claude-fable-5", Price(inputPerMTok: 10, outputPerMTok: 50, cachedPerMTok: 1.00)),
        ("claude-mythos-5", Price(inputPerMTok: 10, outputPerMTok: 50, cachedPerMTok: 0.25)),
        ("claude-opus-5", Price(inputPerMTok: 5, outputPerMTok: 25, cachedPerMTok: 0.50)),
        ("claude-opus-4-8", Price(inputPerMTok: 5, outputPerMTok: 25, cachedPerMTok: 0.50)),
        ("claude-opus-4-7", Price(inputPerMTok: 5, outputPerMTok: 25, cachedPerMTok: 0.50)),
        ("claude-opus-4-6", Price(inputPerMTok: 5, outputPerMTok: 25, cachedPerMTok: 0.50)),
        ("claude-opus-4-5", Price(inputPerMTok: 5, outputPerMTok: 25, cachedPerMTok: 0.50)),
        ("claude-sonnet-5", Price(inputPerMTok: 2, outputPerMTok: 10, cachedPerMTok: 0.20)),
        ("claude-sonnet-4-6", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
        ("claude-haiku-4-5", Price(inputPerMTok: 1, outputPerMTok: 5, cachedPerMTok: 0.10)),
        ("claude-opus-4", Price(inputPerMTok: 15, outputPerMTok: 75, cachedPerMTok: 1.50)),
        ("claude-sonnet-4", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
        ("claude-3-7-sonnet", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
        ("claude-3-5-sonnet", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
        ("claude-3-5-haiku", Price(inputPerMTok: 0.80, outputPerMTok: 4, cachedPerMTok: 0.080)),
        ("claude-haiku-3.5", Price(inputPerMTok: 0.80, outputPerMTok: 4, cachedPerMTok: 0.080)),
        ("claude-3-opus", Price(inputPerMTok: 15, outputPerMTok: 75, cachedPerMTok: 1.50)),
        ("claude-3-sonnet", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
        ("claude-3-haiku", Price(inputPerMTok: 0.25, outputPerMTok: 1.25, cachedPerMTok: 0.025)),
        ("claude-haiku", Price(inputPerMTok: 0.80, outputPerMTok: 4, cachedPerMTok: 0.080)),
        ("claude-opus", Price(inputPerMTok: 15, outputPerMTok: 75, cachedPerMTok: 1.50)),
        ("claude-sonnet", Price(inputPerMTok: 3, outputPerMTok: 15, cachedPerMTok: 0.30)),
    ]

    static func price(for model: String) -> Price? {
        guard let found = ModelPrices.lookup(model) else { return nil }
        return Price(
            inputPerMTok: found.inputPerMTok,
            outputPerMTok: found.outputPerMTok,
            cachedPerMTok: found.cacheReadPerMTok
        )
    }

    static func usd(model: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double? {
        guard let price = price(for: model) else { return nil }
        let m = 1_000_000.0
        return (Double(input) / m) * price.inputPerMTok
            + (Double(output) / m) * price.outputPerMTok
            + (Double(cacheCreate) / m) * price.inputPerMTok * 1.25
            + (Double(cacheRead) / m) * price.cachedPerMTok
    }
}

enum TokenTotals {
    static let rule =
        "claude includes cache tokens; openai/codex/grok exclude cached reads and include reasoning; gateway follows provider api"

    static func normalized(_ event: UsageEvent) -> Int {
        switch event.source {
        case "claude-local":
            return event.inputTokens + event.outputTokens
                + event.cachedReadTokens + event.cacheCreationTokens
        case "codex-local", "openai-api", "grok-local":
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
    enum Source: String {
        case hand
        case fixture
    }

    struct ListPrice: Equatable {
        var inputPerMTok: Double
        var outputPerMTok: Double
        var cacheReadPerMTok: Double
        var source: Source
    }

    /// Tests replace this to load a temp fixture or a missing path. Nil uses the usual search.
    nonisolated(unsafe) static var testFixtureURL: URL?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Table?
    nonisolated(unsafe) private static var loggedMissing = false

    private struct Table {
        var handExact: [String: ListPrice]
        var handPrefix: [(prefix: String, price: ListPrice, contains: Bool)]
        var fixture: [String: ListPrice]
    }

    static func resetCache() {
        lock.lock()
        cached = nil
        loggedMissing = false
        lock.unlock()
    }

    static func loadAtStartup() {
        _ = current()
    }

    static func lookup(_ model: String) -> ListPrice? {
        let table = current()
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        let stripped = stripProvider(lower)
        if let price = table.handExact[stripped] ?? table.handExact[lower] {
            return price
        }
        if let price = table.fixture[stripped] ?? table.fixture[lower] {
            return price
        }
        for row in table.handPrefix {
            if stripped.hasPrefix(row.prefix) || lower.hasPrefix(row.prefix) {
                return row.price
            }
            if row.contains, stripped.contains(row.prefix) || lower.contains(row.prefix) {
                return row.price
            }
        }
        return nil
    }

    static func stripProvider(_ model: String) -> String {
        if let idx = model.firstIndex(of: "/"), idx != model.startIndex {
            return String(model[model.index(after: idx)...])
        }
        return model
    }

    private static func current() -> Table {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    private static func load() -> Table {
        var handExact: [String: ListPrice] = [:]
        var handPrefix: [(prefix: String, price: ListPrice, contains: Bool)] = []
        for (prefix, price) in ClaudeEstimate.table {
            let row = ListPrice(
                inputPerMTok: price.inputPerMTok,
                outputPerMTok: price.outputPerMTok,
                cacheReadPerMTok: price.cachedPerMTok,
                source: .hand
            )
            handExact[prefix] = row
            handPrefix.append((prefix, row, false))
        }
        for (prefix, price) in OpenAIEstimate.table {
            let row = ListPrice(
                inputPerMTok: price.inputPerMTok,
                outputPerMTok: price.outputPerMTok,
                cacheReadPerMTok: price.cachedPerMTok,
                source: .hand
            )
            handExact[prefix] = row
            handPrefix.append((prefix, row, true))
        }

        var fixture: [String: ListPrice] = [:]
        let url = resolveFixtureURL()
        if let url, FileManager.default.isReadableFile(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
           let models = root["models"] as? [Any], !models.isEmpty
        {
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
                    cacheReadPerMTok: cacheRead,
                    source: .fixture
                )
                let lowerId = id.lowercased()
                let stripped = stripProvider(lowerId)
                fixture[lowerId] = price
                fixture[stripped] = price
                if let name = JSONValue.string(obj["name"]) {
                    fixture[name.lowercased()] = price
                }
            }
        } else {
            if !loggedMissing {
                loggedMissing = true
                let line = "models.json missing or empty; using hand price rows only\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        return Table(handExact: handExact, handPrefix: handPrefix, fixture: fixture)
    }

    private static func resolveFixtureURL() -> URL? {
        FixturePath.resolve(fileName: "models.json", envKey: "KEYS_MODELS_JSON", testURL: testFixtureURL)
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
        key: String? = nil
    ) throws -> SpendReport {
        let (start, end) = range.interval(now: now, timeZone: timeZone)
        let events = try db.usageEvents(from: UTC.iso(start), to: UTC.iso(end), source: source, key: key)
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
        let (events, correlated) = dropCorrelatedGatewayEvents(allEvents)
        totals.gatewayCorrelatedCalls = correlated
        // Rows, daily buckets and hourly points follow the headline: without a key filter they
        // are the local ledger, and gateway calls appear only in the gateway totals. A keyed
        // report is the gateway's own ledger (local events carry no key), so everything shows.
        let charted = keyed ? events : events.filter { $0.source != "gateway" }
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
                // Separate ledger. See SpendTotals.localScope.
                let tok = TokenTotals.normalized(event)
                totals.gatewayTokens += tok
                totals.gatewayCalls += 1
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
            if event.source == "codex-local" || event.source == "openai-api" {
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
        totals.usdEstimate = grand
        totals.tokenRule = TokenTotals.rule

        let rows: [SpendRow]
        switch by {
        case .model, .hour:
            rows = groupByModel(charted)
        case .session:
            rows = groupBySession(charted)
        case .project:
            rows = groupByProject(charted)
        }

        let daily = by == .project
            ? dailyPointsByProject(charted, calendar: cal)
            : dailyPoints(charted, calendar: cal)
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

    private static func gatewayUsd(_ event: UsageEvent) -> Double? {
        guard event.source == "gateway" else { return nil }
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

    private static func addTokens(_ row: inout SpendRow, _ event: UsageEvent) {
        row.inputTokens += event.inputTokens
        row.outputTokens += event.outputTokens
        row.cachedReadTokens += event.cachedReadTokens
        row.cacheCreationTokens += event.cacheCreationTokens
        row.reasoningTokens += event.reasoningTokens
        row.modelCalls += event.modelCalls ?? 0
        if event.source == "grok-local", let ticks = event.costUsdTicks {
            row.usd = (row.usd ?? 0) + Ticks.usd(ticks)
        }
        if event.source == "claude-local",
           let est = ClaudeEstimate.usd(
               model: event.model,
               input: event.inputTokens,
               output: event.outputTokens,
               cacheCreate: event.cacheCreationTokens,
               cacheRead: event.cachedReadTokens
           )
        {
            row.usdEstimate = (row.usdEstimate ?? 0) + est
        }
        if event.source == "codex-local" || event.source == "openai-api",
           let est = OpenAIEstimate.usd(
               model: event.model,
               input: event.inputTokens,
               output: event.outputTokens,
               cacheRead: event.cachedReadTokens,
               reasoning: event.reasoningTokens
           )
        {
            row.usdEstimate = (row.usdEstimate ?? 0) + est
        }
        if let est = gatewayUsd(event) {
            row.usdEstimate = (row.usdEstimate ?? 0) + est
        }
    }

    private static func groupByProject(_ events: [UsageEvent]) -> [SpendRow] {
        var acc: [String: SpendRow] = [:]
        for event in events {
            let cwd = event.cwd ?? ""
            var row = acc[cwd] ?? SpendRow(
                cwd: event.cwd,
                project: projectName(event.cwd)
            )
            addTokens(&row, event)
            acc[cwd] = row
        }
        return acc.values.sorted { lhs, rhs in
            let lu = lhs.usd ?? lhs.usdEstimate ?? 0
            let ru = rhs.usd ?? rhs.usdEstimate ?? 0
            if lu != ru { return lu > ru }
            if (lhs.project ?? "") != (rhs.project ?? "") { return (lhs.project ?? "") < (rhs.project ?? "") }
            return (lhs.cwd ?? "") < (rhs.cwd ?? "")
        }
    }

    private static func dailyPointsByProject(_ events: [UsageEvent], calendar: Calendar) -> [DailyPoint] {
        struct Key: Hashable { var day: String; var cwd: String }
        struct Acc {
            var usd: Double?
            var tokens: Int
            var input: Int
            var output: Int
            var cachedRead: Int
            var cacheCreate: Int
            var usdEstimate: Double?
            var project: String
        }
        var acc: [Key: Acc] = [:]
        for event in events {
            guard let date = UTC.parse(event.occurredAt) else { continue }
            let day = SpendRange.localDay(date, timeZone: calendar.timeZone)
            let cwd = event.cwd ?? ""
            let key = Key(day: day, cwd: cwd)
            var cur = acc[key] ?? Acc(
                usd: nil, tokens: 0, input: 0, output: 0, cachedRead: 0, cacheCreate: 0,
                usdEstimate: nil, project: projectName(event.cwd)
            )
            cur.tokens += TokenTotals.normalized(event)
            cur.input += event.inputTokens
            cur.output += event.outputTokens
            cur.cachedRead += event.cachedReadTokens
            cur.cacheCreate += event.cacheCreationTokens
            if event.source == "claude-local",
               let est = ClaudeEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheCreate: event.cacheCreationTokens,
                   cacheRead: event.cachedReadTokens
               )
            {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            acc[key] = cur
        }
        return acc.keys.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            return lhs.cwd < rhs.cwd
        }.map { key in
            let v = acc[key]!
            return DailyPoint(
                day: key.day,
                model: v.project,
                usd: v.usd,
                tokens: v.tokens,
                inputTokens: v.input,
                outputTokens: v.output,
                cachedReadTokens: v.cachedRead,
                cacheCreationTokens: v.cacheCreate,
                usdEstimate: v.usdEstimate,
                project: v.project,
                cwd: key.cwd.isEmpty ? nil : key.cwd
            )
        }
    }

    private static func groupByModel(_ events: [UsageEvent]) -> [SpendRow] {
        struct AccKey: Hashable { var model: String; var key: String? }
        var acc: [AccKey: SpendRow] = [:]
        for event in events {
            let accKey = AccKey(model: event.model, key: event.keyName)
            var row = acc[accKey] ?? SpendRow(model: event.model, key: event.keyName)
            row.inputTokens += event.inputTokens
            row.outputTokens += event.outputTokens
            row.cachedReadTokens += event.cachedReadTokens
            row.cacheCreationTokens += event.cacheCreationTokens
            row.reasoningTokens += event.reasoningTokens
            row.modelCalls += event.modelCalls ?? 0
            if event.source == "grok-local", let ticks = event.costUsdTicks {
                row.usd = (row.usd ?? 0) + Ticks.usd(ticks)
            }
            if event.source == "claude-local",
               let est = ClaudeEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheCreate: event.cacheCreationTokens,
                   cacheRead: event.cachedReadTokens
               )
            {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
            if event.source == "codex-local" || event.source == "openai-api",
               let est = OpenAIEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheRead: event.cachedReadTokens,
                   reasoning: event.reasoningTokens
               )
            {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
            if let est = gatewayUsd(event) {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
            acc[accKey] = row
        }
        return acc.values.sorted { lhs, rhs in
            let lu = lhs.usd ?? lhs.usdEstimate ?? 0
            let ru = rhs.usd ?? rhs.usdEstimate ?? 0
            if lu != ru { return lu > ru }
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
            row.inputTokens += event.inputTokens
            row.outputTokens += event.outputTokens
            row.cachedReadTokens += event.cachedReadTokens
            row.cacheCreationTokens += event.cacheCreationTokens
            row.reasoningTokens += event.reasoningTokens
            row.modelCalls += event.modelCalls ?? 0
            if event.source == "grok-local", let ticks = event.costUsdTicks {
                row.usd = (row.usd ?? 0) + Ticks.usd(ticks)
            }
            if event.source == "claude-local",
               let est = ClaudeEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheCreate: event.cacheCreationTokens,
                   cacheRead: event.cachedReadTokens
               )
            {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
            if event.source == "codex-local" || event.source == "openai-api",
               let est = OpenAIEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheRead: event.cachedReadTokens,
                   reasoning: event.reasoningTokens
               )
            {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
            if let est = gatewayUsd(event) {
                row.usdEstimate = (row.usdEstimate ?? 0) + est
            }
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

    private static func dailyPoints(_ events: [UsageEvent], calendar: Calendar) -> [DailyPoint] {
        struct Key: Hashable { var day: String; var model: String }
        struct Acc {
            var usd: Double?
            var tokens: Int
            var input: Int
            var output: Int
            var cachedRead: Int
            var cacheCreate: Int
            var usdEstimate: Double?
        }
        var acc: [Key: Acc] = [:]
        for event in events {
            guard let date = UTC.parse(event.occurredAt) else { continue }
            let day = SpendRange.localDay(date, timeZone: calendar.timeZone)
            let key = Key(day: day, model: event.model)
            var cur = acc[key] ?? Acc(usd: nil, tokens: 0, input: 0, output: 0, cachedRead: 0, cacheCreate: 0, usdEstimate: nil)
            cur.tokens += TokenTotals.normalized(event)
            cur.input += event.inputTokens
            cur.output += event.outputTokens
            cur.cachedRead += event.cachedReadTokens
            cur.cacheCreate += event.cacheCreationTokens
            if let ticks = event.costUsdTicks {
                cur.usd = (cur.usd ?? 0) + Ticks.usd(ticks)
            }
            if event.source == "claude-local",
               let est = ClaudeEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheCreate: event.cacheCreationTokens,
                   cacheRead: event.cachedReadTokens
               )
            {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            if event.source == "codex-local" || event.source == "openai-api",
               let est = OpenAIEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheRead: event.cachedReadTokens,
                   reasoning: event.reasoningTokens
               )
            {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            if let est = gatewayUsd(event) {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            acc[key] = cur
        }
        return acc.keys.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            return lhs.model < rhs.model
        }.map { key in
            let v = acc[key]!
            return DailyPoint(
                day: key.day,
                model: key.model,
                usd: v.usd,
                tokens: v.tokens,
                inputTokens: v.input,
                outputTokens: v.output,
                cachedReadTokens: v.cachedRead,
                cacheCreationTokens: v.cacheCreate,
                usdEstimate: v.usdEstimate
            )
        }
    }

    /// One point per (elapsed local hour, model). Hours after `now` are dropped.
    private static func hourlyPoints(
        _ events: [UsageEvent],
        now: Date,
        timeZone: TimeZone
    ) -> [HourlyPoint] {
        let today = SpendRange.localDay(now, timeZone: timeZone)
        let currentHour = SpendRange.localHour(now, timeZone: timeZone)
        struct Key: Hashable { var hour: String; var model: String }
        struct Acc {
            var usd: Double?
            var tokens: Int
            var input: Int
            var output: Int
            var cachedRead: Int
            var cacheCreate: Int
            var usdEstimate: Double?
        }
        var acc: [Key: Acc] = [:]
        for event in events {
            guard let date = UTC.parse(event.occurredAt) else { continue }
            let day = SpendRange.localDay(date, timeZone: timeZone)
            guard day == today else { continue }
            let hour = SpendRange.localHour(date, timeZone: timeZone)
            guard hour <= currentHour else { continue }
            let key = Key(hour: hour, model: event.model)
            var cur = acc[key] ?? Acc(
                usd: nil, tokens: 0, input: 0, output: 0, cachedRead: 0, cacheCreate: 0, usdEstimate: nil
            )
            cur.tokens += TokenTotals.normalized(event)
            cur.input += event.inputTokens
            cur.output += event.outputTokens
            cur.cachedRead += event.cachedReadTokens
            cur.cacheCreate += event.cacheCreationTokens
            if let ticks = event.costUsdTicks {
                cur.usd = (cur.usd ?? 0) + Ticks.usd(ticks)
            }
            if event.source == "claude-local",
               let est = ClaudeEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheCreate: event.cacheCreationTokens,
                   cacheRead: event.cachedReadTokens
               )
            {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            if event.source == "codex-local" || event.source == "openai-api",
               let est = OpenAIEstimate.usd(
                   model: event.model,
                   input: event.inputTokens,
                   output: event.outputTokens,
                   cacheRead: event.cachedReadTokens,
                   reasoning: event.reasoningTokens
               )
            {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            if let est = gatewayUsd(event) {
                cur.usdEstimate = (cur.usdEstimate ?? 0) + est
            }
            acc[key] = cur
        }
        return acc.keys.sorted { lhs, rhs in
            if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
            return lhs.model < rhs.model
        }.map { key in
            let v = acc[key]!
            return HourlyPoint(
                hour: key.hour,
                model: key.model,
                usd: v.usd,
                tokens: v.tokens,
                inputTokens: v.input,
                outputTokens: v.output,
                cachedReadTokens: v.cachedRead,
                cacheCreationTokens: v.cacheCreate,
                usdEstimate: v.usdEstimate
            )
        }
    }
}
