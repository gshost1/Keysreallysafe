import Security
import XCTest
@testable import KeysCore

final class SecretStoreTests: XCTestCase {
    func testMemoryAddGetDelete() throws {
        let store = MemorySecretStore()
        try store.add(name: "xai", secret: fixtureSecret)
        XCTAssertEqual(try store.get(name: "xai"), fixtureSecret)
        try store.delete(name: "xai")
        XCTAssertThrowsError(try store.get(name: "xai"))
    }

    func testInvalidNameRejected() {
        let store = MemorySecretStore()
        XCTAssertThrowsError(try store.add(name: "Bad Name", secret: "x"))
        XCTAssertThrowsError(try store.add(name: "-leading", secret: "x"))
        XCTAssertThrowsError(try KeyName.validate("XAI"))
        XCTAssertNoThrow(try KeyName.validate("xai"))
        XCTAssertNoThrow(try KeyName.validate("openai.prod-1"))
    }

    func testListPresenterNamesOnlyNeverSecret() throws {
        let (db, _) = try makeDB()
        let (service, _, clipboard) = makeService(db: db)
        try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "n", secret: fixtureSecret)
        let rows = try service.list()
        XCTAssertEqual(rows.map(\.name), ["xai"])
        let encoded = String(data: try JSONValue.data(service.listJSONObject()), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(fixtureSecret))
        XCTAssertFalse(encoded.contains("\"secret\""))
        try service.copy(name: "xai", holdUntilWipe: false)
        XCTAssertEqual(clipboard.value, fixtureSecret)
        XCTAssertEqual(clipboard.lastBackgroundWipe, 20)
        let revealed = try service.reveal(name: "xai")
        XCTAssertEqual(revealed, fixtureSecret)
        let listedAgain = String(data: try JSONValue.data(service.listJSONObject()), encoding: .utf8)!
        XCTAssertFalse(listedAgain.contains(fixtureSecret))
    }

    func testAddRollsBackCatalogWhenKeychainFailsAfterInsertWouldConflict() throws {
        let (db, _) = try makeDB()
        let secrets = MemorySecretStore()
        try secrets.add(name: "xai", secret: "already")
        let (service, _) = makeGatedService(db: db, secrets: secrets)
        XCTAssertThrowsError(
            try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        )
        XCTAssertTrue(try db.listCatalog().isEmpty)
    }

    func testKeychainQueriesStayFileBasedForAdHocCLI() {
        let query = KeychainQuery.item(service: "keysreallysafe", name: "xai")
        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "keysreallysafe")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "xai")
        // Data-protection keychain returns errSecMissingEntitlement (-34018)
        // for an ad-hoc signed CLI. File-based + kSecAttrAccessControl returns
        // errSecAuthFailed (-25293). Presence is LocalAuthentication on get.
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(query[kSecAttrAccessControl as String])
        XCTAssertNil(query[kSecAttrSynchronizable as String])
    }

    func testCopyAndRevealRequirePresenceAddDoesNot() throws {
        let (db, _) = try makeDB()
        let clipboard = FakeClipboard()
        let (service, gate) = makeGatedService(db: db, clipboard: clipboard)
        try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        XCTAssertEqual(gate.reasons, [])
        try service.copy(name: "xai", holdUntilWipe: false)
        XCTAssertEqual(clipboard.value, fixtureSecret)
        XCTAssertEqual(try service.reveal(name: "xai"), fixtureSecret)
        XCTAssertEqual(gate.reasons, ["Unlock xai", "Unlock xai"])
    }

    func testFailedPresenceReadsNothing() throws {
        let (db, _) = try makeDB()
        let clipboard = FakeClipboard()
        let (service, gate) = makeGatedService(db: db, clipboard: clipboard)
        try service.add(name: "xai", provider: "xai", kind: "runtime", notes: "", secret: fixtureSecret)
        gate.error = .authFailed
        XCTAssertThrowsError(try service.copy(name: "xai", holdUntilWipe: false)) { error in
            guard let app = error as? AppError, case .authFailed = app else {
                return XCTFail("expected authFailed, got \(error)")
            }
        }
        XCTAssertNil(clipboard.value, "a failed presence check leaves the clipboard empty")
        XCTAssertThrowsError(try service.reveal(name: "xai"))
        XCTAssertTrue(try service.keyEvents(name: "xai").allSatisfy { $0.action == "add" }, "nothing was read")
    }
}
