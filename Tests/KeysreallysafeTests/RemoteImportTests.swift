import XCTest
@testable import KeysCore

/// Remote import: usage from a cloud session or a remote droid run, brought in as a file and
/// kept under its own sources so it is never mistaken for what this Mac's logs measured.
final class RemoteImportTests: XCTestCase {
    private let session = "bbbbbbbb-0000-4000-8000-000000000002"

    private func droidLine(model: String, response: String, input: Int = 100, cacheRead: Int = 2_000,
                           output: Int = 50, ts: String = "2026-10-16T21:40:00.000Z") -> String {
        "[\(ts)] INFO: [Agent] Streaming result | Context: "
            + "{\"inputTokens\":\(input),\"cacheReadInputTokens\":\(cacheRead),\"cachedTokensWritten\":0,"
            + "\"outputTokens\":\(output),\"reasoningTokens\":10,\"upstreamResponseId\":\"\(response)\","
            + "\"tags\":{\"modelId\":\"\(model)\",\"sessionId\":\"\(session)\"}}"
    }

    private func completionLine(session: String? = nil) -> String {
        "{\"type\":\"completion\",\"session_id\":\"\(session ?? self.session)\",\"timestamp\":1792118855901,"
            + "\"usage\":{\"input_tokens\":138,\"output_tokens\":165253,\"cache_read_input_tokens\":3573444,"
            + "\"cache_creation_input_tokens\":645689,\"thinking_tokens\":56728}}"
    }

    private let claudeLine = "{\"type\":\"assistant\",\"sessionId\":\"cloud-1\",\"requestId\":\"req_cloud_1\","
        + "\"timestamp\":\"2026-10-16T18:00:00.000Z\",\"cwd\":\"/home/user/repo\","
        + "\"message\":{\"id\":\"msg_1\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":10,"
        + "\"output_tokens\":20,\"cache_read_input_tokens\":300,\"cache_creation_input_tokens\":40}}}"

    private func write(_ lines: [String], in dir: URL, name: String = "export.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func rows(_ db: CatalogDB) throws -> [UsageEvent] {
        try db.usageEvents(from: "1970-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z", source: .all)
            .sorted { ($0.source, $0.promptId) < ($1.source, $1.promptId) }
    }

    func testDroidRequestsKeepTheirModelSoAFallbackToKimiShows() throws {
        let (db, dir) = try makeDB()
        let file = try write([
            droidLine(model: "claude-opus-5-5", response: "r1"),
            droidLine(model: "kimi-k3", response: "r2", input: 400),
        ], in: dir)
        let report = try RemoteImport.importFile(file, db: db)
        XCTAssertEqual(report.rowsInserted, 2)
        let stored = try rows(db)
        XCTAssertEqual(stored.map(\.source), ["droid-remote", "droid-remote"])
        XCTAssertEqual(stored.map(\.model), ["claude-opus-5-5", "kimi-k3"])
        XCTAssertEqual(stored.map(\.provider), ["anthropic", "moonshot"])
        XCTAssertEqual(try db.usageEvents(from: "1970-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z", source: .droid).count, 0,
                       "remote usage never lands in the local Droid ledger or its plan windows")
        XCTAssertEqual(try db.usageEvents(from: "1970-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z", source: .cloud).count, 2)
    }

    func testReimportingTheSameFileUpdatesInsteadOfDoubleCounting() throws {
        let (db, dir) = try makeDB()
        let file = try write([droidLine(model: "kimi-k3", response: "r1"), claudeLine], in: dir)
        _ = try RemoteImport.importFile(file, db: db)
        let again = try RemoteImport.importFile(file, db: db)
        XCTAssertEqual(again.rowsInserted, 0)
        XCTAssertEqual(again.rowsUpdated, 2)
        XCTAssertEqual(try rows(db).count, 2)
    }

    func testClaudeCloudLinesAreClaudeRemoteWithoutTheContainersFolder() throws {
        let (db, dir) = try makeDB()
        _ = try RemoteImport.importFile(try write([claudeLine], in: dir), db: db)
        let row = try XCTUnwrap(try rows(db).first)
        XCTAssertEqual(row.source, "claude-remote")
        XCTAssertEqual(row.model, "claude-opus-5-5")
        XCTAssertNil(row.cwd, "a container path is not a project on this Mac")
        XCTAssertEqual(TokenTotals.normalized(row), 370, "Claude's rule: input, output and both cache buckets")
    }

    func testASessionTotalIsUnattributedAndKeepsNoCreditsOrText() throws {
        let (db, dir) = try makeDB()
        let line = completionLine().replacingOccurrences(of: "\"type\"", with: "\"finalText\":\"SENTINEL-FINAL-TEXT\",\"type\"")
        _ = try RemoteImport.importFile(try write([line], in: dir), db: db)
        let row = try XCTUnwrap(try rows(db).first)
        XCTAssertEqual(row.model, "unattributed", "a session total cannot be split by model")
        XCTAssertEqual(row.promptId, "completion:\(session)")
        XCTAssertEqual(row.reasoningTokens, 56_728)
        XCTAssertEqual(row.occurredAt, "2026-10-16T02:47:35Z", "the stream-json timestamp is epoch milliseconds")
        XCTAssertNil(row.costUsdTicks, "factory_credits is not dollars and is not stored")
        let dump = String(describing: try rows(db))
        XCTAssertFalse(dump.contains("SENTINEL"))
    }

    /// A session total the per-request rows cover bucket for bucket, so nothing of it is left
    /// over; what a partial set of rows leaves is pinned in RemoteImportHardeningTests.
    private func coveredCompletion(session: String? = nil) -> String {
        "{\"type\":\"completion\",\"session_id\":\"\(session ?? self.session)\",\"timestamp\":1792118855901,"
            + "\"usage\":{\"input_tokens\":5,\"output_tokens\":5,\"cache_read_input_tokens\":5,"
            + "\"cache_creation_input_tokens\":0,\"thinking_tokens\":5}}"
    }

    func testPerRequestRowsReplaceASessionTotalInEitherOrder() throws {
        // Total first, details later: the total is deleted.
        let (db, dir) = try makeDB()
        _ = try RemoteImport.importFile(try write([coveredCompletion()], in: dir, name: "a.jsonl"), db: db)
        XCTAssertEqual(try rows(db).map(\.model), ["unattributed"])
        _ = try RemoteImport.importFile(try write([droidLine(model: "kimi-k3", response: "r1")], in: dir, name: "b.jsonl"), db: db)
        XCTAssertEqual(try rows(db).map(\.model), ["kimi-k3"])

        // Details first, total later: the total is never stored.
        let (db2, dir2) = try makeDB()
        _ = try RemoteImport.importFile(try write([droidLine(model: "kimi-k3", response: "r1")], in: dir2, name: "b.jsonl"), db: db2)
        _ = try RemoteImport.importFile(try write([coveredCompletion()], in: dir2, name: "a.jsonl"), db: db2)
        XCTAssertEqual(try rows(db2).map(\.model), ["kimi-k3"])

        // Both in one file: details win; another session's total still counts.
        let (db3, dir3) = try makeDB()
        _ = try RemoteImport.importFile(try write([
            coveredCompletion(), droidLine(model: "kimi-k3", response: "r1"), completionLine(session: "other-session"),
        ], in: dir3), db: db3)
        XCTAssertEqual(try rows(db3).map(\.sessionId).sorted(), ["other-session", session].sorted())
    }

    func testOtherLinesAreSkippedAndBrokenOnesCounted() throws {
        let (db, dir) = try makeDB()
        let file = try write([
            "{\"type\":\"message\",\"text\":\"SENTINEL-MESSAGE\"}",
            "{\"type\":\"tool_call\",\"name\":\"Execute\"}",
            "[2026-10-16T21:40:00.000Z] INFO: [Agent] some other record | Context: {\"text\":\"SENTINEL\"}",
            "{\"type\":\"assistant\",\"message\":",
            "",
        ], in: dir)
        let report = try RemoteImport.importFile(file, db: db)
        XCTAssertEqual(report.rowsInserted, 0)
        XCTAssertEqual(report.parseErrors, 1)
        XCTAssertTrue(try rows(db).isEmpty)
    }

    func testCloudTokensCountInTheTotalAndAreNamedAsRemote() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        _ = try service.importRemote(try write([droidLine(model: "kimi-k3", response: "r1", ts: UTC.iso(Date()))], in: dir))
        let report = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertEqual(report.totals.remoteTokens, 2_160, "every bucket counts, as for local Droid")
        XCTAssertEqual(report.totals.tokens, 2_160)
        XCTAssertNil(report.rows.first?.usdEstimate, "a subscription run is not priced")
        let cloud = try service.spend(range: .month, by: .model, source: .cloud)
        XCTAssertEqual(cloud.rows.map(\.model), ["kimi-k3"])
    }

    func testTheDropFolderImportsOnceAndMovesFilesAside() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let imports = service.importsDir
        XCTAssertEqual(imports.deletingLastPathComponent(), db.path.deletingLastPathComponent(),
                       "beside the catalog, so a test catalog never drains the real folder")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        _ = try write([droidLine(model: "kimi-k3", response: "r1")], in: imports, name: "run1.jsonl")
        let report = RemoteImport.drain(imports, db: db, now: Date().addingTimeInterval(120))
        XCTAssertEqual(report.rowsInserted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imports.appendingPathComponent("run1.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.appendingPathComponent("imported/run1.jsonl").path))
        XCTAssertEqual(RemoteImport.drain(imports, db: db, now: Date().addingTimeInterval(120)).rowsInserted, 0, "the imported/ folder is not read again")
    }
}
