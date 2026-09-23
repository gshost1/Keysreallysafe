import CryptoKit
import Foundation
import XCTest
@testable import KeysCore

/// Keys are verified offline against a public key; the trial is fourteen days
/// from the first status call; a lapsed trial stops ingestion and grants but
/// never the vault.
final class LicenseTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let macA = "0b8f2c1e-5d3a-4c2b-9e7f-1a2b3c4d5e6f", macB = "1c9f2c1e-5d3a-4c2b-9e7f-1a2b3c4d5e6f", macC = "2d0f2c1e-5d3a-4c2b-9e7f-1a2b3c4d5e6f"
    private let day: TimeInterval = 86_400

    private func manager(_ db: CatalogDB, _ server: FakeLicenseServer, mac: String, clock: @escaping @Sendable () -> Date) -> LicenseManager {
        LicenseManager(catalog: db, publicKeyBase64: publicKey, now: clock, server: server, identity: FixedIdentity(id: mac), model: "Mac15,6")
    }

    private func payload(major: Int = LicenseConfiguration.major, v: Int = 1, iat: Int? = nil) -> LicensePayload {
        LicensePayload(v: v, id: "cs_test_123", email: "buyer@example.com", iat: iat ?? Int(t0.timeIntervalSince1970), major: major)
    }

    func testSignedKeyVerifiesAndRoundTrips() throws {
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        XCTAssertTrue(key.hasPrefix("keysrs1."))
        XCTAssertEqual(try LicenseKey.verify(key, publicKeyBase64: publicKey, now: t0), payload())
        // Whitespace around a pasted key is forgiven; nothing inside it is.
        XCTAssertEqual(try LicenseKey.verify("  \(key)\n", publicKeyBase64: publicKey, now: t0), payload())
    }

    func testTamperedPayloadOrSignatureIsRejected() throws {
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        var parts = key.split(separator: ".").map(String.init)
        let other = LicensePayload(v: 1, id: "cs_test_123", email: "thief@example.com", iat: payload().iat, major: 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        parts[1] = LicenseKey.base64url(try encoder.encode(other))
        XCTAssertThrowsError(try LicenseKey.verify(parts.joined(separator: "."), publicKeyBase64: publicKey, now: t0)) {
            XCTAssertEqual($0 as? LicenseError, .badSignature)
        }
        let stranger = Curve25519.Signing.PrivateKey()
        let foreign = try LicenseKey.sign(payload(), privateKey: stranger)
        XCTAssertThrowsError(try LicenseKey.verify(foreign, publicKeyBase64: publicKey, now: t0)) {
            XCTAssertEqual($0 as? LicenseError, .badSignature)
        }
        for junk in ["", "keysrs1", "keysrs1..", "keysrs2.a.b", "hello world", String(repeating: "k", count: 3_000)] {
            XCTAssertThrowsError(try LicenseKey.verify(junk, publicKeyBase64: publicKey, now: t0), junk) {
                XCTAssertEqual($0 as? LicenseError, .malformed)
            }
        }
    }

    func testWrongMajorVersionAndFutureKeysAreRejected() throws {
        let nextMajor = try LicenseKey.sign(payload(major: LicenseConfiguration.major + 1), privateKey: signer)
        XCTAssertThrowsError(try LicenseKey.verify(nextMajor, publicKeyBase64: publicKey, now: t0)) {
            XCTAssertEqual($0 as? LicenseError, .wrongMajor(LicenseConfiguration.major + 1))
        }
        let v2 = try LicenseKey.sign(payload(v: 2), privateKey: signer)
        XCTAssertThrowsError(try LicenseKey.verify(v2, publicKeyBase64: publicKey, now: t0)) {
            XCTAssertEqual($0 as? LicenseError, .unsupportedVersion)
        }
        let future = try LicenseKey.sign(payload(iat: Int(t0.timeIntervalSince1970) + 3 * 86_400), privateKey: signer)
        XCTAssertThrowsError(try LicenseKey.verify(future, publicKeyBase64: publicKey, now: t0)) {
            XCTAssertEqual($0 as? LicenseError, .futureDated)
        }
    }

    func testTrialStartsOnceAndLapsesAfterFourteenDays() throws {
        let (db, _) = try makeDB()
        nonisolated(unsafe) var clock = t0
        let manager = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock })
        let first = try manager.status()
        XCTAssertEqual(first.state, .trial)
        XCTAssertEqual(first.daysLeft, 14)
        XCTAssertEqual(first.trialStartedAt, t0)
        clock = t0.addingTimeInterval(13.5 * 86_400)
        let late = try manager.status()
        XCTAssertEqual(late.state, .trial)
        XCTAssertEqual(late.daysLeft, 1)
        XCTAssertEqual(late.trialStartedAt, t0, "the start never moves")
        clock = t0.addingTimeInterval(14 * 86_400)
        let lapsed = try manager.status()
        XCTAssertEqual(lapsed.state, .expired)
        XCTAssertEqual(lapsed.daysLeft, 0)
        XCTAssertFalse(lapsed.isActive)
        XCTAssertThrowsError(try manager.requireActive())
        // A second manager on the same catalog (another process) sees the same trial.
        let again = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock })
        XCTAssertEqual(try again.status().trialStartedAt, t0)
    }

    func testActivationPersistsAndRemovalReturnsToTrialState() throws {
        let (db, _) = try makeDB()
        nonisolated(unsafe) var clock = t0
        let server = FakeLicenseServer(signer: signer, now: { clock })
        let manager = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock },
                                     server: server, identity: FixedIdentity(id: macA), model: "Mac15,6")
        XCTAssertEqual(try manager.status().state, .trial)
        clock = t0.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(try manager.status().state, .expired)
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        XCTAssertThrowsError(try manager.activate("keysrs1.nope.nope"))
        XCTAssertEqual(try manager.activate(key).state, .licensed)
        XCTAssertTrue(manager.isActive)
        XCTAssertNoThrow(try manager.requireActive())
        let reopened = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock },
                                      server: server, identity: FixedIdentity(id: macA), model: "Mac15,6")
        XCTAssertEqual(try reopened.status().license?.email, "buyer@example.com")
        XCTAssertEqual(try reopened.deactivate().state, .expired, "removing a key does not restart the trial")
        clock = t0
        XCTAssertEqual(try reopened.status().trialStartedAt, t0, "a clock wound back does not either")
        clock = t0.addingTimeInterval(-5 * 86_400)
        XCTAssertEqual(try reopened.status().trialStartedAt, t0, "even before the recorded start")
    }

    func testLapsedTrialBlocksIngestionButNotTheVault() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try service.add(name: "openai-main", provider: "openai", kind: "runtime", notes: "", secret: "sk-test-value")
        // Force the trial into the past through the same meta row the manager reads.
        try db.setMeta(LicenseManager.trialKey, UTC.iso(Date(timeIntervalSinceNow: -20 * 86_400)))
        XCTAssertEqual(try service.license.status().state, .expired)
        XCTAssertThrowsError(try service.ingest(.all)) { error in
            XCTAssertTrue("\(error)".contains("trial ended"), "\(error)")
        }
        XCTAssertEqual(try service.list().map(\.name), ["openai-main"], "the vault still lists")
        XCTAssertEqual(try service.reveal(name: "openai-main"), "sk-test-value", "and still reveals")
    }

    func testLapsedTrialAlsoStopsTheDashboardsStaleRefresh() throws {
        let (db, _) = try makeDB()
        let (service, _, _) = makeService(db: db)
        try db.setMeta(LicenseManager.trialKey, UTC.iso(Date(timeIntervalSinceNow: -20 * 86_400)))
        // /api/spend calls this on every load; it must hit the same gate as `keys ingest`.
        XCTAssertThrowsError(try service.ingestIfStale(olderThan: 0)) { error in
            XCTAssertTrue("\(error)".contains("trial ended"), "\(error)")
        }
        XCTAssertNil(try db.lastIngestAt(), "nothing was ingested")
    }

    func testLicenseEndpointReportsStateAndRejectsBadKeys() throws {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html></html>".write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let handler = APIHandler(service: service, webRoot: web)
        func call(_ method: String, _ body: String = "", token: Bool = true) throws -> (Int, [String: Any]) {
            var headers = ["host": "127.0.0.1:12765"]
            if token { headers["x-ksf-token"] = handler.originToken }
            let response = handler.handle(HTTPRequest(method: method, path: "/api/license", query: [:], headers: headers,
                                                      body: Data(body.utf8), serverPort: 12765))
            return (response.status, (try JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
        }
        let (getStatus, state) = try call("GET")
        XCTAssertEqual(getStatus, 200)
        XCTAssertEqual(state["state"] as? String, "trial")
        XCTAssertEqual(state["days_left"] as? Int, 14)
        XCTAssertEqual(try call("POST", #"{"key":"keysrs1.a.b"}"#, token: false).0, 403, "activation needs the page token")
        let (badStatus, bad) = try call("POST", #"{"key":"keysrs1.a.b"}"#)
        XCTAssertEqual(badStatus, 400)
        XCTAssertEqual(bad["error"] as? String, "invalid_license")
        XCTAssertNotNil(bad["reason"] as? String)
        XCTAssertEqual(try call("POST", #"{"key":"x","extra":1}"#).1["error"] as? String, "invalid_license_request")
        XCTAssertEqual(try call("DELETE").1["state"] as? String, "trial")
    }

    func testActivationChecksInEveryThirtyDaysAndLapsesAfterTheGracePeriod() throws {
        let (db, _) = try makeDB()
        nonisolated(unsafe) var clock = t0
        let server = FakeLicenseServer(signer: signer, now: { clock })
        let mac = manager(db, server, mac: macA, clock: { clock })
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        let active = try mac.activate(key)
        XCTAssertEqual(active.state, .licensed)
        XCTAssertEqual(active.activation?.due, Int(t0.timeIntervalSince1970 + 30 * day))
        XCTAssertEqual(server.calls, 1)

        clock = t0.addingTimeInterval(29 * day)
        mac.checkInIfDue()
        XCTAssertEqual(server.calls, 1, "nothing is sent before the check-in is due")

        clock = t0.addingTimeInterval(31 * day)
        mac.checkInIfDue()
        XCTAssertEqual(server.calls, 2)
        XCTAssertEqual(try mac.status().activation?.due, Int(clock.timeIntervalSince1970 + 30 * day), "a check-in renews the activation")

        // Offline from here: the Mac keeps working through the grace period, then stops.
        server.mode = .unreachable
        let renewedAt = clock
        clock = renewedAt.addingTimeInterval(43 * day)
        mac.checkInIfDue()
        XCTAssertEqual(try mac.status().state, .licensed, "still inside 30 + 14 days")
        clock = renewedAt.addingTimeInterval(45 * day)
        let lapsed = try mac.status()
        XCTAssertEqual(lapsed.state, .unconfirmed)
        XCTAssertFalse(lapsed.isActive)
        XCTAssertThrowsError(try mac.requireActive()) { XCTAssertTrue("\($0)".contains("confirming"), "\($0)") }

        // Back online, the next check-in restores it.
        server.mode = .ok
        clock = clock.addingTimeInterval(2 * LicenseManager.retryInterval)
        mac.checkInIfDue()
        XCTAssertEqual(try mac.status().state, .licensed)
    }

    func testAKeyActivatesOnTwoMacsAndACopiedCatalogDoesNotCount() throws {
        nonisolated(unsafe) let clock = t0.addingTimeInterval(20 * day)   // trial over everywhere
        let server = FakeLicenseServer(signer: signer, now: { clock })
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        let (dbA, _) = try makeDB(), (dbB, _) = try makeDB(), (dbC, _) = try makeDB()
        for db in [dbA, dbB, dbC] { try db.setMeta(LicenseManager.trialKey, UTC.iso(t0)) }
        let a = manager(dbA, server, mac: macA, clock: { clock })
        XCTAssertEqual(try a.activate(key).state, .licensed)
        XCTAssertEqual(try manager(dbB, server, mac: macB, clock: { clock }).activate(key).state, .licensed)
        let c = manager(dbC, server, mac: macC, clock: { clock })
        XCTAssertThrowsError(try c.activate(key)) { XCTAssertEqual($0 as? LicenseServerError, .seatLimit(2)) }
        XCTAssertEqual(try c.status().state, .expired, "a refused activation stores nothing")

        // Mac A's catalog copied onto Mac C: the activation names Mac A, so it does not count.
        let copy = manager(dbA, server, mac: macC, clock: { clock })
        XCTAssertEqual(try copy.status().state, .unconfirmed)

        // Removing the key on Mac A frees its seat for Mac C.
        XCTAssertEqual(try a.deactivate().state, .expired)
        XCTAssertEqual(try c.activate(key).state, .licensed)

        // An activation signed by anyone but keysrs.com is refused.
        let forger = FakeLicenseServer(signer: Curve25519.Signing.PrivateKey(), now: { clock })
        let (dbD, _) = try makeDB()
        XCTAssertThrowsError(try manager(dbD, forger, mac: macA, clock: { clock }).activate(key)) {
            XCTAssertEqual($0 as? LicenseServerError, .rejected)
        }
    }

    /// Produced by worker/index.js `signToken` with a test seed of 32 bytes of 7:
    /// the site and the app agree on the activation format byte for byte.
    func testAnActivationFromTheSiteVerifiesInTheApp() throws {
        let token = "keysrsa1.eyJkdWUiOjE3OTI1OTIwMDAsImV4cCI6MTc5MzgwMTYwMCwiaWF0IjoxNzkwMDAwMDAwLCJpaWQiOiIwYjhmMmMxZS01ZDNhLTRjMmItOWU3Zi0xYTJiM2M0ZDVlNmYiLCJsaWQiOiJjc19saXZlX2FiYyIsInYiOjF9.VaLP-IKXJbKoh5zf0ITf13DL2GD-836XrRxY3wWPRO6YD3CfUdhTDgzGPtTM8ylbMzxzFBML6R9ogK39hsNJDA"
        let site = "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw="
        XCTAssertEqual(try ActivationToken.verify(token, publicKeyBase64: site),
                       ActivationPayload(v: 1, lid: "cs_live_abc", iid: macA, iat: 1_790_000_000, due: 1_792_592_000, exp: 1_793_801_600))
        // The same bytes are never a license key, and a license key is never an activation.
        XCTAssertThrowsError(try LicenseKey.verify(token, publicKeyBase64: site))
        XCTAssertThrowsError(try ActivationToken.verify(try LicenseKey.sign(payload(), privateKey: signer), publicKeyBase64: publicKey))
    }

    func testRevocationAtCheckInEndsTheActivationAndRetriesAreHourly() throws {
        let (db, _) = try makeDB()
        nonisolated(unsafe) var clock = t0
        let server = FakeLicenseServer(signer: signer, now: { clock })
        let mac = manager(db, server, mac: macA, clock: { clock })
        try mac.activate(try LicenseKey.sign(payload(), privateKey: signer))
        server.mode = .revoked
        clock = t0.addingTimeInterval(31 * day)
        mac.checkInIfDue()
        let revoked = try mac.status()
        XCTAssertEqual(revoked.state, .unconfirmed)
        XCTAssertEqual(revoked.problem, .revoked)
        XCTAssertEqual(revoked.json["state"] as? String, "unconfirmed")
        let calls = server.calls
        clock = clock.addingTimeInterval(60)
        mac.checkInIfDue()
        XCTAssertEqual(server.calls, calls, "no second call within the hour")
    }
}

private struct FixedIdentity: InstallIdentity {
    let id: String
    func installID() throws -> String { id }
}

/// keysrs.com's activation rules in memory: two Macs per license, signed tokens.
private final class FakeLicenseServer: LicenseServer, @unchecked Sendable {
    enum Mode { case ok, revoked, unreachable }
    let signer: Curve25519.Signing.PrivateKey
    let now: @Sendable () -> Date
    var mode = Mode.ok
    var calls = 0
    private var macs: [String: [String]] = [:]

    init(signer: Curve25519.Signing.PrivateKey, now: @escaping @Sendable () -> Date) {
        self.signer = signer
        self.now = now
    }

    func activate(key: String, installID: String, model: String) throws -> String {
        calls += 1
        switch mode {
        case .revoked: throw LicenseServerError.revoked
        case .unreachable: throw LicenseServerError.unreachable
        case .ok: break
        }
        let parts = key.split(separator: ".")
        guard parts.count == 3, let data = LicenseKey.base64urlDecode(String(parts[1])),
              let license = try? JSONDecoder().decode(LicensePayload.self, from: data) else { throw LicenseServerError.rejected }
        var list = macs[license.id] ?? []
        if !list.contains(installID) {
            guard list.count < LicenseConfiguration.seats else { throw LicenseServerError.seatLimit(LicenseConfiguration.seats) }
            list.append(installID)
        }
        macs[license.id] = list
        let t = Int(now().timeIntervalSince1970)
        return try ActivationToken.sign(ActivationPayload(v: 1, lid: license.id, iid: installID, iat: t,
                                                          due: t + 30 * 86_400, exp: t + 44 * 86_400), privateKey: signer)
    }

    func deactivate(key: String, installID: String) {
        for id in macs.keys { macs[id]?.removeAll { $0 == installID } }
    }
}
