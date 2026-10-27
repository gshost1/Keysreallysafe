import Foundation

/// A named, saved set of issuance-time bounds on grants. A profile is data, never a
/// credential: the catalog row holds key *names* and scope numbers only — no secret, no
/// token, no hash — so nothing in it can be replayed, and a forged row can only *ask*
/// under bounds the user still has to approve at the Touch ID prompt. A profile alone
/// mints nothing: grant issuance still costs exactly one presence prompt, and the gateway
/// request path (`GrantStore.authorize`) never reads this table. Every value is a
/// default-and-ceiling — an issuance may tighten it, never exceed it — and a grant issued
/// under a profile is self-contained: editing or deleting the profile afterwards changes
/// nothing about it.
struct Profile: Equatable, Sendable {
    /// 8 lowercase hex digits, the `GrantToken.newID()` shape.
    var id: String
    /// Unique across profiles. Follows the key-name charset because it appears in the
    /// Touch ID prompt and in JSON, where free text could forge punctuation.
    var name: String
    /// Vault key names, resolved against the catalog at save time. Choosing a key is what
    /// binds the host (the key's provider supplies it), so hosts are deliberately not a
    /// profile field and the `target_changed` kill path keeps its meaning.
    var keys: [String]
    /// Subset of `Grant.allMethods`. Empty cannot happen (validation demands one).
    var methods: Set<String>
    /// `GrantPath`-normalized scopes; empty = any path.
    var paths: [String]
    /// 1...1440 — the default and the ceiling for minutes on grants under this profile.
    var minutes: Int
    /// Default and ceiling for a grant's request cap; nil = uncapped.
    var maxRequests: Int?
    /// Default and ceiling for a grant's spend cap; nil = uncapped.
    var maxUsd: Double?
    /// Grants under this profile are meant to run while the user is away. Validation
    /// requires a hard cap so an unwatched grant is pre-committed to a number the user
    /// read at approval. Unattended grants still die on screen lock, restart and revoke.
    var unattended: Bool
    var createdAt: Date
    var updatedAt: Date

    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "keys": keys,
            "methods": methods.sorted(),
            "paths": paths,
            "minutes": minutes,
            "max_requests": maxRequests as Any? ?? NSNull(),
            "max_usd": maxUsd as Any? ?? NSNull(),
            "unattended": unattended,
            "created_at": UTC.iso(createdAt),
            "updated_at": UTC.iso(updatedAt),
        ]
    }

    // MARK: containment (issuance applies these before any prompt)

    /// The requested method set must sit inside the profile's; intersection is
    /// request ⊆ profile, so the effective set is the requested one.
    func allows(methods requested: Set<String>) -> Bool {
        requested.isSubset(of: methods)
    }

    /// Every requested scope must sit inside an allowed one, judged by the same rules a
    /// grant judges a request path: exact-or-subdirectory, both sides relative to the
    /// provider's path prefix, dot segments never matching. Empty profile paths allow
    /// any requested path. An empty request means "any path", so a profile that names
    /// scopes refuses it rather than letting it pass as a vacuous subset.
    func allows(paths requested: [String], providerPrefix: String) -> Bool {
        if requested.isEmpty { return paths.isEmpty }
        return requested.allSatisfy { GrantPath.matches(rest: $0, prefix: providerPrefix, allowed: paths) }
    }

    /// Minutes may be shortened, never lengthened; equal is allowed.
    func allows(minutes requested: Int) -> Bool {
        requested <= minutes
    }

    /// A requested request-cap may tighten or meet the profile's ceiling. A profile
    /// without one lets a request pick its own (still tightening, since the request cap
    /// is always ≥ 1); an unspecified request is the profile's business, not a refusal.
    func allows(maxRequests requested: Int?) -> Bool {
        guard let ceiling = maxRequests, let requested else { return true }
        return requested <= ceiling
    }

    /// Same rule as the request cap, for the spend cap.
    func allows(maxUsd requested: Double?) -> Bool {
        guard let ceiling = maxUsd, let requested else { return true }
        return requested <= ceiling
    }
}

/// What the client asked to save, before validation. Validated before anything is
/// written and before any surface shows the profile, exactly like `GrantRequest`.
struct ProfileRequest {
    var name: String
    var keys: [String]
    /// Default: every method. An explicit empty set is refused — "no method at all"
    /// is not a bound anyone can use.
    var methods: Set<String> = Grant.allMethods
    /// Default: any path (the empty scope list, same as a grant).
    var paths: [String] = []
    var minutes: Int = Grant.defaultMinutes
    var maxRequests: Int?
    var maxUsd: Double?
    var unattended: Bool = false

    func validated() throws -> ProfileRequest {
        var r = self
        r.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try KeyName.validate(r.name) } catch { throw ProfileError.nameInvalid }
        r.keys = deduped(r.keys)
        if r.keys.isEmpty { throw ProfileError.keysMissing }
        r.methods = Set(methods.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if r.methods.isEmpty { throw ProfileError.methodMissing }
        if let bad = r.methods.first(where: { !Grant.allMethods.contains($0) }) {
            throw ProfileError.methodUnknown(bad)
        }
        r.paths = try paths.map { raw -> String in
            guard let normalized = try? GrantPath.normalize(raw) else { throw ProfileError.pathInvalid(raw) }
            return normalized
        }.filter { !$0.isEmpty }
        guard minutes >= 1, minutes <= Grant.maxMinutes else { throw ProfileError.minutesRange }
        r.minutes = minutes
        if let maxRequests, maxRequests < 1 { throw ProfileError.requestCapInvalid }
        if let maxUsd, !(maxUsd > 0) { throw ProfileError.usdCapInvalid }
        if r.unattended, r.maxRequests == nil, r.maxUsd == nil { throw ProfileError.requiresCap }
        return r
    }

    /// Trimmed, empties dropped, first occurrence kept — the order a person typed them in.
    private func deduped(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Why a profile save, lookup or bounded issuance was refused. The codes are the wire: the CLI
/// prints the message, the dashboard API answers `{"error": <code>, "message": …}`, and each bad
/// shape is refused with its own name so callers learn which bound they hit instead of
/// being silently clamped. All refusals happen before any Touch ID prompt, and profile
/// CRUD never prompts at all — a profile row holds no secret and no capability.
enum ProfileError: LocalizedError, Equatable {
    case nameInvalid
    case nameTaken(String)
    case keysMissing
    case keyUnknown(String)
    case methodMissing
    case methodUnknown(String)
    case pathInvalid(String)
    case minutesRange
    case requestCapInvalid
    case usdCapInvalid
    case requiresCap
    case notFound(String)
    case keyNotAllowed(key: String, profile: String, keys: [String])
    case methodNotAllowed(method: String, profile: String, methods: [String])
    case pathNotAllowed(path: String, profile: String, paths: [String])
    case minutesOver(requested: Int, profile: String, ceiling: Int)
    case requestCapOver(requested: Int, profile: String, ceiling: Int)
    case usdCapOver(requested: Double, profile: String, ceiling: Double)

    var errorDescription: String? { message }

    var code: String {
        switch self {
        case .nameInvalid: return "profile_name_invalid"
        case .nameTaken: return "profile_name_taken"
        case .keysMissing, .keyUnknown: return "profile_key_unknown"
        case .methodMissing, .methodUnknown: return "profile_method_unknown"
        case .pathInvalid: return "profile_path_invalid"
        case .minutesRange: return "profile_minutes_range"
        case .requestCapInvalid: return "profile_request_cap_invalid"
        case .usdCapInvalid: return "profile_usd_cap_invalid"
        case .requiresCap: return "profile_requires_cap"
        case .notFound: return "profile_not_found"
        case .keyNotAllowed: return "profile_key_not_allowed"
        case .methodNotAllowed: return "profile_method_not_allowed"
        case .pathNotAllowed: return "profile_path_not_allowed"
        case .minutesOver: return "profile_minutes_over"
        case .requestCapOver: return "profile_request_cap_over"
        case .usdCapOver: return "profile_usd_cap_over"
        }
    }

    var message: String {
        switch self {
        case .nameInvalid:
            return "invalid profile name (expected [a-z0-9][a-z0-9._-]*, at most 128 characters)"
        case .nameTaken(let name):
            return "profile name \(name) is already saved; keys profile remove \(name) first, or pick another name"
        case .keysMissing:
            return "at least one vault key is required, e.g. --keys router"
        case .keyUnknown(let name):
            return "key \(name) is not in the vault; add it with keys add first"
        case .methodMissing:
            return "at least one method is required"
        case .methodUnknown(let method):
            return "unknown method \(method)"
        case .pathInvalid(let raw):
            return "invalid path \(raw)"
        case .minutesRange:
            return "minutes must be between 1 and \(Grant.maxMinutes)"
        case .requestCapInvalid:
            return "max requests must be at least 1"
        case .usdCapInvalid:
            return "max usd must be positive"
        case .requiresCap:
            return "an unattended profile needs a hard cap: give it --max-requests or --max-usd"
        case .notFound(let name):
            return "no profile named \(name)"
        case .keyNotAllowed(let key, let name, let keys):
            return "key \(key) is not in profile \(name); its keys: \(keys.joined(separator: ", "))"
        case .methodNotAllowed(let method, let name, let methods):
            return "method \(method) is outside profile \(name) (allows \(methods.joined(separator: ",")))"
        case .pathNotAllowed(let path, let name, let paths):
            return "path \(path) is outside profile \(name) (allows \(paths.joined(separator: ", ")))"
        case .minutesOver(let requested, let name, let ceiling):
            return "minutes \(requested) is above profile \(name)'s ceiling of \(ceiling) min"
        case .requestCapOver(let requested, let name, let ceiling):
            return "max requests \(requested) is above profile \(name)'s ceiling of \(ceiling)"
        case .usdCapOver(let requested, let name, let ceiling):
            return "max usd \(requested) is above profile \(name)'s ceiling of \(String(format: "$%.2f", ceiling))"
        }
    }
}

extension Profile {
    /// The effective grant ask under this profile: every bound the caller named must sit inside
    /// it (tighten, never widen — a refusal names the bound it hit, never a silent clamp), and
    /// every bound left unnamed takes the profile's value as its default. Runs before any
    /// presence prompt, so a refused ask consumes no Touch ID. The key check rides on the key
    /// *name*: a grant is bound to one key and its host follows from the key's provider, so a
    /// profile lists names and hosts are deliberately not a profile field.
    func bounded(
        request: GrantRequest,
        specified: GrantSpecified,
        key: String,
        providerPrefix: String
    ) throws -> GrantRequest {
        guard keys.contains(key) else {
            throw ProfileError.keyNotAllowed(key: key, profile: name, keys: keys)
        }
        var r = request
        if specified.methods {
            guard allows(methods: r.methods) else {
                let bad = r.methods.filter { !methods.contains($0) }.sorted().first ?? "?"
                throw ProfileError.methodNotAllowed(method: bad, profile: name, methods: methods.sorted())
            }
        } else {
            r.methods = methods
        }
        if specified.paths {
            guard allows(paths: r.paths, providerPrefix: providerPrefix) else {
                let bad = r.paths.first { !GrantPath.matches(rest: $0, prefix: providerPrefix, allowed: paths) } ?? "any path"
                throw ProfileError.pathNotAllowed(path: bad, profile: name, paths: paths)
            }
        } else {
            r.paths = paths
        }
        if specified.minutes {
            guard allows(minutes: r.minutes) else {
                throw ProfileError.minutesOver(requested: r.minutes, profile: name, ceiling: minutes)
            }
        } else {
            r.minutes = minutes
        }
        if specified.maxRequests {
            guard allows(maxRequests: r.maxRequests) else {
                throw ProfileError.requestCapOver(requested: r.maxRequests ?? 0, profile: name, ceiling: maxRequests ?? 0)
            }
        } else {
            r.maxRequests = maxRequests
        }
        if specified.maxUsd {
            guard allows(maxUsd: r.maxUsd) else {
                throw ProfileError.usdCapOver(requested: r.maxUsd ?? 0, profile: name, ceiling: maxUsd ?? 0)
            }
        } else {
            r.maxUsd = maxUsd
        }
        // Fail closed: an unattended grant is pre-committed to a number the user read at
        // approval, so the cap is re-checked here even though save-time validation demands
        // one — in case the row reached the catalog some other way.
        if unattended, r.maxRequests == nil, r.maxUsd == nil { throw ProfileError.requiresCap }
        return r
    }
}
