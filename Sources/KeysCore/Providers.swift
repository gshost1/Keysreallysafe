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
        /// Group the picker shows the record under (labs, routers, …). Nil only for a broken entry.
        var group: String? = nil
        /// Secret prefix hint the Add dialog guesses the provider from (e.g. "sk-ant-").
        var keyPrefix: String? = nil
        /// Shown when the provider asks for a per-account host.
        var note: String? = nil
        /// Not offered in the Add dialog any more, but still resolves so existing keys keep working.
        var hidden: Bool = false
        /// Added by the user rather than shipped; removable, and it wins over a built-in id.
        var custom: Bool = false
    }

    struct Catalog: Sendable {
        var raw: Data
        var groups: [[String: String]]
        var list: [Record]
        var byID: [String: Record]
    }

    static let cache = FixtureCache<Catalog>(
        fileName: "providers.json", envKey: "KEYS_PROVIDERS_JSON", missing: "providers.json missing or empty",
        fallback: Catalog(raw: Data("{}".utf8), groups: [], list: [], byID: [:]), parse: parse
    )

    /// Providers the user added, keyed by id. Takes precedence over the shipped file, so a
    /// custom record can extend the catalog or deliberately override a built-in entry. Guarded
    /// like the fixture cache because both are process-wide and read from any queue.
    private static let overlayLock = NSLock()
    nonisolated(unsafe) private static var overlay: [String: Record] = [:]

    static func setOverlay(_ records: [String: Record]) {
        overlayLock.lock()
        overlay = records
        overlayLock.unlock()
    }

    static func loadAtStartup() {
        _ = cache.value
    }

    static func provider(id: String) -> Record? {
        if let custom = overlayLock.withLock({ overlay[id] }) { return custom }
        return cache.value.byID[id]
    }

    /// Snapshot of the user-added overlay, for the guided CLI picker's merged listing.
    static func overlayRecords() -> [Record] {
        overlayLock.withLock { Array(overlay.values) }
    }

    /// Shipped records in file order, for the merged listing. Hidden ones stay in; the listing
    /// flags them and the callers that must not show them skip the flag.
    static func builtinList() -> [Record] {
        cache.value.list
    }

    static func builtinGroups() -> [[String: String]] {
        cache.value.groups
    }

    /// Bytes of `providers.json` as loaded; the dashboard fetches the same file from Web/.
    static func rawJSON() -> Data {
        cache.value.raw
    }

    private static func parse(_ data: Data) -> Catalog? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let list = root["providers"] as? [Any]
        else { return nil }
        let groups = (root["groups"] as? [Any])?.compactMap { group -> [String: String]? in
            guard let obj = JSONValue.object(group),
                  let id = JSONValue.string(obj["id"]) else { return nil }
            return ["id": id, "name": JSONValue.string(obj["name"]) ?? id]
        } ?? []
        var byID: [String: Record] = [:]
        var ordered: [Record] = []
        for item in list {
            guard let obj = JSONValue.object(item),
                  let id = JSONValue.string(obj["id"])
            else { continue }
            let record = Record(
                id: id,
                name: JSONValue.string(obj["name"]) ?? id,
                host: JSONValue.string(obj["host"]),
                api: JSONValue.string(obj["api"]) ?? "other",
                authHeader: JSONValue.string(obj["auth_header"]) ?? "Authorization",
                authPrefix: stringAllowEmpty(obj["auth_prefix"]) ?? "Bearer ",
                pathPrefix: stringAllowEmpty(obj["path_prefix"]) ?? "",
                gateway: JSONValue.bool(obj["gateway"]) ?? true,
                group: JSONValue.string(obj["group"]),
                keyPrefix: JSONValue.string(obj["key_prefix"]),
                note: JSONValue.string(obj["note"]),
                hidden: JSONValue.bool(obj["hidden"]) ?? false
            )
            byID[id] = record
            ordered.append(record)
        }
        return Catalog(raw: data, groups: groups, list: ordered, byID: byID)
    }

    private static func stringAllowEmpty(_ any: Any?) -> String? {
        if any is NSNull { return nil }
        if let s = any as? String { return s }
        return nil
    }
}

enum ProviderID {
    /// Same shape as the shipped ids (anthropic, azure-openai, …): one word the user can also
    /// type free-hand into the Add dialog, so it must survive as a catalog row's `provider`.
    static func validate(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40, trimmed.wholeMatch(of: /^[a-z0-9][a-z0-9-]*$/) != nil else {
            throw AppError.usage(
                "invalid provider id \(trimmed.debugDescription) (lowercase letters, digits and dashes, e.g. my-gateway)"
            )
        }
    }
}

extension Providers.Record {
    /// The dashboard's catalog shape (`/api/providers`), one record. `hiddenReason` is
    /// "app" when the shipped catalog retired it and "user" when it was hidden here; the
    /// picker skips either, while the key table still resolves names from them.
    func jsonObject(group: String? = nil, hiddenReason: String? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "name": name,
            "api": api,
            "auth_header": authHeader,
            "auth_prefix": authPrefix,
            "path_prefix": pathPrefix,
            "gateway": gateway,
            "custom": custom,
        ]
        out["group"] = (group ?? self.group) as Any? ?? NSNull()
        out["host"] = host as Any? ?? NSNull()
        out["key_prefix"] = keyPrefix as Any? ?? NSNull()
        out["note"] = note as Any? ?? NSNull()
        out["hidden"] = hiddenReason as Any? ?? NSNull()
        return out
    }

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
