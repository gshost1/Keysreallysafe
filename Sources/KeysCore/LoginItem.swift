import Darwin
import Foundation

enum LoginItem {
    static let label = "com.keysreallysafe.menubar"
    static let menubarPort: UInt16 = 12766
    static let dashboardPort: UInt16 = 12765

    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var installedBinary: URL {
        Paths.appSupport.appendingPathComponent("bin/keys")
    }

    /// SHA-256 of the binary as it was *before* the install re-signed it. `keys doctor` compares
    /// this to the checkout's debug binary; the installed file itself never matches after codesign.
    static var installedSourceHash: URL {
        Paths.appSupport.appendingPathComponent("bin/keys.sha256")
    }

    static var installedWeb: URL {
        Paths.appSupport.appendingPathComponent("Web", isDirectory: true)
    }

    static var installedModelsJSON: URL {
        Paths.appSupport.appendingPathComponent("Fixtures/models.json")
    }

    static var installedProvidersJSON: URL {
        Paths.appSupport.appendingPathComponent("Fixtures/providers.json")
    }

    static var logFile: URL {
        Paths.appSupport.appendingPathComponent("menubar.log")
    }

    static var bookmarkURL: URL {
        URL(string: "http://127.0.0.1:\(menubarPort)/")!
    }

    static func plistXML(binary: URL, webRoot: URL, logFile: URL) -> String {
        let bin = xml(binary.path)
        let web = xml(webRoot.path)
        let log = xml(logFile.path)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(bin)</string>
            <string>menubar</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>KEYS_WEB_ROOT</key>
            <string>\(web)</string>
            <key>KEYS_MODELS_JSON</key>
            <string>\(xml(installedModelsJSON.path))</string>
            <key>KEYS_PROVIDERS_JSON</key>
            <string>\(xml(installedProvidersJSON.path))</string>
          </dict>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
            <key>Crashed</key>
            <true/>
          </dict>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
          <key>StandardOutPath</key>
          <string>\(log)</string>
          <key>StandardErrorPath</key>
          <string>\(log)</string>
        </dict>
        </plist>

        """
    }

    static func install(fromBinary binary: URL, webRoot: URL) throws {
        try Installer.live.install(fromBinary: binary, webRoot: webRoot)
    }

    static func uninstall() throws {
        try Installer.live.uninstall()
    }

    static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdout, stderr)
    }
}

/// Installs a version of the app under one root. The new version is staged and validated in
/// full before the running agent is stopped; if activation fails, the previous version is put
/// back and started again. `LoginItem.install` uses `.live`; tests give it a temp root and a
/// fake process runner.
struct Installer {
    typealias Runner = (_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String)

    var root: URL
    var agentPlist: URL
    var label: String
    var run: Runner

    static var live: Installer {
        Installer(root: Paths.appSupport, agentPlist: LoginItem.agentPlist, label: LoginItem.label, run: LoginItem.run)
    }

    // Live layout under `root`.
    var binary: URL { root.appendingPathComponent("bin/keys") }
    var sourceHash: URL { root.appendingPathComponent("bin/keys.sha256") }
    var web: URL { root.appendingPathComponent("Web", isDirectory: true) }
    var fixtures: URL { root.appendingPathComponent("Fixtures", isDirectory: true) }
    var logFile: URL { root.appendingPathComponent("menubar.log") }
    /// The version that was live before the last successful install. One back, kept on purpose.
    var previous: URL { root.appendingPathComponent(".previous", isDirectory: true) }

    private static let parts = ["bin", "Web", "Fixtures"]

    struct Failure: Error, CustomStringConvertible {
        var stage: String
        var underlying: Error
        var rolledBack: Bool
        var description: String {
            "install failed at \(stage): \(underlying)" + (rolledBack ? " (previous version restored)" : "")
        }
    }

    func install(fromBinary source: URL, webRoot: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Build and validate the whole version somewhere the running agent does not look.
        //    Nothing live has been touched yet, so a failure here needs no rollback.
        do {
            try stage(into: staging, binary: source, webRoot: webRoot)
        } catch {
            throw Failure(stage: "staging", underlying: error, rolledBack: false)
        }

        // 2. Swap. From here on every failure restores what was live.
        let hadPrevious = fm.fileExists(atPath: binary.path)
        let oldPlist = try? Data(contentsOf: agentPlist)
        let backup = root.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        var moved = false
        do {
            try bootout()
            try moveLive(to: backup)
            moved = true
            for part in Self.parts {
                let from = staging.appendingPathComponent(part)
                if fm.fileExists(atPath: from.path) {
                    try fm.moveItem(at: from, to: root.appendingPathComponent(part))
                }
            }
            let xml = LoginItem.plistXML(binary: binary, webRoot: web, logFile: logFile)
            try fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: agentPlist, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentPlist.path)
            try bootstrap()
        } catch {
            var restored = false
            if moved {
                restored = rollback(from: backup, hadPrevious: hadPrevious, oldPlist: oldPlist)
            }
            throw Failure(stage: "activation", underlying: error, rolledBack: restored)
        }

        // 3. Keep exactly one previous version.
        if hadPrevious {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: backup, to: previous)
        } else {
            try? fm.removeItem(at: backup)
        }
    }

    func uninstall() throws {
        try bootout()
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlist.path) {
            try fm.removeItem(at: agentPlist)
        }
        var doomed = Self.parts.map { root.appendingPathComponent($0) } + [logFile, previous]
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            doomed += entries.filter { $0.lastPathComponent.hasPrefix(".staging-") || $0.lastPathComponent.hasPrefix(".previous-") }
        }
        for url in doomed where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: stages

    private func stage(into staging: URL, binary source: URL, webRoot: URL) throws {
        let fm = FileManager.default
        let bin = staging.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stagedBinary = bin.appendingPathComponent("keys")
        try fm.copyItem(at: source, to: stagedBinary)
        try fm.copyItem(at: webRoot, to: staging.appendingPathComponent("Web", isDirectory: true))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.appendingPathComponent("Web").path)
        try stageFixtures(into: staging.appendingPathComponent("Fixtures", isDirectory: true), webRoot: webRoot)
        if let hash = Doctor.fileSHA256(source) {
            try Data((hash + "\n").utf8).write(to: bin.appendingPathComponent("keys.sha256"), options: .atomic)
        }
        try codesign(stagedBinary)
        try verifySignature(stagedBinary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedBinary.path)
        guard fm.isExecutableFile(atPath: stagedBinary.path) else {
            throw AppError.http("staged binary is not executable")
        }
    }

    private func stageFixtures(into dir: URL, webRoot: URL) throws {
        let fm = FileManager.default
        let fixturesRoot = webRoot.deletingLastPathComponent().appendingPathComponent("Fixtures")
        var sources: [(String, URL)] = []
        let models = fixturesRoot.appendingPathComponent("models.json")
        if fm.isReadableFile(atPath: models.path) { sources.append(("models.json", models)) }
        let fromWeb = webRoot.appendingPathComponent("providers.json")
        let fromFixtures = fixturesRoot.appendingPathComponent("providers.json")
        if fm.isReadableFile(atPath: fromWeb.path) {
            sources.append(("providers.json", fromWeb))
        } else if fm.isReadableFile(atPath: fromFixtures.path) {
            sources.append(("providers.json", fromFixtures))
        }
        guard !sources.isEmpty else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, src) in sources {
            try fm.copyItem(at: src, to: dir.appendingPathComponent(name))
        }
    }

    /// Moves every live part into `backup`, preserving which parts existed.
    private func moveLive(to backup: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for part in Self.parts {
            let live = root.appendingPathComponent(part)
            if fm.fileExists(atPath: live.path) {
                try fm.moveItem(at: live, to: backup.appendingPathComponent(part))
            }
        }
    }

    /// Best effort, never throws: put the old parts back, restore the old plist, start the old agent.
    private func rollback(from backup: URL, hadPrevious: Bool, oldPlist: Data?) -> Bool {
        let fm = FileManager.default
        var ok = true
        for part in Self.parts {
            let live = root.appendingPathComponent(part)
            try? fm.removeItem(at: live)
            let saved = backup.appendingPathComponent(part)
            if fm.fileExists(atPath: saved.path) {
                do { try fm.moveItem(at: saved, to: live) } catch { ok = false }
            }
        }
        if let oldPlist {
            do {
                try oldPlist.write(to: agentPlist, options: .atomic)
            } catch { ok = false }
        } else {
            try? fm.removeItem(at: agentPlist)
        }
        try? fm.removeItem(at: backup)
        if hadPrevious, oldPlist != nil {
            do { try bootstrap() } catch { ok = false }
        }
        return ok
    }

    // MARK: processes

    private func codesign(_ binary: URL) throws {
        let result = try run("/usr/bin/codesign", ["-s", "-", "--force", "--identifier", "keysreallysafe", binary.path])
        if result.status != 0 {
            throw AppError.http("codesign failed: \(result.stderr)")
        }
    }

    private func verifySignature(_ binary: URL) throws {
        let result = try run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        if result.status != 0 {
            throw AppError.http("codesign verify failed: \(result.stderr)")
        }
    }

    private func bootout() throws {
        _ = try run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    private func bootstrap() throws {
        let result = try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist.path])
        if result.status != 0 {
            throw AppError.http("launchctl bootstrap failed: \(result.stderr)")
        }
    }
}
