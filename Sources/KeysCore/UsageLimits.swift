import Foundation

/// A token limit the user sets on one window of a locally tracked row. It lives in the catalog
/// (`usage_limits`), survives restarts, and turns that one window into a percent meter on the
/// Usage pane; the tokens themselves always come from the usage rows, never the limit.
enum UsageLimits {
    /// JSON and API ids, snake_case. `five_hour` is the rolling 5-hour window; the other two are
    /// calendar windows — exactly the windows the Droid row shows.
    enum Window: String, CaseIterable {
        case fiveHour = "five_hour"
        case weekly
        case monthly
    }

    /// Only a row with locally tracked tokens can be limited: a limit on anything else would
    /// never meet a number to steer. The subscriptions overlay writes Factory's token limits
    /// through to the Droid row, which is why this is a set and not one constant.
    static let trackedSources: Set<String> = ["droid"]

    /// The row and window a limit steers; anything else is a usage error (400 on the API).
    static func validate(source: String, window: String) throws -> Window {
        guard trackedSources.contains(source) else {
            throw AppError.usage("limits exist for \(trackedSources.sorted().joined(separator: ", ")) only")
        }
        guard let window = Window(rawValue: window) else {
            throw AppError.usage("window must be one of \(Window.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return window
    }

    /// A whole, positive token count: 0 and negatives can never make a percent that means
    /// anything, and a fraction of a token does not exist.
    static func validateTokens(_ tokens: Int) throws {
        guard tokens > 0 else { throw AppError.usage("tokens must be a positive whole number") }
    }
}
