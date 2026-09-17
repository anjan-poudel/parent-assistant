import XCTest
@testable import ElderlyAssistant

/// T-002 — every failure maps to a stable, content-free code and a reason,
/// and the error → unavailable-reason conversion table is stated once
/// (CL-4). No device, camera or network is involved: this file is pure.
final class LiveTranslateErrorTaxonomyTests: XCTestCase {

    private let sanitiser = LogSanitiser()

    // MARK: Fixtures — one value per case, plus the associated-value variants

    private let samples: [LiveTranslateError] = [
        .cameraPermissionNotDetermined,
        .cameraPermissionDenied,
        .cameraUnavailable(.noCaptureDevice),
        .cameraUnavailable(.configurationFailed),
        .cameraUnavailable(.resourceInUse),
        .cameraSessionInterrupted(.backgrounded),
        .cameraSessionInterrupted(.systemInterruption),
        .cameraSessionInterrupted(.thermal),
        .ocrUnavailable(.requestCreationFailed),
        .ocrUnavailable(.languageDetectionUnsupported),
        .ocrPassFailed(.requestFailed),
        .ocrPassFailed(.noObservations),
        .trackingUnsupported,
        .consentNotRecorded,
        .consentDenied,
        .consentRecordUnreadable,
        .costBudgetExhausted,
        .providerNotConfigured,
        .cloudTransient(.timedOut),
        .cloudTransient(.offline),
        .cloudTransient(.connectionLost),
        .cloudTransient(.other),
        .cloudRejected(status: 400),
        .cloudRejected(status: 408),
        .cloudRejected(status: 429),
        .cloudRejected(status: 500),
        .cloudRejected(status: 503),
        .cloudPolicyBlocked,
        .cloudResponseUnusable(.notJSON),
        .cloudResponseUnusable(.missingIDs),
        .cloudResponseUnusable(.nonStringValue),
        .cloudResponseUnusable(.oversizedValue),
        .cloudDeadlineExceeded,
        .textQuarantined(.markerResidual),
        .textQuarantined(.emptyAfterSanitise),
        .cacheReadFailed(.payloadUnreadable),
        .cacheReadFailed(.storageUnavailable),
        .cacheReadFailed(.writeRejected),
        .cacheWriteFailed(.payloadUnreadable),
        .cacheWriteFailed(.storageUnavailable),
        .cacheWriteFailed(.writeRejected),
        .speechFailed
    ]

    /// The documented table. **No `default:` branch**: adding a case to
    /// `LiveTranslateError` breaks this switch at compile time, which is the
    /// point — a new failure cannot silently acquire a code or a reason.
    private func expected(for error: LiveTranslateError)
        -> (code: String, reason: TranslationUnavailableReason) {
        switch error {
        case .cameraPermissionNotDetermined:
            return ("camera_permission_not_determined", .noTierResolved)
        case .cameraPermissionDenied:
            return ("camera_permission_denied", .noTierResolved)
        case .cameraUnavailable:
            return ("camera_unavailable", .noTierResolved)
        case .cameraSessionInterrupted:
            return ("camera_session_interrupted", .noTierResolved)
        case .ocrUnavailable:
            return ("ocr_unavailable", .noTierResolved)
        case .ocrPassFailed:
            return ("ocr_pass_failed", .noTierResolved)
        case .trackingUnsupported:
            return ("tracking_unsupported", .noTierResolved)
        case .consentNotRecorded:
            return ("consent_not_recorded", .consentNotGranted)
        case .consentDenied:
            return ("consent_denied", .consentNotGranted)
        case .consentRecordUnreadable:
            return ("consent_record_unreadable", .consentNotGranted)
        case .costBudgetExhausted:
            return ("cost_budget_exhausted", .costBudgetExhausted)
        case .providerNotConfigured:
            return ("provider_not_configured", .providerNotConfigured)
        case .cloudTransient(let failure):
            switch failure {
            case .timedOut: return ("cloud_transient", .deadlineExceeded)
            case .offline, .connectionLost: return ("cloud_transient", .noNetwork)
            case .other: return ("cloud_transient", .noTierResolved)
            }
        case .cloudRejected(let status):
            switch status {
            case 400: return ("cloud_rejected_400", .providerRejected)
            case 408: return ("cloud_rejected_408", .deadlineExceeded)
            case 429: return ("cloud_rejected_429", .providerRejected)
            case 500: return ("cloud_rejected_500", .providerRejected)
            case 503: return ("cloud_rejected_503", .providerRejected)
            default:
                XCTFail("fixture status \(status) has no pinned expectation")
                return ("", .noTierResolved)
            }
        case .cloudPolicyBlocked:
            return ("cloud_policy_blocked", .providerRejected)
        case .cloudResponseUnusable:
            return ("cloud_response_unusable", .providerRejected)
        case .cloudDeadlineExceeded:
            return ("cloud_deadline_exceeded", .deadlineExceeded)
        case .textQuarantined:
            return ("text_quarantined", .textQuarantined)
        case .cacheReadFailed:
            return ("cache_read_failed", .noTierResolved)
        case .cacheWriteFailed:
            return ("cache_write_failed", .noTierResolved)
        case .speechFailed:
            return ("speech_failed", .noTierResolved)
        }
    }

    // MARK: Scenario: every failure maps to a stable, content-free code and a reason

    func testEveryErrorCaseHasAStableCodeAndReason() {
        for error in samples {
            let want = expected(for: error)
            XCTAssertEqual(error.logSafeErrorCode, want.code, "code for \(error)")
            XCTAssertEqual(error.unavailableReason, want.reason, "reason for \(error)")

            // Stability across two reads: a code is a constant, not a
            // rendering that could vary (no counters, no addresses).
            XCTAssertEqual(error.logSafeErrorCode, error.logSafeErrorCode)
        }
    }

    /// A code is a constant token — never a description, an upstream body, a
    /// count or a status embedded in a description. The shipped `error_code`
    /// bound is the judge: every code must survive it verbatim.
    func testEveryCodeSurvivesTheShippedErrorCodeBoundVerbatim() {
        for error in samples {
            let code = error.logSafeErrorCode
            let event = ObservabilityEvent(component: "livetranslate",
                                           eventType: "test",
                                           durationMs: nil,
                                           outcome: "failure",
                                           errorCode: code,
                                           metadata: [:])
            XCTAssertEqual(sanitiser.sanitise(event).errorCode, code,
                           "code redacted by the log bound: \(code)")
            XCTAssertFalse(code.contains(" "), "a code is not a sentence: \(code)")
            XCTAssertFalse(code.contains("="), "a code is not a key/value pair: \(code)")
            XCTAssertFalse(code.contains("http"), "a code is not a URL: \(code)")
        }
    }

    /// The integration point, not the unit: every emitter in the app routes
    /// its error through the shipped `ErrorCodeMapper` chokepoint (T-050/B2).
    /// The feature's taxonomy must be recognised there — a type that only
    /// satisfies its own tests and falls through to the `NSError` path would
    /// put `error_-1` on the console instead of the code.
    func testEveryCodeSurvivesTheShippedErrorCodeMapperChokepoint() {
        for error in samples {
            XCTAssertEqual(ErrorCodeMapper.code(for: error), error.logSafeErrorCode,
                           "the shipped mapper did not take the LogSafeErrorCode path for \(error)")
        }
    }

    /// The two failures a compliance surface must never see collapsed:
    /// an unreadable record is a bug to fix, an exhausted budget is a cap
    /// doing its job.
    func testConsentRecordUnreadableAndCostBudgetExhaustedNeverCollapse() {
        XCTAssertNotEqual(LiveTranslateError.consentRecordUnreadable.logSafeErrorCode,
                          LiveTranslateError.costBudgetExhausted.logSafeErrorCode)
        XCTAssertNotEqual(LiveTranslateError.consentRecordUnreadable.unavailableReason,
                          LiveTranslateError.costBudgetExhausted.unavailableReason)

        // Neither collapses into the generic denial either.
        XCTAssertNotEqual(LiveTranslateError.consentRecordUnreadable.logSafeErrorCode,
                          LiveTranslateError.consentDenied.logSafeErrorCode)
        XCTAssertNotEqual(LiveTranslateError.consentRecordUnreadable.logSafeErrorCode,
                          LiveTranslateError.consentNotRecorded.logSafeErrorCode)
        XCTAssertNotEqual(LiveTranslateError.costBudgetExhausted.unavailableReason,
                          TranslationUnavailableReason.providerRejected)
    }

    /// The status travels as an integer suffix on a constant token — it is
    /// never folded into a description.
    func testTheStatusCodeIntCarriesNoUpstreamText() {
        let code = LiveTranslateError.cloudRejected(status: 503).logSafeErrorCode
        XCTAssertEqual(code, "cloud_rejected_503")
        XCTAssertEqual(code.split(separator: "_").last, "503")
    }

    // MARK: Scenario: unsupported tracking degrades to OCR-only

    /// The condition is representable, has a stable code, and is not a
    /// specific elder-facing cause: tracking is a SHOULD (FR-LCT-004), so it
    /// degrades the feature's quality rather than failing it. Whether it is
    /// rendered at all is the overlay's decision (T-021) — what T-002 owes is
    /// the honest, non-alarming representation and the event.
    func testUnsupportedTrackingIsRepresentableAndNotASpecificCause() {
        let error = LiveTranslateError.trackingUnsupported
        XCTAssertEqual(error.logSafeErrorCode, "tracking_unsupported")
        XCTAssertEqual(error.unavailableReason, .noTierResolved)
        XCTAssertNotEqual(error.unavailableReason, .noNetwork)
        XCTAssertNotEqual(error.unavailableReason, .providerNotConfigured)
    }

    // MARK: CL-4 — conversion from the shipped client

    func testTheGeminiClientErrorConversionTableIsTotal() {
        let table: [(GeminiClient.GeminiClientError, LiveTranslateError)] = [
            (.notConfigured, .providerNotConfigured),
            (.dailyCapReached, .costBudgetExhausted),
            (.httpError(status: 503), .cloudRejected(status: 503)),
            (.blockedByProvider(reason: "policy"), .cloudPolicyBlocked),
            (.emptyResponse, .cloudResponseUnusable(.notJSON)),
            (.invalidResponse, .cloudResponseUnusable(.notJSON)),
            (.invalidURL, .providerNotConfigured)
        ]
        for (shipped, ours) in table {
            XCTAssertEqual(LiveTranslateError.fromGemini(shipped), ours,
                           "conversion of \(shipped)")
        }

        // The reasons the tier will show, stated once:
        XCTAssertEqual(LiveTranslateError.fromGemini(.notConfigured).unavailableReason,
                       .providerNotConfigured)
        XCTAssertEqual(LiveTranslateError.fromGemini(.dailyCapReached).unavailableReason,
                       .costBudgetExhausted)
        XCTAssertEqual(LiveTranslateError.fromGemini(.httpError(status: 408)).unavailableReason,
                       .deadlineExceeded)
        XCTAssertEqual(LiveTranslateError.fromGemini(.httpError(status: 429)).unavailableReason,
                       .providerRejected)
        XCTAssertEqual(LiveTranslateError.fromGemini(.httpError(status: 500)).unavailableReason,
                       .providerRejected)
        XCTAssertEqual(LiveTranslateError.fromGemini(.blockedByProvider(reason: "x")).unavailableReason,
                       .providerRejected)
        XCTAssertEqual(LiveTranslateError.fromGemini(.emptyResponse).unavailableReason,
                       .providerRejected)
    }

    /// The shipped client rethrows transport `URLError` values raw, so the
    /// transport shape is mapped here too — including the honest "could not
    /// classify this" case rather than a guessed cause.
    func testTransportErrorsConvertByTheirURLCode() {
        let table: [(URLError.Code, TransportFailure)] = [
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .connectionLost),
            (.cannotFindHost, .other),
            (.badServerResponse, .other)
        ]
        for (code, expectedFailure) in table {
            let mapped = LiveTranslateError.fromTransport(URLError(code))
            XCTAssertEqual(mapped, .cloudTransient(expectedFailure), "\(code)")
        }

        XCTAssertEqual(LiveTranslateError.fromTransport(URLError(.timedOut)).unavailableReason,
                       .deadlineExceeded)
        XCTAssertEqual(LiveTranslateError.fromTransport(URLError(.notConnectedToInternet)).unavailableReason,
                       .noNetwork)
        XCTAssertEqual(LiveTranslateError.fromTransport(URLError(.networkConnectionLost)).unavailableReason,
                       .noNetwork)
        XCTAssertEqual(LiveTranslateError.fromTransport(URLError(.cannotFindHost)).unavailableReason,
                       .noTierResolved)

        struct UnknownTransportError: Error {}
        XCTAssertEqual(LiveTranslateError.fromTransport(UnknownTransportError()),
                       .cloudTransient(.other),
                       "an unclassifiable transport error is reported as unclassified")
    }

    /// The `other` classification must never be presented as a network
    /// claim: the reason set is closed and the honest member is
    /// `no_tier_resolved`.
    func testAnUnclassifiableFailureNeverClaimsANetworkCause() {
        XCTAssertEqual(LiveTranslateError.cloudTransient(.other).unavailableReason, .noTierResolved)
        XCTAssertNotEqual(LiveTranslateError.cloudTransient(.other).unavailableReason, .noNetwork)
    }
}
