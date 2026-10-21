import Darwin
import Foundation

// The Mac half of the relay (docs/relay.md). `keys relay` opens one outbound
// WebSocket to a Worker the user deployed, receives framed HTTP requests from
// it and replays each one against the local gateway on loopback, streaming the
// response back frame by frame. Nothing here reads a provider key or makes a
// grant decision: the gateway on 127.0.0.1 does both, exactly as for a local
// caller. Relay/src/worker.js is the other end and must keep matching.

enum RelayProtocol {
    static let version = "1"
    static let connectPath = "/connect"
    static let protocolHeader = "X-Keysrs-Relay-Protocol"
    /// Largest body chunk per frame; Cloudflare caps a WebSocket message at 1 MiB.
    static let chunk = 64 * 1024
    /// Matches the gateway's own request body cap, so the relay refuses nothing the gateway
    /// would accept and buffers nothing it would refuse.
    static let bodyCap = GatewayListener.bodyCap
    /// The Worker sends no new request into a socket that has not pinged for 45 s (one and a
    /// half intervals; macSilenceMs in Relay/src/protocol.js), so this must stay well under it.
    static let pingInterval: TimeInterval = 30
    /// A relayed response may take as long as the gateway allows upstream, plus connect time.
    static let gatewayReadTimeoutSeconds = Int(GatewayListener.resourceTimeout) + Int(GatewayListener.connectTimeout)
    static let headCap = HTTPFrame.headerCap
    /// How long one response frame may wait for the transport before the replay gives up.
    static let sendTimeout: TimeInterval = 60
    /// Bounds on requests whose body is still arriving. The Worker does not check grants, so
    /// anyone with its URL can start uploads; what the Mac holds for them is capped in number,
    /// in bytes and in time, whatever the Worker does.
    static let maxBufferedRequests = 64
    static let maxBufferedBytes = 4 * bodyCap
    /// Longer than the Worker's own upload deadline (60 s), so a Worker that cancels is never
    /// second-guessed and one that does not still cannot park a request here.
    static let bufferTimeout: TimeInterval = 90
}

enum RelayFrameType: UInt8 {
    case request = 1
    case body = 2
    case end = 3
    case response = 4
    case cancel = 5
    case error = 6
}

/// One WebSocket message: a type byte, a big-endian 32-bit request id, the payload.
struct RelayFrame: Equatable {
    var type: RelayFrameType
    var id: UInt32
    var payload: Data = Data()

    func encoded() -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type.rawValue)
        var be = id.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func decode(_ data: Data) -> RelayFrame? {
        guard data.count >= 5, let type = RelayFrameType(rawValue: data[data.startIndex]) else { return nil }
        let idBytes = data[data.startIndex + 1..<data.startIndex + 5]
        let id = idBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return RelayFrame(type: type, id: id, payload: Data(data[(data.startIndex + 5)...]))
    }

    static func json(_ type: RelayFrameType, id: UInt32, _ object: [String: Any]) -> RelayFrame {
        RelayFrame(type: type, id: id, payload: (try? JSONValue.data(object)) ?? Data("{}".utf8))
    }
}

/// The shared secret between this Mac and its Worker. A Keysrs credential like the client
/// token: shown once, stored under its own Keychain service, never in a config file.
enum RelaySecret {
    static let prefix = "ksfr_"

    static func generate() -> String {
        prefix + Hex.encode(SecureRandom.bytes(24))
    }

    static func looksLikeSecret(_ value: String) -> Bool {
        value.hasPrefix(prefix) && value.count == prefix.count + 48
    }

    static func hint(_ secret: String) -> String {
        String(secret.suffix(4))
    }
}

enum RelayURL {
    /// The Worker's origin: https (http only for a loopback `wrangler dev`), a host, nothing else.
    static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty
        else {
            throw AppError.usage("the relay URL must look like https://keysrs-relay.<your-subdomain>.workers.dev")
        }
        if scheme == "http" {
            guard BindPolicy.isLoopbackHostname(host) else {
                throw AppError.usage("the relay URL must use https (http is allowed only for a local wrangler dev on 127.0.0.1)")
            }
        } else if scheme != "https" {
            throw AppError.usage("the relay URL must use https")
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw AppError.usage("the relay URL is the Worker's origin only, without a path, query or credentials")
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        guard let url = origin.url else { throw AppError.usage("invalid relay URL") }
        return url
    }

    static func connectURL(_ origin: URL) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = RelayProtocol.connectPath
        return components.url!
    }

    /// Where an agent points its SDK for `key`.
    static func baseURL(_ origin: URL, key: String) -> String {
        origin.absoluteString + "/" + key
    }
}

enum RelayMessage: Equatable {
    case binary(Data)
    case text(String)
}

/// One open WebSocket. Sends take a completion so a request can hand its chunks over in
/// order and wait for each before reading the next from the gateway.
protocol RelaySocket: AnyObject, Sendable {
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> RelayMessage
    func close()
}

extension RelaySocket {
    /// Blocks the calling thread until the frame is handed to the transport, or `timeout` has
    /// passed, which counts as a dead socket. Only for replay threads (a GCD queue), never for
    /// the async receive loop: a semaphore wait there would park a cooperative-pool thread.
    func sendBlocking(_ frame: RelayFrame, timeout: TimeInterval = RelayProtocol.sendTimeout) -> Bool {
        let sema = DispatchSemaphore(value: 0)
        let outcome = LockedValue(false)
        send(frame.encoded()) { error in
            outcome.set(error == nil)
            sema.signal()
        }
        guard sema.wait(timeout: .now() + timeout) == .success else { return false }
        return outcome.get()
    }

    /// Hands the frame to the transport and moves on; for one-off error frames whose failure
    /// is also the socket's failure, which the receive loop sees on its own.
    func sendDetached(_ frame: RelayFrame) {
        send(frame.encoded()) { _ in }
    }
}

final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}

struct RelayDialError: Error, CustomStringConvertible {
    /// HTTP status of a refused handshake, when the transport reported one.
    var status: Int?
    var message: String

    var description: String {
        switch status {
        case 401:
            return "the Worker refused the relay secret (401); run keys relay setup again, then `npx wrangler secret put RELAY_SECRET` with the new value"
        case 400:
            return "the Worker speaks another relay protocol (400); redeploy it from this checkout (cd Relay && npx wrangler deploy)"
        case .some(let s):
            return "the Worker answered \(s) instead of opening the relay: \(message)"
        case nil:
            return message
        }
    }
}

protocol RelayDialer: Sendable {
    func connect(url: URL, headers: [String: String]) async throws -> any RelaySocket
}

/// URLSession's WebSocket. A refused handshake only surfaces on first use, so the dialer
/// pings once before handing the socket over and reports the HTTP status when there is one.
final class URLSessionRelayDialer: RelayDialer {
    func connect(url: URL, headers: [String: String]) async throws -> any RelaySocket {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1024 * 1024
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            session.invalidateAndCancel()
            throw RelayDialError(status: status, message: error.localizedDescription)
        }
        return URLSessionRelaySocket(task: task, session: session)
    }
}

final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.data(data), completionHandler: completion)
    }

    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func receive() async throws -> RelayMessage {
        switch try await task.receive() {
        case .data(let data): return .binary(data)
        case .string(let text): return .text(text)
        @unknown default: throw RelayDialError(status: nil, message: "unknown WebSocket message type")
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

/// One relayed call: the request as the Worker framed it, replayed against the gateway.
final class RelayRequest: @unchecked Sendable {
    /// Never forwarded to the gateway: hop-by-hop, what the relay sets itself, and what
    /// Cloudflare adds about the agent's connection (stripped by the Worker too).
    static let dropHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "keep-alive", "te", "trailers",
        "upgrade", "proxy-authenticate", "proxy-authorization", "proxy-connection",
        "x-ksf-via", "x-real-ip", "cdn-loop", "true-client-ip",
    ]
    static let dropResponseHeaders: Set<String> = ["connection", "content-length", "transfer-encoding", "keep-alive"]

    let id: UInt32
    let method: String
    let target: String
    let headers: [(String, String)]
    private let lock = NSLock()
    private var body = Data()
    private var fd: Int32 = -1
    private var cancelled = false

    init?(id: UInt32, head: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: head)).flatMap(JSONValue.object),
              let method = JSONValue.string(object["method"]), Self.isToken(method), method.count <= 16,
              let target = JSONValue.string(object["target"]), target.hasPrefix("/"), target.count <= 8192,
              !target.utf8.contains(where: { $0 == 0x20 || Self.isLineBreakOrNul($0) })
        else { return nil }
        var headers: [(String, String)] = []
        for pair in (object["headers"] as? [Any]) ?? [] {
            guard let kv = pair as? [Any], kv.count == 2,
                  let name = (kv[0] as? String)?.lowercased(), let value = kv[1] as? String,
                  Self.isToken(name), !value.utf8.contains(where: Self.isLineBreakOrNul)
            else { return nil }
            if Self.dropHeaders.contains(name) || name.hasPrefix("cf-") || name.hasPrefix("x-forwarded-") { continue }
            headers.append((name, value))
        }
        self.id = id
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
    }

    /// Checked byte by byte: as Characters, "\r\n" is one grapheme and would slip past.
    static func isLineBreakOrNul(_ byte: UInt8) -> Bool {
        byte == 0x0D || byte == 0x0A || byte == 0x00
    }

    /// RFC 9110 token characters, which both HTTP methods and header names are made of.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || "!#$%&'*+-.^_`|~".utf8.contains(b)
        }
    }

    /// False once the body is over the cap; the request is then dropped.
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        body.append(chunk)
        return body.count <= RelayProtocol.bodyCap
    }

    /// The agent went away (or the Worker gave up): stop whatever the gateway is doing.
    func cancel() {
        lock.lock()
        cancelled = true
        let fd = self.fd
        lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Bytes of request body held so far.
    var bufferedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return body.count
    }

    /// The bytes written to the gateway: the request as received, re-homed on loopback.
    func requestBytes(port: UInt16) -> Data {
        lock.lock()
        let body = self.body
        lock.unlock()
        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "X-KSF-Via: relay\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Blocking: connects to the gateway, writes the request and streams the response
    /// back as frames. `send` returns false once the socket is gone, which ends the replay.
    func replay(port: UInt16, send: (RelayFrame) -> Bool) {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            _ = send(.json(.error, id: id, ["code": "gateway_unreachable", "message": "socket() failed on the Mac"]))
            return
        }
        var nosig: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        HTTPFrame.setDeadlines(fd: sock, seconds: RelayProtocol.gatewayReadTimeoutSeconds)
        lock.lock()
        if cancelled {
            lock.unlock()
            Darwin.close(sock)
            return
        }
        fd = sock
        lock.unlock()
        defer {
            lock.lock()
            fd = -1
            lock.unlock()
            Darwin.close(sock)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(BindPolicy.loopback))
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            _ = send(.json(.error, id: id, [
                "code": "gateway_unreachable",
                "message": "the gateway on 127.0.0.1:\(port) is not running on the Mac; open Keysrs.app or run keys dashboard",
            ]))
            return
        }
        guard HTTPFrame.writeAll(fd: sock, requestBytes(port: port)) else {
            if !isCancelled {
                _ = send(.json(.error, id: id, ["code": "gateway_write_failed", "message": "the gateway closed the connection before reading the request"]))
            }
            return
        }

        var buf = [UInt8](repeating: 0, count: RelayProtocol.chunk)
        var pending = Data()
        var headEnd: Range<Data.Index>?
        while pending.count < RelayProtocol.headCap {
            let n = Darwin.read(sock, &buf, buf.count)
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            if let range = pending.range(of: Data("\r\n\r\n".utf8)) {
                headEnd = range
                break
            }
        }
        guard let headEnd, let head = Self.parseHead(pending[pending.startIndex..<headEnd.lowerBound]) else {
            if !isCancelled {
                _ = send(.json(.error, id: id, ["code": "gateway_read_failed", "message": "the gateway sent no readable response"]))
            }
            return
        }
        guard send(.json(.response, id: id, ["status": head.status, "headers": head.headers.map { [$0.0, $0.1] }])) else { return }
        var leftover = Data(pending[headEnd.upperBound...])
        while !leftover.isEmpty {
            let chunk = leftover.prefix(RelayProtocol.chunk)
            guard send(RelayFrame(type: .body, id: id, payload: Data(chunk))) else { return }
            leftover.removeFirst(chunk.count)
        }
        while true {
            let n = Darwin.read(sock, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                if !isCancelled {
                    _ = send(.json(.error, id: id, ["code": "gateway_read_failed", "message": "the gateway stopped responding mid-body"]))
                }
                return
            }
            guard send(RelayFrame(type: .body, id: id, payload: Data(buf[0..<n]))) else { return }
        }
        _ = send(RelayFrame(type: .end, id: id))
    }

    /// Status line and headers of the gateway's response, minus what the Worker re-frames.
    static func parseHead(_ bytes: Data) -> (status: Int, headers: [(String, String)])? {
        guard let text = String(data: bytes, encoding: .isoLatin1) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]), (100...599).contains(status) else {
            return nil
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if dropResponseHeaders.contains(name.lowercased()) { continue }
            headers.append((name, value))
        }
        return (status, headers)
    }
}

/// Holds the Worker connection: dials, serves frames, reconnects with backoff until cancelled.
final class RelayClient: @unchecked Sendable {
    struct Options {
        var url: URL
        var secret: String
        var gatewayPort: UInt16 = GatewayListener.port
        var pingInterval: TimeInterval = RelayProtocol.pingInterval
        var maxBackoff: TimeInterval = 60
        /// A connection that stayed up this long resets the backoff.
        var stableAfter: TimeInterval = 60
        var maxBufferedRequests = RelayProtocol.maxBufferedRequests
        var maxBufferedBytes = RelayProtocol.maxBufferedBytes
        var bufferTimeout = RelayProtocol.bufferTimeout
    }

    /// A request whose END has not arrived, with when its REQUEST frame did. `seq` orders
    /// arrivals for eviction: the clock may stand still between two frames (it is injected
    /// in tests and coarse in general), so a timestamp alone cannot say which came first.
    private struct Buffered {
        var request: RelayRequest
        var since: Date
        var seq: UInt64
    }

    let options: Options
    let dialer: any RelayDialer
    /// Status lines for the terminal or log. Never given a token, a secret or a body.
    let log: @Sendable (String) -> Void
    let sleep: @Sendable (TimeInterval) async throws -> Void
    /// 0.8…1.2 by default; fixed in tests.
    let jitter: @Sendable () -> Double
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var buffering: [UInt32: Buffered] = [:]
    private var nextSeq: UInt64 = 0
    private var replaying: [UInt32: RelayRequest] = [:]
    /// When the last frame of any kind (pong included) arrived on the current socket.
    private var lastReceived = Date.distantPast
    private let replayQueue = DispatchQueue(label: "keysreallysafe.relay.replay", attributes: .concurrent)

    init(
        options: Options,
        dialer: any RelayDialer = URLSessionRelayDialer(),
        log: @escaping @Sendable (String) -> Void,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.options = options
        self.dialer = dialer
        self.log = log
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
    }

    var connectURL: URL { RelayURL.connectURL(options.url) }

    var connectHeaders: [String: String] {
        [
            "Authorization": "Bearer \(options.secret)",
            RelayProtocol.protocolHeader: RelayProtocol.version,
        ]
    }

    /// Delay before reconnect attempt number `failures` (1-based): 1, 2, 4 … capped, jittered.
    func backoff(failures: Int) -> TimeInterval {
        let base = min(options.maxBackoff, pow(2.0, Double(max(0, failures - 1))))
        return base * jitter()
    }

    /// Runs until the surrounding task is cancelled.
    func run() async {
        var failures = 0
        let host = options.url.host ?? options.url.absoluteString
        while !Task.isCancelled {
            let started = Date()
            do {
                let socket = try await dialer.connect(url: connectURL, headers: connectHeaders)
                log("connected to \(host); relaying requests to the gateway on 127.0.0.1:\(options.gatewayPort)")
                try await serve(socket)
            } catch let error as RelayDialError {
                log("\(error)")
            } catch is CancellationError {
                break
            } catch {
                log("connection to \(host) lost: \(error.localizedDescription)")
            }
            if Task.isCancelled { break }
            if Date().timeIntervalSince(started) >= options.stableAfter { failures = 0 }
            failures += 1
            let delay = backoff(failures: failures)
            log("reconnecting in \(Int(delay.rounded()))s")
            do { try await sleep(delay) } catch { break }
        }
    }

    /// Reads frames until the socket fails. Every request still open when it does is dropped.
    func serve(_ socket: any RelaySocket) async throws {
        lock.withLock { lastReceived = now() }
        // The keepalive doubles as the liveness check. A socket that is half-open after sleep,
        // a NAT drop or a Wi-Fi roam accepts sends and never delivers anything, so silence
        // for two ping intervals, or a ping the transport refuses, closes it here, which
        // fails the receive below and lands in the reconnect loop.
        let pinger = Task { [weak self, options, sleep] in
            while !Task.isCancelled {
                try await sleep(options.pingInterval)
                guard let self else { return }
                let silence = self.now().timeIntervalSince(self.lock.withLock { self.lastReceived })
                if silence > 2 * options.pingInterval {
                    self.log("nothing heard from the Worker for \(Int(silence.rounded()))s; reconnecting")
                    socket.close()
                    return
                }
                socket.sendText("ping") { [weak self] error in
                    guard error != nil, let self else { return }
                    self.log("keepalive ping failed; reconnecting")
                    socket.close()
                }
                self.expireStale(socket: socket)
            }
        }
        defer {
            pinger.cancel()
            dropAll()
            socket.close()
        }
        while true {
            try Task.checkCancellation()
            let message = try await socket.receive()
            lock.withLock { lastReceived = now() }
            switch message {
            case .text:
                continue
            case .binary(let data):
                if let frame = RelayFrame.decode(data) { handle(frame, socket: socket) }
            }
        }
    }

    /// Runs on the receive loop: nothing here may block on the transport.
    func handle(_ frame: RelayFrame, socket: any RelaySocket) {
        switch frame.type {
        case .request:
            guard let request = RelayRequest(id: frame.id, head: frame.payload) else {
                socket.sendDetached(.json(.error, id: frame.id, ["code": "bad_request_frame", "message": "the relay sent a malformed request head"]))
                return
            }
            // The Worker never reuses an id while a request is open, so a repeat means it has
            // forgotten the first one; the first must not keep running in its place.
            let stale = lock.withLock { () -> RelayRequest? in
                let old = buffering.removeValue(forKey: frame.id)?.request ?? replaying.removeValue(forKey: frame.id)
                nextSeq += 1
                buffering[frame.id] = Buffered(request: request, since: now(), seq: nextSeq)
                return old
            }
            stale?.cancel()
            expireStale(socket: socket)
            enforceBufferBounds(socket: socket)
        case .body:
            guard let request = lock.withLock({ buffering[frame.id]?.request }) else { return }
            if !request.append(frame.payload) {
                lock.withLock { _ = buffering.removeValue(forKey: frame.id) }
                socket.sendDetached(.json(.error, id: frame.id, ["code": "payload_too_large", "message": "request body over \(RelayProtocol.bodyCap) bytes"]))
                return
            }
            enforceBufferBounds(socket: socket)
        case .end:
            guard let request = lock.withLock({ buffering.removeValue(forKey: frame.id)?.request }) else { return }
            lock.withLock { replaying[frame.id] = request }
            replayQueue.async { [weak self] in
                request.replay(port: self?.options.gatewayPort ?? GatewayListener.port) { frame in
                    !request.isCancelled && socket.sendBlocking(frame)
                }
                // Only this request's own entry: a newer request may own the id by now.
                self?.lock.withLock {
                    if self?.replaying[frame.id] === request { self?.replaying.removeValue(forKey: frame.id) }
                }
            }
        case .cancel:
            let request = lock.withLock { buffering.removeValue(forKey: frame.id)?.request ?? replaying[frame.id] }
            request?.cancel()
        case .response, .error:
            break
        }
    }

    /// Drops uploads whose END never came within the buffer timeout.
    private func expireStale(socket: any RelaySocket) {
        let cutoff = now().addingTimeInterval(-options.bufferTimeout)
        let expired = lock.withLock { () -> [UInt32] in
            let ids = buffering.filter { $0.value.since < cutoff }.map(\.key)
            for id in ids { buffering.removeValue(forKey: id) }
            return ids
        }
        for id in expired {
            socket.sendDetached(.json(.error, id: id, ["code": "upload_timeout", "message": "the request body did not finish arriving at the Mac within \(Int(options.bufferTimeout))s"]))
        }
    }

    /// Evicts the oldest unfinished uploads until count and bytes are within bounds.
    private func enforceBufferBounds(socket: any RelaySocket) {
        let evicted = lock.withLock { () -> [UInt32] in
            var ids: [UInt32] = []
            var bytes = buffering.values.reduce(0) { $0 + $1.request.bufferedBytes }
            while buffering.count > options.maxBufferedRequests || bytes > options.maxBufferedBytes,
                  let oldest = buffering.min(by: { $0.value.seq < $1.value.seq })
            {
                bytes -= oldest.value.request.bufferedBytes
                buffering.removeValue(forKey: oldest.key)
                ids.append(oldest.key)
            }
            return ids
        }
        for id in evicted {
            socket.sendDetached(.json(.error, id: id, ["code": "relay_buffer_full", "message": "the Mac dropped this request: too many unfinished uploads are already buffered"]))
        }
    }

    private func dropAll() {
        let open = lock.withLock { () -> [RelayRequest] in
            let all = buffering.values.map(\.request) + Array(replaying.values)
            buffering.removeAll()
            replaying.removeAll()
            return all
        }
        for request in open { request.cancel() }
    }

    var inflightCount: Int { lock.withLock { buffering.count + replaying.count } }
}
