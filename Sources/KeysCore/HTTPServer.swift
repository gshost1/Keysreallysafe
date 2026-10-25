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
            case ("POST", "/api/analytics"), ("POST", "/api/analytics/event"):
                return try analyticsRequest(request, path: path)
            case ("GET", "/api/spend"):
                return try spend(request)
            case ("GET", "/api/status"):
                return try liveStatus()
            case ("GET", "/api/grants"):
                return grantsList(request)
            case ("DELETE", "/api/grants"):
                return grantsRevokeAll(request)
            case ("DELETE", let p) where p.hasPrefix("/api/grants/"):
                return try grantRevoke(p)
            case ("GET", "/api/models"):
                return try models()
            case ("GET", "/api/keys"):
                return try keysList()
            case ("POST", "/api/keys"):
                return try keysAdd(request)
            case (_, let p) where p.hasPrefix("/api/keys/"):
                return try keyRequest(request, path: p)
            case ("POST", "/api/wrap"):
                return try wrapPlan(request)
            case (_, let p) where p.hasPrefix("/api/wrap/"):
                return try wrapItem(request, path: p)
            case ("GET", "/api/providers"):
                return HTTPResponse.json(200, try service.providersJSONObject())
            case ("POST", "/api/providers"):
                return try providersAdd(request)
            case (_, let p) where p.hasPrefix("/api/providers/"):
                return try providersItem(request, path: p)
            case ("POST", "/api/ingest"):
                return try ingest(request)
            case ("GET", "/api/relay"):
                return HTTPResponse.json(200, Self.relayJSON(service.relayReport()))
            case ("POST", "/api/relay"):
                return try relaySet(request)
            case ("POST", "/api/preferences/hidden-usage"):
                guard let list = try jsonBody(request)["hidden"] as? [Any] else {
                    return HTTPResponse.json(400, ["error": "hidden must be a list"])
                }
                try service.preferences.setHiddenUsage(list.compactMap { $0 as? String })
                return HTTPResponse.json(200, ["hidden": service.preferences.hiddenUsage.sorted()])
            case ("GET", "/api/limits"):
                return try limitsList()
            case ("PUT", let p) where p.hasPrefix("/api/limits/"):
                return try limitSet(request, path: p)
            case ("DELETE", let p) where p.hasPrefix("/api/limits/"):
                return try limitClear(p)
            case ("GET", "/api/subscriptions"):
                return try subscriptionsList()
            case ("POST", "/api/subscriptions"):
                return try subscriptionsAdd(request)
            case (_, let p) where p.hasPrefix("/api/subscriptions/"):
                return try subscriptionsItem(request, path: p)
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
        // PUT is only the limits route today, but it mutates the same way POST does, so it
        // rides the same token gate instead of growing into a hole.
        method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
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

    private func models() throws -> HTTPResponse {
        HTTPResponse.json(200, try service.modelsJSONObject())
    }

    private func keysList() throws -> HTTPResponse {
        HTTPResponse.json(200, ["keys": try service.listJSONObject()])
    }

    /// Every /api/keys/<name>[/<action>[/<id>]] route: the path is split and the name validated
    /// once, and each route matches its exact method and segment count.
    private func keyRequest(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        let parts = path.dropFirst("/api/keys/".count).split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        let name = parts[0]
        try KeyName.validate(name)
        switch (request.method, parts.count, parts.count > 1 ? parts[1] : "") {
        case ("PATCH", 1, _): return try keysPatch(request, name: name)
        case ("DELETE", 1, _): return try keysDelete(name)
        case ("POST", 2, "gateway"): return try keysGateway(request, name: name)
        case ("POST", 2, "cheapest"): return try keysCheapest(request, name: name)
        case ("GET", 2, "clients"): return try clientsList(name)
        case ("POST", 2, "clients"): return try clientsIssue(request, name: name)
        case ("DELETE", 3, "clients"): return try clientsRevoke(name, id: parts[2])
        case ("POST", 2, "grants"): return try keysGrant(request, name: name)
        case ("POST", 2, "check"): return try keysCheck(name)
        case ("GET", 2, "check"): return try keysLastCheck(name)
        case ("POST", 2, "rotate"): return try keysRotate(request, name: name)
        case ("GET", 2, "events"): return try keysEvents(request, name: name)
        case ("POST", 2, "copy"): return try keysCopy(request, name: name)
        case ("POST", 2, "reveal"): return try keysReveal(request, name: name)
        default: return HTTPResponse.json(405, ["error": "method_not_allowed"])
        }
    }

    /// The body of a route that requires a JSON object; anything else is a 400 "invalid json".
    private func jsonBody(_ request: HTTPRequest) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) else {
            throw AppError.usage("invalid json")
        }
        return obj
    }

    private func providersAdd(_ request: HTTPRequest) throws -> HTTPResponse {
        let obj = try jsonBody(request)
        func field(_ key: String) -> String? {
            guard obj.keys.contains(key), !(obj[key] is NSNull) else { return nil }
            return (obj[key] as? String).map { $0 }
        }
        guard let id = field("id"), let name = field("name") else {
            return HTTPResponse.json(400, ["error": "id and name are required"])
        }
        let record = try service.addProvider(
            id: id,
            name: name,
            host: field("host"),
            api: field("api") ?? "other",
            authHeader: field("auth_header") ?? "Authorization",
            authPrefix: field("auth_prefix") ?? "Bearer ",
            pathPrefix: field("path_prefix") ?? "",
            keyPrefix: field("key_prefix"),
            note: field("note"),
            gateway: JSONValue.bool(obj["gateway"]) ?? true
        )
        return HTTPResponse.json(201, record.jsonObject())
    }

    /// DELETE removes a user-added provider; PATCH hides or unhides a built-in one.
    private func providersItem(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        let id = String(path.dropFirst("/api/providers/".count))
        try ProviderID.validate(id)
        switch request.method {
        case "DELETE":
            try service.removeProvider(id: id)
            return HTTPResponse.json(200, ["removed": id])
        case "PATCH":
            let obj = try jsonBody(request)
            guard let hidden = JSONValue.bool(obj["hidden"]) else {
                return HTTPResponse.json(400, ["error": "hidden is required"])
            }
            try service.setProviderHidden(id: id, hidden: hidden)
            let listing = (try service.providersJSONObject())["providers"] as? [[String: Any]] ?? []
            guard let record = listing.first(where: { $0["id"] as? String == id }) else {
                return HTTPResponse.json(404, ["error": "not_found"])
            }
            return HTTPResponse.json(200, record)
        default:
            return HTTPResponse.json(405, ["error": "method_not_allowed"])
        }
    }

    // The per-window token limits on a locally tracked row (the Droid row today). Writes carry
    // the same per-launch token as every other mutation, and a limit is a positive whole number
    // and nothing else, so a value a caller did not quite mean is refused rather than coerced.
    private func limitsList() throws -> HTTPResponse {
        HTTPResponse.json(200, ["limits": try service.usageLimits().map { $0.jsonObject() }])
    }

    private func limitSet(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        let (source, window) = try limitTarget(path)
        let obj = try jsonBody(request)
        guard let tokens = wholePositiveInt(obj["tokens"]) else {
            return HTTPResponse.json(400, ["error": "tokens must be a positive whole number"])
        }
        return HTTPResponse.json(200, try service.setUsageLimit(
            source: source, window: window, tokens: tokens
        ).jsonObject())
    }

    /// Idempotent on purpose: clearing an already-clear window leaves the same state, so it
    /// answers like clearing a present limit does.
    private func limitClear(_ path: String) throws -> HTTPResponse {
        let (source, window) = try limitTarget(path)
        try service.clearUsageLimit(source: source, window: window)
        return HTTPResponse.json(200, ["removed": "\(source)/\(window)"])
    }

    private func limitTarget(_ path: String) throws -> (source: String, window: String) {
        let parts = path.dropFirst("/api/limits/".count).split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw AppError.usage("expected /api/limits/<source>/<window>") }
        return (parts[0], parts[1])
    }

    // The subscriptions the user pins to the Usage pane. Writes carry the same per-launch token
    // as every other mutation, and the fields are validated strictly — a subscription is a note
    // the user wrote about a plan, so a half-sent one is refused rather than guessed at.
    private func subscriptionsList() throws -> HTTPResponse {
        HTTPResponse.json(200, ["subscriptions": try service.subscriptions().map { $0.jsonObject() }])
    }

    private func subscriptionsAdd(_ request: HTTPRequest) throws -> HTTPResponse {
        let obj = try jsonBody(request)
        let tool = try Subscriptions.validateTool(obj["tool"])
        let name = try Subscriptions.validateName(obj["name"], tool: tool)
        let plan = try Subscriptions.validatePlan(obj["plan"])
        let limit = try Subscriptions.resolveLimit(try subscriptionLimitInput(obj), existing: nil)
        let record = try service.addSubscription(tool: tool, name: name, plan: plan, limit: limit)
        return HTTPResponse.json(201, record.jsonObject())
    }

    /// PATCH rewrites the user's fields (a present-and-equal `tool` is accepted so the dialog can
    /// always send the whole form); DELETE removes the row.
    private func subscriptionsItem(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        let parts = path.dropFirst("/api/subscriptions/".count).split(separator: "/").map(String.init)
        guard parts.count == 1, !parts[0].isEmpty else {
            throw AppError.usage("expected /api/subscriptions/<id>")
        }
        let id = parts[0]
        switch request.method {
        case "PATCH":
            guard let existing = try service.subscription(id: id) else { throw AppError.notFound(id) }
            let obj = try jsonBody(request)
            if obj.keys.contains("tool") {
                let tool = try Subscriptions.validateTool(obj["tool"])
                guard tool == existing.tool else {
                    throw AppError.usage("tool cannot change; remove the subscription and add it again")
                }
            }
            let name: String
            if obj.keys.contains("name") {
                name = try Subscriptions.validateName(obj["name"], tool: existing.tool)
            } else {
                name = existing.name
            }
            let plan: String
            if obj.keys.contains("plan") {
                plan = try Subscriptions.validatePlan(obj["plan"])
            } else {
                plan = existing.plan
            }
            let limit = try Subscriptions.resolveLimit(try subscriptionLimitInput(obj), existing: existing.limit)
            let record = try service.updateSubscription(id: id, name: name, plan: plan, limit: limit)
            return HTTPResponse.json(200, record.jsonObject())
        case "DELETE":
            try service.removeSubscription(id: id)
            return HTTPResponse.json(200, ["removed": id])
        default:
            return HTTPResponse.json(405, ["error": "method_not_allowed"])
        }
    }

    /// The three limit fields with their presence kept, so "all-or-nothing" can be told from
    /// "not being edited". Values of the wrong type are a 400 here, not a silent nil.
    private func subscriptionLimitInput(_ obj: [String: Any]) throws -> Subscriptions.LimitInput {
        var input = Subscriptions.LimitInput()
        if obj.keys.contains("limit_amount") {
            input.amountPresent = true
            let value = obj["limit_amount"]
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                input.amount = number.doubleValue
            } else if !(value is NSNull) {
                throw AppError.usage("limit_amount must be a number or null")
            }
        }
        if obj.keys.contains("limit_unit") {
            input.unitPresent = true
            let value = obj["limit_unit"]
            if let string = value as? String {
                input.unit = string
            } else if !(value is NSNull) {
                throw AppError.usage("limit_unit must be a string or null")
            }
        }
        if obj.keys.contains("limit_period") {
            input.periodPresent = true
            let value = obj["limit_period"]
            if let string = value as? String {
                input.period = string
            } else if !(value is NSNull) {
                throw AppError.usage("limit_period must be a string or null")
            }
        }
        return input
    }

    /// A JSON number that is a whole count above zero: booleans, strings, fractions and floats
    /// beyond the integer range are all nil.
    private func wholePositiveInt(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value > 0, value.rounded() == value, value <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }

    private func keysGateway(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        let obj = try jsonBody(request)
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

    private func keysCheapest(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        guard let enabled = JSONValue.bool(try jsonBody(request)["enabled"]) else {
            return HTTPResponse.json(400, ["error": "enabled is required"])
        }
        let row = try service.setGatewayCheapest(name: name, enabled: enabled, caller: "dashboard")
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    /// `enabled` turns this process's relay on (Touch ID here) or off, `stay_awake` is the
    /// idle-sleep choice; either or both, and nothing else.
    private func relaySet(_ request: HTTPRequest) throws -> HTTPResponse {
        let obj = try jsonBody(request)
        guard !obj.isEmpty, Set(obj.keys).isSubset(of: ["enabled", "stay_awake"]) else {
            return HTTPResponse.json(400, ["error": "send enabled, stay_awake or both"])
        }
        func flag(_ key: String) throws -> Bool? {
            guard obj.keys.contains(key) else { return nil }
            guard let value = JSONValue.bool(obj[key]) else { throw AppError.usage("\(key) must be true or false") }
            return value
        }
        let enabled = try flag("enabled")
        if let stayAwake = try flag("stay_awake") { try service.setRelayStayAwake(stayAwake) }
        if let enabled { _ = try service.setRelay(enabled: enabled) }
        return HTTPResponse.json(200, Self.relayJSON(service.relayReport()))
    }

    /// What Settings and `keys relay on|status` read. The URL is the one agents already use;
    /// the secret and its hint are not here.
    static func relayJSON(_ report: KeysService.RelayReport) -> [String: Any] {
        let state = report.host.state
        var phase = "off", since: Any = NSNull(), retryAt: Any = NSNull()
        if report.host.on {
            switch state.phase {
            case .stopped: phase = "off"
            case .connecting: phase = "connecting"
            case .connected(let at): phase = "connected"; since = UTC.iso(at)
            case .waiting(let until): phase = "waiting"; retryAt = UTC.iso(until)
            }
        }
        let lastError: String? = report.host.on ? state.lastError : nil
        return [
            "configured": report.configured,
            "url": report.url?.absoluteString ?? NSNull(),
            "on": report.host.on,
            "state": phase,
            "connected_since": since,
            "retry_at": retryAt,
            "last_error": lastError ?? NSNull(),
            "inflight": report.host.on ? state.inflight : 0,
            // Another process (keys relay in a Terminal) holds the one relay this Mac may run.
            "elsewhere": report.elsewhere != nil,
            "elsewhere_pid": report.elsewhere?.pid.map { Int($0) } ?? NSNull(),
            "stay_awake": report.stayAwake,
            "awake": report.host.awake,
        ]
    }

    private func clientsList(_ name: String) throws -> HTTPResponse {
        let now = Date()
        return HTTPResponse.json(200, [
            "clients": try service.gatewayClients(name: name).map { $0.jsonObject(now: now) }
        ])
    }

    /// The token appears in this one response and nowhere else.
    private func clientsIssue(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
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
        // `keys client issue` asks for the gateway too, under the same prompt; the dashboard's
        // own Issue button leaves the toggle to the user.
        let enable = JSONValue.bool(obj["gateway"]) ?? false
        let caller = JSONValue.string(obj["caller"]).map { String($0.prefix(32)) } ?? "dashboard"
        let issued = try service.issueGatewayClient(
            name: name, label: label, days: days, methods: methods, pathPrefix: prefix, caller: caller,
            enableGateway: enable
        )
        return HTTPResponse.json(201, [
            "token": issued.token, "client": issued.client.jsonObject(), "gateway_enabled": service.isGatewayEnabled(name),
        ])
    }

    /// The values arrive here only to be compared with the vault and, for the ones the user
    /// adds, stored; the response carries names only.
    private func wrapPlan(_ request: HTTPRequest) throws -> HTTPResponse {
        let obj = try jsonBody(request)
        guard let raw = obj["candidates"] as? [Any] else {
            return HTTPResponse.json(400, ["error": "candidates are required"])
        }
        let candidates = try raw.map { any -> WrapCandidate in
            guard let o = JSONValue.object(any), let variable = JSONValue.string(o["variable"]),
                  let value = JSONValue.string(o["value"])
            else { throw AppError.usage("each candidate needs a variable and a value") }
            return WrapCandidate(
                variable: variable, value: value, provider: JSONValue.string(o["provider"]),
                nameHint: JSONValue.string(o["name_hint"])
            )
        }
        let plan = try service.wrapPlan(file: JSONValue.string(obj["file"]) ?? "env file", candidates: candidates)
        return HTTPResponse.json(200, plan.jsonObject())
    }

    /// POST /api/wrap/<id> carries the plan out; DELETE drops it. The tokens appear in this one
    /// response and nowhere else.
    private func wrapItem(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        let id = String(path.dropFirst("/api/wrap/".count))
        guard id.wholeMatch(of: /^[0-9a-f]{32}$/) != nil else { throw AppError.notFound("wrap plan") }
        switch request.method {
        case "DELETE":
            service.wrapCancel(id: id)
            return HTTPResponse.json(200, ["ok": true])
        case "POST":
            let obj = (try? JSONSerialization.jsonObject(with: request.body)).flatMap(JSONValue.object) ?? [:]
            var days: Int?
            if obj.keys.contains("days") {
                guard let d = obj["days"] as? Int else { return HTTPResponse.json(400, ["error": "invalid days"]) }
                days = d
            }
            let issued = try service.wrapApply(id: id, label: JSONValue.string(obj["label"]) ?? "", days: days, caller: "wrap")
            return HTTPResponse.json(201, [
                "issued": issued.map { ["key": $0.key, "token": $0.token, "client_id": Int($0.clientID), "new": $0.isNew] }
            ])
        default:
            return HTTPResponse.json(405, ["error": "method_not_allowed"])
        }
    }

    private func clientsRevoke(_ name: String, id raw: String) throws -> HTTPResponse {
        guard let id = Int64(raw) else { throw AppError.notFound("client \(raw)") }
        let client = try service.revokeGatewayClient(name: name, id: id, caller: "dashboard")
        return HTTPResponse.json(200, ["client": client.jsonObject()])
    }

    private func keysGrant(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        let obj = try jsonBody(request)
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
        return HTTPResponse.json(200, ["grants": grants.map { $0.jsonObject() }])
    }

    private func grantRevoke(_ path: String) throws -> HTTPResponse {
        let id = String(path.dropFirst("/api/grants/".count))
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit }) else { throw AppError.notFound(id) }
        let g = try service.revokeGrant(id: id, caller: "dashboard")
        return HTTPResponse.json(200, g.jsonObject())
    }

    private func grantsRevokeAll(_ request: HTTPRequest) -> HTTPResponse {
        let key = request.query["key"].flatMap { $0.isEmpty ? nil : $0 }
        let touched = service.revokeGrants(key: key, reason: "revoked", caller: "dashboard")
        return HTTPResponse.json(200, ["revoked": touched.map { $0.jsonObject() }])
    }

    private func keysCheck(_ name: String) throws -> HTTPResponse {
        let result = try service.checkProvider(name: name, caller: "dashboard")
        return HTTPResponse.json(200, result.jsonObject())
    }

    private func keysLastCheck(_ name: String) throws -> HTTPResponse {
        guard let result = try service.lastCheck(name: name) else {
            return HTTPResponse.json(404, ["error": "not_checked", "message": "no check recorded for \(name)"])
        }
        return HTTPResponse.json(200, result.jsonObject())
    }

    private func keysRotate(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        guard let secret = JSONValue.string(try jsonBody(request)["secret"]) else {
            return HTTPResponse.json(400, ["error": "secret is required"])
        }
        let row = try service.rotate(name: name, secret: secret, caller: "dashboard")
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    private func keysEvents(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
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

    private func keysPatch(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        let obj = try jsonBody(request)
        if obj["name"] != nil || obj["secret"] != nil {
            return HTTPResponse.json(400, ["error": "name and secret are immutable"])
        }
        let allowed: Set<String> = ["provider", "kind", "notes", "host"]
        if let unknown = obj.keys.first(where: { !allowed.contains($0) }) {
            return HTTPResponse.json(400, ["error": "unknown field \(unknown)"])
        }
        /// nil when absent (or null, where `null` allows it); otherwise a string, non-empty
        /// unless `empty` allows it.
        func text(_ key: String, null: Bool = false, empty: Bool = false) throws -> String? {
            guard let raw = obj[key], !(null && raw is NSNull) else { return nil }
            guard let s = raw as? String, empty || !s.isEmpty else { throw AppError.usage("\(key) must be a string") }
            return s
        }
        let provider = try text("provider")
        let kind = try text("kind")
        // Present notes replace the old ones; null clears them.
        let notes = obj.keys.contains("notes") ? try text("notes", null: true, empty: true) ?? "" : nil
        let host = try text("host", null: true)
        let row = try service.patch(
            name: name, provider: provider, kind: kind, notes: notes,
            host: host, updateHost: obj.keys.contains("host"), caller: "dashboard"
        )
        return HTTPResponse.json(200, try service.keyJSONObject(row))
    }

    private func keysAdd(_ request: HTTPRequest) throws -> HTTPResponse {
        let obj = try jsonBody(request)
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

    private func keysCopy(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        // Browsers send Sec-Fetch-Site; curl does not. Origin/Host remain the primary gate.
        guard HTTPFrame.LoopbackOrigin.fetchSiteAllowed(request.headers["sec-fetch-site"]) else {
            return HTTPResponse.json(403, ["error": "forbidden"])
        }
        try service.copy(name: name, holdUntilWipe: false, caller: "dashboard")
        return HTTPResponse.json(200, ["ok": true, "wipes_in_s": Int(ClipboardWipe.seconds)])
    }

    private func keysReveal(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        guard HTTPFrame.LoopbackOrigin.fetchSiteAllowed(request.headers["sec-fetch-site"]) else {
            return HTTPResponse.json(403, ["error": "forbidden"])
        }
        let secret = try service.reveal(name: name, caller: "dashboard")
        return HTTPResponse.json(200, ["name": name, "secret": secret])
    }

    private func keysDelete(_ name: String) throws -> HTTPResponse {
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
                "unchanged": report.rowsUnchanged,
                "rows_skipped": report.rowsSkipped,
                "held": report.held,
            ]
        }
        return HTTPResponse.json(200, payload)
    }

    /// `error` is the stable code the dashboard and the control client match on; `message` is
    /// the readable text and `detail` the bare value (a name, a reason) for rebuilding the error.
    private func mapError(_ error: AppError) -> HTTPResponse {
        let (status, code) = error.wire
        var body: [String: Any] = ["error": code, "message": error.description, "detail": error.detail]
        if case .gatewayOwned(let pid) = error { body["gateway_owner_pid"] = Int(pid) }
        return HTTPResponse.json(status, body)
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
