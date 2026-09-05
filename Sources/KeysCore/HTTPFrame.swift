import Darwin
import Foundation

enum HTTPFrame {
    enum Read {
        case ok(method: String, target: String, headers: [String: String], body: Data)
        case bad
        case tooLarge
        case lengthRequired
        case unsupported
    }

    static let headerCap = 65_536
    static let socketTimeoutSeconds: Int = 30

    static func setDeadlines(fd: Int32, seconds: Int = socketTimeoutSeconds) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func read(fd: Int32, bodyCap: Int) -> Read {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while data.count < headerCap {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return .bad }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                break
            }
        }
        guard let headerEnd else { return .bad }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        var leftover = Data(data[headerEnd.upperBound...])
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { return .bad }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return .bad }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .bad }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        var transferEncodings: [String] = []
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                contentLengths.append(String(value))
            } else if key == "transfer-encoding" {
                transferEncodings.append(String(value))
            }
            headers[String(key)] = String(value)
        }

        let te = transferEncodings.joined(separator: ",").lowercased()
        let isChunked = te.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "chunked" }
        if isChunked {
            if !contentLengths.isEmpty { return .bad }
            switch readChunkedBody(fd: fd, leftover: leftover, cap: bodyCap) {
            case .tooLarge: return .tooLarge
            case .failure: return .bad
            case .ok(let body):
                return .ok(method: method, target: target, headers: headers, body: body)
            }
        }
        if !te.isEmpty && te != "identity" {
            return .unsupported
        }
        if contentLengths.count > 1 { return .bad }
        let length: Int
        if let raw = contentLengths.first {
            guard let parsed = parseContentLength(raw) else { return .bad }
            length = parsed
        } else {
            length = 0
            if !leftover.isEmpty { return .bad }
        }
        if length > bodyCap { return .tooLarge }
        while leftover.count < length {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return .bad }
            if n == 0 { return .bad }
            leftover.append(contentsOf: buf[0..<n])
            if leftover.count > bodyCap { return .tooLarge }
        }
        if leftover.count < length { return .bad }
        return .ok(
            method: method,
            target: target,
            headers: headers,
            body: Data(leftover.prefix(length))
        )
    }

    /// Non-negative integer that fits in `Int`. Rejects signs, spaces, and overflow.
    static func parseContentLength(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if s.count > 1 && s.hasPrefix("0") { return nil }
        return Int(s)
    }

    enum LoopbackOrigin {
        static func hostAllowed(_ header: String?, port: UInt16) -> Bool {
            let h = (header ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
        }

        /// Browser `Origin` must be this process's loopback origin when present.
        static func originAllowed(_ origin: String?, port: UInt16) -> Bool {
            guard let origin, !origin.isEmpty else { return true }
            guard let url = URL(string: origin), url.scheme?.lowercased() == "http",
                  let host = url.host
            else { return false }
            let originPort = url.port ?? 80
            guard originPort == Int(port), BindPolicy.isLoopbackHostname(host) else { return false }
            return url.path.isEmpty || url.path == "/"
        }

        static func fetchSiteAllowed(_ site: String?) -> Bool {
            guard let site, !site.isEmpty else { return true }
            let s = site.lowercased()
            return s == "same-origin" || s == "none"
        }
    }

    private enum Chunked {
        case ok(Data)
        case tooLarge
        case failure
    }

    private static func readChunkedBody(fd: Int32, leftover: Data, cap: Int) -> Chunked {
        var pending = leftover
        var body = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        func need(_ n: Int) -> Bool {
            while pending.count < n {
                let r = Darwin.read(fd, &buf, buf.count)
                if r <= 0 { return false }
                pending.append(contentsOf: buf[0..<r])
                if body.count + pending.count > cap + 64 { return false }
            }
            return true
        }
        func readLine() -> String? {
            while true {
                if let range = pending.range(of: Data("\r\n".utf8)) {
                    let line = pending[pending.startIndex..<range.lowerBound]
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    return String(data: Data(line), encoding: .isoLatin1)
                }
                let r = Darwin.read(fd, &buf, buf.count)
                if r <= 0 { return nil }
                pending.append(contentsOf: buf[0..<r])
                if pending.count > cap + 1024 { return nil }
            }
        }
        while true {
            guard let line = readLine() else { return .failure }
            let sizePart = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? line
            guard let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return .failure
            }
            if size == 0 {
                _ = readLine()
                return .ok(body)
            }
            if body.count + size > cap { return .tooLarge }
            if !need(size + 2) { return .failure }
            body.append(pending.prefix(size))
            pending.removeFirst(size)
            guard pending.count >= 2, pending[pending.startIndex] == 13, pending[pending.startIndex + 1] == 10 else {
                return .failure
            }
            pending.removeFirst(2)
        }
    }
}

enum RedirectDenyingDelegate {
    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: DenyRedirects(), delegateQueue: nil)
    }
}

final class DenyRedirects: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
