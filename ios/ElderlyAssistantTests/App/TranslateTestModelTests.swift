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

    /// A gate a test can hold one answer behind.
    ///
    /// **A QUEUE of continuations, not one** (2026-09-21 review). The single
    /// optional this used to be resumed only the first parker: a second call
    /// that arrived while the gate was shut overwrote the stored continuation
    /// and left that waiter suspended forever — a leak that shows up as a
    /// suite that hangs rather than as a test that fails. The array is the
    /// repo's own shape for this (`TransportLatch` in
    /// `CloudTranslationTierTests`), with the same fast-path: a waiter that
    /// arrives after the release never parks at all.
    private final class Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isWaiting: Bool { !waiters.isEmpty }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private final class FakeProbeEngine: TranslateProbeEngine {
        var readinessValue: TranslateEngineReadiness
        var outcome: TranslateProbeOutcome
        private(set) var probed: [String] = []
        /// How many times readiness was asked. The count is what makes "the
        /// screen does not start a walk of its own" an assertion rather than
        /// an inspection.
        private(set) var readinessCount = 0

        /// When true, `readiness()` parks until `release()` — the seam a
        /// test uses to hold one engine's answer in flight while the picker
        /// moves to another row.
        var holdsReadiness = false
        private let readinessLatch = Latch()
        var isWaitingForRelease: Bool { readinessLatch.isWaiting }

        /// And the same for a RUN: `probe` parks until `releaseProbe()`, so
        /// a test can move the picker while an answer is genuinely on its
        /// way rather than after it has already landed.
        var holdsProbe = false
        private let probeLatch = Latch()
        var isProbeWaiting: Bool { probeLatch.isWaiting }

        init(readiness: TranslateEngineReadiness = .ready,
             outcome: TranslateProbeOutcome = .resolved("hello", "नमस्ते", tier: .onDeviceBrain, latencyMs: 12)) {
            self.readinessValue = readiness
            self.outcome = outcome
        }

        func readiness() async -> TranslateEngineReadiness {
            readinessCount += 1
            if holdsReadiness {
                await readinessLatch.wait()
            }
            return readinessValue
        }

        func release() { readinessLatch.open() }

        func releaseProbe() { probeLatch.open() }

        func probe(_ text: String) async -> TranslateProbeOutcome {
            probed.append(text)
            if holdsProbe {
                await probeLatch.wait()
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

    // MARK: - Waiting

    /// Polls `condition` on the main actor until it holds, or fails the test.
    ///
    /// The repo's own idiom (`CalendarShareSettingsSeamTests`, in this same
    /// folder): the fakes park on continuations that are resumed from other
    /// tasks, so a bare `while` loop that spins is a suite that hangs instead
    /// of a test that fails when the thing it waits for never happens.
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
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
                            unavailable: Set<ModelID> = [],
                            names: [ModelID: String] = [:]) -> TranslateTestModelSource {
        TranslateTestModelSource(ladder: ladder,
                                 // The coordinator's own rule (catalog name,
                                 // raw id when the catalog has none) minus the
                                 // catalog: these ids have no entries, which
                                 // is itself the mid-swap case the fallback
                                 // exists for.
                                 displayName: { names[$0] ?? $0.rawValue },
                                 isInstalled: { installed.contains($0) },
                                 // The ledger's verdict as the coordinator
                                 // gives it: a reason token for the models
                                 // this device class refuses.
                                 unavailabilityReason: { unavailable.contains($0) ? .overClassBudget : nil })
    }

    /// The common fixture: a ladder with `head` installed and a fake engine
    /// per row, plus the cloud. Every test that is not about the dropdown
    /// takes it as it comes — the opening selection is `head`.
    private func makeModel(headEngine: FakeProbeEngine = FakeProbeEngine(),
                           fallbackEngine: FakeProbeEngine = FakeProbeEngine(),
                           gemini: FakeProbeEngine = FakeProbeEngine(),
                           ladder: [ModelID] = [head, fallback],
                           installed: Set<ModelID> = [head],
                           unavailable: Set<ModelID> = [],
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
                                                               unavailable: unavailable,
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
                             unavailable: [Self.third],
                             names: [Self.head: "Head model", Self.fallback: "Fallback model"]))

        XCTAssertEqual(options.map(\.id), [Self.head, Self.fallback, Self.third],
                       "the ladder's order is the dropdown's order, which is the tier's preference order")
        XCTAssertEqual(options.map(\.displayName), ["Head model", "Fallback model", "nmt-third"],
                       "the catalog's name when there is one, the raw id when there is not")
        XCTAssertEqual(options.map(\.isInstalled), [false, true, false],
                       "the state is read per row, not once for the ladder")
        XCTAssertEqual(options.map(\.isUnavailable), [false, false, true],
                       "the ledger's verdict is a second fact, read per row: a model can be on the device and still refused")
    }

    /// The warden's verdict reaches the row's LABEL, which is the whole point
    /// of consulting it ([MODEL-SWITCH], 2026-09-21 review): a refused model
    /// that wore the installed row's label would offer a button whose only
    /// outcome is a refusal.
    func testARowTheWardenRefusesDoesNotWearTheInstalledLabel() {
        let locale = Locale(identifier: "en")
        let id = ModelCatalog.nmtEnNeQwen17bR4Q5
        let model = TranslateTestModel()
        let name = ModelCatalog.entry(for: id)?.displayName(locale: locale) ?? ""

        let installed = TranslateTestModelOption(id: id, displayName: name,
                                                 isInstalled: true, isUnavailable: false)
        let refused = TranslateTestModelOption(id: id, displayName: name,
                                               isInstalled: true, isUnavailable: true)

        XCTAssertEqual(model.label(for: installed, locale: locale), name,
                       "an installed, admitted model is its plain name — the composer's own rule")
        XCTAssertNotEqual(model.label(for: refused, locale: locale), name,
                          "a model this device class refuses must not read as ready")
        XCTAssertTrue(model.label(for: refused, locale: locale)
            .contains(L10n.str("model.unavailable.marker", locale: locale)),
                      model.label(for: refused, locale: locale))
    }

    /// The rows are labelled by the SHARED AI-models composer rather than by
    /// a copy of it, and localized: the two states it distinguishes, plus
    /// the localization rule the 2026-09-21 review found broken (no row may
    /// render an English catalog literal on a Nepali build).
    func testTheRowLabelIsTheSharedComposersWordsInTheScreensLanguage() {
        let en = Locale(identifier: "en")
        let ne = Locale(identifier: "ne")
        let id = ModelCatalog.nmtEnNeQwen17bR4Q5
        guard let entry = ModelCatalog.entry(for: id) else {
            return XCTFail("the fixture names a model the catalog must carry")
        }
        let model = TranslateTestModel()
        let installed = TranslateTestModelOption(id: id, displayName: "raw",
                                                 isInstalled: true, isUnavailable: false)
        let absent = TranslateTestModelOption(id: id, displayName: "raw",
                                              isInstalled: false, isUnavailable: false)

        XCTAssertEqual(model.label(for: installed, locale: en), entry.displayName(locale: en))
        XCTAssertEqual(model.label(for: absent, locale: en),
                       "\(entry.displayName(locale: en)) — \(L10n.str("model.notDownloaded", locale: en))",
                       "the same two states the AI-models pickers mark, in the app's own words")

        // A Nepali build: the catalog's ne name, not its English one.
        XCTAssertEqual(model.label(for: installed, locale: ne), entry.displayName(locale: ne))
        XCTAssertNotEqual(model.label(for: installed, locale: ne), entry.displayName(locale: en),
                          "a Nepali screen must not print the English catalog literal")

        // A ladder id this build's catalog does not carry — the mid-swap
        // case — is still named by the id rather than by nothing.
        let unknown = TranslateTestModelOption(id: ModelID("nmt-not-in-this-build"),
                                               displayName: "nmt-not-in-this-build",
                                               isInstalled: false, isUnavailable: false)
        XCTAssertEqual(model.label(for: unknown, locale: en), "nmt-not-in-this-build")
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

    /// …and "can run" includes the device-class verdict, not just the file
    /// (2026-09-21 review round 2).
    ///
    /// An installed rung this phone REFUSES is not a runnable one: the tier's
    /// resolution walks past it, and the screen has to open on the rung the
    /// pipeline would actually pick. The installed test alone put the opening
    /// row on the refused rung — where the first attempt can only answer
    /// `.modelUnavailable`, and the install card is hidden because there is
    /// nothing to download.
    func testDefaultSelectionSkipsRungsTheDeviceRefuses() {
        let options = TranslateTestModel.options(
            from: makeSource(ladder: [Self.head, Self.fallback],
                             installed: [Self.head, Self.fallback],
                             unavailable: [Self.head]))

        XCTAssertEqual(TranslateTestModel.defaultSelection(options: options), .model(Self.fallback),
                       "the installed rung the device refuses is not a runnable one")

        // The refusal is the only thing standing in the way: drop it and the
        // same ladder opens on the same first row as before.
        let permitted = TranslateTestModel.options(
            from: makeSource(ladder: [Self.head, Self.fallback],
                             installed: [Self.head, Self.fallback]))
        XCTAssertEqual(TranslateTestModel.defaultSelection(options: permitted), .model(Self.head))
    }

    /// The install card offers a download only for the models the catalog
    /// PUBLISHES (2026-09-21 review round 2).
    ///
    /// A ladder rung is what the tier will TRY, not what this build hands
    /// out: the superseded quants sit on the ladder so a device that
    /// sideloaded them keeps working, and the AI-models screen deliberately
    /// never offers them. (The round-4 Q8 ceiling is the same kind of rung,
    /// but it is a TEMPORARY member of the offer list for the Q6-vs-Q8
    /// ARM-kernel A/B, so it is NOT the unoffered fixture below.) A card that
    /// drew its management row for every catalog entry made this dev screen
    /// the one place in the app offering those downloads — with a Delete
    /// beside them for an artifact it neither installed nor can fetch.
    ///
    /// The published head IS offered, which is what keeps this from being a
    /// card that offers nothing at all.
    func testOnlyCatalogPublishedModelsGetADownloadRow() {
        let published = ModelCatalog.nmtEnNeQwen17bR4Q6
        XCTAssertNotNil(TranslateTestModel.offeredEntry(for: published),
                        "the ship quant is what the household downloads — the row must be drawn for it")
        XCTAssertEqual(TranslateTestModel.offeredEntry(for: published)?.id, published)

        // Carried, never offered: an entry in the catalog (so it has a
        // management row SOMEWHERE, on the AI-models screen) that this build
        // publishes no download for.
        //
        // The fixture is the SUPERSEDED round-4 Q5, not the Q8 ceiling the
        // previous revision used: the Q8 is a temporary member of the offer
        // list for the Q6-vs-Q8 ARM-kernel A/B, so pinning the unoffered
        // branches on it would be asserting the opposite of what this build
        // does. The Q5 is the same kind of artifact the Q8 was before that
        // offer — on the ladder, in the catalog, published by nobody.
        let sideloadOnly = ModelCatalog.nmtEnNeQwen17bR4Q5
        XCTAssertNotNil(ModelCatalog.entry(for: sideloadOnly),
                        "the fixture must be an entry the catalog carries, or it tests the wrong branch")
        XCTAssertNil(TranslateTestModel.offeredEntry(for: sideloadOnly),
                     "sideload-only rungs are not this screen's to offer")
        XCTAssertEqual(TranslateTestModel.unofferedInstallNoteKey(for: sideloadOnly),
                       "settings.translateTest.install.sideloadOnly")

        // Not carried at all: a catalog swap mid-flight, which is a different
        // fact and a different sentence.
        let unknown = ModelID("nmt-not-in-this-build")
        XCTAssertNil(TranslateTestModel.offeredEntry(for: unknown))
        XCTAssertEqual(TranslateTestModel.unofferedInstallNoteKey(for: unknown),
                       "settings.translateTest.install.unknown")
    }

    /// Every row this screen offers is one the AI-models screen offers too —
    /// asked of the catalog rather than restated, so the two surfaces cannot
    /// drift into disagreeing about what a household may fetch.
    func testTheOfferedRowComesFromTheCatalogssOwnOfferList() {
        let offered = ModelCatalog.availableTranslationEntries.compactMap {
            TranslateTestModel.offeredEntry(for: $0.id)
        }

        XCTAssertEqual(offered.map(\.id), ModelCatalog.availableTranslationEntries.map(\.id),
                       "the same list, in the same order — one is derived from the other")
        XCTAssertFalse(offered.isEmpty,
                       "an empty offer list would make the card a dead end on every model")
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
                                              isInstalled: { installed.contains($0) },
                                              unavailabilityReason: { _ in nil })
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
    /// name from the ladder — and "no name" is `nil` rather than an empty
    /// string, so a caller that went on to print it has to decide what a
    /// model-less row means ([MODEL-SWITCH], 2026-09-21 review).
    func testGeminiHasNoModelRow() {
        let (model, _) = makeModel()
        model.selection = .gemini
        XCTAssertNil(model.selectedModelOption)
        XCTAssertNil(model.selectedModelName)
        XCTAssertNil(model.selection.modelID, "the cloud names no model, which is what guards the callers")
    }

    /// Opening the screen is not a picker move: the construction assigns the
    /// opening row, and that assignment must not trip `selection`'s observer
    /// into a readiness walk the caller never asked for
    /// ([MODEL-SWITCH], 2026-09-21 review — the observer DOES fire from an
    /// initializer, because `selection` is a `@Published` property with an
    /// initial value, so the assignment goes through a real setter).
    ///
    /// Observed through the count of asks: a walk spawned by the initializer
    /// lands on this engine a moment later.
    func testOpeningTheScreenStartsNoReadinessWalkOfItsOwn() async {
        let head = FakeProbeEngine()
        _ = makeModel(headEngine: head)

        // Long enough for a task the constructor spawned to have run: the
        // assertion is that nothing arrives, so it needs a settle window
        // rather than an await.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(head.readinessCount, 0,
                       "the opening row is a value, not a switch — the caller does the asking")
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
        // Bounded (2026-09-21 review): a `while !isProbeWaiting { yield() }`
        // spin does not fail when the run never starts — it hangs the suite.
        await waitUntil("the run to be in flight") { head.isProbeWaiting }

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
        await waitUntil("the readiness answer to be in flight") { head.isWaitingForRelease }

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

    /// A deferral is the DEVICE's doing, not the model's ([MODEL-SWITCH],
    /// 2026-09-21 review). On a normal device the intent brain is resident,
    /// so every row reports `deferred(resident_brain)` at 0 ms; a bare token
    /// beside a zero reads as a model that failed to answer. The caption
    /// says what happened in words, and keeps the token for the log.
    func testADeferralReadsAsTheDeviceBeingBusy() {
        let en = Locale(identifier: "en")
        let caption = LocalBrainDisposition.deferred(.residentBrain).caption(locale: en)

        XCTAssertTrue(caption.contains("device busy"), caption)
        XCTAssertTrue(caption.contains("resident_brain"), "the token stays — the log speaks it")
        XCTAssertFalse(LocalBrainDisposition.neverAttempted.caption(locale: en).contains("device busy"),
                       "only the deferrals are the device's fault")
        XCTAssertEqual(LocalBrainDisposition.attemptedWithoutAnswer.caption(locale: en),
                       "attempted_without_answer",
                       "an attempt that answered nothing is the model's business, token unchanged")
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
    ///
    /// It conforms to the PIPELINE's own seam ([MODEL-SWITCH], 2026-09-21
    /// review): the screen used to declare a narrower one-method protocol of
    /// its own, which is how a conformer of this shape could be handed to a
    /// screen that names models and quietly answer with its own.
    private final class FakeBrain: LocalBrainTranslating, @unchecked Sendable {
        var outcome: LocalBrainTranslationOutcome
        private(set) var asked: [ModelID?] = []
        private(set) var askedStrings: [[String]] = []

        init(outcome: LocalBrainTranslationOutcome = .none) {
            self.outcome = outcome
        }

        /// The pipeline's own method. This fake is never driven through it —
        /// the screen always names a model — but it is a requirement of the
        /// seam, and answering with the same script is the honest stand-in.
        func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome {
            await translate(strings, using: nil)
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
            unavailabilityReason: { _ in nil },
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
                                           unavailabilityReason: { _ in nil },
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
                                           unavailabilityReason: { _ in nil },
                                           config: config())

        let ready = await engine.readiness()
        XCTAssertEqual(ready, .ready, "the named model is on the device")

        let absent = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("absent"),
                                           isInstalled: { $0 == installed },
                                           unavailabilityReason: { _ in nil },
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
                                           unavailabilityReason: { _ in nil },
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
                                           unavailabilityReason: { _ in nil },
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
                                           unavailabilityReason: { _ in nil },
                                           config: config(maxCharacters: 4))

        let outcome = await engine.probe("a string far longer than four characters")

        XCTAssertEqual(outcome.localDisposition, .neverAttempted)
        XCTAssertEqual(outcome.latencyMs, 0, "nothing ran, so nothing took time")
        XCTAssertTrue(brain.asked.isEmpty, "the bound is checked before the brain is touched")
        XCTAssertEqual(outcome.result.degraded, true)
    }

    /// On disk is not runnable. A model the ledger refuses by device class
    /// used to read "Ready" here, offering a button whose only possible
    /// outcome was the refusal this screen now shows up front ([MODEL-KIND]
    /// / [MODEL-SWITCH], 2026-09-21 review).
    func testLocalAdapterReportsTheLedgersRefusalInsteadOfReady() async {
        let engine = LocalBrainProbeEngine(brain: FakeBrain(),
                                           model: ModelID("refused"),
                                           isInstalled: { _ in true },
                                           unavailabilityReason: { _ in .overClassBudget },
                                           config: config())

        let readiness = await engine.readiness()

        XCTAssertEqual(readiness, .modelUnavailable(reason: .overClassBudget))
        XCTAssertNotEqual(readiness, .ready, "installed is not the same question as admitted")
    }

    /// And the store's answer is asked first: for a model that is not on the
    /// device the more useful sentence is the download row, not the class
    /// verdict the ledger would give the entry it has never seen installed.
    func testLocalAdapterPrefersTheInstallAnswerOverTheLedgersVerdict() async {
        let engine = LocalBrainProbeEngine(brain: FakeBrain(),
                                           model: ModelID("absent"),
                                           isInstalled: { _ in false },
                                           unavailabilityReason: { _ in .deviceTooSmall },
                                           config: config())

        let readiness = await engine.readiness()

        XCTAssertEqual(readiness, .modelMissing, "install it — the class verdict is for models you have")
    }

    /// The wait the card shows includes the model load, so the load is
    /// reported as its own number instead of being hidden inside the total
    /// ([MODEL-SWITCH], 2026-09-21 review): swapping models before every
    /// probe is exactly what this screen asks the owner to do, and a reload
    /// folded into the latency makes the A/B comparison a lie.
    func testLocalAdapterCarriesTheLoadShareOfTheWait() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: ["hello": "नमस्ते"],
                                                                    durationMs: 1_400,
                                                                    loadDurationMs: 1_100))
        // A scripted clock, because the split is the assertion and a split
        // needs a total this suite chose. Against the wall clock the total
        // was "however long the machine took between two reads": usually
        // zero, occasionally one millisecond, which failed the equality
        // below on a loaded host — a flake in the harness rather than in the
        // split ([MODEL-SWITCH], 2026-09-21 review round 2).
        var reads = 0
        let engine = LocalBrainProbeEngine(
            brain: brain,
            model: ModelID("named"),
            isInstalled: { _ in true },
            unavailabilityReason: { _ in nil },
            config: config(),
            now: {
                reads += 1
                return Date(timeIntervalSince1970: reads == 1 ? 0 : 0.25)
            })

        let outcome = await engine.probe("hello")

        XCTAssertEqual(outcome.loadMs, 1_100, "the model's own load, on the card beside the wait")
        XCTAssertEqual(outcome.latencyMs, 250,
                       "the whole wait, load included: the load row is a second reading of it, not a deduction from it")
    }

    /// A tier that measured no load reports `nil`, never a made-up zero: a
    /// zero on this row would read as "this model needed no loading".
    func testLocalAdapterLeavesTheLoadShareAbsentWhenNothingMeasuredIt() async {
        let brain = FakeBrain(outcome: LocalBrainTranslationOutcome(translations: ["hello": "नमस्ते"],
                                                                    durationMs: 12))
        let engine = LocalBrainProbeEngine(brain: brain,
                                           model: ModelID("named"),
                                           isInstalled: { _ in true },
                                           unavailabilityReason: { _ in nil },
                                           config: config())

        let outcome = await engine.probe("hello")

        XCTAssertNil(outcome.loadMs)
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

    // MARK: - Production wiring

    /// The ladder the coordinator hands the dropdown: the config's
    /// TRANSLATION rungs, and not the assistant brains in its tail.
    ///
    /// `AppCoordinator.makeTranslateTestDependencies` builds the rows with one
    /// call — `LocalBrainTranslationTier.translationModelIDs(from: config
    /// .brainTranslationModelIDs)` — and this drives that call against the
    /// SHIPPED default ladder, which really is two intent brains longer than
    /// its translation rungs. So the filter is load-bearing rather than
    /// decorative: without it the picker offers rows for artifacts that
    /// answer the intent schema, not `{"translations":[…]}` ([MODEL-SWITCH],
    /// 2026-09-21 review round 2).
    func testTheProductionLadderDropsTheIntentBrainTail() {
        let ladder = LiveTranslateConfig.default.brainTranslationModelIDs
        let rungs = LocalBrainTranslationTier.translationModelIDs(from: ladder)

        XCTAssertTrue(ladder.contains(ModelCatalog.intentQwen4BS43),
                      "the premise: the shipped ladder's tail carries an assistant brain")
        XCTAssertTrue(ladder.contains(ModelCatalog.intentQwen4BSlotCanon))

        XCTAssertTrue(rungs.allSatisfy(ModelCatalog.isTranslationModel),
                      "every row the screen may draw is a translation artifact")
        XCTAssertFalse(rungs.contains(ModelCatalog.intentQwen4BS43),
                       "offering this would send a translation prompt to a slot-filling brain")
        XCTAssertFalse(rungs.contains(ModelCatalog.intentQwen4BSlotCanon))
        XCTAssertEqual(rungs.first, ladder.first,
                       "the head survives the filter — the ship quant is the row this screen exists to measure")
        XCTAssertEqual(rungs.count, ladder.count - 2, "and the filter drops nothing else")
    }

    /// `makeEngines()` over a REAL store: one engine per rung, none for the
    /// intent brains, and an `isInstalled` that actually reads the disk.
    ///
    /// This is the half a fake cannot stand in for. The row marker, the
    /// readiness line and the install card all hang on the closure the
    /// coordinator builds (`modelStore.path(for:)` — the question the tier's
    /// own run gate asks), so the wiring is driven here with exactly one rung
    /// staged on a temporary root: the staged rung must read ready, and a rung
    /// with nothing on disk must report the download the card offers.
    ///
    /// The source is spelled the way the coordinator spells it rather than
    /// approximated, because a test that invents its own closure pins the
    /// screen's reading of a source that production does not build.
    @MainActor
    func testTheProductionDependenciesBuildAnEnginePerRungAndReadTheDisk() async throws {
        let config = LiveTranslateConfig.default
        let ladder = LocalBrainTranslationTier.translationModelIDs(from: config.brainTranslationModelIDs)
        let installed = try XCTUnwrap(ladder.first, "the fixture stages the head rung")
        let absent = ModelCatalog.nmtEnNeQwen17bR2bQ8
        XCTAssertTrue(ladder.contains(absent), "the other half of the fixture must be a rung of this ladder")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translate-test-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ModelStore(observabilityBus: NullObservabilityBus(),
                                   rootDirectoryOverride: root,
                                   checksumPolicy: .skip)
        try Data("not a real model".utf8).write(to: try store.stagingURL(for: installed))
        _ = try store.finalize(installed)

        let bus = NullObservabilityBus()
        let storage = LabelTranslationCacheTestStorage()
        let dependencies = TranslateTestDependencies(
            cache: LabelTranslationCache(storage: LabelTranslationCacheTestStorage(),
                                         config: config,
                                         observabilityBus: bus),
            consentGate: LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus),
            costGovernor: GeminiCostGovernor(storage: storage, observabilityBus: bus),
            client: GeminiClient(configStore: GeminiConfigStore(storage: storage), observabilityBus: bus),
            observabilityBus: bus,
            modelStore: store,
            modelSource: TranslateTestModelSource(
                ladder: ladder,
                displayName: { ModelCatalog.entry(for: $0)?.displayName(locale: Locale(identifier: "en")) ?? $0.rawValue },
                // The coordinator's own predicate: `path(for:)`, non-nil only
                // for a catalog entry whose file is on disk.
                isInstalled: { store.path(for: $0) != nil },
                unavailabilityReason: { id in
                    guard let entry = ModelCatalog.entry(for: id) else { return nil }
                    return ModelLifecycleManager.shared.availability(of: entry).reason
                }),
            isProviderConfigured: { false },
            isCloudEnabled: { false },
            startCapture: { _ in },
            cancelCapture: {})
        let built = dependencies.makeEngines()

        XCTAssertEqual(Set(built.engines.keys),
                       Set(ladder.map { TranslateTestSelection.model($0) } + [.gemini]),
                       "one engine per rung, plus the cloud — and none for a rung the tier filtered out")
        XCTAssertNil(built.engines[.model(ModelCatalog.intentQwen4BS43)],
                     "an engine here would be a row that sends an intent brain a translation prompt")

        let ready = await built.engines[.model(installed)]?.readiness()
        XCTAssertEqual(ready, .ready, "the staged artifact is the run gate's own answer: on disk")
        let missing = await built.engines[.model(absent)]?.readiness()
        XCTAssertEqual(missing, .modelMissing, "and this rung offers a download instead of a spinner")
        XCTAssertEqual(TranslateTestModel.unofferedInstallNoteKey(for: absent),
                       "settings.translateTest.install.sideloadOnly",
                       "a rung the catalog does not PUBLISH gets the sentence, never a management row")
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
