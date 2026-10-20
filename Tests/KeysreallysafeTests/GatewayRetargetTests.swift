import Foundation
import XCTest
@testable import KeysCore

/// A local process holds the dashboard token and can rewrite routing metadata without a
/// prompt. These are the two ways that used to turn into a leaked key or an unprompted
/// authenticated call (SECURITY-REVIEW-multimodel.md, findings 1 and 2).
final class GatewayRetargetTests: XCTestCase {
    override func tearDown() {
        Providers.setOverlay([:])
        super.tearDown()
    }

    // MARK: finding 2: provider override plus the cached secret

    func testPathPrefixesRefuseQueryFragmentAndEscapes() throws {
        let (db, _) = try makeDB()
        let (service, _) = makeGatedService(db: db)
        for bad in ["v1/files#", "v1/files?x=1", "v1/%66iles", "v1 files", "v1/\u{00e9}"] {
            XCTAssertThrowsError(try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", pathPrefix: bad), bad)
            XCTAssertThrowsError(try GatewayClientToken.validatePathPrefix(bad), bad)
        }
        XCTAssertNoThrow(try service.addProvider(id: "acme", name: "Acme", host: "api.acme.dev", pathPrefix: "openai/v1"))
        XCTAssertEqual(try GatewayClientToken.validatePathPrefix("v1beta/models/gemini:generateContent"),
                       "v1beta/models/gemini:generateContent")
    }

    /// The exploit kept id and host and changed the rest of the record, so the cached secret
    /// went out on a request the user never approved.
    func testCheckReusesTheCachedSecretOnlyForTheSameProviderRecord() throws {
        final class Fetcher: ProviderCheckFetching, @unchecked Sendable {
            private(set) var requests: [URLRequest] = []
            func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                requests.append(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (Data(#"{"data":[]}"#.utf8), http)
            }
        }
        for (index, change) in ["path prefix", "auth header", "auth prefix"].enumerated() {
            Providers.setOverlay([:])
            let fetcher = Fetcher()
            let (db, _) = try makeDB()
            let (service, gate) = makeGatedService(db: db)
            service.checker = fetcher
            try service.add(name: "demo", provider: "openai", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.setGateway(name: "demo", enabled: true, host: nil)
            _ = try service.checkProvider(name: "demo")
            XCTAssertEqual(gate.reasons.count, 1, "an unchanged record reuses the unlock")

            switch index {
            case 0: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai", pathPrefix: "v1/files")
            case 1: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai",
                                            authHeader: "x-forward-to", pathPrefix: "v1")
            default: try service.addProvider(id: "openai", name: "OpenAI", host: "api.openai.com", api: "openai",
                                             authPrefix: "Token ", pathPrefix: "v1")
            }
            gate.error = .authCancelled
            XCTAssertThrowsError(try service.checkProvider(name: "demo"), change)
            XCTAssertEqual(gate.reasons.count, 2, change)
            XCTAssertEqual(fetcher.requests.count, 1, "no request without a fresh approval: \(change)")
        }
    }
}
