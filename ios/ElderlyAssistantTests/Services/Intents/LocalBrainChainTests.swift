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
