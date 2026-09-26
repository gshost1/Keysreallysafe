import Darwin
import XCTest
@testable import KeysCore

/// Gateway request hardening, owner pid, framing limits, cursor replay, gateway estimates.
final class GatewayHardeningAndCursorTests: XCTestCase {
    func testGatewayRejectsBadHostOriginAndCrossSiteBeforeLookup() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let gateway = rig.gateway

        let evilHost = try sendRaw(
            port: gateway.boundPort,
            request: "GET /demo/v1/models HTTP/1.1\r\nHost: evil.example:12767\r\n\r\n"
        )
        XCTAssertEqual(evilHost.status, 403)
        XCTAssertEqual(hits.count, 0)

        var cross = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/models")!)
        cross.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        let (_, crossResp) = try await URLSession.shared.data(for: cross)
        XCTAssertEqual((crossResp as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(hits.count, 0)

        var site = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.boundPort)/demo/v1/models")!)
        site.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        let (_, siteResp) = try await URLSession.shared.data(for: site)
        XCTAssertEqual((siteResp as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(hits.count, 0)
    }

    func testDashboardRequiresLoopbackHostWithPort() throws {
        let (handler, _, _) = try makeHandler()
        let bad = handle(handler, method: "GET", path: "/api/keys", headers: ["host": "evil.example:12765"])
        XCTAssertEqual(bad.status, 403)
        let noPort = handle(handler, method: "GET", path: "/api/keys", headers: ["host": "127.0.0.1"])
        XCTAssertEqual(noPort.status, 403)
        let ok = handle(handler, method: "GET", path: "/api/keys")
        XCTAssertEqual(ok.status, 200)
    }

    func testContentLengthNegativeDuplicateShortAndChunked() async throws {
        let captured = RequestLog()
        let rig = try GatewayRig { request in
            captured.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let (service, gateway) = (rig.service, rig.gateway)

        let negative = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nContent-Length: -1\r\n\r\n"
        )
        XCTAssertEqual(negative.status, 400)

        let duplicate = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\nabcd"
        )
        XCTAssertEqual(duplicate.status, 400)

        let overflow = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nContent-Length: 99999999999999999999999\r\n\r\n"
        )
        XCTAssertEqual(overflow.status, 400)

        let short = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nContent-Length: 10\r\n\r\nabc"
        )
        XCTAssertEqual(short.status, 400)

        let token = try grantFor(service, "demo")
        let chunked = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nAuthorization: Bearer \(token)\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        )
        XCTAssertEqual(chunked.status, 200)
        XCTAssertEqual(String(data: try XCTUnwrap(captured.last).body, encoding: .utf8), "hello")

        // A chunk size near Int.max after a non-empty chunk used to overflow the size check and
        // trap, taking down the whole app before auth.
        let hugeChunk = try sendRaw(
            port: gateway.boundPort,
            request: "POST /demo/v1/x HTTP/1.1\r\nHost: 127.0.0.1:\(gateway.boundPort)\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7fffffffffffffff\r\n"
        )
        XCTAssertEqual(hugeChunk.status, 413)
    }

    func testDashboardRejectsOversizeAndShortBodies() throws {
        let server = try LoopbackHTTPServer(port: 0) { _ in
            HTTPResponse.json(200, ["ok": true])
        }
        server.start()
        defer { server.stop() }
        let over = try sendRaw(
            port: server.boundPort,
            request: "POST /api/ingest HTTP/1.1\r\nHost: 127.0.0.1:\(server.boundPort)\r\nContent-Length: 1000001\r\n\r\n"
        )
        XCTAssertEqual(over.status, 413)
        let short = try sendRaw(
            port: server.boundPort,
            request: "POST /api/ingest HTTP/1.1\r\nHost: 127.0.0.1:\(server.boundPort)\r\nContent-Length: 8\r\n\r\nab"
        )
        XCTAssertEqual(short.status, 400)
    }

    func testGatewayOwnerPidBlocksOtherProcessMutations() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        let other = getppid()
        try ControlFile.write(port: 1, token: "other", pid: other, to: ControlFile.url(beside: db.path))
        XCTAssertThrowsError(try service.setGateway(name: "demo", enabled: true, host: nil)) { error in
            guard let app = error as? AppError, case .gatewayOwned(let pid) = app else {
                return XCTFail("expected gatewayOwned, got \(error)")
            }
            XCTAssertEqual(pid, other)
        }
        XCTAssertThrowsError(try service.rotate(name: "demo", secret: "next"))
        XCTAssertThrowsError(try service.remove(name: "demo"))
        XCTAssertThrowsError(try service.purge(confirmation: "purge"))

        let (handler, svc, _) = try makeHandler()
        try svc.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try ControlFile.write(port: 1, token: "other", pid: other, to: ControlFile.url(beside: svc.catalog.path))
        let enable = handle(
            handler,
            method: "POST",
            path: "/api/keys/demo/gateway",
            body: try JSONValue.data(["enabled": true])
        )
        XCTAssertEqual(enable.status, 409)
        let obj = try JSONSerialization.jsonObject(with: enable.body) as! [String: Any]
        XCTAssertEqual(obj["error"] as? String, "gateway owned by another process")
        XCTAssertEqual(obj["gateway_owner_pid"] as? Int, Int(other))
    }

    func testDisableNeverChangesHostAndMismatchDisables() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:9")
        XCTAssertEqual(try db.catalogRow(name: "demo")?.gatewayHost, "127.0.0.1:9")
        _ = try service.setGateway(name: "demo", enabled: false, host: "evil.example")
        XCTAssertEqual(try db.catalogRow(name: "demo")?.gatewayHost, "127.0.0.1:9")
        XCTAssertFalse(service.isGatewayEnabled("demo"))

        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:9")
        _ = try service.patch(name: "demo", provider: "anthropic", kind: nil, notes: nil, caller: "dashboard")
        XCTAssertFalse(service.isGatewayEnabled("demo"))
        let events = try service.keyEvents(name: "demo")
        XCTAssertEqual(events.first?.action, "patch")
        XCTAssertTrue(events.contains { $0.action == "gateway_disable" && $0.detail == "target_changed" })
        XCTAssertNil(service.lookupGateway(name: "demo"))

        _ = try service.setGateway(name: "demo", enabled: true, host: "127.0.0.1:9")
        _ = try db.updateCatalog(name: "demo", provider: "google", kind: nil, notes: nil)
        XCTAssertNil(service.lookupGateway(name: "demo"))
        XCTAssertFalse(service.isGatewayEnabled("demo"))
    }

    func testSplitTargetDecodesOnlyKeySegment() {
        let (path, query) = GatewayListener.splitTarget("/demo%2Fname/v1/x?a=1%26b=2")
        XCTAssertEqual(path, "/demo%2Fname/v1/x")
        XCTAssertEqual(query, "a=1%26b=2")
        let (name, rest) = GatewayListener.splitKey(path)
        XCTAssertEqual(name, "demo/name")
        XCTAssertEqual(rest, "v1/x")
    }

    func testOpenRouterPollDeniesRedirects() async throws {
        let secondHits = RequestLog()
        let second = try LoopbackHTTPServer(port: 0) { request in
            secondHits.record(request)
            return HTTPResponse.json(200, ["data": ["limit": 1]])
        }
        second.start()
        defer { second.stop() }
        let first = try LoopbackHTTPServer(port: 0) { _ in
            HTTPResponse(
                status: 302,
                headers: [
                    "Location": "http://127.0.0.1:\(second.boundPort)/secret",
                    "Content-Type": "text/plain",
                ],
                body: Data("moved".utf8)
            )
        }
        first.start()
        defer { first.stop() }
        let client = OpenRouterHTTP(
            endpoint: URL(string: "http://127.0.0.1:\(first.boundPort)/api/v1/key")!
        )
        XCTAssertThrowsError(try client.fetch(secret: "sk-or-test"))
        XCTAssertEqual(secondHits.count, 0)
    }

    func testTeeKeepsLastSSEUsageWithoutPrefixCap() throws {
        let tee = GatewayTee(api: "openai")
        tee.setContentType("text/event-stream")
        tee.append(Data(repeating: UInt8(ascii: "x"), count: 64) + Data("\n\n".utf8))
        let event = """
        data: {"model":"gpt-4.1","usage":{"prompt_tokens":9,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":1}}}

        """
        tee.append(Data(event.utf8))
        let parsed = tee.result(requestBody: Data())
        XCTAssertEqual(parsed.model, "gpt-4.1")
        XCTAssertEqual(parsed.inputTokens, 9)
        XCTAssertEqual(parsed.outputTokens, 2)
        XCTAssertEqual(parsed.cacheReadTokens, 1)
    }

    func testCodexParserKeepsSessionMetaAcrossIncrementalPasses() throws {
        let home = try TempDir.make()
        let dir = home.appendingPathComponent("sessions/2026/09/04", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(
            "rollout-2026-09-04T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        let header = #"{"timestamp":"2026-09-04T12:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/x","config":{"model":"gpt-5.4"}}}"#
        let first = #"{"timestamp":"2026-09-04T12:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"turn_id":"t1","last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
        try (header + "\n" + first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        XCTAssertEqual(try CodexIngest.run(home: home, db: db).rowsInserted, 1)

        let second = #"{"timestamp":"2026-09-04T12:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"turn_id":"t2","last_token_usage":{"input_tokens":10,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}"#
        let existing = try String(contentsOf: file, encoding: .utf8)
        try (existing + second + "\n").write(to: file, atomically: true, encoding: .utf8)
        let again = try CodexIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 1)
        let events = try db.allUsageEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.model)), ["gpt-5.4"])
        XCTAssertEqual(Set(events.map(\.promptId)), ["t1", "t2"])
    }

    func testRewrittenFileReplaysAndCursorUsesReadSnapshot() throws {
        let home = try TempDir.make()
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let first = assistantLine(uuid: "a1", model: "claude-sonnet-5", input: 10, output: 4)
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let (db, _) = try makeDB()
        XCTAssertEqual(try ClaudeIngest.run(home: home, db: db).rowsInserted, 1)

        let replacement = assistantLine(uuid: "a2", model: "claude-opus-5", input: 20, output: 8)
        try (replacement + "\n" + first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let again = try ClaudeIngest.run(home: home, db: db)
        XCTAssertEqual(again.rowsInserted, 1)
        XCTAssertEqual(Set(try db.allUsageEvents().map(\.model)), ["claude-sonnet-5", "claude-opus-5"])
    }

    func testAnthropicGatewayEstimateIsAdditive() {
        let subtract = GatewayEstimate.usd(
            model: "claude-sonnet-5",
            input: 100,
            output: 10,
            cacheRead: 20,
            cacheWrite: 0,
            api: "openai"
        )
        let additive = GatewayEstimate.usd(
            model: "claude-sonnet-5",
            input: 100,
            output: 10,
            cacheRead: 20,
            cacheWrite: 0,
            api: "anthropic"
        )
        let claude = ClaudeEstimate.usd(
            model: "claude-sonnet-5", input: 100, output: 10, cacheCreate: 0, cacheRead: 20
        )
        XCTAssertEqual(additive, claude)
        XCTAssertNotEqual(subtract, additive)
        XCTAssertGreaterThan(additive ?? 0, subtract ?? 0)
    }

    func testSpendTotalsIncludeGatewayDollarsAndTokenRule() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.recordGatewayUsage(
            GatewayUsageRow(
                ts: "2026-09-04T12:00:00Z",
                key: "demo",
                provider: "openai",
                model: "gpt-4.1",
                inputTokens: 1_000_000,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                status: 200,
                durationMs: 1
            )
        )
        let report = try service.spend(
            range: .month,
            by: .model,
            source: .all,
            now: UTC.parse("2026-09-04T18:00:00Z")!,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            key: "demo"
        )
        XCTAssertEqual(report.totals.gatewayUsdEstimate ?? 0, 2.0, accuracy: 1e-9)
        // Gateway dollars are a separate ledger, never folded into the local estimate.
        XCTAssertEqual(report.totals.usdEstimate ?? 0, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.totals.gatewayCalls, 1)
        let json = report.jsonObject()["totals"] as! [String: Any]
        XCTAssertNotNil(json["gateway_usd_estimate"])
    }

    func testPatchRejectsUnknownFieldsAndWrongTypes() throws {
        let (handler, service, _) = try makeHandler()
        try service.add(name: "demo", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        let unknown = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: try JSONValue.data(["provider": "openai", "color": "red"])
        )
        XCTAssertEqual(unknown.status, 400)
        let numeric = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: Data("{\"provider\":1}".utf8)
        )
        XCTAssertEqual(numeric.status, 400)
        let notes = handle(
            handler,
            method: "PATCH",
            path: "/api/keys/demo",
            body: Data("{\"notes\":3}".utf8)
        )
        XCTAssertEqual(notes.status, 400)
    }

    func testDoctorComparesBinariesBySHA256() throws {
        let dir = try TempDir.make()
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data("alpha".utf8).write(to: a)
        try Data("alpha".utf8).write(to: b)
        XCTAssertEqual(Doctor.fileSHA256(a), Doctor.fileSHA256(b))
        try Data("beta".utf8).write(to: b)
        XCTAssertNotEqual(Doctor.fileSHA256(a), Doctor.fileSHA256(b))
    }
}

private func sendRaw(port: UInt16, request: String) throws -> (status: Int, body: Data) {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw AppError.http("socket") }
    defer { Darwin.close(fd) }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
    if rc != 0 { throw AppError.http("connect") }
    let payload = Data(request.utf8)
    try payload.withUnsafeBytes { raw in
        var written = 0
        let total = payload.count
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        while written < total {
            let n = Darwin.write(fd, base + written, total - written)
            if n <= 0 { throw AppError.http("write") }
            written += n
        }
    }
    Darwin.shutdown(fd, SHUT_WR)
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    guard let text = String(data: data, encoding: .isoLatin1),
          let first = text.split(separator: "\r\n", maxSplits: 1).first
    else { return (0, data) }
    let parts = first.split(separator: " ")
    let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    var body = Data()
    if let range = data.range(of: Data("\r\n\r\n".utf8)) {
        body = Data(data[range.upperBound...])
    }
    return (status, body)
}
