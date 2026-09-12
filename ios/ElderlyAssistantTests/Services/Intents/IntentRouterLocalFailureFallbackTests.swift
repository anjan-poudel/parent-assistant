import XCTest
@testable import ElderlyAssistant

/// [LAT-EVIDENCE] (2026-09-12) Local-failure fallback tests: when the
/// local brain FAILS — inference timeout or truncated JSON, both after
/// the interpreter's own retry — the router escalates to the cloud with
/// the honest `local_failed_fallback` selection event instead of a bare
/// apology. An ABSTENTION keeps today's semantics exactly (pinned in
/// `IntentRouterCloudFirstTests.testCostBlockedSelectsLlamaEvenOnLocalAbstain`).
final class IntentRouterLocalFailureFallbackTests: XCTestCase {

    private func makeFailingLocalInterpreter(
        _ output: @escaping (Int) -> String,
        bus: ObservabilityBus) -> (LocalIntentInterpreter, () -> Int) {
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(modelStore: store, observabilityBus: bus)
        var calls = 0
        interpreter.generateOverride = { _ in
            calls += 1
            return output(calls)
        }
        return (interpreter, { calls })
    }

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func interpret(_ router: IntentRouter, _ transcript: String) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        router.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 3)
        return out
    }

    private func selectionEvents(_ bus: RecordingObservabilityBus) -> [ObservabilityEvent] {
        bus.events(named: "interpreter_selected")
    }

    func testTruncatedJSONRetriesThenFallsBackToCloudWithReasonEvent() {
        // The device-log class end to end: truncated JSON twice (the
        // retry fails too) → the fake cloud answers, with the honest
        // `local_failed_fallback` selection event. Never a bare apology.
        let bus = RecordingObservabilityBus()
        let (local, callCount) = makeFailingLocalInterpreter(
            { _ in "{\"action\": \"query\", \"conf" }, bus: bus)

        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = false   // legacy ladder
        router.cloudEnabled = true
        router.localBrain = local
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        let cloud = StubCommandInterpreter(result: cloudAnswer)
        router.cloudBrain = cloud

        let result = interpret(router, "मौसम कस्तो छ")
        XCTAssertEqual(callCount(), 2, "the interpreter retried once before reporting the failure")
        XCTAssertEqual(result, cloudAnswer, "the failed local brain escalates to the cloud")
        XCTAssertEqual(cloud.callCount, 1)

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metadata["interpreter"], "gemini")
        XCTAssertEqual(events[0].metadata["reason"], "local_failed_fallback")
    }

    func testRetrySuccessNeverTouchesCloud() {
        // The retry recovers on its own — the cloud is never called.
        let bus = RecordingObservabilityBus()
        let (local, callCount) = makeFailingLocalInterpreter({ calls in
            if calls == 1 { return "{\"action\": \"query\", \"conf" }
            return """
            {"action":"query","entryId":null,"contact":null,"time":null,
             "medication":null,"message":null,"callType":null,"requestedApp":null,
             "topic":null,"steps":null,"confidence":0.9,"reply":"ठीक छ"}
            """
        }, bus: bus)

        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = false
        router.cloudEnabled = true
        router.localBrain = local
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.cloudBrain = cloud

        let result = interpret(router, "मौसम कस्तो छ")
        XCTAssertEqual(result?.action, .query)
        XCTAssertEqual(callCount(), 2)
        XCTAssertEqual(cloud.callCount, 0, "the retry answered — no cloud call")
        XCTAssertTrue(selectionEvents(bus).isEmpty)
    }

    func testChainForwardsTheFailureReason() {
        // Production wiring wraps the interpreter in `LocalBrainChain` —
        // the chain must forward the failure so the router still sees it.
        let bus = RecordingObservabilityBus()
        let (local, _) = makeFailingLocalInterpreter(
            { _ in "{\"action\": \"query\", \"conf" }, bus: bus)
        let chain = LocalBrainChain(preferred: local, standIn: StubCommandInterpreter())

        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = false
        router.cloudEnabled = true
        router.localBrain = chain
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        router.cloudBrain = StubCommandInterpreter(result: cloudAnswer)

        XCTAssertEqual(interpret(router, "मौसम कस्तो छ"), cloudAnswer)

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metadata["reason"], "local_failed_fallback",
                       "the failure travels through the chain to the router")
    }

    func testCostBlockedLocalFailureKeepsTheBudget() {
        // Cloud-first mode, budget spent: the selector picked local
        // (cost_blocked) and the governor still blocks the failure
        // fallback — the cost cap is a hard guarantee. (The failure is
        // honest in the events; an apology is the only outcome when the
        // cloud it would call is budget-blocked.)
        let bus = RecordingObservabilityBus()
        let (local, _) = makeFailingLocalInterpreter(
            { _ in "{\"action\": \"query\", \"conf" }, bus: bus)
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = true
        router.cloudEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { false }
        router.localBrain = local
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.cloudBrain = cloud

        XCTAssertNil(interpret(router, "मौसम कस्तो छ"))
        XCTAssertEqual(cloud.callCount, 0,
                       "a budget-blocked turn never escalates to the cloud it declined")

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metadata["reason"], "cost_blocked",
                       "only the selector's original reason is logged")
    }

    func testAbstentionNeverFallsBackInTheCloudFirstLocalLane() {
        // An ABSTAINING local brain (plain nil, no failure report) keeps
        // the cloud-first lane's exact semantics — no escalation, no
        // failure event. Pins the failure-vs-abstention distinction.
        let bus = RecordingObservabilityBus()
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = true
        router.cloudEnabled = true
        router.geminiKeyConfigured = { false }
        router.geminiCostAllows = { true }
        router.localBrain = StubCommandInterpreter(result: nil)
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.cloudBrain = cloud

        XCTAssertNil(interpret(router, "open ended question"))
        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertEqual(selectionEvents(bus).count, 1,
                       "the selector's original no_key event only")
        XCTAssertEqual(selectionEvents(bus)[0].metadata["reason"], "no_key")
    }
}
