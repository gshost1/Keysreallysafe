import Darwin
import XCTest
@testable import KeysCore

/// The gateway's Docker Host acceptance. Docker Desktop for Mac dials the Mac's own
/// loopback when a container connects to `host.docker.internal`, so the listener keeps
/// its 127.0.0.1 bind and a containerized SDK's Host header just spells the URL
/// authority. The gateway alone accepts that exact spelling while `pref_docker_access`
/// is on, and nothing widens the shared loopback checks the dashboard site, the relay
/// URL validation and the egress guards use. Every gateway row here forges the Host
/// over a raw loopback socket, mirroring `testGatewayRejectsBadHostOriginAndCrossSiteBeforeLookup`.
final class DockerGatewayAccessTests: XCTestCase {
    private func dockerCall(port: UInt16, host: String, grant: String) throws -> (status: Int, body: Data) {
        try sendRaw(
            port: port,
            request: "GET /demo/v1/models HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(grant)\r\n\r\n"
        )
    }

    /// A fresh catalog holds no pref row: the Docker Host is refused 403 exactly like any
    /// foreign Host, before the key is looked up — proven with a valid grant in hand, so
    /// only the Host gate can be the one answering, and with the upstream silent.
    func testDockerHostIsRefusedByDefaultBeforeLookup() throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "docker default off")
        let port = rig.gateway.boundPort
        let promptsBefore = rig.gate.reasons.count
        XCTAssertNil(try rig.db.metaValue(AppPreferences.dockerAccessKey), "a fresh catalog holds no pref row")

        // Control: the same call with the loopback Host is served, so the rig is answering.
        let loopback = try dockerCall(port: port, host: "127.0.0.1:\(port)", grant: grant)
        XCTAssertEqual(loopback.status, 200)
        XCTAssertEqual(hits.count, 1)

        let docker = try dockerCall(port: port, host: "host.docker.internal:\(port)", grant: grant)
        XCTAssertEqual(docker.status, 403)
        XCTAssertEqual(hits.count, 1, "the refused call never reached the upstream")
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "a Host refusal shows no presence prompt")
    }

    /// With the setting on, the gateway accepts exactly `host.docker.internal:<bound
    /// port>` — the comparison trims and lowercases like the loopback check beside it —
    /// and serves the request. The bare name, a wrong port and every look-alike stay
    /// foreign Hosts, and the loopback Hosts keep working.
    func testSettingOnAcceptsOnlyTheExactDockerHostWithPort() throws {
        let hits = RequestLog()
        let rig = try GatewayRig { request in
            hits.record(request)
            return HTTPResponse.json(200, ["ok": true])
        }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "docker exact match")
        let port = rig.gateway.boundPort
        let promptsBefore = rig.gate.reasons.count
        try rig.db.setMeta(AppPreferences.dockerAccessKey, "on")

        let exact = try dockerCall(port: port, host: "host.docker.internal:\(port)", grant: grant)
        XCTAssertEqual(exact.status, 200)
        XCTAssertEqual(hits.count, 1, "the accepted call reached the upstream")

        // The Host header value arrives in the client's case, not lowercased.
        let loud = try dockerCall(port: port, host: "Host.Docker.Internal:\(port)", grant: grant)
        XCTAssertEqual(loud.status, 200)
        XCTAssertEqual(hits.count, 2)

        let wrongPort = port == 65535 ? 65534 : port + 1
        let refused: [(String, String)] = [
            ("the bare name with no port", "host.docker.internal"),
            ("the right name on the wrong port", "host.docker.internal:\(wrongPort)"),
            ("a look-alike domain", "host.docker.internal.evil.example:\(port)"),
            ("the Linux docker bridge address", "172.17.0.1:\(port)"),
            ("a foreign host", "evil.example:\(port)"),
        ]
        for (why, host) in refused {
            let row = try dockerCall(port: port, host: host, grant: grant)
            XCTAssertEqual(row.status, 403, why)
        }
        XCTAssertEqual(hits.count, 2, "no refused row reached the upstream")

        for host in ["127.0.0.1:\(port)", "localhost:\(port)"] {
            let loopback = try dockerCall(port: port, host: host, grant: grant)
            XCTAssertEqual(loopback.status, 200, "the loopback Host \(host) keeps working with the setting on")
        }
        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "no presence prompt anywhere in the matrix")
    }

    /// The pref is read per request, like the gateway's other per-call catalog reads:
    /// toggling it between requests changes the answer with no restart and no prompt.
    func testSettingIsReadPerRequestSoTogglingNeedsNoRestartOrPrompt() throws {
        let rig = try GatewayRig { _ in HTTPResponse.json(200, ["ok": true]) }
        defer { rig.stop() }
        try rig.key()
        let grant = try grantFor(rig.service, "demo", task: "docker toggle")
        let port = rig.gateway.boundPort
        let promptsBefore = rig.gate.reasons.count
        let dockerHost = "host.docker.internal:\(port)"

        XCTAssertEqual(try dockerCall(port: port, host: dockerHost, grant: grant).status, 403, "absent row means off")
        try rig.db.setMeta(AppPreferences.dockerAccessKey, "on")
        XCTAssertEqual(try dockerCall(port: port, host: dockerHost, grant: grant).status, 200, "on means accepted")
        try rig.db.setMeta(AppPreferences.dockerAccessKey, "off")
        XCTAssertEqual(try dockerCall(port: port, host: dockerHost, grant: grant).status, 403, "off means refused")
        try rig.db.deleteMeta(AppPreferences.dockerAccessKey)
        XCTAssertEqual(try dockerCall(port: port, host: dockerHost, grant: grant).status, 403, "a deleted row means off")
        try rig.db.setMeta(AppPreferences.dockerAccessKey, "on")
        XCTAssertEqual(try dockerCall(port: port, host: dockerHost, grant: grant).status, 200, "turning it back on")
        XCTAssertEqual(rig.gate.reasons.count, promptsBefore, "no presence prompt for a setting change")
    }

    /// The dashboard site shares `HTTPFrame.LoopbackOrigin` with the relay validation and
    /// the egress guards, so it must refuse the Docker Host in every state of the
    /// setting — the acceptance lives at the gateway call site only.
    func testDashboardSiteRefusesTheDockerHostInEverySettingState() throws {
        let (handler, service, _) = try makeHandler()
        func dashboard(_ host: String) -> (status: Int, error: String?) {
            let response = handler.handle(HTTPRequest(
                method: "GET", path: "/api/keys", query: [:],
                headers: ["host": host], body: Data(), serverPort: 12765
            ))
            let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            return (response.status, object?["error"] as? String)
        }
        let dockerHosts = [
            "host.docker.internal:12765",
            "host.docker.internal",
            "host.docker.internal:12799",
        ]
        let states: [(String, String?)] = [
            ("no pref row", nil),
            ("the pref on", "on"),
            ("the pref off", "off"),
        ]
        for (why, value) in states {
            if let value { try service.catalog.setMeta(AppPreferences.dockerAccessKey, value) }
            for host in dockerHosts {
                let (status, error) = dashboard(host)
                XCTAssertEqual(status, 403, "dashboard with \(why) and Host \(host)")
                XCTAssertEqual(error, "forbidden", "dashboard with \(why) and Host \(host)")
            }
            // Control: the same GET with the loopback Host is a normal 200 in every state.
            let (status, _) = dashboard("127.0.0.1:12765")
            XCTAssertEqual(status, 200, "dashboard with \(why) still serves the loopback Host")
        }
    }

    /// The shared loopback checks (`HTTPFrame.LoopbackOrigin`, the bind code) and
    /// `BindPolicy` are the dashboard's, the relay validation's and the egress guards'
    /// security surface. The Docker name must stay out of their source; `Gateway.swift`,
    /// the call site, is the only file allowed to know it. A source-level pin, because
    /// the behavior it guards is the absence of a widening.
    func testSharedLoopbackAndBindCodeNeverLearnTheDockerHost() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["HTTPFrame.swift", "Support.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("Sources/KeysCore/\(name)"),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("host.docker.internal"),
                "\(name) must never special-case the Docker host; the gateway call site owns it"
            )
        }
    }
}

/// A raw loopback socket carrying a fully forged header set: the docker host is never
/// dialed, only its spelling is written into the Host line.
private func sendRaw(port: UInt16, request: String) throws -> (status: Int, body: Data) {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw AppError.http("socket") }
    defer { Darwin.close(fd) }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
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
    let payload = Data(request.utf8)
    try payload.withUnsafeBytes { raw in
        var written = 0
        let total = payload.count
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        while written < total {
            let n = Darwin.write(fd, base + written, total - written)
            if n <= 0 { throw AppError.http("write") }
            written += n
        }
    }
    Darwin.shutdown(fd, SHUT_WR)
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
    let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    var body = Data()
    if let range = data.range(of: Data("\r\n\r\n".utf8)) {
        body = Data(data[range.upperBound...])
    }
    return (status, body)
}
