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
    }

    /// Beside the catalog, so a service reads the owner of its own catalog. The default is
    /// the installed catalog's sibling, which keeps the atexit cleanup capture-free.
    static func url(beside catalog: URL = Paths.catalogDB) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("control.json")
    }

    static func write(
        port: UInt16, token: String, pid: pid_t = ProcessInfo.processInfo.processIdentifier, to url: URL = url()
    ) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONValue.data(["port": Int(port), "pid": Int(pid), "token": token])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(ifOwnedBy pid: pid_t = ProcessInfo.processInfo.processIdentifier, at url: URL = url()) {
        guard let info = try? read(at: url), info.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func read(at url: URL = url()) throws -> Info? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let port = JSONValue.int(obj["port"]), let pid = JSONValue.int(obj["pid"]),
              let token = JSONValue.string(obj["token"]), port > 0, port <= 65_535,
              // kill(0 or negative) signals a process group, so such a pid is never "alive".
              pid > 0, pid <= Int(Int32.max)
        else { return nil }
        return Info(port: UInt16(port), pid: pid_t(pid), token: token)
    }

    /// A live owner, or nil when the file is missing or its process is gone.
    static func live(at url: URL = url()) -> Info? {
        guard let info = try? read(at: url) else { return nil }
        if kill(info.pid, 0) != 0 && errno == ESRCH { return nil }
        return info
    }
}

/// CLI side: talk to the running site over loopback.
struct ControlClient {
    var info: ControlFile.Info

    static func connect(control: URL = ControlFile.url()) throws -> ControlClient {
        guard let info = ControlFile.live(at: control) else {
            throw AppError.usage(
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
