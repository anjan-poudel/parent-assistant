import XCTest
@testable import ElderlyAssistant

/// [TRANSLATE-TEST] Pins the hidden translate-test screen's view model:
/// which engine a run asks, what it reports back, and how a dictation
/// settles.
///
/// Everything here runs against `TranslateProbeEngine` fakes, so no case
/// needs a model on disk, a network, a consent record or a microphone —
/// which is the whole reason the seam exists. The one thing a fake cannot
/// stand in for is `SearchPhraseCapture`'s own completion, and the tests
/// drive that through the injected `startCapture` closure, exactly as the
/// coordinator would.
@MainActor
final class TranslateTestModelTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeProbeEngine: TranslateProbeEngine {
        var readinessValue: TranslateEngineReadiness
        var outcome: TranslateProbeOutcome
        private(set) var probed: [String] = []

        /// When true, `readiness()` parks until `release()` — the seam a
        /// test uses to hold one engine's answer in flight while the picker
        /// moves to the other.
        var holdsReadiness = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaitingForRelease: Bool { waiter != nil }

        init(readiness: TranslateEngineReadiness = .ready,
             outcome: TranslateProbeOutcome = .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 12)) {
            self.readinessValue = readiness
            self.outcome = outcome
        }

        func readiness() async -> TranslateEngineReadiness {
            if holdsReadiness {
                await withCheckedContinuation { waiter = $0 }
            }
            return readinessValue
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }

        func probe(_ text: String) async -> TranslateProbeOutcome {
            probed.append(text)
            return outcome
        }
    }

    /// Stands in for the coordinator: records the two calls and hands the
    /// test the completion, so a capture can be settled from outside.
    private final class FakeCapture {
        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private var completion: ((Result<String, SearchPhraseCapture.Failure>) -> Void)?

        func start(_ completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) {
            startCount += 1
            self.completion = completion
        }

        func cancel() { cancelCount += 1 }

        func settle(_ result: Result<String, SearchPhraseCapture.Failure>) {
            completion?(result)
        }
    }

    private func makeModel(
        local: FakeProbeEngine = FakeProbeEngine(),
        gemini: FakeProbeEngine = FakeProbeEngine(),
        capture: FakeCapture = FakeCapture()
    ) -> (TranslateTestModel, FakeCapture) {
        let model = TranslateTestModel(
            engines: [.local: local, .gemini: gemini],
            startCapture: { capture.start($0) },
            cancelCapture: { capture.cancel() })
        return (model, capture)
    }

    // MARK: - Running

    func testRunAsksTheSelectedEngineAndReportsItsTier() async {
        let local = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 31))
        let gemini = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .cloud, latencyMs: 412))
        let (model, _) = makeModel(local: local, gemini: gemini)

        model.inputText = "hello"
        model.selectedEngine = .local
        await model.run()

        XCTAssertEqual(local.probed, ["hello"])
        XCTAssertTrue(gemini.probed.isEmpty)
        XCTAssertEqual(model.outcome?.result.sourceTier, .onDeviceBrain)
        XCTAssertEqual(model.outcome?.latencyMs, 31)
        XCTAssertEqual(model.runState, .done)

        // The other engine answers for itself when it is the one selected.
        model.selectedEngine = .gemini
        await model.run()
        XCTAssertEqual(gemini.probed, ["hello"])
        XCTAssertEqual(model.outcome?.result.sourceTier, .cloud)
    }

    func testRunTrimsTheInputAndIgnoresBlankInput() async {
        let local = FakeProbeEngine()
        let (model, _) = makeModel(local: local)

        model.inputText = "   "
        model.selectedEngine = .local
        await model.run()
        XCTAssertTrue(local.probed.isEmpty, "whitespace is not a translation request")
        XCTAssertEqual(model.runState, .idle)

        model.inputText = "  hello \n"
        await model.run()
        XCTAssertEqual(local.probed, ["hello"], "the engine is handed the trimmed text")
    }

    func testCanRunRequiresReadyNonEmptyInput() async {
        let local = FakeProbeEngine(readiness: .modelMissing)
        let (model, _) = makeModel(local: local)
        model.inputText = "hello"

        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .modelMissing)
        XCTAssertFalse(model.canRun, "a refused engine must not be runnable")

        local.readinessValue = .ready
        await model.refreshReadiness()
        XCTAssertTrue(model.canRun)

        model.inputText = ""
        XCTAssertFalse(model.canRun)
    }

    func testSwitchingEngineClearsThePreviousResult() async {
        let (model, _) = makeModel()
        model.inputText = "hello"
        await model.run()
        XCTAssertNotNil(model.outcome)

        model.selectedEngine = .gemini
        // A card still reading "onDeviceBrain" under a Gemini picker would
        // attribute one engine's answer to another.
        XCTAssertNil(model.outcome)
        XCTAssertEqual(model.runState, .idle)
    }

    func testDegradedResultKeepsTheOriginalTextAndNamesTheReason() async {
        let degraded = TranslateProbeOutcome(
            result: .degraded(originalText: "hello", reason: .consentNotGranted),
            latencyMs: 0)
        let (model, _) = makeModel(gemini: FakeProbeEngine(outcome: degraded))

        model.inputText = "hello"
        model.selectedEngine = .gemini
        await model.run()

        XCTAssertEqual(model.outcome?.result.degraded, true)
        XCTAssertEqual(model.outcome?.result.degradedReason, .consentNotGranted)
        XCTAssertEqual(model.outcome?.result.text, "hello",
                       "a degradation shows the original, never a blank card")
        XCTAssertNil(model.outcome?.result.sourceTier,
                     "no tier may be named for a string no tier produced")
    }

    func testReadinessReportsEachRefusalSeparately() async {
        let local = FakeProbeEngine(readiness: .modelMissing)
        let gemini = FakeProbeEngine(readiness: .cloudDisabled)
        let (model, _) = makeModel(local: local, gemini: gemini)

        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .modelMissing,
                       "the local engine needs a model, not a key")

        model.selectedEngine = .gemini
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .cloudDisabled,
                       "a shut cloud is not the same fact as a missing key")

        gemini.readinessValue = .providerKeyMissing
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .providerKeyMissing)
    }

    func testRefreshReadinessIgnoresAStaleAnswerForALeftEngine() async {
        let local = FakeProbeEngine(readiness: .modelMissing)
        let gemini = FakeProbeEngine(readiness: .ready)
        let (model, _) = makeModel(local: local, gemini: gemini)

        // Hold the LOCAL engine's answer in flight, then move the picker to
        // Gemini before releasing it. The late answer describes an engine
        // that is no longer selected, so it must be dropped.
        local.holdsReadiness = true
        model.selectedEngine = .local
        let pending = Task { await model.refreshReadiness() }
        while !local.isWaitingForRelease { await Task.yield() }

        model.selectedEngine = .gemini
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .ready)

        local.release()
        await pending.value
        XCTAssertEqual(model.readiness, .ready,
                       "a late answer for the left engine must not overwrite the new one's")
    }

    func testDeferralTokenNamesEveryCase() {
        // The card prints this token, so every case must have one — a new
        // deferral with no name would print an empty cell rather than fail.
        let all: [LocalBrainDeferral] = [
            .residentBrain,
            .insufficientHeadroom(requiredBytes: 1, availableBytes: 0),
            .memoryPressure(level: .warning),
            .recentCriticalPressure(secondsSince: 1, windowSeconds: 2),
            .releaseRequestedDuringLoad,
        ]
        let tokens = all.map(\.displayToken)
        XCTAssertEqual(Set(tokens).count, all.count, "tokens must be distinct")
        XCTAssertFalse(tokens.contains(where: \.isEmpty))
    }

    // MARK: - Dictation

    func testAppendingPutsOneSpaceBetweenUtterances() {
        XCTAssertEqual(TranslateTestModel.appending("hello", to: ""), "hello")
        XCTAssertEqual(TranslateTestModel.appending("world", to: "hello"), "hello world")
        // An empty transcript changes nothing — a capture that heard
        // nothing must not add a stray space.
        XCTAssertEqual(TranslateTestModel.appending("", to: "hello"), "hello")
        XCTAssertEqual(TranslateTestModel.appending("", to: ""), "")
        // Existing whitespace is respected rather than doubled up.
        XCTAssertEqual(TranslateTestModel.appending("world", to: "hello "), "hello world")
        XCTAssertEqual(TranslateTestModel.appending(" world", to: "hello"), "hello world")
        XCTAssertEqual(TranslateTestModel.appending("world", to: "hello\n"), "hello\nworld")
    }

    func testDictationAppendsTheTranscriptIntoTheField() async {
        let (model, capture) = makeModel()
        model.inputText = "already here"

        model.toggleDictation()
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(model.micPhase, .listening)

        capture.settle(.success("and spoken"))
        XCTAssertEqual(model.inputText, "already here and spoken")
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micFailure)
    }

    func testSecondTapCancelsALiveCapture() async {
        let (model, capture) = makeModel()

        model.toggleDictation()
        model.toggleDictation()
        XCTAssertEqual(capture.cancelCount, 1)
        // The phase is left to the completion, because the coordinator's
        // completion is what restarts the suspended voice pipeline.
        XCTAssertEqual(model.micPhase, .listening, "the capture settles on its own completion")

        capture.settle(.failure(.cancelled))
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micFailure, "a cancel is not a fault to report")
    }

    func testDeniedPermissionAndBusyPipelineAreReportedDifferently() {
        let (model, capture) = makeModel()

        model.toggleDictation()
        capture.settle(.failure(.notAuthorized))
        XCTAssertEqual(model.micPhase, .failed)
        XCTAssertEqual(model.micFailure, .notAuthorized)

        // A busy pipeline is transient — the assistant was mid-turn — so it
        // resets silently rather than alarming the person who tapped: the
        // phase goes back to idle AND nothing is recorded to show.
        model.toggleDictation()
        capture.settle(.failure(.busy))
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micFailure,
                     "a transient outcome is not a fault to report")
    }

    /// The two properties are one fact: a reason to show exists exactly when
    /// the button says something went wrong. Pinned because the caption
    /// renders on `micFailure`, and a transient outcome that recorded a
    /// reason would put "cancelled" on screen as an error.
    func testAFailureReasonExistsExactlyWhenThePhaseReportsOne() {
        let (model, capture) = makeModel()

        for failure: SearchPhraseCapture.Failure in [.cancelled, .busy] {
            model.toggleDictation()
            capture.settle(.failure(failure))
            XCTAssertEqual(model.micPhase, .idle)
            XCTAssertNil(model.micFailure, "\(failure) is transient")
        }

        for failure: SearchPhraseCapture.Failure in [.notAuthorized, .noSpeech,
                                                     .audioUnavailable, .noAudioInput,
                                                     .recognitionFailed] {
            model.toggleDictation()
            capture.settle(.failure(failure))
            XCTAssertEqual(model.micPhase, .failed)
            XCTAssertEqual(model.micFailure, failure)
        }

        capture.settle(.success("said something"))
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micFailure, "a success clears the last reason")
    }

    func testHeardNothingIsAFailureWorthShowing() {
        let (model, capture) = makeModel()

        model.toggleDictation()
        capture.settle(.failure(.noSpeech))
        XCTAssertEqual(model.micPhase, .failed)
    }

    func testDisappearingEndsALiveCaptureAndDropsTheRun() async {
        let (model, capture) = makeModel()
        model.toggleDictation()
        XCTAssertEqual(model.micPhase, .listening)

        model.onDisappear()

        XCTAssertEqual(capture.cancelCount, 1,
                       "a dismissed screen must not leave the mic open")
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micFailure)
    }
}

// MARK: - Convenience

private extension TranslateProbeOutcome {
    static func resolved(_ original: String,
                         _ translation: String,
                         tier: TranslationTier,
                         latencyMs: Int) -> TranslateProbeOutcome {
        TranslateProbeOutcome(
            result: .resolved(originalText: original, translation: translation, tier: tier),
            latencyMs: latencyMs)
    }
}
