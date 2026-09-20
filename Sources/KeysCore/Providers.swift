import Foundation

enum Providers {
    struct Record: Equatable, Sendable {
        var id: String
        var name: String
        var group: String
        var host: String?
        var api: String
        var authHeader: String
        var authPrefix: String
        var pathPrefix: String
        var gateway: Bool
    }

    /// Tests replace this to load a temp fixture. Nil uses the usual search.
    nonisolated(unsafe) static var testFixtureURL: URL?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Cache?
    nonisolated(unsafe) private static var loggedMissing = false

    private struct Cache {
        var raw: Data
        var byID: [String: Record]
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

    static func provider(id: String) -> Record? {
        current().byID[id]
    }

    /// Bytes of `providers.json` as loaded. GET /api/providers returns this verbatim.
    static func rawJSON() -> Data {
        current().raw
    }

    private static func current() -> Cache {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    private static func load() -> Cache {
        let url = resolveFixtureURL()
        if let url, FileManager.default.isReadableFile(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
           let list = root["providers"] as? [Any]
        {
            var byID: [String: Record] = [:]
            for item in list {
                guard let obj = JSONValue.object(item),
                      let id = JSONValue.string(obj["id"])
                else { continue }
                byID[id] = Record(
                    id: id,
                    name: JSONValue.string(obj["name"]) ?? id,
                    group: JSONValue.string(obj["group"]) ?? "",
                    host: JSONValue.string(obj["host"]),
                    api: JSONValue.string(obj["api"]) ?? "other",
                    authHeader: JSONValue.string(obj["auth_header"]) ?? "Authorization",
                    authPrefix: stringAllowEmpty(obj["auth_prefix"]) ?? "Bearer ",
                    pathPrefix: stringAllowEmpty(obj["path_prefix"]) ?? "",
                    gateway: JSONValue.bool(obj["gateway"]) ?? true
                )
            }
            return Cache(raw: data, byID: byID)
        }
        if !loggedMissing {
            loggedMissing = true
            let line = "providers.json missing or empty\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return Cache(raw: Data("{}".utf8), byID: [:])
    }

    private static func stringAllowEmpty(_ any: Any?) -> String? {
        if any is NSNull { return nil }
        if let s = any as? String { return s }
        return nil
    }

    private static func resolveFixtureURL() -> URL? {
        FixturePath.resolve(
            fileName: "providers.json",
            envKey: "KEYS_PROVIDERS_JSON",
            testURL: testFixtureURL
        )
    }
}

/// Reviewed Jev protocols. A provider catalog entry alone never enables an
/// optimizer transport: its identity, route and authentication must match here.
struct OptimizerProvider: Equatable, Sendable {
    let id: String
    let label: String
    let host: String
    let path: String
    let modelID: String
    let api: String
    let pathPrefix: String

    static let supported = [
        OptimizerProvider(id: "vercel-ai-gateway", label: "Vercel AI Gateway", host: "ai-gateway.vercel.sh",
                          path: "/v4/ai/evaluation-model", modelID: "typesafe-ai/jev", api: "openai", pathPrefix: "/v1"),
        OptimizerProvider(id: "typesafe", label: "TypeSafe", host: "api.typesafe.ai",
                          path: "/v1/systemone", modelID: "jev-latest", api: "typesafe-systemone", pathPrefix: ""),
    ]

    var metadata: [String: Any] {
        ["id": id, "label": label, "model_id": modelID,
         "features": ["claude_compaction", "plan_reuse", "tool_selection", "model_routing", "memory_assessment"]]
    }

    func accepts(_ provider: Providers.Record) -> Bool {
        provider.id == id && provider.host == host && provider.gateway && provider.api == api &&
        provider.authHeader == "Authorization" && provider.authPrefix == "Bearer " &&
        provider.pathPrefix == pathPrefix
    }

    static func compatible(provider id: String, host: String?) -> OptimizerProvider? {
        guard let adapter = supported.first(where: { $0.id == id }),
              let provider = Providers.provider(id: id), adapter.accepts(provider),
              (host ?? provider.host) == adapter.host else { return nil }
        return adapter
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
        if api == "typesafe-systemone" { return nil }
        guard let model, let price = ModelPrices.lookup(model) else { return nil }
        if api == "anthropic" {
            return ClaudeEstimate.usd(
                model: model,
                input: input,
                output: output,
                cacheCreate: cacheWrite,
                cacheRead: cacheRead
            )
        }
        let m = 1_000_000.0
        let billedInput = max(0, input - cacheRead)
        return (Double(billedInput) / m) * price.inputPerMTok
            + (Double(output) / m) * price.outputPerMTok
            + (Double(cacheRead) / m) * price.cacheReadPerMTok
            + (Double(cacheWrite) / m) * price.inputPerMTok * 1.25
    }
}
