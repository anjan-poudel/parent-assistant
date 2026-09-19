import AVFoundation
import Combine
import Foundation
import UIKit

// T-026 — C13's observation surface: the session model (FR-LCT-018,
// FR-LCT-022, FR-LCT-023; NFR-LCT-010, NFR-LCT-011).
//
// What this file exists to make true:
//
//  1. **The model is the single observation surface.** The view holds no
//     session state of its own (T-021's overlay is a pure function of its
//     surface, and this is what feeds it). Every value the view renders is a
//     property of this object — including the consent controller's, whose
//     `objectWillChange` is forwarded rather than re-published as a second
//     copy that could drift from its owner.
//
//  2. **All model state is main-confined.** The class is `@MainActor`; the
//     pipeline is an actor that hands publications over in coherent values;
//     the two meet in `receive(_:)`, which is the only writer of
//     `publication`. Nothing here is locked, because nothing here is shared.
//
//  3. **Start is idempotent; close is terminal.** A re-entrant appear must not
//     start a second session (`start` refuses once it has started, and refuses
//     after close), and after close no publication, no frame and no command
//     outcome can reach the model — the frame loop is cancelled, the capture is
//     closed and the pipeline is closed, in that order.
//
//  4. **One session-scoped task tree.** The frame loop is the only task this
//     object owns; the pipeline owns the cloud attempts and the capture owns
//     the microphone window. Closing cancels the loop and closes both, and the
//     design's teardown order is structural: recognition stops, the command
//     window drains, the audio session is released, and only then does the
//     camera session stop (`LiveTranslateCommandCapture.close(then:)`).
//
//  5. **The entry costs nothing until it is opened.** Nothing in this file is
//     built until `start()`: the pipeline is created there (not in `init`), so
//     a plugin that is registered but never opened creates no capture session,
//     no recognition request and no network client (NFR-LCT-012).
//
//  6. **The session never hears itself.** The command capture's microphone
//     gate is `LiveTranslateSpeech.isSpeaking` — one wiring, no second speech
//     path and no second microphone stack.
//
//  7. **A freeze is state here, not in the view (T-033).** The frozen frame
//     is a `LiveTranslateSnapshot` this object holds, and everything the view
//     draws while it is held — the picture, the overlay's placements, the
//     control's own label — is read off it through the same properties the
//     live path uses (`activePublication`, `surface`, `frozenFrameImage`). The
//     view has no freeze state of its own to fall out of step with the model,
//     which is the same rule as (1) applied to the one piece of state a
//     snapshot adds. The frame is held in memory for as long as the elder
//     holds it and is released on thaw and on close; nothing writes it
//     anywhere (OD-13, NFR-LCT-005).

/// Everything a session needs, resolved when the feature is opened.
///
/// The app layer builds this on demand; tests build it with doubles. It is a
/// value of references, deliberately: the model composes the session from it
/// and owns no factory of its own, so there is exactly one place that decides
/// what a production session is made of.
struct LiveTranslateSessionDependencies {
    let locale: Locale
    let camera: LiveCameraSession
    let detector: LiveTextDetector
    let cache: LabelTranslationCache
    let consentGate: LiveTranslateConsentGate
    let costGovernor: GeminiCostGovernor
    let client: GeminiClient
    let speechPath: LiveTranslateSpeechPath
    let captureDevice: LiveTranslateUtteranceCapturing
    let audioSession: AudioSessionManager
    let settings: LiveTranslateSettings
    let notifications: NotificationCenter
    let observabilityBus: ObservabilityBus
    let config: LiveTranslateConfig

    init(locale: Locale,
         camera: LiveCameraSession,
         detector: LiveTextDetector,
         cache: LabelTranslationCache,
         consentGate: LiveTranslateConsentGate,
         costGovernor: GeminiCostGovernor,
         client: GeminiClient,
         speechPath: LiveTranslateSpeechPath,
         captureDevice: LiveTranslateUtteranceCapturing,
         audioSession: AudioSessionManager,
         settings: LiveTranslateSettings,
         notifications: NotificationCenter = .default,
         observabilityBus: ObservabilityBus,
         config: LiveTranslateConfig = .default) {
        self.locale = locale
        self.camera = camera
        self.detector = detector
        self.cache = cache
        self.consentGate = consentGate
        self.costGovernor = costGovernor
        self.client = client
        self.speechPath = speechPath
        self.captureDevice = captureDevice
        self.audioSession = audioSession
        self.settings = settings
        self.notifications = notifications
        self.observabilityBus = observabilityBus
        self.config = config
    }
}

/// C13's session model: one session's life, from appear to close.
@MainActor
final class LiveTranslateSessionModel: ObservableObject {

    /// Where the session is in its life. `failed` carries the start failure
    /// rather than collapsing every outcome into "not running", because T-008's
    /// surfaces differ per failure and the view renders them.
    enum Phase: Equatable {
        case idle
        case starting
        case running
        /// Start failed with an outcome the elder can act on (permission,
        /// camera, resources). The view renders T-008's surface for it.
        case failed(LiveTranslateError)
        case closed
    }

    // MARK: Observation surface

    /// The newest coherent publication, or nil before the first cycle. The
    /// view never sees a partially updated one: the pipeline hands over whole
    /// values, and this property is assigned exactly once per publication.
    @Published private(set) var publication: LiveTranslatePublication?

    /// The frozen frame, or nil while the session is live (T-033).
    ///
    /// A freeze is *holding a publication* — the value the live cycle already
    /// publishes — not a second rendering path: the overlay and the speech
    /// path read it through `activePublication`, so what is drawn on the
    /// frozen picture and what is spoken from it are the same placements as
    /// ever. The picture itself is held here, in memory, and released on thaw
    /// and on close; nothing writes it anywhere (OD-13, NFR-LCT-005).
    @Published private(set) var frozen: LiveTranslateSnapshot?
    @Published private(set) var phase: Phase = .idle

    /// T-008's surface when start ended in a state the elder must act on.
    @Published private(set) var cameraSurface: CameraPermissionSurface.State?

    /// Whether the session has an open command window (T-025).
    @Published private(set) var isListening = false

    /// Whether the session is paused for a background transition. The view
    /// shows nothing for it (the app is not on screen); it exists as evidence
    /// and as the guard the lifecycle works through.
    @Published private(set) var isPaused = false

    /// Whether a freeze is in flight: true from the tick of the capture
    /// control until the picture is held.
    ///
    /// The tap buys a wait — the raster, one still pass over the frame, and the
    /// placement — during which nothing on screen changes: the camera picture
    /// keeps moving and no card is up. Without this flag "working", "slow" and
    /// "broken" are the same experience (owner, device testing: "I could not
    /// tell if it was working, slow, or broken"), so the control draws the wait
    /// from this one value (`snapshotSurface`). It is `true` for exactly the
    /// window between the tap and `frozen` being set, on every path out of that
    /// window — including the ones where nothing is ever held.
    @Published private(set) var freezeInProgress = false

    /// The FR-LCT-017 preference, as the control renders it.
    @Published private(set) var alwaysShowOriginal: Bool

    /// The cloud tier's master switch, as the Settings leaf renders it and as
    /// the pipeline is gated by (owner directive, 2026-09-19).
    ///
    /// Read from `LiveTranslateSettings` when the session is built and
    /// mirrored on every write, so the value the elder sees in Settings, the
    /// value the session model publishes and the value the gate reads are one
    /// value rather than three that have to be kept in step.
    @Published private(set) var geminiCloudEnabled: Bool

    /// **Extract mode** (owner verdict, 2026-09-18), as the mode control
    /// renders it: `true` ⇒ the overlay shows the recognized text and no tier
    /// runs until a block is asked for; `false` ⇒ the translated view.
    ///
    /// It opens at the config's own default (`extractModeDefault`), which is
    /// the mode the feature ships in. It is session state rather than a stored
    /// preference, deliberately: it is a *view* the elder is in, not an
    /// accessibility setting that should follow them into every session, and
    /// the translated view is one tap away whenever they want it.
    @Published private(set) var isExtracting: Bool

    /// The warden's current notice, or nil when there is nothing to say
    /// (owner directive, 2026-09-19: "keep the user in the loop so they don't
    /// wonder about the silences").
    ///
    /// A *status*, not a prompt: the tier pushes one of
    /// `LocalBrainWardenNotice`'s two moments when it pays a model load or
    /// hands its handle to the voice stack, this property carries it to the
    /// screen, and the dismissal below takes it down again. Nothing waits on
    /// the elder to acknowledge it, and nothing here can outlive the wait it
    /// explains — see `noteWardenNotice(_:)`.
    ///
    /// The sentence is never stored: the view resolves `copyKey` through
    /// `L10n` in the active language (`wardenNoticeSurface`), so a notice
    /// cannot exist with a stale or literal wording.
    @Published private(set) var wardenNotice: LocalBrainWardenNotice?

    /// The camera preview layer, or nil until the session's capture session
    /// exists. Handed to the view's host, which only lays it out — the gravity
    /// and the aspect the placement maths uses were fixed by T-006.
    @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// The pixel size of the frame the camera is delivering, or `.zero` before
    /// the first one. The view needs it to draw the picture's window: the
    /// aspect-fit rect a gesture's coordinates are converted through, and the
    /// layer transform that draws the window (`LiveCameraPresentation`).
    /// Published on change only — see `delivered(_:)`.
    @Published private(set) var framePixelSize: CGSize = .zero

    /// How far the **picture itself** has been panned to hold it still against
    /// the hand's tremor, as the frame carried it (owner device verdict,
    /// 2026-09-18: *"the text is still shaky and jittery and unstable …
    /// STABILISE THE IMAGE FIRST"*).
    ///
    /// Published for the same reason `framePixelSize` is, and by the same rule:
    /// the view composes it into the one crop both the preview layer and the
    /// overlay map through (`LiveCameraCrop.stabilized(by:)`), so the picture
    /// that is drawn still and the boxes drawn on it cannot disagree. It is the
    /// *display's* correction only — the frames the recognition pass reads are
    /// the raw ones (see `CameraFrame.stabilization`).
    ///
    /// Guarded on change, like the size: a still hand answers the *same* value
    /// frame after frame, and one value per 4 Hz frame must not invalidate the
    /// view. The value is stamped by the camera on the frame, never recomputed
    /// here — and it is not `.none` while the session is running, because the
    /// inset is the room the correction is held in.
    @Published private(set) var frameStabilization: FrameStabilization = .none

    // MARK: Dependencies

    let locale: Locale
    private let config: LiveTranslateConfig
    private let camera: LiveCameraSession
    private let detector: LiveTextDetector
    private let settings: LiveTranslateSettings

    /// T-015's prompt/control lifecycle, built here over the **injected
    /// shared gate**.
    ///
    /// The gate is what T-015's design makes singular, and it is singular
    /// here: one decision, one record, one revocation path, and one in-flight
    /// registry (a revocation from Settings cancels this session's in-flight
    /// request, because the registration lives on the gate, not on this
    /// object). What is per-session is the *presentation* state — whether
    /// this session's prompt is on screen — which is a fact about one session
    /// and cannot meaningfully be shared with another.
    ///
    /// The construction happens here rather than in the app layer because the
    /// plugin factory is nonisolated by the shipped `AssistantPlugin`
    /// protocol, while `ConsentPromptController` is main-actor-isolated: a
    /// controller built on this side of the boundary is the honest place for
    /// that isolation seam, and it keeps the app layer's factory a value.
    let consent: ConsentPromptController
    private let speech: LiveTranslateSpeech
    private let capture: LiveTranslateCommandCapture
    private let notifications: NotificationCenter

    /// T-016's indicator, owned here rather than by the tier, because the view
    /// binds to it: the model is the single observation surface, so the thing
    /// the tier turns on and the thing the elder sees are one object with one
    /// counter. The tier is handed this instance and never makes its own.
    private let indicator: CloudActivityIndicatorModel

    /// Built in `start()`, never in `init`: registering the plugin must not
    /// create a pipeline, a tier or a session (NFR-LCT-012).
    private var pipeline: LiveTranslationPipeline?

    /// T-033's still path, built beside the pipeline and for the same reason
    /// (nothing is assembled until the feature is opened). It shares the
    /// session's detector, cache, live cycle and ordering counter, so a
    /// snapshot cannot send, resolve or publish by a rule of its own.
    private var snapshotPath: LiveTranslateSnapshotPath?

    // MARK: Session state

    private var hasStarted = false
    private var isClosed = false
    private var frameLoop: Task<Void, Never>?

    /// The newest frame the camera delivered while the session was live.
    ///
    /// The buffer a freeze is taken from: the elder's tap captures "the picture
    /// in front of me", which is the frame most recently handed over — not a
    /// frame requested from the camera on tap, which would freeze a picture the
    /// elder has not seen yet. It is *not* updated while a frame is held: a
    /// thaw starts from a frame delivered after the freeze ended, so a snapshot
    /// can never be taken of a stale buffer.
    private var latestFrame: CameraFrame?

    /// One freeze's async work: the still pass, the device layers, and (later)
    /// the cloud answers for what the device could not translate. Cancelled
    /// when the elder returns to live or the session closes, so a slow pass
    /// cannot land a frozen frame nobody asked for any more.
    private var snapshotTask: Task<Void, Never>?

    /// The notice's own dismissal timer — the only task this object owns
    /// besides the frame loop, and the reason a notice needs no tap to go
    /// away. Replaced (and the previous one cancelled) on every new notice,
    /// and cancelled outright on close.
    private var wardenNoticeTask: Task<Void, Never>?
    /// Which notice the pending timer belongs to. A timer that fires after a
    /// newer notice replaced its own must take nothing down, and this is what
    /// says so — the count is the whole guard, so a notice that is already on
    /// screen when a second one arrives still gets its full window.
    private var wardenNoticeGeneration = 0

    private var lifecycleObservers: [NSObjectProtocol] = []
    private var consentForwarding: AnyCancellable?
    private var indicatorForwarding: AnyCancellable?

    /// The geometry the view reported before the pipeline existed. SwiftUI
    /// lays the view out before `onAppear` in some presentations, so the
    /// layout is stored and flushed into the pipeline at start rather than
    /// being dropped on the floor.
    private var pendingLayout: LiveTranslateLayout = .unknown

    /// Whether a resume has already been applied to the current background
    /// transition — the "resumes once on foreground" rule, enforced rather
    /// than assumed.
    private(set) var resumeCount = 0

    // MARK: Init

    init(dependencies: LiveTranslateSessionDependencies) {
        self.dependencies = dependencies
        self.locale = dependencies.locale
        self.config = dependencies.config
        self.camera = dependencies.camera
        self.detector = dependencies.detector
        self.settings = dependencies.settings
        self.consent = ConsentPromptController(gate: dependencies.consentGate,
                                               config: dependencies.config,
                                               observabilityBus: dependencies.observabilityBus,
                                               locale: dependencies.locale)
        self.notifications = dependencies.notifications
        self.alwaysShowOriginal = dependencies.settings.alwaysShowOriginal
        // The cloud switch is read from the same store, for the same reason:
        // the elder's choice in Settings is the session's opening state, with
        // the config's nominal default (off) standing in for a household that
        // has never chosen.
        self.geminiCloudEnabled = dependencies.settings.geminiCloudEnabled
        self.isExtracting = dependencies.config.extractModeDefault
        self.indicator = CloudActivityIndicatorModel(observabilityBus: dependencies.observabilityBus,
                                                     config: dependencies.config)

        let speech = LiveTranslateSpeech(path: dependencies.speechPath,
                                         events: LiveTranslateEvents(bus: dependencies.observabilityBus,
                                                                     config: dependencies.config))
        self.speech = speech
        // The microphone gate is the feature's own speech, read live: T-025
        // refuses a window while it is true and discards a transcript that
        // arrives during it.
        self.capture = LiveTranslateCommandCapture(device: dependencies.captureDevice,
                                                   audioSession: dependencies.audioSession,
                                                   locale: dependencies.locale,
                                                   notifications: dependencies.notifications,
                                                   isFeatureSpeaking: { speech.isSpeaking })

        // The model is the single observation surface: the consent
        // controller's changes are forwarded, so the view observes one object
        // and the controller keeps ownership of its own state. The indicator's
        // changes are forwarded the same way, and for the same reason — the
        // tier's counter must reach the screen without a second copy of it
        // existing anywhere.
        self.consentForwarding = consent.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        self.indicatorForwarding = indicator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private let dependencies: LiveTranslateSessionDependencies

    deinit {
        lifecycleObservers.forEach { notifications.removeObserver($0) }
    }

    // MARK: - The surface the view renders

    /// The overlay's input, always renderable: before the first publication
    /// the surface is empty and the overlay shows T-005's empty-state hint,
    /// which is a rendered state and not a blank screen.
    ///
    /// It reads `activePublication`, so a frozen frame draws its own
    /// placements — measured against the frozen frame's geometry and carrying
    /// the policy they were measured under — through this same surface. There
    /// is no frozen overlay and no second renderer: the overlay cannot tell a
    /// held publication from a live one.
    var surface: LiveTranslateOverlaySurface {
        guard let activePublication else {
            return LiveTranslateOverlaySurface(
                placements: [],
                policy: LiveTranslateOverlaySurface.policy(config: config,
                                                           alwaysShowOriginal: alwaysShowOriginal,
                                                           extractionMode: isExtracting),
                locale: locale)
        }
        return LiveTranslateOverlaySurface(placements: activePublication.placements,
                                           policy: activePublication.policy,
                                           locale: locale)
    }

    /// What the session is showing: the frozen frame's publication while one
    /// is held, the live one otherwise. The single read for everything that
    /// draws or speaks a region — the overlay's surface, tap-to-hear, read-all
    /// — so "the frozen frame behaves exactly like the live one" is one
    /// property rather than a rule repeated at each call site.
    var activePublication: LiveTranslatePublication? {
        frozen?.publication ?? publication
    }

    /// The frozen picture as a list to read (owner UX rework, 2026-09-17).
    ///
    /// The *reading* surface of a held frame, and the only one: no box is drawn
    /// over a held picture, so this is where the picture's text ends up. It is
    /// built from `activePublication` — one row per **recognized string**, the
    /// regions the overlay drew first and then the ones it had no box for — so
    /// a string the placement could not measure is still read (a frozen picture
    /// with text on it is never an empty card), and its rows carry the very
    /// lines the overlay draws and announces. Taps go through `tapRegion`, the
    /// same call the overlay's boxes make, so reading and hearing on the card
    /// are the live path's own behaviour.
    var resultsCard: LiveTranslateResultsCardSurface {
        let surface = self.surface
        guard let activePublication else {
            // Nothing has been read yet: no rows, and the calm sentence a frame
            // with no text on it says.
            return LiveTranslateResultsCardSurface(emptyHint: surface.emptyHint)
        }
        return LiveTranslateResultsCardSurface(publication: activePublication,
                                               stateCopy: surface.stateCopy(for:),
                                               emptyHint: surface.emptyHint)
    }

    /// The frozen picture, or nil while the session is live. The view draws
    /// this in place of the camera preview: a `CGImage` built once, in memory,
    /// from the frame's own pixel buffer.
    var frozenFrameImage: CGImage? { frozen?.image }

    var isFrozen: Bool { frozen != nil }

    /// The freeze control's surface (T-033).
    ///
    /// `isPresented` is false only where the control would be meaningless: a
    /// failed start has T-008's own surface, and a closed session has none.
    /// While the camera is still coming up the control is drawn disabled
    /// rather than absent — a control that appears and disappears as the
    /// camera settles is harder to learn than one that is simply not ready.
    var snapshotSurface: LiveTranslateSnapshotSurface {
        LiveTranslateSnapshotSurface(isFrozen: isFrozen,
                                     isPresented: isCameraPhase,
                                     isEnabled: isFrozen || canCaptureSnapshot,
                                     isLoading: freezeInProgress,
                                     locale: locale)
    }

    /// The warden's notice as the banner renders it, or nil when there is
    /// nothing to say (which is every moment but two).
    ///
    /// The sentence is resolved here, from `copyKey` and the active locale,
    /// for the reason `repromptText` is: a surface value answers in the
    /// language the session is running in, and the view is handed a sentence
    /// rather than a key it would have to know how to read. Nothing is
    /// duplicated — `LocalBrainWardenNotice.copyKey` is the one place a notice
    /// names its catalog entry, and this is the one place it is resolved.
    var wardenNoticeSurface: WardenNoticeSurface? {
        wardenNotice.map { WardenNoticeSurface(notice: $0, locale: locale) }
    }

    /// Whether the session is in a phase that has (or is about to have) a
    /// camera picture on screen.
    private var isCameraPhase: Bool {
        if case .failed = phase { return false }
        if case .closed = phase { return false }
        return true
    }

    /// Whether a tap would capture a frame right now: the camera is running
    /// and a frame is in hand.
    var canCaptureSnapshot: Bool {
        guard !isClosed, phase == .running, latestFrame != nil else { return false }
        return true
    }

    /// True while the feature has an utterance playing or waiting (T-024).
    /// T-025's gate reads the same source, so the view and the microphone
    /// cannot disagree about whether the feature is speaking.
    var isSpeaking: Bool { speech.isSpeaking }

    /// The re-prompt's sentence, in the active language.
    ///
    /// The wording is the shipped assistant's own "say that again" line
    /// (`router.reprompt`), reused rather than re-written: a command that was
    /// not understood is exactly what it already says, the elder already knows
    /// the sentence, and reusing it adds no new copy to review (T-005's
    /// precedent for reusing a shipped key rather than inventing one).
    var repromptText: String { L10n.str(Self.repromptKey, locale: locale) }

    static let repromptKey = "router.reprompt"

    /// The placement policy in force, for the view's chrome to reserve against.
    var policy: LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: config,
                                           alwaysShowOriginal: alwaysShowOriginal,
                                           extractionMode: isExtracting)
    }

    /// T-016's surface, read straight off the indicator the tier drives. The
    /// view renders this and has no other input to the indicator, which is
    /// what makes "the indicator cannot be suppressed" true on screen and not
    /// only in the model (FR-LCT-011).
    var cloudIndicator: CloudActivityIndicatorSurface {
        CloudActivityIndicatorSurface(isActive: indicator.isActive, locale: locale)
    }

    /// The consent prompt's two answers, routed through the controller that
    /// owns the decision. The view calls these rather than the controller
    /// directly so there is one call path from the feature's UI to consent.
    func grantCloudConsent() {
        guard !isClosed else { return }
        _ = consent.grant()
    }

    func declineCloudConsent() {
        guard !isClosed else { return }
        _ = consent.decline()
    }

    // MARK: - Life

    /// Opens the session. Idempotent: a re-entrant appear (SwiftUI presenting
    /// the sheet, a tab switch, a rotation) must not start a second session,
    /// and nothing starts after a close.
    func start() async {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true
        phase = .starting
        observeLifecycle()

        let pipeline = LiveTranslationPipeline(
            locale: locale,
            recogniser: detector,
            cache: dependencies.cache,
            // The tier is given the model's own indicator: the counter the
            // tier moves is the counter on screen, not a second one.
            tier: CloudTranslationTier(cache: dependencies.cache,
                                       consentGate: dependencies.consentGate,
                                       costGovernor: dependencies.costGovernor,
                                       client: dependencies.client,
                                       config: config,
                                       observabilityBus: dependencies.observabilityBus,
                                       indicator: indicator),
            cloudNeed: consent,
            backpressure: camera,
            alwaysShowOriginal: alwaysShowOriginal,
            // The gate the whole session is built behind (owner directive,
            // 2026-09-19): handed in explicitly rather than left to the
            // config's default, so the switch the elder set in Settings is the
            // switch this session runs under — from its very first cloud need.
            geminiCloudEnabled: geminiCloudEnabled,
            extractionMode: isExtracting,
            config: config,
            observabilityBus: dependencies.observabilityBus,
            // The warden's two moments land on the model's own surface. The
            // hop itself is the named factory below rather than an inline
            // closure, so the wiring a test exercises is the wiring that
            // ships.
            onWardenNotice: Self.wardenNoticeSink(for: self),
            publish: { [weak self] publication in
                await self?.receive(publication)
            })
        self.pipeline = pipeline
        // T-033's still path: the session's own detector, cache and live cycle
        // — the gate-then-tier sequence and the ordering counter are the
        // pipeline's, not a copy, so a snapshot resolves and publishes by
        // exactly the live rules. The target language is the pipeline's own
        // default, so the two cannot disagree about what they are translating
        // into.
        self.snapshotPath = LiveTranslateSnapshotPath(recogniser: detector,
                                                      cycle: pipeline,
                                                      cache: dependencies.cache,
                                                      locale: locale)
        switch await camera.start() {
        case .success:
            _ = detector.begin()
            phase = .running
            cameraSurface = nil
            previewLayer = camera.makePreviewLayer()
            await pipeline.updateLayout(pendingLayout)
            startFrameLoop()
        case .failure(let error):
            // Start may end in the explanation, denial or unavailable state
            // (T-008). The view renders it; nothing here assumes success.
            phase = .failed(error)
            cameraSurface = CameraPermissionSurface.state(for: .failure(error))
        }
    }

    /// T-008's "continue" action: the first start left the camera at
    /// `.notDetermined`, so this call is the one that asks.
    func continueFromCameraExplanation() async {
        guard !isClosed, hasStarted, phase != .running else { return }
        switch await camera.start() {
        case .success:
            _ = detector.begin()
            phase = .running
            cameraSurface = nil
            previewLayer = camera.makePreviewLayer()
            if let pipeline {
                await pipeline.updateLayout(pendingLayout)
            }
            startFrameLoop()
        case .failure(let error):
            phase = .failed(error)
            cameraSurface = CameraPermissionSurface.state(for: .failure(error))
        }
    }

    /// The close control, and the `close` command: one teardown, in the
    /// design's order, after which nothing this session owns can call back.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        phase = .closed

        // 1. The frame loop stops first, so no further tick can reach a
        //    pipeline that is about to be closed.
        frameLoop?.cancel()
        frameLoop = nil
        removeLifecycleObservers()
        previewLayer = nil

        // 1a. The held picture goes with it, and so does any work still
        //     running for it (T-033): the frozen image and the frame it was
        //     taken from are references, and both are released here rather
        //     than waiting for the model to be deallocated.
        snapshotTask?.cancel()
        snapshotTask = nil
        frozen = nil
        latestFrame = nil
        // The picture's correction goes with the picture: a closed model draws
        // no window of a camera that has stopped (see `frameStabilization`).
        frameStabilization = .none
        // The session is over: a closed model is never mid-capture, and no
        // spinner may outlive the view that drew it.
        freezeInProgress = false
        // And no sentence may either: the warden's notice is about work this
        // session is doing, the timer that would have taken it down is
        // cancelled with it, and a view torn down a moment later must not
        // paint a status for a session that has ended.
        wardenNoticeTask?.cancel()
        wardenNoticeTask = nil
        wardenNotice = nil

        // The observation surface returns to the state it had before the first
        // cycle. The last scene is not a claim about a session that has
        // ended, and a view that is torn down a moment after this call must
        // not paint callouts for a camera that has already stopped — so
        // "nothing renders after close" is the surface being empty, not the
        // view being trusted to have gone.
        publication = nil

        // 2. In-flight work is cancelled and recognition is released.
        await pipeline?.close()
        pipeline = nil
        snapshotPath = nil

        // 3. Speech is drained: nothing the feature queued outlives it.
        speech.close()
        isListening = false

        // 4. Recognition stops, the command window drains, the audio session
        //    is released, and only then does the camera session stop.
        capture.close { [camera] in camera.stop() }
    }

    // MARK: - Lifecycle

    /// Backgrounding pauses, foregrounding resumes — once per transition.
    ///
    /// The camera session pauses and resumes itself on the same notifications
    /// (T-006 owns capture's own lifecycle); this observes them for the
    /// *pipeline*, so no frame is processed while the app is in the background
    /// and the resume is a single, idempotent step (FR-LCT-022).
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        // The observer body hops to the main actor explicitly: the model is
        // main-confined and the notification is only a trigger, so the hop is
        // the honest boundary rather than an assumption about the queue.
        lifecycleObservers.append(notifications.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        })
        lifecycleObservers.append(notifications.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        })
    }

    private func removeLifecycleObservers() {
        lifecycleObservers.forEach { notifications.removeObserver($0) }
        lifecycleObservers = []
    }

    /// Pauses frame processing. Idempotent, and a no-op after close.
    func pause() {
        guard !isClosed, !isPaused else { return }
        isPaused = true
        let pipeline = self.pipeline
        Task { await pipeline?.pause() }
    }

    /// Resumes frame processing once: the pipeline restarts its stabiliser
    /// from empty and re-resolves what is on screen, from the cache wherever
    /// the cache can answer (FR-LCT-023). A second foreground signal while
    /// running is a no-op rather than a second resume.
    func resume() {
        guard !isClosed, isPaused else { return }
        isPaused = false
        resumeCount += 1
        let pipeline = self.pipeline
        Task { await pipeline?.resume() }
    }

    // MARK: - Layout and preference

    /// The view's geometry, from its `GeometryReader`. Reports are cheap and
    /// frequent (every layout pass), so an unchanged layout is dropped here
    /// rather than before the pipeline.
    ///
    /// `crop` is the window the elder's fingers have moved to — the zoom's and
    /// the pan's virtual crop (owner follow-up, 2026-09-18) — and it comes from
    /// the same place the container does: the view, which observes the camera's
    /// zoom surface and reports the window whenever it moves. It is an input of
    /// the layout rather than of the publication because it is a fact about
    /// what is on screen, like the container size, and it must be able to
    /// change without a recognition pass or a new region. `.whole` is the
    /// identity and the honest default for a caller that has no window to
    /// report.
    func updateLayout(containerSize: CGSize,
                      safeArea: CGRect,
                      occupiedRects: [CGRect],
                      crop: LiveCameraCrop = .whole) {
        guard !isClosed else { return }
        let layout = LiveTranslateLayout(containerSize: containerSize,
                                         safeArea: safeArea,
                                         occupiedRects: occupiedRects,
                                         crop: crop)
        guard layout != pendingLayout else { return }
        pendingLayout = layout
        guard let pipeline else { return }
        Task { await pipeline.updateLayout(layout) }
    }

    /// The FR-LCT-017 preference's single write path (T-022's control and
    /// T-023's `set-show-original` command both land here).
    func setAlwaysShowOriginal(_ value: Bool) {
        guard !isClosed else { return }
        settings.setAlwaysShowOriginal(value)
        refreshAlwaysShowOriginal()
    }

    /// Mirrors the setting into the model and the pipeline. Reading it back
    /// from the setting (rather than from the argument) is what makes the two
    /// write paths — touch and voice — unable to disagree: whoever wrote it,
    /// the value that is rendered is the value that was stored.
    private func refreshAlwaysShowOriginal() {
        alwaysShowOriginal = settings.alwaysShowOriginal
        let pipeline = self.pipeline
        let resolved = alwaysShowOriginal
        Task { await pipeline?.updateAlwaysShowOriginal(resolved) }

        // A held frame keeps the preference working (T-033): the callouts are
        // measured again under the policy now in force — the same placement
        // call the freeze made, with no pass, no cache read and no request.
        // Without this the toggle would appear to stop working the moment a
        // picture is frozen, which is exactly the kind of lie about a display
        // preference the feature must not tell.
        guard let held = frozen else { return }
        let layout = pendingLayout
        let policy = self.policy
        Task { [weak self] in
            await self?.rePlaceHeldFrame(held.publication, layout: layout, policy: policy)
        }
    }

    func toggleAlwaysShowOriginal() {
        setAlwaysShowOriginal(!alwaysShowOriginal)
    }

    /// The cloud tier's master switch, as the Settings leaf writes it (owner
    /// directive, 2026-09-19).
    ///
    /// The same write path shape as the display preference above, and for the
    /// same reason: the value is written to the store, then read back from it,
    /// so the surface the elder touched and the gate the session runs behind
    /// cannot hold two different answers. That matters more here than there —
    /// this is the setting that decides whether anything leaves the phone —
    /// and it is why the switch is not a `@Published` the view writes
    /// directly.
    func setGeminiCloudEnabled(_ value: Bool) {
        guard !isClosed else { return }
        settings.setGeminiCloudEnabled(value)
        refreshGeminiCloudEnabled()
    }

    /// Mirrors the switch into the model and the pipeline.
    ///
    /// Nothing is re-placed and nothing is re-attempted: this setting is not
    /// part of any placement policy, and strings the session already settled
    /// stay settled (the pipeline's `updateGeminiCloudEnabled` says why). What
    /// it *does* affect is the next attempt — and it reaches the gate through
    /// the pipeline's own flag, which is the one the gate reads, rather than
    /// through a copy held here.
    private func refreshGeminiCloudEnabled() {
        geminiCloudEnabled = settings.geminiCloudEnabled
        let pipeline = self.pipeline
        let resolved = geminiCloudEnabled
        Task { await pipeline?.updateGeminiCloudEnabled(resolved) }
    }

    /// The switch as its row renders it, in the active language — the same
    /// shape every other surface this model owns has (`alwaysShowOriginalSurface`,
    /// `translateAllSurface`, `cloudIndicator`), so the session's chrome and
    /// the Settings leaf draw the same words from the same catalog keys.
    var geminiCloudToggleSurface: GeminiCloudToggleSurface {
        GeminiCloudToggleSurface(isOn: geminiCloudEnabled, locale: locale)
    }

    /// The extract-mode toggle's single write path (the chrome's control).
    ///
    /// `false` is the translated view — the elder has asked for everything on
    /// screen to be translated — and `true` is extract mode: recognition only,
    /// until a block is tapped. The mode is published on this object *and*
    /// pushed into the pipeline in the same call, so the boxes the elder sees
    /// and the work the pipeline is willing to start cannot disagree: the next
    /// rendered frame is drawn from a surface whose policy is the mode the
    /// control just showed.
    func setExtractMode(_ value: Bool) {
        guard !isClosed else { return }
        isExtracting = value
        let pipeline = self.pipeline
        Task { await pipeline?.updateExtractMode(value) }

        // A held frame keeps the mode working (T-033), exactly as it keeps the
        // always-show-original preference working: the callouts are measured
        // again under the policy now in force — the same placement call the
        // freeze made, with no pass, no cache read and no request.
        guard let held = frozen else { return }
        let layout = pendingLayout
        let policy = self.policy
        Task { [weak self] in
            await self?.rePlaceHeldFrame(held.publication, layout: layout, policy: policy)
        }
    }

    /// The mode control's surface, so the chrome and the placements render the
    /// same value.
    var translateAllSurface: TranslateAllSurface {
        TranslateAllSurface(isTranslatingOn: !isExtracting, locale: locale)
    }

    /// Extract mode's one ask: translate **this** region, and no other.
    ///
    /// Tapping a block is the only thing that starts tier work in extract mode,
    /// so this is the mode's whole translation entry point, and it is the
    /// session's ordinary path — the pipeline's own device lookup, cascade,
    /// gate and publication, scoped to the region the elder pointed at.
    func translateRegion(_ regionID: TextRegionStabilizer.RegionIdentity) {
        guard !isClosed else { return }
        let pipeline = self.pipeline
        Task { await pipeline?.translateRegion(regionID) }
    }

    /// The control's surface, so the chrome and the placements render the same
    /// value.
    var alwaysShowOriginalSurface: AlwaysShowOriginalSurface {
        AlwaysShowOriginalSurface(isOn: alwaysShowOriginal, locale: locale)
    }

    // MARK: - Snapshot (T-033)

    /// The elder's tap on the capture control: hold the picture that is on
    /// screen right now.
    ///
    /// Two phases, deliberately. The freeze itself is immediate — the raster is
    /// built from the frame in hand and one still pass decides what text it
    /// holds — and the cloud answers for whatever the device could not
    /// translate arrive afterwards, onto the same held frame. Waiting for the
    /// cloud here would hold the control for up to the tier's deadline before
    /// the picture stopped, which is the opposite of what the tap promises.
    ///
    /// The tap also opens the wait the control draws (`freezeInProgress`): the
    /// still pass and the placement take real time on a real frame, and until
    /// the picture is held the screen shows no other sign of it.
    ///
    /// Nothing is captured once a frame is held (a second tap means *thaw*,
    /// which is `returnToLive`), and nothing at all is captured before the
    /// camera is running: with no frame in hand there is no picture to hold —
    /// and no wait is shown either, because nothing is in flight.
    func captureSnapshot() {
        guard !isClosed, frozen == nil, phase == .running, let frame = latestFrame else { return }
        // The wait starts here, on the tap's own stack, so the control's
        // loading state is up in the same frame as the tap: the work below is
        // off the tap's stack, and a spinner that appeared only once the work
        // began would be a frame late on a fast capture and absent on a slow
        // one.
        freezeInProgress = true
        let layout = pendingLayout
        let policy = self.policy
        // The text the live picture is showing at the tap, taken here on the
        // tap's own stack: it is what the held frame keeps if the still pass
        // over it fails, exactly as a failed live pass keeps the regions on
        // screen (T-007). Read from the live publication, not from
        // `activePublication`: a freeze only starts when nothing is held.
        let holdingRegions = publication?.regions ?? []
        snapshotTask?.cancel()
        // The frame the elder tapped on travels with the work: the freeze is
        // "this picture", not "whatever the camera delivered while the tap was
        // being handled".
        snapshotTask = Task { [weak self] in
            await self?.freezeFrame(frame,
                                    layout: layout,
                                    policy: policy,
                                    holdingRegions: holdingRegions)
        }
    }

    /// The elder's second tap: let the picture move again.
    ///
    /// The held frame and its in-flight work are dropped, and the live path
    /// carries on from the next frame it is handed. Deliberately *not* a
    /// pipeline reset: the camera never stopped, and the freeze never claimed
    /// the scene had ended — which is what a background pause does claim, and
    /// why that path re-declares what is on screen (FR-LCT-023).
    func returnToLive() {
        guard !isClosed, frozen != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = nil
        frozen = nil
        // Thawing ends the wait as surely as holding the picture does: whatever
        // the cancelled task was doing is no longer being waited for.
        freezeInProgress = false
        // The frame the freeze was taken from is dropped with it: the next
        // capture waits for a frame delivered *after* the thaw, so a snapshot
        // can never be taken of a buffer the elder has already put away.
        latestFrame = nil
    }

    /// One tap, one meaning, whichever way the session is: the control's own
    /// label is read from the same `isFrozen` this decides on, so the button
    /// cannot say "freeze" and act as "thaw".
    func toggleSnapshot() {
        if isFrozen { returnToLive() } else { captureSnapshot() }
    }

    /// The capture's work, off the tap's call stack: the still pass over the
    /// frame captured at the tap, then the cloud answers onto the same frame.
    private func freezeFrame(_ frame: CameraFrame,
                             layout: LiveTranslateLayout,
                             policy: LiveOverlayPlacement.Policy,
                             holdingRegions: [TextRegionStabilizer.StableTextRegion]) async {
        guard !isClosed, frozen == nil, let path = snapshotPath else {
            // Nothing was attempted, so nothing is in flight: no path out of
            // the loading state may leave the spinner turning.
            freezeInProgress = false
            return
        }

        let outcome = await path.freeze(frame,
                                        layout: layout,
                                        policy: policy,
                                        holdingRegions: holdingRegions)
        guard !isClosed, frozen == nil, case .success(let snapshot) = outcome else {
            // The frame could not be shown, so it is not held: the live picture
            // stays where it is and the wait is over. (The failure is the
            // detector's own, recorded as `ocr_pass_failed`; a *still pass*
            // that fails is not this path — the freeze then holds the text the
            // live picture was showing.)
            freezeInProgress = false
            return
        }
        frozen = snapshot
        // The held picture is on screen, and the card with it: the loading
        // state's whole life is the tap-to-picture window. The cloud answers
        // that land afterwards arrive onto a picture that is already readable,
        // so they are not part of the wait.
        freezeInProgress = false

        // The answers land on the held frame if it is still the frame that is
        // held — compared by the picture itself, so a re-measure in between (a
        // preference change, say) keeps its answers rather than losing them to
        // a counter that moved for a reason unrelated to the image.
        guard let answers = await path.outcomesAfterCloudAnswers(of: snapshot.publication) else { return }
        guard !isClosed, var held = frozen, held.image === snapshot.image else { return }
        held.publication = await path.placed(regions: held.publication.regions,
                                             outcomes: answers,
                                             policy: held.publication.policy,
                                             layout: layout,
                                             framePixelSize: held.framePixelSize)
        guard !isClosed, frozen?.image === snapshot.image else { return }
        frozen = held
    }

    /// Re-measures a held frame under a new policy and the current geometry —
    /// the placement call and nothing else.
    private func rePlaceHeldFrame(_ publication: LiveTranslatePublication,
                                  layout: LiveTranslateLayout,
                                  policy: LiveOverlayPlacement.Policy) async {
        guard !isClosed, let path = snapshotPath, var held = frozen,
              held.publication.sequence == publication.sequence else { return }
        held.publication = await path.placed(regions: held.publication.regions,
                                             outcomes: held.publication.outcomes,
                                             policy: policy,
                                             layout: layout,
                                             framePixelSize: held.framePixelSize)
        guard !isClosed, frozen?.publication.sequence == publication.sequence else { return }
        frozen = held
    }

    // MARK: - Speech (C12)

    /// Tap-to-hear. The placements the speech is built from are the published
    /// ones, so what is spoken is what is drawn — and while a frame is frozen
    /// they are the *frozen* frame's placements, which is what makes
    /// tap-to-hear behave identically on a held picture (T-033): same speech
    /// object, same placements, same source IDs.
    func tapRegion(_ regionID: TextRegionStabilizer.RegionIdentity) {
        guard !isClosed, let activePublication else { return }
        speech.speakTappedRegion(regionID, in: activePublication.placements)
    }

    @discardableResult
    func readAll() -> Int {
        guard !isClosed, let activePublication else { return 0 }
        return speech.readAll(activePublication.placements)
    }

    @discardableResult
    func repeatLast() -> Bool {
        guard !isClosed else { return false }
        return speech.repeatLast()
    }

    func stopSpeaking() {
        guard !isClosed else { return }
        speech.stop()
    }

    // MARK: - Commands (C12, T-023/T-025)

    /// Opens one command window. One utterance; the capture decides what it
    /// was and refuses to open a second window or to open one while the
    /// feature is speaking.
    func listenForCommand() {
        guard !isClosed else { return }
        isListening = true
        capture.listen { [weak self] outcome in
            self?.handleCapture(outcome)
        }
    }

    /// What one command window produced. Split out and called directly by
    /// tests: the routing is the part with rules in it, and it should not need
    /// a microphone to be exercised.
    func handleCapture(_ outcome: LiveTranslateCommandCapture.Outcome) {
        guard !isClosed else { return }
        isListening = false

        switch outcome {
        case .command(let command):
            perform(command)
        case .reprompt:
            // C12's one re-prompt: the elder is told, in the assistant's own
            // words, and never silently dropped.
            speech.reprompt(text: repromptText)
        case .turnEnded, .noSpeech, .unavailable, .cancelled, .refused:
            // Every one of these is a window that ended without a command.
            // None of them is an error the elder must act on: there is nothing
            // to say and nothing to retry (FR-LCT-023 — the honest state is
            // already on screen).
            break
        }
    }

    /// Performs one parsed command. Exactly one thing happens per command,
    /// and nothing here speaks a translation.
    func perform(_ command: LiveTranslateCommand) {
        guard !isClosed else { return }
        switch command {
        case .readAll:
            _ = readAll()
        case .stopSpeaking:
            stopSpeaking()
        case .repeatLast:
            _ = repeatLast()
        case .setShowOriginal:
            // The parser's own write path (T-023), through the same setting the
            // touch control writes: one setter, no divergence.
            _ = command.applySetting(to: settings)
            refreshAlwaysShowOriginal()
        case .close:
            Task { await close() }
        }
    }

    // MARK: - The frame loop

    private func startFrameLoop() {
        guard frameLoop == nil, !isClosed else { return }
        let camera = self.camera
        frameLoop = Task { [weak self] in
            for await frame in camera.frames {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.delivered(frame)
            }
        }
    }

    /// One frame from the camera, on its way to the pipeline.
    ///
    /// The frozen check is *here* and it is the whole of "no frame is processed
    /// while a picture is held": the frame is neither retained as the next
    /// capture's source nor handed to the live cycle, so a frozen session costs
    /// no recognition, no request and no publication. Nothing else about the
    /// live path changes when a frame is held — and nothing changes about this
    /// loop when one is not.
    private func delivered(_ frame: CameraFrame) async {
        guard !isClosed, frozen == nil else { return }
        latestFrame = frame
        // The picture's own size, published for the view's geometry and not
        // for anything else (owner follow-up, 2026-09-18): the container tells
        // the view *where* the picture is on screen, and this tells it the
        // aspect the aspect-fit is of, so the window the elder's fingers move
        // can be drawn and read through one map (`LiveCameraPresentation`) by
        // the preview layer, the gestures and the recognition pass alike.
        //
        // Guarded on change, because `@Published` announces every assignment:
        // this runs on every delivered frame, and a frame size that only
        // changes when the format does must not invalidate the view at the
        // frame rate.
        if framePixelSize != frame.pixelSize { framePixelSize = frame.pixelSize }
        // The frame's own stabilization, on the frame's own terms: one value per
        // frame, from the camera that measured it, so the window the view draws
        // and the boxes the placement maps are always the same instant of the
        // same correction (owner device verdict, 2026-09-18).
        if frameStabilization != frame.stabilization { frameStabilization = frame.stabilization }
        await pipeline?.ingest(frame)
    }

    // MARK: - The warden's notices (owner directive, 2026-09-19)

    /// The sink the tier pushes its two notices into: the one place a
    /// `@Sendable` call from the tier's actor (or from the warden's thread, on
    /// a hand-off) meets this object's main-confined surface.
    ///
    /// A named factory rather than an inline closure at the one call site,
    /// because the hop is the whole of the wiring and a test cannot exercise a
    /// closure it has to re-write to reach: `LiveTranslateSessionModelTests`
    /// hands a real model this sink, pushes through it exactly as the tier
    /// does, and asserts what the screen would show. The weak capture is the
    /// pipeline's own rule — a session that has gone away is not kept alive by
    /// the tier that used to feed it.
    static func wardenNoticeSink(
        for model: LiveTranslateSessionModel
    ) -> @Sendable (LocalBrainWardenNotice) -> Void {
        { [weak model] notice in
            Task { @MainActor in model?.noteWardenNotice(notice) }
        }
    }

    /// The tier's notice sink, on this side of the actor boundary. The tier
    /// pushes both moments from its own actor (and, for a hand-off, from the
    /// warden's thread via a `Task`), so this is where they join the model's
    /// main-confined surface — the same shape `receive(_:)` has for
    /// publications, and the same shape the view reads.
    ///
    /// Auto-dismiss is here rather than in the view, deliberately: a view that
    /// owned the timer would be a view that starts a task and holds state, and
    /// this feature's render path is a pure function of its surface. The
    /// window is `config.wardenNoticeDismissSeconds`.
    ///
    /// A second notice replaces the first *and* restarts the window: the two
    /// moments can land close together (a load announced, then the handle
    /// taken), and the sentence on screen must be the newer one for its own
    /// full time rather than for the remainder of the older one's.
    func noteWardenNotice(_ notice: LocalBrainWardenNotice) {
        guard !isClosed else { return }
        wardenNotice = notice
        wardenNoticeGeneration += 1
        let generation = wardenNoticeGeneration
        wardenNoticeTask?.cancel()
        // The sleep is the one wait in this file that is not a tier's: it is
        // how long a *sentence* stays up, which is the unit the elder
        // experiences it in (the same reasoning as the pipeline's departure
        // grace). It is bounded below at zero so a config that was handed a
        // negative value dismisses at once instead of trapping on the
        // conversion.
        let nanoseconds = UInt64(max(0, config.wardenNoticeDismissSeconds) * 1_000_000_000)
        wardenNoticeTask = Task { [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismissWardenNotice(generation: generation)
        }
    }

    /// Takes the notice down, if it is still the one the caller was shown for.
    ///
    /// The generation check is what makes a replaced notice's timer harmless:
    /// a timer that fires after a newer notice arrived finds a count that has
    /// moved and does nothing, so a slow dismissal can never blank a sentence
    /// the elder has only just been given.
    private func dismissWardenNotice(generation: Int) {
        guard !isClosed, wardenNoticeGeneration == generation else { return }
        wardenNotice = nil
        wardenNoticeTask = nil
    }

    // MARK: - Publications

    /// The pipeline's one way in.
    ///
    /// Two guards, both structural: a publication that arrives after close is
    /// dropped (nothing renders after the session ended), and a publication
    /// whose counter does not advance is dropped — the counter is the only
    /// ordering signal in the feature (AM-6), so an out-of-order delivery is
    /// refused rather than rendered as a rewind.
    func receive(_ publication: LiveTranslatePublication) {
        guard !isClosed else { return }
        if let current = self.publication, publication.sequence <= current.sequence { return }
        self.publication = publication
    }
}
