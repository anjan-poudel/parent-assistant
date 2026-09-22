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
    /// The on-device brain the session's pipeline runs on, or `nil` for the
    /// shipped one.
    ///
    /// `nil` is what production passes: the pipeline builds the real
    /// `LocalBrainTranslationTier` over the process's own `ModelStore`, so the
    /// app has one construction site for it. A test hands one in for the same
    /// reason the other seams exist — the real tier's ladder ends at whatever
    /// assistant brains the device happens to hold, and a suite that asserts a
    /// cascade should not have its timing decided by that.
    let brain: LocalBrainTranslating?
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
    /// The point, tap & ask session's dependencies, when the host is
    /// wired for it. Nil — the honest default for every pre-existing
    /// construction site, including the test harness — means the session
    /// runs without the point-ask box and chip. The app layer always
    /// passes it (see `AppCoordinator.makeLiveTranslateDependencies`).
    let pointAsk: PointAskSessionDependencies?
    /// The session's one clock, handed to the pipeline it builds (Workstream B,
    /// the clock hold).
    ///
    /// The model gives the pipeline a clock rather than letting it default to
    /// `Date.init`, so that "the brain's clock" is one injectable fact for the
    /// whole session instead of a wall clock that only production can read. A
    /// suite that asserts a *hold* — that a read inside `brainAttemptMin
    /// Interval` is deferred and asked again when the interval opens — cannot
    /// do so against real time without either waiting whole seconds or racing
    /// the scheduler; with this seam it advances the clock itself, exactly as
    /// the camera and detector already do through their own `now`.
    ///
    /// The default is `Date.init`, so production and every pre-existing
    /// construction site keep the wall clock they had.
    let now: () -> Date
    /// How the session waits out the brain's clock (Workstream B, the clock
    /// hold).
    ///
    /// A seam rather than a bare `Task.sleep`, for the reason every other seam
    /// here exists: the wait is *seconds* long by design — `brainAttemptMin
    /// Interval` is the device's own backpressure, measured in whole seconds —
    /// and a suite that asserted the re-drive by sleeping through it would be
    /// measuring the machine rather than the code. A test hands in a double that
    /// returns at once and records what it was asked to wait for; production
    /// gets the real suspension.
    ///
    /// It is the caller's suspension, not a timer in the plan: the task that
    /// runs it is cancellable, so a close, a thaw or a second tap takes the
    /// pending re-drive with it.
    let sleepFor: @Sendable (TimeInterval) async -> Void

    init(locale: Locale,
         camera: LiveCameraSession,
         detector: LiveTextDetector,
         cache: LabelTranslationCache,
         brain: LocalBrainTranslating? = nil,
         consentGate: LiveTranslateConsentGate,
         costGovernor: GeminiCostGovernor,
         client: GeminiClient,
         speechPath: LiveTranslateSpeechPath,
         captureDevice: LiveTranslateUtteranceCapturing,
         audioSession: AudioSessionManager,
         settings: LiveTranslateSettings,
         notifications: NotificationCenter = .default,
         observabilityBus: ObservabilityBus,
         config: LiveTranslateConfig = .default,
         pointAsk: PointAskSessionDependencies? = nil,
         now: @escaping () -> Date = Date.init,
         sleepFor: @escaping @Sendable (TimeInterval) async -> Void =
             LiveTranslateSessionDependencies.realSleep) {
        self.locale = locale
        self.camera = camera
        self.detector = detector
        self.cache = cache
        self.brain = brain
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
        self.pointAsk = pointAsk
        self.now = now
        self.sleepFor = sleepFor
    }

    /// The shipped wait: a plain suspension, cancellable by whoever holds the
    /// task.
    ///
    /// `try?` because a cancelled sleep is not an error to report — it is the
    /// caller's own cancel arriving, and every caller checks `Task.isCancelled`
    /// after this returns, so a cancelled wait never turns into a re-ask.
    static let realSleep: @Sendable (TimeInterval) async -> Void = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

extension LiveTranslateSessionDependencies {
    /// The point-ask session **this host** runs: the app layer's own
    /// composition with `autoAnalyzeOnAnchor` turned off (review round 2,
    /// finding 6).
    ///
    /// In live translate the anchored box is the *target* of a question the
    /// focus capture asks for itself, not the question — and an anchor that
    /// started PointAsk's own ladder would run (and pay for) a second,
    /// different answer nobody asked for. The override lives here rather than
    /// in the app layer's `PointAskConfig.default` because it is this *host*
    /// that must not double-pay, and because the PointAsk feature's own flow
    /// (the standalone tap-and-ask surface) still wants the default. The focus
    /// capture is the consumer of the box this leaves standing: it reads
    /// `anchoredTarget` and drives the focus flow, which is why the anchor
    /// must stay quiet here.
    ///
    /// The dependencies are a value of `let`s, so the quiet config is a whole
    /// new value rather than a mutation: the copy keeps every other field the
    /// app layer chose (the gate, the cache, the client, the engines) and
    /// changes the one flag this host must not inherit. A named seam rather
    /// than an inline closure so the rule can be pinned by behaviour — the
    /// configuration a host hands in is not observable from the model it
    /// builds, so the test drives this function and watches the anchor.
    /// Adding a field to the struct without a default breaks this call site on
    /// purpose — a host that silently dropped one is the failure mode worth
    /// compiling against.
    @MainActor
    static func quietPointAsk(from hosted: PointAskSessionDependencies) -> PointAskSessionModel {
        var quietConfig = hosted.config
        quietConfig.autoAnalyzeOnAnchor = false
        let quiet = PointAskSessionDependencies(locale: hosted.locale,
                                                consentGate: hosted.consentGate,
                                                settings: hosted.settings,
                                                cache: hosted.cache,
                                                client: hosted.client,
                                                objectEngine: hosted.objectEngine,
                                                maskEngine: hosted.maskEngine,
                                                yoloEngine: hosted.yoloEngine,
                                                ocrEngine: hosted.ocrEngine,
                                                observabilityBus: hosted.observabilityBus,
                                                config: quietConfig,
                                                speak: hosted.speak)
        return PointAskSessionModel(dependencies: quiet)
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

    /// The focused read, or nil while there is none ([FOCUS-CAPTURE]).
    ///
    /// Set by `translateFocusedRegion(box:pixelRect:)` and cleared by a thaw,
    /// a close and the next focused read. It is a *second* surface rather than
    /// a mode of `frozen`, and the difference is the elder's intent: a freeze
    /// says "stop the picture so I can read it", a focused read says "tell me
    /// about **that**". So it carries its own picture (the crop, not the
    /// frame), its own rows and its own placement, and holding one does not
    /// hold the camera — the live cycle keeps running behind it.
    ///
    /// Nothing here is persisted: the crop's strings are answered by the
    /// pipeline in `.focused` mode, whose reads and writes are both told so
    /// (`CloudTranslationTier.CachePolicy.readOnly` — the tier's adoption write
    /// and the lookups' own bookkeeping writes, review round 2, finding 8) —
    /// and this session's own answers live in a `LiveTranslateMemoryCache` that
    /// goes with the model.
    @Published private(set) var focusedCapture: LiveTranslateFocusedCapture?

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

    /// Whether a focused read is in flight: true from the tick of the point
    /// until the crop is held. The same window and the same reason as
    /// `freezeInProgress` — the tap buys a crop, a pass and a plan, and
    /// without this flag "working", "slow" and "broken" are one experience.
    @Published private(set) var focusInProgress = false

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

    /// The feature's own master switch, as the Settings leaf renders it and as
    /// **this session is gated by** (owner directive, 2026-09-21; review
    /// finding 1).
    ///
    /// Read from `LiveTranslateSettings` when the model is built and mirrored
    /// on every write, like the cloud switch above it, so the value in Settings
    /// and the value this session opened under are one value.
    ///
    /// **This is the switch's reader.** Until this was wired the setting was
    /// written by the Settings leaf and read by nobody — a master switch that
    /// gated nothing — so the seam is stated here for the UI half, which is
    /// Workstream B's:
    ///
    ///  - `start()` **refuses to open a session** while this is false: no
    ///    camera, no detector, no pipeline, no frame loop, and `hasStarted`
    ///    stays false, so the same model starts cleanly once the switch is
    ///    turned back on. The session that was never opened is the whole gate
    ///    on this side.
    ///  - A surface that says **why** the feature did not open — the Settings
    ///    leaf's row, and the spoken line that routes the elder to it — is
    ///    Workstream B's, and it reads this property to decide which surface to
    ///    draw. No copy is minted here (the string catalog belongs to that
    ///    workstream), and no `Phase` case is added: `phase` stays `.idle`,
    ///    which is the state the surface already renders for a session that has
    ///    not started.
    ///  - A session that is **already open** is not torn down by a write to
    ///    this switch: leaving the live surface is a navigation decision the
    ///    UI owns (`close()` is the call that ends a session). Turning the
    ///    switch on with a session open but never started needs no more than a
    ///    second `start()`, which the guard above permits.
    ///
    /// It is a *policy*, not consent and not egress: the consent record is
    /// still required and still enforced per cloud attempt (AM-1), and this
    /// switch neither creates nor withdraws one.
    @Published private(set) var liveTranslateEnabled: Bool

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

    /// [POINT-ASK] The point, tap & ask session this live session hosts
    /// (design: docs/superpowers/specs/2026-09-19-point-tap-ask-design.md).
    /// Built here from the app layer's dependencies, so the host forwards
    /// frames and close to it and the view reads its single observation
    /// surface. Nil when the host was built without the wiring (the test
    /// harness's shape) — the session then simply has no tap box.
    let pointAsk: PointAskSessionModel?

    /// Built in `start()`, never in `init`: registering the plugin must not
    /// create a pipeline, a tier or a session (NFR-LCT-012).
    private var pipeline: LiveTranslationPipeline?

    /// T-033's still path, built beside the pipeline and for the same reason
    /// (nothing is assembled until the feature is opened). It shares the
    /// session's detector, cache, live cycle and ordering counter, so a
    /// snapshot cannot send, resolve or publish by a rule of its own.
    private var snapshotPath: LiveTranslateSnapshotPath?

    /// The focused read's path, built beside the other two and for the same
    /// reason: nothing is assembled until the feature is opened. It shares the
    /// session's detector, cache and live cycle, and holds one of its own —
    /// the in-memory answer cache, which is the whole of what a focused read
    /// is allowed to keep.
    private var focusPath: LiveTranslateFocusCapture?

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

    /// The frame an anchored box was measured against, for a caller that holds
    /// one (review round 2, finding 5).
    ///
    /// The host forwards every delivered frame to the point-ask session, and
    /// that session anchors its box on the frame it held at the tap — so a
    /// caller building a focused read from an anchor hands this frame to
    /// `translateFocusedRegion(box:pixelRect:measuredOn:)`, and the crop comes
    /// from the picture the rect is a place on rather than from whatever the
    /// camera has delivered since. When no frame has been delivered (before the
    /// first tick, after a close) it is nil, and a caller with no frame to name
    /// passes nothing.
    var anchoredFrame: CameraFrame? { latestFrame }

    /// One freeze's async work: the still pass, the device layers, and (later)
    /// the cloud answers for what the device could not translate. Cancelled
    /// when the elder returns to live or the session closes, so a slow pass
    /// cannot land a frozen frame nobody asked for any more.
    private var snapshotTask: Task<Void, Never>?

    /// One focused read's async work: the crop, the pass over it, the device
    /// layers and the plan. Cancelled on a thaw and on close for the same
    /// reason `snapshotTask` is — a slow crop must not land a picture the
    /// elder has already moved on from — and cancelled on the *next* focused
    /// read, because two taps on two boxes are one question and its answer,
    /// not two pictures racing.
    private var focusTask: Task<Void, Never>?

    /// Which focused read the surface is currently waiting for: the identity
    /// the newest tap minted, held until that read publishes or gives up
    /// (review finding 7).
    ///
    /// Cancellation is cooperative, so a superseded read still runs to its end
    /// and still has an outcome and a `focusInProgress` to write. This is the
    /// value that tells it whether it is still the session's question — the
    /// same job `snapshotTask`'s identity comparison does for the still path,
    /// stated as a token because a focused read has no picture to compare
    /// against until it succeeds. Cleared by the read that owns it, and by
    /// `returnToLive()`/`close()` when the picture is put down.
    private var focusToken: UUID?

    /// The wait a deferred focused read is inside, and the re-ask that follows
    /// it (Workstream B, the clock hold).
    ///
    /// Held for the same reason `focusTask` is, and cancelled by the same three
    /// moments: a close, a thaw, and the next focused read. A re-drive that
    /// survived any of them would plan a picture the elder has put down — the
    /// questions would be asked and paid for with nothing on screen to receive
    /// them. The picture's own guard is the publication sequence (see
    /// `redriveFocusedCapture`), which is what makes a re-drive that lands late
    /// draw nothing rather than draw onto a newer crop.
    private var focusRedriveTask: Task<Void, Never>?

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
        // [DEBUG-LOG] (review finding on #99) The one seam where the persisted
        // diagnostic switch reaches the tiers and the pipeline: both are
        // constructed with this config, so they cannot disagree about whether
        // the content-free console line is on. The switch is off by default
        // and only a Debug build has a reader for it.
        self.config = dependencies.settings.applyingDebugLogging(to: dependencies.config)
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
        // The feature's master switch, from the same store and for the same
        // reason. Its nominal default is **off**, so a household that has never
        // chosen does not get the feature by accident — and it is read here
        // rather than at `start()` so the value the surface renders and the
        // value the gate reads are one value (review finding 1).
        self.liveTranslateEnabled = dependencies.settings.liveTranslateEnabled
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

        // [POINT-ASK] The hosted session, built over the app layer's
        // dependencies — one per live session, sharing the process's own
        // gate, cache and client (which the dependencies carry). Assigned
        // before the forwarding sinks below: an escaping closure that
        // captures `self` may not be created while a `let` stored property
        // is still uninitialized.
        //
        // `autoAnalyzeOnAnchor` is turned **off** for this host (review round
        // 2, finding 6) — see `LiveTranslateSessionDependencies.quietPointAsk`,
        // which is where the rule and its reasons live and what the anchor
        // test drives.
        self.pointAsk = dependencies.pointAsk.map(LiveTranslateSessionDependencies.quietPointAsk(from:))

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
    ///
    /// **Either answer resumes the asks the prompt interrupted.** The live
    /// cycle finds them again by itself — a tick follows every frame, and the
    /// strings the prompt released are pending — but extract mode translates
    /// on the elder's tap alone and has no tick to find them with. Without
    /// this, the answer they just gave would never reach a tier, and the block
    /// they tapped would sit untranslated for the rest of the session.
    ///
    /// A refusal resumes them too, and that is not a courtesy: the plan's
    /// device fallback is what turns "no to the cloud" into a translation on
    /// the device rather than an unavailable region.
    func grantCloudConsent() {
        guard !isClosed else { return }
        _ = consent.grant()
        resumeInterruptedAsks()
    }

    func declineCloudConsent() {
        guard !isClosed else { return }
        _ = consent.decline()
        resumeInterruptedAsks()
    }

    /// Hands the interrupted asks back to the pipeline, off the main actor.
    /// The decision is recorded by the time this runs (`consent.grant()` /
    /// `decline()` above), so the gate the retry reaches reads the elder's
    /// answer rather than asking for it again.
    ///
    /// **The held frame is refreshed too, and that is half the job** (review of
    /// #100, finding 5). A still frame's asks are the pipeline's, and the
    /// answers to them land in the pipeline's terminal state — but the picture
    /// on screen is this model's held publication, built when the frame was
    /// captured. The capture path already draws the answers onto the frame it
    /// froze; a frame whose question was answered *after* that has had nobody
    /// to draw its answers since. Without this, granting the prompt over a held
    /// frame leaves the elder looking at the same untranslated picture they
    /// were looking at before they answered — the one ask they made, answered
    /// and paid for, with nothing on screen to show for it.
    private func resumeInterruptedAsks() {
        guard let pipeline else { return }
        Task { [weak self] in
            await pipeline.retryAwaitingResolution()
            await self?.refreshHeldFrame()
            await self?.repackFocusedCapture()
        }
    }

    /// Draws the answers the replay settled onto the focused picture the elder
    /// is still looking at — the card's half of what `refreshHeldFrame` does
    /// for a still frame (review round 2, finding 3).
    ///
    /// A focused read whose strings reached the consent prompt leaves its card
    /// saying "translating…", and the replay above is what answers them — into
    /// the ledger, where nothing rendered them onto the crop. Without this the
    /// only way to see the answer was to tap again, which re-cropped and re-read
    /// the page to reach the same ledger: the card unanswerable, and the read
    /// paid for twice.
    ///
    /// Guarded the way the held frame's refresh is, and for the same reason: the
    /// picture is compared **before and after** the `await`, so a thaw, a second
    /// tap or a close in between keeps its own picture rather than having this
    /// one's answers drawn onto it. The publication's sequence goes with the
    /// image because a re-place (a rotation, a display preference) changes the
    /// layout the rows were measured against — the same pair `refreshHeldFrame`
    /// compares. `focusInProgress` is deliberately not consulted: a read still
    /// in flight is a *newer* tap's, and the sequence guard is what keeps this
    /// from writing over it.
    private func repackFocusedCapture() async {
        guard !isClosed, let path = focusPath, let standing = focusedCapture else { return }
        let layout = pendingLayout
        let policy = self.policy
        guard let updated = await path.updated(standing, layout: layout, policy: policy) else {
            return
        }
        guard !isClosed, let current = focusedCapture,
              current.image === standing.image,
              current.publication.sequence == standing.publication.sequence else { return }
        focusedCapture = updated
    }

    /// Draws the answers that arrived for a held frame onto that frame — the
    /// second half of `freezeFrame`'s tail, run again now that the asks the
    /// prompt interrupted have been dispatched.
    ///
    /// Guarded the same way the capture is: the layout is the one in force, and
    /// the frame is compared by its picture before and after the `await`, so a
    /// thaw or a second capture in between keeps its own frame rather than
    /// having this one's answers drawn onto it.
    private func refreshHeldFrame() async {
        guard !isClosed, let path = snapshotPath, let held = frozen else { return }
        let layout = pendingLayout
        let sequence = held.publication.sequence
        guard let answers = await path.outcomesAfterCloudAnswers(of: held.publication) else { return }
        // The picture **and** its publication's sequence: the image identity
        // alone passes for a frame that has been re-placed since (a rotation, a
        // chrome change, a geometry push) while this call was awaiting, and
        // writing this publication over that one would draw the answers on the
        // layout the frame no longer has. `rePlaceHeldFrame` has always guarded
        // on the sequence; this path did not (review).
        guard !isClosed, var refreshed = frozen,
              refreshed.image === held.image,
              refreshed.publication.sequence == sequence else { return }
        refreshed.publication = await path.placed(regions: refreshed.publication.regions,
                                                   outcomes: answers,
                                                   policy: refreshed.publication.policy,
                                                   layout: layout,
                                                   framePixelSize: refreshed.framePixelSize)
        guard !isClosed, frozen?.image === held.image,
              frozen?.publication.sequence == sequence else { return }
        frozen = refreshed
    }

    // MARK: - Life

    /// Opens the session. Idempotent: a re-entrant appear (SwiftUI presenting
    /// the sheet, a tab switch, a rotation) must not start a second session,
    /// and nothing starts after a close.
    func start() async {
        guard !hasStarted, !isClosed else { return }
        // **The feature's master switch, first** (review finding 1). Nothing is
        // built and nothing starts while the household has the feature off: no
        // pipeline, no snapshot or focus path, no camera request, no detector
        // and no frame loop. `hasStarted` is deliberately left false, so this
        // is a deferral rather than a refusal — a session that was never opened
        // can be started the moment the switch is turned back on, with no new
        // model and no relaunch. `phase` stays `.idle`, the state the surface
        // already has for "not started"; the surface that says *why*, and the
        // spoken line that offers the Settings leaf, are Workstream B's and
        // read `liveTranslateEnabled` (see that property).
        guard liveTranslateEnabled else { return }
        hasStarted = true
        phase = .starting
        observeLifecycle()
        // [FRESH-SESSION] (owner directive, 2026-09-20: "it's showing cached
        // content — the cache should be cleared upon each restart.") A
        // translation cached yesterday must not answer today's scene: each
        // session starts from an empty persisted layer, and the session's
        // own resolutions re-fill it as they land.
        _ = dependencies.cache.removeAll()

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
            // The router's "can the cloud lead?" half that the switch cannot
            // answer (owner directive, 2026-09-19): the path question. Handed
            // in here rather than defaulted, because the default is the
            // no-path answer — correct for every construction site that
            // predates the router, and wrong for the one that runs on the
            // device.
            reachability: PathMonitorReachability(),
            extractionMode: isExtracting,
            config: config,
            observabilityBus: dependencies.observabilityBus,
            // `nil` in production: the pipeline builds the shipped tier over
            // the process's own store. A test hands one in so what it asserts
            // is the cascade rather than whatever is installed on the machine.
            brain: dependencies.brain,
            // The warden's two moments land on the model's own surface. The
            // hop itself is the named factory below rather than an inline
            // closure, so the wiring a test exercises is the wiring that
            // ships.
            onWardenNotice: Self.wardenNoticeSink(for: self),
            // The session's own clock (Workstream B, the clock hold). The
            // pipeline's default is the wall clock, which is what production
            // gets; handing it in here is what makes the *hold* a fact a suite
            // can arrange rather than a duration it has to wait out.
            now: dependencies.now,
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
        // The focused read's path, assembled the same way and sharing the same
        // three things (detector, cache, live cycle). Its memory cache is its
        // own and is the only store a focused read may write to, which is what
        // makes `.focused` mode's `.readOnly` policy safe rather than lossy:
        // the answers a capture needs again, it already has.
        self.focusPath = LiveTranslateFocusCapture(recogniser: detector,
                                                   cycle: pipeline,
                                                   cache: dependencies.cache,
                                                   memoryCache: LiveTranslateMemoryCache(config: config),
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
        // 1b. And the focused read goes with it, for the same two reasons: the
        //     picture is a reference held in memory, and a crop that is still
        //     being read must not land on a model the view has torn down.
        focusTask?.cancel()
        focusTask = nil
        focusedCapture = nil
        // The clock wait goes with them (Workstream B): nothing this session
        // owns may plan a picture after the session has ended.
        focusRedriveTask?.cancel()
        focusRedriveTask = nil
        // A spoken "translate here" still waiting for a frame is dropped here
        // and only here. It is deliberately *not* dropped by a thaw: an ask
        // made while a picture was held is about a picture the elder has since
        // put down, but they did ask, and the first frame after the thaw
        // answers it rather than the command vanishing without a trace.
        awaitingSpokenFocusFrame = false
        // The token goes with the task: a read already in flight is not this
        // session's question any more, so it may neither publish a crop nor end
        // a wait (review finding 7).
        focusToken = nil
        focusInProgress = false
        // 1c. And the focused read's own answers go with it (review round 2,
        //     finding 7): the memory cache is this session's — it holds the
        //     strings a crop read and the answers they were given — and a model
        //     that is closed but still retained must not keep a document's
        //     contents in memory for the rest of the process. `close()` is the
        //     one moment the session's answers stop being the session's, which
        //     is the moment this method was written for and the reason it is no
        //     longer a method nothing calls.
        if let cache = focusPath?.memoryCache { await cache.clear() }
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

        // [POINT-ASK] The hosted session closes with the camera: its tasks
        // are cancelled and its surface returns to waiting, so a torn-down
        // view cannot paint a tap box for a session that ended.
        pointAsk?.close()

        // 2. In-flight work is cancelled and recognition is released.
        await pipeline?.close()
        pipeline = nil
        snapshotPath = nil
        focusPath = nil

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
    ///
    /// **The focused read goes with the pause** (review finding 15), exactly as
    /// it goes with a close and with a thaw: the crop is a picture the elder is
    /// no longer looking at, and the clock wait scheduled for it is a task that
    /// would otherwise wake up in the background and start a plan — a plan that
    /// can reach the cloud — for a picture nobody can see. A backgrounded
    /// session that kept its crop also kept the strings on it in memory, which
    /// is the thing `close` releases.
    ///
    /// The live picture's own state is left exactly as it was: the pause is a
    /// claim about *frames*, and `resume` re-declares what is on screen from
    /// the cache (FR-LCT-023). This is the focused read's state only.
    func pause() {
        guard !isClosed, !isPaused else { return }
        isPaused = true
        focusTask?.cancel()
        focusTask = nil
        focusRedriveTask?.cancel()
        focusRedriveTask = nil
        focusToken = nil
        focusInProgress = false
        focusedCapture = nil
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
        let layout = pendingLayout
        let policy = self.policy
        if let held = frozen {
            Task { [weak self] in
                await self?.rePlaceHeldFrame(held.publication, layout: layout, policy: policy)
            }
        }
        // **And a focused read keeps it working too** (review finding 12): the
        // crop's own callouts are re-measured the same way. The focused read is
        // the picture the elder *pointed at*, so a toggle that stopped working
        // there would fail on exactly the surface where reading the original
        // matters most — and it is the same lie the held frame above is
        // re-placed to avoid. No pass, no cache read and no request: the
        // strings are read and answered already.
        if let capture = focusedCapture {
            Task { [weak self] in
                await self?.rePlaceFocusedCapture(capture, layout: layout, policy: policy)
            }
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

    /// The feature's master switch, as the Settings leaf writes it (owner
    /// directive, 2026-09-21; review finding 1).
    ///
    /// The same write path shape as the two preferences above — written to the
    /// store, then read back from it — so the row the elder touched and the
    /// gate the next session opens behind cannot hold two different answers.
    /// One setter, one key (`LiveTranslateSettings.setLiveTranslateEnabled`).
    ///
    /// What a write does **not** do is end a session that is already running:
    /// this is a navigation decision the UI owns (Workstream B), and `close()`
    /// is the call that ends a session. What it does do is decide whether the
    /// **next** `start()` opens anything at all — and, for a session that is
    /// open but never started (the switch was off when the surface appeared),
    /// whether a second `start()` now succeeds.
    func setLiveTranslateEnabled(_ value: Bool) {
        guard !isClosed else { return }
        settings.setLiveTranslateEnabled(value)
        refreshLiveTranslateEnabled()
    }

    /// Mirrors the master switch into the model. Nothing is pushed into the
    /// pipeline, deliberately: unlike the cloud switch, this one is not a
    /// per-attempt gate but the answer to "is there a session at all", and a
    /// session that is open already passed it (see `setLiveTranslateEnabled`).
    /// The value is read back from the setting, not taken from the argument,
    /// so both write paths land on the same answer.
    private func refreshLiveTranslateEnabled() {
        liveTranslateEnabled = settings.liveTranslateEnabled
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
        guard !isClosed else { return }
        // A focused read is a picture the elder put down too, and the live
        // picture coming back is what they put it down for. Released before
        // the held-frame guard so a session that has a focused read and no
        // frozen frame still honours the thaw — the two pictures are
        // independent, and the elder's "back to the camera" is one gesture.
        focusTask?.cancel()
        focusTask = nil
        focusedCapture = nil
        // And the clock wait, for the same reason: the picture it was waiting
        // to re-ask about is gone, so a re-ask that woke up would plan strings
        // for a crop the elder has put down (Workstream B, the clock hold).
        focusRedriveTask?.cancel()
        focusRedriveTask = nil
        // The token goes with the task: a read already in flight is no longer
        // the session's question, so it may not publish a picture or end a wait
        // that no longer exists (review finding 7).
        focusToken = nil
        focusInProgress = false
        guard frozen != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = nil
        frozen = nil
        // The frame's answers go with the picture. The pipeline holds a held
        // frame's settlements out of the live sighting's prune so the frame's
        // own refresh cannot pay for them a second time; this is the moment
        // that hold is released, and it is the thaw that owns it — the only
        // moment the picture they belong to stops existing.
        if let pipeline {
            Task { await pipeline.discardHeldAnswers() }
        }
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

    // MARK: The focused read ([FOCUS-CAPTURE])

    /// The elder pointed at one thing: read **that**, translate it, and hold
    /// the crop as a picture.
    ///
    /// The two parameters are the same target in two coordinate spaces, and
    /// both are taken because the caller has one and the session has the
    /// other: `pixelRect` is where the box lands on the frame the camera
    /// delivered (what the crop stage needs), and `box` is the normalized
    /// rectangle the elder's tap actually made. A caller that has only the box
    /// — a recorded anchor restored after a resume, say — passes a null rect
    /// and the session derives it from the frame's own pixel size, so the two
    /// can never name different regions.
    ///
    /// **`measuredOn` is the frame the rect was measured against** (review
    /// round 2, finding 5), and it is a parameter rather than an assumption for
    /// the reason the class of bug it closes exists: a rect is a *place on a
    /// picture*, so a rect measured against one frame and cropped from another
    /// is a crop of a region nobody pointed at. A tap makes both in the same
    /// instant, so a live tap passes nothing and the newest delivered frame is
    /// the right one; a caller holding a rect from an earlier moment — the
    /// anchored box a focus tap was made from, a rect restored with a
    /// publication — passes the frame that rect belongs to, and it is that
    /// picture that is cropped. `anchoredFrame` is what such a caller hands
    /// over when the anchor is current.
    ///
    /// Unlike `captureSnapshot`, this does **not** hold the camera: the live
    /// cycle keeps running, the overlay keeps drawing the scene, and the
    /// focused read lands as its own picture beside it. And unlike a freeze it
    /// writes nothing to the session's persisted store, reads included — see
    /// `LiveTranslateFocusCapture` and `CloudTranslationTier.CachePolicy`.
    ///
    /// A second call cancels the first: two taps are one question and its
    /// answer, not two pictures racing for the same surface.
    ///
    /// **A held picture refuses the read, out loud** (review finding 4). The
    /// freeze owns the surface: no box is drawn over a held frame, and its card
    /// is the reading surface, so there is nothing on it to point at. Worse,
    /// the focus read's only exit is `returnToLive` — which is the thaw — so a
    /// read started over a held frame would destroy the snapshot the elder is
    /// reading on its way to showing its own picture. Refused rather than
    /// silently ignored: they asked for something, and the sentence names the
    /// way out they already have on screen.
    func translateFocusedRegion(box: NormalizedBox,
                                pixelRect: CGRect,
                                measuredOn anchored: CameraFrame? = nil) {
        guard !isClosed, phase == .running, focusPath != nil else { return }
        guard frozen == nil else {
            speech.reprompt(text: L10n.str(Self.frozenRefusalKey, locale: locale))
            return
        }
        guard let frame = anchored ?? latestFrame else { return }
        // The wait starts on the tap's own stack, exactly as the freeze's does,
        // so the surface's loading state is up in the frame of the tap rather
        // than one frame late on a fast read and absent on a slow one.
        focusInProgress = true
        let layout = pendingLayout
        let policy = self.policy
        // The box is a place on the picture the elder is *looking at*, and what
        // they are looking at is the window the zoom and the pan have moved
        // (review finding 12) — so a box that falls outside it is bounded to it
        // before it is measured. The spoken default is the same rule's other
        // half and is built inside the window (`performSpokenFocus`).
        let rect = Self.pixelRect(for: Self.focusBox(box, in: layout.crop),
                                  in: frame,
                                  fallingBackTo: pixelRect)
        focusTask?.cancel()
        // The clock wait belongs to the read that set it off, so it goes the
        // same way the read does: a re-drive of the *previous* crop firing
        // between this tap and its picture would plan strings this read is
        // about to ask for itself (Workstream B, the clock hold).
        focusRedriveTask?.cancel()
        focusRedriveTask = nil
        // **Which read this is** (review finding 7). A second tap cancels the
        // first task, but cancellation is cooperative: a read already inside
        // the crop, the pass or the plan answers whatever it was asked, and it
        // used to write its `focusedCapture` and clear `focusInProgress` when
        // it came back — installing a picture the elder had already replaced
        // and ending the *new* read's wait. The token is this read's identity;
        // only the read that still holds it may publish or finish the wait.
        let token = UUID()
        focusToken = token
        // The frame the elder pointed at travels with the work, for the same
        // reason the freeze's does: "that notice", not "whatever the camera
        // delivered while the tap was being handled".
        focusTask = Task { [weak self] in
            await self?.readFocusedRegion(frame,
                                          pixelRect: rect,
                                          layout: layout,
                                          policy: policy,
                                          token: token)
        }
    }

    /// The fraction of the frame the centre box covers when the elder says
    /// "translate here" without having pointed at anything: the middle half of
    /// each axis. Wide enough to hold the sign, label or screen a phone is
    /// being aimed at, narrow enough that it is a *region* rather than the
    /// whole picture — which is what makes this the focus path and not a
    /// snapshot.
    ///
    /// Read from **this session's own** config rather than the shipped default
    /// (review finding: the injected config on the session path, not
    /// `LiveTranslateConfig.default`): a suite that drives a session with its
    /// own numbers must get a session that reads them, or the number it
    /// arranged is a number nothing consults.
    ///
    /// And from the config rather than spelled here (NFR-LCT-011): the same
    /// rule the source-hygiene scan enforces, and the reason it exists — this
    /// fraction and `ocrSampleInterval` are two different parameters that
    /// happen to share a number, so one spelling for two meanings is exactly
    /// the drift the scan exists to catch.
    var spokenFocusBoxInset: Double { config.spokenFocusBoxInset }

    /// The focused reading surface's geometry rule, built from **this session's
    /// own** config (review finding: the injected config on the surface path).
    ///
    /// The surface takes the rule rather than the config, so it stays a pure
    /// view: the session is what knows which numbers are in force, and a
    /// session built over a suite's own `LiveTranslateConfig` draws the panel
    /// and the growth that suite arranged. `LiveTranslateFocusLayout.Rule
    /// .shipped` remains the default for a preview or a test with no session.
    var focusRule: LiveTranslateFocusLayout.Rule { LiveTranslateFocusLayout.Rule(config: config) }

    /// **"translate here"** — the spoken form of the focus mode's Translate
    /// button (Workstream B, the constitution's voice-reachability rule).
    ///
    /// It calls the same `translateFocusedRegion(box:pixelRect:measuredOn:)`
    /// the button calls, so the words and the touch cannot come to mean two
    /// different things. Nothing about consent, cost or the tiers is special
    /// to this entry: a spoken read is a read.
    ///
    /// **What "here" is**, in order:
    ///
    ///  1. The anchored box, when the elder has pointed at something — the
    ///     place they named with their finger, which is the most specific
    ///     answer available and the one the button would use.
    ///  2. Otherwise the **middle of the picture the camera is aimed at**.
    ///     This is the case that makes the command worth having: an elder who
    ///     says "translate here" while holding the phone up has already said
    ///     where, and a command that answered "tap it first" would require the
    ///     very dexterity the voice path exists to avoid. It is stated as a
    ///     fraction of the frame rather than a pixel size so it means the same
    ///     thing on every camera format.
    ///  3. Otherwise — no frame has been delivered yet, so there is no picture
    ///     to have a middle — the ask is **held, not dropped**: see
    ///     `awaitingSpokenFocusFrame`.
    ///
    /// A closed or not-yet-started session does nothing, like every other
    /// command here: `translateFocusedRegion` is the guard, and it is the same
    /// guard the button passes through.
    func translateHere() {
        guard !isClosed else { return }
        guard anchoredFrame != nil else {
            // The session is running — the frame loop starts with the camera —
            // but nothing has been delivered yet, which is the one window
            // (`phase = .running` is set a moment before the first frame) where
            // "here" has no picture to name. Nothing is said and nothing is
            // dropped: the ask waits for the next frame the camera delivers,
            // which is the same deferral this feature uses everywhere else
            // rather than a state the elder has to notice and retry. In
            // practice the window is shorter than the recognition that produced
            // the command; it is handled because "practically never" is not
            // "never", and a command that silently did nothing would be a stub.
            awaitingSpokenFocusFrame = true
            return
        }
        performSpokenFocus()
    }

    /// A "translate here" that arrived before there was a picture. Cleared by
    /// the frame that answers it, and by leaving the surface: a request the
    /// elder made of a picture they are no longer looking at is not owed an
    /// answer on the next one.
    private var awaitingSpokenFocusFrame = false

    /// The held ask, taken. Called from `translateHere` when a picture is
    /// already in hand, and from `delivered(_:)` for the frame that arrives
    /// after one was not.
    private func performSpokenFocus() {
        awaitingSpokenFocusFrame = false
        guard !isClosed, let frame = anchoredFrame else { return }
        let inset = spokenFocusBoxInset
        // **"Here" is a place in the window the elder is looking through**
        // (review finding 12). The default box is the middle half of *that* —
        // built in the window's own coordinates and mapped back into the
        // frame's, which is what `frameBox(ofCropBox:)` is for. Built against
        // the frame instead (the old `NormalizedBox(xMin: inset, …)`), a
        // zoomed-in elder's "translate here" cropped the middle of the sensor
        // frame: mostly picture their fingers had already pushed off the glass.
        // The live path makes the same mapping the other way round, cropping
        // the frame to the window before recognition.
        let window = pendingLayout.crop
        let middle = NormalizedBox(xMin: inset,
                                   yMin: inset,
                                   xMax: 1 - inset,
                                   yMax: 1 - inset)
        let box = pointAsk?.anchoredTarget?.box ?? window.frameBox(ofCropBox: middle)
        // A null rect means "derive it from the box and the frame's own pixel
        // size", which is what a spoken command must do: there is no finger to
        // have measured one, and the box is this call's own.
        translateFocusedRegion(box: box,
                               pixelRect: .null,
                               measuredOn: frame)
    }

    /// The focused read's work, off the tap's call stack: the crop, one pass
    /// over it, and the shared plan in `.focused` mode.
    private func readFocusedRegion(_ frame: CameraFrame,
                                   pixelRect: CGRect,
                                   layout: LiveTranslateLayout,
                                   policy: LiveOverlayPlacement.Policy,
                                   token: UUID) async {
        // **Three ways this read may no longer be the live question**, and all
        // three must leave the surface alone (review finding 7): the session
        // closed, the *task* was cancelled (a second tap, a thaw, a resume — a
        // cancelled task is still running and still resolves, because every
        // await in the path is cooperative), and a newer read has taken the
        // token. The cancel alone was never enough: the work in flight answers
        // what it was asked and comes back to a session that has moved on.
        guard !isClosed, !Task.isCancelled, let path = focusPath, focusToken == token else {
            finishFocusedRead(token)
            return
        }
        let outcome = await path.capture(in: frame,
                                         pixelRect: pixelRect,
                                         layout: layout,
                                         policy: policy)
        guard !isClosed, !Task.isCancelled, focusToken == token else {
            finishFocusedRead(token)
            return
        }
        // A read that failed leaves the *previous* capture standing rather
        // than blanking the surface: the last thing the session could tell the
        // elder is still true, and the failure is the detector's own (recorded
        // as `ocr_pass_failed` by the pass itself). Clearing here would turn
        // "this crop could not be read" into "the answer you had is gone".
        if case .success(let capture) = outcome {
            focusedCapture = capture
            // **The clock hold, taken** (Workstream B, review finding 5). A
            // crop read inside `brainAttemptMinInterval` of the live cycle's
            // last attempt was answered by nobody: the plan released its
            // strings, the card says "not right now", and the live tick behind
            // this picture is planning the *live* regions, not this crop's —
            // so nothing would ever ask again. The wait is scheduled here, on
            // the read that was deferred, and the re-ask is `reDriven`.
            await scheduleFocusedRedrive(for: capture, token: token)
        }
        finishFocusedRead(token)
    }

    /// Waits out the brain's clock and asks the standing crop again — the
    /// focused path's way out of a deferral the clock caused (Workstream B,
    /// review finding 5).
    ///
    /// **A wait is scheduled only when the clock is what opened the gap.** The
    /// guard is the plan's own remaining time, not `deferredKeys` alone: a
    /// session that has never paid for a generation has nothing to wait for
    /// (`brainClockRemaining()` is zero), and a capture deferred there — a batch
    /// the budget's cap held, a request that failed — must not be re-planned on
    /// a timer. Asking again immediately would be a second plan for strings the
    /// same budget is still holding, paid for with no reason to think the
    /// answer would change. Those rows keep their sentence; the next tap, or
    /// the next capture, is what asks again.
    ///
    /// The one state the guard cannot separate is a plan the budget held while
    /// the clock was *also* closed: there the remaining time is real, so the
    /// re-ask is scheduled, and it lands on an open clock only to be released
    /// by the same budget again. That costs a plan and no generation, and the
    /// row is where it was either way — the same sentence, and the next tap.
    ///
    /// The wait is the plan's own number, read off the plan's own injected
    /// clock, so the re-ask lands when the plan says it may rather than when a
    /// constant here guesses. The suspension is the dependencies' seam
    /// (`sleepFor`), so a suite drives it without sleeping.
    ///
    /// **The read is asked again whose wait this is after the clock is read**
    /// (review finding 6). `brainClockRemaining()` is an actor hop and every
    /// await on this path is an opening for a second tap, a thaw or a close —
    /// the token is what says which read the wait belongs to, and it is read on
    /// the far side of the hop rather than trusted from before it. A wait armed
    /// for a read that has moved on would do its damage on the way *in*, not on
    /// the way out: `focusRedriveTask?.cancel()` would take down the newer
    /// read's own wait before `redriveFocusedCapture`'s identity guard got the
    /// chance to refuse the plan.
    private func scheduleFocusedRedrive(for capture: LiveTranslateFocusedCapture,
                                        token: UUID) async {
        guard !isClosed, !Task.isCancelled, focusToken == token,
              !capture.deferredKeys.isEmpty, let path = focusPath else { return }
        let wait = await path.brainClockRemaining()
        guard !isClosed, !Task.isCancelled, focusToken == token, wait > 0 else { return }
        focusRedriveTask?.cancel()
        armFocusedRedrive(for: capture, after: wait, attempt: 1)
    }

    /// The wait itself, and the re-arms behind it (review findings 6 and 9).
    ///
    /// Split from the decision about *whose* wait it is because an attempt has
    /// no token to check: by the time a wait fires the read that armed it has
    /// finished (`finishFocusedRead` clears `focusToken`), so a re-arm — which
    /// happens inside a running attempt — is guarded by the picture instead
    /// (`redriveFocusedCapture`). Nothing needs cancelling here either: the
    /// only wait that could still be standing when an attempt re-arms is the
    /// attempt's own task, and cancelling that one would cancel the re-ask that
    /// is running.
    private func armFocusedRedrive(for capture: LiveTranslateFocusedCapture,
                                   after wait: TimeInterval,
                                   attempt: Int) {
        focusRedriveTask = Task { [weak self] in
            await self?.dependencies.sleepFor(wait)
            // A cancelled wait is a close, a thaw or a newer tap — all three
            // took the picture away, and none of them wants a plan started.
            guard !Task.isCancelled else { return }
            await self?.redriveFocusedCapture(capture, attempt: attempt)
        }
    }

    /// The re-ask itself, on the picture the wait was scheduled for.
    ///
    /// **Guarded by the picture, not by the sequence** (review finding 3). The
    /// re-packed capture carries the same `image` as the one it was packed from
    /// (`LiveTranslateFocusCapture.updated` copies it through), so identity is
    /// the test that survives a re-pack — and it is the test that says what the
    /// guard means: the picture on screen is the crop this wait belongs to. The
    /// publication sequence could not stand in for it: a re-ask that moved
    /// something wrote a *new* sequence onto the standing capture, so the next
    /// attempt of the same picture would have compared its own (older) sequence
    /// against a newer one and refused to fire — the re-arm dying on the first
    /// answer it rendered.
    ///
    /// Unlike the re-pack it *does* start a plan (`LiveTranslateFocusCapture
    /// .reDriven`) — that is the whole difference between rendering an answer
    /// and asking for one — and it then arms the next wait while the clock is
    /// still what stands between the picture and its answers.
    private func redriveFocusedCapture(_ capture: LiveTranslateFocusedCapture,
                                       attempt: Int) async {
        guard !isClosed, let path = focusPath, let standing = focusedCapture,
              standing.image === capture.image else { return }
        let updated = await path.reDriven(standing,
                                          layout: pendingLayout,
                                          policy: policy)
        guard !isClosed, let current = focusedCapture,
              current.image === standing.image else { return }
        if let updated { focusedCapture = updated }
        // **One wait is not a guarantee** (review finding 9). What the wait
        // buys is a due clock, not an answer: a plan that lands on an open
        // clock can still be released — the budget's cap holding a surplus, a
        // prefix that did not reach the batch — and those rows would then sit
        // on "not right now" for the life of the picture, which is the stall
        // this whole path exists to end. So the attempt re-arms while the
        // picture still has deferred keys, up to the config's bound: a clock
        // the re-ask never opens (a budget that caps every pass) stops on the
        // `wait > 0` guard rather than spinning, and a clock that keeps
        // closing is given `focusRedriveMaxAttempts` plans and no more.
        let pending = (updated ?? standing).deferredKeys
        guard !pending.isEmpty, attempt < config.focusRedriveMaxAttempts else { return }
        let wait = await path.brainClockRemaining()
        guard !isClosed, !Task.isCancelled, wait > 0,
              let stillStanding = focusedCapture,
              stillStanding.image === standing.image else { return }
        armFocusedRedrive(for: capture, after: wait, attempt: attempt + 1)
    }

    /// Ends the focus wait — **only if the wait is still this read's**
    /// (review finding 7). A superseded read that cleared `focusInProgress`
    /// ended the wait the elder's *newest* tap is still inside, so the surface
    /// went from "working…" to nothing while the read it should be showing was
    /// still in flight. The token is cleared with the flag, so the next read
    /// starts from a state no earlier one can finish.
    private func finishFocusedRead(_ token: UUID) {
        guard focusToken == token else { return }
        focusToken = nil
        focusInProgress = false
    }

    /// The box a focus read may crop, given the window the elder is looking
    /// through (review finding 12).
    ///
    /// A box the elder **pointed at** is already frame-normalized — the overlay
    /// maps it through the presentation to draw it — so it needs no mapping,
    /// only a bound: the part of it that lies outside the window is a part they
    /// have pushed off the glass and cannot be asking about. Intersecting is
    /// what makes the picture the crop is taken from *visible*; the anchored
    /// case is unchanged whenever the anchor is on screen, which is the case
    /// the anchor exists for.
    ///
    /// An intersection that comes out empty (the elder panned the window away
    /// from the box and then asked anyway) leaves the box alone rather than
    /// refusing: the read still answers the place they named, which is more
    /// use than a sentence about windows.
    private static func focusBox(_ box: NormalizedBox,
                                 in window: LiveCameraCrop) -> NormalizedBox {
        guard !window.isWhole else { return box }
        let xMin = max(box.xMin, window.box.xMin)
        let xMax = min(box.xMax, window.box.xMax)
        let yMin = max(box.yMin, window.box.yMin)
        let yMax = min(box.yMax, window.box.yMax)
        guard xMax > xMin, yMax > yMin else { return box }
        return NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    /// What the session says when a focus read is asked for over a held picture
    /// (review finding 4). A key and never a literal (NFR-LCT-004), resolved in
    /// the active language at the moment it is spoken.
    static let frozenRefusalKey = "livetranslate.focus.frozen"

    /// The pixel rect a box names on a frame. The caller's own rect wins when
    /// it has one — it was measured against the buffer the crop came from —
    /// and a null rect is derived from the box and the frame's own pixel size,
    /// so a restored anchor still crops the region it named.
    private static func pixelRect(for box: NormalizedBox,
                                  in frame: CameraFrame,
                                  fallingBackTo pixelRect: CGRect) -> CGRect {
        guard pixelRect.isEmpty || pixelRect.isNull else { return pixelRect }
        let width = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        guard width > 0, height > 0, box.isValid else { return pixelRect }
        return CGRect(x: box.xMin * width,
                      y: box.yMin * height,
                      width: (box.xMax - box.xMin) * width,
                      height: (box.yMax - box.yMin) * height)
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

    /// Re-measures a packed **focused** capture under a new policy and the
    /// current geometry — `rePlaceHeldFrame`'s rule for the other picture
    /// (review finding 12).
    ///
    /// The staleness guard is the same shape and on the same field: the crop on
    /// screen must still be the capture this call was made about, compared by
    /// its publication's sequence, so a re-measure that lands after a second
    /// tap — or after a thaw — writes nothing. The picture, its answers and its
    /// rows' text are untouched; only the geometry is measured again.
    private func rePlaceFocusedCapture(_ capture: LiveTranslateFocusedCapture,
                                       layout: LiveTranslateLayout,
                                       policy: LiveOverlayPlacement.Policy) async {
        guard !isClosed, let path = focusPath,
              focusedCapture?.publication.sequence == capture.publication.sequence else { return }
        let rePlaced = await path.rePlaced(capture, layout: layout, policy: policy)
        guard !isClosed,
              focusedCapture?.publication.sequence == capture.publication.sequence else { return }
        focusedCapture = rePlaced
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

    /// Tap-to-hear on the **focused read's** rows (review finding 1).
    ///
    /// The crop's rows carry the crop's own region identities — they were built
    /// from the crop's publication — so that is the publication they must be
    /// resolved against. `tapRegion` resolves against the *live* one, and while
    /// a focused read is up the live picture is a different picture with
    /// different rows: the identity found nothing at all, or found a live
    /// region that happened to answer to it and spoke a sentence from a scene
    /// the elder is no longer looking at. The frozen card's rule
    /// (`tapRegion`'s `activePublication` is the held frame's while a picture
    /// is held), applied to the other picture this session can be showing: what
    /// is spoken is what is drawn.
    ///
    /// A tap with no capture standing is a no-op rather than a fallback to the
    /// live placements: the row that was tapped is gone, and speaking the live
    /// picture's line for it would be the same bug in the other direction.
    func tapFocusedRegion(_ regionID: TextRegionStabilizer.RegionIdentity) {
        guard !isClosed, let capture = focusedCapture else { return }
        speech.speakTappedRegion(regionID, in: capture.publication.placements)
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
        case .translateHere:
            translateHere()
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
        // A spoken "translate here" that arrived before there was a picture is
        // taken here, on the first frame that can answer it (`translateHere`).
        // Before the point-ask hand-off below, so the crop is measured on the
        // frame the elder was aiming at rather than on a later one.
        if awaitingSpokenFocusFrame { performSpokenFocus() }
        // [POINT-ASK] The hosted session reads the same frame: the
        // picture the elder taps on is the picture the analysis crops.
        pointAsk?.receiveFrame(frame)
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
