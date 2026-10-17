import XCTest
@testable import KeysCore

/// The review round on remote import (M1-review F1, F4-F6, F8-F12, F14): hostile export files,
/// the drop folder's filesystem edge cases, the command's per-path loop, session-total
/// residuals and the places remote rows must never reach.
final class RemoteImportHardeningTests: XCTestCase {
    private let session = "cccccccc-0000-4000-8000-000000000003"
    private let wide = "0000-01-01T00:00:00Z"

    // MARK: Fixtures

    private func droidLine(response: String = "r1", model: String = "kimi-k3", session: String? = nil,
                           stamp: String = "2026-10-16T21:40:00.000Z", input: String = "100",
                           output: String = "50", cacheRead: String = "2000") -> String {
        "[\(stamp)] INFO: [Agent] Streaming result | Context: "
            + "{\"inputTokens\":\(input),\"cacheReadInputTokens\":\(cacheRead),\"cachedTokensWritten\":0,"
            + "\"outputTokens\":\(output),\"reasoningTokens\":10,\"upstreamResponseId\":\"\(response)\","
            + "\"tags\":{\"modelId\":\"\(model)\",\"sessionId\":\"\(session ?? self.session)\"}}"
    }

    private func claudeLine(request: String = "req_1", session: String = "cloud-1", model: String = "claude-opus-5-5",
                            stamp: String = "\"2026-10-16T18:00:00.000Z\"", input: String = "10",
                            output: String = "20") -> String {
        "{\"type\":\"assistant\",\"sessionId\":\"\(session)\",\"requestId\":\"\(request)\","
            + "\"timestamp\":\(stamp),\"cwd\":\"/home/user/repo\","
            + "\"message\":{\"id\":\"msg_1\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),"
            + "\"output_tokens\":\(output),\"cache_read_input_tokens\":300,\"cache_creation_input_tokens\":40}}}"
    }

    private func completionLine(session: String? = nil, input: String = "138", output: String = "165253",
                                stamp: String = "1792118855901", cacheRead: String = "3573444",
                                cacheWrite: String = "645689", thinking: String = "56728") -> String {
        "{\"type\":\"completion\",\"session_id\":\"\(session ?? self.session)\",\"timestamp\":\(stamp),"
            + "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),"
            + "\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheWrite),"
            + "\"thinking_tokens\":\(thinking)}}"
    }

    private func write(_ lines: [String], in dir: URL, name: String = "export.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func rows(_ db: CatalogDB, _ source: SourceFilter = .all) throws -> [UsageEvent] {
        try db.usageEvents(from: "1970-01-01T00:00:00Z", to: "2100-01-01T00:00:00Z", source: source)
            .sorted { ($0.source, $0.promptId, $0.model) < ($1.source, $1.promptId, $1.model) }
    }

    private func tempCatalog() throws -> (CatalogDB, URL) {
        let (db, dir) = try makeDB()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (db, dir)
    }

    private var later: Date { Date().addingTimeInterval(120) }

    // MARK: F1 token buckets

    func testHostileTokenBucketsAreParseErrorsForEveryRemoteLineKind() throws {
        let hostile = ["-5", "1000000000001", "1e30", "9223372036854775807", "5.5", "5.0", "true", "\"7\"",
                       "[1]", "{\"a\":1}", "99999999999999999999999"]
        for bad in hostile {
            let (db, dir) = try tempCatalog()
            let lines = [
                droidLine(input: bad),
                droidLine(response: "r2", output: bad),
                droidLine(response: "r3", cacheRead: bad),
                claudeLine(input: bad),
                claudeLine(request: "req_2", output: bad),
                completionLine(input: bad),
                completionLine(session: "s2", cacheWrite: bad),
                completionLine(session: "s3", thinking: bad),
            ]
            let report = try RemoteImport.importFile(try write(lines, in: dir), db: db)
            XCTAssertEqual(report.rowsInserted, 0, "\(bad) stored a row")
            XCTAssertEqual(report.parseErrors, lines.count, "\(bad) was not a parse error on every line kind")
            XCTAssertTrue(try rows(db).isEmpty)
        }
    }

    func testTheLargestAcceptedBucketIsAMillionMillionAndZeroAndAbsentAreFine() throws {
        let (db, dir) = try tempCatalog()
        let report = try RemoteImport.importFile(try write([
            droidLine(input: "1000000000000"), claudeLine(request: "r2", input: "0"),
        ], in: dir), db: db)
        XCTAssertEqual(report.parseErrors, 0)
        XCTAssertEqual(report.rowsInserted, 2)
    }

    func testSpendTotalsSaturateInsteadOfTrappingOnStoredRowsFromAnyBuggySource() throws {
        let (db, _) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        let at = UTC.iso(Date())
        for (source, provider) in [("droid-remote", "other"), ("claude-remote", "anthropic"), ("droid-local", "other"),
                                   ("claude-local", "anthropic"), ("codex-local", "openai"), ("grok-local", "xai")] {
            for n in 0..<2 {
                _ = try db.insertUsage(UsageEvent(
                    source: source, sessionId: "s\(n)", promptId: "p\(n)", model: "m-\(source)", occurredAt: at,
                    provider: provider, inputTokens: Int.max, outputTokens: Int.max, cachedReadTokens: Int.max,
                    cacheCreationTokens: Int.max, reasoningTokens: Int.max))
            }
        }
        let report = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertEqual(report.totals.tokens, Int.max)
        XCTAssertEqual(report.totals.remoteTokens, Int.max)
        XCTAssertEqual(report.rows.count, 6)
        _ = try service.spend(range: .month, by: .session, source: .all)
        _ = report.jsonObject()
    }

    func testANegativeStoredBucketCannotMakeTheTotalNegativeEither() {
        var event = UsageEvent.fixture(source: "droid-remote")
        event.inputTokens = Int.min
        event.outputTokens = Int.min
        XCTAssertEqual(TokenTotals.normalized(event), Int.min, "saturates at the bound rather than trapping")
    }

    // MARK: F4 size cap and regular files

    private func sparse(_ url: URL, bytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    func testAnOversizeFileIsRefusedAndASymlinkToItCannotBypassTheCap() throws {
        let (db, dir) = try tempCatalog()
        let big = dir.appendingPathComponent("big.jsonl")
        try sparse(big, bytes: UInt64(RemoteImport.maxFileBytes) + 1)
        XCTAssertThrowsError(try RemoteImport.importFile(big, db: db))
        let link = dir.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        XCTAssertThrowsError(try RemoteImport.importFile(link, db: db)) { error in
            XCTAssertTrue("\(error)".contains("larger"), "\(error)")
        }
    }

    func testEveryNonRegularPathIsRefusedByNameWithoutTraceNames() throws {
        let (db, dir) = try tempCatalog()
        XCTAssertThrowsError(try RemoteImport.importFile(dir, db: db))
        XCTAssertThrowsError(try RemoteImport.importFile(dir.appendingPathComponent("nope.jsonl"), db: db))
        let fifo = dir.appendingPathComponent("pipe.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try RemoteImport.importFile(fifo, db: db))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a FIFO must not block the import")
    }

    func testTheDropFolderReadsAndMovesRegularFilesOnly() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = try write([droidLine()], in: outside, name: "secret.jsonl")
        try fm.createSymbolicLink(at: imports.appendingPathComponent("link.jsonl"), withDestinationURL: target)
        try fm.createSymbolicLink(at: imports.appendingPathComponent("dirlink"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: imports.appendingPathComponent("dangling.jsonl"),
                                  withDestinationURL: dir.appendingPathComponent("missing"))
        let big = outside.appendingPathComponent("big.jsonl")
        try sparse(big, bytes: UInt64(RemoteImport.maxFileBytes) + 1)
        try fm.createSymbolicLink(at: imports.appendingPathComponent("biglink.jsonl"), withDestinationURL: big)
        XCTAssertEqual(mkfifo(imports.appendingPathComponent("pipe.jsonl").path, 0o600), 0)
        try fm.createDirectory(at: imports.appendingPathComponent("subdir"), withIntermediateDirectories: false)
        _ = try write([droidLine(response: "dot")], in: imports, name: ".hidden.jsonl")

        let started = Date()
        let report = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(report.rowsInserted, 0)
        XCTAssertTrue(try rows(db).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: target.path), "the file behind a link was neither read nor moved")
        for name in ["link.jsonl", "dirlink", "dangling.jsonl", "biglink.jsonl", "pipe.jsonl", "subdir", ".hidden.jsonl"] {
            let path = imports.appendingPathComponent(name).path
            var info = stat()
            XCTAssertEqual(lstat(path, &info), 0, "\(name) stays in the folder")
        }
        XCTAssertFalse(fm.fileExists(atPath: imports.appendingPathComponent("imported/link.jsonl").path))
    }

    // MARK: F5 settle time and what moves

    func testTheDropFolderCreatesImportsWhenMissing() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imports.path))
        _ = RemoteImport.drain(imports, db: db)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testAFileModifiedInTheLastTenSecondsWaitsForTheNextPass() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        _ = try write([droidLine()], in: imports, name: "fresh.jsonl")
        let early = RemoteImport.drain(imports, db: db)
        XCTAssertEqual(early.rowsInserted, 0, "still being written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.appendingPathComponent("fresh.jsonl").path))
        let settled = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertEqual(settled.rowsInserted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.appendingPathComponent("imported/fresh.jsonl").path))
    }

    func testAFileWithParseErrorsOrNoRowsStaysPutAndIsNamed() throws {
        let (db, dir) = try tempCatalog()
        let imports = dir.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        _ = try write([droidLine(response: "ok"), "{\"type\":\"assistant\",\"message\":"], in: imports, name: "truncated.jsonl")
        _ = try write(["{\"type\":\"message\",\"text\":\"hello\"}"], in: imports, name: "nonusage.jsonl")
        _ = try write([droidLine(response: "fine", session: "other")], in: imports, name: "good.jsonl")
        let report = RemoteImport.drain(imports, db: db, now: later)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: imports.appendingPathComponent("truncated.jsonl").path))
        XCTAssertTrue(fm.fileExists(atPath: imports.appendingPathComponent("nonusage.jsonl").path))
        XCTAssertTrue(fm.fileExists(atPath: imports.appendingPathComponent("imported/good.jsonl").path))
        XCTAssertEqual(report.held.sorted(), ["nonusage.jsonl", "truncated.jsonl"])
        XCTAssertTrue(report.line.contains("truncated.jsonl"), report.line)
        XCTAssertEqual(try rows(db).count, 2, "the good lines of the truncated file are stored; the file waits to be fixed")
        // The retry is idempotent: nothing is counted twice.
        _ = RemoteImport.drain(imports, db: db, now: later)
        XCTAssertEqual(try rows(db).count, 2)
    }

    // MARK: F6 the command's loop

    func testImportAllAttemptsEveryPathPrintsOneLineEachAndFailsIfAnyFailed() throws {
        let (db, dir) = try tempCatalog()
        let good = try write([droidLine()], in: dir, name: "good.jsonl")
        let broken = try write(["{\"type\":\"assistant\",\"message\":"], in: dir, name: "broken.jsonl")
        let empty = try write([], in: dir, name: "empty.jsonl")
        let missing = dir.appendingPathComponent("nope.jsonl").path
        var lines: [String] = []
        let failed = UsageImportRun.run(paths: [missing, good.path, dir.path, broken.path, empty.path],
                                        importer: { try RemoteImport.importFile($0, db: db) },
                                        emit: { lines.append($0) })
        XCTAssertTrue(failed)
        XCTAssertEqual(lines.count, 5, "one line per path: \(lines)")
        XCTAssertTrue(lines[0].hasPrefix("nope.jsonl: "), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("good.jsonl: files=1 inserted=1"), lines[1])
        XCTAssertTrue(lines[3].hasPrefix("broken.jsonl: "), lines[3])
        XCTAssertEqual(try rows(db).count, 1, "the good file after a bad path was still imported")
        for line in lines {
            for trace in ["Fatal error", "Error domain", "KeysCore.", "AppError"] { XCTAssertFalse(line.contains(trace), line) }
        }
    }

    func testImportAllSucceedsWhenEveryFileStoredRows() throws {
        let (db, dir) = try tempCatalog()
        let a = try write([droidLine()], in: dir, name: "a.jsonl")
        let b = try write([claudeLine()], in: dir, name: "b.jsonl")
        var lines: [String] = []
        XCTAssertFalse(UsageImportRun.run(paths: [a.path, b.path], importer: { try RemoteImport.importFile($0, db: db) },
                                          emit: { lines.append($0) }))
        XCTAssertEqual(lines.count, 2)
    }

    func testAFileWithOnlyParseErrorsFailsTheRunButAnEmptyOneDoesNot() throws {
        let (db, dir) = try tempCatalog()
        let broken = try write(["{\"type\":\"assistant\",\"message\":"], in: dir, name: "broken.jsonl")
        let empty = try write([], in: dir, name: "empty.jsonl")
        XCTAssertTrue(UsageImportRun.run(paths: [broken.path], importer: { try RemoteImport.importFile($0, db: db) }, emit: { _ in }))
        XCTAssertFalse(UsageImportRun.run(paths: [empty.path], importer: { try RemoteImport.importFile($0, db: db) }, emit: { _ in }))
    }

    func testTheCommandHelpStatesTheEveryPathAndExitRules() {
        let text = UsageImportCommand.configuration.discussion.lowercased()
        XCTAssertTrue(text.contains("every path"), text)
        XCTAssertTrue(text.contains("non-zero"), text)
    }

    // MARK: F9 residual

    private func totalRow(_ db: CatalogDB) throws -> UsageEvent? {
        try rows(db).first { $0.model == "unattributed" }
    }

    func testPerRequestRowsKeepWhatTheyDoNotCoverOfASessionTotal() throws {
        // Total: input 138, output 165253, cacheRead 3573444, cacheWrite 645689, reasoning 56728.
        let (db, dir) = try tempCatalog()
        let report = try RemoteImport.importFile(try write([
            completionLine(), droidLine(input: "100", output: "50", cacheRead: "2000"),
        ], in: dir), db: db)
        XCTAssertEqual(report.parseErrors, 0)
        let residual = try XCTUnwrap(try totalRow(db))
        XCTAssertEqual(residual.inputTokens, 138 - 100)
        XCTAssertEqual(residual.outputTokens, 165_253 - 50)
        XCTAssertEqual(residual.cachedReadTokens, 3_573_444 - 2_000)
        XCTAssertEqual(residual.cacheCreationTokens, 645_689, "the rows reported no cache writes")
        XCTAssertEqual(residual.reasoningTokens, 56_728 - 10)
        XCTAssertEqual(try rows(db).count, 2)
    }

    func testTheResidualIsDeletedWhenTheRowsCoverTheTotalAndNeverGoesNegative() throws {
        let (db, dir) = try tempCatalog()
        _ = try RemoteImport.importFile(try write([
            completionLine(input: "10", output: "10", cacheRead: "10", cacheWrite: "0", thinking: "5"),
            droidLine(input: "100", output: "50", cacheRead: "2000"),
        ], in: dir), db: db)
        XCTAssertNil(try totalRow(db), "rows of 100/50/2000/0/10 cover a 10/10/10/0/5 total in every bucket")
        XCTAssertEqual(try rows(db).map(\.model), ["kimi-k3"])
    }

    func testTheResidualShrinksAsRowsArriveInLaterImports() throws {
        let (db, dir) = try tempCatalog()
        _ = try RemoteImport.importFile(try write([
            completionLine(input: "1000", output: "1000", cacheRead: "1000", cacheWrite: "1000", thinking: "1000"),
        ], in: dir, name: "total.jsonl"), db: db)
        XCTAssertEqual(try totalRow(db)?.inputTokens, 1000)
        _ = try RemoteImport.importFile(try write([droidLine(input: "300", output: "100", cacheRead: "200")], in: dir, name: "r1.jsonl"), db: db)
        var residual = try XCTUnwrap(try totalRow(db))
        XCTAssertEqual([residual.inputTokens, residual.outputTokens, residual.cachedReadTokens, residual.cacheCreationTokens, residual.reasoningTokens],
                       [700, 900, 800, 1000, 990])
        _ = try RemoteImport.importFile(try write([droidLine(response: "r2", input: "500", output: "100", cacheRead: "200")], in: dir, name: "r2.jsonl"), db: db)
        residual = try XCTUnwrap(try totalRow(db))
        XCTAssertEqual([residual.inputTokens, residual.outputTokens, residual.cachedReadTokens],
                       [200, 800, 600])
        // Re-importing the same rows changes nothing.
        _ = try RemoteImport.importFile(try write([droidLine(input: "300", output: "100", cacheRead: "200")], in: dir, name: "r1.jsonl"), db: db)
        XCTAssertEqual(try totalRow(db)?.inputTokens, 200)
    }

    func testATotalForASessionWithRowsOnlyKeepsWhatTheRowsMiss() throws {
        let (db, dir) = try tempCatalog()
        _ = try RemoteImport.importFile(try write([droidLine(input: "100", output: "50", cacheRead: "0")], in: dir, name: "r.jsonl"), db: db)
        _ = try RemoteImport.importFile(try write([completionLine(input: "150", output: "50", cacheRead: "0", cacheWrite: "0", thinking: "10")],
                                                  in: dir, name: "t.jsonl"), db: db)
        let residual = try XCTUnwrap(try totalRow(db))
        XCTAssertEqual([residual.inputTokens, residual.outputTokens, residual.reasoningTokens], [50, 0, 0])
    }

    func testTwoTotalsForOneSessionKeepOneRowAndASessionWithoutRowsKeepsItsTotal() throws {
        let (db, dir) = try tempCatalog()
        let report = try RemoteImport.importFile(try write([
            completionLine(input: "1"), completionLine(input: "2"), completionLine(session: "lone", input: "9"),
        ], in: dir), db: db)
        XCTAssertEqual(report.parseErrors, 0)
        let stored = try rows(db)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first { $0.sessionId == session }?.inputTokens, 2)
        XCTAssertEqual(stored.first { $0.sessionId == "lone" }?.inputTokens, 9)
    }

    // MARK: F10 rows this Mac already holds

    func testARemoteLineThisMacAlreadyRecordedLocallyIsSkippedNotInserted() throws {
        let (db, dir) = try tempCatalog()
        _ = try db.insertUsage(UsageEvent(source: "droid-local", sessionId: "local-sess", promptId: "r1", model: "kimi-k3",
            occurredAt: "2026-10-16T21:40:00Z", provider: "moonshot", inputTokens: 100, outputTokens: 0))
        _ = try db.insertUsage(UsageEvent(source: "claude-local", sessionId: "local-claude", promptId: "req_1",
            model: "claude-opus-5-5", occurredAt: "2026-10-16T18:00:00Z", provider: "anthropic", inputTokens: 10, outputTokens: 20))
        let report = try RemoteImport.importFile(try write([
            droidLine(response: "r1"), claudeLine(request: "req_1"), droidLine(response: "r-new"),
        ], in: dir), db: db)
        XCTAssertEqual(report.rowsInserted, 1)
        XCTAssertEqual(report.rowsSkipped, 2)
        XCTAssertEqual(try rows(db, .cloud).map(\.promptId), ["r-new"])
        // The same prompt under a different model is a different call and is kept.
        let other = try RemoteImport.importFile(try write([droidLine(response: "r1", model: "glm-5.3")], in: dir, name: "o.jsonl"), db: db)
        XCTAssertEqual(other.rowsInserted, 1)
    }

    // MARK: F11 timestamps, ids and the epoch sentinel

    func testATimestampThatIsNotAnInstantIsAParseError() throws {
        let (db, dir) = try tempCatalog()
        let long = String(repeating: "x", count: 10_000)
        let lines = [
            droidLine(response: "a", stamp: "not-a-time"),
            droidLine(response: "b", stamp: long),
            "x" + droidLine(response: "c").drop(while: { $0 != "]" }),
            claudeLine(request: "d", stamp: "\"yesterday\""),
            claudeLine(request: "e", stamp: "12"),
            claudeLine(request: "f", stamp: "null"),
            completionLine(session: "g", stamp: "\"soon\""),
            completionLine(session: "h", stamp: "-1"),
            completionLine(session: "i", stamp: "1.5e12"),
        ]
        let report = try RemoteImport.importFile(try write(lines, in: dir), db: db)
        XCTAssertEqual(report.rowsInserted, 0)
        XCTAssertEqual(report.parseErrors, lines.count)
    }

    func testIsoStampsAndEpochMillisecondsAreStillAccepted() throws {
        let (db, dir) = try tempCatalog()
        let report = try RemoteImport.importFile(try write([
            droidLine(response: "a", stamp: "2026-10-16T21:40:00Z"),
            claudeLine(request: "b", stamp: "\"2026-10-16T18:00:00+00:00\""),
            completionLine(session: "c", stamp: "\"2026-10-16T02:47:35Z\""),
        ], in: dir), db: db)
        XCTAssertEqual(report.parseErrors, 0)
        XCTAssertEqual(report.rowsInserted, 3)
    }

    func testIdsLongerThanTheCapAreParseErrors() throws {
        let (db, dir) = try tempCatalog()
        let ok = String(repeating: "a", count: 128), over = String(repeating: "a", count: 129)
        let report = try RemoteImport.importFile(try write([
            droidLine(response: ok), droidLine(response: over), droidLine(response: "p", session: over),
            claudeLine(request: over), claudeLine(request: "q", session: over), completionLine(session: over),
            completionLine(session: ok),
        ], in: dir), db: db)
        XCTAssertEqual(report.rowsInserted, 2)
        XCTAssertEqual(report.parseErrors, 5)
    }

    func testReimportNeverReplacesAValidTimeWithTheEpochSentinel() throws {
        let (db, _) = try tempCatalog()
        let good = UsageEvent(source: "droid-remote", sessionId: "s", promptId: "p", model: "m",
                              occurredAt: "2026-10-16T21:40:00Z", provider: "other", inputTokens: 5, outputTokens: 0)
        _ = try db.insertUsage(good)
        var sentinel = good
        sentinel.occurredAt = "1970-01-01T00:00:00Z"
        sentinel.inputTokens = 6
        XCTAssertFalse(try db.insertUsage(sentinel))
        let stored = try XCTUnwrap(try rows(db).first)
        XCTAssertEqual(stored.occurredAt, "2026-10-16T21:40:00Z")
        XCTAssertEqual(stored.inputTokens, 6, "the rest of the row still updates")
    }

    // MARK: F8 caption

    func testTheSpendCaptionStopsCallingImportedUsageLocalSpend() throws {
        let (db, dir) = try tempCatalog()
        let (service, _, _) = makeService(db: db)
        let before = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertEqual(before.caption, SpendReport.captionText)
        XCTAssertTrue(before.caption.contains("local tool spend on this Mac"))
        _ = try service.importRemote(try write([droidLine(stamp: UTC.iso(Date()))], in: dir))
        let after = try service.spend(range: .month, by: .model, source: .all)
        XCTAssertGreaterThan(after.totals.remoteTokens, 0)
        XCTAssertFalse(after.caption.contains("local tool spend on this Mac"), after.caption)
        XCTAssertTrue(after.caption.contains("imported cloud usage"), after.caption)
        XCTAssertTrue(after.caption.contains("not priced"), after.caption)
        XCTAssertEqual(after.jsonObject()["caption"] as? String, after.caption)
    }

    // MARK: F12 places remote rows never reach

    func testRemoteRowsNeverEnterTheShareToCompareSummaries() throws {
        let (db, _) = try tempCatalog()
        let clock = ProductAnalyticsTests.Clock(), transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, endpoint: URL(string: "https://analytics.example/v1/reports")!,
                                         transport: transport, now: { clock.date() })   // 2026-05-19T04:00Z
        try analytics.setEnabled(true, consentVersion: 2)
        for (source, model) in [("droid-remote", "kimi-k3"), ("claude-remote", "claude-opus-5-5"),
                                ("droid-remote", "unattributed")] {
            _ = try db.insertUsage(UsageEvent(source: source, sessionId: "remote-session-secret", promptId: UUID().uuidString,
                model: model, occurredAt: "2026-05-19T05:00:00Z", provider: "anthropic", cwd: "/home/user/repo",
                inputTokens: 777_001, outputTokens: 5, cachedReadTokens: 1, cacheCreationTokens: 1, reasoningTokens: 1))
        }
        _ = try db.insertUsage(UsageEvent(source: "claude-local", sessionId: "s", promptId: "local", model: "claude-fable-5-1",
            occurredAt: "2026-05-19T06:00:00Z", provider: "anthropic", inputTokens: 100, outputTokens: 0))
        analytics.record(.viewUsage)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let data = try XCTUnwrap(transport.calls.first?.data)
        let text = String(decoding: data, as: UTF8.self)
        for banned in ["remote", "777001", "unattributed", "kimi-k3", "claude-opus-5-5", "/home/user"] {
            XCTAssertFalse(text.contains(banned), banned)
        }
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(sent["usage"] as? [[String: Any]])
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?["source"] as? String, "claude_code")
        XCTAssertEqual(usage.first?["input_tokens"] as? Int, 100)
    }

    func testDroidPlanWindowsIgnoreRemoteRows() throws {
        let (db, _) = try tempCatalog()
        let now = Date()
        let at = UTC.iso(now.addingTimeInterval(-600))
        _ = try db.insertUsage(UsageEvent(source: "droid-remote", sessionId: "s", promptId: "p", model: "kimi-k3",
            occurredAt: at, provider: "moonshot", inputTokens: 5_000_000, outputTokens: 0))
        XCTAssertEqual(try DroidUsage.windows(catalog: db, now: now), DroidUsage.Windows())
        _ = try db.insertUsage(UsageEvent(source: "droid-local", sessionId: "s", promptId: "p2", model: "kimi-k3",
            occurredAt: at, provider: "moonshot", inputTokens: 40, outputTokens: 0))
        XCTAssertEqual(try DroidUsage.windows(catalog: db, now: now).fiveHour, 40)
    }
}
