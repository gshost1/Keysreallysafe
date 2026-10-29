import XCTest
@testable import KeysCore

/// VAL-H-001 / VAL-G-003: the production-side test-isolation tripwire — the
/// layer that does not depend on a rig remembering anything. The 2026-10-28
/// incident (a test reached the really-running installed app and imported a key
/// into the real vault) was a rig that forgot its guard, so the test-side guards
/// alone could not catch it; under the tripwire the production seams THEMSELVES
/// refuse. A process running under XCTest (`XCTestConfigurationFilePath` is set
/// by the harness for every test run) or with `KEYS_TEST_ISOLATION` set, and
/// with no `KEYS_CATALOG` (the sanctioned override, which every catalog-sibling
/// path follows), can never resolve the real
/// `~/Library/Application Support/Keysreallysafe` state: the no-argument forms
/// of the state seams throw instead of naming the path, so the real catalog is
/// never opened, the real control file is never read and the production
/// Keychain store is never built.
///
/// These rows run under the plain CI environment — no `KEYS_CATALOG` is set
/// there — so the harness's own signal is the armed one, exactly as an
/// accidental production resolution would find it. Like the guard's own test
/// file, this suite constructs forbidden configurations on purpose to prove the
/// refusals, so the structural belt deliberately does not scan it.
final class ProductionTripwireTests: XCTestCase {

    // MARK: - the no-argument production seams refuse

    /// The tripwire's own signal rule. The environment legs are unit-driven so
    /// the rule is testable without mutating a live process's environment, and
    /// the whole-process check is pinned true here because this suite runs
    /// under the harness — the merged tree's `swift test` loads XCTest
    /// in-process without the classic configuration variable.
    func testTheIsolationSignalItself() throws {
        XCTAssertFalse(TestIsolation.armed(environment: [:]), "no signals: not armed")
        XCTAssertFalse(TestIsolation.armed(environment: ["KEYS_TEST_ISOLATION": ""]),
                       "an empty opt-in value means unset, the Paths.env convention")
        XCTAssertTrue(TestIsolation.armed(environment: ["KEYS_TEST_ISOLATION": "1"]),
                      "the explicit opt-in arms the tripwire")
        XCTAssertTrue(TestIsolation.armed(environment: ["XCTestConfigurationFilePath": "/tmp/an-xctest-run"]),
                      "the classic harness variable arms the tripwire")
        XCTAssertTrue(TestIsolation.armed, "this suite runs under a test harness, so the process is armed")
    }

    /// `AppConnection.connect()` with no arguments resolves the default control
    /// URL inside its body — the first thing it does — so under the tripwire the
    /// whole app-bound surface (every eligible CLI command, every app-bound MCP
    /// tool) refuses before any file is read or anything launched. Pre-fix this
    /// row was deliberately not run: the old eager default would have READ the
    /// real control.json and, with the owner's app live, connected to it — the
    /// very incident the tripwire exists for; the url() row above is the
    /// captured pre-fix evidence for the same resolution.
    func testNoArgumentAppConnectionRefusesUnderTestIsolation() throws {
        XCTAssertThrowsError(try AppConnection.connect(), "the no-argument connect must refuse, not resolve") {
            error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
        }
    }

    /// `AppFactory.makeService()` with no arguments is the production service
    /// factory; under the tripwire it refuses before the real catalog is opened
    /// or the production Keychain store is built. Tests build a service over an
    /// explicit temp catalog with injected fakes instead. Pre-fix this row was
    /// deliberately not run (the old factory opened the real catalog); the
    /// url() and KeychainStore rows are the captured pre-fix evidence.
    func testNoArgumentMakeServiceRefusesUnderTestIsolation() throws {
        XCTAssertThrowsError(try AppFactory.makeService(), "the no-argument factory must refuse, not resolve") {
            error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
            XCTAssertFalse(message.contains("/Users/"), "the refusal names no absolute path")
        }
    }

    /// The resolver itself: with no `KEYS_CATALOG` (the sanctioned override) an
    /// armed process never receives the real catalog path, and the refusal
    /// names the isolation rule without naming any production location.
    func testResolvingCatalogRefusesInsteadOfNamingRealState() throws {
        XCTAssertThrowsError(try Paths.resolvingCatalog(), "the default catalog must refuse, not resolve") { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
            XCTAssertTrue(message.contains("KEYS_CATALOG"), "the refusal names the sanctioned override: \(message)")
            XCTAssertFalse(message.contains("/Users/"), "the refusal names no absolute path")
            XCTAssertFalse(message.contains("Application Support"), "the refusal names no production location")
        }
    }

    /// `ControlFile.url()` with no arguments is the default every app-bound
    /// seam and CLI wrapper resolves; under the tripwire it must refuse instead
    /// of naming the real control.json. Refusing here is what makes
    /// `AppConnection.connect()` and the whole app-bound surface fail closed:
    /// the resolution is the first thing those entry points do.
    func testNoArgumentControlFileURLRefusesUnderTestIsolation() throws {
        XCTAssertThrowsError(try ControlFile.url(), "the default control URL must refuse, not resolve") { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
            XCTAssertFalse(message.contains("/Users/"), "the refusal names no absolute path")
            XCTAssertFalse(message.contains("Application Support"), "the refusal names no production location")
        }
    }

    /// The production Keychain store is real state a test process must never
    /// hold — tests inject `MemorySecretStore`, never the real store — so its
    /// construction refuses under the tripwire, for the vault service and the
    /// relay service alike (the Keychain is not catalog-derived, so no
    /// `KEYS_CATALOG` override can sanction it).
    func testKeychainStoreConstructionRefusesUnderTestIsolation() throws {
        XCTAssertThrowsError(try KeychainStore(), "the vault service store must refuse to build") { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
            XCTAssertTrue(message.contains("fake SecretStore"), "the refusal says what to inject instead: \(message)")
        }
        XCTAssertThrowsError(try KeychainStore(service: KeysService.relayKeychainService),
                             "the relay service store must refuse to build")
    }

    /// A wrap rewrite that forgot to inject a `backupRoot` must refuse before
    /// any write instead of backing up into the real Application Support: the
    /// O2 backup root resolves from the catalog location at call time, and that
    /// resolution is what the tripwire gates. The row uses a missing file so it
    /// never writes anywhere in either state of the code.
    func testForgottenBackupRootRefusesInsteadOfResolvingRealState() throws {
        let dir = try TempDir.make()
        let missing = dir.appendingPathComponent(".env")
        XCTAssertThrowsError(
            try EnvFileWriter.rewrite(missing, original: Data("A=1\n".utf8), text: "A=2\n"),
            "a rewrite with no injected backup root must refuse under the tripwire"
        ) { error in
            guard case AppError.usage(let message) = error else {
                return XCTFail("expected a usage refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("test isolation"), "the refusal names the isolation rule: \(message)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "nothing was written")
    }
}
