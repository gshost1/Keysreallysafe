import Foundation

/// The `keys mcp` stdio server: newline-delimited compact JSON-RPC 2.0 on stdout,
/// every diagnostic on stderr. The line source, byte writer, stderr sink and tool
/// registry are injected, so the whole loop runs in-process in a test (the
/// `UsageImportRun.run` precedent); `McpCommand` only wires the real stdio.
struct MCPServer {
    /// The legacy MCP era this server speaks, oldest first. A dual-era client probes
    /// with `server/discover` first; answering -32601 is the documented fallback
    /// that brings it back to `initialize`.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    /// What an unsupported client version is negotiated to: the newest supported.
    static let newestProtocolVersion = supportedProtocolVersions.last!
    /// The per-line byte cap. A line at or under it is served; one above it is
    /// refused with `oversizeLineMessage` instead of being read as a frame.
    static let maxLineBytes = 4 * 1024 * 1024
    /// The documented plain error for an oversized line (VAL-MCP-TRANSPORT-006).
    static let oversizeLineMessage = "the line exceeds the \(maxLineBytes / 1024 / 1024) MiB per-message limit; send one smaller message"
    /// The server name MCP clients see, the same constant the registration writes.
    static let serverName = "keysrs"
    /// The frozen `instructions` string (VAL-MCP-INSTRUCTIONS-002 pins it byte for
    /// byte): the preamble line plus the six rules, LF-joined, no trailing newline.
    /// It names tools later missions add; that is deliberate.
    static let instructions = """
Keysrs is the local API-key vault on this Mac. When using its tools, follow these rules:
1. Never open or read .env files yourself; use the scan_project tool instead.
2. Ask the user before importing keys or requesting a grant.
3. Prefer the gateway token over raw keys.
4. If no key exists, ask the user to run `keys add` in their own terminal; the agent never types a key.
5. After a failure, offer send_feedback but never send it.
6. Never print tokens back to the user unless they ask.
"""

    private let writeBytes: (Data) -> Void
    private let note: (String) -> Void
    private let registry: MCPToolRegistry
    private var handshook = false

    init(write: @escaping (Data) -> Void, note: @escaping (String) -> Void, registry: MCPToolRegistry) {
        self.writeBytes = write
        self.note = note
        self.registry = registry
    }

    /// Serves one line source to its end; stdin EOF in production, a scripted
    /// transcript in a test.
    mutating func run(next: () -> String?) {
        while let line = next() { serve(line) }
    }

    /// One line of input, one message. No path out of here terminates the process.
    mutating func serve(_ raw: String) {
        // CRLF-tolerant: strip one trailing CR before anything else.
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard line.utf8.count <= Self.maxLineBytes else {
            emit(failure: nil, code: -32600, message: Self.oversizeLineMessage)
            return
        }

        let decoded: Any
        do {
            // Fragments allowed on purpose: `5`, "x" or `true` on a line parses and
            // is then rejected as not a request object (-32600), not a parse error.
            decoded = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        } catch {
            emit(failure: nil, code: -32700, message: "the line is not valid JSON")
            return
        }
        guard let object = decoded as? [String: Any] else {
            // Batching was removed from the protocol; an array is an invalid request.
            if decoded is [Any] {
                emit(failure: nil, code: -32600, message: "batching is not supported; send one message per line")
            } else {
                emit(failure: nil, code: -32600, message: "not a JSON-RPC request object")
            }
            return
        }

        // `id` absent means notification; `id` null is a request whose id is null.
        // Anything else a string or number cannot be must not be echoed back.
        let hasID = object.keys.contains("id")
        var id: Any? = nil
        if hasID {
            let raw = object["id"]!
            if raw is NSNull { id = NSNull() }
            else if raw is String { id = raw }
            else if let number = raw as? NSNumber, !Self.isBoolean(number) { id = number }
            else {
                emit(failure: nil, code: -32600, message: "id must be a string or a number")
                return
            }
        }

        guard object["jsonrpc"] as? String == "2.0" else {
            emit(failure: id, code: -32600, message: "jsonrpc must be \"2.0\"")
            return
        }
        guard let method = object["method"] as? String else {
            emit(failure: id, code: -32600, message: "a request needs a string method")
            return
        }

        // Notifications never get a response, known or unknown: `notifications/
        // initialized` and `notifications/cancelled` do nothing, everything else is
        // dropped. A notification-shaped method carrying an id falls through to the
        // request table below and answers -32601 like any unknown request method.
        if !hasID { return }

        if method == "initialize" {
            serveInitialize(id: id, params: object["params"])
            return
        }
        // Requests before the handshake are refused, ping included; after it,
        // tools are served without waiting for notifications/initialized.
        guard handshook else {
            emit(failure: id, code: -32600, message: "initialize before sending other requests")
            return
        }
        switch method {
        case "ping":
            emit(success: id, result: [:])
        case "tools/list":
            emit(success: id, result: ["tools": registry.tools.map { $0.jsonObject() }])
        case "tools/call":
            serveToolsCall(id: id, params: object["params"])
        default:
            emit(failure: id, code: -32601, message: "unknown method: \(Self.echoed(method))")
        }
    }

    /// A JSON `true`/`false` parses as an NSNumber; ids and errors must never
    /// confuse the two (the `JSONValue.bool` CFBoolean check).
    private static func isBoolean(_ any: Any) -> Bool {
        if let number = any as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return false
    }

    /// Client-supplied names are echoed capped, so a hostile string cannot balloon
    /// the response or smuggle a path into it.
    private static func echoed(_ text: String) -> String {
        text.count <= 64 ? text : "\(text.prefix(64))…"
    }

    private mutating func serveInitialize(id: Any?, params: Any?) {
        guard let params = params as? [String: Any] else {
            emit(failure: id, code: -32602, message: "initialize requires an object params")
            return
        }
        guard let requested = params["protocolVersion"] as? String else {
            emit(failure: id, code: -32602, message: "initialize requires a string protocolVersion")
            return
        }
        // A failed handshake never opens the session; a second initialize is an
        // idempotent re-answer.
        handshook = true
        let negotiated = Self.supportedProtocolVersions.contains(requested) ? requested : Self.newestProtocolVersion
        emit(success: id, result: [
            "protocolVersion": negotiated,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": Self.serverName, "version": ProductAnalyticsConfiguration.appVersion],
            "instructions": Self.instructions,
        ])
    }

    private mutating func serveToolsCall(id: Any?, params: Any?) {
        guard let params = params as? [String: Any] else {
            emit(failure: id, code: -32602, message: "tools/call requires an object params")
            return
        }
        guard let name = params["name"] as? String, !name.isEmpty else {
            emit(failure: id, code: -32602, message: "tools/call requires a tool name")
            return
        }
        var arguments: [String: Any] = [:]
        if let raw = params["arguments"], !(raw is NSNull) {
            guard let object = raw as? [String: Any] else {
                emit(failure: id, code: -32602, message: "tools/call arguments must be an object")
                return
            }
            arguments = object
        }
        // An unknown name is a protocol error, not a tool failure: the model asked
        // for something that does not exist, and -32602 is the code for that.
        guard let group = registry.group(for: name) else {
            emit(failure: id, code: -32602, message: "unknown tool: \(Self.echoed(name))")
            return
        }
        do {
            let result = try group.call(name, arguments: arguments)
            emit(success: id, result: result.jsonObject())
        } catch {
            // Every tool failure is a result the model must see and self-correct on,
            // never a JSON-RPC error; the formatter scrubs it before it is text.
            let message = MCPToolErrorFormatter.message(for: error)
            emit(success: id, result: MCPToolResult.failure(message).jsonObject())
        }
    }

    private func emit(success id: Any?, result: Any) {
        frame(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func emit(failure id: Any?, code: Int, message: String) {
        frame(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    /// The only stdout write path: one compact sorted-key JSON message plus the
    /// newline, through the single injected writer, flushed by writing. Nothing
    /// else may ever write stdout.
    private func frame(_ envelope: [String: Any]) {
        do {
            var data = try JSONValue.data(envelope)
            data.append(0x0A)
            writeBytes(data)
        } catch {
            // A frame that cannot be encoded is the one reserved -32603. Say it in
            // prose on stderr and emit a hand-built envelope; never a partial line.
            note("could not encode a response frame: \(error.localizedDescription)")
            writeBytes(Data(
                #"{"error":{"code":-32603,"message":"internal frame fault"},"id":null,"jsonrpc":"2.0"}"#.utf8 + [0x0A]
            ))
        }
    }
}

/// The tool-error formatter: every tool-handler throw becomes a plain sentence a
/// model can read. AppError text is already user-facing prose, but it may carry an
/// internal filesystem path or a pid, so it is scrubbed; anything that is not an
/// AppError becomes one fixed sentence, because its description may name internal
/// types and stack shapes.
enum MCPToolErrorFormatter {
    /// The fixed sentence for an unexpected (non-AppError) throw.
    static let unexpectedFailureMessage = "the tool could not run; try again"
    static let mask = "[redacted]"

    static func message(for error: Error) -> String {
        if let error = error as? AppError { return scrub(error.description) }
        return unexpectedFailureMessage
    }

    /// Strips internal filesystem paths, pids and addresses from text on its way
    /// into a tool result. Prose and versions pass through unchanged, so the
    /// app-connection's exact sentences survive byte for byte.
    static func scrub(_ text: String) -> String {
        var out = text
        // pid mentions: "pid 4242", "process 4242" (the gatewayOwned wording).
        out = out.replacingOccurrences(
            of: #"(?i)\b(?:pid|process)[ #=]*\d+\b"#,
            with: "process \(mask)", options: .regularExpression
        )
        // Memory addresses, from crash text or sqlite pointers.
        out = out.replacingOccurrences(
            of: #"0x[0-9a-fA-F]{8,}"#,
            with: mask, options: .regularExpression
        )
        // POSIX paths of two components or more, absolute or relative, "~" allowed:
        // "/tmp/krs-…/catalog.db", ".build/debug/keys", "~/Library/…". Slashy URL
        // paths are masked with them; a tool error quoting the caller's own path
        // loses it too, which is the fail-safe direction for a scrubber.
        out = out.replacingOccurrences(
            of: #"(?:~)?(?:[A-Za-z0-9._\-]*/)+[A-Za-z0-9._\-]*"#,
            with: mask, options: .regularExpression
        )
        return out
    }
}

/// Splits one byte stream into the server's input lines: LF-delimited, a trailing
/// CR stripped, the final unterminated chunk still delivered, invalid UTF-8 decoded
/// lossily so a bad byte is a parse error rather than a crash. The cap stops an
/// endless LF-free stream from growing the buffer without bound: the run is handed
/// over as one oversized line the server refuses.
struct MCPLineSource {
    private var buffer: [UInt8] = []
    private var finished = false
    private let read: () -> Data?

    init(read: @escaping () -> Data?) { self.read = read }

    /// A finite transcript, exactly as a pipe would deliver it.
    init(data: Data) {
        buffer = [UInt8](data)
        read = { nil }
    }

    mutating func next() -> String? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<index])
                buffer.removeSubrange(0...index)
                return Self.decode(line)
            }
            if finished {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = []
                return Self.decode(line)
            }
            if buffer.count > MCPServer.maxLineBytes {
                let line = buffer
                buffer = []
                return Self.decode(line)
            }
            if let chunk = read() {
                buffer.append(contentsOf: chunk)
            } else {
                finished = true
            }
        }
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        var line = bytes
        if line.last == 0x0D { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
}
