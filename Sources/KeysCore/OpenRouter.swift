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

        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try BlockingHTTP.send(request, timeout: 30)
        } catch is AppError {
            throw AppError.http("openrouter: no response")
        } catch {
            throw AppError.http(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
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
