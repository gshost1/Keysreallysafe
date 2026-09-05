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
        let fm = FileManager.default
        try fm.createDirectory(
            at: Paths.appSupport.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try bootout()
        try replaceItem(at: installedBinary, with: binary)
        try copyWeb(from: webRoot, to: installedWeb)
        try copyModelsJSON(from: webRoot)
        try copyProvidersJSON(from: webRoot)
        try codesign(installedBinary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedBinary.path)
        if let sourceHash = Doctor.fileSHA256(binary) {
            try Data((sourceHash + "\n").utf8).write(to: installedSourceHash, options: .atomic)
        }
        let xml = plistXML(binary: installedBinary, webRoot: installedWeb, logFile: logFile)
        let agents = agentPlist.deletingLastPathComponent()
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: agentPlist, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentPlist.path)
        try bootstrap()
    }

    static func uninstall() throws {
        try bootout()
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlist.path) {
            try fm.removeItem(at: agentPlist)
        }
        for url in [installedBinary, installedWeb, installedModelsJSON, installedProvidersJSON, logFile] {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }

    static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replaceItem(at dest: URL, with src: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: src, to: dest)
    }

    private static func copyWeb(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: src, to: dest)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)
    }

    private static func copyModelsJSON(from webRoot: URL) throws {
        let fm = FileManager.default
        let src = webRoot.deletingLastPathComponent().appendingPathComponent("Fixtures/models.json")
        guard fm.isReadableFile(atPath: src.path) else { return }
        let destDir = installedModelsJSON.deletingLastPathComponent()
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedModelsJSON.path) {
            try fm.removeItem(at: installedModelsJSON)
        }
        try fm.copyItem(at: src, to: installedModelsJSON)
    }

    private static func copyProvidersJSON(from webRoot: URL) throws {
        let fm = FileManager.default
        let fromWeb = webRoot.appendingPathComponent("providers.json")
        let fromFixtures = webRoot.deletingLastPathComponent().appendingPathComponent("Fixtures/providers.json")
        let src: URL
        if fm.isReadableFile(atPath: fromWeb.path) {
            src = fromWeb
        } else if fm.isReadableFile(atPath: fromFixtures.path) {
            src = fromFixtures
        } else {
            return
        }
        let destDir = installedProvidersJSON.deletingLastPathComponent()
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedProvidersJSON.path) {
            try fm.removeItem(at: installedProvidersJSON)
        }
        try fm.copyItem(at: src, to: installedProvidersJSON)
    }

    private static func codesign(_ binary: URL) throws {
        let result = try run("/usr/bin/codesign", [
            "-s", "-",
            "--force",
            "--identifier", "keysreallysafe",
            binary.path,
        ])
        if result.status != 0 {
            throw AppError.http("codesign failed: \(result.stderr)")
        }
    }

    private static func bootout() throws {
        let uid = getuid()
        _ = try run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    }

    private static func bootstrap() throws {
        let uid = getuid()
        let result = try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentPlist.path])
        if result.status != 0 {
            throw AppError.http("launchctl bootstrap failed: \(result.stderr)")
        }
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
