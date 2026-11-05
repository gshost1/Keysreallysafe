import Foundation
import XCTest
@testable import KeysCore

/// `keys provider add|rm|hide` go through the running site when one is up, so its view of
/// the catalog changes with the database. The call was wrapped in `try?`, which turned a
/// live site's refusal into "no site is running": the command then wrote the catalog
/// directly behind the app's back and, for add and rm, told the person the site was down.
final class ProviderWriteTests: XCTestCase {

    /// A site stub answering the health probe and then `status` on a provider write,
    /// recording every request.
    private func site(status: Int) throws -> (server: LoopbackHTTPServer, log: RequestLog) {
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            if request.path == AppConnection.launchHealthPath { return HTTPResponse.json(200, ["grants": []]) }
            if status == 201 { return HTTPResponse.json(201, ["id": "mine"]) }
            return HTTPResponse.json(status, ["error": "provider write refused"])
        }
        server.start()
        addTeardownBlock { server.stop() }
        return (server, log)
    }

    /// The same stub with no health answer: a live pid whose port refuses the control
    /// token is not a site a provider write may hand its catalog view to.
    private func unresponsiveSite() throws -> (server: LoopbackHTTPServer, log: RequestLog) {
        let log = RequestLog()
        let server = try LoopbackHTTPServer(port: 0) { request in
            log.record(request)
            return HTTPResponse.json(403, ["error": "auth_failed"])
        }
        server.start()
        addTeardownBlock { server.stop() }
        return (server, log)
    }

    private func control(_ server: LoopbackHTTPServer) throws -> URL {
        let dir = try TempDir.make()
        let control = ControlFile.url(beside: dir.appendingPathComponent("catalog.db"))
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        try ControlFile.write(port: server.boundPort, token: "app-token", to: control)
        return control
    }

    private func service() throws -> KeysService {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        return service
    }

    /// A live site that refuses the add is the command's error: nothing is written locally
    /// and the "no site is running" line never appears.
    func testARefusedAddIsReportedAndNothingIsWrittenBehindTheSite() throws {
        let (server, log) = try site(status: 400)
        let control = try self.control(server)
        let db = try CatalogDB(path: try TempDir.make().appendingPathComponent("local.db"))
        let local = try makeGatedService(db: db).0

        var printed: [String] = []
        XCTAssertThrowsError(
            try ProviderAddCommand.run(
                id: "mine", name: "Mine", host: nil, api: "other", authHeader: "Authorization",
                authPrefix: "Bearer ", pathPrefix: "", keyPrefix: nil, note: nil, gateway: true,
                control: control, service: { local }, out: { printed.append($0) }
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("provider write refused"), "the site's own answer: \(error)")
        }
        XCTAssertEqual(printed, [], "no success line for a refused write")
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath, "/api/providers"],
                       "the site was probed once, then asked once")
        XCTAssertEqual(try db.listCustomProviders().count, 0, "the catalog was not written behind the site")
    }

    /// With no site up, the direct write still happens and the note says it takes effect
    /// when one starts.
    func testWithNoSiteTheDirectWriteStillHappens() throws {
        let dir = try TempDir.make()
        let control = ControlFile.url(beside: dir.appendingPathComponent("catalog.db"))
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        let db = try CatalogDB(path: dir.appendingPathComponent("local.db"))
        let local = try makeGatedService(db: db).0

        var notes: [String] = []
        try ProviderAddCommand.run(
            id: "mine", name: "Mine", host: nil, api: "other", authHeader: "Authorization",
            authPrefix: "Bearer ", pathPrefix: "", keyPrefix: nil, note: nil, gateway: true,
            control: control, service: { local }, out: { notes.append($0) },
            advise: { notes.append($0) }
        )
        XCTAssertEqual(try db.listCustomProviders().map(\.id), ["mine"])
        XCTAssertTrue(notes.joined().contains("no Keysrs site is running"), notes.joined())
    }

    /// A refused hide is reported too: before the fix it printed "hid" as if the running
    /// app had applied it.
    func testARefusedHideIsReportedAndNotApplied() throws {
        let (server, log) = try site(status: 409)
        let control = try self.control(server)
        let db = try CatalogDB(path: try TempDir.make().appendingPathComponent("local.db"))
        let local = try makeGatedService(db: db).0

        var printed: [String] = []
        XCTAssertThrowsError(
            try ProviderHideCommand.setHidden(true, id: "openai", control: control, service: { local },
                                            out: { printed.append($0) })
        )
        XCTAssertEqual(printed, [], "a refusal never prints hid")
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath, "/api/providers/openai"])
        XCTAssertEqual(try db.hiddenProviderIds(), [], "the app's refusal was not written around")
    }

    /// A refused rm is reported, and the provider stays.
    func testARefusedRemoveIsReportedAndNothingIsRemoved() throws {
        let (server, log) = try site(status: 409)
        let control = try self.control(server)
        let db = try CatalogDB(path: try TempDir.make().appendingPathComponent("local.db"))
        let local = try makeGatedService(db: db).0
        try local.addProvider(id: "mine", name: "Mine", host: nil, api: "other", pathPrefix: "")

        XCTAssertThrowsError(
            try ProviderRmCommand.run(id: "mine", control: control, service: { local }, out: { _ in })
        )
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath, "/api/providers/mine"])
        XCTAssertEqual(try db.listCustomProviders().map(\.id), ["mine"], "the provider was not removed behind the site")
    }

    /// A control file whose pid was recycled: the process exists, so the file reads as a
    /// live site, but nothing there answers the control token. That is "no site to ask",
    /// not a refusal, so the write happens directly — before this, the connection was taken
    /// at face value and the command failed on the failed HTTP call instead.
    func testAStaleControlFileFallsBackToTheDirectWrite() throws {
        let (server, log) = try unresponsiveSite()
        let control = try self.control(server)
        let db = try CatalogDB(path: try TempDir.make().appendingPathComponent("local.db"))
        let local = try makeGatedService(db: db).0

        var notes: [String] = []
        try ProviderAddCommand.run(
            id: "mine", name: "Mine", host: nil, api: "other", authHeader: "Authorization",
            authPrefix: "Bearer ", pathPrefix: "", keyPrefix: nil, note: nil, gateway: true,
            control: control, service: { local }, out: { notes.append($0) },
            advise: { notes.append($0) }
        )
        XCTAssertEqual(try db.listCustomProviders().map(\.id), ["mine"], "the catalog was written despite the stale file")
        XCTAssertTrue(notes.joined().contains("no Keysrs site is running"), notes.joined())
        XCTAssertEqual(log.all.map(\.path), [AppConnection.launchHealthPath],
                       "the stale site was probed and never handed a provider write")
    }
}
