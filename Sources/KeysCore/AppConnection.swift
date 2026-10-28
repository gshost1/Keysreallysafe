import Foundation

/// The ONE seam that decides "is the Keysrs app running" for every app-bound MCP
/// tool: `connect()` wraps `ControlClient.connect()` — the same control channel
/// every CLI command already uses (`control.json` beside the catalog, loopback HTTP
/// with the per-launch `X-KSF-Token`) — and translates its failure into exactly the
/// one sentence below, so the legacy CLI wording never reaches a tool result. No
/// MCP tool may call `ControlClient.connect()` directly; the app-bound tools call
/// `AppConnection.connect()` instead, freshly on every tool call.
///
/// The rules this seam carries:
/// - **The not-running condition is a tool result, never a process exit** — MCP
///   never uses exit codes as an API. The throw lands in the tool handler, whose
///   catch makes it an `isError` result through the error formatter; the sentence
///   carries no path, pid or token shape, so it survives that pipeline and the
///   output guard byte for byte.
/// - **The app-call timeout is 10 s**, overriding `ControlClient`'s 180 s default,
///   so a hung site cannot hang the server: a tool call always comes back.
/// - **The connection is lazy and per call** — nothing here runs at server startup
///   or construction, and no connection is cached, so the server starts and answers
///   `initialize`/`tools/list` with no app present and a site that disappears
///   mid-session is seen on the very next call.
/// - **No analytics** — this path reads one local file and talks to loopback only.
///
/// The headless-app mission adds auto-launch INSIDE `connect()` and nowhere else;
/// keep this the single seam.
struct AppConnection {
    /// The exact sentence every app-not-running failure becomes on the MCP surface,
    /// byte-for-byte as the contract pins it.
    static let notRunningMessage = "Keysrs isn't running. Open Keysrs from Applications, then try again."

    /// The app-call timeout. A site that accepts but never answers — or answers
    /// slowly — cannot hold a tool call (and with it the server's loop) open past
    /// this bound.
    static let appCallTimeout: TimeInterval = 10

    /// The longer bound for the presence-gated calls (`import_and_wrap`; `test_keys`
    /// with confirm): the whole call legitimately stays open while a Touch ID prompt
    /// is up, and 10 s would kill a slow approval mid-import. Opt-in per call through
    /// `call`'s `timeout:` — the 10 s default above stays the bound for everything
    /// else, exactly as its pins describe it.
    static let presenceCallTimeout: TimeInterval = 120

    private let client: ControlClient

    private init(client: ControlClient) { self.client = client }

    /// The single "is the app up?" decision. The control file beside the catalog is
    /// read fresh — nothing is cached — and its owner must be alive; every other
    /// shape (the file missing, invalid, its port or pid out of range, or its
    /// process gone) is one condition, "the app isn't running", and becomes the
    /// pinned sentence so no caller's own wording can reach a tool result.
    static func connect(control: URL = ControlFile.url()) throws -> AppConnection {
        do {
            return AppConnection(client: try ControlClient.connect(control: control))
        } catch {
            throw AppError.siteUnavailable(notRunningMessage)
        }
    }

    /// One app call: loopback HTTP with the per-launch `X-KSF-Token` from the
    /// control file on every request, bounded by `timeout` (the 10 s default; a
    /// presence-gated caller passes `presenceCallTimeout`). The site's answer for
    /// `expect` is returned; anything else becomes the AppError it carries.
    func call(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        expect: Int,
        timeout: TimeInterval = Self.appCallTimeout
    ) throws -> [String: Any] {
        try client.call(method: method, path: path, body: body, expect: expect, timeout: timeout)
    }
}
