import CryptoKit
import Foundation

/// The onboarding group: `scan_project`, `check_exposure`, `import_and_wrap` and
/// `test_keys`. The read-only half of
/// onboarding answers "which credential-shaped variables
/// live in this folder" straight from the files, so an agent can point Keysrs
/// at a project and decide what to import without a single key value ever
/// crossing the MCP surface: the scan parses env files in THIS process, emits
/// names, relative paths, providers, categories and last-4 hints, and the only
/// thing it ever asks another process is the SHA-256 hex of a parsed value.
/// Exposure re-uses the same discovery and answers only git facts — three
/// read-only booleans per file and a rotation recommendation for anything ever
/// committed — never a file's contents. The import is the group's one write tool,
/// and it writes nothing itself: the request carries the folder, variable names
/// and flags only, the app re-reads the files, prompts once and answers with
/// per-variable outcomes — so no key value and no token ever crosses the wire
/// in either direction. The key test closes the group: confirm-gated and
/// app-mediated, so the one prompt it costs and the read-only probes it sends
/// both live in the process that holds the secrets, and an unconfirmed call
/// sends nothing at all.
///
/// **Construction is offline-safe.** Nothing here opens a catalog, touches the
/// control channel or runs anything at init — the control file, the project
/// folder and the git executable are seams, so building the production roster
/// (which every in-process test does) reads nothing. The app is contacted
/// freshly per call through `AppConnection`, and only when a tool needs it:
/// `scan_project` treats the app as an optional oracle and still answers
/// without it; `check_exposure` never needs it at all.
///
/// **No secret anywhere.** The MCP process never reads a vault value; `in_vault`
/// is decided by hash over the control channel, and the app's answer carries key
/// names only. The output guard's token-shape rule is the backstop over results
/// that report wrapped lines.
///
/// @unchecked: the seam closures are not Sendable, but the group is constructed
/// once and called from the server's single-threaded loop, never across a
/// concurrency domain.
struct MCPOnboardingTools: MCPToolGroup, @unchecked Sendable {
    static let groupName = "onboarding"

    /// The control file the app-bound lookups connect through. `AppConnection` is
    /// the only seam — nothing here touches the raw control client.
    private let control: URL
    /// The MCP process's own project folder — the server's working directory by
    /// default — the folder a call with no `folder` argument scans. Injectable so
    /// a test names a folder it built; production never overrides it.
    private let projectFolder: () -> String
    /// Where `check_exposure` finds git: resolved from PATH in production, an
    /// explicit path in tests — including a missing or a fake one, because the
    /// degraded answers are as much the contract as the facts. Read per call,
    /// never at init, so construction stays offline-safe.
    private let gitExecutable: () -> String?
    /// The launch seams behind `AppConnection.connect()`: the app-bound tools
    /// auto-launch the installed app when no live one exists, and tests wire
    /// recording fakes so no test path ever opens the real app or sleeps.
    private let launch: AppLaunchSeam

    init(
        control: URL = ControlFile.url(),
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath },
        gitExecutable: @escaping () -> String? = { MCPOnboardingTools.gitOnPATH() },
        launch: AppLaunchSeam = .production
    ) {
        self.control = control
        self.projectFolder = projectFolder
        self.gitExecutable = gitExecutable
        self.launch = launch
    }

    func tools() -> [MCPTool] { [scanProject, checkExposure, importAndWrap, testKeys] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "scan_project": return try serveScanProject(arguments)
        case "check_exposure": return try serveCheckExposure(arguments)
        case "import_and_wrap": return try serveImportAndWrap(arguments)
        case "test_keys": return try serveTestKeys(arguments)
        default: throw AppError.usage("\(name) is not one of this group's tools")
        }
    }

    private var scanProject: MCPTool {
        MCPTool(
            name: "scan_project",
            title: "Scan a project",
            description: "Scan a project folder for credential-shaped environment variables without reading "
                + "the files yourself: each one's name, relative file, likely provider, category "
                + "(provider_key, aws_pair, credential_url, wrapped), a last-4 hint, whether the value is "
                + "already in the vault, whether the gateway could proxy it, plus the env files read and the "
                + "docker files at the root. Never returns a key value: at most the last 4 characters. The "
                + "folder is optional and defaults to this process's working directory; a folder that does not "
                + "exist is a plain error. in_vault needs the Keysrs app (a hash-only vault comparison); "
                + "without the app the scan still answers and in_vault is null.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "folder": ["type": "string"],
                ] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    private var checkExposure: MCPTool {
        MCPTool(
            name: "check_exposure",
            title: "Check git exposure",
            description: "Check which env files in a project folder git has ever seen, without reading "
                + "the files yourself: for each one the scan finds, reports whether it is gitignored, "
                + "tracked in the index, or present anywhere in history. Never returns file contents or "
                + "diffs — only those three booleans per file, the relative file paths, and a "
                + "rotate-the-keys recommendation for any file that was ever committed. When the folder "
                + "is not a git repository, or git is not installed, every file reports null booleans "
                + "and the git field says so plainly. The folder is optional and defaults to this "
                + "process's working directory; a folder that does not exist is a plain error. Needs "
                + "no app, no vault and no network.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "folder": ["type": "string"],
                ] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    private var importAndWrap: MCPTool {
        MCPTool(
            name: "import_and_wrap",
            title: "Import and wrap a project",
            description: "Import the credential-shaped variables in a project folder into the Keysrs "
                + "vault and rewrite each one to a single 30-day project gateway token, all inside "
                + "the app under one Touch ID prompt that names the keys and the project. Ask the "
                + "user first in the same call. Only names and flags cross the wire: the app re-reads "
                + "the files itself, so never put a value in the request; the result carries "
                + "per-variable outcomes (wrapped, imported_not_wrapped, skipped, not_found with "
                + "reasons), the project label, the token's expiry, whether docker containers may "
                + "reach the gateway, and the base-URL host — never a key value, a token or an "
                + "absolute path. Values the gateway cannot proxy (AWS SigV4 pairs, credential URLs) "
                + "import but keep their lines; values with no recognized provider and no vault match "
                + "are not imported. docker true only with the user's explicit yes: it also lets "
                + "Docker containers reach the gateway through host.docker.internal base URLs. The "
                + "folder is optional and defaults to this process's working directory; variables "
                + "restricts the import to those names. Without the app running the whole call fails "
                + "with one sentence.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "folder": ["type": "string"],
                    "variables": ["type": "array", "items": ["type": "string"]] as [String: Any],
                    "docker": ["type": "boolean"],
                ] as [String: Any],
                "additionalProperties": false,
            ]
        )
    }

    private var testKeys: MCPTool {
        MCPTool(
            name: "test_keys",
            title: "Test vault keys",
            description: "Test whether named vault keys still work, read-only: each key's provider gets one GET "
                + "to its model-list endpoint and the answer is the keys-test shape per key (outcome, summary, "
                + "model list) plus a confirmed flag — never a key value. Confirmation is the user's alone, "
                + "every time: ask the user in this same call and pass confirm true only after they say yes; "
                + "never remember an earlier yes, never treat one approval as covering a later call. With "
                + "confirm absent or false nothing is sent to any provider, no prompt appears, and the result "
                + "says so per key. With confirm true the Keysrs app shows one Touch ID prompt naming the "
                + "keys, then checks each probeable key; a provider with no read-only check endpoint reports "
                + "no_check_endpoint with nothing sent, and a call with no probeable key prompts no one. "
                + "keys is a required list of vault key names; an unknown name is refused. Without the app "
                + "running the whole call fails with one sentence.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "keys": ["type": "array", "items": ["type": "string"]] as [String: Any],
                    "confirm": ["type": "boolean"],
                ] as [String: Any],
                "required": ["keys"],
                "additionalProperties": false,
            ]
        )
    }

    // MARK: - The tools

    /// One scan, parsed in this process, answered from the report alone. The env
    /// values exist only inside the parser: the result carries names, relative
    /// paths and last-4 hints, and the vault comparison sends SHA-256 hex
    /// digests — never a value — over the control channel. Any vault-comparison
    /// failure (the app down, a refused answer) is one honest disposition:
    /// `in_vault` unknown, with the scan itself still succeeding.
    private func serveScanProject(_ arguments: [String: Any]) throws -> MCPToolResult {
        let report = try EnvScan.scan(folder: try Self.folderArgument(arguments) ?? projectFolder())

        // In-vault comparison: one call for every candidate's digest, hashes only.
        // The scan never depends on it, so every failure — connect, status, shape —
        // collapses to the one "unavailable" answer instead of failing the scan.
        var matched: [String: String] = [:]
        var vaultCheck = "unavailable"
        do {
            let app = try AppConnection.connect(control: control, launch: launch)
            let answer = try app.call(
                method: "POST", path: "/api/mcp/vault_lookup",
                body: ["hashes": report.candidates.map { Self.digest($0.value) }], expect: 200
            )
            guard let matches = answer["matches"] as? [[String: Any]] else {
                throw AppError.usage("the vault lookup answer was not understood")
            }
            for entry in matches {
                if let hash = entry["hash"] as? String, let key = entry["key"] as? String {
                    matched[hash] = key
                }
            }
            vaultCheck = "app"
        } catch {
            matched = [:]
            vaultCheck = "unavailable"
        }

        var variables: [[String: Any]] = []
        for candidate in report.candidates {
            variables.append([
                "name": candidate.name,
                "file": candidate.file,
                "provider": candidate.provider ?? NSNull(),
                "category": candidate.category.rawValue,
                "last4": candidate.last4,
                // Unknown when the vault could not be consulted — a null the model
                // can tell apart from a real false, never a guessed answer.
                "in_vault": vaultCheck == "app" ? matched[Self.digest(candidate.value)] != nil : NSNull(),
                "proxyable": Self.proxyable(candidate),
                "wrapped": candidate.category == .wrapped,
            ])
        }
        return try MCPToolResult.json([
            "env_files": report.envFiles,
            "docker_files": report.dockerFiles,
            "vault_check": vaultCheck,
            "variables": variables,
        ])
    }

    // MARK: - The classification helpers

    /// SHA-256 hex of a parsed value, the only form of it that ever leaves this
    /// process. Lowercase by `Hex.encode`'s contract, and the route compares the
    /// same spelling.
    static func digest(_ value: String) -> String {
        Hex.encode(SHA256.hash(data: Data(value.utf8)))
    }

    /// The wrapPlan rule seen from the scan: a variable is proxyable when a
    /// recognized provider's gateway is on AND it has a host the gateway could
    /// reach (`Providers.provider(id:)`, the same refusal `wrapPlan` applies), and
    /// the value is not already a token. AWS pairs, credential URLs and provider
    /// lines no rule names are not proxyable — exactly the values `wrapPlan`
    /// would skip or refuse, so `scan_project` never advertises a wrap the import
    /// path would not perform.
    static func proxyable(_ candidate: EnvScan.Candidate) -> Bool {
        guard candidate.category == .providerKey, let id = candidate.provider,
              let provider = Providers.provider(id: id)
        else { return false }
        return provider.gateway && provider.host != nil
    }

    // MARK: - The shared folder argument

    /// The folder argument both folder-taking tools share: an optional string,
    /// absent or null meaning "the seam's folder". A non-string is the one
    /// usage error, path-free by construction.
    private static func folderArgument(_ arguments: [String: Any]) throws -> String? {
        guard let raw = arguments["folder"], !(raw is NSNull) else { return nil }
        guard let supplied = raw as? String else { throw AppError.usage("folder must be a string") }
        return supplied
    }

    // MARK: - check_exposure

    /// One exposure pass over the same EnvScan discovery: which env files exist
    /// is settled first, then three read-only git facts per file answer the one
    /// question onboarding actually needs — were the keys in this file ever
    /// committed? Contents never enter the result: the facts are booleans, the
    /// paths stay relative, and the recommendation is plain text. Everything
    /// that can go wrong with git (a missing binary, no repository, a call that
    /// outlives its bound) collapses into one honest shape — a plain top-level
    /// statement, null booleans, and a still-successful call — never a guess and
    /// never a hang. No app, no vault, no network: exposure needs nothing but
    /// the folder and, when it answers, a local read-only git.
    private func serveCheckExposure(_ arguments: [String: Any]) throws -> MCPToolResult {
        let report = try EnvScan.scan(folder: try Self.folderArgument(arguments) ?? projectFolder())

        guard let git = gitExecutable(), Self.isRunnable(git) else {
            return try Self.degraded(
                "git was not found, so git exposure could not be checked", files: report.envFiles
            )
        }
        switch Self.probe(git, root: report.root) {
        case .repository:
            break
        case .noRepository:
            return try Self.degraded(
                "the folder is not a git repository, so git exposure could not be checked",
                files: report.envFiles
            )
        case .unresponsive:
            return try Self.degraded(
                "git did not answer, so git exposure could not be checked", files: report.envFiles
            )
        }

        var files: [[String: Any]] = []
        for relative in report.envFiles {
            guard let ignored = Self.gitIgnored(git, root: report.root, file: relative),
                  let tracked = Self.gitTracked(git, root: report.root, file: relative),
                  let history = Self.gitInHistory(git, root: report.root, file: relative)
            else {
                return try Self.degraded(
                    "git did not answer, so git exposure could not be checked", files: report.envFiles
                )
            }
            files.append([
                "file": relative,
                "gitignored": ignored,
                "tracked": tracked,
                "in_history": history,
                // Exactly the committed cases — tracked now or ever — because
                // both mean the file's keys are recoverable from the repository.
                "recommendation": tracked || history ? Self.rotateRecommendation : NSNull(),
            ])
        }
        return try MCPToolResult.json(["git": "available", "files": files])
    }

    /// The recommendation for any file git has ever seen: plain text, no
    /// variable names, no paths — the same sentence for the tracked and the
    /// historical case, and the one follow-up an agent should give the user.
    private static let rotateRecommendation = "rotate the keys that were in this file"

    /// The hard bound on every single git invocation. A hung call costs at most
    /// its own bound before the tool gives up and answers the honest statement,
    /// so no misbehaving git can hold a tool call open.
    private static let gitCallTimeout: TimeInterval = 2

    /// What the repository probe learned — three cases because the plain
    /// statements differ: no repository is the everyday honest answer for a
    /// folder the user just created, while an unresponsive git is a failure.
    private enum RepositoryProbe {
        case repository, noRepository, unresponsive
    }

    /// Whether the resolved git path is something this process could actually
    /// run. A missing or unexecutable binary must be told apart from a failing
    /// command, because the plain statements differ — and nothing is spawned at
    /// all in this case.
    private static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path)
        else { return false }
        return true
    }

    /// The production git seam: git resolved from PATH the way a shell would,
    /// taken per call so construction stays offline-safe and a PATH that
    /// changes mid-session needs no restart. Empty PATH components are skipped
    /// (a shell would read them as the working directory; a tool must not).
    /// Tests inject explicit paths instead — a real one for fixture repos, a
    /// missing or fake one for the degraded answers.
    static func gitOnPATH() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/git"
            if isRunnable(candidate) { return candidate }
        }
        return nil
    }

    /// One metadata-only probe: is the folder inside a git working tree at all?
    /// It prints one word and touches no file contents.
    private static func probe(_ git: String, root: String) -> RepositoryProbe {
        guard let run = runGit(git, working: root, ["rev-parse", "--is-inside-work-tree"]) else {
            return .unresponsive
        }
        if run.exit == 0, run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            return .repository
        }
        return .noRepository
    }

    /// `git check-ignore -- <rel>`: exit 0 ignored, 1 not, anything else unknown.
    /// The rule is consultable with no commits and no working-tree file, which is
    /// what lets an unborn repository still answer honestly.
    private static func gitIgnored(_ git: String, root: String, file: String) -> Bool? {
        guard let run = runGit(git, working: root, ["check-ignore", "--", file]) else { return nil }
        if run.exit == 0 { return true }
        if run.exit == 1 { return false }
        return nil
    }

    /// `git ls-files -- <rel>`: tracked when the index names the file.
    private static func gitTracked(_ git: String, root: String, file: String) -> Bool? {
        guard let run = runGit(git, working: root, ["ls-files", "--", file]), run.exit == 0 else { return nil }
        return !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `git log --all --oneline -- <rel>`: any commit anywhere in the ref graph
    /// ever touched the file — the one fact that survives `git rm --cached`, and
    /// the whole reason this tool exists.
    private static func gitInHistory(_ git: String, root: String, file: String) -> Bool? {
        guard let run = runGit(git, working: root, ["log", "--all", "--oneline", "--", file]),
              run.exit == 0
        else { return nil }
        return !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One bounded git invocation, `-C` pinned to the canonical root. nil means
    /// git could not be spawned or did not finish inside the bound — the caller
    /// turns that into the honest statement instead of a fact. stderr is
    /// discarded unread: a fatal's text must never reach a result, and an unread
    /// stderr could stall git past its bound. stdout of the fact queries is a
    /// path or a handful of `--oneline` lines, read after exit; a repository so
    /// pathological it floods the pipe hits the bound and reads as "did not
    /// answer", the honest sentence.
    private static func runGit(
        _ executable: String, working directory: String, _ arguments: [String]
    ) -> (exit: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory] + arguments
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + gitCallTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The one honest degradation, shared by every way git could not answer: the
    /// plain statement says so, every file keeps its relative path, its three
    /// booleans are null (unknown, never a guess) and so is the recommendation,
    /// and the call itself still succeeds — the agent learns the files exist and
    /// that their git status could not be checked.
    private static func degraded(_ statement: String, files: [String]) throws -> MCPToolResult {
        try MCPToolResult.json([
            "git": statement,
            "files": files.map { [
                "file": $0,
                "gitignored": NSNull(),
                "tracked": NSNull(),
                "in_history": NSNull(),
                "recommendation": NSNull(),
            ] },
        ])
    }

    // MARK: - import_and_wrap

    /// The one write tool of onboarding, and the whole reason the request carries
    /// names and flags only: the app re-scans the folder and reads the values
    /// itself, over the same control channel every app-bound tool uses, through
    /// `AppConnection` — the only seam — with the presence call's longer bound,
    /// because the call legitimately stays open while the import's one Touch ID
    /// prompt is up. The app's answer is relayed verbatim; it carries outcomes,
    /// names and dates, so the output guard's token-shape rule passes over it by
    /// construction (the one token lives in the rewritten file, never on the wire).
    private func serveImportAndWrap(_ arguments: [String: Any]) throws -> MCPToolResult {
        var body: [String: Any] = [:]
        if let folder = try Self.folderArgument(arguments) { body["folder"] = folder }
        if let raw = arguments["variables"], !(raw is NSNull) {
            guard let names = raw as? [Any], names.allSatisfy({ $0 is String }) else {
                throw AppError.usage("variables must be a list of variable names")
            }
            body["variables"] = names
        }
        if let raw = arguments["docker"], !(raw is NSNull) {
            guard let docker = JSONValue.bool(raw) else { throw AppError.usage("docker must be a boolean") }
            body["docker"] = docker
        }
        let app = try AppConnection.connect(control: control, launch: launch)
        let answer = try app.call(
            method: "POST", path: "/api/mcp/import_and_wrap", body: body, expect: 200,
            timeout: AppConnection.presenceCallTimeout
        )
        return try MCPToolResult.json(answer)
    }

    /// The confirm-gated provider test. The whole behavior lives app-side — the
    /// confirm gate, the one prompt per call and the read-only probes all run in
    /// the one process that holds the secrets — so the tool relays key names and
    /// the flag only, never a value. The call bound is the presence bound exactly
    /// when the call is confirmed: that call legitimately stays open while its
    /// Touch ID prompt is up, and every other shape of it — including the
    /// not-confirmed fast path — keeps the 10 s default.
    private func serveTestKeys(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let names = arguments["keys"] as? [Any], !names.isEmpty, names.allSatisfy({ $0 is String }) else {
            throw AppError.usage("keys must be a non-empty list of key names")
        }
        var confirm = false
        if let raw = arguments["confirm"], !(raw is NSNull) {
            guard let flag = JSONValue.bool(raw) else { throw AppError.usage("confirm must be a boolean") }
            confirm = flag
        }
        let app = try AppConnection.connect(control: control, launch: launch)
        let answer = try app.call(
            method: "POST", path: "/api/mcp/test_keys",
            body: ["keys": names, "confirm": confirm],
            expect: 200,
            timeout: confirm ? AppConnection.presenceCallTimeout : AppConnection.appCallTimeout
        )
        return try MCPToolResult.json(answer)
    }
}

extension KeysService {
    /// The app side of `scan_project`'s in-vault comparison: which of the
    /// caller's SHA-256 value hashes match a secret this vault stores, answered by
    /// KEY NAME only — never a value, never a stored hash. The caller already
    /// holds the values it hashed (they came from the folder it scanned), key
    /// names are already public through `list_keys`, and the route is
    /// origin-token gated, so this follows the gateway's sanctioned no-prompt
    /// store read (the same `secrets.get` the gateway serves from): a scan must
    /// never cost a Touch ID prompt.
    ///
    /// One entry per requested hash, in request order: the matching key's name,
    /// or nil when nothing stored matches. The first matching row wins when two
    /// keys hold the same value — the same resolution `wrapPlan`'s dedupe uses.
    func vaultLookup(hashes: [String]) throws -> [(hash: String, key: String?)] {
        for hash in hashes {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                throw AppError.usage("hashes must be a list of SHA-256 hex strings")
            }
        }
        // Stored-side digests, computed once: a Keychain item whose row is gone
        // (or unreadable) matches nothing, like wrapPlan's vault load.
        var stored: [(name: String, digest: [UInt8])] = []
        for row in try catalog.listCatalog() {
            guard let secret = try? secrets.get(name: row.name) else { continue }
            stored.append((row.name, Array(Self.digest(secret).utf8)))
        }
        return hashes.map { hash in
            let wanted = Array(hash.lowercased().utf8)
            var match: String?
            for entry in stored where ConstantTime.equal(entry.digest, wanted) {
                match = match ?? entry.name
            }
            return (hash.lowercased(), match)
        }
    }

    /// The digest form the vault comparison shares: SHA-256 hex, lowercase.
    private static func digest(_ value: String) -> String {
        Hex.encode(SHA256.hash(data: Data(value.utf8)))
    }
}
