import XCTest
@testable import ElderlyAssistant

final class IntentRouterTests: XCTestCase {

    private func makeRouter() -> (IntentRouter, IntentCommandCache) {
        let cache = IntentCommandCache(storage: StubEncryptedStorage())
        return (IntentRouter(cache: cache, observabilityBus: NullObservabilityBus()), cache)
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

    // MARK: Layer 2 — cache

    func testCacheHitShortCircuitsBrains() {
        let (router, cache) = makeRouter()
        let cached = makeCommand(action: .call, contact: "maiya")
        cache.record(transcript: "maiya lai phone gara", command: cached)
        let local = StubCommandInterpreter(result: makeCommand(action: .none))
        let cloud = StubCommandInterpreter(result: makeCommand(action: .none))
        router.localBrain = local
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "maiya lai phone gara"), cached)
        XCTAssertEqual(local.callCount, 0, "cache hit must never reach the local brain")
        XCTAssertEqual(cloud.callCount, 0, "cache hit must never reach the cloud brain")
    }

    // MARK: Layer 3 — cloud preparse

    func testPreparseUsedWhenTranscriptMatches() {
        let (router, _) = makeRouter()
        let pre = makeCommand(action: .call, contact: "maiya")
        router.noteCloudPreparsed(transcript: "maiya lai phone gara", command: pre)
        let local = StubCommandInterpreter(result: makeCommand(action: .none))
        router.localBrain = local

        XCTAssertEqual(interpret(router, "maiya lai phone gara"), pre)
        XCTAssertEqual(local.callCount, 0)
    }

    func testPreparseIsSingleShot() {
        let (router, _) = makeRouter()
        let pre = makeCommand(action: .call, contact: "maiya")
        router.noteCloudPreparsed(transcript: "maiya lai phone gara", command: pre)
        _ = interpret(router, "maiya lai phone gara")

        // Second identical utterance: preparse already consumed — the
        // brains answer this one.
        let local = StubCommandInterpreter(result: makeCommand(action: .none, confidence: 0.9))
        router.localBrain = local
        let result = interpret(router, "maiya lai phone gara")
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(result?.action, InterpretedCommand.Action.none)
    }

    func testPreparseDoesNotBindToDifferentTranscript() {
        let (router, _) = makeRouter()
        router.noteCloudPreparsed(transcript: "utterance one",
                                  command: makeCommand(action: .call, contact: "maiya"))
        let local = StubCommandInterpreter(result: nil)
        router.localBrain = local
        XCTAssertNil(interpret(router, "a completely different utterance"))
        XCTAssertEqual(local.callCount, 1, "no preparse match → falls through to brains")
    }

    // MARK: Layers 4/5 — band policy + escalation

    func testAcceptThresholdDispatches() {
        let (router, _) = makeRouter()
        let cmd = makeCommand(action: .call, contact: "maiya", confidence: 0.85)
        router.localBrain = StubCommandInterpreter(result: cmd)
        XCTAssertEqual(interpret(router, "call maiya"), cmd)
    }

    func testRephraseBandDispatchesTierConfirmActions() {
        // 0.4–0.7 + a tier-`confirm` action: dispatched — the
        // confirmation question verifies the interpretation aloud (spec §4).
        let (router, _) = makeRouter()
        let cmd = makeCommand(action: .call, contact: "maiya", confidence: 0.5)
        router.localBrain = StubCommandInterpreter(result: cmd)
        XCTAssertEqual(interpret(router, "call maiya"), cmd)
    }

    func testRephraseBandDropsTierFreeActions() {
        // Same band, tier-`free` action: dropped (no confirmation exists
        // to catch a wrong guess) → falls through, here to nil.
        let (router, _) = makeRouter()
        router.localBrain = StubCommandInterpreter(result: makeCommand(action: .music, confidence: 0.5))
        XCTAssertNil(interpret(router, "play a bhajan maybe"))
    }

    func testBelowRephraseFloorAbstains() {
        let (router, _) = makeRouter()
        router.localBrain = StubCommandInterpreter(result: makeCommand(action: .call, confidence: 0.3))
        XCTAssertNil(interpret(router, "mumble mumble"))
    }

    func testLocalAbstainEscalatesToCloud() {
        let (router, _) = makeRouter()
        let local = StubCommandInterpreter(result: nil)
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        let cloud = StubCommandInterpreter(result: cloudAnswer)
        router.localBrain = local
        router.cloudBrain = cloud
        router.cloudEnabled = true

        XCTAssertEqual(interpret(router, "what is the weather tomorrow"), cloudAnswer)
        XCTAssertEqual(local.callCount, 1)
        XCTAssertEqual(cloud.callCount, 1)
    }

    func testCloudDisabledNeverConsultsCloud() {
        // The "if configured / allowed" invariant: with cloudEnabled off,
        // a local abstain is the end of the line — no cloud call, ever.
        let (router, _) = makeRouter()
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        router.localBrain = StubCommandInterpreter(result: nil)
        router.cloudBrain = cloud
        router.cloudEnabled = false

        XCTAssertNil(interpret(router, "open ended question"))
        XCTAssertEqual(cloud.callCount, 0)
    }

    func testUnavailableBrainsYieldNil() {
        let (router, _) = makeRouter()
        router.localBrain = StubCommandInterpreter(available: false, result: nil)
        router.cloudBrain = StubCommandInterpreter(available: false, result: nil)
        XCTAssertNil(interpret(router, "anything"))
    }

    func testNoBrainsAtAllYieldsNil() {
        let (router, _) = makeRouter()
        XCTAssertNil(interpret(router, "anything"))
    }
}
