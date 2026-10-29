import AppKit
import Darwin
import Foundation

/// Only the retired runtime is removed. Catalog, preferences, logs and backups survive.
struct LegacyAppMigration {
    var root: URL
    var plist: URL
    var run: Installer.Runner
    var log: (String) -> Void
    var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    func migrate(activate: () throws -> Void = {}) throws {
        let fm = FileManager.default
        let target = "gui/\(getuid())/\(LoginItem.label)"
        let status = try run("/bin/launchctl", ["print", target]).status
        // Only ESRCH means absent. Permission or session errors must not permit deletion.
        guard status == 0 || status == ESRCH || status == 113 else {
            throw AppError.http("Could not inspect the legacy Keysrs agent; its files were preserved.")
        }
        let loaded = status == 0
        let parts = ["bin", "Web", "Fixtures", "Plugins", "scripts"]
        let exists = fm.fileExists(atPath: plist.path)
        guard loaded || exists || parts.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            try activate()
            return
        }
        log("legacy migration started")
        if loaded {
            guard try run("/bin/launchctl", ["bootout", target]).status == 0,
                  [ESRCH, 113].contains(try run("/bin/launchctl", ["print", target]).status) else {
                log("legacy migration stopped: agent could not be unloaded")
                throw AppError.http("Could not stop the legacy Keysrs agent; its files were preserved.")
            }
        }
        // Bind the replacement before deleting the only working runtime. If startup fails,
        // the original launchd job can be restored from its still-intact plist and executable.
        do { try activate() }
        catch {
            if loaded && exists {
                let restored = try? run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
                log(restored?.status == 0 ? "legacy migration rolled back; agent restored" : "legacy migration rollback failed; runtime preserved")
            } else {
                log("legacy migration activation failed; runtime preserved")
            }
            throw error
        }
        var cleanupComplete = true
        let retired = [("launch agent plist", plist)] + parts.map { ($0, root.appendingPathComponent($0)) }
        for (name, url) in retired where fm.fileExists(atPath: url.path) {
            do { try removeItem(url) }
            catch {
                cleanupComplete = false
                log("legacy migration cleanup pending: \(name); will retry next launch")
            }
        }
        // The replacement already owns the listeners. A locked retired file must not
        // turn a successful activation into an outage; the next launch retries cleanup.
        log(cleanupComplete ? "legacy migration completed; user data preserved" : "legacy migration activated; retirement cleanup pending")
    }
}

enum AppRuntime {
    static func run() throws {
        guard let bundle = AppResources.applicationBundle() else {
            throw AppError.usage("Build and open Keysrs.app for the app window, or use keys --help for CLI commands.")
        }
        if Bundle.main.bundleURL.pathExtension != "app", let executable = bundle.executableURL {
            // A CLI symlink makes Foundation treat ~/.local/bin as Bundle.main. Re-exec
            // the real path for app mode so SMAppService.mainApp sees the actual bundle.
            var arguments = [strdup(executable.path), nil]
            defer { arguments.compactMap { $0 }.forEach { free($0) } }
            _ = arguments.withUnsafeMutableBufferPointer { execv(executable.path, $0.baseAddress!) }
            throw AppError.http("Could not launch Keysrs.app from its command line link.")
        }
        // A second direct invocation must not migrate or start another set of listeners.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.keysreallysafe.keysrs")
            .first { $0.processIdentifier != getpid() }
        if let running {
            running.activate(options: [.activateAllWindows])
            // The running app is headless at rest: activation alone would bring
            // no window forward, so ask it to show its own window over the same
            // control channel `keys dashboard` uses, then exit.
            AppRuntime.requestShowFromRunningInstance()
            return
        }
        let binary = Bundle.main.executableURL!
        let previous = Installer.live.binary
        // Reject an identity change before stopping the old process or removing its executable.
        try StableSigning.validate(binary, replacing: FileManager.default.fileExists(atPath: previous.path) ? previous : nil)
        let root = Paths.appSupport
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try AppInstanceLock(root: root)
        defer { lock.close() }
        // A previous one-click update can leave its set-aside bundle behind if the helper died;
        // the names are the updater's own, so this never touches anything a person created.
        AppUpdater.sweepStaleInstall(around: Bundle.main.bundleURL)
        let logFile = AppLogFile(url: root.appendingPathComponent("menubar.log"))
        func log(_ message: String) { logFile.write(message) }
        _ = try WebRoot.find()
        let service = try AppFactory.makeService()
        // Before the site serves, so every relay the menu or the dashboard turns on logs here.
        service.relayHost = RelayHost(log: { logFile.write("relay " + $0) })
        // The app owns notifications: the authorization ask and the local-state poll
        // both run from the app process, never from a CLI or MCP subprocess.
        let notifications = AppNotifier(preferences: service.preferences)
        // The MCP set_analytics_sharing route's one confirmation line, beside the relay's.
        service.analyticsLog = { logFile.write($0) }
        var startedServer: LoopbackHTTPServer?
        do {
            try LegacyAppMigration(root: root, plist: LoginItem.agentPlist, run: LoginItem.run, log: log).migrate {
                startedServer = try LoopbackSite.bind(service: service, preferredPort: LoginItem.menubarPort, requireGateway: true)
            }
        } catch {
            service.stopGateway()
            startedServer?.stop()
            throw error
        }
        guard let server = startedServer else { throw AppError.http("Keysrs could not start its dashboard.") }
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/keys")
        if CommandLineLink.repairRetired(link: link, retired: root.appendingPathComponent("bin/keys"), binary: binary) {
            log("command line link moved from the retired runtime to Keysrs.app")
        }
        let url = URL(string: "http://127.0.0.1:\(server.boundPort)/")!
        runOnMainActor {
            _ = AppRuntime.assembleApp(service: service, server: server, url: url, log: log, notifications: notifications)
            NSApplication.shared.run()
        }
    }

    /// A direct second invocation (a person opening Keysrs.app again, or running
    /// the binary while the app is up) asks the running app to present its
    /// window through the same token-gated control channel `keys dashboard`
    /// uses, then exits. The launch is the app's own show path, so it becomes
    /// `.regular` while the window is shown; a failure is ignored, because a
    /// first launch that is still binding its site will show it itself.
    /// Returns whether a live site was asked.
    @discardableResult
    static func requestShowFromRunningInstance(
        control: URL? = nil,
        client: (ControlFile.Info) -> ControlClient = { ControlClient(info: $0) }
    ) -> Bool {
        // The default control URL resolves inside the body (a Swift default
        // argument cannot throw): under the test tripwire there is deliberately
        // no default control file, so a second invocation inside a test process
        // finds no live app and asks nothing — the fail-closed direction.
        guard let control = control ?? (try? ControlFile.url()) else { return false }
        guard let info = ControlFile.live(at: control) else { return false }
        _ = try? client(info).call(method: "POST", path: "/api/mcp/app/show", expect: 200)
        return true
    }

    /// The main-actor half of `run()`: the long-lived app assembled around the
    /// bound site, split out with injected seams so the headless launch contract
    /// is testable without a bundle or a window server. Launch applies the
    /// resting `.accessory` policy, runs the one-time 0.13 preference migration
    /// before any surface reads a preference, starts no dashboard window and
    /// raises no welcome — presentation waits for an approved show path — while
    /// the ingest scheduler, the OpenRouter scheduler and the first ingest pass
    /// all start, because they are services, not presentation.
    @MainActor
    static func assembleApp(
        service: KeysService,
        server: LoopbackHTTPServer,
        url: URL,
        log: @escaping (String) -> Void = { _ in },
        activationApplier: @escaping (AppActivation.Policy) -> Void = AppActivation.applyPolicy,
        window: (any DashboardWindow)? = nil,
        makeItemController: @escaping () -> MenubarItemController = { MenubarItemController() },
        scheduleIngest: (KeysService) -> Void = { IngestScheduler.scheduleRepeating(service: $0) },
        scheduleOpenRouter: (KeysService) -> Void = { OpenRouterScheduler.schedule(service: $0) },
        ingestInitially: (KeysService) -> Void = { service in
            DispatchQueue.global(qos: .utility).async {
                _ = try? service.ingest(.all)
                try? service.pollOpenRouter()
            }
        },
        notifications: AppNotifier? = nil,
        startNotifications: (AppNotifier, KeysService) -> Void = AppRuntime.startNotificationPoller,
        latestRelease: (() async throws -> ReleaseInfo)? = nil,
        background: BackgroundUpdater? = nil
    ) -> MenubarExtra {
        do { try service.preferences.applyHeadlessDefaults() }
        catch { log("headless defaults pending: \(error.localizedDescription)") }
        let activation = AppActivation(apply: activationApplier)
        let extra = MenubarExtra(service: service, server: server, url: url, makeItemController: makeItemController)
        // The scheduled check's install half: the app's own prompt and gateway
        // counters, the same installer path Update Now runs, and the app's own
        // quit. Absent only where a rig injects one — the seam is what keeps
        // every launch test offline.
        let updater = background ?? BackgroundUpdater(
            activity: AppUpdateActivity(
                prompts: service.presencePrompts,
                pendingGrants: service.mcpPendingGrants,
                gateway: service.gatewayActivity
            ),
            notifier: notifications,
            quit: { [weak extra] in
                if let extra { extra.quit() } else { NSApp.terminate(nil) }
            },
            log: log
        )
        extra.appWindow = AppWindowController(
            url: url,
            preferences: service.preferences,
            activation: activation,
            window: window,
            latestRelease: latestRelease,
            background: updater,
            log: log
        )
        extra.appWindow?.installMenu(extra: extra)
        MenubarRuntime.extra = extra
        NSApplication.shared.delegate = extra
        scheduleIngest(service)
        scheduleOpenRouter(service)
        ingestInitially(service)
        // The one startup prompt the headless app may raise: the OS notification
        // permission request, behind the injected notifier. Absent (every test
        // rig that does not inject one) it starts nothing and shows no dialog.
        if let notifications {
            service.notifications = notifications
            startNotifications(notifications, service)
        }
        return extra
    }

    /// Starts the app's notification poll: the one authorization ask and the
    /// repeating local-state poll. The poller is retained on the service so its
    /// timer outlives this launch seam; a local would deallocate and its weak
    /// handler would go quiet.
    static func startNotificationPoller(_ notifier: AppNotifier, service: KeysService) {
        let poller = AppNotificationPoller(notifier: notifier, snapshot: { service.notificationSnapshot() })
        service.notificationPoller = poller
        poller.start()
    }
}


enum CommandLineLink {
    static func install(binary: URL, destination: URL, replacingSymbolicLink expected: String? = nil) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path), existing == binary.path { return }
        if let expected {
            guard (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == expected else {
                throw AppError.http("The existing tool changed since confirmation; it was preserved.")
            }
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".keys-link-\(UUID().uuidString)")
            try fm.createSymbolicLink(at: staged, withDestinationURL: binary)
            defer { try? fm.removeItem(at: staged) }
            guard Darwin.rename(staged.path, destination.path) == 0 else {
                throw AppError.http("Could not replace the command line link; the previous link was preserved.")
            }
            return
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // createSymbolicLink fails if any file or even a dangling link already occupies this path.
        try fm.createSymbolicLink(at: destination, withDestinationURL: binary)
    }
}

extension CommandLineLink {
    /// 0.9.x linked ~/.local/bin/keys to the runtime the migration retires. Repoint only
    /// that exact, now-dangling link; a link to anything else is the person's own choice.
    @discardableResult
    static func repairRetired(link: URL, retired: URL, binary: URL) -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
              target == retired.path, !fm.fileExists(atPath: retired.path) else { return false }
        return (try? install(binary: binary, destination: link, replacingSymbolicLink: target)) != nil
    }
}

final class UpdateCheck: NSObject, URLSessionTaskDelegate, Sendable {
    static func latestRelease() async throws -> ReleaseInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: UpdateCheck(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/gshost1/Keysreallysafe/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.http("GitHub did not return a release.") }
        return try AppUpdater.parseRelease(data)
    }

    static func parseVersion(_ data: Data) throws -> String {
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        guard let version = AppUpdater.normalizedVersion(tag) else {
            throw AppError.http("GitHub returned an unsupported version string.")
        }
        return version
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        current.compare(candidate, options: .numeric) == .orderedAscending
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension UpdateCheck {
    /// The synchronous face of `latestRelease()` for callers on a plain thread —
    /// the `keys mcp` server serves its whole loop on one thread, so `check_update`
    /// needs the answer inline. The bridge only waits: the ephemeral session, its
    /// policies (no cookies, no cache, redirects refused, the 20 s bound) and every
    /// failure sentence stay in `latestRelease()`, so this can add no wording of
    /// its own. A read-only check — the installer is never on this path.
    static func latestReleaseSync() throws -> ReleaseInfo {
        final class Outcome: @unchecked Sendable {
            private let lock = NSLock()
            private var result: Result<ReleaseInfo, any Error>?
            func store(_ value: Result<ReleaseInfo, any Error>) {
                lock.lock(); result = value; lock.unlock()
            }
            func load() throws -> ReleaseInfo {
                lock.lock(); defer { lock.unlock() }
                guard let result else { throw AppError.http("GitHub did not return a release.") }
                return try result.get()
            }
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { outcome.store(.success(try await UpdateCheck.latestRelease())) }
            catch { outcome.store(.failure(error)) }
            done.signal()
        }
        done.wait()
        return try outcome.load()
    }
}

/// menubar.log, 0600: the app's own lines and its relay's, which arrive from the relay's
/// threads, so each line is written whole under a lock.
final class AppLogFile: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func write(_ message: String) {
        let data = Data((UTC.iso(Date()) + " " + message + "\n").utf8)
        lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

/// Serializes migration and listeners even when two binaries are invoked directly at once.
final class AppInstanceLock {
    private var descriptor: Int32

    init(root: URL) throws {
        descriptor = Darwin.open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppError.http("Could not open the Keysrs app lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw AppError.http("Another Keysrs app is starting or already running.")
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
}
