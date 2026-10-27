import XCTest
@testable import KeysCore

/// Profiles: named, saved, issuance-time bounds on grants. A profile row holds names and
/// numbers only — no secret, no token, no hash — and the gateway's request path never
/// reads it. This suite pins the save-time refusal matrix (each bad shape its own named
/// error), the catalog round-trip and its bounds-only guarantee (sentinel), containment
/// (a request may tighten a profile, never exceed it), the unattended-requires-a-cap rule,
/// and the `keys profile` commands running straight off the catalog with no site and no
/// presence prompt.
final class ProfileTests: XCTestCase {
    private func gatedService() throws -> (KeysService, RecordingPresenceGate, CatalogDB, URL) {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        return (service, gate, db, dir)
    }

    /// A service with two vault keys, so profile key lists can name more than one.
    private func serviceWithKeys() throws -> (KeysService, RecordingPresenceGate, CatalogDB, URL) {
        let (service, gate, db, dir) = try gatedService()
        try service.add(name: "router", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
        try service.add(name: "spare", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret + "2")
        return (service, gate, db, dir)
    }

    /// The unvalidated ask, with the profile defaults for anything unsaid.
    private func draft(
        name: String = "evals",
        keys: [String] = ["router"],
        methods: Set<String>? = nil,
        paths: [String]? = nil,
        minutes: Int? = nil,
        maxRequests: Int? = nil,
        maxUsd: Double? = nil,
        unattended: Bool = false
    ) -> ProfileRequest {
        ProfileRequest(
            name: name,
            keys: keys,
            methods: methods ?? Grant.allMethods,
            paths: paths ?? [],
            minutes: minutes ?? Grant.defaultMinutes,
            maxRequests: maxRequests,
            maxUsd: maxUsd,
            unattended: unattended
        )
    }

    /// A saved profile for containment checks; ids and dates are fixed so only bounds vary.
    private func saved(
        methods: Set<String> = Grant.allMethods,
        paths: [String] = [],
        minutes: Int = 480,
        maxRequests: Int? = nil,
        maxUsd: Double? = nil,
        unattended: Bool = false
    ) -> Profile {
        Profile(
            id: "00000000",
            name: "evals",
            keys: ["router"],
            methods: methods,
            paths: paths,
            minutes: minutes,
            maxRequests: maxRequests,
            maxUsd: maxUsd,
            unattended: unattended,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func assertRefuses(
        _ expected: ProfileError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body() as Any, file: file, line: line) { error in
            guard let profileError = error as? ProfileError else {
                return XCTFail("expected \(expected), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(profileError, expected, "\(profileError)", file: file, line: line)
            XCTAssertFalse(profileError.message.isEmpty, "named errors carry a human message", file: file, line: line)
        }
    }

    /// One command's printed output, with stdout briefly pointed at a temp file. The profile
    /// commands print (rather than return) their rows, so their bytes are what gets pinned.
    @discardableResult
    private func capturingStdout(_ body: () throws -> Void) rethrows -> String {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("krs-profile-out-\(UUID().uuidString)")
        let saved = dup(STDOUT_FILENO)
        defer {
            dup2(saved, STDOUT_FILENO)
            close(saved)
            try? FileManager.default.removeItem(at: out)
        }
        guard freopen(out.path, "w", stdout) != nil else { return "" }
        try body()
        // `print` buffers inside the FILE; the bytes are only in the file once flushed.
        fflush(stdout)
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }

    func testValidationRefusesEveryBadShapeWithItsOwnNamedError() throws {
        // The wire codes the dashboard API will surface, pinned here so they cannot drift.
        XCTAssertEqual(ProfileError.nameInvalid.code, "profile_name_invalid")
        XCTAssertEqual(ProfileError.nameTaken("evals").code, "profile_name_taken")
        XCTAssertEqual(ProfileError.keysMissing.code, "profile_key_unknown")
        XCTAssertEqual(ProfileError.keyUnknown("ghost").code, "profile_key_unknown")
        XCTAssertEqual(ProfileError.methodMissing.code, "profile_method_unknown")
        XCTAssertEqual(ProfileError.methodUnknown("FETCH").code, "profile_method_unknown")
        XCTAssertEqual(ProfileError.pathInvalid("/a?b").code, "profile_path_invalid")
        XCTAssertEqual(ProfileError.minutesRange.code, "profile_minutes_range")
        XCTAssertEqual(ProfileError.requestCapInvalid.code, "profile_request_cap_invalid")
        XCTAssertEqual(ProfileError.usdCapInvalid.code, "profile_usd_cap_invalid")
        XCTAssertEqual(ProfileError.requiresCap.code, "profile_requires_cap")
        XCTAssertEqual(ProfileError.notFound("evals").code, "profile_not_found")

        // Names: a profile name appears in the Touch ID prompt and in JSON, so it follows
        // the key-name charset rather than free text.
        for bad in ["", "   ", "night evals", "Профиль", String(repeating: "a", count: 129)] {
            assertRefuses(.nameInvalid) { try draft(name: bad).validated() }
        }
        XCTAssertTrue(ProfileError.nameInvalid.message.contains("[a-z0-9]"), ProfileError.nameInvalid.message)

        // Keys and methods: an explicitly empty list is refused, an unknown member too.
        assertRefuses(.keysMissing) { try draft(keys: []).validated() }
        assertRefuses(.methodMissing) { try draft(methods: []).validated() }
        assertRefuses(.methodUnknown("FETCH")) { try draft(methods: ["GET", "FETCH"]).validated() }
        XCTAssertTrue(ProfileError.keyUnknown("ghost").message.contains("ghost"))

        // Paths: the same rules a grant scope follows, refused per bad path.
        for bad in ["/a?b", "/a/../b", "/a b", "a/../b"] {
            assertRefuses(.pathInvalid(bad)) { try draft(paths: ["/models", bad]).validated() }
        }

        // Minutes, caps, unattended.
        assertRefuses(.minutesRange) { try draft(minutes: 0).validated() }
        assertRefuses(.minutesRange) { try draft(minutes: Grant.maxMinutes + 1).validated() }
        assertRefuses(.requestCapInvalid) { try draft(maxRequests: 0).validated() }
        assertRefuses(.usdCapInvalid) { try draft(maxUsd: 0).validated() }
        assertRefuses(.usdCapInvalid) { try draft(maxUsd: -1).validated() }
        assertRefuses(.requiresCap) { try draft(unattended: true).validated() }
        let capMessage = ProfileError.requiresCap.message
        XCTAssertTrue(capMessage.contains("--max-requests") && capMessage.contains("--max-usd"), capMessage)

        // Valid shapes normalize exactly as grant scopes do, and keys de-duplicate in order.
        let r = try draft(
            keys: ["router", "router", "spare"],
            methods: ["get", "POST "],
            paths: ["v1/messages/", "/chat/completions"],
            minutes: 90
        ).validated()
        XCTAssertEqual(r.name, "evals")
        XCTAssertEqual(r.keys, ["router", "spare"])
        XCTAssertEqual(r.methods, ["GET", "POST"])
        XCTAssertEqual(r.paths, ["/v1/messages", "/chat/completions"])
        XCTAssertEqual(r.minutes, 90)
    }

    func testAnUnattendedProfileNeedsAtLeastOneHardCap() throws {
        let (service, gate, _, _) = try serviceWithKeys()
        assertRefuses(.requiresCap) {
            try service.addProfile(draft(unattended: true))
        }
        XCTAssertEqual(try service.listProfiles().count, 0, "a refused profile saved nothing")

        // Either hard cap makes an unattended profile saveable.
        let byRequests = try service.addProfile(draft(maxRequests: 500, unattended: true))
        XCTAssertEqual(byRequests.unattended, true)
        XCTAssertEqual(byRequests.maxRequests, 500)
        let byUsd = try service.addProfile(draft(name: "evals-usd", maxUsd: 2, unattended: true))
        XCTAssertEqual(byUsd.unattended, true)
        XCTAssertEqual(byUsd.maxUsd, 2)
        XCTAssertEqual(try service.listProfiles().map(\.name), ["evals", "evals-usd"])

        // Profiles hold no secret and no capability, so nothing about them prompts.
        XCTAssertEqual(gate.reasons, [])
    }

    func testProfileCRUDRoundTripsThroughTheCatalogStoringBoundsOnly() throws {
        let (service, _, db, dir) = try serviceWithKeys()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let savedProfile = try service.addProfile(
            draft(keys: ["router", "spare"], methods: ["GET", "POST"], paths: ["/v1/messages"], minutes: 480, maxUsd: 2.5),
            now: now
        )
        // The id is the grant-id shape: 8 lowercase hex digits.
        XCTAssertEqual(savedProfile.id.count, 8)
        XCTAssertTrue(savedProfile.id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, savedProfile.id)
        XCTAssertEqual(savedProfile.createdAt, now)
        XCTAssertEqual(savedProfile.updatedAt, now)

        let json = savedProfile.jsonObject()
        XCTAssertEqual(json["id"] as? String, savedProfile.id)
        XCTAssertEqual(json["name"] as? String, "evals")
        XCTAssertEqual(json["keys"] as? [String], ["router", "spare"])
        XCTAssertEqual(json["methods"] as? [String], ["GET", "POST"])
        XCTAssertEqual(json["paths"] as? [String], ["/v1/messages"])
        XCTAssertEqual(json["minutes"] as? Int, 480)
        XCTAssertTrue(json["max_requests"] is NSNull)
        XCTAssertEqual(json["max_usd"] as? Double, 2.5)
        XCTAssertEqual(json["unattended"] as? Bool, false)
        XCTAssertEqual(Set(json.keys), Set([
            "id", "name", "keys", "methods", "paths", "minutes",
            "max_requests", "max_usd", "unattended", "created_at", "updated_at",
        ]))

        // Fetch by name, list, and a reopen of the same catalog: the row is the storage.
        XCTAssertEqual(try service.profile(name: "evals"), savedProfile)
        XCTAssertEqual(try service.listProfiles(), [savedProfile])
        let reopened = try CatalogDB(path: db.path)
        XCTAssertEqual(try reopened.listProfiles(), [savedProfile])
        XCTAssertNil(try reopened.profile(name: "nope"))

        // Remove, and the named refusal for what is no longer there.
        let removed = try service.removeProfile(name: "evals")
        XCTAssertEqual(removed, savedProfile)
        XCTAssertEqual(try service.listProfiles(), [])
        assertRefuses(.notFound("evals")) { try service.profile(name: "evals") }
        assertRefuses(.notFound("evals")) { try service.removeProfile(name: "evals") }

        // The sentinel: only names and bounds ever reached the catalog's directory.
        assertNoSentinel(fixtureSecret, in: dir)
    }

    func testDuplicateNamesAndUnknownKeysAreRefusedAgainstTheVault() throws {
        let (service, gate, _, _) = try serviceWithKeys()
        _ = try service.addProfile(draft())
        assertRefuses(.nameTaken("evals")) { try service.addProfile(draft()) }
        assertRefuses(.keyUnknown("ghost")) { try service.addProfile(draft(name: "other", keys: ["ghost"])) }
        assertRefuses(.keyUnknown("ghost")) {
            try service.addProfile(draft(name: "other", keys: ["router", "ghost"]))
        }
        XCTAssertEqual(try service.listProfiles().map(\.name), ["evals"], "nothing saved by a refused add")
        XCTAssertEqual(gate.reasons, [])
    }

    func testContainmentFollowsGrantScopeSemantics() {
        let p = saved(methods: ["GET", "POST"], paths: ["/messages"])
        // A requested scope inside an allowed one: exact, subdirectory, and the repeated
        // provider prefix means the same scope (the grant rules, applied to scopes).
        XCTAssertTrue(p.allows(paths: ["/messages"], providerPrefix: "/v1"))
        XCTAssertTrue(p.allows(paths: ["/messages/count_tokens"], providerPrefix: "/v1"))
        XCTAssertTrue(p.allows(paths: ["/v1/messages"], providerPrefix: "/v1"))
        XCTAssertTrue(p.allows(paths: ["messages"], providerPrefix: "/v1"))
        // Wider than, beside, or partially outside: refused. No silent widening.
        XCTAssertFalse(p.allows(paths: ["/"], providerPrefix: "/v1"))
        XCTAssertFalse(p.allows(paths: ["/messages", "/models"], providerPrefix: "/v1"))
        XCTAssertFalse(p.allows(paths: ["/messagesx"], providerPrefix: "/v1"))
        // Dot segments never match any scope, exactly like a grant.
        XCTAssertFalse(p.allows(paths: ["/messages/../models"], providerPrefix: "/v1"))
        XCTAssertFalse(p.allows(paths: ["/messages/./x"], providerPrefix: "/v1"))
        // Empty profile paths = any requested path.
        XCTAssertTrue(saved().allows(paths: [], providerPrefix: "/v1"))
        XCTAssertTrue(saved().allows(paths: ["/anything/at/all"], providerPrefix: "/v1"))
        // A repeated prefix on the requested side works like a request path does.
        XCTAssertTrue(saved(paths: ["/models"]).allows(paths: ["/v1/models"], providerPrefix: "/v1"))
        XCTAssertFalse(saved(paths: ["/models"]).allows(paths: ["/v1/messages"], providerPrefix: "/v1"))

        // Methods: the requested set must be a subset of the profile's.
        XCTAssertTrue(p.allows(methods: ["GET"]))
        XCTAssertTrue(p.allows(methods: ["GET", "POST"]))
        XCTAssertFalse(p.allows(methods: ["GET", "DELETE"]))

        // Minutes: a request may shorten, never lengthen.
        let ceiling = saved(minutes: 480)
        XCTAssertTrue(ceiling.allows(minutes: 30))
        XCTAssertTrue(ceiling.allows(minutes: 480))
        XCTAssertFalse(ceiling.allows(minutes: 481))

        // Caps: tightenable, never widenable; a profile without one lets a request pick its own.
        let capped = saved(maxRequests: 10, maxUsd: 2)
        XCTAssertTrue(capped.allows(maxRequests: nil))
        XCTAssertTrue(capped.allows(maxRequests: 5))
        XCTAssertFalse(capped.allows(maxRequests: 11))
        XCTAssertTrue(capped.allows(maxUsd: nil))
        XCTAssertTrue(capped.allows(maxUsd: 1.5))
        XCTAssertFalse(capped.allows(maxUsd: 2.5))
        XCTAssertTrue(saved().allows(maxRequests: 1000))
        XCTAssertTrue(saved().allows(maxUsd: 1000))
    }

    func testProfileCommandsParseWithHouseStyleFlags() throws {
        let add = try XCTUnwrap(try KeysCLI.parseAsRoot([
            "profile", "add", "evals",
            "--keys", "router,spare",
            "--methods", "GET,POST",
            "--paths", "/v1/messages",
            "--minutes", "480",
            "--max-requests", "500",
            "--max-usd", "2",
            "--unattended",
            "--json",
        ]) as? ProfileAddCommand)
        XCTAssertEqual(add.name, "evals")
        XCTAssertEqual(add.keys, "router,spare")
        XCTAssertEqual(add.methods, "GET,POST")
        XCTAssertEqual(add.paths, "/v1/messages")
        XCTAssertEqual(add.minutes, 480)
        XCTAssertEqual(add.maxRequests, 500)
        XCTAssertEqual(add.maxUsd, 2)
        XCTAssertTrue(add.unattended)
        XCTAssertTrue(add.json)

        XCTAssertTrue(try KeysCLI.parseAsRoot(["profile", "list"]) is ProfileListCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["profile", "list", "--json"]) is ProfileListCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["profile"]) is ProfileListCommand)
        XCTAssertTrue(try KeysCLI.parseAsRoot(["profile", "remove", "evals"]) is ProfileRemoveCommand)
        // --keys is what makes a profile useful; the command refuses to guess.
        XCTAssertThrowsError(try KeysCLI.parseAsRoot(["profile", "add", "evals"]))
    }

    func testProfileCommandsRunStraightOffTheCatalogWithNoSiteAndNoPrompt() throws {
        let (db, dir) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        try service.add(name: "router", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)

        let list = try XCTUnwrap(try KeysCLI.parseAsRoot(["profile", "list"]) as? ProfileListCommand)
        let emptyText = try capturingStdout { try list.run(service: service) }
        XCTAssertEqual(emptyText.trimmingCharacters(in: .whitespacesAndNewlines), "no profiles")

        // Add: bounds on the command line, straight into the catalog.
        let add = try XCTUnwrap(try KeysCLI.parseAsRoot([
            "profile", "add", "evals", "--keys", "router", "--methods", "GET,POST",
            "--paths", "/v1/messages", "--minutes", "480", "--max-requests", "500",
            "--max-usd", "2", "--unattended",
        ]) as? ProfileAddCommand)
        let addText = try capturingStdout { try add.run(service: service) }
        XCTAssertTrue(addText.contains("profile evals saved"), addText)
        XCTAssertTrue(addText.contains("unattended"), addText)
        XCTAssertTrue(addText.contains("keys grant <key> --profile evals"), addText)
        XCTAssertEqual(gate.reasons, [], "profiles hold no secret: nothing to prompt for")

        // A refusal reaches the command's caller with its named error and no prompt.
        let bad = try XCTUnwrap(try KeysCLI.parseAsRoot(["profile", "add", "bad", "--keys", "router", "--unattended"]) as? ProfileAddCommand)
        assertRefuses(.requiresCap) { try bad.run(service: service) }
        XCTAssertEqual(gate.reasons, [])

        // --json prints exactly the service's profile JSON (what the dashboard API serves).
        let listJson = try XCTUnwrap(try KeysCLI.parseAsRoot(["profile", "list", "--json"]) as? ProfileListCommand)
        let jsonText = try capturingStdout { try listJson.run(service: service) }
        let printed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(jsonText.data(using: .utf8))) as? [[String: Any]]
        )
        XCTAssertEqual(printed.count, 1)
        let served = try service.listProfiles()
        XCTAssertEqual(served.count, 1)
        XCTAssertEqual(try JSONValue.data(printed[0]), try JSONValue.data(served[0].jsonObject()))

        // Plain list: the table shape.
        let listText = try capturingStdout { try list.run(service: service) }
        XCTAssertEqual(listText.trimmingCharacters(in: .whitespacesAndNewlines), [
            "NAME\tKEYS\tSCOPE\tCEILING",
            "evals\trouter\tGET,POST /v1/messages\t480 min · max 500 req · max $2.00 · unattended",
        ].joined(separator: "\n"))

        // Remove, then the named refusal for a profile that is gone.
        let rm = try XCTUnwrap(try KeysCLI.parseAsRoot(["profile", "remove", "evals"]) as? ProfileRemoveCommand)
        let rmText = try capturingStdout { try rm.run(service: service) }
        XCTAssertEqual(rmText.trimmingCharacters(in: .whitespacesAndNewlines), "removed profile evals")
        XCTAssertEqual(try service.listProfiles(), [])
        assertRefuses(.notFound("evals")) { try rm.run(service: service) }

        // The sentinel again: through the whole CLI surface, only bounds and names on disk.
        assertNoSentinel(fixtureSecret, in: dir)
    }

    func testProfileAddAndRemoveWritePerKeyAuditRows() throws {
        let (service, _, _, _) = try serviceWithKeys()
        let savedProfile = try service.addProfile(
            draft(keys: ["router", "spare"], methods: ["GET"], paths: ["/v1/messages"], minutes: 120),
            caller: "cli"
        )
        XCTAssertEqual(savedProfile.unattended, false)
        _ = try service.removeProfile(name: "evals", caller: "cli")
        for key in ["router", "spare"] {
            let events = try service.keyEvents(name: key).filter {
                $0.action == "profile_add" || $0.action == "profile_remove"
            }
            // `keys log` reads newest first; the remove is the newer event of the pair.
            XCTAssertEqual(events.map(\.action), ["profile_remove", "profile_add"], key)
            XCTAssertEqual(events.map { $0.caller ?? "" }, ["cli", "cli"], key)
            let detail = events.first?.detail ?? ""
            XCTAssertTrue(detail.contains("evals"), detail)
            XCTAssertTrue(detail.contains("/v1/messages"), detail)
            XCTAssertTrue(detail.contains("120 min"), detail)
            XCTAssertFalse(detail.contains(fixtureSecret), "audit detail holds bounds and names only")
        }
    }
}
