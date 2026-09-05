import Darwin
import Foundation
import Security

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var serverPort: UInt16
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONValue.data(object)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    static func text(_ status: Int, _ body: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": type, "Cache-Control": "no-store"],
            body: Data(body.utf8)
        )
    }

    static func data(_ status: Int, _ body: Data, type: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": type, "Cache-Control": "no-store"],
            body: body
        )
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private(set) var boundPort: UInt16
    private(set) var boundHost: String = BindPolicy.loopback
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private let acceptQueue = DispatchQueue(label: "keysreallysafe.accept")
    private let workQueue = DispatchQueue(label: "keysreallysafe.http", attributes: .concurrent)
    private var stopped = false
    private let lock = NSLock()

    init(host: String = BindPolicy.loopback, port: UInt16 = 12765, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        guard BindPolicy.allowBind(host: host) else {
            throw AppError.refusedBind(host)
        }
        self.handler = handler
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

    var isBoundToLoopback: Bool { boundHost == BindPolicy.loopback }

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
            HTTPFrame.setDeadlines(fd: client)
            let port = boundPort
            workQueue.async { [handler] in
                Self.serve(client: client, port: port, handler: handler)
            }
        }
    }

    static let bodyCap = 1_000_000

    private static func serve(client: Int32, port: UInt16, handler: @Sendable (HTTPRequest) -> HTTPResponse) {
        defer { Darwin.close(client) }
        switch HTTPFrame.read(fd: client, bodyCap: bodyCap) {
        case .tooLarge:
            _ = writeResponse(fd: client, HTTPResponse.json(413, ["error": "payload too large"]))
            return
        case .bad:
            _ = writeResponse(fd: client, HTTPResponse.text(400, "bad request"))
            return
        case .lengthRequired:
            _ = writeResponse(fd: client, HTTPResponse.json(411, ["error": "length required"]))
            return
        case .unsupported:
            _ = writeResponse(fd: client, HTTPResponse.json(501, ["error": "unsupported transfer-encoding"]))
            return
        case .ok(let method, let target, let headers, let body):
            let (path, query) = splitTarget(target)
            var request = HTTPRequest(
                method: method,
                path: path,
                query: query,
                headers: headers,
                body: body,
                serverPort: port
            )
            request.serverPort = port
            let response = handler(request)
            _ = writeResponse(fd: client, response)
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

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        let decoded = target.removingPercentEncoding ?? target
        let pieces = decoded.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces.first ?? "/")
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        return (path, query)
    }

    private static func writeResponse(fd: Int32, _ response: HTTPResponse) -> Bool {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 501: reason = "Not Implemented"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        return payload.withUnsafeBytes { raw -> Bool in
            var written = 0
            let total = payload.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while written < total {
                let n = Darwin.write(fd, base + written, total - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    static func startOnAvailablePort(
        preferred: UInt16 = 12765,
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> LoopbackHTTPServer {
        var last: Error = AppError.http("could not bind loopback port")
        for port in preferred..<(preferred + 20) {
            do {
                return try LoopbackHTTPServer(host: BindPolicy.loopback, port: port, handler: handler)
            } catch {
                last = error
            }
        }
        throw last
    }
}

enum OriginToken {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var fallback = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&fallback, fallback.count)
            bytes = fallback
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func equal(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8)
        let bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in aa.indices { diff |= aa[i] ^ bb[i] }
        return diff == 0
    }
}

final class APIHandler: @unchecked Sendable {
    let service: KeysService
    let webRoot: URL
    let originToken: String

    init(service: KeysService, webRoot: URL, originToken: String = OriginToken.generate()) {
        self.service = service
        self.webRoot = webRoot
        self.originToken = originToken
        ModelPrices.loadAtStartup()
        Providers.loadAtStartup()
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        if !sameOriginOK(request) {
            return HTTPResponse.json(403, ["error": "forbidden"])
        }
        let path = normalizePath(request.path)
        if path.hasPrefix("/api/"), mutatingAPI(request.method), !tokenOK(request) {
            return HTTPResponse.json(403, ["error": "missing or bad token"])
        }
        do {
            switch (request.method, path) {
            case ("GET", "/api/spend"):
                return try spend(request)
            case ("GET", "/api/status"):
                return try liveStatus()
            case ("GET", "/api/doctor"):
                return try doctor()
            case ("GET", "/api/providers"):
                return providers()
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/gateway"):
                return try keysGateway(request, nameFrom: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/rotate"):
                return try keysRotate(request, nameFrom: p)
            case ("GET", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/events"):
                return try keysEvents(request, nameFrom: p)
            case ("GET", "/api/models"):
                return try models()
            case ("GET", "/api/keys"):
                return try keysList()
            case ("POST", "/api/keys"):
                return try keysAdd(request)
            case ("PATCH", let p) where p.hasPrefix("/api/keys/"):
                return try keysPatch(request, nameFrom: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/copy"):
                return try keysCopy(request, nameFrom: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/reveal"):
                return try keysReveal(request, nameFrom: p)
            case ("DELETE", let p) where p.hasPrefix("/api/keys/"):
                return try keysDelete(nameFrom: p)
            case ("POST", "/api/ingest"):
                return try ingest(request)
            case ("GET", _) where !path.hasPrefix("/api/"):
                return staticFile(path)
            case ("HEAD", _) where !path.hasPrefix("/api/"):
                var r = staticFile(path)
                r.body = Data()
                return r
            default:
                if path.hasPrefix("/api/") {
                    return HTTPResponse.json(405, ["error": "method_not_allowed"])
                }
                return HTTPResponse.text(404, "not found")
            }
        } catch let error as AppError {
            return mapError(error)
        } catch {
            return HTTPResponse.json(400, ["error": "bad_request"])
        }
    }

    private func mutatingAPI(_ method: String) -> Bool {
        method == "POST" || method == "PATCH" || method == "DELETE"
    }

    private func tokenOK(_ request: HTTPRequest) -> Bool {
        let header = request.headers["x-ksf-token"] ?? ""
        return OriginToken.equal(header, originToken)
    }

    private func sameOriginOK(_ request: HTTPRequest) -> Bool {
        HTTPFrame.LoopbackOrigin.hostAllowed(request.headers["host"], port: request.serverPort)
            && HTTPFrame.LoopbackOrigin.originAllowed(request.headers["origin"], port: request.serverPort)
    }

    private func liveStatus() throws -> HTTPResponse {
        HTTPResponse.json(200, try service.liveStatus().jsonObject())
    }

    private func doctor() throws -> HTTPResponse {
        HTTPResponse.json(200, try Doctor.report(service: service).jsonObject())
    }

    private func spend(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let range = SpendRange(rawValue: request.query["range"] ?? "month") else {
            return HTTPResponse.json(400, ["error": "invalid range"])
        }
        guard let by = SpendGroup(rawValue: request.query["by"] ?? "model") else {
            return HTTPResponse.json(400, ["error": "invalid by"])
        }
        if by == .hour && range != .today {
            return HTTPResponse.json(400, ["error": "invalid by"])
        }
        guard let source = SourceFilter(rawValue: request.query["source"] ?? "all") else {
            return HTTPResponse.json(400, ["error": "invalid source"])
        }
        if by == .project && source != .claude {
            return HTTPResponse.json(400, ["error": "by=project requires source=claude"])
        }
        try? service.ingestIfStale()
        let key = request.query["key"].flatMap { $0.isEmpty ? nil : $0 }
        let report = try service.spend(range: range, by: by, source: source, key: key)
        return HTTPResponse.json(200, report.jsonObject())
    }

    private func providers() -> HTTPResponse {
        HTTPResponse.data(200, Providers.rawJSON(), type: "application/json")
    }

    private func models() throws -> HTTPResponse {
        HTTPResponse.json(200, try service.modelsJSONObject())
    }

    private func keysList() throws -> HTTPResponse {
        let rows = try service.listJSONObject()
        let owner = service.gatewayOwnerPid()
        return HTTPResponse.json(200, [
            "keys": rows,
            "gateway_resets_on_restart": true,
            "gateway_owner_pid": owner.map { Int($0) } as Any? ?? NSNull(),
            "gateway_owned": service.thisProcessOwnsGateway(),
        ])
    }

    private func keysGateway(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/gateway")
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            return HTTPResponse.json(400, ["error": "invalid json"])
        }
        guard let enabled = JSONValue.bool(obj["enabled"]) else {
            return HTTPResponse.json(400, ["error": "enabled is required"])
        }
        var host: String?
        if obj.keys.contains("host") {
            if obj["host"] is NSNull {
                host = nil
            } else if let s = obj["host"] as? String {
                host = s
            } else {
                return HTTPResponse.json(400, ["error": "invalid host"])
            }
        }
        let row = try service.setGateway(name: name, enabled: enabled, host: host, caller: "dashboard")
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    private func keysRotate(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/rotate")
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            return HTTPResponse.json(400, ["error": "invalid json"])
        }
        guard let secret = JSONValue.string(obj["secret"]), !secret.isEmpty else {
            return HTTPResponse.json(400, ["error": "secret is required"])
        }
        let row = try service.rotate(name: name, secret: secret, caller: "dashboard")
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    private func keysEvents(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/events")
        var limit = 50
        if let raw = request.query["limit"], let n = Int(raw) {
            limit = n
        }
        let rows = try service.keyEvents(name: name, limit: limit)
        return HTTPResponse.json(200, [
            "events": rows.map { row -> [String: Any] in
                [
                    "id": row.id,
                    "ts": row.ts,
                    "name": row.name,
                    "action": row.action,
                    "caller": row.caller as Any? ?? NSNull(),
                    "detail": row.detail as Any? ?? NSNull(),
                ]
            }
        ])
    }

    private func keysPatch(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = String(path.dropFirst("/api/keys/".count))
        if name.isEmpty || name.contains("/") {
            return HTTPResponse.json(404, ["error": "not_found"])
        }
        try KeyName.validate(name)
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            return HTTPResponse.json(400, ["error": "invalid json"])
        }
        if obj["name"] != nil || obj["secret"] != nil {
            return HTTPResponse.json(400, ["error": "name and secret are immutable"])
        }
        let allowed: Set<String> = ["provider", "kind", "notes", "host"]
        if let unknown = obj.keys.first(where: { !allowed.contains($0) }) {
            return HTTPResponse.json(400, ["error": "unknown field \(unknown)"])
        }
        if obj.keys.contains("provider"), JSONValue.string(obj["provider"]) == nil {
            return HTTPResponse.json(400, ["error": "provider must be a string"])
        }
        if obj.keys.contains("kind"), JSONValue.string(obj["kind"]) == nil {
            return HTTPResponse.json(400, ["error": "kind must be a string"])
        }
        if obj.keys.contains("notes"), !(obj["notes"] is String) && !(obj["notes"] is NSNull) {
            return HTTPResponse.json(400, ["error": "notes must be a string"])
        }
        if obj.keys.contains("host"), obj["host"] is NSNull == false, JSONValue.string(obj["host"]) == nil {
            return HTTPResponse.json(400, ["error": "host must be a string"])
        }
        let provider = JSONValue.string(obj["provider"])
        let kind = JSONValue.string(obj["kind"])
        let notes: String?
        if obj.keys.contains("notes") {
            notes = JSONValue.string(obj["notes"]) ?? ""
        } else {
            notes = nil
        }
        let host: String?
        if obj.keys.contains("host") {
            host = JSONValue.string(obj["host"])
        } else {
            host = nil
        }
        let row = try service.patch(
            name: name,
            provider: provider,
            kind: kind,
            notes: notes,
            host: host,
            updateHost: obj.keys.contains("host"),
            caller: "dashboard"
        )
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    private func keysAdd(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            return HTTPResponse.json(400, ["error": "invalid json"])
        }
        guard let name = JSONValue.string(obj["name"]),
              let provider = JSONValue.string(obj["provider"]),
              let secret = JSONValue.string(obj["secret"])
        else {
            return HTTPResponse.json(400, ["error": "name, provider, and secret are required"])
        }
        let kind = JSONValue.string(obj["kind"]) ?? "runtime"
        let notes = JSONValue.string(obj["notes"]) ?? ""
        try service.add(name: name, provider: provider, kind: kind, notes: notes, secret: secret, caller: "dashboard")
        return HTTPResponse.json(201, ["ok": true, "name": name])
    }

    private func keysCopy(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        if !fetchSiteOK(request) {
            return HTTPResponse.json(403, ["error": "forbidden"])
        }
        let name = try extractName(path, suffix: "/copy")
        try service.copy(name: name, holdUntilWipe: false, caller: "dashboard")
        return HTTPResponse.json(200, ["ok": true, "wipes_in_s": Int(ClipboardWipe.seconds)])
    }

    private func keysReveal(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        if !fetchSiteOK(request) {
            return HTTPResponse.json(403, ["error": "forbidden"])
        }
        let name = try extractName(path, suffix: "/reveal")
        let secret = try service.reveal(name: name, caller: "dashboard")
        return HTTPResponse.json(200, ["name": name, "secret": secret])
    }

    /// Browsers send Sec-Fetch-Site; curl does not. Origin/Host remain the primary gate.
    private func fetchSiteOK(_ request: HTTPRequest) -> Bool {
        guard let site = request.headers["sec-fetch-site"] else { return true }
        let s = site.lowercased()
        return s == "same-origin" || s == "none"
    }

    private func keysDelete(nameFrom path: String) throws -> HTTPResponse {
        let name = String(path.dropFirst("/api/keys/".count))
        try KeyName.validate(name)
        try service.remove(name: name, caller: "dashboard")
        return HTTPResponse.json(200, ["ok": true, "name": name])
    }

    private func ingest(_ request: HTTPRequest) throws -> HTTPResponse {
        var source = Ingest.Source.all
        if !request.body.isEmpty,
           let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object),
           let raw = JSONValue.string(obj["source"]),
           let parsed = Ingest.Source(rawValue: raw)
        {
            source = parsed
        }
        let reports = try service.ingest(source)
        var payload: [String: Any] = [:]
        for (name, report) in reports {
            payload[name] = [
                "files": report.filesScanned,
                "inserted": report.rowsInserted,
                "updated": report.rowsUpdated,
                "skipped": report.skippedDupes,
                "errors": report.parseErrors,
            ]
        }
        return HTTPResponse.json(200, payload)
    }

    private func extractName(_ path: String, suffix: String) throws -> String {
        let rest = String(path.dropFirst("/api/keys/".count))
        guard rest.hasSuffix(suffix) else { throw AppError.usage("bad path") }
        let name = String(rest.dropLast(suffix.count))
        try KeyName.validate(name)
        return name
    }

    private func mapError(_ error: AppError) -> HTTPResponse {
        switch error {
        case .usage(let m):
            return HTTPResponse.json(400, ["error": m])
        case .notFound:
            return HTTPResponse.json(404, ["error": "not_found"])
        case .alreadyExists:
            return HTTPResponse.json(409, ["error": "already_exists"])
        case .gatewayOwned(let pid):
            return HTTPResponse.json(409, [
                "error": "gateway owned by another process",
                "gateway_owner_pid": Int(pid),
            ])
        case .authFailed:
            return HTTPResponse.json(403, ["error": "auth_failed"])
        case .keychain(let m):
            return HTTPResponse.json(500, ["error": m])
        default:
            return HTTPResponse.json(400, ["error": error.description])
        }
    }

    private func normalizePath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        if path != "/" && path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }

    private func staticFile(_ path: String) -> HTTPResponse {
        let relative: String
        if path == "/" {
            relative = "index.html"
        } else {
            relative = String(path.dropFirst())
        }
        if relative.contains("..") || relative.hasPrefix("/") || relative.contains("\0") {
            return HTTPResponse.text(403, "forbidden")
        }
        let root = webRoot.standardizedFileURL
        let full = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.path
        if full.path != rootPath && !full.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
            return HTTPResponse.text(403, "forbidden")
        }
        guard FileManager.default.isReadableFile(atPath: full.path),
              let data = try? Data(contentsOf: full)
        else {
            return HTTPResponse.text(404, "not found")
        }
        let body: Data
        if relative == "index.html" {
            body = injectOriginToken(data)
        } else {
            body = data
        }
        var response = HTTPResponse.data(200, body, type: mime(full.pathExtension))
        if full.pathExtension.lowercased() == "html" {
            response.headers["Content-Security-Policy"] =
                "default-src 'self'; connect-src 'self'; img-src 'self' data:"
            response.headers["Referrer-Policy"] = "no-referrer"
        }
        return response
    }

    /// Injects the per-launch origin token. Does not write `Web/index.html`.
    private func injectOriginToken(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let meta = "<meta name=\"ksf-token\" content=\"\(originToken)\">"
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            html.replaceSubrange(range, with: "  \(meta)\n</head>")
        } else if let range = html.range(of: "<head>", options: .caseInsensitive) {
            html.replaceSubrange(range, with: "<head>\n  \(meta)")
        } else {
            html = meta + html
        }
        return Data(html.utf8)
    }

    private func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
