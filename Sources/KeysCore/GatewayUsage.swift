import Foundation

struct GatewayUsageRow: Equatable {
    var id: Int64? = nil
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
}

struct GatewayParsedUsage: Equatable {
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
}

enum GatewayUsageParser {
    static func parse(
        api: String,
        requestBody: Data,
        responseBody: Data,
        contentType: String?
    ) -> GatewayParsedUsage {
        var parsed: GatewayParsedUsage
        switch api {
        case "openai":
            parsed = parseOpenAI(responseBody: responseBody, contentType: contentType)
        case "anthropic":
            parsed = parseAnthropic(responseBody: responseBody, contentType: contentType)
        case "gemini":
            parsed = parseGemini(responseBody: responseBody, contentType: contentType)
        default:
            parsed = GatewayParsedUsage()
        }
        if parsed.model == nil {
            parsed.model = modelFromRequest(requestBody)
        }
        return parsed
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

    private static func parseOpenAI(responseBody: Data, contentType: String?) -> GatewayParsedUsage {
        if isSSE(contentType, body: responseBody) {
            var last = GatewayParsedUsage()
            for obj in sseJSONObjects(responseBody) {
                let piece = openAI(from: obj)
                if piece.inputTokens != nil || piece.outputTokens != nil {
                    last.inputTokens = piece.inputTokens ?? last.inputTokens
                    last.outputTokens = piece.outputTokens ?? last.outputTokens
                    last.cacheReadTokens = piece.cacheReadTokens ?? last.cacheReadTokens
                }
                if let model = piece.model { last.model = model }
            }
            return last
        }
        guard let obj = lastJSONObject(in: responseBody) else { return GatewayParsedUsage() }
        return openAI(from: obj)
    }

    private static func parseAnthropic(responseBody: Data, contentType: String?) -> GatewayParsedUsage {
        if isSSE(contentType, body: responseBody) {
            var merged = GatewayParsedUsage()
            for obj in sseJSONObjects(responseBody) {
                applyAnthropic(obj, into: &merged)
            }
            return merged
        }
        guard let obj = lastJSONObject(in: responseBody) else { return GatewayParsedUsage() }
        var merged = GatewayParsedUsage()
        applyAnthropic(obj, into: &merged)
        return merged
    }

    private static func parseGemini(responseBody: Data, contentType: String?) -> GatewayParsedUsage {
        if isSSE(contentType, body: responseBody) {
            var last = GatewayParsedUsage()
            for obj in sseJSONObjects(responseBody) {
                let piece = gemini(from: obj)
                if piece.inputTokens != nil || piece.outputTokens != nil { last = piece }
                else if let model = piece.model { last.model = model }
            }
            return last
        }
        guard let obj = lastJSONObject(in: responseBody) else { return GatewayParsedUsage() }
        return gemini(from: obj)
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

    private static func applyAnthropic(_ obj: [String: Any], into r: inout GatewayParsedUsage) {
        let type = obj["type"] as? String
        if type == "message_start", let message = JSONValue.object(obj["message"]) {
            r.model = JSONValue.string(message["model"]) ?? r.model
            if let usage = JSONValue.object(message["usage"]) {
                applyAnthropicUsage(usage, into: &r, outputOnly: false)
            }
            return
        }
        if type == "message_delta", let usage = JSONValue.object(obj["usage"]) {
            applyAnthropicUsage(usage, into: &r, outputOnly: true)
            return
        }
        if let model = JSONValue.string(obj["model"]) { r.model = model }
        if let usage = JSONValue.object(obj["usage"]) {
            applyAnthropicUsage(usage, into: &r, outputOnly: false)
        }
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

    func result(requestBody: Data, contentType: String?) -> GatewayParsedUsage {
        lock.lock()
        if sse, !eventBuf.isEmpty {
            parseSSEEvent(eventBuf)
            eventBuf.removeAll(keepingCapacity: true)
        }
        var parsed = lastUsage
        let json = jsonBuf
        let isSSE = sse
        lock.unlock()
        if !isSSE {
            parsed = GatewayUsageParser.parse(
                api: api,
                requestBody: requestBody,
                responseBody: json,
                contentType: contentType ?? self.contentType
            )
        } else if parsed.model == nil {
            let fromRequest = GatewayUsageParser.parse(
                api: api,
                requestBody: requestBody,
                responseBody: Data(),
                contentType: contentType ?? self.contentType
            )
            parsed.model = fromRequest.model
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
            lastUsage = merge(lastUsage, parseObject(obj))
        }
    }

    private func parseObject(_ obj: [String: Any]) -> GatewayParsedUsage {
        let encoded = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return GatewayUsageParser.parse(
            api: api,
            requestBody: Data(),
            responseBody: encoded,
            contentType: "application/json"
        )
    }

    private func merge(_ base: GatewayParsedUsage, _ piece: GatewayParsedUsage) -> GatewayParsedUsage {
        var out = base
        if piece.model != nil { out.model = piece.model }
        if piece.inputTokens != nil { out.inputTokens = piece.inputTokens }
        if piece.outputTokens != nil { out.outputTokens = piece.outputTokens }
        if piece.cacheReadTokens != nil { out.cacheReadTokens = piece.cacheReadTokens }
        if piece.cacheWriteTokens != nil { out.cacheWriteTokens = piece.cacheWriteTokens }
        return out
    }
}
