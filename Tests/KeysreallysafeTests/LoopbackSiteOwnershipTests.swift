import Foundation
import XCTest
@testable import KeysCore

/// `LoopbackSite.bind` publishes the control file a CLI needs to reach the site. With a
/// live site already owning that file, the publish refused — but only after the server and
/// the gateway were up, so the refusal left a listening gateway with no control file
/// pointing at it, and the caller printed "gateway not started" about a gateway that was
/// running. The ownership question is now asked before anything starts.
final class LoopbackSiteOwnershipTests: XCTestCase {

    /// A live Keysrs-shaped process that is not this one: a copy of `/bin/sleep` named
    /// `keys`, which `proc_pidpath` reports as a `keys` binary. The real app is never
    /// started by a test.
    private func liveSiteStandIn() throws -> Process {
        let dir = try TempDir.make()
        let binary = dir.appendingPathComponent("keys")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        return process
    }

    /// A world where bind can find the dashboard resources. `WebRoot.find` reads
    /// `KEYS_WEB_ROOT`, so a temp directory with an `index.html` stands in for `Web/`.
    private func webRoot() throws {
        let web = try TempDir.make()
        try Data("<html></html>".utf8).write(to: web.appendingPathComponent("index.html"))
        setenv("KEYS_WEB_ROOT", web.path, 1)
        addTeardownBlock { unsetenv("KEYS_WEB_ROOT") }
    }

    /// A service over a temp catalog, and the control file its bind will publish beside it.
    private func service() throws -> (service: KeysService, control: URL) {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        return (service, control)
    }

    /// Another live site owns the control file. A checkout dashboard still serves its
    /// pages (the documented dev copy beside the installed app), but starts no gateway
    /// and leaves the running site's file alone.
    func testABindBesideARunningSiteServesWithoutTheGatewayOrTheFile() throws {
        let (service, control) = try service()
        _ = try webRoot()
        let app = try liveSiteStandIn().processIdentifier
        try ControlFile.write(port: 12_766, token: "app-token", pid: app, to: control)

        let server = try LoopbackSite.bind(service: service, preferredPort: 0, gatewayPort: 0)
        defer { server.stop() }
        XCTAssertGreaterThan(server.boundPort, 0, "the dashboard is served")
        XCTAssertFalse(service.isGatewayRunning(), "no gateway beside the running site's")
        XCTAssertEqual(try ControlFile.read(at: control)?.token, "app-token", "the running site keeps its file")
    }

    /// The refusal reads as a sentence, not a struct dump.
    func testTheOwnershipRefusalSaysWhoOwnsTheSite() {
        let held = ControlFile.OwnerHeld(pid: 4242, port: 12_766)
        XCTAssertEqual("\(held)", held.localizedDescription)
        XCTAssertTrue(held.localizedDescription.contains("Keysrs is already running"))
        XCTAssertTrue(held.localizedDescription.contains("4242"))
    }

    /// `requireGateway` is what the app's own launch uses: the refusal it throws must be
    /// the real one, not a gateway failure dressed up as one.
    func testARequiredGatewayBindRefusesWithTheOwnershipAnswer() throws {
        let (service, control) = try service()
        _ = try webRoot()
        let app = try liveSiteStandIn().processIdentifier
        try ControlFile.write(port: 12_766, token: "app-token", pid: app, to: control)

        XCTAssertThrowsError(
            try LoopbackSite.bind(service: service, preferredPort: 0, requireGateway: true)
        ) { error in
            XCTAssertTrue(error is ControlFile.OwnerHeld, "the ownership refusal reaches the caller: \(error)")
        }
        XCTAssertFalse(service.isGatewayRunning())
    }
}
