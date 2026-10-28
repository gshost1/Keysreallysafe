import Foundation
@testable import KeysCore

/// The shared fail-closed isolation guard for every test that exercises
/// auto-launch or `AppConnection`. An intermediate auto-launch run used the
/// default control file, found the machine's really-running installed app, and
/// reached the real catalog and Keychain before anyone noticed — this guard is
/// the approved answer: a rig that is pointed at production state, or wired to
/// production side effects, aborts BEFORE the first operation that could touch
/// it.
///
/// Every rig passes the exact values it is about to run with — its configured
/// control-file URL, its launch pair, its secret store — either directly to
/// `assertIsolated(...)` or by building the whole world through `makeWorld(...)`,
/// and the guard rejects by THROWING, so a forbidden configuration never gets to
/// its side effects:
///
/// - the configured control-file URL must not be at or beneath
///   `~/Library/Application Support/Keysreallysafe` (the production control
///   path — which is exactly where the default `ControlFile.url()` points when
///   no explicit catalog is injected), nor beneath `/Applications/Keysrs.app`;
/// - the configured control-file URL must live inside this process's own
///   temporary area, so a rig cannot fall back to a default or a checkout
///   location and still pass;
/// - the launch pair must not be the production implementations
///   (`LaunchServicesAppLauncher`, `ThreadAppLaunchClock`) and the secret store
///   must not be the production `KeychainStore`.
///
/// The guard compares CONFIGURATION ONLY: paths as strings, implementations as
/// types. It never stats, opens, reads, writes or otherwise inspects the real
/// `control.json` — not even to confirm a rejection — and creates nothing
/// except `makeWorld(...)`'s own directory, after the check has passed.
///
/// The structural belt under the wiring — every rig block that configures or
/// uses a control URL carries a guard call — is
/// `AppConnectionIsolationGuardTests.testEveryAppConnectionRigPassesTheGuard`.
enum AppConnectionIsolationGuard {

    /// Fails closed on a production-shaped configuration. Call this with the
    /// rig's own values, before any fixture, file, socket, Keychain or app
    /// operation: the throw aborts the rig before its first side effect, and
    /// the refusal message names the rule that fired.
    static func assertIsolated(
        control: URL,
        launch: AppLaunchSeam? = nil,
        secrets: (any SecretStore)? = nil
    ) throws {
        // Paths first, compared as configured strings only. The production
        // worlds are rejected wherever the file happens to be — the guard never
        // asks the filesystem, so a rejection needs no evidence from the very
        // state it is refusing to touch.
        let path = control.path
        let productionWorlds: [(root: String, what: String)] = [
            (Paths.appSupport.path, "the production app-support directory"),
            (AppConnection.installedAppURL.path, "the installed app bundle"),
        ]
        for world in productionWorlds where path == world.root || path.hasPrefix(world.root + "/") {
            throw AppError.usage(
                "test isolation rejected \(path): \(world.what) is production state; "
                + "point the rig at an explicit temporary control file"
            )
        }
        // And positively: the configured control path must be this process's
        // own temporary area — an explicit temporary world, never a default.
        if !isTemporary(path) {
            throw AppError.usage(
                "test isolation rejected \(path): the control file must be an explicit "
                + "temporary URL beneath \(FileManager.default.temporaryDirectory.path)"
            )
        }
        // Implementations: production side effects have no place in a rig.
        if let launch {
            if launch.launcher is LaunchServicesAppLauncher {
                throw AppError.usage(
                    "test isolation rejected the production launcher; inject a fake AppLauncher"
                )
            }
            if launch.clock is ThreadAppLaunchClock {
                throw AppError.usage(
                    "test isolation rejected the production clock; inject a fake AppLaunchClock"
                )
            }
        }
        if let secrets, secrets is KeychainStore {
            throw AppError.usage(
                "test isolation rejected the production Keychain store; inject a fake SecretStore"
            )
        }
    }

    /// The guarded world every app-connection rig builds in: an explicit
    /// temporary directory, the catalog URL inside it, and the control URL
    /// beside that catalog — all fail-closed-checked (with the rig's fake
    /// launch pair and fake secret store) BEFORE the directory is even created,
    /// so no fixture, file, socket, Keychain or app operation can precede the
    /// guard. The directory layout matches `makeDB()` exactly: the catalog is
    /// `catalog.db` at the world's root and the control file is its sibling.
    static func makeWorld(
        launch: AppLaunchSeam = .neverLaunching,
        secrets: (any SecretStore)? = nil
    ) throws -> (dir: URL, catalog: URL, control: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("krs-\(UUID().uuidString)", isDirectory: true)
        let catalog = dir.appendingPathComponent("catalog.db")
        let control = ControlFile.url(beside: catalog)
        try assertIsolated(control: control, launch: launch, secrets: secrets)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return (dir, catalog, control)
    }

    /// Path comparison only: the process's temporary area in both of its
    /// spellings (`/var/...` and the `/private/var/...` a resolved URL can
    /// carry). No filesystem call is made — this is the guard's whole job, to
    /// judge the configuration without inspecting the world.
    private static func isTemporary(_ path: String) -> Bool {
        var roots = [FileManager.default.temporaryDirectory.path]
        if !roots[0].hasPrefix("/private") { roots.append("/private" + roots[0]) }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
