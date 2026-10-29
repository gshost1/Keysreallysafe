import Foundation
import XCTest
@testable import KeysCore

/// EnvScan — the shared folder-walk + classification pass both processes use. All trees
/// are synthetic, built in temp dirs at runtime, and every "key" is built from an obviously
/// fake body so no literal resembles a real one. The tests pin the contract's scan rules:
/// the three names, depth 3, the pinned directory list, the 1 MiB cap, the auth-name guard,
/// per-entry symlink containment and the classification matrix.
final class EnvScanTests: XCTestCase {
    private let fm = FileManager.default
    private let fakeBody = "FAKE0TEST0VALUE0NOT0A0REAL0KEY"
    private var anthropicValue: String { "sk-ant-" + fakeBody + "01" }
    private var openrouterValue: String { "sk-or-" + fakeBody + "02" }
    private var groqValue: String { "gsk_" + fakeBody + "03" }
    private var plainValue: String { "sk-" + fakeBody + "04" }
    private var awsAccessValue: String { "AKIA" + fakeBody + "05" }
    private var awsSecretValue: String { fakeBody + "AWSSECRET06" }
    private var clientTokenValue: String { GatewayClientToken.prefix + String(repeating: "a", count: 48) }
    /// A grant token's shape (`ksf_` + 8 hex + `_` + 43 base64url characters), obviously fake.
    private var grantTokenValue: String { "ksf_00112233_" + String(repeating: "b", count: 43) }

    /// The provider overlay is process-wide; every test leaves it empty behind it.
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    // MARK: names and depth (VAL-SCAN-002)

    func testScanReadsExactlyTheThreeEnvNames() throws {
        let root = try TempDir.make()
        try write("A_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try write("A_KEY=\(openrouterValue)\n", to: ".env.local", under: root)
        try write("A_KEY=\(groqValue)\n", to: ".env.production", under: root)
        // No ".ENV" here: on the case-insensitive default filesystem it would be the same
        // file as ".env" and just overwrite it.
        for ignored in [".env.example", ".env.sample", ".env.template", ".env.development", ".envrc", "environ", "env"] {
            try write("A_KEY=\(plainValue)\n", to: ignored, under: root)
        }
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env", ".env.local", ".env.production"])
        XCTAssertEqual(report.candidates.map(\.value), [anthropicValue, openrouterValue, groqValue],
                       "no candidate came from a file that was never read")
    }

    func testSubfolderEnvFilesStopAtDepthThree() throws {
        let root = try TempDir.make()
        try write("A=1\n", to: ".env", under: root)
        try write("A=1\n", to: "one/.env", under: root)
        try write("A=1\n", to: "one/two/.env", under: root)
        try write("A=1\n", to: "one/two/three/.env", under: root)
        try write("A=1\n", to: "one/two/three/four/.env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env", "one/.env", "one/two/.env", "one/two/three/.env"],
                       "a fourth-level .env is never read; the first three levels are")
        XCTAssertEqual(report.candidates, [])
    }

    func testExampleSampleAndTemplateAreSkippedAtEveryDepth() throws {
        let root = try TempDir.make()
        try write("TEMPLATED_KEY=\(anthropicValue)\n", to: ".env.example", under: root)
        try write("TEMPLATED_KEY=\(anthropicValue)\n", to: "sub/.env.sample", under: root)
        try write("TEMPLATED_KEY=\(anthropicValue)\n", to: "a/b/.env.template", under: root)
        try write("TEMPLATED_KEY=\(anthropicValue)\n", to: "x/y/z/.env.example", under: root)
        try write("REAL_KEY=\(openrouterValue)\n", to: "sub/.env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, ["sub/.env"])
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue],
                       "template files stay unread at every depth")
    }

    // MARK: the walk limits (VAL-SCAN-003, VAL-SCAN-004)

    func testPinnedDirectoriesAreSkipped() throws {
        let root = try TempDir.make()
        for name in [".git", "node_modules", ".build", ".venv", "venv", "vendor", "dist", "build", "target", "Pods", "DerivedData", "__pycache__"] {
            try write("PINNED_KEY=\(anthropicValue)\n", to: "\(name)/.env", under: root)
            try write("PINNED_KEY=\(anthropicValue)\n", to: "nested/\(name)/.env", under: root)
        }
        try write("PINNED_KEY=\(groqValue)\n", to: "nested/.env", under: root)
        try write("PINNED_KEY=\(openrouterValue)\n", to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env", "nested/.env"], "none of the twelve pinned names is ever descended into")
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue, groqValue])
    }

    func testFilesOverTheSizeCapAreSkippedUnread() throws {
        let root = try TempDir.make()
        let readLine = "ANTHROPIC_API_KEY=\(openrouterValue)"
        // Exactly 1 MiB: one comment line, the key line, two newlines.
        let exact = String(repeating: "#", count: EnvScan.maxFileBytes - readLine.count - 2) + "\n" + readLine + "\n"
        XCTAssertEqual(exact.utf8.count, EnvScan.maxFileBytes)
        let over = "ANTHROPIC_API_KEY=\(anthropicValue)\n" + String(repeating: "#", count: EnvScan.maxFileBytes)
        XCTAssertGreaterThan(over.utf8.count, EnvScan.maxFileBytes, "comfortably over the cap")
        try write(over, to: ".env", under: root)
        try write(exact, to: ".env.local", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env.local"], "the oversized .env is skipped unread, not truncated")
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue],
                       "the over-cap file's value never reached the parser")
    }

    func testAuthNamedFilesAreNeverOpened() throws {
        let root = try TempDir.make()
        for name in ["auth.json", "credentials", "credentials.json"] {
            try write("SECRET_IN_AUTH=\(anthropicValue)\n", to: name, under: root)
        }
        try write("SECRET_IN_AUTH=\(anthropicValue)\n", to: "deep/auth.json", under: root)
        // Defense in depth: an env-named symlink pointed at an auth-named file inside the
        // root would pass the name filter; the guard still refuses to open it.
        try link(".env", to: "auth.json", under: root)
        try write("ANTHROPIC_API_KEY=\(openrouterValue)\n", to: ".env.local", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env.local"], "the symlinked auth.json was never opened under the .env name")
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue])
        XCTAssertFalse(report.candidates.contains { $0.value == anthropicValue })
    }

    // MARK: containment (VAL-SCAN-001)

    func testSymlinksLeavingTheRootAreNeverFollowedOrRead() throws {
        let parent = try TempDir.make()
        let root = parent.appendingPathComponent("proj")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside")
        try fm.createDirectory(at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try write("OUTSIDE_KEY=\(anthropicValue)\n", to: ".env", under: outside)
        try write("OUTSIDE_KEY=\(groqValue)\n", to: "nested/.env", under: outside)
        try link(".env.local", to: "../outside/.env", under: root)
        try link("outsider", to: "../outside", under: root)
        try link("chained", to: "../outside/nested", under: root)
        try write("INSIDE_KEY=\(openrouterValue)\n", to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env"], "no entry resolving outside the root was followed or read")
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue])
    }

    func testSymlinksStayingInsideAreStillDiscovered() throws {
        let root = try TempDir.make()
        try write("ALIASED_KEY=\(anthropicValue)\n", to: "real/.env", under: root)
        try link("alias", to: "real", under: root)
        try link("self", to: ".", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, ["alias/.env"],
                       "an inside symlink is followed, and the file is reported once under the first walk path")
        XCTAssertEqual(report.candidates.first?.file, "alias/.env")

        let other = try TempDir.make()
        try write("LINKED_KEY=\(openrouterValue)\n", to: "real/.env", under: other)
        try link(".env", to: "real/.env", under: other)
        let second = try EnvScan.scan(folder: other.path)
        XCTAssertEqual(second.envFiles, [".env"], "a file symlink staying inside is read under its own name")
        XCTAssertEqual(second.candidates.map(\.value), [openrouterValue])
    }

    func testRootSpellingsResolveToOneRoot() throws {
        let parent = try TempDir.make()
        let root = parent.appendingPathComponent("proj")
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try write("A_KEY=\(anthropicValue)\n", to: "nested/.env", under: root)
        let alias = parent.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)

        let direct = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(direct.envFiles, ["nested/.env"])
        XCTAssertEqual(direct.root, try Project.canonicalFolder(root.path), "the canonicalFolder discipline")
        XCTAssertFalse(direct.root.hasSuffix("/"))

        XCTAssertEqual(try EnvScan.scan(folder: root.path + "/").root, direct.root, "trailing slash")
        XCTAssertEqual(try EnvScan.scan(folder: root.path + "/").envFiles, direct.envFiles)
        XCTAssertEqual(try EnvScan.scan(folder: alias.path).root, direct.root, "a symlinked spelling")
        XCTAssertEqual(try EnvScan.scan(folder: alias.path).envFiles, direct.envFiles)
        if root.path.hasPrefix("/var/") {
            XCTAssertEqual(try EnvScan.scan(folder: "/private" + root.path).root, direct.root,
                           "the /private spelling of the same /var path")
        }
        // A cwd-relative spelling resolves against the process working directory.
        let saved = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(parent.path))
        defer { fm.changeCurrentDirectoryPath(saved) }
        XCTAssertEqual(try EnvScan.scan(folder: "proj").root, direct.root)
        XCTAssertEqual(try EnvScan.scan(folder: "proj").envFiles, direct.envFiles)
    }

    // MARK: classification (VAL-SCAN-005)

    func testClassificationMatrix() throws {
        let root = try TempDir.make()
        let text = """
        # a comment
        GEMINI_API_KEY=AIza\(fakeBody)
        ANTHROPIC_API_KEY=\(anthropicValue)
        OPENAI_BASE_URL=https://api.deepseek.com/v1
        OPENAI_API_KEY=\(plainValue)
        MY_FAST_ONE=\(groqValue)
        STRIPE_SECRET_KEY=sk_\(fakeBody)
        NO_SUFFIX_SHORT=sk_\(fakeBody)
        AWS_ACCESS_KEY_ID=\(awsAccessValue)
        AWS_SECRET_ACCESS_KEY=\(awsSecretValue)
        ALREADY_WRAPPED=\(clientTokenValue)
        GRANT_SHAPED=\(grantTokenValue)
        DATABASE_URL=postgres://u:p@h/db
        BARE_URL=postgres://h/db
        DEBUG=true
        EMPTY=
        """
        try write(text, to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.candidates.count, 10, "exactly the credential-shaped lines, nothing else")
        let byName = Dictionary(report.candidates.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // provider_key through the existing WrapDetect rules, provider guessing included.
        XCTAssertEqual(byName["GEMINI_API_KEY"]?.category, .providerKey)
        XCTAssertEqual(byName["GEMINI_API_KEY"]?.provider, "google", "the alias table")
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?.provider, "anthropic", "the name rule")
        XCTAssertEqual(byName["OPENAI_API_KEY"]?.provider, "deepseek", "the sibling BASE_URL re-label")
        XCTAssertEqual(byName["MY_FAST_ONE"]?.provider, "groq", "a distinctive value prefix on its own")
        XCTAssertEqual(byName["STRIPE_SECRET_KEY"]?.provider, nil,
                       "no rule names it, but the line is still reported")
        XCTAssertNil(byName["NO_SUFFIX_SHORT"], "a short ambiguous prefix without a key-ish name is noise")

        // aws_pair, both halves classified and linked.
        XCTAssertEqual(byName["AWS_ACCESS_KEY_ID"]?.category, .awsPair)
        XCTAssertEqual(byName["AWS_ACCESS_KEY_ID"]?.provider, nil)
        XCTAssertEqual(byName["AWS_ACCESS_KEY_ID"]?.pair, "AWS_SECRET_ACCESS_KEY")
        XCTAssertEqual(byName["AWS_SECRET_ACCESS_KEY"]?.category, .awsPair)
        XCTAssertEqual(byName["AWS_SECRET_ACCESS_KEY"]?.pair, "AWS_ACCESS_KEY_ID")

        // credential_url only with embedded userinfo.
        XCTAssertEqual(byName["DATABASE_URL"]?.category, .credentialURL)
        XCTAssertEqual(byName["DATABASE_URL"]?.provider, nil)
        XCTAssertNil(byName["BARE_URL"], "no userinfo, no credential")

        // wrapped token shapes.
        XCTAssertEqual(byName["ALREADY_WRAPPED"]?.category, .wrapped)
        XCTAssertEqual(byName["GRANT_SHAPED"]?.category, .wrapped)
        XCTAssertEqual(byName["GRANT_SHAPED"]?.last4, String(grantTokenValue.suffix(4)))

        XCTAssertNil(byName["DEBUG"])
        XCTAssertNil(byName["EMPTY"])

        // last4: never more than the last four characters, and the value stays in-process.
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?.last4, String(anthropicValue.suffix(4)))
        for candidate in report.candidates {
            XCTAssertLessThanOrEqual(candidate.last4.count, 4)
            XCTAssertFalse(candidate.last4.isEmpty)
            XCTAssertEqual(candidate.file, ".env")
        }
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?.value, anthropicValue)

        // The parsed file surface the import path reads.
        XCTAssertEqual(report.files.map(\.path), [".env"])
        XCTAssertEqual(report.files.first?.parsed.value(of: "ANTHROPIC_API_KEY"), anthropicValue)
    }

    func testCredentialURLNeedsEmbeddedUserinfo() throws {
        let root = try TempDir.make()
        let text = """
        WITH_PASS=postgres://u:p@h/db
        USER_ONLY=https://token@h/x
        PASSWORD_ONLY=redis://:p@h:6379
        NO_USERINFO=postgres://h/db
        PATH_AT=http://h.test/@handle
        NOT_A_URL=u:p@h/db
        """
        try write(text, to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.candidates.map(\.name), ["WITH_PASS", "USER_ONLY", "PASSWORD_ONLY"])
        XCTAssertTrue(report.candidates.allSatisfy { $0.category == .credentialURL },
                      "a token as the username and a bare password count as embedded userinfo; an @ in the path does not")
    }

    func testOverlayProvidersResolveThroughTheNameRules() throws {
        Providers.setOverlay([
            "my-gw": Providers.Record(
                id: "my-gw", name: "My Gateway", host: "gw.example.test", api: "other",
                authHeader: "Authorization", authPrefix: "Bearer ", pathPrefix: "", gateway: true,
                keyPrefix: "mk_"
            ),
        ])
        let root = try TempDir.make()
        try write("MY_GW_API_KEY=mk_\(fakeBody)\nANTHROPIC_API_KEY=\(anthropicValue)\n", to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        let byName = Dictionary(report.candidates.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["MY_GW_API_KEY"]?.category, .providerKey)
        XCTAssertEqual(byName["MY_GW_API_KEY"]?.provider, "my-gw",
                       "the name rules resolve through the overlay-aware Providers.provider")
        XCTAssertEqual(byName["ANTHROPIC_API_KEY"]?.provider, "anthropic", "shipped rules unaffected")
    }

    func testMultilineValuesAreNotCandidates() throws {
        let root = try TempDir.make()
        let text = "CERT=\"-----BEGIN-----\nINNER_KEY=\(anthropicValue)\n-----END-----\"\nANTHROPIC_API_KEY=\(openrouterValue)\n"
        try write(text, to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.candidates.map(\.value), [openrouterValue],
                       "a line inside a quoted value is not an assignment")
    }

    func testCRLFFilesAreReadAndClassified() throws {
        let root = try TempDir.make()
        try write("ANTHROPIC_API_KEY=\(anthropicValue)\r\nDEBUG=true\r\n", to: ".env", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env"])
        XCTAssertEqual(report.candidates.map(\.value), [anthropicValue])
        XCTAssertEqual(report.candidates.first?.last4, String(anthropicValue.suffix(4)))
    }

    // MARK: docker files (VAL-SCAN-006)

    func testDockerFilesPresenceMatrix() throws {
        let none = try TempDir.make()
        try fm.createDirectory(atPath: none.appendingPathComponent("Dockerfile").path, withIntermediateDirectories: true)
        XCTAssertEqual(try EnvScan.scan(folder: none.path).dockerFiles, [],
                       "none present — and a directory wearing a docker name is not a docker file")

        let cases: [([String], [String])] = [
            (["docker-compose.yml"], ["docker-compose.yml"]),
            (["compose.yaml"], ["compose.yaml"]),
            (["Dockerfile"], ["Dockerfile"]),
            (["Dockerfile", "compose.yaml", "docker-compose.yml"],
             ["docker-compose.yml", "compose.yaml", "Dockerfile"]),
        ]
        for (present, expected) in cases {
            let root = try TempDir.make()
            for name in present { try write("FROM scratch\n", to: name, under: root) }
            try write("FROM scratch\n", to: "sub/Dockerfile", under: root)
            try write("services:\n", to: "docker-compose.override.yml", under: root)
            XCTAssertEqual(try EnvScan.scan(folder: root.path).dockerFiles, expected,
                           "root files only, in the pinned order")
        }
    }

    // MARK: the report shape

    func testResultsCarryRelativePOSIXPaths() throws {
        let root = try TempDir.make()
        try write("A_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try write("A_KEY=\(openrouterValue)\n", to: "packages/api/.env", under: root)
        try write("A_KEY=\(groqValue)\n", to: "my app/.env.local", under: root)
        try write("A=1\n", to: "Dockerfile", under: root)
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [".env", "my app/.env.local", "packages/api/.env"],
                       "POSIX joins, no percent-encoding")
        XCTAssertEqual(report.dockerFiles, ["Dockerfile"])
        for path in report.envFiles {
            XCTAssertFalse(path.hasPrefix("/"))
            XCTAssertFalse(path.contains(report.root), "the canonical root never appears in a result path")
        }
        for candidate in report.candidates {
            XCTAssertTrue(report.envFiles.contains(candidate.file), candidate.file)
        }
        XCTAssertEqual(report.absolute(".env").path, report.root + "/.env",
                       "the in-process helper joins the canonical root to a reported path")
    }

    func testUnusableFoldersArePathFreeUsageErrors() throws {
        let dir = try TempDir.make()
        let missing = dir.appendingPathComponent("no-such-\(UUID().uuidString)").path
        XCTAssertThrowsError(try EnvScan.scan(folder: missing)) { error in
            guard case AppError.usage(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "that project folder does not exist")
            XCTAssertFalse(message.contains(missing), "the message is path-free")
        }
        let file = dir.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try EnvScan.scan(folder: file.path)) { error in
            guard case AppError.usage(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "the project folder is not a folder")
            XCTAssertFalse(message.contains(file.path))
        }
    }

    func testARootThatCannotBeListedIsAPathFreeError() throws {
        let root = try TempDir.make()
        try write("A_KEY=\(anthropicValue)\n", to: ".env", under: root)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try EnvScan.scan(folder: root.path)) { error in
            guard case AppError.usage(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "the project folder could not be read")
            XCTAssertFalse(message.contains(root.path), "the message is path-free")
        }
    }

    func testEmptyFolderScansClean() throws {
        let root = try TempDir.make()
        let report = try EnvScan.scan(folder: root.path)
        XCTAssertEqual(report.envFiles, [])
        XCTAssertEqual(report.files, [])
        XCTAssertEqual(report.candidates, [])
        XCTAssertEqual(report.dockerFiles, [])
        XCTAssertEqual(report.root, try Project.canonicalFolder(root.path))
    }

    // MARK: helpers

    @discardableResult
    private func write(_ text: String, to relative: String, under root: URL) throws -> URL {
        var url = root
        for part in relative.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// `name` under `root` as a symlink; `destination` may be relative to the link's folder.
    @discardableResult
    private func link(_ name: String, to destination: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }
}
