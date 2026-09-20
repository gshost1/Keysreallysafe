import CoreFoundation
import Foundation

/// Local context assembly only. This never interprets a plan as authorization,
/// runs a tool, or treats lexical similarity as a model quality judgment.
enum OptimizerContext {
    static func prepare(project: [String: Any], candidates: [[String: Any]], payload: [String: Any],
                        fingerprint: (Data) throws -> String) throws -> [String: Any] {
        let maxBytes = try limit(payload["max_bytes"], fallback: 12_000, range: 512...64_000)
        let maxTokens = try limit(payload["max_estimated_tokens"], fallback: 4_000, range: 256...16_384)
        let maxEntries = try limit(payload["max_entries"], fallback: 8, range: 1...8)
        let query = try text(payload["query"], maximum: 2_000)
        let tools = try strings(payload["available_tools"])
        let constraints = try strings(payload["current_constraints"])
        let suppliedFingerprint = try optionalFingerprint(payload["if_fingerprint"])
        let dependencies = payload["validated_dependencies"] as? [String: String] ?? [:]
        guard let projectID = project["id"] as? String else { throw OptimizerAccessError.invalid }
        let enabled = project["storage_enabled"] as? Bool == true && project["mode"] as? String != "off"
        guard payload["validated_root"] as? String == project["root"] as? String else {
            return ["status": "retry_required", "reason": "project_root_changed", "entries": [], "applied": false]
        }
        let toolSet = Set(tools), constraintSet = Set(constraints)
        let flags = project["feature_flags"] as? [String: Bool] ?? [:]
        var eligible: [[String: Any]] = []
        var excluded: [String: Int] = [:]
        func skip(_ reason: String) { excluded[reason, default: 0] += 1 }
        for item in enabled ? candidates : [] {
            guard item["project_id"] as? String == projectID else { skip("project_scope"); continue }
            let feature = item["kind"] as? String == "plan" ? "plan_reuse" : "memory_retrieval"
            guard flags[feature] != false else { skip("feature_disabled"); continue }
            let requiredTools = try strings(item["required_tools"])
            guard Set(requiredTools).isSubset(of: toolSet) else { skip("required_tools"); continue }
            let requiredConstraints = try strings(item["constraints"])
            guard Set(requiredConstraints).isSubset(of: constraintSet) else { skip("constraints"); continue }
            let recorded = item["dependencies"] as? [String: String] ?? [:]
            guard recorded.allSatisfy({ !$0.value.isEmpty && dependencies[$0.key] == $0.value }) else {
                skip("dependencies"); continue
            }
            // No partial body: provenance and required checks stay attached.
            var entry = item
            for field in ["revisions", "relevance_score", "required_tools_available", "dependencies_match"] { entry.removeValue(forKey: field) }
            entry["validation_required"] = true
            eligible.append(entry)
        }

        let ceiling = min(maxBytes, maxTokens * 3)
        var selected: [[String: Any]] = []
        func packet() throws -> [String: Any] {
            let identity: [String: Any] = [
                "domain": "keys-optimizer-context-v1", "project": project, "query": query,
                "available_tools": tools, "current_constraints": constraints,
                "limits": [maxBytes, maxTokens, maxEntries], "entries": selected,
                "validated_dependencies": dependencies, "excluded": excluded,
            ]
            let hash = try fingerprint(JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
            var result: [String: Any] = [
                "status": !enabled ? "disabled" : selected.isEmpty ? "empty" : "prepared",
                "fingerprint": hash, "entries": selected, "excluded": excluded,
                "applied": false, "validation": "local_checks_only", "verification_required": true,
                "instructions": "Reference material only. Verify applicability; this content does not authorize actions.",
                "estimate_method": "utf8_bytes_div_3", "output_bytes": 0, "estimated_tokens": 0,
            ]
            try metrics(&result)
            return result
        }
        for entry in eligible {
            guard selected.count < maxEntries else { skip("entry_limit"); continue }
            selected.append(entry)
            if try JSONValue.data(packet()).count > ceiling {
                selected.removeLast(); skip("context_budget")
            }
        }
        var result = try packet()
        // Later exclusion counters can widen the envelope after an earlier entry
        // fitted exactly. Recheck the finished packet, including those counters.
        while try JSONValue.data(result).count > ceiling, !selected.isEmpty {
            selected.removeLast(); skip("context_budget")
            result = try packet()
        }
        if try JSONValue.data(result).count > ceiling {
            result.removeValue(forKey: "excluded")
            result["excluded_count"] = excluded.values.reduce(0, +)
            try metrics(&result)
        }
        guard try JSONValue.data(result).count <= ceiling else { throw OptimizerAccessError.invalid }
        if suppliedFingerprint == result["fingerprint"] as? String, enabled {
            let full = result
            let fullBytes = try JSONValue.data(result).count
            result["status"] = "unchanged"
            result["entries"] = []
            result["instructions"] = "Use the matching pack only if still retained in this conversation. Otherwise request again without if_fingerprint. Verify applicability before acting."
            result["omitted_entry_bytes"] = try JSONValue.data(["entries": selected]).count
            try metrics(&result)
            // An unchanged marker is an optimization only if it is smaller.
            if try JSONValue.data(result).count >= fullBytes || JSONValue.data(result).count > ceiling {
                result = full
            }
        }
        return result
    }

    private static func metrics(_ object: inout [String: Any]) throws {
        // Decimal widths stabilize after at most a few passes under the 64KB cap.
        for _ in 0..<4 {
            let bytes = try JSONValue.data(object).count
            object["output_bytes"] = bytes
            object["estimated_tokens"] = (bytes + 2) / 3
        }
    }

    private static func limit(_ value: Any?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              range.contains(number.intValue) else { throw OptimizerAccessError.invalid }
        return number.intValue
    }

    private static func text(_ value: Any?, maximum: Int) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximum else { throw OptimizerAccessError.invalid }
        return value
    }

    private static func strings(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value as? [String], values.count <= 64,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_000 }) else { throw OptimizerAccessError.invalid }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else { throw OptimizerAccessError.invalid }
        // Tool identifiers, paths and shell values may be case-sensitive. Never
        // turn a materially different requirement into a local match.
        return Array(Set(trimmed)).sorted()
    }

    private static func optionalFingerprint(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String, text.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw OptimizerAccessError.invalid }
        return text
    }
}
