import XCTest
@testable import KeysCore

/// `keys list --json` runs in its own process, whose gateway cache is always empty; the
/// running app is the only place that knows which keys are on.
final class ListCommandTests: XCTestCase {
    func testJSONRowsTakeGatewayStateFromTheRunningSite() throws {
        let (db, dir) = try makeDB()
        let (app, _, _) = makeService(db: db)
        try app.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: app, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)
        _ = try app.setGateway(name: "demo", enabled: true, host: "api.openai.com")

        // A second service on the same catalog stands in for the CLI process: it has the row
        // but not the app's memory, so on its own it reports the key off.
        let (cli, _, _) = makeService(db: db)
        XCTAssertEqual(try cli.listJSONObject().first.flatMap { JSONValue.bool($0["gateway_enabled"]) }, false)

        let live = try ListCommand.jsonRows(service: cli)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?["name"] as? String, "demo")
        XCTAssertEqual(live.first.flatMap { JSONValue.bool($0["gateway_enabled"]) }, true)
        XCTAssertEqual(live.first?["gateway_url"] as? String, "http://127.0.0.1:\(GatewayListener.port)/demo")

        // With no site running there is no gateway, and the local rows are the truth.
        try FileManager.default.removeItem(at: control)
        let local = try ListCommand.jsonRows(service: cli)
        XCTAssertEqual(local.first?["name"] as? String, "demo")
        XCTAssertEqual(local.first.flatMap { JSONValue.bool($0["gateway_enabled"]) }, false)
    }
}
