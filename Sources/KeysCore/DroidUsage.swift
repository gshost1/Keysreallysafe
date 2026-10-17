import Foundation

/// The Droid row on the Usage pane: three token windows counted from the per-request records the
/// ingest keeps in the catalog under source `droid-local`. Only the catalog is read here, so the
/// row no longer opens anything under `~/.factory` — not the per-session settings files it used
/// to read, and never transcripts or auth — and its history survives Droid's log rotation.
enum DroidUsage {
    struct Windows: Equatable {
        var fiveHour = 0
        var weekly = 0
        var monthly = 0
    }

    /// Rolling 5 hours from now, then the same calendar week and month the other rows and the
    /// Chart use (`SpendRange`), so a week starts in the same place everywhere.
    static func windows(catalog: CatalogDB, now: Date, timeZone: TimeZone = .current) throws -> Windows {
        let fiveHourStart = now.addingTimeInterval(-5 * 3600)
        let week = SpendRange.week.interval(now: now, timeZone: timeZone)
        let month = SpendRange.month.interval(now: now, timeZone: timeZone)
        // One read from the earliest edge: a 5-hour window on the 1st reaches into the previous
        // month, so the month start is not necessarily the earliest of the three.
        let start = min(min(fiveHourStart, week.0), month.0)
        let events = try catalog.usageEvents(from: UTC.iso(start), to: UTC.iso(now), source: .droid)
        var out = Windows()
        for event in events {
            // One token rule, the engine's own for droid-local (every bucket counts), stated in
            // TokenTotals.normalized and reused here so the row and the Chart cannot disagree.
            let tokens = TokenTotals.normalized(event)
            guard let at = UTC.parse(event.occurredAt) else { continue }
            if at >= fiveHourStart { out.fiveHour.saturatingAdd(tokens) }
            if at >= week.0 && at < week.1 { out.weekly.saturatingAdd(tokens) }
            if at >= month.0 && at < month.1 { out.monthly.saturatingAdd(tokens) }
        }
        return out
    }

    /// tokens / limit × 100 as a whole percent, honest past 100: the number keeps the truth and
    /// the meter caps visually.
    static func pct(_ tokens: Int, limit: Int) -> Int {
        Int((Double(tokens) / Double(limit) * 100).rounded())
    }

    static func row(catalog: CatalogDB, now: Date = Date(), timeZone: TimeZone = .current) throws -> ToolStatus {
        let windows = try self.windows(catalog: catalog, now: now, timeZone: timeZone)
        let limits = Dictionary(
            try catalog.usageLimits(source: "droid").map { ($0.window, $0.tokens) },
            uniquingKeysWith: { first, _ in first }
        )
        var row = ToolStatus(source: "droid", title: "Droid", kind: "subscription")
        row.fiveHourTokens = windows.fiveHour
        row.weeklyTokens = windows.weekly
        row.monthlyTokens = windows.monthly
        row.fiveHourLimit = limits[UsageLimits.Window.fiveHour.rawValue]
        row.weeklyLimit = limits[UsageLimits.Window.weekly.rawValue]
        row.monthlyLimit = limits[UsageLimits.Window.monthly.rawValue]
        // A percent exists only where the user set a limit; an unlimited window is tokens only,
        // never a percent of a limit nobody chose.
        if let limit = row.fiveHourLimit { row.fiveHourPct = pct(windows.fiveHour, limit: limit) }
        if let limit = row.weeklyLimit { row.weeklyPct = pct(windows.weekly, limit: limit) }
        if let limit = row.monthlyLimit { row.monthlyPct = pct(windows.monthly, limit: limit) }
        // The empty state stays honest: with nothing ingested the row says so instead of dressing
        // a zero up as a measurement. Records that simply fall outside every window are different:
        // those zeros are real zeros.
        if try catalog.newestUsage(source: "droid-local") == nil {
            row.usageNote = "No Droid usage recorded yet. The windows fill from the per-request records in Droid's local logs."
        } else {
            row.usageNote = "Tokens per window, from the per-request records in Droid's local logs. Factory's own plan limits are not in local files; use Set limits to add your own."
        }
        return row
    }
}
