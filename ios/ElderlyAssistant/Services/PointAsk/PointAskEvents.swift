import Foundation

// The feature's event schema and its typed emitters — the T-003 shape.
//
// OCR text, translations, class labels and the VLM's words are user content
// and may never appear in a log, in any build. This file enforces that **by
// schema**: every metadata value is an integer count, an integer duration, a
// closed-vocabulary token or the disclosure version stamp, and there is no
// parameter anywhere in `PointAskEvents` through which content could travel
// — the API is typed, so content is not merely discouraged, it is not
// expressible.
//
// Two coverage rules ride on this file (mirroring `LiveTranslateEvents`):
//  - `PointAskEventCatalogue` is the pinned key set; `PointAskCopyTests`
//    asserts every declared key is in `LogSanitiser.allowedKeys` and that
//    every key an emitter produces is declared,
//  - the emitters build metadata only from `MetadataKey`, whose raw values
//    are the allow-listed spellings, so an undeclared key is a compile error
//    rather than a silently dropped field.

/// Closed vocabulary for the `reason` metadata key: why the cloud VLM stage
/// did not run, or why a stage failed. A closed set of tokens rather than a
/// message, because the value travels in event metadata and a free-form
/// string is how content reaches a log.
enum PointAskCloudSkipReason: String, Equatable, CaseIterable {
    /// The master switch is off: nothing was attempted.
    case cloudDisabled = "cloud_disabled"
    /// The gate refused — no recorded grant (the prompt has not been shown,
    /// or was shown and the answer is pending).
    case consentNotRecorded = "consent_not_recorded"
    /// The elder declined or revoked.
    case consentDenied = "consent_denied"
    /// The record exists but cannot be trusted.
    case consentUnreadable = "consent_unreadable"
    /// A revocation cancelled the in-flight request.
    case revoked = "revoked"
    /// The shared cost governor's daily cap is spent.
    case quotaCapped = "quota_capped"
}

/// Closed vocabulary for the `reason` metadata key on a stage failure.
enum PointAskStageFailureReason: String, Equatable, CaseIterable {
    /// The Vision request could not be performed at all.
    case requestFailed = "request_failed"
    /// The stage outlived its configured deadline and the pipeline stopped
    /// waiting.
    case stageTimeout = "stage_timeout"
    /// The model returned nothing usable (parse failure or empty payload).
    case parseFailed = "parse_failed"
    /// Transport or timeout failure, after the configured retries.
    case transportFailed = "transport_failed"
}

/// The feature's event schema, pinned against the log allow-list.
enum PointAskEventCatalogue {

    /// The observability component every one of these events is emitted on.
    static let component = "pointask"

    struct Entry: Equatable {
        /// Every outcome value this event may carry. Fixed vocabulary.
        let outcomes: Set<String>
        /// Every metadata key this event may carry. A subset of
        /// `LogSanitiser.allowedKeys`, asserted by test.
        let metadataKeys: Set<String>
    }

    /// Event type → schema. One entry per emitter in `PointAskEvents`.
    static let entries: [String: Entry] = [
        // Tap → box. `origin` is a `PointAskTargetSource` token.
        "tap_anchored": Entry(outcomes: ["success"],
                              metadataKeys: ["origin"]),
        // The box retired without a chip tap.
        "box_aged_out": Entry(outcomes: ["success"], metadataKeys: []),
        // The elder asked "what is this?".
        "chip_tapped": Entry(outcomes: ["success"], metadataKeys: []),
        // One local stage completed. `stage` is the stage token carried in
        // the event type itself (one type per stage), so it needs no key.
        "stage_ocr": Entry(outcomes: ["success", "failure"],
                           metadataKeys: ["count", "durationMs", "reason"]),
        "stage_translate": Entry(outcomes: ["success", "failure"],
                                 metadataKeys: ["count", "durationMs", "reason"]),
        "stage_classify": Entry(outcomes: ["success", "failure"],
                                metadataKeys: ["durationMs", "reason"]),
        // The VLM stage: skipped (a `PointAskCloudSkipReason` token) or
        // completed. `confidence` carries the model's own 0…1 score.
        "stage_vlm": Entry(outcomes: ["success", "failure", "skipped"],
                           metadataKeys: ["durationMs", "reason", "confidence"]),
        // One analysis settled. `origin` is the tier that answered
        // (local_ladder / vlm), `confidence` the VLM score when present.
        "analysis_answered": Entry(outcomes: ["success"],
                                   metadataKeys: ["origin", "confidence", "count"]),
        // The consent surfaces (C09's evidence set).
        "consent_prompt_shown": Entry(outcomes: ["success"],
                                      metadataKeys: ["disclosureVersion"]),
        "consent_recorded": Entry(outcomes: ["success"],
                                  metadataKeys: ["disclosureVersion"]),
        "consent_denied": Entry(outcomes: ["success"],
                                metadataKeys: ["disclosureVersion"]),
        "consent_revoked": Entry(outcomes: ["success"],
                                 metadataKeys: ["disclosureVersion"]),
        "consent_unreadable": Entry(outcomes: ["failure"], metadataKeys: []),
        "consent_write_failed": Entry(outcomes: ["failure"], metadataKeys: []),
    ]
}

/// The feature's typed emitters. One method per event, so an emitter that
/// produces a key the catalogue does not declare is a test failure and an
/// undeclared metadata spelling is a compile error (`MetadataKey`).
struct PointAskEvents {

    enum MetadataKey: String, CaseIterable {
        case origin
        case count
        case durationMs
        case reason
        case confidence
        case disclosureVersion
    }

    let bus: ObservabilityBus
    let config: PointAskConfig

    init(bus: ObservabilityBus, config: PointAskConfig = .default) {
        self.bus = bus
        self.config = config
    }

    // MARK: Emitters

    func tapAnchored(source: PointAskTargetSource) {
        emit("tap_anchored", outcome: "success",
             metadata: [.origin: source.rawValue])
    }

    func boxAgedOut() {
        emit("box_aged_out", outcome: "success")
    }

    func chipTapped() {
        emit("chip_tapped", outcome: "success")
    }

    func ocrCompleted(count: Int, durationMs: Int) {
        emit("stage_ocr", outcome: "success",
             metadata: [.count: String(count), .durationMs: String(durationMs)])
    }

    func ocrFailed(reason: PointAskStageFailureReason, durationMs: Int) {
        emit("stage_ocr", outcome: "failure",
             metadata: [.reason: reason.rawValue, .durationMs: String(durationMs)])
    }

    func translateCompleted(count: Int, durationMs: Int) {
        emit("stage_translate", outcome: "success",
             metadata: [.count: String(count), .durationMs: String(durationMs)])
    }

    func translateFailed(reason: PointAskStageFailureReason, durationMs: Int) {
        emit("stage_translate", outcome: "failure",
             metadata: [.reason: reason.rawValue, .durationMs: String(durationMs)])
    }

    func classifyCompleted(durationMs: Int) {
        emit("stage_classify", outcome: "success",
             metadata: [.durationMs: String(durationMs)])
    }

    func classifyFailed(reason: PointAskStageFailureReason, durationMs: Int) {
        emit("stage_classify", outcome: "failure",
             metadata: [.reason: reason.rawValue, .durationMs: String(durationMs)])
    }

    func vlmSkipped(reason: PointAskCloudSkipReason) {
        emit("stage_vlm", outcome: "skipped",
             metadata: [.reason: reason.rawValue])
    }

    func vlmCompleted(confidence: Double, durationMs: Int) {
        emit("stage_vlm", outcome: "success",
             metadata: [.confidence: String(confidence), .durationMs: String(durationMs)])
    }

    func vlmFailed(reason: PointAskStageFailureReason, durationMs: Int) {
        emit("stage_vlm", outcome: "failure",
             metadata: [.reason: reason.rawValue, .durationMs: String(durationMs)])
    }

    func analysisAnswered(origin: PointAskAnswerOrigin, confidence: Double?, count: Int) {
        var metadata: [MetadataKey: String] = [.origin: origin.rawValue, .count: String(count)]
        if let confidence { metadata[.confidence] = String(confidence) }
        emit("analysis_answered", outcome: "success", metadata: metadata)
    }

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
        emit("consent_unreadable", outcome: "failure")
    }

    func consentWriteFailed() {
        emit("consent_write_failed", outcome: "failure",
             errorCode: "pointask_consent_write_failed")
    }

    // MARK: Plumbing

    private func emit(_ eventType: String,
                      outcome: String,
                      errorCode: String? = nil,
                      metadata: [MetadataKey: String] = [:]) {
        bus.emit(ObservabilityEvent(
            component: PointAskEventCatalogue.component,
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: Dictionary(uniqueKeysWithValues:
                metadata.map { ($0.key.rawValue, $0.value) })))
    }
}

/// Where an answer came from — the closed `origin` token on
/// `analysis_answered`.
enum PointAskAnswerOrigin: String, Equatable, CaseIterable {
    /// The complete on-device answer: box, OCR, dictionary/cache and the
    /// classifier. No egress.
    case localLadder = "local_ladder"
    /// The Gemini VLM answer, on top of the local passes.
    case vlm
}
