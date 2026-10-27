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
            claudeHome: Fixtures.claudeHome,
            droidHome: Fixtures.droidHome
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
            claudeHome: Fixtures.claudeHome,
            droidHome: Fixtures.droidHome
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
            codexHome: empty,
            droidHome: empty
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

    // MARK: - Profiles over the dashboard API (saved grant bounds)

    /// One JSON object out of a response, for the route assertions below.
    private func object(_ r: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])
    }

    /// The profile routes follow the same discipline as every other mutation: no write without
    /// the per-launch token, and every answer carries bounds only — a profile is saved scope,
    /// never a credential, and nothing in these rows may say otherwise.
    func testProfileRoutesNeedTheTokenOnWritesAndCRUDAnswersBoundsOnly() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let draft = try JSONValue.data([
            "name": "evals", "keys": ["demo"], "methods": ["POST", "GET"], "paths": ["/v1/messages"],
            "minutes": 480, "max_requests": 500, "max_usd": 2.5, "unattended": true,
        ])

        // Writes without the token are refused like every other mutating route; reads stay
        // open to the page behind the same-origin gate alone.
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/profiles", body: draft, token: false).status, 403)
        XCTAssertEqual(handle(handler, method: "DELETE", path: "/api/profiles/00000000", token: false).status, 403)
        XCTAssertTrue(((try object(handle(handler, method: "GET", path: "/api/profiles"))["profiles"] as? [Any]) ?? [[:]]).isEmpty)

        // With the token the row saves and answers with its bounds, normalized the way the
        // CLI prints them.
        let created = handle(handler, method: "POST", path: "/api/profiles", body: draft)
        XCTAssertEqual(created.status, 201)
        let row = try object(created)
        XCTAssertEqual(row["name"] as? String, "evals")
        XCTAssertEqual(row["keys"] as? [String], ["demo"])
        XCTAssertEqual(row["methods"] as? [String], ["GET", "POST"])
        XCTAssertEqual(row["paths"] as? [String], ["/v1/messages"])
        XCTAssertEqual(row["minutes"] as? Int, 480)
        XCTAssertEqual(row["max_requests"] as? Int, 500)
        XCTAssertEqual(row["max_usd"] as? Double, 2.5)
        XCTAssertEqual(row["unattended"] as? Bool, true)
        let id = try XCTUnwrap(row["id"] as? String)
        XCTAssertEqual(id.count, 8, "the id is the Grant.newID() shape")
        XCTAssertEqual(Set(row.keys), [
            "id", "name", "keys", "methods", "paths", "minutes",
            "max_requests", "max_usd", "unattended", "created_at", "updated_at",
        ], "a profile answers with bounds only")

        let listed = try object(handle(handler, method: "GET", path: "/api/profiles"))
        let rows = try XCTUnwrap(listed["profiles"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"] as? String, "evals")

        // A bad save is refused with the same named errors the CLI prints, whatever the shape.
        let bad: [(String, [String: Any], String)] = [
            ("a duplicate name", ["name": "evals", "keys": ["demo"]], "profile_name_taken"),
            ("an unknown key", ["name": "other", "keys": ["ghost"]], "profile_key_unknown"),
            ("an unattended profile with no cap", ["name": "night", "keys": ["demo"], "unattended": true], "profile_requires_cap"),
            ("minutes outside 1...1440", ["name": "long", "keys": ["demo"], "minutes": 0], "profile_minutes_range"),
        ]
        for (why, extra, code) in bad {
            var body: [String: Any] = extra
            if extra["name"] as? String != "night" { body["unattended"] = false }
            let refused = handle(handler, method: "POST", path: "/api/profiles", body: try JSONValue.data(body))
            XCTAssertEqual(refused.status, 400, why)
            XCTAssertEqual(try object(refused)["error"] as? String, code, why)
        }

        // Remove answers the removed row, then the profile is gone; a second remove and a
        // malformed id are both a plain 404.
        let removed = handle(handler, method: "DELETE", path: "/api/profiles/\(id)")
        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(try object(removed)["name"] as? String, "evals")
        XCTAssertTrue((try object(handle(handler, method: "GET", path: "/api/profiles"))["profiles"] as? [[String: Any]])!.isEmpty)
        XCTAssertEqual(handle(handler, method: "DELETE", path: "/api/profiles/\(id)").status, 404)
        XCTAssertEqual(handle(handler, method: "DELETE", path: "/api/profiles/zz").status, 404)
    }

    /// A grant asked for through the dashboard API under a profile lands inside the same bounds
    /// the CLI path enforces — the CLI's control path is this very route — with the same named
    /// refusals, and a refused ask never reaches the presence gate.
    func testGrantUnderAProfileViaTheAPISharesTheCLIPathBoundsAndNamedRefusals() throws {
        let (handler, service, _) = try makeHandler()
        let gate = try XCTUnwrap(service.presence as? RecordingPresenceGate)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.addProfile(ProfileRequest(
            name: "evals", keys: ["demo"], methods: ["GET", "POST"], paths: ["/v1/messages"],
            minutes: 480, maxRequests: 500, maxUsd: 2.5, unattended: true
        ))

        let issued = handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data([
            "task": "night evals", "profile": "evals",
        ]))
        XCTAssertEqual(issued.status, 201)
        let row = try object(issued)
        XCTAssertEqual(row["methods"] as? [String], ["GET", "POST"])
        XCTAssertEqual(row["paths"] as? [String], ["/v1/messages"])
        XCTAssertEqual(row["max_requests"] as? Int, 500)
        XCTAssertEqual(row["max_usd"] as? Double, 2.5)
        XCTAssertEqual(row["profile"] as? String, "evals")
        XCTAssertEqual(row["unattended"] as? Bool, true)
        let viaAPI = try XCTUnwrap(service.listGrants().first { $0.task == "night evals" })
        XCTAssertEqual(
            Int(viaAPI.expiresAt.timeIntervalSince(viaAPI.createdAt) / 60), 480,
            "an unset lifetime takes the profile's"
        )
        XCTAssertEqual(gate.reasons.count, 1, "one prompt for the whole issuance")
        XCTAssertTrue(gate.reasons[0].contains("profile evals"), "the prompt names the profile")

        // Every way the ask can sit outside the profile is refused with the profile's own
        // named error, and none of them consumed a prompt.
        let promptsBefore = gate.reasons
        try service.add(name: "other", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let refusals: [(String, String, [String: Any], Int)] = [
            ("an unknown profile", "/api/keys/demo/grants", ["task": "x", "profile": "nope"], 404),
            ("a key the profile does not name", "/api/keys/other/grants", ["task": "x", "profile": "evals"], 400),
            ("minutes above the ceiling", "/api/keys/demo/grants", ["task": "x", "profile": "evals", "minutes": 600], 400),
            ("a method outside the profile", "/api/keys/demo/grants", ["task": "x", "profile": "evals", "methods": ["DELETE"]], 400),
            ("a path outside the profile", "/api/keys/demo/grants", ["task": "x", "profile": "evals", "paths": ["/v1/models"]], 400),
            ("a request cap above the ceiling", "/api/keys/demo/grants", ["task": "x", "profile": "evals", "max_requests": 900], 400),
            ("a usd cap above the ceiling", "/api/keys/demo/grants", ["task": "x", "profile": "evals", "max_usd": 9], 400),
        ]
        let codes = [
            "profile_not_found", "profile_key_not_allowed", "profile_minutes_over",
            "profile_method_not_allowed", "profile_path_not_allowed", "profile_request_cap_over",
            "profile_usd_cap_over",
        ]
        for ((why, path, body, status), code) in zip(refusals, codes) {
            let refused = handle(handler, method: "POST", path: path, body: try JSONValue.data(body))
            XCTAssertEqual(refused.status, status, why)
            XCTAssertEqual(try object(refused)["error"] as? String, code, why)
        }
        XCTAssertEqual(gate.reasons, promptsBefore, "a refused API ask consumed no prompt")

        // Parity with the CLI path: the same ask through the service seam the control path
        // drives lands on the same bounds as the API row above.
        let viaCLI = try service.issueGrant(
            name: "demo", request: GrantRequest(task: "night evals"), profile: "evals", caller: "cli"
        )
        XCTAssertEqual(viaCLI.grant.methods, viaAPI.methods)
        XCTAssertEqual(viaCLI.grant.paths, viaAPI.paths)
        XCTAssertEqual(viaCLI.grant.maxRequests, viaAPI.maxRequests)
        XCTAssertEqual(viaCLI.grant.maxUsd, viaAPI.maxUsd)
        XCTAssertEqual(viaCLI.grant.profile, viaAPI.profile)
        XCTAssertEqual(viaCLI.grant.unattended, viaAPI.unattended)
    }

    /// The grants list answers the profile name and the unattended flag for grants issued under
    /// a profile, and null/false for plain grants — additive fields, the old shape unchanged.
    func testGrantsListAnswersProfileAndUnattendedForProfileIssuedGrants() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.addProfile(ProfileRequest(
            name: "evals", keys: ["demo"], methods: ["GET", "POST"], paths: ["/v1/messages"],
            minutes: 480, maxRequests: 500, maxUsd: 2.5, unattended: true
        ))
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data([
            "task": "night evals", "profile": "evals",
        ])).status, 201)
        XCTAssertEqual(handle(handler, method: "POST", path: "/api/keys/demo/grants", body: try JSONValue.data([
            "task": "plain ask",
        ])).status, 201)

        let rows = try XCTUnwrap(try object(handle(handler, method: "GET", path: "/api/grants"))["grants"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        let profiled = try XCTUnwrap(rows.first { $0["task"] as? String == "night evals" })
        XCTAssertEqual(profiled["profile"] as? String, "evals")
        XCTAssertEqual(profiled["unattended"] as? Bool, true)
        XCTAssertEqual(profiled["unpriced_calls"] as? Int, 0, "the old fields keep their shape")
        let plain = try XCTUnwrap(rows.first { $0["task"] as? String == "plain ask" })
        XCTAssertTrue(plain["profile"] is NSNull, "a plain grant has no profile")
        XCTAssertEqual(plain["unattended"] as? Bool, false)

        // The audit row names the profile and never the token.
        let events = try service.keyEvents(name: "demo")
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("profile evals") })
        XCTAssertFalse(events.contains { ($0.detail ?? "").contains("ksf_") })
    }


    // MARK: - Grant renewal over the dashboard API

    /// A handler over a catalog with one key and a visible presence gate, so a refused
    /// renewal can prove it consumed no prompt.
    private func makeRenewalHandler() throws -> (APIHandler, KeysService, RecordingPresenceGate) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><head></head><title>Keysrs</title></html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        return (APIHandler(service: service, webRoot: web), service, gate)
    }

    /// The renew route re-approves the grant in place: 200 with the renewed grant's JSON —
    /// same id, renewals 1, the window fields — and NO token anywhere in the body (contrast
    /// issuance, the one response that carries one). The renewed row then lists with its
    /// renewal count, active again.
    func testGrantRenewRouteReturnsTheRenewedGrantWithoutAToken() throws {
        let (handler, service, gate) = try makeRenewalHandler()
        let issued = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(
                task: "night evals", minutes: 60, methods: ["POST"], paths: ["/v1/messages"]
            ).validated()
        )
        XCTAssertEqual(gate.reasons, [], "issuing straight into the store prompts nothing")

        let renewed = handle(
            handler, method: "POST", path: "/api/grants/\(issued.grant.id)/renew",
            body: try JSONValue.data([:]))
        XCTAssertEqual(renewed.status, 200, String(decoding: renewed.body, as: UTF8.self))
        let obj = try object(renewed)
        XCTAssertEqual(obj["id"] as? String, issued.grant.id)
        XCTAssertEqual(obj["key"] as? String, "demo")
        XCTAssertEqual(obj["task"] as? String, "night evals")
        XCTAssertEqual(obj["renewals"] as? Int, 1)
        XCTAssertEqual(obj["window_minutes"] as? Int, 60)
        XCTAssertNil(obj["token"], "the renew response never carries a token")
        XCTAssertFalse(String(decoding: renewed.body, as: UTF8.self).contains(issued.token))
        XCTAssertEqual(gate.reasons.count, 1, "exactly one prompt, for the renewal")
        XCTAssertTrue(gate.reasons.last?.hasPrefix("renew \"night evals\"") ?? false, gate.reasons.last ?? "")

        let listed = try object(handle(handler, method: "GET", path: "/api/grants"))
        let rows = try XCTUnwrap(listed["grants"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == issued.grant.id })
        XCTAssertEqual(row["renewals"] as? Int, 1, "the renewal count is visible in the list")
        XCTAssertNil(row["token"])
    }

    /// The renew route rides the same pre-routing gates as every other mutation: no token or
    /// a wrong one is a flat 403 before the route is even looked up.
    func testGrantRenewRouteNeedsTheToken() throws {
        let (handler, service, _) = try makeRenewalHandler()
        let issued = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x").validated()
        )
        let path = "/api/grants/\(issued.grant.id)/renew"
        let missing = handle(handler, method: "POST", path: path, token: false)
        XCTAssertEqual(missing.status, 403)
        XCTAssertEqual(try object(missing)["error"] as? String, "missing or bad token")
        let wrong = handle(
            handler, method: "POST", path: path,
            headers: ["x-ksf-token": "deadbeef"], token: false)
        XCTAssertEqual(wrong.status, 403)
        XCTAssertEqual(try object(wrong)["error"] as? String, "missing or bad token")
        XCTAssertEqual(service.grants.grant(id: issued.grant.id)?.renewals, 0, "a refused ask renewed nothing")
    }

    /// A bad id shape is the plain 404 any unknown grant gets; a well-shaped unknown id is the
    /// named renew_not_found; a revoked grant is renew_revoked naming the reason — each in the
    /// error envelope the CLI reads back, and none of them consumed a prompt.
    func testGrantRenewRouteNamesItsRefusals() throws {
        let (handler, service, gate) = try makeRenewalHandler()

        for badID in ["nothex", "zzzzzzzz", "a1b2c3d"] {
            let badShape = handle(handler, method: "POST", path: "/api/grants/\(badID)/renew")
            XCTAssertEqual(badShape.status, 404, badID)
            XCTAssertEqual(try object(badShape)["error"] as? String, "not_found", badID)
        }

        let unknown = handle(handler, method: "POST", path: "/api/grants/deadbeef/renew")
        XCTAssertEqual(unknown.status, 404)
        let unknownObj = try object(unknown)
        XCTAssertEqual(unknownObj["error"] as? String, "renew_not_found")
        XCTAssertTrue((unknownObj["message"] as? String ?? "").contains("keys grant"))

        let revoked = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x").validated()
        )
        _ = try service.revokeGrant(id: revoked.grant.id)
        let dead = handle(handler, method: "POST", path: "/api/grants/\(revoked.grant.id)/renew")
        XCTAssertEqual(dead.status, 409)
        let deadObj = try object(dead)
        XCTAssertEqual(deadObj["error"] as? String, "renew_revoked")
        XCTAssertTrue((deadObj["message"] as? String ?? "").contains("revoked"))

        XCTAssertEqual(gate.reasons, [], "no refusal consumed a prompt")
    }

    /// Renewal takes no scope fields: a body naming any of them is refused 400
    /// renew_scope_immutable BEFORE the service runs — the prompt log stays empty and the
    /// grant is untouched. No body and `{}` are the accepted shapes.
    func testGrantRenewRouteRefusesScopeFieldsBeforeAnyPrompt() throws {
        let (handler, service, gate) = try makeRenewalHandler()
        let issued = service.grants.issue(
            key: "demo", provider: "openai", host: "api.openai.com",
            request: try GrantRequest(task: "x", minutes: 30).validated()
        )
        let path = "/api/grants/\(issued.grant.id)/renew"
        let scoped: [[String: Any]] = [
            ["key": "demo"], ["host": "api.openai.com"], ["methods": ["GET"]],
            ["paths": ["/models"]], ["minutes": 30], ["max_requests": 5], ["max_usd": 1],
            ["task": "y"], ["profile": "evals"], ["unattended": true],
        ]
        for body in scoped {
            let refused = handle(handler, method: "POST", path: path, body: try JSONValue.data(body))
            XCTAssertEqual(refused.status, 400, "\(body)")
            XCTAssertEqual(try object(refused)["error"] as? String, "renew_scope_immutable", "\(body)")
        }
        XCTAssertEqual(gate.reasons, [], "a scope-carrying body is refused before any prompt")
        XCTAssertEqual(service.grants.grant(id: issued.grant.id)?.renewals, 0)

        XCTAssertEqual(handle(handler, method: "POST", path: path).status, 200, "no body at all renews")
        XCTAssertEqual(
            handle(handler, method: "POST", path: path, body: try JSONValue.data([:])).status, 200,
            "an empty object renews")
        XCTAssertEqual(service.grants.grant(id: issued.grant.id)?.renewals, 2)
        XCTAssertEqual(gate.reasons.count, 2, "one prompt per accepted renewal")
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
