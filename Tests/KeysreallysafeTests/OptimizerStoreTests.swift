import Foundation
import CryptoKit
import XCTest
@testable import KeysCore

final class OptimizerStoreTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func project(_ id: String = "project-a", mode: String = "suggest", retention: Int = 30) -> [String: Any] {
        [
            "id": id, "name": "Synthetic Project", "root": "/tmp/synthetic", "mode": mode,
            "storage_enabled": true, "provider_enabled": false, "retention_days": retention,
            "max_requests": 10, "max_input_tokens": 1_000, "feature_flags": ["search": true],
        ]
    }

    private func addProject(_ store: OptimizerStore, id: String = "project-a", mode: String = "suggest") throws {
        _ = try store.perform(operation: "project_save", payload: project(id, mode: mode))
    }

    private func entry(_ projectID: String = "project-a", id: String = "entry-a", content: String = "Run the synthetic verification command") -> [String: Any] {
        [
            "project_id": projectID, "id": id, "kind": "plan", "title": "Synthetic test plan", "content": content,
            "tags": ["synthetic", "test"], "source": "approved", "constraints": ["use a test fixture"],
            "required_tools": ["shell"], "dependencies": ["Package.swift": "hash-a"], "verification": "tests pass",
        ]
    }

    func testLockReopenAndEncryptedFiles() throws {
        let dir = try TempDir.make()
        let first = try OptimizerStore(directory: dir)
        XCTAssertEqual(first.status()["state"] as? String, "locked")
        try first.unlock(key: key)
        try addProject(first)
        _ = try first.perform(operation: "entry_save", payload: entry())
        first.lock()
        XCTAssertEqual(first.status()["state"] as? String, "locked")
        XCTAssertThrowsError(try first.perform(operation: "entry_export", payload: ["project_id": "project-a"]))

        let second = try OptimizerStore(directory: dir)
        try second.unlock(key: key)
        let exported = try second.perform(operation: "entry_export", payload: ["project_id": "project-a"])
        XCTAssertEqual((exported["entries"] as? [[String: Any]])?.count, 1)
        let encrypted = try Data(contentsOf: dir.appendingPathComponent("optimizer-content.gcm"))
        XCTAssertFalse(String(data: encrypted, encoding: .utf8)?.contains("Synthetic test plan") ?? false)
    }

    func testTamperFailsClosed() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key)
        try addProject(store)
        try Data(repeating: 0xA5, count: 48).write(to: dir.appendingPathComponent("optimizer-content.gcm"))
        let reopened = try OptimizerStore(directory: dir)
        XCTAssertThrowsError(try reopened.unlock(key: key))
    }

    func testScopedIsolationAndAdminProjectMutations() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key)
        try addProject(store, id: "project-a")
        try addProject(store, id: "project-b")
        _ = try store.perform(operation: "entry_save", payload: entry("project-a"))
        XCTAssertThrowsError(try store.perform(operation: "entry_export", payload: ["project_id": "project-a"], projectScope: "project-b"))
        let summary = try store.perform(operation: "summary", payload: [:], projectScope: "project-a")
        XCTAssertEqual((summary["projects"] as? [[String: Any]])?.map { $0["id"] as? String }, ["project-a"])
        XCTAssertThrowsError(try store.perform(operation: "project_save", payload: project("project-a"), projectScope: "project-a"))
    }

    func testConcurrentStoresDoNotLoseEntryUpdates() throws {
        let dir = try TempDir.make()
        let first = try OptimizerStore(directory: dir)
        let second = try OptimizerStore(directory: dir)
        try first.unlock(key: key)
        try addProject(first)
        try second.unlock(key: key)
        let group = DispatchGroup()
        let errors = LockedErrors()
        for (store, id) in [(first, "one"), (second, "two")] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let payload: [String: Any] = [
                    "project_id": "project-a", "id": id, "kind": "plan", "title": "Concurrent plan",
                    "content": "Synthetic concurrent verification", "source": "approved", "verification": ["tests pass"],
                ]
                do { _ = try store.perform(operation: "entry_save", payload: payload) }
                catch { errors.append(error) }
            }
        }
        group.wait()
        XCTAssertTrue(errors.values.isEmpty)
        let list = try first.perform(operation: "entry_list", payload: ["project_id": "project-a"])
        XCTAssertEqual((list["entries"] as? [[String: Any]])?.count, 2)
    }

    func testSearchStalenessAndSecretFilter() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store)
        var expired = entry(); expired["expires_at"] = "1970-01-01T00:00:00Z"
        _ = try store.perform(operation: "entry_save", payload: expired)
        let result = try store.perform(operation: "search", payload: ["project_id": "project-a", "query": "synthetic verification", "available_tools": ["shell"], "dependencies": ["Package.swift": "hash-a"], "max_candidates": 5])
        XCTAssertEqual(result["candidate_count"] as? Int, 0)
        XCTAssertThrowsError(try store.perform(operation: "entry_save", payload: entry(id: "secret", content: "api_key=not-a-real-secret")))
    }

    func testSearchKeepsCurrentBodiesWithinContextBudget() throws {
        let store = try OptimizerStore(directory: TempDir.make())
        try store.unlock(key: key); try addProject(store)
        for index in 0..<8 {
            let payload = entry(id: "plan-\(index)", content: "synthetic verification " + String(repeating: "fixture ", count: 1_200))
            _ = try store.perform(operation: "entry_save", payload: payload)
            _ = try store.perform(operation: "entry_save", payload: payload)
        }
        let found = try store.perform(operation: "search", payload: ["project_id": "project-a", "query": "synthetic verification"])
        let candidates = try XCTUnwrap(found["candidates"] as? [[String: Any]])
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThan(candidates.count, 8)
        XCTAssertLessThan(try JSONValue.data(found).count, 65_000)
        XCTAssertTrue(candidates.allSatisfy { $0["revisions"] == nil && $0["content"] != nil })
        let current = try store.perform(operation: "entry_get", payload: ["project_id": "project-a", "id": "plan-0", "include_revisions": false])
        XCTAssertNil(current["revisions"])
        let history = try store.perform(operation: "entry_get", payload: ["project_id": "project-a", "id": "plan-0"])
        XCTAssertEqual((history["revisions"] as? [[String: Any]])?.count, 2)
    }

    func testReservationsAndUnknownNumericAccounting() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        let reservation = try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a", "reservation_id": "r1", "request_count": 1, "estimated_input_tokens": 100])
        XCTAssertEqual(reservation["reservation_id"] as? String, "r1")
        _ = try store.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a", "reservation_id": "r1", "dispatched": false])
        _ = try store.perform(operation: "event_record", payload: ["project_id": "project-a", "task_id": "task-a", "event_id": "event-a", "source": "gateway", "kind": "jev", "model": "synthetic", "latency_ms": 4, "status": "ok"])
        let list = try store.perform(operation: "event_list", payload: ["project_id": "project-a"])
        let totals = list["aggregate"] as? [String: Any]
        XCTAssertEqual(totals?["input_tokens_known"] as? Int, 0)
        XCTAssertEqual(totals?["input_tokens_unknown_events"] as? Int, 1)
        XCTAssertThrowsError(try store.perform(operation: "event_record", payload: ["project_id": "project-a", "task_id": "task-a", "event_id": "event-b", "source": "gateway", "kind": "jev", "model": "synthetic", "input_tokens": false, "latency_ms": 1, "status": "ok"]))
        XCTAssertThrowsError(try store.perform(operation: "event_record", payload: ["project_id": "project-a", "task_id": "task-a", "event_id": "event-c", "source": "gateway", "kind": "jev", "model": "synthetic", "input_tokens": 1.5, "latency_ms": 1, "status": "ok"]))
    }

    func testProjectDeleteClearsPendingAndSettledBudget() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        _ = try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a", "reservation_id": "settled", "request_count": 1, "estimated_input_tokens": 100])
        _ = try store.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a", "reservation_id": "settled", "dispatched": true, "actual_input_tokens": 100])
        _ = try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a", "reservation_id": "pending", "request_count": 1, "estimated_input_tokens": 100])
        _ = try store.perform(operation: "project_delete", payload: ["project_id": "project-a"])
        try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        XCTAssertNoThrow(try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a", "request_count": 10, "estimated_input_tokens": 1_000]))
    }

    func testJSONNumbersAllowZeroAndOneButRejectBoolean() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        func decoded(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let zeroOne = try decoded("""
        {"project_id":"project-a","task_id":"task-a","event_id":"json-number","source":"gateway","kind":"jev","model":"synthetic","input_tokens":0,"output_tokens":1,"reported_cost_usd":0,"latency_ms":0,"status":"ok"}
        """)
        XCTAssertNoThrow(try store.perform(operation: "event_record", payload: zeroOne))
        let boolean = try decoded("""
        {"project_id":"project-a","task_id":"task-a","event_id":"json-bool","source":"gateway","kind":"jev","model":"synthetic","input_tokens":false,"latency_ms":0,"status":"ok"}
        """)
        XCTAssertThrowsError(try store.perform(operation: "event_record", payload: boolean))
    }

    func testRequestIdentityDedupAndParentProjectIsolation() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store, id: "project-a"); try addProject(store, id: "project-b")
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "parent", "client": "test"])
        XCTAssertNoThrow(try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "child", "parent_id": "parent", "client": "test"]))
        XCTAssertThrowsError(try store.perform(operation: "task_start", payload: ["project_id": "project-b", "id": "cross-project-child", "parent_id": "parent", "client": "test"]))
        let base: [String: Any] = ["project_id": "project-a", "task_id": "parent", "request_id": "request-1", "source": "gateway", "kind": "jev", "model": "synthetic", "latency_ms": 1, "status": "observed"]
        var first = base; first["event_id"] = "event-a"
        var duplicate = base; duplicate["event_id"] = "event-b"; duplicate["source"] = "client"
        XCTAssertEqual(try store.perform(operation: "event_record", payload: first)["deduplicated"] as? Bool, false)
        XCTAssertEqual(try store.perform(operation: "event_record", payload: duplicate)["deduplicated"] as? Bool, true)
        let events = try store.perform(operation: "event_list", payload: ["project_id": "project-a"])
        XCTAssertEqual((events["events"] as? [[String: Any]])?.count, 1)
    }

    func testMixedUsageAggregateSeparatesOptimizerClientAndCache() throws {
        let dir = try TempDir.make()
        let store = try OptimizerStore(directory: dir)
        try store.unlock(key: key); try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        let common: [String: Any] = ["project_id": "project-a", "task_id": "task-a", "latency_ms": 1]
        var jev = common
        jev.merge(["event_id": "jev-1", "source": "optimizer", "kind": "jev_decision", "model": "jev-v1", "input_tokens": 10, "output_tokens": 2, "cache_read_tokens": 1, "reported_cost_usd": 0.1, "status": "selected"]) { _, new in new }
        var main = common
        main.merge(["event_id": "main-1", "source": "client", "kind": "main", "model": "main-v1", "input_tokens": 100, "output_tokens": 20, "estimated_cost_usd": 0.8, "status": "success"]) { _, new in new }
        var cache = common
        cache.merge(["event_id": "cache-1", "source": "optimizer", "kind": "decision_cache_hit", "model": "jev-v1", "status": "reused"]) { _, new in new }
        _ = try store.perform(operation: "event_record", payload: jev)
        _ = try store.perform(operation: "event_record", payload: main)
        _ = try store.perform(operation: "event_record", payload: cache)
        var duplicate = main; duplicate["input_tokens"] = 999
        XCTAssertEqual(try store.perform(operation: "event_record", payload: duplicate)["deduplicated"] as? Bool, true)

        let eventList = try store.perform(operation: "event_list", payload: ["project_id": "project-a"])
        let aggregate = try XCTUnwrap(eventList["aggregate"] as? [String: Any])
        XCTAssertEqual(aggregate["input_tokens_known"] as? Int, 110)
        XCTAssertEqual(aggregate["input_tokens_unknown_events"] as? Int, 1)
        XCTAssertEqual(aggregate["exact_cache_hits"] as? Int, 1)
        XCTAssertEqual((aggregate["decisions_by_status"] as? [String: Int])?["selected"], 1)
        let optimizer = try XCTUnwrap(aggregate["optimizer"] as? [String: Any])
        XCTAssertEqual(optimizer["input_tokens_known"] as? Int, 10)
        XCTAssertEqual(optimizer["input_tokens_unknown_events"] as? Int, 1)
        let client = try XCTUnwrap(aggregate["client"] as? [String: Any])
        XCTAssertEqual(client["input_tokens_known"] as? Int, 100)
        XCTAssertEqual(client["input_tokens_unknown_events"] as? Int, 0)
        let bySource = try XCTUnwrap(aggregate["by_source"] as? [String: [String: Any]])
        XCTAssertEqual(bySource["optimizer"]?["events"] as? Int, 2)
        XCTAssertEqual(bySource["client"]?["events"] as? Int, 1)

        let summary = try store.perform(operation: "summary", payload: [:])
        let task = try XCTUnwrap((summary["tasks"] as? [[String: Any]])?.first)
        let taskAggregate = try XCTUnwrap(task["aggregate"] as? [String: Any])
        XCTAssertEqual((taskAggregate["optimizer"] as? [String: Any])?["input_tokens_known"] as? Int, 10)
        XCTAssertEqual((taskAggregate["client"] as? [String: Any])?["input_tokens_known"] as? Int, 100)
    }

    private func rewriteLedger(_ directory: URL, change: (inout [String: Any]) throws -> Void) throws {
        let path = directory.appendingPathComponent("optimizer-ledger.gcm")
        let symmetricKey = SymmetricKey(data: key)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: path)), using: symmetricKey)
        var ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try change(&ledger)
        try XCTUnwrap(AES.GCM.seal(JSONValue.data(ledger), using: symmetricKey).combined).write(to: path)
    }

    func testCumulativeSettledAndUnknownUsageSurviveRetentionAndReopen() throws {
        let directory = try TempDir.make(), store = try OptimizerStore(directory: directory)
        try store.unlock(key: key); try addProject(store)
        _ = try store.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        for id in ["settled", "unknown"] {
            _ = try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a",
                "reservation_id": id, "request_count": 1, "estimated_input_tokens": 100])
        }
        _ = try store.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "settled", "dispatched": true, "actual_input_tokens": 75])
        store.lock()
        try rewriteLedger(directory) { ledger in
            for (key, timestamp) in [("reservations", "createdAt"), ("budgetUsage", "settledAt")] {
                var rows = try XCTUnwrap(ledger[key] as? [[String: Any]])
                for index in rows.indices { rows[index][timestamp] = Int64(Date().addingTimeInterval(-31 * 86_400).timeIntervalSince1970 * 1_000) }
                ledger[key] = rows
            }
        }
        // A new controller/store has no in-memory outcome facts after a crash.
        let reopened = try OptimizerStore(directory: directory)
        try reopened.unlock(key: key)
        let pending = try reopened.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "unknown", "request_count": 1, "estimated_input_tokens": 100])
        let budget = try XCTUnwrap(pending["budget"] as? [String: Any])
        XCTAssertEqual(budget["requests_used"] as? Int, 2)
        XCTAssertEqual(budget["input_tokens_used"] as? Int, 175)
        let released = try reopened.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "unknown", "dispatched": false])
        XCTAssertEqual((released["budget"] as? [String: Any])?["input_tokens_used"] as? Int, 75)
    }

    func testConcurrentReservationsReserveSettlementCapacityBeforeDispatch() throws {
        let directory = try TempDir.make(), first = try OptimizerStore(directory: directory)
        try first.unlock(key: key)
        var configuration = project()
        configuration["max_requests"] = 100_000
        configuration["max_input_tokens"] = 100_000_000
        _ = try first.perform(operation: "project_save", payload: configuration)
        _ = try first.perform(operation: "task_start", payload: ["project_id": "project-a", "id": "task-a", "client": "test"])
        _ = try first.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "seed", "request_count": 1, "estimated_input_tokens": 1])
        _ = try first.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "seed", "dispatched": true])
        first.lock()
        try rewriteLedger(directory) { ledger in
            let row = try XCTUnwrap((ledger["budgetUsage"] as? [[String: Any]])?.first)
            ledger["budgetUsage"] = Array(repeating: row, count: 9_999)
        }
        try first.unlock(key: key)
        let second = try OptimizerStore(directory: directory)
        try second.unlock(key: key)
        let group = DispatchGroup(), errors = LockedErrors()
        for (store, id) in [(first, "one"), (second, "two")] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try store.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a",
                        "reservation_id": id, "request_count": 1, "estimated_input_tokens": 1])
                } catch { errors.append(error) }
            }
        }
        group.wait()
        XCTAssertEqual(errors.values.count, 1, "Only one settlement slot remains")
        guard let error = errors.values.first, case OptimizerStoreError.limit = error else { return XCTFail("Expected reservation-time ledger limit") }
        var settlements = 0
        for id in ["one", "two"] {
            do {
                _ = try first.perform(operation: "task_settle", payload: ["project_id": "project-a", "task_id": "task-a",
                    "reservation_id": id, "dispatched": true])
                settlements += 1
            } catch OptimizerStoreError.notFound { }
        }
        XCTAssertEqual(settlements, 1, "The admitted request always has a settlement slot")
        XCTAssertThrowsError(try first.perform(operation: "task_reserve", payload: ["project_id": "project-a", "task_id": "task-a",
            "reservation_id": "full", "request_count": 1, "estimated_input_tokens": 1]))
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Error] = []
    func append(_ error: Error) { lock.lock(); values.append(error); lock.unlock() }
}
