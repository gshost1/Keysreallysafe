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
        let manager = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock })
        XCTAssertEqual(try manager.status().state, .trial)
        clock = t0.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(try manager.status().state, .expired)
        let key = try LicenseKey.sign(payload(), privateKey: signer)
        XCTAssertThrowsError(try manager.activate("keysrs1.nope.nope"))
        XCTAssertEqual(try manager.activate(key).state, .licensed)
        XCTAssertTrue(manager.isActive)
        XCTAssertNoThrow(try manager.requireActive())
        let reopened = LicenseManager(catalog: db, publicKeyBase64: publicKey, now: { clock })
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
}
