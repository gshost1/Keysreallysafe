import CoreFoundation
import Foundation

/// The deployed HTTPS collector (Analytics/collector.py behind a Cloudflare
/// Tunnel). An unconfigured build cannot opt in or upload. Changing this URL
/// requires fresh consent. `appVersion` follows the release version.
enum ProductAnalyticsConfiguration {
    static let endpoint: URL? = URL(string: "https://analytics.keysrs.com/v1/reports")
    static let appVersion = "0.9.1"
}

// The view_optimizer, optimizer_* and context_* cases have no producer since the
// optimizer was removed. They stay so reports, consent and the collector's
// vocabulary from 0.9.0 and 0.9.1 keep decoding.
enum ProductAnalyticsEvent: String, Codable, CaseIterable, Sendable {
    case viewUsage = "view_usage", viewChart = "view_chart", viewKeys = "view_keys", viewOptimizer = "view_optimizer"
    case keyAdd = "key_add", keyCopy = "key_copy", keyDelete = "key_delete"
    case grantCreate = "grant_create", clientCreate = "client_create"
    case ingestSuccess = "ingest_success", ingestFailure = "ingest_failure"
    case gatewaySuccess = "gateway_success", gatewayFailure = "gateway_failure"
    case optimizerSuccess = "optimizer_success", optimizerFailure = "optimizer_failure", optimizerCacheHit = "optimizer_cache_hit"
    case optimizerAbstained = "optimizer_abstained"
    case contextPrepared = "context_prepared", contextUnchanged = "context_unchanged", contextEmpty = "context_empty", contextFailure = "context_failure"
    case gatewayLT100 = "gateway_lt_100ms", gatewayLT1000 = "gateway_lt_1s", gatewayLT10000 = "gateway_lt_10s", gatewayGTE10000 = "gateway_gte_10s"
    case optimizerLT100 = "optimizer_lt_100ms", optimizerLT1000 = "optimizer_lt_1s", optimizerLT10000 = "optimizer_lt_10s", optimizerGTE10000 = "optimizer_gte_10s"
}

protocol AnalyticsUpload: Sendable { func cancel() }
protocol AnalyticsTransport: Sendable {
    func send(to endpoint: URL, data: Data, completion: @escaping @Sendable (Bool) -> Void) -> any AnalyticsUpload
    /// GET with no body; completes with the response body only on a 200.
    func fetch(from url: URL, maxBytes: Int, completion: @escaping @Sendable (Data?) -> Void) -> any AnalyticsUpload
}

/// Opt-in aggregate reports. The counters come only from the closed event enum.
/// When a UTC day closes, the report also gets that day's usage totals per
/// (tool, provider, model) from `usage_events`, per (provider, model) from
/// `gateway_usage`, and the plan-window peaks observed through `observe`.
/// Nothing else is read: no vault, prompt library, task ledger, session,
/// project, path or key name. Consent and unsent aggregates live in the private
/// local catalog, independently of vault unlock.
final class ProductAnalytics: @unchecked Sendable {
    static let consentVersion = 2
    static let schemaVersion = 2
    static let stateKey = "product_analytics_v1"
    static let benchmarkKey = "product_analytics_benchmarks"
    static let maxReportBytes = 32_768
    static let maxBenchmarkBytes = 32_768
    static let maxTokens = 1_000_000_000_000
    private let catalog: CatalogDB
    private let endpoint: URL?
    private let transport: any AnalyticsTransport
    private let now: @Sendable () -> Date
    private let appVersion: String
    private let operationLock = NSRecursiveLock()
    private var upload: (any AnalyticsUpload)?
    private var uploadAttempt: String?
    private var fetch: (any AnalyticsUpload)?
    private var timer: DispatchSourceTimer?

    struct UsageRow: Codable, Equatable, Sendable {
        var source: String
        var provider: String
        var model: String
        var prompts: Int
        var model_calls: Int
        var input_tokens: Int
        var output_tokens: Int
        var cached_read_tokens: Int
        var cache_creation_tokens: Int
        var reasoning_tokens: Int
    }

    struct WindowRow: Codable, Equatable, Sendable {
        var source: String
        var window: String
        var peak_percent: Int
        var hit_cap: Bool
        var readings: Int
    }

    struct GatewayRow: Codable, Equatable, Sendable {
        var provider: String
        var model: String
        var requests: Int
        var ok: Int
        var failed: Int
        var input_tokens: Int
        var output_tokens: Int
        var cache_read_tokens: Int
        var cache_write_tokens: Int
    }

    struct Report: Codable, Sendable {
        let schema_version: Int
        let consent_version: Int
        let report_id: String
        let day: String
        let app_version: String
        let os_major: Int
        let architecture: String
        var counts: [String: Int]
        var usage: [UsageRow]
        var windows: [WindowRow]
        var gateway: [GatewayRow]
    }

    /// Plan-window readings for a day that is still open. `hours` is a bitmask of
    /// the UTC hours with a reading, so a report says how many hours were seen,
    /// not how often the dashboard happened to poll.
    private struct WindowReading: Codable, Equatable {
        var day: String
        var source: String
        var window: String
        var peak: Int
        var hit: Bool
        var hours: Int
    }

    private struct State: Codable {
        var schemaVersion = 2
        var enabled = false
        var consentVersion = 0
        var endpoint: String? = nil
        var generation = UUID().uuidString.lowercased()
        var reports: [Report] = []
        /// Report IDs whose day has closed and whose arrays are filled; they
        /// never change again, so a retry sends identical bytes.
        var sealed: [String] = []
        var readings: [WindowReading] = []
        /// Usage before this instant is never summarized: no backfill before
        /// opting in, and nothing from before a "discard unsent reports".
        var collectFrom: Double = 0
        var leaseID: String? = nil
        var leaseToken: String? = nil
        var leaseUntil: Double = 0
        var retryAfter: Double = 0
        var lastResult = "never"
    }

    init(catalog: CatalogDB, endpoint: URL? = ProductAnalyticsConfiguration.endpoint,
         transport: any AnalyticsTransport = AnalyticsHTTPTransport(),
         appVersion: String = ProductAnalyticsConfiguration.appVersion,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.endpoint = endpoint.flatMap(Self.validEndpoint)
        self.transport = transport
        self.appVersion = Self.validVersion(appVersion) ? appVersion : "development"
        self.now = now
        // An upgrade with a different destination/schema immediately invalidates
        // persisted consent, even before a user next opens Privacy settings.
        try? update { _ in }
    }

    deinit { timer?.cancel(); upload?.cancel(); fetch?.cancel() }

    /// Same host as the report endpoint; the Privacy dialog shows that host.
    var benchmarksURL: URL? {
        guard let endpoint, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/v1/benchmarks"
        return components.url
    }

    /// Only the dashboard process starts a timer; CLI events can contribute
    /// counts without creating background network activity or another daemon.
    func start() {
        operationLock.lock(); defer { operationLock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "keys.analytics"))
        source.schedule(deadline: .now() + 60, repeating: 900, leeway: .seconds(30))
        source.setEventHandler { [weak self] in
            self?.flushCompletedReports()
            self?.refreshBenchmarks()
        }
        timer = source
        source.resume()
    }

    func status() throws -> [String: Any] {
        let (state, preview): (State, [Report]) = try update { state in
            // Open days are shown as they would be sent if the day ended now.
            (state, state.reports.map { state.sealed.contains($0.report_id) ? $0 : sealedCopy($0, state: state) })
        }
        let previewJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preview))
        return ["enabled": state.enabled, "configured": endpoint != nil,
                "endpoint": endpoint?.absoluteString as Any? ?? NSNull(),
                "benchmarks_url": (endpoint == nil ? nil : benchmarksURL?.absoluteString) as Any? ?? NSNull(),
                "consent_version": Self.consentVersion,
                "pending_events": state.reports.reduce(0) { $0 + $1.counts.values.reduce(0, +) },
                "last_result": state.lastResult,
                "preview": state.reports.isEmpty ? NSNull() : ["reports": previewJSON],
                "compare": (state.enabled ? compare() : nil) as Any? ?? NSNull()]
    }

    func setEnabled(_ enabled: Bool, consentVersion: Int) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard !enabled || (consentVersion == Self.consentVersion && endpoint != nil) else {
            throw AppError.usage("analytics_not_configured_or_consent_outdated")
        }
        try update { state in
            if !enabled {
                state = State()
                state.lastResult = "disabled"
            } else if !state.enabled {
                state = State()
                state.enabled = true
                state.consentVersion = Self.consentVersion
                state.endpoint = endpoint?.absoluteString
                state.collectFrom = now().timeIntervalSince1970
            }
        }
        if !enabled {
            let previous = upload, previousFetch = fetch
            upload = nil; uploadAttempt = nil; fetch = nil
            previous?.cancel(); previousFetch?.cancel()
            try? catalog.setMeta(Self.benchmarkKey, "")
        }
    }

    func clear() throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try update { state in
            state.reports = []
            state.sealed = []
            state.readings = []
            state.collectFrom = now().timeIntervalSince1970
            state.generation = UUID().uuidString.lowercased()
            state.leaseID = nil
            state.leaseToken = nil
            state.leaseUntil = 0
            state.retryAfter = 0
        }
        let previous = upload
        upload = nil; uploadAttempt = nil
        previous?.cancel()
    }

    /// Closed enum only: arbitrary properties, strings and identifiers cannot
    /// enter a report. Analytics failures never fail the user's actual action.
    func record(_ event: ProductAnalyticsEvent, durationMS: Int? = nil) {
        try? update { state in
            guard state.enabled, let index = openReport(&state) else { return }
            var events = [event]
            if let ms = durationMS, ms >= 0 {
                let bucket = ms < 100 ? 0 : ms < 1_000 ? 1 : ms < 10_000 ? 2 : 3
                if event == .gatewaySuccess || event == .gatewayFailure {
                    events.append([.gatewayLT100, .gatewayLT1000, .gatewayLT10000, .gatewayGTE10000][bucket])
                }
            }
            for entry in events {
                state.reports[index].counts[entry.rawValue] = min(1_000_000, (state.reports[index].counts[entry.rawValue] ?? 0) + 1)
            }
        }
    }

    /// Plan-window percentages the Usage pane and menu bar already show. A
    /// reading counts only while its window is current (reset time in the
    /// future, or none given), so yesterday's cached figure is not re-counted.
    func observe(_ status: LiveStatus) {
        let current = now()
        func live(_ pct: Int?, _ resets: String?) -> Int? {
            guard let pct else { return nil }
            if let resets, let date = UTC.parse(resets), date <= current { return nil }
            return min(100, max(0, pct))
        }
        var seen: [(String, String, Int)] = []
        if let claude = status.claude {
            if let pct = live(claude.fiveHourPct, claude.fiveHourResetsAt) { seen.append(("claude_code", "5h", pct)) }
            if let pct = live(claude.weeklyPct, claude.weeklyResetsAt) { seen.append(("claude_code", "weekly", pct)) }
            if let pct = live(claude.fablePct, claude.fableResetsAt) { seen.append(("claude_code", "fable", pct)) }
        }
        if let codex = status.plans.first(where: { $0.source == "openai" }) {
            if let pct = live(codex.fiveHourPct, codex.fiveHourResetsAt) { seen.append(("codex", "5h", pct)) }
            if let pct = live(codex.weeklyPct, codex.weeklyResetsAt) { seen.append(("codex", "weekly", pct)) }
        }
        if let grok = status.grok, let pct = live(grok.weeklyPct, grok.weeklyResetsAt) { seen.append(("grok", "weekly", pct)) }
        let today = Self.day(current)
        let hour = Int(UTC.iso(current).dropFirst(11).prefix(2)) ?? 0
        try? update { state in
            guard state.enabled, openReport(&state) != nil else { return }
            for (source, window, pct) in seen {
                if let index = state.readings.firstIndex(where: { $0.day == today && $0.source == source && $0.window == window }) {
                    state.readings[index].peak = max(state.readings[index].peak, pct)
                    state.readings[index].hit = state.readings[index].hit || pct >= 100
                    state.readings[index].hours |= 1 << hour
                } else {
                    state.readings.append(WindowReading(day: today, source: source, window: window,
                                                        peak: pct, hit: pct >= 100, hours: 1 << hour))
                }
            }
        }
    }

    /// Send immutable, completed UTC days only, at most one report per tick.
    /// Failed attempts keep the same report ID for collector deduplication.
    func flushCompletedReports() {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let endpoint else { return }
        do {
            let prepared: (Report, String, String)? = try update { state in
                let timestamp = now().timeIntervalSince1970
                let today = Self.day(now())
                guard state.enabled else { return nil }
                // Seal every closed day once, before anything is sent.
                for index in state.reports.indices where state.reports[index].day < today
                    && !state.sealed.contains(state.reports[index].report_id) {
                    state.reports[index] = sealedCopy(state.reports[index], state: state)
                    state.sealed.append(state.reports[index].report_id)
                    let day = state.reports[index].day
                    state.readings.removeAll { $0.day == day }
                }
                guard state.leaseUntil <= timestamp, state.retryAfter <= timestamp,
                      let report = state.reports.first(where: { $0.day < today }) else { return nil }
                state.leaseID = report.report_id
                let attempt = UUID().uuidString.lowercased()
                state.leaseToken = attempt
                state.leaseUntil = timestamp + 60
                return (report, state.generation, attempt)
            }
            guard let (report, generation, attempt) = prepared else { return }
            // Sorted keys: a retry of the same sealed report is byte-identical.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(report)
            guard data.count <= Self.maxReportBytes else { return }
            let previous = upload
            upload = nil; uploadAttempt = attempt
            previous?.cancel()
            let sending = transport.send(to: endpoint, data: data) { [weak self] success in
                self?.complete(reportID: report.report_id, generation: generation, attempt: attempt, success: success)
            }
            if uploadAttempt == attempt { upload = sending } else { sending.cancel() }
        } catch { /* Collection must not interfere with Keys. */ }
    }

    private func complete(reportID: String, generation: String, attempt: String, success: Bool) {
        operationLock.lock(); defer { operationLock.unlock() }
        try? update { state in
            guard state.enabled, state.generation == generation, state.leaseID == reportID, state.leaseToken == attempt else { return }
            if success {
                state.reports.removeAll { $0.report_id == reportID }
                state.sealed.removeAll { $0 == reportID }
            }
            state.leaseID = nil
            state.leaseToken = nil
            state.leaseUntil = 0
            state.retryAfter = now().timeIntervalSince1970 + (success ? 0 : 900)
            state.lastResult = success ? "sent" : "failed"
        }
        if uploadAttempt == attempt { upload = nil; uploadAttempt = nil }
    }

    // MARK: Benchmarks and Compare

    private struct BenchmarkCache: Codable {
        var fetched_day: String
        var attempted_at: Double
        var table: Benchmarks?
    }

    struct Benchmarks: Codable, Equatable, Sendable {
        struct Daily: Codable, Equatable, Sendable { var source: String; var reports: Int; var percentiles: [Int] }
        struct CapHit: Codable, Equatable, Sendable { var source: String; var window: String; var reports: Int; var hit_rate: Double }
        var schema_version: Int
        var generated_day: String
        var window_days: Int
        var min_reports: Int
        var daily_tokens: [Daily]
        var cap_hits: [CapHit]

        var isValid: Bool {
            let sources = Set(ProductAnalytics.sources.values)
            return schema_version == 1 && ProductAnalytics.validDay(generated_day) && (1...90).contains(window_days)
                && (1...1_000_000).contains(min_reports) && daily_tokens.count <= 3 && cap_hits.count <= 8
                && daily_tokens.allSatisfy { row in
                    sources.contains(row.source) && row.reports >= min_reports && row.percentiles.count == 19
                        && row.percentiles.allSatisfy { (0...ProductAnalytics.maxTokens).contains($0) }
                        && row.percentiles == row.percentiles.sorted()
                }
                && cap_hits.allSatisfy { row in
                    ProductAnalytics.windows.contains("\(row.source)|\(row.window)") && row.reports >= min_reports
                        && row.hit_rate.isFinite && (0...1).contains(row.hit_rate)
                }
        }
    }

    /// At most one fetch a day (and one attempt every six hours), only while
    /// sharing is on. The request carries nothing about this Mac.
    func refreshBenchmarks() {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let url = benchmarksURL, fetch == nil else { return }
        let enabled = (try? update { $0.enabled }) ?? false
        guard enabled else { return }
        let today = Self.day(now()), timestamp = now().timeIntervalSince1970
        let cached = benchmarkCache()
        if let cached, cached.fetched_day == today || timestamp - cached.attempted_at < 6 * 3_600 { return }
        let attempt = BenchmarkCache(fetched_day: cached?.fetched_day ?? "", attempted_at: timestamp, table: cached?.table)
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        try? catalog.setMeta(Self.benchmarkKey, String(decoding: data, as: UTF8.self))
        fetch = transport.fetch(from: url, maxBytes: Self.maxBenchmarkBytes) { [weak self] body in
            self?.completeBenchmarks(body, day: today, attemptedAt: timestamp)
        }
    }

    private func completeBenchmarks(_ body: Data?, day: String, attemptedAt: Double) {
        operationLock.lock(); defer { operationLock.unlock() }
        fetch = nil
        guard let body, body.count <= Self.maxBenchmarkBytes,
              let table = try? JSONDecoder().decode(Benchmarks.self, from: body), table.isValid,
              (try? update { $0.enabled }) == true,
              let data = try? JSONEncoder().encode(BenchmarkCache(fetched_day: day, attempted_at: attemptedAt, table: table))
        else { return }
        try? catalog.setMeta(Self.benchmarkKey, String(decoding: data, as: UTF8.self))
    }

    private func benchmarkCache() -> BenchmarkCache? {
        guard let raw = try? catalog.metaValue(Self.benchmarkKey), !raw.isEmpty, raw.utf8.count <= 2 * Self.maxBenchmarkBytes,
              let cache = try? JSONDecoder().decode(BenchmarkCache.self, from: Data(raw.utf8)) else { return nil }
        if let table = cache.table, !table.isValid { return nil }
        return cache
    }

    /// This Mac's last seven closed UTC days against the cached benchmark,
    /// computed locally. A tool without a published cell, or without local
    /// activity, is left out rather than estimated.
    func compare() -> [String: Any]? {
        guard let table = benchmarkCache()?.table else { return nil }
        let today = Self.dayStart(Self.day(now()))
        let start = today.addingTimeInterval(-7 * 86_400)
        guard let events = try? catalog.usageEvents(from: UTC.iso(start), to: UTC.iso(today), source: .all) else { return nil }
        var perDay: [String: [String: Int]] = [:]
        for event in events {
            guard let source = Self.sources[event.source] else { continue }
            perDay[source, default: [:]][String(event.occurredAt.prefix(10)), default: 0] += TokenTotals.normalized(event)
        }
        var rows: [[String: Any]] = []
        for daily in table.daily_tokens {
            let days = (perDay[daily.source] ?? [:]).values.filter { $0 > 0 }.sorted()
            guard !days.isEmpty else { continue }
            let median = days[(days.count - 1) / 2]
            let above = daily.percentiles.filter { $0 <= median }.count * 5
            let caps = table.cap_hits.filter { $0.source == daily.source }.map {
                ["window": $0.window, "hit_rate": $0.hit_rate] as [String: Any]
            }
            rows.append(["source": daily.source, "typical_day_tokens": median, "higher_than_percent": above, "cap_hits": caps])
        }
        guard !rows.isEmpty else { return nil }
        return ["window_days": table.window_days, "sources": rows]
    }

    // MARK: Day summaries

    static let sources = ["claude-local": "claude_code", "codex-local": "codex", "grok-local": "grok"]
    static let windows: Set<String> = ["claude_code|5h", "claude_code|weekly", "claude_code|fable",
                                       "codex|5h", "codex|weekly", "grok|weekly"]
    /// The ids in Fixtures/providers.json. A custom provider id is text the user
    /// chose, so anything else is sent as "other". Analytics/collector.py keeps
    /// the same list and a test on each side pins it to the fixture.
    static let providers: Set<String> = Set((
        "openai typesafe anthropic google xai mistral cohere deepseek moonshot zhipu dashscope minimax meta "
        + "perplexity openrouter haimaker ramp-router requesty portkey helicone kilo vercel-ai-gateway "
        + "cloudflare-ai-gateway groq together fireworks deepinfra cerebras sambanova novita hyperbolic nebius "
        + "baseten replicate huggingface lambda featherless azure-openai bedrock vertex cloudflare-workers-ai "
        + "watsonx nvidia elevenlabs deepgram assemblyai voyage jina tavily exa firecrawl brave-search fal "
        + "stability experiential-labs"
    ).split(separator: " ").map(String.init))
    /// Model ids are free text a provider or deployment can choose (fine-tunes
    /// and Azure deployments carry organisation names, often after a public
    /// prefix like "gpt-4-acme-prod"), so a model is sent only if every part is
    /// public vocabulary: a known family, then version numbers, sizes, dates or
    /// words from `modelWords`. Anything else becomes "unknown". Same rule as
    /// `valid_model` in Analytics/collector.py.
    static let modelFamilies = "^(claude|gpt|o[1-9]|codex|grok|gemini|gemma|mistral|magistral|codestral|devstral|ministral|pixtral|llama|deepseek|qwen|command|sonar|kimi|glm|minimax)[0-9]*$"
    static let modelWords: Set<String> = Set((
        "sonnet opus haiku fable instant mini nano pro max plus turbo preview latest lite flash thinking reasoning "
        + "non chat coder code codex instruct vision beta exp experimental fast high medium low small large tiny base "
        + "audio realtime search deep research online spark astra xl xs ultra it embed embedding image omni oss "
        + "maverick scout nemotron distill"
    ).split(separator: " ").map(String.init))

    static func publicModel(_ model: String?) -> String {
        guard let model, model.utf8.count <= 64, !model.isEmpty,
              model.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return "unknown" }
        let parts = model.lowercased().split(separator: /[-._]/, omittingEmptySubsequences: false).map(String.init)
        guard let family = parts.first, family.range(of: modelFamilies, options: .regularExpression) != nil,
              parts.dropFirst().allSatisfy({ part in
                  modelWords.contains(part)
                      || part.range(of: "^([0-9]+[a-z]{0,2}|[a-z][0-9]+[a-z]?|[a-z])$", options: .regularExpression) != nil
              }) else { return "unknown" }
        return model
    }

    static func publicProvider(_ provider: String) -> String { providers.contains(provider) ? provider : "other" }

    private func sealedCopy(_ report: Report, state: State) -> Report {
        var copy = report
        let (usage, gateway) = summarize(day: report.day, from: state.collectFrom)
        copy.usage = usage
        copy.gateway = gateway
        copy.windows = state.readings.filter { $0.day == report.day }.map { reading in
            WindowRow(source: reading.source, window: reading.window,
                      peak_percent: min(100, Int((Double(reading.peak) / 5).rounded()) * 5),
                      hit_cap: reading.hit, readings: max(1, min(24, reading.hours.nonzeroBitCount)))
        }.sorted { ($0.source, $0.window) < ($1.source, $1.window) }
        return copy
    }

    /// The one place analytics reads usage tables: totals for one UTC day, from
    /// the later of the day's start and the moment sharing began.
    private func summarize(day: String, from collectFrom: Double) -> ([UsageRow], [GatewayRow]) {
        let dayStart = Self.dayStart(day)
        let start = max(dayStart, Date(timeIntervalSince1970: collectFrom))
        let end = dayStart.addingTimeInterval(86_400)
        guard start < end else { return ([], []) }
        let clamp = { (value: Int) in min(Self.maxTokens, max(0, value)) }
        var usage: [String: UsageRow] = [:]
        for event in (try? catalog.usageEvents(from: UTC.iso(start), to: UTC.iso(end), source: .all)) ?? [] {
            guard let source = Self.sources[event.source] else { continue }
            let provider = Self.publicProvider(event.provider), model = Self.publicModel(event.model)
            let key = "\(source)|\(provider)|\(model)"
            var row = usage[key] ?? UsageRow(source: source, provider: provider, model: model, prompts: 0, model_calls: 0,
                input_tokens: 0, output_tokens: 0, cached_read_tokens: 0, cache_creation_tokens: 0, reasoning_tokens: 0)
            row.prompts = clamp(row.prompts + 1)
            row.model_calls = clamp(row.model_calls + max(0, event.modelCalls ?? 0))
            row.input_tokens = clamp(row.input_tokens + event.inputTokens)
            row.output_tokens = clamp(row.output_tokens + event.outputTokens)
            row.cached_read_tokens = clamp(row.cached_read_tokens + event.cachedReadTokens)
            row.cache_creation_tokens = clamp(row.cache_creation_tokens + event.cacheCreationTokens)
            row.reasoning_tokens = clamp(row.reasoning_tokens + event.reasoningTokens)
            usage[key] = row
        }
        var gateway: [String: GatewayRow] = [:]
        for call in (try? catalog.gatewayUsage(from: UTC.iso(start), to: UTC.iso(end))) ?? [] {
            let provider = Self.publicProvider(call.provider), model = Self.publicModel(call.model)
            let key = "\(provider)|\(model)"
            var row = gateway[key] ?? GatewayRow(provider: provider, model: model, requests: 0, ok: 0, failed: 0,
                input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0)
            let ok = (200..<400).contains(call.status)
            row.requests = clamp(row.requests + 1)
            row.ok = clamp(row.ok + (ok ? 1 : 0))
            row.failed = clamp(row.failed + (ok ? 0 : 1))
            row.input_tokens = clamp(row.input_tokens + (call.inputTokens ?? 0))
            row.output_tokens = clamp(row.output_tokens + (call.outputTokens ?? 0))
            row.cache_read_tokens = clamp(row.cache_read_tokens + (call.cacheReadTokens ?? 0))
            row.cache_write_tokens = clamp(row.cache_write_tokens + (call.cacheWriteTokens ?? 0))
            gateway[key] = row
        }
        // The collector's row limits are 40; the biggest rows are kept, ties by name.
        let usageRows = usage.values.sorted {
            let a = $0.input_tokens + $0.output_tokens + $0.cached_read_tokens + $0.cache_creation_tokens + $0.reasoning_tokens
            let b = $1.input_tokens + $1.output_tokens + $1.cached_read_tokens + $1.cache_creation_tokens + $1.reasoning_tokens
            return a != b ? a > b : ($0.source, $0.provider, $0.model) < ($1.source, $1.provider, $1.model)
        }.prefix(40)
        let gatewayRows = gateway.values.sorted {
            $0.requests != $1.requests ? $0.requests > $1.requests : ($0.provider, $0.model) < ($1.provider, $1.model)
        }.prefix(40)
        return (Array(usageRows), Array(gatewayRows))
    }

    /// Today's report, created on first use. Returns nil only if it cannot exist.
    private func openReport(_ state: inout State) -> Int? {
        let today = Self.day(now())
        if let index = state.reports.firstIndex(where: { $0.day == today }) { return index }
        guard state.reports.count < 8 else { return nil }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        state.reports.append(Report(schema_version: Self.schemaVersion, consent_version: Self.consentVersion,
            report_id: UUID().uuidString.lowercased(), day: today, app_version: appVersion,
            os_major: min(99, max(10, ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
            architecture: architecture, counts: [:], usage: [], windows: [], gateway: []))
        return state.reports.count - 1
    }

    /// Catalog transactions also serialize separate CLI/dashboard processes.
    private func update<T>(_ body: (inout State) throws -> T) throws -> T {
        try catalog.withTransaction {
            let original = try catalog.metaValue(Self.stateKey)
            var state = original.flatMap(Self.decodeState) ?? State()
            if state.enabled && (endpoint == nil || state.endpoint != endpoint?.absoluteString || state.consentVersion != Self.consentVersion) {
                state = State()
            }
            let today = Self.day(now())
            let oldest = Self.day(now().addingTimeInterval(-7 * 86_400))
            let valid = state.schemaVersion == Self.schemaVersion && UUID(uuidString: state.generation) != nil
                && ["never", "sent", "failed", "disabled"].contains(state.lastResult)
                && state.reports.count <= 8 && Set(state.reports.map(\.day)).count == state.reports.count
                && Set(state.reports.map(\.report_id)).count == state.reports.count
                && Set(state.sealed).isSubset(of: Set(state.reports.map(\.report_id)))
                && state.readings.count <= 8 * Self.windows.count
                && state.readings.allSatisfy { Self.windows.contains("\($0.source)|\($0.window)") && (0...100).contains($0.peak)
                    && Self.validDay($0.day) && (0..<(1 << 24)).contains($0.hours) }
                && state.reports.allSatisfy(Self.validReport)
            if !valid { state = State() }
            if !state.enabled { state.reports = []; state.sealed = []; state.readings = [] }
            state.reports.removeAll { $0.day < oldest || $0.day > today }
            state.sealed.removeAll { id in !state.reports.contains { $0.report_id == id } }
            state.readings.removeAll { $0.day < oldest || $0.day > today }
            state.reports.sort { $0.day < $1.day }
            let result = try body(&state)
            // Do not create analytics state just because the app was opened, and
            // skip the write when a poll changed nothing.
            if original != nil || state.enabled || state.lastResult == "disabled" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = try encoder.encode(state)
                guard let string = String(data: data, encoding: .utf8), data.count <= 262_144 else { throw AppError.usage("analytics_state_too_large") }
                if string != original { try catalog.setMeta(Self.stateKey, string) }
            }
            return result
        }
    }

    private static func validReport(_ report: Report) -> Bool {
        let unique = { (keys: [String]) in Set(keys).count == keys.count }
        let tokens = { (value: Int) in (0...maxTokens).contains(value) }
        return report.schema_version == schemaVersion && report.consent_version == consentVersion
            && UUID(uuidString: report.report_id) != nil && validVersion(report.app_version)
            && (10...99).contains(report.os_major) && ["arm64", "x86_64", "unknown"].contains(report.architecture)
            && validDay(report.day) && report.counts.count <= ProductAnalyticsEvent.allCases.count
            && report.counts.allSatisfy { ProductAnalyticsEvent(rawValue: $0.key) != nil && (1...1_000_000).contains($0.value) }
            && report.usage.count <= 40 && report.windows.count <= 8 && report.gateway.count <= 40
            && unique(report.usage.map { "\($0.source)|\($0.provider)|\($0.model)" })
            && unique(report.windows.map { "\($0.source)|\($0.window)" })
            && unique(report.gateway.map { "\($0.provider)|\($0.model)" })
            && report.usage.allSatisfy { row in
                sources.values.contains(row.source) && (providers.contains(row.provider) || row.provider == "other")
                    && publicModel(row.model) == row.model && row.prompts >= 1
                    && [row.prompts, row.model_calls, row.input_tokens, row.output_tokens, row.cached_read_tokens,
                        row.cache_creation_tokens, row.reasoning_tokens].allSatisfy(tokens)
            }
            && report.windows.allSatisfy { row in
                windows.contains("\(row.source)|\(row.window)") && (0...100).contains(row.peak_percent)
                    && row.peak_percent % 5 == 0 && (1...24).contains(row.readings)
            }
            && report.gateway.allSatisfy { row in
                (providers.contains(row.provider) || row.provider == "other") && publicModel(row.model) == row.model
                    && row.requests >= 1 && row.ok + row.failed == row.requests
                    && [row.requests, row.ok, row.failed, row.input_tokens, row.output_tokens, row.cache_read_tokens,
                        row.cache_write_tokens].allSatisfy(tokens)
            }
    }

    private static func decodeState(_ value: String) -> State? {
        guard value.utf8.count <= 262_144, let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let required: Set<String> = ["schemaVersion", "enabled", "consentVersion", "generation", "reports", "sealed",
                                     "readings", "collectFrom", "leaseUntil", "retryAfter", "lastResult"]
        let allowed = required.union(["endpoint", "leaseID", "leaseToken"])
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
              let reports = object["reports"] as? [[String: Any]], reports.count <= 8 else { return nil }
        let fields: Set<String> = ["schema_version", "consent_version", "report_id", "day", "app_version", "os_major",
                                   "architecture", "counts", "usage", "windows", "gateway"]
        guard reports.allSatisfy({ Set($0.keys) == fields }) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func day(_ date: Date) -> String { String(UTC.iso(date).prefix(10)) }
    private static func dayStart(_ day: String) -> Date { UTC.parse(day + "T00:00:00Z") ?? Date(timeIntervalSince1970: 0) }
    static func validDay(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = ISO8601DateFormatter().date(from: value + "T00:00:00Z") else { return false }
        return day(date) == value
    }
    private static func validVersion(_ value: String) -> Bool {
        value == "development" || (value.utf8.count <= 32 && value.range(of: "^[0-9]+(\\.[0-9]+){1,3}$", options: .regularExpression) != nil)
    }
    private static func validEndpoint(_ url: URL) -> URL? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path == "/v1/reports" else { return nil }
        return url
    }
}

struct AnalyticsHTTPTransport: AnalyticsTransport {
    func send(to endpoint: URL, data: Data, completion: @escaping @Sendable (Bool) -> Void) -> any AnalyticsUpload {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return AnalyticsHTTPUpload(request: request, expect: 204, maxBytes: 4_096) { completion($0 != nil) }
    }

    func fetch(from url: URL, maxBytes: Int, completion: @escaping @Sendable (Data?) -> Void) -> any AnalyticsUpload {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return AnalyticsHTTPUpload(request: request, expect: 200, maxBytes: maxBytes, completion: completion)
    }
}

/// Ephemeral, no cookies or credentials, no redirects, bounded response body.
private final class AnalyticsHTTPUpload: NSObject, URLSessionDataDelegate, AnalyticsUpload, @unchecked Sendable {
    private let lock = NSLock()
    private let expect: Int
    private let maxBytes: Int
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: (@Sendable (Data?) -> Void)?
    private var accepted = false
    private var body = Data()

    init(request original: URLRequest, expect: Int, maxBytes: Int, completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
        self.expect = expect
        self.maxBytes = maxBytes
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        var request = original
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("KeysProductAnalytics/2", forHTTPHeaderField: "User-Agent")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() { finish(nil) }
    private func finish(_ result: Data?) {
        lock.lock()
        let callback = completion
        completion = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        callback?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        accepted = (response as? HTTPURLResponse)?.statusCode == expect
        completionHandler(response.expectedContentLength > Int64(maxBytes) ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        if body.count > maxBytes { accepted = false; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && accepted ? body : nil)
    }
}
