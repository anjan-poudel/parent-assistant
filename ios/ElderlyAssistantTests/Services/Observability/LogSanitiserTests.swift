import XCTest
@testable import ElderlyAssistant

/// Direct tests for the log sanitiser's contract — including the T-050
/// `error_code` bound (finding B2: `error_code` was the one top-level field
/// copied through with no scrub, which is how a key-bearing `URLError`
/// description reached the console through the only allow-listed content
/// field).
///
/// NFR-016: the sentinel below is deliberately not key-shaped — no
/// realistic-looking secrets in tests or fixtures.
final class LogSanitiserTests: XCTestCase {

    private let sanitiser = LogSanitiser()
    private let sentinelKey = "sentinel-not-a-real-key-000"

    private func event(errorCode: String? = nil,
                       metadata: [String: String] = [:]) -> ObservabilityEvent {
        ObservabilityEvent(component: "test_component",
                           eventType: "test_event",
                           durationMs: nil,
                           outcome: "failure",
                           errorCode: errorCode,
                           metadata: metadata)
    }

    // MARK: - Existing contract (must not change)

    func testAllowListedMetadataKeysSurviveAndUnknownKeysAreDropped() {
        let clean = sanitiser.sanitise(event(metadata: [
            "duration_ms": "42",
            "outcome": "failure",
            "future_feature_key": "must be dropped"
        ]))
        XCTAssertEqual(clean.metadata["duration_ms"], "42")
        XCTAssertEqual(clean.metadata["outcome"], "failure")
        XCTAssertNil(clean.metadata["future_feature_key"],
                     "unknown metadata keys are still dropped outright")
    }

    func testChunksCountSurvivesTheSanitiser() {
        // [DEAD-TAP-RECOVERY] The capture chunk count is the console's
        // discriminator between a silent capture and a dead tap.
        let clean = sanitiser.sanitise(event(metadata: ["chunks": "0"]))
        XCTAssertEqual(clean.metadata["chunks"], "0")
    }

    func testDecodeDetailSurvivesTheSanitiser() {
        // [DECODE-DIAGNOSTIC] The Google schema field a decode failed on
        // must reach the console — it is the entire diagnostic value.
        let clean = sanitiser.sanitise(event(metadata: [
            "decode_detail": "type_mismatch:items",
        ]))
        XCTAssertEqual(clean.metadata["decode_detail"], "type_mismatch:items")
    }

    func testScopeLedgerNamesSurviveTheSanitiser() {
        // [SCOPE-LEDGER] The console must be able to say which Google
        // scope is granted or missing — fixed vocabulary names, no PII.
        let clean = sanitiser.sanitise(event(metadata: [
            "calendar": "granted",
            "contacts": "missing",
        ]))
        XCTAssertEqual(clean.metadata["calendar"], "granted")
        XCTAssertEqual(clean.metadata["contacts"], "missing")
    }

    func testStagesMetadataIsPreservedVerbatim() {
        let stages = #"[{"stage":"asr","ms":812},{"stage":"llm","ms":1430}]"#
        let clean = sanitiser.sanitise(event(metadata: ["stages": stages]))
        XCTAssertEqual(clean.metadata["stages"], stages,
                       "the [TURN-TIMING] stages allowance must not regress")
    }

    func testMetadataValuesAreStillScrubbedForObviousPII() {
        let clean = sanitiser.sanitise(event(metadata: ["outcome": "call +9779812345678 now"]))
        let value = clean.metadata["outcome"] ?? ""
        XCTAssertFalse(value.contains("9812345678"), "phone-shaped metadata is scrubbed")
    }

    /// [MULTIPART-DOWNLOAD] The part-diagnostic keys are numeric-only and
    /// must survive the bus: without them the on-device log for a failed
    /// part reads exactly like the 2026-09-14 report — an event with no
    /// part, no status, and no way to tell a 404 from a corrupt file.
    func testDownloadPartDiagnosticKeysSurviveTheBus() {
        let clean = sanitiser.sanitise(event(metadata: [
            "part": "0",
            "parts": "2",
            "bytes": "0",
            "http_status": "404"
        ]))
        XCTAssertEqual(clean.metadata["part"], "0")
        XCTAssertEqual(clean.metadata["parts"], "2")
        XCTAssertEqual(clean.metadata["bytes"], "0")
        XCTAssertEqual(clean.metadata["http_status"], "404")
        // The allow-list is still an allow-list.
        XCTAssertNil(sanitiser.sanitise(event(metadata: ["part_url": "https://x/y"])).metadata["part_url"])
    }

    func testTopLevelNonContentFieldsPassThroughUnchanged() {
        let original = ObservabilityEvent(component: "c", eventType: "e", durationMs: 7,
                                          outcome: "failure", errorCode: nil, metadata: [:])
        let clean = sanitiser.sanitise(original)
        XCTAssertEqual(clean.component, "c")
        XCTAssertEqual(clean.eventType, "e")
        XCTAssertEqual(clean.durationMs, 7)
        XCTAssertEqual(clean.outcome, "failure")
    }

    // MARK: - error_code bound (T-050)

    func testContentFreeErrorCodesPassThroughUnchanged() {
        for code in ["http_429", "url_error_-1004", "not_configured",
                     "recognition_failed", "timed_out", "jsonRemnant",
                     "dup_source", "a,b", "429"] {
            XCTAssertEqual(sanitiser.sanitise(event(errorCode: code)).errorCode, code,
                           "a content-free code must survive verbatim: \(code)")
        }
    }

    func testNilAndEmptyErrorCodeStayNil() {
        XCTAssertNil(sanitiser.sanitise(event(errorCode: nil)).errorCode)
        XCTAssertNil(sanitiser.sanitise(event(errorCode: "")).errorCode)
    }

    /// The exact leak shape of record: `String(describing: URLError)` with
    /// a key-bearing failing URL in its userInfo.
    func testKeyBearingURLErrorDescriptionIsRedacted() {
        let keyURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=\(sentinelKey)")!
        let description = String(describing: URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: keyURL,
            NSURLErrorFailingURLStringErrorKey: keyURL.absoluteString
        ]))
        // Sanity guard against a vacuous test: the raw shape really does
        // carry the key (it is what the emitters used to pass).
        XCTAssertTrue(description.contains(sentinelKey))

        let clean = sanitiser.sanitise(event(errorCode: description))
        XCTAssertEqual(clean.errorCode, "[redacted]",
                       "a description is not a code — it is replaced, not trimmed")
        XCTAssertFalse((clean.errorCode ?? "").contains(sentinelKey))
    }

    func testBareURLIsRedacted() {
        let clean = sanitiser.sanitise(event(errorCode: "https://example.invalid/path?key=\(sentinelKey)"))
        XCTAssertFalse((clean.errorCode ?? "").contains(sentinelKey))
        XCTAssertFalse((clean.errorCode ?? "").contains("https"))
    }

    func testQuotedDescriptionsAreRedacted() {
        for value in [#"Error Domain=NSURLErrorDomain Code=-1004 "Could not connect""#,
                      "{error: upstream body text}",
                      "boom secret=\(sentinelKey)"] {
            XCTAssertEqual(sanitiser.sanitise(event(errorCode: value)).errorCode, "[redacted]",
                           "non-code shape must be replaced: \(value)")
        }
    }

    func testOverlongButCodeShapedValueIsTruncated() {
        // Separator-joined words: legal code shape (longest run 4), so the
        // bound is the length cap, not the run rule.
        let long = String(repeating: "word_", count: 40)
        let clean = sanitiser.sanitise(event(errorCode: long))
        XCTAssertEqual(clean.errorCode?.count, LogSanitiser.maxErrorCodeLength)
        XCTAssertEqual(clean.errorCode, String(long.prefix(LogSanitiser.maxErrorCodeLength)))
    }

    /// A pasted API key is charset-valid, so the charset rule alone would
    /// pass it; the unbroken-run rule is what stops it. Shape only — the
    /// value below is a run of one letter, deliberately not key-shaped
    /// (NFR-016).
    func testKeyShapedUnbrokenAlphanumericRunIsRedacted() {
        let keyShaped = String(repeating: "A", count: 40)
        XCTAssertGreaterThan(keyShaped.count, LogSanitiser.maxUnbrokenRunLength)
        XCTAssertEqual(sanitiser.sanitise(event(errorCode: keyShaped)).errorCode,
                       "[redacted]",
                       "an unbroken 32+-character alphanumeric token is a key shape, not a code")
    }

    func testRunLengthBoundaryIsInclusiveOfShorterRuns() {
        // One character below the limit: still treated as a code shape and
        // preserved verbatim (the boundary is documented, not accidental).
        let shortRun = String(repeating: "b", count: LogSanitiser.maxUnbrokenRunLength - 1)
        XCTAssertEqual(sanitiser.sanitise(event(errorCode: shortRun)).errorCode, shortRun)
        // At the limit the run rule fires.
        let atLimit = String(repeating: "b", count: LogSanitiser.maxUnbrokenRunLength)
        XCTAssertEqual(sanitiser.sanitise(event(errorCode: atLimit)).errorCode, "[redacted]")
    }

    // MARK: - Memory-ledger counts (finding B2: the phone pattern ate the bytes)

    func testByteBudgetsSurviveTheSanitiser() {
        // The 9-digit phone pattern matches a byte budget exactly, so the
        // ledger's own numbers used to arrive as "[redacted]" — the review's
        // evidence for the memory-pressure story, unreadable. These are the
        // real magnitudes the ledger reports.
        let clean = sanitiser.sanitise(event(metadata: [
            "budgetBytes": "268435456",
            "liveBytes": "1200000000",
            "transientLiveBytes": "33554432",
            "phys_footprint": "734003200",
        ]))
        XCTAssertEqual(clean.metadata["budgetBytes"], "268435456")
        XCTAssertEqual(clean.metadata["liveBytes"], "1200000000")
        XCTAssertEqual(clean.metadata["transientLiveBytes"], "33554432")
        XCTAssertEqual(clean.metadata["phys_footprint"], "734003200")
    }

    func testDecimalAndLongDurationsSurviveTheSanitiser() {
        // Both are long enough that the phone pattern matches them, so both
        // are discriminating cases rather than values the scrub would have
        // passed through anyway: a fractional duration and a long one.
        let clean = sanitiser.sanitise(event(metadata: [
            "heldSeconds": "1234567.5",
            "load_ms": "86400000",
        ]))
        XCTAssertEqual(clean.metadata["heldSeconds"], "1234567.5",
                       "one decimal point is a count, so the scrub must not run")
        XCTAssertEqual(clean.metadata["load_ms"], "86400000")
    }

    /// The exemption is **value-shaped, not key-shaped**: naming a key as
    /// numeric is a promise about its content, and a value that breaks the
    /// promise keeps the full scrub. A phone number written into a byte key
    /// must not become a redaction bypass.
    func testANumericKeysNonNumericValueIsStillScrubbed() {
        let clean = sanitiser.sanitise(event(metadata: [
            "budgetBytes": "555 123 4567",
            "liveBytes": "268-435-4567",
        ]))
        XCTAssertEqual(clean.metadata["budgetBytes"], "[redacted]",
                       "a listed key carrying a phone shape is scrubbed in full")
        XCTAssertEqual(clean.metadata["liveBytes"], "[redacted]",
                       "separators are not a count shape, so the scrub decides")
    }

    /// Boundary pairs on a numeric key: the count shape is digits with at
    /// most one decimal point, so one decimal is a count and two is not —
    /// and the second one takes the scrub path, where a separator-joined
    /// digit run is exactly the phone shape. A leading `+` reads the same
    /// way: signed-number intent, phone-number shape.
    func testCountShapeBoundarySplitsDecimalsAndSigns() {
        let clean = sanitiser.sanitise(event(metadata: [
            "heldSeconds": "12.5",
            "ceiling_bytes": "1234567.8.9",
            "load_ms": "+2684354561",
        ]))
        XCTAssertEqual(clean.metadata["heldSeconds"], "12.5",
                       "one decimal point is still a count")
        XCTAssertEqual(clean.metadata["ceiling_bytes"], "[redacted]",
                       "a second point is not a number, so the scrub decides")
        XCTAssertEqual(clean.metadata["load_ms"], "[redacted]",
                       "a leading + is the phone shape, not a signed count")
    }
}
