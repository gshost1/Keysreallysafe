import Foundation

/// Droid (Factory's coding agent) writes one small `<session>.settings.json` beside each session
/// transcript, carrying the session's running token totals. Only that `tokenUsage` block is read;
/// the `.jsonl` transcripts, auth files and everything else under ~/.factory are never opened.
enum DroidActivity {
    /// Settings files are a few KB; anything far larger is not one.
    static let maxSettingsBytes = 1 << 20

    /// Totals are per session, not per turn, so a session counts toward the week its settings file
    /// was last written in, with its whole total. `thinkingTokens` is left out: it never exceeds
    /// `outputTokens`, so it is part of it, and adding it would count those tokens twice.
    /// `factoryCredits` is left out because its unit is not documented.
    static func row(home: URL, period: SpendPeriod?, now: Date, timeZone: TimeZone = .current) -> ToolStatus {
        var row = ToolStatus(source: "droid", title: "Droid", kind: "subscription", period: period)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey]) else {
            row.usageNote = "No Droid sessions on this Mac."
            return row
        }
        let (start, end) = SpendRange.week.interval(now: now, timeZone: timeZone)
        var tokens = 0
        var count = 0
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            ) else { continue }
            for url in files where url.lastPathComponent.hasSuffix(".settings.json") {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= maxSettingsBytes,
                      let modified = values.contentModificationDate, modified >= start, modified < end,
                      let data = try? Data(contentsOf: url),
                      let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
                      let usage = JSONValue.object(obj["tokenUsage"])
                else { continue }
                let total = ["inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens"]
                    .reduce(0) { $0 + max(0, (usage[$1] as? NSNumber)?.intValue ?? 0) }
                guard total > 0 else { continue }
                tokens += total
                count += 1
            }
        }
        row.weeklyTokens = tokens
        let limits = "Factory plan limits and credits are not in local files."
        row.usageNote = tokens == 0
            ? "No Droid usage this week. \(limits)"
            : "\(count) Droid session\(count == 1 ? "" : "s") active this week, from the token totals Droid keeps on this Mac. \(limits)"
        return row
    }
}
