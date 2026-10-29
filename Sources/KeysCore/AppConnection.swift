import Foundation

/// The ONE seam that decides "is the Keysrs app running" for every app-bound MCP
/// tool and every eligible CLI caller: `connect()` wraps `ControlClient.connect()`
/// — the same control channel every CLI command already uses (`control.json`
/// beside the catalog, loopback HTTP with the per-launch `X-KSF-Token`) — and
/// when no live app exists it owns the whole on-demand launch: open the installed
/// app by bundle id with the installed path as the fallback, wait on a bounded
/// backoff schedule for a live `control.json` AND a healthy authenticated control
/// call, retry the launch once, and then translate everything into exactly the
/// one sentence below. No other code path gains launch, wait or retry behavior —
/// no tool, no command, no `ControlClient` — and every eligible caller routes
/// through this function instead of its own policy. `keys unwrap` (the onboarding
/// slice, merged onto this branch) deliberately keeps the plain control client and
/// no auto-launch — a script gets exit 6 and nothing changes — so it is the one
/// documented exception to this seam.
///
/// The rules this seam carries:
/// - **The not-running condition is a tool result on MCP, never a process exit** —
///   MCP never uses exit codes as an API. The throw lands in the tool handler,
///   whose catch makes it an `isError` result through the error formatter; the
///   sentence carries no path, pid or token shape, so it survives that pipeline
///   and the output guard byte for byte. On the CLI the same throw is exit 6.
/// - **The app-call timeout is 10 s**, overriding `ControlClient`'s 180 s default,
///   so a hung site cannot hang the server: a tool call always comes back. CLI
///   callers that sit inside one Touch ID prompt keep the long default by using
///   `controlClient` after `connect()` decided the launch.
/// - **The connection is lazy and per call** — nothing here runs at server startup
///   or construction, and no connection is cached, so the server starts and answers
///   `initialize`/`tools/list` with no app present and a site that disappears
///   mid-session is seen on the very next call.
/// - **No analytics** — this path reads one local file and talks to loopback only.
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

    /// The installed app, opened by bundle id first with the documented install
    /// location as the fallback. The id is the registered one; the path covers a
    /// bundle LaunchServices has not registered yet (a just-copied install).
    static let appBundleID = "com.keysreallysafe.keysrs"
    static let installedAppURL = URL(fileURLWithPath: "/Applications/Keysrs.app")

    /// The bounded launch policy: one launch attempt, then exactly ONE retry.
    /// Each attempt waits at most `launchHealthBudget` seconds for the app to
    /// come up, so a missing or wedged app costs a caller about twice the budget
    /// and never an unbounded hang.
    static let launchAttempts = 2
    static let launchHealthBudget: TimeInterval = 10
    /// The backoff between health polls, capped by the last step and by the
    /// remaining budget, so an attempt ends on its bound and not a step past it.
    static let launchBackoffSteps: [TimeInterval] = [0.25, 0.5, 1, 1, 2, 2]
    /// One health probe's own bound; the site is loopback, so this only bites a
    /// half-started owner whose socket accepts and never answers.
    static let launchProbeTimeout: TimeInterval = 2

    /// The health probe: a token-gated read on the control endpoint. POST, so the
    /// per-launch token is actually checked — a stale or wrong token answers 403
    /// and the site is not healthy — and a pure status listing, so it changes
    /// nothing and works before any window exists.
    static let launchHealthPath = "/api/mcp/grants/status"

    private let client: ControlClient

    private init(client: ControlClient) { self.client = client }

    /// The single "is the app up?" decision. A live control file is today's rule
    /// unchanged — its owner alive means the app is running, so nothing launches
    /// and nothing polls on that path. With no live app, this function alone owns
    /// the launch: open, bounded wait for health, one retry, and after the retry
    /// the plain sentence is the answer — a tool result on MCP, exit 6 on the CLI,
    /// never any caller's own wording.
    static func connect(
        control: URL = ControlFile.url(),
        launch: AppLaunchSeam = .production
    ) throws -> AppConnection {
        // The fast path: the file's owner is the truth, exactly as before this
        // seam grew a launch; a hung site stays the app-call timeout's problem.
        if let client = try? ControlClient.connect(control: control) {
            return AppConnection(client: client)
        }
        // No live app: this is the only place in the product that launches it.
        for _ in 0..<launchAttempts {
            openInstalledApp(launch: launch)
            if let app = waitForHealthyApp(control: control, launch: launch) {
                return app
            }
        }
        throw AppError.siteUnavailable(notRunningMessage)
    }

    /// One open attempt: the bundle id first, the installed path only when that
    /// open was refused. Which target and when is this seam's policy; the opening
    /// itself is the injected launcher's, and nothing else in the product opens
    /// the app on a caller's behalf.
    private static func openInstalledApp(launch: AppLaunchSeam) {
        if launch.launcher.open(bundleID: appBundleID) { return }
        _ = launch.launcher.open(installedAt: installedAppURL)
    }

    /// The bounded wait: poll for BOTH a live control.json and a healthy
    /// authenticated control call, backing off through `launchBackoffSteps` until
    /// `launchHealthBudget` is spent, then one last poll on the bound.
    private static func waitForHealthyApp(control: URL, launch: AppLaunchSeam) -> AppConnection? {
        var waited: TimeInterval = 0
        var step = 0
        while waited < launchHealthBudget {
            if let app = healthyApp(control: control) { return app }
            let interval = min(
                launchBackoffSteps[min(step, launchBackoffSteps.count - 1)],
                launchHealthBudget - waited
            )
            launch.clock.sleep(for: interval)
            waited += interval
            step += 1
        }
        return healthyApp(control: control)
    }

    /// One poll: the control file live AND its site answering the authenticated
    /// health probe. The app writes control.json only after its loopback server is
    /// accepting and its gateway is bound, but the probe is the belt over races
    /// and half-started owners: it proves this launch's app, not just its file.
    private static func healthyApp(control: URL) -> AppConnection? {
        guard let client = try? ControlClient.connect(control: control) else { return nil }
        do {
            _ = try client.call(
                method: "POST", path: launchHealthPath, body: [:], expect: 200, timeout: launchProbeTimeout
            )
            return AppConnection(client: client)
        } catch {
            return nil
        }
    }

    /// The connected control client, for eligible CLI callers: the launch decision
    /// was this seam's, and the calls after it keep `ControlClient`'s long default
    /// timeout because a CLI call like `keys grant` sits inside one Touch ID
    /// prompt — the 10 s `call` bound is for MCP tools, which never wait on a
    /// person. Nothing here re-exposes `ControlClient.connect()`: the decision
    /// stays with `connect()`.
    var controlClient: ControlClient { client }

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
