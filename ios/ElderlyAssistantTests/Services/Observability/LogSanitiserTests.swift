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

    /// **A bare digit run past its key's unit is scrubbed** (finding 10).
    ///
    /// The count shape used to be value-only — ASCII digits with at most one
    /// decimal point — so an unformatted ten-digit string written into a
    /// duration key took the fast path and the phone scrub never ran on it:
    /// a bare phone number, in a metadata field, on the way to the log. The
    /// bound is the key's own unit (a brain stage is under 1e9 ms, a byte
    /// total on a phone is under 1e12), so a run past it is not a reading for
    /// that key and keeps the full scrub. The boundary is stated here as well
    /// as the refusal, because a bound that redacted every value would pass
    /// this test for the wrong reason.
    func testABareDigitRunPastItsKeysUnitIsScrubbed() {
        let clean = sanitiser.sanitise(event(metadata: [
            "load_ms": "9812345678",
            "budgetBytes": "12345678901234",
        ]))
        XCTAssertEqual(clean.metadata["load_ms"], "[redacted]",
                       "a duration key's unit is under 1e9 ms; ten bare digits is not a reading")
        XCTAssertEqual(clean.metadata["budgetBytes"], "[redacted]",
                       "…and a byte total is under 1e12")

        let atTheBound = sanitiser.sanitise(event(metadata: [
            "load_ms": "999999999",
            "budgetBytes": "999999999999",
        ]))
        XCTAssertEqual(atTheBound.metadata["load_ms"], "999999999",
                       "the bound refuses what is past it, not what is inside it")
        XCTAssertEqual(atTheBound.metadata["budgetBytes"], "999999999999")
    }

    // MARK: - The debug lane's content-typed keys (owner decision, 2026-09-20)

    /// [SANITISED-DEBUG-LANE] The debug lane's three keys are redacted **by
    /// declaration**: whatever the value is, the token replaces it. The
    /// sentence below holds no phone number, no e-mail address and no blood
    /// pressure shape, so the PII scrub would return it untouched — which is
    /// exactly why the claim is pinned on this input. "Redacted" here cannot
    /// mean "a PII pattern happened to match"; the key decides, in every
    /// configuration.
    func testAContentTypedKeyIsRedactedEvenWhenTheValueHoldsNoPII() {
        let sentence = "Take two tablets after breakfast at eight"
        let clean = sanitiser.sanitise(event(metadata: [
            "recognized_text": sentence,
            "source_text": sentence,
            "translated_text": "नाश्ते के बाद दो गोलियाँ लें",
        ]))
        XCTAssertEqual(clean.metadata["recognized_text"], "[redacted]")
        XCTAssertEqual(clean.metadata["source_text"], "[redacted]")
        XCTAssertEqual(clean.metadata["translated_text"], "[redacted]")
    }

    /// The half that matters for a log surface: after sanitisation the text is
    /// nowhere on the event. Every field is swept, because a redaction that
    /// moved the string into `errorCode`, `eventType` or the component tag
    /// would satisfy a metadata-only assertion and still leak.
    func testNoFieldOfASanitisedEventCarriesTheRedactedText() {
        let sentence = "Take two tablets after breakfast at eight"
        let clean = sanitiser.sanitise(event(errorCode: sentence, metadata: [
            "recognized_text": sentence,
            "source_text": sentence,
            "translated_text": sentence,
        ]))
        var fields = [clean.eventType, clean.outcome, clean.errorCode ?? "", clean.component]
        fields.append(contentsOf: clean.metadata.map { "\($0.key)=\($0.value)" })
        for field in fields {
            XCTAssertFalse(field.contains(sentence),
                           "the redacted text survived on the sanitised event in '\(field)'")
        }
    }

    /// A redacted key is still a **declared** key: the lane adds no undeclared
    /// corner to the log surface, and the by-declaration redaction is what
    /// keeps the declaration from becoming a route for scene text. (The
    /// declaration itself is pinned by `LiveTranslateAllowListTests`, whose
    /// pinned extension set names these three.)
    func testTheContentTypedKeysAreDeclaredAndRedactedTogether() {
        for key in ["recognized_text", "source_text", "translated_text"] {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "\(key) travels the bus and must be declared here")
            XCTAssertEqual(sanitiser.sanitise(event(metadata: [key: "anything at all"]))
                            .metadata[key],
                           LogSanitiser.redactionToken)
        }
    }

    // MARK: - Profile field names are dropped whole (profile-interview T-104)

    /// [PROFILE-INTERVIEW T-104] The five profile field-name keys are
    /// redacted first and then dropped by the allow-list (design-l2 §7.4):
    /// no shipped event carries them, so the pair does not survive
    /// sanitisation at all — not its value, and not even the token. The
    /// values below hold no PII shape, which makes the disappearance a
    /// property of the KEY, not of the scrub happening to match.
    func testProfileFieldKeysAreDroppedWholeAndNeverCarryTheirValue() {
        let values: [String: String] = [
            "profile_name": "Maya Gurung",
            "address_as": "Mum",
            "date_of_birth": "1943-07-21",
            "emergency_doctor": "Dr. Sharma",
            "local_hospital": "Teaching Hospital",
        ]
        for (key, value) in values {
            let clean = sanitiser.sanitise(event(metadata: [key: value]))
            XCTAssertNil(clean.metadata[key],
                         "\(key) must not survive the allow-list filter")
            var fields = [clean.eventType, clean.outcome,
                          clean.errorCode ?? "", clean.component]
            fields.append(contentsOf: clean.metadata.map { "\($0.key)=\($0.value)" })
            for field in fields {
                XCTAssertFalse(field.contains(value),
                               "the value of \(key) survived on the "
                               + "sanitised event in '\(field)'")
            }
        }
    }

    /// The mechanism, not just the outcome: all five keys are members of
    /// `redactedKeys`, so the redaction runs BEFORE the allow-list — and
    /// none of them is allow-listed, which is what makes the drop whole.
    /// Together these pin the design's fail-closed direction: a future
    /// edit that allow-lists one of them cannot turn it into a
    /// pass-through (the token would be substituted first), and a future
    /// emitter that writes one cannot leak it (the allow-list drops it).
    func testTheProfileFieldKeysAreRedactedByDeclarationAndNotAllowListed() {
        for key in ["profile_name", "address_as", "date_of_birth",
                    "emergency_doctor", "local_hospital"] {
            XCTAssertTrue(LogSanitiser.redactedKeys.contains(key),
                          "\(key) must be redacted by declaration")
            XCTAssertFalse(LogSanitiser.allowedKeys.contains(key),
                           "\(key) must NOT be allow-listed — no shipped "
                           + "event carries it, and the drop-whole "
                           + "behaviour is the pin (design-l2 §7.4)")
        }
    }

    // MARK: - Dialogue metadata keys (multi-turn-conversation T-137; M-4/E5)

    /// The shipped allow-list as it stood before the dialogue extension.
    /// Pinned key for key so the diff below is provably exactly SIX NEW keys
    /// (E5): an existing key cannot be removed, renamed or re-meant, and
    /// `reason` is visible in this set — the dialogue feature REUSES it, it
    /// does not add it (M-4).
    private let shippedKeysBeforeTheDialogueExtension: Set<String> = [
        "entry_id_hash", "contact_id_hash", "refire_count", "entry_count", "alert_type",
        "outcome", "state", "duration_ms", "error_code",
        "calendar", "contacts", "decode_detail", "chunks", "frame", "rect", "cloud",
        "labels", "boxes", "stages", "part", "parts", "bytes", "http_status",
        "correction_mode", "correction_state", "correction_lexicon_revision",
        "correction_tokens_considered", "correction_applied_count",
        "correction_threshold_bucket", "correction_reasons", "correction_veto",
        "correction_entry_ids", "correction_classes", "correction_class_origins",
        "correction_best_bucket", "correction_margin_bucket",
        "regionCount", "regionSetHash", "stringCount", "batchIndex", "batchCount",
        "resolvedCount", "unresolvedCount", "durationMs", "keyCount", "count",
        "origin", "mode", "reason", "tier", "failureStage",
        "generationLength", "generationShape", "rejections", "disclosureVersion",
        "cap", "errorCode", "provider", "threshold", "confidence",
        "slot", "liveBytes", "budgetBytes", "evicted", "purpose", "isLargeLoad",
        "heldSeconds", "transientLiveBytes",
        "phys_footprint", "ceiling_bytes", "working_set_bytes",
        "projected_peak_bytes", "freed_bytes", "load_ms", "priority",
        "recognized_text", "source_text", "translated_text"
    ]

    /// The exactly six keys this change adds, with each key's documented
    /// closed vocabulary — the raw-value sets of the emitting types
    /// (design-l2 §26 over the §9/§12.5 enums) and the bounded counts of
    /// `DialogueConfig` (`maxProbes` = 2, `maxSlotOptions` = 4). `reason` is
    /// deliberately NOT here: it is a reused generic key whose dialogue
    /// tokens are closed at the construction site (M-4), not at the bus.
    private let dialogueClosedVocabularies: [String: Set<String>] = [
        "intake": ["ladder", "interpreted", "candidate"],
        "probe_kind": ["slotFill", "candidateChoice"],
        "attempt": ["1", "2"],
        "option_count": ["0", "1", "2", "3", "4"],
        "capture_form": ["indexWord", "optionName", "repetition", "freeText"],
        "merge_source": ["catalog", "freeText", "candidate", "defaultQuery"]
    ]

    /// Asserts the marker appears in **no field** of the sanitised event — a
    /// redaction that moved the string into `errorCode`, `eventType` or the
    /// component tag would satisfy a metadata-only assertion and still leak
    /// (the [SANITISED-DEBUG-LANE] sweep, reused).
    private func assertNoTrace(of marker: String, in clean: ObservabilityEvent,
                               file: StaticString = #filePath, line: UInt = #line) {
        var fields = [clean.eventType, clean.outcome,
                      clean.errorCode ?? "", clean.component]
        fields.append(contentsOf: clean.metadata.map { "\($0.key)=\($0.value)" })
        for field in fields {
            XCTAssertFalse(field.contains(marker),
                           "content '\(marker)' survived sanitisation in '\(field)'",
                           file: file, line: line)
        }
    }

    // MARK: Scenario: The six new keys are admitted with closed value sets

    func testTheSixNewDialogueKeysAreAdmittedAndInVocabularyPairsSurvive() {
        let clean = sanitiser.sanitise(event(metadata: [
            "intake": "ladder",
            "probe_kind": "slotFill",
            "attempt": "1",
            "option_count": "4",
            "capture_form": "optionName",
            "merge_source": "catalog",
            // The reused key and a pre-existing key ride along untouched.
            "reason": "degenerateAnswer",
            "outcome": "invalid"
        ]))
        XCTAssertEqual(clean.metadata["intake"], "ladder")
        XCTAssertEqual(clean.metadata["probe_kind"], "slotFill")
        XCTAssertEqual(clean.metadata["attempt"], "1")
        XCTAssertEqual(clean.metadata["option_count"], "4")
        XCTAssertEqual(clean.metadata["capture_form"], "optionName")
        XCTAssertEqual(clean.metadata["merge_source"], "catalog")
        XCTAssertEqual(clean.metadata["reason"], "degenerateAnswer")
        XCTAssertEqual(clean.metadata["outcome"], "invalid")
        XCTAssertEqual(Set(clean.metadata.keys), Set([
            "intake", "probe_kind", "attempt", "option_count",
            "capture_form", "merge_source", "reason", "outcome"
        ]), "every pair survives the filter — none is dropped or invented")
    }

    func testEveryDocumentedDialogueTokenSurvivesTheFilter() {
        for (key, vocabulary) in dialogueClosedVocabularies {
            for token in vocabulary {
                let clean = sanitiser.sanitise(event(metadata: [key: token]))
                XCTAssertEqual(clean.metadata[key], token,
                               "documented token '\(token)' for \(key) must survive untouched")
            }
        }
    }

    /// The vocabularies are **part of the log contract**: each one is exact
    /// (widening one takes a deliberate, reviewable edit here — a silent
    /// widening fails) and governs exactly the keys the allow-list admits.
    func testTheDialogueVocabulariesAreClosedAndExactlyAsDocumented() {
        XCTAssertEqual(LogSanitiser.closedVocabularyMetadataKeys,
                       dialogueClosedVocabularies,
                       "the closed vocabularies are pinned, not documented-only")
        XCTAssertEqual(LogSanitiser.closedVocabularyMetadataKeys.count, 6,
                       "exactly the six new dialogue keys are value-governed")
        for key in dialogueClosedVocabularies.keys {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "\(key) is governed by a vocabulary and must be allow-listed")
        }
        XCTAssertNil(LogSanitiser.closedVocabularyMetadataKeys["reason"],
                     "reason is reused and generic — its dialogue tokens are "
                     + "closed at the construction site, not at the bus (M-4)")
    }

    // MARK: Scenario: An unlisted key is still dropped

    func testAnUnlistedDialogueKeyIsDroppedAndTheAllowedPairsAreUnaffected() {
        // The verbatim answer text the feature must never log (the owner's
        // merge example, a benign fixture from the requirements corpus).
        let answerMarker = "दुर्गा भजन बजाऊ"
        // Plausible emitter mistakes: content-named keys and camelCase
        // near-twins of the new keys — near-twins are NOT the keys.
        let unlistedKeys = ["answer_text", "dialogue_transcript", "probe_text",
                            "answerText", "probeKind", "mergeSource",
                            "captureForm", "optionCount", "intake_source"]
        var metadata: [String: String] = [
            "intake": "ladder",
            "probe_kind": "candidateChoice",
            "attempt": "2",
            "option_count": "3",
            "capture_form": "freeText",
            "merge_source": "freeText"
        ]
        for key in unlistedKeys { metadata[key] = answerMarker }

        let clean = sanitiser.sanitise(event(metadata: metadata))

        for key in unlistedKeys {
            XCTAssertNil(clean.metadata[key],
                         "\(key) is not in the allow-list and must be dropped whole")
        }
        // The allowed pairs of the same event are unaffected.
        XCTAssertEqual(clean.metadata["intake"], "ladder")
        XCTAssertEqual(clean.metadata["probe_kind"], "candidateChoice")
        XCTAssertEqual(clean.metadata["attempt"], "2")
        XCTAssertEqual(clean.metadata["option_count"], "3")
        XCTAssertEqual(clean.metadata["capture_form"], "freeText")
        XCTAssertEqual(clean.metadata["merge_source"], "freeText")
        // …and the verbatim answer appears in no field of the output.
        assertNoTrace(of: answerMarker, in: clean)
    }

    // MARK: Scenario: Out-of-vocabulary token values fail closed

    func testAnOutOfVocabularyDialogueTokenFailsClosed() {
        // Each value is outside its key's documented set by a different
        // failure shape: a suffix, a case drift, a count past the config
        // bound and a joined pair. None may be logged — the pair survives
        // only as the redaction token.
        let outOfVocabulary: [String: String] = [
            "intake": "ladder_stage",
            "probe_kind": "SlotFill",
            "attempt": "3",
            "option_count": "5",
            "capture_form": "free_text",
            "merge_source": "freeText,catalog"
        ]
        for (key, value) in outOfVocabulary {
            let clean = sanitiser.sanitise(event(metadata: [key: value]))
            XCTAssertEqual(clean.metadata[key], LogSanitiser.redactionToken,
                           "\(key)='\(value)' is outside its closed vocabulary "
                           + "and must be rejected, not logged")
        }
        // Boundary: the in-vocabulary neighbours of the same inputs pass —
        // the bound refuses what is past it, not what is inside it.
        let atTheBounds = sanitiser.sanitise(event(metadata: [
            "attempt": "2",
            "option_count": "4",
            "capture_form": "freeText"
        ]))
        XCTAssertEqual(atTheBounds.metadata["attempt"], "2")
        XCTAssertEqual(atTheBounds.metadata["option_count"], "4")
        XCTAssertEqual(atTheBounds.metadata["capture_form"], "freeText")
    }

    /// The sharpest out-of-vocabulary case, across all six keys: verbatim
    /// answer text. The value is replaced wholesale — the PII scrub would
    /// have left the sentence intact, because a sentence holds no phone
    /// number — and it appears in no field of the sanitised event.
    func testVerbatimAnswerTextUnderADialogueKeyIsReplacedNotScrubbed() {
        let answer = "दुर्गा भजन बजाऊ"
        for key in dialogueClosedVocabularies.keys {
            let clean = sanitiser.sanitise(event(metadata: [key: answer]))
            XCTAssertEqual(clean.metadata[key], LogSanitiser.redactionToken,
                           "\(key) may never carry answer text")
            assertNoTrace(of: answer, in: clean)
        }
    }

    // MARK: Scenario: The reused reason key is already admitted

    func testTheReusedReasonKeySurvivesDialogueTokensWithoutAnAllowListChange() {
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("reason"))
        XCTAssertTrue(shippedKeysBeforeTheDialogueExtension.contains("reason"),
                      "reason is in the pre-change snapshot — reused, not added (M-4)")
        // The dialogue invalid-answer tokens under the reused key
        // (`InvalidAnswerReason` raw values, design-l2 §9) all survive with
        // no allow-list change for it.
        for token in ["overLength", "emptyAfterStrip", "degenerateAnswer",
                      "noCandidateClaimed"] {
            XCTAssertEqual(sanitiser.sanitise(event(metadata: ["reason": token]))
                            .metadata["reason"], token)
        }
        // …and the key keeps its shipped meaning for the non-dialogue
        // emitters: a real ledger token still rides it untouched, which a
        // bus-level narrowing to the dialogue vocabulary would have broken.
        XCTAssertEqual(sanitiser.sanitise(event(metadata: ["reason": "over_class_budget"]))
                        .metadata["reason"], "over_class_budget")
    }

    // MARK: The allow-list diff (E5 producer line)

    func testTheAllowListDiffIsExactlyTheSixNewKeysAndReasonIsUntouched() {
        // Nothing pre-existing was removed, renamed or re-meant.
        for key in shippedKeysBeforeTheDialogueExtension {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "\(key) was in the shipped allow-list and must not be removed")
        }
        let added = LogSanitiser.allowedKeys
            .subtracting(shippedKeysBeforeTheDialogueExtension)
        XCTAssertEqual(added, Set(dialogueClosedVocabularies.keys),
                       "the extension is exactly the six documented dialogue keys "
                       + "— a silent widening fails here")
        XCTAssertEqual(added.count, 6)
        XCTAssertEqual(LogSanitiser.allowedKeys.count,
                       shippedKeysBeforeTheDialogueExtension.count + 6)
        XCTAssertFalse(added.contains("reason"),
                       "reason is reused (already in the shipped set), never re-added")
        for key in added {
            XCTAssertNotNil(LogSanitiser.closedVocabularyMetadataKeys[key],
                            "every added dialogue key is governed by a closed vocabulary")
        }
    }
}
