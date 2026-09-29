import Foundation

/// Grok Bot (the desktop app) is billed on its own plan, apart from SuperGrok and the Grok row.
/// It keeps chat replicas on disk but no plan name, tokens, cost, credits or limits,
/// so the only honest local measure is how many prompts were sent. Only each entry's kind, role
/// and timestamp are looked at; message text is never kept, logged or passed on.
enum GrokBotActivity {
    /// Replicas are a few hundred KB; anything far larger is not a transcript worth parsing.
    static let maxBlobBytes = 16 << 20

    static func row(home: URL, period: SpendPeriod?, now: Date, timeZone: TimeZone = .current) -> ToolStatus {
        var row = ToolStatus(source: "grok-bot", title: "Grok Bot", kind: "subscription", period: period)
        let dir = home.appendingPathComponent("sand-client-persistence", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            row.usageNote = "No Grok Bot data on this Mac."
            return row
        }
        let (start, end) = SpendRange.week.interval(now: now, timeZone: timeZone)
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        var prompts = 0
        var chats = 0
        for url in files where url.pathExtension == "blob" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBlobBytes,
                  let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
                  let value = JSONValue.object(obj["value"]),
                  let entries = value["entries"] as? [Any]
            else { continue }
            var inChat = 0
            for case let entry as [String: Any] in entries {
                guard JSONValue.string(entry["kind"]) == "message",
                      JSONValue.string(entry["role"]) == "user",
                      let ms = (entry["timestampMs"] as? NSNumber)?.int64Value,
                      ms >= startMs, ms < endMs
                else { continue }
                inChat += 1
            }
            if inChat > 0 {
                prompts += inChat
                chats += 1
            }
        }
        row.weeklyPrompts = prompts
        let limits = "Grok Bot's plan is separate from SuperGrok; its credits and limits are not in local files."
        row.usageNote = prompts == 0
            ? "No Grok Bot prompts this week. \(limits)"
            : "\(plural(prompts, "prompt")) in \(plural(chats, "chat")) this week, counted from the chats Grok Bot keeps on this Mac. \(limits)"
        return row
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
