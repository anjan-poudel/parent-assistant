import Foundation

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

    /// The mic button's state, following the shipped leaf-mic pattern
    /// (`DirectionsView.MicPhase`, `CallView.MicPhase`).
    enum MicPhase: Equatable {
        case idle
        case listening
        /// The capture ended without a transcript for a reason worth
        /// putting on screen — nothing heard, no audio input, recognition
        /// failed.
        ///
        /// A user cancel and a busy pipeline are deliberately NOT failures:
        /// both are transient, both are silent, and neither is a fault the
        /// person tapping the button should be asked to read about.
        case failed
    }

    // MARK: Inputs

    /// What to translate. Bound to the screen's `TextEditor`.
    @Published var inputText: String = ""

    /// Which engine the next run asks.
    ///
    /// Setting it clears the last result: a card still reading "Gemini ·
    /// 412 ms" under a Local picker would be a screenshot of one engine
    /// labelled as another, which is worse than an empty screen.
    @Published var selectedEngine: TranslateTestEngine = .local {
        didSet {
            guard oldValue != selectedEngine else { return }
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
    @Published private(set) var micPhase: MicPhase = .idle
    /// Why the last capture failed, when it did. Kept beside `micPhase`
    /// rather than inside it so the caption can name the reason without the
    /// phase enum carrying a payload the button's state does not need.
    ///
    /// Non-nil exactly when `micPhase == .failed`: a transient outcome
    /// (a cancel, a busy pipeline) leaves both untouched, so "there is a
    /// fault worth showing" is one fact and not two that could disagree.
    @Published private(set) var micFailure: SearchPhraseCapture.Failure?

    // MARK: Dependencies

    /// Empty until the screen configures them — see `configure(with:)`.
    private var engines: [TranslateTestEngine: any TranslateProbeEngine] = [:]
    /// The inner `@escaping` matches `TranslateTestDependencies`: the
    /// completion outlives the call that starts the capture, so the type
    /// says so (and only then can a coordinator forward it on).
    private var startCapture: (@escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) -> Void = { _ in }
    private var cancelCapture: () -> Void = {}
    /// The in-flight run, so a second tap supersedes the first instead of
    /// racing it: two results arriving out of order would show the slower
    /// engine's answer.
    private var runTask: Task<Void, Never>?

    /// The screen's own init. Dependencies arrive through `configure`
    /// rather than here because they come from the environment, which is
    /// not readable while a `@StateObject` is being built.
    init() {}

    init(engines: [TranslateTestEngine: any TranslateProbeEngine],
         startCapture: @escaping (@escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) -> Void,
         cancelCapture: @escaping () -> Void) {
        self.engines = engines
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
        engines = dependencies.makeEngines()
        startCapture = dependencies.startCapture
        cancelCapture = dependencies.cancelCapture
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
    /// appears, when the engine changes, and when a download settles — the
    /// three moments the answer can change.
    func refreshReadiness() async {
        let engine = selectedEngine
        // Unconfigured (the screen has not appeared yet) leaves the answer
        // alone rather than clearing it: "not asked" and "asked and refused"
        // are different states, and this one resolves on its own a moment
        // later.
        guard let probe = engines[engine] else { return }
        let next = await probe.readiness()
        // Guarded: an answer that arrives after the picker moved describes
        // the engine that is no longer selected.
        guard engine == selectedEngine else { return }
        readiness = next
    }

    /// Runs one translation through the selected engine.
    func run() async {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        guard let engine = engines[selectedEngine] else { return }

        runTask?.cancel()
        runState = .running
        outcome = nil

        let task = Task { @MainActor [weak self] in
            let probe = await engine.probe(text)
            guard let self, !Task.isCancelled else { return }
            self.outcome = probe
            self.runState = .done
        }
        runTask = task
        await task.value
    }

    // MARK: - Dictation

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
            case .cancelled, .busy:
                // A second tap, or the assistant mid-turn. Transient and
                // silent: there is nothing the person should do about it,
                // so nothing is recorded for them to read either. The
                // invariant this keeps — `micFailure != nil` means exactly
                // "there is a fault worth showing" — is what stops a later
                // caption from rendering a cancel as an error.
                micPhase = .idle
                micFailure = nil
            case .notAuthorized, .noSpeech, .audioUnavailable, .noAudioInput,
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
        runTask?.cancel()
        runTask = nil
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
