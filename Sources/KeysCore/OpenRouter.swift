import Foundation

protocol OpenRouterFetching: Sendable {
    func fetch(secret: String) throws -> CatalogDB.ProviderSnapshot
}

struct OpenRouterHTTP: OpenRouterFetching {
    static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    var endpoint: URL

    init(endpoint: URL = OpenRouterHTTP.defaultEndpoint) {
        self.endpoint = endpoint
    }

    func fetch(secret: String) throws -> CatalogDB.ProviderSnapshot {
        let url = endpoint
        guard url.host == "openrouter.ai" || BindPolicy.isLoopbackHostname(url.host ?? "") else {
            throw AppError.http("refusing outbound host \(url.host ?? "")")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        let session = RedirectDenyingDelegate.makeSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let box = SyncBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.finish(data: data, response: response, error: error)
        }
        task.resume()
        box.wait()
        if let error = box.error {
            throw AppError.http(error.localizedDescription)
        }
        guard let http = box.response as? HTTPURLResponse else {
            throw AppError.http("openrouter: no response")
        }
        guard (200..<300).contains(http.statusCode), let data = box.data else {
            throw AppError.http("openrouter: HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) else {
            throw AppError.http("openrouter: invalid json")
        }
        let payload = JSONValue.object(obj["data"]) ?? obj
        return CatalogDB.ProviderSnapshot(
            provider: "openrouter",
            keyName: "",
            ts: UTC.iso(Date()),
            usageDaily: JSONValue.double(payload["usage_daily"]),
            usageWeekly: JSONValue.double(payload["usage_weekly"]),
            usageMonthly: JSONValue.double(payload["usage_monthly"]),
            limit: JSONValue.double(payload["limit"]),
            limitRemaining: JSONValue.double(payload["limit_remaining"]),
            rawKind: JSONValue.string(payload["limit_reset"])
        )
    }
}

enum OpenRouterScheduler {
    static let interval: TimeInterval = 15 * 60

    static func schedule(service: KeysService, interval: TimeInterval = interval) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            try? service.pollOpenRouter()
        }
        RunLoop.current.add(timer, forMode: .common)
    }
}

/// Wait for a URLSession callback without deadlocking the main run loop.
private final class SyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sema = DispatchSemaphore(value: 0)
    private var done = false
    var data: Data?
    var response: URLResponse?
    var error: Error?

    func finish(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        done = true
        lock.unlock()
        sema.signal()
    }

    func wait() {
        if Thread.isMainThread {
            while true {
                lock.lock()
                let done = self.done
                lock.unlock()
                if done { return }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            sema.wait()
        }
    }
}
