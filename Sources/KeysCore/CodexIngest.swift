import Foundation

enum CodexIngest {
    static func run(home: URL, db: CatalogDB) throws -> IngestReport {
        var report = IngestReport()
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessions.path) else { return report }

        let enumerator = fm.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.path.contains("/archived_sessions/") { continue }
            let name = item.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), !name.hasSuffix(".jsonl.zst") else {
                continue
            }
            report.filesScanned += 1
            let fresh = LineParser(sessionId: sessionIdFromFilename(name))
            var parser = fresh
            do {
                // The parser state is committed with every batch cursor, so a resume mid-file
                // restores exactly the state that produced that offset.
                report.add(try IngestFiles.ingest(
                    item, db: db,
                    restore: { json in
                        parser = json.flatMap { try? JSONDecoder().decode(LineParser.self, from: Data($0.utf8)) } ?? fresh
                    },
                    state: { (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
                ) { line in parser.consume(line).map { [$0] } ?? [] })
            } catch {
                report.parseErrors += 1
            }
        }
        return report
    }

    struct LineParser: Codable {
        var sessionId: String
        var cwd: String?
        var model: String?
        var lastUsageFingerprint: String?
        var lastTurnId: String?
        var lastTotalsFingerprint: String?
        var turnIndex: Int = 0
        /// Calls stored since the last line that carried totals, with their summed bucket
        /// counts. The stored baseline plus this gap is every call the parser accounts for,
        /// so a totals line equal to that sum is a repeat emission and anything larger is a
        /// call not yet stored. Stored JSON from before these fields decodes with a zero
        /// gap, which is exactly the pre-totals upgrade case.
        var untrackedCalls: Int = 0
        var untrackedInput: Int = 0
        var untrackedOutput: Int = 0
        var untrackedCached: Int = 0
        var untrackedReasoning: Int = 0

        /// Stored `parser_json` is read back forever, so every field added after the first
        /// release has to decode when it is missing: an older build wrote only the fields
        /// it knew, and a state that fails to decode is replaced by a fresh parser, which
        /// mints prompt ids that collide with the rows already stored.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            lastUsageFingerprint = try container.decodeIfPresent(String.self, forKey: .lastUsageFingerprint)
            lastTurnId = try container.decodeIfPresent(String.self, forKey: .lastTurnId)
            lastTotalsFingerprint = try container.decodeIfPresent(String.self, forKey: .lastTotalsFingerprint)
            turnIndex = try container.decodeIfPresent(Int.self, forKey: .turnIndex) ?? 0
            untrackedCalls = try container.decodeIfPresent(Int.self, forKey: .untrackedCalls) ?? 0
            untrackedInput = try container.decodeIfPresent(Int.self, forKey: .untrackedInput) ?? 0
            untrackedOutput = try container.decodeIfPresent(Int.self, forKey: .untrackedOutput) ?? 0
            untrackedCached = try container.decodeIfPresent(Int.self, forKey: .untrackedCached) ?? 0
            untrackedReasoning = try container.decodeIfPresent(Int.self, forKey: .untrackedReasoning) ?? 0
        }

        init(sessionId: String) {
            self.sessionId = sessionId
        }

        mutating func consume(_ line: String) -> UsageEvent? {
            guard let root = try? JSONValue.line(line) else { return nil }
            let type = JSONValue.string(root["type"]) ?? ""
            let payload = JSONValue.object(root["payload"]) ?? [:]
            if type == "session_meta" {
                if let id = JSONValue.string(payload["id"]), !id.isEmpty { sessionId = id }
                cwd = JSONValue.string(payload["cwd"])
                if let m = CodexIngest.configuredModel(payload) { model = m }
                return nil
            }
            if type == "turn_context" {
                if let m = CodexIngest.configuredModel(payload) { model = m }
                return nil
            }
            if type == "event_msg", JSONValue.string(payload["type"]) == "token_count" {
                let turnId = CodexIngest.turnIdentity(root: root, payload: payload)
                guard var event = CodexIngest.eventFromTokenCount(
                    root: root,
                    payload: payload,
                    sessionId: sessionId,
                    cwd: cwd,
                    model: model
                ) else { return nil }
                let fingerprint =
                    "\(event.model)|\(event.inputTokens)|\(event.outputTokens)|\(event.cachedReadTokens)|\(event.reasoningTokens)"
                let totals = CodexIngest.totals(payload: payload, model: event.model)
                // Real rollouts carry no turn/event id, so two distinct calls can share a
                // per-call fingerprint. The cumulative totals disambiguate, and they can
                // only grow: a line whose totals do not exceed what is already accounted
                // for adds no call, and one that does exceed it is a call not yet stored.
                // Comparing against turnIndex x this call's spend instead counted a repeat
                // emission as new whenever the earlier calls had spent differently, and
                // stored it twice.
                if let turnId {
                    if turnId == lastTurnId { return nil }
                } else if let totals {
                    if let accounted = accountedTotals {
                        if !totals.exceeds(accounted) { return nil }
                    } else if untrackedCalls > 0 {
                        // No totals line yet, so the calls stored since the start are the
                        // whole account. A line whose totals do not exceed their sum
                        // re-emits one of them.
                        if !totals.exceeds(untrackedTotals) { return nil }
                    } else if fingerprint == lastUsageFingerprint {
                        // State saved by a build that recorded neither totals nor per-call
                        // sums, so nothing here can be checked against the totals. The line
                        // may re-emit the call that build already ingested, so drop it once
                        // and start tracking from its totals.
                        lastTotalsFingerprint = totals.fingerprint(model: event.model)
                        return nil
                    }
                } else if fingerprint == lastUsageFingerprint {
                    // Without totals a repeat emission (logged later, so a new timestamp) and a
                    // second identical call look the same; dropping it is the safer error.
                    return nil
                }
                if turnId == nil { turnIndex += 1 }
                event.promptId = turnId ?? "turn-\(turnIndex)"
                lastTurnId = turnId ?? event.promptId
                lastUsageFingerprint = fingerprint
                if let totals {
                    lastTotalsFingerprint = totals.fingerprint(model: event.model)
                    untrackedCalls = 0
                    untrackedInput = 0
                    untrackedOutput = 0
                    untrackedCached = 0
                    untrackedReasoning = 0
                } else {
                    // A totalless line says nothing about the cumulative count, so the stored
                    // baseline stays and only this call joins the gap. Clearing it here made
                    // the next totals line look like pre-totals state and dropped a call.
                    untrackedCalls += 1
                    untrackedInput += event.inputTokens
                    untrackedOutput += event.outputTokens
                    untrackedCached += event.cachedReadTokens
                    untrackedReasoning += event.reasoningTokens
                }
                return event
            }
            return nil
        }

        /// The stored baseline plus every call accepted since it, or nil when no totals line
        /// has been seen. A line whose totals do not exceed this adds no call.
        var accountedTotals: Totals? {
            guard let baseline = lastTotalsFingerprint.flatMap(CodexIngest.parseTotalsFingerprint) else {
                return nil
            }
            var sum = untrackedTotals
            sum.input += baseline.input
            sum.output += baseline.output
            sum.cached += baseline.cached
            sum.reasoning += baseline.reasoning
            return sum
        }

        /// Every call accepted since the last totals line, summed. This is the whole account
        /// before the first totals line of a session, which is why a totals line is checked
        /// against it rather than against `turnIndex x` one call's spend.
        var untrackedTotals: Totals {
            Totals(input: untrackedInput, output: untrackedOutput, cached: untrackedCached, reasoning: untrackedReasoning)
        }
    }

    /// One session-cumulative reading of `total_token_usage`.
    struct Totals: Equatable {
        var input: Int
        var output: Int
        var cached: Int
        var reasoning: Int

        func fingerprint(model: String) -> String {
            "\(model)|\(input)|\(output)|\(cached)|\(reasoning)"
        }

        /// Whether this reading covers more calls than `other`: one bucket larger and none
        /// smaller. A re-emission repeats the whole reading exactly, so equality is the
        /// repeat, and a strictly larger one is a call not yet stored.
        func exceeds(_ other: Totals) -> Bool {
            input >= other.input && output >= other.output && cached >= other.cached
                && reasoning >= other.reasoning && self != other
        }
    }

    /// The session-cumulative reading on this line, or nil when it carries none.
    /// Used only to tell an advancing call apart from a repeat emission; never summed.
    static func totals(payload: [String: Any], model: String) -> Totals? {
        let info = JSONValue.object(payload["info"]) ?? [:]
        guard let totals = JSONValue.object(info["total_token_usage"]) else { return nil }
        return Totals(
            input: JSONValue.int(totals["input_tokens"]) ?? 0,
            output: JSONValue.int(totals["output_tokens"]) ?? 0,
            cached: JSONValue.int(totals["cached_input_tokens"]) ?? 0,
            reasoning: JSONValue.int(totals["reasoning_output_tokens"]) ?? 0
        )
    }

    /// Reads a stored `model|in|out|cached|reasoning` fingerprint back into its totals.
    static func parseTotalsFingerprint(_ text: String) -> Totals? {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5, let input = Int(parts[1]), let output = Int(parts[2]),
              let cached = Int(parts[3]), let reasoning = Int(parts[4])
        else { return nil }
        return Totals(input: input, output: output, cached: cached, reasoning: reasoning)
    }

    /// Fingerprint of the session-cumulative `total_token_usage`, or nil when absent.
    /// Used only to tell an advancing call apart from a repeat emission; never summed.
    static func totalsFingerprint(payload: [String: Any], model: String) -> String? {
        totals(payload: payload, model: model)?.fingerprint(model: model)
    }

    static func turnIdentity(root: [String: Any], payload: [String: Any]) -> String? {
        let info = JSONValue.object(payload["info"]) ?? [:]
        if let id = JSONValue.string(info["turn_id"]), !id.isEmpty { return id }
        if let id = JSONValue.string(payload["turn_id"]), !id.isEmpty { return id }
        if let id = JSONValue.string(root["id"]), !id.isEmpty { return id }
        return nil
    }

    /// Session header / first turn_context model. Never `"unknown"`.
    static func configuredModel(_ payload: [String: Any]) -> String? {
        if let m = JSONValue.string(payload["model"]), isRealModel(m) { return m }
        if let m = JSONValue.string(payload["current_model"]), isRealModel(m) { return m }
        if let config = JSONValue.object(payload["config"]),
           let m = JSONValue.string(config["model"]), isRealModel(m)
        {
            return m
        }
        return nil
    }

    private static func isRealModel(_ model: String) -> Bool {
        !model.isEmpty && model.lowercased() != "unknown"
    }

    /// Per-turn buckets only (`last_token_usage`). Cumulative `total_token_usage` would double-count.
    static func eventFromTokenCount(
        root: [String: Any],
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        model: String?
    ) -> UsageEvent? {
        let info = JSONValue.object(payload["info"]) ?? [:]
        guard let last = JSONValue.object(info["last_token_usage"]) else { return nil }
        let input = JSONValue.int(last["input_tokens"]) ?? 0
        let output = JSONValue.int(last["output_tokens"]) ?? 0
        let cached = JSONValue.int(last["cached_input_tokens"]) ?? 0
        let reasoning = JSONValue.int(last["reasoning_output_tokens"]) ?? 0
        if input == 0 && output == 0 && cached == 0 && reasoning == 0 { return nil }
        let occurredAt = UTC.normalize(root["timestamp"]) ?? UTC.iso(Date(timeIntervalSince1970: 0))
        let resolvedModel: String? = {
            if let m = JSONValue.string(info["model"]), isRealModel(m) { return m }
            if let m = JSONValue.string(payload["model"]), isRealModel(m) { return m }
            if let model, isRealModel(model) { return model }
            return nil
        }()
        guard let resolvedModel else { return nil }
        // LineParser.consume sets the prompt id from the turn.
        return UsageEvent(
            source: "codex-local",
            sessionId: sessionId,
            promptId: "",
            model: resolvedModel,
            occurredAt: occurredAt,
            provider: "openai",
            cwd: cwd,
            modelCalls: 1,
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cached,
            reasoningTokens: reasoning
        )
    }

    static func sessionIdFromFilename(_ name: String) -> String {
        let stem = name.replacingOccurrences(of: ".jsonl", with: "")
        if let range = stem.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(stem[range])
        }
        return stem
    }
}
