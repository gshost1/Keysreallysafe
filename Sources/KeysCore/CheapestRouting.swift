import Foundation

/// "Cheapest upstream" for aggregators whose request body can ask for it. A per-key setting,
/// off by default: on, the gateway adds the aggregator's own price-sort field to a JSON request
/// that names no routing preference of its own, and never touches one that does. The body is
/// changed only on its way upstream; nothing about it is stored or logged.
enum CheapestRouting {
    struct Rule: Equatable {
        /// Object members the preference lives under, outermost first.
        var path: [String]
        var field: String
        var value: String
        /// Members of that object that already say how to route. Any one of them means the
        /// caller chose, and the body goes upstream as sent.
        var explicit: Set<String>
        /// Upstream paths (after the provider prefix is joined) the field is valid on.
        var endpoints: [String]
        /// Model suffixes that are themselves a routing choice (OpenRouter's `:nitro`, `:floor`).
        var modelSuffixes: [String] = []
        /// Top-level members that also choose a route. Vercel's chat completions take a
        /// `provider` shorthand and fail a request whose two forms disagree.
        var rootExplicit: Set<String> = []
    }

    /// Only aggregators that document a request-level price sort are here; the rest are left
    /// alone (see `docs/cheapest-routing.md` for which and why).
    static func rule(provider: String) -> Rule? {
        switch provider {
        case "openrouter":
            // https://openrouter.ai/docs/features/provider-routing
            return Rule(
                path: ["provider"], field: "sort", value: "price",
                explicit: ["sort", "order", "only"],
                endpoints: ["/api/v1/chat/completions", "/api/v1/completions", "/api/v1/responses", "/api/v1/messages"],
                modelSuffixes: [":nitro", ":floor"]
            )
        case "vercel-ai-gateway":
            // https://vercel.com/docs/ai-gateway/models-and-providers/provider-filtering-and-ordering
            return Rule(
                path: ["providerOptions", "gateway"], field: "sort", value: "cost",
                explicit: ["sort", "order", "only"],
                endpoints: ["/v4/ai/language-model", "/v1/chat/completions", "/v1/responses", "/v1/messages"],
                rootExplicit: ["provider"]
            )
        default:
            return nil
        }
    }

    static func supports(provider: String) -> Bool { rule(provider: provider) != nil }

    /// The body to send instead, or nil to send the caller's bytes unchanged. Everything that is
    /// not an uncompressed JSON object POSTed to a listed endpoint is left alone, as is any body
    /// that already routes, and any body this cannot edit without guessing.
    static func apply(_ body: Data, provider: String, path: String, method: String, headers: [String: String]) -> Data? {
        guard let rule = rule(provider: provider), method.uppercased() == "POST",
              rule.endpoints.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              let type = headers["content-type"]?.lowercased(), type.contains("json"),
              (headers["content-encoding"] ?? "identity").lowercased() == "identity",
              let root = (try? JSONSerialization.jsonObject(with: body)).flatMap(JSONValue.object)
        else { return nil }
        if !rule.rootExplicit.isDisjoint(with: root.keys) { return nil }
        if let model = JSONValue.string(root["model"]), rule.modelSuffixes.contains(where: { model.hasSuffix($0) }) {
            return nil
        }
        // Walk the members the field lives under: the ones present must be objects, and the
        // innermost may not already route.
        var existing = 0
        var object = root
        for name in rule.path {
            guard let value = object[name] else { break }
            guard let next = JSONValue.object(value) else { return nil }
            object = next
            existing += 1
        }
        if existing == rule.path.count, !rule.explicit.isDisjoint(with: object.keys) { return nil }

        var bytes = [UInt8](body)
        guard var at = JSONScan.skipSpace(bytes, 0), at < bytes.count, bytes[at] == UInt8(ascii: "{") else { return nil }
        for name in rule.path.prefix(existing) {
            // nil when the member can't be found byte-for-byte (an escaped name) or appears twice;
            // either way a parser upstream might read it differently than this one did.
            guard let value = JSONScan.member(bytes, objectAt: at, name: name), bytes[value] == UInt8(ascii: "{") else {
                return nil
            }
            at = value
        }
        var literal = "\(quoted(rule.field)):\(quoted(rule.value))"
        for name in rule.path.dropFirst(existing).reversed() {
            literal = "\(quoted(name)):{\(literal)}"
        }
        guard let next = JSONScan.skipSpace(bytes, at + 1), next < bytes.count else { return nil }
        if bytes[next] != UInt8(ascii: "}") { literal += "," }
        bytes.insert(contentsOf: Array(literal.utf8), at: at + 1)
        let out = Data(bytes)
        // The edit must parse, keep every member the caller sent, and carry the field.
        guard var check = (try? JSONSerialization.jsonObject(with: out)).flatMap(JSONValue.object),
              Set(check.keys).isSuperset(of: root.keys)
        else { return nil }
        for name in rule.path {
            guard let next = JSONValue.object(check[name]) else { return nil }
            check = next
        }
        return JSONValue.string(check[rule.field]) == rule.value ? out : nil
    }

    private static func quoted(_ s: String) -> String { "\"" + s + "\"" }
}

/// Byte offsets in a JSON text that `JSONSerialization` has already accepted, so this only
/// finds boundaries and never validates. Iterative, so nesting depth costs no stack.
enum JSONScan {
    static func skipSpace(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        return i
    }

    /// Index just past the string whose opening quote is at `start`.
    static func skipString(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    /// Index just past the value starting at `start`.
    static func skipValue(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case UInt8(ascii: "\""):
            return skipString(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    guard let end = skipString(b, i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) {
                i += 1
            }
            return i
        }
    }

    /// Where the value of member `name` starts in the object whose `{` is at `objectAt`, when
    /// the name is written plainly and exactly once.
    static func member(_ b: [UInt8], objectAt: Int, name: String) -> Int? {
        let want = Array(name.utf8)
        var found: Int?
        guard var i = skipSpace(b, objectAt + 1) else { return nil }
        if i < b.count, b[i] == UInt8(ascii: "}") { return nil }
        while i < b.count {
            guard b[i] == UInt8(ascii: "\""), let keyEnd = skipString(b, i) else { return nil }
            let key = Array(b[(i + 1)..<(keyEnd - 1)])
            guard let colon = skipSpace(b, keyEnd), colon < b.count, b[colon] == UInt8(ascii: ":"),
                  let value = skipSpace(b, colon + 1), let end = skipValue(b, value)
            else { return nil }
            if key == want {
                if found != nil { return nil }
                found = value
            }
            guard let after = skipSpace(b, end), after < b.count else { return nil }
            if b[after] == UInt8(ascii: "}") { break }
            guard b[after] == UInt8(ascii: ","), let next = skipSpace(b, after + 1) else { return nil }
            i = next
        }
        return found
    }
}
