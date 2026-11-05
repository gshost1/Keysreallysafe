import Darwin
import Foundation

/// The running site (menubar or dashboard) writes its port and per-launch token to a
/// 0600 file so `keys grant` in a Terminal can ask it for a grant. The token only lets a
/// local process ask; every grant still needs Touch ID in the owner process.
enum ControlFile {
    struct Info: Equatable {
        var port: UInt16
        var pid: pid_t
        var token: String
        /// Written by whichever process created this file; the pid alone is not the
        /// identity, because a pid is recycled and two sites can share one catalog.
        var bootID: String = ""
    }

    /// The live owner of an existing file, when a different site may not displace it.
    /// Carries no token: the refusal is printed, and a token never is.
    struct OwnerHeld: Error, Equatable, LocalizedError, CustomStringConvertible {
        var pid: pid_t
        var port: UInt16
        var description: String {
            "Keysrs is already running (pid \(pid), dashboard port \(port)); quit it or use that one"
        }
        var errorDescription: String? { description }
    }

    /// One random id per process, so `remove` can tell its own file from a newer
    /// owner's file that happens to carry a recycled pid.
    static let processBootID = UUID().uuidString

    /// Beside an explicit catalog — pure math, never throwing, for the callers
    /// that already hold their catalog (the app, a service, a rigged test).
    static func url(beside catalog: URL) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("control.json")
    }

    /// The default control URL for a caller that resolved nothing itself. A
    /// Swift default argument cannot throw, so the no-argument form resolves
    /// the default catalog INSIDE the body — through the tripwire-checked
    /// resolver, so under XCTest or `KEYS_TEST_ISOLATION` with no
    /// `KEYS_CATALOG` it throws instead of naming the real control.json
    /// (VAL-G-003/VAL-H-001). Production behavior is unchanged: outside the
    /// tripwire this is the installed catalog's sibling, as before.
    static func url() throws -> URL {
        ControlFile.url(beside: try Paths.resolvingCatalog())
    }

    /// Publishes this site, or refuses to displace a running one.
    ///
    /// The rule: a file a *live Keysrs site* owns, in another process, is left alone
    /// unless the caller passes `takeover` — which only the installed app's bind does,
    /// because a relaunch or an explicit start is meant to own the file. A file whose
    /// owner is dead, or whose pid now belongs to some other program (a recycled pid,
    /// a test stand-in), is stale and is replaced. Without this rule a checkout
    /// `keys dashboard` on 12765 overwrote the app's file on 12766 and its exit removed
    /// it, leaving the running app unreachable to every CLI command.
    static func write(
        port: UInt16, token: String, pid: pid_t = ProcessInfo.processInfo.processIdentifier,
        bootID: String? = nil, takeover: Bool = false, to url: URL? = nil
    ) throws {
        let url = try url ?? ControlFile.url()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try assertPublishable(at: url, pid: pid, takeover: takeover)
        // A foreign pid is a rig or a stand-in, never this process: giving it this
        // process's boot id would let our exit cleanup delete its file.
        let id = bootID ?? (pid == getpid() ? processBootID : UUID().uuidString)
        let data = try JSONValue.data(["port": Int(port), "pid": Int(pid), "token": token, "boot": id])
        try writeOwnerOnly(data, to: url)
    }

    /// The ownership half of `write`, on its own so a site can ask before it starts
    /// anything. `bind` used to learn this only while publishing, by which point its
    /// gateway was already listening with no control file that could point at it.
    static func assertPublishable(
        at url: URL, pid: pid_t = ProcessInfo.processInfo.processIdentifier, takeover: Bool = false
    ) throws {
        if !takeover, let existing = try? read(at: url), existing.pid != pid, isRunningSite(existing.pid) {
            throw OwnerHeld(pid: existing.pid, port: existing.port)
        }
    }

    static func remove(
        ifOwnedBy pid: pid_t = ProcessInfo.processInfo.processIdentifier, at url: URL? = nil
    ) {
        // The tripwire's refusal reads as "nothing to remove" here, the
        // fail-closed direction for a cleanup call: under test isolation there
        // is deliberately no default control file to own.
        guard let url = url ?? (try? ControlFile.url()) else { return }
        // Re-read immediately before the unlink: between the bind and this call a
        // newer owner may have replaced the file, and deleting it would strand them.
        guard let info = try? read(at: url), info.pid == pid else { return }
        // A file with no boot id predates this field; there the pid is all there is.
        guard info.bootID.isEmpty || info.bootID == processBootID else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func read(at url: URL? = nil) throws -> Info? {
        let url = try url ?? ControlFile.url()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let port = JSONValue.int(obj["port"]), let pid = JSONValue.int(obj["pid"]),
              let token = JSONValue.string(obj["token"]), port > 0, port <= 65_535,
              // kill(0 or negative) signals a process group, so such a pid is never "alive".
              pid > 0, pid <= Int(Int32.max)
        else { return nil }
        return Info(port: UInt16(port), pid: pid_t(pid), token: token, bootID: JSONValue.string(obj["boot"]) ?? "")
    }

    /// A live owner, or nil when the file is missing or its process is gone.
    /// Under the tripwire the no-argument form answers nil: there is
    /// deliberately no default control file in a test process.
    static func live(at url: URL? = nil) -> Info? {
        guard let url = url ?? (try? ControlFile.url()), let info = try? read(at: url) else { return nil }
        if kill(info.pid, 0) != 0 && errno == ESRCH { return nil }
        return info
    }

    /// Whether `pid` is a live Keysrs binary. The site that may not be displaced is a
    /// `keys` process (the app's `Contents/MacOS/keys` or a checkout dev copy), so a
    /// live pid running something else — a recycled pid, a test stand-in — leaves the
    /// file stale and replaceable.
    static func isRunningSite(_ pid: pid_t) -> Bool {
        guard isAlive(pid) else { return false }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(raw.count))
        }
        guard length > 0 else { return false }
        return URL(fileURLWithPath: String(decoding: buffer[0..<Int(length)], as: UTF8.self))
            .lastPathComponent == "keys"
    }

    /// Whether `pid` is a process that exists (a zombie counts, as it does for `live`).
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Publishes the file with 0600 from creation: writing to the final path and then
    /// chmod'ing left it at the process umask for a moment, and the token is in it.
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppError.http("could not create \(temp.path)") }
        var failure: Error?
        do {
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                    if n <= 0 {
                        if n < 0 && errno == EINTR { continue }
                        throw AppError.http("could not write \(temp.path)")
                    }
                    written += n
                }
            }
            if fsync(fd) != 0 { throw AppError.http("could not flush \(temp.path)") }
            // O_EXCL above created it 0600 minus the umask, so a strict umask only ever
            // narrows it; this restores the intended mode before the file is published,
            // which is still before its path exists.
            if fchmod(fd, 0o600) != 0 { throw AppError.http("could not set the mode of \(temp.path)") }
        } catch {
            failure = error
        }
        Darwin.close(fd)
        if failure == nil, Darwin.rename(temp.path, url.path) != 0 {
            failure = AppError.http("could not publish \(url.path)")
        }
        if let failure {
            Darwin.unlink(temp.path)
            throw failure
        }
    }
}

/// CLI side: talk to the running site over loopback.
struct ControlClient {
    var info: ControlFile.Info

    /// The default control URL resolves INSIDE the body (a Swift default
    /// argument cannot throw): under the test tripwire the no-argument form
    /// throws the refusal instead of reaching for the real control.json, and a
    /// caller with an explicit catalog sibling keeps today's behavior.
    static func connect(control: URL? = nil) throws -> ControlClient {
        let control = try control ?? ControlFile.url()
        guard let info = ControlFile.live(at: control) else {
            // Its own exit code (6), so a script can tell a site that is not running from a
            // mistyped command.
            throw AppError.siteUnavailable(
                "no running Keysrs site owns the gateway; open Keysrs.app or run keys dashboard, then retry"
            )
        }
        return ControlClient(info: info)
    }

    /// The response object when the site answers `expect`; any other status is thrown as the
    /// AppError it carries.
    func call(
        method: String, path: String, body: [String: Any]? = nil, expect: Int, timeout: TimeInterval = 180
    ) throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(info.port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(info.token, forHTTPHeaderField: "X-KSF-Token")
        req.setValue("127.0.0.1:\(info.port)", forHTTPHeaderField: "Host")
        if let body {
            req.httpBody = try JSONValue.data(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try BlockingHTTP.send(req, timeout: timeout)
        } catch {
            let reason = (error as? AppError)?.description ?? error.localizedDescription
            throw AppError.http("could not reach the local site on 127.0.0.1:\(info.port): \(reason)")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object) ?? [:]
        guard http.statusCode == expect else {
            throw AppError(wireCode: JSONValue.string(obj["error"]) ?? "error", status: http.statusCode, body: obj)
        }
        return obj
    }
}
