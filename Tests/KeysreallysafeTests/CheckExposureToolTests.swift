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
        ControlFile.url(beside: try TempDir.make().appendingPathComponent("catalog.db"))
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
        case "$3" in
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
        for (index, expected) in [
            "rev-parse --is-inside-work-tree",
            "check-ignore -- .env",
            "ls-files -- .env",
            "log --all --oneline -- .env",
        ].enumerated() {
            // "git", "-C", "<the canonical root>", "<the fact query on the relative path>"
            let parts = recorded[index].split(separator: " ", maxSplits: 3).map(String.init)
            XCTAssertEqual(parts[0], "git")
            XCTAssertEqual(parts[1], "-C", "every call pins the working directory")
            XCTAssertTrue(parts[2].hasPrefix("/"), "the canonical root, absolute for git and never in the result")
            XCTAssertEqual(parts[3], expected, "the exact fact query, on the relative path")
            for forbidden in ["show", "diff", "blame", "cat ", "checkout", "remote"] {
                XCTAssertFalse(recorded[index].contains(forbidden),
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

    /// The omitted folder is the projectFolder seam, and a supplied folder wins
    /// over it; unusable folders are the same path-free errors as scan_project.
    func testFolderInputMatchesScanProject() throws {
        let seamRoot = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: seamRoot)

        let bySeam = try callJSON(try roster(projectFolder: { seamRoot.path }), arguments: [:])
        XCTAssertEqual(Set((try rows(bySeam)).keys), [".env"], "the seam answers when no folder came")

        let askedRoot = try TempDir.make()
        try write("GROQ_API_KEY=\(groqValue)\n", to: ".env", under: askedRoot)
        let byArgument = try callJSON(
            try roster(projectFolder: { seamRoot.path }), arguments: ["folder": askedRoot.path]
        )
        XCTAssertEqual(Set((try rows(byArgument)).keys), [".env"], "the argument wins over the seam")

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
}
