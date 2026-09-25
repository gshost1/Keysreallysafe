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

    let listener: LoopbackListener
    private let service: KeysService

    var boundPort: UInt16 { listener.port }

    init(service: KeysService, port: UInt16 = GatewayListener.port) throws {
        self.service = service
        self.listener = try LoopbackListener(
            port: port, acceptLabel: "keysreallysafe.gateway.accept", workLabel: "keysreallysafe.gateway",
            ioTimeoutSeconds: Self.ioTimeoutSeconds, maxConcurrent: Self.maxConcurrent
        )
    }

    func start() {
        listener.start { [weak self] client in
            self?.serve(client: client)
        }
    }

    func stop() { listener.stop() }

    private func serve(client: Int32) {
        switch HTTPFrame.read(fd: client, bodyCap: Self.bodyCap) {
        case .tooLarge:
            Self.writeJSON(fd: client, status: 413, object: ["error": "payload too large"])
            // Closing with unread bytes in the receive buffer makes the kernel send RST, and the
            // client then sees a dropped connection instead of the 413. Drain briefly first.
            Self.drain(fd: client)
            return
        case .bad:
            Self.writeJSON(fd: client, status: 400, object: ["error": "bad request"])
            return
        case .unsupported:
            Self.writeJSON(fd: client, status: 501, object: ["error": "unsupported transfer-encoding"])
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
            Self.writeJSON(fd: client, status: 403, object: ["error": "forbidden"])
            return
        }
        guard let keyName = request.keyName, (try? KeyName.validate(keyName)) != nil else {
            Self.writeJSON(fd: client, status: 404, object: ["error": "not_found"])
            return
        }
        // Loopback headers say where a browser request came from; they say nothing about a native
        // local process. Every caller must hold either a long-lived client capability (ksfc_)
        // or a task grant (ksf_), presented where the SDK would put the provider key.
        let (grantToken, rawQuery) = Self.extractGrantToken(headers: request.headers, rawQuery: request.rawQuery)
        var gatewayClient: GatewayClient?
        if grantToken == nil {
            switch service.authorizeGatewayClient(
                name: keyName, headers: request.headers, method: request.method, rest: request.rest
            ) {
            case .allowed(let c):
                gatewayClient = c
            case .denied(let reason):
                service.recordGatewayDenial(name: keyName, reason: reason)
                Self.writeJSON(fd: client, status: 401, object: [
                    "error": "client_required",
                    "hint": "issue one with: keys grant \(keyName) --task \"...\" (temporary) or keys client issue \(keyName) (long-lived)",
                ])
                return
            }
        }
        guard let target = service.lookupGateway(name: keyName) else {
            Self.writeJSON(fd: client, status: 404, object: [
                "error": "not_found",
                "message": "no key \(keyName) with the gateway on; run: keys grant \(keyName) --task \"...\"",
            ])
            return
        }
        var grant: Grant?
        if grantToken != nil {
            switch service.authorizeGateway(token: grantToken, target: target, method: request.method, rest: request.rest) {
            case .success(let g):
                grant = g
            case .failure(let denial):
                service.recordGatewayDenial(name: keyName, reason: denial.code)
                Self.writeJSON(fd: client, status: denial.status, object: [
                    "error": denial.code,
                    "message": denial.message,
                    "key": keyName,
                    "provider": target.provider.id,
                    "host": target.host,
                ].merging(denial.details) { current, _ in current })
                return
            }
        }
        if let gatewayClient { service.noteGatewayClientUse(gatewayClient) }
        let path = GatewayPath.join(prefix: target.provider.pathPrefix, rest: request.rest)
        var headers = request.headers.filter { !Self.dropIncoming.contains($0.key.lowercased()) }
        headers["Host"] = target.host
        guard var urlRequest = target.provider.upstreamRequest(
            host: target.host, path: path, query: rawQuery, method: request.method, headers: headers,
            secret: target.secret, timeout: Self.resourceTimeout
        ) else {
            Self.writeJSON(fd: client, status: 400, object: ["error": "bad request"])
            return
        }
        urlRequest.httpBody = request.body

        // Vercel's native evaluation protocol differs from its OpenAI-compatible
        // /v1 endpoints. Keep the extra parser scoped to this provider and path.
        let evaluation = target.provider.id == "vercel-ai-gateway" && path == "/v4/ai/evaluation-model"
        let directEvaluation = target.provider.id == "typesafe" && path == "/v1/systemone"
        let usageAPI = evaluation ? "vercel-evaluation" : directEvaluation ? "typesafe-systemone" :
            target.provider.api == "typesafe-systemone" ? "other" : target.provider.api
        let tee = GatewayTee(api: usageAPI)
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
            Self.writeJSON(fd: client, status: 502, object: ["error": "upstream_error"])
        }
        let parsed = tee.result(
            requestBody: request.body,
            requestModel: evaluation ? request.headers["ai-model-id"] : nil
        )
        do {
            try service.recordGatewayUsage(
                GatewayUsageRow(
                    ts: UTC.iso(Date()),
                    key: target.name,
                    provider: target.provider.id,
                    // The model can come from the caller's request body; cap it so a local
                    // client cannot store arbitrary text in the catalog and the dashboard.
                    model: parsed.model.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(128))) },
                    inputTokens: parsed.inputTokens,
                    outputTokens: parsed.outputTokens,
                    cacheReadTokens: parsed.cacheReadTokens,
                    cacheWriteTokens: parsed.cacheWriteTokens,
                    status: status,
                    durationMs: durationMs,
                    requestId: proxy.requestId,
                    reportedCostUsdTicks: (200..<300).contains(status) ? parsed.reportedCostUsdTicks : nil
                ),
                grantId: grant?.id
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

    /// Headers a caller may put a grant token in, where its SDK would put the provider key.
    /// `dropIncoming` strips every one of them, so a token never reaches the provider.
    static let grantHeaders = ["authorization", "x-api-key", "x-goog-api-key", "api-key", "x-ksf-grant"]

    /// Grant token from any auth-style header, or Gemini's `?key=`. Every token-bearing `key` is
    /// removed from the returned query, even when a header carried the grant, so none reaches the
    /// provider.
    static func extractGrantToken(headers: [String: String], rawQuery: String) -> (String?, String) {
        var kept: [String] = []
        var fromQuery: String?
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = (String(kv[0]).removingPercentEncoding ?? String(kv[0])).lowercased()
            if kv.count == 2, name == "key" {
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if GrantToken.looksLikeToken(v) {
                    fromQuery = v
                    continue
                }
            }
            kept.append(String(pair))
        }
        let query = fromQuery == nil ? rawQuery : kept.joined(separator: "&")
        for name in grantHeaders {
            guard var value = headers[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            if name == "authorization" {
                let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 { value = String(parts[1]).trimmingCharacters(in: .whitespaces) }
            }
            if GrantToken.looksLikeToken(value) { return (value, query) }
        }
        return (fromQuery, query)
    }

    private static let dropIncoming = Set(grantHeaders).union([
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection",
        "host", "content-length", "accept-encoding", "x-ksf-token", "x-ksf-client",
    ])

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

    @discardableResult
    static func writeJSON(fd: Int32, status: Int, object: [String: Any]) -> Bool {
        var headers = ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"]
        if status == 401 { headers["WWW-Authenticate"] = "Bearer realm=\"keysreallysafe-gateway\"" }
        let body = (try? JSONValue.data(object)) ?? Data("{}".utf8)
        return HTTPFrame.write(fd: fd, status: status, headers: headers, body: body)
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
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
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
        if !HTTPFrame.writeAll(fd: clientFD, data) {
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
        var head = "HTTP/1.1 \(status) \(HTTPFrame.reason(status))\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        return HTTPFrame.writeAll(fd: clientFD, Data(head.utf8))
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
