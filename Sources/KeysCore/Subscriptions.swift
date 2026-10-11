import Foundation

/// The subscriptions the user pins to the Usage pane with "+ Add subscription": a plan name and
/// an optional limit for a tool Keysrs cannot measure locally, or for Factory, which is the one
/// listed tool whose usage is measured here (Droid's). The rows live in the catalog beside the
/// keys, like custom providers, so they survive restarts. Nothing here reads a tool's files —
/// a subscription is a note the user wrote, never a measurement.
enum Subscriptions {
    /// The API and JSON ids, shared by the dialog, the routes and the table's CHECK.
    static let tools = ["cursor", "gemini", "copilot", "perplexity", "chatgpt", "factory", "custom"]
    static let units = ["tokens", "requests", "credits", "usd"]

    /// One limit: an amount, the unit it is counted in, and the window it resets on. The three
    /// fields are one fact — every write sets or clears all three together.
    struct LimitFields: Equatable {
        var amount: Double
        var unit: String
        var period: String
    }

    /// A limit's three fields as a body carried them: present-with-a-value, present-as-null or
    /// absent. The distinction is what makes "all-or-nothing" enforceable on PATCH, where an
    /// absent group means "leave the limit alone" while three nulls mean "clear it".
    struct LimitInput {
        var amount: Double?
        var amountPresent = false
        var unit: String?
        var unitPresent = false
        var period: String?
        var periodPresent = false

        var presentCount: Int { (amountPresent ? 1 : 0) + (unitPresent ? 1 : 0) + (periodPresent ? 1 : 0) }
        var valueCount: Int { (amount != nil ? 1 : 0) + (unit != nil ? 1 : 0) + (period != nil ? 1 : 0) }
        var anyPresent: Bool { presentCount > 0 }
    }

    static func validateTool(_ raw: Any?) throws -> String {
        guard let tool = raw as? String, tools.contains(tool) else {
            throw AppError.usage("tool must be one of \(tools.joined(separator: ", "))")
        }
        return tool
    }

    /// A custom tool is named by its own name; the built-ins carry no name of their own, so a
    /// name on one is a caller that did not mean what it sent.
    static func validateName(_ raw: Any?, tool: String) throws -> String {
        let trimmed = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tool == "custom" {
            guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.contains(where: { $0.isNewline }) else {
                throw AppError.usage("a custom subscription needs a name (one line, at most 64 characters)")
            }
            return trimmed
        }
        guard trimmed.isEmpty else { throw AppError.usage("name is only for a custom tool") }
        return ""
    }

    static func validatePlan(_ raw: Any?) throws -> String {
        guard let plan = raw as? String else { throw AppError.usage("plan is required") }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.contains(where: { $0.isNewline }) else {
            throw AppError.usage("plan is required (one line, at most 80 characters)")
        }
        return trimmed
    }

    /// Resolves the limit a body asked for: absent → keep `existing`; three nulls → none; three
    /// values → one validated limit; anything in between is a caller that half-sent one fact.
    static func resolveLimit(_ input: LimitInput, existing: LimitFields?) throws -> LimitFields? {
        guard input.anyPresent else { return existing }
        if input.valueCount == 0 {
            guard input.presentCount == 3 else { throw AppError.usage(Self.limitRule) }
            return nil
        }
        guard input.presentCount == 3,
              let amount = input.amount, let unit = input.unit, let period = input.period
        else { throw AppError.usage(Self.limitRule) }
        try validateLimit(amount: amount, unit: unit, period: period)
        return LimitFields(amount: amount, unit: unit, period: period)
    }

    private static let limitRule =
        "limit fields are all-or-nothing: set amount, unit and period together, or clear all three"

    static func validateLimit(amount: Double, unit: String, period: String) throws {
        guard amount.isFinite, amount > 0, amount <= 1_000_000_000 else {
            throw AppError.usage("limit amount must be greater than 0 and at most a billion")
        }
        guard units.contains(unit) else {
            throw AppError.usage("limit unit must be one of \(units.joined(separator: ", "))")
        }
        guard UsageLimits.Window(rawValue: period) != nil else {
            throw AppError.usage("limit period must be one of \(UsageLimits.Window.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        // Nobody sells a fraction of a token or half a request; money and credits are real as
        // decimals. A whole token limit is also what the Factory write-through needs, since
        // `usage_limits` holds a whole token count.
        if unit == "tokens" || unit == "requests", amount.rounded() != amount {
            throw AppError.usage("a \(unit) limit is a whole number")
        }
    }

    /// The tool's own display name, or the custom tool's name. This is the row title.
    static func displayName(_ sub: CatalogDB.Subscription) -> String {
        switch sub.tool {
        case "cursor": return "Cursor"
        case "gemini": return "Gemini"
        case "copilot": return "GitHub Copilot"
        case "perplexity": return "Perplexity"
        case "chatgpt": return "ChatGPT"
        case "factory": return "Factory"
        default: return sub.name.isEmpty ? "Custom" : sub.name
        }
    }

    /// The limit as one line of text, exactly what the row shows. Deterministic en_US digits:
    /// the dashboard's own copy is English, so a comma-separated group is what every user sees.
    static func limitText(_ limit: LimitFields) -> String {
        let period = limit.period == UsageLimits.Window.fiveHour.rawValue
            ? "per 5-hour window"
            : limit.period == UsageLimits.Window.weekly.rawValue ? "per week" : "per month"
        if limit.unit == "usd" { return "\(money(limit.amount)) \(period)" }
        return "\(plain(limit.amount)) \(limit.unit) \(period)"
    }

    private static func plain(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = amount.rounded() == amount ? 0 : 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    }

    private static func money(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = amount.rounded() == amount ? 0 : 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    }

    /// The status row a subscription renders as. It is a card the user chose to pin, so it never
    /// carries a measured figure: no tokens, no percent, and the one honest sentence about why.
    static func statusRow(_ sub: CatalogDB.Subscription) -> ToolStatus {
        var row = ToolStatus(source: sub.tool, title: displayName(sub), kind: "subscription")
        row.plan = sub.plan
        row.subscriptionId = sub.id
        if let limit = sub.limit { row.limitText = limitText(limit) }
        row.usageNote = "usage not tracked locally"
        return row
    }

    /// Merges the user's subscriptions into the plan rows the dashboard renders:
    /// - a built-in tool's subscription rows take over that tool's placeholder slot (one row per
    ///   subscription, so a second plan for the same tool is a second row in the same place);
    /// - a Factory subscription attaches to the Droid row instead of adding one, because Droid
    ///   is the one listed tool whose usage is measured locally — its token limit is already in
    ///   `usage_limits`, the single source of truth for a Droid window limit, so the row's meter
    ///   needs no second number here, and a non-token limit stays display text;
    /// - a custom tool has no placeholder to take over, so its rows go after the built-ins.
    static func merge(_ subs: [CatalogDB.Subscription], into plans: [ToolStatus]) -> [ToolStatus] {
        guard !subs.isEmpty else { return plans }
        var byTool: [String: [ToolStatus]] = [:]
        var custom: [ToolStatus] = []
        var factory: CatalogDB.Subscription?
        for sub in subs {
            if sub.tool == "factory" { factory = sub; continue }
            let row = statusRow(sub)
            if sub.tool == "custom" { custom.append(row) } else { byTool[sub.tool, default: []].append(row) }
        }
        var out: [ToolStatus] = []
        var placed: Set<String> = []
        for var row in plans {
            if row.source == "droid" {
                if let factory {
                    row.plan = factory.plan
                    row.subscriptionId = factory.id
                    if let limit = factory.limit, limit.unit != "tokens" { row.limitText = limitText(limit) }
                }
                out.append(row)
                continue
            }
            if row.subscriptionId == nil, row.kind == "subscription",
               let rows = byTool[row.source], !placed.contains(row.source)
            {
                placed.insert(row.source)
                out.append(contentsOf: rows)
                continue
            }
            out.append(row)
        }
        // A subscribed tool whose placeholder is somehow absent (or a custom tool) still gets its
        // rows; created order keeps the list stable.
        for (tool, rows) in byTool where !placed.contains(tool) {
            out.append(contentsOf: rows)
            placed.insert(tool)
        }
        out.append(contentsOf: custom)
        return out
    }
}
