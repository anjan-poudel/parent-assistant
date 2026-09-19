import Foundation

// T-003 — the feature's event schema and its typed emitters.
//
// Recognized text and translated text are user content and may never appear
// in a log, in any build (NFR-LCT-006). This file enforces that **by
// schema**: every metadata value is an integer count, an integer duration, a
// closed-vocabulary token or the disclosure version stamp, and there is no
// parameter anywhere in `LiveTranslateEvents` through which a recognized or
// translated string could travel — the API is typed, so content is not
// merely discouraged, it is not expressible.
//
// Two coverage rules ride on this file:
//  - `LiveTranslateEventCatalogue` is the pinned key set. A test asserts
//    every declared key is in `LogSanitiser.allowedKeys` (the additive
//    extension landed with this task — AM-2/CL-5) and that every key an
//    emitter actually produces is declared, so a new key cannot be added
//    without a deliberate decision in both places.
//  - the emitters can only build metadata from `MetadataKey`, whose raw
//    values are the allow-listed spellings, so an undeclared key is a
//    compile error rather than a silently dropped field.
//
// One event is not in the design's catalogue table and is named here
// deliberately: `tracking_unsupported`. C02's prose requires an unsupported
// tracking request to degrade to OCR-only "with an honest event", and no
// event in the table carries that signal; the event is content-free (a fixed
// type, a fixed outcome and the taxonomy's code) and introduces no key.

/// Closed vocabulary for the `origin` metadata key: where a cache operation
/// was decided. The cache's own `Origin` maps onto these tokens; the token
/// spellings live here with the event schema so they cannot be spelled two
/// ways.
enum LiveTranslateCacheOrigin: String, Equatable, CaseIterable {
    /// The curated on-device dictionary (tier 0).
    case curatedDictionary = "curated_dictionary"
    /// The persisted translation cache.
    case persisted = "persisted"
}

/// Closed vocabulary for `translation_resolved.origin` (cascade provenance,
/// 2026-09-19): a settle's answer came from storage or was computed now.
enum LiveTranslateResolutionOrigin: String, Equatable, CaseIterable {
    case fresh = "fresh"
    case cache = "cache"
}

/// Closed vocabulary for the `reason` metadata key on the on-device tier's
/// events: why a batch was not answered by the brain.
///
/// It covers both halves of "the tier could not answer" — the tier was never
/// usable (`modelNotInstalled`, `runtimeMissing`, `modelLoadFailed`) and the
/// attempt failed (`inferenceFailed`, `inferenceTimeout`) — because from the
/// caller's side they are one outcome: the strings fall through to the next
/// tier unresolved. The token says which it was.
///
/// A closed set of tokens rather than a message, for the same reason every
/// other reason in this file is: the value travels in event metadata, and a
/// free-form string is how content or a rendered error reaches a log. `String`
/// is the raw type, not a parameter type — no emitter takes a `String`
/// (pinned by `LiveTranslateSourceHygieneTests.testNoEmitterAcceptsFreeText`).
enum LiveTranslateBrainUnavailableReason: String, Equatable, CaseIterable {
    /// No translation model is installed on this device.
    case modelNotInstalled = "model_not_installed"
    /// The on-device LLM runtime (or the model store that fronts it) is not
    /// available in this build.
    case runtimeMissing = "runtime_missing"
    /// The language model could not be constructed from the installed file.
    case modelLoadFailed = "model_load_failed"
    /// The generation returned nothing usable — a runtime failure, an
    /// unusable completion, or an answer that matched no source string.
    case inferenceFailed = "inference_failed"
    /// The generation outlived the configured deadline
    /// (`brainTranslationTimeoutSeconds`) and was stopped.
    case inferenceTimeout = "inference_timeout"
}

/// [PRESSURE-SAFE LOAD] (2026-09-19) Closed vocabulary for the `reason` key on
/// `brain_translation_batch`: **why** the tier declined to attempt a batch it
/// was handed.
///
/// Until this existed the deferral was carried only in the tier's return value
/// (`LocalBrainDeferral`), so the one fact a device capture most needed — "the
/// brain was never asked, and here is what stopped it" — was visible on screen
/// and nowhere else. A capture of the 2026-09-19 death showed a batch event
/// with `resolvedCount: 0` and no way to tell a resident voice brain from a
/// mis-set memory floor from a starved device.
///
/// A closed set, like every other token in this file, and for the same reason:
/// the value travels in event metadata, so it can be no free-form string
/// (`LiveTranslateSourceHygieneTests.testNoEmitterAcceptsFreeText` pins that no
/// emitter takes a `String`).
enum LiveTranslateBrainDeferralReason: String, Equatable, CaseIterable {
    /// Another owner's brain is live (the voice pipeline's `.brain` /
    /// `.intentBrain` slot).
    case residentBrain = "resident_brain"
    /// The app's own headroom under its jetsam ceiling is below the brain's
    /// declared non-pageable footprint.
    case insufficientHeadroom = "insufficient_headroom"
    /// [PRESSURE-SAFE LOAD] The kernel's own memory-pressure level is
    /// `.warning` or `.critical` right now.
    case memoryPressure = "memory_pressure"
    /// [PRESSURE-SAFE LOAD] `.critical` fired inside the tier's recency window
    /// (`brainTranslationCriticalPressureWindowSeconds`) — the device is still
    /// the device that was about to be killed, whatever the level says now.
    case recentCriticalPressure = "recent_critical_pressure"
    /// [PRESSURE-SAFE LOAD] The load had already been admitted and declared in
    /// flight when a warden asked for the position, so it stood down rather
    /// than re-filling the row the warden had just cleared.
    case releaseRequestedDuringLoad = "release_requested_during_load"
}

/// Closed vocabulary for the `failureStage` metadata key: **where** an
/// on-device brain attempt stopped.
///
/// Added 2026-09-17 for the device report this file was amended over. The
/// `reason` token answers "could not answer" — but the shipped pair
/// (`inference_failed`, `inference_timeout`) collapses four different device
/// facts into two tokens: a handle that never loaded, a prompt the guard
/// refused, a decode that threw, and a decode that the deadline (or the
/// caller) stopped. The owner's console showed the tier failing every cycle
/// with no way to tell a slow 4B from a refused prompt from a stopped decode,
/// so the reason token alone was not enough to act on. The stage is the
/// missing half and it is what a capture now carries.
///
/// A closed set, like every other token in this file, and for the same
/// reason: the value travels in event metadata, so it can be no free-form
/// string (`LiveTranslateSourceHygieneTests.testNoEmitterAcceptsFreeText`
/// pins that no emitter takes a `String`).
enum BrainFailureStage: String, Equatable, CaseIterable {
    /// The tier never reached a load: no installed model, or no llama.cpp
    /// runtime in this build. The strings were never at risk and nothing was
    /// spent — this stage says "the device cannot", where every other stage
    /// says "the device tried".
    case availability
    /// The handle could not be constructed from the installed file — a corrupt
    /// or mismatched artifact, or a context the device could not create.
    case load
    /// [PRESSURE-SAFE LOAD] (2026-09-19) The load was stood down **before the
    /// runtime was asked to construct anything**, because the kernel's
    /// memory-pressure state — or a warden's ask that arrived while the load
    /// was in flight — made it a spike the device must not create.
    ///
    /// Its own case rather than a second spelling of `load`, because the two
    /// are opposite facts about the artifact: `load` means somebody tried and
    /// the file or the context would not construct, this means the device
    /// declined and nothing was ever at risk. Collapsing them is what would
    /// make the next device capture read a starved phone as a corrupt model.
    case loadAbandoned = "load_abandoned"
    /// The composed prompt would have left less than the output headroom
    /// inside the shared 1,024-token context, so the guard refused it before
    /// the first token rather than discovering the wall as a truncated answer.
    case promptBudget = "prompt_budget"
    /// The constrained decode threw — a llama.cpp error raised out of
    /// `generateWithConstraints` that the tier does not classify further
    /// (context creation, grammar construction, a failed `llama_decode`).
    case decode
    /// The decode outlived `brainTranslationTimeoutSeconds` and the tier
    /// stopped it. A device fact about the model and the batch, not about the
    /// caller.
    case deadline
    /// The caller stopped waiting, so the tier stopped the decode with it.
    /// Distinguished from `deadline` on purpose: the tier's own bound was
    /// never reached, which points at everything *before* the decode — the
    /// handle load, or a previous attempt's decode still holding the runtime.
    case cancelled
    /// The pipeline's own stage deadline expired
    /// (`brainTranslationStageDeadlineSeconds`): the tier never returned at
    /// all, so this one is recorded by the caller and not by the tier.
    case stageDeadline = "stage_deadline"
}

/// Closed vocabulary for the `mode` metadata key: what asked for speech.
enum LiveTranslateSpeechMode: String, Equatable, CaseIterable {
    /// The tap-to-hear affordance in the overlay.
    case tap
    /// The `read this to me` command.
    case readAll = "read_all"
    /// The `repeat` command — replayed from what was already spoken; it never
    /// re-translates, re-sends or re-consents.
    case repeatLast = "repeat_last"
    /// The command handler's one re-prompt after an utterance that matched
    /// nothing (C12). Added by T-026, which is where the capture's
    /// `Outcome.reprompt` meets the copy; the wording is the shipped
    /// assistant's own line rather than a new one.
    case reprompt
}

extension CameraUnavailableReason {
    /// Closed token for the `reason` metadata key.
    var token: String {
        switch self {
        case .noCaptureDevice: return "no_capture_device"
        case .configurationFailed: return "configuration_failed"
        case .resourceInUse: return "resource_in_use"
        }
    }
}

extension CameraInterruption {
    /// Closed token for the `reason` metadata key.
    var token: String {
        switch self {
        case .backgrounded: return "backgrounded"
        case .systemInterruption: return "system_interruption"
        case .thermal: return "thermal"
        }
    }
}

/// The feature's complete event schema, pinned against the log allow-list.
enum LiveTranslateEventCatalogue {

    /// The observability component every one of these events is emitted on.
    static let component = "livetranslate"

    struct Entry: Equatable {
        /// Every outcome value this event may carry. Fixed vocabulary.
        let outcomes: Set<String>
        /// Every metadata key this event may carry. A subset of
        /// `LogSanitiser.allowedKeys`, asserted by test.
        let metadataKeys: Set<String>
    }

    /// The declared keys an event may **omit**, per event type.
    ///
    /// Every other declared key is unconditional and asserted so by test: an
    /// event that declares a key carries it, always. This map exists for the
    /// one shape that is genuinely conditional —
    /// `brain_translation_batch`'s `reason`, which a batch that ran has
    /// nothing to say about — and it is declared here, once, rather than left
    /// to an emitter's discretion, so that "this key may be absent" is a
    /// decision the schema records. `Entry`'s own doc already reads "every
    /// metadata key this event *may* carry"; this is where that becomes
    /// checkable.
    ///
    /// A key that is not listed here and not emitted fails the completeness
    /// test, which is the point: a new conditional key must be declared
    /// conditional rather than quietly weakening the check.
    static let optionalMetadataKeys: [String: Set<String>] = [
        // Present exactly when the tier declined to attempt the batch
        // ([PRESSURE-SAFE LOAD], 2026-09-19).
        "brain_translation_batch": ["reason"],
    ]

    /// Event type → schema. One entry per emitter in `LiveTranslateEvents`.
    static let entries: [String: Entry] = [
        "session_started": Entry(outcomes: ["success"], metadataKeys: []),
        "session_ended": Entry(outcomes: ["success"], metadataKeys: []),

        "camera_denied": Entry(outcomes: ["failure"], metadataKeys: []),
        "camera_unavailable": Entry(outcomes: ["failure"], metadataKeys: ["reason"]),
        "camera_interrupted": Entry(outcomes: ["failure"], metadataKeys: ["reason"]),
        "camera_resumed": Entry(outcomes: ["success"], metadataKeys: ["reason"]),

        "ocr_pass": Entry(outcomes: ["success", "empty"], metadataKeys: ["regionCount"]),
        "ocr_pass_failed": Entry(outcomes: ["failure"], metadataKeys: []),
        "tracking_unsupported": Entry(outcomes: ["degraded"], metadataKeys: []),
        // The object pass (scene-block rework, 2026-09-18). `object_pass` is
        // the slow pass's own report: how many objects the frame was grouped
        // by. Zero is `empty` and not a failure — a scene with nothing
        // object-like in it is grouped by text geometry, which is exactly what
        // every pass did before the rework.
        //
        // The two ways the pass can be lost are kept apart, because they are
        // different facts about a device and a probe that conflated them would
        // report the wrong one. `object_detection_unsupported` is this pass's
        // `tracking_unsupported`: the runtime has no such capability.
        // `object_pass_failed` is a request the runtime *has* the capability to
        // answer and refused — which is what this build meets on a simulator
        // whose Vision cannot create an Espresso context — and it carries the
        // taxonomy's code for it. Both leave the feature grouping by text
        // geometry, and the elder never sees the difference. All three events
        // carry counts and closed tokens only.
        "object_pass": Entry(outcomes: ["success", "empty"], metadataKeys: ["count"]),
        "object_pass_failed": Entry(outcomes: ["failure"], metadataKeys: []),
        "object_detection_unsupported": Entry(outcomes: ["degraded"], metadataKeys: []),

        "region_appeared": Entry(outcomes: ["success"], metadataKeys: []),
        "region_removed": Entry(outcomes: ["success"], metadataKeys: []),
        // `regionSetHash` added 2026-09-18 with the owner's identity-churn
        // report: the count alone cannot tell a changed reading from a re-keyed
        // region, and both were arriving as the same line of console.
        "text_change": Entry(outcomes: ["success"],
                             metadataKeys: ["regionCount", "regionSetHash"]),

        "translation_batch_requested": Entry(outcomes: ["success"],
                                             metadataKeys: ["stringCount", "batchIndex", "batchCount"]),
        // The on-device (tier 1) translation tier. Two events, both honest:
        //  - `brain_translation_batch` says the tier RAN and what it answered
        //    — every item it was handed either came back translated or did
        //    not, so the two counts plus the duration are the whole story.
        //    No key here can carry a string: the counts are integers and the
        //    duration is a number of milliseconds.
        //  - `brain_translation_unavailable` says the tier could not answer
        //    this batch and why, with the closed-vocabulary reason — an
        //    absent model and a timed-out generation are both "the next tier
        //    has to answer", and the token keeps them distinguishable. It is
        //    the same shape as `tracking_unsupported`: a degradation the
        //    project must be able to see and the elder never sees, because
        //    the cloud tier is still there to answer.
        // `reason` joined this schema 2026-09-19 ([PRESSURE-SAFE LOAD]) and is
        // present only when the tier declined to attempt the batch — see
        // `LiveTranslateBrainDeferralReason`. A batch that ran carries no
        // reason; one that did not carries exactly one closed token.
        "brain_translation_batch": Entry(outcomes: ["success", "partial", "degraded"],
                                         metadataKeys: ["resolvedCount", "unresolvedCount", "durationMs", "reason"]),
        // `failureStage` joined the schema 2026-09-17 with the tier's device
        // report (see `BrainFailureStage`): the reason token says the attempt
        // could not answer, the stage says where it stopped. Both are closed
        // vocabularies, so neither can carry content.
        "brain_translation_unavailable": Entry(outcomes: ["degraded"],
                                               metadataKeys: ["reason", "failureStage"]),
        "translation_batch_resolved": Entry(outcomes: ["success", "partial"],
                                           metadataKeys: ["resolvedCount", "unresolvedCount", "durationMs"]),
        "translation_degraded": Entry(outcomes: ["degraded"], metadataKeys: ["reason", "regionCount"]),
        // The cascade's provenance (owner ask, 2026-09-19: "log what source
        // the translation is coming from"): one event per settle call per
        // tier present, counts only — no string ever rides in it.
        "translation_resolved": Entry(outcomes: ["success"], metadataKeys: ["tier", "origin", "count"]),
        "translation_dedupe_hit": Entry(outcomes: ["deduped"], metadataKeys: ["keyCount"]),
        "text_quarantined": Entry(outcomes: ["quarantined"], metadataKeys: ["count"]),

        "consent_prompt_shown": Entry(outcomes: ["success"], metadataKeys: ["disclosureVersion"]),
        "consent_recorded": Entry(outcomes: ["success"], metadataKeys: ["disclosureVersion"]),
        "consent_denied": Entry(outcomes: ["success"], metadataKeys: ["disclosureVersion"]),
        "consent_revoked": Entry(outcomes: ["success"], metadataKeys: ["disclosureVersion"]),
        "consent_unreadable": Entry(outcomes: ["failure"], metadataKeys: []),
        // T-014/AM-4: a consent record or revocation that could not be made to
        // take effect is evidence the safety property needs — the elder's
        // decision did not reach storage, and that must be visible rather
        // than implied by a missing success event.
        "consent_write_failed": Entry(outcomes: ["failure"], metadataKeys: []),

        "cloud_indicator_shown": Entry(outcomes: ["success"], metadataKeys: []),
        "cloud_indicator_hidden": Entry(outcomes: ["success"], metadataKeys: []),
        "cost_exhausted_latched": Entry(outcomes: ["latched"], metadataKeys: []),

        "cache_hit": Entry(outcomes: ["success"], metadataKeys: ["origin", "count"]),
        "cache_miss": Entry(outcomes: ["success"], metadataKeys: ["origin", "count"]),
        "cache_evicted": Entry(outcomes: ["success"], metadataKeys: ["origin", "count"]),
        "cache_payload_reset": Entry(outcomes: ["failure"], metadataKeys: []),
        "cache_write_failed": Entry(outcomes: ["failure"], metadataKeys: []),

        "speak_requested": Entry(outcomes: ["success"], metadataKeys: ["mode"]),
        "speak_failed": Entry(outcomes: ["failure"], metadataKeys: ["mode"])
    ]

    /// Every metadata key the feature can emit, across all events.
    static var allMetadataKeys: Set<String> {
        entries.values.reduce(into: Set<String>()) { $0.formUnion($1.metadataKeys) }
    }

    /// Every event type the feature can emit.
    static var allEventTypes: Set<String> { Set(entries.keys) }
}

/// Typed, content-free emitters for component `livetranslate`.
///
/// Every parameter is an integer, a closed-vocabulary enum or nothing at all
/// — with one exception, the disclosure version, which the type reads from
/// its own config so no call site can pass anything else into it.
struct LiveTranslateEvents {

    /// The metadata keys this feature may emit, spelled once. The raw values
    /// are the `LogSanitiser` allow-list entries added for this feature; a
    /// test pins this enum against that set, so the two cannot drift.
    enum MetadataKey: String, CaseIterable {
        case regionCount
        /// The content-free digest of the visible text set a `text_change`
        /// carries (2026-09-18). A `UInt32`, rendered `xxxx:xxxx` by the
        /// emitter — never a recognized string, and never a region identity.
        case regionSetHash
        case stringCount
        case batchIndex
        case batchCount
        case resolvedCount
        case unresolvedCount
        case durationMs
        case keyCount
        case count
        case origin
        case tier
        case mode
        case reason
        /// Where an on-device brain attempt stopped (`BrainFailureStage`).
        /// Added 2026-09-17: the reason token alone could not tell a slow
        /// decode from a refused prompt from a stopped one.
        case failureStage
        case disclosureVersion
    }

    let bus: ObservabilityBus
    let config: LiveTranslateConfig

    init(bus: ObservabilityBus, config: LiveTranslateConfig = .default) {
        self.bus = bus
        self.config = config
    }

    // MARK: Private plumbing

    private func emit(_ eventType: String,
                      outcome: String,
                      errorCode: String? = nil,
                      metadata: [MetadataKey: String] = [:],
                      durationMs: Int? = nil) {
        var stringMetadata: [String: String] = [:]
        for (key, value) in metadata { stringMetadata[key.rawValue] = value }
        bus.emit(ObservabilityEvent(
            component: LiveTranslateEventCatalogue.component,
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: stringMetadata
        ))
    }

    /// The code path for every failure event: the code comes from the
    /// taxonomy, never from a rendered error.
    private func code(_ error: LiveTranslateError) -> String { error.logSafeErrorCode }

    /// The same route for the consent gate's own write-path error (T-014):
    /// it is a `LogSafeErrorCode` like every other error the feature
    /// records, so no rendered message can reach an event.
    private func code(_ error: LiveTranslateConsentGate.ConsentError) -> String {
        error.logSafeErrorCode
    }

    // MARK: Session

    func sessionStarted() {
        emit("session_started", outcome: "success")
    }

    func sessionEnded() {
        emit("session_ended", outcome: "success")
    }

    // MARK: Camera (C01)

    func cameraDenied() {
        emit("camera_denied", outcome: "failure",
             errorCode: code(.cameraPermissionDenied))
    }

    func cameraUnavailable(_ reason: CameraUnavailableReason) {
        emit("camera_unavailable", outcome: "failure",
             errorCode: code(.cameraUnavailable(reason)),
             metadata: [.reason: reason.token])
    }

    func cameraInterrupted(_ reason: CameraInterruption) {
        emit("camera_interrupted", outcome: "failure",
             errorCode: code(.cameraSessionInterrupted(reason)),
             metadata: [.reason: reason.token])
    }

    /// The cause is carried so a resumed session says what it recovered
    /// from — a resume without a cause is an unexplained state change.
    func cameraResumed(recoveringFrom reason: CameraInterruption) {
        emit("camera_resumed", outcome: "success",
             metadata: [.reason: reason.token])
    }

    // MARK: Detection (C02)

    /// One completed OCR pass. Zero recognized regions is `empty` — the
    /// empty-state hint, not a failure (failure table row 4).
    func ocrPass(regionCount: Int) {
        emit("ocr_pass", outcome: regionCount > 0 ? "success" : "empty",
             metadata: [.regionCount: String(regionCount)])
    }

    func ocrPassFailed(_ error: LiveTranslateError) {
        emit("ocr_pass_failed", outcome: "failure", errorCode: code(error))
    }

    /// Tracking is a SHOULD (FR-LCT-004): the feature continues with OCR
    /// only. Never surfaced to the elder — recorded here so the degradation
    /// is visible to the project rather than invisible to everyone.
    func trackingUnsupported() {
        emit("tracking_unsupported", outcome: "degraded",
             errorCode: code(.trackingUnsupported))
    }

    /// One completed object pass, and how many objects the scene resolved
    /// into. Zero is the `empty` outcome rather than a failure: it is the
    /// documented "group by text geometry" path, and the text is unaffected.
    func objectPass(objectCount: Int) {
        emit("object_pass", outcome: objectCount > 0 ? "success" : "empty",
             metadata: [.count: String(objectCount)])
    }

    /// The runtime answered an object request with a refusal. The feature goes
    /// on without it exactly as it does when the capability is absent, so what
    /// this event adds is the *reason*: the taxonomy's code, in the same shape
    /// `ocr_pass_failed` records the OCR request's.
    func objectPassFailed(_ error: LiveTranslateError) {
        emit("object_pass_failed", outcome: "failure", errorCode: code(error))
    }

    /// Object detection is a SHOULD, like tracking: the feature continues
    /// grouping by text geometry alone, and the degradation is recorded so it
    /// is visible to the project rather than invisible to everyone. No error
    /// code: this is a capability the runtime does not have, not a failure of
    /// one of the taxonomy's operations, and the elder is never shown it.
    func objectDetectionUnsupported() {
        emit("object_detection_unsupported", outcome: "degraded")
    }

    // MARK: Stabilisation (C03)

    func regionAppeared() {
        emit("region_appeared", outcome: "success")
    }

    func regionRemoved() {
        emit("region_removed", outcome: "success")
    }

    /// A change on screen, with the two content-free facts the next device
    /// capture needs to tell one failure from the other (owner verdict,
    /// 2026-09-18): how many regions the screen has, and a **digest of the text
    /// set** they carry.
    ///
    /// The count alone could not separate the two stories the same log tells:
    /// "the reading really changed, so the session is re-asking" and "the
    /// identity churned, so the overlay is re-drawing" produce the same count on
    /// every pass. With the digest the two part company — a constant digest under
    /// a stream of `text_change` events is identity churn, a changing one is a
    /// changing reading — and neither number carries a recognized string, a
    /// translation or a region identity.
    ///
    /// The digest is rendered here, from a `UInt32`, so no call site can hand
    /// this emitter anything but a number: free text has no parameter to travel
    /// in (`LiveTranslateSourceHygieneTests` pins that structurally).
    func textChange(regionCount: Int, regionSetHash: UInt32) {
        emit("text_change", outcome: "success",
             metadata: [.regionCount: String(regionCount),
                        .regionSetHash: Self.regionSetHashHex(regionSetHash)])
    }

    /// How a region-set digest is spelled in the log: two groups of four hex
    /// digits, `"a1b2:c3d4"`.
    ///
    /// The **colon is load-bearing**, not decoration. `LogSanitiser`'s
    /// defence-in-depth scrub redacts anything matching a phone number — a digit
    /// followed by six or more digits, spaces, hyphens, dots or parentheses and
    /// another digit — so a digest that happened to come out all digits (about
    /// one in forty of them) would be logged as `[redacted]` and the one line the
    /// owner is reading would lose its discriminator, intermittently and
    /// invisibly. A colon is outside that pattern's character class, so no
    /// rendering of these eight hex digits can match it. The value is also short
    /// enough (nine characters) to stay under the bus's unbroken-run bound, and
    /// it is not routed through the code-shaped bound (`codeShapedMetadataKeys`
    /// lists `errorCode` alone).
    ///
    /// The name says "hex" and not "text" deliberately: the release log-safety
    /// gate flags any event-field expression containing a content word
    /// (`…Text`, `text`, transcript, translated, recognized, prompt), and this
    /// helper is called from inside a `metadata:` literal. A content-worded name
    /// there is indistinguishable, to that scanner, from an emitter that really
    /// does render a string into the log; renaming keeps the gate meaningful for
    /// the code that *should* trip it instead of teaching it to ignore a line.
    static func regionSetHashHex(_ digest: UInt32) -> String {
        let hex = String(digest, radix: 16, uppercase: false)
        let padded = String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        return "\(padded.prefix(4)):\(padded.suffix(4))"
    }

    // MARK: Tier 2 (C08)

    func translationBatchRequested(stringCount: Int, batchIndex: Int, batchCount: Int) {
        emit("translation_batch_requested", outcome: "success",
             metadata: [.stringCount: String(stringCount),
                        .batchIndex: String(batchIndex),
                        .batchCount: String(batchCount)])
    }

    func translationBatchResolved(resolvedCount: Int, unresolvedCount: Int, durationMs: Int) {
        emit("translation_batch_resolved",
             outcome: unresolvedCount > 0 ? "partial" : "success",
             metadata: [.resolvedCount: String(resolvedCount),
                        .unresolvedCount: String(unresolvedCount),
                        // The catalogue declares `durationMs` as metadata;
                        // the shipped event also has a top-level duration
                        // field. Both are written from this one parameter,
                        // so they cannot disagree.
                        .durationMs: String(durationMs)],
             durationMs: durationMs)
    }

    func translationDegraded(reason: TranslationUnavailableReason, regionCount: Int) {
        emit("translation_degraded", outcome: "degraded",
             metadata: [.reason: reason.rawValue,
                        .regionCount: String(regionCount)])
    }

    /// Where a translation came from, logged at the moment it settles: the
    /// tier that answered (`dictionary` / `onDeviceBrain` / `cloud`) and the
    /// origin (`cache` for a persisted answer, `fresh` for a new one). One
    /// event per tier per settle, so a mixed batch reads as a tier histogram.
    func translationResolved(tier: TranslationTier, origin: LiveTranslateResolutionOrigin, count: Int) {
        emit("translation_resolved", outcome: "success",
             metadata: [.tier: tier.rawValue,
                        .origin: origin.rawValue,
                        .count: String(count)])
    }

    func translationDedupeHit(keyCount: Int) {
        emit("translation_dedupe_hit", outcome: "deduped",
             metadata: [.keyCount: String(keyCount)])
    }

    // MARK: Tier 1 — the on-device brain

    /// One brain batch's result. `success` only when every string it was
    /// handed came back translated, `partial` when some did, `degraded` when
    /// none did — the same three-way honesty the cloud's batch event uses,
    /// and never a claim of success for a batch that answered nothing.
    ///
    /// [PRESSURE-SAFE LOAD] (2026-09-19) `deferral` is present exactly when
    /// the tier declined to attempt the batch, and it is the *only* thing that
    /// distinguishes "the brain was asked and answered nothing" from "the
    /// brain was never asked". Both are `degraded` with `resolvedCount: 0`,
    /// which is correct — the caller's next move is the same — but a capture
    /// that cannot tell them apart cannot say whether a phone is short of
    /// memory or the model is bad. It is a closed token, never free text.
    func brainTranslationBatch(resolvedCount: Int,
                               unresolvedCount: Int,
                               durationMs: Int,
                               deferral: LiveTranslateBrainDeferralReason? = nil) {
        let outcome: String
        if unresolvedCount == 0 {
            outcome = "success"
        } else if resolvedCount > 0 {
            outcome = "partial"
        } else {
            outcome = "degraded"
        }
        var metadata: [MetadataKey: String] = [.resolvedCount: String(resolvedCount),
                                               .unresolvedCount: String(unresolvedCount),
                                               // The catalogue declares
                                               // `durationMs` as metadata and
                                               // the shipped event also has a
                                               // top-level duration field;
                                               // both are written from this one
                                               // parameter, so they cannot
                                               // disagree.
                                               .durationMs: String(durationMs)]
        if let deferral { metadata[.reason] = deferral.rawValue }
        emit("brain_translation_batch", outcome: outcome,
             metadata: metadata,
             durationMs: durationMs)
    }

    /// The tier could not be used. Content-free by construction: the reason is
    /// a closed token, the stage is another, and there is nothing else to
    /// carry.
    ///
    /// `stage` is required rather than defaulted: a call site that could omit
    /// it is a call site that would leave a capture unable to say where the
    /// attempt stopped, which is the whole reason the key exists. The cheap
    /// tokens (`availability` for a missing model, `load` for a refused
    /// handle) are the ones the tier's early exits pass.
    func brainTranslationUnavailable(_ reason: LiveTranslateBrainUnavailableReason,
                                     stage: BrainFailureStage) {
        emit("brain_translation_unavailable", outcome: "degraded",
             metadata: [.reason: reason.rawValue, .failureStage: stage.rawValue])
    }

    // MARK: Sanitisation (C07)

    /// Count only. The offending text is never part of the record.
    func textQuarantined(count: Int) {
        emit("text_quarantined", outcome: "quarantined",
             metadata: [.count: String(count)])
    }

    // MARK: Consent (C09)

    func consentPromptShown() {
        emit("consent_prompt_shown", outcome: "success",
             metadata: [.disclosureVersion: config.disclosureVersion])
    }

    func consentRecorded() {
        emit("consent_recorded", outcome: "success",
             metadata: [.disclosureVersion: config.disclosureVersion])
    }

    func consentDenied() {
        emit("consent_denied", outcome: "success",
             metadata: [.disclosureVersion: config.disclosureVersion])
    }

    func consentRevoked() {
        emit("consent_revoked", outcome: "success",
             metadata: [.disclosureVersion: config.disclosureVersion])
    }

    func consentUnreadable() {
        emit("consent_unreadable", outcome: "failure",
             errorCode: code(.consentRecordUnreadable))
    }

    /// A consent write (or the verified delete) did not take effect. The
    /// error code is the gate's stable token; no identifier, no text.
    func consentWriteFailed() {
        emit("consent_write_failed", outcome: "failure",
             errorCode: code(LiveTranslateConsentGate.ConsentError.writeFailed))
    }

    // MARK: Cloud indicator (C10)

    func cloudIndicatorShown() {
        emit("cloud_indicator_shown", outcome: "success")
    }

    func cloudIndicatorHidden() {
        emit("cloud_indicator_hidden", outcome: "success")
    }

    // MARK: Cost (C15/OD7)

    /// The feature's own session latch. The family-visible cap signal stays
    /// the shipped governor's `daily_cap_warning` / `daily_cap_reached` on
    /// component `gemini_cost`; this event is additional and is never a
    /// replacement for them.
    func costExhaustedLatched() {
        emit("cost_exhausted_latched", outcome: "latched")
    }

    // MARK: Cache (C05)

    func cacheHit(origin: LiveTranslateCacheOrigin, count: Int) {
        emit("cache_hit", outcome: "success",
             metadata: [.origin: origin.rawValue, .count: String(count)])
    }

    func cacheMiss(origin: LiveTranslateCacheOrigin, count: Int) {
        emit("cache_miss", outcome: "success",
             metadata: [.origin: origin.rawValue, .count: String(count)])
    }

    func cacheEvicted(origin: LiveTranslateCacheOrigin, count: Int) {
        emit("cache_evicted", outcome: "success",
             metadata: [.origin: origin.rawValue, .count: String(count)])
    }

    func cachePayloadReset(_ error: LiveTranslateError) {
        emit("cache_payload_reset", outcome: "failure", errorCode: code(error))
    }

    func cacheWriteFailed(_ error: LiveTranslateError) {
        emit("cache_write_failed", outcome: "failure", errorCode: code(error))
    }

    // MARK: Speech (C12)

    func speakRequested(mode: LiveTranslateSpeechMode) {
        emit("speak_requested", outcome: "success",
             metadata: [.mode: mode.rawValue])
    }

    func speakFailed(mode: LiveTranslateSpeechMode) {
        emit("speak_failed", outcome: "failure",
             metadata: [.mode: mode.rawValue])
    }
}
