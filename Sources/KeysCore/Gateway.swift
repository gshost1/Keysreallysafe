import Darwin
import Foundation

struct GatewayTarget {
    var name: String
    var secret: String
    var provider: Providers.Record
    var host: String
    var version: Int
}

final class GatewayListener: @unchecked Sendable {
    static let port: UInt16 = 12767
    static let bodyCap = 8 * 1024 * 1024
    static let connectTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 300
    static let maxConcurrent = 32
    static let ioTimeoutSeconds = 30

    private var listenFD: Int32 = -1
    private(set) var boundPort: UInt16
    private(set) var boundHost: String = BindPolicy.loopback
    private let service: KeysService
    private let acceptQueue = DispatchQueue(label: "keysreallysafe.gateway.accept")
    private let workQueue = DispatchQueue(label: "keysreallysafe.gateway", attributes: .concurrent)
    private var stopped = false
    private let lock = NSLock()
    private var activeConnections = 0

    init(service: KeysService, port: UInt16 = GatewayListener.port) throws {
        self.service = service
        let fd = try Self.bindListen(port: port)
        self.listenFD = fd
        self.boundPort = try Self.readPort(fd: fd)
        try Self.assertLoopback(fd: fd)
    }

    deinit { stop() }

    func start() {
        let fd = listenFD
        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenFD: Int32) {
        while !isStopped() {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFD, sa, &len)
                }
            }
            if client < 0 {
                if isStopped() { return }
                continue
            }
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            HTTPFrame.setDeadlines(fd: client, seconds: Self.ioTimeoutSeconds)
            lock.lock()
            let busy = activeConnections >= Self.maxConcurrent
            if !busy { activeConnections += 1 }
            lock.unlock()
            if busy {
                _ = Self.writeJSON(fd: client, status: 503, object: ["error": "too many connections"])
                Darwin.close(client)
                continue
            }
            workQueue.async { [weak self] in
                self?.serve(client: client)
            }
        }
    }

    private func serve(client: Int32) {
        defer {
            Darwin.close(client)
            lock.lock()
            activeConnections = max(0, activeConnections - 1)
            lock.unlock()
        }
        switch HTTPFrame.read(fd: client, bodyCap: Self.bodyCap) {
        case .tooLarge:
            _ = Self.writeJSON(fd: client, status: 413, object: ["error": "payload too large"])
            // Closing with unread bytes in the receive buffer makes the kernel send RST, and the
            // client then sees a dropped connection instead of the 413. Drain briefly first.
            Self.drain(fd: client)
            return
        case .bad:
            _ = Self.writeJSON(fd: client, status: 400, object: ["error": "bad request"])
            return
        case .lengthRequired:
            _ = Self.writeJSON(fd: client, status: 411, object: ["error": "length required"])
            return
        case .unsupported:
            _ = Self.writeJSON(fd: client, status: 501, object: ["error": "unsupported transfer-encoding"])
            return
        case .ok(let method, let target, let headers, let body):
            let (path, rawQuery) = Self.splitTarget(target)
            let (keyName, rest) = Self.splitKey(path)
            handle(
                Incoming(
                    method: method,
                    keyName: keyName,
                    rest: rest,
                    rawQuery: rawQuery,
                    headers: headers,
                    body: body
                ),
                client: client
            )
        }
    }

    private func handle(_ request: Incoming, client: Int32) {
        if !HTTPFrame.LoopbackOrigin.hostAllowed(request.headers["host"], port: boundPort)
            || !HTTPFrame.LoopbackOrigin.originAllowed(request.headers["origin"], port: boundPort)
            || !HTTPFrame.LoopbackOrigin.fetchSiteAllowed(request.headers["sec-fetch-site"])
        {
            _ = Self.writeJSON(fd: client, status: 403, object: ["error": "forbidden"])
            return
        }
        guard let keyName = request.keyName, (try? KeyName.validate(keyName)) != nil else {
            _ = Self.writeJSON(fd: client, status: 404, object: ["error": "not_found"])
            return
        }
        // Loopback headers say where a browser request came from; they say nothing about a native
        // local process. Every caller must hold a client capability issued for this key.
        let gatewayClient: GatewayClient
        switch service.authorizeGatewayClient(
            name: keyName, headers: request.headers, method: request.method, rest: request.rest
        ) {
        case .allowed(let c):
            gatewayClient = c
        case .denied(let reason):
            service.recordGatewayDenial(name: keyName, reason: reason)
            _ = Self.writeJSON(fd: client, status: 401, object: [
                "error": "client_required",
                "hint": "issue one with: keys client issue \(keyName)",
            ])
            return
        }
        guard let target = service.lookupGateway(name: keyName) else {
            _ = Self.writeJSON(fd: client, status: 404, object: ["error": "not_found"])
            return
        }
        service.noteGatewayClientUse(gatewayClient)
        let host = target.host
        let hostname = host.split(separator: ":").first.map(String.init) ?? host
        let scheme = BindPolicy.isLoopbackHostname(hostname) ? "http" : "https"
        let path = GatewayPath.join(prefix: target.provider.pathPrefix, rest: request.rest)
        var urlString = "\(scheme)://\(host)\(path)"
        if !request.rawQuery.isEmpty {
            urlString += "?" + request.rawQuery
        }
        guard let url = URL(string: urlString) else {
            _ = Self.writeJSON(fd: client, status: 400, object: ["error": "bad request"])
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Self.resourceTimeout
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            let lower = name.lowercased()
            if Self.dropIncoming.contains(lower) { continue }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue(host, forHTTPHeaderField: "Host")
        let auth = target.provider.authPrefix + target.secret
        urlRequest.setValue(auth, forHTTPHeaderField: target.provider.authHeader)

        let tee = GatewayTee(api: target.provider.api)
        let started = Date()
        let proxy = GatewayProxyTask(clientFD: client, tee: tee)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.resourceTimeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: proxy, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        proxy.sessionTask = task
        let connectWatch = DispatchWorkItem { [weak task] in
            if !proxy.hasResponse {
                task?.cancel()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.connectTimeout,
            execute: connectWatch
        )
        task.resume()
        proxy.wait()
        connectWatch.cancel()
        session.finishTasksAndInvalidate()

        let durationMs = Int((Date().timeIntervalSince(started) * 1000.0).rounded())
        let status = proxy.statusCode ?? 502
        if !proxy.wroteHead {
            _ = Self.writeJSON(fd: client, status: 502, object: ["error": "upstream_error"])
        }
        let parsed = tee.result(requestBody: request.body, contentType: proxy.contentType)
        do {
            try service.recordGatewayUsage(
                GatewayUsageRow(
                    ts: UTC.iso(Date()),
                    key: target.name,
                    provider: target.provider.id,
                    model: parsed.model,
                    inputTokens: parsed.inputTokens,
                    outputTokens: parsed.outputTokens,
                    cacheReadTokens: parsed.cacheReadTokens,
                    cacheWriteTokens: parsed.cacheWriteTokens,
                    status: status,
                    durationMs: durationMs,
                    requestId: proxy.requestId
                )
            )
        } catch {
            let line = "gateway usage persist failed for \(target.name): \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private struct Incoming {
        var method: String
        var keyName: String?
        var rest: String
        var rawQuery: String
        var headers: [String: String]
        var body: Data
    }

    private static let dropIncoming: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection",
        "host", "content-length", "authorization", "x-api-key", "x-goog-api-key",
        "api-key", "accept-encoding", "x-ksf-token", "x-ksf-client",
    ]

    /// Split on the first `?` in the raw target. Path/query bytes are not decoded.
    static func splitTarget(_ target: String) -> (String, String) {
        if let idx = target.firstIndex(of: "?") {
            return (String(target[..<idx]), String(target[target.index(after: idx)...]))
        }
        return (target, "")
    }

    /// Decode only the key-name segment. Upstream path bytes stay encoded.
    static func splitKey(_ path: String) -> (String?, String) {
        var p = path
        if p.hasPrefix("/") { p = String(p.dropFirst()) }
        if p.isEmpty { return (nil, "") }
        if let idx = p.firstIndex(of: "/") {
            let rawName = String(p[..<idx])
            let name = rawName.removingPercentEncoding ?? rawName
            var rest = String(p[p.index(after: idx)...])
            if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
            return (name, rest)
        }
        let name = p.removingPercentEncoding ?? p
        return (name, "")
    }

    /// Reads and discards what the client is still sending, bounded in bytes and time.
    static func drain(fd: Int32, maxBytes: Int = 4 * bodyCap, seconds: Int = 2) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Darwin.shutdown(fd, SHUT_WR)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while total < maxBytes {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            total += n
        }
    }

    static func writeJSON(fd: Int32, status: Int, object: [String: Any]) -> Bool {
        let body = (try? JSONValue.data(object)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 501: reason = "Not Implemented"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer realm=\"keysreallysafe-gateway\"\r\n" }
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        return writeRaw(fd: fd, payload)
    }

    static func writeRaw(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var written = 0
            let total = data.count
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            while written < total {
                let n = Darwin.write(fd, base + written, total - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    private static func bindListen(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw AppError.http("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(BindPolicy.loopback))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw AppError.http("bind 127.0.0.1:\(port) failed")
        }
        if Darwin.listen(fd, 32) != 0 {
            Darwin.close(fd)
            throw AppError.http("listen failed")
        }
        return fd
    }

    private static func readPort(fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard rc == 0 else { throw AppError.http("getsockname failed") }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func assertLoopback(fd: Int32) throws {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let ip = String(cString: inet_ntoa(addr.sin_addr))
        if ip != BindPolicy.loopback {
            Darwin.close(fd)
            throw AppError.refusedBind(ip)
        }
    }
}

private final class GatewayProxyTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let dropOutgoing: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection",
    ]

    let clientFD: Int32
    let tee: GatewayTee
    let sema = DispatchSemaphore(value: 0)
    weak var sessionTask: URLSessionTask?
    private let lock = NSLock()
    private var done = false
    private(set) var wroteHead = false
    private(set) var hasResponse = false
    private(set) var statusCode: Int?
    private(set) var contentType: String?
    private(set) var requestId: String?

    init(clientFD: Int32, tee: GatewayTee) {
        self.clientFD = clientFD
        self.tee = tee
    }

    func wait() {
        sema.wait()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        hasResponse = true
        let http = response as? HTTPURLResponse
        statusCode = http?.statusCode
        contentType = http?.value(forHTTPHeaderField: "Content-Type")
        requestId = Self.requestId(from: http)
        if let contentType { tee.setContentType(contentType) }
        if !wroteHead {
            wroteHead = writeHead(http)
            if !wroteHead {
                sessionTask?.cancel()
                lock.unlock()
                finish()
                completionHandler(.cancel)
                return
            }
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !GatewayListener.writeRaw(fd: clientFD, data) {
            sessionTask?.cancel()
            finish()
            return
        }
        tee.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    static func requestId(from http: HTTPURLResponse?) -> String? {
        guard let http else { return nil }
        for name in ["request-id", "x-request-id"] {
            if let value = http.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
               !value.isEmpty, value.count <= 128
            {
                return value
            }
        }
        return nil
    }

    private func writeHead(_ http: HTTPURLResponse?) -> Bool {
        let status = http?.statusCode ?? 502
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var headers: [(String, String)] = []
        var skipContentLength = false
        if let http {
            for (key, value) in http.allHeaderFields {
                let name = String(describing: key)
                let lower = name.lowercased()
                if Self.dropOutgoing.contains(lower) {
                    if lower == "transfer-encoding", String(describing: value).lowercased().contains("chunked") {
                        skipContentLength = true
                    }
                    continue
                }
                if lower == "content-type", String(describing: value).lowercased().contains("event-stream") {
                    skipContentLength = true
                }
                headers.append((name, String(describing: value)))
            }
        }
        if skipContentLength {
            headers.removeAll { $0.0.lowercased() == "content-length" }
        }
        headers.append(("Connection", "close"))
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        return GatewayListener.writeRaw(fd: clientFD, Data(head.utf8))
    }

    private func finish() {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        sema.signal()
    }
}
