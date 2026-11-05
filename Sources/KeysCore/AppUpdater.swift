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

    /// `hdiutil` attach, the plist parse and the `Keysrs.app` check, as one blocking
    /// call: the installer runs it off the main actor so a Cancel can be handled while
    /// the disk image is mounting.
    static func attachDiskImage(_ dmg: URL, mount: URL) throws -> String {
        let attached = try LoginItem.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist", "-mountpoint", mount.path])
        guard attached.status == 0, let mountPath = mountPoint(fromPlist: Data(attached.stdout.utf8)) else {
            throw AppError.http("The download could not be opened as a disk image.")
        }
        return mountPath
    }

    static func detachDiskImage(_ mountPath: String, force: Bool = false) {
        var arguments = ["detach", mountPath]
        if force { arguments.append("-force") }
        _ = try? LoginItem.run("/usr/bin/hdiutil", arguments)
    }

    /// The Info.plist gate, blocking, for the installer's background hop.
    static func readCandidateVersion(at candidate: URL, release: String, current: String) throws {
        let infoPlist = candidate.appendingPathComponent("Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoPlist),
              let dictionary = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw AppError.http("The update's Info.plist could not be read. Nothing was installed.")
        }
        _ = try candidateVersion(infoDictionary: dictionary, release: release, current: current)
    }

    /// Staging the mounted bundle beside the running one, blocking.
    static func stageCandidate(_ candidate: URL, _ incoming: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: incoming)
        try fm.copyItem(at: candidate, to: incoming)
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

/// Who asked for the update: the person's Update Now, or the scheduled check.
enum UpdateOrigin: Equatable, Sendable {
    case manual
    case background
}

/// One ownership token for the machine. Every continuation and every end of a
/// run carries the token it was handed, so work that was refused — or a
/// download callback that fires after its run ended — cannot write over the
/// claim that is live now. Without it a late progress write after `finish()`
/// put the machine back to `.downloading` and every later check was refused
/// until the app was relaunched.
struct UpdateClaim: Equatable, Sendable {
    let id: UInt64
    let origin: UpdateOrigin
}

/// The one update state machine, shared by the manual flow and the scheduled
/// one. They used to keep separate flags (`updating` on the controller,
/// `installing` on the background updater), so both could be true at once and
/// two installers staged beside the same `.Keysrs.app.incoming` /
/// `.Keysrs.app.previous` names. Both paths now claim this coordinator before
/// they touch anything, so a second start is refused, and every step boundary
/// of the install asks it again: a cancel, or automatic updates being turned
/// off during the download, stops the run while nothing has moved. Once the
/// swap has begun the phase says so, and the cancel is refused: the bundle is
/// moving and there is no step left to stop at.
@MainActor
final class UpdateCoordinator {
    enum Phase: Equatable, Sendable {
        case idle
        /// A release lookup is in flight.
        case checking(UpdateOrigin)
        /// The scheduled path's claim is held while it waits for the Mac to be
        /// idle. Nothing is downloading yet, so the phase says that instead of
        /// reporting zero bytes as if a download had started.
        case waiting(UpdateOrigin)
        case downloading(UpdateOrigin, written: Int64, expected: Int64)
        /// Checksum, Info.plist, signature and staging: everything verified and
        /// nothing moved yet.
        case verifying(UpdateOrigin)
        /// The running bundle is being renamed aside and replaced.
        case swapping(UpdateOrigin)
        /// The new bundle is in place; the restart helper and the quit follow.
        case relaunching(UpdateOrigin)
        /// The new bundle is in place and the restart did not happen. Terminal
        /// for this process: the claim is never released, because a second
        /// claim would try to set the already-replaced bundle aside again.
        case installedPendingRelaunch(UpdateOrigin)

        var origin: UpdateOrigin? {
            switch self {
            case .idle: return nil
            case .checking(let origin), .waiting(let origin), .downloading(let origin, _, _),
                 .verifying(let origin), .swapping(let origin), .relaunching(let origin),
                 .installedPendingRelaunch(let origin):
                return origin
            }
        }

        /// Cancel is live only before the running bundle starts moving. The
        /// progress window disables the button on exactly this.
        var allowsCancel: Bool {
            switch self {
            case .idle, .swapping, .relaunching, .installedPendingRelaunch: return false
            case .checking, .waiting, .downloading, .verifying: return true
            }
        }

        /// Whether an install (not a lookup) of this origin is underway.
        func isInstalling(_ origin: UpdateOrigin) -> Bool {
            switch self {
            case .waiting(let running), .downloading(let running, _, _), .verifying(let running),
                 .swapping(let running), .relaunching(let running),
                 .installedPendingRelaunch(let running):
                return running == origin
            case .idle, .checking:
                return false
            }
        }

        /// Where the phase sits in one run. Every write is checked against it,
        /// so a late progress report can never move the machine backwards —
        /// from `.verifying` back to `.downloading`, say, which would re-enable
        /// Cancel over work that is already done.
        var rank: Int {
            switch self {
            case .idle: return 0
            case .checking: return 1
            case .waiting: return 2
            case .downloading: return 3
            case .verifying: return 4
            case .swapping: return 5
            case .relaunching: return 6
            case .installedPendingRelaunch: return 7
            }
        }
    }

    /// What the caller that loses the claim is told: the manual path shows it,
    /// the scheduled path logs it, and neither starts a second install.
    nonisolated static let busyMessage = "update already in progress"

    /// The rank of `.swapping`: the first phase in which the running bundle has
    /// begun to move and the claim can no longer be released.
    nonisolated static let movedBundleRank = Phase.swapping(.manual).rank

    private(set) var phase: Phase = .idle
    /// The live claim; nil when nothing is running. The phase is this claim's
    /// rendering, and every write is checked against it.
    private(set) var claim: UpdateClaim?
    /// Set by the person's Cancel; read at every boundary until the swap.
    private(set) var cancelRequested = false
    /// The scheduled path's own setting, re-read at every boundary: someone who
    /// turns automatic updates off mid-download means it. Defaults to refusing,
    /// so a machine assembled without the setting never installs unwatched.
    var backgroundAllowed: () -> Bool = { false }
    /// The download a cancel must also stop, with the claim of the run that set
    /// it: a run that was taken over clears only its own hook, never the one
    /// the run that replaced it installed. A cancel that arrives between
    /// downloads still sets the flag the boundaries read.
    private var cancelDownload: (claim: UpdateClaim, stop: () -> Void)?
    /// How to finish an update whose bundle is already in place but whose
    /// restart did not happen: start the held restart helper and quit. Set
    /// only in `.installedPendingRelaunch`, so a later Check for Updates offers
    /// the restart instead of reporting a busy machine forever.
    private var pendingRestart: (@MainActor () throws -> Void)?
    /// Where the phase is rendered; the progress window is the only listener.
    var onChange: ((Phase) -> Void)?
    private var nextClaimID: UInt64 = 0

    var origin: UpdateOrigin? { claim?.origin }
    var isIdle: Bool { claim == nil }

    /// The claim a run of this origin holds, if any. An installer built by a
    /// caller that already claimed reads its token here.
    func currentClaim(for origin: UpdateOrigin) -> UpdateClaim? {
        guard let claim, claim.origin == origin else { return nil }
        return claim
    }

    /// Claims the machine for a release lookup. A lookup never blocks the
    /// person's click: their Check for Updates takes over a scheduled lookup or
    /// the scheduled path's quiet wait, and that run abandons at its next
    /// boundary. The timer never interrupts the person, so a scheduled check is
    /// still refused while any lookup or install claim is held. An install
    /// claim blocks a lookup outright: a second lookup could start a second
    /// installer beside the same staging names.
    func beginCheck(_ origin: UpdateOrigin) -> UpdateClaim? {
        switch phase {
        case .idle:
            return start(origin, phase: .checking(origin))
        case .checking(let running), .waiting(let running):
            guard origin == .manual, running == .background else { return nil }
            return start(origin, phase: .checking(origin))
        case .downloading, .verifying, .swapping, .relaunching, .installedPendingRelaunch:
            return nil
        }
    }
    /// Claims the machine for an install. A lookup of the SAME origin hands
    /// over, so the scheduled check and the install it starts are one non-idle
    /// stretch; anything else is refused — including a claim past the swap,
    /// where the bundle in place is the new one and a second install must never
    /// stage beside it. That case is retried by the run that swapped, which
    /// still holds the restart helper.
    func beginInstall(_ origin: UpdateOrigin, waiting: Bool = false) -> UpdateClaim? {
        let next: Phase = waiting ? .waiting(origin) : .downloading(origin, written: 0, expected: 0)
        switch phase {
        case .idle:
            return start(origin, phase: next)
        case .checking(let running) where running == origin:
            guard let claim else { return nil }
            set(next)
            return claim
        default:
            return nil
        }
    }

    /// Whether an install of `origin` holds the machine.
    func isInstalling(_ origin: UpdateOrigin) -> Bool {
        phase.isInstalling(origin)
    }

    /// Whether this claim is the one the machine is on. A run whose token is no
    /// longer current was taken over; it must not touch anything.
    func isCurrent(_ claim: UpdateClaim) -> Bool {
        self.claim == claim
    }

    /// A lookup that found nothing, failed, or handed over: only the claim that
    /// made the call is released, and only while it is still the lookup.
    func finishCheck(_ claim: UpdateClaim) {
        guard isCurrent(claim), case .checking = phase else { return }
        finish(claim)
    }

    /// Back to idle, for the run that owns the claim. A run that was refused
    /// has no claim to pass here at all, and one whose token a newer run
    /// replaced is ignored: the loser's `defer` used to wipe the winner's
    /// claim. A claim past the swap is never released in this process.
    func finish(_ claim: UpdateClaim) {
        guard isCurrent(claim), self.phase.rank < UpdateCoordinator.movedBundleRank else { return }
        cancelRequested = false
        cancelDownload = nil
        self.claim = nil
        set(.idle)
    }

    /// The swap failed and the running bundle is back where it was (or never
    /// left): the claim may be released again. Without this a failed first
    /// move left the machine in `.swapping` and refused every later check
    /// until the app was relaunched.
    func swapRolledBack(_ claim: UpdateClaim) {
        guard isCurrent(claim), case .swapping = phase else { return }
        set(.verifying(claim.origin))
    }

    /// The bundle is replaced and the restart did not happen. The claim stays
    /// held, and `restart` is what a later Check for Updates runs.
    func installedPendingRelaunch(_ claim: UpdateClaim, restart: @escaping @MainActor () throws -> Void) {
        guard isCurrent(claim), phase.rank >= UpdateCoordinator.movedBundleRank else { return }
        pendingRestart = restart
        set(.installedPendingRelaunch(claim.origin))
    }

    /// Retries the restart of an update already in place. False when there is
    /// none to retry.
    func restartPending() throws -> Bool {
        guard case .installedPendingRelaunch = phase, let pendingRestart else { return false }
        try pendingRestart()
        return true
    }

    /// The installer's download stop, owned by its claim.
    func setCancelDownload(_ claim: UpdateClaim, _ stop: @escaping () -> Void) {
        guard isCurrent(claim) else { return }
        cancelDownload = (claim, stop)
    }

    func clearCancelDownload(_ claim: UpdateClaim) {
        if cancelDownload?.claim == claim { cancelDownload = nil }
    }

    /// The person's Cancel. Refused once the swap has begun, so the flag can
    /// never stop a run that already moved the bundle.
    func cancel() {
        guard phase.allowsCancel else { return }
        cancelRequested = true
        cancelDownload?.stop()
    }

    /// Publishes a step. Only the claim that owns the machine may write, and
    /// only forwards.
    func step(_ phase: Phase, for claim: UpdateClaim) {
        guard isCurrent(claim), phase.rank >= self.phase.rank else { return }
        set(phase)
    }

    /// Why the claimed run may not continue, or nil when it may: the one place
    /// the reason is decided, so a caller never guesses it.
    func stopReason(_ claim: UpdateClaim) -> UpdateStopped.Why? {
        guard isCurrent(claim) else { return .superseded }
        if cancelRequested { return .cancelled }
        if claim.origin == .background, !backgroundAllowed() { return .disabled }
        return nil
    }

    /// The boundary the installer reads at every step before the swap. It
    /// throws while nothing has moved, so stopping costs nothing.
    func checkContinue(_ claim: UpdateClaim) throws {
        if let why = stopReason(claim) { throw UpdateStopped(why: why) }
    }

    private func start(_ origin: UpdateOrigin, phase: Phase) -> UpdateClaim {
        cancelRequested = false
        cancelDownload = nil
        nextClaimID += 1
        let claim = UpdateClaim(id: nextClaimID, origin: origin)
        self.claim = claim
        set(phase)
        return claim
    }

    private func set(_ phase: Phase) {
        self.phase = phase
        onChange?(phase)
    }
}

/// A pre-swap step boundary stopped the run. Nothing has moved and nothing is
/// pending, so both paths answer it without an error dialog.
struct UpdateStopped: Error, Equatable, LocalizedError {
    enum Why: Equatable {
        /// The person pressed Cancel before the swap began.
        case cancelled
        /// Automatic updates were turned off during the scheduled install.
        case disabled
        /// The person's own Check for Updates took the machine over. Nothing
        /// moved, and the person's run is the one that continues.
        case superseded
    }

    let why: Why

    var errorDescription: String? {
        switch why {
        case .cancelled: return "The update was cancelled before anything was installed."
        case .disabled: return "Automatic updates were turned off before anything was installed."
        case .superseded: return "The automatic update stood down for Check for Updates."
        }
    }
}

/// A second start while an update is underway. The manual path shows
/// `busyMessage`; the scheduled path logs it.
struct UpdateBusy: Error, Equatable, LocalizedError {
    var errorDescription: String? { UpdateCoordinator.busyMessage }
}

/// The install itself runs on the main actor with the UI. `@unchecked Sendable` is safe here by
/// construction: every property is read and written from the main actor, and the only cross-thread
/// handoff is the downloader's `@MainActor @Sendable` progress closure.
@MainActor
final class UpdateInstaller: @unchecked Sendable {
    let release: ReleaseInfo
    let app: URL
    /// The one shared state machine. The caller claims it before building this
    /// installer, and `run()` refuses to start without that claim.
    let coordinator: UpdateCoordinator
    /// Which path is running this install; the coordinator's phases and the
    /// boundary checks carry it so each path only reads its own setting.
    let origin: UpdateOrigin
    /// How to quit the app once the swap is done; AppWindow passes the menu's own quit path.
    var quit: (() -> Void)?
    /// The background path's pre-swap idleness gate (H2): the same activity the
    /// quiet wait sampled, re-read immediately before the first bundle move. The
    /// download and verification took minutes, and a Touch ID prompt or gateway
    /// call that came up in that window must not die to the swap — past this
    /// point the running bundle starts moving and a relaunch helper is about to
    /// be pending, so this is the last refusal that costs nothing. The manual
    /// flow leaves it nil: its modal progress window keeps the person in charge
    /// of the timing.
    var idleGate: (any UpdateActivitySource)?
    /// Whether the swap hands off to the restart helper itself (the manual flow)
    /// or leaves it pending for the caller (the background path, S2). The
    /// helper deletes the old bundle and opens the new one 30 s after this
    /// process is gone at the latest, so it may only start once the caller has
    /// decided to quit: the background updater re-checks idleness after `run()`
    /// returns, and a helper spawned before that check would delete the bundle
    /// out from under an app that stayed up and open a second copy beside it.
    var defersRelaunch = false
    /// How the restart helper starts; a test counts calls instead of spawning.
    var spawn: ([String]) throws -> Void = AppUpdater.spawnRelauncher
    /// How the disk image is fetched; nil uses `ReleaseAssetDownload`. A test
    /// uses this to hold the progress sink past the end of a run, which is what
    /// a queue of late `@MainActor` progress hops looks like to the machine.
    var downloadStep: (@MainActor (URL, URL, @escaping @MainActor @Sendable (Double, Int64) -> Void) async throws -> Void)?
    /// The verification steps, each replaceable so a test can suspend one. The
    /// production values do their blocking work in a detached task, so hashing,
    /// `hdiutil`, the plist read, the copy and codesign never hold the main
    /// actor: that is what lets a Cancel click land while they run.
    var sha256Step: @Sendable (URL) async throws -> String = { url in
        try await Task.detached(priority: .userInitiated) { try AppUpdater.hexSha256(fileAt: url) }.value
    }
    var mountStep: @Sendable (URL, URL) async throws -> String = { dmg, mount in
        try await Task.detached(priority: .userInitiated) { try AppUpdater.attachDiskImage(dmg, mount: mount) }.value
    }
    var unmountStep: @Sendable (String, Bool) async -> Void = { mountPath, force in
        await Task.detached(priority: .userInitiated) {
            AppUpdater.detachDiskImage(mountPath, force: force)
        }.value
    }
    var versionStep: @Sendable (URL, String) async throws -> Void = { candidate, release in
        try await Task.detached(priority: .userInitiated) {
            try AppUpdater.readCandidateVersion(at: candidate, release: release, current: AppVersion.current)
        }.value
    }
    var stageStep: @Sendable (URL, URL) async throws -> Void = { candidate, incoming in
        try await Task.detached(priority: .userInitiated) { try AppUpdater.stageCandidate(candidate, incoming) }.value
    }
    var validateStep: @Sendable (URL, URL) async throws -> Void = { incoming, running in
        try await Task.detached(priority: .userInitiated) { try StableSigning.validate(incoming, replacing: running) }.value
    }
    private var pendingRelaunch: [String]?
    private var download: ReleaseAssetDownload?

    init(release: ReleaseInfo, app: URL, coordinator: UpdateCoordinator, origin: UpdateOrigin) {
        self.release = release
        self.app = app
        self.coordinator = coordinator
        self.origin = origin
    }

    /// The person's Cancel and the download stop are the coordinator's, so a
    /// cancel that arrives between two downloads still stops the run.
    func cancel() {
        coordinator.cancel()
    }

    func run() async throws {
        // The caller claimed the machine before building this installer; a
        // claim that is gone means another run owns it and this one must not
        // stage beside the same names.
        guard !app.path.hasPrefix("/Volumes/") else {
            throw AppError.http("Keysrs is running from a disk image. Drag it to the Applications folder, open it, and update again.")
        }
        // The claim the caller holds, read once: every step and every boundary
        // carries this token, so a run that the person's Check for Updates took
        // over — or a progress report that arrives after this run ended — can
        // never write over the claim that is live now.
        guard let claim = coordinator.currentClaim(for: origin), coordinator.isInstalling(origin) else {
            throw UpdateBusy()
        }
        try coordinator.checkContinue(claim)
        // From here the run is downloading, even before the first byte: the
        // scheduled path's claim would otherwise still read `.waiting` through
        // the checksum sidecar, and the person's Check for Updates would take it
        // over and start a second download beside this one.
        coordinator.step(.downloading(origin, written: 0, expected: 0), for: claim)
        let plan = AppUpdater.installPlan(app: app)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("keysrs-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        coordinator.setCancelDownload(claim) { [weak self] in self?.download?.cancel() }
        defer { coordinator.clearCancelDownload(claim) }

        // The checksum is known before anything large is fetched, so a release that publishes
        // none is refused before the download rather than after.
        let expected = try await checksum(in: work)
        // Step boundary: a cancel (or automatic updates turned off) during the checksum
        // download stops the run here, before the large download even starts.
        try coordinator.checkContinue(claim)
        let dmgFile = work.appendingPathComponent(AppUpdater.dmgName)
        // Progress is published with the token this run was handed: the sink
        // runs in a `@MainActor` hop queued from the download delegate's own
        // thread, so one can land after `finish()` — and then it only updates
        // the phase if this claim is still the current one, never reviving the
        // machine from `.idle`.
        let progress: @MainActor @Sendable (Double, Int64) -> Void = { [weak self] fraction, expected in
            guard let self else { return }
            let written = Int64((Double(expected) * fraction).rounded())
            self.coordinator.step(.downloading(self.origin, written: written, expected: expected), for: claim)
        }
        if let downloadStep {
            try await downloadStep(release.dmg, dmgFile, progress)
        } else {
            let downloader = ReleaseAssetDownload()
            download = downloader
            defer { download = nil }
            try await downloader.download(from: release.dmg, to: dmgFile, progress: progress)
        }
        // The DMG is on disk but nothing has been verified or moved: the last
        // point where stopping costs nothing at all.
        try coordinator.checkContinue(claim)
        coordinator.step(.verifying(origin), for: claim)
        // Everything from here to the swap blocks: hashing, hdiutil, the
        // plist read, the copy and codesign all take real time. They run off
        // the main actor and are awaited, so the main actor is free — a Cancel
        // click lands, and the boundary right after each step sees it. Running
        // them inline on the main actor is what made Cancel do nothing after
        // the download.
        let sha256 = sha256Step
        let actual = try await sha256(dmgFile)
        guard actual == expected else {
            throw AppError.http("The download's checksum does not match the release. Nothing was installed; try again.")
        }
        if let size = release.expectedBytes,
           (try? fm.attributesOfItem(atPath: dmgFile.path)[.size] as? Int) != size {
            throw AppError.http("The download's size differs from the release. Nothing was installed; try again.")
        }
        try coordinator.checkContinue(claim)

        // Mounting, the Info.plist gate, staging and the signature gate are all
        // `verifying`: nothing beside the running app has moved yet, so a cancel
        // here still costs nothing. The disk image is detached on every path,
        // because `defer` cannot await the detach off the main actor.
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let mountPath: String
        do {
            mountPath = try await mountStep(dmgFile, mount)
        } catch {
            // The attach may have got as far as registering the mountpoint.
            await unmountStep(mount.path, true)
            throw error
        }
        do {
            try await verifyAndSwap(mountedAt: mountPath, dmgFile: dmgFile, work: work,
                                    plan: plan, expected: expected, claim: claim, fileManager: fm)
        } catch {
            await unmountStep(mountPath, false)
            throw error
        }
    }

    /// Everything between the mount and the swap, plus the hand-off. The disk
    /// image is detached here rather than by a `defer` in `run()`: the hand-off
    /// is the last thing this process does when it quits, so the detach has to
    /// come first, exactly as it did before the swap was split out.
    private func verifyAndSwap(mountedAt mountPath: String, dmgFile: URL, work: URL,
                               plan: AppUpdater.InstallPlan, expected: String,
                               claim: UpdateClaim, fileManager fm: FileManager) async throws {
        let candidate = URL(fileURLWithPath: mountPath).appendingPathComponent("Keysrs.app")
        guard fm.fileExists(atPath: candidate.path) else {
            throw AppError.http("The disk image does not contain Keysrs.app. Nothing was installed.")
        }
        try coordinator.checkContinue(claim)
        let version = release.version
        try await versionStep(candidate, version)
        try coordinator.checkContinue(claim)

        // Staging replaces any leftover `.Keysrs.app.incoming` itself, off the
        // main actor. Every refusal between staging and the first move removes
        // what was staged, so a cancel or a deferral leaves nothing beside the
        // running app.
        do { try await stageStep(candidate, plan.incoming) }
        catch {
            await discard(plan.incoming)
            throw AppError.http("The new version could not be staged beside Keysrs (\(error.localizedDescription)). Nothing was installed.")
        }
        do {
            try coordinator.checkContinue(claim)
            // The signature gate comes after staging and before the swap: a different team or
            // requirement would silently cut the app off from every Keychain item it owns.
            try await validateStep(plan.incoming, plan.app)
            // The boundary after the signature gate covers the whole of the blocking
            // verification: it is the one the person's Cancel lands on, because the
            // awaits above are where the main actor gets to run it.
            try coordinator.checkContinue(claim)
            // The background path's last idleness check, before the point of no return
            // (H2): the quiet window that opened before the download says nothing about
            // the minutes that have since passed, and a prompt or gateway call that came
            // up in that window must not die to the swap. Nothing has moved yet, so
            // refusing here is the one point where the install can defer with no
            // relauncher pending; the background updater answers the thrown deferral
            // with its deferred line and the next daily check tries again.
            if let idleGate, idleGate.busy { throw BackgroundInstallBusy() }
        } catch {
            await discard(plan.incoming)
            throw error
        }
        // From `.swapping` on the run is not cancellable — the bundle is moving —
        // so the coordinator refuses a cancel from there and the progress window
        // disables its button. Nothing awaits between the boundary above and
        // the first move, so no cancel can land in between.
        coordinator.step(.swapping(origin), for: claim)
        do { try fm.moveItem(at: plan.app, to: plan.previous) }
        catch {
            await discard(plan.incoming)
            coordinator.swapRolledBack(claim)
            throw AppError.http("The running Keysrs could not be set aside; the previous version was kept (\(error.localizedDescription)).")
        }
        do { try fm.moveItem(at: plan.incoming, to: plan.app) }
        catch {
            do {
                try fm.moveItem(at: plan.previous, to: plan.app)
            } catch {
                // Neither bundle is at the app's path. The claim stays held so
                // nothing stages beside the set-aside copy; the person is told
                // where it is.
                throw AppError.http("The new version could not be moved into place, and the previous version could not be put back. It is at \(plan.previous.path); move it back to \(plan.app.path).")
            }
            await discard(plan.incoming)
            coordinator.swapRolledBack(claim)
            throw AppError.http("The new version could not be moved into place; the previous version was restored.")
        }

        // Past this point the running bundle is the new one. The claim is never
        // released in this process from here on, whatever happens to the
        // restart: a new claim would try to set the already-replaced bundle
        // aside a second time. A failed restart leaves the run in
        // `.installedPendingRelaunch`, where only `relaunch()` is retried.
        coordinator.step(.relaunching(origin), for: claim)
        // The quit below exits without unwinding anything, so the disk image is
        // detached and the download removed here; on every failure path the
        // caller's detach and this run's defer are the cleanup.
        await unmountStep(mountPath, false)
        try? fm.removeItem(at: work)
        let relauncher = AppUpdater.relauncher(pid: getpid(), old: plan.previous, new: plan.app)
        do {
            try handOff(relauncher)
        } catch {
            pendingRelaunch = relauncher
            // Captured strongly on purpose: the caller drops its reference to
            // this installer, and the coordinator's restart is now the only
            // thing holding the helper's arguments. The state is terminal for
            // the process, so the cycle never needs breaking.
            coordinator.installedPendingRelaunch(claim) {
                try self.relaunch()
                self.quit?()
            }
            throw error
        }
    }

    /// Removes a staged bundle off the main actor: it is a whole app's worth of
    /// files.
    private func discard(_ url: URL) async {
        await Task.detached(priority: .userInitiated) { try? FileManager.default.removeItem(at: url) }.value
    }

    /// The swap is done: the manual flow starts the restart helper and quits now,
    /// the background path keeps the helper's arguments until `relaunch()`.
    func handOff(_ relauncher: [String]) throws {
        if defersRelaunch {
            pendingRelaunch = relauncher
            return
        }
        try spawn(relauncher)
        quit?()
    }

    /// Starts the restart helper the background path held back, immediately
    /// before its quit. A failed spawn keeps it pending for the next attempt:
    /// the retry is another `relaunch()`, never another swap.
    func relaunch() throws {
        guard let relauncher = pendingRelaunch else { return }
        try spawn(relauncher)
        pendingRelaunch = nil
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

    /// Renders the one shared phase. Cancel stays live through the download and
    /// every verification step — the run really does stop there — and locks the
    /// moment the swap begins, because from `.swapping` on the bundle is moving
    /// and there is nothing left to stop.
    func update(_ phase: UpdateCoordinator.Phase) {
        switch phase {
        case .idle:
            break
        case .checking:
            status.stringValue = "Checking for updates…"
        case .waiting:
            status.stringValue = "Waiting for Keysrs to be idle…"
            bar.doubleValue = 0
        case .downloading(_, _, let expected) where expected <= 0:
            status.stringValue = "Starting…"
        case .downloading(_, let written, let expected):
            status.stringValue = "Downloading… \(Self.bytes.string(fromByteCount: written)) of \(Self.bytes.string(fromByteCount: expected))"
            bar.doubleValue = expected > 0 ? Double(written) / Double(expected) : 0
        case .verifying:
            status.stringValue = "Verifying the update…"
            bar.doubleValue = 1
        case .swapping:
            status.stringValue = "Replacing Keysrs…"
            bar.doubleValue = 1
        case .relaunching:
            status.stringValue = "Restarting…"
        case .installedPendingRelaunch:
            status.stringValue = "Installed. Open Keysrs again to finish."
            bar.doubleValue = 1
        }
        // Disabled from the swap on, hidden once only the restart is left —
        // as before the shared machine.
        cancelButton.isEnabled = phase.allowsCancel
        switch phase {
        case .relaunching, .installedPendingRelaunch: cancelButton.isHidden = true
        default: break
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
