import XCTest

/// The shipped agent skill (`Skills/keysrs/SKILL.md`) is a byte-for-byte artifact: the
/// packager stages it unchanged into the app bundle, and its frontmatter is the contract
/// every Agent Skills host reads. Drift — a renamed skill, an empty description, a token
/// pasted into the body — must fail here rather than on a user's Mac. The python layout
/// tests pin that the file ships; this test pins that what ships is a valid skill.
final class AgentSkillTests: XCTestCase {
    // tests run from the checkout root, so three levels up from this file is the repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let skillRelativePath = "Skills/keysrs/SKILL.md"
    private static let skillName = "keysrs"

    private var text: String!

    override func setUpWithError() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.skillRelativePath)
        text = try String(contentsOf: url, encoding: .utf8)
    }

    func testFrontmatterNameMatchesTheDirectory() throws {
        let frontmatter = try Self.frontmatter(of: text)
        XCTAssertEqual(frontmatter["name"], Self.skillName)
        XCTAssertEqual(
            Self.skillRelativePath.split(separator: "/").dropLast().last.map(String.init),
            frontmatter["name"], "the frontmatter name must match the skill directory"
        )
    }

    func testDescriptionIsPresentAndWithinTheLimit() throws {
        let description = try XCTUnwrap(try Self.frontmatter(of: text)["description"])
        XCTAssertFalse(description.isEmpty)
        XCTAssertLessThanOrEqual(description.count, 1024)
    }

    func testLicenseIsMIT() throws {
        XCTAssertEqual(try Self.frontmatter(of: text)["license"], "MIT")
    }

    func testBodyStaysUnderFiveHundredLines() throws {
        let body = try Self.body(of: text)
        XCTAssertFalse(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThan(lines, 500, "the body is progressive disclosure and must stay short")
    }

    /// The shortening: the skill is a pointer note now, and the new bound keeps it
    /// from growing back into a manual.
    func testBodyGenuinelyShort() throws {
        let body = try Self.body(of: text)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThanOrEqual(lines, 200, "the note points at the MCP server; the manual lives in docs/agents.md")
    }

    func testPointsAtMCPServer() throws {
        let body = try Self.body(of: text)
        XCTAssertNotNil(body.range(of: "MCP", options: .caseInsensitive), "the note names the MCP server")
        XCTAssertTrue(
            body.contains("keys mcp") || body.contains(Self.skillName),
            "the note references the `keys mcp` server or its registered name")
        let description = try XCTUnwrap(try Self.frontmatter(of: text)["description"])
        XCTAssertNotNil(description.range(of: "MCP", options: .caseInsensitive),
                        "the description names the new surface")
        // No stale claims about the removed long workflows survive in the description.
        XCTAssertFalse(description.contains("wire and launch coding agents"))
        XCTAssertFalse(description.contains("check plan-usage status"))
    }

    func testSafetyFloorRestated() throws {
        // An agent that reads ONLY the skill still gets the floor rules, stated in the
        // body — not as a pointer to another document.
        let body = try Self.body(of: text)
        XCTAssertTrue(body.contains("Touch ID"), "user presence is a floor rule")
        XCTAssertNotNil(
            body.range(of: #"(?i)never[^\n]*key value"#, options: .regularExpression),
            "the floor says never echo a key value")
        XCTAssertNotNil(
            body.range(of: #"(?i)never[^\n]*token"#, options: .regularExpression),
            "the floor says never echo a token")
        XCTAssertTrue(body.contains("auth.json"), "the floor bars the provider credential stores")
    }

    func testOldWorkflowsGoneAndEveryReferenceResolves() throws {
        // The old manual walked through these; the note must not. An exit-code table
        // is the clearest marker of the old format.
        for marker in [
            "keys agent droid", "keys setup droid", "keys tunnel user@", "keys relay setup",
            "| 6 |", "keys grant work-anthropic", "keys client issue router",
        ] {
            XCTAssertFalse(text.contains(marker), "the old workflow \(marker.debugDescription) is gone")
        }
        // Every repo-relative path the note names exists in the checkout. Doc
        // references are checkout-only (the bundle ships no docs/), which the note
        // itself says.
        let pattern = #"(?:\bdocs/[A-Za-z0-9_./-]+\.md\b|\bREADME\.md\b)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let references = regex.matches(in: text, range: range).map {
            String(text[Range($0.range, in: text)!])
        }
        XCTAssertFalse(references.isEmpty, "the note keeps at least one resolvable reference")
        for reference in Set(references) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(reference).path),
                "\(reference) must resolve in the checkout"
            )
        }
    }

    func testNoLiteralTokenValues() throws {
        // A real grant/client/relay token is a prefix plus a long run of token characters.
        // The bare prefix written as a format (`ksfc_…`) has no token characters after it
        // and is allowed, exactly as the other docs write it.
        let pattern = #"ksf(?:c|r)?_[A-Za-z0-9_-]{10,}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, range: range).map {
            String(text[Range($0.range, in: text)!])
        }
        XCTAssertEqual(found, [], "no literal token values belong in the shipped skill")
    }

    private enum Malformed: Error, CustomStringConvertible {
        case frontmatter(String)
        var description: String {
            switch self { case .frontmatter(let reason): return reason }
        }
    }

    private static func frontmatter(of text: String) throws -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw Malformed.frontmatter("SKILL.md must open with a --- frontmatter block")
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw Malformed.frontmatter("SKILL.md frontmatter is not closed with ---")
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }

    private static func body(of text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw Malformed.frontmatter("SKILL.md frontmatter is not closed with ---")
        }
        return lines[(end + 1)...].joined(separator: "\n")
    }
}
