import XCTest
@testable import KeysCore

/// The real dashboard against the real backend.
///
/// Everything between the browser and the vault row is production code: the real
/// `Web/` assets, the real `LoopbackHTTPServer` on an ephemeral loopback port, the
/// real `APIHandler` routing, the real `KeysService` and the real JSON response
/// serialization. Only the platform boundaries a test may not touch are replaced,
/// and each replacement is a type the product already accepts by injection:
///
/// | Boundary | Replaced with | Why |
/// |---|---|---|
/// | Secret storage | `MemorySecretStore` in a temp dir | never the login keychain |
/// | Touch ID | `RecordingPresenceGate` | no GUI presence prompt in CI |
/// | Clipboard | `FakeClipboard` | no real pasteboard write |
/// | Optimizer key material | fixed 32 bytes via `loadKey` | never the keychain |
/// | Optimizer provider call | `runEngine` that fails the test | no network, no JEV |
/// | Analytics upload | endpoint `nil` + refusing transport | nothing leaves the machine |
///
/// The browser half lives in `scripts/tests/test_backend_contract_ui.cjs`, which
/// this test launches against the port it just bound. Every secret below is
/// invented for the harness.
///
/// Authentication is never relaxed. The driver's authorization cases send
/// missing, wrong and truncated tokens and forged Origin and Host headers into
/// the unmodified real gates and expect to be refused; the assertions at the end
/// of this test are the service-side half of that, checking the refusals left no
/// key, no secret, no presence prompt and no event behind.
///
/// The driver is launched through `BoundedChild`, so a wedged browser fails this
/// test in bounded time and leaves no Chromium behind. That teardown has its own
/// tests, without a browser, in `BoundedChildProcessTests`.
final class BackendContractUITests: XCTestCase {
    /// A transport that must never be reached: analytics is unconfigured here.
    final class RefusingAnalyticsTransport: AnalyticsTransport, @unchecked Sendable {
        final class NoUpload: AnalyticsUpload, @unchecked Sendable {
            func cancel() {}
        }
        let lock = NSLock()
        private(set) var attempts = 0
        func send(to endpoint: URL, data: Data, completion: @escaping @Sendable (Bool) -> Void) -> any AnalyticsUpload {
            lock.lock(); attempts += 1; lock.unlock()
            completion(false)
            return NoUpload()
        }
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Invented fixture secrets. `alpha` is seeded server-side; `delta` is typed
    /// into the real Add dialog by the browser, so both halves must agree on it.
    static let alphaSecret = "sk-contract-alpha-NEVER-REAL-000001"
    static let deltaSecret = "sk-contract-delta-NEVER-REAL-000002"

    func testRealDashboardDrivesTheRealKeysAndOptimizerAPIs() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KEYS_BACKEND_CONTRACT_UI"] == "1",
            "browser contract harness: set KEYS_BACKEND_CONTRACT_UI=1 with the pinned Playwright Chromium installed"
        )
        let script = Self.repoRoot.appendingPathComponent("scripts/tests/test_backend_contract_ui.cjs")
        let webRoot = Self.repoRoot.appendingPathComponent("Web")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: script.path), "missing \(script.path)")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: webRoot.appendingPathComponent("app.js").path))

        let (db, directory) = try makeDB()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let presence = RecordingPresenceGate()
        let secrets = MemorySecretStore()
        let clipboard = FakeClipboard()
        let analyticsTransport = RefusingAnalyticsTransport()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: secrets, presence: presence),
            clipboard: clipboard,
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        // Unconfigured endpoint: the privacy pane reads a real status and no
        // report can be uploaded even if something tried.
        service.analytics = ProductAnalytics(catalog: db, endpoint: nil, transport: analyticsTransport)

        let optimizerDirectory = directory.appendingPathComponent("optimizer")
        let optimizer = try OptimizerController(
            directory: optimizerDirectory,
            loadKey: { Data(repeating: 7, count: 32) },
            deleteKey: {},
            runEngine: { _, _ in
                XCTFail("no provider call may leave this harness")
                throw OptimizerAccessError.unavailable
            }
        )
        service.configureOptimizer(optimizer)
        addTeardownBlock { optimizer.lock(service: service) }

        // A synthetic vault: three keys the browser will list, and one of them a
        // real optimizer-compatible provider so the Optimizer affordance is
        // decided by the real `/api/optimizer/keys` answer.
        try service.add(name: "contract-alpha", provider: "openai", kind: "runtime",
                        notes: "first harness key", secret: Self.alphaSecret, caller: "harness")
        try service.add(name: "contract-bravo", provider: "anthropic", kind: "billing",
                        notes: "", secret: "sk-contract-bravo-NEVER-REAL-00003", caller: "harness")
        try service.add(name: "contract-typesafe", provider: "typesafe", kind: "runtime",
                        notes: "", secret: "sk-contract-typesafe-NEVER-REAL-04", caller: "harness")
        let seeded = try service.list().map(\.name).sorted()
        XCTAssertEqual(seeded, ["contract-alpha", "contract-bravo", "contract-typesafe"])

        let handler = APIHandler(service: service, webRoot: webRoot)
        let server = try LoopbackHTTPServer(host: "127.0.0.1", port: 0, handler: handler.handle)
        XCTAssertTrue(server.isBoundToLoopback)
        server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.boundPort)"

        let screenshots = ProcessInfo.processInfo.environment["KEYS_CONTRACT_SCREENSHOT_DIR"]
            ?? Self.repoRoot.appendingPathComponent(".build/keys-backend-contract-screenshots").path
        var environment = ProcessInfo.processInfo.environment
        environment["KEYS_CONTRACT_BASE_URL"] = base
        environment["KEYS_CONTRACT_TOKEN"] = handler.originToken
        environment["KEYS_CONTRACT_PROJECT_ROOT"] = directory.path
        environment["KEYS_CONTRACT_ALPHA_SECRET"] = Self.alphaSecret
        environment["KEYS_CONTRACT_DELTA_SECRET"] = Self.deltaSecret
        environment["KEYS_CONTRACT_SCREENSHOT_DIR"] = screenshots
        if environment["NODE_PATH"] == nil {
            environment["NODE_PATH"] = Self.repoRoot.appendingPathComponent("Plugins/jev-optimizer/node_modules").path
        }
        // The driver names the browser it launched here before it does anything
        // else. Playwright launches Chromium detached, in a group of its own, so
        // teardown can only reach it if the driver says which pid it is.
        let guardFile = directory.appendingPathComponent("contract-child-guard.json")
        environment["KEYS_CONTRACT_GUARD_FILE"] = guardFile.path

        // A hung browser must not hang the suite, and a killed driver must not
        // leave Chromium behind: `BoundedChild` bounds every wait and escalates
        // SIGTERM → SIGCONT → SIGKILL over the groups it started, and only those.
        // Its own failure path is covered by `BoundedChildProcessTests`.
        let seconds = Double(ProcessInfo.processInfo.environment["KEYS_CONTRACT_TIMEOUT_S"] ?? "") ?? 300
        let grace = Double(ProcessInfo.processInfo.environment["KEYS_CONTRACT_GRACE_S"] ?? "") ?? 10
        let report = try BoundedChild.run(
            ["node", script.path],
            directory: Self.repoRoot,
            environment: environment,
            timeout: seconds,
            grace: grace,
            guardFile: guardFile
        )
        XCTAssertFalse(report.timedOut,
                       "the browser contract suite did not finish within \(Int(seconds)) s; teardown: \(report.escalations)")
        XCTAssertEqual(report.exitCode, 0, "the browser contract suite failed; see its output above")
        XCTAssertTrue(report.isClean,
                      "the browser suite left processes behind in groups \(report.leakedGroups)")

        XCTAssertEqual(analyticsTransport.attempts, 0, "no analytics report may be attempted")
        // The state assertions below describe the whole ordered scenario, so a
        // deliberately filtered run stops here rather than reporting the cases
        // it was told not to run as failures.
        if let only = ProcessInfo.processInfo.environment["KEYS_CONTRACT_ONLY"], !only.isEmpty {
            return
        }

        // What the browser did must be visible in the real service state, not
        // only in the page it rendered.
        let names = try service.list().map(\.name).sorted()
        XCTAssertEqual(names, ["contract-alpha", "contract-bravo", "contract-typesafe"],
                       "the dialog-created key must have been created and then deleted through the real API")
        XCTAssertThrowsError(try secrets.get(name: "contract-delta"),
                             "deleting through the dashboard must drop the stored secret too")
        XCTAssertEqual(clipboard.value, Self.alphaSecret, "the real copy route must reach the clipboard boundary")
        XCTAssertEqual(clipboard.lastBackgroundWipe, ClipboardWipe.seconds)
        XCTAssertTrue(presence.reasons.contains("Unlock contract-alpha"), "\(presence.reasons)")
        XCTAssertTrue(presence.reasons.contains("Unlock contract-delta"), "\(presence.reasons)")
        XCTAssertTrue(presence.reasons.contains("Delete contract-delta"), "\(presence.reasons)")

        // The create/reveal round trip the browser performed went through real
        // storage: the event log is the service's own record of it.
        let events = try service.keyEvents(name: "contract-alpha", limit: 50).map(\.action)
        XCTAssertTrue(events.contains("copy"), "\(events)")

        // The forged requests the driver sent are refused at the HTTP gates, so
        // their effects must be absent from the service too, not merely from the
        // page: no intruder row, no stored intruder secret, no presence prompt
        // for the delete that was refused, and no recorded patch or removal.
        XCTAssertFalse(names.contains("contract-intruder"),
                       "a request refused by the token or same-origin gate created a key")
        XCTAssertThrowsError(try secrets.get(name: "contract-intruder"),
                             "a refused request reached secret storage")
        XCTAssertFalse(presence.reasons.contains("Delete contract-alpha"),
                       "a refused DELETE reached the presence gate: \(presence.reasons)")
        XCTAssertFalse(events.contains("rm"), "a refused DELETE was recorded against contract-alpha: \(events)")
        XCTAssertFalse(events.contains("patch"), "a refused PATCH was recorded against contract-alpha: \(events)")
    }
}
