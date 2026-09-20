import Foundation
import XCTest
@testable import KeysCore

final class OptimizerCandidateTests: XCTestCase {
    private let key = Data(repeating: 31, count: 32)
    private func project(_ enabled: Bool = true, id: String = "project-a") -> [String: Any] {
        ["id": id, "name": "Candidate fixture", "root": "/tmp/keys-candidate-fixture", "mode": "suggest",
         "storage_enabled": true, "provider_enabled": false, "retention_days": 30,
         "max_requests": 10, "max_input_tokens": 1000, "feature_flags": ["candidate_capture": enabled]]
    }
    private func store(enabled: Bool = true) throws -> OptimizerStore {
        let store = try OptimizerStore(directory: TempDir.make())
        try store.unlock(key: key)
        _ = try store.perform(operation: "project_save", payload: project(enabled))
        return store
    }
    private func task(_ store: OptimizerStore, outcome: String = "success", evidence: [String] = ["Fixture verification passed"]) throws {
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "fixture"])
        _ = try store.perform(operation: "task_finish", payload: ["project_id": "project-a", "id": "task-a", "outcome": outcome, "verification": evidence])
    }
    private func candidate() -> [String: Any] {
        ["project_id": "project-a", "task_id": "task-a", "kind": "plan", "title": "Synthetic reusable plan",
         "content": "Run the fixture verification", "source": "task:task-a", "verification": ["Run fixture checks"]]
    }
    private func search(_ store: OptimizerStore) throws -> [[String: Any]] {
        try store.perform(operation: "search", payload: ["project_id": "project-a", "query": "synthetic"])["candidates"] as? [[String: Any]] ?? []
    }

    func testCaptureRequiresOptInWritableAndVerifiedSuccessfulTask() throws {
        let disabled = try store(enabled: false)
        try task(disabled)
        XCTAssertThrowsError(try disabled.perform(operation: "candidate_capture", payload: candidate()))
        for (outcome, evidence) in [("success", [String]()), ("failed", ["Failed fixture"])] {
            let s = try store()
            try task(s, outcome: outcome, evidence: evidence)
            XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: candidate()))
        }
        let s = try store()
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: candidate()))
        try task(s)
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: candidate(), allowWrite: false))
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: candidate(), projectScope: "project-b"))
        var malicious = candidate(); malicious["review_state"] = "approved"
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: malicious))
    }

    func testPendingCandidateIsExcludedFromLibrarySearchAndContextUntilAdminApproval() throws {
        let s = try store(); try task(s)
        let captured = try s.perform(operation: "candidate_capture", payload: candidate(), projectScope: "project-a")
        let id = try XCTUnwrap(captured["id"] as? String)
        XCTAssertEqual(captured["review_state"] as? String, "pending")
        XCTAssertTrue(try search(s).isEmpty)
        XCTAssertEqual((try s.perform(operation: "entry_list", payload: ["project_id": "project-a"])["entries"] as? [Any])?.count, 0)
        let pack = try s.perform(operation: "context_prepare", payload: ["project_id": "project-a", "query": "synthetic", "validated_dependencies": [:], "validated_root": "/tmp/keys-candidate-fixture"])
        XCTAssertEqual(pack["status"] as? String, "empty")
        let review: [String: Any] = ["project_id": "project-a", "id": id, "decision": "approve", "expected_version": 1]
        XCTAssertThrowsError(try s.perform(operation: "candidate_review", payload: review, projectScope: "project-a"))
        XCTAssertThrowsError(try s.perform(operation: "candidate_review", payload: review, allowWrite: false))
        _ = try s.perform(operation: "candidate_review", payload: review)
        XCTAssertEqual(try search(s).count, 1)
        XCTAssertEqual(try search(s).first?["review_state"] as? String, "approved")
        var changed = candidate(); changed["id"] = id; changed["content"] = "Edited after review"
        let edited = try s.perform(operation: "entry_save", payload: changed, projectScope: "project-a")
        XCTAssertEqual(edited["review_state"] as? String, "pending")
        XCTAssertTrue(try search(s).isEmpty)
        XCTAssertThrowsError(try s.perform(operation: "candidate_review", payload: review))
        var currentReview = review; currentReview["expected_version"] = 2
        _ = try s.perform(operation: "candidate_review", payload: currentReview)
        XCTAssertEqual(try search(s).count, 1)
    }

    func testReviewVersionAndRejectionCannotBeBypassedByEditOrRestore() throws {
        let s = try store(); try task(s)
        let captured = try s.perform(operation: "candidate_capture", payload: candidate())
        let id = try XCTUnwrap(captured["id"] as? String)
        var edited = candidate(); edited["id"] = id; edited["content"] = "Changed candidate content"
        _ = try s.perform(operation: "entry_save", payload: edited)
        XCTAssertTrue(try search(s).isEmpty)
        var review: [String: Any] = ["project_id": "project-a", "id": id, "decision": "approve", "expected_version": 1]
        XCTAssertThrowsError(try s.perform(operation: "candidate_review", payload: review))
        review["expected_version"] = 2; review["decision"] = "reject"
        _ = try s.perform(operation: "candidate_review", payload: review)
        _ = try s.perform(operation: "entry_archive", payload: ["project_id": "project-a", "id": id, "archived": false])
        _ = try s.perform(operation: "entry_save", payload: edited)
        XCTAssertTrue(try search(s).isEmpty)
        XCTAssertEqual((try s.perform(operation: "candidate_list", payload: ["project_id": "project-a", "review_state": "rejected"])["candidates"] as? [Any])?.count, 1)
    }

    func testCaptureRetriesDeduplicateAndFinalOutcomeCannotBeRewritten() throws {
        let s = try store(); try task(s)
        try task(s)
        let a = try s.perform(operation: "candidate_capture", payload: candidate())
        let b = try s.perform(operation: "candidate_capture", payload: candidate())
        XCTAssertEqual(a["id"] as? String, b["id"] as? String)
        XCTAssertEqual(b["deduplicated"] as? Bool, true)
        var changed = candidate(); changed["content"] = "Conflicting retry"
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: changed))
        var prerequisites = candidate(); prerequisites["required_tools"] = ["new-required-tool"]
        XCTAssertThrowsError(try s.perform(operation: "candidate_capture", payload: prerequisites))
        XCTAssertThrowsError(try task(s, outcome: "failed"))
    }

    func testEncryptedCandidateSurvivesLockAndProjectDeletionRemovesIt() throws {
        let directory = try TempDir.make()
        let s = try OptimizerStore(directory: directory); try s.unlock(key: key)
        _ = try s.perform(operation: "project_save", payload: project()); try task(s)
        _ = try s.perform(operation: "candidate_capture", payload: candidate())
        s.lock()
        XCTAssertThrowsError(try s.perform(operation: "candidate_list", payload: ["project_id": "project-a"]))
        let encrypted = try Data(contentsOf: directory.appendingPathComponent("optimizer-content.gcm"))
        XCTAssertNil(encrypted.range(of: Data("Synthetic reusable plan".utf8)))
        try s.unlock(key: key)
        XCTAssertTrue(try search(s).isEmpty)
        XCTAssertEqual((try s.perform(operation: "candidate_list", payload: ["project_id": "project-a"])["candidates"] as? [Any])?.count, 1)
        _ = try s.perform(operation: "project_delete", payload: ["project_id": "project-a"])
        XCTAssertEqual(try s.perform(operation: "summary", payload: [:])["entries"] as? Int, 0)
    }
}

extension OptimizerAPITests {
    func testCandidateHTTPFlowRequiresWriteCaptureOptInAndAdminReview() throws {
        let h = try harness(), admin = try unlock(h), project = try addProject(h, admin)
        var settings = try rpc(h, admin, "project_get", ["project_id": project]).1
        settings["feature_flags"] = ["candidate_capture": true]
        XCTAssertEqual(try rpc(h, admin, "project_save", settings).0, 200)
        let writer = try unlock(h, project: project), reader = try unlock(h, project: project, writable: false)
        let task = try rpc(h, writer, "task_start", ["project_id": project, "client": "capture-test"]).1
        let taskID = try XCTUnwrap(task["id"] as? String)
        let finish = try rpc(h, writer, "task_finish", ["project_id": project, "id": taskID,
            "outcome": "success", "verification": ["Private verification evidence"]])
        XCTAssertEqual(finish.0, 200)
        XCTAssertEqual(finish.1["verification_recorded"] as? Bool, true)
        XCTAssertFalse(String(decoding: try JSONValue.data(finish.1), as: UTF8.self).contains("Private verification evidence"))
        let payload: [String: Any] = ["project_id": project, "task_id": taskID, "kind": "plan",
            "title": "HTTP candidate", "content": "Run fixture checks", "source": "synthetic", "verification": ["Run checks"]]
        XCTAssertEqual(try rpc(h, reader, "candidate_capture", payload).0, 403)
        let capture = try rpc(h, writer, "candidate_capture", payload)
        XCTAssertEqual(capture.0, 200)
        let id = try XCTUnwrap(capture.1["id"] as? String)
        let review: [String: Any] = ["project_id": project, "id": id, "decision": "approve", "expected_version": 1]
        XCTAssertEqual(try rpc(h, writer, "candidate_review", review).0, 403)
        var stale = review; stale["expected_version"] = 2
        XCTAssertEqual(try rpc(h, admin, "candidate_review", stale).0, 409)
        XCTAssertEqual(try rpc(h, admin, "candidate_review", review).0, 200)
        h.service.handleScreenLock()
        XCTAssertEqual(try rpc(h, writer, "candidate_list", ["project_id": project]).0, 403)
    }
}
