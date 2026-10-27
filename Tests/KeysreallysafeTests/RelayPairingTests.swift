import Foundation
import SQLite3
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
        let (service, gate) = makeGatedService(db: db)
        XCTAssertFalse(service.relayPairingRequired(), "default is off: today's behavior")
        try service.setRelayPairingRequired(true)
        XCTAssertTrue(service.relayPairingRequired())

        let reopened = try CatalogDB(path: dir.appendingPathComponent("catalog.db"))
        XCTAssertEqual(try reopened.metaValue(KeysService.relayPairingRequiredMetaKey), "1", "the flag lives in the catalog")
        try service.setRelayPairingRequired(false)
        XCTAssertEqual(gate.reasons, ["stop requiring paired agents on the relay"],
                       "clearing the flag now costs the one presence prompt")
        XCTAssertNil(try reopened.metaValue(KeysService.relayPairingRequiredMetaKey))
    }

    /// Turning enforcement off is the one security-lowering move in the pairing surface, so
    /// it costs exactly one presence prompt, ordered before the catalog write.
    func testRequireOffPromptsOnceWithReasonAndClearsTheFlag() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.setRelayPairingRequired(true)

        try service.setRelayPairingRequired(false)
        XCTAssertEqual(gate.reasons, ["stop requiring paired agents on the relay"], "one prompt to stop requiring pairings")
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "the write happened under the prompt")
        XCTAssertFalse(service.relayPairingRequired())
    }

    /// A cancelled prompt is a refusal, so the flag must stay exactly as it was: the write
    /// happens only after a successful prompt, never on the way to one.
    func testRequireOffThroughAThrowingGateLeavesTheFlagSet() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db, gate: RecordingPresenceGate(error: AppError.authCancelled))
        try service.setRelayPairingRequired(true)

        XCTAssertThrowsError(try service.setRelayPairingRequired(false))
        XCTAssertEqual(gate.reasons, ["stop requiring paired agents on the relay"], "the refusal came from the prompt")
        XCTAssertEqual(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "1", "a cancelled prompt leaves the flag set")
        XCTAssertTrue(service.relayPairingRequired())
    }

    /// Raising enforcement only ever tightens, so turning it on needs no presence at all.
    func testRequireOnNeverPrompts() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.setRelayPairingRequired(true)
        XCTAssertEqual(gate.reasons, [], "raising enforcement costs no presence")
        XCTAssertEqual(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "1")
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

    /// A thrown flag read must not silently disable enforcement: an unreadable flag refuses
    /// exactly like a missing credential, while an absent row stays a legitimate off. The
    /// read error is induced deterministically — a second raw SQLite connection drops the
    /// meta table, and sqlite's schema change makes the service connection's next prepare
    /// of the flag read throw.
    func testVerifyPairingFailsClosedWhenTheFlagCannotBeRead() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // An absent row is the legitimate default off, with and without a credential.
        XCTAssertEqual(service.verifyRelayPairing(credential: nil, keyName: nil, now: t0), .notRequired)
        try service.setRelayPairingRequired(true)
        try seedPairing(db, credential: pairCredential, label: "ci", at: t0, expiresAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: nil, now: t0), .ok)
        let touched = try XCTUnwrap(try db.relayPairing(tokenHash: RelayPairing.hash(pairCredential))?.lastUsedAt)

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("catalog.db").path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TABLE meta;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        XCTAssertEqual(service.verifyRelayPairing(credential: nil, keyName: nil, now: t0), .pairingRequired,
                       "an unreadable flag fails closed")
        XCTAssertEqual(service.verifyRelayPairing(credential: pairCredential, keyName: nil, now: t0), .pairingRequired,
                       "a valid credential does not rescue an unreadable flag")
        XCTAssertEqual(try db.relayPairing(tokenHash: RelayPairing.hash(pairCredential))?.lastUsedAt, touched,
                       "the refusals never move last_used_at")
        XCTAssertEqual(gate.reasons, [], "a failed flag read refuses without prompting")
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

    // MARK: management surface (CLI and /api/relay/pairings)

    /// An API handler over a fresh catalog with a recording presence gate.
    private func makePairingAPI() throws -> (handler: APIHandler, gate: RecordingPresenceGate, db: CatalogDB, dir: URL) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        return (APIHandler(service: service, webRoot: dir), gate, db, dir)
    }

    /// One call against the pairings routes; the raw body text comes back for absence checks.
    private func pairCall(
        _ handler: APIHandler, _ method: String, body: [String: Any]? = nil, token: String? = nil,
        path: String = "/api/relay/pairings"
    ) throws -> (status: Int, object: [String: Any], text: String) {
        var headers = ["host": "127.0.0.1:12765"]
        if let token { headers["x-ksf-token"] = token }
        let response = handler.handle(HTTPRequest(
            method: method, path: path, query: [:], headers: headers,
            body: try body.map(JSONValue.data) ?? Data(), serverPort: 12765
        ))
        let text = String(decoding: response.body, as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return (response.status, object, text)
    }

    func testIssueRouteMintsOnceAndStoresOnlyTheHash() throws {
        let (handler, gate, db, dir) = try makePairingAPI()
        let (status, obj, text) = try pairCall(handler, "POST", body: ["label": "github actions"], token: handler.originToken)
        XCTAssertEqual(status, 201, text)
        let credential = try XCTUnwrap(JSONValue.string(obj["credential"]))
        XCTAssertTrue(RelayPairing.looksLikeCredential(credential))
        XCTAssertEqual(gate.reasons, ["pair a remote agent as github actions"], "one presence prompt per mint")
        XCTAssertEqual(text.components(separatedBy: credential).count - 1, 1, "the credential is returned exactly once")

        let row = try XCTUnwrap(try db.relayPairings().first)
        XCTAssertEqual(row.label, "github actions")
        XCTAssertEqual(row.tokenHash, RelayPairing.hash(credential))
        XCTAssertEqual(row.tokenHash.count, 64, "a SHA-256 hex digest, not the credential")
        XCTAssertEqual(row.hint, RelayPairing.hint(credential))
        XCTAssertEqual(row.hint.count, 4)
        assertNoSentinel(credential, in: dir)
        XCTAssertFalse(try db.metaRows(prefix: "").contains { $0.value.contains(credential) })
    }

    func testIssueRoutePersistsKeyScopesAndExpiryAndListShowsMetadataOnly() throws {
        let (handler, _, db, _) = try makePairingAPI()
        let (status, obj, _) = try pairCall(
            handler, "POST", body: ["label": "demo", "keys": ["work", "personal"], "days": 7], token: handler.originToken
        )
        XCTAssertEqual(status, 201, "\(obj)")
        let credential = try XCTUnwrap(JSONValue.string(obj["credential"]))
        let row = try XCTUnwrap(try db.relayPairings().first)
        XCTAssertEqual(row.keys, ["work", "personal"], "repeated --key scopes land in order")
        let created = try XCTUnwrap(UTC.parse(row.createdAt))
        let expiry = try XCTUnwrap(UTC.parse(try XCTUnwrap(row.expiresAt)))
        XCTAssertEqual(expiry.timeIntervalSince(created), 7 * 86_400, accuracy: 2)
        XCTAssertNil(row.revokedAt)
        XCTAssertNil(row.lastUsedAt)

        // No keys and no days: an empty scope (all keys) and the 30-day default; expiry always set.
        let (allStatus, _, _) = try pairCall(handler, "POST", body: ["label": "everything"], token: handler.originToken)
        XCTAssertEqual(allStatus, 201)
        let all = try XCTUnwrap(try db.relayPairings().first { $0.label == "everything" })
        XCTAssertEqual(all.keys, [], "no --key means all keys")
        let allExpiry = try XCTUnwrap(UTC.parse(try XCTUnwrap(all.expiresAt)))
        XCTAssertEqual(allExpiry.timeIntervalSince(try XCTUnwrap(UTC.parse(all.createdAt))), 30 * 86_400, accuracy: 2)

        // GET lists hints and metadata only: never the credential, never its hash.
        let (getStatus, list, listText) = try pairCall(handler, "GET")
        XCTAssertEqual(getStatus, 200)
        let pairings = try XCTUnwrap(list["pairings"] as? [[String: Any]])
        XCTAssertEqual(pairings.count, 2)
        let listed = try XCTUnwrap(pairings.first { JSONValue.string($0["label"]) == "demo" })
        XCTAssertEqual(JSONValue.string(listed["hint"]), String(credential.suffix(4)))
        XCTAssertEqual(listed["keys"] as? [String], ["work", "personal"])
        XCTAssertEqual(listed["revoked"] as? Bool, false)
        XCTAssertNotNil(JSONValue.string(listed["expires_at"]))
        XCTAssertTrue(listed["last_used_at"] is NSNull)
        XCTAssertFalse(listText.contains(credential), "the credential appears in the mint response only")
        XCTAssertFalse(listText.contains(RelayPairing.hash(credential)))
        XCTAssertFalse(listText.contains("token_hash"), "the hash column is never serialized")
        XCTAssertFalse(listText.contains("ksfp_"), "no credential-shaped value on the wire")
    }

    func testRevokeByLabelOrHintRefusesAmbiguity() throws {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Two live pairings share a hint; a third stands alone. Fixed synthetic credentials.
        let sharedA = "ksfp_" + String(repeating: "a", count: 44) + "beef"
        let sharedB = "ksfp_" + String(repeating: "b", count: 44) + "beef"
        let solo = "ksfp_" + String(repeating: "c", count: 44) + "cafe"
        try seedPairing(db, credential: sharedA, label: "ci", at: t0, expiresAt: t0.addingTimeInterval(3600))
        try seedPairing(db, credential: sharedB, label: "laptop", at: t0, expiresAt: t0.addingTimeInterval(3600))
        try seedPairing(db, credential: solo, label: "runner", at: t0, expiresAt: t0.addingTimeInterval(3600))

        // An ambiguous hint revokes nothing and names the colliding labels.
        XCTAssertThrowsError(try service.revokeRelayPairing("beef", now: t0)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("ci"), text)
            XCTAssertTrue(text.contains("laptop"), text)
        }
        XCTAssertEqual(try db.relayPairings().filter { $0.revokedAt != nil }.count, 0, "ambiguity revokes nothing")

        // A unique hint revokes exactly its row; the row and its hash stay.
        let revoked = try service.revokeRelayPairing("cafe", now: t0)
        XCTAssertEqual(revoked.label, "runner")
        XCTAssertEqual(revoked.revokedAt, UTC.iso(t0))
        XCTAssertEqual(try db.relayPairings().count, 3)

        // Labels work too, and a revoked credential stops verifying.
        let byLabel = try service.revokeRelayPairing("ci", now: t0)
        XCTAssertEqual(byLabel.hint, "beef")
        try service.setRelayPairingRequired(true)
        XCTAssertEqual(service.verifyRelayPairing(credential: sharedA, keyName: nil, now: t0), .revoked)
        XCTAssertEqual(service.verifyRelayPairing(credential: sharedB, keyName: nil, now: t0), .ok,
                       "only the named pairing was revoked")

        // Unknown and already-revoked targets fail cleanly and touch nothing.
        XCTAssertThrowsError(try service.revokeRelayPairing("nosuch", now: t0))
        XCTAssertThrowsError(try service.revokeRelayPairing("ci", now: t0)) { error in
            XCTAssertTrue(String(describing: error).contains("already revoked"), "\(error)")
        }
        XCTAssertEqual(try db.relayPairings().count, 3)
        XCTAssertEqual(gate.reasons, [], "revocation never prompts")
    }

    /// The enforcement-toggle route: `required` false costs one prompt in the app (this is
    /// the route the CLI verb delegates to), true costs none, and every refused body is a
    /// 4xx that consumed no prompt. Behind the mutating token gate like the rest of the
    /// pairings family.
    func testRequiredRoutePromptsOnlyForOffAndRefusalsConsumeNoPrompt() throws {
        let (handler, gate, db, _) = try makePairingAPI()

        // on: no prompt, the flag lands, the response reports the mode.
        let (onStatus, onObj, _) = try pairCall(
            handler, "POST", body: ["required": true], token: handler.originToken,
            path: "/api/relay/pairings/required"
        )
        XCTAssertEqual(onStatus, 200)
        XCTAssertEqual(gate.reasons, [], "raising enforcement needs no presence")
        XCTAssertEqual(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "1")
        XCTAssertEqual(onObj["pairing_required"] as? Bool, true)

        // off: exactly one prompt with the house reason, then the write.
        let (offStatus, offObj, _) = try pairCall(
            handler, "POST", body: ["required": false], token: handler.originToken,
            path: "/api/relay/pairings/required"
        )
        XCTAssertEqual(offStatus, 200)
        XCTAssertEqual(gate.reasons, ["stop requiring paired agents on the relay"])
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey))
        XCTAssertEqual(offObj["pairing_required"] as? Bool, false)

        // A bad body is refused before the service method can prompt: 4xx, nothing written.
        // (A JSON number for `required` is deliberately absent from this list: this
        // Foundation's JSONSerialization bridges 1 through `as? Bool` as true, so
        // JSONValue.bool coerces it — the same truth table every other boolean route uses.
        // The coercion cannot bypass presence: only the false direction costs the prompt,
        // and the service method decides that, not the body parser.)
        let badBodies: [[String: Any]?] = [
            nil, [:], ["required": "yes"], ["required": "on"], ["enabled": false],
            ["required": true, "label": "x"],
        ]
        for bad in badBodies {
            let (status, _, _) = try pairCall(
                handler, "POST", body: bad, token: handler.originToken,
                path: "/api/relay/pairings/required"
            )
            XCTAssertEqual(status, 400, "\(String(describing: bad))")
        }
        XCTAssertEqual(gate.reasons.count, 1, "the refused bodies consumed no prompt")
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "they wrote nothing either")

        // Token-gated like the rest of the pairings family: without the token, a 403 that
        // never reached the service method.
        let (gated, _, _) = try pairCall(
            handler, "POST", body: ["required": false], token: nil,
            path: "/api/relay/pairings/required"
        )
        XCTAssertEqual(gated, 403)
        XCTAssertEqual(gate.reasons.count, 1, "the ungated call consumed no prompt")
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "and it wrote nothing")
    }

    func testStatusReportsPairingModeAndActiveCount() throws {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        let t0 = Date()
        var report = service.relayReport()
        XCTAssertFalse(report.pairingRequired, "default off")
        XCTAssertEqual(report.activePairings, 0)

        try seedPairing(db, credential: pairCredential, label: "live", at: t0, expiresAt: t0.addingTimeInterval(3600))
        try seedPairing(db, credential: pairCredentialB, label: "gone", at: t0, expiresAt: t0.addingTimeInterval(3600), revoked: true)
        try seedPairing(db, credential: unknownCredential, label: "old", at: t0, expiresAt: t0.addingTimeInterval(-60))
        try service.setRelayPairingRequired(true)

        report = service.relayReport()
        XCTAssertTrue(report.pairingRequired)
        XCTAssertEqual(report.activePairings, 1, "revoked and expired pairings are not active")

        let json = APIHandler.relayJSON(report)
        XCTAssertEqual(json["pairing_required"] as? Bool, true)
        XCTAssertEqual(json["active_pairings"] as? Int, 1)
        let text = String(decoding: try JSONValue.data(json), as: UTF8.self)
        XCTAssertFalse(text.contains("ksfp_"), "status carries a mode and a count, never a credential")
        XCTAssertEqual(RelayCommand.pairingLine(required: true, active: 1), "required, 1 active")
        XCTAssertEqual(RelayCommand.pairingLine(required: false, active: 2), "off, 2 active")
    }

    func testPairCLIParsingRefusesBadInputBeforeAnyAppContact() throws {
        // Repeated --key and --days parse like keys client issue.
        let parsed = try RelayPairCommand.parseAsRoot(["issue", "demo", "--key", "work", "--key", "personal", "--days", "7"])
        let issue = try XCTUnwrap(parsed as? RelayPairIssueCommand)
        XCTAssertEqual(issue.label, "demo")
        XCTAssertEqual(issue.keys, ["work", "personal"])
        XCTAssertEqual(issue.days, 7)

        // Zero or negative days, a non-numeric days and unknown flags fail in parsing itself
        // (parseAsRoot runs validate()), before run() could reach the running app.
        for bad in [
            ["issue", "demo", "--days", "0"], ["issue", "demo", "--days", "-1"],
            ["issue", "demo", "--bogus"], ["issue", "demo", "--days", "abc"],
        ] {
            XCTAssertThrowsError(try RelayPairCommand.parseAsRoot(bad), "\(bad)")
        }

        // `require` takes only on|off; anything else is a usage error in run(), still before
        // the command opens the catalog or contacts the app.
        let require = try XCTUnwrap(try RelayPairCommand.parseAsRoot(["require", "maybe"]) as? RelayPairRequireCommand)
        XCTAssertThrowsError(try require.run()) { error in
            XCTAssertTrue(String(describing: error).contains("on|off"), "\(error)")
        }

        // The two valid states parse; run() is not driven here because with a valid state it
        // would reach whatever site owns the default control file — the round-trip test
        // below drives the delegated call against an in-process site instead.
        let off = try XCTUnwrap(try RelayPairCommand.parseAsRoot(["require", "off"]) as? RelayPairRequireCommand)
        XCTAssertEqual(off.state, "off")
        let on = try XCTUnwrap(try RelayPairCommand.parseAsRoot(["require", "on"]) as? RelayPairRequireCommand)
        XCTAssertEqual(on.state, "on")

        // No verb: the group itself runs and answers with usage, not a connection attempt.
        var bare = try RelayPairCommand.parseAsRoot([])
        XCTAssertThrowsError(try bare.run()) { error in
            XCTAssertTrue(String(describing: error).contains("keys relay pair"), "\(error)")
        }
    }

    /// The verb's real path is the control file: `keys relay pair require` delegates to the
    /// running site, which owns the catalog and the one Touch ID the off-toggle costs —
    /// exactly the call RelayPairRequireCommand.run() makes, driven here against an
    /// in-process site so the prompt lands in the app, never in the Terminal.
    func testRequireVerbDelegatesThroughTheControlFileAndPromptsInTheApp() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.setRelayPairingRequired(true)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let handler = APIHandler(service: service, webRoot: web)
        let server = try LoopbackHTTPServer(port: 0) { handler.handle($0) }
        server.start()
        defer { server.stop() }
        let control = ControlFile.url(beside: db.path)
        try ControlFile.write(port: server.boundPort, token: handler.originToken, to: control)

        let client = try ControlClient.connect(control: control)
        let off = try client.call(
            method: "POST", path: "/api/relay/pairings/required", body: ["required": false], expect: 200
        )
        XCTAssertEqual(off["pairing_required"] as? Bool, false)
        XCTAssertEqual(gate.reasons, ["stop requiring paired agents on the relay"], "the prompt happens in the app")
        XCTAssertNil(try db.metaValue(KeysService.relayPairingRequiredMetaKey))

        let on = try client.call(
            method: "POST", path: "/api/relay/pairings/required", body: ["required": true], expect: 200
        )
        XCTAssertEqual(on["pairing_required"] as? Bool, true)
        XCTAssertEqual(gate.reasons.count, 1, "require on performs no prompt anywhere")

        // A refused body over the wire reads back as its message and consumes no prompt.
        XCTAssertThrowsError(try client.call(
            method: "POST", path: "/api/relay/pairings/required", body: ["required": "maybe"], expect: 200
        )) { error in
            guard case AppError.usage(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("true or false"), m)
        }
        XCTAssertEqual(gate.reasons.count, 1, "the refusal consumed no prompt")
        XCTAssertEqual(try db.metaValue(KeysService.relayPairingRequiredMetaKey), "1",
                       "the flag stayed exactly where require on left it")
    }
}
