import Foundation
import XCTest
@testable import KeysCore

/// VAL-EXPO-001..005: the check_exposure MCP tool, driven through real server
/// frames (error formatter and output guard included) over real temp git
/// repositories built at runtime — the only honest fixture for git facts. The
/// tool answers the one question onboarding needs before importing: were the
/// keys in each env file ever committed? It never reads a file's contents into
/// a result: three read-only booleans per file (gitignored, tracked,
/// in_history), the relative path, and a rotate recommendation for any file
/// that was ever committed. The git binary is a seam, so the degraded answers —
/// missing git, not a repository, a git that hangs — are all driven with fakes;
/// no Keychain, no Touch ID, no network, no real credential, and no test ever
/// touches the machine's real catalog or installed app.
final class CheckExposureToolTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var openaiValue: String { "sk-" + fakeBody + "02" }
    private var groqValue: String { "gsk_" + fakeBody + "03" }
    private var awsSecretValue: String { fakeBody + "AWSSECRET04" }

    // MARK: - Rigs

    /// A control URL no live site answers: exposure never contacts the app, but
    /// the group's shared init takes the seam like every other tool.
    private func deadControl() throws -> URL {
        let control = ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        return control
    }

    /// The onboarding group wired over injected seams, never the machine's real
    /// catalog, installed app or PATH-pinned git — the git seam defaults to the
    /// production PATH resolution, and the degraded tests inject fakes.
    private func roster(
        projectFolder: @escaping () -> String,
        gitExecutable: @escaping () -> String? = { MCPOnboardingTools.gitOnPATH() }
    ) throws -> MCPToolRegistry {
        MCPToolRegistry(groups: [
            MCPOnboardingTools(
                control: try deadControl(), projectFolder: projectFolder, gitExecutable: gitExecutable,
                launch: .neverLaunching
            )
        ])
    }

    /// One tools/call through real server frames — the surface the model sees.
    private func call(
        _ registry: MCPToolRegistry,
        name: String = "check_exposure",
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (isError: Bool, text: String) {
        let argumentsJSON = String(decoding: try JSONValue.data(arguments), as: UTF8.self)
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"\#(name)","arguments":\#(argumentsJSON)}}"#,
        ], registry: registry, file: file, line: line)
        XCTAssertEqual(frames.last, "", file: file, line: line)
        let result = try MCPSession.assertResult(frames[1], id: "t", file: file, line: line)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    private func callJSON(
        _ registry: MCPToolRegistry,
        name: String = "check_exposure",
        arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (isError, text) = try call(registry, name: name, arguments: arguments, file: file, line: line)
        XCTAssertFalse(isError, "an unexpected tool error: \(text)", file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    /// The result's per-file rows, indexed by their (relative) path.
    private func rows(_ result: [String: Any]) throws -> [String: [String: Any]] {
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        var out: [String: [String: Any]] = [:]
        for row in files {
            let path = try XCTUnwrap(row["file"] as? String)
            out[path] = row
        }
        return out
    }

    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// One fixture git command, expected to succeed — a loud failure here means
    /// the fixture broke, not the tool.
    @discardableResult
    private func git(_ arguments: [String], in root: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(MCPOnboardingTools.gitOnPATH(), "git must be on PATH to build a fixture repo")
        let result = try LoginItem.run(binary, ["-C", root.path] + arguments)
        XCTAssertEqual(result.status, 0, "fixture git \(arguments.first ?? "") failed: \(result.stderr)")
        return result
    }

    /// The exposure fixture: a real repository holding the four cases the
    /// contract names. `.env` was committed and then dropped from the index
    /// (in history, no longer tracked), `.env.local` is gitignored and never
    /// committed, `.env.production` is tracked, and `sub/.env` was never
    /// touched. Every value is the runtime fake-body convention; the repo is
    /// created in a temp dir at runtime and committed nowhere else.
    private func makeExposureRepo() throws -> URL {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try write(".env.local\n", to: ".gitignore", under: root)
        try write("GROQ_API_KEY=\(groqValue)\n", to: ".env.local", under: root)
        try write("OPENAI_API_KEY=\(openaiValue)\n", to: ".env.production", under: root)
        try write("AWS_SECRET_ACCESS_KEY=\(awsSecretValue)\n", to: "sub/.env", under: root)

        try git(["init", "-q"], in: root)
        // Local config only: the fixture must commit the same way on every
        // machine, whatever the global config signs or hooks.
        try git(["config", "user.email", "fixture@invalid"], in: root)
        try git(["config", "user.name", "fixture"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        try git(["config", "core.hooksPath", ""], in: root)
        try git(["add", ".env", ".env.production", ".gitignore"], in: root)
        try git(["commit", "-q", "-m", "fixture adds env files"], in: root)
        try git(["rm", "-q", "--cached", ".env"], in: root)
        try git(["commit", "-q", "-m", "fixture stops tracking .env"], in: root)
        return root
    }

    /// A shell script standing in for git: it answers the exposure queries with
    /// fixed facts and appends every argv it was handed to `log` — the pin that
    /// the tool only ever asks check-ignore, ls-files and log, never a command
    /// that could print contents.
    private func recordingGit(log: URL) throws -> String {
        let script = """
        #!/bin/sh
        printf '%s\\n' "git $*" >> "\(log.path)"
        # Skip the global options (-C <dir>, -c <key=value>) to the subcommand.
        while [ "$1" = "-C" ] || [ "$1" = "-c" ]; do shift 2; done
        case "$1" in
          rev-parse) echo true; exit 0 ;;
          check-ignore) exit 1 ;;
          ls-files) exit 0 ;;
          log) exit 0 ;;
        esac
        exit 1
        """
        let url = try TempDir.make().appendingPathComponent("recording-git")
        try Data(script.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A shell script standing in for a hung git: it never answers, so the
    /// per-call bound is the only thing that ends the call.
    private func hangingGit() throws -> String {
        let script = "#!/bin/sh\nsleep 60\n"
        let url = try TempDir.make().appendingPathComponent("hanging-git")
        try Data(script.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - VAL-EXPO-001 (per-file git facts)

    /// The four git facts cases in one real repository: committed-then-removed
    /// (in history, not tracked), gitignored (ignored, never committed),
    /// still-tracked, and never-touched.
    func testGitFactsPerFile() throws {
        let root = try makeExposureRepo()
        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])

        XCTAssertEqual(result["git"] as? String, "available", "a real repository answers real facts")
        let rows = try rows(result)
        XCTAssertEqual(Set(rows.keys), [".env", ".env.local", ".env.production", "sub/.env"])

        let removed = rows[".env"]!
        XCTAssertEqual(removed["gitignored"] as? Bool, false)
        XCTAssertEqual(removed["tracked"] as? Bool, false, "git rm --cached dropped it from the index")
        XCTAssertEqual(removed["in_history"] as? Bool, true, "the add commit is still in history")

        let ignored = rows[".env.local"]!
        XCTAssertEqual(ignored["gitignored"] as? Bool, true)
        XCTAssertEqual(ignored["tracked"] as? Bool, false)
        XCTAssertEqual(ignored["in_history"] as? Bool, false)

        let tracked = rows[".env.production"]!
        XCTAssertEqual(tracked["gitignored"] as? Bool, false)
        XCTAssertEqual(tracked["tracked"] as? Bool, true)
        XCTAssertEqual(tracked["in_history"] as? Bool, true)

        let clean = rows["sub/.env"]!
        XCTAssertEqual(clean["gitignored"] as? Bool, false)
        XCTAssertEqual(clean["tracked"] as? Bool, false)
        XCTAssertEqual(clean["in_history"] as? Bool, false)
    }

    /// An unborn repository (git init, no commits) still answers honestly: no
    /// history exists, so nothing is tracked or in history, while ignore rules
    /// still apply — the uniform exit codes need no special casing.
    func testUnbornRepositoryAnswersHonestZeroes() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try write(".env\n", to: ".gitignore", under: root)
        try write("GROQ_API_KEY=\(groqValue)\n", to: ".env.local", under: root)
        try git(["init", "-q"], in: root)

        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])
        XCTAssertEqual(result["git"] as? String, "available")
        let rows = try rows(result)
        XCTAssertEqual(rows[".env"]?["gitignored"] as? Bool, true, "the ignore rule applies with no commits")
        XCTAssertEqual(rows[".env"]?["tracked"] as? Bool, false)
        XCTAssertEqual(rows[".env"]?["in_history"] as? Bool, false, "no history exists yet")
        XCTAssertEqual(rows[".env.local"]?["tracked"] as? Bool, false)
        XCTAssertEqual(rows[".env.local"]?["in_history"] as? Bool, false)
    }

    // MARK: - VAL-EXPO-002 (rotation recommendation)

    /// The recommendation is present exactly for tracked-or-in-history files
    /// and says, in plain language, to rotate the keys that were in it.
    func testRotationRecommendationExactlyWhenTrackedOrInHistory() throws {
        let root = try makeExposureRepo()
        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])
        let rows = try rows(result)

        for (file, exposed) in [".env": true, ".env.production": true, ".env.local": false, "sub/.env": false] {
            let recommendation = rows[file]?["recommendation"]
            if exposed {
                let text = try XCTUnwrap(recommendation as? String, "\(file) was committed: it carries the recommendation")
                XCTAssertTrue(text.contains("rotate the keys"), "\(file): plain-language rotation advice")
            } else {
                XCTAssertTrue(recommendation is NSNull, "\(file) was never committed: no recommendation")
            }
        }
    }

    // MARK: - VAL-EXPO-003 (never contents or diffs)

    /// The payload is facts only: the two top-level keys, the five per-file
    /// keys, relative paths, and no trace of any file body, value or diff hunk
    /// anywhere in the wire text.
    func testResultCarriesBooleansPathsAndRecommendationOnly() throws {
        let root = try makeExposureRepo()
        let (isError, text) = try call(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])
        XCTAssertFalse(isError, "an unexpected tool error: \(text)")
        let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]

        XCTAssertEqual(Set(result.keys), ["git", "files"], "exactly the two top-level keys")
        XCTAssertEqual(result["git"] as? String, "available")
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 4)
        for row in files {
            XCTAssertEqual(Set(row.keys), ["file", "gitignored", "tracked", "in_history", "recommendation"],
                           "exactly the five per-file keys")
            let path = try XCTUnwrap(row["file"] as? String)
            XCTAssertFalse(path.hasPrefix("/"), "a result path is relative")
        }

        for forbidden in [
            anthropicValue, openaiValue, groqValue, awsSecretValue, fakeBody,
            "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "AWS_SECRET_ACCESS_KEY",
            "+++", "--- ", "@@", "diff --git",
        ] {
            XCTAssertFalse(text.contains(forbidden), "no file body, value or diff hunk in the result: \(forbidden)")
        }
        XCTAssertFalse(text.contains(root.path), "the absolute root never appears in a result")
    }

    /// The commands the tool runs are the three fact queries and the repository
    /// probe, pinned by a fake git that records every argv it is given: per file
    /// exactly check-ignore, ls-files and log --all --oneline on the relative
    /// path, and never show, diff or anything that could print contents.
    func testGitCallsAreFactQueriesOnly() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        let log = root.appendingPathComponent("argv.log")
        let fake = try recordingGit(log: log)

        let result = try callJSON(
            try roster(projectFolder: { root.path }, gitExecutable: { fake }),
            arguments: ["folder": root.path]
        )
        XCTAssertEqual(result["git"] as? String, "available", "the fake answered the probe")
        XCTAssertEqual((result["files"] as? [[String: Any]])?.count, 1)

        let recorded = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(recorded.count, 4, "one repository probe plus the three facts for the one file")
        let hardening = [
            "-c", "core.fsmonitor=false", "-c", "log.showSignature=false",
            "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
        ]
        for (index, expected) in [
            "rev-parse --is-inside-work-tree",
            "check-ignore -- .env",
            "ls-files -- .env",
            "log --all --oneline -- .env",
        ].enumerated() {
            // "git", "-C", "<the canonical root>", the overrides that keep the
            // scanned repository's config from running anything, then "<the
            // fact query on the relative path>".
            let parts = recorded[index].split(separator: " ", maxSplits: 3 + hardening.count).map(String.init)
            XCTAssertEqual(parts.count, 4 + hardening.count, "unexpected argv: \(recorded[index])")
            guard parts.count == 4 + hardening.count else { continue }
            XCTAssertEqual(parts[0], "git")
            XCTAssertEqual(parts[1], "-C", "every call pins the working directory")
            XCTAssertTrue(parts[2].hasPrefix("/"), "the canonical root, absolute for git and never in the result")
            XCTAssertEqual(Array(parts[3..<(3 + hardening.count)]), hardening,
                           "every call overrides the repository's command-running settings")
            XCTAssertEqual(parts[3 + hardening.count], expected, "the exact fact query, on the relative path")
            // The query alone: "log.showSignature=false" in the overrides is not a show.
            for forbidden in ["show", "diff", "blame", "cat ", "checkout", "remote"] {
                XCTAssertFalse(parts[3 + hardening.count].contains(forbidden),
                               "no content-bearing command is ever run: \(recorded[index])")
            }
        }
    }

    // MARK: - VAL-EXPO-004 (works without git, bounded)

    /// Outside a repository the tool still succeeds: a plain statement, per-file
    /// null booleans, and the files still listed — never a guessed fact.
    func testNotARepositoryAnswersPlainlyWithNulls() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try write("GROQ_API_KEY=\(groqValue)\n", to: "sub/.env.local", under: root)

        let started = Date()
        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])
        let elapsed = Date().timeIntervalSince(started)

        let statement = try XCTUnwrap(result["git"] as? String)
        XCTAssertTrue(statement.contains("not a git repository"), "the plain statement says so: \(statement)")
        XCTAssertFalse(statement.contains("/"), "the statement is path-free")
        let rows = try rows(result)
        XCTAssertEqual(Set(rows.keys), [".env", "sub/.env.local"], "the files are still reported")
        for row in rows.values {
            XCTAssertTrue(row["gitignored"] is NSNull, "unknown, not a guess")
            XCTAssertTrue(row["tracked"] is NSNull, "unknown, not a guess")
            XCTAssertTrue(row["in_history"] is NSNull, "unknown, not a guess")
            XCTAssertTrue(row["recommendation"] is NSNull, "never a recommendation on unknown facts")
        }
        XCTAssertLessThan(elapsed, 2, "the refusal is immediate — git answers and is read, never waited on")
    }

    /// A missing git binary (a path that does not exist, and a PATH that holds
    /// no git) degrades the same way, without spawning anything.
    func testMissingGitBinaryAnswersPlainlyWithNulls() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        let missing = root.appendingPathComponent("no-such-git-\(UUID().uuidString)").path

        for (label, seam) in [("a nonexistent path", { missing }), ("no git on PATH", { nil })] {
            let started = Date()
            let result = try callJSON(
                try roster(projectFolder: { root.path }, gitExecutable: seam),
                arguments: ["folder": root.path]
            )
            let elapsed = Date().timeIntervalSince(started)
            let statement = try XCTUnwrap(result["git"] as? String, "\(label): a plain statement")
            XCTAssertTrue(statement.contains("git was not found"), "\(label): the statement says so: \(statement)")
            XCTAssertFalse(statement.contains("/"), "\(label): the statement is path-free")
            let row = try rows(result)[".env"]!
            XCTAssertTrue(row["gitignored"] is NSNull, "\(label): unknown, not a guess")
            XCTAssertTrue(row["tracked"] is NSNull, "\(label): unknown, not a guess")
            XCTAssertTrue(row["in_history"] is NSNull, "\(label): unknown, not a guess")
            XCTAssertLessThan(elapsed, 2, "\(label): nothing is spawned, so nothing can hang")
        }
    }

    /// A git that never answers is bounded by the per-call hard timeout: the
    /// tool still succeeds, with the plain statement and nulls, inside a small
    /// multiple of the bound — never a hang.
    func testHangingGitIsBoundedByTheHardTimeout() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        let hanging = try hangingGit()

        let started = Date()
        let result = try callJSON(
            try roster(projectFolder: { root.path }, gitExecutable: { hanging }),
            arguments: ["folder": root.path]
        )
        let elapsed = Date().timeIntervalSince(started)

        let statement = try XCTUnwrap(result["git"] as? String)
        XCTAssertTrue(statement.contains("did not answer"), "the statement says git never answered: \(statement)")
        let row = try rows(result)[".env"]!
        XCTAssertTrue(row["gitignored"] is NSNull)
        XCTAssertTrue(row["tracked"] is NSNull)
        XCTAssertTrue(row["in_history"] is NSNull)
        XCTAssertGreaterThanOrEqual(elapsed, 1.5, "the bound was actually exercised, not skipped")
        XCTAssertLessThan(elapsed, 8, "bounded: a hung git costs its own timeout, never a hang")
    }

    // MARK: - VAL-EXPO-005 (the same safe discovery as scan)

    /// Discovery is the shared EnvScan pass, verbatim: a `.env` reached only
    /// through a symlink out of the root is never reported, and the file list
    /// check_exposure reports is exactly the one scan_project reports.
    func testSymlinkedOutEnvIsNotReportedAndDiscoveryMatchesScan() throws {
        let root = try makeExposureRepo()
        // The fixture's gitignored `.env.local` gives way to the symlink: the
        // gitignored row is pinned by the dedicated facts tests, this one pins
        // discovery.
        try fm.removeItem(at: root.appendingPathComponent(".env.local"))
        let outside = try TempDir.make()
        try write("OUTSIDE_KEY=\(anthropicValue)\n", to: ".env", under: outside)
        try write("OUTSIDE_KEY=\(anthropicValue)\n", to: "inside/.env", under: outside)
        // A file symlink out of the root wearing an env name...
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent(".env.local").path,
            withDestinationPath: outside.appendingPathComponent(".env").path
        )
        // ...and a directory symlink out of the root holding one.
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("linked").path,
            withDestinationPath: outside.appendingPathComponent("inside").path
        )

        let registry = try roster(projectFolder: { root.path })
        let exposure = try callJSON(registry, arguments: ["folder": root.path])
        let scan = try callJSON(registry, name: "scan_project", arguments: ["folder": root.path])

        let exposureFiles = (exposure["files"] as? [[String: Any]])?.compactMap { $0["file"] as? String }
        XCTAssertEqual(exposureFiles, [".env", ".env.production", "sub/.env"],
                       "the symlinked-out .env files never appear")
        XCTAssertEqual(scan["env_files"] as? [String], exposureFiles,
                       "exposure and scan answer from the same discovery")
    }

    // MARK: - The folder input (the scan_project parity)

    /// The omitted folder is the projectFolder seam, and a supplied folder that is a
    /// folder INSIDE the session working directory wins over it; unusable folders are
    /// the same path-free errors as scan_project (VAL-O-006: an outside folder is
    /// refused below, so the pin an outside folder used to win no longer holds).
    func testFolderInputMatchesScanProject() throws {
        let seamRoot = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: seamRoot)

        let bySeam = try callJSON(try roster(projectFolder: { seamRoot.path }), arguments: [:])
        XCTAssertEqual(Set((try rows(bySeam)).keys), [".env"], "the seam answers when no folder came")

        // A subfolder of the seam folder: inside the session working directory's
        // subtree, so the argument is honoured.
        let askedRoot = seamRoot.appendingPathComponent("nested", isDirectory: true)
        try write("GROQ_API_KEY=\(groqValue)\n", to: "deep/.env", under: askedRoot)
        let byArgument = try callJSON(
            try roster(projectFolder: { seamRoot.path }), arguments: ["folder": askedRoot.path]
        )
        XCTAssertEqual(Set((try rows(byArgument)).keys), ["deep/.env"], "the argument wins over the seam")

        let missing = seamRoot.appendingPathComponent("no-such-\(UUID().uuidString)").path
        let file = seamRoot.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        for (label, arguments, message) in [
            ("missing folder", ["folder": missing], "that project folder does not exist"),
            ("a plain file", ["folder": file.path], "the project folder is not a folder"),
            ("not a string", ["folder": 42] as [String: Any], "folder must be a string"),
        ] {
            let (isError, text) = try call(try roster(projectFolder: { seamRoot.path }), arguments: arguments)
            XCTAssertTrue(isError, "\(label): a plain refusal, not an exposure report")
            XCTAssertEqual(text, message, "\(label): the exact path-free message")
        }
    }

    // MARK: - VAL-O-006 (folders outside the session working directory are refused)

    /// The exposure tool takes the same folder input as the scan, so it shares the
    /// restriction: an outside folder is refused with the scan's path-free error.
    /// Failed pre-fix: the outside folder was scanned and answered (isError false).
    func testAnOutsideFolderIsRefusedWithAPathFreeError() throws {
        let seamRoot = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: seamRoot)
        let outside = try TempDir.make()
        try write("OUTSIDE_KEY=\(groqValue)\n", to: ".env", under: outside)

        let (isError, text) = try call(
            try roster(projectFolder: { seamRoot.path }), arguments: ["folder": outside.path]
        )
        XCTAssertTrue(isError, "an outside folder is a plain refusal, not an exposure report")
        XCTAssertEqual(text, "the folder must be this session's working directory or inside it",
                       "the scan's exact path-free message")
        XCTAssertFalse(text.contains("/"), "the message carries no filesystem tell")
    }

    /// The disk root and the home directory are refused exactly like the scan's —
    /// the same containment check, deliberately not run pre-fix (the pre-fix
    /// behavior of "/" or "~" is to walk them; decision recorded in the mission
    /// log).
    func testTheRootAndTheHomeFolderAreRefused() throws {
        let seamRoot = try TempDir.make()
        let registry = try roster(projectFolder: { seamRoot.path })
        for (label, folder) in [("the disk root", "/"), ("the home directory", "~")] {
            let (isError, text) = try call(registry, arguments: ["folder": folder])
            XCTAssertTrue(isError, "\(label): a plain refusal, not an exposure report")
            XCTAssertEqual(text, "the folder must be this session's working directory or inside it",
                          "\(label): the exact path-free message")
        }
    }

    // MARK: - The scanned repository's config never runs a command

    /// A repository is a folder someone else may have written: an archive, a
    /// synced folder, a nested checkout. Its .git/config can name commands that
    /// git runs "in the usual way" (man git, SECURITY), and safe.directory does
    /// not help when the user owns the extracted folder. check_exposure is the
    /// read-only check agents are told to use instead of git, so none of those
    /// commands may run. `core.fsmonitor` is consulted by every query that reads
    /// the index; check-ignore is the first. Failed pre-fix: the marker existed.
    func testARepositoryConfiguredFsmonitorNeverRuns() throws {
        let root = try makeExposureRepo()
        let marker = try TempDir.make().appendingPathComponent("fsmonitor-ran")
        // Set last: the fixture's own add and commit must not trip it.
        try git(["config", "core.fsmonitor", "touch '\(marker.path)'; false"], in: root)

        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])

        XCTAssertFalse(fm.fileExists(atPath: marker.path), "the repository's core.fsmonitor command ran")
        try assertFixtureFacts(result)
    }

    /// `log.showSignature` in the repository config makes `git log` verify every
    /// signed commit it prints with `gpg.program`, which the same config names.
    /// The signed commit is a hand-written object with a dummy signature, so no
    /// key or real gpg is involved. Failed pre-fix: the marker existed.
    func testARepositoryConfiguredSignatureProgramNeverRuns() throws {
        let root = try makeExposureRepo()
        let scratch = try TempDir.make()
        let marker = scratch.appendingPathComponent("gpg-ran")
        let fakeGPG = scratch.appendingPathComponent("fake-gpg")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".utf8).write(to: fakeGPG)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

        // A root commit carrying a gpgsig header over the current tree, so it
        // touches every tracked env file and `log -- <file>` prints it.
        let tree = try git(["rev-parse", "HEAD^{tree}"], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = scratch.appendingPathComponent("signed-commit")
        let signedCommit = [
            "tree \(tree)",
            "author fixture <fixture@invalid> 1700000000 +0000",
            "committer fixture <fixture@invalid> 1700000000 +0000",
            "gpgsig -----BEGIN PGP SIGNATURE-----",
            " ",
            " iQEzBAABCAAdFIXTURE",
            " -----END PGP SIGNATURE-----",
            "",
            "fixture signed commit",
            "",
        ].joined(separator: "\n")
        try Data(signedCommit.utf8).write(to: object)
        let commit = try git(["hash-object", "-t", "commit", "-w", object.path], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-ref", "refs/heads/signed", commit], in: root)
        try git(["config", "log.showSignature", "true"], in: root)
        try git(["config", "gpg.program", fakeGPG.path], in: root)

        let result = try callJSON(try roster(projectFolder: { root.path }), arguments: ["folder": root.path])

        XCTAssertFalse(fm.fileExists(atPath: marker.path), "the repository's gpg.program ran")
        try assertFixtureFacts(result)
    }

    /// git runs with a fixed environment: no system or global config, no lazy
    /// fetch, and nothing inherited from the MCP process beyond PATH and HOME.
    /// An inherited GIT_DIR, GIT_CONFIG_COUNT or GIT_SSH_COMMAND would otherwise
    /// point git at another repository or add config the overrides do not name.
    /// The fake git dumps its environment; PATH keeps only absolute entries.
    func testGitRunsWithAMinimalEnvironment() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        let dump = try TempDir.make().appendingPathComponent("env.txt")
        let fake = try TempDir.make().appendingPathComponent("env-git")
        try Data("#!/bin/sh\n/usr/bin/env > '\(dump.path)'\necho true\nexit 0\n".utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let inherited = ["GIT_DIR", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_SSH_COMMAND"]
        for name in inherited { setenv(name, "inherited-\(name)", 1) }
        let savedPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "relative-entry:\(savedPath ?? "/usr/bin:/bin")", 1)
        defer {
            for name in inherited { unsetenv(name) }
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }

        _ = try callJSON(try roster(projectFolder: { root.path }, gitExecutable: { fake.path }),
                         arguments: ["folder": root.path])

        var seen: [String: String] = [:]
        for line in try String(contentsOf: dump, encoding: .utf8).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            seen[pair[0]] = pair.count > 1 ? pair[1] : ""
        }
        // /bin/sh adds PWD, SHLVL and _ on its own; they never came from Keysrs.
        let fromShell: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        XCTAssertEqual(Set(seen.keys).subtracting(fromShell),
                       ["PATH", "HOME", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_NO_LAZY_FETCH"],
                       "git sees only the fixed environment")
        XCTAssertEqual(seen["GIT_CONFIG_NOSYSTEM"], "1")
        XCTAssertEqual(seen["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(seen["GIT_NO_LAZY_FETCH"], "1")
        XCTAssertFalse((seen["PATH"] ?? "").split(separator: ":").contains { !$0.hasPrefix("/") },
                       "PATH keeps absolute entries only: \(seen["PATH"] ?? "")")
    }

    /// The facts makeExposureRepo builds, unchanged by the hardening.
    private func assertFixtureFacts(
        _ result: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(result["git"] as? String, "available", file: file, line: line)
        let rows = try rows(result)
        for (path, facts) in [
            ".env": (false, false, true), ".env.local": (true, false, false),
            ".env.production": (false, true, true), "sub/.env": (false, false, false),
        ] {
            let row = try XCTUnwrap(rows[path], file: file, line: line)
            XCTAssertEqual(row["gitignored"] as? Bool, facts.0, "\(path) gitignored", file: file, line: line)
            XCTAssertEqual(row["tracked"] as? Bool, facts.1, "\(path) tracked", file: file, line: line)
            XCTAssertEqual(row["in_history"] as? Bool, facts.2, "\(path) in_history", file: file, line: line)
        }
    }

    // MARK: - gitOnPATH resolves absolute entries only

    /// A relative PATH entry (".", "node_modules/.bin") resolves against the MCP
    /// process's working directory, which is the project folder, so a `git` the
    /// repository ships would run. The entry here is a relative path to a temp
    /// dir holding a fake git, placed ahead of the real PATH, so the test needs
    /// no chdir. Failed pre-fix: gitOnPATH returned the fake.
    func testGitOnPATHSkipsRelativeEntries() throws {
        let fakeDir = try TempDir.make().resolvingSymlinksInPath()
        let fake = fakeDir.appendingPathComponent("git")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).resolvingSymlinksInPath().path
        let depth = cwd.split(separator: "/").count
        let relative = String(repeating: "../", count: depth) + String(fakeDir.path.dropFirst())
        XCTAssertFalse(relative.hasPrefix("/"))
        XCTAssertTrue(fm.isExecutableFile(atPath: relative + "/git"), "the relative entry reaches the fake")

        let saved = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(relative):\(saved ?? "/usr/bin:/bin")", 1)
        defer {
            if let saved { setenv("PATH", saved, 1) } else { unsetenv("PATH") }
        }

        let resolved = MCPOnboardingTools.gitOnPATH()
        XCTAssertNotNil(resolved, "the real git on the absolute entries still resolves")
        XCTAssertTrue(resolved?.hasPrefix("/") ?? false, "only an absolute entry may supply git: \(resolved ?? "nil")")
        XCTAssertNotEqual(resolved.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, fake.path,
                          "the relative entry's fake git was chosen")
    }
}
