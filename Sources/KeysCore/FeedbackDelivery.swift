import AppKit
import Foundation

/// How a scrubbed feedback draft leaves the app: the destination URL (a
/// prefilled mail to Keysrs support, or the GitHub issue page) and the one
/// production action, opening it. This is the deliberate, documented exception
/// to the no-opening rule `open_app` carries: `send_feedback` exists to put a
/// prefilled mail (or issue) in front of the user, so the route opens the
/// user's mail client or browser through the seam whose production default
/// lives here — and nothing else in the app opens anything on this path.
/// Keysrs itself never submits the feedback: the open is the only side effect,
/// and the user is the one who reviews and sends.
enum FeedbackDelivery {
    /// Support mail, the Cloudflare-routed address (a frozen identifier).
    static let supportAddress = "support@keysrs.com"
    /// The repository's issue page (the frozen repo name, CLAUDE.md).
    static let issuesURL = "https://github.com/gshost1/Keysreallysafe/issues/new"
    /// The fixed, short subject/title both destinations carry. The version
    /// footer lives in the body, not the subject.
    static let feedbackSubject = "Keysrs feedback"

    /// One URL query component: RFC 3986's unreserved characters stay literal
    /// and everything else — spaces, newlines, ampersands, non-ASCII — is
    /// percent-encoded, so a draft can never smuggle an extra query parameter,
    /// a fragment or a raw newline into the URL. This is new code on purpose:
    /// no in-repo Swift precedent existed (the dashboard JS uses
    /// `encodeURIComponent`), so it is pinned by tests covering exactly the
    /// characters that would break a query: commas, newlines, ampersands and
    /// non-ASCII.
    static func queryValue(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The encoded-URL ceiling, characters. Mail clients and browsers accept a
    /// few thousand characters of mailto URL and truncate silently past that;
    /// ~2,000 leaves headroom (VAL-F-005).
    static let maxURLLength = 2_000

    /// The prefilled support mail for a scrubbed draft, capped so the whole
    /// encoded URL stays within `cap` characters with the version footer always
    /// kept: the draft is cut from its end (never the footer) when the encoded
    /// URL would overflow. Returns the URL, the body it actually encodes (the
    /// capped draft plus the footer) and whether the draft had to be cut, so the
    /// caller can report the truncation instead of opening a silently short
    /// draft (VAL-F-005).
    static func mailtoURL(body: String, footer: String, cap: Int = maxURLLength)
        -> (url: URL?, body: String, truncated: Bool) {
        let prefix = "mailto:\(supportAddress)"
            + "?subject=\(queryValue(feedbackSubject))"
            + "&body="
        let encodedFooter = queryValue(footer)
        let budget = max(0, cap - prefix.count - encodedFooter.count)
        let (encodedBody, kept) = capped(body, encodedLimit: budget)
        let string = prefix + encodedBody + encodedFooter
        return (URL(string: string), kept + footer, kept.count < body.count)
    }

    /// The longest prefix of `value` whose percent-encoding fits `limit`
    /// characters, cut on a whole-character boundary so a percent-escape is
    /// never split. Returns the encoded prefix and the decoded prefix it stands
    /// for (the body the answer reports).
    private static func capped(_ value: String, encodedLimit limit: Int) -> (encoded: String, decoded: String) {
        var encoded = ""
        var decoded = ""
        for character in value {
            let piece = queryValue(String(character))
            if encoded.count + piece.count > limit { break }
            encoded += piece
            decoded.append(character)
        }
        return (encoded, decoded)
    }

    /// The prefilled GitHub issue page for a scrubbed draft.
    static func githubIssueURL(body: String) -> URL? {
        URL(string: issuesURL
            + "?title=\(queryValue(feedbackSubject))"
            + "&body=\(queryValue(body))")
    }

    /// The closing footer the scrubbed draft gains: the Keysrs version (the
    /// single version constant) and this Mac's macOS version, read fresh and
    /// unclamped — a support mail or issue that says which build reported it is
    /// worth more than a clamped range.
    static func versionFooter() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\n\nKeysrs \(ProductAnalyticsConfiguration.appVersion) on macOS "
            + "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The production default of the route's opener seam: hand the prefilled
    /// URL to the system opener, which picks the user's mail client for a
    /// mailto and the default browser for the GitHub page. Tests inject a spy
    /// and never open anything.
    static func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
