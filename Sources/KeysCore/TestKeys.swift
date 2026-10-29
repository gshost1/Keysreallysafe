import Foundation

/// The app side of the test_keys tool (architecture §2.7): a confirm-gated,
/// read-only provider check for named vault keys, run entirely in the process
/// that holds the secrets. The confirm gate is absolute — an unconfirmed call
/// sends nothing to any provider and prompts no one — and a confirmed call never
/// rides a remembered yes: it pays exactly ONE presence prompt, every call,
/// covering the secret reads of the keys it will probe. The per-key answer is the
/// existing keys-test shape (already secret-free, its error text scrubbed against
/// the secret) plus the confirmed flag, so no value and no token shape ever
/// crosses the wire in either direction.
extension KeysService {

    /// One test_keys call: resolve every key, then either answer without doing
    /// anything (not confirmed) or prompt once for the call and probe each
    /// probeable key (confirmed). Returns the payload the route relays verbatim:
    /// `{"results": [one row per key, in request order, one row per distinct name]}`.
    func testKeys(keys: [String], confirm: Bool, caller: String = "mcp", now: Date = Date()) throws -> [String: Any] {
        guard !keys.isEmpty else { throw AppError.usage("keys must be a non-empty list of key names") }

        // Resolve every key BEFORE anything else. An unknown name is the caller's
        // typo and refuses the whole call, and a probeable key with no host refuses
        // the same way `keys test` does — so no shape of this call ever spends a
        // Touch ID it cannot use. A name given twice is one key: one row, one probe.
        var targets: [(name: String, target: CheckTarget)] = []
        for name in keys {
            guard !targets.contains(where: { $0.name == name }) else { continue }
            let target = try checkTarget(name: name)
            if target.probe != nil, target.host == nil {
                throw AppError.usage("set a gateway host for \(name) first (this provider has one host per account)")
            }
            targets.append((name, target))
        }

        // Not confirmed: nothing is sent and no one is prompted. The per-key row
        // says exactly that, so the caller knows the one thing it owes the user
        // before this call can do anything.
        guard confirm else {
            return ["results": targets.map { Self.notConfirmedRow(name: $0.name, provider: $0.target.provider) }]
        }

        // The ONE prompt for the whole call, covering the secret reads of every key
        // it will probe. It is paid again on every confirmed call: the gateway's
        // unlocked in-memory secret is deliberately not consulted, because a test's
        // approval is never remembered as standing in for the user's yes.
        let probing = targets.filter { $0.target.probe != nil }
        if !probing.isEmpty {
            try presence.require(
                reason: "test \(probing.count) key\(probing.count == 1 ? "" : "s") read-only: "
                    + probing.map(\.name).joined(separator: ", ")
            )
        }

        var rows: [[String: Any]] = []
        for (name, target) in targets {
            var row: [String: Any]
            if target.probe != nil, let host = target.host {
                // The resolution pass proved a probeable target has a host.
                let secret = try secrets.get(name: name)
                let result = ProviderCheck.run(
                    key: name, provider: target.provider, host: host,
                    secret: secret, fetcher: checker, now: now
                )
                try recordCheck(result, caller: caller)
                row = result.jsonObject()
            } else {
                // No read-only endpoint for this provider: nothing is sent, and
                // the recorded result says so — the same `keys test` answer.
                let result = ProviderCheck.noEndpoint(
                    key: name, provider: target.provider, host: target.host ?? "", now: now
                )
                try catalog.upsertProviderCheck(result)
                row = result.jsonObject()
            }
            row["confirmed"] = true
            rows.append(row)
        }
        return ["results": rows]
    }

    /// The per-key row for an unconfirmed call. It carries the fields an honest
    /// answer exists for — the check fields only a real probe could fill are
    /// absent, because nothing ran — and its summary states both facts the gate
    /// owes the caller: nothing was sent, and the user must be asked first.
    private static func notConfirmedRow(name: String, provider: Providers.Record) -> [String: Any] {
        [
            "key": name,
            "provider": provider.id,
            "confirmed": false,
            "ok": false,
            "outcome": "not_confirmed",
            "summary": "not confirmed: nothing was sent; ask the user in this same call before passing confirm true",
        ]
    }
}
