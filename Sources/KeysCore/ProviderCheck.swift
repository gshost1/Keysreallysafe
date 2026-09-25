import Foundation

/// Read-only provider checks: authentication status and model list. Never falls back to a
/// billable generation request when a provider has no list endpoint.
enum ProviderCheck {
    static let timeout: TimeInterval = 20
    static let maxModels = 2000
    static let userAgent = "keysrs (+https://keysrs.com)"

    enum Outcome: String, Sendable {
        case ok
        case providerAuthFailed = "provider_auth_failed"
        case providerRefused = "provider_refused"
        case providerError = "provider_error"
        case redirect
        case network
        case malformed
        case noCheckEndpoint = "no_check_endpoint"

        var line: String {
            switch self {
            case .ok: return "ok"
            case .providerAuthFailed: return "provider rejected the key (401)"
            case .providerRefused: return "provider refused the request (403): key is recognised but not allowed here"
            case .providerError: return "provider error"
            case .redirect: return "host moved (redirect not followed; fix the host in Edit)"
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

    /// Provider-specific, read-only: the model list. Nil means "do not probe".
    static func endpoint(for provider: Providers.Record) -> Endpoint? {
        guard ["openai", "anthropic", "gemini"].contains(provider.api) else { return nil }
        return Endpoint(
            path: GatewayPath.join(prefix: provider.pathPrefix, rest: "models"),
            headers: provider.api == "anthropic" ? ["anthropic-version": "2023-06-01"] : [:]
        )
    }

    /// The recorded result for a provider with no read-only endpoint: nothing is sent.
    static func noEndpoint(key: String, provider: Providers.Record, host: String, now: Date = Date()) -> Result {
        Result(
            key: key, provider: provider.id, host: host, checkedAt: UTC.iso(now),
            outcome: .noCheckEndpoint, httpStatus: nil, models: [], requestId: nil,
            message: "no read-only endpoint for \(provider.name); nothing was sent", endpoint: nil
        )
    }

    static func run(
        key: String,
        provider: Providers.Record,
        host: String,
        secret: String,
        fetcher: any ProviderCheckFetching,
        now: Date = Date()
    ) -> Result {
        guard let endpoint = endpoint(for: provider) else {
            return noEndpoint(key: key, provider: provider, host: host, now: now)
        }
        func result(_ outcome: Outcome, _ status: Int? = nil, models: [String] = [], requestId: String? = nil,
                    message: String?) -> Result {
            Result(
                key: key, provider: provider.id, host: host, checkedAt: UTC.iso(now), outcome: outcome,
                httpStatus: status, models: models, requestId: requestId, message: message, endpoint: endpoint.path
            )
        }
        let headers = ["Accept": "application/json", "User-Agent": userAgent].merging(endpoint.headers) { $1 }
        guard let req = provider.upstreamRequest(
            host: host, path: endpoint.path, method: "GET", headers: headers, secret: secret, timeout: timeout
        ) else {
            return result(.network, message: "invalid host")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try fetcher.fetch(req)
        } catch {
            return result(.network, message: Redact.scrub(error.localizedDescription, secrets: [secret]))
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
                return result(.malformed, http.statusCode, requestId: requestId, message: why)
            }
            return result(.ok, http.statusCode, models: Array(models.prefix(maxModels)), requestId: requestId, message: nil)
        case 401:
            return result(.providerAuthFailed, 401, requestId: requestId, message: message)
        case 403:
            return result(.providerRefused, 403, requestId: requestId, message: message)
        case 301, 302, 307, 308:
            let location = http.value(forHTTPHeaderField: "Location") ?? "unknown"
            let target = URL(string: location)?.host ?? location
            return result(.redirect, http.statusCode, requestId: requestId,
                          message: "\(host) redirects to \(Redact.scrub(target, secrets: [secret])); the key was not sent there")
        default:
            return result(.providerError, http.statusCode, requestId: requestId, message: message)
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

struct ProviderCheckHTTP: ProviderCheckFetching {
    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        try BlockingHTTP.send(request, timeout: ProviderCheck.timeout)
    }
}
