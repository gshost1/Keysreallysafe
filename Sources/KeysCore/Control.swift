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

    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["KEYS_CONTROL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Paths.appSupport.appendingPathComponent("control.json")
    }

    static func write(port: UInt16, token: String, pid: pid_t = ProcessInfo.processInfo.processIdentifier) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONValue.data(["port": Int(port), "pid": Int(pid), "token": token])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(ifOwnedBy pid: pid_t = ProcessInfo.processInfo.processIdentifier) {
        guard let info = try? read(), info.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func read() throws -> Info? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.object),
              let port = JSONValue.int(obj["port"]), let pid = JSONValue.int(obj["pid"]),
              let token = JSONValue.string(obj["token"]), port > 0, port <= 65_535
        else { return nil }
        return Info(port: UInt16(port), pid: pid_t(pid), token: token)
    }

    /// A live owner, or nil when the file is missing or its process is gone.
    static func live() -> Info? {
        guard let info = try? read() else { return nil }
        if kill(info.pid, 0) != 0 && errno == ESRCH { return nil }
        return info
    }
}

/// CLI side: talk to the running site over loopback.
struct ControlClient {
    var info: ControlFile.Info

    static func connect() throws -> ControlClient {
        guard let info = ControlFile.live() else {
            throw AppError.usage(
                "no running Keysreallysafe site owns the gateway; start one with keys autostart (login item) or keys dashboard, then retry"
            )
        }
        return ControlClient(info: info)
    }

    func call(method: String, path: String, body: [String: Any]? = nil, timeout: TimeInterval = 180) throws -> (Int, [String: Any]) {
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
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let sema = DispatchSemaphore(value: 0)
        let box = ControlBox()
        session.dataTask(with: req) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            sema.signal()
        }.resume()
        sema.wait()
        if let error = box.error {
            throw AppError.http("could not reach the local site on 127.0.0.1:\(info.port): \(error.localizedDescription)")
        }
        let obj = box.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)).flatMap(JSONValue.object) } ?? [:]
        return (box.status ?? 0, obj)
    }

    /// Turn an API error body into the same errors the CLI raises locally.
    static func raise(status: Int, body: [String: Any]) -> AppError {
        let code = JSONValue.string(body["error"]) ?? "error"
        let message = JSONValue.string(body["message"]) ?? code
        switch code {
        case "auth_failed": return .authFailed
        case "auth_cancelled": return .authCancelled
        case "auth_unavailable": return .authUnavailable(message)
        case "not_found": return .notFound(message)
        case "gateway owned by another process":
            return .gatewayOwned(pid_t(JSONValue.int(body["gateway_owner_pid"]) ?? 0))
        default:
            return .usage(status == 403 ? "site refused the request (\(message)); restart the site and retry" : message)
        }
    }
}

private final class ControlBox: @unchecked Sendable {
    var data: Data?
    var status: Int?
    var error: Error?
}
