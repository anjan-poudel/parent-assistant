import Foundation

// C04 — `TranslationResult`, `TranslationTier`, `TranslationOutcome` — and
// the feature's error taxonomy (T-002).
//
// Truthful tier attribution and honest degradation are **structural** here,
// not procedural (FR-LCT-008, NFR-LCT-010):
//
//  - `TranslationOutcome` is the single source of truth. The documented
//    accessors (`text`, `sourceTier`, `degraded`, `isFinal`) are computed
//    from it, so the inconsistent states the first-pass flat struct allowed
//    — a degraded result naming a tier that did not translate — cannot be
//    constructed at all.
//  - `TranslationTier` has exactly three cases, and no ordinal tier number
//    is reserved: ordinals live in prose and in observability metadata only.
//
//    The third case — the on-device brain — is the owner's 2026-09-17
//    directive, which revisits the §13.5 non-goal that had kept the
//    on-device tier absent (FR-LCT-008, amended the same day): the elder's
//    complaint was that any string the curated dictionary missed degraded to
//    "can't translate" whenever the cloud was declined or unreachable. The
//    tier that closes that gap is the app's OWN installed Nepali brain, so
//    the result must name it rather than borrowing `.cloud` (a claim that
//    something left the device, which would poison the security evidence) or
//    `.dictionary` (a claim of curation, which would also let an unvetted
//    model translation replace a sign's text in place — FR-LCT-015's
//    tier-0-only rule). It is tier 1 *in spirit*: on-device, no consent, no
//    network, no budget. The case is spelled `onDeviceBrain`, never an
//    ordinal.
//  - The error taxonomy keeps every failure's log-safe code a constant
//    token (never a description, an upstream body, a count or a status
//    embedded in a description) and maps every case onto the closed
//    `TranslationUnavailableReason` set (CL-4), so the tier consumes one
//    table instead of re-deriving it.
//
// This file is pure: no I/O, no device, no network, so every case is
// unit-testable directly.

// MARK: - Tier

/// Which translation source produced a string.
///
/// Three cases, one per tier that can actually produce a translation: the
/// curated on-device dictionary (tier 0), the on-device brain (tier 1 — the
/// app's installed Nepali LLM, local and consent-free), and the consent-gated
/// cloud tier (tier 2). Every case is a statement about what happened, and
/// none of them is a placeholder: a case that no code path can produce would
/// be the "stubbed deferred capability" FR-LCT-008's amendment still forbids.
enum TranslationTier: String, Equatable, Codable, CaseIterable {
    case dictionary     // tier 0 — `ApplianceLabelLocalizer` curated entries
    /// Tier 1 — the on-device brain (`LocalBrainTranslationTier`). Never
    /// consent-gated and never sent anywhere: nothing about it is cloud, and
    /// nothing about it is curated. Renderers treat it exactly like `.cloud`
    /// (callout, original preserved); only `.dictionary` may replace in place
    /// (FR-LCT-015), which is why the curated table's provenance may not be
    /// borrowed by a model's output.
    case onDeviceBrain
    case cloud          // tier 2 — consent-gated, text-only
}

// MARK: - Unavailable reason

/// Why a region has no translation. The reason never carries upstream text,
/// an image or a scene identifier: it is a closed vocabulary, and its
/// `rawValue` is the token that travels in the `reason` event metadata.
enum TranslationUnavailableReason: String, Equatable, CaseIterable {
    /// The provider could not be reached (offline, connection lost).
    case noNetwork = "no_network"
    /// No provider key is configured on this device.
    case providerNotConfigured = "provider_not_configured"
    /// Consent for the cloud tier is not recorded, was denied, or its record
    /// is unreadable. Distinct from `costBudgetExhausted` by contract.
    case consentNotGranted = "consent_not_granted"
    /// The day's cost budget is spent — the cap doing its job, not a fault.
    case costBudgetExhausted = "cost_budget_exhausted"
    /// The provider refused or returned something unusable.
    case providerRejected = "provider_rejected"
    /// The recognized text carried a marker shape after sanitisation, so it
    /// was never sent and is never spoken.
    case textQuarantined = "text_quarantined"
    /// The tier-2 deadline was exceeded.
    case deadlineExceeded = "deadline_exceeded"
    /// No tier resolved the string and no more specific cause applies. This
    /// is the honest statement for failures that do not themselves terminate
    /// a region (tracking off, cache miss after a self-heal, speech failure).
    case noTierResolved = "no_tier_resolved"
}

// MARK: - Outcome

/// The single source of truth for a region's translation state.
enum TranslationOutcome: Equatable {
    /// Unresolved, with a tier in flight (or about to be). Claims nothing.
    case pending(originalText: String)
    /// A tier produced this translation, and is named for what it is.
    case resolved(originalText: String, translation: String, tier: TranslationTier)
    /// No tier produced a translation. The elder sees the original text plus
    /// an honest unavailable indication — never a blank bubble.
    case degraded(originalText: String, reason: TranslationUnavailableReason)
}

/// What the overlay renders for one region.
///
/// `sourceTier` is non-nil **only** for a resolved outcome, so "a tier that
/// did not translate" is not nameable; `text` is the original recognized
/// text unless a tier actually translated it, so the honest fallback is the
/// default rather than something a caller must remember to apply.
struct TranslationResult: Equatable {
    let outcome: TranslationOutcome

    init(_ outcome: TranslationOutcome) {
        self.outcome = outcome
    }

    // MARK: Documented accessors (computed — never stored alongside the enum)

    /// The translation when resolved; the original recognized text
    /// otherwise.
    var text: String {
        switch outcome {
        case .pending(let originalText):
            return originalText
        case .resolved(_, let translation, _):
            return translation
        case .degraded(let originalText, _):
            return originalText
        }
    }

    /// Non-nil only when a tier actually produced this string.
    var sourceTier: TranslationTier? {
        guard case .resolved(_, _, let tier) = outcome else { return nil }
        return tier
    }

    /// False only while the outcome is pending.
    var isFinal: Bool {
        if case .pending = outcome { return false }
        return true
    }

    /// True only for an honest degradation.
    var degraded: Bool {
        if case .degraded = outcome { return true }
        return false
    }

    /// The recognized text this result is about, in every state.
    var originalText: String {
        switch outcome {
        case .pending(let originalText): return originalText
        case .resolved(let originalText, _, _): return originalText
        case .degraded(let originalText, _): return originalText
        }
    }

    // MARK: Construction conveniences

    static func pending(_ originalText: String) -> TranslationResult {
        TranslationResult(.pending(originalText: originalText))
    }

    static func resolved(originalText: String,
                         translation: String,
                         tier: TranslationTier) -> TranslationResult {
        TranslationResult(.resolved(originalText: originalText,
                                    translation: translation,
                                    tier: tier))
    }

    static func degraded(originalText: String,
                         reason: TranslationUnavailableReason) -> TranslationResult {
        TranslationResult(.degraded(originalText: originalText, reason: reason))
    }

    // MARK: Monotone transitions (FR-LCT-018)

    /// Applies the next observed outcome for the **same region**, enforcing
    /// the design's monotonicity rule:
    ///
    ///  - a text change replaces the outcome wholesale (never merged) — the
    ///    new text's outcome is a new claim about a new string,
    ///  - for unchanged text, a `pending` outcome never overwrites a
    ///    terminal one: a region resolved once never flickers back to
    ///    pending,
    ///  - otherwise the newer outcome wins (a later tier result replaces an
    ///    earlier one for the same string).
    ///
    /// Pure and total: the pipeline publishes through this so the rule
    /// cannot be forgotten at a call site.
    func applying(_ next: TranslationOutcome) -> TranslationResult {
        if next.originalText != originalText { return TranslationResult(next) }
        if case .pending = next, isFinal { return self }
        return TranslationResult(next)
    }
}

extension TranslationOutcome {
    /// The recognized text this outcome is about, in every state. Used by
    /// the monotonicity rule above and by callers that only hold an outcome.
    var originalText: String {
        switch self {
        case .pending(let originalText): return originalText
        case .resolved(let originalText, _, _): return originalText
        case .degraded(let originalText, _): return originalText
        }
    }
}

// MARK: - Error taxonomy

/// Why the camera could not be used. The case refines event metadata only —
/// the log-safe code is the family token.
enum CameraUnavailableReason: Equatable {
    case noCaptureDevice
    case configurationFailed
    case resourceInUse
}

/// Why a running camera session was interrupted.
enum CameraInterruption: Equatable {
    case backgrounded
    case systemInterruption
    case thermal
}

/// Why OCR could not be set up at all (a pass that fails is `OCRFailure`).
enum OCRUnavailableReason: Equatable {
    case requestCreationFailed
    case languageDetectionUnsupported
}

/// Why a single OCR pass failed.
///
/// `noObservations` is **not** a failure in the pipeline's terms (failure
/// table row 4): it is the empty-state hint, and that distinction is the
/// caller's — the case exists so the distinction is nameable rather than
/// collapsed.
enum OCRFailure: Equatable {
    case requestFailed
    case noObservations
}

/// Transport-level classification for a cloud attempt.
enum TransportFailure: Equatable {
    case timedOut
    case offline
    case connectionLost
    /// Classified by neither side; carried honestly rather than guessed.
    case other
}

/// How a provider response failed to be usable.
enum ResponseDefect: Equatable {
    case notJSON
    case missingIDs
    case nonStringValue
    case oversizedValue
}

/// Why recognized text was quarantined rather than sent.
enum QuarantineReason: Equatable {
    case markerResidual
    case emptyAfterSanitise
}

/// Why a cache operation failed. Both are self-healing (rows 6/7): a read
/// failure is a miss, a write failure is retried by the next resolution.
enum CacheFailure: Equatable {
    case payloadUnreadable
    case storageUnavailable
    case writeRejected
}

/// One feature-scoped error type. Every case carries a **stable, content-free
/// code** for `error_code` (the shipped `ErrorCodeMapper` precedent); counts
/// and statuses travel in observability metadata, never in the code string.
///
/// Retryability is deliberately **not** decided here. The design's "Failure
/// modes and retryability per asynchronous operation" table (rows 1–24) is
/// the owner of that policy; this type supplies the codes and the reason
/// mapping the tier reads.
enum LiveTranslateError: Error, Equatable {
    // Camera
    case cameraPermissionNotDetermined
    case cameraPermissionDenied
    case cameraUnavailable(CameraUnavailableReason)
    case cameraSessionInterrupted(CameraInterruption)

    // Detection
    case ocrUnavailable(OCRUnavailableReason)
    case ocrPassFailed(OCRFailure)
    /// The device refused the tracking request. Tracking is a SHOULD
    /// (FR-LCT-004): this is reported as an honest event and degrades the
    /// feature to OCR-only. It is never an error shown to the elder.
    case trackingUnsupported

    // Consent
    case consentNotRecorded
    case consentDenied
    /// The record exists but could not be read: fail closed. Never collapsed
    /// into a generic denial — it is a different failure with a different
    /// owner action (a corrupt record is a bug to fix).
    case consentRecordUnreadable

    // Cost
    /// The day's budget is spent. Fail closed and session-latched, and never
    /// collapsed into a generic denial — an exhausted budget is a cap doing
    /// its job.
    case costBudgetExhausted

    // Cloud translation
    case providerNotConfigured
    case cloudTransient(TransportFailure)
    case cloudRejected(status: Int)
    case cloudPolicyBlocked
    case cloudResponseUnusable(ResponseDefect)
    case cloudDeadlineExceeded

    // Sanitisation
    case textQuarantined(QuarantineReason)

    // Cache
    case cacheReadFailed(CacheFailure)
    case cacheWriteFailed(CacheFailure)

    // Speech
    case speechFailed
}

// MARK: - Log-safe codes

extension LiveTranslateError: LogSafeErrorCode {
    /// One stable token per case family. Associated values refine event
    /// metadata; they never widen a code except for the HTTP status, which
    /// is an integer suffix on a constant token, not a description (T-002,
    /// the design's `cloud_rejected_<status>` form).
    var logSafeErrorCode: String {
        switch self {
        case .cameraPermissionNotDetermined:
            return "camera_permission_not_determined"
        case .cameraPermissionDenied:
            return "camera_permission_denied"
        case .cameraUnavailable:
            return "camera_unavailable"
        case .cameraSessionInterrupted:
            return "camera_session_interrupted"
        case .ocrUnavailable:
            return "ocr_unavailable"
        case .ocrPassFailed:
            return "ocr_pass_failed"
        case .trackingUnsupported:
            return "tracking_unsupported"
        case .consentNotRecorded:
            return "consent_not_recorded"
        case .consentDenied:
            return "consent_denied"
        case .consentRecordUnreadable:
            return "consent_record_unreadable"
        case .costBudgetExhausted:
            return "cost_budget_exhausted"
        case .providerNotConfigured:
            return "provider_not_configured"
        case .cloudTransient:
            return "cloud_transient"
        case .cloudRejected(let status):
            return "cloud_rejected_\(status)"
        case .cloudPolicyBlocked:
            return "cloud_policy_blocked"
        case .cloudResponseUnusable:
            return "cloud_response_unusable"
        case .cloudDeadlineExceeded:
            return "cloud_deadline_exceeded"
        case .textQuarantined:
            return "text_quarantined"
        case .cacheReadFailed:
            return "cache_read_failed"
        case .cacheWriteFailed:
            return "cache_write_failed"
        case .speechFailed:
            return "speech_failed"
        }
    }
}

// MARK: - Error → unavailable reason (CL-4)

extension LiveTranslateError {
    /// The reason a degraded region shows when this failure is why it has no
    /// translation.
    ///
    /// Failures that do not themselves terminate a region — a camera or OCR
    /// problem (the feature keeps running), tracking off (OCR-only), a cache
    /// read/write fault (self-healing; the translation still renders), a
    /// speech fault (the visual translation stays) — map to
    /// `.noTierResolved`, which is the honest statement when such a failure
    /// is consulted for a reason: no tier resolved the string, and there is
    /// no more specific cause to name.
    ///
    /// The mapping is total and exhaustive: there is no default branch, so a
    /// new case cannot silently acquire a reason.
    var unavailableReason: TranslationUnavailableReason {
        switch self {
        case .cameraPermissionNotDetermined,
             .cameraPermissionDenied,
             .cameraUnavailable,
             .cameraSessionInterrupted,
             .ocrUnavailable,
             .ocrPassFailed,
             .trackingUnsupported,
             .cacheReadFailed,
             .cacheWriteFailed,
             .speechFailed:
            return .noTierResolved

        case .consentNotRecorded,
             .consentDenied,
             .consentRecordUnreadable:
            return .consentNotGranted

        case .costBudgetExhausted:
            return .costBudgetExhausted

        case .providerNotConfigured:
            return .providerNotConfigured

        case .cloudTransient(let failure):
            switch failure {
            case .timedOut:
                return .deadlineExceeded
            case .offline, .connectionLost:
                return .noNetwork
            case .other:
                return .noTierResolved
            }

        case .cloudRejected(let status):
            // 408 is the provider saying "too slow", not "refused"; every
            // other status (429, 5xx, other 4xx) is a rejection.
            return status == 408 ? .deadlineExceeded : .providerRejected

        case .cloudPolicyBlocked, .cloudResponseUnusable:
            return .providerRejected

        case .cloudDeadlineExceeded:
            return .deadlineExceeded

        case .textQuarantined:
            return .textQuarantined
        }
    }
}

// MARK: - Conversion from the shipped client (CL-4)

extension LiveTranslateError {

    /// The transport-error conversion table, stated once so the tier does
    /// not re-derive it (CL-4). The shipped client rethrows `URLError`
    /// values from its transport rather than wrapping them, so both shapes
    /// are mapped here.
    ///
    /// | Shipped case | Feature error | Reason | Retry (table rows 1–24) |
    /// |---|---|---|---|
    /// | `.notConfigured` | `.providerNotConfigured` | `.providerNotConfigured` | no (row 10) |
    /// | `.dailyCapReached` | `.costBudgetExhausted` | `.costBudgetExhausted` | no (row 12) |
    /// | `.httpError(status:)` | `.cloudRejected(status:)` | `.providerRejected`, or `.deadlineExceeded` for 408 | per status: 408/429/5xx once (rows 14/15) |
    /// | `.blockedByProvider` | `.cloudPolicyBlocked` | `.providerRejected` | no (row 16) |
    /// | `.emptyResponse` | `.cloudResponseUnusable(.notJSON)` | `.providerRejected` | once (row 17) |
    /// | `.invalidResponse` | `.cloudResponseUnusable(.notJSON)` | `.providerRejected` | once (row 17) |
    /// | `.invalidURL` | `.providerNotConfigured` | `.providerNotConfigured` | no — a request that cannot be built will not build on retry |
    /// | `URLError(.timedOut)` | `.cloudTransient(.timedOut)` | `.deadlineExceeded` | once (row 13) |
    /// | `URLError(.notConnectedToInternet)` | `.cloudTransient(.offline)` | `.noNetwork` | once (row 13) |
    /// | `URLError(.networkConnectionLost)` | `.cloudTransient(.connectionLost)` | `.noNetwork` | once (row 13) |
    /// | any other error | `.cloudTransient(.other)` | `.noTierResolved` | once (row 13) |
    ///
    /// The retry column is informative only: the tier owns the policy (T-019).
    static func fromGemini(_ error: GeminiClient.GeminiClientError) -> LiveTranslateError {
        switch error {
        case .notConfigured:
            return .providerNotConfigured
        case .dailyCapReached:
            return .costBudgetExhausted
        case .httpError(let status):
            return .cloudRejected(status: status)
        case .blockedByProvider:
            return .cloudPolicyBlocked
        case .emptyResponse:
            // An empty body is not a usable JSON envelope: the same defect
            // class as a body that does not decode.
            return .cloudResponseUnusable(.notJSON)
        case .invalidResponse:
            return .cloudResponseUnusable(.notJSON)
        case .invalidURL:
            // The client could not construct a request at all: a
            // configuration defect, not a transient one.
            return .providerNotConfigured
        }
    }

    /// Transport errors in the shape the shipped client rethrows them.
    /// Anything unrecognised is `.other`, which the closed vocabulary has a
    /// case for — an honest "we could not classify this" rather than a
    /// guessed cause.
    static func fromTransport(_ error: Error) -> LiveTranslateError {
        guard let urlError = error as? URLError else {
            return .cloudTransient(.other)
        }
        switch urlError.code {
        case .timedOut:
            return .cloudTransient(.timedOut)
        case .notConnectedToInternet:
            return .cloudTransient(.offline)
        case .networkConnectionLost:
            return .cloudTransient(.connectionLost)
        default:
            return .cloudTransient(.other)
        }
    }
}
