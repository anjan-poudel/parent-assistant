import XCTest
@testable import ElderlyAssistant

/// [LAT-M3] (2026-09-11) Cloud-first interpretation tests (latency plan
/// M3): with the mode armed, `IntentRouter` picks the CLOUD interpreter
/// for open-domain utterances whenever a key + budget allow, falls back
/// to the llama chain on cloud failure, and logs every selection as
/// `interpreter_selected` with an honest reason. The legacy local-first
/// ladder is pinned unchanged whenever the mode is off or the stack
/// declines cloud.
final class IntentRouterCloudFirstTests: XCTestCase {

    private func makeRouter(keyConfigured: Bool,
                            costAllows: Bool,
                            cloudFirstEnabled: Bool = true,
                            cloudEnabled: Bool = true) -> (IntentRouter, RecordingObservabilityBus) {
        let bus = RecordingObservabilityBus()
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = cloudFirstEnabled
        router.cloudEnabled = cloudEnabled
        router.geminiKeyConfigured = { keyConfigured }
        router.geminiCostAllows = { costAllows }
        return (router, bus)
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
        waitForExpectations(timeout: 2)
        return out
    }

    private func selectionEvents(_ bus: RecordingObservabilityBus) -> [ObservabilityEvent] {
        bus.events(named: "interpreter_selected")
    }

    /// Asserts the interpreter_selected event at `index` carries the
    /// given interpreter + reason metadata.
    private func assertSelection(_ event: ObservabilityEvent,
                                 interpreter: String,
                                 reason: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(event.metadata["interpreter"], interpreter, file: file, line: line)
        XCTAssertEqual(event.metadata["reason"], reason, file: file, line: line)
    }

    // MARK: Selection

    func testKeyAndBudgetSelectCloudFirst() {
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: true)
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        let cloud = StubCommandInterpreter(result: cloudAnswer)
        let local = StubCommandInterpreter(result: makeCommand(action: .none))
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "what is the weather tomorrow"), cloudAnswer)
        XCTAssertEqual(cloud.callCount, 1, "cloud must answer first")
        XCTAssertEqual(local.callCount, 0, "a successful cloud answer never touches llama")

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        assertSelection(events[0], interpreter: "gemini", reason: "cloud_configured")
    }

    func testNoKeySelectsLlama() {
        let (router, bus) = makeRouter(keyConfigured: false, costAllows: true)
        let localAnswer = makeCommand(action: .query, confidence: 0.9)
        let local = StubCommandInterpreter(result: localAnswer)
        let cloud = StubCommandInterpreter(result: makeCommand(action: .none))
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "what is the weather tomorrow"), localAnswer)
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(cloud.callCount, 0, "no key configured — cloud must never be called")

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        assertSelection(events[0], interpreter: "llama", reason: "no_key")
    }

    func testCostBlockedSelectsLlamaEvenOnLocalAbstain() {
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: false)
        let local = StubCommandInterpreter(result: nil)
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertNil(interpret(router, "open ended question"))
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(cloud.callCount, 0,
                       "budget-blocked turn must never escalate to the cloud it declined")

        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 1)
        assertSelection(events[0], interpreter: "llama", reason: "cost_blocked")
    }

    // MARK: Cloud failure fallback

    func testCloudFailureFallsBackToLlama() {
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: true)
        let localAnswer = makeCommand(action: .query, confidence: 0.9)
        let cloud = StubCommandInterpreter(result: nil)
        let local = StubCommandInterpreter(result: localAnswer)
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "what is the weather tomorrow"), localAnswer)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(local.callCount, 1, "a failed cloud attempt falls back to llama")

        // Two honest events: the original selection, then the fallback.
        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 2)
        assertSelection(events[0], interpreter: "gemini", reason: "cloud_configured")
        assertSelection(events[1], interpreter: "llama", reason: "cloud_failed_fallback")
    }

    func testCloudFailureWithoutLocalYieldsNil() {
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: true)
        router.cloudBrain = StubCommandInterpreter(result: nil)
        router.localBrain = StubCommandInterpreter(available: false, result: nil)

        XCTAssertNil(interpret(router, "anything"))
        let events = selectionEvents(bus)
        XCTAssertEqual(events.count, 2, "selection + fallback both logged")
        assertSelection(events[1], interpreter: "llama", reason: "cloud_failed_fallback")
    }

    func testCloudBelowRephraseFloorFallsBackToLlama() {
        // A cloud answer below the rephrase floor is a comprehension
        // failure — the fallback gives llama its chance.
        let (router, _) = makeRouter(keyConfigured: true, costAllows: true)
        let localAnswer = makeCommand(action: .query, confidence: 0.9)
        router.cloudBrain = StubCommandInterpreter(result: makeCommand(action: .call, confidence: 0.3))
        router.localBrain = StubCommandInterpreter(result: localAnswer)

        XCTAssertEqual(interpret(router, "open ended question"), localAnswer)
    }

    func testCloudMidBandTierFreeIsFinalNoLlamaRetry() {
        // A mid-band tier-free cloud answer is RETURNED as the rephrase
        // question — the cloud already answered, and a llama retry would
        // only add ~7 s of latency for a worse answer.
        let (router, _) = makeRouter(keyConfigured: true, costAllows: true)
        let midBand = makeCommand(action: .music, confidence: 0.5)
        router.cloudBrain = StubCommandInterpreter(result: midBand)
        let local = StubCommandInterpreter(result: makeCommand(action: .music, confidence: 0.9))
        router.localBrain = local

        XCTAssertEqual(interpret(router, "play a bhajan maybe"), midBand)
        XCTAssertEqual(local.callCount, 0)
    }

    // MARK: Invariants

    func testStackDecliningCloudKeepsLegacyLadder() {
        // The stack's cloud consent still gates the M3 mode: with
        // `cloudEnabled` false the legacy local-first ladder runs and
        // the cloud is never consulted — the on-device stack's privacy
        // contract is untouched.
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: true,
                                       cloudEnabled: false)
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.localBrain = StubCommandInterpreter(result: nil)
        router.cloudBrain = cloud

        XCTAssertNil(interpret(router, "open ended question"))
        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertTrue(selectionEvents(bus).isEmpty,
                      "no interpreter_selected events when cloud-first is not engaged")
    }

    func testLegacyLadderUnchangedWhenCloudFirstDisabled() {
        // The pre-M3 world pinned: with the mode off, local answers
        // first and its abstention escalates to cloud — even with a key
        // and budget open.
        let (router, bus) = makeRouter(keyConfigured: true, costAllows: true,
                                       cloudFirstEnabled: false)
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        let local = StubCommandInterpreter(result: nil)
        let cloud = StubCommandInterpreter(result: cloudAnswer)
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "what is the weather tomorrow"), cloudAnswer)
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertTrue(selectionEvents(bus).isEmpty)
    }
}
