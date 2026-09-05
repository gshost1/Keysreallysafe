import XCTest
@testable import KeysCore

final class ServerTests: XCTestCase {
    func testGenericKeychainErrorIsNotReportedAsTouchID() throws {
        let (db, dir) = try makeDB()
        let service = KeysService(
            catalog: db,
            secrets: ThrowingSecretStore(.keychain("add failed (-25308)")),
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

    func testRefuseNonLoopbackHosts() {
        XCTAssertFalse(BindPolicy.allowBind(host: "0.0.0.0"))
        XCTAssertFalse(BindPolicy.allowBind(host: "192.168.1.5"))
        XCTAssertFalse(BindPolicy.allowBind(host: "10.0.0.1"))
        XCTAssertFalse(BindPolicy.allowBind(host: "::"))
        XCTAssertFalse(BindPolicy.allowBind(host: "localhost"))
        XCTAssertTrue(BindPolicy.allowBind(host: "127.0.0.1"))
        XCTAssertThrowsError(try LoopbackHTTPServer(host: "0.0.0.0", port: 0, handler: { _ in HTTPResponse.text(200, "x") })) { error in
            guard let app = error as? AppError, case .refusedBind("0.0.0.0") = app else {
                return XCTFail("expected refusedBind, got \(error)")
            }
        }
        XCTAssertThrowsError(try LoopbackHTTPServer(host: "192.168.0.10", port: 0, handler: { _ in HTTPResponse.text(200, "x") }))
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
        let server = try LoopbackHTTPServer(host: "127.0.0.1", port: 0, handler: handler.handle)
        XCTAssertEqual(server.boundHost, "127.0.0.1")
        XCTAssertTrue(server.isBoundToLoopback)
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
        XCTAssertTrue(rows1[0].keys.contains("source"))

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

    private func makeHandler() throws -> (APIHandler, KeysService, URL) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><head></head><title>Keysreallysafe</title></html>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        return (APIHandler(service: service, webRoot: web), service, dir)
    }

    private func handle(
        _ handler: APIHandler,
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data(),
        token: Bool = true
    ) -> HTTPResponse {
        var headers = headers
        headers["host"] = headers["host"] ?? "127.0.0.1:12765"
        if token, method != "GET", method != "HEAD" {
            headers["x-ksf-token"] = headers["x-ksf-token"] ?? handler.originToken
        }
        return handler.handle(HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            serverPort: 12765
        ))
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

    private func grokEvent(
        at iso: String, usd: Double, prompt: String, model: String = "grok-4.6-build"
    ) -> UsageEvent {
        UsageEvent(
            source: "grok-local",
            sessionId: "boundary",
            promptId: prompt,
            model: model,
            occurredAt: iso,
            provider: "xai",
            cwd: nil,
            sessionTitle: nil,
            agentName: nil,
            stopReason: nil,
            modelCalls: 1,
            apiDurationMs: 1,
            inputTokens: 10,
            outputTokens: 5,
            cachedReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            costUsdTicks: Int64((usd * Ticks.perUSD).rounded())
        )
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
