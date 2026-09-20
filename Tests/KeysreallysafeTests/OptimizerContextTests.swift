import XCTest
@testable import KeysCore

extension OptimizerAPITests {
    private func contextEntry(_ h: Harness, admin: String, project: String, changes: [String: Any] = [:]) throws -> [String: Any] {
        var payload: [String: Any] = ["project_id": project, "kind": "plan", "title": "Parser tests",
            "content": "Run parser fixture tests and verify their exit status.", "source": "synthetic fixture",
            "verification": ["fixture suite passes"]]
        payload.merge(changes) { _, new in new }
        let response = try rpc(h, admin, "entry_save", payload)
        XCTAssertEqual(response.0, 200, "\(response.1)")
        return response.1
    }

    func testContextRepeatUsesMarkerAndContentRevisionInvalidatesIt() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        let entry = try contextEntry(h, admin: admin, project: project)
        let reader = try unlock(h, project: project, writable: false)
        var payload: [String: Any] = ["project_id": project, "query": "parser tests"]
        let first = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(first.0, 200, "\(first.1)")
        XCTAssertEqual(first.1["status"] as? String, "prepared")
        XCTAssertEqual(first.1["validation"] as? String, "local_checks_only")
        XCTAssertEqual((first.1["entries"] as? [[String: Any]])?.count, 1)
        let fingerprint = try XCTUnwrap(first.1["fingerprint"] as? String)
        payload["if_fingerprint"] = fingerprint
        let second = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(second.1["status"] as? String, "unchanged")
        XCTAssertEqual((second.1["entries"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(String(decoding: try JSONValue.data(second.1), as: UTF8.self).contains("Run parser fixture"))
        XCTAssertLessThan(try JSONValue.data(second.1).count, try JSONValue.data(first.1).count)
        _ = try contextEntry(h, admin: admin, project: project, changes: ["id": entry["id"]!, "source": "newly verified fixture"])
        let changed = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(changed.1["status"] as? String, "prepared")
        XCTAssertNotEqual(changed.1["fingerprint"] as? String, fingerprint)
        let current = try XCTUnwrap((changed.1["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(current["source"] as? String, "newly verified fixture")
        XCTAssertNil(current["revisions"])
    }

    func testContextRechecksDependenciesToolsAndConstraintsBeforeMarker() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        let file = h.directory.appendingPathComponent("parser.swift")
        try Data("synthetic parser source".utf8).write(to: file)
        let capture = try rpc(h, admin, "dependency_fingerprints", ["project_id": project, "paths": ["parser.swift"]])
        let dependencies = try XCTUnwrap(capture.1["dependencies"] as? [String: String])
        _ = try contextEntry(h, admin: admin, project: project, changes: ["dependencies": dependencies,
            "required_tools": ["shell"], "constraints": ["run fixture tests"]])
        let reader = try unlock(h, project: project, writable: false)
        var payload: [String: Any] = ["project_id": project, "query": "parser tests", "available_tools": ["shell"],
            "current_constraints": ["run fixture tests"]]
        let first = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(first.1["status"] as? String, "prepared")
        payload["if_fingerprint"] = first.1["fingerprint"]
        payload["available_tools"] = []
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "empty")
        payload["available_tools"] = ["shell"]
        payload["current_constraints"] = ["RUN fixture tests"]
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "empty")
        payload["current_constraints"] = []
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "empty")
        payload["current_constraints"] = ["run fixture tests"]
        try Data("changed source".utf8).write(to: file)
        payload["validated_dependencies"] = dependencies // Never trust caller freshness claims.
        let stale = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(stale.1["status"] as? String, "empty")
        XCTAssertEqual((stale.1["excluded"] as? [String: Int])?["dependencies"], 1)
    }

    func testContextHonorsArchiveExpiryFeatureAndProjectScope() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin), other = try addProject(h, admin)
        let entry = try contextEntry(h, admin: admin, project: project)
        _ = try contextEntry(h, admin: admin, project: project, changes: ["expires_at": "2000-01-01T00:00:00Z"])
        let reader = try unlock(h, project: project, writable: false)
        let payload: [String: Any] = ["project_id": project, "query": "parser tests"]
        let first = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual((first.1["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try rpc(h, reader, "context_prepare", ["project_id": other, "query": "parser tests"]).0, 403)
        _ = try rpc(h, admin, "entry_archive", ["project_id": project, "id": entry["id"]!, "archived": true])
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "empty")
        _ = try rpc(h, admin, "entry_archive", ["project_id": project, "id": entry["id"]!, "archived": false])
        var settings = try rpc(h, admin, "project_get", ["project_id": project]).1
        settings["feature_flags"] = ["plan_reuse": false]
        XCTAssertEqual(try rpc(h, admin, "project_save", settings).0, 200)
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "empty")
        settings["mode"] = "off"
        _ = try rpc(h, admin, "project_save", settings)
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).1["status"] as? String, "disabled")
        h.service.handleScreenLock()
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).0, 403)
    }

    func testContextBoundsFullMultibytePacketAndRejectsInvalidLimits() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        _ = try contextEntry(h, admin: admin, project: project, changes: ["content": "Parser tests " + String(repeating: "🥭", count: 5_000)])
        _ = try contextEntry(h, admin: admin, project: project, changes: ["content": "Parser tests " + String(repeating: "測試", count: 30)])
        let reader = try unlock(h, project: project, writable: false)
        var payload: [String: Any] = ["project_id": project, "query": "parser tests", "max_bytes": 2_000, "max_estimated_tokens": 650]
        let result = try rpc(h, reader, "context_prepare", payload)
        XCTAssertEqual(result.0, 200, "\(result.1)")
        let bytes = try JSONValue.data(result.1).count
        XCTAssertLessThanOrEqual(bytes, 1_950)
        XCTAssertEqual(result.1["output_bytes"] as? Int, bytes)
        XCTAssertEqual(result.1["estimated_tokens"] as? Int, (bytes + 2) / 3)
        XCTAssertEqual((result.1["entries"] as? [[String: Any]])?.count, 1)
        payload["max_bytes"] = true
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).0, 400)
        payload["max_bytes"] = 2_000
        payload["if_fingerprint"] = "not-a-fingerprint"
        XCTAssertEqual(try rpc(h, reader, "context_prepare", payload).0, 400)
    }

    func testContextFinalBudgetIncludesExclusionsAndRequestIdentity() throws {
        let project: [String: Any] = ["id": "fixture-project", "root": "/synthetic", "mode": "suggest", "storage_enabled": true]
        let first: [String: Any] = ["id": "first", "project_id": "fixture-project", "kind": "memory", "content": String(repeating: "source ", count: 80)]
        let large: [String: Any] = ["id": "large", "project_id": "fixture-project", "kind": "memory", "content": String(repeating: "long ", count: 800)]
        let fingerprint: (Data) -> String = { _ in String(repeating: "a", count: 64) }
        var payload: [String: Any] = ["query": "source", "validated_root": "/synthetic"]
        let baseline = try OptimizerContext.prepare(project: project, candidates: [first], payload: payload, fingerprint: fingerprint)
        let exact = try JSONValue.data(baseline).count
        payload["max_bytes"] = exact
        let bounded = try OptimizerContext.prepare(project: project, candidates: [first, large], payload: payload, fingerprint: fingerprint)
        XCTAssertLessThanOrEqual(try JSONValue.data(bounded).count, exact)
        payload["max_bytes"] = 512
        let minimum = try OptimizerContext.prepare(project: project, candidates: [large], payload: payload, fingerprint: fingerprint)
        XCTAssertLessThanOrEqual(try JSONValue.data(minimum).count, 512)
        XCTAssertTrue((minimum["entries"] as? [[String: Any]])?.isEmpty == true)

        let h = try harness(), admin = try unlock(h), projectID = try addProject(h, admin)
        _ = try contextEntry(h, admin: admin, project: projectID)
        let reader = try unlock(h, project: projectID, writable: false)
        var request: [String: Any] = ["project_id": projectID, "query": "parser tests"]
        let original = try rpc(h, reader, "context_prepare", request).1
        request["if_fingerprint"] = original["fingerprint"]
        request["max_bytes"] = 10_000
        let changed = try rpc(h, reader, "context_prepare", request).1
        XCTAssertEqual(changed["status"] as? String, "prepared")
        XCTAssertNotEqual(changed["fingerprint"] as? String, original["fingerprint"] as? String)
    }

    func testContextRootChangeRetriesAndFingerprintsAreKeyedPerProject() throws {
        let project: [String: Any] = ["id": "fixture", "root": "/changed", "mode": "suggest", "storage_enabled": true]
        let result = try OptimizerContext.prepare(project: project, candidates: [],
            payload: ["query": "tests", "validated_root": "/old"], fingerprint: { _ in XCTFail("stale root cannot produce fingerprint"); return "" })
        XCTAssertEqual(result["status"] as? String, "retry_required")
        XCTAssertNil(result["fingerprint"])
        let h = try harness(), admin = try unlock(h), first = try addProject(h, admin), second = try addProject(h, admin)
        let source = Data("same approved content".utf8)
        let firstHash = try h.optimizer.store.fingerprint(projectID: first, data: source)
        XCTAssertNotEqual(firstHash, try h.optimizer.store.fingerprint(projectID: second, data: source))
        let otherStore = try OptimizerStore(directory: TempDir.make())
        try otherStore.unlock(key: Data(repeating: 7, count: 32))
        var sameProject = try rpc(h, admin, "project_get", ["project_id": first]).1
        sameProject["id"] = first
        _ = try otherStore.perform(operation: "project_save", payload: sameProject)
        XCTAssertNotEqual(firstHash, try otherStore.fingerprint(projectID: first, data: source))
    }
}
