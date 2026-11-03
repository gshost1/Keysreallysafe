import Foundation

/// Sharing keys with another machine (docs/relay.md, "Sharing keys with another machine"):
/// one relay pairing plus one client token that serves every shared key, minted under one
/// Touch ID, so a Linux box gets a base URL and a token and never a key. A share is nothing
/// the gateway trusts on its own: the token is an ordinary multi-key client token, checked,
/// scoped and metered on the Mac like any other, and the pairing is an ordinary pairing.
///
/// The pairing row is the share's anchor. The token is bound to it through the client's
/// soft `project` reference, `share:<pairing id>`: the authorize path already serves several
/// keys from one token only when it carries a project, and the id has no projects row, so no
/// folder flow (unwrap, revoke_project, the import) can ever reach it.
enum Share {
    /// The label prefix on the share's pairing and token, so `keys relay pair list` and the
    /// dashboard's token lists show where they came from.
    static let labelPrefix = "share: "
    static let projectPrefix = "share:"
    /// An SDK lists models before it calls one, so a share allows GET beside POST.
    static let defaultMethods = ["GET", "POST"]

    static func project(pairingID: Int64) -> String { projectPrefix + String(pairingID) }

    /// The share label from a pairing label, nil when the pairing is not a share's.
    static func label(fromPairing label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let rest = String(label.dropFirst(labelPrefix.count))
        return rest.isEmpty ? nil : rest
    }

    static func validateLabel(_ raw: String) throws -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AppError.usage("a share needs a label, e.g. the machine's name") }
        // The stored pairing label is capped at 80 with the prefix included.
        guard label.count <= 80 - labelPrefix.count else { throw AppError.usage("a share label is at most \(80 - labelPrefix.count) characters") }
        // The label reaches the Touch ID prompt and the printed revoke command, so it holds no
        // control, format (bidi overrides) or line/paragraph separator characters, and none a
        // shell would expand inside the quoted command.
        let refused = label.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return "\"$`\\".unicodeScalars.contains(scalar)
            }
        }
        guard !refused else {
            throw AppError.usage("a share label cannot contain control characters or any of \" $ ` \\")
        }
        return label
    }
}

/// One share as `keys share list` and the API show it: hints and metadata, never a credential.
struct ShareRecord: Equatable {
    var label: String
    var pairing: RelayPairingRecord
    /// The share's token; nil when it was revoked on its own and its row aged out of the join.
    var client: GatewayClient?
    var keys: [String]

    /// Live when both halves are: revoking either one ends the share.
    func isActive(now: Date) -> Bool {
        pairing.isActive(now: now) && (client?.isActive(now: now) ?? false)
    }

    var lastUsedAt: String? {
        [pairing.lastUsedAt, client?.lastUsedAt].compactMap { $0 }.max()
    }

    func jsonObject(now: Date) -> [String: Any] {
        [
            "label": label,
            "keys": keys,
            "created_at": pairing.createdAt,
            "expires_at": client?.expiresAt ?? pairing.expiresAt ?? NSNull(),
            "active": isActive(now: now),
            "revoked": pairing.revokedAt != nil || client?.revokedAt != nil,
            "last_used_at": lastUsedAt ?? NSNull(),
            "token_hint": client?.hint ?? NSNull(),
            "pairing_hint": pairing.hint,
        ]
    }
}

/// The lines the other machine pastes into its shell or an env file. Pure, so a test pins
/// them without a catalog.
enum ShareEnv {
    struct Member: Equatable {
        var name: String
        /// The provider's wire, `anthropic` or `openai` for the SDK variables; anything else
        /// gets only the generic Keysrs pair.
        var api: String
    }

    static let tokenVar = "KEYSRS_TOKEN"
    static let pairVar = "KEYSRS_PAIR"

    /// `KEYSRS_<KEY>_BASE_URL`: the key name upper-cased, every other character an underscore.
    static func baseVar(_ key: String) -> String {
        let body = String(key.uppercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
        return "KEYSRS_\(body)_BASE_URL"
    }

    /// Every key gets its own base URL variable. The first Anthropic-wire key also fills the
    /// variables the Anthropic SDKs and Claude Code read, and the first OpenAI-wire key the
    /// OpenAI SDK's; a second key on the same wire keeps only its Keysrs variable, because two
    /// values for OPENAI_BASE_URL would silently leave one of them unused.
    static func lines(origin: URL, members: [Member], token: String, pairing: String) -> [String] {
        var out = [
            "export \(tokenVar)=\(token)",
            "export \(pairVar)=\(pairing)",
        ]
        for member in members {
            out.append("export \(baseVar(member.name))=\(RelayURL.baseURL(origin, key: member.name))")
        }
        if let first = members.first(where: { $0.api == "anthropic" }) {
            out.append("export ANTHROPIC_BASE_URL=\(RelayURL.baseURL(origin, key: first.name))")
            out.append("export ANTHROPIC_AUTH_TOKEN=\"$\(tokenVar)\"")
            // Claude Code sends these on every request; the relay strips the pairing header
            // before the gateway or the provider can see it.
            out.append("export ANTHROPIC_CUSTOM_HEADERS=\"X-KSF-Pair: $\(pairVar)\"")
        }
        if let first = members.first(where: { $0.api == "openai" }) {
            out.append("export OPENAI_BASE_URL=\(RelayURL.baseURL(origin, key: first.name))")
            out.append("export OPENAI_API_KEY=\"$\(tokenVar)\"")
        }
        return out
    }

    /// Whether some member's SDK cannot be told to send the pairing header from the
    /// environment: only Claude Code reads extra headers from a variable.
    static func needsHeaderInCode(_ members: [Member]) -> Bool {
        members.contains { $0.api != "anthropic" }
    }
}

extension KeysService {
    /// Shares one or more keys with another machine through the relay: one pairing and one
    /// client token serving every key, both under ONE presence prompt naming the label and the
    /// keys, with the gateway turned on for each key in the same prompt when this process owns
    /// it. Everything that can be refused is refused before the prompt. The token and the
    /// credential are returned once; only their hashes are stored.
    func issueShare(
        label rawLabel: String,
        keys: [String],
        days: Int? = nil,
        methods: [String]? = nil,
        caller: String = "dashboard",
        now: Date = Date()
    ) throws -> (token: String, credential: String, share: ShareRecord) {
        let label = try Share.validateLabel(rawLabel)
        let pairingLabel = Share.labelPrefix + label
        let ttlDays = try GatewayClientToken.validateDays(days)
        _ = try RelayPairing.validateDays(ttlDays)
        let allowed = try GatewayClientToken.validateMethods(methods ?? Share.defaultMethods)
        for key in keys { try KeyName.validate(key) }
        let members = try projectMembers(keys)
        for member in members {
            let row = try existingRow(member.name)
            guard let provider = Providers.provider(id: row.provider), provider.gateway else {
                throw AppError.usage("\(member.name) cannot be shared: the gateway is not available for provider \(row.provider)")
            }
        }
        guard relayStatus().configured else {
            throw AppError.usage(
                "no relay is set up, so another machine has nothing to call; deploy the Worker (docs/relay.md), then run: keys relay setup --url https://<your worker>.workers.dev"
            )
        }
        if try catalog.relayPairings().contains(where: { $0.label == pairingLabel && $0.revokedAt == nil }) {
            throw AppError.alreadyExists("a live share named \(label) already exists; revoke it first: keys share revoke \"\(label)\"")
        }
        let owner = (try? requireGatewayOwner()) != nil
        let names = members.map(\.name).joined(separator: ", ")
        try presence.require(reason: "share \(names) with \(label) for \(ttlDays) days")
        if owner {
            for member in members {
                _ = try setGateway(name: member.name, enabled: true, host: nil, caller: caller, presenceChecked: true)
            }
        }
        let credential = RelayPairing.generate()
        // One transaction: a mint that fails must not leave a live pairing without its token,
        // which no share list would show and whose label would block the next share. The
        // label is checked again inside it, because a second share of the same name may have
        // been approved while this prompt was up.
        let (pairing, issued) = try catalog.withTransaction {
            if try catalog.relayPairings().contains(where: { $0.label == pairingLabel && $0.revokedAt == nil }) {
                throw AppError.alreadyExists("a live share named \(label) already exists; revoke it first: keys share revoke \"\(label)\"")
            }
            let pairing = try catalog.insertRelayPairing(
                label: pairingLabel,
                tokenHash: RelayPairing.hash(credential),
                hint: RelayPairing.hint(credential),
                keys: members.map(\.name),
                createdAt: UTC.iso(now),
                expiresAt: UTC.iso(now.addingTimeInterval(TimeInterval(ttlDays) * 86_400))
            )
            let issued = try mintProjectGatewayClient(
                members: members, label: pairingLabel, days: ttlDays, methods: allowed, pathPrefix: nil,
                project: Share.project(pairingID: pairing.id), caller: caller, now: now
            )
            return (pairing, issued)
        }
        let share = ShareRecord(label: label, pairing: pairing, client: issued.client, keys: members.map(\.name))
        return (issued.token, credential, share)
    }

    /// Every share, live and ended, newest first. Hints and metadata only.
    func shares() throws -> [ShareRecord] {
        try Self.shares(catalog: catalog)
    }

    static func shares(catalog: CatalogDB) throws -> [ShareRecord] {
        let clients = try catalog.allGatewayClients().filter { $0.project?.hasPrefix(Share.projectPrefix) == true }
        var byProject: [String: GatewayClient] = [:]
        for client in clients { byProject[client.project!] = client }
        return try catalog.relayPairings().compactMap { pairing -> ShareRecord? in
            guard let label = Share.label(fromPairing: pairing.label),
                  let client = byProject[Share.project(pairingID: pairing.id)] else { return nil }
            return ShareRecord(label: label, pairing: pairing, client: client, keys: pairing.keys)
        }.sorted { $0.pairing.id > $1.pairing.id }
    }

    /// Whether any share is live: what "Keep Mac Awake While Sharing" holds the Mac awake for.
    /// It reads the catalog only and never throws, because the relay's awake check polls it.
    static func hasLiveShare(catalog: CatalogDB, now: Date = Date()) -> Bool {
        ((try? shares(catalog: catalog)) ?? []).contains { $0.isActive(now: now) }
    }

    /// Ends a share by its label: the pairing and the token together, so neither half lingers.
    /// No prompt, like every revoke: ending access never needs the person present.
    @discardableResult
    func revokeShare(_ rawLabel: String, caller: String = "dashboard", now: Date = Date()) throws -> ShareRecord {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AppError.usage("revoke needs a share's label") }
        let all = try shares()
        guard let share = all.first(where: { $0.label == label && $0.pairing.revokedAt == nil })
            ?? all.first(where: { $0.label == label && $0.client?.revokedAt == nil }) else {
            if all.contains(where: { $0.label == label }) {
                throw AppError.usage("the share \(label) is already revoked")
            }
            throw AppError.notFound("share \(label)")
        }
        let iso = UTC.iso(now)
        if share.pairing.revokedAt == nil {
            _ = try catalog.revokeRelayPairing(id: share.pairing.id, at: iso)
        }
        if let client = share.client, client.revokedAt == nil,
           try catalog.revokeGatewayClient(id: client.id, keyName: client.keyName, at: iso) {
            try recordKeyEvent(name: client.keyName, action: "client_revoke", caller: caller, detail: "#\(client.id) share")
        }
        return try shares().first { $0.pairing.id == share.pairing.id } ?? share
    }

    /// The SDK wire of each shared key, for the env lines.
    func shareMembers(_ share: ShareRecord) -> [ShareEnv.Member] {
        share.keys.map { name in
            let api = (try? existingRow(name)).flatMap { Providers.provider(id: $0.provider)?.api } ?? ""
            return ShareEnv.Member(name: name, api: api)
        }
    }
}
