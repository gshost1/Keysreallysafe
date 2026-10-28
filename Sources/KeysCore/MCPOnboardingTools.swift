import CryptoKit
import Foundation

/// The onboarding group: `scan_project` first, with `check_exposure`,
/// `import_and_wrap` and `test_keys` joining this file in their own features. The
/// read-only half of onboarding answers "which credential-shaped variables live in
/// this folder" straight from the files, so an agent can point Keysrs at a project
/// and decide what to import without a single key value ever crossing the MCP
/// surface: the scan parses env files in THIS process, emits names, relative
/// paths, providers, categories and last-4 hints, and the only thing it ever asks
/// another process is the SHA-256 hex of a parsed value.
///
/// **Construction is offline-safe.** Nothing here opens a catalog, touches the
/// control channel or runs anything at init — the control file and the project
/// folder are seams, so building the production roster (which every in-process
/// test does) reads nothing. The app is contacted freshly per call through
/// `AppConnection`, and only when a tool needs it: `scan_project` treats the app
/// as an optional oracle and still answers without it.
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

    init(
        control: URL = ControlFile.url(),
        projectFolder: @escaping () -> String = { FileManager.default.currentDirectoryPath }
    ) {
        self.control = control
        self.projectFolder = projectFolder
    }

    func tools() -> [MCPTool] { [scanProject] }

    func call(_ name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "scan_project": return try serveScanProject(arguments)
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

    // MARK: - The tools

    /// One scan, parsed in this process, answered from the report alone. The env
    /// values exist only inside the parser: the result carries names, relative
    /// paths and last-4 hints, and the vault comparison sends SHA-256 hex
    /// digests — never a value — over the control channel. Any vault-comparison
    /// failure (the app down, a refused answer) is one honest disposition:
    /// `in_vault` unknown, with the scan itself still succeeding.
    private func serveScanProject(_ arguments: [String: Any]) throws -> MCPToolResult {
        var folder: String?
        if let raw = arguments["folder"], !(raw is NSNull) {
            guard let supplied = raw as? String else {
                throw AppError.usage("folder must be a string")
            }
            folder = supplied
        }
        let report = try EnvScan.scan(folder: folder ?? projectFolder())

        // In-vault comparison: one call for every candidate's digest, hashes only.
        // The scan never depends on it, so every failure — connect, status, shape —
        // collapses to the one "unavailable" answer instead of failing the scan.
        var matched: [String: String] = [:]
        var vaultCheck = "unavailable"
        do {
            let app = try AppConnection.connect(control: control)
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
