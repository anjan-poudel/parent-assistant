import XCTest
@testable import ElderlyAssistant

/// [LAT-EVIDENCE] (2026-09-12) First-use prewarm tests: the device log
/// showed the first transcribe paying the one-time CoreML/ANE
/// specialization INSIDE the turn (`transcribed duration_ms=10633` for
/// 2.7 s audio) when the boot warm was skipped. Pinned rules:
///  - at listening start, with the weights NOT resident (boot warm
///    skipped / post-turn hold lapsed) and the engine available, a
///    background prepare runs BEFORE the first transcribe (non-gating),
///  - no prewarm when the weights are resident,
///  - the simulator skips it (the CPU-only prepare never helps a sim
///    conversation — the boot warm doctrine).
final class WhisperFirstUsePrewarmTests: XCTestCase {

    // MARK: - Pure policy

    func testSkippedBootWarmPrewarms() {
        XCTAssertTrue(WhisperFirstUsePrewarmPolicy.shouldPrewarm(
            isModelLoaded: false, isAvailable: true, isSimulator: false))
    }

    func testResidentWeightsSkipThePrewarm() {
        XCTAssertFalse(WhisperFirstUsePrewarmPolicy.shouldPrewarm(
            isModelLoaded: true, isAvailable: true, isSimulator: false),
            "the warm/hold kept the weights resident — nothing to prewarm")
    }

    func testUnavailableEngineSkipsThePrewarm() {
        XCTAssertFalse(WhisperFirstUsePrewarmPolicy.shouldPrewarm(
            isModelLoaded: false, isAvailable: false, isSimulator: false))
    }

    func testSimulatorSkipsThePrewarm() {
        XCTAssertFalse(WhisperFirstUsePrewarmPolicy.shouldPrewarm(
            isModelLoaded: false, isAvailable: true, isSimulator: true),
            "the CPU-only prepare is a minutes-scale load that never helps a sim conversation")
    }

    // MARK: - Listening-start seam (fake)

    func testListeningStartPrewarmsBeforeAnyTranscribe() {
        // The boot warm was skipped: the model is NOT resident when the
        // session starts. The prewarm seam (overridden — the policy
        // decision is real, only the load is replaced) must fire at
        // listening start, i.e. BEFORE the first transcribe is even
        // possible (transcription only exists after `finish()`).
        let recognizer = WhisperKitSpeechRecognizer(
            observabilityBus: NullObservabilityBus())
        // Bench hook: makes `isAvailable` true without a real artifact.
        recognizer.modelFolderURL = URL(fileURLWithPath: "/tmp/bench-model")
        var prewarmCount = 0
        recognizer.firstUsePrewarmOverride = { prewarmCount += 1 }

        let done = expectation(description: "listening session ends")
        recognizer.startListening(timeout: 30) { result in
            if case .failure(.cancelled) = result { done.fulfill() }
        }
        XCTAssertEqual(prewarmCount, 1,
                       "listening start prewarms once when the boot warm was skipped")
        XCTAssertFalse(recognizer.isModelLoaded)
        recognizer.cancel()
        wait(for: [done], timeout: 2)
    }

    func testPrewarmEmitsHonestEventOnTheRealPath() {
        // The production path (no override) emits `first_use_prewarm`
        // so a device log can tell the prewarm ran.
        let bus = RecordingObservabilityBus()
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus)
        recognizer.modelFolderURL = URL(fileURLWithPath: "/tmp/bench-model")

        let done = expectation(description: "listening session ends")
        recognizer.startListening(timeout: 30) { result in
            if case .failure(.cancelled) = result { done.fulfill() }
        }
        XCTAssertEqual(
            bus.events(named: "first_use_prewarm").count, 1,
            "the real path logs the prewarm start")
        recognizer.cancel()
        wait(for: [done], timeout: 2)
    }
}
