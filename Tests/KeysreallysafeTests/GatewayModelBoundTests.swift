import Foundation
import XCTest
@testable import KeysCore

/// The request `model` (and the evaluation `ai-model-id` header) is caller text that lands in
/// the usage catalog and on the dashboard, so it is bounded before it is recorded.
final class GatewayModelBoundTests: XCTestCase {
    private let usage = Data(#"{"usage":{"prompt_tokens":10,"completion_tokens":2}}"#.utf8)

    private func requestModel(_ model: String, api: String = "openai") -> String? {
        let body = try! JSONSerialization.data(withJSONObject: ["model": model])
        return GatewayUsageParser.parse(
            api: api, requestBody: body, responseBody: usage
        ).model
    }

    func testRealModelIdsPassUnchanged() {
        for id in [
            "gpt-4.1",
            "claude-opus-5-5",
            "anthropic/claude-3.5-sonnet:beta",
            "anthropic.claude-3-5-sonnet-20240620-v1:0",
            "models/gemini-2.0-flash",
            "accounts/fireworks/models/llama-v3p1-405b-instruct",
            "llama3:8b",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo+free",
            "claude-sonnet-4@20250514",
        ] {
            XCTAssertEqual(requestModel(id), id)
        }
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(requestModel("  gpt-4.1\n"), "gpt-4.1")
    }

    func testLengthCapIs128Characters() {
        let atCap = String(repeating: "a", count: GatewayUsageParser.maxModelIdLength)
        XCTAssertEqual(requestModel(atCap), atCap)
        XCTAssertNil(requestModel(atCap + "b"))
        XCTAssertNil(requestModel(String(repeating: "x", count: 100_000)))
    }

    func testTextOutsideTheModelIdSetIsDropped() {
        for text in [
            "",
            "   ",
            "gpt 4.1",
            "gpt-4.1\u{0}",
            "gpt-4.1\nforged log line",
            "gpt-4.1\u{1b}[31m",
            "<img src=x onerror=alert(1)>",
            "gpt-4.1\"; DROP TABLE usage;--",
            "gpt\u{2011}4.1",  // non-breaking hyphen, a look-alike
            "gpt-4.1\u{202e}",  // bidi override
            "модель",
            "gpt-4.1😀",
        ] {
            XCTAssertNil(requestModel(text), text.debugDescription)
        }
    }

    func testNonStringModelIsDropped() {
        for body in [#"{"model":42}"#, #"{"model":["gpt-4.1"]}"#, #"{"model":null}"#] {
            let parsed = GatewayUsageParser.parse(
                api: "anthropic", requestBody: Data(body.utf8),
                responseBody: Data()
            )
            XCTAssertNil(parsed.model, body)
        }
    }

    func testEvaluationHeaderIsBoundedTheSameWay() {
        func header(_ value: String?) -> String? {
            GatewayUsageParser.parse(
                api: "vercel-evaluation", requestBody: Data(),
                responseBody: Data(#"{"answers":{},"usage":{"inputTokens":1}}"#.utf8),
                requestModel: value
            ).model
        }
        XCTAssertEqual(header(" typesafe-ai/jev "), "typesafe-ai/jev")
        XCTAssertNil(header(String(repeating: "m", count: 129)))
        XCTAssertNil(header("typesafe-ai/jev<script>"))
        XCTAssertNil(header(nil))
    }

    func testResponseReportedModelStillWins() {
        // The bound applies to caller text; the model the provider reports is used as before.
        let body = Data(#"{"model":"not a model id"}"#.utf8)
        let response = Data(#"{"model":"gpt-4.1-2025-04-14","usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
        let parsed = GatewayUsageParser.parse(
            api: "openai", requestBody: body, responseBody: response
        )
        XCTAssertEqual(parsed.model, "gpt-4.1-2025-04-14")
        XCTAssertEqual(parsed.inputTokens, 1)
    }

    func testStreamingFallbackToRequestModelIsBounded() {
        let stream = Data("data: {\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4}}\n\ndata: [DONE]\n\n".utf8)
        func streamed(_ model: String) -> GatewayParsedUsage {
            let tee = GatewayTee(api: "openai")
            tee.setContentType("text/event-stream")
            tee.append(stream)
            let body = try! JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
            return tee.result(requestBody: body)
        }
        XCTAssertEqual(streamed("gpt-4.1").model, "gpt-4.1")
        let rejected = streamed(String(repeating: "z", count: 500))
        XCTAssertNil(rejected.model)
        XCTAssertEqual(rejected.inputTokens, 3)
        XCTAssertEqual(rejected.outputTokens, 4)
    }
}
