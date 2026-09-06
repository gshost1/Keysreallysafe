import Foundation

/// Read-only provider checks: authentication status and model list. Never falls back to a
/// billable generation request when a provider has no list endpoint.
enum ProviderCheck {
    static let timeout: TimeInterval = 20
    static let maxModels = 2000
    static let userAgent = "keysreallysafe/0.2 (+https://github.com/gshost1/Keysreallysafe)"

    enum Outcome: String, Sendable {
        case ok
        case providerAuthFailed = "provider_auth_failed"
        case providerRefused = "provider_refused"
        case providerError = "provider_error"
        case network
        case malformed
        case noCheckEndpoint = "no_check_endpoint"

        var line: String {
            switch self {
            case .ok: return "ok"
            case .providerAuthFailed: return "provider rejected the key (401)"
            case .providerRefused: return "provider refused the request (403): key is recognised but not allowed here"
            case .providerError: return "provider error"
            case .network: return "network failure (no response from the provider host)"
            case .malformed: return "provider answered but the body was not the expected model list"
            case .noCheckEndpoint: return "no read-only check endpoint for this provider; nothing was sent"
            }
        }
    }

    struct Result: Equatable, Sendable {
        var key: String
        var provider: String
        var host: String
        var checkedAt: String
        var outcome: Outcome
        var httpStatus: Int?
        var models: [String]
        var requestId: String?
        var message: String?
        var endpoint: String?

        var ok: Bool { outcome == .ok }

        func jsonObject() -> [String: Any] {
            [
                "key": key,
                "provider": provider,
                "host": host,
                "checked_at": checkedAt,
                "outcome": outcome.rawValue,
                "ok": ok,
                "http_status": httpStatus as Any? ?? NSNull(),
                "model_count": models.count,
                "models": models,
                "request_id": requestId as Any? ?? NSNull(),
                "message": message as Any? ?? NSNull(),
                "endpoint": endpoint as Any? ?? NSNull(),
                "summary": summary,
            ]
        }

        var summary: String {
            var s = outcome.line
            if let httpStatus, outcome != .ok, outcome != .network { s += " [HTTP \(httpStatus)]" }
            if ok { s = "ok, \(models.count) models" }
            if let requestId { s += "  request-id \(requestId)" }
            if let message, outcome != .ok { s += "  \(message)" }
            return s
        }
    }

    struct Endpoint: Equatable {
        var path: String
        var headers: [String: String]
    }

    /// Provider-specific, read-only. Nil means "do not probe".
    static func endpoint(for provider: Providers.Record) -> Endpoint? {
        switch provider.api {
        case "openai":
            return Endpoint(path: GatewayPath.join(prefix: provider.pathPrefix, rest: "models"), headers: [:])
        case "anthropic":
            return Endpoint(
                path: GatewayPath.join(prefix: provider.pathPrefix, rest: "models"),
                headers: ["anthropic-version": "2023-06-01"]
            )
        case "gemini":
            return Endpoint(path: GatewayPath.join(prefix: provider.pathPrefix, rest: "models"), headers: [:])
        default:
            return nil
        }
    }

    static func run(
        key: String,
        provider: Providers.Record,
        host: String,
        secret: String,
        fetcher: any ProviderCheckFetching,
        now: Date = Date()
    ) -> Result {
        let ts = UTC.iso(now)
        guard let endpoint = endpoint(for: provider) else {
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .noCheckEndpoint, httpStatus: nil, models: [], requestId: nil,
                message: "provider api \(provider.api) has no model-list endpoint in providers.json", endpoint: nil
            )
        }
        let hostname = host.split(separator: ":").first.map(String.init) ?? host
        let scheme = BindPolicy.isLoopbackHostname(hostname) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)\(endpoint.path)") else {
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .network, httpStatus: nil, models: [], requestId: nil,
                message: "invalid host", endpoint: endpoint.path
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(provider.authPrefix + secret, forHTTPHeaderField: provider.authHeader)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try fetcher.fetch(req)
        } catch {
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .network, httpStatus: nil, models: [], requestId: nil,
                message: Redact.scrub(error.localizedDescription, secrets: [secret]), endpoint: endpoint.path
            )
        }
        let requestId = Self.requestId(http)
        let message = Self.safeMessage(data, secret: secret)
        switch http.statusCode {
        case 200..<300:
            let models = parseModels(api: provider.api, data: data)
            if models.isEmpty, !looksLikeList(api: provider.api, data: data) {
                let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let why = ctype.contains("text/html") || data.prefix(64).contains(where: { $0 == UInt8(ascii: "<") })
                    ? "answered a web page, not JSON; \(host) is probably the app host, not the API host"
                    : message
                return Result(
                    key: key, provider: provider.id, host: host, checkedAt: ts,
                    outcome: .malformed, httpStatus: http.statusCode, models: [], requestId: requestId,
                    message: why, endpoint: endpoint.path
                )
            }
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .ok, httpStatus: http.statusCode, models: Array(models.prefix(maxModels)),
                requestId: requestId, message: nil, endpoint: endpoint.path
            )
        case 401:
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .providerAuthFailed, httpStatus: 401, models: [], requestId: requestId,
                message: message, endpoint: endpoint.path
            )
        case 403:
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .providerRefused, httpStatus: 403, models: [], requestId: requestId,
                message: message, endpoint: endpoint.path
            )
        default:
            return Result(
                key: key, provider: provider.id, host: host, checkedAt: ts,
                outcome: .providerError, httpStatus: http.statusCode, models: [], requestId: requestId,
                message: message, endpoint: endpoint.path
            )
        }
    }

    static func parseModels(api: String, data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) else {
            return []
        }
        var ids: [String] = []
        switch api {
        case "gemini":
            for item in (root["models"] as? [Any]) ?? [] {
                guard let obj = JSONValue.object(item), var name = JSONValue.string(obj["name"]) else { continue }
                if name.hasPrefix("models/") { name = String(name.dropFirst("models/".count)) }
                ids.append(name)
            }
        default:
            for item in (root["data"] as? [Any]) ?? [] {
                guard let obj = JSONValue.object(item), let id = JSONValue.string(obj["id"]) else { continue }
                ids.append(id)
            }
        }
        return Array(Set(ids)).sorted()
    }

    private static func looksLikeList(api: String, data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) else {
            return false
        }
        return (api == "gemini" ? root["models"] : root["data"]) is [Any]
    }

    static func requestId(_ http: HTTPURLResponse) -> String? {
        for name in ["x-request-id", "request-id", "openai-request-id", "x-amzn-requestid", "cf-ray", "x-trace-id"] {
            if let v = http.value(forHTTPHeaderField: name), !v.isEmpty { return String(v.prefix(80)) }
        }
        return nil
    }

    /// The provider's own error text, trimmed and scrubbed. Never the raw body.
    static func safeMessage(_ data: Data, secret: String) -> String? {
        guard !data.isEmpty else { return nil }
        var text: String?
        if let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) {
            if let err = JSONValue.object(root["error"]) {
                text = JSONValue.string(err["message"]) ?? JSONValue.string(err["type"])
            } else if let s = JSONValue.string(root["error"]) {
                text = s
            } else if let s = JSONValue.string(root["message"]) ?? JSONValue.string(root["detail"]) {
                text = s
            }
        } else if let s = String(data: data.prefix(160), encoding: .utf8), !s.contains("<") {
            text = s
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.count > 200 { t = String(t.prefix(200)) + "…" }
        return Redact.scrub(t, secrets: [secret])
    }
}

protocol ProviderCheckFetching: Sendable {
    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

/// Ephemeral session, no cookies, no redirects (a redirect would carry the auth header elsewhere).
struct ProviderCheckHTTP: ProviderCheckFetching {
    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ProviderCheck.timeout
        config.timeoutIntervalForResource = ProviderCheck.timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let box = FetchBox()
        session.dataTask(with: request) { data, response, error in
            box.finish(data: data, response: response, error: error)
        }.resume()
        box.wait()
        if let error = box.error { throw error }
        guard let http = box.response as? HTTPURLResponse else {
            throw AppError.http("no HTTP response")
        }
        return (box.data ?? Data(), http)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class FetchBox: @unchecked Sendable {
    private let sema = DispatchSemaphore(value: 0)
    var data: Data?
    var response: URLResponse?
    var error: Error?
    func finish(data: Data?, response: URLResponse?, error: Error?) {
        self.data = data
        self.response = response
        self.error = error
        sema.signal()
    }
    func wait() { sema.wait() }
}
