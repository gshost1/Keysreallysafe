import XCTest
@testable import KeysCore

/// Droid ingest: one row per nonzero `[Agent] Streaming result` record, and nothing else
/// from the log — not message content, not the non-whitelisted tag ids.
final class DroidIngestTests: XCTestCase {
    private let sentinels = [
        "SENTINEL-STREAMING-TEXT-CONTENT", "SENTINEL-REQUEST-BODY-CONTENT", "SENTINEL-TOOL-RESULT-CONTENT",
        "HOSTID-SENTINEL", "COMPUTERID-SENTINEL", "INSTALLATIONID-SENTINEL",
        "TRACEID-SENTINEL", "SPANID-SENTINEL", "MISSIONID-SENTINEL",
    ]

    private func resultLine(
        ts: String = "2026-10-10T20:18:27.378Z",
        model: String = "claude-sonnet-5",
        session: String = "aaaaaaaa-0000-4000-8000-000000000001",
        input: Int = 1200, cacheRead: Int = 30_000, cacheWrite: Int = 500,
        output: Int = 340, reasoning: Int = 0,
        total: Int = 31_700, count: Int = 1,
        responseId: String? = "up-resp-active-1", requestId: String? = "up-req-active-1"
    ) -> String {
        var json = "{\"count\":\(count),\"inputTokens\":\(input),\"cacheReadInputTokens\":\(cacheRead)"
        json += ",\"cachedTokensWritten\":\(cacheWrite),\"totalInputTokens\":\(total)"
        json += ",\"outputTokens\":\(output),\"reasoningTokens\":\(reasoning)"
        if let requestId { json += ",\"upstreamRequestId\":\"\(requestId)\"" }
        if let responseId { json += ",\"upstreamResponseId\":\"\(responseId)\"" }
        json += ",\"tags\":{\"sessionId\":\"\(session)\",\"modelId\":\"\(model)\""
        json += ",\"hostId\":\"HOSTID-SENTINEL\",\"traceId\":\"TRACEID-SENTINEL\"}}"
        return "[\(ts)] INFO: [Agent] Streaming result | Context: \(json)"
    }

    func testStreamingResultYieldsOneRowWithRawBuckets() throws {
        let event = try XCTUnwrap(try DroidIngest.parseLine(resultLine()))
        XCTAssertEqual(event.source, "droid-local")
        XCTAssertEqual(event.model, "claude-sonnet-5")
        XCTAssertEqual(event.provider, "anthropic")
        XCTAssertEqual(event.sessionId, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(event.promptId, "up-resp-active-1", "the response id wins over the request id")
        XCTAssertEqual(event.occurredAt, "2026-10-10T20:18:27Z")
        XCTAssertEqual(event.inputTokens, 1200)
        XCTAssertEqual(event.cachedReadTokens, 30_000)
        XCTAssertEqual(event.cacheCreationTokens, 500)
        XCTAssertEqual(event.outputTokens, 340)
        XCTAssertEqual(event.reasoningTokens, 0)
    }

    func testTotalInputTokensAndCountAreNeverAddedToTheirParts() throws {
        let event = try XCTUnwrap(try DroidIngest.parseLine(
            resultLine(input: 3, cacheRead: 0, cacheWrite: 0, output: 4, reasoning: 5, total: 999_999, count: 7)
        ))
        XCTAssertEqual(event.tokenCount, 12, "3 + 4 + 5; the repeated total and the record count stay out")
        XCTAssertNil(event.modelCalls, "the log's count numbers records, not model calls")
    }

    func testZeroTokenRecordsAreSkipped() throws {
        XCTAssertNil(try DroidIngest.parseLine(
            resultLine(input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)
        ))
    }

    func testMissingUpstreamIdsFallBackToAStableSyntheticPromptId() throws {
        let line = resultLine(responseId: nil, requestId: nil)
        let a = try XCTUnwrap(try DroidIngest.parseLine(line))
        let b = try XCTUnwrap(try DroidIngest.parseLine(line))
        XCTAssertEqual(a.promptId, b.promptId)
        XCTAssertEqual(a.promptId.count, 64)
        let requestOnly = try XCTUnwrap(try DroidIngest.parseLine(resultLine(responseId: nil)))
        XCTAssertEqual(requestOnly.promptId, "up-req-active-1")
    }

    func testOnlyTheExactStreamingResultMarkerIsParsed() throws {
        let dropped = [
            "[2026-10-10T20:18:26.900Z] INFO: [Agent] Streaming text | Context: {\"text\":\"SENTINEL-STREAMING-TEXT-CONTENT\"}",
            "[2026-10-10T09:04:10.500Z] INFO: [Gateway] Request | Context: {\"body\":\"SENTINEL-REQUEST-BODY-CONTENT\"}",
            "[2026-10-10T20:18:27.378Z] DEBUG: [Agent] Streaming result | Context: {\"inputTokens\":1,\"outputTokens\":1}",
            "[2026-10-10T20:18:27.378Z] INFO: [Agent] Streaming results | Context: {\"inputTokens\":1,\"outputTokens\":1}",
            "[2026-10-10T20:18:27.378Z] INFO: [Agent] Streaming result Context: {\"inputTokens\":1,\"outputTokens\":1}",
            "[2026-10-10T20:18:27.378Z] INFO: [Agent] Streaming result | Context: [1,2]",
        ]
        for line in dropped {
            XCTAssertNil(try DroidIngest.parseLine(line), line)
        }
    }

    func testProviderComesFromTheModelPrefix() {
        let cases = [
            ("claude-sonnet-5", "anthropic"), ("gpt-6-pro", "openai"), ("o4-mini", "openai"),
            ("codex-mini", "openai"), ("gemini-3-pro", "google"), ("grok-4-fast", "xai"),
            ("glm-5.3", "zhipu"), ("kimi-k3", "moonshot"), ("deepseek-v3", "deepseek"),
            ("qwen-max", "other"), ("unknown", "other"),
        ]
        for (model, provider) in cases {
            XCTAssertEqual(DroidIngest.provider(forModel: model), provider, model)
        }
    }

    func testIsUsageLogAcceptsTheActiveLogAndDatedRotationsOnly() {
        XCTAssertTrue(DroidIngest.isUsageLog("droid-log-single.log"))
        XCTAssertTrue(DroidIngest.isUsageLog("droid-log-single.log.2026-09-30"))
        XCTAssertFalse(DroidIngest.isUsageLog("droid-log-single.log.tmp"))
        XCTAssertFalse(DroidIngest.isUsageLog("droid-log-single.log.2026-9-3"))
        XCTAssertFalse(DroidIngest.isUsageLog("droid-log-single.log.2026-09-30.part"))
        XCTAssertFalse(DroidIngest.isUsageLog("unified.jsonl"))
        XCTAssertFalse(DroidIngest.isUsageLog(".droid-log-single.log.swp"))
    }

    func testRunIngestsActiveAndRotatedFilesOnce() throws {
        let (db, _) = try makeDB()
        let first = try DroidIngest.run(home: Fixtures.droidHome, db: db)
        XCTAssertEqual(first.filesScanned, 2, "the active log and the dated rotation")
        XCTAssertEqual(first.rowsInserted, 7)
        XCTAssertEqual(first.rowsUpdated, 0)
        let expected: [String: Int] = [
            "claude-sonnet-5": 2, "gpt-6-pro": 1, "gemini-3-pro": 1,
            "glm-5.3": 1, "kimi-k3": 1, "grok-4-fast": 1,
        ]
        let byModel: [String: Int] = try db.allUsageEvents().reduce(into: [:]) { out, event in
            out[event.model, default: 0] += 1
        }
        XCTAssertEqual(byModel, expected, "per-model rows match Fixtures/droid-home/README.md")

        let second = try DroidIngest.run(home: Fixtures.droidHome, db: db)
        XCTAssertEqual(second.rowsInserted, 0)
        XCTAssertEqual(second.rowsUpdated, 0, "unchanged files are not re-read")
        XCTAssertEqual(try db.allUsageEvents().count, 7)

        // A replay (here: a cursor the engine cannot trust) upserts instead of duplicating.
        let path = Fixtures.droidHome.appendingPathComponent("logs/droid-log-single.log").standardizedFileURL.path
        let prev = try XCTUnwrap(db.ingestFile(path: path))
        try db.upsertIngestFile(path: path, size: prev.size + 1, mtimeMs: prev.mtimeMs + 1, byteOffset: 3)
        let replay = try DroidIngest.run(home: Fixtures.droidHome, db: db)
        XCTAssertEqual(replay.rowsInserted, 0)
        XCTAssertEqual(replay.rowsUpdated, 3, "the active log holds 3 nonzero records")
        XCTAssertEqual(try db.allUsageEvents().count, 7)
    }

    func testNothingButUsageFieldsReachesTheCatalog() throws {
        let (db, dir) = try makeDB()
        _ = try DroidIngest.run(home: Fixtures.droidHome, db: db)
        let blob = try db.allUsageEvents()
            .map { "\($0.source) \($0.sessionId) \($0.promptId) \($0.model) \($0.occurredAt) \($0.provider)" }
            .joined()
        for sentinel in sentinels {
            XCTAssertFalse(blob.contains(sentinel), sentinel)
        }
        // The whole catalog file, WAL included: no sentinel bytes from content records or tags.
        for name in ["catalog.db", "catalog.db-wal"] {
            let url = dir.appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: url) else { continue }
            for sentinel in sentinels {
                XCTAssertNil(bytes.range(of: Data(sentinel.utf8)), "\(name) holds \(sentinel)")
            }
        }
    }

    func testAppendedLineIsPickedUpIncrementally() throws {
        let home = try TempDir.make()
        let sourceLogs = Fixtures.droidHome.appendingPathComponent("logs")
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: sourceLogs.path) {
            try fm.copyItem(at: sourceLogs.appendingPathComponent(name), to: logs.appendingPathComponent(name))
        }
        let active = logs.appendingPathComponent("droid-log-single.log")

        let (db, _) = try makeDB()
        XCTAssertEqual(try DroidIngest.run(home: home, db: db).rowsInserted, 7)

        let handle = try FileHandle(forWritingTo: active)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((resultLine(ts: "2026-10-10T22:30:00.000Z", model: "claude-opus-5") + "\n").utf8))
        try handle.close()
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: active.path)

        let again = try DroidIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 1)
        XCTAssertEqual(again.rowsUpdated, 0)
        XCTAssertEqual(try db.allUsageEvents().count, 8)
    }

    func testSourcesAndFiltersAcceptDroid() throws {
        XCTAssertEqual(Ingest.Source(rawValue: "droid"), .droid)
        XCTAssertEqual(SourceFilter(rawValue: "droid"), .droid)
        XCTAssertEqual(SourceFilter.droid.sqlValues, ["droid-local"])
        let event = try XCTUnwrap(try DroidIngest.parseLine(resultLine()))
        XCTAssertEqual(TokenTotals.normalized(event), 32_040, "all five buckets count for droid-local")
    }

    func testServiceIngestAndSpendExposeTheDroidLedger() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let reports = try service.ingest(.droid)
        XCTAssertEqual(reports.map(\.name), ["droid"])
        XCTAssertEqual(reports[0].report.rowsInserted, 7)
        XCTAssertTrue(try service.ingest(.all).contains { $0.name == "droid" }, "the scheduled pass reads Droid too")

        let utc = TimeZone(identifier: "UTC")!
        // The active log's records are October; the rotated file holds the previous month.
        let october = try XCTUnwrap(UTC.parse("2026-10-10T22:00:00Z"))
        let active = try service.spend(range: .month, by: .model, source: .droid, now: october, timeZone: utc)
        XCTAssertEqual(active.totals.tokens, 75_308)
        XCTAssertEqual(active.rows.compactMap(\.model).sorted(), ["claude-sonnet-5", "gpt-6-pro"])
        let claude = try XCTUnwrap(active.rows.first { $0.model == "claude-sonnet-5" })
        XCTAssertEqual(claude.inputTokens + claude.outputTokens + claude.cachedReadTokens
                       + claude.cacheCreationTokens + claude.reasoningTokens, 74_352)

        let september = try XCTUnwrap(UTC.parse("2026-09-30T23:00:00Z"))
        let rotated = try service.spend(range: .month, by: .model, source: .droid, now: september, timeZone: utc)
        XCTAssertEqual(rotated.totals.tokens, 6_274, "the rotated file's records are queryable history")
        XCTAssertEqual(rotated.rows.compactMap(\.model).sorted(), ["gemini-3-pro", "glm-5.3", "grok-4-fast", "kimi-k3"])

        let codex = try service.spend(range: .month, by: .model, source: .openai, now: october, timeZone: utc)
        XCTAssertFalse(codex.rows.contains { $0.source == "droid-local" }, "the codex filter must not leak Droid rows")
    }

    func testPostIngestAcceptsTheDroidSource() throws {
        let (handler, _, _) = try makeHandler()
        let response = handle(
            handler,
            method: "POST",
            path: "/api/ingest",
            body: try JSONValue.data(["source": "droid"])
        )
        XCTAssertEqual(response.status, 200)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let droid = try XCTUnwrap(obj["droid"] as? [String: Any])
        XCTAssertEqual(droid["files"] as? Int, 2)
        XCTAssertEqual(droid["inserted"] as? Int, 7)
    }
}
