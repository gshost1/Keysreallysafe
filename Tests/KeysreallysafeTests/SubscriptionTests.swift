import XCTest
@testable import KeysCore

/// The subscriptions the user pins to the Usage pane: strict validation, the token-protected
/// CRUD routes, the merge into /api/status that takes over a built-in tool's placeholder, and
/// the Factory subscription's write-through to the Droid window limits. Every subscription and
/// usage event here is invented and written straight into a temp catalog.
final class SubscriptionTests: XCTestCase {
    private func droidEvent(at iso: String, prompt: String, input: Int = 0, output: Int = 0) -> UsageEvent {
        UsageEvent(
            source: "droid-local", sessionId: "sess-\(prompt)", promptId: prompt, model: "claude-opus-5-5",
            occurredAt: iso, provider: "anthropic",
            inputTokens: input, outputTokens: output, cachedReadTokens: 0,
            cacheCreationTokens: 0, reasoningTokens: 0
        )
    }

    private func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// A handler over a fresh catalog, with the catalog itself so tests can reopen it.
    private func makeRig() throws -> (handler: APIHandler, service: KeysService, db: CatalogDB, dir: URL) {
        let (db, dir) = try makeDB()
        let (service, _, _) = makeService(db: db)
        let web = dir.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "<html><head></head><title>Keysreallysafe</title></html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        return (APIHandler(service: service, webRoot: web), service, db, dir)
    }

    @discardableResult
    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    // MARK: validation

    func testAddRefusesEveryWrongShape() throws {
        let (handler, _, _, _) = try makeRig()
        func post(_ object: [String: Any]) throws -> Int {
            try handle(handler, method: "POST", path: "/api/subscriptions", body: try body(object)).status
        }
        let good: [String: Any] = [
            "tool": "cursor", "name": NSNull(), "plan": "Pro",
            "limit_amount": 500.0, "limit_unit": "requests", "limit_period": "monthly",
        ]
        // The good shape passes, so every refusal below is about the field it changes.
        XCTAssertEqual(try post(good), 201)

        XCTAssertEqual(try post(["tool": "notion", "plan": "Pro"]), 400, "unknown tool")
        XCTAssertEqual(try post(["tool": 7, "plan": "Pro"]), 400, "tool is not a string")
        XCTAssertEqual(try post(["plan": "Pro"]), 400, "tool is required")
        XCTAssertEqual(try post(["tool": "custom", "plan": "Pro"]), 400, "custom needs a name")
        XCTAssertEqual(try post(["tool": "custom", "name": "   ", "plan": "Pro"]), 400, "blank name")
        XCTAssertEqual(try post(["tool": "custom", "name": "A\nB", "plan": "Pro"]), 400, "name is one line")
        XCTAssertEqual(
            try post(["tool": "custom", "name": String(repeating: "x", count: 65), "plan": "Pro"]),
            400, "name is capped at 64 characters"
        )
        XCTAssertEqual(try post(["tool": "cursor", "name": "My Cursor", "plan": "Pro"]), 400, "name is custom-only")
        XCTAssertEqual(try post(["tool": "cursor"]), 400, "plan is required")
        XCTAssertEqual(try post(["tool": "cursor", "plan": "  "]), 400, "blank plan")
        XCTAssertEqual(try post(["tool": "cursor", "plan": 42]), 400, "plan is not a string")
        XCTAssertEqual(try post(["tool": "cursor", "plan": "Two\nlines"]), 400, "plan is one line")
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": String(repeating: "y", count: 81)]),
            400, "plan is capped at 80 characters"
        )

        // The limit is one fact in three fields: all set, or none set.
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 500.0]), 400, "amount alone"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 500.0, "limit_unit": "requests"]),
            400, "amount and unit without a period"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_unit": "tokens", "limit_period": "weekly"]),
            400, "unit and period without an amount"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": NSNull(), "limit_unit": "tokens", "limit_period": "weekly"]),
            400, "a null amount next to set fields"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": NSNull()]), 400, "clearing one field"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 500.0, "limit_unit": "hours", "limit_period": "monthly"]),
            400, "unknown unit"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 500.0, "limit_unit": "tokens", "limit_period": "yearly"]),
            400, "unknown period"
        )
        for bad in [0.0, -5.0, 1e12, "500", true] {
            XCTAssertEqual(
                try post(["tool": "cursor", "plan": "Pro", "limit_amount": bad, "limit_unit": "usd", "limit_period": "monthly"]),
                400, "limit amount \(bad) is refused"
            )
        }
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 12.5, "limit_unit": "tokens", "limit_period": "monthly"]),
            400, "a tokens limit is a whole number"
        )
        XCTAssertEqual(
            try post(["tool": "cursor", "plan": "Pro", "limit_amount": 12.5, "limit_unit": "requests", "limit_period": "monthly"]),
            400, "a requests limit is a whole number"
        )
        // A fractional money or credit limit is a real thing people buy.
        XCTAssertEqual(
            try post([
                "tool": "cursor", "plan": "Pro",
                "limit_amount": 9.99, "limit_unit": "credits", "limit_period": "monthly",
            ]),
            201
        )

        // A body that is not a JSON object never reaches the service.
        XCTAssertEqual(
            try handle(handler, method: "POST", path: "/api/subscriptions", body: Data("nope".utf8)).status,
            400
        )
    }

    func testWritesNeedTheTokenAndReadsDoNot() throws {
        let (handler, _, _, _) = try makeRig()
        let add = ["tool": "cursor", "plan": "Pro"]
        XCTAssertEqual(
            try handle(handler, method: "POST", path: "/api/subscriptions", body: try body(add), token: false).status,
            403
        )
        XCTAssertEqual(try handle(handler, method: "GET", path: "/api/subscriptions", token: false).status, 200)

        XCTAssertEqual(try handle(handler, method: "POST", path: "/api/subscriptions", body: try body(add)).status, 201)
        let list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        let id = try XCTUnwrap(((list["subscriptions"] as? [[String: Any]])?.first)?["id"] as? String)
        XCTAssertEqual(
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(["plan": "Ultra"]), token: false).status,
            403
        )
        XCTAssertEqual(
            try handle(handler, method: "DELETE", path: "/api/subscriptions/\(id)", token: false).status,
            403
        )
    }

    // MARK: the CRUD lifecycle

    func testLifecycleAddsListsEditsAndRemoves() throws {
        let (handler, _, db, dir) = try makeRig()
        let add = try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "cursor", "name": NSNull(), "plan": "  Pro  ",
            "limit_amount": 500.0, "limit_unit": "requests", "limit_period": "monthly",
        ]))
        XCTAssertEqual(add.status, 201)
        let record = try json(add)
        let id = try XCTUnwrap(record["id"] as? String)
        XCTAssertEqual(record["tool"] as? String, "cursor")
        XCTAssertEqual(record["name"] as? String, "")
        XCTAssertEqual(record["plan"] as? String, "Pro", "the plan is trimmed before it is stored")
        XCTAssertEqual(record["limit_amount"] as? Double, 500.0)
        XCTAssertEqual(record["limit_unit"] as? String, "requests")
        XCTAssertEqual(record["limit_period"] as? String, "monthly")
        XCTAssertNotNil(record["created_at"] as? String)

        // A plan-only PATCH leaves the limit alone; the limit group replaces or clears as one.
        var patch = try json(try handle(
            handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(["plan": "Ultra"])
        ))
        XCTAssertEqual(patch["plan"] as? String, "Ultra")
        XCTAssertEqual(patch["limit_amount"] as? Double, 500.0, "an untouched limit stays")

        patch = try json(try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body([
            "limit_amount": 250_000.0, "limit_unit": "tokens", "limit_period": "weekly",
        ])))
        XCTAssertEqual(patch["limit_unit"] as? String, "tokens")
        XCTAssertEqual(patch["limit_period"] as? String, "weekly")

        XCTAssertEqual(
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(["limit_amount": 250.0])).status,
            400, "a partial limit edit is refused"
        )
        XCTAssertEqual(
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(["tool": "gemini"])).status,
            400, "the tool cannot change; remove and add again"
        )

        patch = try json(try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body([
            "limit_amount": NSNull(), "limit_unit": NSNull(), "limit_period": NSNull(),
        ])))
        XCTAssertTrue(patch["limit_amount"] is NSNull, "three nulls clear the one limit")
        XCTAssertTrue(patch["limit_unit"] is NSNull)
        XCTAssertTrue(patch["limit_period"] is NSNull)

        // The list is the same rows, in creation order, and they survive a reopen.
        let list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        XCTAssertEqual((list["subscriptions"] as? [[String: Any]])?.count, 1)
        let reopened = try CatalogDB(path: dir.appendingPathComponent("catalog.db"))
        XCTAssertEqual(try reopened.listSubscriptions().map(\.plan), ["Ultra"])

        let remove = try handle(handler, method: "DELETE", path: "/api/subscriptions/\(id)")
        XCTAssertEqual(remove.status, 200)
        XCTAssertEqual(try json(remove)["removed"] as? String, id)
        XCTAssertEqual((try json(try handle(handler, method: "GET", path: "/api/subscriptions"))["subscriptions"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(
            try handle(handler, method: "DELETE", path: "/api/subscriptions/\(id)").status, 404,
            "a second remove is a missing row, not a repeat"
        )
        XCTAssertEqual(
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(["plan": "X"])).status,
            404
        )
        XCTAssertEqual(try handle(handler, method: "PUT", path: "/api/subscriptions/\(id)").status, 405)
        XCTAssertEqual(
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)/extra", body: try body(["plan": "X"])).status,
            400, "an id-shaped path only"
        )
        _ = db
    }

    // MARK: the /api/status merge

    func testStatusMergesSubscriptionRowsAndHidesThePlaceholders() throws {
        let (handler, service, _, _) = try makeRig()
        XCTAssertEqual(try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "cursor", "plan": "Pro",
            "limit_amount": 500.0, "limit_unit": "requests", "limit_period": "monthly",
        ])).status, 201)
        XCTAssertEqual(try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "custom", "name": "Windsurf", "plan": "Team",
        ])).status, 201)

        var status = try service.liveStatus()
        let cursor = try XCTUnwrap(status.plans.first { $0.source == "cursor" })
        XCTAssertNotNil(cursor.subscriptionId, "the subscription row takes over the cursor slot")
        XCTAssertEqual(status.plans.filter { $0.source == "cursor" }.count, 1, "the placeholder is replaced, not joined")
        XCTAssertEqual(cursor.title, "Cursor")
        XCTAssertEqual(cursor.plan, "Pro")
        XCTAssertEqual(cursor.limitText, "500 requests per month")
        XCTAssertEqual(cursor.usageNote, "usage not tracked locally")
        // No invented usage: a subscription row carries no measured figure of any kind.
        XCTAssertNil(cursor.weeklyTokens)
        XCTAssertNil(cursor.weeklyPct)
        XCTAssertNil(cursor.weeklyUsd)
        XCTAssertNil(cursor.weeklyPrompts)
        let cursorJSON = cursor.jsonObject()
        XCTAssertEqual(cursorJSON["kind"] as? String, "subscription")
        XCTAssertNotNil(cursorJSON["subscription_id"])
        XCTAssertEqual(cursorJSON["limit_text"] as? String, "500 requests per month")

        let custom = try XCTUnwrap(status.plans.first { $0.source == "custom" })
        XCTAssertEqual(custom.title, "Windsurf", "a custom tool is named by its own name")
        XCTAssertEqual(custom.plan, "Team")
        XCTAssertNil(custom.limitText, "a subscription without a limit shows no limit text")

        // The other built-ins keep their placeholders until they are subscribed to.
        for tool in ["gemini", "copilot", "perplexity", "chatgpt"] {
            let row = try XCTUnwrap(status.plans.first { $0.source == tool })
            XCTAssertNil(row.subscriptionId, "\(tool) keeps its placeholder")
            XCTAssertNil(row.plan)
        }

        // The subscription row sits where the placeholder sat, so the pane's order stays put.
        let sources = status.plans.map(\.source)
        let cursorIndex = try XCTUnwrap(sources.firstIndex(of: "cursor"))
        XCTAssertLessThan(try XCTUnwrap(sources.firstIndex(of: "droid")), cursorIndex)
        XCTAssertLessThan(cursorIndex, try XCTUnwrap(sources.firstIndex(of: "gemini")))
        // A custom tool has no placeholder to take over, so it goes after the built-ins.
        XCTAssertGreaterThan(try XCTUnwrap(sources.firstIndex(of: "custom")), cursorIndex)

        // Removing the subscription restores the placeholder it was hiding.
        XCTAssertEqual(try handle(handler, method: "DELETE", path: "/api/subscriptions/\(cursor.subscriptionId!)").status, 200)
        status = try service.liveStatus()
        let restored = try XCTUnwrap(status.plans.first { $0.source == "cursor" })
        XCTAssertNil(restored.subscriptionId)
        XCTAssertNil(restored.plan)
        XCTAssertNil(restored.limitText)
    }

    func testLimitTextFormatsPlainUnitsAndPeriods() throws {
        func text(_ amount: Double, _ unit: String, _ period: String) throws -> String {
            let limit = try XCTUnwrap(try Subscriptions.resolveLimit(
                Subscriptions.LimitInput(
                    amount: amount, amountPresent: true,
                    unit: unit, unitPresent: true,
                    period: period, periodPresent: true
                ),
                existing: nil
            ))
            return Subscriptions.limitText(limit)
        }
        XCTAssertEqual(try text(100_000, "tokens", "weekly"), "100,000 tokens per week")
        XCTAssertEqual(try text(500, "requests", "monthly"), "500 requests per month")
        XCTAssertEqual(try text(200, "usd", "monthly"), "$200 per month")
        XCTAssertEqual(try text(12.5, "usd", "five_hour"), "$12.50 per 5-hour window")
        XCTAssertEqual(try text(9.99, "credits", "monthly"), "9.99 credits per month")
    }

    // MARK: the Factory subscription

    func testFactoryAttachesToTheDroidRowAndDrivesItsWindowLimit() throws {
        let (handler, service, db, _) = try makeRig()
        _ = try db.insertUsage(droidEvent(at: UTC.iso(Date()), prompt: "f1", input: 1000, output: 100))
        XCTAssertEqual(try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "factory", "plan": "Max",
            "limit_amount": 100_000.0, "limit_unit": "tokens", "limit_period": "monthly",
        ])).status, 201)

        var status = try service.liveStatus()
        let droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertEqual(droid.plan, "Max", "the Factory plan names the Droid row")
        XCTAssertNotNil(droid.subscriptionId)
        XCTAssertEqual(droid.monthlyLimit, 100_000, "a Factory token limit is the Droid Month window limit")
        XCTAssertNotNil(droid.monthlyPct)
        XCTAssertEqual(status.plans.filter { $0.source == "droid" }.count, 1)
        XCTAssertNil(status.plans.first { $0.source == "factory" }, "no separate Factory row appears")
        XCTAssertNil(droid.limitText, "a token limit shows as the window meter, not as text")

        // usage_limits is where the window limit lives; the subscription wrote straight through.
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.window), ["monthly"])
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.tokens), [100_000])

        // A second Factory subscription would fight over the same Droid row.
        XCTAssertEqual(
            try handle(handler, method: "POST", path: "/api/subscriptions", body: try body(["tool": "factory", "plan": "Pro"])).status,
            400
        )
    }

    func testFactoryEditsAndRemovalsKeepUsageLimitsConsistent() throws {
        let (handler, service, db, _) = try makeRig()
        _ = try db.insertUsage(droidEvent(at: UTC.iso(Date()), prompt: "f1", input: 1000, output: 100))
        _ = try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "factory", "plan": "Max",
            "limit_amount": 100_000.0, "limit_unit": "tokens", "limit_period": "monthly",
        ]))
        let list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        let id = try XCTUnwrap(((list["subscriptions"] as? [[String: Any]])?.first)?["id"] as? String)

        func patch(_ object: [String: Any]) throws -> HTTPResponse {
            try handle(handler, method: "PATCH", path: "/api/subscriptions/\(id)", body: try body(object))
        }

        // Editing the amount moves the one window limit.
        XCTAssertEqual(try patch(["limit_amount": 200_000.0, "limit_unit": "tokens", "limit_period": "monthly"]).status, 200)
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.tokens), [200_000])

        // Moving the limit to another window clears the old one.
        XCTAssertEqual(try patch(["limit_amount": 50_000.0, "limit_unit": "tokens", "limit_period": "weekly"]).status, 200)
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.window), ["weekly"])

        // A non-token Factory limit is display text only; the window limit is gone with it.
        let usd = try json(try patch(["limit_amount": 200.0, "limit_unit": "usd", "limit_period": "monthly"]))
        XCTAssertTrue(usd["limit_amount"] as? Double == 200.0)
        XCTAssertEqual(try db.usageLimits(source: "droid").count, 0, "no token limit remains to steer a meter")
        var status = try service.liveStatus()
        var droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertEqual(droid.plan, "Max")
        XCTAssertEqual(droid.limitText, "$200 per month")
        XCTAssertNil(droid.monthlyLimit)
        XCTAssertNil(droid.monthlyPct)

        // Removing the subscription clears both the plan and any window limit it still held.
        XCTAssertEqual(try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "factory", "plan": "Max", "limit_amount": 100.0, "limit_unit": "usd", "limit_period": "monthly",
        ])).status, 400, "still one Factory subscription")
        XCTAssertEqual(try patch(["limit_amount": 100_000.0, "limit_unit": "tokens", "limit_period": "monthly"]).status, 200)
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.window), ["monthly"])
        XCTAssertEqual(try handle(handler, method: "DELETE", path: "/api/subscriptions/\(id)").status, 200)
        XCTAssertEqual(try db.usageLimits(source: "droid").count, 0, "the window limit the subscription drove is cleared")
        status = try service.liveStatus()
        droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertNil(droid.plan)
        XCTAssertNil(droid.subscriptionId)
        XCTAssertNil(droid.monthlyLimit)
    }

    func testSetLimitsAndTheFactorySubscriptionAreOneFact() throws {
        let (handler, service, db, _) = try makeRig()
        _ = try db.insertUsage(droidEvent(at: UTC.iso(Date()), prompt: "f1", input: 1000, output: 100))
        _ = try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "factory", "plan": "Max",
            "limit_amount": 100_000.0, "limit_unit": "tokens", "limit_period": "monthly",
        ]))

        // The Droid row's own Set limits control writes the same window; the subscription,
        // which is the same fact seen from the dialog, follows it.
        XCTAssertEqual(
            try handle(handler, method: "PUT", path: "/api/limits/droid/monthly", body: try body(["tokens": 150_000])).status,
            200
        )
        var list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        var sub = try XCTUnwrap((list["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(sub["limit_amount"] as? Double, 150_000, "the subscription's amount is the saved window limit")
        XCTAssertEqual(sub["limit_unit"] as? String, "tokens")
        XCTAssertEqual(sub["limit_period"] as? String, "monthly")

        // Clearing the window through Set limits clears the subscription's limit too.
        XCTAssertEqual(try handle(handler, method: "DELETE", path: "/api/limits/droid/monthly").status, 200)
        list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        sub = try XCTUnwrap((list["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertTrue(sub["limit_amount"] is NSNull)
        XCTAssertTrue(sub["limit_unit"] is NSNull)
        XCTAssertTrue(sub["limit_period"] is NSNull)
        var status = try service.liveStatus()
        var droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertEqual(droid.plan, "Max", "the plan survives; only the limit was the shared fact")
        XCTAssertNil(droid.monthlyLimit)

        // A window the subscription does not name is its own fact and leaves the row alone.
        _ = try handle(handler, method: "PATCH", path: "/api/subscriptions/\(sub["id"] as! String)", body: try body([
            "limit_amount": 80_000.0, "limit_unit": "tokens", "limit_period": "monthly",
        ]))
        XCTAssertEqual(
            try handle(handler, method: "PUT", path: "/api/limits/droid/weekly", body: try body(["tokens": 10_000])).status,
            200
        )
        list = try json(try handle(handler, method: "GET", path: "/api/subscriptions"))
        sub = try XCTUnwrap((list["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(sub["limit_period"] as? String, "monthly")
        XCTAssertEqual(sub["limit_amount"] as? Double, 80_000)

        // A subscription for a tool Keysrs cannot measure never touches the window limits.
        _ = try handle(handler, method: "POST", path: "/api/subscriptions", body: try body([
            "tool": "cursor", "plan": "Pro", "limit_amount": 500.0, "limit_unit": "tokens", "limit_period": "monthly",
        ]))
        XCTAssertEqual(try db.usageLimits(source: "droid").map(\.window).sorted(), ["monthly", "weekly"])
        status = try service.liveStatus()
        droid = try XCTUnwrap(status.plans.first { $0.source == "droid" })
        XCTAssertEqual(droid.monthlyLimit, 80_000, "the Factory subscription's window limit is the Droid one")
        let cursor = try XCTUnwrap(status.plans.first { $0.source == "cursor" })
        XCTAssertEqual(cursor.limitText, "500 tokens per month")
        XCTAssertNil(cursor.monthlyLimit, "a Cursor subscription steers nothing: its usage is not measured here")
    }
}
