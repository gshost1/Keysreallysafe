import AppKit
import Foundation

/// The side effects `AppConnection.connect()` may use to start the installed app
/// and wait for it. The POLICY — when to launch, by which target, how long to
/// wait, how often to retry — lives in `AppConnection.connect()` and nowhere
/// else; these are only the injectable effects, so a test runs the real bounded
/// schedule and the real retry against a recording fake and never reaches
/// LaunchServices, the wall clock or the installed app.

/// Opens the installed Keysrs app. Two spellings because the contract's launch
/// order is two-step: the registered bundle id first, the fixed installed path as
/// the fallback when that open is refused. Each answers whether the open was
/// accepted, so the one seam can tell "nothing is installed" from "starting".
protocol AppLauncher: Sendable {
    /// Where LaunchServices has the bundle id registered; nil when nothing
    /// resolves under it. Separate from the open, so the seam's POLICY can
    /// inspect the resolution before anything is opened: LaunchServices
    /// registers a mounted disk image's copy or a build output under the same
    /// id as readily as the real install, and only the installed location is
    /// the app this product promises to open.
    func resolve(bundleID: String) -> URL?
    /// Opens the app LaunchServices has registered under the bundle id; false
    /// when nothing resolves (or nothing opens) under it.
    func open(bundleID: String) -> Bool
    /// Opens the app at an exact path; false when nothing is there to open.
    func open(installedAt url: URL) -> Bool
}

/// The wait behind the launch backoff. One method, so a fake runs the whole
/// bounded schedule without sleeping and records exactly what was asked.
protocol AppLaunchClock: Sendable {
    func sleep(for interval: TimeInterval)
}

/// The pair `AppConnection.connect()` needs, bundled so a caller injects one
/// thing and can never mix a real opener with a fake clock (or the reverse).
/// Production is `.production`; tests build the pair over their own fakes.
struct AppLaunchSeam: Sendable {
    var launcher: any AppLauncher = LaunchServicesAppLauncher()
    var clock: any AppLaunchClock = ThreadAppLaunchClock()

    /// LaunchServices and the wall clock: what every production caller runs
    /// with. `KEYS_TEST_NO_LAUNCH` — ours, the `KEYS_*` fixture-variable
    /// convention — swaps in the fail-closed test pair below: a spawned `keys`
    /// subprocess runs production code and cannot be handed a Swift closure,
    /// so the environment is the one injection channel its test rig has, and
    /// with it the process CANNOT reach LaunchServices or the installed app
    /// even on a down site — opens are refused and the clock never sleeps, so
    /// an app-bound call fails closed to the plain not-running sentence, fast
    /// and bounded. An empty value means unset, the `Paths.env` convention.
    static var production: AppLaunchSeam { production(environment: ProcessInfo.processInfo.environment) }

    /// The resolved pair for an explicit environment — the testable form of
    /// the default above.
    static func production(environment: [String: String]) -> AppLaunchSeam {
        guard let flag = environment["KEYS_TEST_NO_LAUNCH"], !flag.isEmpty else {
            return AppLaunchSeam()
        }
        return AppLaunchSeam(launcher: NoLaunchAppLauncher(), clock: NoSleepAppLaunchClock())
    }
}

/// Production: LaunchServices resolves the bundle id to its app and opens it; the
/// path form opens the fixed installed location, for a bundle LaunchServices has
/// not registered yet (a just-copied install). `NSWorkspace.open` answers whether
/// the open was accepted, and the app takes it from there — the launcher never
/// waits for it; the waiting belongs to the one seam's bounded poll.
struct LaunchServicesAppLauncher: AppLauncher {
    func resolve(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func open(bundleID: String) -> Bool {
        guard let url = resolve(bundleID: bundleID) else { return false }
        return open(installedAt: url)
    }

    func open(installedAt url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Production: the real sleep, so the bounded schedule is a real (short) wait.
struct ThreadAppLaunchClock: AppLaunchClock {
    func sleep(for interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Test-only (`KEYS_TEST_NO_LAUNCH`): the launcher that never opens anything.
/// Both forms answer false, so the one seam's launch loop is a pure refusal —
/// nothing resolves through LaunchServices, and nothing can reach the
/// installed app from a subprocess under test. The refusal is what a rig
/// wants: a down site then fails closed to the plain sentence instead of
/// ever touching the user's real app.
struct NoLaunchAppLauncher: AppLauncher {
    func resolve(bundleID: String) -> URL? { nil }
    func open(bundleID: String) -> Bool { false }
    func open(installedAt url: URL) -> Bool { false }
}

/// Test-only (`KEYS_TEST_NO_LAUNCH`): the clock that never sleeps, so the
/// bounded wait runs its whole schedule instantly — a down site fails closed
/// in milliseconds instead of spending the two launch budgets a real wait
/// would, which is also what proves the seam was active: a test whose
/// subprocess quietly regressed to the real clock would take its 20 s.
struct NoSleepAppLaunchClock: AppLaunchClock {
    func sleep(for interval: TimeInterval) {}
}
