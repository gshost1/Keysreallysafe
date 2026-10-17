import XCTest
@testable import KeysCore

/// Round 2 of the remote import review: totals that count this Mac's own droid rows as detail,
/// remote rows a later local ingest duplicates, mixed spend rows, held-file churn, purge, the
/// ingest API and saturating sums in the windows and analytics.
final class RemoteImportRound2Tests: XCTestCase {
    // Not a session id the fixture droid logs use: those count as this Mac's detail for it.
    private let session = "r2r2r2r2-0000-4000-8000-0000000000a1"

    private func tempCatalog() throws -> (CatalogDB, URL) {
        let (db, dir) = try makeDB()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (db, dir)
    }

    private func write(_ lines: [String], in dir: URL, name: String = "export.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func completionLine(session: String? = nil, input: Int = 1000, output: Int = 1000, cacheRead: Int = 1000,
                                cacheWrite: Int = 1000, thinking: Int = 1000) -> String {
        "{\"type\":\"completion\",\"session_id\":\"\(session ?? self.session)\",\"timestamp\":1792118855901,"
            + "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead),"
            + "\"cache_creation_input_tokens\":\(cacheWrite),\"thinking_tokens\":\(thinking)}}"
    }

    private func droidLine(response: String, session: String? = nil, model: String = "kimi-k3", input: Int = 100,
                           output: Int = 50, cacheRead: Int = 200) -> String {
        "[2026-10-16T21:40:00.000Z] INFO: [Agent] Streaming result | Context: "
            + "{\"inputTokens\":\(input),\"cacheReadInputTokens\":\(cacheRead),\"cachedTokensWritten\":0,"
            + "\"outputTokens\":\(output),\"reasoningTokens\":10,\"upstreamResponseId\":\"\(response)\","
            + "\"tags\":{\"modelId\":\"\(model)\",\"sessionId\":\"\(session ?? self.session)\"}}"
    }

    private func local(_ source: String = "droid-local", session: String? = nil, prompt: String, model: String = "kimi-k3",
                       input: Int = 100, output: Int = 50, cacheRead: Int = 200, reasoning: Int = 10,
                       at: String = "2026-10-16T21:40:00Z") -> UsageEvent {
        UsageEvent(source: source, sessionId: session ?? self.session, promptId: prompt, model: model, occurredAt: at,
                   provider: source.hasPrefix("claude") ? "anthropic" : "moonshot", inputTokens: input, outputTokens: output,
                   cachedReadTokens: cacheRead, cacheCreationTokens: 0, reasoningTokens: reasoning)
    }

    private func all(_ db: CatalogDB) throws -> [UsageEvent] {
        try db.usageEvents(from: "1970-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z", source: .all)
            .sorted { ($0.source, $0.promptId, $0.model) < ($1.source, $1.promptId, $1.model) }
    }

    private func residual(_ db: CatalogDB, _ session: String? = nil) throws -> UsageEvent? {
        try all(db).first { $0.model == "unattributed" && $0.sessionId == (session ?? self.session) }
    }

    private func buckets(_ e: UsageEvent) -> [Int] {
        [e.inputTokens, e.outputTokens, e.cachedReadTokens, e.cacheCreationTokens, e.reasoningTokens]
    }

    // MARK: 1 and 2: double counts

    func testATotalCountsThisMacsLocalDroidRowsOfTheSameSessionAsDetail() throws {
        let (db, dir) = try tempCatalog()
        _ = try db.insertUsage(local(prompt: "l1"))
        _ = try db.insertUsage(local(prompt: "l2", input: 300, output: 150, cacheRead: 0, reasoning: 0))
        let report = try RemoteImport.importFile(try write([completionLine()], in: dir), db: db)
        XCTAssertEqual(report.parseErrors, 0)
        XCTAssertEqual(buckets(try XCTUnwrap(try residual(db))), [600, 800, 800, 1000, 990])
        // Rows that cover the total leave nothing.
        let (db2, dir2) = try tempCatalog()
        _ = try db2.insertUsage(local(prompt: "l1", input: 5_000, output: 5_000, cacheRead: 5_000, reasoning: 5_000))
        _ = try RemoteImport.importFile(try write([completionLine(cacheWrite: 0)], in: dir2), db: db2)
        XCTAssertNil(try residual(db2))
    }

    func testRowsOfEitherSideArrivingLaterRecomputeTheResidual() throws {
        let (db, dir) = try tempCatalog()
        _ = try RemoteImport.importFile(try write([completionLine()], in: dir, name: "t.jsonl"), db: db)
        XCTAssertEqual(try residual(db)?.inputTokens, 1000)
        // A local row shows up later; the next reconcile (every local ingest pass runs it) shrinks the total.
        _ = try db.insertUsage(local(prompt: "l1"))
        XCTAssertGreaterThan(try RemoteImport.reconcile(db: db), 0)
        XCTAssertEqual(buckets(try XCTUnwrap(try residual(db))), [900, 950, 800, 1000, 990])
        XCTAssertEqual(try RemoteImport.reconcile(db: db), 0, "nothing left to change")
        // A remote row arriving later does the same.
        _ = try RemoteImport.importFile(try write([droidLine(response: "r1", input: 400, output: 0, cacheRead: 0)], in: dir, name: "r.jsonl"), db: db)
        XCTAssertEqual(try residual(db)?.inputTokens, 500)
        // Both rows cover input entirely: the residual's input bucket reaches zero, never below.
        _ = try db.insertUsage(local(prompt: "l9", input: 9_000))
        _ = try RemoteImport.reconcile(db: db)
        XCTAssertEqual(try residual(db)?.inputTokens, 0)
    }

    func testALocalIngestPassDeletesRemoteRowsItNowDuplicatesAndRecomputesResiduals() throws {
        let (db, dir) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        // Session X holds a total and one remote row; this Mac later records the same call locally.
        _ = try RemoteImport.importFile(try write([
            completionLine(), droidLine(response: "dup-droid"), droidLine(response: "keep-droid", model: "glm-5.3"),
            "{\"type\":\"assistant\",\"sessionId\":\"cloud-1\",\"requestId\":\"dup-claude\",\"timestamp\":\"2026-10-16T18:00:00.000Z\","
                + "\"message\":{\"id\":\"m\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20}}}",
        ], in: dir), db: db)
        XCTAssertEqual(buckets(try XCTUnwrap(try residual(db))), [800, 900, 600, 1000, 980],
                       "two remote rows of 100/50/200/10 each were subtracted")
        _ = try db.insertUsage(local(session: "this-mac", prompt: "dup-droid"))
        _ = try db.insertUsage(local("claude-local", session: "this-mac-claude", prompt: "dup-claude", model: "claude-opus-5-5",
                                     input: 10, output: 20, cacheRead: 0, reasoning: 0))
        _ = try service.ingest(.droid)
        let rows = try all(db)
        XCTAssertFalse(rows.contains { $0.source == "droid-remote" && $0.promptId == "dup-droid" })
        XCTAssertFalse(rows.contains { $0.source == "claude-remote" })
        XCTAssertTrue(rows.contains { $0.source == "droid-remote" && $0.promptId == "keep-droid" })
        XCTAssertTrue(rows.contains { $0.source == "droid-local" && $0.promptId == "dup-droid" }, "the local row stays")
        // Session X's detail is now only keep-droid: the deleted row's share of the total came
        // back, because the local copy sits under another session id and is not X's detail.
        XCTAssertEqual(try residual(db)?.inputTokens, 900)
    }

    // MARK: 3 mixed rows

    func testGroupedRowsReportTheRemotePartOfTheirCountedTokens() throws {
        let (db, _) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        let at = UTC.iso(Date())
        _ = try db.insertUsage(local(prompt: "a", model: "claude-opus-5-5", input: 100, output: 0, cacheRead: 0, reasoning: 0, at: at))
        var remote = local("droid-remote", prompt: "b", model: "claude-opus-5-5", input: 40, output: 0, cacheRead: 0, reasoning: 0, at: at)
        remote.sessionId = "cloud"
        _ = try db.insertUsage(remote)
        for by in [SpendGroup.model, .session] {
            let report = try service.spend(range: .month, by: by, source: .all)
            let json = report.jsonObject()
            let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
            let counted = rows.reduce(0) { $0 + ($1["counted_tokens"] as? Int ?? 0) }
            let remoteCounted = rows.reduce(0) { $0 + ($1["remote_counted_tokens"] as? Int ?? 0) }
            XCTAssertEqual(counted, 140, "\(by)")
            XCTAssertEqual(remoteCounted, 40, "\(by)")
            XCTAssertTrue(rows.allSatisfy { $0["remote_counted_tokens"] is Int }, "every row carries the field")
        }
        let byModel = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertEqual(byModel.rows.count, 1, "one model, one mixed row")
        XCTAssertEqual(byModel.rows[0].remoteCountedTokens, 40)
        XCTAssertEqual(byModel.rows[0].countedTokens, 140)
    }

    // MARK: 4 held-file churn, catalog version, future mtime

    func testAHeldFileIsNotReimportedWhileItsSizeAndTimeStayTheSame() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let file = try write([droidLine(response: "ok"), "{\"type\":\"assistant\",\"message\":"], in: imports, name: "held.jsonl")
        let later = Date().addingTimeInterval(120)
        let first = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertEqual(first.held, ["held.jsonl"])
        XCTAssertEqual(first.filesScanned, 1)
        let stored = try all(db).count
        XCTAssertEqual(stored, 1)
        try db.deleteUsage(source: "droid-remote", sessionId: session, promptId: "ok", model: "kimi-k3")
        let second = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertEqual(second.held, ["held.jsonl"], "still named")
        XCTAssertEqual(second.filesScanned, 0, "but not read again")
        XCTAssertTrue(try all(db).isEmpty)
        // A change to the file makes it eligible again.
        try (try String(contentsOf: file, encoding: .utf8) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let third = RemoteImport.drain(imports, db: db, now: Date().addingTimeInterval(240))
        XCTAssertEqual(third.filesScanned, 1)
        XCTAssertEqual(try all(db).count, 1)
        // Once the file is gone its record is gone too.
        try FileManager.default.removeItem(at: file)
        _ = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertTrue(try db.metaRows(prefix: RemoteImport.attemptPrefix).isEmpty)
    }

    func testAFileWithAFutureTimeIsNamedHeldNotSilentlySkipped() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let file = try write([droidLine(response: "ok")], in: imports, name: "future.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: file.path)
        let report = RemoteImport.drain(imports, db: db)
        XCTAssertEqual(report.held, ["future.jsonl"])
        XCTAssertTrue(try all(db).isEmpty)
    }

    func testAnIdenticalReimportChangesNothingAndDoesNotBumpTheCatalogVersion() throws {
        let (db, dir) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        let file = try write([droidLine(response: "r1"), completionLine()], in: dir)
        let first = try service.importRemote(file)
        XCTAssertEqual(first.rowsInserted, 2)
        let version = try db.catalogVersion()
        XCTAssertGreaterThan(version, 0)
        let again = try service.importRemote(file)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.rowsUpdated, 0, "nothing was different")
        XCTAssertEqual(again.rowsUnchanged, 2)
        XCTAssertEqual(try db.catalogVersion(), version)
        // A real change counts.
        let edited = try write([droidLine(response: "r1", input: 999), completionLine()], in: dir)
        let changed = try service.importRemote(edited)
        XCTAssertEqual(changed.rowsUpdated, 2, "the edited row and the residual that follows it")
        XCTAssertEqual(try db.catalogVersion(), version + 1)
    }

    // MARK: 5 purge

    func testPurgeRemovesTheImportsFolderAndTheHeldRecords() throws {
        let (db, dir) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        let imports = service.importsDir
        try FileManager.default.createDirectory(at: imports.appendingPathComponent("imported", isDirectory: true),
                                                withIntermediateDirectories: true)
        _ = try write([droidLine(response: "r1")], in: imports, name: "waiting.jsonl")
        _ = try write([droidLine(response: "r2")], in: imports.appendingPathComponent("imported"), name: "done.jsonl")
        try db.setMeta(RemoteImport.attemptPrefix + "waiting.jsonl", "1:1")
        XCTAssertThrowsError(try service.purge(confirmation: "nope"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.path), "a refused purge deletes nothing")
        try service.purge(confirmation: "purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: imports.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "only imports/ goes, not the catalog folder")
        XCTAssertTrue(try db.metaRows(prefix: RemoteImport.attemptPrefix).isEmpty)
    }

    // MARK: 6 ingest API

    func testTheIngestResponseCarriesSkippedRowsAndHeldNamesForTheImportsPass() throws {
        let (handler, service, _) = try makeHandler()
        let imports = service.importsDir
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let file = try write(["{\"type\":\"assistant\",\"message\":"], in: imports, name: "stuck.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: file.path)
        _ = try service.catalog.insertUsage(local("droid-local", session: "x", prompt: "p-known"))
        let ok = try write([droidLine(response: "p-known", session: "cloud")], in: imports, name: "dup.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: ok.path)
        let response = handle(handler, method: "POST", path: "/api/ingest", body: try JSONValue.data(["source": "all"]))
        XCTAssertEqual(response.status, 200)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let pass = try XCTUnwrap(obj["imports"] as? [String: Any])
        XCTAssertEqual(pass["held"] as? [String], ["stuck.jsonl"])
        XCTAssertEqual(pass["rows_skipped"] as? Int, 1)
        let claude = try XCTUnwrap(obj["claude"] as? [String: Any])
        XCTAssertEqual(claude["held"] as? [String], [])
        XCTAssertEqual(claude["rows_skipped"] as? Int, 0)
    }

    // MARK: 7 saturating windows and analytics

    func testDroidWindowsAndAnalyticsSumsSaturateOnHugeStoredRows() throws {
        let (db, _) = try tempCatalog()
        let now = Date()
        let at = UTC.iso(now.addingTimeInterval(-600))
        for n in 0..<2 {
            _ = try db.insertUsage(UsageEvent(source: "droid-local", sessionId: "s\(n)", promptId: "p\(n)", model: "kimi-k3",
                occurredAt: at, provider: "moonshot", inputTokens: Int.max, outputTokens: Int.max,
                cachedReadTokens: Int.max, cacheCreationTokens: Int.max, reasoningTokens: Int.max))
        }
        let windows = try DroidUsage.windows(catalog: db, now: now)
        XCTAssertEqual(windows.fiveHour, Int.max)
        XCTAssertEqual(windows.monthly, Int.max)

        let clock = ProductAnalyticsTests.Clock(), transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, endpoint: URL(string: "https://analytics.example/v1/reports")!,
                                         transport: transport, now: { clock.date() })   // 2026-05-19T04:00Z
        try analytics.setEnabled(true, consentVersion: 2)
        for n in 0..<2 {
            _ = try db.insertUsage(UsageEvent(source: "claude-local", sessionId: "s", promptId: "c\(n)", model: "claude-fable-5-1",
                occurredAt: "2026-05-19T06:00:00Z", provider: "anthropic", inputTokens: Int.max, outputTokens: Int.max,
                cachedReadTokens: Int.max, cacheCreationTokens: Int.max, reasoningTokens: Int.max))
        }
        analytics.record(.viewUsage)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let data = try XCTUnwrap(transport.calls.first?.data)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(sent["usage"] as? [[String: Any]])
        XCTAssertEqual(usage.first?["prompts"] as? Int, 2)
        XCTAssertEqual(usage.first?["input_tokens"] as? Int, Int(ProductAnalytics.maxTokens))
    }
}
