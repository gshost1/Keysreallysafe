import Darwin
import Foundation
import ServiceManagement

/// How the app's login item is registered, plus `.notQueried` for the cases doctor cannot
/// answer (not an app bundle, or the installed binary could not be asked).
enum LoginItemState: String, Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case notQueried

    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    /// The single word the hidden `login-item-status` subcommand prints. `.notQueried` never
    /// comes from a live status, but map it to a valid word so the command can't emit garbage.
    var statusWord: String {
        switch self {
        case .enabled: return "enabled"
        case .notRegistered: return "not-registered"
        case .requiresApproval: return "requires-approval"
        case .notFound, .notQueried: return "not-found"
        }
    }

    /// Parse the one word printed by the subprocess. Anything unexpected (empty, garbage, a
    /// usage error from an older installed binary) reads as `.notQueried`.
    init(word: String) {
        switch word {
        case "enabled": self = .enabled
        case "not-registered": self = .notRegistered
        case "requires-approval": self = .requiresApproval
        case "not-found": self = .notFound
        default: self = .notQueried
        }
    }
}

/// Everything `keys doctor` needs to describe how Keysrs is installed, gathered once so the
/// line formatter stays pure and testable. `live(...)` fills it from the real system; tests
/// construct it directly.
struct DoctorInstall: Equatable {
    var appBundle: URL? = nil
    var bundleBinarySHA256: String? = nil
    var runningExecutable: URL? = nil
    var runningBinarySHA256: String? = nil
    var commandOnPath: URL? = nil
    var commandTarget: String? = nil
    var commandSHA256: String? = nil
    var loginItem: LoginItemState = .notQueried
    var legacyPlist: URL = LoginItem.agentPlist
    var legacyPlistExists: Bool = false
    var legacyBinary: URL? = nil
    var legacyBinaryExists: Bool = false
    var legacyBinarySHA256: String? = nil
    var legacyAgentLoaded: Bool? = nil

    /// Runs `<binary> login-item-status` and returns its single output word, or nil on any
    /// failure (spawn error, non-zero exit, no output, or a child that outlived the timeout).
    typealias LoginRunner = (_ binary: URL) -> String?

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probeAgent: Bool,
        runningExecutable: URL? = Bundle.main.executableURL,
        loginRunner: LoginRunner = { probeLoginItem(binary: $0) }
    ) -> DoctorInstall {
        let fm = FileManager.default
        let command = keysOnPath(environment: environment)

        var bundle = AppResources.applicationBundle()?.bundleURL
        if bundle == nil, let command, let fromCommand = appBundle(forExecutable: command) {
            bundle = fromCommand
        }
        if bundle == nil {
            let installed = URL(fileURLWithPath: "/Applications/Keysrs.app")
            if fm.fileExists(atPath: installed.path) { bundle = installed }
        }

        let running = runningExecutable

        let loginItem: LoginItemState
        if Bundle.main.bundleURL.pathExtension == "app" {
            loginItem = LoginItemState(status: SMAppService.mainApp.status)
        } else if let bundle,
                  let running,
                  running.resolvingSymlinksInPath() == bundle.appendingPathComponent("Contents/MacOS/keys").resolvingSymlinksInPath() {
            // Only ask a bundle this very binary lives in. A dev build or a stray copy would be
            // running someone else's executable and reporting that build's answer as its own.
            let bundled = bundle.appendingPathComponent("Contents/MacOS/keys")
            loginItem = loginRunner(bundled).map(LoginItemState.init(word:)) ?? .notQueried
        } else {
            loginItem = .notQueried
        }

        let legacyPlist = LoginItem.agentPlist
        let legacyBinary = try? Installer.live.binary
        let legacyBinaryExists = legacyBinary.map { fm.fileExists(atPath: $0.path) } ?? false

        return DoctorInstall(
            appBundle: bundle,
            bundleBinarySHA256: bundle.flatMap { Doctor.fileSHA256($0.appendingPathComponent("Contents/MacOS/keys")) },
            runningExecutable: running,
            runningBinarySHA256: running.flatMap(Doctor.fileSHA256),
            commandOnPath: command,
            commandTarget: command.flatMap { try? fm.destinationOfSymbolicLink(atPath: $0.path) },
            commandSHA256: command.flatMap(Doctor.fileSHA256),
            loginItem: loginItem,
            legacyPlist: legacyPlist,
            legacyPlistExists: fm.fileExists(atPath: legacyPlist.path),
            legacyBinary: legacyBinary,
            legacyBinaryExists: legacyBinaryExists,
            legacyBinarySHA256: legacyBinaryExists ? legacyBinary.flatMap(Doctor.fileSHA256) : nil,
            legacyAgentLoaded: probeAgent ? legacyAgentLoaded() : nil
        )
    }

    /// First executable named `keys` across the injected PATH, searched in order.
    static func keysOnPath(environment: [String: String]) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        let fm = FileManager.default
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("keys")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The `.app` a `keys` executable lives in, resolving symlinks, or nil. Mirrors
    /// `AppResources.applicationBundle` for an executable we hold directly rather than a Bundle.
    static func appBundle(forExecutable executable: URL) -> URL? {
        let resolved = executable.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "keys",
              resolved.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
        let contents = resolved.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return app
    }

    /// The same `launchctl print` interpretation `LegacyAppMigration` uses: 0 = loaded,
    /// ESRCH/113 = absent, anything else (permission, session) = unknown.
    static func legacyAgentLoaded() -> Bool? {
        let target = "gui/\(getuid())/\(LoginItem.label)"
        guard let status = try? LoginItem.run("/bin/launchctl", ["print", target]).status else { return nil }
        if status == 0 { return true }
        if status == ESRCH || status == 113 { return false }
        return nil
    }

    static func probeLoginItem(binary: URL, timeout: TimeInterval = 3) -> String? {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["login-item-status"]
        let out = Pipe()
        proc.standardOutput = out
        // An older binary answers with usage text on stderr; an unread pipe could fill and
        // stall it until the timeout, so stderr goes nowhere.
        proc.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }
        // stdout is one word from a current binary and empty from an older one, so it is read
        // after exit; a child that floods it hits the timeout and reads as not queried.
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(decoding: data.prefix(256), as: UTF8.self)
        return text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }
}
