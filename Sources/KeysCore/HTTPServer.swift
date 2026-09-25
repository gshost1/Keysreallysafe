import Darwin
import CoreFoundation
import Foundation

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
    let listener: LoopbackListener
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse

    var boundPort: UInt16 { listener.port }

    init(port: UInt16 = 12765, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        self.listener = try LoopbackListener(port: port, acceptLabel: "keysreallysafe.accept", workLabel: "keysreallysafe.http")
    }

    func start() {
        let port = boundPort
        listener.start { [handler] client in
            Self.serve(client: client, port: port, handler: handler)
        }
    }

    func stop() { listener.stop() }

    static let bodyCap = 1_000_000

    private static func serve(client: Int32, port: UInt16, handler: @Sendable (HTTPRequest) -> HTTPResponse) {
        let response: HTTPResponse
        switch HTTPFrame.read(fd: client, bodyCap: bodyCap) {
        case .tooLarge:
            response = HTTPResponse.json(413, ["error": "payload too large"])
        case .bad:
            response = HTTPResponse.text(400, "bad request")
        case .unsupported:
            response = HTTPResponse.json(501, ["error": "unsupported transfer-encoding"])
        case .ok(let method, let target, let headers, let body):
            let (path, query) = splitTarget(target)
            response = handler(HTTPRequest(
                method: method, path: path, query: query, headers: headers, body: body, serverPort: port
            ))
        }
        HTTPFrame.write(fd: client, status: response.status, headers: response.headers, body: response.body)
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
}

enum OriginToken {
    static func generate() -> String {
        Hex.encode(SecureRandom.bytes(32))
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
        service.analytics?.start()
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
            case ("GET", "/api/analytics"):
                return try analyticsStatus()
            case ("POST", "/api/analytics"), ("POST", "/api/analytics/clear"), ("POST", "/api/analytics/event"):
                return try analyticsRequest(request, path: path)
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
            case ("GET", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/clients"):
                return try clientsList(nameFrom: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/clients"):
                return try clientsIssue(request, nameFrom: p)
            case ("DELETE", let p) where p.hasPrefix("/api/keys/") && p.contains("/clients/"):
                return try clientsRevoke(pathWith: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/grants"):
                return try keysGrant(request, nameFrom: p)
            case ("POST", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/check"):
                return try keysCheck(nameFrom: p)
            case ("GET", let p) where p.hasPrefix("/api/keys/") && p.hasSuffix("/check"):
                return try keysLastCheck(nameFrom: p)
            case ("GET", "/api/grants"):
                return grantsList(request)
            case ("DELETE", "/api/grants"):
                return grantsRevokeAll(request)
            case ("DELETE", let p) where p.hasPrefix("/api/grants/"):
                return try grantRevoke(p)
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

    private func analyticsStatus() throws -> HTTPResponse {
        guard let analytics = service.analytics else {
            return HTTPResponse.json(503, ["error": "analytics_unavailable"])
        }
        return HTTPResponse.json(200, try analytics.status())
    }

    private func analyticsRequest(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        guard let analytics = service.analytics else {
            return HTTPResponse.json(503, ["error": "analytics_unavailable"])
        }
        guard request.body.count <= 1_024,
              let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HTTPResponse.json(400, ["error": "invalid_analytics_request"])
        }
        switch path {
        case "/api/analytics":
            guard Set(object.keys) == ["enabled", "consent_version"],
                  let enabled = object["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(),
                  let version = object["consent_version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.doubleValue == Double(ProductAnalytics.consentVersion) else {
                return HTTPResponse.json(400, ["error": "invalid_analytics_consent"])
            }
            try analytics.setEnabled(enabled.boolValue, consentVersion: version.intValue)
        case "/api/analytics/clear":
            guard object.isEmpty else { return HTTPResponse.json(400, ["error": "invalid_analytics_request"]) }
            try analytics.clear()
        case "/api/analytics/event":
            guard Set(object.keys) == ["event"], let value = object["event"] as? String,
                  ["view_usage", "view_chart", "view_keys"].contains(value),
                  let event = ProductAnalyticsEvent(rawValue: value) else {
                return HTTPResponse.json(400, ["error": "invalid_analytics_event"])
            }
            analytics.record(event)
            return HTTPResponse.json(200, ["ok": true])
        default:
            return HTTPResponse.json(404, ["error": "not_found"])
        }
        return try analyticsStatus()
    }

    private func tokenOK(_ request: HTTPRequest) -> Bool {
        let header = request.headers["x-ksf-token"] ?? ""
        return ConstantTime.equal(header.utf8, originToken.utf8)
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
        // A provider names the upstream a vault key routes to, which only gateway calls have.
        // Refusing it elsewhere keeps a stale filter from silently returning an empty local view.
        let provider = request.query["provider"].flatMap { $0.isEmpty ? nil : $0 }
        if provider != nil && source != .keys {
            return HTTPResponse.json(400, ["error": "provider requires source=keys"])
        }
        try? service.ingestIfStale()
        let key = request.query["key"].flatMap { $0.isEmpty ? nil : $0 }
        let report = try service.spend(range: range, by: by, source: source, key: key, provider: provider)
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

    private func clientsList(nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/clients")
        let now = Date()
        return HTTPResponse.json(200, [
            "clients": try service.gatewayClients(name: name).map { $0.jsonObject(now: now) }
        ])
    }

    /// The token appears in this one response and nowhere else.
    private func clientsIssue(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/clients")
        let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) ?? [:]
        let label = JSONValue.string(obj["label"]) ?? ""
        var days: Int?
        if obj.keys.contains("days") {
            guard let d = obj["days"] as? Int else { return HTTPResponse.json(400, ["error": "invalid days"]) }
            days = d
        }
        var methods: [String]?
        if obj.keys.contains("methods") {
            guard let m = obj["methods"] as? [String] else { return HTTPResponse.json(400, ["error": "invalid methods"]) }
            methods = m
        }
        var prefix: String?
        if obj.keys.contains("path_prefix"), !(obj["path_prefix"] is NSNull) {
            guard let p = obj["path_prefix"] as? String else { return HTTPResponse.json(400, ["error": "invalid path_prefix"]) }
            prefix = p
        }
        let issued = try service.issueGatewayClient(
            name: name, label: label, days: days, methods: methods, pathPrefix: prefix, caller: "dashboard"
        )
        return HTTPResponse.json(201, ["token": issued.token, "client": issued.client.jsonObject()])
    }

    private func clientsRevoke(pathWith path: String) throws -> HTTPResponse {
        let rest = String(path.dropFirst("/api/keys/".count))
        guard let marker = rest.range(of: "/clients/") else { throw AppError.usage("bad path") }
        let name = String(rest[..<marker.lowerBound])
        try KeyName.validate(name)
        guard let id = Int64(rest[marker.upperBound...]) else {
            return HTTPResponse.json(404, ["error": "not_found"])
        }
        let client = try service.revokeGatewayClient(name: name, id: id, caller: "dashboard")
        return HTTPResponse.json(200, ["client": client.jsonObject()])
    }

    private func keysGrant(_ request: HTTPRequest, nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/grants")
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            return HTTPResponse.json(400, ["error": "invalid json"])
        }
        var req = GrantRequest(task: JSONValue.string(obj["task"]) ?? "")
        if let m = JSONValue.int(obj["minutes"]) { req.minutes = m }
        if let methods = obj["methods"] as? [Any] {
            req.methods = Set(methods.compactMap { $0 as? String })
        }
        if let paths = obj["paths"] as? [Any] {
            req.paths = paths.compactMap { $0 as? String }
        }
        if obj.keys.contains("max_requests"), !(obj["max_requests"] is NSNull) {
            guard let n = JSONValue.int(obj["max_requests"]) else {
                return HTTPResponse.json(400, ["error": "max_requests must be an integer"])
            }
            req.maxRequests = n
        }
        if obj.keys.contains("max_usd"), !(obj["max_usd"] is NSNull) {
            guard let d = JSONValue.double(obj["max_usd"]) else {
                return HTTPResponse.json(400, ["error": "max_usd must be a number"])
            }
            req.maxUsd = d
        }
        let caller = JSONValue.string(obj["caller"]).map { String($0.prefix(32)) } ?? "dashboard"
        let issued = try service.issueGrant(name: name, request: req, caller: caller)
        var body = issued.grant.jsonObject()
        body["token"] = issued.token
        body["gateway_url"] = "http://127.0.0.1:\(GatewayListener.port)/\(name)"
        let prefix = Providers.provider(id: issued.grant.provider)?.pathPrefix ?? ""
        body["base_url"] = "http://127.0.0.1:\(GatewayListener.port)/\(name)" + prefix
        body["auth_header"] = Providers.provider(id: issued.grant.provider)?.authHeader ?? "Authorization"
        return HTTPResponse.json(201, body)
    }

    private func grantsList(_ request: HTTPRequest) -> HTTPResponse {
        let all = request.query["all"] == "1" || request.query["all"] == "true"
        var grants = service.listGrants(includeInactive: all)
        if let key = request.query["key"], !key.isEmpty {
            grants = grants.filter { $0.key == key }
        }
        return HTTPResponse.json(200, [
            "grants": grants.map { $0.jsonObject() },
            "gateway_owned": service.thisProcessOwnsGateway(),
        ])
    }

    private func grantRevoke(_ path: String) throws -> HTTPResponse {
        let id = String(path.dropFirst("/api/grants/".count))
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit }) else {
            return HTTPResponse.json(404, ["error": "not_found"])
        }
        let g = try service.revokeGrant(id: id, caller: "dashboard")
        return HTTPResponse.json(200, g.jsonObject())
    }

    private func grantsRevokeAll(_ request: HTTPRequest) -> HTTPResponse {
        let key = request.query["key"].flatMap { $0.isEmpty ? nil : $0 }
        let touched = service.revokeGrants(key: key, reason: "revoked", caller: "dashboard")
        return HTTPResponse.json(200, ["revoked": touched.map { $0.jsonObject() }])
    }

    private func keysCheck(nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/check")
        let result = try service.checkProvider(name: name, caller: "dashboard")
        return HTTPResponse.json(200, result.jsonObject())
    }

    private func keysLastCheck(nameFrom path: String) throws -> HTTPResponse {
        let name = try extractName(path, suffix: "/check")
        guard let result = try service.lastCheck(name: name) else {
            return HTTPResponse.json(404, ["error": "not_checked", "message": "no check recorded for \(name)"])
        }
        return HTTPResponse.json(200, result.jsonObject())
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
            return HTTPResponse.json(403, ["error": "auth_failed", "message": error.description])
        case .authCancelled:
            return HTTPResponse.json(403, ["error": "auth_cancelled", "message": error.description])
        case .authUnavailable:
            return HTTPResponse.json(503, ["error": "auth_unavailable", "message": error.description])
        case .keychain(let m):
            return HTTPResponse.json(500, ["error": "keychain", "message": m])
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
    /// The token is a browser CSRF defense: any local process can GET this page and read it,
    /// so it must never be treated as authentication of the caller. Secret reads stay behind
    /// the presence gate regardless.
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
        case "png": return "image/png"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
