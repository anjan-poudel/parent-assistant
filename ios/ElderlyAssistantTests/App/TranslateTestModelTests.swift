import XCTest
@testable import ElderlyAssistant

/// [TRANSLATE-TEST] Pins the hidden translate-test screen's view model:
/// which MODEL a run asks, what it reports back, and how a dictation
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
/// forwards a deferral, a provenance, a named model or a refusal.
@MainActor
final class TranslateTestModelTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeProbeEngine: TranslateProbeEngine {
        var readinessValue: TranslateEngineReadiness
        var outcome: TranslateProbeOutcome
        private(set) var probed: [String] = []

        /// When true, `readiness()` parks until `release()` — the seam a
        /// test uses to hold one engine's answer in flight while the picker
        /// moves to another row.
        var holdsReadiness = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaitingForRelease: Bool { waiter != nil }

        /// And the same for a RUN: `probe` parks until `releaseProbe()`, so
        /// a test can move the picker while an answer is genuinely on its
        /// way rather than after it has already landed.
        var holdsProbe = false
        private var probeWaiter: CheckedContinuation<Void, Never>?
        var isProbeWaiting: Bool { probeWaiter != nil }

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

        func releaseProbe() {
            probeWaiter?.resume()
            probeWaiter = nil
        }

        func probe(_ text: String) async -> TranslateProbeOutcome {
            probed.append(text)
            if holdsProbe {
                await withCheckedContinuation { probeWaiter = $0 }
            }
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

    // MARK: - Fixtures

    /// A ladder of three ids with no relationship to the real catalog: the
    /// screen never reads the catalog itself, it reads this source, so the
    /// fixtures only have to be distinguishable.
    private static let head = ModelID("nmt-head")
    private static let fallback = ModelID("nmt-fallback")
    private static let third = ModelID("nmt-third")

    private func makeSource(ladder: [ModelID] = [head, fallback],
                            installed: Set<ModelID> = [],
                            names: [ModelID: String] = [:]) -> TranslateTestModelSource {
        TranslateTestModelSource(ladder: ladder,
                                 // The coordinator's own rule (catalog name,
                                 // raw id when the catalog has none) minus the
                                 // catalog: these ids have no entries, which
                                 // is itself the mid-swap case the fallback
                                 // exists for.
                                 displayName: { names[$0] ?? $0.rawValue },
                                 isInstalled: { installed.contains($0) })
    }

    /// The common fixture: a ladder with `head` installed and a fake engine
    /// per row, plus the cloud. Every test that is not about the dropdown
    /// takes it as it comes — the opening selection is `head`.
    private func makeModel(headEngine: FakeProbeEngine = FakeProbeEngine(),
                           fallbackEngine: FakeProbeEngine = FakeProbeEngine(),
                           gemini: FakeProbeEngine = FakeProbeEngine(),
                           ladder: [ModelID] = [head, fallback],
                           installed: Set<ModelID> = [head],
                           names: [ModelID: String] = [:],
                           capture: FakeCapture = FakeCapture())
        -> (model: TranslateTestModel, capture: FakeCapture) {
        var engines: [TranslateTestSelection: any TranslateProbeEngine] = [.gemini: gemini]
        for id in ladder {
            if id == Self.head { engines[.model(id)] = headEngine }
            if id == Self.fallback { engines[.model(id)] = fallbackEngine }
        }
        let model = TranslateTestModel(engines: engines,
                                       modelSource: makeSource(ladder: ladder,
                                                               installed: installed,
                                                               names: names),
                                       startCapture: { capture.start($0) },
                                       cancelCapture: { capture.cancel() })
        return (model, capture)
    }

    // MARK: - The dropdown

    /// The rows ARE the ladder, in its own order, each labelled by the
    /// source and marked with the live install state. No id is spelled in
    /// the screen, which is what makes a catalog swap a config change.
    func testOptionsFollowTheLadderWithLiveInstallState() {
        let options = TranslateTestModel.options(
            from: makeSource(ladder: [Self.head, Self.fallback, Self.third],
                             installed: [Self.fallback],
                             names: [Self.head: "Head model", Self.fallback: "Fallback model"]))

        XCTAssertEqual(options.map(\.id), [Self.head, Self.fallback, Self.third],
                       "the ladder's order is the dropdown's order, which is the tier's preference order")
        XCTAssertEqual(options.map(\.displayName), ["Head model", "Fallback model", "nmt-third"],
                       "the catalog's name when there is one, the raw id when there is not")
        XCTAssertEqual(options.map(\.isInstalled), [false, true, false],
                       "the state is read per row, not once for the ladder")
    }

    /// A ladder that lists one model twice — a config mistake, but one the
    /// screen must not turn into two rows with the same selection value.
    func testOptionsDropADuplicatedLadderEntry() {
        let options = TranslateTestModel.options(
            from: makeSource(ladder: [Self.head, Self.head, Self.fallback]))

        XCTAssertEqual(options.map(\.id), [Self.head, Self.fallback])
    }

    /// The opening row: the first model the device can run, falling back to
    /// the first row (whose card offers its download) and then to the cloud.
    func testDefaultSelectionPrefersTheFirstInstalledModel() {
        let options = TranslateTestModel.options(
            from: makeSource(ladder: [Self.head, Self.fallback], installed: [Self.fallback]))
        XCTAssertEqual(TranslateTestModel.defaultSelection(options: options), .model(Self.fallback),
                       "an installed model beats an earlier row that is only downloadable")

        let noneInstalled = TranslateTestModel.options(from: makeSource())
        XCTAssertEqual(TranslateTestModel.defaultSelection(options: noneInstalled), .model(Self.head),
                       "with nothing installed the first row opens, and its card offers the download")

        XCTAssertEqual(TranslateTestModel.defaultSelection(options: []), .gemini,
                       "an empty ladder leaves the cloud as the only row there is")
    }

    /// The two states are marked with the app's own vocabulary — the keys
    /// the AI-models pickers use — and a model with no row (the mid-swap
    /// ladder) still gets an honest name out of the raw id.
    func testOptionLabelMarksBothStatesInTheAppsOwnWords() {
        let en = Locale(identifier: "en")
        let installed = TranslateTestModelOption(id: Self.head,
                                                 displayName: "Head model",
                                                 isInstalled: true)
        let absent = TranslateTestModelOption(id: Self.fallback,
                                              displayName: "Fallback model",
                                              isInstalled: false)

        let readyLabel = TranslateTestModel.optionLabel(installed, locale: en)
        XCTAssertTrue(readyLabel.contains("Head model"), readyLabel)
        XCTAssertEqual(readyLabel, "Head model — \(L10n.str("model.ready", locale: en))",
                       "the marker is the app's own 'ready' string, not copy of this screen's")
        XCTAssertTrue(readyLabel.lowercased().contains("ready"), readyLabel)

        let absentLabel = TranslateTestModel.optionLabel(absent, locale: en)
        XCTAssertTrue(absentLabel.contains("Fallback model"), absentLabel)
        XCTAssertEqual(absentLabel, "Fallback model — \(L10n.str("model.notDownloaded", locale: en))")
        XCTAssertTrue(absentLabel.lowercased().contains("not downloaded"), absentLabel)
        XCTAssertNotEqual(readyLabel, absentLabel,
                          "the two states must not read the same, or the marker is decoration")
    }

    /// The screen opens on the model its ladder can run — and the rows it
    /// draws agree with the readiness line under them, because one call
    /// refreshes both.
    func testTheScreenOpensOnTheFirstInstalledModel() {
        let (model, _) = makeModel(installed: [Self.head, Self.fallback])
        XCTAssertEqual(model.selection, .model(Self.head))
        XCTAssertEqual(model.selectedModelOption?.isInstalled, true)
    }

    /// An install that finishes while the screen is open flips the row it
    /// belongs to — which is the whole reason the state is a closure over
    /// the device rather than a value captured at configure time.
    func testRefreshingReadinessRefreshesTheRowsLiveState() async {
        var installed: Set<ModelID> = []
        let source = TranslateTestModelSource(ladder: [Self.head],
                                              displayName: { $0.rawValue },
                                              isInstalled: { installed.contains($0) })
        let engine = FakeProbeEngine(readiness: .modelMissing)
        let model = TranslateTestModel(engines: [.model(Self.head): engine], modelSource: source)
        model.inputText = "hello"

        await model.refreshReadiness()
        XCTAssertEqual(model.modelOptions.map(\.isInstalled), [false])
        XCTAssertEqual(model.readiness, .modelMissing)
        XCTAssertFalse(model.canRun, "a model that is not on the device cannot be run")

        // The download lands: the store has it now, and the fake engine —
        // which stands in for the adapter over the same store — says so.
        installed = [Self.head]
        engine.readinessValue = .ready
        await model.refreshReadiness()

        XCTAssertEqual(model.modelOptions.map(\.isInstalled), [true],
                       "the row follows the device, not the screen's opening state")
        XCTAssertEqual(model.readiness, .ready,
                       "and the line under it follows the same call")
        XCTAssertTrue(model.canRun,
                      "the finished install is what arms the button, with no relaunch")
    }

    /// A selection whose row the source no longer lists — a ladder that
    /// changed under the screen — still names something honest: the raw id
    /// the tier would be asked for.
    func testAModelWithNoRowStillHasAnHonestName() {
        let (model, _) = makeModel()
        model.selection = .model(ModelID("not-in-this-ladder"))

        XCTAssertNil(model.selectedModelOption, "there is no row to read a state from")
        XCTAssertEqual(model.selectedModelName, "not-in-this-ladder",
                       "the id is what the download card and the readiness line have to show")
    }

    /// Gemini is not a model row: it has no install state to read and no
    /// name from the ladder.
    func testGeminiHasNoModelRow() {
        let (model, _) = makeModel()
        model.selection = .gemini
        XCTAssertNil(model.selectedModelOption)
        XCTAssertTrue(model.selectedModelName.isEmpty)
    }

    // MARK: - Running

    func testRunAsksTheSelectedModelAndReportsItsTier() async {
        let head = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 31))
        let fallback = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 99))
        let gemini = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .cloud, latencyMs: 412))
        let (model, _) = makeModel(headEngine: head, fallbackEngine: fallback, gemini: gemini)

        model.inputText = "hello"
        model.selection = .model(Self.head)
        await model.run()

        XCTAssertEqual(head.probed, ["hello"])
        XCTAssertTrue(fallback.probed.isEmpty, "the other ladder row is not asked")
        XCTAssertTrue(gemini.probed.isEmpty)
        XCTAssertEqual(model.outcome?.result.sourceTier, .onDeviceBrain)
        XCTAssertEqual(model.outcome?.latencyMs, 31)
        XCTAssertEqual(model.runState, .done)

        // A DIFFERENT ladder row is a different engine, and the answer says
        // which weights produced it.
        model.selection = .model(Self.fallback)
        await model.run()
        XCTAssertEqual(fallback.probed, ["hello"])
        XCTAssertEqual(head.probed, ["hello"], "the row that was left is not asked again")
        XCTAssertEqual(model.outcome?.latencyMs, 99)

        model.selection = .gemini
        await model.run()
        XCTAssertEqual(gemini.probed, ["hello"])
        XCTAssertEqual(model.outcome?.result.sourceTier, .cloud)
    }

    func testRunTrimsTheInputAndIgnoresBlankInput() async {
        let head = FakeProbeEngine()
        let (model, _) = makeModel(headEngine: head)

        model.inputText = "   "
        await model.run()
        XCTAssertTrue(head.probed.isEmpty, "whitespace is not a translation request")
        XCTAssertEqual(model.runState, .idle)

        model.inputText = "  hello \n"
        await model.run()
        XCTAssertEqual(head.probed, ["hello"], "the engine is handed the trimmed text")
    }

    func testCanRunRequiresReadyNonEmptyInput() async {
        let head = FakeProbeEngine(readiness: .modelMissing)
        let (model, _) = makeModel(headEngine: head)
        model.inputText = "hello"

        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .modelMissing)
        XCTAssertFalse(model.canRun, "a refused engine must not be runnable")

        head.readinessValue = .ready
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

        model.selection = .gemini
        // A card still reading "onDeviceBrain" under a Gemini picker would
        // attribute one engine's answer to another.
        XCTAssertNil(model.outcome)
        XCTAssertEqual(model.runState, .idle)
    }

    /// The same rule between two rows of the SAME tier: two models are two
    /// engines as far as this screen is concerned, so an answer computed
    /// with one must not sit under the other's name.
    func testSwitchingModelClearsThePreviousResult() async {
        let (model, _) = makeModel(installed: [Self.head, Self.fallback])
        model.inputText = "hello"
        await model.run()
        XCTAssertNotNil(model.outcome)

        model.selection = .model(Self.fallback)
        XCTAssertNil(model.outcome,
                     "an answer from one model's weights must not be labelled as another's")
        XCTAssertEqual(model.runState, .idle)
    }

    /// A run in flight is DROPPED when the picker moves, not merely hidden:
    /// the answer that arrives late would otherwise be written onto the card
    /// the new row is about to fill.
    func testAModelSwitchDropsTheRunInFlight() async {
        let head = FakeProbeEngine()
        let fallback = FakeProbeEngine(
            outcome: .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 7))
        let (model, _) = makeModel(headEngine: head, fallbackEngine: fallback)
        model.inputText = "hello"

        // The head engine parks until released: the run is genuinely in
        // flight, rather than already returned, when the selection moves.
        head.holdsProbe = true
        let inFlight = Task { await model.run() }
        while !head.isProbeWaiting { await Task.yield() }

        model.selection = .model(Self.fallback)
        head.releaseProbe()
        await inFlight.value

        XCTAssertNil(model.outcome,
                     "the answer belongs to the row that was left, and the cards were reset for the new one")
        XCTAssertEqual(model.runState, .idle,
                       "the dropped run did not mark itself done for the row on screen now")
        XCTAssertTrue(fallback.probed.isEmpty,
                      "moving the picker does not silently ask the new row as well")
    }

    func testDegradedResultKeepsTheOriginalTextAndNamesTheReason() async {
        let degraded = TranslateProbeOutcome(
            result: .degraded(originalText: "hello", reason: .consentNotGranted),
            latencyMs: 0)
        let (model, _) = makeModel(gemini: FakeProbeEngine(outcome: degraded))

        model.inputText = "hello"
        model.selection = .gemini
        await model.run()

        XCTAssertEqual(model.outcome?.result.degraded, true)
        XCTAssertEqual(model.outcome?.result.degradedReason, .consentNotGranted)
        XCTAssertEqual(model.outcome?.result.text, "hello",
                       "a degradation shows the original, never a blank card")
        XCTAssertNil(model.outcome?.result.sourceTier,
                     "no tier may be named for a string no tier produced")
    }

    /// Readiness is asked of the ROW, not of tier 1: with the head missing
    /// and the fallback installed, moving between them changes the answer
    /// and the button's availability with it.
    func testReadinessReportsEachRefusalSeparately() async {
        let head = FakeProbeEngine(readiness: .modelMissing)
        let fallback = FakeProbeEngine(readiness: .ready)
        let gemini = FakeProbeEngine(readiness: .cloudDisabled)
        let (model, _) = makeModel(headEngine: head,
                                   fallbackEngine: fallback,
                                   gemini: gemini,
                                   installed: [Self.fallback])

        // The head explicitly, because the opening row is the installed
        // fallback in this fixture — and the point here is the answer each
        // row gives, not which one opens.
        model.selection = .model(Self.head)
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .modelMissing,
                       "the head is not on this device, whatever the other row's state is")

        model.selection = .model(Self.fallback)
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .ready, "the same tier, a model that IS on the device")

        model.selection = .gemini
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .cloudDisabled,
                       "a shut cloud is not the same fact as a missing key")

        gemini.readinessValue = .providerKeyMissing
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .providerKeyMissing)
    }

    func testRefreshReadinessIgnoresAStaleAnswerForALeftEngine() async {
        let head = FakeProbeEngine(readiness: .modelMissing)
        let gemini = FakeProbeEngine(readiness: .ready)
        let (model, _) = makeModel(headEngine: head, gemini: gemini)

        // Hold the HEAD's answer in flight, then move the picker to Gemini
        // before releasing it. The late answer describes a row that is no
        // longer selected, so it must be dropped.
        head.holdsReadiness = true
        model.selection = .model(Self.head)
        let pending = Task { await model.refreshReadiness() }
        while !head.isWaitingForRelease { await Task.yield() }

        model.selection = .gemini
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, .ready)

        head.release()
        await pending.value
        XCTAssertEqual(model.readiness, .ready,
                       "a late answer for the left row must not overwrite the new one's")
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
/// that is dropped, a cache hit presented as fresh cloud work, a named model
/// that is quietly swapped for the ladder's own pick and a refusal that
/// spends a request are all invisible from the model's side.
final class TranslateTestEngineAdapterTests: XCTestCase {

    // MARK: - Fakes (the tier side)

    /// Stands in for tier 1. Records which model it was asked to run beside
    /// the strings, so "the model that ran is the model that was named" is
    /// an assertion rather than an assumption.
    private final class FakeBrain: LocalBrainModelTier, @unchecked Sendable {
        var outcome: LocalBrainTranslationOutcome
        private(set) var asked: [ModelID?] = []
        private(set) var askedStrings: [[String]] = []

        init(outcome: LocalBrainTranslationOutcome = .none) {
            self.outcome = outcome
        }

        func translate(_ strings: [String], using model: ModelID?) async -> LocalBrainTranslationOutcome {
            asked.append(model)
            askedStrings.append(strings)
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
            model: ModelID("chosen"),
            isInstalled: { _ in true },
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
        XCTAssertEqual(brain.askedStrings, [["hello"]])

        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .ready)
    }

    /// The NAMED model is what reaches the tier. This is the whole point of
    /// the picker at the adapter's level: the ladder's preference is the
    /// tier's own business, and a screen that asked "tier 1" would get
    /// whichever entry the device happens to prefer.
    func testLocalAdapterHandsTheTierTheModelItWasBuiltWith() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: ["hello": "नमस्ते"],
                                                                    durationMs: 1))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("second-rung"),
                                           isInstalled: { _ in true },
                                           config: config())

        _ = await engine.probe("hello")

        XCTAssertEqual(brain.asked, [ModelID("second-rung")],
                       "the named model, not the ladder's first installed entry")
    }

    /// Readiness is a fact about THIS model: the same adapter over the same
    /// store answers differently for a row that is installed and one that is
    /// not, which is what lets the screen offer a download instead of a wait.
    func testLocalAdapterReadinessFollowsTheModelItNames() async {
        let brain = FakeBrain()
        let installed = ModelID("installed")
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: installed,
                                           isInstalled: { $0 == installed },
                                           config: config())

        let ready = await engine.readiness()
        XCTAssertEqual(ready, .ready, "the named model is on the device")

        let absent = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("absent"),
                                           isInstalled: { $0 == installed },
                                           config: config())
        let missing = await absent.readiness()
        XCTAssertEqual(missing, .modelMissing,
                       "another row being installed is not this row's answer")
    }

    func testLocalAdapterForwardsTheTiersDeferral() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:],
                                                                    durationMs: 0,
                                                                    deferral: .residentBrain))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("named"),
                                           isInstalled: { _ in false },
                                           config: config())

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.result.degraded, true)
        XCTAssertEqual(outcome.localDisposition, .deferred(.residentBrain))
        XCTAssertEqual(outcome.localDisposition?.token, "resident_brain",
                       "the card shows the tier's own event token")

        let readiness = await engine.readiness()
        XCTAssertEqual(readiness, .modelMissing, "a model that is not installed says so")
    }

    func testLocalAdapterSeparatesAnAttemptThatFailedFromOneNeverMade() async {
        // Same empty outcome the deferral case returns — the tier's value
        // cannot tell the two apart, which is why the adapter keeps them
        // apart by the disposition instead.
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:], durationMs: 9))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("named"),
                                           isInstalled: { _ in true },
                                           config: config())

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.localDisposition, .attemptedWithoutAnswer)
        XCTAssertEqual(brain.askedStrings, [["hello"]], "the brain WAS asked")
    }

    /// Over the tier's own character bound, the string never reaches the
    /// brain. Reporting that as an attempt would put a fault on a tier that
    /// was never asked, and a latency on work that never ran.
    func testLocalAdapterNeverAsksTheBrainForAStringOverTheBound() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: [:], durationMs: 0))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("named"),
                                           isInstalled: { _ in true },
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
