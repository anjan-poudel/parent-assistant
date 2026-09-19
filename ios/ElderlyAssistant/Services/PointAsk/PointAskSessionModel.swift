import Combine
import CoreGraphics
import Foundation

// The point-ask session model (design §4's state machine):
//
//   `.awaitingTap ──tap──▶ .boxAnchored ──chipTap──▶ .analyzing ──▶ .answered`
//        ▲                     │  (box + chip)             │  (stages)      │
//        │                     └── aged out (5 s) ──▶ .awaitingTap          │
//        │                                                               .failed
//        └── any tap re-anchors (dismissing the answer/failure first) ◀──┘
//
// What this file exists to make true:
//
//  1. **One box at a time.** A tap anchors the box the resolver chose —
//     a saliency box containing the tap, or the pad box around it. A tap
//     during `.analyzing`, `.answered` or `.failed` dismisses that state
//     and re-anchors: the box follows the elder's finger, never a stale
//     position. The box ages out after `boxAgeOutSeconds` without a chip
//     tap (design §4).
//  2. **The model is the single observation surface.** Everything the
//     overlay draws — the box, the chip, the answer card — is a property
//     of this object (`overlaySurface`), in the same shape
//     `LiveTranslateSessionModel` holds for its overlay. The view holds
//     no point-ask state of its own.
//  3. **Consent is a sheet, not a pipeline state.** `.consentPending` is
//     presentation state here: the prompt appears at the first chip tap
//     that would send a crop (the "first cloud need" rule of the shipped
//     `ConsentPromptController`), and the elder's answer — grant or
//     decline — releases the pending analysis. A decline (or a deny, or
//     an unreadable record) runs the ladder-1 analysis: the answer is
//     complete with zero egress.
//  4. **The spoken answer is composed here, in the active language.**
//     The pipeline returns structured findings; this model turns them
//     into the spoken line and the card lines through `L10n` — so the
//     user-visible strings live at the one layer that knows the locale,
//     and none of them ever reaches an event (the `PointAskEvents`
//     contract).
//  5. **Honest, never fabricated.** Medicine refusals speak the
//     app-owned refusal copy and nothing else; a VLM failure serves the
//     ladder-1 answer when there is local content and the honest failure
//     line when there is none; a quota cap is announced and the ladder-1
//     answer follows (design §3).
//
// `@MainActor` + `ObservableObject`: the repo's shipped observation
// pattern (iOS 16 deployment target — `LiveTranslateSessionModel` is the
// sibling this mirrors). All state is main-confined; the pipeline is an
// actor that hands whole values back.

/// Everything a point-ask session needs, resolved when the live-translate
/// session that hosts it is opened. The app layer builds this on demand;
/// tests build it with doubles. A value of references, deliberately: the
/// model composes the session from it and owns no factory of its own.
struct PointAskSessionDependencies {

    let locale: Locale
    let consentGate: PointAskConsentGate
    let settings: PointAskSettings
    let cache: LabelTranslationCache
    let client: GeminiClient
    /// The existing saliency engine (`VisionObjectDetectionEngine`) the
    /// tap hit-test reads boxes from.
    let objectEngine: LiveObjectDetectionEngine
    /// The opt-in mask engine, or nil (the shipped default: the spike
    /// stays behind the probe).
    let maskEngine: PointAskMaskProbing?
    let ocrEngine: LiveTextRecognitionEngine
    let observabilityBus: ObservabilityBus
    let config: PointAskConfig
    /// The speech path: the shell's own speak queue, wired by the app
    /// layer. The answer is spoken through this and never logged.
    let speak: (String) -> Void

    init(locale: Locale,
         consentGate: PointAskConsentGate,
         settings: PointAskSettings,
         cache: LabelTranslationCache,
         client: GeminiClient,
         objectEngine: LiveObjectDetectionEngine,
         maskEngine: PointAskMaskProbing? = nil,
         ocrEngine: LiveTextRecognitionEngine,
         observabilityBus: ObservabilityBus,
         config: PointAskConfig = .default,
         speak: @escaping (String) -> Void) {
        self.locale = locale
        self.consentGate = consentGate
        self.settings = settings
        self.cache = cache
        self.client = client
        self.objectEngine = objectEngine
        self.maskEngine = maskEngine
        self.ocrEngine = ocrEngine
        self.observabilityBus = observabilityBus
        self.config = config
        self.speak = speak
    }
}

/// The composed answer — the strings the session speaks and the card
/// draws, in the active language. Pure content: nothing here is ever
/// logged.
struct PointAskAnswer: Equatable {
    let spokenLine: String
    let cardLines: [String]
    let isMedicineRefusal: Bool
    let isFailure: Bool
    let vlmUsed: Bool
}

/// The pure surface the overlay draws: the anchored box (normalized
/// against the frame — the overlay maps it through the live camera
/// presentation), what the chip shows, and the answer card's lines when
/// one is up. The box is the tap's; the copy is the catalog's.
struct PointAskOverlaySurface: Equatable {

    enum State: Equatable {
        /// Nothing anchored: nothing is drawn.
        case idle
        /// Box + chip, waiting for the elder's "what is this?".
        case box
        /// The analysis is running: box + the pending chip.
        case analyzing
        /// The answer card is up.
        case answered
    }

    let box: NormalizedBox?
    let state: State
    let chipLabel: String
    let cardLines: [String]
}

/// The pure surface behind the point-ask consent prompt: every string the
/// sheet shows and the two choices, in the active language — the same
/// shape the shipped `ConsentPromptSurface` holds for live translate, with
/// the point-ask disclosure copy (design §5: the wording clones the
/// shipped `livetranslate.consent.*` formula — what leaves, where it goes,
/// nothing until agreement, stop any time).
struct PointAskConsentSurface: Equatable {

    /// One choice the prompt offers. Two fields and no more: no primary,
    /// no role, no style — equal weight is a property of the types (the
    /// shipped `ConsentAction` rule).
    struct Action: Equatable {
        enum Kind: String, Equatable {
            case grant
            case decline
        }

        let kind: Kind
        let title: String

        var accessibilityIdentifier: String { "pointask.consent.\(kind.rawValue)" }
    }

    let title: String
    /// The disclosure: what is sent (the small crop, nothing else), where
    /// it goes, and that it stops when the elder says so.
    let message: String
    let actions: [Action]
    /// Set when the elder's answer could not be recorded. The sheet stays
    /// up: the answer did not take effect, and the elder is told so
    /// rather than being shown a success that did not happen (AM-4).
    let failureMessage: String?
    let locale: Locale

    init(locale: Locale, failureMessage: String? = nil) {
        self.locale = locale
        self.title = L10n.str("pointask.consent.title", locale: locale)
        self.message = L10n.str("pointask.consent.body", locale: locale)
        self.actions = [
            Action(kind: .grant,
                   title: L10n.str("pointask.consent.grant", locale: locale)),
            Action(kind: .decline,
                   title: L10n.str("pointask.consent.decline", locale: locale))
        ]
        self.failureMessage = failureMessage
    }
}

@MainActor
final class PointAskSessionModel: ObservableObject {

    /// Where the session is in its life. Every state past `.awaitingTap`
    /// carries the anchored box, so the overlay's box never comes from a
    /// second place.
    enum Phase: Equatable {
        case awaitingTap
        case boxAnchored(NormalizedBox, pixelRect: CGRect)
        case analyzing(NormalizedBox)
        case answered(NormalizedBox)
        case failed(NormalizedBox)
    }

    // MARK: Observation surface

    @Published private(set) var phase: Phase = .awaitingTap
    /// The composed answer, or nil until one is spoken.
    @Published private(set) var answer: PointAskAnswer?
    /// The consent sheet (`.consentPending` is presentation state here,
    /// not a pipeline state — design §4).
    @Published private(set) var isConsentPromptPresented = false
    /// The honest failure line when the elder's answer did not reach
    /// storage (AM-4's "told, not stranded" rule).
    @Published private(set) var consentFailureMessage: String?
    /// Whether cloud work may be in flight — the visible cloud
    /// indicator's input (design §5: "visible cloud indicator").
    @Published private(set) var cloudIndicatorActive = false
    /// The cloud tier's master switch, as the Settings leaf renders it
    /// and as every attempt decision reads it. Mirrored on every write.
    @Published private(set) var cloudEnabled: Bool

    // MARK: Dependencies

    let locale: Locale
    private let config: PointAskConfig
    private let consentGate: PointAskConsentGate
    private let settings: PointAskSettings
    private let events: PointAskEvents
    private let resolver: PointAskTargetResolver
    private let deps: PointAskSessionDependencies
    private let speak: (String) -> Void

    /// Built on first use, never in `init` — a session that never gets a
    /// chip tap never creates a pipeline (NFR-LCT-012's shape).
    private var pipeline: PointAskAnalysisPipeline?

    // MARK: Session state

    /// The newest frame the camera delivered. The analysis works from the
    /// frame in hand at the chip tap — "the picture in front of me" —
    /// not a frame requested on tap (the live-translate snapshot's rule).
    private var latestFrame: CameraFrame?

    /// The elder's tap, waiting to be resolved. Serialized: one resolve
    /// at a time, each draining the previous, so the resolver's cache is
    /// never read and written by two taps at once.
    private var resolveTask: Task<Void, Never>?

    /// One analysis's work, cancelled when a new tap dismisses it.
    private var analysisTask: Task<Void, Never>?
    /// The box's age-out timer. A generation counter is the whole guard:
    /// a timer that fires after a newer anchor replaced its own must
    /// retire nothing.
    private var ageOutTask: Task<Void, Never>?
    private var boxGeneration = 0

    /// The analysis the consent sheet is holding, when the chip tap was
    /// the first cloud need: the frame and box the elder asked about.
    private var pendingAnalysis: (frame: CameraFrame, box: NormalizedBox, pixelRect: CGRect)?

    private var isClosed = false

    // MARK: Init

    init(dependencies: PointAskSessionDependencies) {
        self.deps = dependencies
        self.locale = dependencies.locale
        self.config = dependencies.config
        self.consentGate = dependencies.consentGate
        self.settings = dependencies.settings
        self.events = PointAskEvents(bus: dependencies.observabilityBus,
                                     config: dependencies.config)
        self.resolver = PointAskTargetResolver(objectEngine: dependencies.objectEngine,
                                               maskEngine: dependencies.maskEngine,
                                               config: dependencies.config,
                                               observabilityBus: dependencies.observabilityBus)
        self.speak = dependencies.speak
        self.cloudEnabled = dependencies.settings.cloudEnabled
    }

    // MARK: - The overlay's surface

    /// Everything the overlay draws, in one value. The box is the
    /// anchored one — or nil when nothing is anchored, which is the
    /// overlay's "draw nothing" instruction, not an empty-state hint.
    var overlaySurface: PointAskOverlaySurface {
        let chip = L10n.str("pointask.chip.label", locale: locale)
        switch phase {
        case .awaitingTap:
            return PointAskOverlaySurface(box: nil, state: .idle, chipLabel: chip, cardLines: [])
        case .boxAnchored(let box, _):
            return PointAskOverlaySurface(box: box, state: .box, chipLabel: chip, cardLines: [])
        case .analyzing(let box):
            return PointAskOverlaySurface(box: box, state: .analyzing, chipLabel: chip, cardLines: [])
        case .answered(let box):
            return PointAskOverlaySurface(box: box, state: .answered, chipLabel: chip,
                                          cardLines: answer?.cardLines ?? [])
        case .failed(let box):
            return PointAskOverlaySurface(box: box, state: .answered, chipLabel: chip,
                                          cardLines: answer?.cardLines ?? [])
        }
    }

    /// The consent sheet's content, in the active language — the same
    /// shape the shipped `ConsentPromptSurface` holds for live translate,
    /// with the point-ask disclosure copy.
    var consentSurface: PointAskConsentSurface {
        PointAskConsentSurface(locale: locale, failureMessage: consentFailureMessage)
    }

    // MARK: - Frames

    /// One frame from the host session's loop, held as the picture the
    /// next analysis reads. Nothing is retained beyond the session.
    func receiveFrame(_ frame: CameraFrame) {
        guard !isClosed else { return }
        latestFrame = frame
    }

    // MARK: - Taps

    /// A tap on the picture. Whatever the session is doing, a tap means
    /// "look here": the answer (or failure) is dismissed, any in-flight
    /// analysis is dropped, and the box anchors where the finger is —
    /// one box at a time, re-anchored by design (§4).
    func handleTap(atFramePoint point: CGPoint, framePixelSize: CGSize) {
        guard !isClosed,
              framePixelSize.width > 0, framePixelSize.height > 0 else { return }
        let normalized = CGPoint(x: point.x / framePixelSize.width,
                                 y: point.y / framePixelSize.height)
        dismissCurrent()
        guard let frame = latestFrame else { return }

        // Resolve off the tap's stack: the first tap on a scene pays the
        // saliency pass (bounded, and cached for the next), and a still
        // finger must not block the picture. The drain-await keeps the
        // resolver's cache serial; a newer tap cancels an older resolve
        // outright (`dismissCurrent`), so the anchor that lands is the
        // newest tap's.
        let resolver = self.resolver
        let prior = resolveTask
        resolveTask = Task { [weak self] in
            await prior?.value
            guard !Task.isCancelled, let self else { return }
            let target = resolver.resolve(tap: normalized, in: frame.pixelBuffer)
            guard !Task.isCancelled else { return }
            self.anchor(target)
        }
    }

    /// The chip — the elder's "what is this?". Only an anchored box has a
    /// chip, and only an un-analyzed one launches work.
    func chipTapped() {
        guard !isClosed, case .boxAnchored(let box, let pixelRect) = phase,
              let frame = latestFrame else { return }
        events.chipTapped()
        ageOutTask?.cancel()
        ageOutTask = nil
        phase = .analyzing(box)

        // The consent decision is taken BEFORE any work launches — the
        // "first cloud need" rule. Only a chip tap that would send a crop
        // presents the prompt; a denied or unreadable record runs the
        // ladder-1 analysis without a prompt, exactly as the shipped
        // `ConsentPromptController.cloudNeedDetected()` routes.
        if settings.cloudEnabled, consentGate.currentDecision() == .notRecorded {
            pendingAnalysis = (frame, box, pixelRect)
            presentConsent()
            return
        }
        let cloud = settings.cloudEnabled && consentGate.currentDecision().allowsEgress
        startAnalysis(frame: frame, box: box, pixelRect: pixelRect, cloud: cloud)
    }

    // MARK: - Consent

    private func presentConsent() {
        isConsentPromptPresented = true
        consentFailureMessage = nil
        events.consentPromptShown()
    }

    /// The elder grants. On success the pending analysis runs with the
    /// cloud tier; on a failed write the sheet stays up and the elder is
    /// told — a consent that was not recorded is not a consent (AM-4).
    func grantCloudConsent() {
        guard !isClosed else { return }
        switch consentGate.record(granted: true) {
        case .success:
            isConsentPromptPresented = false
            consentFailureMessage = nil
            runPendingAnalysis(cloud: true)
        case .failure:
            consentFailureMessage = L10n.str("pointask.consent.failed", locale: locale)
        }
    }

    /// The elder declines. The sheet closes and the pending analysis runs
    /// the on-device ladder — a complete answer with zero egress. A
    /// decline whose write fails still denies (the gate mirrors the "no"
    /// before it writes); the failure is reported so the elder knows the
    /// decision may not survive a restart.
    func declineCloudConsent() {
        guard !isClosed else { return }
        let result = consentGate.record(granted: false)
        if case .failure = result {
            consentFailureMessage = L10n.str("pointask.consent.failed", locale: locale)
        } else {
            consentFailureMessage = nil
        }
        isConsentPromptPresented = false
        runPendingAnalysis(cloud: false)
    }

    /// Withdraws consent — the gate's immediate-and-total revocation,
    /// which cancels any in-flight VLM request. Exposed for the Settings
    /// leaf's revocation control (Phase 2) and for tests; the session
    /// itself never revokes.
    @discardableResult
    func revokeCloudConsent() -> Result<Void, PointAskConsentGate.ConsentError> {
        consentGate.revoke()
    }

    private func runPendingAnalysis(cloud: Bool) {
        guard let pending = pendingAnalysis else {
            // The sheet was not up — the decision changed under it
            // (unreachable in practice: the sheet has no auto-dismiss).
            return
        }
        pendingAnalysis = nil
        startAnalysis(frame: pending.frame, box: pending.box,
                      pixelRect: pending.pixelRect, cloud: cloud)
    }

    // MARK: - The cloud switch

    /// The master switch's single write path (the Settings leaf). The
    /// value is written to the store, then read back, so the surface the
    /// elder touched and the decision the next tap reads cannot disagree.
    func setCloudEnabled(_ value: Bool) {
        guard !isClosed else { return }
        settings.setCloudEnabled(value)
        cloudEnabled = settings.cloudEnabled
    }

    // MARK: - Anchoring

    /// Anchors the resolved target: box + chip on screen, the age-out
    /// clock running.
    private func anchor(_ target: ResolvedPointAskTarget) {
        guard !isClosed else { return }
        guard case .awaitingTap = phase else { return }
        phase = .boxAnchored(target.normalizedBox, pixelRect: target.pixelRect)
        boxGeneration += 1
        let generation = boxGeneration
        let seconds = UInt64(max(0, config.boxAgeOutSeconds) * 1_000_000_000)
        ageOutTask?.cancel()
        ageOutTask = Task { [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: seconds)
            guard !Task.isCancelled else { return }
            self?.ageOut(generation: generation)
        }
    }

    private func ageOut(generation: Int) {
        guard !isClosed, boxGeneration == generation else { return }
        guard case .boxAnchored = phase else { return }
        phase = .awaitingTap
        ageOutTask = nil
        events.boxAgedOut()
    }

    /// Ends whatever the session was doing and returns to waiting — the
    /// tap's first step, whatever state it interrupted.
    private func dismissCurrent() {
        resolveTask?.cancel()
        resolveTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        ageOutTask?.cancel()
        ageOutTask = nil
        answer = nil
        cloudIndicatorActive = false
        isConsentPromptPresented = false
        consentFailureMessage = nil
        pendingAnalysis = nil
        phase = .awaitingTap
    }

    // MARK: - Analysis

    private func ensurePipeline() -> PointAskAnalysisPipeline {
        if let pipeline { return pipeline }
        let pipeline = PointAskAnalysisPipeline(
            ocrEngine: deps.ocrEngine,
            classifier: VisionPointAskClassifier(
                minimumConfidence: config.classifierMinimumConfidence),
            cache: deps.cache,
            consentGate: consentGate,
            client: deps.client,
            targetLanguage: AppLanguage(locale: locale),
            config: config,
            observabilityBus: deps.observabilityBus)
        self.pipeline = pipeline
        return pipeline
    }

    private func startAnalysis(frame: CameraFrame,
                               box: NormalizedBox,
                               pixelRect: CGRect,
                               cloud: Bool) {
        // The indicator is on while cloud work may be in flight: from the
        // launch of a cloud-enabled analysis until its findings land — a
        // window that contains the actual VLM request (the shipped
        // indicator's own semantics: on while tier-2 work is in flight).
        cloudIndicatorActive = cloud
        let pipeline = ensurePipeline()
        let config = self.config
        let speak = self.speak
        let locale = self.locale
        let targetLanguage = AppLanguage(locale: locale)

        analysisTask = Task { [weak self] in
            // The crop and the re-encode are the analysis's own cost
            // (bounded — the research's <15 ms stage), and the pipeline
            // runs on its own actor; the elder's screen never waits on
            // Vision or the network.
            let crop = PointAskCrop.cropped(frame.pixelBuffer, pixelRect: pixelRect)
            let jpeg = crop.flatMap {
                PointAskCrop.jpegUploadData(from: $0, maxSide: config.maxUploadSide)
            }
            guard !Task.isCancelled, let crop, let jpeg else {
                await self?.finishFailed(box: box)
                return
            }
            let findings = await pipeline.analyze(
                PointAskAnalysisRequest(crop: crop, uploadJPEG: jpeg),
                cloudEnabled: cloud)
            guard !Task.isCancelled else { return }
            let composed = Self.compose(findings,
                                        locale: locale,
                                        targetLanguage: targetLanguage)
            await self?.finishAnswered(box: box, composed: composed)
            speak(composed.spokenLine)
        }
    }

    private func finishAnswered(box: NormalizedBox, composed: PointAskAnswer) {
        guard !isClosed else { return }
        answer = composed
        cloudIndicatorActive = false
        phase = composed.isFailure ? .failed(box) : .answered(box)
        analysisTask = nil
    }

    private func finishFailed(box: NormalizedBox) {
        guard !isClosed else { return }
        cloudIndicatorActive = false
        answer = Self.failureAnswer(locale: locale)
        phase = .failed(box)
        analysisTask = nil
    }

    // MARK: - Answer composition

    /// Findings → the spoken line and the card, in the active language.
    /// The one place user-visible strings are made, and none of them
    /// reaches a log.
    static func compose(_ findings: PointAskFindings,
                        locale: Locale,
                        targetLanguage: AppLanguage) -> PointAskAnswer {
        // 1. The medicine refusal outranks everything: the app-owned
        //    refusal copy, nothing else (design §1 item 4).
        if findings.medicineRefusal {
            let line = L10n.str("pointask.answer.medicineRefusal", locale: locale)
            return PointAskAnswer(spokenLine: line, cardLines: [line],
                                  isMedicineRefusal: true, isFailure: false, vlmUsed: false)
        }

        // 2. The VLM answer, hedged when the confidence is low.
        if let vlm = findings.vlm {
            var spoken = vlm.spokenLine
            var card = [vlm.whatIsIt.isEmpty ? vlm.spokenLine : vlm.whatIsIt]
            if findings.hedge {
                spoken += " " + L10n.str("appliance.hedgeNotice", locale: locale)
            }
            card = card.filter { !$0.isEmpty }
            return PointAskAnswer(spokenLine: spoken, cardLines: card,
                                  isMedicineRefusal: false, isFailure: false, vlmUsed: true)
        }

        // 3. The ladder-1 answer — complete without egress. The cap is
        //    announced first when it stopped the VLM (design §3 ladder 2).
        var spokenParts: [String] = []
        var cardLines: [String] = []
        if findings.quotaCapped {
            spokenParts.append(L10n.str("router.capReached", locale: locale))
        }
        if let label = findings.classLabel {
            let looks = L10n.fmt("pointask.answer.looksLike", locale: locale, label)
            spokenParts.append(looks)
            cardLines.append(looks)
        }
        if !findings.ocrText.isEmpty {
            let said = L10n.fmt("pointask.answer.labelSays", locale: locale,
                                findings.translatedText ?? findings.ocrText)
            spokenParts.append(said)
            cardLines.append(said)
        }

        // 4. Nothing local and no VLM: the honest failure line — never a
        //    fabricated answer, never a silent empty card (design §3
        //    ladder 6).
        guard !spokenParts.isEmpty else {
            return failureAnswer(locale: locale)
        }
        return PointAskAnswer(spokenLine: spokenParts.joined(separator: " "),
                              cardLines: cardLines,
                              isMedicineRefusal: false, isFailure: false, vlmUsed: false)
    }

    static func failureAnswer(locale: Locale) -> PointAskAnswer {
        let line = L10n.str("pointask.state.failed", locale: locale)
        return PointAskAnswer(spokenLine: line, cardLines: [line],
                              isMedicineRefusal: false, isFailure: true, vlmUsed: false)
    }

    // MARK: - Close

    /// Ends the session's work: no task may publish after close, and the
    /// surface returns to waiting for a session that is gone.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        resolveTask?.cancel()
        analysisTask?.cancel()
        ageOutTask?.cancel()
        resolveTask = nil
        analysisTask = nil
        ageOutTask = nil
        latestFrame = nil
        pendingAnalysis = nil
        answer = nil
        cloudIndicatorActive = false
        isConsentPromptPresented = false
        consentFailureMessage = nil
        phase = .awaitingTap
    }
}

extension AppLanguage {
    /// The target language for point-ask answers and dictionary lookups,
    /// derived from the session's locale — the same default the
    /// live-translate pipeline translates into.
    init(locale: Locale) {
        self = (locale.language.languageCode?.identifier == "en") ? .english : .nepali
    }
}
