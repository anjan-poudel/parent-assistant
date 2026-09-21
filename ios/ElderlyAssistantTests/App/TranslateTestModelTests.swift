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
///
/// The two REAL adapters — the ones that talk to the shipped tiers — are
/// pinned separately below (`TranslateTestEngineAdapterTests`): a fake in
/// front of the model says nothing about whether the adapter behind it
/// forwards a deferral, a provenance or a refusal.
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

    /// The card prints a token for every disposition, and the deferral's is
    /// the TIER's own event vocabulary — derived from `eventReason` rather
    /// than re-spelled here, because the two had already drifted once
    /// (`residentBrain` on screen, `resident_brain` in the log).
    func testEveryDispositionHasAToken() {
        let deferrals: [LocalBrainDeferral] = [
            .residentBrain,
            .insufficientHeadroom(requiredBytes: 1, availableBytes: 0),
            .memoryPressure(level: .warning),
            .recentCriticalPressure(secondsSince: 1, windowSeconds: 2),
            .releaseRequestedDuringLoad,
        ]
        let tokens = deferrals.map(\.eventToken)
        XCTAssertEqual(Set(tokens).count, deferrals.count, "tokens must be distinct")
        XCTAssertFalse(tokens.contains(where: \.isEmpty))
        XCTAssertEqual(LocalBrainDeferral.residentBrain.eventToken, "resident_brain",
                       "the token is the event schema's spelling")

        let dispositions: [LocalBrainDisposition] = [
            .neverAttempted,
            .attemptedWithoutAnswer,
            .deferred(.residentBrain),
        ]
        XCTAssertEqual(dispositions.map(\.token),
                       ["never_attempted", "attempted_without_answer", "resident_brain"],
                       "every disposition prints a token, and only a deferral borrows the tier's")
    }

    /// The coalescing key for the readiness re-ask: the service republishes
    /// `states` on every progress chunk, and only a finished install can
    /// change the answer.
    func testCompletedInstallsNamesOnlyFinishedDownloads() {
        let finished = ModelID("finished")
        let running = ModelID("running")

        XCTAssertEqual(
            TranslateTestModel.completedInstalls(in: [finished: .completed, running: .downloading(bytesReceived: 1, totalBytes: 2)]),
            [finished])

        XCTAssertTrue(TranslateTestModel.completedInstalls(in: [:]).isEmpty)
        XCTAssertTrue(TranslateTestModel.completedInstalls(in: [running: .notStarted]).isEmpty,
                      "a download that has not started is not an install")
        XCTAssertTrue(TranslateTestModel.completedInstalls(in: [running: .verifying]).isEmpty,
                      "nor is one still being verified")
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
        XCTAssertNil(model.micNotice)
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
        XCTAssertNil(model.micNotice, "the person's own cancel is not something to tell them about")
    }

    /// Every outcome the capture can report lands on exactly one phase and
    /// one caption, and the table is the point: the composer draws
    /// `micNotice`, so a failure nobody mapped would compile and say
    /// nothing.
    ///
    /// A fresh model per row, because a refusal hides the button for the
    /// rest of the visit (`micHidden`) and would answer `.denied` for
    /// everything after it.
    func testEveryOutcomeHasOnePhaseAndOneCaption() {
        typealias Phase = TranslateTestModel.MicPhase
        typealias Notice = TranslateTestModel.MicNotice
        let table: [(SearchPhraseCapture.Failure, Phase, Notice?)] = [
            (.cancelled, .idle, nil),
            (.busy, .idle, .busy),
            (.notAuthorized, .idle, .denied),
            (.noSpeech, .failed, .notHeard),
            (.recognitionFailed, .failed, .notHeard),
            (.audioUnavailable, .failed, .noAudio),
            (.noAudioInput, .failed, .noAudio),
        ]

        for (failure, phase, notice) in table {
            let (model, capture) = makeModel()
            model.toggleDictation()
            capture.settle(.failure(failure))
            XCTAssertEqual(model.micPhase, phase, "\(failure)")
            XCTAssertEqual(model.micNotice, notice, "\(failure)")
        }
    }

    /// A busy engine is transient — the button comes back — but the tap
    /// LOOKED like it did nothing, so the caption says why. The one case
    /// that used to be folded in with `.cancelled`, and the reason the two
    /// are no longer the same.
    func testABusyEngineExplainsItselfWithoutAlarming() {
        let (model, capture) = makeModel()

        model.toggleDictation()
        capture.settle(.failure(.busy))

        XCTAssertEqual(model.micPhase, .idle, "the button is offered again")
        XCTAssertEqual(model.micFailure, .busy)
        XCTAssertEqual(model.micNotice, .busy)
    }

    /// Denied at the point of use: the button goes away, exactly as the
    /// shipped leaves hide theirs, and the caption names the only fix.
    ///
    /// Only the hidden direction is asserted: whether a fresh model shows
    /// the button depends on the host's own microphone permission, and the
    /// `micHidden` short-circuit is the half this code owns.
    func testADenialHidesTheButtonAndNamesTheFix() {
        let (model, capture) = makeModel()

        model.toggleDictation()
        capture.settle(.failure(.notAuthorized))

        XCTAssertTrue(model.micHidden)
        XCTAssertFalse(model.micButtonVisible)
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertEqual(model.micNotice, .denied)
    }

    func testDisappearingEndsALiveCaptureAndDropsTheRun() async {
        let (model, capture) = makeModel()
        model.toggleDictation()
        XCTAssertEqual(model.micPhase, .listening)

        model.onDisappear()

        XCTAssertEqual(capture.cancelCount, 1,
                       "a dismissed screen must not leave the mic open")
        XCTAssertEqual(model.micPhase, .idle)
        XCTAssertNil(model.micNotice)
    }
}

// MARK: - The adapters over the shipped tiers

/// The model's own suite drives it through `TranslateProbeEngine` fakes, so
/// the two ADAPTERS — `LocalBrainProbeEngine` and `CloudProbeEngine` — are
/// covered here, against fakes on the TIER side. That is the direction the
/// screen actually depends on: the adapter is real, and the thing behind it
/// returns the shapes the shipped tiers are documented to return. A deferral
/// that is dropped, a cache hit presented as fresh cloud work and a refusal
/// that spends a request are all invisible from the model's side.
final class TranslateTestEngineAdapterTests: XCTestCase {

    // MARK: - Fakes (the tier side)

    /// Stands in for tier 1. Records what it was asked, so "the brain was
    /// never touched" is an assertion rather than an assumption.
    private final class FakeBrain: LocalBrainTranslating, @unchecked Sendable {
        var outcome: LocalBrainTranslationOutcome
        private(set) var asked: [[String]] = []

        init(outcome: LocalBrainTranslationOutcome = .none) {
            self.outcome = outcome
        }

        func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome {
            asked.append(strings)
            return outcome
        }
    }

    /// Stands in for tier 2: one scripted batch, and a count of how many
    /// times the tier was asked at all — the difference between "the doors
    /// refused" and "a request was spent".
    private final class FakeCloudTier: CloudProbeTier, @unchecked Sendable {
        var batch: CloudTranslationTier.BatchResult
        private(set) var resolveCount = 0

        init(batch: CloudTranslationTier.BatchResult = .init(resolved: [:], failures: [:])) {
            self.batch = batch
        }

        func resolve(items: [CloudTranslationTier.Item],
                     targetLanguage: AppLanguage) async -> CloudTranslationTier.BatchResult {
            resolveCount += 1
            return batch
        }
    }

    private func cloudBatch(_ id: String,
                            translation: String,
                            origin: CloudTranslationTier.ResolutionOrigin) -> CloudTranslationTier.BatchResult {
        CloudTranslationTier.BatchResult(
            resolved: [id: CloudTranslationTier.Resolution(translation: translation,
                                                           origin: origin)],
            failures: [:])
    }

    private func config(maxCharacters: Int = 300) -> LiveTranslateConfig {
        var config = LiveTranslateConfig()
        config.brainTranslationMaxCharacters = maxCharacters
        return config
    }

    // MARK: - Tier 1

    func testLocalAdapterNamesTheTierItsAnswerCameFrom() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: ["hello": "नमस्ते"],
                                                                    durationMs: 7))
        // Two reads of the clock, one on each side of the await: the latency
        // is the caller's wait, not the tier's own duration.
        var reads = 0
        let engine = LocalBrainProbeEngine(
            brain: brain,
            installedModel: { ModelID("installed") },
            config: config(),
            now: {
                reads += 1
                return Date(timeIntervalSince1970: reads == 1 ? 0 : 0.25)
            })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result, .resolved(originalText: "hello",
                                                 translation: "नमस्ते",
                                                 tier: .onDeviceBrain))
        XCTAssertEqual(outcome.latencyMs, 250)
        XCTAssertNil(outcome.localDisposition, "an answered string has no disposition to report")
        XCTAssertEqual(brain.asked, [["hello"]])

        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .ready, "readiness is the tier's own installedModel()")
    }

    func testLocalAdapterForwardsTheTiersDeferral() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:],
                                                                    durationMs: 0,
                                                                    deferral: .residentBrain))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           installedModel: { nil },
                                           config: config())

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result.degraded, true)
        XCTAssertEqual(outcome.localDisposition, .deferred(.residentBrain))
        XCTAssertEqual(outcome.localDisposition?.token, "resident_brain",
                       "the card shows the tier's own event token")

        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .modelMissing, "a tier with no installed model says so")
    }

    func testLocalAdapterSeparatesAnAttemptThatFailedFromOneNeverMade() async {
        // Same empty outcome the deferral case returns — the tier's value
        // cannot tell the two apart, which is why the adapter keeps them
        // apart by the disposition instead.
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:], durationMs: 9))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           installedModel: { nil },
                                           config: config())

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.localDisposition, .attemptedWithoutAnswer)
        XCTAssertEqual(brain.asked, [["hello"]], "the brain WAS asked")
    }

    /// Over the tier's own character bound, the string never reaches the
    /// brain. Reporting that as an attempt would put a fault on a tier that
    /// was never asked, and a latency on work that never ran.
    func testLocalAdapterNeverAsksTheBrainForAStringOverTheBound() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:], durationMs: 0))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           installedModel: { nil },
                                           config: config(maxCharacters: 4))

        let outcome = await engine.probe("a string far longer than four characters")

        XCTAssertEqual(outcome.localDisposition, .neverAttempted)
        XCTAssertEqual(outcome.latencyMs, 0, "nothing ran, so nothing took time")
        XCTAssertTrue(brain.asked.isEmpty, "the bound is checked before the brain is touched")
        XCTAssertEqual(outcome.result.degraded, true)
    }

    // MARK: - Tier 2

    func testCloudAdapterReportsACacheHitAsCache() async {
        let tier = FakeCloudTier(batch: cloudBatch(CloudProbeEngine.itemID,
                                                   translation: "नमस्ते",
                                                   origin: .cache(.persisted(tier: .cloud))))
        let engine = CloudProbeEngine(tier: tier,
                                      targetLanguage: .nepali,
                                      isProviderConfigured: { true },
                                      isCloudEnabled: { true })

        let outcome = await engine.probe("hello")

        // Without the origin this reads as a cloud answer that took a
        // millisecond — the one comparison this screen exists to make.
        XCTAssertEqual(outcome.cloudOrigin, .cache)
        XCTAssertEqual(outcome.cloudOrigin?.rawValue, "cache")
        XCTAssertEqual(outcome.result.text, "नमस्ते")
        XCTAssertEqual(tier.resolveCount, 1)
    }

    func testCloudAdapterReportsAFreshAnswerAsFresh() async {
        let tier = FakeCloudTier(batch: cloudBatch(CloudProbeEngine.itemID,
                                                   translation: "नमस्ते",
                                                   origin: .cloud))
        let engine = CloudProbeEngine(tier: tier,
                                      targetLanguage: .nepali,
                                      isProviderConfigured: { true },
                                      isCloudEnabled: { true })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.cloudOrigin, .fresh)
        XCTAssertEqual(outcome.result.sourceTier, .cloud)
    }

    func testCloudAdapterClaimsNoOriginForAnUnansweredItem() async {
        let tier = FakeCloudTier()
        let engine = CloudProbeEngine(tier: tier,
                                      targetLanguage: .nepali,
                                      isProviderConfigured: { true },
                                      isCloudEnabled: { true })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result.outcome, .pending(originalText: "hello"))
        XCTAssertNil(outcome.cloudOrigin, "nothing answered, so nothing has a provenance")
    }

    func testCloudAdapterRefusesAKeylessCloudWithoutSpendingARequest() async {
        let tier = FakeCloudTier()
        let engine = CloudProbeEngine(tier: tier,
                                      targetLanguage: .nepali,
                                      isProviderConfigured: { false },
                                      isCloudEnabled: { true })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result.degradedReason, .providerNotConfigured)
        XCTAssertEqual(outcome.latencyMs, 0)
        XCTAssertEqual(tier.resolveCount, 0, "the tier is not asked to fail for us")

        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .providerKeyMissing)
    }

    func testCloudAdapterRefusesAShutCloudWithoutSpendingARequest() async {
        let tier = FakeCloudTier()
        let engine = CloudProbeEngine(tier: tier,
                                      targetLanguage: .nepali,
                                      isProviderConfigured: { true },
                                      isCloudEnabled: { false })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result.degradedReason, .cloudDisabled)
        XCTAssertEqual(tier.resolveCount, 0)

        // The switch is asked before the key: with the cloud shut, "add a
        // key" is advice for a door that is still locked.
        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .cloudDisabled)
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
