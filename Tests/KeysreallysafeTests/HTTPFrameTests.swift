import Darwin
import XCTest
@testable import KeysCore

/// HTTPFrame.read is the parser in front of both the dashboard and the gateway. A bare CR or
/// LF (or a NUL) that survives into a header or the request-target can end up in a header the
/// gateway hands to URLRequest, and a name a stricter peer would parse differently (space
/// before the colon, a folded line) is the same kind of gap, so these requests are refused
/// before any handler runs.
final class HTTPFrameTests: XCTestCase {
    private func server(_ hits: RequestLog) throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer(port: 0) { request in
            hits.record(request)
            return HTTPResponse.text(200, "ok")
        }
        server.start()
        return server
    }

    func testControlCharactersInTheRequestAreRefused() throws {
        let hits = RequestLog()
        let server = try server(hits)
        defer { server.stop() }
        let host = "Host: 127.0.0.1:\(server.boundPort)\r\n"
        let cases: [(String, String)] = [
            ("bare LF in a value", "GET / HTTP/1.1\r\n\(host)X-Pad: a\nX-Injected: b\r\n\r\n"),
            ("bare CR in a value", "GET / HTTP/1.1\r\n\(host)X-Pad: a\rX-Injected: b\r\n\r\n"),
            ("NUL in a value", "GET / HTTP/1.1\r\n\(host)X-Pad: a\u{0}b\r\n\r\n"),
            ("bare LF in a name", "GET / HTTP/1.1\r\n\(host)X-A\nX-B: c\r\n\r\n"),
            ("NUL in a name", "GET / HTTP/1.1\r\n\(host)X-A\u{0}B: c\r\n\r\n"),
            ("bare LF in the target", "GET /a\nb HTTP/1.1\r\n\(host)\r\n"),
            ("NUL in the target", "GET /a\u{0}b HTTP/1.1\r\n\(host)\r\n"),
            ("bare CR in the version", "GET / HTTP/1.1\rX\r\n\(host)\r\n"),
            ("space before the colon", "GET / HTTP/1.1\r\n\(host)Authorization : Bearer x\r\n\r\n"),
            ("folded line", "GET / HTTP/1.1\r\n\(host)X-Pad: a\r\n Authorization: Bearer x\r\n\r\n"),
            ("space in a name", "GET / HTTP/1.1\r\n\(host)X A: v\r\n\r\n"),
            ("tab in the method", "GET\tX / HTTP/1.1\r\n\(host)\r\n"),
        ]
        for (label, request) in cases {
            let (status, _) = try exchangeRaw(port: server.boundPort, request: Data(request.utf8))
            XCTAssertEqual(status, 400, label)
        }
        XCTAssertEqual(hits.count, 0, "no refused request reaches the handler")
    }

    func testTabsAndOrdinaryHeadersStillPass() throws {
        let hits = RequestLog()
        let server = try server(hits)
        defer { server.stop() }
        let request = "GET /x?y=1 HTTP/1.1\r\nHost: 127.0.0.1:\(server.boundPort)\r\nX-Tab:\tvalue\twith tab\r\n\r\n"
        let (status, _) = try exchangeRaw(port: server.boundPort, request: Data(request.utf8))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(hits.last?.headers["x-tab"], "value\twith tab")
    }
}

/// Writes `request` on a fresh loopback socket and reads until the peer closes. Raw bytes,
/// because URLSession refuses to send the malformed requests these tests need.
func exchangeRaw(port: UInt16, request: Data) throws -> (status: Int, response: Data) {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw AppError.http("socket") }
    defer { Darwin.close(fd) }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 { throw AppError.http("connect") }
    guard HTTPFrame.writeAll(fd: fd, request) else { throw AppError.http("write") }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    guard let text = String(data: data, encoding: .isoLatin1),
          let first = text.split(separator: "\r\n", maxSplits: 1).first
    else { return (0, data) }
    let parts = first.split(separator: " ")
    return (parts.count >= 2 ? Int(parts[1]) ?? 0 : 0, data)
}
