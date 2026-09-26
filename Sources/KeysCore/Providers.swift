import Foundation

enum Providers {
    struct Record: Equatable, Sendable {
        var id: String
        var name: String
        var host: String?
        var api: String
        var authHeader: String
        var authPrefix: String
        var pathPrefix: String
        var gateway: Bool
    }

    struct Catalog: Sendable {
        var raw: Data
        var byID: [String: Record]
    }

    static let cache = FixtureCache<Catalog>(
        fileName: "providers.json", envKey: "KEYS_PROVIDERS_JSON", missing: "providers.json missing or empty",
        fallback: Catalog(raw: Data("{}".utf8), byID: [:]), parse: parse
    )

    static func loadAtStartup() {
        _ = cache.value
    }

    static func provider(id: String) -> Record? {
        cache.value.byID[id]
    }

    /// Bytes of `providers.json` as loaded; the dashboard fetches the same file from Web/.
    static func rawJSON() -> Data {
        cache.value.raw
    }

    private static func parse(_ data: Data) -> Catalog? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let list = root["providers"] as? [Any]
        else { return nil }
        var byID: [String: Record] = [:]
        for item in list {
            guard let obj = JSONValue.object(item),
                  let id = JSONValue.string(obj["id"])
            else { continue }
            byID[id] = Record(
                id: id,
                name: JSONValue.string(obj["name"]) ?? id,
                host: JSONValue.string(obj["host"]),
                api: JSONValue.string(obj["api"]) ?? "other",
                authHeader: JSONValue.string(obj["auth_header"]) ?? "Authorization",
                authPrefix: stringAllowEmpty(obj["auth_prefix"]) ?? "Bearer ",
                pathPrefix: stringAllowEmpty(obj["path_prefix"]) ?? "",
                gateway: JSONValue.bool(obj["gateway"]) ?? true
            )
        }
        return Catalog(raw: data, byID: byID)
    }

    private static func stringAllowEmpty(_ any: Any?) -> String? {
        if any is NSNull { return nil }
        if let s = any as? String { return s }
        return nil
    }
}

extension Providers.Record {
    /// The authenticated request to this provider. Caller headers go on first, then identity
    /// encoding, then the provider's auth header, so a caller's own copy of that header
    /// (xi-api-key, x-portkey-api-key, X-Subscription-Token, ...) never replaces the vault
    /// secret. Loopback hosts are plain http, everything else https.
    func upstreamRequest(
        host: String, path: String, query: String = "", method: String,
        headers: [String: String], secret: String, timeout: TimeInterval
    ) -> URLRequest? {
        let hostname = host.split(separator: ":").first.map(String.init) ?? host
        let scheme = BindPolicy.isLoopbackHostname(hostname) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)\(path)" + (query.isEmpty ? "" : "?" + query)) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(authPrefix + secret, forHTTPHeaderField: authHeader)
        return request
    }
}

enum GatewayHost {
    /// Hostname or IPv4 with optional port. No scheme, path, or userinfo.
    static func validate(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw AppError.usage("host is required") }
        if s.contains("://") || s.contains("/") || s.contains("@") || s.contains("\\") || s.contains(" ") {
            throw AppError.usage("invalid host")
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 2 { throw AppError.usage("invalid host") }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port) else {
                throw AppError.usage("invalid host")
            }
        }
        let name = String(parts[0])
        guard !name.isEmpty else { throw AppError.usage("invalid host") }
        return s
    }
}

enum GatewayPath {
    /// Join fixture `path_prefix` with the remainder after `/<keyname>`.
    /// If `rest` already starts with the prefix, do not double it.
    static func join(prefix: String, rest: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var trimmedRest = rest
        while trimmedRest.hasPrefix("/") {
            trimmedRest = String(trimmedRest.dropFirst())
        }
        let prefixPath = trimmedPrefix.isEmpty ? "" : "/" + trimmedPrefix
        let restPath = trimmedRest.isEmpty ? "" : "/" + trimmedRest
        if !prefixPath.isEmpty, restPath == prefixPath || restPath.hasPrefix(prefixPath + "/") {
            return restPath.isEmpty ? "/" : restPath
        }
        // A client that names its own API version is authoritative when the
        // fixture prefix is itself only a version: Vercel AI Gateway serves the
        // OpenAI-compatible API under /v1 and the AI SDK's native one under
        // /v4/ai, and Gemini serves /v1 beside /v1beta. Prefixes with a real
        // path (/api/gateway, and versioned ones like DeepInfra's /v1/openai)
        // still apply to everything, so the whole prefix must be the version.
        if isVersionSegment(trimmedPrefix[...]),
           isVersionSegment(trimmedRest.split(separator: "/").first) {
            return restPath
        }
        let combined = prefixPath + restPath
        return combined.isEmpty ? "/" : combined
    }

    /// `v1`, `v4`, `v1beta`: a leading `v`, digits, then letters only.
    static func isVersionSegment(_ segment: Substring?) -> Bool {
        guard let segment, segment.count >= 2, segment.first == "v" else { return false }
        let body = segment.dropFirst()
        guard let firstNonDigit = body.firstIndex(where: { !$0.isNumber }) else { return true }
        return firstNonDigit > body.startIndex && body[firstNonDigit...].allSatisfy { $0.isLetter }
    }
}

enum GatewayEstimate {
    static func usd(
        model: String?,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        api: String? = nil
    ) -> Double? {
        // TypeSafe's System One reports neither tokens nor cost.
        guard api != "typesafe-systemone", let model else { return nil }
        return ModelPrices.usd(model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                               inputIncludesCacheRead: api != "anthropic")
    }
}
