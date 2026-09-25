import CoreFoundation
import Foundation

struct GatewayUsageRow: Equatable {
    var ts: String
    var key: String
    var provider: String
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var status: Int
    var durationMs: Int
    /// Upstream `request-id` / `x-request-id` response header. Claude Code stores the same value
    /// as `requestId`, so a call seen both locally and through the gateway can be matched exactly.
    var requestId: String? = nil
    /// Provider-reported total USD, at the same precision as local usage costs.
    /// nil means absent/invalid, while zero is an explicit reported zero.
    var reportedCostUsdTicks: Int64? = nil

    /// The usage_events row this call is stored as. Absent token counts become zero there,
    /// which is why pricing (`SpendQueries.gatewayUsd`) treats an all-zero call as unknown.
    func usageEvent() -> UsageEvent {
        UsageEvent(
            source: "gateway",
            sessionId: "gw:" + key,
            promptId: requestId ?? UUID().uuidString.lowercased(),
            model: model ?? "",
            occurredAt: ts,
            provider: provider,
            modelCalls: 1,
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cachedReadTokens: cacheReadTokens ?? 0,
            cacheCreationTokens: cacheWriteTokens ?? 0,
            costUsdTicks: reportedCostUsdTicks,
            keyName: key,
            httpStatus: status
        )
    }
}

struct GatewayParsedUsage: Equatable {
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reportedCostUsdTicks: Int64?
}

enum GatewayUsageParser {
    /// Usage from a whole, non-streamed response body.
    static func parse(api: String, requestBody: Data, responseBody: Data, requestModel: String? = nil) -> GatewayParsedUsage {
        var parsed = lastJSONObject(in: responseBody).map { usage(api: api, object: $0) } ?? GatewayParsedUsage()
        if parsed.model == nil {
            parsed.model = requestedModel(api: api, requestBody: requestBody, requestModel: requestModel)
        }
        return parsed
    }

    /// Usage from one response object: a whole JSON body or a single SSE event. A stream is the
    /// merge of its events (see GatewayTee), so each API is parsed the same way either way.
    static func usage(api: String, object obj: [String: Any]) -> GatewayParsedUsage {
        switch api {
        case "openai": return openAI(from: obj)
        case "anthropic": return anthropic(from: obj)
        case "gemini": return gemini(from: obj)
        case "vercel-evaluation": return vercelEvaluation(from: obj)
        case "typesafe-systemone": return typeSafe(from: obj)
        default: return GatewayParsedUsage()
        }
    }

    /// The model the request named, for when the response names none. The evaluation protocol
    /// sends it in `ai-model-id`, not in its state/questions body; other APIs must not trust
    /// that header.
    static func requestedModel(api: String, requestBody: Data, requestModel: String?) -> String? {
        if api == "vercel-evaluation" {
            let model = requestModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return model?.isEmpty == false ? model : nil
        }
        return modelFromRequest(requestBody)
    }

    static func isSSE(_ contentType: String?, body: Data) -> Bool {
        if let contentType, contentType.lowercased().contains("event-stream") { return true }
        if body.starts(with: Data("data:".utf8)) || body.starts(with: Data("event:".utf8)) { return true }
        if let text = String(data: body.prefix(16), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("data:") || trimmed.hasPrefix("event:")
        }
        return false
    }

    private static func modelFromRequest(_ body: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)).flatMap(JSONValue.object) else {
            return nil
        }
        return JSONValue.string(obj["model"])
    }

    private static func vercelEvaluation(from obj: [String: Any]) -> GatewayParsedUsage {
        let usage = JSONValue.object(obj["usage"])
        let metadata = JSONValue.object(obj["providerMetadata"])
        let gateway = metadata.flatMap { JSONValue.object($0["gateway"]) }
        return GatewayParsedUsage(
            inputTokens: evaluationTokenCount(usage?["inputTokens"]),
            outputTokens: evaluationTokenCount(usage?["outputTokens"]),
            reportedCostUsdTicks: evaluationCostTicks(gateway?["cost"])
        )
    }

    private static func typeSafe(from obj: [String: Any]) -> GatewayParsedUsage {
        let usage = JSONValue.object(obj["usage"])
        return GatewayParsedUsage(model: JSONValue.string(obj["model"]),
            inputTokens: evaluationTokenCount(usage?["input_tokens"]),
            outputTokens: evaluationTokenCount(usage?["output_tokens"]))
    }

    /// Invalid or absent counts stay unknown; `0` is a valid reported count.
    private static func evaluationTokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(exactly: number.doubleValue), count >= 0
        else { return nil }
        return count
    }

    private static func evaluationCostTicks(_ value: Any?) -> Int64? {
        let usd: Double?
        if let text = value as? String {
            usd = Double(text)
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            usd = number.doubleValue
        } else {
            usd = nil
        }
        guard let usd, usd.isFinite, usd >= 0 else { return nil }
        return Int64(exactly: (usd * Ticks.perUSD).rounded())
    }

    private static func openAI(from obj: [String: Any]) -> GatewayParsedUsage {
        var r = GatewayParsedUsage()
        r.model = JSONValue.string(obj["model"])
        if let type = obj["type"] as? String, type == "response.completed",
           let response = JSONValue.object(obj["response"])
        {
            r.model = JSONValue.string(response["model"]) ?? r.model
            if let usage = JSONValue.object(response["usage"]) {
                applyOpenAIUsage(usage, into: &r)
            }
            return r
        }
        if let usage = JSONValue.object(obj["usage"]) {
            applyOpenAIUsage(usage, into: &r)
        }
        return r
    }

    private static func applyOpenAIUsage(_ usage: [String: Any], into r: inout GatewayParsedUsage) {
        if let prompt = JSONValue.int(usage["prompt_tokens"]) {
            r.inputTokens = prompt
            r.outputTokens = JSONValue.int(usage["completion_tokens"])
            if let details = JSONValue.object(usage["prompt_tokens_details"]) {
                r.cacheReadTokens = JSONValue.int(details["cached_tokens"])
            }
        } else if let input = JSONValue.int(usage["input_tokens"]) {
            r.inputTokens = input
            r.outputTokens = JSONValue.int(usage["output_tokens"])
            if let details = JSONValue.object(usage["input_tokens_details"]) {
                r.cacheReadTokens = JSONValue.int(details["cached_tokens"])
            }
        }
    }

    private static func anthropic(from obj: [String: Any]) -> GatewayParsedUsage {
        var r = GatewayParsedUsage()
        let type = obj["type"] as? String
        if type == "message_start", let message = JSONValue.object(obj["message"]) {
            r.model = JSONValue.string(message["model"]) ?? r.model
            if let usage = JSONValue.object(message["usage"]) {
                applyAnthropicUsage(usage, into: &r, outputOnly: false)
            }
            return r
        }
        if type == "message_delta", let usage = JSONValue.object(obj["usage"]) {
            applyAnthropicUsage(usage, into: &r, outputOnly: true)
            return r
        }
        if let model = JSONValue.string(obj["model"]) { r.model = model }
        if let usage = JSONValue.object(obj["usage"]) {
            applyAnthropicUsage(usage, into: &r, outputOnly: false)
        }
        return r
    }

    private static func applyAnthropicUsage(
        _ usage: [String: Any],
        into r: inout GatewayParsedUsage,
        outputOnly: Bool
    ) {
        if outputOnly {
            if let output = JSONValue.int(usage["output_tokens"]) {
                r.outputTokens = output
            }
            return
        }
        if let input = JSONValue.int(usage["input_tokens"]) { r.inputTokens = input }
        if let output = JSONValue.int(usage["output_tokens"]) { r.outputTokens = output }
        if let read = JSONValue.int(usage["cache_read_input_tokens"]) { r.cacheReadTokens = read }
        if let write = JSONValue.int(usage["cache_creation_input_tokens"]) { r.cacheWriteTokens = write }
    }

    private static func gemini(from obj: [String: Any]) -> GatewayParsedUsage {
        var r = GatewayParsedUsage()
        r.model = JSONValue.string(obj["modelVersion"]) ?? JSONValue.string(obj["model"])
        if let meta = JSONValue.object(obj["usageMetadata"]) {
            r.inputTokens = JSONValue.int(meta["promptTokenCount"])
            r.outputTokens = JSONValue.int(meta["candidatesTokenCount"])
            r.cacheReadTokens = JSONValue.int(meta["cachedContentTokenCount"])
        }
        return r
    }

    /// Last complete JSON object in `data`. Used for non-SSE bodies.
    static func lastJSONObject(in data: Data) -> [String: Any]? {
        if let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var last: [String: Any]?
        var decoder = JSONBoundaryScanner()
        for ch in text.utf8 {
            if let obj = decoder.consume(ch) {
                last = obj
            }
        }
        return last
    }

    static func sseJSONObjects(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var objects: [[String: Any]] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            var dataLines: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("data:") {
                    var payload = String(line.dropFirst(5))
                    if payload.hasPrefix(" ") { payload = String(payload.dropFirst()) }
                    dataLines.append(payload)
                }
            }
            let payload = dataLines.joined(separator: "\n")
            if payload.isEmpty || payload == "[DONE]" { continue }
            if let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))).flatMap(JSONValue.object) {
                objects.append(obj)
            }
        }
        return objects
    }
}

/// Finds successive top-level JSON objects without holding more than the current object.
private struct JSONBoundaryScanner {
    private var depth = 0
    private var inString = false
    private var escape = false
    private var start: [UInt8] = []

    mutating func consume(_ byte: UInt8) -> [String: Any]? {
        if inString {
            start.append(byte)
            if escape {
                escape = false
            } else if byte == UInt8(ascii: "\\") {
                escape = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
            }
            return nil
        }
        if byte == UInt8(ascii: "\"") {
            if depth > 0 { start.append(byte) }
            inString = true
            return nil
        }
        if byte == UInt8(ascii: "{") {
            if depth == 0 { start = [byte] } else { start.append(byte) }
            depth += 1
            return nil
        }
        if depth == 0 { return nil }
        start.append(byte)
        if byte == UInt8(ascii: "}") {
            depth -= 1
            if depth == 0 {
                let data = Data(start)
                start.removeAll(keepingCapacity: true)
                return (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object)
            }
        }
        return nil
    }
}

/// Tee of the upstream response: client already has the bytes; this only parses usage.
final class GatewayTee: @unchecked Sendable {
    let api: String
    private let lock = NSLock()
    private var eventBuf = Data()
    private var jsonBuf = Data()
    private var lastUsage = GatewayParsedUsage()
    private var contentType: String?
    private let eventCap = 256 * 1024
    private let jsonCap = 1 * 1024 * 1024
    private var sse = false
    private var sseKnown = false

    init(api: String) {
        self.api = api
    }

    func setContentType(_ value: String) {
        lock.lock()
        contentType = value
        if value.lowercased().contains("event-stream") {
            sse = true
            sseKnown = true
        }
        lock.unlock()
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if !sseKnown {
            sse = GatewayUsageParser.isSSE(contentType, body: data)
            sseKnown = true
        }
        if sse {
            appendSSE(data)
        } else if jsonBuf.count < jsonCap {
            let room = jsonCap - jsonBuf.count
            jsonBuf.append(Data(data.prefix(room)))
        }
    }

    func result(requestBody: Data, requestModel: String? = nil) -> GatewayParsedUsage {
        lock.lock()
        // A stream whose first chunk was too short to recognise went to jsonBuf; sniff the
        // whole buffer again so a short-first-chunk Anthropic stream still counts.
        if !sse, GatewayUsageParser.isSSE(contentType, body: jsonBuf) {
            sse = true
            eventBuf = jsonBuf
            jsonBuf.removeAll()
        }
        if sse, !eventBuf.isEmpty {
            parseSSEEvent(eventBuf)
            eventBuf.removeAll(keepingCapacity: true)
        }
        var parsed = sse
            ? lastUsage
            : GatewayUsageParser.lastJSONObject(in: jsonBuf).map { GatewayUsageParser.usage(api: api, object: $0) }
                ?? GatewayParsedUsage()
        lock.unlock()
        if parsed.model == nil {
            parsed.model = GatewayUsageParser.requestedModel(api: api, requestBody: requestBody, requestModel: requestModel)
        }
        return parsed
    }

    private func appendSSE(_ data: Data) {
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            eventBuf.append(bytes[i])
            if eventBuf.count > eventCap {
                eventBuf.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            if eventBuf.count >= 2 {
                let n = eventBuf.count
                let b1 = eventBuf[eventBuf.startIndex + (n - 1)]
                let b2 = eventBuf[eventBuf.startIndex + (n - 2)]
                if b2 == 10, b1 == 10 {
                    parseSSEEvent(eventBuf)
                    eventBuf.removeAll(keepingCapacity: true)
                } else if n >= 4 {
                    let b3 = eventBuf[eventBuf.startIndex + (n - 3)]
                    let b4 = eventBuf[eventBuf.startIndex + (n - 4)]
                    if b4 == 13, b3 == 10, b2 == 13, b1 == 10 {
                        parseSSEEvent(eventBuf)
                        eventBuf.removeAll(keepingCapacity: true)
                    }
                }
            }
            i += 1
        }
    }

    private func parseSSEEvent(_ data: Data) {
        for obj in GatewayUsageParser.sseJSONObjects(data) {
            lastUsage = merge(lastUsage, GatewayUsageParser.usage(api: api, object: obj))
        }
    }

    private func merge(_ base: GatewayParsedUsage, _ piece: GatewayParsedUsage) -> GatewayParsedUsage {
        var out = base
        if piece.model != nil { out.model = piece.model }
        if piece.inputTokens != nil { out.inputTokens = piece.inputTokens }
        if piece.outputTokens != nil { out.outputTokens = piece.outputTokens }
        if piece.cacheReadTokens != nil { out.cacheReadTokens = piece.cacheReadTokens }
        if piece.cacheWriteTokens != nil { out.cacheWriteTokens = piece.cacheWriteTokens }
        if piece.reportedCostUsdTicks != nil { out.reportedCostUsdTicks = piece.reportedCostUsdTicks }
        return out
    }
}
