import XCTest
@testable import KeysCore

final class OptimizerAPITests: XCTestCase {
    struct Harness {
        let directory: URL
        let service: KeysService
        let optimizer: OptimizerController
        let handler: APIHandler
        let presence: RecordingPresenceGate
    }

    func harness(cacheNow: @escaping @Sendable () -> Date = { Date() },
                 engine: @escaping @Sendable ([String: Any], [String: String]) throws -> [String: Any] = { _, _ in
                     XCTFail("No provider should be used by these local tests"); return [:]
                 }) throws -> Harness {
        let (db, directory) = try makeDB()
        let presence = RecordingPresenceGate()
        let service = KeysService(catalog: db,
            secrets: GatedSecretStore(inner: MemorySecretStore(), presence: presence), clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome, claudeHome: Fixtures.claudeHome, codexHome: Fixtures.codexHome)
        let optimizer = try OptimizerController(directory: directory.appendingPathComponent("optimizer"),
            loadKey: { Data(repeating: 3, count: 32) }, deleteKey: {},
            cacheNow: cacheNow, runEngine: engine)
        service.configureOptimizer(optimizer)
        return Harness(directory: directory, service: service, optimizer: optimizer,
            handler: APIHandler(service: service, webRoot: directory), presence: presence)
    }

    func request(_ h: Harness, path: String = "/api/optimizer/rpc", token: String? = nil,
                 body: [String: Any] = [:], csrf: Bool = true, method: String = "POST") throws -> (Int, [String: Any]) {
        var headers = ["host": "127.0.0.1:12765"]
        if csrf { headers["x-ksf-token"] = h.handler.originToken }
        if let token { headers["x-ksf-optimizer"] = token }
        let response = h.handler.handle(HTTPRequest(method: method, path: path, query: [:], headers: headers,
            body: try JSONValue.data(body), serverPort: 12765))
        return (response.status, try JSONSerialization.jsonObject(with: response.body) as! [String: Any])
    }

    func unlock(_ h: Harness, project: String? = nil, writable: Bool = true) throws -> String {
        var body: [String: Any] = ["minutes": 30, "writable": writable]
        if let project { body["project_id"] = project }
        let (status, response) = try request(h, path: "/api/optimizer/unlock", body: body)
        XCTAssertEqual(status, 200, "\(response)")
        return try XCTUnwrap(response["token"] as? String)
    }

    func rpc(_ h: Harness, _ token: String, _ operation: String, _ payload: [String: Any] = [:]) throws -> (Int, [String: Any]) {
        try request(h, token: token, body: ["operation": operation, "payload": payload])
    }

    func addProject(_ h: Harness, _ token: String, provider: Bool = false, maxInput: Int = 60_000) throws -> String {
        let (status, response) = try rpc(h, token, "project_save", ["name": "Synthetic", "root": h.directory.path,
            "mode": "suggest", "storage_enabled": true, "provider_enabled": provider, "retention_days": 30,
            "max_requests": 10, "max_input_tokens": maxInput])
        XCTAssertEqual(status, 200, "\(response)")
        return try XCTUnwrap(response["id"] as? String)
    }

    func testOriginTokenDoesNotAuthorizeContentOrSkipPresence() throws {
        let h = try harness()
        XCTAssertEqual(try request(h, path: "/api/optimizer/unlock", csrf: false).0, 403)
        XCTAssertEqual(h.presence.reasons.count, 0)
        XCTAssertEqual(try request(h, body: ["operation": "summary", "payload": [:]]).0, 403)
        let token = try unlock(h)
        XCTAssertEqual(h.presence.reasons.count, 1)
        _ = try addProject(h, token)
        let publicStatus = try request(h, path: "/api/optimizer/status", csrf: false, method: "GET")
        XCTAssertEqual(publicStatus.0, 200)
        XCTAssertFalse(String(decoding: try JSONValue.data(publicStatus.1), as: UTF8.self).contains("Synthetic"))
    }

    func testScopedReadOnlySessionCannotReadOtherProjectOrWrite() throws {
        let h = try harness(), admin = try unlock(h)
        let first = try addProject(h, admin), second = try addProject(h, admin)
        let reader = try unlock(h, project: first, writable: false)
        let summary = try rpc(h, reader, "summary")
        XCTAssertEqual((summary.1["projects"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try rpc(h, reader, "entry_list", ["project_id": second]).0, 403)
        XCTAssertEqual(try rpc(h, reader, "project_delete", ["project_id": first]).0, 403)
        XCTAssertEqual(try rpc(h, reader, "entry_save", ["project_id": first, "title": "x", "kind": "memory", "content": "x"]).0, 403)
        XCTAssertEqual(try request(h, path: "/api/optimizer/lock", token: reader).0, 403)
    }

    func testScreenLockExpiryAndCloseRevokeContentAccess() throws {
        let h = try harness(), token = try unlock(h)
        _ = try addProject(h, token)
        h.service.handleScreenLock()
        XCTAssertEqual(try rpc(h, token, "summary").0, 403)
        XCTAssertFalse(h.optimizer.store.isUnlocked)
        let second = try unlock(h)
        XCTAssertThrowsError(try h.optimizer.authorize(second, now: Date().addingTimeInterval(1900)))
        let third = try unlock(h)
        XCTAssertEqual(try request(h, path: "/api/optimizer/close", token: third).0, 200)
        XCTAssertEqual(try rpc(h, third, "summary").0, 403)
    }

    func testActualJSONZeroUsageAndPlanSaveRoundTrip() throws {
        let h = try harness(), token = try unlock(h), project = try addProject(h, token)
        let saved = try rpc(h, token, "entry_save", ["project_id": project, "kind": "plan", "title": "Tests",
            "content": "Run the fixture tests", "source": "synthetic verified run", "verification": ["fixture tests pass"]])
        XCTAssertEqual(saved.0, 200, "\(saved.1)")
        let id = try XCTUnwrap(saved.1["id"] as? String)
        XCTAssertEqual(try rpc(h, token, "entry_get", ["project_id": project, "id": id]).1["content"] as? String, "Run the fixture tests")
        let task = try rpc(h, token, "task_start", ["project_id": project, "client": "fixture"])
        let taskID = try XCTUnwrap(task.1["id"] as? String)
        let event: [String: Any] = ["project_id": project, "task_id": taskID, "event_id": "numeric-zero",
            "source": "test", "kind": "model_call", "model": "fixture", "input_tokens": 0, "output_tokens": 1,
            "reported_cost_usd": 0, "latency_ms": 0, "status": "success"]
        XCTAssertEqual(try rpc(h, token, "event_record", event).0, 200)
        var bad = event; bad["event_id"] = "invalid-boolean"; bad["input_tokens"] = true
        XCTAssertEqual(try rpc(h, token, "event_record", bad).0, 400)
        let noProvider = try rpc(h, token, "retrieve", ["project_id": project, "task_id": taskID, "request_text": "Run tests"])
        XCTAssertEqual(noProvider.1["reason"] as? String, "provider_disabled")
    }

    func testFailedPresenceDoesNotLoadEncryptionKey() throws {
        let h = try harness()
        h.presence.error = .authCancelled
        XCTAssertEqual(try request(h, path: "/api/optimizer/unlock").0, 403)
        XCTAssertFalse(h.optimizer.store.isUnlocked)
    }

    func testDependencyHashingRejectsOutsideAndSecretSymlinks() throws {
        let directory = try TempDir.make()
        try Data("public source".utf8).write(to: directory.appendingPathComponent("source.txt"))
        try Data("synthetic private value".utf8).write(to: directory.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.txt"), withDestinationURL: directory.appendingPathComponent(".env"))
        let result = try OptimizerFiles.fingerprints(root: directory.path, relativePaths: ["source.txt", ".env", "alias.txt", "../outside"])
        XCTAssertNotNil(result["source.txt"])
        XCTAssertNil(result[".env"])
        XCTAssertNil(result["alias.txt"])
        XCTAssertNil(result["../outside"])
    }

    // The service uses an in-memory synthetic key and a recording presence gate.
    // The engine is injected below, so these calls never reach a provider.
    func jevSession(_ h: Harness, project: String) throws -> String {
        try h.service.add(name: "fixture-jev", provider: "vercel-ai-gateway", kind: "runtime", notes: "", secret: "synthetic-test-only")
        let (status, response) = try request(h, path: "/api/optimizer/unlock", body: [
            "project_id": project, "minutes": 30, "writable": false, "jev_key": "fixture-jev",
        ])
        XCTAssertEqual(status, 200, "\(response)")
        XCTAssertNotNil(response["task_id"] as? String)
        return try XCTUnwrap(response["token"] as? String)
    }

    func testReadOnlySessionAttributesEvaluationsAndUsesRemainingBudget() throws {
        let box = EngineCapture()
        let h = try harness(engine: { input, _ in box.record(input); return EngineCapture.success })
        let admin = try unlock(h), project = try addProject(h, admin, provider: true, maxInput: 1_000)
        let token = try jevSession(h, project: project)
        for requestText in ["check the tests", "check another test"] {
            let response = try rpc(h, token, "assess_memory", ["project_id": project,
                "request_text": requestText, "proposed_memory": "Run fixture tests"])
            XCTAssertEqual(response.0, 200, "\(response.1)")
        }
        XCTAssertEqual(box.inputs.count, 2)
        guard box.inputs.count == 2 else { return }
        XCTAssertEqual((box.inputs[0]["policy"] as? [String: Any])?["max_input_tokens"] as? Int, 1_000)
        XCTAssertEqual((box.inputs[1]["policy"] as? [String: Any])?["max_input_tokens"] as? Int, 900)
        XCTAssertEqual((box.inputs[0]["proposed_memory"] as? [String: Any])?["content"] as? String, "Run fixture tests")
        let events = try rpc(h, token, "event_list", ["project_id": project])
        XCTAssertEqual((events.1["aggregate"] as? [String: Any])?["input_tokens_known"] as? Int, 200)
        XCTAssertEqual((events.1["events"] as? [[String: Any]])?.count, 2)
    }

    func testEvaluationCacheExpiresWithCandidateAndCarriesRoutingCost() throws {
        let box = EngineCapture()
        let h = try harness(cacheNow: { box.now }, engine: { input, _ in box.record(input); return EngineCapture.success })
        let admin = try unlock(h), project = try addProject(h, admin, provider: true)
        let token = try jevSession(h, project: project)
        let payload: [String: Any] = ["project_id": project, "request_text": "run test", "optimizer_cost_usd": 0.001,
            "candidates": [["id": "model", "name": "fixture", "expires_at": UTC.iso(box.now.addingTimeInterval(10))]]]
        XCTAssertEqual(try rpc(h, token, "route_model", payload).0, 200)
        let hit = try rpc(h, token, "route_model", payload)
        XCTAssertEqual((hit.1["usage"] as? [String: Any])?["cache_hits"] as? Int, 1)
        XCTAssertEqual(box.inputs.count, 1)
        XCTAssertEqual((box.inputs[0]["policy"] as? [String: Any])?["optimizer_cost_usd"] as? Double, 0.001)
        box.advance(20)
        XCTAssertEqual(try rpc(h, token, "route_model", payload).0, 200)
        XCTAssertEqual(box.inputs.count, 2, "Expired candidates must be rechecked by the engine")
    }

    func testHistoricalPlanBodiesStayOutOfEvaluationRequest() throws {
        let box = EngineCapture()
        let h = try harness(engine: { input, _ in box.record(input); return EngineCapture.success })
        let admin = try unlock(h), project = try addProject(h, admin, provider: true)
        var entry: [String: Any] = ["project_id": project, "kind": "plan", "title": "Tests",
            "content": "Run tests " + String(repeating: "old evidence ", count: 1_700), "source": "fixture", "verification": ["fixture passed"]]
        for _ in 0..<6 {
            let saved = try rpc(h, admin, "entry_save", entry)
            XCTAssertEqual(saved.0, 200, "\(saved.1)")
            entry["id"] = saved.1["id"]
        }
        entry["content"] = "Run tests and verify the exit status"
        XCTAssertEqual(try rpc(h, admin, "entry_save", entry).0, 200)
        let token = try jevSession(h, project: project)
        let response = try rpc(h, token, "retrieve", ["project_id": project, "request_text": "Run tests"])
        XCTAssertEqual(response.0, 200, "\(response.1)")
        XCTAssertEqual(box.inputs.count, 1, "Historical revisions must not trigger input_limit")
        let candidate = (box.inputs.first?["candidates"] as? [[String: Any]])?.first
        XCTAssertNil(candidate?["revisions"])
        XCTAssertEqual(candidate?["content"] as? String, "Run tests and verify the exit status")
    }

    func testDashboardJSONCreateListSaveAndClearOptionalFields() throws {
        let h = try harness(), token = try unlock(h)
        func send(_ json: String) throws -> (Int, [String: Any]) {
            let response = h.handler.handle(HTTPRequest(method: "POST", path: "/api/optimizer/rpc", query: [:],
                headers: ["host": "127.0.0.1:12765", "x-ksf-token": h.handler.originToken, "x-ksf-optimizer": token],
                body: Data(json.utf8), serverPort: 12765))
            return (response.status, try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
        }
        let created = try send(#"{"operation":"project_save","payload":{"name":"UI fixture","root":"/tmp/fixture","mode":"suggest","storage_enabled":true,"provider_enabled":false,"retention_days":30,"max_requests":1000,"max_input_tokens":1000000,"feature_flags":{}}}"#)
        XCTAssertEqual(created.0, 200)
        let project = try XCTUnwrap(created.1["id"] as? String)
        XCTAssertEqual(try send("""
            {"operation":"entry_list","payload":{"project_id":"\(project)","kind":"all","include_archived":false}}
            """).0, 200)
        let saved = try send("""
            {"operation":"entry_save","payload":{"project_id":"\(project)","kind":"memory","title":"UI memory","content":"Run fixture tests","tags":[],"constraints":[],"required_tools":[],"dependencies":{},"verification":[],"pinned":false}}
            """)
        XCTAssertEqual(saved.0, 200, "\(saved.1)")
        let entry = try XCTUnwrap(saved.1["id"] as? String)
        XCTAssertTrue(saved.1["source"] is NSNull)
        XCTAssertTrue(saved.1["expires_at"] is NSNull)
        XCTAssertEqual(try send("""
            {"operation":"entry_save","payload":{"id":"\(entry)","project_id":"\(project)","kind":"memory","title":"UI memory","content":"Run fixture tests","source":"fixture evidence","expires_at":"2099-01-01T00:00:00Z"}}
            """).0, 200)
        let cleared = try send("""
            {"operation":"entry_save","payload":{"id":"\(entry)","project_id":"\(project)","kind":"memory","title":"UI memory","content":"Run fixture tests"}}
            """)
        XCTAssertEqual(cleared.0, 200)
        XCTAssertTrue(cleared.1["source"] is NSNull)
        XCTAssertTrue(cleared.1["expires_at"] is NSNull)
    }

    func testPolicyAndCapabilityDenialsPreserveSessionButLocksReportAuthenticationLoss() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        let reader = try unlock(h, project: project, writable: false)
        let capability = try rpc(h, reader, "entry_save", ["project_id": project])
        XCTAssertEqual(capability.0, 403)
        XCTAssertEqual(capability.1["error"] as? String, "optimizer_access_denied")
        XCTAssertEqual(try rpc(h, reader, "summary").0, 200)
        var disabled = try rpc(h, admin, "project_get", ["project_id": project]).1
        disabled["storage_enabled"] = false
        XCTAssertEqual(try rpc(h, admin, "project_save", disabled).0, 200)
        let policy = try rpc(h, admin, "entry_save", ["project_id": project])
        XCTAssertEqual(policy.0, 403)
        XCTAssertEqual(policy.1["error"] as? String, "optimizer_access_denied")
        XCTAssertEqual(try rpc(h, admin, "summary").0, 200)
        h.optimizer.store.lock()
        XCTAssertEqual(try rpc(h, admin, "summary").1["error"] as? String, "optimizer_locked")
        XCTAssertEqual(try rpc(h, "kso_missing", "summary").1["error"] as? String, "optimizer_locked")
    }

    private func budget(_ h: Harness, project: String, token: String) throws -> [String: Any] {
        let task = try XCTUnwrap(h.optimizer.authorize(token).taskID)
        let reserved = try h.optimizer.store.perform(operation: "task_reserve", payload: [
            "project_id": project, "task_id": task, "request_count": 1, "estimated_input_tokens": 1])
        return try XCTUnwrap(h.optimizer.store.perform(operation: "task_settle", payload: [
            "project_id": project, "task_id": task, "reservation_id": reserved["reservation_id"]!, "dispatched": false])["budget"] as? [String: Any])
    }

    func testPreStartFailuresRefundBudgetButUnknownStartedFailuresRemainReserved() throws {
        for neverStarted in [true, false] {
            let h = try harness(engine: { _, _ in
                if neverStarted {
                    return try OptimizerProcess.run([:], [:], executable: URL(fileURLWithPath: "/missing/synthetic-engine"), arguments: [])
                }
                throw OptimizerEngineFailure.startedOutcomeUnknown
            })
            let admin = try unlock(h), project = try addProject(h, admin, provider: true)
            let token = try jevSession(h, project: project)
            let response = try rpc(h, token, "assess_memory", ["project_id": project, "request_text": "fixture"])
            XCTAssertEqual(response.1["reason"] as? String, "engine_unavailable")
            let after = try budget(h, project: project, token: token)
            XCTAssertEqual(after["requests_used"] as? Int, neverStarted ? 0 : 1)
            XCTAssertEqual(after["input_tokens_used"] as? Int, neverStarted ? 0 : 30_000)
            let event = try XCTUnwrap((try rpc(h, token, "event_list", ["project_id": project]).1["events"] as? [[String: Any]])?.first)
            if neverStarted { XCTAssertEqual(event["reported_cost_usd"] as? Double, 0) }
            else { XCTAssertTrue(event["reported_cost_usd"] is NSNull) }
        }
    }

    func testZeroRequestAbstentionRecordsExplicitZeroButUnknownCalledUsageStaysUnknown() throws {
        for count in [0, 1] {
            let h = try harness(engine: { _, _ in ["status": "abstained", "reason": "fixture", "usage": ["requests": count]] })
            let admin = try unlock(h), project = try addProject(h, admin, provider: true)
            let token = try jevSession(h, project: project)
            XCTAssertEqual(try rpc(h, token, "route_model", ["project_id": project, "request_text": "fixture"]).0, 200)
            let event = try XCTUnwrap((try rpc(h, token, "event_list", ["project_id": project]).1["events"] as? [[String: Any]])?.first)
            for field in ["input_tokens", "output_tokens", "reported_cost_usd"] {
                if count == 0 { XCTAssertEqual(event[field] as? Double, 0) }
                else { XCTAssertTrue(event[field] is NSNull) }
            }
            XCTAssertEqual(try budget(h, project: project, token: token)["requests_used"] as? Int, count)
        }
    }

    func testLockDuringEngineReconcilesOnlyKnownOutcomesAfterUnlock() throws {
        for outcome in ["not_started", "known", "unknown"] {
            let reference = EngineControllerReference()
            let h = try harness(engine: { _, _ in
                reference.controller?.lock()
                if outcome == "not_started" { throw OptimizerEngineFailure.notStarted }
                if outcome == "unknown" { throw OptimizerEngineFailure.startedOutcomeUnknown }
                return EngineCapture.success
            })
            reference.controller = h.optimizer
            let admin = try unlock(h), project = try addProject(h, admin, provider: true)
            let token = try jevSession(h, project: project)
            let response = try rpc(h, token, "assess_memory", ["project_id": project, "request_text": "fixture"])
            XCTAssertEqual(response.0, 403)
            XCTAssertEqual(response.1["error"] as? String, "optimizer_locked")
            let reopened = try unlock(h, project: project)
            let usage = try budget(h, project: project, token: reopened)
            XCTAssertEqual(usage["requests_used"] as? Int, outcome == "not_started" ? 0 : 1)
            XCTAssertEqual(usage["input_tokens_used"] as? Int, outcome == "known" ? 100 : outcome == "unknown" ? 30_000 : 0)
        }
    }

    func testLargeDependencySetDoesNotPoisonAnotherContextCandidate() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        try Data("fixture".utf8).write(to: h.directory.appendingPathComponent("source.txt"))
        let hashes = try rpc(h, admin, "dependency_fingerprints", ["project_id": project, "paths": ["source.txt"]]).1["dependencies"] as! [String: String]
        let many = Dictionary(uniqueKeysWithValues: (0..<128).map { ("missing-\($0)", "unknown") })
        for (title, dependencies) in [("fixture large", many), ("fixture source", hashes)] {
            XCTAssertEqual(try rpc(h, admin, "entry_save", ["project_id": project, "kind": "memory", "title": title,
                "content": "fixture evidence", "dependencies": dependencies]).0, 200)
        }
        let context = try rpc(h, admin, "context_prepare", ["project_id": project, "query": "fixture"])
        XCTAssertEqual(context.0, 200)
        XCTAssertEqual((context.1["entries"] as? [[String: Any]])?.map { $0["title"] as? String }, ["fixture source"])
        XCTAssertEqual((context.1["excluded"] as? [String: Int])?["dependencies"], 1)
    }
}

private final class EngineControllerReference: @unchecked Sendable {
    var controller: OptimizerController?
}

private final class EngineCapture: @unchecked Sendable {
    private let mutex = NSLock()
    private var captured: [[String: Any]] = []
    private var time = Date()
    var inputs: [[String: Any]] { mutex.lock(); defer { mutex.unlock() }; return captured }
    var now: Date { mutex.lock(); defer { mutex.unlock() }; return time }
    func record(_ value: [String: Any]) { mutex.lock(); captured.append(value); mutex.unlock() }
    func advance(_ seconds: TimeInterval) { mutex.lock(); time = time.addingTimeInterval(seconds); mutex.unlock() }
    static var success: [String: Any] {
        let usage: [String: Any] = ["requests": 1, "cache_hits": 0, "actual_input_tokens": 100, "actual_output_tokens": 1, "optimizer_cost_usd": 0.001]
        return ["ok": true, "status": "suggested", "applied": false, "usage": usage]
    }
}
