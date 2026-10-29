import Foundation

/// The app side of `import_and_wrap` (architecture §2.6). The MCP request carries names
/// and flags only; THIS process re-scans the folder and reads the values itself, so no
/// key value ever crosses the wire in either direction. The whole import — comparing the
/// values with the vault, storing new keys, turning the gateway on, issuing ONE project
/// client token, and rewriting the files — happens under exactly ONE presence prompt
/// naming the keys and the project label.
///
/// Every rule here is the `wrapPlan`/`wrapApply` rule seen from a folder: dedupe by
/// value through `ConstantTime.equal`, `WrapNames`-suggested names for new keys, the
/// gateway on with `presenceChecked` (the one prompt stands in for the per-key prompt,
/// exactly as `wrapApply` does), and the same refusals with the same wording. What the
/// folder adds on top: AWS SigV4 pairs and credential URLs import under the reserved
/// provider id "imported" and stay in place (the gateway structurally refuses unknown
/// providers, and `keys env` serves them), and every rewritten line shares the one
/// project token, so the gateway answers each key's own path with the same capability.
extension KeysService {

    /// The host the import writes into BASE_URL companion lines, and reports as
    /// `base_url_host`. Containers cannot use 127.0.0.1 (it is the container's own
    /// loopback), so the docker flag switches the whole import to
    /// `host.docker.internal` — the spelling Docker Desktop for Mac routes to the host.
    static func baseURLHost(docker: Bool) -> String {
        docker ? "host.docker.internal" : "127.0.0.1"
    }

    /// One import: resolve the project, scan, filter, prompt once, then compare, store,
    /// enable, mint and rewrite. Returns the result payload the route relays verbatim —
    /// relative paths, names and dates only; never a value, a token or an absolute path.
    func importAndWrap(
        folder: String?,
        variables: [String]?,
        docker: Bool,
        caller: String = "mcp",
        now: Date = Date()
    ) throws -> [String: Any] {
        try requireGatewayOwner()
        let project = try resolveProject(folder: folder, now: now)
        let report = try EnvScan.scan(folder: folder)

        // The requested names restrict the import. Each is validated as an env variable
        // name first — a caller's typo is a plain refusal, not a silent not_found.
        var wanted: Set<String>?
        if let variables {
            for name in variables { try EnvVar.validate(name) }
            wanted = Set(variables)
        }

        // Already-wrapped lines are outcomes, not imports: nothing happens to them, and
        // they are never named in the prompt — only the values this import will touch.
        var alreadyWrapped: [EnvScan.Candidate] = []
        var imports: [EnvScan.Candidate] = []
        for candidate in report.candidates {
            if let wanted, !wanted.contains(candidate.name) { continue }
            if candidate.category == .wrapped {
                alreadyWrapped.append(candidate)
            } else {
                imports.append(candidate)
            }
        }

        // Nothing left to import: no prompt, no token, no rewrite. The result still
        // answers honestly, per variable, including every not-found requested name.
        guard !imports.isEmpty else {
            let outcomes = Self.mergedOutcomes(
                report: report, wanted: wanted, decisions: [], alreadyWrapped: alreadyWrapped,
                notFound: Self.notFoundOutcomes(requested: variables, candidates: report.candidates, wanted: wanted)
            )
            return Self.payload(
                project: project, outcomes: outcomes, expiresAt: nil, docker: docker, preferences: preferences
            )
        }
        guard imports.count <= WrapPlan.maxCandidates else {
            throw AppError.usage("too many variables to import at once (at most \(WrapPlan.maxCandidates))")
        }

        // The ONE prompt. It names the keys being imported/wrapped and the project label,
        // and it covers everything the call does afterwards: reading vault values for the
        // dedupe, storing new keys, turning the gateway on and issuing the project token.
        // Identities are known before the vault is read (the read happens under this
        // prompt), so a new key names its provider and everything else names its variable.
        // docker:true also opens the global Docker gateway access (set only after a
        // successful rewrite), so the one reason must say that too — the flag never
        // flips a global preference unannounced (VAL-O-003).
        var identities: [String] = []
        for candidate in imports {
            let identity = candidate.provider ?? WrapNames.slug(candidate.name)
            if !identities.contains(identity) { identities.append(identity) }
        }
        try presence.require(
            reason: "import and wrap \(imports.count) key\(imports.count == 1 ? "" : "s") "
                + "for project \(project.label): \(identities.joined(separator: ", "))"
                + (docker ? " and allow Docker containers to reach the gateway" : "")
        )

        // The batch vault read wrapPlan performs under its own one prompt, with the same
        // tolerance for a row whose secret cannot be read: it matches nothing.
        let rows = try catalog.listCatalog()
        var vault: [(name: String, secret: Data)] = []
        for row in rows {
            if let secret = try? secrets.get(name: row.name) { vault.append((row.name, Data(secret.utf8))) }
        }

        // Decide every candidate, in scan order, against the wrap rules.
        let decisions = Self.decide(imports, rows: rows, vault: vault, report: report)

        // Re-read every file a wrapped line will land in, and prove the values the scan
        // saw are still on their lines, BEFORE anything changes: a file edited while the
        // prompt was up refuses the whole import with the vault untouched, exactly like
        // wrap's refuse-if-changed, and the fresh bytes become the rewrite's originals.
        let fresh = try Self.verifyWrappedFiles(decisions: decisions, report: report)

        // Store the new keys under the one prompt. A name already holding a different
        // value (a Keychain item without a catalog row, or a concurrent add) skips its
        // variables and reports itself; the existing key is never overwritten.
        var conflicted: Set<String> = []
        for key in Self.newKeysFor(decisions) {
            do {
                try add(
                    name: key.name, provider: key.provider, kind: "runtime",
                    notes: "imported by import_and_wrap for \(project.label)",
                    secret: key.value, caller: caller
                )
            } catch AppError.alreadyExists {
                conflicted.insert(key.name)
            }
        }

        // Gateway on for every wrapped key. Conflicted names never reach this (no row,
        // so there is nothing to enable); duplicates of one key enable it once. The
        // decisions were computed from rows read after the prompt, and everything since
        // ran inside this one call, so there is no plan to go stale — no wrapApply-style
        // host recheck here.
        var wrappedKeys: [String] = []
        for decision in decisions {
            guard case let .wrap(_, key, _, _) = decision, !conflicted.contains(key) else { continue }
            if !wrappedKeys.contains(key) { wrappedKeys.append(key) }
            _ = try setGateway(name: key, enabled: true, host: nil, caller: caller, presenceChecked: true)
        }

        // The onboarding counters' producers. This flow imported at least one key, so
        // the `key_import` step is recorded now; the flow's completion records
        // `onboarding_finished` after the rewrite below. Both are opt-in — `record`
        // is a no-op while analytics sharing is off — so an import never records
        // anything a non-sharing user did not ask for.
        let importedKeys = Set(decisions.compactMap(\.importedKey))
        if !importedKeys.isEmpty { analytics?.record(.keyImport) }

        // The ONE project token, under the same prompt: one gateway_clients row plus one
        // membership row per wrapped key. Nothing to wrap means no token and a null
        // expiry — never a zero-member mint.
        var expiresAt: String?
        var token: String?
        if !wrappedKeys.isEmpty {
            let minted = try mintProjectGatewayClient(
                members: try projectMembers(wrappedKeys),
                label: "import_and_wrap \(project.label)",
                days: GatewayClientToken.defaultDays,
                methods: ["POST", "GET"],
                pathPrefix: nil,
                project: project.id,
                caller: caller,
                now: now
            )
            token = minted.token
            expiresAt = minted.client.expiresAt
        }

        // Rewrite each file: the value span of every wrapped line becomes the one token,
        // and the SDK's BASE_URL companion is set to the gateway URL for its key. The
        // fresh bytes from the verify pass are the originals, so EnvFileWriter's
        // refuse-if-changed still guards the window between that read and this write.
        if let token {
            try Self.rewriteWrappedFiles(
                decisions: decisions, fresh: fresh, token: token, docker: docker, now: now,
                conflicted: conflicted
            ) { path, companions in
                try recordWrappedFile(path: path, project: project.id, now: now, companions: companions)
            }
        }

        // The docker flag only acts when true: it turns the global setting on (the
        // approved tradeoff — the token is still the gate) and this import writes
        // host.docker.internal base URLs. Absent or false never touches the pref.
        if docker { try preferences.setDockerAccess(true) }

        // The onboarding's final step reached the end of the flow: the keys were
        // imported and the files rewritten, so the flow is finished.
        if !importedKeys.isEmpty { analytics?.record(.onboardingFinished) }

        let outcomes = Self.mergedOutcomes(
            report: report, wanted: wanted, decisions: decisions, alreadyWrapped: alreadyWrapped,
            notFound: Self.notFoundOutcomes(requested: variables, candidates: report.candidates, wanted: wanted),
            conflicted: conflicted
        )
        return Self.payload(
            project: project, outcomes: outcomes, expiresAt: expiresAt, docker: docker, preferences: preferences
        )
    }

    // MARK: - Deciding the candidates

    /// What one candidate becomes: wrapped under a key, imported-but-left-in-place under
    /// a key, or skipped with a reason. The new key's stored value stays on the
    /// candidate; `newEntry` derives the add list so each new key is added once.
    private enum Decision {
        case wrap(candidate: EnvScan.Candidate, key: String, provider: String, isNew: Bool)
        case leave(candidate: EnvScan.Candidate, key: String, provider: String, reason: String, isNew: Bool)
        case skip(candidate: EnvScan.Candidate, key: String?, provider: String?, reason: String)

        /// The key this decision touches, when it touches one.
        var keyName: String? {
            switch self {
            case let .wrap(_, key, _, _), let .leave(_, key, _, _, _): return key
            case let .skip(_, key, _, _): return key
            }
        }

        var file: String? {
            switch self {
            case let .wrap(candidate, _, _, _), let .leave(candidate, _, _, _, _), let .skip(candidate, _, _, _):
                return candidate.file
            }
        }

        /// The (name, value, provider) a NEW key of this decision will store; nil for
        /// reuses and skips, so the add loop sees each new key exactly once.
        var newEntry: (name: String, value: String, provider: String)? {
            switch self {
            case let .wrap(candidate, key, provider, true):
                return (key, candidate.value, provider)
            case let .leave(candidate, key, provider, _, true):
                return (key, candidate.value, provider)
            default:
                return nil
            }
        }

        /// The vault key this decision imported (a wrap or an import-left-in-place);
        /// nil for a skip, which imports nothing. The onboarding `key_import`
        /// counter's producer reads this.
        var importedKey: String? {
            switch self {
            case let .wrap(_, key, _, _), let .leave(_, key, _, _, _): return key
            case .skip: return nil
            }
        }

        /// The same decision for a second variable holding the same value: the same key,
        /// provider, newness and reason — the dedupe's visible half.
        func duplicated(for candidate: EnvScan.Candidate) -> Decision {
            switch self {
            case let .wrap(_, key, provider, isNew):
                return .wrap(candidate: candidate, key: key, provider: provider, isNew: isNew)
            case let .leave(_, key, provider, reason, isNew):
                return .leave(candidate: candidate, key: key, provider: provider, reason: reason, isNew: isNew)
            case let .skip(_, key, provider, reason):
                return .skip(candidate: candidate, key: key, provider: provider, reason: reason)
            }
        }
    }

    /// The wrapPlan rule over the scan's candidates, plus the import's own categories.
    private static func decide(
        _ imports: [EnvScan.Candidate],
        rows: [CatalogRow],
        vault: [(name: String, secret: Data)],
        report: EnvScan.Report
    ) -> [Decision] {
        // The folder slug names disambiguated keys, the way WrapRunner hints from the
        // file's folder: the project root here, since one import is one project.
        let hint = WrapNames.slug(URL(fileURLWithPath: report.root).lastPathComponent)
        var taken = Set(rows.map(\.name))
        var newByValue: [String: String] = [:]
        var decisions: [Decision] = []

        for candidate in imports {
            let value = Data(candidate.value.utf8)

            // An exact vault match wraps with the existing key — never a duplicate.
            var match: String?
            for entry in vault where ConstantTime.equal(entry.secret, value) { match = match ?? entry.name }
            if let match, let row = rows.first(where: { $0.name == match }) {
                let record = Providers.provider(id: row.provider)
                if record == nil || record?.gateway == false {
                    decisions.append(.leave(
                        candidate: candidate, key: match, provider: row.provider,
                        reason: "the gateway does not proxy \(record?.name ?? row.provider); "
                            + "the line stays as it is (keys env \(match) prints it)",
                        isNew: false
                    ))
                } else if Self.effectiveHost(row) == nil {
                    decisions.append(.skip(
                        candidate: candidate, key: match, provider: row.provider,
                        reason: "set a gateway host for \(match) first"
                    ))
                } else {
                    decisions.append(.wrap(candidate: candidate, key: match, provider: row.provider, isNew: false))
                }
                continue
            }

            // The same new value twice shares the first decision's key, so no value is
            // ever stored twice — the wrapPlan `newByValue` precedent.
            if let name = newByValue[candidate.value],
               let earlier = decisions.first(where: { $0.keyName == name }) {
                decisions.append(earlier.duplicated(for: candidate))
                continue
            }

            // AWS SigV4 pairs and credential URLs: real secrets the gateway structurally
            // cannot proxy. They import under the reserved provider id "imported" (the
            // vault requires a provider string; the enable path refuses the unknown id,
            // which is what keeps them unwrapped) and their lines stay as they are.
            if candidate.category == .awsPair || candidate.category == .credentialURL {
                let name = WrapNames.suggest(provider: "imported", hint: hint, taken: taken)
                let what = candidate.category == .awsPair
                    ? "an AWS SigV4 pair, which the gateway cannot proxy"
                    : "a credential URL, which the gateway cannot proxy"
                decisions.append(.leave(
                    candidate: candidate, key: name, provider: "imported",
                    reason: "\(what); the line stays as it is (keys env \(name) prints it)",
                    isNew: true
                ))
                taken.insert(name)
                newByValue[candidate.value] = name
                continue
            }

            // A key-shaped value with no recognized provider and no vault match is not
            // imported — the same refusal wrapPlan gives, verbatim.
            guard let pid = candidate.provider, let record = Providers.provider(id: pid) else {
                decisions.append(.skip(
                    candidate: candidate, key: nil, provider: nil,
                    reason: "not in the vault and no provider recognised; add it with keys add, then rerun"
                ))
                continue
            }

            // A provider the gateway does not serve: imported under its own provider id,
            // left in place, served by `keys env`.
            if !record.gateway {
                let name = WrapNames.suggest(provider: pid, hint: hint, taken: taken)
                decisions.append(.leave(
                    candidate: candidate, key: name, provider: pid,
                    reason: "the gateway does not proxy \(record.name); "
                        + "the line stays as it is (keys env \(name) prints it)",
                    isNew: true
                ))
                taken.insert(name)
                newByValue[candidate.value] = name
                continue
            }

            // A gateway provider with no effective host cannot be wrapped; wrapPlan
            // refuses to add such a key and so does the import.
            guard record.host != nil else {
                decisions.append(.skip(
                    candidate: candidate, key: nil, provider: pid,
                    reason: "the gateway cannot proxy \(record.name) without a per-key host; add it with keys add"
                ))
                continue
            }

            let name = WrapNames.suggest(provider: pid, hint: hint, taken: taken)
            decisions.append(.wrap(candidate: candidate, key: name, provider: pid, isNew: true))
            taken.insert(name)
            newByValue[candidate.value] = name
        }
        return decisions
    }

    /// The new keys the add loop stores, in decision order, once each.
    private static func newKeysFor(_ decisions: [Decision]) -> [(name: String, value: String, provider: String)] {
        var seen: Set<String> = []
        var out: [(name: String, value: String, provider: String)] = []
        for decision in decisions {
            guard let entry = decision.newEntry, seen.insert(entry.name).inserted else { continue }
            out.append(entry)
        }
        return out
    }

    // MARK: - The file rewrite

    /// One file read fresh at apply time. The parsed copy is what gets rewritten; the
    /// bytes are the originals `EnvFileWriter.rewrite` refuses to overwrite.
    private final class FreshRead {
        let url: URL
        let data: Data
        var parsed: EnvFile
        var claimed: Set<Int> = []

        init?(url: URL) {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            self.url = url
            self.data = data
            self.parsed = EnvFile.parse(text)
        }
    }

    /// Reads every file a wrapped line will land in and proves each wrapped variable's
    /// value is still on its line (name and value both, claimed in order so a duplicated
    /// line answers its own candidate). Called BEFORE any mutation, so a file edited
    /// while the prompt was up refuses the whole import with nothing changed.
    private static func verifyWrappedFiles(
        decisions: [Decision], report: EnvScan.Report
    ) throws -> [String: FreshRead] {
        var fresh: [String: FreshRead] = [:]
        for decision in decisions {
            guard case .wrap = decision, let file = decision.file,
                  fresh[file] == nil else { continue }
            guard let read = FreshRead(url: report.absolute(file)) else {
                throw AppError.usage("a file in the project could not be read; nothing was imported")
            }
            fresh[file] = read
        }
        for decision in decisions {
            guard case let .wrap(candidate, _, _, _) = decision, let file = decision.file,
                  let read = fresh[file] else { continue }
            guard entryIndex(name: candidate.name, value: candidate.value, in: read.parsed, claimed: &read.claimed) != nil else {
                throw AppError.usage("a file in the project changed while the import ran; nothing was imported")
            }
        }
        return fresh
    }

    /// Rewrites each file holding a wrapped line: the value span becomes the one project
    /// token, the BASE_URL companions for the three wrap-detected SDK variables are set
    /// to the gateway URL for their key, and the rewritten file is recorded in
    /// `wrapped_files` through `record` — together with the companion names it wrote,
    /// so unwrap later removes exactly those. Files whose every wrap was conflicted
    /// away are left untouched — nothing in them was ever rewritten.
    private static func rewriteWrappedFiles(
        decisions: [Decision],
        fresh: [String: FreshRead],
        token: String,
        docker: Bool,
        now: Date,
        conflicted: Set<String>,
        record: (String, [String]) throws -> Void
    ) throws {
        let host = baseURLHost(docker: docker)
        for file in fresh.keys.sorted() {
            guard let read = fresh[file] else { continue }
            guard decisions.contains(where: {
                guard case let .wrap(_, key, _, _) = $0 else { return false }
                return $0.file == file && !conflicted.contains(key)
            }) else { continue }
            read.claimed = []
            var companions: [String: String] = [:]
            for decision in decisions {
                guard case let .wrap(candidate, key, _, _) = decision, decision.file == file else { continue }
                guard let index = entryIndex(name: candidate.name, value: candidate.value, in: read.parsed, claimed: &read.claimed) else {
                    throw AppError.usage("a file in the project changed while the import ran; nothing further was rewritten")
                }
                read.parsed.setValue(at: index, token)
                if let baseVar = WrapDetect.baseURLVariables[candidate.name] {
                    companions[baseVar] = "http://\(host):\(GatewayListener.port)/\(key)"
                }
            }
            for (name, value) in companions.sorted(by: { $0.key < $1.key }) {
                read.parsed.upsert(name: name, value: value)
            }
            _ = try EnvFileWriter.rewrite(read.url, original: read.data, text: read.parsed.render(), now: now)
            try record(read.url.path, companions.keys.sorted())
        }
    }

    /// The line index of one candidate's assignment, claimed in order: the name AND the
    /// value identify the exact line, so a variable assigned twice in one file answers
    /// its own candidate and anything else matches nothing.
    private static func entryIndex(name: String, value: String, in file: EnvFile, claimed: inout Set<Int>) -> Int? {
        for (index, entry) in file.entries where !entry.multiline && entry.name == name
        && entry.value == value && !claimed.contains(index) {
            claimed.insert(index)
            return index
        }
        return nil
    }

    // MARK: - Outcomes and the payload

    /// One per-variable row of the result. Every row has exactly the six keys
    /// {variable, file, key, provider, status} plus `new` for wrapped rows and `reason`
    /// for every other status — the exact shape the contract pins.
    private struct Outcome {
        var variable: String
        var file: String?
        var key: String?
        var provider: String?
        var status: String
        var reason: String?
        var isNew: Bool?

        func jsonObject() -> [String: Any] {
            var o: [String: Any] = [
                "variable": variable,
                "file": file ?? NSNull(),
                "key": key ?? NSNull(),
                "provider": provider ?? NSNull(),
                "status": status,
            ]
            if let reason { o["reason"] = reason }
            if let isNew { o["new"] = isNew }
            return o
        }
    }

    /// The requested names the scan never saw, in request order.
    private static func notFoundOutcomes(
        requested: [String]?, candidates: [EnvScan.Candidate], wanted: Set<String>?
    ) -> [Outcome] {
        guard let requested, let wanted else { return [] }
        let present = Set(candidates.filter { wanted.contains($0.name) }.map(\.name))
        return requested.filter { !present.contains($0) }.map {
            Outcome(variable: $0, file: nil, key: nil, provider: nil, status: "not_found",
                    reason: "not found in the project's env files")
        }
    }

    /// Outcomes in scan order (files by path, then line order), with the not-found
    /// requested names after them — the same order the scan reports its variables in.
    private static func mergedOutcomes(
        report: EnvScan.Report,
        wanted: Set<String>?,
        decisions: [Decision],
        alreadyWrapped: [EnvScan.Candidate],
        notFound: [Outcome],
        conflicted: Set<String> = []
    ) -> [Outcome] {
        var wrappedOutcomes: [Outcome] = []
        for candidate in alreadyWrapped {
            wrappedOutcomes.append(Outcome(
                variable: candidate.name, file: candidate.file, key: nil, provider: nil,
                status: "skipped", reason: "already wrapped"
            ))
        }
        var decisionOutcomes: [Outcome] = []
        for decision in decisions {
            decisionOutcomes.append(outcome(decision, conflicted: conflicted))
        }
        var merged: [Outcome] = []
        var wrapped = 0
        var decided = 0
        for candidate in report.candidates {
            if let wanted, !wanted.contains(candidate.name) { continue }
            if candidate.category == .wrapped {
                if wrapped < wrappedOutcomes.count { merged.append(wrappedOutcomes[wrapped]); wrapped += 1 }
                continue
            }
            if decided < decisionOutcomes.count { merged.append(decisionOutcomes[decided]); decided += 1 }
        }
        merged.append(contentsOf: notFound)
        return merged
    }

    /// One decision as its result row. A conflicted name turns either import kind into
    /// a skip: nothing was stored for that variable and the existing key kept its value.
    private static func outcome(_ decision: Decision, conflicted: Set<String>) -> Outcome {
        switch decision {
        case let .wrap(candidate, key, provider, isNew):
            if conflicted.contains(key) {
                return Outcome(
                    variable: candidate.name, file: candidate.file, key: nil, provider: provider,
                    status: "skipped",
                    reason: "the key name \(key) is taken by a different value; nothing was overwritten"
                )
            }
            return Outcome(
                variable: candidate.name, file: candidate.file, key: key, provider: provider,
                status: "wrapped", reason: nil, isNew: isNew
            )
        case let .leave(candidate, key, provider, reason, _):
            if conflicted.contains(key) {
                return Outcome(
                    variable: candidate.name, file: candidate.file, key: nil, provider: provider,
                    status: "skipped",
                    reason: "the key name \(key) is taken by a different value; nothing was overwritten"
                )
            }
            // imported_not_wrapped rows carry no `new`: the vault-backed end state is the
            // same whether the key just landed or was already there, and the reason is
            // what the agent needs.
            return Outcome(
                variable: candidate.name, file: candidate.file, key: key, provider: provider,
                status: "imported_not_wrapped", reason: reason
            )
        case let .skip(candidate, key, provider, reason):
            return Outcome(
                variable: candidate.name, file: candidate.file, key: key, provider: provider,
                status: "skipped", reason: reason
            )
        }
    }

    /// The result payload: per-variable outcomes, the project label, the token's expiry
    /// (null when nothing was wrapped), the docker setting's live value, and the host
    /// this import's base URLs point at. Names, relative paths and dates only.
    private static func payload(
        project: CatalogDB.ProjectRow,
        outcomes: [Outcome],
        expiresAt: String?,
        docker: Bool,
        preferences: AppPreferences
    ) -> [String: Any] {
        [
            "project_label": project.label,
            "expires_at": expiresAt ?? NSNull(),
            "docker_access": preferences.dockerAccess,
            "base_url_host": baseURLHost(docker: docker),
            "variables": outcomes.map { $0.jsonObject() },
        ]
    }
}
