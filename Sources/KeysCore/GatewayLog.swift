import ArgumentParser
import Darwin
import Foundation

/// Why a gateway call ended the way it did, as a stable code. It is stored with every call,
/// printed by `keys log` and `keys doctor`, and sent as `reason` in the 502 the gateway writes
/// when no response head arrived, so a harness can tell this side's failures from a
/// provider's status without parsing `detail`. Codes are only ever added, never renamed.
enum GatewayReason {
    /// The provider answered; its status is what the caller got.
    static let upstreamStatus = "upstream_status"
    /// The gateway's own request limit (`GatewayListener.resourceTimeout`) ran out.
    static let gatewayTimeout = "gateway_timeout"
    /// No connection: the host did not resolve, refused, or there is no network.
    static let connectFailed = "connect_failed"
    static let tlsFailed = "tls_failed"
    /// The connection to the provider dropped before the call finished.
    static let connectionLost = "connection_lost"
    /// The caller went away (or stopped reading for the socket deadline) and the gateway
    /// cancelled the upstream call.
    static let clientClosed = "client_closed"
    /// Any other transport failure; the 502 body's `detail` has the URL error code.
    static let networkError = "network_error"

    /// The bucket for a transport failure. Only the domain and code are read, never a message.
    static func classify(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return networkError }
        switch error.code {
        case NSURLErrorTimedOut:
            return gatewayTimeout
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed:
            return connectFailed
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return tlsFailed
        case NSURLErrorNetworkConnectionLost:
            return connectionLost
        default:
            return networkError
        }
    }

    /// How one forwarded call ended. The caller leaving comes first because the gateway then
    /// cancels the upstream task itself. A failure after the head (a stream cut off by the
    /// request limit) still names the failure: the status the caller saw is the provider's,
    /// but the provider did not end the call.
    static func outcome(clientClosed: Bool, failure: NSError?, gotHead: Bool) -> String {
        if clientClosed { return Self.clientClosed }
        if let failure { return classify(failure) }
        return gotHead ? upstreamStatus : networkError
    }
}

/// One line of the gateway's request log: a call it forwarded (a `usage_events` row) or one it
/// refused (a `gateway_denied` key event). Neither table holds a body, a token or a key value,
/// and nothing here reads one.
struct GatewayLogEntry: Equatable {
    enum Kind: String { case call, refusal }

    var kind: Kind
    var ts: String
    var key: String
    var provider: String?
    /// Where the call went; nil for a refusal (nothing went upstream) and for calls stored
    /// before the column existed.
    var host: String?
    /// What the caller got. Nil for a breaker trip, which is an event rather than an answer,
    /// and for rows stored before statuses were kept.
    var status: Int?
    var durationMs: Int?
    var reason: String?
    /// "loopback" or "relay".
    var via: String

    var jsonObject: [String: Any] {
        [
            "ts": ts,
            "kind": kind.rawValue,
            "key": key,
            "provider": provider ?? NSNull(),
            "host": host ?? NSNull(),
            "status": status ?? NSNull(),
            "duration_ms": durationMs ?? NSNull(),
            "reason": reason ?? NSNull(),
            "via": via,
        ]
    }
}

/// Which entries a log query returns.
enum GatewayLogFilter {
    case all
    /// `keys log --failed`: refusals, non-2xx answers, gateway-side failures, and calls too old
    /// to have a status (product analytics counts those as failed too).
    case failed
    /// What `keys doctor` lists: calls that ended for a gateway-side reason and the refusals in
    /// `gatewaySideRefusals`. Token refusals are left out (`keys log --failed` has them): anyone
    /// who can reach the gateway, the relay's URL included, can collect them and push real
    /// failures off a short list. Old rows with no reason are left out, since nobody knows why
    /// they ended.
    case gatewaySide

    /// The 404 refusal for a key whose gateway is off, recorded only for a verified client.
    static let gatewayOff = "gateway_off"
    /// Refusals only a working credential can cause: a key the breaker paused, and a verified
    /// client calling a key whose gateway is off.
    static let gatewaySideRefusals = [GatewayBreaker.code, gatewayOff]
}

/// Where a `keys log --tail` has read up to: the highest usage row and key event it has seen.
struct GatewayLogCursor: Equatable {
    var call: Int64
    var refusal: Int64
}

enum GatewayLogFormat {
    static let header = ["TIME", "KEY", "PROVIDER", "HOST", "STATUS", "DURATION", "REASON", "VIA"]
    /// Starting widths, so a followed log stays aligned for typical rows as it grows.
    private static let floors = [19, 8, 10, 24, 6, 8, 15, 8]

    static func fields(_ entry: GatewayLogEntry, timeZone: TimeZone) -> [String] {
        [
            time(entry.ts, timeZone: timeZone),
            printable(entry.key),
            entry.provider.map(printable) ?? "-",
            entry.host.map(printable) ?? "-",
            entry.status.map(String.init) ?? "-",
            duration(entry.durationMs),
            entry.reason.map(printable) ?? "-",
            entry.via,
        ]
    }

    /// Catalog text goes straight to a terminal here, so a control character (an escape
    /// sequence in a provider name, say) is printed as "?" instead of being interpreted.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? "?" : scalar
        }))
    }

    static func duration(_ ms: Int?) -> String {
        guard let ms, ms >= 0 else { return "-" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    /// Local wall-clock time to the second; an unparseable stored value is shown as stored.
    static func time(_ iso: String, timeZone: TimeZone) -> String {
        guard let date = UTC.parse(iso) else { return printable(iso) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    static func widths(_ rows: [[String]], atLeast base: [Int] = []) -> [Int] {
        var widths = header.indices.map { max(floors[$0], header[$0].count, base.indices.contains($0) ? base[$0] : 0) }
        for row in rows {
            for (i, field) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], field.count)
            }
        }
        return widths
    }

    static func line(_ fields: [String], widths: [Int]) -> String {
        var out = ""
        for (i, field) in fields.enumerated() {
            if i == fields.count - 1 {
                out += field
            } else {
                out += field.padding(toLength: max(widths[i], field.count), withPad: " ", startingAt: 0) + "  "
            }
        }
        return out
    }

    /// The whole table, header first, rows in the order given.
    static func table(_ entries: [GatewayLogEntry], timeZone: TimeZone) -> [String] {
        let rows = entries.map { fields($0, timeZone: timeZone) }
        let widths = widths(rows)
        return [line(header, widths: widths)] + rows.map { line($0, widths: widths) }
    }
}

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Show recent gateway calls and refusals, newest last (never a body, token or key value).",
        discussion: """
            One line per call the gateway forwarded or refused: time, key, provider, upstream \
            host, status, duration, reason, and whether it came in on loopback or through keys \
            relay. A call is written when it finishes. REASON is upstream_status when the \
            provider answered (its status is passed through unchanged); gateway_timeout, \
            connect_failed, tls_failed, connection_lost, network_error and client_closed are \
            failures on this side of the provider; a refusal shows the code the gateway refused \
            with, such as no_client_token, grant_path_not_allowed or gateway_off. VIA is a \
            label: keys relay always sets it and drops a caller's copy, but a program on this Mac \
            can send it too.
            """
    )

    @Option(help: "Only calls with this key.")
    var key: String?

    @Flag(help: "Only failures: non-2xx statuses, gateway-side failures and refusals.")
    var failed = false

    @Flag(help: "Keep printing entries as they are written; Ctrl-C stops.")
    var tail = false

    @Option(help: "How many recent entries to print first.")
    var limit = 50

    @Flag(help: "One JSON object per line instead of the table.")
    var json = false

    static let pollInterval: TimeInterval = 1

    func validate() throws {
        guard (1...10_000).contains(limit) else { throw ValidationError("--limit must be between 1 and 10000") }
    }

    func run() throws {
        if let key { try KeyName.validate(key) }
        let filter: GatewayLogFilter = failed ? .failed : .all
        let db = try CatalogDB(path: Paths.resolvingCatalog())
        var cursor = try db.gatewayLogCursor()
        let recent = try db.gatewayLog(through: cursor, key: key, filter: filter, limit: limit)
        let timeZone = TimeZone.current
        var widths = GatewayLogFormat.widths(recent.map { GatewayLogFormat.fields($0, timeZone: timeZone) })
        if json {
            for entry in recent { try JSONValue.printLine(entry.jsonObject) }
        } else if recent.isEmpty, !tail {
            print(failed ? "no failed gateway calls recorded" : "no gateway calls recorded")
            return
        } else {
            print(GatewayLogFormat.line(GatewayLogFormat.header, widths: widths))
            for entry in recent { print(GatewayLogFormat.line(GatewayLogFormat.fields(entry, timeZone: timeZone), widths: widths)) }
            fflush(stdout)
        }
        guard tail else { return }
        while true {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let next = try db.gatewayLogCursor()
            // A purge empties the tables and usage row ids start over; read from the start again.
            if next.call < cursor.call { cursor.call = 0 }
            if next.refusal < cursor.refusal { cursor.refusal = 0 }
            guard next != cursor else { continue }
            let entries = try db.gatewayLog(after: cursor, through: next, key: key, filter: filter)
            cursor = next
            if json {
                for entry in entries { try JSONValue.printLine(entry.jsonObject) }
                continue
            }
            let rows = entries.map { GatewayLogFormat.fields($0, timeZone: timeZone) }
            widths = GatewayLogFormat.widths(rows, atLeast: widths)
            for row in rows { print(GatewayLogFormat.line(row, widths: widths)) }
            fflush(stdout)
        }
    }
}
