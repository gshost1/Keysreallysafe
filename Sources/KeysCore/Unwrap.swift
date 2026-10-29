import Foundation

/// The app side of `keys unwrap` (architecture §2.9) — the inverse of both wrap paths.
/// Every wrapped line of the target file(s) gets its real value back from the vault,
/// the companion base URLs the wrap wrote are restored from the wrap-time backup (or
/// removed when no backup holds the original — the documented fallback), and the
/// gateway client tokens those lines held are revoked, all under ONE presence prompt:
/// reading the vault, rewriting the file and revoking are one user-approved action,
/// the mirror of the import's one prompt. Unwrap lives in the app on purpose — the
/// vault and `gateway_clients` belong to the one process that owns them — and the MCP
/// surface deliberately has no unwrap tool (the roster's `neverRegistered` pin keeps
/// it out), so this flow is reachable only through the local, origin-token-gated
/// `/api/unwrap` route.
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
            throw AppError.notFound(path)
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

    // MARK: - The per-file restore (shared by both forms, already under the prompt)

    /// Reads the file fresh (the prompt window may have been long), restores each
    /// wrapped line's value from the vault, fixes the companion lines the wrap wrote,
    /// swaps the file in without a new backup, revokes the tokens the file held by
    /// the hash of their values, and clears the file's record. Per-line failures are
    /// reported and the other lines still restore — no silent partial state.
    private func restoreFile(canonical: String, caller: String, now: Date) throws -> FileOutcome {
        var outcome = FileOutcome(path: canonical)
        let display = URL(fileURLWithPath: canonical).lastPathComponent
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

        // The wrap-time backup: the newest `.keysrs-backup-` sibling, the only source
        // for companion lines the wrap replaced (byte-for-byte restoration when the
        // file is unedited since wrap). No backup → the documented fallback below.
        let backup = Self.newestBackup(of: canonical)
        outcome.backup = backup?.path
        var backupParsed: EnvFile?
        if let backup,
           let backupData = FileManager.default.contents(atPath: backup.path),
           let backupText = String(data: backupData, encoding: .utf8) {
            backupParsed = EnvFile.parse(backupText)
        }

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
        // removed when the wrap appended it (or when no backup exists). Only lines
        // pointing at this gateway are touched — a companion the user already repointed
        // elsewhere, or a relay URL from `keys wrap --relay`, is left as the user set
        // it. Removals are collected first and applied in one pass, because line
        // indices shift under a removal loop.
        var removedIndices: Set<Int> = []
        for (name, index) in companions {
            if let original = backupParsed?.value(of: name) {
                parsed.setValue(at: index, original)
                if !outcome.companionsRestored.contains(name) { outcome.companionsRestored.append(name) }
            } else {
                removedIndices.insert(index)
                if !outcome.companionsRemoved.contains(name) { outcome.companionsRemoved.append(name) }
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
            try EnvFileWriter.swap(URL(fileURLWithPath: canonical), original: data, text: parsed.render())
        }

        // Revoke exactly the tokens this file held, found by hashing each wrapped
        // line's token value: per-key tokens from `keys wrap` and the project token
        // from `import_and_wrap` alike. A token the catalog no longer knows (a purge
        // since wrap) has nothing to revoke; the revocation is idempotent, so the
        // same token on several lines flips once.
        var seenTokens: Set<String> = []
        for (_, entry) in wrapped where seenTokens.insert(entry.value).inserted {
            guard let client = try catalog.gatewayClient(tokenHash: GatewayClientToken.hash(entry.value)) else {
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

    /// The newest wrap-time backup beside the file. The `yyyyMMdd-HHmmss` timestamp
    /// sorts lexically and the `-2`/`-3` collision suffixes sort after their base, so
    /// the lexical maximum is the most recent wrap.
    static func newestBackup(of path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        let prefix = url.lastPathComponent + ".keysrs-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.max()
            .map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    // MARK: - The result rows

    /// One file's row of the result. Variable names and counts only.
    private struct FileOutcome {
        var path: String
        var restored: [String] = []
        var failed: [(variable: String, reason: String)] = []
        var companionsRestored: [String] = []
        var companionsRemoved: [String] = []
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
            let revoked = JSONValue.int(file["revoked"]) ?? 0
            if revoked > 0 { out("  \(revoked) gateway client token\(revoked == 1 ? "" : "s") revoked") }
        }
        let revoked = JSONValue.int(result["revoked"]) ?? 0
        out("revoked \(revoked) gateway client token\(revoked == 1 ? "" : "s"); the wrapped-files records were cleared")
    }
}
