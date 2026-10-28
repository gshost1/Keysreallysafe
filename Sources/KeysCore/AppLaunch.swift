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

    /// LaunchServices and the wall clock: what every production caller runs with.
    static let production = AppLaunchSeam()
}

/// Production: LaunchServices resolves the bundle id to its app and opens it; the
/// path form opens the fixed installed location, for a bundle LaunchServices has
/// not registered yet (a just-copied install). `NSWorkspace.open` answers whether
/// the open was accepted, and the app takes it from there — the launcher never
/// waits for it; the waiting belongs to the one seam's bounded poll.
struct LaunchServicesAppLauncher: AppLauncher {
    func open(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
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
