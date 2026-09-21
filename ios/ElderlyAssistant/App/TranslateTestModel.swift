import AVFoundation
import Foundation
import Speech

// MARK: - [TRANSLATE-TEST] The hidden screen's view model (2026-09-21)
//
// Everything the screen decides lives here rather than in the view, for the
// usual reason and one specific to this screen: the thing being tested is
// the ENGINES, and a suite that had to drive SwiftUI to ask "what happens
// when tier 1 has no model" would test the wrong layer. The engines arrive
// through `TranslateProbeEngine`, so every branch below is reachable with no
// model on disk, no network and no consent record.
//
// `ObservableObject`, not `@Observable`: this target's floor is iOS 16
// (`ios/project.yml`, `deploymentTarget.iOS: "16.0"`), where the macro is
// unavailable. `HomePresentationState` carries the same note — the codebase
// migrates when the floor moves, not before, so new types join the existing
// convention rather than splitting it.

@MainActor
final class TranslateTestModel: ObservableObject {

    /// Where the last run got to. Three cases, because the screen shows
    /// exactly three things: the button, a working line, and a result.
    enum RunState: Equatable {
        case idle
        case running
        case done
    }

    /// The mic BUTTON's state, following the shipped leaf-mic pattern
    /// (`DirectionsView.MicPhase`, `CallView.MicPhase`).
    ///
    /// The button and the caption are two facts, not one: a busy pipeline
    /// returns the button to idle (a second tap may well work) and still owes
    /// the person a sentence explaining why the first tap appeared to do
    /// nothing. So the caption is derived from `micFailure` below rather than
    /// read off this enum.
    enum MicPhase: Equatable {
        case idle
        case listening
        /// The capture ended without a transcript for a reason that is a
        /// fault rather than a transient: nothing heard, no audio input,
        /// recognition failed, the microphone refused.
        ///
        /// A user cancel and a busy pipeline are deliberately NOT failures of
        /// this kind — see the pair in `settleCapture`.
        case failed
    }

    /// What the composer says under the editor, or `nil` for silence.
    ///
    /// Derived (`micNotice`) rather than stored, so the caption cannot
    /// disagree with the button beside it — and so the two questions the
    /// person actually has ("why did nothing happen", "what do I do now") are
    /// answered in the copy rather than in a toast that has already gone.
    enum MicNotice: Equatable {
        /// The microphone is refused for this app: the button is hidden and
        /// the caption names the only fix, which is in Settings.
        case denied
        /// The capture never started because the assistant holds the one mic
        /// tap. Transient — the button stays offered.
        case busy
        /// Nothing was heard, or nothing recognisable was.
        case notHeard
        /// The audio input itself was unavailable — no route, no device.
        case noAudio

        /// The caption's catalog key.
        var captionKey: String {
            switch self {
            case .denied: return "settings.translateTest.mic.denied"
            case .busy: return "settings.translateTest.mic.busy"
            case .notHeard: return "settings.translateTest.mic.failed"
            case .noAudio: return "settings.translateTest.mic.audio"
            }
        }
    }

    // MARK: Inputs

    /// What to translate. Bound to the screen's `TextEditor`.
    @Published var inputText: String = ""

    /// Which row of the model dropdown the next run asks.
    ///
    /// Setting it clears the last result: a card still reading "Gemini ·
    /// 412 ms" under a model row would be a screenshot of one engine
    /// labelled as another, which is worse than an empty screen.
    ///
    /// MODEL switching gets the same treatment engine switching did, and for
    /// the same reason: two ladder entries are two different engines as far
    /// as this screen is concerned — different weights, different answers,
    /// different latencies — so an answer computed with one must not be
    /// displayed under the other's name.
    @Published var selection: TranslateTestSelection = .gemini {
        didSet {
            guard oldValue != selection else { return }
            // The OPENING row is not a switch. `selection` carries an initial
            // value AND an observer, so assigning it from an initializer (or
            // from `configure`) goes through a real setter and fires this —
            // verified against swiftc, because the language's "observers do
            // not run during initialization" rule does not cover a property
            // whose storage the wrapper already owns. Left unguarded that
            // spawned a readiness task nobody asked for, from the screen's
            // own construction, and gave `configure` a second walk of the
            // ladder beside the one its caller makes.
            guard !isChoosingOpeningRow else { return }
            // A run in flight asked the OLD engine. Its answer would arrive
            // to find the cards cleared for the new one and would be read as
            // the new engine's — the one mislabelling this screen must not
            // have — so it is dropped here, at the source. The engine that
            // asked is also re-checked after the await (`run()`), because a
            // probe that had already returned when the picker moved is past
            // the point where cancelling means anything.
            runTask?.cancel()
            runTask = nil
            outcome = nil
            runState = .idle
            // The old answer described the old engine, so it stops being
            // displayed immediately and is re-asked for the new one: a
            // readiness line about the engine you just left is the one
            // thing this card must never show.
            readiness = nil
            Task { await refreshReadiness() }
        }
    }

    // MARK: State the view reads

    @Published private(set) var runState: RunState = .idle
    /// The last run's answer. Non-nil once a run has finished, and cleared
    /// when the engine changes. Held as the engine's own vocabulary
    /// (`TranslationResult`) so the screen renders tiers, degradations and
    /// errors through the same types the camera overlay does.
    @Published private(set) var outcome: TranslateProbeOutcome?
    /// Whether the selected engine can run right now, as of the last ask.
    /// `nil` before the first ask, so the screen can hold the button rather
    /// than offer an engine it has not checked.
    @Published private(set) var readiness: TranslateEngineReadiness?
    /// The dropdown's model rows, in the ladder's own order, each with the
    /// name the catalog gives it and whether the device can run it now.
    ///
    /// Built from the dependency's `TranslateTestModelSource` — the ladder,
    /// live — rather than from a list written here, so a catalog that adds,
    /// retires or reorders translation models changes this dropdown with no
    /// code change on this screen (a sibling workstream is swapping the
    /// catalog's translation head; this must keep working when it lands).
    /// Empty until the screen configures, which is also when the picker is
    /// drawn for the first time — so the list is never shown half-built.
    @Published private(set) var modelOptions: [TranslateTestModelOption] = []
    @Published private(set) var micPhase: MicPhase = .idle
    /// Why the last capture ended without a transcript. Kept beside
    /// `micPhase` rather than inside it so the caption can name the reason
    /// without the phase enum carrying a payload the button's state does not
    /// need.
    ///
    /// `nil` exactly when there is nothing to say: before any capture, after
    /// a transcript, and after the person's own cancel — the one outcome they
    /// do not need told about. A busy pipeline is recorded here even though
    /// it is not a fault: the tap looked like it did nothing, and a caption
    /// is the whole of what that case owes them.
    @Published private(set) var micFailure: SearchPhraseCapture.Failure?
    /// True once this visit has been told the microphone is not usable — a
    /// refusal at the tap, or a permission read that says the same. The
    /// shipped leaves' rule (`DirectionsView.micHidden`): the button hides
    /// rather than offering a tap that can only fail again.
    @Published private(set) var micHidden = false
    /// This screen's cloud-activity indicator, built with the engines.
    /// OD-13 requires a visible indicator while the cloud tier is active, and
    /// this screen gives the tier its own indicator (there is no session
    /// here) — so this screen must render the one its tier moves.
    @Published private(set) var cloudIndicator: CloudActivityIndicatorModel?

    // MARK: Dependencies

    /// Empty until the screen configures them — see `configure(with:)`.
    /// One entry per dropdown row, Gemini included.
    private var engines: [TranslateTestSelection: any TranslateProbeEngine] = [:]
    /// Kept, not just read once at configure, because "is this model on the
    /// device" is a question about the device rather than a value captured
    /// when the screen was built — a download can finish while it is open.
    private var modelSource: TranslateTestModelSource?
    /// The inner `@escaping` matches `TranslateTestDependencies`: the
    /// completion outlives the call that starts the capture, so the type
    /// says so (and only then can a coordinator forward it on).
    private var startCapture: (@escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) -> Void = { _ in }
    private var cancelCapture: () -> Void = {}
    /// True while the screen's OPENING row is being assigned — from the
    /// initializer, or from `configure`. The observer above does nothing for
    /// either: the transient state is already at its opening values, and the
    /// caller that configures the screen asks for readiness itself. See the
    /// observer's note.
    private var isChoosingOpeningRow = true
    /// A row's composed label, keyed by model, state and locale. The picker
    /// asks for every visible row on every redraw, and composing one is a
    /// catalog lookup plus a localization scan; the answer changes only when
    /// the rows are rebuilt, which is what empties this.
    private var labelCache: [String: String] = [:]
    /// The in-flight run, so a second tap supersedes the first instead of
    /// racing it: two results arriving out of order would show the slower
    /// engine's answer.
    private var runTask: Task<Void, Never>?

    /// The screen's own init. Dependencies arrive through `configure`
    /// rather than here because they come from the environment, which is
    /// not readable while a `@StateObject` is being built — every parameter
    /// below is defaulted so `TranslateTestModel()` is that no-arg init.
    ///
    /// The test-facing init takes the same parameters without the
    /// environment, and with `modelSource` beside the engines because a
    /// suite that scripts answers still has to say which models exist.
    init(engines: [TranslateTestSelection: any TranslateProbeEngine] = [:],
         modelSource: TranslateTestModelSource? = nil,
         startCapture: @escaping (@escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) -> Void = { _ in },
         cancelCapture: @escaping () -> Void = {}) {
        self.engines = engines
        self.modelSource = modelSource
        // The same opening rule `configure` applies, so a suite that injects
        // a source drives the screen it will actually see — assigned with the
        // flag up, because the observer DOES fire from an initializer here
        // (see its note), and a switch it did not ask for is a readiness walk
        // the caller never made.
        self.modelOptions = modelSource.map(Self.options(from:)) ?? []
        self.selection = Self.defaultSelection(options: self.modelOptions)
        self.isChoosingOpeningRow = false
        self.startCapture = startCapture
        self.cancelCapture = cancelCapture
    }

    /// Adopts the coordinator's own instances, once.
    ///
    /// The engines are built here rather than per run because tier 1 holds a
    /// resident model handle across calls — constructing a tier per tap
    /// would reload the weights every time. Idempotent, so the screen can
    /// call it from `.task` without racing a re-appearance.
    func configure(with dependencies: TranslateTestDependencies) {
        guard engines.isEmpty else { return }
        let built = dependencies.makeEngines()
        engines = built.engines
        cloudIndicator = built.cloudIndicator
        modelSource = dependencies.modelSource
        startCapture = dependencies.startCapture
        cancelCapture = dependencies.cancelCapture
        // The rows, ONCE, through the one walk — the init's copy and this one
        // used to be joined by a third from `refreshReadiness`, which the
        // caller makes a moment later anyway.
        refreshModelOptions()
        // The opening row: the first model the device can actually run,
        // falling back to the first ladder entry (which offers its download)
        // and then to Gemini. Assigned with the flag up, so it is the opening
        // value rather than a switch — the caller's own `refreshReadiness()`
        // is this screen's ask on appearing, and a second one spawned here
        // would be two walks of the same ladder for one appearance.
        let opening = Self.defaultSelection(options: modelOptions)
        isChoosingOpeningRow = true
        selection = opening
        isChoosingOpeningRow = false
    }

    // MARK: - The dropdown

    /// The ladder as dropdown rows. Pure and static so the mapping — ladder
    /// order, catalog name, live install state — is pinned by a test rather
    /// than by inspection.
    ///
    /// Duplicates are dropped rather than drawn twice: a ladder that names
    /// the same model in two slots is a config that would show two identical
    /// rows with two different selection values, and the second one could
    /// never be reached by looking at the screen.
    static func options(from source: TranslateTestModelSource) -> [TranslateTestModelOption] {
        var seen: Set<ModelID> = []
        return source.ladder.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return TranslateTestModelOption(id: id,
                                            displayName: source.displayName(id),
                                            isInstalled: source.isInstalled(id),
                                            isUnavailable: source.unavailabilityReason(id) != nil)
        }
    }

    /// The row the screen opens on.
    ///
    /// The first model the device can actually **run** — asked through the
    /// TIER'S own resolution rule (`LocalBrainTranslationTier
    /// .resolvedModel(in:isAvailable:)`, the function `installedModel()` is
    /// built from) rather than through a second "first where installed"
    /// spelled here, so the row this screen opens on is the rung the
    /// pipeline would itself pick ([MODEL-SWITCH], 2026-09-21 review).
    ///
    /// **"Runnable" is two questions, not one** (2026-09-21 review round 2):
    /// the artifact is on the device AND the device class does not refuse it.
    /// The installed test alone put the opening row on a rung this phone
    /// cannot run — the screen would open on a model whose first attempt could
    /// only answer `.modelUnavailable`, with the download card hidden (there
    /// is nothing to download) and no way forward but a manual pick. The
    /// tier's own resolution skips those rungs; this is that skip rule.
    ///
    /// Failing that, the first row at all: an uninstalled model is a valid
    /// selection whose card offers that model's download, which is a better
    /// opening screen than a cloud path the household may have switched off.
    static func defaultSelection(options: [TranslateTestModelOption]) -> TranslateTestSelection {
        let resolved = LocalBrainTranslationTier.resolvedModel(in: options.map(\.id)) { id in
            guard let option = options.first(where: { $0.id == id }) else { return false }
            return option.isInstalled && !option.isUnavailable
        }
        return resolved.map { .model($0) }
            ?? options.first.map { .model($0.id) }
            ?? .gemini
    }

    /// The dropdown row the selection names, or `nil` for Gemini (and for a
    /// model the source no longer lists — the installed state is read from
    /// the row, so nothing is drawn for a model with no row).
    var selectedModelOption: TranslateTestModelOption? {
        guard case .model(let id) = selection else { return nil }
        return modelOptions.first { $0.id == id }
    }

    /// The name to print for the selected model: the row's, when the source
    /// has one, and the raw id when it does not.
    ///
    /// The raw-id half is a contract for a hand-built source rather than a
    /// case production reaches ([MODEL-SWITCH], 2026-09-21 review round 2):
    /// the ladder is filtered by catalogue membership
    /// (`LocalBrainTranslationTier.translationModelIDs(from:)` is a
    /// `ModelCatalog.isTranslationModel` filter), so every rung the screen
    /// draws has an entry and a name. It is kept because the rows are a
    /// caller's to build — the same reason `TranslateTestModelSource
    /// .displayName` keeps its fallback.
    ///
    /// `nil` exactly when the selection is not a model ([MODEL-SWITCH],
    /// 2026-09-21 review). It used to be `""` for Gemini, which is a name
    /// that reads as a missing one — and the callers that were supposed to
    /// be guarded by "nobody asks about Gemini" were not checked by the
    /// compiler. An optional makes every caller decide what a model-less
    /// row means.
    var selectedModelName: String? {
        guard let option = selectedModelOption else { return selection.modelID?.rawValue }
        return option.displayName
    }

    /// A dropdown row's text, composed by the SAME function the AI-models
    /// pickers use (`AIModelsSettingsView.sttOptionLabel`) rather than by a
    /// copy of it written here.
    ///
    /// [MODEL-SWITCH] (2026-09-21 review): the copy had drifted — it always
    /// appended a state marker, so an installed row said "Ready" and a row
    /// the DEVICE CLASS refuses said "Ready" too, while the settings row for
    /// the same artifact said "not for this phone". One composer means
    /// "installed" and "this phone cannot run it" mean the same thing on
    /// every screen that says them, and the warden's marker is why a refused
    /// row can no longer claim to be ready.
    ///
    /// The raw-id fallback is this screen's own: the shared composer takes a
    /// catalog entry, and a row for an id this build does not carry has none.
    /// Showing the id is the honest answer for a dev screen, and it keeps
    /// the row selectable. Unreachable through the production ladder, which
    /// is filtered by catalogue membership (see `selectedModelName`) — it is
    /// kept for the same reason: the rows are a caller's to build, and the
    /// test that pins it builds exactly that caller.
    ///
    /// Memoized per (model, state, locale): the picker asks for every row on
    /// every redraw, and each compose is a catalog lookup plus a localization
    /// scan for an answer that can only change when the rows are rebuilt.
    func label(for option: TranslateTestModelOption, locale: Locale) -> String {
        let key = "\(option.id.rawValue)|\(option.isInstalled)|\(option.isUnavailable)|\(locale.identifier)"
        if let cached = labelCache[key] { return cached }
        let label: String
        if let entry = ModelCatalog.entry(for: option.id) {
            label = AIModelsSettingsView.sttOptionLabel(entry: entry,
                                                        downloaded: option.isInstalled,
                                                        unavailable: option.isUnavailable,
                                                        locale: locale)
        } else {
            label = option.displayName
        }
        labelCache[key] = label
        return label
    }

    // MARK: - Running a translation

    /// The trimmed text a run would send. Whitespace-only input is not a
    /// translation request.
    var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the Translate button does anything. The button is disabled
    /// when this is false, so a tap can never start a run the screen has
    /// already decided is pointless.
    var canRun: Bool {
        !trimmedInput.isEmpty && runState != .running && readiness == .ready
    }

    /// Asks the selected engine for its readiness. Called when the screen
    /// appears, when the selection changes, and when a download settles —
    /// the three moments the answer can change.
    ///
    /// It refreshes the dropdown's labels FIRST, and both live here because
    /// they are the same question asked about the same trigger: the rows and
    /// the line under them say whether a model is installed, and a caller
    /// that updated one without the other would draw a row marked
    /// "downloadable" above a line that says the model is missing — the two
    /// halves of one sentence, disagreeing on screen.
    func refreshReadiness() async {
        refreshModelOptions()
        let current = selection
        // Unconfigured (the screen has not appeared yet) leaves the answer
        // alone rather than clearing it: "not asked" and "asked and refused"
        // are different states, and this one resolves on its own a moment
        // later.
        guard let probe = engines[current] else { return }
        let next = await probe.readiness()
        // Guarded: an answer that arrives after the picker moved describes
        // the engine that is no longer selected.
        guard current == selection else { return }
        readiness = next
    }

    /// Re-reads the install state behind every row. Cheap (one store query
    /// per ladder entry, and the ladder is a handful), and published only on
    /// a real change so a readiness re-ask cannot spin the view.
    ///
    /// **The one walk** ([MODEL-SWITCH], 2026-09-21 review): the initializer,
    /// `configure` and every readiness refresh all come through here — they
    /// each used to rebuild the rows for themselves, which is three walks of
    /// the same ladder for one appearance. The label cache is emptied with
    /// the rows, because a label is a fact about a row's state.
    private func refreshModelOptions() {
        guard let source = modelSource else { return }
        let next = Self.options(from: source)
        guard next != modelOptions else { return }
        modelOptions = next
        labelCache.removeAll(keepingCapacity: true)
    }

    /// Runs one translation through the selected engine.
    func run() async {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        let asked = selection
        guard let probe = engines[asked] else { return }

        runTask?.cancel()
        runState = .running
        outcome = nil

        let task = Task { @MainActor [weak self] in
            let answer = await probe.probe(text)
            guard let self, !Task.isCancelled else { return }
            // Asked-is-not-selected: the picker may have moved while the
            // engine worked — to another model as much as to the cloud. The
            // cards were reset for the row on screen now, so an answer from
            // the one that was asked is dropped rather than displayed under
            // the wrong name.
            guard self.selection == asked else { return }
            self.outcome = answer
            self.runState = .done
        }
        runTask = task
        await task.value
        // The run itself can change what the selected engine needs next: the
        // cloud tier spends budget (and can retire a consent grant), and the
        // household can clear the key while the request is in flight. Re-asked
        // here so the line under the picker describes the engine as it is NOW
        // rather than as it was before the run.
        await refreshReadiness()
    }

    // MARK: - Dictation

    /// Whether the mic button may be shown at all.
    ///
    /// The shipped leaves' rule, spelled the same way (`DirectionsView`):
    /// hidden once this visit has been told a no, and hidden live while the
    /// permission read says so. `.notDetermined` counts as visible — the ask
    /// happens at the tap, at the point of use.
    var micButtonVisible: Bool {
        guard !micHidden else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: break
        case .denied, .restricted: return false
        @unknown default: return false
        }
        if Self.recordPermissionDenied() { return false }
        return true
    }

    /// The caption under the editor, or `nil` for silence.
    ///
    /// Derived from the facts rather than stored, so the sentence cannot
    /// describe a state the button is not in. A refusal is reported even
    /// though the button is gone: a button that vanished with no sentence is
    /// how a person concludes the screen is broken.
    var micNotice: MicNotice? {
        if micHidden { return .denied }
        switch micFailure {
        case .notAuthorized: return .denied
        case .busy: return .busy
        case .noSpeech, .recognitionFailed: return .notHeard
        case .audioUnavailable, .noAudioInput: return .noAudio
        case .cancelled, .none: return nil
        }
    }

    /// Re-reads the microphone permission — called when the screen appears
    /// and when the app returns to the foreground, the two moments it can
    /// have changed under us (the fix for a denial lives in Settings).
    ///
    /// Sets, never clears, exactly as the leaves' `updateMicVisibility` does:
    /// the hide is for this visit, and `micButtonVisible` reads the live
    /// permission beside it — so a grant made in Settings is honoured by that
    /// read rather than by anything this has to undo.
    func refreshMicVisibility() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            micHidden = true
        default:
            if Self.recordPermissionDenied() { micHidden = true }
        }
    }

    /// The record-permission read, spelled as the leaves spell it
    /// (`DirectionsView.micRecordPermissionDenied`) so the two screens cannot
    /// disagree about whether the microphone is usable.
    private static func recordPermissionDenied() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }

    /// The mic button's tap. One button, two jobs: it starts a capture, and
    /// a second tap on a live capture ends it (the shipped leaf-mic
    /// behaviour — see `DirectionsView`).
    func toggleDictation() {
        switch micPhase {
        case .listening:
            cancelDictation()
        case .idle, .failed:
            startDictation()
        }
    }

    private func startDictation() {
        guard micPhase != .listening else { return }
        micFailure = nil
        micPhase = .listening
        // A capture the coordinator refuses to start — another holder owns the
        // engine's one tap — does not strand this phase: the coordinator
        // guards its arbitration flag BEFORE it starts anything and reports
        // `.busy` through this same completion, which `settleCapture` turns
        // into idle-plus-caption. (`SearchPhraseCapture.start`'s own silent
        // bail for a second concurrent start is unreachable through this path
        // for that reason, and is not something this screen has to defend
        // against twice.)

        // `[weak self]`: the capture outlives the view briefly (it runs
        // while the voice pipeline is suspended), and a completion that
        // arrives after the screen is gone must not resurrect it.
        startCapture { [weak self] result in
            guard let self else { return }
            self.settleCapture(result)
        }
    }

    /// Ends a live capture. The coordinator's completion still fires — it is
    /// what restarts the suspended voice pipeline — so the phase is left for
    /// `settleCapture` to reset, exactly as the shipped leaves do.
    func cancelDictation() {
        guard micPhase == .listening else { return }
        cancelCapture()
    }

    /// Settles one capture. `internal` rather than `private` so a suite can
    /// drive the outcome without a live microphone — the completion is the
    /// only thing a test cannot fake through the injected `startCapture`.
    func settleCapture(_ result: Result<String, SearchPhraseCapture.Failure>) {
        switch result {
        case .success(let transcript):
            inputText = Self.appending(transcript, to: inputText)
            micPhase = .idle
            micFailure = nil
        case .failure(let failure):
            switch failure {
            case .cancelled:
                // The person's own second tap. Nothing happened that they do
                // not already know about, so nothing is said and no caption
                // is owed — the one outcome that stays silent.
                micPhase = .idle
                micFailure = nil
            case .busy:
                // The engine already had a capture in flight. Transient, so
                // the button is offered again — but the tap LOOKED like it
                // did nothing, and silence there reads as a broken button
                // rather than as a busy assistant. The caption is the whole
                // of what this case owes the person, and it is the reason
                // this case is no longer folded in with `.cancelled`.
                micPhase = .idle
                micFailure = .busy
            case .notAuthorized:
                // Denied at the point of use: the button is honestly dead for
                // this visit and Settings can reverse it — the leaves' own
                // handling (`DirectionsView.micHidden`), so the two screens
                // refuse the same way. The caption names the fix, since a
                // button that simply vanishes explains nothing.
                micHidden = true
                micPhase = .idle
                micFailure = failure
            case .noSpeech, .audioUnavailable, .noAudioInput,
                 .recognitionFailed:
                micPhase = .failed
                micFailure = failure
            }
        }
    }

    /// Appends a transcript to the field.
    ///
    /// A space between utterances and never before the first one, and a
    /// transcript that already begins with whitespace keeps its own
    /// separator — so a second dictation reads as continuous prose rather
    /// than running into the first word.
    ///
    /// Pure and static so the rule is pinned by a test instead of by
    /// inspection.
    static func appending(_ transcript: String, to existing: String) -> String {
        guard !transcript.isEmpty else { return existing }
        guard !existing.isEmpty else { return transcript }
        if existing.last?.isWhitespace == true { return existing + transcript }
        if transcript.first?.isWhitespace == true { return existing + transcript }
        return existing + " " + transcript
    }

    // MARK: - Installs

    /// The ids whose download has finished, out of the service's live states.
    ///
    /// The service republishes `states` on every progress chunk of every
    /// download, so this is the only part of that stream the screen acts on:
    /// comparing it is what turns "ask again when an install finishes" into
    /// one ask per finished install instead of one per chunk. Pure and static
    /// so the rule is pinned by a test rather than by inspection.
    static func completedInstalls(in states: [ModelID: ModelDownloadState]) -> Set<ModelID> {
        Set(states.compactMap { entry in entry.value == .completed ? entry.key : nil })
    }

    /// The catalog entry this screen may OFFER as a download for `id`, or
    /// `nil` when it may not ([MODEL-SWITCH], 2026-09-21 review round 2).
    ///
    /// **The offer is the catalog's, not the ladder's.** A ladder rung is a
    /// model the TIER will try; it is not a promise that this build publishes
    /// the artifact for download, and several rungs exist precisely so a
    /// device that sideloaded them keeps working (the round-4 Q8 ceiling, the
    /// superseded quants). This screen used to draw a full management row —
    /// Download, Cancel, **Delete** — for every rung the catalog happened to
    /// carry, which made it the one place in the app offering an in-app
    /// download for models the AI-models screen deliberately never offers.
    ///
    /// So the list is `ModelCatalog.availableTranslationEntries`: the SAME
    /// list the Settings translation section's own download row draws from,
    /// asked rather than re-spelled, so the two surfaces cannot disagree
    /// about what a household may fetch.
    static func offeredEntry(for id: ModelID) -> ModelCatalogEntry? {
        ModelCatalog.availableTranslationEntries.first { $0.id == id }
    }

    /// The sentence for a rung this screen cannot offer — one of the two
    /// cases the catalog leaves, keyed by which one it is.
    ///
    /// An id no entry carries at all (a catalog swap mid-flight) and an
    /// artifact this build carries but does not publish (sideload-only) are
    /// different facts, and the household's next action differs: nothing can
    /// be installed for the first, and the file must be put on the device by
    /// hand for the second. Pure and static so both halves are pinned by a
    /// test rather than by inspection.
    static func unofferedInstallNoteKey(for id: ModelID) -> String {
        ModelCatalog.entry(for: id) == nil
            ? "settings.translateTest.install.unknown"
            : "settings.translateTest.install.sideloadOnly"
    }

    // MARK: - Teardown

    /// The screen went away: stop listening and drop the in-flight run.
    ///
    /// Leaving the mic open behind a dismissed sheet is the one failure this
    /// screen must not have — the capture holds the engine's only tap and
    /// keeps the voice pipeline suspended until it settles.
    func onDisappear() {
        if micPhase == .listening {
            cancelCapture()
        }
        micPhase = .idle
        micFailure = nil
        // The run is cancelled, so nothing will ever set `.done`. Leaving
        // `.running` behind would strand the button on "Translating…" and
        // disabled for the whole life of the model if the screen comes back
        // (the model survives disappearance; the view's is a `@StateObject`).
        runTask?.cancel()
        runTask = nil
        runState = .idle
    }
}

// MARK: - Reading a degradation

extension TranslationResult {
    /// The reason this result was degraded, when it was.
    ///
    /// Derived here rather than added to the shipped type: nothing in the
    /// pipeline has needed to name the reason outside the enum, and a dev
    /// screen is not a good enough reason to widen a production type's
    /// surface. The associated value is the whole of the answer, so this is
    /// a read, not a second source of truth.
    var degradedReason: TranslationUnavailableReason? {
        guard case .degraded(_, let reason) = outcome else { return nil }
        return reason
    }
}
