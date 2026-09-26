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
        let logURL = root.appendingPathComponent("menubar.log")
        func log(_ message: String) {
            let data = Data((UTC.iso(Date()) + " " + message + "\n").utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
        _ = try WebRoot.find()
        let service = try AppFactory.makeService()
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
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let extra = MenubarExtra(service: service, server: server, url: url)
            extra.appWindow = AppWindowController(url: url, preferences: service.preferences)
            extra.appWindow?.installMenu(extra: extra)
            MenubarRuntime.extra = extra
            app.delegate = extra
            IngestScheduler.scheduleRepeating(service: service)
            OpenRouterScheduler.schedule(service: service)
            DispatchQueue.global(qos: .utility).async {
                _ = try? service.ingest(.all)
                try? service.pollOpenRouter()
            }
            app.run()
        }
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
    static func latestVersion() async throws -> String {
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
        return try parseVersion(data)
    }

    static func parseVersion(_ data: Data) throws -> String {
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: "^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}$", options: .regularExpression) != nil else {
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
