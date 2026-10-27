import XCTest
@testable import KeysCore

/// The CLI's exit codes are a contract a script reads instead of prose. Pin the whole
/// documented table here so a change to one code fails this test, not someone's script.
final class ExitCodeTests: XCTestCase {
    func testAppErrorTable() {
        // 1 usage or HTTP.
        XCTAssertEqual(AppError.usage("bad flag").exitCode, 1)
        XCTAssertEqual(AppError.http("could not reach the local site").exitCode, 1)
        XCTAssertEqual(AppError.alreadyExists("demo").exitCode, 1)
        XCTAssertEqual(AppError.gatewayOwned(1234).exitCode, 1)
        XCTAssertEqual(AppError.refusedBind("0.0.0.0").exitCode, 1)
        // 2 not found.
        XCTAssertEqual(AppError.notFound("nope").exitCode, 2)
        // 3 presence or Keychain.
        XCTAssertEqual(AppError.authFailed.exitCode, 3)
        XCTAssertEqual(AppError.authCancelled.exitCode, 3)
        XCTAssertEqual(AppError.authUnavailable("no interactive session").exitCode, 3)
        XCTAssertEqual(AppError.keychain("denied").exitCode, 3)
        // 4 ingest or catalog.
        XCTAssertEqual(AppError.ingestIO("unreadable").exitCode, 4)
        XCTAssertEqual(AppError.sqlite("corrupt").exitCode, 4)
        // 6 no running site: the one deliberate change, these failures used to be 1.
        XCTAssertEqual(AppError.siteUnavailable("no site").exitCode, 6)
    }

    func testTestAndModelsSpecialCases() {
        // keys test/models: no read-only check endpoint -> 2, any other failed check -> 5.
        XCTAssertEqual(ProviderCheck.Outcome.noCheckEndpoint.cliExitCode, 2)
        for outcome: ProviderCheck.Outcome in [
            .providerAuthFailed, .providerRefused, .providerError, .redirect, .network, .malformed,
        ] {
            XCTAssertEqual(outcome.cliExitCode, 5, "\(outcome) is a failed check")
        }
    }

    func testConnectWithoutASiteIsSiteUnavailable() throws {
        // A temp catalog dir with no control.json beside it means no live site.
        let dir = try TempDir.make()
        let control = ControlFile.url(beside: dir.appendingPathComponent("catalog.db"))
        XCTAssertThrowsError(try ControlClient.connect(control: control)) { error in
            guard case AppError.siteUnavailable(let message) = error else {
                return XCTFail("expected .siteUnavailable, got \(error)")
            }
            XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6)
            XCTAssertTrue(message.contains("no running Keysrs site"), message)
        }
    }

    func testTunnelGatewayDownIsSiteUnavailable() {
        guard case AppError.siteUnavailable(let message) = TunnelCommand.gatewayDown() else {
            return XCTFail("tunnel's gateway-not-up error must be .siteUnavailable")
        }
        XCTAssertEqual(AppError.siteUnavailable(message).exitCode, 6)
        XCTAssertTrue(message.contains("gateway is not listening"), message)
        XCTAssertTrue(message.contains("Keysrs.app"), message)
    }
}
