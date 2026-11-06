import Darwin
import Foundation

/// The running site (menubar or dashboard) writes its port and per-launch token to a
/// 0600 file so `keys grant` in a Terminal can ask it for a grant. The token only lets a
/// local process ask; every grant still needs Touch ID in the owner process.
///
/// The file also carries a second per-launch value, the control secret. The token is the
/// dashboard page's CSRF value too, so any loopback peer reads it from GET /, and macOS
/// loopback is shared by every account on the Mac. The control secret is never served:
/// only a reader of this owner-only file has it, and the routes that answer with a
/// credential or a vault-derived fact without asking for presence require it.
enum ControlFile {
    struct Info: Equatable {
        var port: UInt16
        var pid: pid_t
        var token: String
        /// Written by whichever process created this file; the pid alone is not the
        /// identity, because a pid is recycled and two sites can share one catalog.
        var bootID: String = ""
        /// Empty when the file was written by a site that predates the field; the
        /// client then refuses the secret-gated routes itself instead of trying them.
        var controlSecret: String = ""
    }

    /// The header the control secret travels in. Never set by the dashboard page.
    static let secretHeader = "X-KSF-Control"

    /// The routes only a control-file holder may call: their answers carry a live
    /// credential or confirm a vault value, and none asks for presence. The
    /// dashboard page calls none of them, so the page's token is never enough.
    /// One list for both sides, so the client can fail closed on an older site.
    static func requiresSecret(method: String, path: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        return path == "/api/clients/held/token"
            || path == "/api/mcp/vault_lookup"
            || path == "/api/mcp/feedback"
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
        port: UInt16, token: String, controlSecret: String = "",
        pid: pid_t = ProcessInfo.processInfo.processIdentifier,
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
        var fields: [String: Any] = ["port": Int(port), "pid": Int(pid), "token": token, "boot": id]
        if !controlSecret.isEmpty { fields["control"] = controlSecret }
        let data = try JSONValue.data(fields)
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
        return Info(
            port: UInt16(port), pid: pid_t(pid), token: token, bootID: JSONValue.string(obj["boot"]) ?? "",
            controlSecret: JSONValue.string(obj["control"]) ?? ""
        )
    }

    /// A live owner, or nil when the file is missing or its pid is not this user's
    /// Keysrs. Under the tripwire the no-argument form answers nil: there is
    /// deliberately no default control file in a test process.
    ///
    /// The file outlives an unclean exit (it is removed only at exit), so its pid can
    /// be recycled. "Some process has this pid" used to be enough, and kill's EPERM
    /// for another account's process counted as alive too, so a stale file read as
    /// the running app.
    static func live(at url: URL? = nil) -> Info? {
        guard let url = url ?? (try? ControlFile.url()), let info = try? read(at: url) else { return nil }
        return isOwnSite(info) ? info : nil
    }

    /// Whether the file's pid may be this user's site: this very process, or a live
    /// process of this user that is a `keys` binary or holds the file's listener.
    /// The installed app and a checkout dev copy are both `keys`; the listener
    /// branch is for a site whose binary is called something else (an XCTest rig
    /// serving a spawned `keys` subprocess), and admits only the process actually
    /// serving that port. This process counts as itself whatever its binary is.
    static func isOwnSite(_ info: Info) -> Bool {
        if info.pid == getpid() { return true }
        guard isSameUser(info.pid) else { return false }
        return isRunningSite(info.pid) || holdsLoopbackListener(info.pid, port: info.port)
    }

    /// The owner a client may talk to: a process of this user (or this one) that
    /// holds the file's loopback listener. `live` answers "is a Keysrs up"; this
    /// answers "is the thing on this port that Keysrs". Every call after it carries
    /// the control token and, for keys wrap, raw key values, and the file survives
    /// a crash: its pid may be recycled into any process, and its port bound by
    /// anyone, in any account, while the app is down.
    static func serving(at url: URL) -> Info? {
        guard let info = try? read(at: url),
              info.pid == getpid() || isSameUser(info.pid),
              holdsLoopbackListener(info.pid, port: info.port)
        else { return nil }
        return info
    }

    /// Whether `pid` runs as this process's effective user. Another account's
    /// process answers kill with EPERM, which `isAlive` counts as alive.
    static func isSameUser(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == geteuid()
    }

    /// Whether `pid` holds a listening TCP socket on 127.0.0.1:`port`. A file's pid
    /// being a Keysrs binary says nothing about who answers on its port: a recycled
    /// pid can land on a `keys mcp`. Only the process holding the listener is the
    /// site. Same-user processes only: those are the ones whose fds libproc lists,
    /// and a refused listing answers false, the fail-closed direction.
    static func holdsLoopbackListener(_ pid: pid_t, port: UInt16) -> Bool {
        guard pid > 0, port > 0 else { return false }
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for a few fds opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 32)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return false }
        let loopback = inet_addr(BindPolicy.loopback)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  Int(info.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  Int32(local.insi_vflag) & Int32(INI_IPV4) != 0,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: local.insi_lport)) == port,
                  local.insi_laddr.ina_46.i46a_addr4.s_addr == loopback
            else { continue }
            return true
        }
        return false
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

    /// Whether `pid` is a process that exists (a zombie counts). `live` asks more:
    /// a zombie has no path, so it is not a running site.
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

    /// Only a file whose owner holds its listener connects (`ControlFile.serving`):
    /// every call after this carries the token, so a port nobody proved gets none.
    ///
    /// The default control URL resolves INSIDE the body (a Swift default
    /// argument cannot throw): under the test tripwire the no-argument form
    /// throws the refusal instead of reaching for the real control.json, and a
    /// caller with an explicit catalog sibling keeps today's behavior.
    static func connect(control: URL? = nil) throws -> ControlClient {
        let control = try control ?? ControlFile.url()
        guard let info = ControlFile.serving(at: control) else {
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
        // A site that predates the control secret answers these routes on the page token
        // alone, which any account on this Mac can read; so this side refuses first.
        if info.controlSecret.isEmpty, ControlFile.requiresSecret(method: method, path: path) {
            throw AppError.usage(
                "the running Keysrs is older than this keys command and cannot prove the control file for \(path); update Keysrs and reopen it, then retry"
            )
        }
        let url = URL(string: "http://127.0.0.1:\(info.port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(info.token, forHTTPHeaderField: "X-KSF-Token")
        // Sent on every call: `serving` already proved this listener is this user's site.
        if !info.controlSecret.isEmpty { req.setValue(info.controlSecret, forHTTPHeaderField: ControlFile.secretHeader) }
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
