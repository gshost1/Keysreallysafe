import CryptoKit
import Darwin
import Foundation

/// One folder on this Mac, as the MCP surface names it: a canonical, symlink-resolved
/// absolute path held in the catalog, and a display label that is the only thing that
/// ever leaves the process. The path is the project's identity and its secret: no tool
/// result, no log line and no analytics report carries it.
enum Project {
    /// 8 hex characters, the text-keyed-row convention (`GrantToken.newID()`'s shape).
    static func newID() -> String {
        Hex.encode(SecureRandom.bytes(4))
    }

    /// The canonical form of a folder, the one spelling a project is stored and matched
    /// by: the symlink-resolved absolute path (POSIX `realpath`), so one folder reached
    /// through a symlink, through `/var` instead of `/private/var`, with a trailing
    /// slash, or as a cwd-relative spelling is ONE project. Foundation's
    /// `resolvingSymlinksInPath` leaves `/var` alone (it even turns `/private/var` back
    /// into `/var`), so this is `realpath`, not Foundation. A nil or empty `folder` is
    /// the process working directory — the MCP server's default project. The folder
    /// must exist and be a directory: a tool-supplied path that does not exist is a
    /// plain usage error before anything is stored. The message stays path-free, since
    /// it can end up in a tool result.
    static func canonicalFolder(_ folder: String?) throws -> String {
        let supplied = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = ((supplied.isEmpty ? FileManager.default.currentDirectoryPath : supplied) as NSString)
            .expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else {
            throw AppError.usage("that project folder does not exist")
        }
        guard isDirectory.boolValue else {
            throw AppError.usage("the project folder is not a folder")
        }
        guard let resolved = realpath(target, nil) else {
            throw AppError.usage("the project folder could not be resolved")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The label one project gets, from its canonical path and the labels earlier rows
    /// in the same pass already took. A folder name no other project shares is the bare
    /// name; when two projects would collide, both become distinguishable in the pinned
    /// format "<folder> (<parent>)", extending to more parent components (grandparent,
    /// and up) until unique. The id is the unreachable last resort for a path with no
    /// parents left to add: it is unique, so the pass always ends with distinct labels.
    static func label(
        forCanonicalPath path: String,
        id: String,
        folderCounts: [String: Int],
        taken: Set<String>
    ) -> String {
        let components = path.split(separator: "/").map(String.init)
        let folder = components.last ?? "/"
        let parents = components.dropLast()
        if folderCounts[folder] ?? 0 <= 1, !taken.contains(folder) {
            return folder
        }
        for depth in 1...max(parents.count, 1) where depth <= parents.count {
            // The `depth` components immediately above the folder, outermost first,
            // so one more level reads as a longer path prefix, not a reshuffle.
            let qualifier = parents[(parents.count - depth)...].joined(separator: "/")
            let label = "\(folder) (\(qualifier))"
            if !taken.contains(label) { return label }
        }
        return "\(folder) (\(id))"
    }

    /// Labels for a whole (small) table in one pass, in the caller's row order. Rows
    /// earlier in the order keep the shorter qualifier, so the result is deterministic
    /// for a given insertion history.
    static func labels(forProjects rows: [(id: String, path: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for path in rows.map(\.path) { counts[folderName(path), default: 0] += 1 }
        var taken: Set<String> = []
        var out: [String] = []
        for row in rows {
            let label = Project.label(forCanonicalPath: row.path, id: row.id, folderCounts: counts, taken: taken)
            taken.insert(label)
            out.append(label)
        }
        return out
    }

    private static func folderName(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        return components.last ?? "/"
    }
}

extension KeysService {
    /// The only place a folder becomes a project: canonicalize it, then get-or-create
    /// the `projects` row. Same folder through a symlink or a `/var` spelling resolves
    /// to one row and one id; the caller gets the id and the label, and the path stays
    /// in this process and the catalog.
    func resolveProject(folder: String? = nil, now: Date = Date()) throws -> CatalogDB.ProjectRow {
        try catalog.upsertProject(canonicalPath: Project.canonicalFolder(folder), now: UTC.iso(now))
    }

    /// The project labels a key's *active* client tokens are bound to — the projects an
    /// agent is using this key in, deduped, in first-issue order. Revoked and expired
    /// tokens are not in use; a null project or a dangling reference contributes
    /// nothing (its joined label is nil), so this never throws for a deleted project.
    func projectLabelsInUse(name: String, now: Date = Date()) throws -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for client in try gatewayClients(name: name) where client.isActive(now: now) {
            guard let label = client.projectLabel, seen.insert(label).inserted else { continue }
            out.append(label)
        }
        return out
    }
}
