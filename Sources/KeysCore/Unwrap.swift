import Foundation

/// The app side of `keys unwrap` (architecture §2.9) — the inverse of both wrap paths.
/// Every wrapped line of the target file(s) gets its real value back from the vault,
/// the companion base URLs the wrap wrote are restored from the wrap-time backup (or
/// removed when no backup holds the original — the documented fallback), and the
/// gateway client tokens those lines held are revoked — except a token another
/// recorded wrapped file still holds, which is kept so the others keep working — all
/// under ONE presence prompt: reading the vault, rewriting the file and revoking are
/// one user-approved action, the mirror of the import's one prompt. Unwrap lives in
/// the app on purpose — the vault and `gateway_clients` belong to the one process that
/// owns them — and the MCP surface deliberately has no unwrap tool (the roster's
/// `neverRegistered` pin keeps it out), so this flow is reachable only through the
/// local, origin-token-gated `/api/unwrap` route.
extension KeysService {

    /// One unwrap call. Exactly one of `file` (the file form: exactly that file) or
    /// `folder` (the project form: every `wrapped_files` row of that project) must be
    /// given — the CLI sends the file argument it received, or its own working
    /// directory when there was none. The answer names variables, files and counts
    /// only; never a value, never a token.
    func unwrap(file: String?, folder: String?, caller: String = "unwrap", now: Date = Date()) throws -> [String: Any] {
        try requireGatewayOwner()
        if let file {
            guard folder == nil else { throw AppError.usage("keys unwrap takes a file or a project folder, not both") }
            return try unwrapFile(path: file, caller: caller, now: now)
        }
        guard let folder else {
            throw AppError.usage("keys unwrap needs a file path, or no argument in a project with wrapped files")
        }
        return try unwrapProject(folder: folder, caller: caller, now: now)
    }

    // MARK: - The file form

    private func unwrapFile(path: String, caller: String, now: Date) throws -> [String: Any] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // A recorded file the user deleted since wrap is a stale record, not an
            // error: the record must not outlive its file, and the uninstall offer —
            // which unwraps the recorded files before anything is removed — must not
            // abort on the first missing one. A path Keysrs never recorded keeps
            // today's honest notFound.
            let canonical = Self.canonicalSpelling(evenIfMissing: path)
            guard Set(try catalog.listWrappedFiles().map(\.path)).contains(canonical) else {
                throw AppError.notFound(path)
            }
            try catalog.clearWrappedFile(path: canonical)
            return ["files": [Self.goneRow(path: canonical)], "revoked": 0]
        }
        guard !isDirectory.boolValue else {
            throw AppError.usage("\(URL(fileURLWithPath: path).lastPathComponent) is a folder, not an env file")
        }
        guard let canonical = Self.canonicalPath(path) else { throw AppError.notFound(path) }
        // The file's own bytes decide whether there is anything to unwrap — the prompt
        // only fires when there is, and a stale record clears without one.
        guard Self.fileHasWrappedState(canonical) else {
            try catalog.clearWrappedFile(path: canonical)
            return ["files": [Self.staleRow(path: canonical)], "revoked": 0]
        }
        let display = URL(fileURLWithPath: canonical).lastPathComponent
        try presence.require(reason: "unwrap \(display) and revoke its gateway client tokens")
        let outcome = try restoreFile(canonical: canonical, caller: caller, now: now)
        return ["files": [outcome.payload()], "revoked": outcome.revoked]
    }

    // MARK: - The project form

    private func unwrapProject(folder: String, caller: String, now: Date) throws -> [String: Any] {
        // A lookup, never a get-or-create: a cwd whose project was never wrapped must
        // answer an honest "nothing was changed" without leaving a row behind.
        let expanded = (folder as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return try clearDeletedProject(folder: expanded)
        }
        let canonical = try Project.canonicalFolder(folder)
        guard let project = try catalog.project(path: canonical) else {
            throw AppError.notFound("no project at the working directory was ever wrapped; nothing was changed")
        }
        let rows = try catalog.listWrappedFiles().filter { $0.project == project.id }
        guard !rows.isEmpty else {
            throw AppError.notFound("no wrapped files are recorded for this project; nothing was changed")
        }

        // The pre-prompt pass over the recorded files: only a project with live
        // wrapped state prompts. Rows whose files are gone or hold nothing wrapped are
        // stale — cleared and reported without a Touch ID.
        var live: [String] = []
        var stale: [String] = []
        var gone: [String] = []
        for row in rows {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: row.path, isDirectory: &isDirectory) {
                gone.append(row.path)
            } else if Self.fileHasWrappedState(row.path) {
                live.append(row.path)
            } else {
                stale.append(row.path)
            }
        }
        guard !live.isEmpty else {
            for path in gone + stale { try catalog.clearWrappedFile(path: path) }
            return [
                "project": project.label,
                "files": gone.map(Self.goneRow) + stale.map(Self.staleRow),
                "revoked": 0,
            ]
        }

        // ONE prompt for the whole call, naming the files and the project.
        let names = live.map { URL(fileURLWithPath: $0).lastPathComponent }
        let named = names.count == 1 ? names[0] : "\(names.count) files"
        try presence.require(
            reason: "unwrap \(named) for project \(project.label) and revoke their gateway client tokens"
        )

        var files: [[String: Any]] = []
        var revoked = 0
        for row in rows {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: row.path, isDirectory: &isDirectory) {
                files.append(Self.goneRow(path: row.path))
                try catalog.clearWrappedFile(path: row.path)
                continue
            }
            let outcome = try restoreFile(canonical: row.path, caller: caller, now: now)
            files.append(outcome.payload())
            revoked += outcome.revoked
        }
        // The project's own tokens die with the call even when no restored file held
        // one (a token whose only file was deleted, say). Per-key `keys wrap` tokens
        // minted outside any project were revoked per file above, by the hash of the
        // token values their files held.
        revoked += try revokeGatewayClients(project: project.id)
        return ["project": project.label, "files": files, "revoked": revoked]
    }

    /// A recorded project whose folder was deleted since wrap is stale, like a
    /// deleted file: there is nothing left to restore, so its records clear and
    /// its tokens are revoked, with no prompt — both only remove access. The
    /// uninstall offer unwraps every recorded project before the removal, and a
    /// throw here used to abort it on every retry. A folder that never was a
    /// project keeps the honest "nothing was changed".
    private func clearDeletedProject(folder: String) throws -> [String: Any] {
        let spelled = Self.canonicalSpelling(evenIfMissing: folder)
        guard let project = try catalog.project(path: spelled) ?? catalog.project(path: folder) else {
            throw AppError.usage("that project folder does not exist")
        }
        let rows = try catalog.listWrappedFiles().filter { $0.project == project.id }
        for row in rows { try catalog.clearWrappedFile(path: row.path) }
        let revoked = try revokeGatewayClients(project: project.id)
        return ["project": project.label, "files": rows.map { Self.goneRow(path: $0.path) }, "revoked": revoked]
    }

    // MARK: - The per-file restore (shared by both forms, already under the prompt)

    /// Reads the file fresh (the prompt window may have been long), restores each
    /// wrapped line's value from the vault, fixes the companion lines the wrap wrote,
    /// swaps the file in without a new backup, revokes the tokens the file held by
    /// the hash of their values — except a token another recorded wrapped file still
    /// holds, which is kept and reported — and clears the file's record. Per-line
    /// failures are reported and the other lines still restore — no silent partial
    /// state.
    private func restoreFile(canonical: String, caller: String, now: Date) throws -> FileOutcome {
        var outcome = FileOutcome(path: canonical)
        let display = URL(fileURLWithPath: canonical).lastPathComponent
        // The recorded path is canonical as of the wrap. A parent folder swapped
        // for a symlink since then would make the restore write real key values
        // wherever that link points, so the file must still resolve to exactly
        // where it was recorded (the import's own apply-time re-check, S7).
        guard Self.stillAtRecordedPath(canonical) else {
            outcome.message = "\(display) no longer resolves to the recorded location; nothing was restored for it"
            return outcome
        }
        guard let data = FileManager.default.contents(atPath: canonical),
              let text = String(data: data, encoding: .utf8) else {
            outcome.message = "could not read \(display); nothing was restored for it"
            return outcome
        }
        var parsed = EnvFile.parse(text)
        let wrapped = Self.wrappedLines(in: parsed)
        let companions = Self.companionIndices(in: parsed)
        guard !wrapped.isEmpty || !companions.isEmpty else {
            outcome.message = "nothing to unwrap in \(display); the stale record was cleared"
            try catalog.clearWrappedFile(path: canonical)
            return outcome
        }

        // The wrap-time backup, from either location (VAL-O-002): the newest
        // `.keysrs-backup-` beside the file (wraps written before backups moved out
        // of the project) or the file's hashed folder under the catalog-sibling
        // backups tree (every wrap since) — the only source for companion lines the
        // wrap replaced. No backup → the documented fallback below.
        //
        // The App Support tree wins whenever it holds a backup for this file: a
        // legacy backup beside the file sits in the project, where anyone who can
        // commit to the repo can plant one, so it is read only when no App Support
        // backup exists, and it never decides a gateway base URL line (S7) — a
        // planted `OPENAI_BASE_URL=https://attacker/v1` beside the real key would
        // send the key there.
        let backup = Self.newestBackup(of: canonical, under: EnvFileWriter.backupsRoot(beside: catalog.path))
        outcome.backup = backup?.url.path
        var backupParsed: EnvFile?
        if let backup,
           let backupData = FileManager.default.contents(atPath: backup.url.path),
           let backupText = String(data: backupData, encoding: .utf8) {
            backupParsed = EnvFile.parse(backupText)
        }
        let backupIsLegacy = backup?.legacy ?? false

        // Restore each wrapped line from the vault. Resolution order per line: the
        // gateway base URL companion beside it (the only per-line signal when one
        // project token covers several keys), then the token's own row (a per-key
        // token names its key; a project token with one member names it) — but the
        // token is what proves the line, so a companion's key is accepted only when
        // that token's client serves it (keyNameForWrappedLine). A line whose key
        // cannot be resolved, or whose key is gone from the vault, is a stated
        // per-line failure; its token still dies in the revocation below.
        for (index, entry) in wrapped {
            guard let key = try keyNameForWrappedLine(entry, file: parsed) else {
                outcome.failed.append((entry.name, "cannot tell which vault key this line held: "
                    + "its token is unknown to Keysrs or serves several keys with no gateway base URL naming one"))
                continue
            }
            guard (try? catalog.catalogRow(name: key)) != nil, let secret = try? secrets.get(name: key) else {
                outcome.failed.append((entry.name, "the vault key \(key) is gone; the line keeps its token "
                    + "(revoked now) — add the key back with keys add and run keys unwrap again"))
                continue
            }
            parsed.setValue(at: index, secret)
            outcome.restored.append(entry.name)
        }

        // The companion lines: restored from the backup when it holds the variable,
        // removed when the wrap wrote them and no backup holds an original. Only
        // lines pointing at this gateway are touched — a companion the user already
        // repointed elsewhere, or a relay URL from `keys wrap --relay`, is left as the
        // user set it. Removal, too, is limited to what Keysrs recorded writing: the
        // wrap's own record names its companions, and a gateway-pointing URL the user
        // wrote themselves stays as written and is reported. A record from before the
        // companion list existed (or no record at all) keeps today's documented
        // removal fallback — nil means "unknown", not "none". Removals are collected
        // first and applied in one pass, because line indices shift under a removal
        // loop.
        let recordedCompanions = try catalog.recordedCompanions(path: canonical)
        var removedIndices: Set<Int> = []
        for (name, index) in companions {
            if backupIsLegacy, name.hasSuffix("_BASE_URL") {
                // The in-project backup is not trusted for base URLs: the current
                // line stays as it is and is reported.
                if !outcome.companionsLeft.contains(name) { outcome.companionsLeft.append(name) }
            } else if let original = backupParsed?.value(of: name) {
                parsed.setValue(at: index, original)
                if !outcome.companionsRestored.contains(name) { outcome.companionsRestored.append(name) }
            } else if recordedCompanions?.contains(name) ?? true {
                removedIndices.insert(index)
                if !outcome.companionsRemoved.contains(name) { outcome.companionsRemoved.append(name) }
            } else if !outcome.companionsLeft.contains(name) {
                outcome.companionsLeft.append(name)
            }
        }
        if !removedIndices.isEmpty {
            parsed.lines = parsed.lines.enumerated()
                .filter { !removedIndices.contains($0.offset) }
                .map(\.element)
        }

        // Swap the restored file in. The refuse-if-changed comparison is against the
        // bytes read under the prompt, so an edit made while it was up refuses here
        // with nothing half-applied — the same refusal keys wrap gives.
        if !outcome.restored.isEmpty
            || !outcome.companionsRestored.isEmpty || !removedIndices.isEmpty {
            guard Self.stillAtRecordedPath(canonical) else {
                throw AppError.usage("\(display) no longer resolves to the recorded location; nothing rewritten")
            }
            try EnvFileWriter.swap(URL(fileURLWithPath: canonical), original: data, text: parsed.render())
        }
        // A legacy backup beside the file holds the pre-wrap values inside the
        // project, where git can pick it up; once every line came back it has no
        // further use, so it goes (every one of this file's, not only the newest).
        if backupIsLegacy, outcome.failed.isEmpty {
            for legacy in Self.legacyBackups(of: canonical) { try? FileManager.default.removeItem(at: legacy) }
            outcome.backup = nil
        }

        // Revoke exactly the tokens this file held, found by hashing each wrapped
        // line's token value: per-key tokens from `keys wrap` and the project token
        // from `import_and_wrap` alike. A token another RECORDED wrapped file still
        // holds is kept — import_and_wrap gives one project token to several files,
        // and unwrapping one must leave the others working: the token dies when the
        // last of its files unwraps (its own check finds no other holder), or with the
        // project revoke in the project form. A token the catalog no longer knows (a
        // purge since wrap) has nothing to revoke; the revocation is idempotent, so
        // the same token on several lines flips once.
        var seenTokens: Set<String> = []
        for (_, entry) in wrapped where seenTokens.insert(entry.value).inserted {
            guard let client = try catalog.gatewayClient(tokenHash: GatewayClientToken.hash(entry.value)) else {
                continue
            }
            let stillUsedBy = try catalog.listWrappedFiles()
                .filter { $0.path != canonical }
                .filter { Self.fileHoldsToken($0.path, token: entry.value) }
                .map(\.path)
            if !stillUsedBy.isEmpty {
                outcome.stillUsedBy.append(
                    contentsOf: stillUsedBy.filter { !outcome.stillUsedBy.contains($0) }
                )
                continue
            }
            if try catalog.revokeGatewayClient(id: client.id, keyName: client.keyName, at: UTC.iso(now)) {
                // Best effort after the revoke already succeeded: the audit row is not
                // worth failing a restored file over.
                try? recordKeyEvent(name: client.keyName, action: "client_revoke", caller: caller, detail: "#\(client.id)")
                outcome.revoked += 1
            }
        }
        try catalog.clearWrappedFile(path: canonical)
        return outcome
    }

    /// Which vault key one wrapped line holds. The line's own token identifies the
    /// client — and so the exact keys it may serve; the gateway base URL companion
    /// beside it only names one of them. A companion-derived key is accepted only when
    /// that token's client actually serves it (a membership row, or the client's own
    /// keyName), or when the named key is absent from the catalog entirely — a key
    /// deleted since wrap, which cannot write anything and whose "gone" failure below
    /// is the actionable report. A companion edited to point at a key that EXISTS in
    /// the vault but was never served by this token resolves to nil: the line fails
    /// per-line and nothing is written for it.
    private func keyNameForWrappedLine(_ entry: EnvFile.Entry, file: EnvFile) throws -> String? {
        guard let client = try catalog.gatewayClient(tokenHash: GatewayClientToken.hash(entry.value)) else {
            return nil
        }
        let members = try catalog.gatewayClientKeys(clientID: client.id)
        if let baseVar = WrapDetect.baseURLVariables[entry.name],
           let url = file.value(of: baseVar),
           let key = Self.gatewayKeySegment(of: url) {
            let served = members.contains { $0.keyName == key } || key == client.keyName
            return served || (try? catalog.catalogRow(name: key)) == nil ? key : nil
        }
        if members.count == 1 { return members[0].keyName }
        if members.isEmpty { return client.keyName }
        return nil
    }

    // MARK: - File reading helpers (values stay in this process)

    /// The canonical spelling of a path whose file may be gone: `realpath` cannot
    /// resolve a deleted final component, so the parent is resolved and the name
    /// appended — the same spelling `recordWrappedFile` stored while the file existed
    /// (the `/var` → `/private/var` spelling difference is exactly why the parent
    /// must be resolved and not the path passed through).
    static func canonicalSpelling(evenIfMissing path: String) -> String {
        if let resolved = canonicalPath(path) { return resolved }
        let components = path as NSString
        let parent = canonicalPath(components.deletingLastPathComponent) ?? components.deletingLastPathComponent
        return (parent as NSString).appendingPathComponent(components.lastPathComponent)
    }

    /// True when the file holds a wrapped line or a companion pointing at this
    /// gateway — the pre-prompt test for "is there anything to unwrap".
    static func fileHasWrappedState(_ canonical: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: canonical),
              let text = String(data: data, encoding: .utf8) else { return false }
        let parsed = EnvFile.parse(text)
        return !wrappedLines(in: parsed).isEmpty || !companionIndices(in: parsed).isEmpty
    }

    /// The assignment lines holding a gateway client token, in file order.
    static func wrappedLines(in file: EnvFile) -> [(index: Int, entry: EnvFile.Entry)] {
        file.entries.filter { !$0.entry.multiline && GatewayClientToken.looksLikeToken($0.entry.value) }
            .map { ($0.index, $0.entry) }
    }

    /// True when the file on disk still assigns this exact token value — the check
    /// that keeps a project token alive while another recorded wrapped file still
    /// holds it. The token value never leaves this process; only the boolean does.
    static func fileHoldsToken(_ canonical: String, token: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: canonical),
              let text = String(data: data, encoding: .utf8) else { return false }
        return wrappedLines(in: EnvFile.parse(text)).contains { $0.entry.value == token }
    }

    /// The lines assigning one of the three wrap companion variables a value that
    /// points at this gateway. Relay URLs, upstream URLs and the user's own proxies
    /// are not wrap companions and are never touched.
    static func companionIndices(in file: EnvFile) -> [(name: String, index: Int)] {
        let names = Set(WrapDetect.baseURLVariables.values)
        return file.entries.compactMap { index, entry in
            guard !entry.multiline, names.contains(entry.name),
                  Self.gatewayKeySegment(of: entry.value) != nil else { return nil }
            return (entry.name, index)
        }
    }

    /// `http://127.0.0.1:12767/<key>` and the docker form the import writes: the first
    /// path segment is the key the URL routes to. Anything else answers nil.
    static func gatewayKeySegment(of value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              components.port == Int(GatewayListener.port),
              host == "127.0.0.1" || host == "host.docker.internal"
        else { return nil }
        guard let first = components.path.split(separator: "/").first else { return nil }
        let key = String(first)
        return (try? KeyName.validate(key)) != nil ? key : nil
    }

    /// The newest wrap-time backup of the file, from either location (VAL-O-002):
    /// the legacy `<file>.keysrs-backup-<ts>` beside the file — wraps written before
    /// backups moved out of the project — and the current location, the file's own
    /// hashed folder under the catalog-sibling backups tree. The `yyyyMMdd-HHmmss`
    /// timestamp sorts lexically and the `-2`/`-3` collision suffixes sort after
    /// their base, so the lexical maximum across both places is the most recent
    /// wrap, whichever location holds it.
    static func newestBackup(of path: String, under backupsRoot: URL) -> (url: URL, legacy: Bool)? {
        let url = URL(fileURLWithPath: path)
        let prefix = url.lastPathComponent + ".keysrs-backup-"
        if let dir = EnvFileWriter.backupDirectory(for: url, under: backupsRoot),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           let newest = names.filter({ $0.hasPrefix(prefix) }).max() {
            return (dir.appendingPathComponent(newest), false)
        }
        return legacyBackups(of: path).max { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, true) }
    }

    /// The pre-0.14 backups a wrap wrote beside the file itself.
    static func legacyBackups(of path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".keysrs-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { folder.appendingPathComponent($0) }
    }

    /// True when the recorded canonical path still resolves to itself: no folder
    /// on the way was swapped for a symlink since the wrap recorded it.
    static func stillAtRecordedPath(_ canonical: String) -> Bool {
        EnvScan.resolve(canonical) == canonical
    }

    // MARK: - The result rows

    /// One file's row of the result. Variable names and counts only.
    private struct FileOutcome {
        var path: String
        var restored: [String] = []
        var failed: [(variable: String, reason: String)] = []
        var companionsRestored: [String] = []
        var companionsRemoved: [String] = []
        /// Gateway-pointing companions the wrap never recorded writing — the user's
        /// own lines, left as written and reported.
        var companionsLeft: [String] = []
        /// Other recorded wrapped files still holding one of this file's tokens —
        /// why those tokens were kept instead of revoked.
        var stillUsedBy: [String] = []
        var backup: String?
        var revoked = 0
        var message: String?

        init(path: String, message: String? = nil) {
            self.path = path
            self.message = message
        }

        func payload() -> [String: Any] {
            var o: [String: Any] = [
                "file": path,
                "restored": restored,
                "failed": failed.map { ["variable": $0.variable, "reason": $0.reason] },
                "companions_restored": companionsRestored,
                "companions_removed": companionsRemoved,
                "companions_left": companionsLeft,
                "still_used_by": stillUsedBy,
                "revoked": revoked,
                "backup": backup ?? NSNull(),
            ]
            if let message { o["message"] = message }
            return o
        }
    }

    private static func staleRow(path: String) -> [String: Any] {
        FileOutcome(
            path: path,
            message: "nothing to unwrap in \(URL(fileURLWithPath: path).lastPathComponent); the stale record was cleared"
        ).payload()
    }

    private static func goneRow(path: String) -> [String: Any] {
        FileOutcome(
            path: path,
            message: "the recorded file \(URL(fileURLWithPath: path).lastPathComponent) no longer exists; its stale record was cleared"
        ).payload()
    }
}

/// `keys unwrap` — the CLI half. Connects exactly like `keys wrap` (`ControlClient`, no
/// auto-launch: a script gets exit 6 and the wrap-style sentence when the app is down),
/// sends the file path absolutized against this process's working directory (the app
/// cannot know the terminal's cwd) or the working directory itself for the project
/// form, then prints what happened: variable names, files and counts — a restored
/// value or a token is never printed.
struct UnwrapRunner {
    let connect: () throws -> ControlClient
    let out: (String) -> Void
    /// The folder the project form unwraps. Injectable so tests point at a temp
    /// project; the default is the command line's own working directory.
    let projectFolder: () -> String

    init(
        connect: @escaping () throws -> ControlClient,
        out: @escaping (String) -> Void,
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath }
    ) {
        self.connect = connect
        self.out = out
        self.projectFolder = projectFolder
    }

    @discardableResult
    func run(path: String?) throws -> [String: Any] {
        let client = try connect()
        let body: [String: Any]
        if let path {
            body = ["file": URL(fileURLWithPath: path).path]
        } else {
            body = ["folder": projectFolder()]
        }
        let result = try client.call(method: "POST", path: "/api/unwrap", body: body, expect: 200)
        report(result)
        return result
    }

    private func report(_ result: [String: Any]) {
        for any in (result["files"] as? [Any]) ?? [] {
            guard let file = JSONValue.object(any) else { continue }
            let name = URL(fileURLWithPath: JSONValue.string(file["file"]) ?? "").lastPathComponent
            if let message = JSONValue.string(file["message"]) {
                out("\(name): \(message)")
                continue
            }
            let restored = (file["restored"] as? [Any])?.compactMap { $0 as? String } ?? []
            out(restored.isEmpty
                ? "\(name): no wrapped line could be restored from the vault"
                : "\(name): restored \(restored.joined(separator: ", ")) from the vault")
            for failed in (file["failed"] as? [Any])?.compactMap(JSONValue.object) ?? [] {
                out("  could not restore \(JSONValue.string(failed["variable"]) ?? "") — "
                    + (JSONValue.string(failed["reason"]) ?? ""))
            }
            let companionsRestored = (file["companions_restored"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !companionsRestored.isEmpty {
                out("  \(companionsRestored.joined(separator: ", ")) restored from the wrap-time backup")
            }
            let companionsRemoved = (file["companions_removed"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !companionsRemoved.isEmpty {
                out("  \(companionsRemoved.joined(separator: ", ")) removed (the wrap-time backup holds no original for it)")
            }
            let companionsLeft = (file["companions_left"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !companionsLeft.isEmpty {
                out("  \(companionsLeft.joined(separator: ", ")) left as written (not one of the companions this wrap recorded)")
            }
            let stillUsedBy = (file["still_used_by"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !stillUsedBy.isEmpty {
                let names = stillUsedBy.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: ", ")
                out("  \(names) still use\(stillUsedBy.count == 1 ? "s" : "") this file's gateway token; it was kept")
            }
            let revoked = JSONValue.int(file["revoked"]) ?? 0
            if revoked > 0 { out("  \(revoked) gateway client token\(revoked == 1 ? "" : "s") revoked") }
        }
        let revoked = JSONValue.int(result["revoked"]) ?? 0
        out("revoked \(revoked) gateway client token\(revoked == 1 ? "" : "s"); the wrapped-files records were cleared")
    }
}
