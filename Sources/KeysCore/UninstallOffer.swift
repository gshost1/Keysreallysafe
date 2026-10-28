import Darwin
import Foundation

/// The `keys autostart --remove` unwrap offer (architecture §2.10). The removal is
/// the only uninstall-performing code path (`Installer.uninstall`), and a wrapped
/// env file whose tokens die with the install is the silent bricking this offer
/// exists to prevent — so before anything is removed the recorded `wrapped_files`
/// are listed and the user is asked an explicit question. Yes unwraps each file
/// through the running app (the `/api/unwrap` flow) BEFORE the removal; when the app
/// is not running the unwrap's control sentence propagates and the removal never
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

    /// The recorded wrapped files, straight from the catalog beside the install.
    var wrappedFiles: () throws -> [String]
    /// Whether stdin is a terminal. The offer never defaults to yes: without a tty it
    /// cannot ask, so it proceeds with the explicit statement only (the keys wrap
    /// guard precedent).
    var isInteractive: () -> Bool
    /// The explicit question; tests script the yes/no (the WrapRunner precedent).
    var confirm: () -> Bool
    /// Unwraps one file through the running app. A throw — the not-running control
    /// sentence above all — aborts the whole removal.
    var unwrap: (String) throws -> Void
    /// The removal itself, injected in tests (`Installer.live.uninstall()` live).
    var uninstall: () throws -> Void
    /// Statements and the file list; live writes to stderr so stdout keeps its one
    /// line ("removed login item …").
    var report: (String) -> Void

    func run() throws {
        let files = try wrappedFiles()
        guard !files.isEmpty else {
            try uninstall()
            return
        }
        report("wrapped env files recorded for this installation:")
        for file in files { report("  \(file)") }
        if isInteractive(), confirm() {
            // Unwrap everything BEFORE anything is removed. A failure partway — or
            // the app not running at all — propagates and the removal never runs, so
            // no file is left holding a token whose app was just deleted.
            for file in files { try unwrap(file) }
        } else {
            report(Self.leftBehindStatement)
        }
        try uninstall()
    }

    /// The catalog's recorded wrapped files, read-only: a missing catalog (an
    /// install that predates the records) answers "none" without creating the file.
    static func recordedWrappedFiles(catalog: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }
        return try CatalogDB(path: catalog).listWrappedFiles().map(\.path)
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
            unwrap: { path in
                let runner = UnwrapRunner(connect: { try ControlClient.connect() }, out: out)
                _ = try runner.run(path: path)
            },
            uninstall: { try Installer.live.uninstall() },
            report: { fputs($0 + "\n", stderr) }
        )
    }
}
