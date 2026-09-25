import Foundation
import Security

/// Ordinary updates must retain both Keychain's designated requirement and team partition.
/// A self-signed certificate stabilizes only the former, so it is deliberately rejected.
enum StableSigning {
    static let appleSigner = "anchor apple generic and (" +
        "(certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or " +
        "(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists) or " +
        "(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.7] exists))"

    static func requirement(team: String) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw AppError.http("invalid code-signing team identifier")
        }
        return "identifier \"keysreallysafe\" and certificate leaf[subject.OU] = \"\(team)\" and " + appleSigner
    }

    private static func code(_ url: URL) throws -> SecStaticCode {
        var result: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &result)
        guard status == errSecSuccess, let result else {
            throw AppError.http("cannot inspect signing identity (\(status))")
        }
        return result
    }

    private static func compile(_ text: String) throws -> SecRequirement {
        var result: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &result)
        guard status == errSecSuccess, let result else {
            throw AppError.http("cannot compile signing requirement (\(status))")
        }
        return result
    }

    private static func canonical(_ requirement: SecRequirement) throws -> String {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw AppError.http("cannot inspect designated requirement")
        }
        return text as String
    }

    static func validate(_ candidate: URL, replacing previous: URL?) throws {
        let candidateCode = try code(candidate)
        let accepted = try compile("identifier \"keysreallysafe\" and " + appleSigner)
        guard SecStaticCodeCheckValidity(candidateCode, SecCSFlags(rawValue: kSecCSStrictValidate), accepted) == errSecSuccess else {
            throw AppError.http("install requires Apple Development or Developer ID signing; run make build or scripts/sign-local.py with your persistent signing identity. Ad-hoc/self-signed builds break Keychain permissions after updates")
        }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(candidateCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw AppError.http("signed build has no team identifier")
        }
        let expected = try compile(requirement(team: team))
        var actual: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(candidateCode, [], &actual) == errSecSuccess, let actual,
              try canonical(actual) == canonical(expected) else {
            throw AppError.http("build does not use the stable Keysrs signing requirement; run make build or scripts/sign-local.py")
        }
        if let previous {
            let oldCode = try code(previous)
            var oldInfo: CFDictionary?
            guard SecCodeCopySigningInformation(oldCode, SecCSFlags(rawValue: kSecCSSigningInformation), &oldInfo) == errSecSuccess,
                  let old = oldInfo as? [String: Any],
                  old[kSecCodeInfoIdentifier as String] as? String == "keysreallysafe",
                  SecStaticCodeCheckValidity(oldCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
                throw AppError.http("cannot establish the installed app's signing identity; installed version preserved")
            }
            var oldRequirement: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(oldCode, [], &oldRequirement) == errSecSuccess,
                  let oldRequirement,
                  try canonical(oldRequirement) == canonical(expected),
                  SecStaticCodeCheckValidity(candidateCode, SecCSFlags(rawValue: kSecCSStrictValidate), oldRequirement) == errSecSuccess else {
                throw AppError.http("signing identity changed; refusing to replace the app and invalidate Keychain access")
            }
        }
    }
}
