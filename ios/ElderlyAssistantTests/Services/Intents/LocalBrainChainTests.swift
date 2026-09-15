import XCTest
@testable import ElderlyAssistant

/// Local-brain availability chain (wiring regression, 2026-09-06): the
/// fine-tuned intent GGUF is not downloadable yet (placeholder artifact),
/// so the LLaMA stand-in must carry `IntentRouter`'s local slot. The
/// merge that first installed the fine-tuned model replaced the live
/// LLaMA wiring outright, leaving configurations that can't reach the
/// cloud (the on-device Whisper stack; Gemini without a key) with NO
/// interpretation layer — every utterance came back nil and the router
/// spoke the generic "didn't understand" re-prompt despite correct
/// transcription.
final class LocalBrainChainTests: XCTestCase {

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    @discardableResult
    private func interpret(_ chain: LocalBrainChain, _ transcript: String) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        chain.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
        return out
    }

    // MARK: - Chain mechanics

    func testIsAvailableWhenEitherBrainIsAvailable() {
        let none = StubCommandInterpreter(available: false, result: nil)
        XCTAssertFalse(LocalBrainChain(preferred: none, standIn: none).isAvailable)
        XCTAssertTrue(LocalBrainChain(
            preferred: none,
            standIn: StubCommandInterpreter(available: true, result: nil)).isAvailable)
        XCTAssertTrue(LocalBrainChain(
            preferred: StubCommandInterpreter(available: true, result: nil),
            standIn: none).isAvailable)
    }

    func testUsesPreferredWhenAvailable() {
        let answer = makeCommand(action: .setReminder, confidence: 0.9)
        let preferred = StubCommandInterpreter(result: answer)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        let chain = LocalBrainChain(preferred: preferred, standIn: standIn)

        XCTAssertEqual(interpret(chain, "भोलि बिहान ८ बजे सम्झाउनु"), answer)
        XCTAssertEqual(preferred.callCount, 1)
        XCTAssertEqual(standIn.callCount, 0,
                       "an available preferred brain must be the only brain consulted")
    }

    func testFallsBackToStandInWhenPreferredUnavailable() {
        // The production state while the fine-tuned GGUF is a placeholder:
        // a plain query must reach the cached LLaMA interpreter instead of
        // dying in the router as nil → generic re-prompt.
        let preferred = StubCommandInterpreter(available: false, result: nil)
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "भोलि घाम लाग्नेछ।")
        let standIn = StubCommandInterpreter(result: answer)
        let chain = LocalBrainChain(preferred: preferred, standIn: standIn)

        XCTAssertEqual(interpret(chain, "भोलि मौसम कस्तो हुन्छ?"), answer)
        XCTAssertEqual(standIn.callCount, 1)
        XCTAssertEqual(preferred.callCount, 0,
                       "an unavailable brain must not be asked")
    }

    func testPreferredAbstentionIsNotReroutedToStandIn() {
        // A fine-tuned brain's calibrated abstention (nil) belongs to the
        // router's escalation policy — the stand-in must not answer over
        // it, or an abstain that should escalate to Gemini never reaches
        // Gemini. Stand-in substitution is availability-only.
        let preferred = StubCommandInterpreter(result: nil)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        let chain = LocalBrainChain(preferred: preferred, standIn: standIn)

        XCTAssertNil(interpret(chain, "केही प्रश्न"))
        XCTAssertEqual(preferred.callCount, 1)
        XCTAssertEqual(standIn.callCount, 0)
    }

    func testYieldsNilWhenNothingIsAvailable() {
        let chain = LocalBrainChain(preferred: StubCommandInterpreter(available: false, result: nil),
                                    standIn: StubCommandInterpreter(available: false, result: nil))
        XCTAssertFalse(chain.isAvailable)
        XCTAssertNil(interpret(chain, "केही प्रश्न"))
    }

    // MARK: - [ENCODER-RUNTIME-CASCADE] the opt-in encoder-first rule

    private func cascadeChain(preferred: CommandInterpreter,
                              standIn: CommandInterpreter,
                              acceptThreshold: Double = 0.7,
                              onEscalated: @escaping (LocalBrainChain.EscalationReason) -> Void = { _ in })
    -> LocalBrainChain {
        LocalBrainChain(preferred: preferred,
                        standIn: standIn,
                        cascade: LocalBrainChain.Cascade(acceptThreshold: acceptThreshold,
                                                         onEscalated: onEscalated))
    }

    func testCascadeEscalatesAnAbstentionToTheStandInOnTheSameTurn() {
        // The opt-in half of the gap pinned above: with a cascade the
        // preferred brain's abstention does NOT end the turn — the
        // stand-in answers it, one completion, no second prompt.
        let preferred = StubCommandInterpreter(result: nil)
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "भोलि घाम लाग्नेछ।")
        let standIn = StubCommandInterpreter(result: answer)
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: preferred, standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), answer)
        XCTAssertEqual(preferred.callCount, 1)
        XCTAssertEqual(standIn.callCount, 1)
        XCTAssertEqual(reasons, [.abstained],
                       "an abstention is not a failure — the reason says which")
    }

    func testCascadeEscalatesASubBandAnswerToTheStandIn() {
        // Below the ACCEPT band the preferred answer is one the router
        // would have had to rephrase or drop; the cascade hands the turn
        // to the stand-in instead of spending the user's next exchange.
        let subBand = makeCommand(action: .query, confidence: 0.55, reply: "encoder")
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "standin")
        let preferred = StubCommandInterpreter(result: subBand)
        let standIn = StubCommandInterpreter(result: answer)
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: preferred, standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), answer)
        XCTAssertEqual(standIn.callCount, 1)
        XCTAssertEqual(reasons, [.subBandConfidence])
    }

    func testCascadeServesThePreferredAnswerAtTheBand() {
        // At the band the preferred brain IS the answer: the stand-in is
        // never asked, and nothing is reported as escalated.
        let atBand = makeCommand(action: .query, confidence: 0.7, reply: "encoder")
        let preferred = StubCommandInterpreter(result: atBand)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: preferred, standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), atBand)
        XCTAssertEqual(standIn.callCount, 0)
        XCTAssertTrue(reasons.isEmpty)
    }

    func testCascadeReportsAFailureAsFailed() {
        // Failure and abstention both arrive as nil; only the failure
        // carries a reason, and the escalation event says which it was.
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: FailingBrainStub(failureReason: "inference_timeout"),
                                 standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न")?.action, .query)
        XCTAssertEqual(reasons, [.failed])
    }

    func testCascadeDegradesToThePreferredAnswerWhenTheStandInIsUnavailable() {
        // A cascade can only ADD: with no configured brain to escalate to,
        // the preferred brain's own answer stands — byte-identical to the
        // standalone rule.
        let subBand = makeCommand(action: .query, confidence: 0.55, reply: "encoder")
        let standIn = StubCommandInterpreter(available: false,
                                             result: makeCommand(action: .query, confidence: 0.9))
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: StubCommandInterpreter(result: subBand),
                                 standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), subBand)
        XCTAssertEqual(standIn.callCount, 0, "an unavailable brain is never asked")
        XCTAssertTrue(reasons.isEmpty, "nothing escalated — there was nowhere to escalate to")
    }

    func testCascadeKeepsTheAvailabilityRuleWhenThePreferredBrainIsUnavailable() {
        // The cascade changes what happens AFTER a preferred answer, never
        // the availability substitution: an unavailable preferred brain is
        // not asked and nothing was "escalated".
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "standin")
        let standIn = StubCommandInterpreter(result: answer)
        let preferred = StubCommandInterpreter(available: false, result: nil)
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = cascadeChain(preferred: preferred, standIn: standIn) { reasons.append($0) }

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), answer)
        XCTAssertEqual(preferred.callCount, 0)
        XCTAssertEqual(standIn.callCount, 1)
        XCTAssertTrue(reasons.isEmpty)
    }

    func testDefaultChainStillPassesASubBandAnswerThrough() {
        // The opt-in boundary: without a cascade the chain keeps the
        // documented exclusive rule (and the open gap I-2 stays pinned) —
        // the encoder A/B cannot change shipped behaviour by accident.
        let subBand = makeCommand(action: .query, confidence: 0.55, reply: "encoder")
        let preferred = StubCommandInterpreter(result: subBand)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9))
        let chain = LocalBrainChain(preferred: preferred, standIn: standIn)

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), subBand)
        XCTAssertEqual(standIn.callCount, 0)
    }

    func testCascadeFailureReasonFollowsTheBrainThatServed() {
        // The router's LAT-EVIDENCE path reads `lastInferenceFailureReason`
        // through the chain: under a cascade it must describe the brain
        // that actually answered, or a stand-in answer would be logged as
        // the preferred brain's failure — and vice versa.
        let standIn = FailingBrainStub(failureReason: "truncated_json")
        let chain = cascadeChain(preferred: FailingBrainStub(failureReason: "inference_timeout"),
                                 standIn: standIn)
        XCTAssertNil(interpret(chain, "केही प्रश्न"))
        XCTAssertEqual(chain.lastInferenceFailureReason, "truncated_json",
                       "the stand-in served, so its failure is the honest one")
        XCTAssertEqual(standIn.callCount, 1)

        // …and the exclusive chain still reports the preferred brain's own
        // failure (the unchanged rule).
        let exclusive = LocalBrainChain(preferred: FailingBrainStub(failureReason: "inference_timeout"),
                                        standIn: FailingBrainStub(failureReason: "truncated_json"))
        XCTAssertNil(interpret(exclusive, "केही प्रश्न"))
        XCTAssertEqual(exclusive.lastInferenceFailureReason, "inference_timeout")
    }

    // MARK: - [TURN-TIMING-BREAKDOWN] the cascade's decision span
    //
    // The serve-or-escalate decision is the one piece of the local-brain
    // path no other stage covers: the breakdown must show it was taken,
    // not just that two brains ran. It is timed on BOTH outcomes (a
    // serve is a decision too), and it stays absent on a chain with no
    // cascade — a nil recorder and a cascade-less chain both change
    // nothing about the rule itself.

    func testCascadeDecisionStageIsRecordedWhenTheAnswerServes() {
        let recorder = TurnTimingRecorder()
        recorder.beginTurn()
        let atBand = makeCommand(action: .query, confidence: 0.7, reply: "encoder")
        let chain = LocalBrainChain(
            preferred: StubCommandInterpreter(result: atBand),
            standIn: StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9)),
            cascade: LocalBrainChain.Cascade(acceptThreshold: 0.7),
            timingRecorder: recorder)

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), atBand)
        let stages = recorder.finishTurn().stages
        XCTAssertEqual(stages.map(\.stage), ["cascade_decision"],
                       "the decision is timed even when it serves")
        XCTAssertTrue(stages.allSatisfy { $0.ms >= 0 },
                      "measured durations are non-negative")
    }

    func testCascadeDecisionStageIsRecordedWhenItEscalates() {
        let recorder = TurnTimingRecorder()
        recorder.beginTurn()
        var reasons: [LocalBrainChain.EscalationReason] = []
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "standin")
        let chain = LocalBrainChain(
            preferred: StubCommandInterpreter(result: nil),
            standIn: StubCommandInterpreter(result: answer),
            cascade: LocalBrainChain.Cascade(acceptThreshold: 0.7) { reasons.append($0) },
            timingRecorder: recorder)

        XCTAssertEqual(interpret(chain, "केही प्रश्न"), answer)
        XCTAssertEqual(reasons, [.abstained], "the escalation rule is unchanged")
        XCTAssertEqual(recorder.finishTurn().stages.map(\.stage),
                       ["cascade_decision"],
                       "an escalated turn still shows its decision")
    }

    func testChainWithoutACascadeRecordsNoDecisionStage() {
        let recorder = TurnTimingRecorder()
        recorder.beginTurn()
        let chain = LocalBrainChain(
            preferred: StubCommandInterpreter(result: nil),
            standIn: StubCommandInterpreter(result: makeCommand(action: .query, confidence: 0.9)),
            timingRecorder: recorder)

        XCTAssertNil(interpret(chain, "केही प्रश्न"),
                     "no cascade: the exclusive rule is byte-identical")
        XCTAssertTrue(recorder.finishTurn().isEmpty,
                      "a chain with no cascade has no decision to time")
    }

    // MARK: - [CORRECTION-ANYBRAIN] the local slot's input seam
    //
    // The composition point MOVED here from `IntentEncoderInterpreter`: the
    // corrected → canonicalized pair is now prepared once, at the slot's
    // input, and handed to whichever brain serves. These tests pin the chain's
    // half of that contract with a hand-built seam (no banks, no policies), so
    // they cannot be satisfied by a policy fixture that quietly did nothing.

    func testTheSeamRunsOnceAndAProducingBrainReadsThePair() {
        let seam = RecordingInputSeam(rewrite: { "\($0) भोलि" })
        let encoder = PreparedBrainSpy()
        let chain = LocalBrainChain(preferred: encoder,
                                    standIn: StubCommandInterpreter(result: nil),
                                    inputSeam: seam.seam)

        XCTAssertEqual(interpret(chain, "भोलि मौसम")?.action, .query)
        XCTAssertEqual(seam.callCount, 1, "one turn, one run of the layers")
        XCTAssertEqual(seam.inputs,
                       [InputSanitiser.sanitise("भोलि मौसम", level: .quarantine)],
                       "the seam is handed the SANITISED transcript")
        XCTAssertEqual(encoder.pairs.count, 1,
                       "a brain that consumes the pair is handed the pair")
        XCTAssertTrue(encoder.transcripts.isEmpty,
                      "…and never the plain-string entry point")
        XCTAssertEqual(encoder.pairs.first?.canonical, "भोलि मौसम भोलि")
        XCTAssertEqual(encoder.pairs.first?.modelInput, "भोलि मौसम भोलि")
    }

    func testAPlainBrainReadsThePreparedTextAndTheSafetyHalfIsTheOriginal() {
        let seam = RecordingInputSeam(rewrite: { "\($0) भोलि" })
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        // The picker brain's shape: a plain interpreter, with the slot served
        // by nobody else (the encoder-off configuration this change exists for).
        let chain = LocalBrainChain(preferred: StubCommandInterpreter(available: false,
                                                                      result: nil),
                                    standIn: standIn,
                                    inputSeam: seam.seam)

        XCTAssertNotNil(interpret(chain, "भोलि मौसम"))
        XCTAssertEqual(standIn.lastTranscript, "भोलि मौसम भोलि",
                       "a plain brain reads the prepared text once a layer "
                       + "rewrote something — the switch must be visible")
        XCTAssertEqual(seam.callCount, 1)
        XCTAssertEqual(seam.pairs.first?.original, "भोलि मौसम",
                       "D-1: the safety half is the sanitised transcript")
        XCTAssertEqual(seam.pairs.first?.safetyNetInput, "भोलि मौसम",
                       "…and no accessor hands the prepared form to it")
    }

    func testAnInertPairPassesTheTranscriptThroughByteIdentically() {
        // The shipped default (both switches absent): the seam runs, rewrites
        // nothing, and the brain must read exactly what the router was handed
        // — the pre-relocation string, byte for byte.
        let seam = RecordingInputSeam()
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        let chain = LocalBrainChain(preferred: StubCommandInterpreter(available: false,
                                                                      result: nil),
                                    standIn: standIn,
                                    inputSeam: seam.seam)

        XCTAssertNotNil(interpret(chain, "भोलि मौसम"))
        XCTAssertTrue(seam.pairs.first?.isIdentity == true)
        XCTAssertEqual(standIn.lastTranscript, "भोलि मौसम",
                       "an inert pair leaves the input untouched")
    }

    func testAChainWithoutASeamIsThePreRelocationPath() {
        // `inputSeam: nil` — the default, the nested chain's construction, and
        // every call site that predates the relocation. Nothing is prepared and
        // nothing changes, including for a brain that COULD consume a pair: it
        // is reached through the string entry point, which is where the
        // encoder's own direct-caller preparation lives.
        let consumer = PreparedBrainSpy()
        let chain = LocalBrainChain(preferred: consumer,
                                    standIn: StubCommandInterpreter(result: nil))

        XCTAssertNotNil(interpret(chain, "भोलि मौसम"))
        XCTAssertEqual(consumer.transcripts, ["भोलि मौसम"],
                       "no seam → no pair, so the string path is the one taken")
        XCTAssertTrue(consumer.pairs.isEmpty)
    }

    func testANestedChainDoesNotPrepareASecondTime() {
        // The shipped shape: the slot's outer chain owns the seam, the nested
        // chain in the `preferred` slot (`IntentEncoderWiring
        // .deferredEncoderPreference`) owns none. A seam on the nested chain
        // too — the mis-wiring this guards — must still run ZERO times when the
        // nested chain is entered with the pair, because the pair path never
        // consults a seam.
        let outerSeam = RecordingInputSeam(rewrite: { "\($0) भोलि" })
        let nestedSeam = RecordingInputSeam(rewrite: { "\($0) नेस्टेड" })
        let encoder = PreparedBrainSpy()
        let nested = LocalBrainChain(preferred: encoder,
                                     standIn: StubCommandInterpreter(result: nil),
                                     inputSeam: nestedSeam.seam)
        let slot = LocalBrainChain(preferred: nested,
                                   standIn: StubCommandInterpreter(result: nil),
                                   inputSeam: outerSeam.seam)

        XCTAssertNotNil(interpret(slot, "भोलि मौसम"))
        XCTAssertEqual(outerSeam.callCount, 1, "the slot ran the layers once")
        XCTAssertEqual(nestedSeam.callCount, 0,
                       "the nested chain must not run them again — a "
                       + "correct∘correct turn is not a turn any switch asks for")
        XCTAssertEqual(encoder.pairs.first?.canonical, "भोलि मौसम भोलि",
                       "the slot's pair is what reached the brain, verbatim")
    }

    func testACascadeTurnPreparesOnceAndFeedsBothBrainsTheSamePreparedText() {
        // Under a cascade BOTH brains answer the same turn — and they read the
        // SAME prepared input: escalation chooses a brain, never an input, or
        // the layer's effect would depend on which brain happened to serve.
        let seam = RecordingInputSeam(rewrite: { "\($0) भोलि" })
        let abstaining = PreparedBrainSpy(result: nil)
        let picker = StubCommandInterpreter(result: makeCommand(action: .query))
        var reasons: [LocalBrainChain.EscalationReason] = []
        let chain = LocalBrainChain(
            preferred: abstaining,
            standIn: picker,
            cascade: LocalBrainChain.Cascade(acceptThreshold: 0.7) { reasons.append($0) },
            inputSeam: seam.seam)

        XCTAssertNotNil(interpret(chain, "भोलि मौसम"))
        XCTAssertEqual(reasons, [.abstained])
        XCTAssertEqual(seam.callCount, 1, "one turn, one run — despite two brains")
        XCTAssertEqual(abstaining.pairs.first?.modelInput, "भोलि मौसम भोलि")
        XCTAssertEqual(picker.lastTranscript, "भोलि मौसम भोलि",
                       "the escalated brain reads the SAME prepared text")
    }

    // MARK: - Router integration (the reported bug's shape)

    func testOnDeviceStackPlainQueryAnsweredThroughRouter() {
        // The on-device Whisper configuration: cloudEnabled = false, local
        // brain = the chain with the fine-tuned model unavailable. A plain
        // open-domain query previously came back nil (→ the generic
        // "didn't understand" re-prompt); the stand-in must answer it.
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: NullObservabilityBus())
        router.cloudEnabled = false
        router.cloudBrain = StubCommandInterpreter(available: false, result: nil)
        let answer = makeCommand(action: .query, confidence: 0.9, reply: "भोलि घाम लाग्नेछ।")
        let standIn = StubCommandInterpreter(result: answer)
        router.localBrain = LocalBrainChain(
            preferred: StubCommandInterpreter(available: false, result: nil),
            standIn: standIn)

        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        router.interpret(transcript: "भोलि मौसम कस्तो हुन्छ?",
                         context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(out, answer,
                       "the on-device stack must reach a real interpreter for a plain query")
        XCTAssertEqual(standIn.callCount, 1)
    }
}

/// [ENCODER-RUNTIME-CASCADE] A brain that FAILED — nil plus an
/// `InterpreterFailureReporting` reason, the shape a timeout or truncated
/// output leaves behind (the distinction `IntentRouter`'s LAT-EVIDENCE
/// path reads). Configurable so two of them can be told apart.
private final class FailingBrainStub: CommandInterpreter, InterpreterFailureReporting {
    private let failureReason: String?
    private(set) var callCount = 0

    init(failureReason: String? = "inference_timeout") {
        self.failureReason = failureReason
    }

    var isAvailable: Bool { true }
    var lastInferenceFailureReason: String? { failureReason }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        callCount += 1
        DispatchQueue.main.async { completion(nil) }
    }
}
