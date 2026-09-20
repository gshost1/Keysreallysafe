import CoreFoundation
import Foundation

/// Set a deployed HTTPS collector URL when preparing a release. An unconfigured
/// build cannot opt in or upload. Changing this URL requires fresh consent.
enum ProductAnalyticsConfiguration {
    static let endpoint: URL? = nil
    static let appVersion = "development"
}

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
}

/// A small allowlisted counter store. It never reads the vault, prompt library,
/// task ledger or historical usage tables. Consent and unsent aggregates are
/// stored in the existing private local catalog, independently of vault unlock.
final class ProductAnalytics: @unchecked Sendable {
    static let consentVersion = 1
    static let stateKey = "product_analytics_v1"
    private let catalog: CatalogDB
    private let endpoint: URL?
    private let transport: any AnalyticsTransport
    private let now: @Sendable () -> Date
    private let appVersion: String
    private let operationLock = NSRecursiveLock()
    private var upload: (any AnalyticsUpload)?
    private var uploadAttempt: String?
    private var timer: DispatchSourceTimer?

    struct Report: Codable, Sendable {
        let schema_version: Int
        let consent_version: Int
        let report_id: String
        let day: String
        let app_version: String
        let os_major: Int
        let architecture: String
        var counts: [String: Int]
    }

    private struct State: Codable {
        var schemaVersion = 1
        var enabled = false
        var consentVersion = 0
        var endpoint: String? = nil
        var generation = UUID().uuidString.lowercased()
        var reports: [Report] = []
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

    deinit { timer?.cancel(); upload?.cancel() }

    /// Only the dashboard process starts a timer; CLI events can contribute
    /// counts without creating background network activity or another daemon.
    func start() {
        operationLock.lock(); defer { operationLock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "keys.analytics"))
        source.schedule(deadline: .now() + 60, repeating: 900, leeway: .seconds(30))
        source.setEventHandler { [weak self] in self?.flushCompletedReports() }
        timer = source
        source.resume()
    }

    func status() throws -> [String: Any] {
        try update { state in
            let preview = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.reports))
            return ["enabled": state.enabled, "configured": endpoint != nil,
                    "endpoint": endpoint?.absoluteString as Any? ?? NSNull(),
                    "consent_version": Self.consentVersion,
                    "pending_events": state.reports.reduce(0) { $0 + $1.counts.values.reduce(0, +) },
                    "last_result": state.lastResult,
                    "preview": state.reports.isEmpty ? NSNull() : ["reports": preview]]
        }
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
            }
        }
        if !enabled {
            let previous = upload
            upload = nil; uploadAttempt = nil
            previous?.cancel()
        }
    }

    func clear() throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try update { state in
            state.reports = []
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
            guard state.enabled else { return }
            let today = Self.day(now())
            if !state.reports.contains(where: { $0.day == today }) {
                #if arch(arm64)
                let architecture = "arm64"
                #elseif arch(x86_64)
                let architecture = "x86_64"
                #else
                let architecture = "unknown"
                #endif
                state.reports.append(Report(schema_version: 1, consent_version: Self.consentVersion,
                    report_id: UUID().uuidString.lowercased(), day: today, app_version: appVersion,
                    os_major: min(99, max(10, ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
                    architecture: architecture, counts: [:]))
            }
            guard let index = state.reports.firstIndex(where: { $0.day == today }) else { return }
            var events = [event]
            if let ms = durationMS, ms >= 0 {
                let bucket = ms < 100 ? 0 : ms < 1_000 ? 1 : ms < 10_000 ? 2 : 3
                if event == .gatewaySuccess || event == .gatewayFailure {
                    events.append([.gatewayLT100, .gatewayLT1000, .gatewayLT10000, .gatewayGTE10000][bucket])
                } else if event == .optimizerSuccess || event == .optimizerFailure || event == .optimizerCacheHit || event == .optimizerAbstained {
                    events.append([.optimizerLT100, .optimizerLT1000, .optimizerLT10000, .optimizerGTE10000][bucket])
                }
            }
            for entry in events {
                state.reports[index].counts[entry.rawValue] = min(1_000_000, (state.reports[index].counts[entry.rawValue] ?? 0) + 1)
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
                guard state.enabled, state.leaseUntil <= timestamp, state.retryAfter <= timestamp,
                      let report = state.reports.first(where: { $0.day < Self.day(now()) }) else { return nil }
                state.leaseID = report.report_id
                let attempt = UUID().uuidString.lowercased()
                state.leaseToken = attempt
                state.leaseUntil = timestamp + 60
                return (report, state.generation, attempt)
            }
            guard let (report, generation, attempt) = prepared else { return }
            let data = try JSONEncoder().encode(report)
            guard data.count <= 16_384 else { return }
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
            if success { state.reports.removeAll { $0.report_id == reportID } }
            state.leaseID = nil
            state.leaseToken = nil
            state.leaseUntil = 0
            state.retryAfter = now().timeIntervalSince1970 + (success ? 0 : 900)
            state.lastResult = success ? "sent" : "failed"
        }
        if uploadAttempt == attempt { upload = nil; uploadAttempt = nil }
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
            let valid = state.schemaVersion == 1 && UUID(uuidString: state.generation) != nil
                && ["never", "sent", "failed", "disabled"].contains(state.lastResult)
                && state.reports.count <= 8 && Set(state.reports.map(\.day)).count == state.reports.count
                && Set(state.reports.map(\.report_id)).count == state.reports.count
                && state.reports.allSatisfy { report in
                    report.schema_version == 1 && report.consent_version == Self.consentVersion
                    && UUID(uuidString: report.report_id) != nil && Self.validVersion(report.app_version)
                    && (10...99).contains(report.os_major) && ["arm64", "x86_64", "unknown"].contains(report.architecture)
                    && Self.validDay(report.day) && !report.counts.isEmpty && report.counts.count <= ProductAnalyticsEvent.allCases.count
                    && report.counts.allSatisfy { ProductAnalyticsEvent(rawValue: $0.key) != nil && (1...1_000_000).contains($0.value) }
                }
            if !valid { state = State() }
            if !state.enabled { state.reports = [] }
            state.reports.removeAll { $0.day < oldest || $0.day > today }
            state.reports.sort { $0.day < $1.day }
            let result = try body(&state)
            // Do not create analytics state just because the app was opened.
            if original != nil || state.enabled || state.lastResult == "disabled" {
                let data = try JSONEncoder().encode(state)
                guard let string = String(data: data, encoding: .utf8), data.count <= 65_536 else { throw AppError.usage("analytics_state_too_large") }
                try catalog.setMeta(Self.stateKey, string)
            }
            return result
        }
    }

    private static func decodeState(_ value: String) -> State? {
        guard value.utf8.count <= 65_536, let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let required: Set<String> = ["schemaVersion", "enabled", "consentVersion", "generation", "reports", "leaseUntil", "retryAfter", "lastResult"]
        let allowed = required.union(["endpoint", "leaseID", "leaseToken"])
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
              let reports = object["reports"] as? [[String: Any]], reports.count <= 8 else { return nil }
        let fields: Set<String> = ["schema_version", "consent_version", "report_id", "day", "app_version", "os_major", "architecture", "counts"]
        guard reports.allSatisfy({ Set($0.keys) == fields }) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func day(_ date: Date) -> String { String(UTC.iso(date).prefix(10)) }
    private static func validDay(_ value: String) -> Bool {
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
        AnalyticsHTTPUpload(endpoint: endpoint, data: data, completion: completion)
    }
}

/// Ephemeral, no cookies or credentials, no redirects, bounded response body.
private final class AnalyticsHTTPUpload: NSObject, URLSessionDataDelegate, AnalyticsUpload, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: (@Sendable (Bool) -> Void)?
    private var accepted = false
    private var received = 0

    init(endpoint: URL, data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KeysProductAnalytics/1", forHTTPHeaderField: "User-Agent")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() { finish(false) }
    private func finish(_ success: Bool) {
        lock.lock()
        let callback = completion
        completion = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        callback?(success)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        accepted = (response as? HTTPURLResponse)?.statusCode == 204
        completionHandler(response.expectedContentLength > 4_096 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        if received > 4_096 { accepted = false; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && accepted)
    }
}
