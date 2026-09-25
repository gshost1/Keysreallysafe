import XCTest
@testable import KeysCore

final class ProductAnalyticsTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_779_163_200) // a fixed UTC day
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    }
    final class Upload: AnalyticsUpload, @unchecked Sendable {
        let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    final class Transport: AnalyticsTransport, @unchecked Sendable {
        struct Call {
            let endpoint: URL
            let data: Data
            let complete: @Sendable (Bool) -> Void
            let upload: Upload
        }
        let lock = NSLock()
        private var storage: [Call] = []
        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storage }
        func send(to endpoint: URL, data: Data, completion: @escaping @Sendable (Bool) -> Void) -> any AnalyticsUpload {
            let upload = Upload()
            lock.lock(); storage.append(Call(endpoint: endpoint, data: data, complete: completion, upload: upload)); lock.unlock()
            return upload
        }
        struct Fetch {
            let url: URL
            let complete: @Sendable (Data?) -> Void
        }
        private var fetchStorage: [Fetch] = []
        var fetches: [Fetch] { lock.lock(); defer { lock.unlock() }; return fetchStorage }
        func fetch(from url: URL, maxBytes: Int, completion: @escaping @Sendable (Data?) -> Void) {
            lock.lock(); fetchStorage.append(Fetch(url: url, complete: completion)); lock.unlock()
        }
    }
    let endpoint = URL(string: "https://analytics.example/v1/reports")!

    func harness() throws -> (CatalogDB, Clock, Transport, ProductAnalytics) {
        let (db, directory) = try makeDB()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), transport = Transport()
        return (db, clock, transport, ProductAnalytics(catalog: db, endpoint: endpoint,
            transport: transport, now: { clock.date() }))
    }
    func reports(_ analytics: ProductAnalytics) throws -> [[String: Any]] {
        ((try analytics.status()["preview"] as? [String: Any])?["reports"] as? [[String: Any]]) ?? []
    }

    func testDefaultOffHasNoStorageNoUploadAndOldConsentCannotOptIn() throws {
        let (db, clock, transport, analytics) = try harness()
        analytics.record(.keyAdd)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
        XCTAssertNil(try db.metaValue(ProductAnalytics.stateKey))
        XCTAssertEqual(transport.calls.count, 0)
        XCTAssertThrowsError(try analytics.setEnabled(true, consentVersion: 1))
        XCTAssertEqual(transport.calls.count, 0)
    }

    func testConsentOnlyCollectsNewTypedCountersAndCoarseTimings() throws {
        let (_, _, transport, analytics) = try harness()
        analytics.record(.keyCopy)
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.viewKeys)
        analytics.record(.gatewaySuccess, durationMS: 25)
        analytics.record(.gatewayFailure, durationMS: 12_000)
        let report = try XCTUnwrap(reports(analytics).first)
        XCTAssertEqual(Set(report.keys), ["schema_version", "consent_version", "report_id", "day", "app_version", "os_major", "architecture", "counts", "usage", "windows", "gateway"])
        XCTAssertEqual(report["counts"] as? [String: Int], ["view_keys": 1, "gateway_success": 1,
            "gateway_lt_100ms": 1, "gateway_failure": 1, "gateway_gte_10s": 1])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(report["report_id"] as? String)))
        analytics.flushCompletedReports()
        XCTAssertTrue(transport.calls.isEmpty, "Current UTC day must stay local and mutable")
    }

    func testCompletedDayRetryIsImmutableAndAcknowledgmentPreservesNewDay() throws {
        let (_, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.viewKeys)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 1)
        analytics.record(.viewUsage)
        transport.calls[0].complete(false)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 1, "Failure must respect backoff")
        clock.advance(901)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        let first = try JSONSerialization.jsonObject(with: transport.calls[0].data) as! NSDictionary
        let retry = try JSONSerialization.jsonObject(with: transport.calls[1].data) as! NSDictionary
        XCTAssertEqual(first, retry)
        transport.calls[1].complete(true)
        XCTAssertEqual(try reports(analytics).count, 1)
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_usage": 1])
        XCTAssertEqual(try analytics.status()["last_result"] as? String, "sent")
    }

    func testOptOutCancelsAndLateOldCompletionCannotDetachNewUpload() throws {
        let (_, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.viewKeys)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let first = try XCTUnwrap(transport.calls.first)
        try analytics.setEnabled(false, consentVersion: 2)
        XCTAssertTrue(first.upload.isCancelled)
        XCTAssertTrue(try reports(analytics).isEmpty)
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.viewChart)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        first.complete(true) // A delayed callback from the previous consent epoch.
        XCTAssertEqual(try reports(analytics).count, 1)
        try analytics.setEnabled(false, consentVersion: 2)
        XCTAssertTrue(transport.calls[1].upload.isCancelled, "Stale completion must not detach the current upload")
        analytics.record(.keyAdd)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testClearKeepsConsentButDiscardsDataAndChangesNextReportIdentity() throws {
        let (_, _, _, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.keyAdd)
        let firstID = try reports(analytics).first?["report_id"] as? String
        try analytics.clear()
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, true)
        XCTAssertTrue(try reports(analytics).isEmpty)
        analytics.record(.viewUsage)
        XCTAssertNotEqual(try reports(analytics).first?["report_id"] as? String, firstID)
    }

    func testRetentionAndDestinationChangeRequireFreshConsent() throws {
        let (db, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.keyAdd)
        clock.advance(8 * 86_400)
        analytics.flushCompletedReports()
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(try reports(analytics).isEmpty)
        analytics.record(.viewKeys)
        let changed = ProductAnalytics(catalog: db, endpoint: URL(string: "https://different.example/v1/reports")!,
            transport: transport, now: { clock.date() })
        XCTAssertEqual(try changed.status()["enabled"] as? Bool, false)
        XCTAssertTrue(try reports(changed).isEmpty)
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
    }

    func testUnknownStoredFieldsAreDroppedAndBadSchemasOrCountersFailClosed() throws {
        let (db, _, _, analytics) = try harness()
        for alteration in 0..<5 {
            try analytics.setEnabled(true, consentVersion: 2)
            analytics.record(.viewUsage)
            var state = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(db.metaValue(ProductAnalytics.stateKey)).utf8)) as! [String: Any]
            var pending = state["reports"] as! [[String: Any]]
            let dropped: Bool
            switch alteration {
            case 0: state["future_schema_field"] = "private sample"; dropped = true
            case 1: state["schemaVersion"] = 1; dropped = false
            case 2: pending[0]["private_prompt"] = "do not send me"; state["reports"] = pending; dropped = true
            case 3: pending[0]["counts"] = ["unknown_event": 1]; state["reports"] = pending; dropped = false
            default: pending[0]["schema_version"] = 1; state["reports"] = pending; dropped = false
            }
            try db.setMeta(ProductAnalytics.stateKey, String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
            if dropped {
                // An unknown key is ignored and never sent; sharing and the day's counts survive.
                XCTAssertEqual(try analytics.status()["enabled"] as? Bool, true)
                XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_usage": 1])
                let stored = try XCTUnwrap(db.metaValue(ProductAnalytics.stateKey))
                XCTAssertFalse(stored.contains("private"), "the unknown key is not written back")
                try analytics.setEnabled(false, consentVersion: 2)
            } else {
                XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
                XCTAssertTrue(try reports(analytics).isEmpty)
            }
        }
    }

    func testTwoCatalogConnectionsShareConsentAndSerializeCounters() throws {
        let (db, clock, transport, analytics) = try harness()
        let secondDB = try CatalogDB(path: db.path)
        let second = ProductAnalytics(catalog: secondDB, endpoint: endpoint, transport: transport, now: { clock.date() })
        try analytics.setEnabled(true, consentVersion: 2)
        DispatchQueue.concurrentPerform(iterations: 100) { i in (i % 2 == 0 ? analytics : second).record(.viewKeys) }
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_keys": 100])
        clock.advance(86_400)
        analytics.flushCompletedReports()
        second.flushCompletedReports()
        // Two processes may both send a closed day; the bytes are identical, so the
        // collector acknowledges the second copy as a duplicate.
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(transport.calls[0].data, transport.calls[1].data)
        try second.setEnabled(false, consentVersion: 2)
        analytics.record(.viewKeys)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testAPIEnforcesOriginCSRFExplicitBooleanAndClosedEventShapeWithoutPresence() throws {
        let (db, _, _, analytics) = try harness()
        let presence = RecordingPresenceGate()
        let service = KeysService(catalog: db, secrets: GatedSecretStore(inner: MemorySecretStore(), presence: presence), clipboard: FakeClipboard())
        service.analytics = analytics
        let handler = APIHandler(service: service, webRoot: db.path.deletingLastPathComponent())
        func request(_ path: String, _ body: [String: Any], csrf: Bool = true, origin: String? = nil) throws -> Int {
            var headers = ["host": "127.0.0.1:12765"]
            if csrf { headers["x-ksf-token"] = handler.originToken }
            if let origin { headers["origin"] = origin }
            return handler.handle(HTTPRequest(method: "POST", path: path, query: [:], headers: headers,
                body: try JSONValue.data(body), serverPort: 12765)).status
        }
        let consent: [String: Any] = ["enabled": true, "consent_version": 2]
        XCTAssertEqual(try request("/api/analytics", consent, csrf: false), 403)
        XCTAssertEqual(try request("/api/analytics", consent, origin: "https://outside.example"), 403)
        XCTAssertEqual(try request("/api/analytics", ["enabled": 1, "consent_version": 2]), 400)
        XCTAssertEqual(try request("/api/analytics", ["enabled": true, "consent_version": 2, "endpoint": "https://evil.example"]), 400)
        XCTAssertEqual(try request("/api/analytics", consent), 200)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "view_keys", "prompt": "secret"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "arbitrary_secret"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "key_add"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "view_keys"]), 200)
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_keys": 1])
        XCTAssertTrue(presence.reasons.isEmpty)
        XCTAssertEqual(try request("/api/analytics", ["enabled": false, "consent_version": 2]), 200)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testAuditHooksOnlyExportFixedEventNamesAndPurgeRemovesConsent() throws {
        let (db, _, _, analytics) = try harness()
        let service = KeysService(catalog: db, secrets: MemorySecretStore(), clipboard: FakeClipboard())
        service.analytics = analytics
        try analytics.setEnabled(true, consentVersion: 2)
        try service.add(name: "private-key-name", provider: "anthropic", kind: "runtime", notes: "private-notes", secret: "private-secret")
        try service.recordKeyEvent(name: "private-key-name", action: "copy", caller: "private-caller", detail: "private-detail")
        let preview = String(decoding: try JSONValue.data(analytics.status()), as: UTF8.self)
        XCTAssertFalse(preview.contains("private-"))
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["key_add": 1, "key_copy": 1])
        try db.wipeData()
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    /// Fixtures/analytics/report-golden.json is also parsed by Analytics/test_collector.py;
    /// a field or counter added on one side only fails one of the two suites.
    func testUploadedReportMatchesSharedCollectorGolden() throws {
        let data = try Data(contentsOf: Fixtures.root.appendingPathComponent("analytics/report-golden.json"))
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ProductAnalytics.Report.self, from: data)
        XCTAssertEqual(Set(decoded.counts.keys), Set(ProductAnalyticsEvent.allCases.map(\.rawValue)))
        XCTAssertEqual(decoded.schema_version, ProductAnalytics.schemaVersion)
        XCTAssertFalse(decoded.usage.isEmpty || decoded.windows.isEmpty || decoded.gateway.isEmpty)
        XCTAssertEqual(decoded.consent_version, ProductAnalytics.consentVersion)

        let (_, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        for event in ProductAnalyticsEvent.allCases { analytics.record(event) }
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.calls.first).data) as? [String: Any])
        XCTAssertEqual(Set(sent.keys), Set(golden.keys))
        XCTAssertEqual(Set(try XCTUnwrap(sent["counts"] as? [String: Int]).keys), Set(try XCTUnwrap(golden["counts"] as? [String: Int]).keys))
        XCTAssertEqual(sent["day"] as? String, golden["day"] as? String, "The fixed test clock is the golden's UTC day")
        for key in ["schema_version", "consent_version"] { XCTAssertEqual(sent[key] as? Int, golden[key] as? Int, key) }
        for key in ["report_id", "day", "app_version", "architecture"] { XCTAssertNotNil(sent[key] as? String, key) }
        XCTAssertNotNil(sent["os_major"] as? Int)
        let identifier = try XCTUnwrap(sent["report_id"] as? String)
        XCTAssertEqual(identifier, UUID(uuidString: identifier)?.uuidString.lowercased(), "Collector requires canonical lowercase UUIDs")
    }

    func testShippedEndpointIsAPlainHTTPSReportsURL() throws {
        let c = try XCTUnwrap(URLComponents(url: ProductAnalyticsConfiguration.endpoint, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "analytics.keysrs.com")
        XCTAssertEqual(c.path, "/v1/reports")
        XCTAssertNil(c.user)
        XCTAssertNil(c.password)
        XCTAssertNil(c.query)
        XCTAssertNil(c.fragment)
    }

    func usage(_ db: CatalogDB, _ at: String, source: String = "claude-local", provider: String = "anthropic",
               model: String = "claude-fable-5-1", input: Int = 100, output: Int = 50, cacheRead: Int = 1_000,
               cacheWrite: Int = 10, reasoning: Int = 0, prompt: String = UUID().uuidString) throws {
        _ = try db.insertUsage(UsageEvent(source: source, sessionId: "private-session", promptId: prompt, model: model,
            occurredAt: at, provider: provider, cwd: "/Users/private/project", sessionTitle: "private title",
            modelCalls: 2, inputTokens: input, outputTokens: output,
            cachedReadTokens: cacheRead, cacheCreationTokens: cacheWrite, reasoningTokens: reasoning, costUsdTicks: 123,
            keyName: "private-key"))
    }

    func sentReport(_ transport: Transport, _ index: Int = 0) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: transport.calls[index].data) as? [String: Any])
    }

    func testClosedDayCarriesUsageAndGatewayTotalsFromOptInOnwardOnly() throws {
        let (db, clock, transport, analytics) = try harness()   // 2026-05-19T04:00Z
        try usage(db, "2026-05-19T03:00:00Z", input: 999_999)   // before opting in: never sent
        try analytics.setEnabled(true, consentVersion: 2)
        try usage(db, "2026-05-19T05:00:00Z")
        try usage(db, "2026-05-19T06:00:00Z", model: "claude-fable-5-1")
        try usage(db, "2026-05-19T07:00:00Z", source: "codex-local", provider: "openai", model: "gpt-6-astra",
                  input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 3)
        try usage(db, "2026-05-19T08:00:00Z", source: "codex-local", provider: "openai", model: "ft:gpt-4o:acme-corp:secret:1")
        try usage(db, "2026-05-19T09:00:00Z", provider: "acme-internal-llm", model: "acme-prod-deployment")
        try usage(db, "2026-05-20T01:00:00Z")                    // next day: not in this report
        for (status, model) in [(200, "claude-fable-5-1"), (500, "claude-fable-5-1"), (200, "my-azure-deployment")] {
            try db.insertUsage(GatewayUsageRow(ts: "2026-05-19T10:00:00Z", key: "private-key", provider: "anthropic",
                model: model, inputTokens: 7, outputTokens: 3, cacheReadTokens: nil, cacheWriteTokens: 1,
                status: status, durationMs: 40).usageEvent())
        }
        analytics.record(.viewUsage)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let sent = try sentReport(transport)
        let text = String(decoding: transport.calls[0].data, as: UTF8.self)
        for secret in ["private", "acme", "ft:", "/Users", "999999", "cost"] { XCTAssertFalse(text.contains(secret), secret) }
        let rows = try XCTUnwrap(sent["usage"] as? [[String: Any]])
        let claude = try XCTUnwrap(rows.first { $0["source"] as? String == "claude_code" && $0["provider"] as? String == "anthropic" })
        XCTAssertEqual(claude["model"] as? String, "claude-fable-5-1")
        XCTAssertEqual(claude["prompts"] as? Int, 2)
        XCTAssertEqual(claude["model_calls"] as? Int, 4)
        XCTAssertEqual(claude["input_tokens"] as? Int, 200)
        XCTAssertEqual(claude["cached_read_tokens"] as? Int, 2_000)
        XCTAssertTrue(rows.contains { $0["source"] as? String == "claude_code" && $0["provider"] as? String == "other"
            && $0["model"] as? String == "unknown" })
        XCTAssertTrue(rows.contains { $0["source"] as? String == "codex" && $0["model"] as? String == "unknown" })
        let codex = try XCTUnwrap(rows.first { $0["model"] as? String == "gpt-6-astra" })
        XCTAssertEqual(codex["reasoning_tokens"] as? Int, 3)
        let gateway = try XCTUnwrap(sent["gateway"] as? [[String: Any]])
        let known = try XCTUnwrap(gateway.first { $0["model"] as? String == "claude-fable-5-1" })
        XCTAssertEqual(known["requests"] as? Int, 2)
        XCTAssertEqual(known["ok"] as? Int, 1)
        XCTAssertEqual(known["failed"] as? Int, 1)
        XCTAssertEqual(known["cache_read_tokens"] as? Int, 0)
        XCTAssertEqual(gateway.first { $0["model"] as? String == "unknown" }?["requests"] as? Int, 1)
        XCTAssertEqual((sent["windows"] as? [[String: Any]])?.count, 0)
    }

    func testSealedReportIsIdenticalOnRetryEvenIfLateUsageArrives() throws {
        let (db, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        try usage(db, "2026-05-19T05:00:00Z")
        analytics.record(.viewUsage)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        transport.calls[0].complete(false)
        try usage(db, "2026-05-19T06:00:00Z")   // ingested late, after the report sealed
        clock.advance(901)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(transport.calls[0].data, transport.calls[1].data)
    }

    func testDayWithOnlyUsageStillReportsAndPreviewShowsOpenDayArrays() throws {
        let (db, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        try usage(db, "2026-05-19T05:00:00Z")
        analytics.observe(LiveStatus())
        let preview = try XCTUnwrap(reports(analytics).first)
        XCTAssertEqual((preview["usage"] as? [[String: Any]])?.count, 1, "The preview shows what would be sent")
        XCTAssertEqual((preview["counts"] as? [String: Int])?.isEmpty, true)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(((try sentReport(transport))["usage"] as? [[String: Any]])?.count, 1)
    }

    func testPlanWindowPeaksCountHoursAndIgnoreExpiredWindows() throws {
        let (_, clock, transport, analytics) = try harness()
        func status(_ five: Int?, fiveReset: String?, week: Int?, codexWeek: Int?) -> LiveStatus {
            var claude = ToolStatus(source: "claude", title: "Claude")
            claude.fiveHourPct = five; claude.fiveHourResetsAt = fiveReset
            claude.weeklyPct = week; claude.weeklyResetsAt = "2026-05-25T00:00:00Z"
            var codex = ToolStatus(source: "openai", title: "Codex")
            codex.weeklyPct = codexWeek
            return LiveStatus(grok: nil, claude: claude, plans: [codex])
        }
        analytics.observe(status(40, fiveReset: "2026-05-19T06:00:00Z", week: 90, codexWeek: 10))
        XCTAssertNil(try reports(analytics).first, "Nothing is observed before opting in")
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.observe(status(40, fiveReset: "2026-05-19T06:00:00Z", week: 90, codexWeek: 10))
        analytics.observe(status(62, fiveReset: "2026-05-19T06:00:00Z", week: 90, codexWeek: 12))
        clock.advance(3_600)
        analytics.observe(status(100, fiveReset: "2026-05-19T09:00:00Z", week: 97, codexWeek: 12))
        clock.advance(7 * 3_600)   // 12:00, the 09:00 window has reset but the cache still says 100
        analytics.observe(status(100, fiveReset: "2026-05-19T09:00:00Z", week: 97, codexWeek: 12))
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let windows = try XCTUnwrap((try sentReport(transport))["windows"] as? [[String: Any]])
        func row(_ source: String, _ window: String) -> [String: Any]? {
            windows.first { $0["source"] as? String == source && $0["window"] as? String == window }
        }
        XCTAssertEqual(row("claude_code", "5h")?["peak_percent"] as? Int, 100)
        XCTAssertEqual(row("claude_code", "5h")?["hit_cap"] as? Bool, true)
        XCTAssertEqual(row("claude_code", "5h")?["readings"] as? Int, 2, "Hours with a live reading, not polls")
        XCTAssertEqual(row("claude_code", "weekly")?["peak_percent"] as? Int, 95, "Rounded to 5")
        XCTAssertEqual(row("claude_code", "weekly")?["hit_cap"] as? Bool, false)
        XCTAssertEqual(row("claude_code", "weekly")?["readings"] as? Int, 3)
        XCTAssertEqual(row("codex", "weekly")?["peak_percent"] as? Int, 10)
        XCTAssertNil(row("claude_code", "fable"))
    }

    func testProviderAllowlistMatchesShippedCatalog() throws {
        let data = try Data(contentsOf: Fixtures.root.deletingLastPathComponent().appendingPathComponent("Web/providers.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = Set(try XCTUnwrap(object["providers"] as? [[String: Any]]).compactMap { $0["id"] as? String })
        XCTAssertEqual(ProductAnalytics.providers, ids)
        XCTAssertEqual(ProductAnalytics.publicModel("claude-fable-5-1"), "claude-fable-5-1")
        XCTAssertEqual(ProductAnalytics.publicModel("GPT-6-astra"), "GPT-6-astra")
        for model in ["claude-opus-4-1-20250805", "gpt-5.1-codex-max", "o4-mini-high", "llama3.1-70b-instruct", "gpt-oss-120b"] {
            XCTAssertEqual(ProductAnalytics.publicModel(model), model)
        }
        for model in ["ft:gpt-4o:acme:x:1", "acme-prod", "claude-" + String(repeating: "x", count: 64), "", "claude fable", nil,
                      "gpt-4-acmecorp-prod", "claude-widgetco-eval", "gpt--"] {
            XCTAssertEqual(ProductAnalytics.publicModel(model), "unknown")
        }
    }

    func testBenchmarksFetchOnlyWhileSharingAndCompareUsesLocalMedian() throws {
        let (db, clock, transport, analytics) = try harness()
        analytics.refreshBenchmarks()
        XCTAssertTrue(transport.fetches.isEmpty, "No request before opting in")
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.refreshBenchmarks()
        XCTAssertEqual(transport.fetches.first?.url.absoluteString, "https://analytics.example/v1/benchmarks")
        analytics.refreshBenchmarks()
        XCTAssertEqual(transport.fetches.count, 1, "One fetch in flight; retries wait six hours")
        let table: [String: Any] = [
            "schema_version": 1, "generated_day": "2026-05-19", "window_days": 28, "min_reports": 50,
            "daily_tokens": [["source": "claude_code", "reports": 80,
                              "percentiles": (1...19).map { $0 * 1_000 }]],
            "cap_hits": [["source": "claude_code", "window": "5h", "reports": 60, "hit_rate": 0.25]],
        ]
        transport.fetches[0].complete(try JSONSerialization.data(withJSONObject: table))
        XCTAssertNil(try analytics.status()["compare"] as? [String: Any], "No local activity yet: no line")
        // Three active days in the previous week: 1,160 / 5,220 / 11,600 tokens; the median is 5,220.
        try usage(db, "2026-05-16T05:00:00Z", input: 100, output: 50, cacheRead: 1_000, cacheWrite: 10)
        try usage(db, "2026-05-17T05:00:00Z", input: 200, output: 20, cacheRead: 5_000, cacheWrite: 0)
        try usage(db, "2026-05-18T05:00:00Z", input: 600, output: 0, cacheRead: 11_000, cacheWrite: 0)
        try usage(db, "2026-05-19T05:00:00Z", input: 9_999_999)   // today is still open: excluded
        let compare = try XCTUnwrap(try analytics.status()["compare"] as? [String: Any])
        let claude = try XCTUnwrap((compare["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(claude["typical_day_tokens"] as? Int, 5_220)
        XCTAssertEqual(claude["higher_than_percent"] as? Int, 25)
        XCTAssertEqual((claude["cap_hits"] as? [[String: Any]])?.first?["hit_rate"] as? Double, 0.25)
        clock.advance(3_600)
        analytics.refreshBenchmarks()
        XCTAssertEqual(transport.fetches.count, 1, "Already fetched today")
        try analytics.setEnabled(false, consentVersion: 2)
        XCTAssertTrue(try analytics.status()["compare"] is NSNull)
        XCTAssertEqual(try db.metaValue(ProductAnalytics.benchmarkKey), "")
    }

    func testInvalidBenchmarksAreIgnored() throws {
        let (_, _, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.refreshBenchmarks()
        let bad: [String: Any] = [
            "schema_version": 1, "generated_day": "2026-05-19", "window_days": 28, "min_reports": 50,
            "daily_tokens": [["source": "claude_code", "reports": 10, "percentiles": (1...19).map { $0 }]],
            "cap_hits": [], "models": [],
        ]
        transport.fetches[0].complete(try JSONSerialization.data(withJSONObject: bad))
        XCTAssertTrue(try analytics.status()["compare"] is NSNull)
    }
}
