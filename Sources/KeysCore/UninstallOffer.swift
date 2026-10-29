import Darwin
import Foundation

/// The `keys autostart --remove` unwrap offer (architecture §2.10). The removal is
/// the only uninstall-performing code path (`Installer.uninstall`), and a wrapped
/// env file whose tokens die with the install is the silent bricking this offer
/// exists to prevent — so before anything is removed the recorded `wrapped_files`
/// are listed and the user is asked an explicit question. Yes unwraps every recorded
/// project through the running app (the per-project `/api/unwrap` flow, one Touch ID
/// per project, gone files tolerated as stale records) BEFORE the removal; when the
/// app is not running the unwrap's control sentence propagates and the removal never
/// happens — the user starts Keysrs.app and retries. No proceeds with a plain
/// statement that the files were left holding tokens that no longer work. No records
/// means no offer at all: the command behaves byte-for-byte as it did before.
///
/// Every seam is a closure so tests script the answer and inject the removal — the
/// live `Installer.uninstall` operates on the real ~/Library/Application
/// Support/Keysreallysafe and must never run from a test (owner directive
/// 2026-10-28).
struct UninstallOfferRunner {
    /// The explicit question, on stderr like keys wrap's confirm. Pinned.
    static let question = "Unwrap these files first? [y/N] "

    /// The plain statement printed whenever the removal proceeds without
    /// unwrapping (a decline, or no terminal to ask).
    static let leftBehindStatement =
        "leaving the wrapped files as they are: they hold gateway tokens that no longer work "
            + "without Keysrs — run keys unwrap <file> with Keysrs.app open if you still need the real values"

    /// The recorded wrapped files as (path, project) rows, straight from the catalog
    /// beside the install. The offer lists the paths and groups the rows by project,
    /// so the unwrap is ONE call per project; `project` is a projects.id the unwrap
    /// seam resolves.
    var wrappedFiles: () throws -> [(path: String, project: String)]
    /// Whether stdin is a terminal. The offer never defaults to yes: without a tty it
    /// cannot ask, so it proceeds with the explicit statement only (the keys wrap
    /// guard precedent).
    var isInteractive: () -> Bool
    /// The explicit question; tests script the yes/no (the WrapRunner precedent).
    var confirm: () -> Bool
    /// Unwraps one project (its projects.id) through the running app — the per-project
    /// form, one Touch ID for every file the project wraps, a record whose file was
    /// deleted since wrap cleared as stale. A throw — the not-running control sentence
    /// above all — aborts the whole removal.
    var unwrap: (String) throws -> Void
    /// The removal itself, injected in tests (`Installer.live.uninstall()` live).
    var uninstall: () throws -> Void
    /// Statements and the file list; live writes to stderr so stdout keeps its one
    /// line ("removed login item …").
    var report: (String) -> Void

    func run() throws {
        let rows = try wrappedFiles()
        guard !rows.isEmpty else {
            try uninstall()
            return
        }
        report("wrapped env files recorded for this installation:")
        for row in rows { report("  \(row.path)") }
        if isInteractive(), confirm() {
            // Unwrap everything BEFORE anything is removed, one call per project: the
            // per-project form tolerates a record whose file is gone (it clears the
            // stale row and moves on) where a per-file call would abort the removal on
            // the first missing file. A failure partway — or the app not running at
            // all — still propagates and the removal never runs, so nothing is left
            // holding a token whose app was just deleted.
            var seen: Set<String> = []
            for row in rows where seen.insert(row.project).inserted {
                try unwrap(row.project)
            }
        } else {
            report(Self.leftBehindStatement)
        }
        try uninstall()
    }

    /// The catalog's recorded wrapped files, read-only: a missing catalog (an
    /// install that predates the records) answers "none" without creating the file.
    /// Rows, not paths — the offer groups them by project for the one-prompt-per-
    /// project unwrap.
    static func recordedWrappedFiles(catalog: URL) throws -> [(path: String, project: String)] {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }
        return try CatalogDB(path: catalog).listWrappedFiles().map { ($0.path, $0.project) }
    }

    /// The live seams for `keys autostart --remove`. The unwrap connection is the
    /// same plain `ControlClient.connect()` keys wrap and keys unwrap use: no
    /// auto-launch, exit 6 with the control sentence when the app is down.
    static func live(out: @escaping (String) -> Void = { print($0); fflush(stdout) }) -> UninstallOfferRunner {
        UninstallOfferRunner(
            wrappedFiles: { try recordedWrappedFiles(catalog: Paths.catalogDB) },
            isInteractive: { isatty(STDIN_FILENO) != 0 },
            confirm: {
                fputs(question, stderr)
                fflush(stderr)
                let answer = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return answer == "y" || answer == "yes"
            },
            unwrap: { project in
                // The per-project form: the projects row holds the project's canonical
                // folder, and the runner's projectFolder seam carries it — one prompt
                // unwraps every file the project wraps, gone files included. A project
                // id with no row (possible only through raw SQL) cannot be unwrapped,
                // and refusing is the safe direction: the removal must not leave files
                // behind that nothing can restore.
                guard let row = try CatalogDB(path: Paths.catalogDB).project(id: project) else {
                    throw AppError.notFound("project \(project)")
                }
                let runner = UnwrapRunner(
                    connect: { try ControlClient.connect() }, out: out, projectFolder: { row.path }
                )
                _ = try runner.run(path: nil)
            },
            uninstall: { try Installer.live.uninstall() },
            report: { fputs($0 + "\n", stderr) }
        )
    }
}
