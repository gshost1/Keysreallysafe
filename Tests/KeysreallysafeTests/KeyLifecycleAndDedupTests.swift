import XCTest
@testable import KeysCore

/// Key audit log, rotate/remove/purge presence, OpenRouter poll, Claude dedup, project spend, menubar text.
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

    func testRemoveAndRotateRequirePresenceAndBumpVersion() throws {
        let (db, _) = try makeDB()
        let inner = MemorySecretStore()
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: inner, presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(gate.reasons, [])
        let rotated = try service.rotate(name: "demo", secret: "new-secret-value", caller: "rotate")
        XCTAssertEqual(rotated.version, 2)
        XCTAssertEqual(try inner.get(name: "demo"), "new-secret-value")
        XCTAssertEqual(gate.reasons, ["Unlock demo"])
        XCTAssertEqual(try service.keyEvents(name: "demo").map(\.action).first, "rotate")

        _ = try service.setGateway(name: "demo", enabled: true, host: nil)
        XCTAssertTrue(service.isGatewayEnabled("demo"))
        _ = try service.rotate(name: "demo", secret: "swapped-secret")
        XCTAssertEqual(service.lookupGateway(name: "demo")?.secret, "swapped-secret")

        let beforeRemove = gate.reasons.count
        try service.remove(name: "demo", caller: "rm")
        XCTAssertEqual(gate.reasons.count, beforeRemove + 1)
        XCTAssertEqual(gate.reasons.last, "Unlock demo")
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

    func testOpenRouterPollRequiresGatewayMemoryAndFillsStatus() throws {
        let (db, _) = try makeDB()
        let fake = FakeOpenRouter(
            snapshot: CatalogDB.ProviderSnapshot(
                provider: "openrouter",
                keyName: "",
                ts: "2026-09-04T20:00:00Z",
                usageDaily: 1.5,
                usageWeekly: 8.25,
                usageMonthly: 20,
                limit: 100,
                limitRemaining: 79.5,
                rawKind: "monthly"
            )
        )
        let service = KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            openRouter: fake
        )
        try service.add(name: "or-bill", provider: "openrouter", kind: "billing", notes: "", secret: fixtureSecret)
        try service.pollOpenRouter()
        XCTAssertEqual(fake.calls, [])
        var status = try service.liveStatus()
        var row = try XCTUnwrap(status.plans.first { $0.source == "openrouter" })
        XCTAssertEqual(row.usageNote, "enable the gateway for this key to poll")
        XCTAssertNil(row.limitRemaining)

        _ = try service.setGateway(name: "or-bill", enabled: true, host: nil)
        try service.pollOpenRouter()
        XCTAssertEqual(fake.calls, [fixtureSecret])
        status = try service.liveStatus()
        row = try XCTUnwrap(status.plans.first { $0.source == "openrouter" })
        XCTAssertEqual(row.limitRemaining, 79.5)
        XCTAssertEqual(row.limit, 100)
        XCTAssertEqual(row.usageWeekly, 8.25)
        XCTAssertEqual(row.snapshotAt, "2026-09-04T20:00:00Z")
        XCTAssertNil(row.usageNote)
        let json = row.jsonObject()
        XCTAssertEqual(json["limit_remaining"] as? Double, 79.5)
        XCTAssertEqual(json["source"] as? String, "openrouter")
    }

    func testDoctorListsSourcesAndDoesNotProbeInTests() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let report = try Doctor.report(service: service, probeListener: false)
        XCTAssertEqual(report.sources.map(\.id), [
            "grok-sessions", "grok-quota", "claude-projects", "claude-hud", "codex-sessions",
        ])
        XCTAssertTrue(report.printed.contains("strip=Grok weekly $"))
        XCTAssertTrue(report.printed.contains("catalog"))
        XCTAssertTrue(report.printed.contains("keychain"))
        XCTAssertFalse(report.printed.contains(fixtureSecret))
        let (handler, _, _) = try makeHandler()
        let response = handle(handler, method: "GET", path: "/api/doctor")
        XCTAssertEqual(response.status, 200)
        let obj = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertNotNil(obj["sources"])
        XCTAssertNotNil(obj["catalog_path"])
        XCTAssertNotNil(obj["gateway_listening"])
    }

    func testClaudeDedupKeepsLastLineOfTurn() throws {
        let (db, _) = try makeDB()
        let report = try ClaudeIngest.run(home: Fixtures.claudeDedupHome, db: db)
        XCTAssertEqual(report.rowsInserted, 1)
        XCTAssertEqual(report.rowsUpdated, 3)
        let events = try db.allUsageEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].promptId, "turn-req-1")
        XCTAssertEqual(events[0].inputTokens, 100)
        XCTAssertEqual(events[0].outputTokens, 25)
        XCTAssertEqual(events[0].cachedReadTokens, 4)
    }

    func testClaudeDedupUpdatesOnIncrementalAppend() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let first = assistant(requestId: "r1", uuid: "a", output: 10)
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 1)
        let later = assistant(requestId: "r1", uuid: "b", output: 22)
        try (first + "\n" + later + "\n").write(to: file, atomically: true, encoding: .utf8)
        let again = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.rowsUpdated, 1)
        let events = try db.allUsageEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].outputTokens, 22)
    }

    func testSpendByProjectClaudeOnly() throws {
        let (handler, service, _) = try makeHandler()
        _ = try service.catalog.insertUsage(
            UsageEvent(
                source: "claude-local",
                sessionId: "s1",
                promptId: "p1",
                model: "claude-sonnet-5",
                occurredAt: "2026-09-03T18:00:00Z",
                provider: "anthropic",
                cwd: "/tmp/alpha/keysreallysafe",
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: nil,
                inputTokens: 10,
                outputTokens: 4,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: nil
            )
        )
        _ = try service.catalog.insertUsage(
            UsageEvent(
                source: "claude-local",
                sessionId: "s2",
                promptId: "p2",
                model: "claude-sonnet-5",
                occurredAt: "2026-09-03T19:00:00Z",
                provider: "anthropic",
                cwd: "/tmp/beta/other",
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: nil,
                inputTokens: 20,
                outputTokens: 8,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: nil
            )
        )
        let now = UTC.parse("2026-09-04T12:00:00Z")!
        let report = try service.spend(
            range: .month, by: .project, source: .claude, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(Set(report.rows.compactMap(\.project)), ["keysreallysafe", "other"])
        XCTAssertEqual(Set(report.rows.compactMap(\.cwd)), ["/tmp/alpha/keysreallysafe", "/tmp/beta/other"])
        XCTAssertEqual(Set(report.daily.compactMap(\.project)), ["keysreallysafe", "other"])
        let bad = handle(
            handler,
            method: "GET",
            path: "/api/spend",
            query: ["range": "month", "by": "project", "source": "grok"]
        )
        XCTAssertEqual(bad.status, 400)
        let ok = handle(
            handler,
            method: "GET",
            path: "/api/spend",
            query: ["range": "month", "by": "project", "source": "claude"]
        )
        XCTAssertEqual(ok.status, 200)
        let obj = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
        XCTAssertEqual(obj["by"] as? String, "project")
    }

    func testDailyBucketPins2330LocalVersusNextDayUTC() throws {
        let tz = TimeZone(identifier: "America/Denver")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        let (db, _) = try makeDB()
        // 23:30 MDT on Sep 1 is 05:30 UTC on Sep 2.
        _ = try db.insertUsage(
            UsageEvent(
                source: "grok-local",
                sessionId: "tz",
                promptId: "late-2330",
                model: "grok-4.6-build",
                occurredAt: "2026-09-02T05:30:00Z",
                provider: "xai",
                cwd: nil,
                sessionTitle: nil,
                agentName: nil,
                stopReason: nil,
                modelCalls: 1,
                apiDurationMs: 1,
                inputTokens: 10,
                outputTokens: 5,
                cachedReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: 0,
                costUsdTicks: Int64((1.25 * Ticks.perUSD).rounded())
            )
        )
        let month = try SpendQueries(db: db).report(
            range: .month, by: .model, source: .grok, now: now, timeZone: tz
        )
        XCTAssertEqual(month.daily.map(\.day), ["2026-09-01"])
        XCTAssertEqual(month.startDay, "2026-09-01")
    }

    func testMenubarShowsPlanPercentsAndKeepsGrokMonthUsd() {
        var totals = SpendTotals()
        totals.grokUsd = 2.81
        totals.claudeTokens = 1000
        let report = SpendReport(
            range: .month,
            by: .model,
            source: .all,
            caption: SpendReport.captionText,
            totals: totals,
            rows: [],
            daily: []
        )
        var status = LiveStatus()
        status.grok = ToolStatus(source: "grok", title: "Grok", weeklyPct: 3, weeklyUsd: 2.81)
        status.claude = ToolStatus(source: "claude", title: "Claude", fiveHourPct: 22)
        status.plans = [
            ToolStatus(source: "openai", title: "OpenAI · Codex", weeklyPct: 32)
        ]
        let snap = MenubarSnapshot.from(report, status: status)
        XCTAssertEqual(snap.title, "X 32%  G 3%") // Claude has no weekly window here, so only its 5h is in the tooltip
        XCTAssertTrue(snap.tooltip.hasPrefix("Grok $2.81"))
        XCTAssertTrue(snap.tooltip.contains("Claude 5h 22%"))
        XCTAssertTrue(snap.tooltip.contains("Codex weekly 32%"))
        XCTAssertTrue(snap.tooltip.contains("Grok weekly 3%"))
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
        let gate = RecordingPresenceGate()
        let service = KeysService(
            catalog: db,
            secrets: GatedSecretStore(inner: inner, presence: gate),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome
        )
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertThrowsError(try service.purge(confirmation: "nope"))
        XCTAssertEqual(try service.list().map(\.name), ["demo"])
        try service.purge(confirmation: "purge")
        XCTAssertEqual(gate.reasons.last, "Purge Keysreallysafe")
        XCTAssertTrue(try service.list().isEmpty)
        XCTAssertThrowsError(try inner.get(name: "demo"))
    }

    func testCodexSkipsConsecutiveDuplicateTokenCount() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("sessions/2026/09/04", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(
            "rollout-2026-09-04T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        let lines = [
            #"{"timestamp":"2026-09-04T12:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/x","config":{"model":"gpt-5.4"}}}"#,
            #"{"timestamp":"2026-09-04T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#,
            #"{"timestamp":"2026-09-04T12:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":8,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#,
            #"{"timestamp":"2026-09-04T12:00:02.100Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":8,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let events = try CodexIngest.parseFile(file)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.inputTokens), [10, 20])
        XCTAssertEqual(events.map(\.outputTokens).reduce(0, +), 12)
    }

    private func assistant(requestId: String, uuid: String, output: Int) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"requestId\":\"\(requestId)\",\"sessionId\":\"s\",\"timestamp\":\"2026-09-03T12:00:00.000Z\",\"cwd\":\"/tmp/p\",\"message\":{\"id\":\"msg\",\"model\":\"claude-sonnet-5\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func makeHandler() throws -> (APIHandler, KeysService, URL) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><head></head><title>Keysreallysafe</title></html>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        return (APIHandler(service: service, webRoot: web), service, dir)
    }

    private func handle(
        _ handler: APIHandler,
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data = Data(),
        token: Bool = true
    ) -> HTTPResponse {
        var headers = ["host": "127.0.0.1:12765"]
        if token, method != "GET", method != "HEAD" {
            headers["x-ksf-token"] = handler.originToken
        }
        return handler.handle(HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            serverPort: 12765
        ))
    }
}

final class DoctorBinaryNoteTests: XCTestCase {
    func testBinaryNoteUsesSourceHashSidecarNotResignedCopy() {
        // The installed copy is re-signed, so its own hash never equals the debug binary.
        XCTAssertEqual(Doctor.binaryNote(installed: "resigned", installedSource: "abc", debug: "abc"), "match")
        XCTAssertEqual(Doctor.binaryNote(installed: "resigned", installedSource: "abc", debug: "def"), "stale")
        XCTAssertTrue(Doctor.binaryNote(installed: "resigned", installedSource: nil, debug: "abc").hasPrefix("unknown"))
        XCTAssertEqual(Doctor.binaryNote(installed: nil, installedSource: nil, debug: "abc"), "login item binary missing")
        XCTAssertEqual(Doctor.binaryNote(installed: "x", installedSource: "x", debug: nil), "debug binary missing")
        XCTAssertEqual(Doctor.binaryNote(installed: nil, installedSource: nil, debug: nil), "missing")
    }
}
