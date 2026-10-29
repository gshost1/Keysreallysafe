import Foundation
import XCTest
@testable import KeysCore

/// F4 VAL-AC-001..007: `activity` reads the catalog locally — forwarded gateway
/// calls from `usage_events`, refusals from the `gateway_denied` audit rows, and
/// the project labels joined through each key's active client tokens — so it
/// answers with the app closed. The rig seeds a temp catalog and drives the real
/// group over it with an injected clock; one test drives the whole `MCPSession`
/// dispatch so the roster, the output guard and the JSON shape are pinned as a
/// client sees them. No Keychain, no Touch ID, no network, never the installed
/// app.
final class ActivityToolsTests: XCTestCase {
    private let fm = FileManager.default

    /// A fixed clock so the rolling window's boundaries are exact.
    private let now = UTC.parse("2026-10-28T12:00:00Z")!

    /// The contract's pinned not-running sentence — `activity` must never emit it.
    private static let notRunning = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    // MARK: - Rig

    @discardableResult
    private func makeRig() throws -> (service: KeysService, db: CatalogDB, dir: URL, gate: RecordingPresenceGate) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        return (service, db, dir, gate)
    }

    /// The real group over the rig's catalog, with the clock pinned to `now`.
    private func tools(_ db: CatalogDB) -> MCPActivityTools {
        MCPActivityTools(catalog: { db }, now: { self.now })
    }

    private func makeFolder(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One forwarded call, stored exactly the way the gateway stores it.
    private func call(
        _ db: CatalogDB, _ key: String, hoursAgo: Double, requestId: String,
        provider: String = "anthropic", model: String = "claude-sonnet-5",
        input: Int? = 100, output: Int? = 50, ticks: Int64? = nil
    ) throws {
        let row = GatewayUsageRow(
            ts: UTC.iso(now.addingTimeInterval(-hoursAgo * 3600)),
            key: key, provider: provider, model: model,
            inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: 0,
            status: 200, durationMs: 12, requestId: requestId, reportedCostUsdTicks: ticks
        )
        try db.insertUsage(row.usageEvent())
    }

    /// One refusal, stored as the gateway's `gateway_denied` audit row.
    private func refusal(_ db: CatalogDB, _ key: String, hoursAgo: Double, code: String = "out_of_scope") throws {
        try db.insertKeyEvent(
            ts: UTC.iso(now.addingTimeInterval(-hoursAgo * 3600)),
            name: key, action: "gateway_denied", caller: "gateway", detail: code, httpStatus: 401
        )
    }

    private func payload(_ result: MCPToolResult) throws -> [String: Any] {
        let text = (result.content.first?["text"] as? String) ?? ""
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    private func rows(_ db: CatalogDB, _ arguments: [String: Any] = [:]) throws -> [[String: Any]] {
        let body = try payload(try tools(db).call("activity", arguments: arguments))
        return (body["rows"] as? [[String: Any]]) ?? []
    }

    private func requestCount(_ db: CatalogDB, _ arguments: [String: Any]) throws -> Int {
        try rows(db, arguments).reduce(0) { $0 + ($1["requests"] as? Int ?? 0) }
    }

    private func text(_ result: MCPToolResult) -> String {
        (result.content.first?["text"] as? String) ?? ""
    }

    /// The refusal message a tool call would surface, as a client sees it.
    private func refusalMessage(_ db: CatalogDB, _ arguments: [String: Any]) -> String {
        do {
            _ = try tools(db).call("activity", arguments: arguments)
            return ""
        } catch {
            return MCPToolErrorFormatter.message(for: error)
        }
    }

    // MARK: - VAL-AC-001

    /// One row per key used in the window: request counts, refusals, and the active
    /// clients' project labels. A key with no project client carries no labels; the
    /// label is the only project fact, never the path.
    func testRowsPerKeyWithCountsRefusalsAndProjectLabels() throws {
        let (service, db, dir, _) = try makeRig()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "plain", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let project = try service.resolveProject(folder: try makeFolder(dir, "work").path)
        _ = try service.issueGatewayClient(name: "demo", label: "agent", project: project.id)

        try call(db, "demo", hoursAgo: 1, requestId: "d1")
        try call(db, "demo", hoursAgo: 2, requestId: "d2")
        try call(db, "plain", hoursAgo: 3, requestId: "p1")
        try refusal(db, "demo", hoursAgo: 1.5)
        try refusal(db, "plain", hoursAgo: 2.5, code: "grant_required")

        let result = try tools(db).call("activity", arguments: [:])
        let body = try payload(result)
        XCTAssertEqual(body["window_hours"] as? Int, 24, "the default window is 24 hours")
        let all = try XCTUnwrap(body["rows"] as? [[String: Any]])
        XCTAssertEqual(all.count, 2, "one row per key used in the window")
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0["key"] as? String ?? "", $0) })
        XCTAssertEqual(byKey["demo"]?["requests"] as? Int, 2)
        XCTAssertEqual(byKey["demo"]?["refusals"] as? Int, 1)
        XCTAssertEqual(byKey["demo"]?["projects"] as? [String], [project.label], "the label, by label only")
        XCTAssertEqual(byKey["plain"]?["requests"] as? Int, 1)
        XCTAssertEqual(byKey["plain"]?["refusals"] as? Int, 1)
        XCTAssertEqual(byKey["plain"]?["projects"] as? [String], [],
                       "a key used with no project client carries no project labels")

        let out = text(result)
        XCTAssertTrue(out.contains(project.label))
        XCTAssertFalse(out.contains(dir.path), "labels never paths")
    }

    /// A key that only refused (never forwarded) is still used: it earns a row.
    func testRefusalOnlyKeyGetsARow() throws {
        let (service, db, _, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try refusal(db, "demo", hoursAgo: 1)
        let all = try rows(db)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0]["requests"] as? Int, 0)
        XCTAssertEqual(all[0]["refusals"] as? Int, 1)
    }

    /// An empty catalog yields empty rows — a success, no fake numbers.
    func testEmptyCatalogYieldsEmptyRows() throws {
        let (_, db, _, _) = try makeRig()
        let result = try tools(db).call("activity", arguments: [:])
        XCTAssertEqual(result.isError, false)
        let body = try payload(result)
        XCTAssertEqual((body["rows"] as? [Any])?.count, 0)
        XCTAssertEqual(body["window_hours"] as? Int, 24)
    }

    // MARK: - VAL-AC-002

    /// `window` bounds the aggregation to `now − window h`, half-open at the start
    /// edge and exclusive at the end.
    func testWindowBoundsTheAggregation() throws {
        let (service, db, _, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try call(db, "demo", hoursAgo: 0.5, requestId: "recent")
        try call(db, "demo", hoursAgo: 1, requestId: "edge")
        try call(db, "demo", hoursAgo: 1.5, requestId: "old")

        XCTAssertEqual(try requestCount(db, [:]), 3, "the 24 h default includes everything here")
        XCTAssertEqual(try requestCount(db, ["window": 1]), 2,
                       "the call exactly at the start edge is inside; the older one is out")
        XCTAssertEqual(try requestCount(db, ["window": 3]), 3)
        XCTAssertEqual(try requestCount(db, ["window": 2]), 3)
    }

    /// The default is 24, the bounds are 1 and 720, and anything else — a fractional
    /// number, a string, a boolean, an out-of-range value — is a local argument
    /// error, refused before the catalog is read.
    func testWindowValidation() throws {
        let (_, db, _, _) = try makeRig()
        for bad in [0, 721, -1, 24.5, "24", true] as [Any] {
            let message = refusalMessage(db, ["window": bad])
            XCTAssertTrue(message.contains("window must be a whole number of hours from 1 to 720"),
                          "\(bad) is refused: \(message)")
        }
        for good in [1, 720, 24] as [Any] {
            XCTAssertNoThrow(try tools(db).call("activity", arguments: ["window": good]), "\(good) is in range")
        }
    }

    // MARK: - VAL-AC-003

    /// `project` filters to the keys whose active clients carry that label; an
    /// unknown label yields empty rows, not an error.
    func testProjectFiltersByLabel() throws {
        let (service, db, dir, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "plain", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let work = try service.resolveProject(folder: try makeFolder(dir, "work").path)
        let side = try service.resolveProject(folder: try makeFolder(dir, "side").path)
        _ = try service.issueGatewayClient(name: "demo", label: "a", project: work.id)
        _ = try service.issueGatewayClient(name: "other", label: "b", project: side.id)

        try call(db, "demo", hoursAgo: 1, requestId: "d")
        try call(db, "other", hoursAgo: 1, requestId: "o")
        try call(db, "plain", hoursAgo: 1, requestId: "p")

        XCTAssertEqual(Set(try rows(db).compactMap { $0["key"] as? String }), ["demo", "other", "plain"])
        XCTAssertEqual(try rows(db, ["project": work.label]).compactMap { $0["key"] as? String }, ["demo"])
        XCTAssertEqual(try rows(db, ["project": side.label]).compactMap { $0["key"] as? String }, ["other"])

        let unknown = try tools(db).call("activity", arguments: ["project": "no-such-project"])
        XCTAssertEqual(unknown.isError, false, "an unknown label is an empty answer, not an error")
        XCTAssertEqual((try payload(unknown)["rows"] as? [Any])?.count, 0)

        // A wrong-typed project is refused locally.
        XCTAssertTrue(refusalMessage(db, ["project": 3]).contains("project must be a project label"))
        XCTAssertTrue(refusalMessage(db, ["project": ""]).contains("project must be a project label"))
    }

    // MARK: - VAL-AC-004

    /// Spend reuses `SpendQueries.gatewayUsd`: a reported receipt wins, else the
    /// list-price estimate, and a call that could not be priced leaves `usd` null —
    /// never a fake zero. A reported zero stays a known zero.
    func testSpendHonesty() throws {
        let (service, db, _, _) = try makeRig()
        for name in ["priced", "estimated", "unpriced", "zero"] {
            try service.add(name: name, provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        }
        try call(db, "priced", hoursAgo: 1, requestId: "r1", ticks: 5_000_000_000)          // $0.50 reported
        try call(db, "estimated", hoursAgo: 1, requestId: "e1", input: 1_000_000, output: 0) // list price → $2.00
        try call(db, "unpriced", hoursAgo: 1, requestId: "u1", input: 0, output: 0)          // no receipt, no usage
        try call(db, "zero", hoursAgo: 1, requestId: "z1", input: 0, output: 0, ticks: 0)    // a reported zero

        let byKey = Dictionary(uniqueKeysWithValues: try rows(db).map { ($0["key"] as? String ?? "", $0) })
        func spend(_ key: String) throws -> [String: Any] {
            try XCTUnwrap(byKey[key]?["spend"] as? [String: Any])
        }

        let priced = try spend("priced")
        XCTAssertEqual(priced["usd"] as? Double ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(priced["calls"] as? Int, 1)
        XCTAssertEqual(priced["priced_calls"] as? Int, 1)
        XCTAssertEqual(priced["unpriced_calls"] as? Int, 0)
        XCTAssertEqual(priced["kind"] as? String, "estimate")

        let estimated = try spend("estimated")
        XCTAssertEqual(estimated["usd"] as? Double ?? -1, 2.0, accuracy: 1e-9, "the list-price estimate, no new math")
        XCTAssertEqual(estimated["priced_calls"] as? Int, 1)

        let unpriced = try spend("unpriced")
        XCTAssertTrue(unpriced["usd"] is NSNull, "an unpriced call is unknown, never $0")
        XCTAssertEqual(unpriced["calls"] as? Int, 1)
        XCTAssertEqual(unpriced["priced_calls"] as? Int, 0)
        XCTAssertEqual(unpriced["unpriced_calls"] as? Int, 1)
        XCTAssertEqual(unpriced["kind"] as? String, "unknown")

        let zero = try spend("zero")
        XCTAssertEqual(zero["usd"] as? Double, 0.0, "a reported zero is a known zero")
        XCTAssertEqual(zero["priced_calls"] as? Int, 1)
    }

    /// A key with calls but nothing priced is `unknown`; adding a priced call makes
    /// it `partial` and the sum a floor.
    func testMixedPricedAndUnpricedCalls() throws {
        let (service, db, _, _) = try makeRig()
        try service.add(name: "mixed", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        try call(db, "mixed", hoursAgo: 1, requestId: "m1", input: 0, output: 0)
        try call(db, "mixed", hoursAgo: 2, requestId: "m2", ticks: 5_000_000_000)
        let spend = try XCTUnwrap(try rows(db).first?["spend"] as? [String: Any])
        XCTAssertEqual(spend["kind"] as? String, "partial")
        XCTAssertEqual(spend["calls"] as? Int, 2)
        XCTAssertEqual(spend["priced_calls"] as? Int, 1)
        XCTAssertEqual(spend["unpriced_calls"] as? Int, 1)
        XCTAssertEqual(spend["usd"] as? Double ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - VAL-AC-005

    /// The exact JSON key sets are pinned, top to bottom.
    func testExactJSONKeySets() throws {
        let (service, db, dir, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let project = try service.resolveProject(folder: try makeFolder(dir, "work").path)
        _ = try service.issueGatewayClient(name: "demo", label: "a", project: project.id)
        try call(db, "demo", hoursAgo: 1, requestId: "d1")
        try refusal(db, "demo", hoursAgo: 1.5)

        let body = try payload(try tools(db).call("activity", arguments: [:]))
        XCTAssertEqual(Set(body.keys), ["window_hours", "rows"])
        let row = try XCTUnwrap((body["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(row.keys), ["key", "projects", "requests", "refusals", "spend"])
        let spend = try XCTUnwrap(row["spend"] as? [String: Any])
        XCTAssertEqual(Set(spend.keys), ["usd", "calls", "priced_calls", "unpriced_calls", "kind"])
    }

    /// No token, no vault value, no request body fragment: the output is names,
    /// labels and counts only, and it passes the output guard.
    func testOutputCarriesNoTokenValueOrBody() throws {
        let (service, db, _, _) = try makeRig()
        // A key-shaped string built at runtime, never a committed literal a scanner flags.
        let planted = "sk-ant-FAKE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: planted)
        let issued = try service.issueGatewayClient(name: "demo", label: "agent")
        try call(db, "demo", hoursAgo: 1, requestId: "BODY-SENTINEL-fragment")

        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        let registry = try MCPRoster.registry(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("the activity rig fetches no release") }
        )
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"activity","arguments":{}}}"#,
        ], registry: registry)
        XCTAssertEqual(stderr, [])
        let result = try MCPSession.assertResult(frames[1], id: "a")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let out = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""

        XCTAssertFalse(out.contains(planted), "a vault value never appears")
        XCTAssertFalse(out.contains(issued.token), "a client token never appears")
        XCTAssertFalse(out.contains("BODY-SENTINEL-fragment"), "a request body fragment never appears")
        XCTAssertNil(out.range(of: MCPOutputGuard.tokenShapePattern, options: .regularExpression),
                     "no token shape survives the guard")
    }

    // MARK: - VAL-AC-006

    /// `activity` works with the app closed: no control file is read and the
    /// not-running sentence never appears.
    func testWorksWithTheAppClosed() throws {
        let (service, db, _, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try call(db, "demo", hoursAgo: 1, requestId: "d1")
        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        XCTAssertFalse(fm.fileExists(atPath: control.path), "no control file is written")

        let result = try tools(db).call("activity", arguments: [:])
        XCTAssertEqual(result.isError, false)
        XCTAssertFalse(text(result).contains(Self.notRunning), "activity never answers the not-running sentence")

        // Through the full roster over the same unwritten control file it still answers.
        let registry = try MCPRoster.registry(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("the activity rig fetches no release") }
        )
        let (frames, _) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"activity","arguments":{}}}"#,
        ], registry: registry)
        let result2 = try MCPSession.assertResult(frames[1], id: "a")
        XCTAssertEqual(result2["isError"] as? Bool, false, "the full roster answers with the app closed")
        let out = ((result2["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertFalse(out.contains(Self.notRunning))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                        "the answer is a JSON object, not prose")
    }

    // MARK: - VAL-AC-007

    /// Registered last, after `revoke_project`, and callable through the real
    /// server dispatch with the guard in place.
    func testRegisteredAfterRevokeProjectAndCallable() throws {
        let (service, db, _, _) = try makeRig()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try call(db, "demo", hoursAgo: 1, requestId: "d1")
        let control = ControlFile.url(beside: db.path)
        try AppConnectionIsolationGuard.assertIsolated(control: control)
        let registry = try MCPRoster.registry(
            catalog: { db },
            control: control,
            fetchLatestRelease: { throw AppError.usage("the activity rig fetches no release") }
        )
        let (frames, stderr) = try MCPSession.run([
            MCPSession.initialize(),
            #"{"jsonrpc":"2.0","id":"l","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"activity","arguments":{"window":6}}}"#,
        ], registry: registry)
        XCTAssertEqual(stderr, [])
        let roster = try MCPSession.toolNames(in: frames[1], id: "l")
        XCTAssertEqual(roster.last, "activity", "activity is appended last")
        XCTAssertEqual(Array(roster.suffix(3)), ["revoke_all", "revoke_project", "activity"])
        let result = try MCPSession.assertResult(frames[2], id: "a")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let out = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let body = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(body?["window_hours"] as? Int, 6)
    }
}
