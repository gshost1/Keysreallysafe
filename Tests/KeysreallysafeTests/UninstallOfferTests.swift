import Foundation
import XCTest
@testable import KeysCore

/// VAL-UNIN-001..005: the `keys autostart --remove` unwrap offer. Every seam is
/// injected — the prompt, the tty check, the catalog read, the unwrap and THE
/// REMOVAL itself: `Installer.uninstall` operates on the REAL
/// ~/Library/Application Support/Keysreallysafe, so no test may ever execute it
/// (owner directive 2026-10-28); the rig records an "uninstall" event instead.
/// The one test that drives a real unwrap does it over a temp control file beside
/// a temp catalog behind the fail-closed guard, with a fake presence gate and a
/// fake secret store, exactly like UnwrapTests. Fake key bodies are built at
/// runtime (NEVER-REAL) and never appear in any report.
final class UninstallOfferTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var openaiValue: String { "sk-" + fakeBody + "02" }
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }

    /// What one scripted run did, in order: "unwrap:<project>" per accepted per-project
    /// unwrap and "uninstall" for the removal — the event log is how a test proves the
    /// removal came last, or never came.
    private final class Recorder {
        var events: [String] = []
        var reports: [String] = []
        var confirmCalls = 0
    }

    private func makeRunner(
        rows: [(path: String, project: String)],
        interactive: Bool = true,
        answer: Bool = false,
        recorder: Recorder,
        unwrapError: @escaping (String) -> Error? = { _ in nil }
    ) -> UninstallOfferRunner {
        UninstallOfferRunner(
            wrappedFiles: { rows },
            isInteractive: { interactive },
            confirm: {
                recorder.confirmCalls += 1
                return answer
            },
            unwrap: { project in
                recorder.events.append("unwrap:\(project)")
                if let error = unwrapError(project) { throw error }
            },
            uninstall: { recorder.events.append("uninstall") },
            report: { recorder.reports.append($0) }
        )
    }

    // MARK: - VAL-UNIN-003 (no records: byte-identical to today)

    /// No wrapped files recorded: no offer, no prompt, no extra output — the removal
    /// runs exactly as it did before the offer existed.
    func testNoRecordsRemovesWithoutAnyOffer() throws {
        let rec = Recorder()
        let runner = makeRunner(rows: [], recorder: rec)

        try runner.run()

        XCTAssertEqual(rec.events, ["uninstall"], "the removal runs, and nothing else")
        XCTAssertTrue(rec.reports.isEmpty, "no listing, no statement — byte-identical output")
        XCTAssertEqual(rec.confirmCalls, 0, "the question is never asked")
    }

    // MARK: - VAL-UNIN-001 (the offer lists and asks, never silent)

    /// With records: every path is printed BEFORE the explicit question, and nothing
    /// is removed before the answer.
    func testOfferListsEveryPathBeforeAsking() throws {
        let rows: [(path: String, project: String)] = [
            ("/tmp/proj/.env", "proj"), ("/tmp/proj/sub/.env.local", "proj"),
        ]
        let rec = Recorder()
        var runner = makeRunner(rows: rows, answer: false, recorder: rec)
        let ask = runner.confirm
        runner.confirm = {
            for row in rows {
                XCTAssertTrue(rec.reports.contains { $0.contains(row.path) },
                              "the path is listed before the question: \(row.path)")
            }
            XCTAssertFalse(rec.events.contains("uninstall"), "nothing is removed before the answer")
            XCTAssertTrue(rec.events.isEmpty, "nothing is unwrapped before the answer")
            return ask()
        }

        try runner.run()

        XCTAssertEqual(rec.confirmCalls, 1, "the explicit question was asked once")
        XCTAssertEqual(rec.events, ["uninstall"])
    }

    /// The question is the pinned explicit one, asked on stderr like keys wrap's
    /// confirm — never a default yes.
    func testTheQuestionIsThePinnedExplicitOne() {
        XCTAssertEqual(UninstallOfferRunner.question, "Unwrap these files first? [y/N] ")
    }

    // MARK: - VAL-UNIN-002 (accept unwraps first; decline states what is left)

    /// Yes: every recorded project is unwrapped through the app first, one call per
    /// distinct project, and only then does the removal proceed.
    func testAcceptUnwrapsEveryProjectBeforeTheRemoval() throws {
        let rows: [(path: String, project: String)] = [
            ("/tmp/a/.env", "a"), ("/tmp/b/.env", "b"),
        ]
        let rec = Recorder()
        let runner = makeRunner(rows: rows, answer: true, recorder: rec)

        try runner.run()

        XCTAssertEqual(rec.events, ["unwrap:a", "unwrap:b", "uninstall"],
                       "both projects unwrap before the removal")
    }

    /// No: the removal still proceeds, with a plain statement that the wrapped files
    /// were left holding tokens that no longer work.
    func testDeclineProceedsWithTheDeadTokenStatement() throws {
        let rec = Recorder()
        let runner = makeRunner(rows: [("/tmp/a/.env", "a")], answer: false, recorder: rec)

        try runner.run()

        XCTAssertEqual(rec.events, ["uninstall"], "the removal proceeds on a decline")
        XCTAssertTrue(rec.events.filter { $0.hasPrefix("unwrap:") }.isEmpty, "nothing was unwrapped")
        let statement = rec.reports.first { $0.contains("no longer work") }
        XCTAssertNotNil(statement, "the plain statement about the dead tokens: \(rec.reports)")
    }

    // MARK: - VAL-UNIN-004 (the non-interactive guard)

    /// No tty: the question cannot be asked, so the offer NEVER defaults to yes —
    /// nothing is unwrapped blindly; the removal proceeds with the explicit statement
    /// only (the keys wrap guard precedent).
    func testNonInteractiveNeverUnwrapsBlindly() throws {
        let rows: [(path: String, project: String)] = [("/tmp/a/.env", "a")]
        let rec = Recorder()
        let runner = makeRunner(rows: rows, interactive: false, answer: true, recorder: rec)

        try runner.run()

        XCTAssertEqual(rec.confirmCalls, 0, "no question without a terminal")
        XCTAssertEqual(rec.events, ["uninstall"], "the removal proceeds without unwrapping")
        XCTAssertTrue(rec.reports.contains { $0.contains("/tmp/a/.env") }, "the paths are still listed")
        XCTAssertTrue(rec.reports.contains { $0.contains("no longer work") },
                      "the explicit statement is printed: \(rec.reports)")
    }

    // MARK: - VAL-UNIN-005 (accept + app down aborts the removal)

    /// The user says yes but the app is not running: the control sentence surfaces
    /// with its exit code 6 and the removal NEVER runs — nothing is bricked silently;
    /// start Keysrs.app and retry.
    func testAppDownAfterAcceptAbortsTheRemoval() throws {
        let rec = Recorder()
        let sentence = "no running Keysrs site owns the gateway; open Keysrs.app or run keys dashboard, then retry"
        let runner = makeRunner(
            rows: [("/tmp/a/.env", "a")], answer: true, recorder: rec,
            unwrapError: { _ in AppError.siteUnavailable(sentence) }
        )

        XCTAssertThrowsError(try runner.run()) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected the control sentence, got \(error)")
            }
            XCTAssertEqual(message, sentence)
            XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6, "keys wrap's exit code for a missing app")
        }
        XCTAssertFalse(rec.events.contains("uninstall"), "the removal was aborted — nothing bricked")
    }

    /// A failure partway through the projects aborts the removal too: a half-unwrapped
    /// set with the install already gone is exactly the silent bricking this offer
    /// exists to prevent.
    func testAFailedUnwrapMidListAlsoAborts() throws {
        let rec = Recorder()
        let runner = makeRunner(
            rows: [("/tmp/a/.env", "a"), ("/tmp/b/.env", "b")], answer: true, recorder: rec,
            unwrapError: { $0 == "b" ? AppError.http("connection dropped") : nil }
        )

        XCTAssertThrowsError(try runner.run())
        XCTAssertEqual(rec.events, ["unwrap:a", "unwrap:b"],
                       "the second project's unwrap was attempted and failed…")
        XCTAssertFalse(rec.events.contains("uninstall"), "…so the removal never ran")
    }

    // MARK: - The catalog read (no catalog is created to answer "none")

    /// The wrapped-files read never creates a catalog: an installation that predates
    /// the records has no DB file, and the offer must not leave one behind.
    func testRecordedWrappedFilesDoesNotCreateAMissingCatalog() throws {
        let dir = try TempDir.make()
        let catalog = dir.appendingPathComponent("catalog.db")
        try assertNotProductionPath(catalog)

        let rows = try UninstallOfferRunner.recordedWrappedFiles(catalog: catalog)

        XCTAssertTrue(rows.isEmpty, "no records means no rows")
        XCTAssertFalse(fm.fileExists(atPath: catalog.path), "no catalog file was created")
    }

    /// With a catalog, the read returns every recorded row — path AND project, the
    /// fields the offer groups by (and the fail-closed guard runs on the rig's temp
    /// location like every control-channel test).
    func testRecordedWrappedFilesListsTheCatalogsRows() throws {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        try db.recordWrappedFile(path: dir.appendingPathComponent("p/.env").path,
                                 project: "p", at: "2026-10-28T00:00:00Z")
        try db.recordWrappedFile(path: dir.appendingPathComponent("q/.env.local").path,
                                 project: "q", at: "2026-10-28T00:00:00Z")

        let rows = try UninstallOfferRunner.recordedWrappedFiles(catalog: db.path)

        XCTAssertEqual(rows.map(\.project), ["p", "q"], "the rows carry the project to group by")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.path.hasSuffix(".env") || $0.path.hasSuffix(".env.local") })
    }

    // MARK: - The accept path drives the real unwrap flow (temp control channel only)

    /// The in-process app for the end-to-end tests: a real APIHandler over a temp
    /// catalog behind a recording loopback server, `control.json` beside that same
    /// catalog — the UnwrapTests rig shape, guarded by the fail-closed check on every
    /// control-channel path.
    private struct OfferSite {
        let db: CatalogDB
        let dir: URL
        let service: KeysService
        let gate: RecordingPresenceGate
        let handler: APIHandler
        let server: LoopbackHTTPServer
        let control: URL
    }

    private func makeOfferSite() throws -> OfferSite {
        let (db, dir) = try makeDB()
        try assertNotProductionPath(db.path)
        let (service, gate) = makeGatedService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        addTeardownBlock { server.stop() }
        let control = ControlFile.url(beside: db.path)
        // Both isolation guards: the onboarding-side path check and the shared
        // configuration guard, before any write.
        try assertNotProductionPath(control)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        return OfferSite(db: db, dir: dir, service: service, gate: gate, handler: handler,
                         server: server, control: control)
    }

    /// End to end through the seams the command actually uses: the records come from
    /// a temp catalog, the unwrap goes through UnwrapRunner over a temp control file
    /// to an in-process app with fake presence and a fake secret store, and the
    /// removal is the injected recorder — the real Installer.uninstall never runs in
    /// a test (owner directive 2026-10-28).
    func testAcceptUnwrapsThroughTheAppBeforeTheInjectedRemoval() throws {
        let site = try makeOfferSite()
        let project = site.dir.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let original = "OPENAI_API_KEY=\(openaiValue)\nANTHROPIC_API_KEY=\(anthropicValue)\n"
        let env = project.appendingPathComponent(".env")
        try Data(original.utf8).write(to: env)
        let imported = try site.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        let rows = (imported["variables"] as? [Any])?.compactMap(JSONValue.object) ?? []
        let openaiKey = try XCTUnwrap(rows.first { JSONValue.string($0["variable"]) == "OPENAI_API_KEY" }
            .flatMap { JSONValue.string($0["key"]) })
        let token = try XCTUnwrap(EnvFile.parse(try String(contentsOf: env, encoding: .utf8)).value(of: "OPENAI_API_KEY"))
        XCTAssertTrue(token.hasPrefix("ksfc_"), "the file was wrapped")
        let promptsBefore = site.gate.reasons.count

        let rec = Recorder()
        let runner = UninstallOfferRunner(
            wrappedFiles: { try UninstallOfferRunner.recordedWrappedFiles(catalog: site.db.path) },
            isInteractive: { true },
            confirm: { rec.confirmCalls += 1; return true },
            unwrap: { projectID in
                rec.events.append("unwrap:\(projectID)")
                let folder = try XCTUnwrap(try site.db.project(id: projectID)?.path)
                let unwrap = UnwrapRunner(
                    connect: { try ControlClient.connect(control: site.control) },
                    out: { _ in },
                    projectFolder: { folder }
                )
                _ = try unwrap.run(path: nil)
            },
            uninstall: { rec.events.append("uninstall") },
            report: { rec.reports.append($0) }
        )

        try runner.run()

        XCTAssertEqual(rec.events.count, 2, "one per-project unwrap, then the removal")
        XCTAssertTrue(rec.events[0].hasPrefix("unwrap:"), "the unwrap came first")
        XCTAssertEqual(rec.events[1], "uninstall", "the removal came last")
        XCTAssertEqual(try Data(contentsOf: env), Data(original.utf8),
                       "the file was restored byte-for-byte before the removal")
        XCTAssertEqual(site.gate.reasons.count - promptsBefore, 1,
                       "the unwrap's one Touch ID — the per-project form prompts once")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0, "the record was cleared by the unwrap")
        if case .allowed = site.service.authorizeGatewayClient(
            name: openaiKey, headers: ["authorization": "Bearer \(token)"], method: "POST", rest: ""
        ) {
            XCTFail("the file's token must be dead after the unwrap")
        }
        let printed = rec.reports.joined(separator: "\n")
        XCTAssertTrue(printed.contains(env.path), "the offer listed the file")
        XCTAssertFalse(printed.contains(fakeBody), "no value in any report")
        XCTAssertFalse(printed.contains("ksfc_"), "no token in any report")
    }

    // MARK: - VAL-O-004 (a deleted recorded file does not abort the uninstall)

    /// A recorded wrapped file the user deleted since wrap must not abort the removal:
    /// answered yes, the offer unwraps the project in ONE per-project call, the
    /// per-project unwrap clears the deleted file's stale record and restores the
    /// survivor, and the uninstall completes. Failed pre-fix: the per-file unwrap of
    /// the deleted path threw notFound ("not found: …/acme/.env") and the removal
    /// never ran.
    func testDeletedRecordedFileDoesNotAbortTheUninstall() throws {
        let site = try makeOfferSite()
        let project = site.dir.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let original = "OPENAI_API_KEY=\(openaiValue)\n"
        let envA = project.appendingPathComponent(".env")
        try Data(original.utf8).write(to: envA)
        let originalB = "ANTHROPIC_API_KEY=\(anthropicValue)\n"
        let envB = project.appendingPathComponent(".env.local")
        try Data(originalB.utf8).write(to: envB)
        _ = try site.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        XCTAssertEqual(try site.db.listWrappedFiles().count, 2, "both files are recorded")
        let projectID = try site.db.listWrappedFiles()[0].project
        try fm.removeItem(at: envA)
        let promptsBefore = site.gate.reasons.count

        let rec = Recorder()
        let runner = UninstallOfferRunner(
            wrappedFiles: { try UninstallOfferRunner.recordedWrappedFiles(catalog: site.db.path) },
            isInteractive: { true },
            confirm: { rec.confirmCalls += 1; return true },
            unwrap: { projectID in
                rec.events.append("unwrap:\(projectID)")
                let folder = try XCTUnwrap(try site.db.project(id: projectID)?.path)
                let unwrap = UnwrapRunner(
                    connect: { try ControlClient.connect(control: site.control) },
                    out: { _ in },
                    projectFolder: { folder }
                )
                _ = try unwrap.run(path: nil)
            },
            uninstall: { rec.events.append("uninstall") },
            report: { rec.reports.append($0) }
        )

        try runner.run()

        XCTAssertEqual(rec.events, ["unwrap:\(projectID)", "uninstall"],
                       "one per-project unwrap, then the removal — the deleted file did not abort it")
        XCTAssertEqual(try Data(contentsOf: envB), Data(originalB.utf8),
                       "the surviving file was restored byte-for-byte")
        XCTAssertEqual(try site.db.listWrappedFiles().count, 0,
                       "every record was cleared, the deleted file's included")
        XCTAssertEqual(site.gate.reasons.count - promptsBefore, 1,
                        "one Touch ID — the surviving file's, under the one per-project prompt")
    }

    /// S4: the whole project folder deleted since wrap. Answered yes, the offer's
    /// per-project unwrap treats the project as stale — its records clear and its
    /// token is revoked, with no prompt — and the uninstall completes. Failed
    /// pre-fix: Project.canonicalFolder threw "that project folder does not exist",
    /// the removal never ran, and every retry failed the same way.
    func testDeletedProjectFolderDoesNotAbortTheUninstall() throws {
        let site = try makeOfferSite()
        let project = site.dir.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("OPENAI_API_KEY=\(openaiValue)\n".utf8).write(to: project.appendingPathComponent(".env"))
        _ = try site.service.importAndWrap(folder: project.path, variables: nil, docker: false)
        let projectID = try XCTUnwrap(try site.db.listWrappedFiles().first?.project)
        let liveBefore = try site.db.gatewayClients(keyName: "openai").filter { $0.revokedAt == nil }
        XCTAssertEqual(liveBefore.count, 1, "the import minted one project token")
        try fm.removeItem(at: project)
        let promptsBefore = site.gate.reasons.count

        let rec = Recorder()
        let runner = UninstallOfferRunner(
            wrappedFiles: { try UninstallOfferRunner.recordedWrappedFiles(catalog: site.db.path) },
            isInteractive: { true },
            confirm: { rec.confirmCalls += 1; return true },
            unwrap: { projectID in
                rec.events.append("unwrap:\(projectID)")
                let folder = try XCTUnwrap(try site.db.project(id: projectID)?.path)
                let unwrap = UnwrapRunner(
                    connect: { try ControlClient.connect(control: site.control) },
                    out: { _ in },
                    projectFolder: { folder }
                )
                _ = try unwrap.run(path: nil)
            },
            uninstall: { rec.events.append("uninstall") },
            report: { rec.reports.append($0) }
        )

        try runner.run()

        XCTAssertEqual(rec.events, ["unwrap:\(projectID)", "uninstall"], "the removal ran")
        XCTAssertTrue(try site.db.listWrappedFiles().isEmpty, "the stale record was cleared")
        XCTAssertTrue(try site.db.gatewayClients(keyName: "openai").allSatisfy { $0.revokedAt != nil },
                      "the project's token was revoked")
        XCTAssertEqual(site.gate.reasons.count, promptsBefore, "nothing to restore, so no prompt")
    }

    /// The command surface: `autostart --remove`'s help names the offer, so the
    /// behavior is discoverable before it ever runs.
    func testTheRemoveFlagHelpNamesTheOffer() {
        XCTAssertTrue(AutostartCommand.configuration.abstract.contains("login item"))
        XCTAssertTrue(UninstallOfferRunner.leftBehindStatement.contains("no longer work"))
    }
}
