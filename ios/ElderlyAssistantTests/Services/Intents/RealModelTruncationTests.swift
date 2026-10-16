import XCTest
@testable import ElderlyAssistant

/// [TRUNCATION-FIX] End-to-end proof on the REAL llama.cpp path. The
/// "दशैँ कहिले हो" device session truncated mid-JSON twice because the
/// composed prompt (template + schema wrapper) filled the shared
/// 1,024-token context; every unit test until now replaced the model
/// with `generateOverride`, so the real path was never exercised. This
/// test runs the ACTUAL fine-tuned GGUF and asserts a complete
/// generation: the model loads, inference finishes, and the output is
/// never the truncated-JSON class.
///
/// Skips when the GGUF is not cached on this machine (same skip idiom
/// as the bundled-manual tests): place
/// `intent-ne-qwen-s42-q4_k_m.gguf` (models v12 release) in the app's
/// Application Support/Models directory.
final class RealModelTruncationTests: XCTestCase {

    func testDashainQuestionGeneratesCompleteJSONOnTheRealModel() throws {
        let bus = RecordingObservabilityBus()
        let store = try ModelStore(observabilityBus: bus)
        guard store.isCached(ModelCatalog.intentNepali1B) else {
            throw XCTSkip("intent-ne-qwen-s42-q4_k_m.gguf not cached — "
                          + "download from the models v12 release to run the real-model gate")
        }

        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: bus,
            // The 10 s production bound is calibrated for the DEVICE
            // GPU; the x86_64 simulator's translated Metal is several
            // times slower, so this gate runs a sim-appropriate bound
            // to prove the real path can produce a COMPLETE answer.
            config: .init(confidenceThreshold: 0.4, maxTokens: 192,
                          timeoutSeconds: 150))
        let done = expectation(description: "real-model interpret completes")
        var result: InterpretedCommand?
        interpreter.interpret(
            transcript: "दशैँ कहिले हो",
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
        ) { command in
            result = command
            done.fulfill()
        }
        wait(for: [done], timeout: 300)
        if !bus.eventTypes.isEmpty {
            print("RealModelTruncationTests events: "
                  + bus.eventTypes.joined(separator: ", "))
        }

        XCTAssertTrue(bus.contains("model_loaded"), "the real model must load")
        XCTAssertFalse(bus.contains("inference_truncated"),
                       "a complete generation must never end truncated "
                       + "(the exact device failure this fix removes)")
        XCTAssertFalse(bus.contains("inference_prompt_overflow"),
                       "the composed prompt must fit the guarded budget")
        XCTAssertFalse(bus.contains("model_load_denied"),
                       "the ledger must admit the 1B brain on this host")
        // The strongest proof: a parsed command. A low-confidence
        // abstention is NOT a truncation and stays legal; but if the
        // model answered, the JSON was complete enough to parse AND to
        // carry real reply text — not a cut-off string.
        if let result {
            XCTAssertFalse(result.reply.isEmpty,
                           "the reply must be real text, not a cut-off string")
        }
    }
}
