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

        "region_appeared": Entry(outcomes: ["success"], metadataKeys: []),
        "region_removed": Entry(outcomes: ["success"], metadataKeys: []),
        "text_change": Entry(outcomes: ["success"], metadataKeys: ["regionCount"]),

        "translation_batch_requested": Entry(outcomes: ["success"],
                                             metadataKeys: ["stringCount", "batchIndex", "batchCount"]),
        "translation_batch_resolved": Entry(outcomes: ["success", "partial"],
                                           metadataKeys: ["resolvedCount", "unresolvedCount", "durationMs"]),
        "translation_degraded": Entry(outcomes: ["degraded"], metadataKeys: ["reason", "regionCount"]),
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
        case stringCount
        case batchIndex
        case batchCount
        case resolvedCount
        case unresolvedCount
        case durationMs
        case keyCount
        case count
        case origin
        case mode
        case reason
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

    // MARK: Stabilisation (C03)

    func regionAppeared() {
        emit("region_appeared", outcome: "success")
    }

    func regionRemoved() {
        emit("region_removed", outcome: "success")
    }

    func textChange(regionCount: Int) {
        emit("text_change", outcome: "success",
             metadata: [.regionCount: String(regionCount)])
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

    func translationDedupeHit(keyCount: Int) {
        emit("translation_dedupe_hit", outcome: "deduped",
             metadata: [.keyCount: String(keyCount)])
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
