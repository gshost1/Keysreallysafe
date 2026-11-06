import Foundation
import XCTest
@testable import KeysCore

/// The doorbell (docs/relay.md, The doorbell): its key, its wire, how often a ring may become
/// a prompt, its socket loop, and how the service answers a ring. Offline: fake sockets, a
/// recording presence gate, memory secret stores and a temp catalog.
final class RelayDoorbellTests: XCTestCase {
    private let origin = URL(string: "https://keysrs-relay.me.workers.dev")!

    func testKillAfterEnabledCheckCannotReopenRelay() throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func next(_ service: KeysService) -> Date {
                let count = lock.withLock { calls += 1; return calls }
                if count == 4 { _ = service.stopRelayForRevoke() }
                return Date()
            }
        }
        let (service, _, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer { service.stopRelay(); service.stopGateway() }
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")
        _ = try service.setDoorbell(enabled: true)
        let clock = Clock()
        let answer = service.answerDoorbellRing(ring(client: token), now: { clock.next(service) })
        XCTAssertFalse(service.doorbellEnabled())
        XCTAssertFalse(service.relayHost.isOn, "kill completed before start, so relay must remain off")
        XCTAssertNotEqual(answer, .on)
    }

    // MARK: key and wire

    func testTheKeyMatchesTheWorkersDerivation() {
        // Relay/test/doorbell.test.js pins the same value for the same secret.
        XCTAssertEqual(
            DoorbellKey.derive(relaySecret: "ksfr_test_secret_for_offline_tests_only"),
            "ksfd_8e08d4cec8c525bf32a5136871d5275b83fa0d3a18a18025153bc5108c6a5bcf"
        )
        let key = DoorbellKey.derive(relaySecret: RelaySecret.generate())
        XCTAssertTrue(DoorbellKey.looksLikeKey(key))
        XCTAssertFalse(DoorbellKey.looksLikeKey(RelaySecret.generate()))
        XCTAssertNotEqual(DoorbellKey.derive(relaySecret: RelaySecret.generate()), key, "a new relay secret, a new key")
    }

    func testTheListenURLAndRingURLLiveUnderADotPathNoKeyNameCanTake() {
        XCTAssertEqual(RelayURL.doorbellListenURL(origin).absoluteString, "wss://keysrs-relay.me.workers.dev/.keysrs/doorbell/listen")
        XCTAssertEqual(RelayURL.doorbellListenURL(URL(string: "http://127.0.0.1:8787")!).absoluteString, "ws://127.0.0.1:8787/.keysrs/doorbell/listen")
        XCTAssertEqual(RelayURL.doorbellRingURL(origin), "https://keysrs-relay.me.workers.dev/.keysrs/doorbell")
        XCTAssertThrowsError(try KeyName.validate(".keysrs"))
    }

    func testARingParsesOnlyInTheWorkersShape() {
        let id = String(repeating: "a1", count: 16)
        let hash = String(repeating: "0f", count: 32)
        XCTAssertEqual(
            DoorbellRing.parse(#"{"type":"ring","id":"\#(id)","client":"\#(hash)","pair":null}"#),
            DoorbellRing(id: id, clientHash: hash, pairHash: nil)
        )
        XCTAssertNil(DoorbellRing.parse(#"{"type":"answer","id":"\#(id)"}"#))
        XCTAssertNil(DoorbellRing.parse(#"{"type":"ring","id":"short"}"#))
        XCTAssertNil(DoorbellRing.parse("pong"))
        // A hash in any other shape is no hash: it cannot match a stored one anyway.
        let upper = DoorbellRing.parse(#"{"type":"ring","id":"\#(id)","client":"\#(hash.uppercased())","pair":"ksfp_x"}"#)
        XCTAssertEqual(upper, DoorbellRing(id: id, clientHash: nil, pairHash: nil))
    }

    func testAnAnswerCarriesTheResultAndOnlyWhatTheWorkerPassesOn() throws {
        func object(_ answer: DoorbellAnswer) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.json(id: "abc").utf8)) as? [String: Any])
        }
        XCTAssertEqual(try object(.on) as NSDictionary, ["type": "answer", "id": "abc", "result": "on"])
        XCTAssertEqual(try object(.notNow(retryAfter: 42))["retry_after"] as? Int, 42)
        XCTAssertEqual(try object(.away)["result"] as? String, "away")
        let long = try object(.unavailable(String(repeating: "x", count: 1000)))
        XCTAssertEqual((long["message"] as? String)?.count, 400)
    }

    // MARK: gate

    func testTheGateAllowsOnePromptAtATimeAndBacksOffAfterADecline() {
        let gate = DoorbellGate(cooldown: 600, perHour: 6)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(gate.admit(now: t0), .prompt)
        XCTAssertEqual(gate.admit(now: t0), .pending, "a prompt is up")
        gate.finished(declined: true, now: t0)
        XCTAssertEqual(gate.admit(now: t0.addingTimeInterval(1)), .notNow(retryAfter: 599))
        XCTAssertEqual(gate.admit(now: t0.addingTimeInterval(600)), .prompt, "the cooldown is over")
        gate.finished(declined: false, now: t0.addingTimeInterval(600))
    }

    func testTheGateCapsPromptsPerHour() {
        let gate = DoorbellGate(cooldown: 600, perHour: 3)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<3 {
            let at = t0.addingTimeInterval(Double(i) * 60)
            XCTAssertEqual(gate.admit(now: at), .prompt)
            gate.finished(declined: false, now: at)
        }
        XCTAssertEqual(gate.admit(now: t0.addingTimeInterval(200)), .notNow(retryAfter: 3400))
        XCTAssertEqual(gate.admit(now: t0.addingTimeInterval(3600)), .prompt, "the first prompt aged out")
    }

    // MARK: client

    func testTheClientListensWithTheKeyAnswersRingsAndIgnoresTheRest() async throws {
        let socket = FakeRelaySocket()
        let dialer = FakeRelayDialer([.success(socket)])
        let seen = LockedValue<[DoorbellRing]>([])
        let key = DoorbellKey.derive(relaySecret: RelaySecret.generate())
        let client = DoorbellClient(
            options: .init(url: origin, key: key, pingInterval: 3600),
            dialer: dialer,
            log: { _ in },
            onRing: { ring in
                seen.set(seen.get() + [ring])
                return .declined
            },
            sleep: { _ in throw CancellationError() }
        )
        let task = Task { await client.run() }
        let id = String(repeating: "b2", count: 16)
        socket.pushText("pong")
        socket.pushText("not json")
        socket.pushText(#"{"type":"ring","id":"\#(id)","client":null,"pair":null}"#)
        try await until("the answer") { socket.pings.contains { $0.contains(id) } }
        let answer = try XCTUnwrap(socket.pings.first { $0.contains(id) })
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? NSDictionary,
            ["type": "answer", "id": id, "result": "declined"]
        )
        XCTAssertEqual(seen.get().map(\.id), [id], "only the ring reached onRing")
        let attempt = try XCTUnwrap(dialer.attempts.first)
        XCTAssertEqual(attempt.0, RelayURL.doorbellListenURL(origin))
        XCTAssertEqual(attempt.1["Authorization"], "Bearer \(key)")
        XCTAssertEqual(attempt.1[RelayProtocol.protocolHeader], RelayProtocol.version)
        socket.drop()
        await task.value
    }

    func testRingsBeyondTheBoundsAreAnsweredNotNowWithoutReachingTheService() async throws {
        let socket = FakeRelaySocket()
        let release = DispatchSemaphore(value: 0)
        let calls = LockedValue(0)
        var options = DoorbellClient.Options(url: origin, key: DoorbellKey.derive(relaySecret: RelaySecret.generate()), pingInterval: 3600)
        options.maxConcurrentRings = 1
        let client = DoorbellClient(
            options: options,
            dialer: FakeRelayDialer([.success(socket)]),
            log: { _ in },
            onRing: { _ in
                calls.set(calls.get() + 1)
                release.wait()
                return .on
            },
            sleep: { _ in throw CancellationError() }
        )
        let task = Task { await client.run() }
        let first = String(repeating: "c3", count: 16), second = String(repeating: "d4", count: 16)
        socket.pushText(#"{"type":"ring","id":"\#(first)","client":null,"pair":null}"#)
        try await until("the first ring to be handled") { calls.get() == 1 }
        socket.pushText(#"{"type":"ring","id":"\#(second)","client":null,"pair":null}"#)
        try await until("the second ring's answer") { socket.pings.contains { $0.contains(second) } }
        XCTAssertTrue(try XCTUnwrap(socket.pings.first { $0.contains(second) }).contains("not_now"))
        XCTAssertEqual(calls.get(), 1, "the second ring never reached the service")
        release.signal()
        try await until("the first ring's answer") { socket.pings.contains { $0.contains(first) } }
        socket.drop()
        await task.value
    }

    func testEachDialReadsTheStoredKeyAndAGoneKeyEndsTheLoop() async throws {
        let first = FakeRelaySocket()
        let dialer = FakeRelayDialer([.success(first), .success(FakeRelaySocket())])
        let stored = LockedValue<(url: URL, key: String)?>((origin, DoorbellKey.derive(relaySecret: RelaySecret.generate())))
        let lines = LockedValue<[String]>([])
        let client = DoorbellClient(
            options: .init(url: origin, key: "ksfd_stale", pingInterval: 3600),
            dialer: dialer,
            log: { line in lines.set(lines.get() + [line]) },
            onRing: { _ in .refused },
            current: { stored.get() },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) }
        )
        let task = Task { await client.run() }
        try await until("the first dial") { dialer.attempts.count == 1 }
        XCTAssertEqual(dialer.attempts[0].1["Authorization"], "Bearer \(stored.get()!.key)", "the stored key, not the one it started with")
        stored.set(nil)
        first.drop()
        await task.value
        XCTAssertEqual(dialer.attempts.count, 1, "no dial once the key is gone")
        XCTAssertTrue(lines.get().contains { $0.contains("no longer stored") }, "\(lines.get())")
    }

    func testAFourOhOneSaysTheTwoSidesHoldDifferentSecrets() async throws {
        let lines = LockedValue<[String]>([])
        let client = DoorbellClient(
            options: .init(url: origin, key: DoorbellKey.derive(relaySecret: RelaySecret.generate())),
            dialer: FakeRelayDialer([.failure(RelayDialError(status: 401, message: "refused"))]),
            log: { line in lines.set(lines.get() + [line]) },
            onRing: { _ in .refused },
            sleep: { _ in throw CancellationError() }
        )
        await client.run()
        XCTAssertTrue(lines.get().contains { $0.contains("different relay secrets") }, "\(lines.get())")
        XCTAssertTrue(client.state.lastError?.contains("keys relay doorbell on") == true)
    }

    // MARK: service

    private func service() throws -> (KeysService, RecordingPresenceGate, FakeRelayDialer) {
        let (db, _) = try makeDB()
        let (service, gate) = makeGatedService(db: db)
        // Sockets nobody feeds stay open, as a listening doorbell does.
        let dialer = FakeRelayDialer((0..<8).map { _ in .success(FakeRelaySocket()) })
        service.doorbellHost = DoorbellHost(log: { _ in }, dialer: dialer)
        service.relayHost = RelayHost(log: { _ in }, dialer: FakeRelayDialer([]), blocker: FakeSleepBlocker())
        service.screenLocked = { false }
        return (service, gate, dialer)
    }

    private func ring(client: String? = nil, pair: String? = nil) -> DoorbellRing {
        DoorbellRing(
            id: Hex.encode(SecureRandom.bytes(16)),
            clientHash: client.map(GatewayClientToken.hash),
            pairHash: pair.map(RelayPairing.hash)
        )
    }

    func testTurningTheDoorbellOnTakesOneTouchIDAndKeepsOnlyTheDerivedKey() throws {
        let (service, gate, _) = try service()
        XCTAssertThrowsError(try service.setDoorbell(enabled: true)) { error in
            XCTAssertTrue("\(error)".contains("no relay is set up"), "\(error)")
        }
        XCTAssertEqual(gate.reasons, [], "refused before Touch ID")
        let (_, secret) = try service.setupRelay(url: origin.absoluteString)
        let before = gate.reasons.count

        let report = try service.setDoorbell(enabled: true)
        XCTAssertEqual(gate.reasons.count, before + 1)
        XCTAssertEqual(gate.reasons.last, "let agents ring this Mac to ask for the relay at keysrs-relay.me.workers.dev")
        XCTAssertTrue(report.doorbellEnabled)
        XCTAssertTrue(report.doorbell.on)
        XCTAssertFalse(report.host.on, "the doorbell turns nothing else on")
        let stored = try XCTUnwrap(service.relaySecrets).get(name: DoorbellKey.accountName)
        XCTAssertEqual(stored, DoorbellKey.derive(relaySecret: secret))
        XCTAssertEqual(try XCTUnwrap(service.relaySecrets).get(name: KeysService.relaySecretName), secret, "the relay secret stays as it was")

        let json = APIHandler.relayJSON(service.relayReport())
        XCTAssertEqual(json["doorbell"] as? Bool, true)
        XCTAssertFalse(String(decoding: try JSONValue.data(json), as: UTF8.self).contains(stored), "the key never leaves in the status")

        _ = try service.setDoorbell(enabled: true)
        XCTAssertEqual(gate.reasons.count, before + 1, "already on asks for nothing")

        let off = try service.setDoorbell(enabled: false)
        XCTAssertFalse(off.doorbellEnabled)
        XCTAssertFalse(off.doorbell.on)
        XCTAssertThrowsError(try XCTUnwrap(service.relaySecrets).get(name: DoorbellKey.accountName), "off forgets the key")
        XCTAssertEqual(gate.reasons.count, before + 1, "off asks for nothing")
    }

    func testACancelledPromptLeavesTheDoorbellOff() throws {
        let (service, gate, _) = try service()
        _ = try service.setupRelay(url: origin.absoluteString)
        gate.error = .authCancelled
        XCTAssertThrowsError(try service.setDoorbell(enabled: true))
        XCTAssertFalse(service.doorbellEnabled())
        XCTAssertFalse(service.doorbellHost.isOn)
        XCTAssertThrowsError(try XCTUnwrap(service.relaySecrets).get(name: DoorbellKey.accountName))
    }

    func testLaunchStartsALeftOnDoorbellWithoutTouchID() throws {
        let (service, gate, dialer) = try service()
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.setDoorbell(enabled: true)
        service.doorbellHost.stop()
        let prompts = gate.reasons.count

        service.startDoorbellAtLaunch()
        XCTAssertTrue(service.doorbellHost.isOn)
        XCTAssertEqual(gate.reasons.count, prompts)
        _ = dialer

        // A missing key leaves it off rather than asking at launch.
        service.doorbellHost.stop()
        try XCTUnwrap(service.relaySecrets).delete(name: DoorbellKey.accountName)
        service.startDoorbellAtLaunch()
        XCTAssertFalse(service.doorbellHost.isOn)
        XCTAssertEqual(gate.reasons.count, prompts)
    }

    func testSetupAgainRederivesTheKeyAndResetForgetsIt() throws {
        let (service, _, _) = try service()
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.setDoorbell(enabled: true)
        let (_, second) = try service.setupRelay(url: origin.absoluteString)
        XCTAssertEqual(try XCTUnwrap(service.relaySecrets).get(name: DoorbellKey.accountName), DoorbellKey.derive(relaySecret: second))
        XCTAssertTrue(service.doorbellHost.isOn)

        try service.resetRelay()
        XCTAssertFalse(service.doorbellEnabled())
        XCTAssertFalse(service.doorbellHost.isOn)
        XCTAssertThrowsError(try XCTUnwrap(service.relaySecrets).get(name: DoorbellKey.accountName))
    }

    func testTheKillSwitchTurnsTheDoorbellOff() throws {
        let (service, _, _) = try service()
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.setDoorbell(enabled: true)
        service.stopRelayForRevoke()
        XCTAssertFalse(service.doorbellEnabled())
        XCTAssertFalse(service.doorbellHost.isOn)
    }

    func testARingWithoutALiveCredentialAsksNobody() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        // Issuing takes its own Touch ID; the rings below must take none.
        let (token, issued) = try service.issueGatewayClient(name: "demo", label: "ci box")
        _ = try service.revokeGatewayClient(name: "demo", id: issued.id)
        let (expiring, _) = try service.issueGatewayClient(name: "demo", label: "old", days: 1)
        let prompts = gate.reasons.count

        XCTAssertEqual(service.answerDoorbellRing(ring()), .refused)
        XCTAssertEqual(service.answerDoorbellRing(ring(client: GatewayClientToken.generate())), .refused, "never issued")
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .refused, "revoked")
        XCTAssertEqual(service.answerDoorbellRing(ring(client: expiring), now: { Date().addingTimeInterval(2 * 86_400) }), .refused, "expired")
        XCTAssertEqual(gate.reasons.count, prompts)
    }

    func testARingFromALiveTokenAsksForTouchIDNamingItAndTurnsTheRelayOn() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
        }
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "hetzner box")
        _ = try service.setDoorbell(enabled: true)

        service.screenLocked = { true }
        let prompts = gate.reasons.count
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .away)
        XCTAssertEqual(gate.reasons.count, prompts, "nobody to ask behind the lock screen")

        service.screenLocked = { false }
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .on)
        XCTAssertEqual(gate.reasons.last, #"turn on the relay: "hetzner box" asked through keysrs-relay.me.workers.dev"#)
        XCTAssertTrue(service.relayHost.isOn)

        let after = gate.reasons.count
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .on, "already on")
        XCTAssertEqual(gate.reasons.count, after)
    }

    func testADeclineIsAnsweredAndTheNextRingWaitsOutTheCooldown() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer { service.stopGateway() }
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")

        gate.error = .authCancelled
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .declined)
        XCTAssertFalse(service.relayHost.isOn)
        let prompts = gate.reasons.count
        guard case .notNow(let after) = service.answerDoorbellRing(ring(client: token)) else {
            return XCTFail("the next ring is held back")
        }
        XCTAssertGreaterThan(after, 500)
        XCTAssertEqual(gate.reasons.count, prompts)
    }

    func testARelayThatCannotStartIsUnavailableWithTheMacsOwnReason() throws {
        let (service, _, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")
        // No gateway in this process: the relay would have nothing to reach.
        guard case .unavailable(let message) = service.answerDoorbellRing(ring(client: token)) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(message.contains("gateway is not running"), message)
    }

    /// The kill switch run while the prompt is up must not wait for it (it would deadlock
    /// here if the prompt held the relay's toggle lock), and an approval that lands after it
    /// turns nothing on.
    func testTheKillSwitchDuringThePromptWinsOverTheApproval() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
        }
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")
        _ = try service.setDoorbell(enabled: true)
        gate.duringNextPrompt = { _ = service.stopRelayForRevoke() }

        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .unavailable("the doorbell was turned off on the Mac"))
        XCTAssertFalse(service.relayHost.isOn)
        XCTAssertFalse(service.doorbellEnabled())
    }

    func testATokenRevokedWhileThePromptIsUpTurnsNothingOn() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
        }
        let (token, issued) = try service.issueGatewayClient(name: "demo", label: "agent")
        _ = try service.setDoorbell(enabled: true)
        gate.duringNextPrompt = { _ = try service.revokeGatewayClient(name: "demo", id: issued.id) }

        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .refused)
        XCTAssertFalse(service.relayHost.isOn)
    }

    /// Run each shutdown both inside Touch ID and at the old check/start boundary. The
    /// synchronous callbacks make the ordering deterministic, and deadlock if a prompt
    /// accidentally holds relayToggleLock. No scheduler delays are needed.
    private func assertPendingApprovalCancelled(
        expected: DoorbellAnswer,
        _ cancel: @escaping @Sendable (KeysService, Int64) throws -> Void
    ) throws {
        for atFinalCheck in [false, true] {
            let (service, gate, _) = try service()
            try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
            _ = try service.setupRelay(url: origin.absoluteString)
            _ = try service.startGateway(port: 0)
            defer {
                service.stopRelay()
                service.stopGateway()
                service.stopDoorbell()
            }
            let (token, issued) = try service.issueGatewayClient(name: "demo", label: "agent")
            _ = try service.setDoorbell(enabled: true)
            let calls = LockedValue(0)
            let failure = LockedValue<String?>(nil)
            if !atFinalCheck {
                gate.duringNextPrompt = { try cancel(service, issued.id) }
            }
            let answer = service.answerDoorbellRing(ring(client: token), now: {
                let count = calls.get() + 1
                calls.set(count)
                // Initial ringer, gate admission, gate completion, final validation.
                if atFinalCheck && count == 4 {
                    do { try cancel(service, issued.id) }
                    catch { failure.set(String(describing: error)) }
                }
                return Date()
            })
            XCTAssertNil(failure.get())
            XCTAssertEqual(answer, expected, "at final check: \(atFinalCheck)")
            XCTAssertFalse(service.relayHost.isOn)
        }
    }

    func testDoorbellOffCancelsAPendingApproval() throws {
        try assertPendingApprovalCancelled(expected: .unavailable("the doorbell was turned off on the Mac")) { service, _ in
            _ = try service.setDoorbell(enabled: false)
        }
    }

    func testDoorbellOffThenOnDoesNotReuseTheOldApproval() throws {
        try assertPendingApprovalCancelled(expected: .unavailable("the relay was turned off on the Mac")) { service, _ in
            _ = try service.setDoorbell(enabled: false)
            _ = try service.setDoorbell(enabled: true)
        }
    }

    func testRelayOffCancelsAPendingApprovalWhileLeavingTheDoorbellEnabled() throws {
        try assertPendingApprovalCancelled(expected: .unavailable("the relay was turned off on the Mac")) { service, _ in
            _ = try service.setRelay(enabled: false)
            XCTAssertTrue(service.doorbellEnabled())
        }
    }

    func testProcessShutdownCancelsAPendingApproval() throws {
        try assertPendingApprovalCancelled(expected: .unavailable("the relay was turned off on the Mac")) { service, _ in
            service.stopRelay()
        }
    }

    func testRevokeAllCancelsAPendingApproval() throws {
        try assertPendingApprovalCancelled(expected: .unavailable("the doorbell was turned off on the Mac")) { service, _ in
            let handler = APIHandler(service: service, webRoot: service.catalog.path.deletingLastPathComponent())
            let response = handle(handler, method: "POST", path: "/api/mcp/revoke_all", body: Data("{}".utf8))
            XCTAssertEqual(response.status, 200)
            XCTAssertTrue(try service.catalog.allGatewayClients().allSatisfy { $0.revokedAt != nil })
        }
    }

    func testTokenRevokeCancelsAPendingApprovalAtBothBoundaries() throws {
        try assertPendingApprovalCancelled(expected: .refused) { service, id in
            _ = try service.revokeGatewayClient(name: "demo", id: id)
        }
    }

    func testPairingRevokeDuringThePromptTurnsNothingOn() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
            service.stopDoorbell()
        }
        let (pair, _) = try service.issueRelayPairing(label: "agent", keys: ["demo"])
        _ = try service.setDoorbell(enabled: true)
        gate.duringNextPrompt = { _ = try service.revokeRelayPairing("agent") }
        XCTAssertEqual(service.answerDoorbellRing(ring(pair: pair)), .refused)
        XCTAssertFalse(service.relayHost.isOn)
    }

    func testRingsTheRelayCouldNotServeAreNotCountedAgainstTheHour() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")
        _ = try service.setDoorbell(enabled: true)
        let prompts = gate.reasons.count
        for _ in 0..<(DoorbellGate.defaultPerHour + 2) {
            guard case .unavailable = service.answerDoorbellRing(ring(client: token)) else { return XCTFail("no gateway yet") }
        }
        XCTAssertEqual(gate.reasons.count, prompts, "nobody was asked")
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
        }
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .on, "the hour's allowance is untouched")
    }

    func testADoorbellWhoseLoopEndedIsOffAndStartsAgain() async throws {
        let host = DoorbellHost(log: { _ in }, dialer: FakeRelayDialer([]))
        host.start(origin: origin, key: "ksfd_x", current: { nil }, onRing: { _ in .refused })
        try await until("the loop to end by itself") { !host.isOn }
        host.start(origin: origin, key: "ksfd_x", onRing: { _ in .refused })
        XCTAssertTrue(host.isOn)
        host.stop()
    }

    func testWhilePairingIsRequiredOnlyAPairingRings() throws {
        let (service, gate, _) = try service()
        try service.add(name: "demo", provider: "anthropic", kind: "runtime", notes: "", secret: fixtureSecret)
        _ = try service.setupRelay(url: origin.absoluteString)
        _ = try service.startGateway(port: 0)
        defer {
            service.stopRelay()
            service.stopGateway()
        }
        let (token, _) = try service.issueGatewayClient(name: "demo", label: "agent")
        let (credential, _) = try service.issueRelayPairing(label: "paired box", keys: ["demo"])
        try service.setRelayPairingRequired(true)
        _ = try service.setDoorbell(enabled: true)
        let prompts = gate.reasons.count

        XCTAssertEqual(service.answerDoorbellRing(ring(client: token)), .refused)
        XCTAssertEqual(gate.reasons.count, prompts)
        XCTAssertEqual(service.answerDoorbellRing(ring(client: token, pair: credential)), .on)
        XCTAssertTrue(gate.reasons.last?.contains(#""paired box""#) == true, "\(gate.reasons)")
    }

    func testTheAPITogglesTheDoorbellAndReportsIt() throws {
        let (service, gate, _) = try service()
        _ = try service.setupRelay(url: origin.absoluteString)
        let web = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let handler = APIHandler(service: service, webRoot: web)
        let on = handle(handler, method: "POST", path: "/api/relay", body: try JSONValue.data(["doorbell": true]))
        XCTAssertEqual(on.status, 200, String(decoding: on.body, as: UTF8.self))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: on.body) as? [String: Any])
        XCTAssertEqual(object["doorbell"] as? Bool, true)
        XCTAssertNotNil(object["doorbell_state"] as? String)
        XCTAssertTrue(gate.reasons.last?.hasPrefix("let agents ring this Mac") == true)

        let bad = handle(handler, method: "POST", path: "/api/relay", body: try JSONValue.data(["doorbell": "yes"]))
        XCTAssertEqual(bad.status, 400)
        let off = handle(handler, method: "POST", path: "/api/relay", body: try JSONValue.data(["doorbell": false]))
        XCTAssertEqual(off.status, 200)
        XCTAssertFalse(service.doorbellEnabled())
    }

    func testStatusLines() {
        XCTAssertEqual(RelayCommand.doorbellLine(enabled: false, app: nil), "off")
        XCTAssertEqual(RelayCommand.doorbellLine(enabled: true, app: nil), "on (Keysrs is not running, so nobody is listening)")
        XCTAssertEqual(RelayCommand.doorbellLine(enabled: true, app: ["doorbell_state": "connected"]), "on, listening")
        XCTAssertEqual(
            RelayCommand.doorbellLine(enabled: true, app: ["doorbell_state": "waiting", "doorbell_last_error": "401"]),
            "on, not connected; retrying (401)"
        )
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            if Date() > deadline { throw RelayDialError(status: nil, message: "timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
