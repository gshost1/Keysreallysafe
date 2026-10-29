import Foundation

/// The single output guard: every `tools/call` result passes through `screened(_:)`
/// before `MCPServer` writes it, and there is no other write path for results. Two
/// rules, and a rejection REPLACES the whole result with one fixed error result —
/// it never scrubs in place and never echoes what it rejected:
///
/// 1. **The unconditional token-shape rule.** Any full `ksf_`/`ksfc_`/`ksfp_` token
///    shape in the result is rejected, with exactly one permitted handover value:
///    the token a `grant_status` approval is delivering, declared per result by the
///    tool delivering it (`MCPToolResult.handover`). The exemption is one value for
///    that one result — never a tool, never a rule — so a result carrying it plus a
///    second token is still rejected.
/// 2. **The injected forbidden-value rule.** Any value from the injected
///    forbidden-value set, appearing anywhere in the result, is rejected. The needle
///    is the exact whole value — never a fragment, a prefix or a shape-derived
///    pattern — so a last-4 hint or a bare `ksf_` prefix can never false-positive.
///
/// **Production wiring is deliberately empty-set.** The production initializer takes
/// no secret store and never reads one — no MCP tool is presence-gated, so no vault
/// value can be in this process's memory — and the production forbidden-value set is
/// empty by construction. The real production protection is the unconditional
/// token-shape rule plus the structural rule that no MCP tool may call a
/// presence-gated read; the value rule is the seam a test uses to prove the
/// mechanism with a planted value.
///
/// Fail-closed: if the forbidden-value provider throws, the result is refused, not
/// passed. The guard never logs or persists what it rejected — a rejection is
/// answered with the fixed replacement and nothing else.
///
/// `@unchecked Sendable`: the guard is constructed once and used from the server's
/// single-threaded loop; a test's provider closure may capture a lock-protected
/// test double, which is safe for the same single-threaded use.
struct MCPOutputGuard: @unchecked Sendable {
    /// The fixed sentence every rejection is replaced with. It names neither the
    /// value nor the result, so there is nothing in it a leak could compare against.
    static let rejectionMessage =
        "the tool result was withheld because it contained a secret value or a token; Keysrs never sends one through a tool result"

    /// The full token shapes rule 1 rejects, as ONE constant — the single place the
    /// shape list lives (a minted-shape change updates this line alone). A grant
    /// token is `ksf_` + 8-hex id + `_` + base64url(32 bytes) (43 chars); a client
    /// capability and a relay-pairing credential are `ksfc_`/`ksfp_` + 24 bytes hex
    /// (48 chars). The length floors sit below the minted lengths so a small change
    /// in minting cannot silently outgrow the rule, while a bare prefix or a
    /// malformed `ksf_1` / `ksfc_short` can never match.
    static let tokenShapePattern =
        "ksf_[0-9a-fA-F]{8}_[A-Za-z0-9_-]{32,}|ksfc_[0-9a-fA-F]{32,}|ksfp_[0-9a-fA-F]{32,}"

    /// The fixed replacement every rejection becomes: a plain `isError` result
    /// carrying the constant message.
    static var replacement: MCPToolResult { MCPToolResult.failure(rejectionMessage) }

    private let forbidden: () throws -> [String]

    /// The production guard: built with no arguments and nothing to read — the
    /// forbidden-value set is empty by construction, and the unconditional
    /// token-shape rule is the live protection.
    init() {
        forbidden = { [] }
    }

    /// The production guard, for the wiring that ships. `MCPRun` passes this
    /// explicitly so the production construction stays greppable.
    static let production = MCPOutputGuard()

    /// A test seam: an explicit forbidden-value list (the planted values).
    init(forbiddenValues: [String]) {
        let values = forbiddenValues
        forbidden = { values }
    }

    /// A test seam: a forbidden-value provider, fetched fresh on every inspection
    /// so a fault is seen immediately and a recovery on the very next call. A
    /// provider that throws fails the whole inspection closed.
    init(forbiddenValues: @escaping () throws -> [String]) {
        forbidden = forbiddenValues
    }

    /// The injected forbidden-value set, fetched fresh. The production set is empty.
    func forbiddenValues() throws -> [String] { try forbidden() }

    /// The result to write: `result` itself when it is clean, the fixed replacement
    /// when it is not. This is the only verdict the write path ever sees.
    func screened(_ result: MCPToolResult) -> MCPToolResult {
        let values: [String]
        do {
            values = try forbidden()
        } catch {
            // Fail-closed: a provider fault refuses the result, never passes it.
            return Self.replacement
        }
        // The result is scanned exactly as a client could read it: the serialized
        // text the wire carries, plus every string of its JSON tree — keys and
        // values, at any depth, including text that is itself escaped JSON. A result
        // that cannot be encoded cannot be scanned, so it is refused rather than
        // guessed about.
        guard let wire = try? JSONValue.data(result.jsonObject()) else { return Self.replacement }
        var scopes = [String(decoding: wire, as: UTF8.self)]
        Self.collect(result.jsonObject(), into: &scopes)

        // The one permitted handover value is masked out of every scan first;
        // everything left that matches a rule rejects the whole result.
        let exempt = result.handover ?? ""
        for scope in scopes {
            let text = exempt.isEmpty ? scope : scope.replacingOccurrences(of: exempt, with: "\u{FFFD}")
            for value in values where !value.isEmpty {
                if text.range(of: value) != nil { return Self.replacement }
            }
            if text.range(of: Self.tokenShapePattern, options: .regularExpression) != nil {
                return Self.replacement
            }
        }
        return result
    }

    /// Every string in a JSON tree — keys and values — at any depth.
    private static func collect(_ node: Any, into scopes: inout [String]) {
        switch node {
        case let string as String:
            scopes.append(string)
        case let object as [String: Any]:
            for (key, value) in object {
                scopes.append(key)
                collect(value, into: &scopes)
            }
        case let array as [Any]:
            for element in array {
                collect(element, into: &scopes)
            }
        default:
            break
        }
    }
}
