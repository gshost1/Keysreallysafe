import Darwin
import Foundation

// The one folder-walk + classification pass both processes share. The MCP process reports
// what a scan found (`scan_project`, `check_exposure`) and the app re-reads the same files
// on import, so both must answer "which credential-shaped variables live in this folder"
// with the exact same rules — and every rule here is also a limit on what a scan of a
// folder the user only just pointed at can ever open: three file names, depth 3, a size
// cap, a pinned directory list and per-entry symlink containment mean no walk reaches
// `~/.codex/auth.json`, a node_modules cache, or anything a symlink leads to outside the
// project. Values parsed on the way exist only in the calling process: callers hash them,
// store them or rewrite them, but no tool result, log or report carries one — the
// candidates here carry a last-4 hint for everything that leaves the process.

/// One `.env`-shaped project scan: the env files that were read, the credential-shaped
/// variables found in them, and which docker files sit at the root.
enum EnvScan {

    /// The only filenames ever read. `.env.example`-style templates are documentation,
    /// not secrets; every other name stays unread whatever it contains.
    static let envFileNames: Set<String> = [".env", ".env.local", ".env.production"]

    /// Directory names never descended into: dependency caches, build output, checkouts.
    /// They hold vendored `.env` fixtures and gigabytes the user did not point at.
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", ".venv", "venv", "vendor", "dist",
        "build", "target", "Pods", "DerivedData", "__pycache__",
    ]

    /// Never opened under any name. Defense in depth: the name filter already excludes
    /// these, and this still refuses when an env-named symlink is pointed at one.
    static let neverOpenNames: Set<String> = ["auth.json", "credentials", "credentials.json"]

    /// Files larger than this are skipped unread rather than truncated or partially read.
    static let maxFileBytes = 1_048_576

    /// Directory levels below the root that are enumerated for env files.
    static let maxDepth = 3

    /// Docker files reported by presence at the scan root, in this order.
    static let dockerFileNames = ["docker-compose.yml", "compose.yaml", "Dockerfile"]

    /// The AWS SigV4 halves. Neither is a provider key the gateway could proxy, and they
    /// are one credential, so each carries the other's name when both sit in a file.
    static let awsPairSiblings: [String: String] = [
        "AWS_ACCESS_KEY_ID": "AWS_SECRET_ACCESS_KEY",
        "AWS_SECRET_ACCESS_KEY": "AWS_ACCESS_KEY_ID",
    ]

    enum Category: String, Equatable, Sendable {
        case providerKey = "provider_key"
        case awsPair = "aws_pair"
        case credentialURL = "credential_url"
        case wrapped = "wrapped"
    }

    /// One credential-shaped variable. The value stays in the calling process; `last4` is
    /// the only piece of it any result ever carries.
    struct Candidate: Equatable, Sendable {
        var name: String
        /// POSIX path relative to the scan root — never absolute in a result.
        var file: String
        var category: Category
        /// Provider id from the WrapDetect rules; nil when no rule names one (a vault
        /// match needs none, exactly as `wrapPlan` treats them).
        var provider: String?
        /// The other half of an AWS pair, when the sibling is itself a candidate.
        var pair: String?
        /// The last four characters of the value.
        var last4: String
        var value: String
    }

    /// One env file the scan actually read, parsed line for line. For the caller that
    /// owns the folder (the import path); reporting callers emit names and paths only.
    struct ScannedFile: Equatable {
        /// POSIX path relative to the scan root — the only form a result may carry.
        var path: String
        var parsed: EnvFile
    }

    struct Report: Equatable {
        /// The canonical (realpath-resolved) root, the `Project.canonicalFolder`
        /// discipline. The project's identity: used in-process for absolute paths and
        /// git, never in a tool result or log.
        var root: String
        /// Relative POSIX paths of the env files that were read, sorted.
        var envFiles: [String]
        /// Which of `dockerFileNames` exist at the scan root, in the pinned order.
        var dockerFiles: [String]
        /// The parsed files behind `envFiles`, in the same order.
        var files: [ScannedFile]
        /// Credential-shaped variables, `files` order then line order within a file.
        var candidates: [Candidate]

        /// The absolute URL of a reported path, for the process that owns the folder.
        func absolute(_ relative: String) -> URL {
            URL(fileURLWithPath: root).appendingPathComponent(relative)
        }
    }

    /// Scans a folder. A nil or empty folder is the process working directory; a folder
    /// that does not exist or is not a directory is a plain, path-free usage error (the
    /// message can end up in a tool result).
    static func scan(folder: String?) throws -> Report {
        let root = try Project.canonicalFolder(folder)

        // The walk treats a directory it cannot list as empty — right for a locked
        // subfolder, but the root is the folder the user pointed at: a root whose
        // contents cannot even be listed must not answer "no env files found".
        guard (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else {
            throw AppError.usage("the project folder could not be read")
        }

        var dockerFiles: [String] = []
        for name in dockerFileNames {
            // Presence only — nothing is opened. Containment applies even here: a
            // Dockerfile symlinked out of the project is not the project's, and a
            // directory wearing a docker name is not a docker file.
            var isDirectory: ObjCBool = false
            guard let resolved = resolve(join(root, name)), isInside(resolved, root: root),
                  FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            dockerFiles.append(name)
        }

        var walker = Walk(root: root)
        walker.walk(directory: root, prefix: "", depth: 0)

        // Deterministic order: files by relative path, candidates in each file's line
        // order (the same order `keys wrap` would see them in).
        walker.files.sort { $0.path < $1.path }
        var candidates: [Candidate] = []
        for file in walker.files {
            candidates.append(contentsOf: classify(file.parsed, at: file.path))
        }
        return Report(
            root: root, envFiles: walker.files.map(\.path), dockerFiles: dockerFiles,
            files: walker.files, candidates: candidates
        )
    }

    /// `scheme://user:pass@host…` — the shape that embeds a secret in a connection string.
    /// Userinfo counts when either half is non-empty: the classic `user:pass`, a bare
    /// password (`redis://:p@h`), or a token as the username (the `https://token@host`
    /// form). A URL without userinfo is an address, not a credential, and an `@` that
    /// merely sits in the path is not userinfo.
    static func isCredentialURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme != nil,
              !(components.percentEncodedHost ?? "").isEmpty
        else { return false }
        let user = components.percentEncodedUser ?? ""
        let password = components.percentEncodedPassword ?? ""
        return !user.isEmpty || !password.isEmpty
    }

    /// One parsed file's credential-shaped lines, in file order. Provider guessing is
    /// `WrapDetect.candidates` verbatim — the same rules `keys wrap` trusts, resolved
    /// through the overlay-aware `Providers.provider` — so a variable the wrap path would
    /// wrap is exactly a `provider_key` here. The other categories sit beside it:
    /// `valueLooksLikeKey` refuses token and URL values by design, which is why they get
    /// their own branches here instead of more WrapDetect rules.
    private static func classify(_ file: EnvFile, at path: String) -> [Candidate] {
        let detected = Dictionary(
            WrapDetect.candidates(in: file, nameHint: nil).map { ($0.index, $0.candidate) },
            uniquingKeysWith: { first, _ in first }
        )
        var out: [Candidate] = []
        for (index, entry) in file.entries where !entry.multiline {
            let value = entry.value
            if GatewayClientToken.looksLikeToken(value) || GrantToken.looksLikeToken(value) {
                out.append(candidate(entry, at: path, category: .wrapped, provider: nil, pair: nil))
                continue
            }
            if let sibling = awsPairSiblings[entry.name], WrapDetect.valueLooksLikeKey(value) {
                // Link the two halves so the report can present them as one credential;
                // a lone half is still reported.
                let pair = WrapDetect.valueLooksLikeKey(file.value(of: sibling) ?? "") ? sibling : nil
                out.append(candidate(entry, at: path, category: .awsPair, provider: nil, pair: pair))
                continue
            }
            if let wrap = detected[index] {
                out.append(candidate(entry, at: path, category: .providerKey, provider: wrap.provider, pair: nil))
                continue
            }
            if isCredentialURL(value) {
                out.append(candidate(entry, at: path, category: .credentialURL, provider: nil, pair: nil))
            }
        }
        return out
    }

    private static func candidate(
        _ entry: EnvFile.Entry, at file: String, category: Category, provider: String?, pair: String?
    ) -> Candidate {
        Candidate(
            name: entry.name, file: file, category: category, provider: provider, pair: pair,
            last4: String(entry.value.suffix(4)), value: entry.value
        )
    }

    /// POSIX `realpath`, the same resolution the root uses. Foundation's
    /// `resolvingSymlinksInPath` leaves `/var` alone, so a walk must not mix spellings.
    private static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` is the canonical root itself or below it. This is the whole
    /// containment rule: anything else is never followed and never read.
    private static func isInside(_ path: String, root: String) -> Bool {
        if path == root { return true }
        return path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Last path component of a canonical path (`realpath` never leaves a trailing slash
    /// except on the filesystem root itself).
    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// The bounded walk. Depth counts directory levels below the root as walked, so a
    /// fourth level is never enumerated; the visited set stops symlink cycles and keeps
    /// an inside alias from walking one directory twice.
    private struct Walk {
        let root: String
        var seenDirectories: Set<String>
        var seenFiles: Set<String> = []
        var files: [EnvScan.ScannedFile] = []

        init(root: String) {
            self.root = root
            self.seenDirectories = [root]
        }

        mutating func walk(directory: String, prefix: String, depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() {
                let entryPath = EnvScan.join(directory, name)
                // Per-entry containment: resolve the entry all the way before touching
                // it, and drop it unless the resolved path is the root or below. A
                // symlink out of the project dies here, unread and unfollowed.
                guard let resolved = EnvScan.resolve(entryPath),
                      EnvScan.isInside(resolved, root: root)
                else { continue }
                // The guard sees the resolved name too, so an env-named symlink pointed
                // at an auth-named file inside the root is still never opened.
                guard !EnvScan.neverOpenNames.contains(name),
                      !EnvScan.neverOpenNames.contains(EnvScan.lastComponent(resolved))
                else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if isDirectory.boolValue {
                    guard depth < EnvScan.maxDepth,
                          !EnvScan.skippedDirectories.contains(name),
                          !EnvScan.skippedDirectories.contains(EnvScan.lastComponent(resolved)),
                          !seenDirectories.contains(resolved)
                    else { continue }
                    seenDirectories.insert(resolved)
                    walk(directory: resolved, prefix: relative, depth: depth + 1)
                } else {
                    read(resolved, named: name, reportedAs: relative)
                }
            }
        }

        private mutating func read(_ resolved: String, named name: String, reportedAs path: String) {
            guard EnvScan.envFileNames.contains(name), !seenFiles.contains(resolved) else { return }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= EnvScan.maxFileBytes
            else { return }
            // Over the cap, not a regular file (a named pipe would block a read), or not
            // readable UTF-8: skipped, never a failed scan.
            guard let text = try? String(contentsOf: URL(fileURLWithPath: resolved), encoding: .utf8) else { return }
            seenFiles.insert(resolved)
            files.append(EnvScan.ScannedFile(path: path, parsed: EnvFile.parse(text)))
        }
    }
}
