import AppKit
import CryptoKit
import Darwin
import Foundation

/// What the latest GitHub release says, reduced to what installing needs. The DMG name is
/// pinned because the site's download links and the updater both address the asset by name.
struct ReleaseInfo: Equatable, Sendable {
    enum Checksum: Equatable, Sendable {
        /// GitHub's own `sha256:<hex>` digest on the asset record.
        case digest(String)
        /// A `Keysrs-arm64.dmg.sha256` sidecar asset; its bytes are downloaded and parsed.
        case sidecar(URL)
    }

    var version: String
    var dmg: URL
    var checksum: Checksum?
    var expectedBytes: Int?
    var notes: URL?
}

enum AppUpdater {
    static let dmgName = "Keysrs-arm64.dmg"
    static let sidecarName = dmgName + ".sha256"
    /// The swap happens as renames beside the running app, so both names must sit on one volume
    /// and must never collide with anything a person would name themselves.
    static let incomingName = ".Keysrs.app.incoming"
    static let previousName = ".Keysrs.app.previous"

    struct InstallPlan: Equatable {
        var app: URL
        var incoming: URL
        var previous: URL
    }

    static func installPlan(app: URL) -> InstallPlan {
        let parent = app.deletingLastPathComponent()
        return InstallPlan(app: app,
                          incoming: parent.appendingPathComponent(incomingName),
                          previous: parent.appendingPathComponent(previousName))
    }

    /// The release tag rules are shared with UpdateCheck.parseVersion.
    static func normalizedVersion(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: "^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}$", options: .regularExpression) != nil else { return nil }
        return version
    }

    /// Checksums are compared in lowercase hex; anything that is not 64 hex characters is refused.
    static func normalizedChecksum(_ hex: String) -> String? {
        let value = hex.lowercased()
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func normalizedDigest(_ digest: String) -> String? {
        guard digest.lowercased().hasPrefix("sha256:") else { return nil }
        return normalizedChecksum(String(digest.dropFirst("sha256:".count)))
    }

    /// Accepts "sha256:<hex>" from the API, or a checksum file line: "<hex>  Keysrs-arm64.dmg",
    /// the BSD "SHA256 (Keysrs-arm64.dmg) = <hex>" layout, or a bare hash.
    static func parseChecksumSidecar(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { continue }
            if let direct = normalizedChecksum(first) { return direct }
            if words.count == 4, first.lowercased() == "sha256", words[2] == "=" {
                return normalizedChecksum(words[3])
            }
        }
        return nil
    }

    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String?; let size: Int? }
        struct Release: Decodable { let tag_name: String; let html_url: String?; let assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let version = normalizedVersion(release.tag_name) else {
            throw AppError.http("GitHub returned an unsupported version string.")
        }
        guard let asset = release.assets.first(where: { $0.name == dmgName }),
              let dmg = URL(string: asset.browser_download_url), dmg.scheme == "https" else {
            throw AppError.http("The latest release has no \(dmgName) download.")
        }
        let notes = release.html_url.flatMap { URL(string: $0) }
        if let digest = asset.digest.flatMap(normalizedDigest) {
            return ReleaseInfo(version: version, dmg: dmg, checksum: .digest(digest), expectedBytes: asset.size, notes: notes)
        }
        if let sidecar = release.assets.first(where: { $0.name == sidecarName }),
           let url = URL(string: sidecar.browser_download_url), url.scheme == "https" {
            return ReleaseInfo(version: version, dmg: dmg, checksum: .sidecar(url), expectedBytes: asset.size, notes: notes)
        }
        return ReleaseInfo(version: version, dmg: dmg, checksum: nil, expectedBytes: asset.size, notes: notes)
    }

    /// Streams the file so a large disk image never sits in memory twice.
    static func hexSha256(fileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AppError.http("The downloaded update could not be read.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Hex.encode(hasher.finalize())
    }

    /// Refuses a bundle whose Info.plist is not exactly the release and does not beat the
    /// installed version; a mismatch means the disk image is not what GitHub described.
    static func candidateVersion(infoDictionary: [String: Any], release: String, current: String) throws -> String {
        guard let value = infoDictionary["CFBundleShortVersionString"] as? String else {
            throw AppError.http("The update does not state its version; it was not installed.")
        }
        guard value == release else {
            throw AppError.http("The update says version \(value), the release says \(release); it was not installed.")
        }
        guard UpdateCheck.isNewer(value, than: current) else {
            throw AppError.http("Version \(value) is not newer than the installed \(current); it was not installed.")
        }
        return value
    }

    /// `hdiutil attach -plist` prints a dictionary whose `system-entities` lists each partition;
    /// only the mounted one carries a `mount-point`. A bare array is accepted as well.
    static func mountPoint(fromPlist data: Data) -> String? {
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let entries: [[String: Any]]
        if let dictionary = parsed as? [String: Any] { entries = [dictionary] }
        else if let array = parsed as? [[String: Any]] { entries = array }
        else { return nil }
        for entry in entries {
            if let point = entry["mount-point"] as? String, !point.isEmpty { return point }
            for entity in entry["system-entities"] as? [[String: Any]] ?? [] {
                if let point = entity["mount-point"] as? String, !point.isEmpty { return point }
            }
        }
        return nil
    }

    /// The old bundle is renamed aside, so a helper process removes it after this process exits
    /// and then reopens the app. Paths travel as arguments, never inside the script: splicing a
    /// path into a shell string is how a folder name becomes code.
    static func relauncher(pid: Int32, old: URL, new: URL) -> [String] {
        let script = """
        i=0
        while [ "$i" -lt 150 ] && kill -0 "$1" 2>/dev/null; do sleep 0.2; i=$((i+1)); done
        rm -rf "$2" || true
        /usr/bin/open "$3" || true
        """
        return ["/bin/sh", "-c", script, "keysrs-update", String(pid), old.path, new.path]
    }

    /// The helper must outlive this process, so it starts in its own session; a shell quitting
    /// alongside the app would kill the restart before it happens.
    static func spawnRelauncher(_ argv: [String]) throws {
        var pid: pid_t = 0
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attributes) }
        var arguments = argv.map { strdup($0) }
        arguments.append(nil)
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        // `environ` is already the NULL-terminated C array posix_spawn wants.
        let status = arguments.withUnsafeMutableBufferPointer { args in
            posix_spawn(&pid, argv[0], nil, &attributes, args.baseAddress!, environ)
        }
        guard status == 0 else {
            throw AppError.http("The restart helper could not start (errno \(status)); the update is installed but Keysrs did not restart. Open Keysrs from the Applications folder.")
        }
    }

    /// Removes a half-finished updater install beside the app: a helper that died or a full
    /// disk can leave one behind. The names are the updater's alone and the running bundle is
    /// never touched.
    static func sweepStaleInstall(around app: URL, fileManager: FileManager = .default) {
        let plan = installPlan(app: app)
        for url in [plan.incoming, plan.previous] where url.path != app.path {
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Downloads the release's disk image (and, when needed, its checksum sidecar) with GitHub-only
/// redirects. URLSession's delegate methods run on the session's queue, so shared state sits
/// behind a lock; progress is forwarded to the main actor so callers can touch UI freely.
final class ReleaseAssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@MainActor @Sendable (Double, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var moved = false
    private var error: Error?
    private var lastReported = -1.0

    /// NSLock cannot be released from an async context, so every touch goes through this
    /// synchronous helper, including the ones the async `download` method makes.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func download(from url: URL, to destination: URL,
                  progress: (@MainActor @Sendable (Double, Int64) -> Void)? = nil) async throws {
        withLock {
            self.destination = destination
            self.progress = progress
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { pending in
            withLock { continuation = pending }
            let started = session.downloadTask(with: url)
            withLock { task = started }
            started.resume()
        }
        if let error = withLock({ error }) { throw error }
    }

    func cancel() {
        let pending = withLock { task }
        pending?.cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = withLock {
            let saved = continuation
            continuation = nil
            if case .failure(let failure) = result { error = failure }
            return saved
        }
        if let pending { pending.resume(with: result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // GitHub signs the asset's real location; a redirect anywhere else is not GitHub's download.
        guard let host = request.url?.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Throttle to one report per percent so the main actor is not flooded with tiny Tasks.
        let sink = withLock { () -> (@MainActor @Sendable (Double, Int64) -> Void)? in
            guard fraction - lastReported >= 0.01 || fraction == 1 else { return nil }
            lastReported = fraction
            return progress
        }
        if let sink { Task { @MainActor in sink(fraction, totalBytesExpectedToWrite) } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = withLock { destination }
        guard let target else { finish(.failure(AppError.http("The download finished before it was asked for."))); return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            withLock { moved = true }
        } catch { finish(.failure(AppError.http("The download could not be saved: \(error.localizedDescription)"))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            guard withLock({ moved }) else { finish(.failure(AppError.http("The download did not finish."))); return }
            finish(.success(()))
            return
        }
        // The user cancelling the download is not an error dialog.
        if (error as? URLError)?.code == .cancelled || error is CancellationError {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(AppError.http("The download did not finish: \(error.localizedDescription)")))
        }
    }
}

/// The install itself runs on the main actor with the UI. `@unchecked Sendable` is safe here by
/// construction: every property is read and written from the main actor, and the only cross-thread
/// handoff is the downloader's `@MainActor @Sendable` progress closure.
@MainActor
final class UpdateInstaller: @unchecked Sendable {
    enum Phase: Equatable {
        case downloading(written: Int64, expected: Int64)
        case verifying
        case checking
        case installing
        case restarting
    }

    let release: ReleaseInfo
    let app: URL
    var report: ((Phase) -> Void)?
    /// How to quit the app once the swap is done; AppWindow passes the menu's own quit path.
    var quit: (() -> Void)?
    private var download: ReleaseAssetDownload?
    private var cancelled = false

    init(release: ReleaseInfo, app: URL) {
        self.release = release
        self.app = app
    }

    func cancel() {
        cancelled = true
        download?.cancel()
    }

    func run() async throws {
        guard !app.path.hasPrefix("/Volumes/") else {
            throw AppError.http("Keysrs is running from a disk image. Drag it to the Applications folder, open it, and update again.")
        }
        let plan = AppUpdater.installPlan(app: app)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("keysrs-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // The checksum is known before anything large is fetched, so a release that publishes
        // none is refused before the download rather than after.
        let expected = try await checksum(in: work)
        let dmgFile = work.appendingPathComponent(AppUpdater.dmgName)
        let downloader = ReleaseAssetDownload()
        download = downloader
        defer { download = nil }
        try await downloader.download(from: release.dmg, to: dmgFile) { [weak self] fraction, expected in
            guard let self else { return }
            let written = Int64((Double(expected) * fraction).rounded())
            self.report?(.downloading(written: written, expected: expected))
        }
        if cancelled { throw CancellationError() }
        report?(.verifying)
        let actual = try AppUpdater.hexSha256(fileAt: dmgFile)
        guard actual == expected else {
            throw AppError.http("The download's checksum does not match the release. Nothing was installed; try again.")
        }
        if let size = release.expectedBytes,
           (try? fm.attributesOfItem(atPath: dmgFile.path)[.size] as? Int) != size {
            throw AppError.http("The download's size differs from the release. Nothing was installed; try again.")
        }

        report?(.checking)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attached = try LoginItem.run("/usr/bin/hdiutil", ["attach", dmgFile.path, "-nobrowse", "-readonly", "-plist", "-mountpoint", mount.path])
        guard attached.status == 0, let mountPath = AppUpdater.mountPoint(fromPlist: Data(attached.stdout.utf8)) else {
            _ = try? LoginItem.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw AppError.http("The download could not be opened as a disk image.")
        }
        defer { _ = try? LoginItem.run("/usr/bin/hdiutil", ["detach", mountPath]) }
        let candidate = URL(fileURLWithPath: mountPath).appendingPathComponent("Keysrs.app")
        guard fm.fileExists(atPath: candidate.path) else {
            throw AppError.http("The disk image does not contain Keysrs.app. Nothing was installed.")
        }
        let infoPlist = candidate.appendingPathComponent("Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoPlist),
              let dictionary = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw AppError.http("The update's Info.plist could not be read. Nothing was installed.")
        }
        _ = try AppUpdater.candidateVersion(infoDictionary: dictionary, release: release.version, current: ProductAnalyticsConfiguration.appVersion)

        report?(.installing)
        try? fm.removeItem(at: plan.incoming)
        do { try fm.copyItem(at: candidate, to: plan.incoming) }
        catch { throw AppError.http("The new version could not be staged beside Keysrs (\(error.localizedDescription)). Nothing was installed.") }
        // The signature gate comes after staging and before the swap: a different team or
        // requirement would silently cut the app off from every Keychain item it owns.
        try StableSigning.validate(plan.incoming, replacing: plan.app)
        do { try fm.moveItem(at: plan.app, to: plan.previous) }
        catch {
            try? fm.removeItem(at: plan.incoming)
            throw AppError.http("The running Keysrs could not be set aside; the previous version was kept (\(error.localizedDescription)).")
        }
        do { try fm.moveItem(at: plan.incoming, to: plan.app) }
        catch {
            try? fm.moveItem(at: plan.previous, to: plan.app)
            throw AppError.http("The new version could not be moved into place; the previous version was restored.")
        }

        report?(.restarting)
        // The quit below exits without unwinding these defers, so the disk image is detached
        // and the download removed here; on every failure path the defers are the cleanup.
        try? LoginItem.run("/usr/bin/hdiutil", ["detach", mountPath])
        try? fm.removeItem(at: work)
        try AppUpdater.spawnRelauncher(AppUpdater.relauncher(pid: getpid(), old: plan.previous, new: plan.app))
        quit?()
    }

    /// The API's own digest is preferred; a sidecar asset means one more small download.
    private func checksum(in work: URL) async throws -> String {
        switch release.checksum {
        case .digest(let hex):
            return hex
        case .sidecar(let url):
            let sidecar = work.appendingPathComponent(AppUpdater.sidecarName)
            let downloader = ReleaseAssetDownload()
            download = downloader
            defer { download = nil }
            try await downloader.download(from: url, to: sidecar) { _, _ in }
            guard let text = try? String(contentsOf: sidecar, encoding: .utf8),
                  let hex = AppUpdater.parseChecksumSidecar(text) else {
                throw AppError.http("The release's checksum file could not be read. Nothing was downloaded or installed.")
            }
            return hex
        case nil:
            throw AppError.http("The release does not publish a checksum, so Keysrs cannot verify the download. Nothing was downloaded or installed.")
        }
    }
}

/// A small, plain progress window in the app's own style: one status line, one bar, one
/// Cancel button that locks once the swap is underway.
@MainActor
final class UpdateProgressWindow {
    private let window: NSWindow
    private let status: NSTextField
    private let bar: NSProgressIndicator
    private let cancelButton: NSButton
    private let onCancel: () -> Void
    private static let bytes = ByteCountFormatter()

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 148),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating Keysrs"
        window.isReleasedWhenClosed = false
        window.center()
        let heading = NSTextField(labelWithString: "Keysrs")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        status = NSTextField(labelWithString: "Starting…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .regular
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        let stack = NSStackView(views: [heading, status, bar, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.setHuggingPriority(.required, for: .horizontal)
        window.contentView = stack
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ phase: UpdateInstaller.Phase) {
        switch phase {
        case .downloading(let written, let expected):
            status.stringValue = "Downloading… \(Self.bytes.string(fromByteCount: written)) of \(Self.bytes.string(fromByteCount: expected))"
            bar.doubleValue = expected > 0 ? Double(written) / Double(expected) : 0
        case .verifying:
            status.stringValue = "Verifying the checksum…"
            bar.doubleValue = 1
        case .checking:
            status.stringValue = "Checking the update's signature…"
        case .installing:
            status.stringValue = "Replacing Keysrs…"
            cancelButton.isEnabled = false
        case .restarting:
            status.stringValue = "Restarting…"
            cancelButton.isHidden = true
        }
    }

    func close() {
        window.orderOut(nil)
    }

    @objc private func cancelTapped() {
        onCancel()
        close()
    }
}
