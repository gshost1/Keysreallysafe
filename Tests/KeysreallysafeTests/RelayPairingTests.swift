import Foundation
import XCTest
@testable import KeysCore

/// Pairing (docs/proposals/relay-pairing.md): the Mac verifies an `x-ksf-pair` credential
/// against the catalog's `relay_pairings` table when `relay_pairing_required` is on, before a
/// relayed request's body is buffered. These tests drive FakeRelaySocket into a real
/// RelayClient wired to a real loopback gateway (GatewayRig), exactly like RelayTests.
/// Every credential here is a fixed, obviously fake constant.
final class RelayPairingTests: XCTestCase {
    private let pairCredential = "ksfp_" + String(repeating: "0123456789abcdef", count: 3)
    private let pairCredentialB = "ksfp_" + String(repeating: "fedcba9876543210", count: 3)
    private let unknownCredential = "ksfp_" + String(repeating: "aaaabbbbccccdddd", count: 3)
    private let grant = "ksfc_" + String(repeating: "0011223344556677", count: 3)

    private func head(_ target: String, headers: [[String]] = []) -> Data {
        try! JSONValue.data(["method": "POST", "target": target, "headers": headers])
    }

    private func makeClient(
        port: UInt16,
        dialer: FakeRelayDialer,
        pairing: RelayPairingVerifier?,
        clock: RelayClock = RelayClock(),
        logs: RelayTests.LogSink = RelayTests.LogSink()
    ) -> RelayClient {
        var options = RelayClient.Options(
            url: URL(string: "https://keysrs-relay.example.workers.dev")!,
            secret: "ksfr_" + String(repeating: "a", count: 48),
            gatewayPort: port, pingInterval: 3600
        )
        options.pairing = pairing
        return RelayClient(
            options: options,
            dialer: dialer,
            log: { logs.add($0) },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            jitter: { 1.0 },
            now: { clock.now }
        )
    }

    @discardableResult
    private func seedPairing(
        _ db: CatalogDB, credential: String, label: String = "ci", keys: [String] = [],
        at created: Date, expiresAt expiry: Date?, revoked: Bool = false
    ) throws -> RelayPairingRecord {
        let row = try db.insertRelayPairing(
            label: label, tokenHash: RelayPairing.hash(credential), hint: RelayPairing.hint(credential),
            keys: keys, createdAt: UTC.iso(created), expiresAt: expiry.map(UTC.iso)
        )
        if revoked { XCTAssertTrue(try db.revokeRelayPairing(id: row.id, at: UTC.iso(created))) }
        return row
    }

    /// A rig with pairing required, one gateway-enabled key and a grant for it.
    private func pairedRig(
        clock: RelayClock,
        stub: @escaping @Sendable (HTTPRequest) -> HTTPResponse = { _ in HTTPResponse.json(200, ["ok": true]) }
    ) throws -> GatewayRig {
        let rig = try GatewayRig(upstream: stub)
        try rig.key(secret: "sk-test-secret")
        try seedPairing(rig.db, credential: pairCredential, at: clock.now, expiresAt: clock.now.addingTimeInterval(3600))
        try rig.service.setRelayPairingRequired(true)
        return rig
    }

    // MARK: credential shape and storage

    func testPairingCredentialShapeMirrorsClientTokens() {
        let credential = RelayPairing.generate()
        XCTAssertTrue(credential.hasPrefix("ksfp_"))
        XCTAssertEqual(credential.count, 5 + 48)
        XCTAssertTrue(RelayPairing.looksLikeCredential(credential))
        XCTAssertFalse(RelayPairing.looksLikeCredential("ksfc_" + String(repeating: "0", count: 48)))
        XCTAssertFalse(RelayPairing.looksLikeCredential("ksfp_" + String(repeating: "0", count: 47)))
        XCTAssertFalse(RelayPairing.looksLikeCredential(""))
        XCTAssertEqual(RelayPairing.hash(credential).count, 64)
        XCTAssertEqual(RelayPairing.hint(credential), String(credential.suffix(4)))
        XCTAssertNotEqual(RelayPairing.generate(), credential)
        XCTAssertEqual(try RelayPairing.validateDays(nil), 30)
        XCTAssertThrowsError(try RelayPairing.validateDays(0))
        XCTAssertThrowsError(try RelayPairing.validateDays(366))
    }

    func testIssueMintsUnderOnePromptAndStoresOnlyTheHash() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let (credential, pairing) = try service.issueRelayPairing(label: "github actions", keys: ["demo"], days: 7)
        XCTAssertTrue(RelayPairing.looksLikeCredential(credential))
        XCTAssertEqual(gate.reasons, ["pair a remote agent as github actions"], "one presence prompt per mint")
        XCTAssertEqual(pairing.label, "github actions")
        XCTAssertEqual(pairing.keys, ["demo"])
        XCTAssertEqual(pairing.tokenHash, RelayPairing.hash(credential))
        XCTAssertEqual(pairing.hint, RelayPairing.hint(credential))
        XCTAssertEqual(pairing.tokenHash.count, 64)
        XCTAssertNil(pairing.revokedAt)
        XCTAssertNil(pairing.lastUsedAt)
        assertNoSentinel(credential, in: dir)
        XCTAssertFalse(try db.metaRows(prefix: "").contains { $0.value.contains(credential) })
    }

    func testIssueRefusesADuplicateLiveLabelBeforePrompting() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let (first, firstRow) = try service.issueRelayPairing(label: "ci")
        XCTAssertThrowsError(try service.issueRelayPairing(label: "ci")) { error in
            XCTAssertTrue(String(describing: error).contains("ci"), "\(error)")
        }
        XCTAssertEqual(gate.reasons.count, 1, "a refused duplicate never reaches Touch ID")
        let rows = try db.relayPairings()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tokenHash, RelayPairing.hash(first), "the refusal must not overwrite the row")

        // A revoked label is free again: the new issue is a second row, the old one untouched.
        XCTAssertTrue(try db.revokeRelayPairing(id: firstRow.id, at: UTC.iso(Date())))
        let (second, secondRow) = try service.issueRelayPairing(label: "ci")
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try db.relayPairings().count, 2)
        XCTAssertNotNil(try db.relayPairings().first { $0.id == firstRow.id }?.revokedAt)
        XCTAssertNil(secondRow.revokedAt)
    }

    func testIssuePersistsKeyScopesAndExpiryWithThirtyDayDefault() throws {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        let start = Date()
        let (_, scoped) = try service.issueRelayPairing(label: "scoped", keys: ["work", "personal"], days: 7, now: start)
        XCTAssertEqual(scoped.keys, ["work", "personal"], "stored in the order given")
        let expiry = try XCTUnwrap(UTC.parse(try XCTUnwrap(scoped.expiresAt)))
        XCTAssertEqual(expiry.timeIntervalSince(start), 7 * 86_400, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(UTC.parse(scoped.createdAt)).timeIntervalSince(start), 0, accuracy: 1)

        let (_, all) = try service.issueRelayPairing(label: "all keys", now: start)
        XCTAssertEqual(all.keys, [], "no --key means all keys")
        let defaultExpiry = try XCTUnwrap(UTC.parse(try XCTUnwrap(all.expiresAt)))
        XCTAssertEqual(defaultExpiry.timeIntervalSince(start), 30 * 86_400, accuracy: 1)
        XCTAssertThrowsError(try service.issueRelayPairing(label: "bad", days: 0))
        XCTAssertThrowsError(try service.issueRelayPairing(label: "bad", days: -3))
        XCTAssertEqual(try db.relayPairings().count, 2, "a refused issue stores nothing")
    }

    func testRequireFlagDefaultsOffAndPersistsAcrossReopen() throws {
        let (db, dir) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        XCTAssertFalse(service.relayPairingRequired(), "default is off: today's behavior")
        try service.setRelayPairingRequired(true)
        XCTAssertTrue(service.relayPairingRequired())

        let reopened = try CatalogDB(path: dir.appendingPathComponent("catalog.db"))
        XCTAssertEqual(try reopened.metaValue(KeysService.relayPairingRequiredMetaKey), "1", "the flag lives in the catalog")
        try service.setRelayPairingRequired(false)
        XCTAssertNil(try reopened.metaValue(KeysService.relayPairingRequiredMetaKey))
    }

    func testPurgeClearsRelayPairingsAndTheFlag() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        _ = try service.issueRelayPairing(label: "ci")
        try service.setRelayPairingRequired(true)
        XCTAssertEqual(try db.relayPairings().count, 1)

        try service.purge(confirmation: "purge")
        XCTAssertEqual(try db.relayPairings().count, 0)
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "purge returns pairing to default-off")
        // The table itself survives: pairing can be used again without a reinstall.
        let now = Date()
        XCTAssertNoThrow(try db.insertRelayPairing(
            label: "again", tokenHash: RelayPairing.hash(pairCredential), hint: RelayPairing.hint(pairCredential),
            keys: [], createdAt: UTC.iso(now), expiresAt: nil
        ))
        XCTAssertEqual(gate.reasons.last, "purge Keysrs")
    }

    // MARK: the verdict, at the service boundary

    func testVerifyPairingMapsEveryRefusalWithoutPrompting() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(service.verifyRelayPairing(credential: nil, keyName: nil, now: t0), .notRequired,
                       "flag off: the verifier never engages")
        try service.setRelayPairingRequired(true)

        // Missing, malformed and never-issued are one refusal: no oracle.
        XCTAssertEqual(service.verifyRelayPairing(credential: nil, keyName: "demo", now: t0), .pairingRequired)
        XCTAssertEqual(service.verifyRelayPairing(credential: "", keyName: "demo", now: t0), .pairingRequired)
        XCTAssertEqual(service.verifyRelayPairing(credential: "ksfp_short", keyName: "demo", now: t0), .pairingRequired)
        XCTAssertEqual(service.verifyRelayPairing(credential: " ksfp_" + String(repeating: "0", count: 48), keyName: "demo", now: t0), .pairingRequired)
        XCTAssertEqual(service.verifyRelayPairing(credential: unknownCredential, keyName: "demo", now: t0), .pairingRequired)

        let expiry = t0.addingTimeInterval(60)
        let scoped = try seedPairing(db, credential: pairCredential, keys: ["work"], at: t0, expiresAt: expiry)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "work", now: t0), .ok)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "personal", now: t0), .outOfScope)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: nil, now: t0), .outOfScope,
                       "a scoped pairing accepts no keyless target")

        // Expiry is exclusive: one second before is valid, exactly at is expired.
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "work", now: expiry.addingTimeInterval(-1)), .ok)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "work", now: expiry), .expired)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "work", now: expiry.addingTimeInterval(1)), .expired)

        // Acceptance touched last_used_at; the refusals around it did not.
        let row = try XCTUnwrap(try db.relayPairing(tokenHash: RelayPairing.hash(pairCredential)))
        XCTAssertEqual(row.lastUsedAt, UTC.iso(expiry.addingTimeInterval(-1)))

        XCTAssertTrue(try db.revokeRelayPairing(id: scoped.id, at: UTC.iso(t0)))
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: "work", now: t0), .revoked)

        // An empty key list accepts any target key.
        try seedPairing(db, credential: pairCredentialB, label: "all", keys: [], at: t0, expiresAt: expiry)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredentialB, keyName: "anything", now: t0), .ok)
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredentialB, keyName: nil, now: t0), .ok)

        XCTAssertEqual(gate.reasons, [], "pairing verification reads the catalog only; it never prompts")
    }

    // MARK: enforcement at the relay socket

    func testPairingOffKeepsTodaysBehavior() async throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")
        let socket = FakeRelaySocket()
        // The verifier is wired, but the flag was never set: off is exactly today's behavior.
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier())
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions", headers: [["authorization", "Bearer \(grant)"]])))
        socket.push(RelayFrame(type: .end, id: 1))
        let first = try socket.json(try await socket.frame(.response, id: 1))
        XCTAssertEqual(first["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 1)

        // A pairing header on an unpaired relay is the Mac's business: consumed, never forwarded.
        socket.push(RelayFrame(type: .request, id: 2, payload: head("/demo/v1/chat/completions", headers: [
            ["authorization", "Bearer \(grant)"], ["x-ksf-pair", unknownCredential],
        ])))
        socket.push(RelayFrame(type: .end, id: 2))
        let second = try socket.json(try await socket.frame(.response, id: 2))
        XCTAssertEqual(second["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 2)

        XCTAssertEqual(hits.count, 2)
        XCTAssertNil(hits.last?.headers["x-ksf-pair"])
        XCTAssertTrue(socket.frames.filter { $0.type == .error }.isEmpty)
    }

    func testPairingRequiredRefusalNeverReachesTheGateway() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock, stub: { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        })
        defer { rig.stop() }
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions", headers: [["content-type", "application/json"]])))
        let error = try socket.json(try await socket.frame(.error, id: 1))
        XCTAssertEqual(error["code"] as? String, "pairing_required")
        // Late body frames for the refused id change nothing.
        socket.push(RelayFrame(type: .body, id: 1, payload: Data("late".utf8)))
        socket.push(RelayFrame(type: .end, id: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(socket.frames.filter { $0.id == 1 }.count, 1, "one ERROR frame, no response")
        XCTAssertEqual(hits.count, 0, "the gateway's upstream never saw the refused request")
        XCTAssertEqual(client.inflightCount, 0, "a refused id is never buffered")
    }

    func testUnknownPairingCredentialIsRefusedIdenticallyToMissing() async throws {
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock)
        defer { rig.stop() }
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions")))
        socket.push(RelayFrame(type: .request, id: 2, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", unknownCredential]])))
        let missing = try await socket.frame(.error, id: 1)
        let unknown = try await socket.frame(.error, id: 2)
        XCTAssertEqual(try socket.json(missing)["code"] as? String, "pairing_required")
        XCTAssertEqual(try socket.json(unknown)["code"] as? String, "pairing_required")
        XCTAssertEqual(missing.payload, unknown.payload, "unknown and missing are indistinguishable: no oracle")
    }

    func testMalformedPairingCredentialsAreRefusedAsPairingRequired() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock, stub: { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        })
        defer { rig.stop() }
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        let malformed = [
            "",
            "ksfp_",
            "ksfp_abc",
            "ksfc_" + String(repeating: "0", count: 48),
            "ksfp_" + String(repeating: "0", count: 47),
            "Bearer ksfp_" + String(repeating: "0", count: 48),
        ]
        for (i, value) in malformed.enumerated() {
            let id = UInt32(10 + i)
            socket.push(RelayFrame(type: .request, id: id, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", value]])))
            let error = try socket.json(try await socket.frame(.error, id: id))
            XCTAssertEqual(error["code"] as? String, "pairing_required", "credential \(value.debugDescription)")
        }
        XCTAssertEqual(hits.count, 0)
    }

    func testExpiredPairingIsRefusedAtTheBoundary() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo")
        let seeded = try seedPairing(rig.db, credential: pairCredential, at: clock.now, expiresAt: clock.now.addingTimeInterval(60))
        try rig.service.setRelayPairingRequired(true)
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        let send: (UInt32) -> Void = { id in
            socket.push(RelayFrame(type: .request, id: id, payload: self.head("/demo/v1/chat/completions", headers: [
                ["x-ksf-pair", self.pairCredential], ["authorization", "Bearer \(grant)"],
            ])))
            socket.push(RelayFrame(type: .end, id: id))
        }
        send(1)
        let f0 = try socket.json(try await socket.frame(.response, id: 1))
        XCTAssertEqual(f0["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 1)

        // One second before expiry the pairing is still good.
        clock.advance(59)
        send(2)
        let f1 = try socket.json(try await socket.frame(.response, id: 2))
        XCTAssertEqual(f1["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 2)

        // Exactly at expires_at the pairing is expired.
        clock.advance(1)
        send(3)
        let f2 = try socket.json(try await socket.frame(.error, id: 3))
        XCTAssertEqual(f2["code"] as? String, "pairing_expired")
        clock.advance(30)
        send(4)
        let f3 = try socket.json(try await socket.frame(.error, id: 4))
        XCTAssertEqual(f3["code"] as? String, "pairing_expired")

        XCTAssertEqual(hits.count, 2, "the expired requests never reached the gateway")
        let row = try XCTUnwrap(try rig.db.relayPairing(tokenHash: RelayPairing.hash(pairCredential)))
        XCTAssertEqual(row.id, seeded.id)
        XCTAssertEqual(row.lastUsedAt, UTC.iso(clock.now.addingTimeInterval(-31)),
                       "only the accepted requests moved last_used_at")
    }

    func testRevokedPairingStaysRevokedAcrossReconnect() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        try seedPairing(rig.db, credential: pairCredential, at: clock.now, expiresAt: clock.now.addingTimeInterval(3600), revoked: true)
        try rig.service.setRelayPairingRequired(true)
        let first = FakeRelaySocket()
        let second = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(first), .success(second)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        first.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", pairCredential]])))
        let f4 = try first.json(try await first.frame(.error, id: 1))
        XCTAssertEqual(f4["code"] as? String, "pairing_revoked")

        // The socket drops and the relay reconnects: revocation lives in the catalog, not in
        // connection state, so the same credential is still refused.
        first.drop()
        second.push(RelayFrame(type: .request, id: 2, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", pairCredential]])))
        let f5 = try second.json(try await second.frame(.error, id: 2))
        XCTAssertEqual(f5["code"] as? String, "pairing_revoked")
        XCTAssertEqual(hits.count, 0)
    }

    func testPairingScopeIsCheckedAgainstTheTargetKey() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key("work", secret: "sk-test-secret")
        let grant = try grantFor(rig.service, "work")
        try seedPairing(rig.db, credential: pairCredential, keys: ["work"], at: clock.now, expiresAt: clock.now.addingTimeInterval(3600))
        try seedPairing(rig.db, credential: pairCredentialB, label: "all", keys: [], at: clock.now, expiresAt: clock.now.addingTimeInterval(3600))
        try rig.service.setRelayPairingRequired(true)
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        // Scoped to work, aimed at personal: refused before the gateway.
        socket.push(RelayFrame(type: .request, id: 1, payload: head("/personal/v1/chat/completions", headers: [
            ["x-ksf-pair", pairCredential], ["authorization", "Bearer \(grant)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 1))
        let f6 = try socket.json(try await socket.frame(.error, id: 1))
        XCTAssertEqual(f6["code"] as? String, "pairing_out_of_scope")
        XCTAssertEqual(hits.count, 0)

        // The same pairing aimed at work goes through.
        socket.push(RelayFrame(type: .request, id: 2, payload: head("/work/v1/chat/completions", headers: [
            ["x-ksf-pair", pairCredential], ["authorization", "Bearer \(grant)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 2))
        let f7 = try socket.json(try await socket.frame(.response, id: 2))
        XCTAssertEqual(f7["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 2)

        // An unscoped pairing accepts any first path segment; the gateway's own 404 for the
        // unknown key proves the relay let it through.
        socket.push(RelayFrame(type: .request, id: 3, payload: head("/nosuchkey/v1/models", headers: [
            ["x-ksf-pair", pairCredentialB], ["authorization", "Bearer \(grant)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 3))
        let f8 = try socket.json(try await socket.frame(.response, id: 3))
        XCTAssertEqual(f8["status"] as? Int, 404)
        _ = try await socket.frame(.end, id: 3)
        XCTAssertEqual(hits.count, 1, "only the in-scope request reached upstream")
    }

    func testPairedRelayedCallRoundTripsThroughTheGateway() async throws {
        let captured = RequestLog()
        let stubBody = try Data(contentsOf: Fixtures.root.appendingPathComponent("gateway/openai-chat.json"))
        let clock = RelayClock()
        let logs = RelayTests.LogSink()
        let rig = try GatewayRig { request in
            captured.record(request)
            return HTTPResponse.data(200, stubBody, type: "application/json")
        }
        defer { rig.stop() }
        try rig.key(secret: "sk-test-secret")
        let grant = try grantFor(rig.service, "demo", task: "paired round trip")
        try seedPairing(rig.db, credential: pairCredential, keys: ["demo"], at: clock.now, expiresAt: clock.now.addingTimeInterval(3600))
        try rig.service.setRelayPairingRequired(true)
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock, logs: logs)
        let run = Task { await client.run() }
        defer { run.cancel() }

        let id: UInt32 = 42
        socket.push(RelayFrame(type: .request, id: id, payload: head("/demo/v1/chat/completions", headers: [
            ["authorization", "Bearer \(grant)"], ["content-type", "application/json"], ["X-KSF-Pair", pairCredential],
        ])))
        let body = Data("{\"model\":\"gpt-4.1\",\"messages\":[]}".utf8)
        socket.push(RelayFrame(type: .body, id: id, payload: body))
        socket.push(RelayFrame(type: .end, id: id))

        let f9 = try socket.json(try await socket.frame(.response, id: id))
        XCTAssertEqual(f9["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: id)
        let streamed = socket.frames.filter { $0.type == .body && $0.id == id }.reduce(Data()) { $0 + $1.payload }
        XCTAssertEqual(streamed, stubBody)

        let upstream = try XCTUnwrap(captured.last)
        XCTAssertEqual(upstream.headers["authorization"], "Bearer sk-test-secret", "the gateway swapped the real key in")
        XCTAssertNil(upstream.headers["x-ksf-pair"], "the pairing credential is stripped before replay")
        XCTAssertFalse(upstream.headers.values.contains { $0.contains(self.pairCredential) })

        let usage = try await rig.usageRows()
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.sessionId, "gw-relay:demo", "same relay attribution as any relayed call")
        let call = try XCTUnwrap(try rig.service.keyEvents(name: "demo").first { $0.action == "gateway_call" })
        XCTAssertEqual(call.caller, "relay")

        let pairing = try XCTUnwrap(try rig.db.relayPairing(tokenHash: RelayPairing.hash(pairCredential)))
        XCTAssertEqual(pairing.lastUsedAt, UTC.iso(clock.now), "acceptance updates last_used_at")
        XCTAssertFalse(logs.all.joined(separator: "\n").contains(pairCredential), "the credential is never logged")
        assertNoSentinel(pairCredential, in: rig.dir)
    }

    func testAcceptedPairingUpdatesLastUsedAtRefusalsDoNot() async throws {
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock)
        defer { rig.stop() }
        let grant = try grantFor(rig.service, "demo")
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions")))
        _ = try await socket.frame(.error, id: 1)
        XCTAssertNil(try rig.db.relayPairing(tokenHash: RelayPairing.hash(pairCredential))?.lastUsedAt,
                     "a refusal never updates last_used_at")

        clock.advance(5)
        socket.push(RelayFrame(type: .request, id: 2, payload: head("/demo/v1/chat/completions", headers: [
            ["x-ksf-pair", pairCredential], ["authorization", "Bearer \(grant)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 2))
        _ = try await socket.frame(.response, id: 2)
        _ = try await socket.frame(.end, id: 2)
        XCTAssertEqual(try rig.db.relayPairing(tokenHash: RelayPairing.hash(pairCredential))?.lastUsedAt, UTC.iso(clock.now))

        socket.push(RelayFrame(type: .request, id: 3, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", unknownCredential]])))
        _ = try await socket.frame(.error, id: 3)
        XCTAssertEqual(try rig.db.relayPairing(tokenHash: RelayPairing.hash(pairCredential))?.lastUsedAt, UTC.iso(clock.now),
                       "a later refusal leaves last_used_at alone")
    }

    func testPairedRequestWithoutATokenGetsTheGatewaysOwn401() async throws {
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock)
        defer { rig.stop() }
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions", headers: [["x-ksf-pair", pairCredential]])))
        socket.push(RelayFrame(type: .end, id: 1))
        let response = try socket.json(try await socket.frame(.response, id: 1))
        XCTAssertEqual(response["status"] as? Int, 401, "pairing never substitutes for a client token; the gateway answers")
        _ = try await socket.frame(.end, id: 1)
        let body = socket.frames.filter { $0.type == .body && $0.id == 1 }.reduce(Data()) { $0 + $1.payload }
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("client_required"))
        XCTAssertTrue(socket.frames.filter { $0.type == .error }.isEmpty, "no pairing error for a gateway refusal")
    }

    func testGrantScopeStillAppliesToPairedRequests() async throws {
        let hits = RequestLog()
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock, stub: { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        })
        defer { rig.stop() }
        let scoped = try rig.service.issueGrant(
            name: "demo", request: GrantRequest(task: "models only", paths: ["/v1/models"]), caller: "test"
        ).token
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions", headers: [
            ["x-ksf-pair", pairCredential], ["authorization", "Bearer \(scoped)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 1))
        let response = try socket.json(try await socket.frame(.response, id: 1))
        XCTAssertEqual(response["status"] as? Int, 403, "the gateway's grant scope is unchanged by pairing")
        _ = try await socket.frame(.end, id: 1)
        let body = socket.frames.filter { $0.type == .body && $0.id == 1 }.reduce(Data()) { $0 + $1.payload }
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("grant_path_not_allowed"))
        XCTAssertTrue(socket.frames.filter { $0.type == .error }.isEmpty)
        XCTAssertEqual(hits.count, 0, "the gateway refused it; upstream stayed untouched")
    }

    func testPairingVerificationNeverPrompts() async throws {
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock)
        defer { rig.stop() }
        let grant = try grantFor(rig.service, "demo")
        // The verifier the relay runs must need nothing but the catalog: a service whose secret
        // store throws on any touch, and a presence gate that records any prompt.
        let gate = RecordingPresenceGate()
        let verifierService = KeysService(
            catalog: rig.db,
            secrets: ThrowingSecretStore(.keychain("pairing verification touched the secret store")),
            presence: gate,
            clipboard: FakeClipboard(),
            grokHome: Fixtures.grokHome,
            claudeHome: Fixtures.claudeHome,
            codexHome: Fixtures.codexHome,
            droidHome: Fixtures.droidHome
        )
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: verifierService.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions")))
        _ = try await socket.frame(.error, id: 1)
        socket.push(RelayFrame(type: .request, id: 2, payload: head("/demo/v1/chat/completions", headers: [
            ["x-ksf-pair", pairCredential], ["authorization", "Bearer \(grant)"],
        ])))
        socket.push(RelayFrame(type: .end, id: 2))
        let f10 = try socket.json(try await socket.frame(.response, id: 2))
        XCTAssertEqual(f10["status"] as? Int, 200)
        _ = try await socket.frame(.end, id: 2)
        XCTAssertEqual(gate.reasons, [], "no relayed request, accepted or refused, may prompt for Touch ID")
    }

    func testPairingRefusalPrecedesBodyBuffering() async throws {
        let clock = RelayClock()
        let rig = try pairedRig(clock: clock)
        defer { rig.stop() }
        let socket = FakeRelaySocket()
        let client = makeClient(port: rig.gateway.boundPort, dialer: FakeRelayDialer([.success(socket)]), pairing: rig.service.relayPairingVerifier(), clock: clock)
        let run = Task { await client.run() }
        defer { run.cancel() }

        socket.push(RelayFrame(type: .request, id: 1, payload: head("/demo/v1/chat/completions")))
        _ = try await socket.frame(.error, id: 1)
        // BODY and END behind a refused REQUEST are stray frames for an id that was never buffered.
        socket.push(RelayFrame(type: .body, id: 1, payload: Data("chunk".utf8)))
        socket.push(RelayFrame(type: .end, id: 1))
        // A malformed head is a framing error even with pairing on: parsing precedes pairing.
        socket.push(RelayFrame(type: .request, id: 2, payload: Data("not json".utf8)))
        let f11 = try socket.json(try await socket.frame(.error, id: 2))
        XCTAssertEqual(f11["code"] as? String, "bad_request_frame")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(socket.frames.filter { $0.id == 1 }.count, 1, "exactly one ERROR for the refused id")
        XCTAssertEqual(client.inflightCount, 0)
    }
}
