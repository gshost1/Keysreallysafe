import XCTest
@testable import KeysCore

final class ServerTests: XCTestCase {
    func testGenericKeychainErrorIsNotReportedAsTouchID() throws {
        let (db, dir) = try makeDB()
        let service = KeysService(
            catalog: db,
            secrets: ThrowingSecretStore(.keychain("add failed (-25308)")),
            presence: RecordingPresenceGate(),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome
        )
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let body = try JSONValue.data([
            "name": "demo",
            "provider": "xai",
            "kind": "runtime",
            "secret": fixtureSecret,
        ])
        let response = handler.handle(HTTPRequest(
            method: "POST",
            path: "/api/keys",
            query: [:],
            headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken],
            body: body,
            serverPort: 12765
        ))
        XCTAssertEqual(response.status, 500)
        let text = String(data: response.body, encoding: .utf8)!
        XCTAssertFalse(text.contains("auth_failed"), text)
        XCTAssertTrue(text.contains("add failed (-25308)"), text)
    }

    func testAuthFailedStillMapsToTouchIDCode() throws {
        let (db, dir) = try makeDB()
        let service = KeysService(
            catalog: db,
            secrets: ThrowingSecretStore(.authFailed),
            presence: RecordingPresenceGate(),
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome
        )
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let body = try JSONValue.data([
            "name": "demo",
            "provider": "xai",
            "kind": "runtime",
            "secret": fixtureSecret,
        ])
        let response = handler.handle(HTTPRequest(
            method: "POST",
            path: "/api/keys",
            query: [:],
            headers: ["host": "127.0.0.1:12765", "x-ksf-token": handler.originToken],
            body: body,
            serverPort: 12765
        ))
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(String(data: response.body, encoding: .utf8)!.contains("auth_failed"))
    }

    /// The dashboard's HTTP gates, row by row, through the unmodified handler: every forged token,
    /// Origin or Host is refused before it reaches the vault, the presence gate or the event log.
    /// Requests are built directly, not through `handle`, so a row can leave out the Host header.
    func testDashboardGatesRefuseForgedTokenOriginAndHost() throws {
        let (db, dir) = try makeDB()
        let secrets = MemorySecretStore()
        let (service, gate) = makeGatedService(db: db, secrets: secrets)
        let handler = APIHandler(service: service, webRoot: dir)
        let token = handler.originToken
        let host = "127.0.0.1:12765", origin = "http://127.0.0.1:12765"
        let allowed = ["host": host, "origin": origin, "x-ksf-token": token]
        func send(
            _ method: String, _ path: String, _ headers: [String: String], body: [String: Any]? = nil
        ) throws -> (status: Int, object: [String: Any], text: String) {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let response = handler.handle(HTTPRequest(
                method: method, path: path, query: [:], headers: headers, body: data, serverPort: 12765
            ))
            let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
            return (response.status, object, String(decoding: response.body, as: UTF8.self))
        }
        let intruder: [String: Any] = [
            "name": "intruder", "provider": "openai", "kind": "runtime", "notes": "", "secret": "sk-never-stored",
        ]

        // Control: the same request with the real token and a same-origin Host and Origin is
        // accepted, so every refusal below is a gate answering.
        let control = try send("POST", "/api/keys", allowed, body: [
            "name": "echo", "provider": "openai", "kind": "runtime", "notes": "loopback control", "secret": fixtureSecret,
        ])
        XCTAssertEqual(control.status, 201, control.text)
        let before = try service.list()
        let eventsBefore = try service.keyEvents(name: "echo")
        let promptsBefore = gate.reasons

        let tokens: [(String, String?)] = [
            ("no X-KSF-Token", nil),
            ("an empty X-KSF-Token", ""),
            ("a wrong X-KSF-Token of the right length", String(repeating: "z", count: token.count)),
            ("a truncated X-KSF-Token", String(token.dropLast())),
            ("an X-KSF-Token with a trailing byte", token + "z"),
        ]
        for (why, value) in tokens {
            var headers = ["host": host, "origin": origin]
            headers["x-ksf-token"] = value
            let rows: [(String, String, [String: Any]?)] = [
                ("POST", "/api/keys", intruder),
                ("DELETE", "/api/keys/echo", nil),
                ("PATCH", "/api/keys/echo", ["kind": "billing", "notes": "forged"]),
            ]
            for (method, path, body) in rows {
                let refused = try send(method, path, headers, body: body)
                XCTAssertEqual(refused.status, 403, "\(method) \(path) with \(why)")
                XCTAssertEqual(refused.object["error"] as? String, "missing or bad token", "\(method) \(path) with \(why)")
            }
        }

        // Each of these carries the real token, so only the Origin/Host gate can refuse it.
        let forged: [(String, [String: String])] = [
            ("a cross-site Origin", ["host": host, "origin": "http://attacker.example"]),
            ("an Origin on another port", ["host": host, "origin": "http://127.0.0.1:12766"]),
            ("an https Origin", ["host": host, "origin": "https://\(host)"]),
            ("an Origin naming a non-loopback host", ["host": host, "origin": "http://10.0.0.1:12765"]),
            ("a foreign Host", ["host": "attacker.example", "origin": origin]),
            ("a Host on another port", ["host": "127.0.0.1:12766", "origin": origin]),
            ("a bare Host with no port", ["host": "127.0.0.1", "origin": origin]),
            ("no Host header at all", ["origin": origin]),
        ]
        for (why, headers) in forged {
            var sent = headers
            sent["x-ksf-token"] = token
            let rows: [(String, String, [String: Any]?)] = [
                ("POST", "/api/keys", intruder),
                ("DELETE", "/api/keys/echo", nil),
                // Not a read/write distinction: a forged listing may not see a name either.
                ("GET", "/api/keys", nil),
            ]
            for (method, path, body) in rows {
                let refused = try send(method, path, sent, body: body)
                XCTAssertEqual(refused.status, 403, "\(method) \(path) with \(why)")
                XCTAssertEqual(refused.object["error"] as? String, "forbidden", "\(method) \(path) with \(why)")
                XCTAssertNil(refused.object["keys"], "\(method) \(path) with \(why) leaked the vault listing")
            }
        }

        // A cross-site Sec-Fetch-Site is refused on a route that carries a secret.
        var crossSite = allowed
        crossSite["sec-fetch-site"] = "cross-site"
        let revealed = try send("POST", "/api/keys/echo/reveal", crossSite, body: [:])
        XCTAssertEqual(revealed.status, 403)
        XCTAssertEqual(revealed.object["error"] as? String, "forbidden")
        XCTAssertFalse(revealed.text.contains(fixtureSecret), "a refused reveal returned the secret")

        // None of it reached the vault, the presence gate or the audit log.
        XCTAssertEqual(try service.list(), before, "a refused request changed the vault")
        XCTAssertThrowsError(try secrets.get(name: "intruder"), "a refused request reached secret storage")
        XCTAssertEqual(try secrets.get(name: "echo"), fixtureSecret)
        XCTAssertEqual(try service.keyEvents(name: "echo"), eventsBefore, "a refused request was recorded")
        XCTAssertEqual(gate.reasons, promptsBefore, "a refused request reached the presence gate")
        let echo = try XCTUnwrap(try db.catalogRow(name: "echo"))
        XCTAssertEqual(echo.kind, "runtime")
        XCTAssertEqual(echo.notes, "loopback control")
        XCTAssertEqual(echo.version, 1)

        // The documented localhost alias is a same origin too.
        let alias = try send("DELETE", "/api/keys/echo", [
            "host": "localhost:12765", "origin": "http://localhost:12765", "x-ksf-token": token,
        ])
        XCTAssertEqual(alias.status, 200, alias.text)
        XCTAssertTrue(try service.list().isEmpty)
    }

    func testListenersBindLoopbackOnly() throws {
        let server = try LoopbackHTTPServer(port: 0) { _ in HTTPResponse.text(200, "x") }
        defer { server.stop() }
        XCTAssertEqual(server.listener.address, "127.0.0.1", "getsockname must report the loopback address")
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let gateway = try GatewayListener(service: service, port: 0)
        defer { gateway.stop() }
        XCTAssertEqual(gateway.listener.address, "127.0.0.1")
    }

    func testBindIsLoopbackOnlyAndAPIOmitsSecrets() async throws {
        let (db, dir) = try makeDB()
        let (service, _, clipboard) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><title>Keysreallysafe</title></html>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0, handler: handler.handle)
        XCTAssertGreaterThan(server.boundPort, 0)
        server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(server.boundPort)")!
        let index = try await fetch(base)
        XCTAssertEqual(index.status, 200)
        XCTAssertTrue(String(data: index.body, encoding: .utf8)!.contains("Keysreallysafe"))

        let addBody = try JSONValue.data([
            "name": "demo",
            "provider": "xai",
            "kind": "runtime",
            "notes": "",
            "secret": fixtureSecret,
        ])
        let added = try await fetch(
            base.appendingPathComponent("api/keys"),
            method: "POST",
            origin: "http://127.0.0.1:\(server.boundPort)",
            body: addBody,
            token: handler.originToken
        )
        XCTAssertEqual(added.status, 201)
        let addedText = String(data: added.body, encoding: .utf8)!
        XCTAssertFalse(addedText.contains(fixtureSecret))
        XCTAssertFalse(addedText.contains("\"secret\""))

        let listed = try await fetch(base.appendingPathComponent("api/keys"))
        XCTAssertEqual(listed.status, 200)
        let listedText = String(data: listed.body, encoding: .utf8)!
        XCTAssertTrue(listedText.contains("demo"))
        XCTAssertFalse(listedText.contains(fixtureSecret))
        XCTAssertFalse(listedText.contains("\"secret\""))

        let copied = try await fetch(
            base.appendingPathComponent("api/keys/demo/copy"),
            method: "POST",
            origin: "http://127.0.0.1:\(server.boundPort)",
            token: handler.originToken
        )
        XCTAssertEqual(copied.status, 200)
        XCTAssertFalse(String(data: copied.body, encoding: .utf8)!.contains(fixtureSecret))
        XCTAssertEqual(clipboard.value, fixtureSecret)
        XCTAssertEqual(clipboard.lastBackgroundWipe, 20)

        let revealed = try await fetch(
            base.appendingPathComponent("api/keys/demo/reveal"),
            method: "POST",
            origin: "http://127.0.0.1:\(server.boundPort)",
            token: handler.originToken
        )
        XCTAssertEqual(revealed.status, 200)
        XCTAssertTrue(String(data: revealed.body, encoding: .utf8)!.contains(fixtureSecret))

        let forbidden = try await fetch(
            base.appendingPathComponent("api/keys"),
            origin: "http://example.com"
        )
        XCTAssertEqual(forbidden.status, 403)

        let spend = try await fetch(
            URL(string: "http://127.0.0.1:\(server.boundPort)/api/spend?range=month&by=model&source=all")!
        )
        XCTAssertEqual(spend.status, 200)
        XCTAssertFalse(String(data: spend.body, encoding: .utf8)!.contains(fixtureSecret))
        let spendObj = try JSONSerialization.jsonObject(with: spend.body) as! [String: Any]
        XCTAssertNotNil(spendObj["start_day"] as? String)
        XCTAssertNotNil(spendObj["end_day"] as? String)
        XCTAssertNotNil(spendObj["start"] as? String)
        XCTAssertNotNil(spendObj["end"] as? String)
        XCTAssertNotNil(spendObj["last_ingest_at"] as? String)
        XCTAssertGreaterThan(spendObj["catalog_version"] as? Int ?? 0, 0)
    }

    func testHTMLResponsesSendCSPAndReferrerPolicy() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><title>Keysreallysafe</title></html>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let handler = APIHandler(service: service, webRoot: web)
        let response = handler.handle(HTTPRequest(
            method: "GET",
            path: "/",
            query: [:],
            headers: ["host": "127.0.0.1:12765"],
            body: Data(),
            serverPort: 12765
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            response.headers["Content-Security-Policy"],
            "default-src 'self'; connect-src 'self'; img-src 'self' data:"
        )
        XCTAssertEqual(response.headers["Referrer-Policy"], "no-referrer")
        let html = String(data: response.body, encoding: .utf8)!
        XCTAssertTrue(html.contains("<meta name=\"ksf-token\" content=\"\(handler.originToken)\">"), html)
    }

    func testCopyAndRevealRejectCrossSiteFetch() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)

        func post(_ path: String, site: String?) -> HTTPResponse {
            var headers = [
                "host": "127.0.0.1:12765",
                "origin": "http://127.0.0.1:12765",
                "x-ksf-token": handler.originToken,
            ]
            if let site {
                headers["sec-fetch-site"] = site
            }
            return handler.handle(HTTPRequest(
                method: "POST",
                path: path,
                query: [:],
                headers: headers,
                body: Data(),
                serverPort: 12765
            ))
        }

        XCTAssertEqual(post("/api/keys/demo/copy", site: "cross-site").status, 403)
        XCTAssertEqual(post("/api/keys/demo/reveal", site: "cross-site").status, 403)
        XCTAssertEqual(post("/api/keys/demo/copy", site: "same-site").status, 403)
        XCTAssertEqual(post("/api/keys/demo/copy", site: "same-origin").status, 200)
        XCTAssertEqual(post("/api/keys/demo/reveal", site: "none").status, 200)
        XCTAssertEqual(post("/api/keys/demo/copy", site: nil).status, 200)
    }

    func testPatchKeyUpdatesProviderAndRejectsSecret() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)

        let patched = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: try JSONValue.data(["provider": "openai", "notes": "x"])
        )
        XCTAssertEqual(patched.status, 200)
        let obj = try JSONSerialization.jsonObject(with: patched.body) as! [String: Any]
        XCTAssertEqual(obj["name"] as? String, "demo")
        XCTAssertEqual(obj["provider"] as? String, "openai")
        XCTAssertEqual(obj["notes"] as? String, "x")
        XCTAssertEqual(obj["kind"] as? String, "runtime")
        XCTAssertNil(obj["secret"])
        XCTAssertFalse(String(data: patched.body, encoding: .utf8)!.contains(fixtureSecret))

        let listed = handle(handler, method: "GET", path: "/api/keys")
        XCTAssertEqual(listed.status, 200)
        let listText = String(data: listed.body, encoding: .utf8)!
        XCTAssertTrue(listText.contains("\"provider\":\"openai\""), listText)
        XCTAssertTrue(listText.contains("\"notes\":\"x\""), listText)
        XCTAssertFalse(listText.contains(fixtureSecret))

        let secretBody = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: try JSONValue.data(["secret": "nope"])
        )
        XCTAssertEqual(secretBody.status, 400)

        let nameBody = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: try JSONValue.data(["name": "other"])
        )
        XCTAssertEqual(nameBody.status, 400)

        let missing = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/nosuch",
            body: try JSONValue.data(["notes": "x"])
        )
        XCTAssertEqual(missing.status, 404)

        let badKind = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: try JSONValue.data(["kind": "gateway"])
        )
        XCTAssertEqual(badKind.status, 400)
    }

    func testOriginTokenRequiredOnPOSTIngest() throws {
        let (handler, _, _) = try makeHandler()
        let without = handle(handler, method: "POST", path: "/api/ingest", token: false)
        XCTAssertEqual(without.status, 403)
        XCTAssertEqual(
            String(data: without.body, encoding: .utf8),
            String(data: try JSONValue.data(["error": "missing or bad token"]), encoding: .utf8)
        )

        let wrong = handle(
            handler,
            method: "POST",
            path: "/api/ingest",
            headers: ["x-ksf-token": "deadbeef"],
            token: false
        )
        XCTAssertEqual(wrong.status, 403)

        let ok = handle(handler, method: "POST", path: "/api/ingest")
        XCTAssertEqual(ok.status, 200)
    }

    /// The dashboard's API keys view over HTTP: the gateway ledger, filterable by key name,
    /// and the groupings that do not apply to it are refused rather than answered wrongly.
    func testSpendKeysSourceServesTheGatewayLedgerByKey() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "alpha", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "systemone", provider: "typesafe", kind: "runtime", notes: "", secret: fixtureSecret)
        let day = UTC.iso(Date())
        try service.recordGatewayUsage(GatewayUsageRow(
            ts: day, key: "alpha", provider: "anthropic", model: "claude-sonnet-5",
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0,
            status: 200, durationMs: 9, requestId: "alpha-1"
        ))
        // No tokens and no receipt: the request is still countable and must still be served.
        try service.recordGatewayUsage(GatewayUsageRow(
            ts: day, key: "systemone", provider: "typesafe", model: "system-one",
            inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
            status: 200, durationMs: 9, requestId: "systemone-1"
        ))
        _ = try service.catalog.insertUsage(grokEvent(at: day, usd: 3, prompt: "local-only"))

        let all = handle(handler, method: "GET", path: "/api/spend", query: ["range": "month", "source": "keys"])
        XCTAssertEqual(all.status, 200)
        let obj = try JSONSerialization.jsonObject(with: all.body) as! [String: Any]
        XCTAssertEqual(obj["source"] as? String, "keys")
        let rows = obj["rows"] as! [[String: Any]]
        XCTAssertEqual(Set(rows.compactMap { $0["key"] as? String }), ["alpha", "systemone"])
        XCTAssertFalse(rows.contains { ($0["model"] as? String) == "grok-4.6-build" }, "local rows stay out")
        let unpriced = try XCTUnwrap(rows.first { ($0["model"] as? String) == "system-one" })
        XCTAssertTrue(unpriced["usd_estimate"] is NSNull, "unknown cost, not zero")
        XCTAssertEqual(unpriced["model_calls"] as? Int, 1)
        let totals = obj["totals"] as! [String: Any]
        XCTAssertEqual(totals["gateway_calls"] as? Int, 2)
        XCTAssertFalse(String(data: all.body, encoding: .utf8)!.contains(fixtureSecret))

        let keyed = handle(
            handler, method: "GET", path: "/api/spend",
            query: ["range": "month", "source": "keys", "key": "systemone"]
        )
        XCTAssertEqual(keyed.status, 200)
        let keyedObj = try JSONSerialization.jsonObject(with: keyed.body) as! [String: Any]
        XCTAssertEqual((keyedObj["totals"] as! [String: Any])["gateway_calls"] as? Int, 1)
        XCTAssertEqual(Set((keyedObj["rows"] as! [[String: Any]]).compactMap { $0["key"] as? String }), ["systemone"])

        // Projects come from a Claude session path; the gateway has none.
        let byProject = handle(
            handler, method: "GET", path: "/api/spend",
            query: ["range": "month", "source": "keys", "by": "project"]
        )
        XCTAssertEqual(byProject.status, 400)

        let bogus = handle(handler, method: "GET", path: "/api/spend", query: ["source": "gateway"])
        XCTAssertEqual(bogus.status, 400)

        // The provider axis: TypeSafe alone, then a provider outside the gateway ledger, which is
        // refused rather than answered with an empty local view.
        let typesafe = handle(
            handler, method: "GET", path: "/api/spend",
            query: ["range": "month", "source": "keys", "provider": "typesafe"]
        )
        XCTAssertEqual(typesafe.status, 200)
        let tsObj = try JSONSerialization.jsonObject(with: typesafe.body) as! [String: Any]
        XCTAssertEqual((tsObj["totals"] as! [String: Any])["gateway_calls"] as? Int, 1)
        let tsRows = tsObj["rows"] as! [[String: Any]]
        XCTAssertEqual(tsRows.compactMap { $0["provider"] as? String }, ["typesafe"])
        XCTAssertEqual(tsRows.compactMap { $0["model"] as? String }, ["system-one"])

        let mismatched = handle(
            handler, method: "GET", path: "/api/spend",
            query: ["range": "month", "source": "keys", "provider": "anthropic", "key": "systemone"]
        )
        XCTAssertEqual(mismatched.status, 200)
        XCTAssertEqual(
            ((try JSONSerialization.jsonObject(with: mismatched.body) as! [String: Any])["rows"] as! [[String: Any]]).count,
            0,
            "a key of one provider under another provider is an empty intersection, not an error"
        )

        let wrongScope = handle(
            handler, method: "GET", path: "/api/spend",
            query: ["range": "month", "source": "all", "provider": "typesafe"]
        )
        XCTAssertEqual(wrongScope.status, 400, "a provider means nothing outside the gateway ledger")
    }

    func testSpendTodayByHourAndInvalidBy() throws {
        let (handler, service, _) = try makeHandler()
        let tz = TimeZone(identifier: "America/Denver")!
        let now = localDate(2026, 9, 4, 14, 30, timeZone: tz)
        _ = try service.catalog.insertUsage(
            grokEvent(at: UTC.iso(localDate(2026, 9, 4, 10, 15, timeZone: tz)), usd: 1, prompt: "h10")
        )
        _ = try service.catalog.insertUsage(
            grokEvent(at: UTC.iso(localDate(2026, 9, 4, 14, 5, timeZone: tz)), usd: 2, prompt: "h14")
        )
        _ = try service.catalog.insertUsage(
            grokEvent(at: UTC.iso(localDate(2026, 9, 4, 15, 0, timeZone: tz)), usd: 9, prompt: "future")
        )

        let report = try service.spend(
            range: .today, by: .hour, source: .grok, now: now, timeZone: tz
        )
        XCTAssertEqual(report.points.map(\.hour), ["2026-09-04T10:00", "2026-09-04T14:00"])
        XCTAssertEqual(report.points.last?.hour, "2026-09-04T14:00")
        XCTAssertEqual(report.points.last?.usd ?? 0, 2, accuracy: 1e-9)

        let daily = try service.spend(
            range: .today, by: .model, source: .grok, now: now, timeZone: tz
        )
        XCTAssertEqual(Set(daily.daily.map(\.day)), ["2026-09-04"])
        XCTAssertTrue(daily.points.isEmpty)

        let badBy = handle(
            handler,
            method: "GET",
            path: "/api/spend",
            query: ["range": "today", "by": "nope"]
        )
        XCTAssertEqual(badBy.status, 400)

        let hourOnMonth = handle(
            handler,
            method: "GET",
            path: "/api/spend",
            query: ["range": "month", "by": "hour"]
        )
        XCTAssertEqual(hourOnMonth.status, 400)
    }

    func testGetModelsAssignsStableSlots() throws {
        let (db, dir) = try makeDB()
        let empty = try TempDir.make()
        let service = KeysService(
            catalog: db,
            secrets: MemorySecretStore(),
            presence: RecordingPresenceGate(),
            clipboard: FakeClipboard(),
            grokHome: empty,
            claudeHome: empty,
            codexHome: empty
        )
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        _ = try service.catalog.insertUsage(grokEvent(at: "2026-09-01T12:00:00Z", usd: 1, prompt: "a", model: "model-a"))
        _ = try service.catalog.insertUsage(grokEvent(at: "2026-09-01T13:00:00Z", usd: 1, prompt: "b", model: "model-b"))

        _ = try service.ingest(.all)
        let first = handle(handler, method: "GET", path: "/api/models")
        XCTAssertEqual(first.status, 200)
        let rows1 = try JSONSerialization.jsonObject(with: first.body) as! [[String: Any]]
        XCTAssertEqual(rows1.map { $0["model"] as? String }, ["model-a", "model-b"])
        XCTAssertEqual(rows1.map { $0["slot"] as? Int }, [0, 1])
        XCTAssertNotNil(rows1[0]["priced"])
        XCTAssertTrue(rows1[0].keys.contains("input_per_mtok"))

        _ = try service.ingest(.all)
        let second = handle(handler, method: "GET", path: "/api/models")
        let rows2 = try JSONSerialization.jsonObject(with: second.body) as! [[String: Any]]
        XCTAssertEqual(rows2.map { $0["model"] as? String }, ["model-a", "model-b"])
        XCTAssertEqual(rows2.map { $0["slot"] as? Int }, [0, 1])

        _ = try service.catalog.insertUsage(grokEvent(at: "2026-09-01T14:00:00Z", usd: 1, prompt: "c", model: "model-c"))
        _ = try service.ingest(.all)
        let third = handle(handler, method: "GET", path: "/api/models")
        let rows3 = try JSONSerialization.jsonObject(with: third.body) as! [[String: Any]]
        let c = try XCTUnwrap(rows3.first { $0["model"] as? String == "model-c" })
        XCTAssertEqual(c["slot"] as? Int, 2)
    }

    private func localDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func fetch(
        _ url: URL,
        method: String = "GET",
        origin: String? = nil,
        body: Data? = nil,
        token: String? = nil
    ) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let origin {
            req.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let token {
            req.setValue(token, forHTTPHeaderField: "X-KSF-Token")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }
}
