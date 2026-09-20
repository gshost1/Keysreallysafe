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

    func testDefaultOffHasNoStorageNoUploadAndUnconfiguredCannotOptIn() throws {
        let (db, clock, transport, analytics) = try harness()
        analytics.record(.keyAdd)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
        XCTAssertNil(try db.metaValue(ProductAnalytics.stateKey))
        XCTAssertEqual(transport.calls.count, 0)
        let unconfigured = ProductAnalytics(catalog: db, endpoint: nil, transport: transport)
        XCTAssertThrowsError(try unconfigured.setEnabled(true, consentVersion: 1))
        XCTAssertThrowsError(try analytics.setEnabled(true, consentVersion: 2))
        XCTAssertEqual(transport.calls.count, 0)
    }

    func testConsentOnlyCollectsNewTypedCountersAndCoarseTimings() throws {
        let (_, _, transport, analytics) = try harness()
        analytics.record(.keyCopy)
        try analytics.setEnabled(true, consentVersion: 1)
        analytics.record(.viewOptimizer)
        analytics.record(.gatewaySuccess, durationMS: 25)
        analytics.record(.optimizerCacheHit, durationMS: 12_000)
        let report = try XCTUnwrap(reports(analytics).first)
        XCTAssertEqual(Set(report.keys), ["schema_version", "consent_version", "report_id", "day", "app_version", "os_major", "architecture", "counts"])
        XCTAssertEqual(report["counts"] as? [String: Int], ["view_optimizer": 1, "gateway_success": 1,
            "gateway_lt_100ms": 1, "optimizer_cache_hit": 1, "optimizer_gte_10s": 1])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(report["report_id"] as? String)))
        analytics.flushCompletedReports()
        XCTAssertTrue(transport.calls.isEmpty, "Current UTC day must stay local and mutable")
    }

    func testCompletedDayRetryIsImmutableAndAcknowledgmentPreservesNewDay() throws {
        let (_, clock, transport, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 1)
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
        try analytics.setEnabled(true, consentVersion: 1)
        analytics.record(.viewKeys)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let first = try XCTUnwrap(transport.calls.first)
        try analytics.setEnabled(false, consentVersion: 1)
        XCTAssertTrue(first.upload.isCancelled)
        XCTAssertTrue(try reports(analytics).isEmpty)
        try analytics.setEnabled(true, consentVersion: 1)
        analytics.record(.viewChart)
        clock.advance(86_400)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        first.complete(true) // A delayed callback from the previous consent epoch.
        XCTAssertEqual(try reports(analytics).count, 1)
        try analytics.setEnabled(false, consentVersion: 1)
        XCTAssertTrue(transport.calls[1].upload.isCancelled, "Stale completion must not detach the current upload")
        analytics.record(.keyAdd)
        analytics.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testClearKeepsConsentButDiscardsDataAndChangesNextReportIdentity() throws {
        let (_, _, _, analytics) = try harness()
        try analytics.setEnabled(true, consentVersion: 1)
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
        try analytics.setEnabled(true, consentVersion: 1)
        analytics.record(.keyAdd)
        clock.advance(8 * 86_400)
        analytics.flushCompletedReports()
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(try reports(analytics).isEmpty)
        analytics.record(.viewKeys)
        let changed = ProductAnalytics(catalog: db, endpoint: URL(string: "https://different.example/v1/reports"),
            transport: transport, now: { clock.date() })
        XCTAssertEqual(try changed.status()["enabled"] as? Bool, false)
        XCTAssertTrue(try reports(changed).isEmpty)
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
    }

    func testUnknownStoredFieldsSchemasAndCountersFailClosed() throws {
        let (db, _, _, analytics) = try harness()
        for alteration in 0..<5 {
            try analytics.setEnabled(true, consentVersion: 1)
            analytics.record(.viewUsage)
            var state = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(db.metaValue(ProductAnalytics.stateKey)).utf8)) as! [String: Any]
            var pending = state["reports"] as! [[String: Any]]
            switch alteration {
            case 0: state["future_schema_field"] = "private sample"
            case 1: state["schemaVersion"] = 2
            case 2: pending[0]["private_prompt"] = "do not send me"; state["reports"] = pending
            case 3: pending[0]["counts"] = ["unknown_event": 1]; state["reports"] = pending
            default: pending[0]["schema_version"] = 2; state["reports"] = pending
            }
            try db.setMeta(ProductAnalytics.stateKey, String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
            XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
            XCTAssertTrue(try reports(analytics).isEmpty)
        }
    }

    func testTwoCatalogConnectionsShareConsentAndSerializeCounters() throws {
        let (db, clock, transport, analytics) = try harness()
        let secondDB = try CatalogDB(path: db.path)
        let second = ProductAnalytics(catalog: secondDB, endpoint: endpoint, transport: transport, now: { clock.date() })
        try analytics.setEnabled(true, consentVersion: 1)
        DispatchQueue.concurrentPerform(iterations: 100) { i in (i % 2 == 0 ? analytics : second).record(.viewKeys) }
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_keys": 100])
        clock.advance(86_400)
        analytics.flushCompletedReports()
        second.flushCompletedReports()
        XCTAssertEqual(transport.calls.count, 1, "The persisted lease must prevent duplicate simultaneous dispatch")
        try second.setEnabled(false, consentVersion: 1)
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
        let consent: [String: Any] = ["enabled": true, "consent_version": 1]
        XCTAssertEqual(try request("/api/analytics", consent, csrf: false), 403)
        XCTAssertEqual(try request("/api/analytics", consent, origin: "https://outside.example"), 403)
        XCTAssertEqual(try request("/api/analytics", ["enabled": 1, "consent_version": 1]), 400)
        XCTAssertEqual(try request("/api/analytics", ["enabled": true, "consent_version": 1, "endpoint": "https://evil.example"]), 400)
        XCTAssertEqual(try request("/api/analytics", consent), 200)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "view_keys", "prompt": "secret"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "arbitrary_secret"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "key_add"]), 400)
        XCTAssertEqual(try request("/api/analytics/event", ["event": "view_keys"]), 200)
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["view_keys": 1])
        XCTAssertTrue(presence.reasons.isEmpty)
        XCTAssertEqual(try request("/api/analytics", ["enabled": false, "consent_version": 1]), 200)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testAuditHooksOnlyExportFixedEventNamesAndPurgeRemovesConsent() throws {
        let (db, _, _, analytics) = try harness()
        let service = KeysService(catalog: db, secrets: MemorySecretStore(), clipboard: FakeClipboard())
        service.analytics = analytics
        try analytics.setEnabled(true, consentVersion: 1)
        try service.add(name: "private-key-name", provider: "anthropic", kind: "runtime", notes: "private-notes", secret: "private-secret")
        try service.recordKeyEvent(name: "private-key-name", action: "copy", caller: "private-caller", detail: "private-detail")
        let preview = String(decoding: try JSONValue.data(analytics.status()), as: UTF8.self)
        XCTAssertFalse(preview.contains("private-"))
        XCTAssertEqual(try reports(analytics).first?["counts"] as? [String: Int], ["key_add": 1, "key_copy": 1])
        try db.wipeData()
        XCTAssertEqual(try analytics.status()["enabled"] as? Bool, false)
        XCTAssertTrue(try reports(analytics).isEmpty)
    }

    func testInvalidEndpointCannotReceiveConsent() throws {
        let (db, _, transport, _) = try harness()
        for raw in ["http://analytics.example/v1/reports", "https://user:password@analytics.example/v1/reports",
                    "https://analytics.example/v1/reports?token=secret", "https://analytics.example/v1/reports#extra", "https://analytics.example/other"] {
            let analytics = ProductAnalytics(catalog: db, endpoint: URL(string: raw), transport: transport)
            XCTAssertEqual(try analytics.status()["configured"] as? Bool, false)
            XCTAssertThrowsError(try analytics.setEnabled(true, consentVersion: 1))
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }
}
