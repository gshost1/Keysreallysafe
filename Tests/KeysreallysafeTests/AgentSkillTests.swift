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
