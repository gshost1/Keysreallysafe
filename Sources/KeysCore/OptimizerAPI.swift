import CryptoKit
import Foundation

enum OptimizerAccessError: Error {
    case denied
    case invalid
    case unavailable
}

/// Optional content access has its own presence-approved capability. The dashboard's
/// origin token remains only CSRF protection and never unlocks stored content.
final class OptimizerController: @unchecked Sendable {
    struct Session {
        var project: String?
        var writable: Bool
        var expires: Date
        var generation: UInt64
        var grantID: String?
        var grantToken: String?
        var endpoint: String?
        var provider: OptimizerProvider?
        var taskID: String?
    }

    let store: OptimizerStore
    let directory: URL
    private let mutex = NSLock()
    private var sessions: [Data: Session] = [:]
    private var decisionCache: [Data: (expires: Date, result: [String: Any])] = [:]
    private var failures: [String: (count: Int, until: Date)] = [:]
    private var generation: UInt64 = 0
    private let loadKey: @Sendable () throws -> Data
    private let deleteKey: @Sendable () throws -> Void
    private let cacheNow: @Sendable () -> Date
    var runEngine: @Sendable ([String: Any], [String: String]) throws -> [String: Any]

    init(directory: URL, loadKey: (@Sendable () throws -> Data)? = nil,
         deleteKey: (@Sendable () throws -> Void)? = nil,
         cacheNow: @escaping @Sendable () -> Date = { Date() },
         runEngine: @escaping @Sendable ([String: Any], [String: String]) throws -> [String: Any] = OptimizerProcess.run) throws {
        self.directory = directory
        self.cacheNow = cacheNow
        self.store = try OptimizerStore(directory: directory)
        let account = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.loadKey = loadKey ?? {
            let keychain = KeychainStore(service: "keysreallysafe.optimizer")
            do {
                let encoded = try keychain.get(name: account)
                guard let key = Data(base64Encoded: encoded), key.count == 32 else { throw OptimizerAccessError.invalid }
                return key
            } catch AppError.notFound {
                // Never replace a missing encryption key for an existing archive.
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                guard !files.contains(where: { $0.hasSuffix(".gcm") }) else { throw OptimizerAccessError.unavailable }
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                do { try keychain.add(name: account, secret: key.base64EncodedString()) }
                catch AppError.alreadyExists {
                    guard let existing = Data(base64Encoded: try keychain.get(name: account)), existing.count == 32 else {
                        throw OptimizerAccessError.invalid
                    }
                    return existing
                }
                return key
            }
        }
        self.deleteKey = deleteKey ?? { try KeychainStore(service: "keysreallysafe.optimizer").delete(name: account) }
        self.runEngine = runEngine
    }

    static var capabilities: [String: Any] { [
        "claude_compaction": true, "memory_and_plans": true, "mcp": true,
        "model_routing": "suggestions", "tool_selection": "suggestions",
        "codex_context_editing": false, "automatic_reuse": false,
        "live_savings_verified": false, "local_context_packs": true,
        "candidate_capture": true, "candidate_review": "required",
        "task_preparation": "mcp", "read_result_reuse": "supported_host_adapter",
    ] }

    func status(now: Date = Date()) -> [String: Any] {
        mutex.lock()
        defer { mutex.unlock() }
        expire(now: now)
        return ["unlocked": store.isUnlocked, "capabilities": Self.capabilities,
                "live_validation": "pending", "content_storage": "optional_encrypted_local"]
    }

    /// Catalog metadata only: no secret read, presence prompt, grant, or network.
    func compatibleKeys(service: KeysService) throws -> [String: Any] {
        let keys = try service.catalog.listCatalog().compactMap { row -> [String: Any]? in
            guard let adapter = OptimizerProvider.compatible(provider: row.provider, host: row.gatewayHost) else { return nil }
            var metadata = adapter.metadata
            metadata.removeValue(forKey: "id")
            metadata["name"] = row.name
            metadata["provider"] = adapter.id
            return metadata
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let providers = OptimizerProvider.supported.filter {
            guard let record = Providers.provider(id: $0.id) else { return false }
            return $0.accepts(record)
        }.map(\.metadata)
        return ["keys": keys, "providers": providers]
    }

    func unlock(service: KeysService, payload: [String: Any], now: Date = Date()) throws -> [String: Any] {
        let minutes = try integer(payload["minutes"], fallback: 30, range: 1...120)
        if let value = payload["project_id"], !(value is String) { throw OptimizerAccessError.invalid }
        let project = payload["project_id"] as? String
        if let project, UUID(uuidString: project) == nil { throw OptimizerAccessError.invalid }
        if let value = payload["writable"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw OptimizerAccessError.invalid }
        }
        let writable = (payload["writable"] as? Bool) ?? (project == nil)
        if let value = payload["jev_key"], !(value is String) { throw OptimizerAccessError.invalid }
        let jevKey = payload["jev_key"] as? String
        mutex.lock()
        let startGeneration = generation
        mutex.unlock()
        var issued: (grant: Grant, token: String)?
        var adapter: OptimizerProvider?
        if let jevKey, !jevKey.isEmpty {
            guard let row = try service.catalog.catalogRow(name: jevKey),
                  let supported = OptimizerProvider.compatible(provider: row.provider, host: row.gatewayHost) else {
                throw AppError.usage("choose a compatible Vercel AI Gateway or TypeSafe key for Jev")
            }
            adapter = supported
            issued = try service.issueGrant(name: jevKey, request: GrantRequest(
                task: "Optimizer \(project ?? "ALL projects and settings") \(writable ? "read/write" : "read") + Jev", minutes: minutes,
                methods: ["POST"], paths: [supported.path], maxRequests: 100, jevProvider: supported.id
            ), caller: "optimizer")
        } else {
            try service.secrets.confirmPresence(reason: project == nil
                ? "Unlock Keys optimizer library and project settings for \(minutes) minutes"
                : "Allow \(writable ? "read and write" : "read") access to optimizer project \(project!) for \(minutes) minutes")
        }
        do {
            // Recheck the issued grant after presence: catalog metadata could have
            // changed while the native prompt was open.
            if let issued, let adapter {
                guard issued.grant.provider == adapter.id, issued.grant.host == adapter.host,
                      issued.grant.methods == ["POST"], issued.grant.paths == [adapter.path], issued.grant.jevProvider == adapter.id else {
                    throw OptimizerAccessError.denied
                }
            }
            let key = try loadKey()
            mutex.lock()
            defer { mutex.unlock() }
            guard generation == startGeneration else { throw OptimizerAccessError.denied }
            expire(now: now)
            guard sessions.count < 16 else { throw AppError.usage("too many optimizer sessions; lock and reconnect") }
            try store.unlock(key: key)
            if let project {
                _ = try store.perform(operation: "project_get", payload: ["project_id": project], projectScope: project, allowWrite: false)
            }
            let taskID: String?
            if let project {
                taskID = try store.perform(operation: "task_start", payload: ["project_id": project, "client": "optimizer-session"], projectScope: project)["id"] as? String
            } else { taskID = nil }
            let token = "kso_" + OriginToken.generate()
            let expires = now.addingTimeInterval(TimeInterval(minutes * 60))
            sessions[GrantToken.hash(token)] = Session(
                project: project, writable: writable, expires: expires, generation: generation,
                grantID: issued?.grant.id, grantToken: issued?.token,
                endpoint: adapter.map { "http://127.0.0.1:12767/\(jevKey!)\($0.path)" }, provider: adapter, taskID: taskID
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, expires.timeIntervalSinceNow)) { [weak self] in
                guard let self else { return }
                self.mutex.lock()
                self.expire(now: Date())
                self.mutex.unlock()
            }
            return ["token": token, "expires_at": UTC.iso(expires), "writable": writable,
                    "project_id": project as Any? ?? NSNull(), "jev_enabled": issued != nil,
                    "task_id": taskID as Any? ?? NSNull(),
                    "capabilities": Self.capabilities]
        } catch {
            if let issued { _ = try? service.revokeGrant(id: issued.grant.id, caller: "optimizer_unlock_failed") }
            mutex.lock()
            if sessions.isEmpty { store.lock() }
            mutex.unlock()
            throw error
        }
    }

    func lock(service: KeysService? = nil) {
        mutex.lock()
        let grants = sessions.values.compactMap(\.grantID)
        generation &+= 1
        sessions.removeAll()
        decisionCache.removeAll()
        failures.removeAll()
        store.lock()
        mutex.unlock()
        if let service { for id in grants { _ = try? service.revokeGrant(id: id, caller: "optimizer_lock") } }
    }

    func close(token: String, service: KeysService) throws {
        mutex.lock()
        let session = sessions.removeValue(forKey: GrantToken.hash(token))
        if sessions.isEmpty { store.lock() }
        decisionCache.removeAll()
        mutex.unlock()
        guard let session else { throw OptimizerAccessError.denied }
        if let id = session.grantID { _ = try? service.revokeGrant(id: id, caller: "optimizer_disconnect") }
    }

    func authorize(_ token: String, now: Date = Date()) throws -> Session {
        mutex.lock()
        defer { mutex.unlock() }
        expire(now: now)
        guard token.hasPrefix("kso_"), let session = sessions[GrantToken.hash(token)],
              session.generation == generation, session.expires > now, store.isUnlocked else {
            throw OptimizerAccessError.denied
        }
        return session
    }

    private func expire(now: Date) {
        sessions = sessions.filter { $0.value.expires > now }
        if sessions.isEmpty { store.lock(); decisionCache.removeAll() }
    }

    func destroy(service: KeysService) throws {
        lock(service: service)
        try store.destroy()
        try deleteKey()
    }

    func perform(token: String, service: KeysService, operation: String, payload: [String: Any]) throws -> [String: Any] {
        let began = DispatchTime.now().uptimeNanoseconds
        var productEvent: ProductAnalyticsEvent? = operation == "context_prepare" ? .contextFailure :
            (["retrieve", "select_tools", "route_model", "assess_memory"].contains(operation) ? .optimizerFailure : nil)
        defer {
            if let productEvent {
                let duration = Int(min(UInt64(Int.max), (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000))
                service.analytics?.record(productEvent, durationMS: duration)
            }
        }
        let session = try authorize(token)
        let reads: Set<String> = ["summary", "project_get", "entry_get", "entry_list", "entry_export", "search", "event_list", "diagnostics", "dependency_fingerprints", "context_prepare", "candidate_list"]
        let writes: Set<String> = ["entry_save", "entry_archive", "entry_delete", "task_start", "task_finish", "event_record", "candidate_capture"]
        let admin: Set<String> = ["project_save", "project_delete", "candidate_review"]
        let evaluations: Set<String> = ["retrieve", "select_tools", "route_model", "assess_memory"]
        guard reads.contains(operation) || writes.contains(operation) || admin.contains(operation) || evaluations.contains(operation) else {
            throw OptimizerAccessError.invalid
        }
        if admin.contains(operation), session.project != nil { throw OptimizerAccessError.denied }
        if writes.contains(operation) || admin.contains(operation), !session.writable { throw OptimizerAccessError.denied }
        if operation == "project_save", let id = payload["id"] as? String, UUID(uuidString: id) == nil {
            throw OptimizerAccessError.invalid
        }
        let result: [String: Any]
        if operation == "context_prepare" {
            guard let projectID = payload["project_id"] as? String, session.project == nil || session.project == projectID else {
                throw OptimizerAccessError.denied
            }
            let project = try store.perform(operation: "project_get", payload: ["project_id": projectID], projectScope: session.project, allowWrite: false)
            var clean = payload
            clean["max_candidates"] = 8
            let enabled = project["storage_enabled"] as? Bool == true && project["mode"] as? String != "off"
            let shortlist = enabled ? try store.perform(operation: "search", payload: clean, projectScope: session.project, allowWrite: false) : [:]
            let candidates = shortlist["candidates"] as? [[String: Any]] ?? []
            let paths = Array(Set(candidates.flatMap { ($0["dependencies"] as? [String: String] ?? [:]).keys })).sorted()
            let root = project["root"] as? String ?? ""
            clean["validated_dependencies"] = try OptimizerFiles.fingerprints(root: root, relativePaths: paths) { data in
                try self.store.fingerprint(projectID: projectID, data: data)
            }
            clean["validated_root"] = root
            // The store reloads current policy and entries atomically and rejects
            // root changes. Never trust client-supplied freshness hashes.
            result = try store.perform(operation: operation, payload: clean, projectScope: session.project, allowWrite: false)
        } else if operation == "dependency_fingerprints" {
            guard let projectID = payload["project_id"] as? String, session.project == nil || session.project == projectID,
                  let paths = payload["paths"] as? [String] else { throw OptimizerAccessError.denied }
            let project = try store.perform(operation: "project_get", payload: ["project_id": projectID], projectScope: session.project, allowWrite: false)
            let hashes = try OptimizerFiles.fingerprints(root: project["root"] as? String ?? "", relativePaths: paths) { data in
                try self.store.fingerprint(projectID: projectID, data: data)
            }
            result = ["dependencies": hashes, "excluded_count": paths.count - hashes.count]
        } else if evaluations.contains(operation) {
            result = try evaluate(session: session, service: service, operation: operation, payload: payload)
        } else {
            result = try store.perform(operation: operation, payload: payload, projectScope: session.project, allowWrite: session.writable)
            if writes.contains(operation) || admin.contains(operation) {
                mutex.lock(); decisionCache.removeAll(); mutex.unlock()
            }
        }
        // A screen lock/revocation during work must not return newly decrypted content.
        _ = try authorize(token)
        if operation == "context_prepare" {
            productEvent = switch result["status"] as? String {
            case "prepared": .contextPrepared
            case "unchanged": .contextUnchanged
            case "empty", "disabled": .contextEmpty
            default: .contextFailure
            }
        } else if evaluations.contains(operation) {
            if ((result["usage"] as? [String: Any])?["cache_hits"] as? Int ?? 0) > 0 {
                productEvent = .optimizerCacheHit
            } else if result["status"] as? String == "abstained" {
                productEvent = .optimizerAbstained
            } else {
                productEvent = ["suggested", "selected", "observed"].contains(result["status"] as? String ?? "") ? .optimizerSuccess : .optimizerFailure
            }
        }
        return result
    }

    private func evaluate(session: Session, service: KeysService, operation: String, payload: [String: Any]) throws -> [String: Any] {
        guard let projectID = payload["project_id"] as? String, session.project == nil || session.project == projectID else {
            throw OptimizerAccessError.denied
        }
        let object = try store.perform(operation: "project_get", payload: ["project_id": projectID], projectScope: session.project, allowWrite: false)
        let project = (object["project"] as? [String: Any]) ?? object
        let mode = project["mode"] as? String ?? "off"
        func abstain(_ reason: String) -> [String: Any] {
            ["ok": true, "command": operation, "status": "abstained", "applied": false, "reason": reason]
        }
        guard mode != "off", project["storage_enabled"] as? Bool == true else { return abstain("project_disabled") }
        let feature = ["retrieve": "plan_reuse", "select_tools": "tool_selection", "route_model": "model_routing", "assess_memory": "memory_assessment"][operation]!
        if (project["feature_flags"] as? [String: Bool])?[feature] == false { return abstain("feature_disabled") }
        guard project["provider_enabled"] as? Bool == true else { return abstain("provider_disabled") }
        guard let grantID = session.grantID, let grantToken = session.grantToken, let endpoint = session.endpoint, let adapter = session.provider,
              service.grants.grant(id: grantID)?.isActive(at: Date()) == true else { return abstain("jev_not_authorized") }
        guard let taskID = payload["task_id"] as? String ?? session.taskID, UUID(uuidString: taskID) != nil else {
            throw AppError.usage("start an optimizer task before requesting an evaluation")
        }
        let text = payload["request_text"] as? String ?? payload["query"] as? String ?? ""
        guard !text.isEmpty, text.utf8.count <= 16_000 else { throw OptimizerAccessError.invalid }
        mutex.lock()
        let circuitOpen = failures[projectID].map { $0.count >= 3 && $0.until > Date() } ?? false
        mutex.unlock()
        if circuitOpen { return abstain("circuit_open") }
        var candidates = payload["candidates"] as? [[String: Any]] ?? []
        var dependencies: [String: String] = [:]
        if operation == "retrieve" {
            let found = try store.perform(operation: "search", payload: [
                "project_id": projectID, "query": String(text.prefix(2_000)), "available_tools": payload["available_tools"] ?? [],
                "dependencies": [:], "max_candidates": 8,
            ], projectScope: session.project, allowWrite: false)
            candidates = (found["candidates"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "plan" }
            if candidates.isEmpty { return abstain("no_candidates") }
            let paths = candidates.flatMap { ($0["dependencies"] as? [String: String] ?? [:]).keys }
            dependencies = try OptimizerFiles.fingerprints(root: project["root"] as? String ?? "", relativePaths: Array(Set(paths)).sorted()) { data in
                try self.store.fingerprint(projectID: projectID, data: data)
            }
        }
        // Historical bodies are available in the library inspector, but are not
        // inputs to an applicability decision. Keep the current revision identity.
        candidates = candidates.map { candidate in
            var current = candidate
            current.removeValue(forKey: "revisions")
            return current
        }
        guard candidates.count <= 64 else { throw OptimizerAccessError.invalid }
        let candidateExpiry = candidates.compactMap { candidate -> Date? in
            if let number = candidate["expires_at"] as? NSNumber {
                let value = number.doubleValue
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
            }
            if let value = candidate["expires_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            }
            return nil
        }.min()
        let maximumInput = min(30_000, project["max_input_tokens"] as? Int ?? 30_000)
        let proposedMemory = (payload["proposed_memory"] as? String).map { ["content": $0] as [String: Any] }
            ?? payload["proposed_memory"] as? [String: Any] ?? [:]
        var request: [String: Any] = [
            "command": operation, "project_id": projectID, "task_id": taskID,
            "project_enabled": true, "provider_enabled": true, "mode": mode,
            "request_text": text, "current_constraints": payload["current_constraints"] ?? ["requirements": []],
            "available_tools": payload["available_tools"] ?? [], "dependency_hashes": dependencies,
            "candidates": candidates, "task_requirements": payload["task_requirements"] ?? [:],
            "proposed_memory": proposedMemory,
            "policy": ["max_requests": 1, "max_input_tokens": maximumInput, "candidate_limit": 8, "threshold": 0.9],
        ]
        for field in ["explicit_model_id", "current_model_id", "optimizer_cost_usd", "cache_rebuild_cost_usd", "fallback_cost_usd"] {
            if let value = payload[field] { request[field] = value }
        }
        if let cost = payload["optimizer_cost_usd"] {
            var policy = request["policy"] as! [String: Any]
            policy["optimizer_cost_usd"] = cost
            request["policy"] = policy
        }
        guard try JSONValue.data(request).count <= 100_000 else { return abstain("input_limit") }
        let encoded = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let cacheKey = Data(SHA256.hash(data: encoded + GrantToken.hash(grantToken)))
        mutex.lock()
        decisionCache = decisionCache.filter { $0.value.expires > cacheNow() }
        let cached = decisionCache[cacheKey]?.result
        mutex.unlock()
        if var cached {
            cached["usage"] = ["requests": 0, "cache_hits": 1, "actual_input_tokens": 0, "actual_output_tokens": 0, "optimizer_cost_usd": 0]
            _ = try store.perform(operation: "event_record", payload: [
                "project_id": projectID, "task_id": taskID, "event_id": UUID().uuidString,
                "source": "optimizer", "kind": "decision_cache_hit", "model": adapter.modelID,
                "status": "reused", "latency_ms": 0, "input_tokens": 0, "output_tokens": 0, "reported_cost_usd": 0,
            ], projectScope: session.project, allowWrite: true)
            return cached
        }
        let reservation = try store.perform(operation: "task_reserve", payload: [
            "project_id": projectID, "task_id": taskID, "request_count": 1,
            "estimated_input_tokens": maximumInput, "clamp_to_remaining": true,
        ], projectScope: session.project, allowWrite: true)
        var policy = request["policy"] as! [String: Any]
        policy["max_input_tokens"] = reservation["estimated_input_tokens"]
        request["policy"] = policy
        let started = Date()
        let result: [String: Any]
        do {
            result = try runEngine(request, ["AI_GATEWAY_API_KEY": grantToken, "AI_GATEWAY_BASE_URL": endpoint,
                                           "KEYS_JEV_SCOPED_GRANT": "1", "KEYS_JEV_PROVIDER": adapter.id])
        } catch {
            recordFailure(projectID)
            // It may have dispatched before failing. Retain its reservation and
            // report unknown cost rather than making the failure free.
            _ = try? store.perform(operation: "event_record", payload: [
                "project_id": projectID, "task_id": taskID, "event_id": UUID().uuidString,
                "source": "optimizer", "kind": "jev_decision", "model": adapter.modelID,
                "status": "engine_unavailable", "latency_ms": max(0, Int(Date().timeIntervalSince(started) * 1000)),
            ], projectScope: session.project, allowWrite: true)
            return abstain("engine_unavailable")
        }
        let usage = result["usage"] as? [String: Any] ?? [:]
        if ["provider_unavailable", "evaluation_failed", "invalid_evaluation", "engine_unavailable"].contains(result["reason"] as? String ?? "") {
            recordFailure(projectID)
        } else {
            mutex.lock(); failures.removeValue(forKey: projectID); mutex.unlock()
        }
        if let reservationID = reservation["reservation_id"] as? String {
            var settlement: [String: Any] = ["project_id": projectID, "task_id": taskID,
                "reservation_id": reservationID, "dispatched": (usage["requests"] as? Int ?? 1) > 0]
            if let actual = usage["actual_input_tokens"] { settlement["actual_input_tokens"] = actual }
            _ = try store.perform(operation: "task_settle", payload: settlement, projectScope: session.project, allowWrite: true)
        }
        var event: [String: Any] = [
            "project_id": projectID, "task_id": taskID, "event_id": UUID().uuidString,
            "source": "optimizer", "kind": "jev_decision", "model": adapter.modelID,
            "status": result["status"] as? String ?? "abstained",
            "latency_ms": max(0, Int(Date().timeIntervalSince(started) * 1000)),
        ]
        for (source, target) in [("actual_input_tokens", "input_tokens"), ("actual_output_tokens", "output_tokens"),
                                  ("optimizer_cost_usd", "reported_cost_usd")] {
            if let value = usage[source] { event[target] = value }
        }
        _ = try store.perform(operation: "event_record", payload: event, projectScope: session.project, allowWrite: true)
        if ["suggested", "selected", "observed"].contains(result["status"] as? String ?? "") {
            mutex.lock()
            if decisionCache.count >= 32, let first = decisionCache.keys.first { decisionCache.removeValue(forKey: first) }
            let expires = min(cacheNow().addingTimeInterval(300), candidateExpiry ?? .distantFuture)
            if expires > cacheNow() { decisionCache[cacheKey] = (expires, result) }
            mutex.unlock()
        }
        return result
    }

    private func recordFailure(_ project: String) {
        mutex.lock()
        let count = (failures[project]?.count ?? 0) + 1
        failures[project] = (count, Date().addingTimeInterval(60))
        mutex.unlock()
    }

    private func integer(_ value: Any?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              range.contains(n.intValue) else { throw OptimizerAccessError.invalid }
        return n.intValue
    }
}

enum OptimizerFiles {
    /// Hash only bounded regular files below the approved project root. Never follow
    /// a symlink out of that root, and omit credential/configuration locations.
    static func fingerprints(root: String, relativePaths: [String], fingerprint: (Data) throws -> String = { data in
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }) throws -> [String: String] {
        guard root.hasPrefix("/"), relativePaths.count <= 64 else { return [:] }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        var result: [String: String] = [:]
        for path in relativePaths {
            let parts = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty,
                  !parts.contains(where: { $0.hasPrefix(".env") || [".git", ".ssh", ".aws", ".codex", ".claude"].contains($0) }),
                  !path.lowercased().contains("credential"), !path.lowercased().contains("secret"),
                  !path.hasSuffix(".pem"), !path.hasSuffix(".key") else { continue }
            let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { continue }
            // Reject aliases as well as their spelled-out sensitive destinations.
            guard url.path == base.appendingPathComponent(path).standardizedFileURL.path else { continue }
            let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info?.isRegularFile == true, let count = info?.fileSize, count <= 2_000_000,
                  let data = try? Data(contentsOf: url), data.count <= 2_000_000 else { continue }
            result[path] = try fingerprint(data)
        }
        return result
    }
}

enum OptimizerProcess {
    static func run(_ request: [String: Any], _ environment: [String: String]) throws -> [String: Any] {
        let root = try WebRoot.find().deletingLastPathComponent()
        let script = root.appendingPathComponent("Plugins/jev-optimizer/dist/optimizer-cli.js")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw OptimizerAccessError.unavailable }
        let process = Process()
        let nodePaths = [ProcessInfo.processInfo.environment["KEYS_OPTIMIZER_NODE"],
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node").path,
                         "/opt/homebrew/bin/node", "/usr/local/bin/node"].compactMap { $0 }
        guard let node = nodePaths.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw OptimizerAccessError.unavailable
        }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        var env = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer { timeout.cancel(); if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: JSONValue.data(request))
        try input.fileHandleForWriting.close()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 256_000 else { throw OptimizerAccessError.invalid }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OptimizerAccessError.unavailable
        }
        return result
    }
}
