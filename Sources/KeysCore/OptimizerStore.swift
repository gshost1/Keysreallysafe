import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// Optional, local storage for curated optimizer knowledge and numeric usage.
/// The caller owns authentication and capabilities; this type enforces the
/// storage boundary, project scope, and bounded record shapes a second time.
final class OptimizerStore: @unchecked Sendable {
    private static let schema = 1
    private static let maxProjects = 128
    private static let maxEntriesPerProject = 250
    private static let maxEntries = 1_000
    private static let maxEvents = 10_000
    private static let maxLogicalContentBytes = 5 * 1_024 * 1_024
    private static let maxStateBytes = 8 * 1_024 * 1_024
    private static let maxTransactionBytes = 16 * 1_024 * 1_024
    private static let defaultFeatureFlags: [String: Bool] = [
        "memory_retrieval": true, "plan_reuse": true, "tool_selection": true,
        "model_routing": true, "memory_assessment": true,
        "candidate_capture": false, "auto_validation": false,
    ]

    private let directory: URL
    private let contentURL: URL
    private let ledgerURL: URL
    private let transactionURL: URL
    private let lockURL: URL
    private let stateLock = NSLock()
    private var key: SymmetricKey?
    private var content = ContentState()
    private var ledger = LedgerState()
    private var shortlist: [String: [Entry]] = [:]

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        contentURL = self.directory.appendingPathComponent("optimizer-content.gcm")
        ledgerURL = self.directory.appendingPathComponent("optimizer-ledger.gcm")
        transactionURL = self.directory.appendingPathComponent("optimizer-transaction.gcm")
        lockURL = self.directory.appendingPathComponent("optimizer.lock")
        try ensureDirectory()
    }

    var isUnlocked: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return key != nil
    }

    func unlock(key rawKey: Data) throws {
        guard rawKey.count == 32 else { throw OptimizerStoreError.invalid("unlock key must be 32 bytes") }
        stateLock.lock()
        defer { stateLock.unlock() }
        try withProcessLock {
            let unlockedKey = SymmetricKey(data: rawKey)
            try recoverTransaction(key: unlockedKey)
            let loadedContent = try load(ContentState.self, from: contentURL, key: unlockedKey) ?? ContentState()
            let loadedLedger = try load(LedgerState.self, from: ledgerURL, key: unlockedKey) ?? LedgerState()
            try validateLoaded(content: loadedContent, ledger: loadedLedger)
            content = loadedContent
            ledger = loadedLedger
            self.key = unlockedKey
            let pruned = prune(now: Self.now())
            rebuildShortlist()
            if pruned { try persist(key: unlockedKey, previousContent: loadedContent, previousLedger: loadedLedger) }
        }
    }

    func lock() {
        stateLock.lock()
        key = nil
        content = ContentState()
        ledger = LedgerState()
        shortlist.removeAll(keepingCapacity: false)
        stateLock.unlock()
    }

    /// Deletes encrypted optimizer payloads under the process lock. The caller
    /// removes any separately managed Keychain key after its presence check.
    func destroy() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try withProcessLock {
            let fm = FileManager.default
            if fm.fileExists(atPath: contentURL.path) { try removeAndSync(contentURL) }
            if fm.fileExists(atPath: ledgerURL.path) { try removeAndSync(ledgerURL) }
            if fm.fileExists(atPath: transactionURL.path) { try removeAndSync(transactionURL) }
            content = ContentState()
            ledger = LedgerState()
            shortlist.removeAll(keepingCapacity: false)
            key = nil
        }
    }

    func status() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        guard key != nil else { return ["state": "locked"] }
        return [
            "state": "ready",
            "schema_version": Self.schema,
            "projects": content.projects.count,
            "entries": content.entries.count,
            "events": ledger.events.count,
        ]
    }

    /// Produces a project-domain-separated fingerprint without exposing the
    /// master key or using an unkeyed, guessable content hash.
    func fingerprint(projectID: String, data: Data) throws -> String {
        guard data.count <= 10 * 1_024 * 1_024 else { throw OptimizerStoreError.limit("fingerprint input is too large") }
        try validateIdentifier(projectID, field: "project_id")
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let key else { throw OptimizerStoreError.locked }
        guard content.projects.contains(where: { $0.id == projectID }) else { throw OptimizerStoreError.notFound("project") }
        return fingerprintLocked(projectID: projectID, data: data, key: key)
    }

    private func fingerprintLocked(projectID: String, data: Data, key: SymmetricKey) -> String {
        var message = Data(projectID.utf8)
        message.append(0)
        message.append(data)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    func perform(
        operation: String,
        payload: [String: Any],
        projectScope: String? = nil,
        allowWrite: Bool = true
    ) throws -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let key else { throw OptimizerStoreError.locked }
        let writeOperation = Self.writes.contains(operation)
        if writeOperation && !allowWrite { throw OptimizerStoreError.denied("write capability is required") }
        return try withProcessLock {
            try reload(key: key)
            let beforeContent = content
            let beforeLedger = ledger
            do {
                let response = try dispatch(operation: operation, payload: payload, projectScope: projectScope)
                if writeOperation {
                    try persist(key: key, previousContent: beforeContent, previousLedger: beforeLedger)
                }
                return response
            } catch {
                content = beforeContent
                ledger = beforeLedger
                rebuildShortlist()
                throw error
            }
        }
    }

    private static let writes: Set<String> = [
        "project_save", "project_delete", "entry_save", "entry_archive", "entry_delete",
        "task_start", "task_reserve", "task_settle", "task_finish", "event_record", "reset",
        "candidate_capture", "candidate_review",
    ]

    private func dispatch(operation: String, payload: [String: Any], projectScope: String?) throws -> [String: Any] {
        if prune(now: Self.now()) { rebuildShortlist() }
        switch operation {
        case "summary":
            return summary(projectScope: projectScope)
        case "project_get":
            return try projectGet(payload, scope: projectScope)
        case "project_save":
            return try projectSave(payload, scope: projectScope)
        case "project_delete":
            return try projectDelete(payload, scope: projectScope)
        case "entry_save":
            return try entrySave(payload, scope: projectScope)
        case "candidate_capture":
            return try candidateCapture(payload, scope: projectScope)
        case "candidate_list":
            return try candidateList(payload, scope: projectScope)
        case "candidate_review":
            return try candidateReview(payload, scope: projectScope)
        case "entry_list":
            return try entryList(payload, scope: projectScope)
        case "entry_get":
            return try entryGet(payload, scope: projectScope)
        case "entry_archive":
            return try entryArchive(payload, scope: projectScope)
        case "entry_delete":
            return try entryDelete(payload, scope: projectScope)
        case "entry_export":
            return try entryExport(payload, scope: projectScope)
        case "search":
            return try search(payload, scope: projectScope)
        case "context_prepare":
            let id = try projectID(payload, scope: projectScope)
            let record = try project(id)
            let found = record.mode != "off" && record.storageEnabled ? try search(payload, scope: projectScope) : [:]
            guard let key else { throw OptimizerStoreError.locked }
            return try OptimizerContext.prepare(project: projectObject(record),
                candidates: found["candidates"] as? [[String: Any]] ?? [], payload: payload) { data in
                    self.fingerprintLocked(projectID: id, data: data, key: key)
                }
        case "task_start":
            return try taskStart(payload, scope: projectScope)
        case "task_reserve":
            return try taskReserve(payload, scope: projectScope)
        case "task_settle":
            return try taskSettle(payload, scope: projectScope)
        case "task_finish":
            return try taskFinish(payload, scope: projectScope)
        case "event_record":
            return try eventRecord(payload, scope: projectScope)
        case "event_list":
            return try eventList(payload, scope: projectScope)
        case "diagnostics":
            return diagnostics(projectScope: projectScope)
        case "reset":
            guard projectScope == nil else { throw OptimizerStoreError.denied("reset requires an admin scope") }
            content = ContentState(); ledger = LedgerState(); rebuildShortlist()
            return ["reset": true]
        default:
            throw OptimizerStoreError.invalid("unknown optimizer operation")
        }
    }

    private func summary(projectScope: String?) -> [String: Any] {
        let projects = scopedProjects(projectScope)
        let ids = Set(projects.map(\.id))
        let entries = content.entries.filter { ids.contains($0.projectID) }
        let events = ledger.events.filter { ids.contains($0.projectID) }
        return [
            "projects": projects.map(projectObject),
            "project_count": projects.count,
            "entries": entries.count,
            "active_entries": entries.filter { $0.isApproved && !$0.archived && !$0.isExpired(now: Self.now()) }.count,
            "pending_candidates": entries.filter { $0.reviewState == "pending" }.count,
            "tasks": ledger.tasks.filter { ids.contains($0.projectID) }.map { taskSummary($0, events: events) },
            "aggregate": aggregate(events),
        ]
    }

    private func diagnostics(projectScope: String?) -> [String: Any] {
        let projects = scopedProjects(projectScope)
        let ids = Set(projects.map(\.id))
        return [
            "schema_version": Self.schema,
            "project_count": projects.count,
            "entry_count": content.entries.filter { ids.contains($0.projectID) }.count,
            "event_count": ledger.events.filter { ids.contains($0.projectID) }.count,
            "content_quota_bytes": Self.maxLogicalContentBytes,
            "content_bytes": logicalContentBytes(),
            "event_quota": Self.maxEvents,
            "storage_encrypted": true,
            "index_persisted": false,
        ]
    }

    private func projectSave(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        guard scope == nil else { throw OptimizerStoreError.denied("project save requires an admin scope") }
        let existingID = try optionalID(p["id"], field: "id")
        if let existingID { try requireScope(existingID, scope) }
        let id = existingID ?? scope ?? UUID().uuidString.lowercased()
        try validateIdentifier(id, field: "id")
        try requireScope(id, scope)
        let existing = content.projects.first(where: { $0.id == id })
        if existing == nil && content.projects.count >= Self.maxProjects { throw OptimizerStoreError.limit("project quota reached") }
        let name = try string(p, "name", max: 200, required: true)
        let root = try string(p, "root", max: 2_048, required: true)
        let requestedMode = try mode(try string(p, "mode", max: 16, required: true))
        let storageEnabled = try bool(p, "storage_enabled")
        let providerEnabled = try bool(p, "provider_enabled")
        let retention = try integer(p, "retention_days", min: 1, max: 3_650)
        let maxRequests = try integer(p, "max_requests", min: 0, max: 1_000_000)
        let maxInput = try integer(p, "max_input_tokens", min: 0, max: 100_000_000)
        var features = existing?.featureFlags ?? Self.defaultFeatureFlags
        for (name, enabled) in try boolMap(p["feature_flags"]) { features[name] = enabled }
        let effectiveMode = requestedMode == "auto" ? "suggest" : requestedMode
        let record = Project(
            id: id, name: name, root: root, mode: effectiveMode, storageEnabled: storageEnabled,
            providerEnabled: providerEnabled, retentionDays: retention, maxRequests: maxRequests,
            maxInputTokens: maxInput, featureFlags: features, createdAt: existing?.createdAt ?? Self.now(), updatedAt: Self.now()
        )
        if let index = content.projects.firstIndex(where: { $0.id == id }) { content.projects[index] = record }
        else { content.projects.append(record) }
        rebuildShortlist()
        var out = projectObject(record)
        if requestedMode == "auto" { out["mode_downgraded"] = true }
        return out
    }

    private func projectGet(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let id = try projectID(p, scope: scope)
        return projectObject(try project(id))
    }

    private func projectDelete(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        guard scope == nil else { throw OptimizerStoreError.denied("project deletion requires an admin scope") }
        let id = try projectID(p, scope: scope)
        guard content.projects.contains(where: { $0.id == id }) else { throw OptimizerStoreError.notFound("project") }
        content.projects.removeAll { $0.id == id }
        content.entries.removeAll { $0.projectID == id }
        ledger.tasks.removeAll { $0.projectID == id }
        ledger.events.removeAll { $0.projectID == id }
        ledger.reservations.removeAll { $0.projectID == id }
        ledger.budgetUsage.removeAll { $0.projectID == id }
        rebuildShortlist()
        return ["deleted": true, "project_id": id]
    }

    private func entrySave(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let project = try project(projectID)
        guard project.storageEnabled else { throw OptimizerStoreError.denied("storage is disabled for this project") }
        let existingID = try optionalID(p["id"], field: "id")
        let id = existingID ?? UUID().uuidString.lowercased()
        if let entry = content.entries.first(where: { $0.id == id }), entry.projectID != projectID {
            throw OptimizerStoreError.denied("entry belongs to a different project")
        }
        let old = content.entries.first(where: { $0.id == id })
        if old == nil && content.entries.filter({ $0.projectID == projectID }).count >= Self.maxEntriesPerProject {
            throw OptimizerStoreError.limit("entry quota reached")
        }
        if old == nil && content.entries.count >= Self.maxEntries { throw OptimizerStoreError.limit("global entry quota reached") }
        let kind = try oneOf(try string(p, "kind", max: 16, required: true), ["memory", "plan"], field: "kind")
        let title = try string(p, "title", max: 300, required: true)
        let body = try string(p, "content", max: 100_000, required: true)
        let tags = try stringArray(p["tags"], field: "tags", maxItems: 32, maxLength: 64)
        let source = try optionalString(p["source"], field: "source", max: 2_000)
        let constraints = try stringArray(p["constraints"], field: "constraints", maxItems: 64, maxLength: 1_000)
        let tools = try stringArray(p["required_tools"], field: "required_tools", maxItems: 64, maxLength: 128)
        let dependencies = try stringMap(p["dependencies"], field: "dependencies", maxItems: 128, maxKey: 1_024, maxValue: 256)
        let verification = try verificationList(p["verification"])
        let expiresAt = try optionalTimestamp(p["expires_at"], field: "expires_at")
        if kind == "plan", (source == nil || verification.isEmpty) {
            throw OptimizerStoreError.invalid("plans require source and verification")
        }
        try rejectSecrets([title, body] + tags + constraints + tools + dependencies.flatMap { [$0.key, $0.value] } + [source ?? ""] + verification)
        let revision = EntryRevision(version: (old?.revisions.last?.version ?? 0) + 1, title: title, content: body, savedAt: Self.now())
        var revisions = old?.revisions ?? []
        revisions.append(revision)
        if revisions.count > 20 { revisions.removeFirst(revisions.count - 20) }
        let record = Entry(
            id: id, projectID: projectID, kind: kind, title: title, content: body, tags: tags,
            source: source, constraints: constraints, requiredTools: tools, dependencies: dependencies,
            verification: verification, expiresAt: expiresAt, pinned: boolOr(p["pinned"], default: old?.pinned ?? false),
            archived: old?.archived ?? false, createdAt: old?.createdAt ?? Self.now(), updatedAt: Self.now(), revisions: revisions,
            reviewState: old?.reviewState == "approved" ? "pending" : old?.reviewState, capturedFromTaskID: old?.capturedFromTaskID
        )
        if let index = content.entries.firstIndex(where: { $0.id == id }) { content.entries[index] = record }
        else { content.entries.append(record) }
        guard logicalContentBytes() <= Self.maxLogicalContentBytes else { throw OptimizerStoreError.limit("content storage quota reached") }
        rebuildShortlist()
        return entryObject(record, includeContent: false)
    }

    private func entryList(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        let query = try optionalString(p["query"], field: "query", max: 500)?.lowercased() ?? ""
        let includeArchived = boolOr(p["include_archived"], default: false)
        let values = content.entries.filter {
            $0.projectID == projectID && $0.isApproved && (includeArchived || !$0.archived) && (query.isEmpty || $0.matches(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
        return ["project_id": projectID, "entries": values.map { entryObject($0, includeContent: false) }]
    }

    private func entryGet(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let id = try identifier(p, "id", max: 128)
        guard let entry = content.entries.first(where: { $0.id == id && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("entry") }
        var result = entryObject(entry, includeContent: true)
        if p["include_revisions"] as? Bool == false { result.removeValue(forKey: "revisions") }
        return result
    }

    private func entryArchive(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let id = try identifier(p, "id", max: 128)
        let archived = try bool(p, "archived")
        guard let index = content.entries.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("entry") }
        content.entries[index].archived = archived
        content.entries[index].updatedAt = Self.now()
        rebuildShortlist()
        return entryObject(content.entries[index], includeContent: false)
    }

    private func entryDelete(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let id = try identifier(p, "id", max: 128)
        guard let index = content.entries.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("entry") }
        content.entries.remove(at: index)
        rebuildShortlist()
        return ["deleted": true, "project_id": projectID, "id": id]
    }

    private func entryExport(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        if let id = try optionalIdentifier(p["id"], field: "id") {
            guard let entry = content.entries.first(where: { $0.projectID == projectID && $0.id == id }) else { throw OptimizerStoreError.notFound("entry") }
            return ["project_id": projectID, "entries": [entryObject(entry, includeContent: true)]]
        }
        return ["project_id": projectID, "entries": content.entries.filter { $0.projectID == projectID }.map { entryObject($0, includeContent: true) }]
    }

    private func search(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let project = try project(projectID)
        guard project.mode != "off" else { throw OptimizerStoreError.denied("optimization is off for this project") }
        let query = try string(p, "query", max: 2_000, required: true)
        let tools = Set(try stringArray(p["available_tools"], field: "available_tools", maxItems: 256, maxLength: 128))
        let dependencies = try stringMap(p["dependencies"], field: "dependencies", maxItems: 256, maxKey: 1_024, maxValue: 256)
        let limit = try optionalInteger(p["max_candidates"], field: "max_candidates", min: 1, max: 20) ?? 8
        let active = (shortlist[projectID] ?? []).filter {
            guard $0.isApproved && !$0.archived && !$0.isExpired(now: Self.now()) else { return false }
            if $0.kind == "memory" { return project.featureFlags["memory_retrieval"] != false }
            if $0.kind == "plan" { return project.featureFlags["plan_reuse"] != false }
            return false
        }
        let scored = active.map { (entry: $0, score: $0.score(query)) }.filter { $0.score > 0 }
        let sorted = scored.sorted { left, right in left.score == right.score ? left.entry.updatedAt > right.entry.updatedAt : left.score > right.score }
        var remainingBytes = 64_000
        let candidates = try sorted.prefix(limit).compactMap { item -> [String: Any]? in
                var out = entryObject(item.entry, includeContent: true)
                out.removeValue(forKey: "revisions")
                out["relevance_score"] = item.score
                out["validation_required"] = true
                let toolsAvailable = Set(item.entry.requiredTools).isSubset(of: tools)
                let dependenciesMatch = item.entry.dependencies.allSatisfy { dependencies[$0.key] == $0.value }
                out["required_tools_available"] = toolsAvailable
                out["dependencies_match"] = dependenciesMatch
                let count = try JSONValue.data(out).count
                guard count <= remainingBytes else { return nil }
                remainingBytes -= count
                return out
            }
        return ["project_id": projectID, "candidates": candidates, "candidate_count": candidates.count]
    }

    private func taskStart(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        let id = try optionalID(p["id"], field: "id") ?? UUID().uuidString.lowercased()
        let parentID = try optionalIdentifier(p["parent_id"], field: "parent_id")
        let client = try identifier(p, "client", max: 128)
        if let task = ledger.tasks.first(where: { $0.id == id }) {
            guard task.projectID == projectID else { throw OptimizerStoreError.denied("task belongs to a different project") }
            return taskObject(task)
        }
        if let parentID, !ledger.tasks.contains(where: { $0.id == parentID && $0.projectID == projectID }) {
            throw OptimizerStoreError.notFound("parent task")
        }
        guard ledger.tasks.count < Self.maxEvents else { throw OptimizerStoreError.limit("task quota reached") }
        let task = Task(id: id, projectID: projectID, parentID: parentID, client: client, startedAt: Self.now(), finishedAt: nil, outcome: nil)
        ledger.tasks.append(task)
        return taskObject(task)
    }

    private func taskFinish(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let id = try identifier(p, "id", max: 128)
        let outcome = try oneOf(try string(p, "outcome", max: 32, required: true), ["success", "failed", "cancelled", "unknown"], field: "outcome")
        guard let index = ledger.tasks.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("task") }
        let verification = try verificationList(p["verification"])
        try rejectSecrets(verification)
        guard let key else { throw OptimizerStoreError.locked }
        let verificationDigest = verification.isEmpty ? nil : fingerprintLocked(projectID: projectID, data: try JSONValue.data(["verification": verification]), key: key)
        if ledger.tasks[index].finishedAt != nil {
            guard ledger.tasks[index].outcome == outcome && ledger.tasks[index].verificationDigest == verificationDigest else {
                throw OptimizerStoreError.conflict("a finished task cannot be rewritten")
            }
            return taskObject(ledger.tasks[index])
        }
        ledger.tasks[index].finishedAt = Self.now()
        ledger.tasks[index].outcome = outcome
        ledger.tasks[index].verificationDigest = verificationDigest
        return taskObject(ledger.tasks[index])
    }

    /// Captured outcomes remain reference candidates until an administrative
    /// review approves them. A client-reported success is not independent proof.
    private func candidateCapture(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let record = try project(projectID)
        guard record.storageEnabled, record.mode != "off", record.featureFlags["candidate_capture"] == true else {
            throw OptimizerStoreError.denied("candidate capture is not enabled")
        }
        let taskID = try identifier(p, "task_id", max: 128)
        guard let task = ledger.tasks.first(where: { $0.id == taskID && $0.projectID == projectID }),
              task.finishedAt != nil, task.outcome == "success", task.verificationDigest != nil else {
            throw OptimizerStoreError.denied("capture requires a successful task with verification evidence")
        }
        guard p["id"] == nil, p["pinned"] == nil, p["review_state"] == nil else {
            throw OptimizerStoreError.invalid("captured candidates cannot choose identity or approval")
        }
        let verification = try verificationList(p["verification"])
        guard !verification.isEmpty, try optionalString(p["source"], field: "source", max: 2_000) != nil else {
            throw OptimizerStoreError.invalid("candidates require source and verification steps")
        }
        if let old = content.entries.first(where: { $0.projectID == projectID && $0.capturedFromTaskID == taskID && $0.kind == p["kind"] as? String }) {
            guard old.title == p["title"] as? String, old.content == p["content"] as? String,
                  old.source == p["source"] as? String, old.verification == verification,
                  old.tags == (try stringArray(p["tags"], field: "tags", maxItems: 32, maxLength: 64)),
                  old.constraints == (try stringArray(p["constraints"], field: "constraints", maxItems: 64, maxLength: 1_000)),
                  old.requiredTools == (try stringArray(p["required_tools"], field: "required_tools", maxItems: 64, maxLength: 128)),
                  old.dependencies == (try stringMap(p["dependencies"], field: "dependencies", maxItems: 128, maxKey: 1_024, maxValue: 256)),
                  old.expiresAt == (try optionalTimestamp(p["expires_at"], field: "expires_at")) else {
                throw OptimizerStoreError.conflict("a task already has a different candidate of this kind")
            }
            var result = entryObject(old, includeContent: false)
            result["deduplicated"] = true
            return result
        }
        let result = try entrySave(p, scope: scope)
        guard let id = result["id"] as? String, let index = content.entries.firstIndex(where: { $0.id == id }) else {
            throw OptimizerStoreError.invalid("candidate creation failed")
        }
        content.entries[index].reviewState = "pending"
        content.entries[index].capturedFromTaskID = taskID
        rebuildShortlist()
        return entryObject(content.entries[index], includeContent: false)
    }

    private func candidateList(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        let state = try optionalString(p["review_state"], field: "review_state", max: 16) ?? "pending"
        _ = try oneOf(state, ["pending", "approved", "rejected"], field: "review_state")
        return ["project_id": projectID, "candidates": content.entries.filter {
            $0.projectID == projectID && $0.reviewState == state
        }.sorted { $0.updatedAt > $1.updatedAt }.map { entryObject($0, includeContent: false) }]
    }

    private func candidateReview(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        guard scope == nil else { throw OptimizerStoreError.denied("candidate approval requires an administrative session") }
        let projectID = try projectID(p, scope: scope)
        let record = try project(projectID)
        guard record.storageEnabled else { throw OptimizerStoreError.denied("storage is disabled") }
        let id = try identifier(p, "id", max: 128)
        let decision = try oneOf(try string(p, "decision", max: 16, required: true), ["approve", "reject"], field: "decision")
        let expectedVersion = try integer(p, "expected_version", min: 1, max: 1_000_000)
        guard let index = content.entries.firstIndex(where: { $0.id == id && $0.projectID == projectID }),
              content.entries[index].reviewState == "pending" else { throw OptimizerStoreError.notFound("pending candidate") }
        guard content.entries[index].revisions.last?.version == expectedVersion else {
            throw OptimizerStoreError.conflict("candidate changed; review the current version")
        }
        if decision == "approve", content.entries[index].isExpired(now: Self.now()) {
            throw OptimizerStoreError.invalid("expired candidate cannot be approved")
        }
        content.entries[index].reviewState = decision == "approve" ? "approved" : "rejected"
        content.entries[index].archived = decision == "reject"
        content.entries[index].updatedAt = Self.now()
        rebuildShortlist()
        return entryObject(content.entries[index], includeContent: false)
    }

    /// Reserves the project budget before an optimizer request is dispatched.
    /// `task_settle` releases only reservations that were never dispatched.
    private func taskReserve(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let project = try project(projectID)
        guard project.mode != "off" else { throw OptimizerStoreError.denied("optimization is off for this project") }
        let taskID = try identifier(p, "task_id", max: 128)
        guard ledger.tasks.contains(where: { $0.id == taskID && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("task") }
        let reservationID = try optionalID(p["reservation_id"], field: "reservation_id") ?? UUID().uuidString.lowercased()
        let requestCount = try integer(p, "request_count", min: 0, max: 10_000)
        var estimate = try integer(p, "estimated_input_tokens", min: 0, max: 100_000_000)
        guard requestCount > 0 || estimate > 0 else { throw OptimizerStoreError.invalid("reservation must reserve requests or input tokens") }
        if let old = ledger.reservations.first(where: { $0.id == reservationID }) {
            guard old.projectID == projectID && old.taskID == taskID else { throw OptimizerStoreError.denied("reservation belongs to a different task") }
            return [
                "reservation_id": old.id, "project_id": old.projectID, "task_id": old.taskID,
                "request_count": old.requestCount, "estimated_input_tokens": old.estimatedInputTokens,
                "budget": budgetObject(projectID, project: project),
            ]
        }
        guard ledger.reservations.count < Self.maxEvents else { throw OptimizerStoreError.limit("reservation quota reached") }
        let used = budgetUsed(projectID)
        guard used.requests + requestCount <= project.maxRequests else { throw OptimizerStoreError.limit("project request budget exceeded") }
        // The controller reserves a per-call ceiling and passes this exact granted
        // amount to the evaluator. Clamp while holding the store transaction lock,
        // so concurrent clients cannot both consume the remaining project capacity.
        if p["clamp_to_remaining"] as? Bool == true {
            estimate = min(estimate, max(0, project.maxInputTokens - used.inputTokens))
            guard estimate > 0 else { throw OptimizerStoreError.limit("project input-token budget exhausted") }
        }
        guard used.inputTokens + estimate <= project.maxInputTokens else { throw OptimizerStoreError.limit("project input-token budget exceeded") }
        let reservation = Reservation(id: reservationID, projectID: projectID, taskID: taskID, requestCount: requestCount, estimatedInputTokens: estimate, createdAt: Self.now())
        ledger.reservations.append(reservation)
        return [
            "reservation_id": reservation.id, "project_id": reservation.projectID, "task_id": reservation.taskID,
            "request_count": reservation.requestCount, "estimated_input_tokens": reservation.estimatedInputTokens,
            "budget": budgetObject(projectID, project: project),
        ]
    }

    private func taskSettle(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        let project = try project(projectID)
        let taskID = try identifier(p, "task_id", max: 128)
        let reservationID = try identifier(p, "reservation_id", max: 128)
        let dispatched = try bool(p, "dispatched")
        guard let index = ledger.reservations.firstIndex(where: { $0.id == reservationID && $0.projectID == projectID && $0.taskID == taskID }) else { throw OptimizerStoreError.notFound("reservation") }
        if dispatched, ledger.budgetUsage.count >= Self.maxEvents { throw OptimizerStoreError.limit("budget ledger quota reached") }
        let reservation = ledger.reservations.remove(at: index)
        if dispatched {
            let actual = try optionalInteger(p["actual_input_tokens"], field: "actual_input_tokens", min: 0, max: 1_000_000_000) ?? reservation.estimatedInputTokens
            // Submitted requests remain charged even for a failed response; actual
            // input reconciles the reservation and may cause bounded overshoot.
            ledger.budgetUsage.append(BudgetUsage(projectID: projectID, taskID: taskID, requestCount: reservation.requestCount, inputTokens: actual, settledAt: Self.now()))
        }
        return ["reservation_id": reservationID, "dispatched": dispatched, "released": !dispatched, "budget": budgetObject(projectID, project: project)]
    }

    private func eventRecord(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        let taskID = try identifier(p, "task_id", max: 128)
        guard ledger.tasks.contains(where: { $0.id == taskID && $0.projectID == projectID }) else { throw OptimizerStoreError.notFound("task") }
        let eventID = try identifier(p, "event_id", max: 128)
        let requestID = try optionalIdentifier(p["request_id"], field: "request_id")
        let source = try identifier(p, "source", max: 128)
        let kind = try identifier(p, "kind", max: 128)
        let model = try identifier(p, "model", max: 256)
        let input = try optionalInteger(p["input_tokens"], field: "input_tokens", min: 0, max: 1_000_000_000)
        let output = try optionalInteger(p["output_tokens"], field: "output_tokens", min: 0, max: 1_000_000_000)
        let cache = try optionalInteger(p["cache_read_tokens"], field: "cache_read_tokens", min: 0, max: 1_000_000_000)
        let reported = try optionalCost(p["reported_cost_usd"], field: "reported_cost_usd")
        let estimated = try optionalCost(p["estimated_cost_usd"], field: "estimated_cost_usd")
        let latency = try integer(p, "latency_ms", min: 0, max: 86_400_000)
        let status = try oneOf(try string(p, "status", max: 32, required: true), ["ok", "error", "failed", "cancelled", "timeout", "unknown", "success", "suggested", "selected", "observed", "abstained", "reused", "engine_unavailable"], field: "status")
        if let exact = ledger.events.first(where: { $0.projectID == projectID && $0.eventID == eventID }) {
            return ["event": eventObject(exact), "deduplicated": true, "deduplication": "event_id"]
        }
        let overlap = requestID.flatMap { request in
            ledger.events.first { event in
                event.projectID == projectID && event.taskID == taskID && event.requestID == request && event.kind == kind && event.model == model
            }
        }
        if let overlap {
            return ["event": eventObject(overlap), "deduplicated": true, "deduplication": "request_identity"]
        }
        if ledger.events.count >= Self.maxEvents { ledger.events.sort { $0.createdAt < $1.createdAt }; ledger.events.removeFirst() }
        let event = OptimizerUsageEvent(projectID: projectID, taskID: taskID, eventID: eventID, requestID: requestID, source: source, kind: kind, model: model, inputTokens: input, outputTokens: output, cacheReadTokens: cache, reportedCostUSD: reported, estimatedCostUSD: estimated, latencyMS: latency, status: status, createdAt: Self.now())
        ledger.events.append(event)
        return ["event": eventObject(event), "deduplicated": false]
    }

    private func eventList(_ p: [String: Any], scope: String?) throws -> [String: Any] {
        let projectID = try projectID(p, scope: scope)
        _ = try project(projectID)
        let taskID = try optionalIdentifier(p["task_id"], field: "task_id")
        var events = ledger.events.filter { $0.projectID == projectID }
        if let taskID { events = events.filter { $0.taskID == taskID } }
        events.sort { $0.createdAt > $1.createdAt }
        return ["project_id": projectID, "events": events.map(eventObject), "aggregate": aggregate(events)]
    }

    private func taskSummary(_ task: Task, events: [OptimizerUsageEvent]) -> [String: Any] {
        var out = taskObject(task)
        out["aggregate"] = aggregate(events.filter { $0.taskID == task.id && $0.projectID == task.projectID })
        return out
    }

    private func aggregate(_ events: [OptimizerUsageEvent]) -> [String: Any] {
        var out = numericTotals(events)
        let optimizer = events.filter(isOptimizerEvent)
        let client = events.filter { !isOptimizerEvent($0) }
        out["optimizer"] = numericTotals(optimizer)
        out["client"] = numericTotals(client)
        out["by_source"] = Dictionary(grouping: events, by: \.source).mapValues { numericTotals($0) }
        out["exact_cache_hits"] = events.filter { ["decision_cache_hit", "exact_cache"].contains($0.kind) }.count
        let decisions = events.filter { ["jev_decision", "decision", "jev"].contains($0.kind) }
        out["decisions_by_status"] = Dictionary(grouping: decisions, by: \.status).mapValues { $0.count }
        return out
    }

    private func numericTotals(_ events: [OptimizerUsageEvent]) -> [String: Any] {
        func totals(_ values: [Int?], _ name: String) -> [String: Any] {
            let known = values.compactMap { $0 }
            return ["\(name)_known": known.reduce(0, +), "\(name)_unknown_events": values.count - known.count]
        }
        var out: [String: Any] = ["events": events.count, "latency_ms": events.reduce(0) { $0 + $1.latencyMS }]
        let inputValues = events.map { $0.inputTokens }
        let outputValues = events.map { $0.outputTokens }
        let cacheValues = events.map { $0.cacheReadTokens }
        out.merge(totals(inputValues, "input_tokens")) { _, new in new }
        out.merge(totals(outputValues, "output_tokens")) { _, new in new }
        out.merge(totals(cacheValues, "cache_read_tokens")) { _, new in new }
        let reported = events.map { $0.reportedCostUSD }; let estimated = events.map { $0.estimatedCostUSD }
        out["reported_cost_usd_known"] = reported.compactMap { $0 }.reduce(0, +)
        out["reported_cost_usd_unknown_events"] = reported.filter { $0 == nil }.count
        out["estimated_cost_usd_known"] = estimated.compactMap { $0 }.reduce(0, +)
        out["estimated_cost_usd_unknown_events"] = estimated.filter { $0 == nil }.count
        return out
    }

    private func isOptimizerEvent(_ event: OptimizerUsageEvent) -> Bool {
        ["jev_decision", "decision_cache_hit", "jev", "optimizer", "decision", "exact_cache"].contains(event.kind)
    }

    private func budgetUsed(_ projectID: String) -> (requests: Int, inputTokens: Int) {
        let settled = ledger.budgetUsage.filter { $0.projectID == projectID }
        let pending = ledger.reservations.filter { $0.projectID == projectID }
        return (
            settled.reduce(0) { $0 + $1.requestCount } + pending.reduce(0) { $0 + $1.requestCount },
            settled.reduce(0) { $0 + $1.inputTokens } + pending.reduce(0) { $0 + $1.estimatedInputTokens }
        )
    }

    private func budgetObject(_ projectID: String, project: Project) -> [String: Any] {
        let used = budgetUsed(projectID)
        return [
            "requests_used": used.requests,
            "requests_remaining": max(0, project.maxRequests - used.requests),
            "input_tokens_used": used.inputTokens,
            "input_tokens_remaining": max(0, project.maxInputTokens - used.inputTokens),
        ]
    }

    private func projectID(_ payload: [String: Any], scope: String?) throws -> String {
        let id = try identifier(payload, "project_id", max: 128)
        try requireScope(id, scope)
        return id
    }

    private func requireScope(_ id: String, _ scope: String?) throws {
        if let scope, scope != id { throw OptimizerStoreError.denied("project scope does not match") }
    }

    private func project(_ id: String) throws -> Project {
        guard let value = content.projects.first(where: { $0.id == id }) else { throw OptimizerStoreError.notFound("project") }
        return value
    }

    private func scopedProjects(_ scope: String?) -> [Project] {
        guard let scope else { return content.projects }
        return content.projects.filter { $0.id == scope }
    }

    private func reload(key: SymmetricKey) throws {
        try recoverTransaction(key: key)
        content = try load(ContentState.self, from: contentURL, key: key) ?? ContentState()
        ledger = try load(LedgerState.self, from: ledgerURL, key: key) ?? LedgerState()
        try validateLoaded(content: content, ledger: ledger)
        rebuildShortlist()
    }

    private func persist(key: SymmetricKey, previousContent: ContentState, previousLedger: LedgerState) throws {
        try validateLoaded(content: content, ledger: ledger)
        try write(Transaction(previousContent: previousContent, previousLedger: previousLedger, committed: false), to: transactionURL, key: key)
        var committed = false
        do {
            try write(content, to: contentURL, key: key)
            try write(ledger, to: ledgerURL, key: key)
            try write(Transaction(previousContent: previousContent, previousLedger: previousLedger, committed: true), to: transactionURL, key: key)
            committed = true
        }
        catch {
            // The encrypted journal lets the next locked/reloaded client recover
            // the old matched snapshots even if this process is interrupted here.
            if !committed {
                var restored = false
                do {
                    try write(previousContent, to: contentURL, key: key)
                    try write(previousLedger, to: ledgerURL, key: key)
                    restored = true
                } catch {}
                if restored { try? removeAndSync(transactionURL) }
            }
            throw error
        }
        // The committed journal is authoritative if cleanup is interrupted; a
        // subsequent unlock preserves the new pair and removes it then.
        try? removeAndSync(transactionURL)
    }

    private func recoverTransaction(key: SymmetricKey) throws {
        guard let transaction = try load(Transaction.self, from: transactionURL, key: key) else { return }
        if !transaction.committed {
            try write(transaction.previousContent, to: contentURL, key: key)
            try write(transaction.previousLedger, to: ledgerURL, key: key)
        }
        try removeAndSync(transactionURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL, key: SymmetricKey) throws -> T? {
        guard fileExists(url) else { return nil }
        let encrypted = try secureRead(url)
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(T.self, from: plain)
        } catch {
            throw OptimizerStoreError.tampered
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL, key: SymmetricKey) throws {
        let plain = try JSONEncoder().encode(value)
        let maximum = value is Transaction ? Self.maxTransactionBytes : Self.maxStateBytes
        guard plain.count <= maximum else { throw OptimizerStoreError.limit("optimizer storage size limit reached") }
        let box = try AES.GCM.seal(plain, using: key)
        guard let combined = box.combined else { throw OptimizerStoreError.io("could not encrypt optimizer data") }
        try atomicWrite(combined, to: url)
    }

    private func validateLoaded(content: ContentState, ledger: LedgerState) throws {
        guard content.schemaVersion == Self.schema, ledger.schemaVersion == Self.schema else { throw OptimizerStoreError.tampered }
        guard content.projects.count <= Self.maxProjects, content.entries.count <= Self.maxEntries,
              ledger.events.count <= Self.maxEvents, ledger.tasks.count <= Self.maxEvents,
              ledger.reservations.count <= Self.maxEvents, ledger.budgetUsage.count <= Self.maxEvents else { throw OptimizerStoreError.tampered }
        let ids = Set(content.projects.map(\.id))
        guard ids.count == content.projects.count,
              content.entries.allSatisfy({ ids.contains($0.projectID) }),
              ledger.tasks.allSatisfy({ ids.contains($0.projectID) }),
              ledger.events.allSatisfy({ ids.contains($0.projectID) }),
              ledger.reservations.allSatisfy({ ids.contains($0.projectID) }),
              ledger.budgetUsage.allSatisfy({ ids.contains($0.projectID) }) else { throw OptimizerStoreError.tampered }
        guard content.entries.allSatisfy({ entry in
            if let state = entry.reviewState {
                return ["pending", "approved", "rejected"].contains(state) && entry.capturedFromTaskID != nil
            }
            return entry.capturedFromTaskID == nil
        }) else { throw OptimizerStoreError.tampered }
        guard logicalContentBytes(content.entries) <= Self.maxLogicalContentBytes else { throw OptimizerStoreError.tampered }
        guard try encodedSize(content) <= Self.maxStateBytes, try encodedSize(ledger) <= Self.maxStateBytes else { throw OptimizerStoreError.tampered }
    }

    @discardableResult
    private func prune(now: Int64) -> Bool {
        let originalEntries = content.entries.count
        let originalEvents = ledger.events.count
        let originalTasks = ledger.tasks.count
        let originalReservations = ledger.reservations.count
        let originalUsage = ledger.budgetUsage.count
        let retention = Dictionary(uniqueKeysWithValues: content.projects.map { ($0.id, Int64($0.retentionDays) * 86_400_000) })
        content.entries.removeAll { entry in
            guard let age = retention[entry.projectID] else { return true }
            return now - entry.updatedAt > age
        }
        let existing = Set(content.projects.map(\.id))
        ledger.events.removeAll { !existing.contains($0.projectID) }
        ledger.tasks.removeAll { !existing.contains($0.projectID) }
        ledger.reservations.removeAll { !existing.contains($0.projectID) }
        ledger.budgetUsage.removeAll { !existing.contains($0.projectID) }
        for (projectID, age) in retention {
            ledger.events.removeAll { $0.projectID == projectID && now - $0.createdAt > age }
            ledger.tasks.removeAll { $0.projectID == projectID && now - $0.startedAt > age }
            ledger.budgetUsage.removeAll { $0.projectID == projectID && now - $0.settledAt > age }
        }
        return originalEntries != content.entries.count || originalEvents != ledger.events.count || originalTasks != ledger.tasks.count || originalReservations != ledger.reservations.count || originalUsage != ledger.budgetUsage.count
    }

    private func rebuildShortlist() { shortlist = Dictionary(grouping: content.entries, by: \.projectID) }
    private func logicalContentBytes(_ entries: [Entry]? = nil) -> Int { (entries ?? content.entries).reduce(0) { $0 + $1.logicalSize } }
    private func encodedSize<T: Encodable>(_ value: T) throws -> Int { try JSONEncoder().encode(value).count }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try guardDirectory(directory) }
        else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try guardDirectory(directory)
    }

    private func withProcessLock<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OptimizerStoreError.io("could not open optimizer lock") }
        defer { close(fd) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        guard flock(fd, LOCK_EX) == 0 else { throw OptimizerStoreError.io("could not lock optimizer storage") }
        defer { _ = flock(fd, LOCK_UN) }
        try guardRegularOrMissing(contentURL); try guardRegularOrMissing(ledgerURL); try guardRegularOrMissing(transactionURL); try guardRegularOrMissing(lockURL)
        return try body()
    }

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func guardDirectory(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw OptimizerStoreError.io("optimizer directory is unsafe") }
    }

    private func guardRegularOrMissing(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) != 0 { if errno == ENOENT { return }; throw OptimizerStoreError.io("could not inspect optimizer storage") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw OptimizerStoreError.io("optimizer storage path is unsafe") }
    }

    private func secureRead(_ url: URL) throws -> Data {
        try guardRegularOrMissing(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw OptimizerStoreError.io("could not open optimizer storage") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try handle.readToEnd(), data.count <= Self.maxTransactionBytes * 2 else { throw OptimizerStoreError.tampered }
        return data
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try guardRegularOrMissing(url)
        let temp = directory.appendingPathComponent(".optimizer-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OptimizerStoreError.io("could not create optimizer temporary file") }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard fsync(fd) == 0 else { throw OptimizerStoreError.io("could not write optimizer storage") }
        guard rename(temp.path, url.path) == 0 else { throw OptimizerStoreError.io("could not replace optimizer storage") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try syncDirectory()
    }

    private func removeAndSync(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw OptimizerStoreError.io("could not sync optimizer directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw OptimizerStoreError.io("could not sync optimizer directory") }
    }
}

enum OptimizerStoreError: Error, LocalizedError {
    case locked, invalid(String), conflict(String), denied(String), notFound(String), limit(String), tampered, io(String)
    var errorDescription: String? {
        switch self {
        case .locked: return "optimizer storage is locked"
        case .invalid(let m), .conflict(let m), .denied(let m), .limit(let m), .io(let m): return m
        case .notFound(let m): return "optimizer \(m) not found"
        case .tampered: return "optimizer storage could not be authenticated"
        }
    }
}

private struct ContentState: Codable { var schemaVersion = 1; var projects: [Project] = []; var entries: [Entry] = [] }
private struct LedgerState: Codable { var schemaVersion = 1; var tasks: [Task] = []; var events: [OptimizerUsageEvent] = []; var reservations: [Reservation] = []; var budgetUsage: [BudgetUsage] = [] }
private struct Transaction: Codable { let previousContent: ContentState; let previousLedger: LedgerState; let committed: Bool }
private struct Project: Codable { let id, name, root, mode: String; let storageEnabled, providerEnabled: Bool; let retentionDays, maxRequests, maxInputTokens: Int; let featureFlags: [String: Bool]; let createdAt, updatedAt: Int64 }
private struct EntryRevision: Codable { let version: Int; let title, content: String; let savedAt: Int64 }
private struct Entry: Codable {
    let id, projectID, kind, title, content: String; let tags: [String]; let source: String?; let constraints, requiredTools: [String]; let dependencies: [String: String]; let verification: [String]; let expiresAt: Int64?; let pinned: Bool; var archived: Bool; let createdAt: Int64; var updatedAt: Int64; let revisions: [EntryRevision]
    var reviewState: String? = nil
    var capturedFromTaskID: String? = nil
    var isApproved: Bool { reviewState == nil || reviewState == "approved" }
    func isExpired(now: Int64) -> Bool { expiresAt.map { $0 <= now } ?? false }
    func matches(_ query: String) -> Bool { score(query) > 0 }
    func score(_ query: String) -> Int {
        let queryTokens = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 })
        guard !queryTokens.isEmpty else { return 0 }
        let haystack = "\(title) \(tags.joined(separator: " ")) \(constraints.joined(separator: " ")) \(content)".lowercased()
        return queryTokens.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }
    var logicalSize: Int {
        title.utf8.count + content.utf8.count + tags.reduce(0) { $0 + $1.utf8.count }
            + (source?.utf8.count ?? 0) + constraints.reduce(0) { $0 + $1.utf8.count }
            + requiredTools.reduce(0) { $0 + $1.utf8.count }
            + dependencies.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + verification.reduce(0) { $0 + $1.utf8.count }
            + revisions.reduce(0) { $0 + $1.title.utf8.count + $1.content.utf8.count }
    }
}
private struct Task: Codable { let id, projectID: String; let parentID: String?; let client: String; let startedAt: Int64; var finishedAt: Int64?; var outcome: String?; var verificationDigest: String? = nil }
private struct Reservation: Codable { let id, projectID, taskID: String; let requestCount, estimatedInputTokens: Int; let createdAt: Int64 }
private struct BudgetUsage: Codable { let projectID, taskID: String; let requestCount, inputTokens: Int; let settledAt: Int64 }
private struct OptimizerUsageEvent: Codable { let projectID, taskID, eventID: String; let requestID: String?; let source, kind, model: String; let inputTokens, outputTokens, cacheReadTokens: Int?; let reportedCostUSD, estimatedCostUSD: Double?; let latencyMS: Int; let status: String; let createdAt: Int64 }

private func projectObject(_ p: Project) -> [String: Any] { ["id": p.id, "name": p.name, "root": p.root, "mode": p.mode, "storage_enabled": p.storageEnabled, "provider_enabled": p.providerEnabled, "retention_days": p.retentionDays, "max_requests": p.maxRequests, "max_input_tokens": p.maxInputTokens, "feature_flags": p.featureFlags, "created_at": p.createdAt, "updated_at": p.updatedAt] }
private func entryObject(_ e: Entry, includeContent: Bool) -> [String: Any] { var out: [String: Any] = ["id": e.id, "project_id": e.projectID, "kind": e.kind, "title": e.title, "tags": e.tags, "constraints": e.constraints, "required_tools": e.requiredTools, "dependencies": e.dependencies, "expires_at": e.expiresAt.map(iso) ?? NSNull(), "pinned": e.pinned, "archived": e.archived, "created_at": iso(e.createdAt), "updated_at": iso(e.updatedAt), "version": e.revisions.last?.version ?? 0]; out["review_state"] = e.reviewState ?? "curated"; out["captured_from_task_id"] = e.capturedFromTaskID ?? NSNull(); out["source"] = e.source ?? NSNull(); out["verification"] = e.verification; if includeContent { out["content"] = e.content; out["revisions"] = e.revisions.map { ["version": $0.version, "title": $0.title, "content": $0.content, "saved_at": iso($0.savedAt)] } }; return out }
private func taskObject(_ t: Task) -> [String: Any] { ["id": t.id, "project_id": t.projectID, "parent_id": t.parentID ?? NSNull(), "client": t.client, "started_at": iso(t.startedAt), "finished_at": t.finishedAt.map(iso) ?? NSNull(), "outcome": t.outcome ?? NSNull(), "verification_recorded": t.verificationDigest != nil] }
private func eventObject(_ e: OptimizerUsageEvent) -> [String: Any] { ["project_id": e.projectID, "task_id": e.taskID, "event_id": e.eventID, "request_id": e.requestID ?? NSNull(), "source": e.source, "kind": e.kind, "model": e.model, "input_tokens": e.inputTokens ?? NSNull(), "output_tokens": e.outputTokens ?? NSNull(), "cache_read_tokens": e.cacheReadTokens ?? NSNull(), "reported_cost_usd": e.reportedCostUSD ?? NSNull(), "estimated_cost_usd": e.estimatedCostUSD ?? NSNull(), "latency_ms": e.latencyMS, "status": e.status, "created_at": iso(e.createdAt)] }

private func string(_ p: [String: Any], _ field: String, max: Int, required: Bool) throws -> String { guard let value = p[field] as? String else { if required { throw OptimizerStoreError.invalid("\(field) is required") }; return "" }; let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, trimmed.count <= max else { throw OptimizerStoreError.invalid("invalid \(field)") }; return trimmed }
private func optionalString(_ value: Any?, field: String, max: Int) throws -> String? { guard let value else { return nil }; guard let text = value as? String else { throw OptimizerStoreError.invalid("invalid \(field)") }; let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, trimmed.count <= max else { throw OptimizerStoreError.invalid("invalid \(field)") }; return trimmed }
private func validateIdentifier(_ value: String, field: String) throws {
    guard value.count <= 256, value.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil else { throw OptimizerStoreError.invalid("invalid \(field)") }
}
private func identifier(_ p: [String: Any], _ field: String, max: Int) throws -> String {
    let value = try string(p, field, max: max, required: true)
    try validateIdentifier(value, field: field)
    return value
}
private func optionalIdentifier(_ value: Any?, field: String) throws -> String? {
    guard let value = try optionalString(value, field: field, max: 256) else { return nil }
    try validateIdentifier(value, field: field)
    return value
}
private func optionalID(_ value: Any?, field: String) throws -> String? { try optionalIdentifier(value, field: field) }
private func bool(_ p: [String: Any], _ field: String) throws -> Bool {
    guard let value = p[field] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw OptimizerStoreError.invalid("\(field) must be boolean") }
    return value.boolValue
}
private func boolOr(_ value: Any?, default fallback: Bool) -> Bool {
    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
    return value.boolValue
}
private func integer(_ p: [String: Any], _ field: String, min: Int, max: Int) throws -> Int { guard let value = p[field] else { throw OptimizerStoreError.invalid("\(field) is required") }; return try strictInteger(value, field: field, min: min, max: max) }
private func optionalInteger(_ value: Any?, field: String, min: Int, max: Int) throws -> Int? { guard let value else { return nil }; return try strictInteger(value, field: field, min: min, max: max) }
private func strictInteger(_ value: Any, field: String, min: Int, max: Int) throws -> Int {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw OptimizerStoreError.invalid("\(field) must be an integer") }
    let type = String(cString: n.objCType)
    guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type), n.int64Value >= Int64(min), n.int64Value <= Int64(max) else { throw OptimizerStoreError.invalid("invalid \(field)") }
    return Int(n.int64Value)
}
private func optionalCost(_ value: Any?, field: String) throws -> Double? {
    guard let value else { return nil }
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw OptimizerStoreError.invalid("invalid \(field)") }
    let d = n.doubleValue
    guard d.isFinite, d >= 0, d <= 1_000_000_000 else { throw OptimizerStoreError.invalid("invalid \(field)") }
    return d
}
private func optionalTimestamp(_ value: Any?, field: String) throws -> Int64? {
    guard let value else { return nil }
    guard let text = value as? String, let date = UTC.parse(text) else { throw OptimizerStoreError.invalid("invalid \(field)") }
    return Int64(date.timeIntervalSince1970 * 1_000)
}
private func iso(_ milliseconds: Int64) -> String { UTC.iso(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)) }
private func oneOf(_ value: String, _ allowed: Set<String>, field: String) throws -> String { guard allowed.contains(value) else { throw OptimizerStoreError.invalid("invalid \(field)") }; return value }
private func mode(_ value: String) throws -> String { try oneOf(value, ["off", "observe", "suggest", "auto"], field: "mode") }
private func stringArray(_ value: Any?, field: String, maxItems: Int, maxLength: Int) throws -> [String] { guard let value else { return [] }; guard let array = value as? [Any], array.count <= maxItems else { throw OptimizerStoreError.invalid("invalid \(field)") }; return try array.map { item in guard let text = item as? String else { throw OptimizerStoreError.invalid("invalid \(field)") }; let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, trimmed.count <= maxLength else { throw OptimizerStoreError.invalid("invalid \(field)") }; return trimmed } }
private func verificationList(_ value: Any?) throws -> [String] {
    guard let value else { return [] }
    if let text = value as? String { return [try optionalString(text, field: "verification", max: 8_000)!] }
    return try stringArray(value, field: "verification", maxItems: 32, maxLength: 1_000)
}
private func stringMap(_ value: Any?, field: String, maxItems: Int, maxKey: Int, maxValue: Int) throws -> [String: String] { guard let value else { return [:] }; guard let map = value as? [String: Any], map.count <= maxItems else { throw OptimizerStoreError.invalid("invalid \(field)") }; var out: [String: String] = [:]; for (key, raw) in map { guard !key.isEmpty, key.count <= maxKey, let value = raw as? String, !value.isEmpty, value.count <= maxValue else { throw OptimizerStoreError.invalid("invalid \(field)") }; out[key] = value }; return out }
private func boolMap(_ value: Any?) throws -> [String: Bool] {
    guard let value else { return [:] }
    guard let map = value as? [String: Any], map.count <= 64 else { throw OptimizerStoreError.invalid("invalid feature_flags") }
    var out: [String: Bool] = [:]
    for (key, raw) in map {
        guard !key.isEmpty, key.count <= 128,
              let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw OptimizerStoreError.invalid("invalid feature_flags") }
        out[key] = flag.boolValue
    }
    return out
}
private func rejectSecrets(_ values: [String]) throws { let patterns = [#"(?i)(api[_-]?key|authorization|secret|password)\s*[:=]"#, #"\bsk-[A-Za-z0-9_-]{16,}\b"#, #"\bAKIA[0-9A-Z]{16}\b"#, #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#, #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#]; for value in values { for pattern in patterns where value.range(of: pattern, options: .regularExpression) != nil { throw OptimizerStoreError.denied("entry appears to contain a secret") } } }
