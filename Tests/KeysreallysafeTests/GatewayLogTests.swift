import Darwin
import SQLite3
import XCTest
@testable import KeysCore

/// The gateway's request log: what each call stores (duration, host, reason), the reason in the
/// gateway's own 502, refusals, `keys log` and the doctor lines. Offline: the real gateway on
/// loopback in front of a fake upstream, as the other gateway tests do.
final class GatewayLogTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: forwarded calls

    func testTimeoutAndUpstream502AreTellableApartInTheBodyTheRowAndTheLog() async throws {
        let rig = try ShortTimeoutRig(timeout: 0.5) { request in
            if request.path.hasSuffix("/slow") {
                Thread.sleep(forTimeInterval: 3)
                return HTTPResponse.json(200, ["late": true])
            }
            return HTTPResponse.json(502, ["error": ["message": "bad gateway at the provider"]])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")

        let (timeoutBody, timeoutStatus) = try await rig.call("v1/slow", token: grant)
        XCTAssertEqual(timeoutStatus, 502)
        let timeoutJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: timeoutBody) as? [String: Any])
        XCTAssertEqual(timeoutJSON["error"] as? String, "upstream_error")
        XCTAssertEqual(timeoutJSON["reason"] as? String, "gateway_timeout")
        XCTAssertEqual(timeoutJSON["detail"] as? String, "NSURLErrorDomain -1001")

        let (upstreamBody, upstreamStatus) = try await rig.call("v1/bad", token: grant)
        XCTAssertEqual(upstreamStatus, 502)
        let upstreamJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        XCTAssertNil(upstreamJSON["reason"], "an upstream status passes through unchanged")
        XCTAssertEqual((upstreamJSON["error"] as? [String: Any])?["message"] as? String, "bad gateway at the provider")

        let rows = try await rig.waitForRows(2)
        let timedOut = try XCTUnwrap(rows.first { $0.reason == "gateway_timeout" })
        XCTAssertEqual(timedOut.httpStatus, 502)
        XCTAssertEqual(timedOut.upstreamHost, "127.0.0.1:\(rig.stub.boundPort)")
        let ms = try XCTUnwrap(timedOut.durationMs)
        XCTAssertGreaterThanOrEqual(ms, 400)
        XCTAssertLessThan(ms, 3000, "the gateway gave up at its own limit, not when the upstream answered")
        let upstream = try XCTUnwrap(rows.first { $0.reason == "upstream_status" })
        XCTAssertEqual(upstream.httpStatus, 502)
        XCTAssertEqual(upstream.upstreamHost, "127.0.0.1:\(rig.stub.boundPort)")
        XCTAssertNotNil(upstream.durationMs)

        let lines = GatewayLogFormat.table(
            try rig.db.gatewayLog(through: rig.db.gatewayLogCursor(), limit: 50), timeZone: utc
        )
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("TIME "))
        let timeoutLine = try XCTUnwrap(lines.first { $0.contains("gateway_timeout") })
        let upstreamLine = try XCTUnwrap(lines.first { $0.contains("upstream_status") })
        for line in [timeoutLine, upstreamLine] {
            let fields = line.split(separator: " ").map(String.init)
            XCTAssertEqual(fields.count, 9, line)
            XCTAssertEqual(Array(fields[2...5]), ["demo", "openai", "127.0.0.1:\(rig.stub.boundPort)", "502"], line)
            XCTAssertEqual(fields.last, "loopback", line)
        }
        let failed = try rig.db.gatewayLog(through: rig.db.gatewayLogCursor(), filter: .gatewaySide, limit: 5)
        XCTAssertEqual(failed.map(\.reason), ["gateway_timeout"], "an upstream 502 is the provider's, not the gateway's")
    }

    func testRefusedConnectionIsConnectFailed() async throws {
        let rig = try ShortTimeoutRig(timeout: 5) { _ in HTTPResponse.json(200, [:]) }
        defer { rig.stop() }
        try rig.key(host: "127.0.0.1:\(try closedPort())")
        let grant = try grantFor(rig.service, "demo")
        let (body, status) = try await rig.call("v1/models", token: grant)
        XCTAssertEqual(status, 502)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["reason"] as? String, "connect_failed")
        let rows = try await rig.waitForRows(1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reason, "connect_failed")
        XCTAssertEqual(row.httpStatus, 502)
    }

    func testACallerThatLeavesIsClientClosedWithTheUpstreamStatus() async throws {
        let reached = DispatchSemaphore(value: 0)
        let rig = try ShortTimeoutRig(timeout: 10) { _ in
            reached.signal()
            Thread.sleep(forTimeInterval: 0.3)
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                body: Data(repeating: 0x61, count: 4 * 1024 * 1024))
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")
        let fd = try connectLoopback(port: rig.gateway.boundPort)
        try writeAll(fd, "GET /demo/v1/files HTTP/1.1\r\nHost: 127.0.0.1:\(rig.gateway.boundPort)\r\n"
            + "Authorization: Bearer \(grant)\r\n\r\n")
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success, "the call reached the upstream")
        // Reset rather than close, so the gateway's first write fails at once.
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        Darwin.close(fd)
        let rows = try await rig.waitForRows(1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reason, "client_closed")
        XCTAssertEqual(row.httpStatus, 200, "the status is still the provider's")
    }

    func testTransportFailuresMapToStableReasons() {
        func reason(_ code: Int, domain: String = NSURLErrorDomain) -> String {
            GatewayReason.classify(NSError(domain: domain, code: code))
        }
        XCTAssertEqual(reason(NSURLErrorTimedOut), "gateway_timeout")
        for code in [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorNotConnectedToInternet] {
            XCTAssertEqual(reason(code), "connect_failed", "\(code)")
        }
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasBadDate, NSURLErrorClientCertificateRequired] {
            XCTAssertEqual(reason(code), "tls_failed", "\(code)")
        }
        XCTAssertEqual(reason(NSURLErrorNetworkConnectionLost), "connection_lost")
        XCTAssertEqual(reason(NSURLErrorBadServerResponse), "network_error")
        XCTAssertEqual(reason(NSURLErrorTimedOut, domain: NSPOSIXErrorDomain), "network_error")

        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(GatewayReason.outcome(clientClosed: false, failure: nil, gotHead: true), "upstream_status")
        XCTAssertEqual(GatewayReason.outcome(clientClosed: true, failure: cancelled, gotHead: true), "client_closed")
        // A stream the request limit cut off: the head was the provider's, the ending was not.
        XCTAssertEqual(GatewayReason.outcome(clientClosed: false, failure: timeout, gotHead: true), "gateway_timeout")
        XCTAssertEqual(GatewayReason.outcome(clientClosed: false, failure: timeout, gotHead: false), "gateway_timeout")
    }

    // MARK: refusals

    func testRefusalsAreLoggedWithTheStatusAnsweredAndThePathTaken() async throws {
        let rig = try ShortTimeoutRig(timeout: 5) { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key()

        let (_, noToken) = try await rig.call("v1/models", token: nil)
        XCTAssertEqual(noToken, 401)
        let (_, relayed) = try await rig.call("v1/models", token: nil, headers: ["X-KSF-Via": "relay"])
        XCTAssertEqual(relayed, 401)
        let getOnly = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "read only", methods: ["GET"]), caller: "test"
        ).token
        let (_, wrongMethod) = try await rig.call("v1/chat/completions", token: getOnly, method: "POST")
        XCTAssertEqual(wrongMethod, 403)
        // Every key is off after a relaunch; its callers then get 404 until it is turned on again.
        _ = try rig.service.setGateway(name: "demo", enabled: false, host: nil)
        let (_, off) = try await rig.call("v1/models", token: getOnly)
        XCTAssertEqual(off, 404)
        // A name that is no key at all must not grow the log.
        let (_, ghost) = try await rig.call("v1/models", token: getOnly, key: "ghost")
        XCTAssertEqual(ghost, 404)

        let entries = try rig.db.gatewayLog(through: rig.db.gatewayLogCursor(), limit: 50)
        XCTAssertEqual(entries.map(\.kind), [.refusal, .refusal, .refusal, .refusal])
        XCTAssertEqual(entries.map(\.reason), ["no_client_token", "no_client_token", "grant_method_not_allowed", "gateway_off"])
        XCTAssertEqual(entries.map(\.status), [401, 401, 403, 404])
        XCTAssertEqual(entries.map(\.via), ["loopback", "relay", "loopback", "loopback"])
        XCTAssertEqual(Set(entries.map(\.key)), ["demo"])
        XCTAssertEqual(Set(entries.compactMap(\.provider)), ["openai"])
        XCTAssertTrue(entries.allSatisfy { $0.host == nil && $0.durationMs == nil }, "nothing went upstream")
        XCTAssertEqual(try rig.db.gatewayEvents().count, 0, "a refusal is not a usage row")
        // The dashboard's history shows the same refusals; the caller says which way they came.
        let callers = try rig.service.keyEvents(name: "demo").filter { $0.action == "gateway_denied" }.map(\.caller)
        XCTAssertEqual(callers, ["gateway", "gateway", "relay", "gateway"])
    }

    // MARK: storage

    /// A catalog from before the log columns: usage_events with http_status but no duration,
    /// host or reason, and key_events without a status. Opening it adds the columns, the old
    /// rows still decode (with nothing invented for them), and new rows keep every field.
    func testOpeningAnOlderCatalogAddsTheLogColumnsAndOldRowsStillDecode() throws {
        let dir = try TempDir.make()
        let path = dir.appendingPathComponent("catalog.db")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE usage_events (
              source TEXT NOT NULL, session_id TEXT NOT NULL, prompt_id TEXT NOT NULL, model TEXT NOT NULL,
              occurred_at TEXT NOT NULL, provider TEXT NOT NULL, cwd TEXT, session_title TEXT, model_calls INTEGER,
              input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              cached_read_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              reasoning_tokens INTEGER NOT NULL DEFAULT 0, cost_usd_ticks INTEGER, key_name TEXT, http_status INTEGER,
              PRIMARY KEY (source, session_id, prompt_id, model));
            CREATE TABLE key_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, name TEXT NOT NULL,
              action TEXT NOT NULL, caller TEXT, detail TEXT);
            INSERT INTO usage_events (source, session_id, prompt_id, model, occurred_at, provider, model_calls,
              input_tokens, output_tokens, key_name, http_status)
              VALUES ('gateway', 'gw-relay:glm', 'old-1', 'z-ai/glm-5.3', '2026-10-20T09:00:00Z', 'nvidia', 1, 0, 0, 'glm', 504);
            INSERT INTO key_events (ts, name, action, caller, detail)
              VALUES ('2026-10-20T09:00:05Z', 'glm', 'gateway_denied', 'gateway', 'no_client_token');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = try CatalogDB(path: path)
        let old = try XCTUnwrap(try db.gatewayEvents().first)
        XCTAssertEqual(old.httpStatus, 504)
        XCTAssertNil(old.durationMs)
        XCTAssertNil(old.upstreamHost)
        XCTAssertNil(old.reason)

        try db.insertUsage(GatewayUsageRow(
            ts: "2026-10-20T09:01:00Z", key: "glm", provider: "nvidia", model: "z-ai/glm-5.3",
            status: 502, durationMs: 900_012, requestId: "r-new", via: "relay",
            upstreamHost: "integrate.api.nvidia.com", reason: "gateway_timeout"
        ).usageEvent())
        try db.insertKeyEvent(ts: "2026-10-20T09:02:00Z", name: "glm", action: "gateway_denied",
                              caller: "relay", detail: "grant_expired", httpStatus: 403)

        let entries = try CatalogDB(path: path).gatewayLog(through: db.gatewayLogCursor(), limit: 50)
        XCTAssertEqual(entries, [
            GatewayLogEntry(kind: .call, ts: "2026-10-20T09:00:00Z", key: "glm", provider: "nvidia", host: nil,
                            status: 504, durationMs: nil, reason: nil, via: "relay"),
            GatewayLogEntry(kind: .refusal, ts: "2026-10-20T09:00:05Z", key: "glm", provider: nil, host: nil,
                            status: nil, durationMs: nil, reason: "no_client_token", via: "loopback"),
            GatewayLogEntry(kind: .call, ts: "2026-10-20T09:01:00Z", key: "glm", provider: "nvidia",
                            host: "integrate.api.nvidia.com", status: 502, durationMs: 900_012,
                            reason: "gateway_timeout", via: "relay"),
            GatewayLogEntry(kind: .refusal, ts: "2026-10-20T09:02:00Z", key: "glm", provider: nil, host: nil,
                            status: 403, durationMs: nil, reason: "grant_expired", via: "relay"),
        ])
        XCTAssertEqual(
            GatewayLogFormat.table(Array(entries.prefix(1)), timeZone: utc)[1],
            "2026-10-20 09:00:00  glm       nvidia      -                         504     -         -                relay"
        )
    }

    func testStoredRowsHoldNoBodyTokenOrKeyValue() async throws {
        let sentinelBody = "BODY-SENTINEL-3f9a"
        let rig = try ShortTimeoutRig(timeout: 0.5) { _ in
            Thread.sleep(forTimeInterval: 2)
            return HTTPResponse.json(200, ["text": "RESPONSE-SENTINEL-77c1"])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")
        _ = try await rig.call("v1/chat/completions", token: grant, method: "POST",
                               body: Data(#"{"model":"gpt-4.1","messages":[{"role":"user","content":"\#(sentinelBody)"}]}"#.utf8))
        _ = try await rig.waitForRows(1)
        assertNoSentinel(sentinelBody, in: rig.dir)
        assertNoSentinel(grant, in: rig.dir)
        assertNoSentinel(fixtureSecret, in: rig.dir)
    }

    // MARK: keys log

    func testKeysLogShowsTheLastFiftyNewestLastAndFiltersByKeyAndFailure() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (service, _, _) = makeService(db: db)
        try service.add(name: "glm", provider: "nvidia", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        func call(_ minute: Int, _ key: String, _ status: Int, _ reason: String?, ms: Int? = 1200, via: String? = nil) throws {
            let row = GatewayUsageRow(ts: String(format: "2026-10-20T10:%02d:00Z", minute), key: key,
                                      provider: key == "glm" ? "nvidia" : "openai", model: "m",
                                      status: status, durationMs: ms ?? 0, requestId: "r-\(minute)-\(key)", via: via,
                                      upstreamHost: key == "glm" ? "integrate.api.nvidia.com" : "api.openai.com",
                                      reason: reason)
            var event = row.usageEvent()
            if ms == nil { event.durationMs = nil }
            try db.insertUsage(event)
        }
        func minutes(_ entries: [GatewayLogEntry]) -> [String] { entries.map { String($0.ts.dropFirst(14).prefix(5)) } }
        try call(0, "demo", 200, "upstream_status")
        try call(1, "glm", 504, "upstream_status", via: "relay")
        try call(2, "glm", 502, "gateway_timeout", ms: 900_001, via: "relay")
        try call(3, "demo", 200, "client_closed")
        try call(4, "demo", 404, "upstream_status")
        try call(5, "demo", 200, nil, ms: nil)    // stored before reasons were kept
        // Stored before statuses were kept at all (0.9): nobody knows how it ended.
        try db.insertUsage(UsageEvent(source: "gateway", sessionId: "gw:demo", promptId: "ancient", model: "m",
                                      occurredAt: "2026-10-20T10:05:30Z", provider: "openai", modelCalls: 1,
                                      inputTokens: 0, outputTokens: 0, costUsdTicks: nil, keyName: "demo"))
        try db.insertKeyEvent(ts: "2026-10-20T10:06:00Z", name: "demo", action: "gateway_denied",
                              caller: "gateway", detail: "out_of_scope", httpStatus: 401)
        try db.insertKeyEvent(ts: "2026-10-20T10:06:30Z", name: "demo", action: "gateway_enable", caller: "cli", detail: nil)
        let cursor = try db.gatewayLogCursor()

        let all = try db.gatewayLog(through: cursor, limit: 50)
        XCTAssertEqual(minutes(all), ["00:00", "01:00", "02:00", "03:00", "04:00", "05:00", "05:30", "06:00"],
                       "newest last; other audit entries are not calls")
        XCTAssertEqual(GatewayLogFormat.table(all, timeZone: utc), [
            "TIME                 KEY       PROVIDER    HOST                      STATUS  DURATION  REASON           VIA",
            "2026-10-20 10:00:00  demo      openai      api.openai.com            200     1.2s      upstream_status  loopback",
            "2026-10-20 10:01:00  glm       nvidia      integrate.api.nvidia.com  504     1.2s      upstream_status  relay",
            "2026-10-20 10:02:00  glm       nvidia      integrate.api.nvidia.com  502     900.0s    gateway_timeout  relay",
            "2026-10-20 10:03:00  demo      openai      api.openai.com            200     1.2s      client_closed    loopback",
            "2026-10-20 10:04:00  demo      openai      api.openai.com            404     1.2s      upstream_status  loopback",
            "2026-10-20 10:05:00  demo      openai      api.openai.com            200     -         -                loopback",
            "2026-10-20 10:05:30  demo      openai      -                         -       -         -                loopback",
            "2026-10-20 10:06:00  demo      openai      -                         401     -         out_of_scope     loopback",
        ])

        XCTAssertEqual(try db.gatewayLog(through: cursor, key: "glm", limit: 50).map(\.status), [504, 502])
        XCTAssertEqual(minutes(try db.gatewayLog(through: cursor, filter: .failed, limit: 50)),
                       ["01:00", "02:00", "03:00", "04:00", "05:30", "06:00"],
                       "only a 2xx the provider answered is left out; a row with no status at all stays")
        XCTAssertEqual(try db.gatewayLog(through: cursor, key: "demo", filter: .failed, limit: 50).map(\.reason),
                       ["client_closed", "upstream_status", nil, "out_of_scope"])
        XCTAssertEqual(try db.gatewayLog(through: cursor, filter: .gatewaySide, limit: 50).map(\.reason),
                       ["gateway_timeout", "client_closed", "out_of_scope"])
        XCTAssertEqual(minutes(try db.gatewayLog(through: cursor, limit: 2)), ["05:30", "06:00"])

        let json = all[2].jsonObject
        XCTAssertEqual(Set(json.keys), ["ts", "kind", "key", "provider", "host", "status", "duration_ms", "reason", "via"])
        XCTAssertEqual(json["reason"] as? String, "gateway_timeout")
        XCTAssertEqual(json["duration_ms"] as? Int, 900_001)
        XCTAssertTrue(all[7].jsonObject["host"] is NSNull)
        XCTAssertTrue(all[6].jsonObject["status"] is NSNull)

        // --tail reads what was written after the cursor, and only that.
        try call(7, "glm", 200, "upstream_status")
        try db.insertKeyEvent(ts: "2026-10-20T10:08:00Z", name: "glm", action: "gateway_denied",
                              caller: "relay", detail: "no_client_token", httpStatus: 401)
        let next = try db.gatewayLogCursor()
        XCTAssertEqual(try db.gatewayLog(after: cursor, through: next).map(\.reason), ["upstream_status", "no_client_token"])
        XCTAssertEqual(try db.gatewayLog(after: cursor, through: next, filter: .failed).map(\.reason), ["no_client_token"])
        XCTAssertEqual(try db.gatewayLog(after: next, through: next), [])
    }

    func testDefaultLimitIsTheLastFifty() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<55 {
            try db.insertUsage(GatewayUsageRow(ts: String(format: "2026-10-20T11:%02d:00Z", i), key: "demo",
                                               provider: "openai", model: "m", status: 200, durationMs: i,
                                               requestId: "r\(i)", reason: "upstream_status").usageEvent())
        }
        let command = try LogCommand.parse([])
        XCTAssertEqual(command.limit, 50)
        let entries = try db.gatewayLog(through: db.gatewayLogCursor(), limit: command.limit)
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(entries.first?.durationMs, 5)
        XCTAssertEqual(entries.last?.durationMs, 54)
    }

    func testLogCommandParsesItsOptions() throws {
        let command = try LogCommand.parse(["--key", "glm", "--failed", "--tail", "--limit", "10", "--json"])
        XCTAssertEqual(command.key, "glm")
        XCTAssertTrue(command.failed)
        XCTAssertTrue(command.tail)
        XCTAssertTrue(command.json)
        XCTAssertEqual(command.limit, 10)
        XCTAssertThrowsError(try LogCommand.parse(["--limit", "0"]))
        XCTAssertThrowsError(try LogCommand.parse(["--limit", "10001"]))
        XCTAssertEqual(GatewayLogFormat.duration(nil), "-")
        XCTAssertEqual(GatewayLogFormat.duration(850), "850ms")
        XCTAssertEqual(GatewayLogFormat.duration(61_249), "61.2s")
        // A provider name is whatever was typed into `keys add`; an escape sequence in it must
        // not reach the terminal as one.
        let odd = GatewayLogEntry(kind: .refusal, ts: "2026-10-20T10:00:00Z", key: "demo", provider: "evil\u{1b}[31m\u{9b}x",
                                  host: nil, status: 401, durationMs: nil, reason: "no_client_token", via: "loopback")
        XCTAssertEqual(GatewayLogFormat.fields(odd, timeZone: TimeZone(secondsFromGMT: 0)!)[2], "evil?[31m?x")
    }

    // MARK: doctor

    func testDoctorPrintsTheGatewayLimitsAndTheLatestGatewaySideFailures() throws {
        XCTAssertEqual(Doctor.gatewayLines(failures: [], timeZone: utc), [
            "gateway limits  request_timeout=900s (idle and whole call)  connect_timeout=none (the request timeout covers it)"
                + "  body_cap=8MiB  max_connections=32  caller_io_timeout=30s",
            "gateway breaker  5 upstream 401/403 in a row pause a key's calls for 60s (503 upstream_auth_blocked)",
            "gateway failures  none recorded",
        ])

        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (minute, status, reason) in [(0, 502, "gateway_timeout"), (1, 504, "upstream_status"), (2, 200, "upstream_status")] {
            try db.insertUsage(GatewayUsageRow(ts: "2026-10-20T12:0\(minute):00Z", key: "glm", provider: "nvidia",
                                               model: "m", status: status, durationMs: 900_000, requestId: "d\(minute)",
                                               via: "relay", upstreamHost: "integrate.api.nvidia.com", reason: reason).usageEvent())
        }
        try db.insertKeyEvent(ts: "2026-10-20T12:03:00Z", name: "glm", action: "gateway_denied", caller: "gateway",
                              detail: "upstream_auth_blocked")
        let failures = try db.gatewayLog(through: db.gatewayLogCursor(), filter: .gatewaySide, limit: Doctor.gatewayFailureCount)
        let lines = Doctor.gatewayLines(failures: failures, timeZone: utc)
        XCTAssertEqual(Array(lines.dropFirst(2)), [
            "gateway failures  last 2 refused or failed on this side, newest last (more: keys log --failed)",
            "  TIME                 KEY       PROVIDER    HOST                      STATUS  DURATION  REASON                 VIA",
            "  2026-10-20 12:00:00  glm       nvidia      integrate.api.nvidia.com  502     900.0s    gateway_timeout        relay",
            "  2026-10-20 12:03:00  glm       -           -                         -       -         upstream_auth_blocked  loopback",
        ])

        let report = DoctorReport(sources: [], catalogPath: "/tmp/catalog.db", catalogSize: 1, keychainService: "keysreallysafe",
                                  keychainReachable: true, gatewayListening: true, gatewayPort: 12767,
                                  install: DoctorInstall(runningExecutable: URL(fileURLWithPath: "/tmp/keys")),
                                  gatewayFailures: failures)
        let printed = report.printed.components(separatedBy: "\n")
        let at = try XCTUnwrap(printed.firstIndex(of: "gateway  127.0.0.1:12767  listening"))
        XCTAssertTrue(printed[at + 1].hasPrefix("gateway limits  request_timeout=900s"))
        XCTAssertTrue(printed[at + 2].hasPrefix("gateway breaker  5 upstream 401/403"))
        XCTAssertTrue(printed.contains { $0.contains("gateway_timeout") })
    }

    // MARK: product analytics

    /// The log's new fields stay in the catalog: the analytics report carries no host, reason
    /// or duration, and a timed-out call counts exactly as any failed call did before.
    func testLogFieldsNeverReachProductAnalytics() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ProductAnalyticsTests.Clock(), transport = ProductAnalyticsTests.Transport()
        let analytics = ProductAnalytics(catalog: db, endpoint: URL(string: "https://analytics.example/v1/reports")!,
                                         transport: transport, now: { clock.date() })
        try analytics.setEnabled(true, consentVersion: 2)
        analytics.record(.viewUsage)
        let day = UTC.iso(clock.date().addingTimeInterval(3600))
        for (status, reason) in [(502, "gateway_timeout"), (200, "client_closed"), (200, "upstream_status")] {
            try db.insertUsage(GatewayUsageRow(ts: day, key: "demo", provider: "openai", model: "gpt-4.1",
                                               inputTokens: 5, outputTokens: 1, status: status, durationMs: 987_654,
                                               upstreamHost: "private-upstream.example", reason: reason).usageEvent())
        }
        clock.advance(86_400)
        analytics.flushCompletedReports()
        let data = try XCTUnwrap(transport.calls.first?.data)
        let text = String(decoding: data, as: UTF8.self)
        for leak in ["private-upstream", "gateway_timeout", "client_closed", "upstream_status", "987654", "reason", "duration"] {
            XCTAssertFalse(text.contains(leak), leak)
        }
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let gateway = try XCTUnwrap((sent["gateway"] as? [[String: Any]])?.first)
        XCTAssertEqual(gateway["requests"] as? Int, 3)
        XCTAssertEqual(gateway["ok"] as? Int, 2)
        XCTAssertEqual(gateway["failed"] as? Int, 1)
    }
}

/// The real gateway with a short request limit, so a timeout takes half a second, in front of
/// a fake upstream on loopback.
private final class ShortTimeoutRig {
    let db: CatalogDB
    let dir: URL
    let service: KeysService
    let stub: LoopbackHTTPServer
    let gateway: GatewayListener

    init(timeout: TimeInterval, upstream: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        (db, dir) = try makeDB()
        (service, _) = makeGatedService(db: db)
        stub = try LoopbackHTTPServer(port: 0, handler: upstream)
        gateway = try GatewayListener(service: service, port: 0, requestTimeout: timeout)
        stub.start()
        gateway.start()
    }

    func stop() {
        gateway.stop()
        stub.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func key(_ name: String = "demo", host: String? = nil) throws {
        try service.add(name: name, provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: name, enabled: true, host: host ?? "127.0.0.1:\(stub.boundPort)")
    }

    func call(
        _ rest: String, token: String?, key: String = "demo", method: String = "GET",
        headers: [String: String] = [:], body: Data? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/\(key)/\(rest)")!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The gateway answers before it records the call, so wait (boundedly) for the rows.
    func waitForRows(_ count: Int) async throws -> [UsageEvent] {
        var rows: [UsageEvent] = []
        for _ in 0..<400 where rows.count < count {
            rows = try db.gatewayEvents()
            if rows.count < count { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        return rows
    }
}

/// A loopback port nothing listens on: bound once to learn a free number, then closed.
private func closedPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw AppError.http("socket") }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
            guard Darwin.bind(fd, sa, len) == 0 else { return -1 }
            return getsockname(fd, sa, &len)
        }
    }
    if rc != 0 { throw AppError.http("bind") }
    return UInt16(bigEndian: addr.sin_port)
}

private func connectLoopback(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw AppError.http("socket") }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 {
        Darwin.close(fd)
        throw AppError.http("connect")
    }
    return fd
}

private func writeAll(_ fd: Int32, _ text: String) throws {
    guard HTTPFrame.writeAll(fd: fd, Data(text.utf8)) else { throw AppError.http("write") }
}
