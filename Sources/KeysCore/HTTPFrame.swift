import Darwin
import Foundation

enum HTTPFrame {
    enum Read {
        case ok(method: String, target: String, headers: [String: String], body: Data)
        case bad
        case tooLarge
        case unsupported
    }

    static let headerCap = 65_536
    static let socketTimeoutSeconds: Int = 30

    static func setDeadlines(fd: Int32, seconds: Int = socketTimeoutSeconds) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func read(fd: Int32, bodyCap: Int) -> Read {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while data.count < headerCap {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return .bad }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                break
            }
        }
        guard let headerEnd else { return .bad }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        var leftover = Data(data[headerEnd.upperBound...])
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { return .bad }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return .bad }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .bad }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        var transferEncodings: [String] = []
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                contentLengths.append(String(value))
            } else if key == "transfer-encoding" {
                transferEncodings.append(String(value))
            }
            headers[String(key)] = String(value)
        }

        let te = transferEncodings.joined(separator: ",").lowercased()
        let isChunked = te.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "chunked" }
        if isChunked {
            if !contentLengths.isEmpty { return .bad }
            switch readChunkedBody(fd: fd, leftover: leftover, cap: bodyCap) {
            case .tooLarge: return .tooLarge
            case .failure: return .bad
            case .ok(let body):
                return .ok(method: method, target: target, headers: headers, body: body)
            }
        }
        if !te.isEmpty && te != "identity" {
            return .unsupported
        }
        if contentLengths.count > 1 { return .bad }
        let length: Int
        if let raw = contentLengths.first {
            guard let parsed = parseContentLength(raw) else { return .bad }
            length = parsed
        } else {
            length = 0
            if !leftover.isEmpty { return .bad }
        }
        if length > bodyCap { return .tooLarge }
        while leftover.count < length {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return .bad }
            if n == 0 { return .bad }
            leftover.append(contentsOf: buf[0..<n])
            if leftover.count > bodyCap { return .tooLarge }
        }
        if leftover.count < length { return .bad }
        return .ok(
            method: method,
            target: target,
            headers: headers,
            body: Data(leftover.prefix(length))
        )
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        // The reason phrase is optional (RFC 9110 §15); an unlisted upstream status goes without.
        default: return ""
        }
    }

    /// One complete `Connection: close` response.
    @discardableResult
    static func write(fd: Int32, status: Int, headers: [String: String], body: Data) -> Bool {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        return writeAll(fd: fd, payload)
    }

    static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var written = 0
            let total = data.count
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return total == 0 }
            while written < total {
                let n = Darwin.write(fd, base + written, total - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    /// Non-negative integer that fits in `Int`. Rejects signs, spaces, and overflow.
    static func parseContentLength(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if s.count > 1 && s.hasPrefix("0") { return nil }
        return Int(s)
    }

    enum LoopbackOrigin {
        static func hostAllowed(_ header: String?, port: UInt16) -> Bool {
            let h = (header ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
        }

        /// Browser `Origin` must be this process's loopback origin when present.
        static func originAllowed(_ origin: String?, port: UInt16) -> Bool {
            guard let origin, !origin.isEmpty else { return true }
            guard let url = URL(string: origin), url.scheme?.lowercased() == "http",
                  let host = url.host
            else { return false }
            let originPort = url.port ?? 80
            guard originPort == Int(port), BindPolicy.isLoopbackHostname(host) else { return false }
            return url.path.isEmpty || url.path == "/"
        }

        static func fetchSiteAllowed(_ site: String?) -> Bool {
            guard let site, !site.isEmpty else { return true }
            let s = site.lowercased()
            return s == "same-origin" || s == "none"
        }
    }

    private enum Chunked {
        case ok(Data)
        case tooLarge
        case failure
    }

    private static func readChunkedBody(fd: Int32, leftover: Data, cap: Int) -> Chunked {
        var pending = leftover
        var body = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        func need(_ n: Int) -> Bool {
            while pending.count < n {
                let r = Darwin.read(fd, &buf, buf.count)
                if r <= 0 { return false }
                pending.append(contentsOf: buf[0..<r])
                if body.count + pending.count > cap + 64 { return false }
            }
            return true
        }
        func readLine() -> String? {
            while true {
                if let range = pending.range(of: Data("\r\n".utf8)) {
                    let line = pending[pending.startIndex..<range.lowerBound]
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    return String(data: Data(line), encoding: .isoLatin1)
                }
                let r = Darwin.read(fd, &buf, buf.count)
                if r <= 0 { return nil }
                pending.append(contentsOf: buf[0..<r])
                if pending.count > cap + 1024 { return nil }
            }
        }
        while true {
            guard let line = readLine() else { return .failure }
            let sizePart = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? line
            guard let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return .failure
            }
            if size == 0 {
                _ = readLine()
                return .ok(body)
            }
            // Written so a huge hex size cannot overflow and trap before auth.
            if size > cap - body.count { return .tooLarge }
            if !need(size + 2) { return .failure }
            body.append(pending.prefix(size))
            pending.removeFirst(size)
            guard pending.count >= 2, pending[pending.startIndex] == 13, pending[pending.startIndex + 1] == 10 else {
                return .failure
            }
            pending.removeFirst(2)
        }
    }
}

/// A TCP listener on 127.0.0.1 and nowhere else, shared by the dashboard site and the gateway.
/// Each accepted connection gets socket deadlines and SO_NOSIGPIPE, is served on the work
/// queue, and is closed when `serve` returns.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    /// The bound address as getsockname reports it; init refuses anything but 127.0.0.1.
    let address: String
    private var fd: Int32
    private let acceptQueue: DispatchQueue
    private let workQueue: DispatchQueue
    private let ioTimeoutSeconds: Int
    private let maxConcurrent: Int?
    private let lock = NSLock()
    private var stopped = false
    private var active = 0

    /// Queue labels show up in process samples, so each listener keeps its own.
    init(
        port: UInt16, acceptLabel: String, workLabel: String,
        ioTimeoutSeconds: Int = HTTPFrame.socketTimeoutSeconds, maxConcurrent: Int? = nil
    ) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw AppError.http("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(BindPolicy.loopback))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let inUse = errno == EADDRINUSE
            Darwin.close(fd)
            throw AppError.http("bind 127.0.0.1:\(port) failed" + (inUse ? " (address in use; is Keysrs already running?)" : ""))
        }
        if Darwin.listen(fd, 32) != 0 {
            Darwin.close(fd)
            throw AppError.http("listen failed")
        }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let ip = String(cString: inet_ntoa(local.sin_addr))
        guard rc == 0 else {
            Darwin.close(fd)
            throw AppError.http("getsockname failed")
        }
        guard ip == BindPolicy.loopback else {
            Darwin.close(fd)
            throw AppError.refusedBind(ip)
        }
        self.fd = fd
        self.port = UInt16(bigEndian: local.sin_port)
        self.address = ip
        self.acceptQueue = DispatchQueue(label: acceptLabel)
        self.workQueue = DispatchQueue(label: workLabel, attributes: .concurrent)
        self.ioTimeoutSeconds = ioTimeoutSeconds
        self.maxConcurrent = maxConcurrent
    }

    deinit { stop() }

    func start(serve: @escaping @Sendable (Int32) -> Void) {
        let fd = self.fd
        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd, serve: serve)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = self.fd
        self.fd = -1
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

    private func acceptLoop(listenFD: Int32, serve: @escaping @Sendable (Int32) -> Void) {
        while !isStopped() {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if isStopped() { return }
                continue
            }
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            HTTPFrame.setDeadlines(fd: client, seconds: ioTimeoutSeconds)
            lock.lock()
            let busy = maxConcurrent.map { active >= $0 } ?? false
            if !busy { active += 1 }
            lock.unlock()
            if busy {
                HTTPFrame.write(
                    fd: client, status: 503,
                    headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                    body: Data(#"{"error":"too many connections"}"#.utf8)
                )
                Darwin.close(client)
                continue
            }
            workQueue.async { [weak self] in
                serve(client)
                Darwin.close(client)
                guard let self else { return }
                self.lock.lock()
                self.active = max(0, self.active - 1)
                self.lock.unlock()
            }
        }
    }
}

final class DenyRedirects: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Waits for one callback. On the main thread it spins the run loop, because the OpenRouter
/// timer and presence prompts run there and a plain semaphore would freeze the menu bar for
/// up to the whole timeout; elsewhere it blocks on a semaphore.
final class MainSafeWait<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let sema = DispatchSemaphore(value: 0)
    private var value: T?

    func finish(_ result: T) {
        lock.lock()
        value = result
        lock.unlock()
        sema.signal()
    }

    func wait() -> T {
        if !Thread.isMainThread { sema.wait() }
        while true {
            lock.lock()
            let result = value
            lock.unlock()
            if let result { return result }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

enum BlockingHTTP {
    /// One request on an ephemeral session with no cookies and no redirects (a redirect would
    /// carry an auth header elsewhere). The transport error is rethrown as is: each caller
    /// words it differently, and ProviderCheck scrubs the secret from it.
    static func send(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: DenyRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = MainSafeWait<(Data?, URLResponse?, Error?)>()
        session.dataTask(with: request) { data, response, error in
            done.finish((data, response, error))
        }.resume()
        let (data, response, error) = done.wait()
        if let error { throw error }
        guard let http = response as? HTTPURLResponse else { throw AppError.http("no HTTP response") }
        return (data ?? Data(), http)
    }
}
