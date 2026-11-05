import XCTest
@testable import KeysCore

/// Key audit log, rotate/remove/purge presence, Claude dedup, project spend.
final class KeyLifecycleAndDedupTests: XCTestCase {
    func testKeyEventsNewestFirstAndLastUsedOnlyOnUse() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret, caller: "add")
        XCTAssertNil(try service.list()[0].lastUsedAt)
        try service.copy(name: "demo", holdUntilWipe: false, caller: "copy")
        _ = try service.reveal(name: "demo", caller: "dashboard")
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: "n", caller: "dashboard")
        let events = try service.keyEvents(name: "demo", limit: 50)
        XCTAssertEqual(events.map(\.action), ["patch", "reveal", "copy", "add"])
        XCTAssertEqual(Set(events.map(\.caller)), ["add", "copy", "dashboard"])
        XCTAssertTrue(events.allSatisfy { $0.detail == nil })
        XCTAssertNotNil(try service.list()[0].lastUsedAt)
        let blob = String(data: try JSONValue.data(events.map { ["action": $0.action, "caller": $0.caller ?? ""] }), encoding: .utf8)!
        XCTAssertFalse(blob.contains(fixtureSecret))
        _ = dir
    }

    func testEventsRouteOmitsSecretAndHonorsLimit() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.copy(name: "demo", holdUntilWipe: false)
        _ = try service.reveal(name: "demo")
        _ = try service.patch(name: "demo", provider: nil, kind: nil, notes: "x")
        let response = handle(handler, method: "GET", path: "/api/keys/demo/events", query: ["limit": "3"])
        XCTAssertEqual(response.status, 200)
        let obj = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let events = obj["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map { $0["action"] as? String }, ["patch", "reveal", "copy"])
        let text = String(data: response.body, encoding: .utf8)!
        XCTAssertFalse(text.contains(fixtureSecret))
        XCTAssertFalse(text.contains("\"secret\""))
        let missing = handle(handler, method: "GET", path: "/api/keys/nosuch/events")
        XCTAssertEqual(missing.status, 404)
    }

    /// VAL-SECRET-004: the catalog is not a secret store. After an add the secret may live
    /// only in the SecretStore — the raw catalog files on disk (the main DB and its WAL) and
    /// the key_events rows the dashboard's History reads must hold no trace of it. The
    /// sentinel is invented.
    func testAddLeavesNoSecretInCatalogFilesOrKeyEvents() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let sentinel = "sk-add-NEVER-REAL-4604109371"
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "n", secret: sentinel, caller: "add")

        // The audit row exists, so the scans below run over real rows, not an empty table.
        let events = try service.keyEvents(name: "demo")
        XCTAssertEqual(events.map(\.action), ["add"])

        // The wire shape the History drawer reads: the add is in there, the secret is not.
        let handler = APIHandler(service: service, webRoot: dir)
        let response = handle(handler, method: "GET", path: "/api/keys/demo/events")
        XCTAssertEqual(response.status, 200)
        let text = String(data: response.body, encoding: .utf8)!
        XCTAssertFalse(text.contains(sentinel))
        XCTAssertFalse(text.contains("\"secret\""))

        // Raw bytes: every file of the catalog on disk, the main DB and its WAL included.
        // The key's own name does appear among those bytes — the row is stored, by design —
        // so the same traversal that finds it proves it read the files that hold the write.
        assertNoSentinel(sentinel, in: dir)
        var sawName = false
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url), data.range(of: Data("demo".utf8)) != nil { sawName = true }
        }
        XCTAssertTrue(sawName, "the scan must traverse the files that hold the key's own row")
    }

    func testRemoveAndRotateRequirePresenceAndBumpVersion() throws {
        let (db, _) = try makeDB()
        let inner = MemorySecretStore()
        let (service, gate) = makeGatedService(db: db, secrets: inner)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(gate.reasons, [])
        let rotated = try service.rotate(name: "demo", secret: "new-secret-value", caller: "rotate")
        XCTAssertEqual(rotated.version, 2)
        XCTAssertEqual(try inner.get(name: "demo"), "new-secret-value")
        XCTAssertEqual(gate.reasons, ["unlock demo"])
        XCTAssertEqual(try service.keyEvents(name: "demo").map(\.action).first, "rotate")

        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertTrue(service.isGatewayEnabled("demo"))
        _ = try service.rotate(name: "demo", secret: "swapped-secret")
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "swapped-secret")

        let beforeRemove = gate.reasons.count
        try service.remove(name: "demo", caller: "rm")
        XCTAssertEqual(gate.reasons.count, beforeRemove + 1)
        XCTAssertEqual(gate.reasons.last, "delete demo")
        XCTAssertTrue(try service.list().isEmpty)
        XCTAssertThrowsError(try inner.get(name: "demo"))
    }

    func testRotateRouteNeedsTokenAndDoesNotEchoSecret() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        let without = handle(
            handler,
            method: "POST",
            path: "/api/keys/demo/rotate",
            body: try JSONValue.data(["secret": "next-secret"]),
            token: false
        )
        XCTAssertEqual(without.status, 403)
        let ok = handle(
            handler,
            method: "POST",
            path: "/api/keys/demo/rotate",
            body: try JSONValue.data(["secret": "next-secret"])
        )
        XCTAssertEqual(ok.status, 200)
        let obj = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
        XCTAssertEqual(obj["version"] as? Int, 2)
        XCTAssertFalse(String(data: ok.body, encoding: .utf8)!.contains("next-secret"))
        XCTAssertFalse(String(data: ok.body, encoding: .utf8)!.contains(fixtureSecret))
    }

    func testDoctorReadsNoUsageLogsAndDoesNotProbeInTests() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        // A stub install keeps this test off the live app bundle, the real command line link
        // and Installer.live.binary; the install block has its own coverage in DoctorInstallTests.
        let report = try Doctor.report(service: service, probeListener: false, install: DoctorInstall())
        for gone in ["grok-sessions", "claude-projects", "codex-sessions", "strip="] {
            XCTAssertFalse(report.printed.contains(gone), "doctor no longer checks subscription logs: \(gone)")
        }
        XCTAssertTrue(report.printed.contains("catalog"))
        XCTAssertTrue(report.printed.contains("keychain"))
        XCTAssertFalse(report.printed.contains(fixtureSecret))
    }

    /// The project and session groupings and the per-tool sources belonged to the subscription
    /// logs, removed on 2026-11-04; the spend route refuses them instead of answering empty.
    func testSpendRouteRefusesRetiredGroupingsAndSources() throws {
        let (handler, _, _) = try makeHandler()
        for query in [
            ["range": "month", "by": "project"],
            ["range": "month", "by": "session"],
            ["range": "month", "source": "claude"],
            ["range": "month", "source": "cloud"],
        ] {
            XCTAssertEqual(handle(handler, method: "GET", path: "/api/spend", query: query).status, 400, "\(query)")
        }
        for source in ["keys", "all", ""] {
            let ok = handle(handler, method: "GET", path: "/api/spend", query: ["range": "month", "source": source])
            XCTAssertEqual(ok.status, 200, "an older link's source=\(source) still answers")
        }
        let ingest = handle(handler, method: "POST", path: "/api/ingest").status
        XCTAssertTrue([404, 405].contains(ingest), "/api/ingest is gone: \(ingest)")
    }

    func testParseAutostartRemoveAndNewCommands() throws {
        XCTAssertTrue(try KeysCLI.parseAsRoot(["autostart", "--remove"]) is AutostartCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["doctor"]) is DoctorCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["purge"]) is PurgeCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["rotate", "demo"]) is RotateCommand)
    }

    func testPurgeRequiresLiteralWordAndPresence() throws {
        let (db, _) = try makeDB()
        let inner = MemorySecretStore()
        let (service, gate) = makeGatedService(db: db, secrets: inner)
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        try db.upsertProviderCheck(ProviderCheck.Result(
            key: "demo", provider: "xai", host: "api.x.ai", checkedAt: "2026-09-25T00:00:00Z",
            outcome: .ok, httpStatus: 200, models: [], requestId: nil, message: nil, endpoint: nil
        ))
        try db.setMeta("license_key", "left over from 0.8")
        // The removed optimizer's encrypted archive, as 0.9.0 and 0.9.1 left it beside the catalog.
        let optimizer = db.path.deletingLastPathComponent().appendingPathComponent("optimizer", isDirectory: true)
        try FileManager.default.createDirectory(at: optimizer, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: optimizer.appendingPathComponent("optimizer-content.gcm"))
        // The claude-hud plan snapshot the removed plan meter read, in the same folder.
        let planSnapshot = db.path.deletingLastPathComponent().appendingPathComponent("claude-plan.json")
        try Data("{}".utf8).write(to: planSnapshot)
        XCTAssertThrowsError(try service.purge(confirmation: "nope"))
        XCTAssertEqual(try service.list().map(\.name), ["demo"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: optimizer.path), "a refused purge deletes nothing")
        try service.purge(confirmation: "purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: optimizer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: planSnapshot.path))
        XCTAssertEqual(gate.reasons.last, "purge Keysrs")
        XCTAssertTrue(try service.list().isEmpty)
        XCTAssertThrowsError(try inner.get(name: "demo"))
        XCTAssertNil(try db.providerCheck(keyName: "demo"))
        XCTAssertNil(try db.metaValue("license_key"))
        XCTAssertEqual(try db.catalogVersion(), 0)
    }
}
