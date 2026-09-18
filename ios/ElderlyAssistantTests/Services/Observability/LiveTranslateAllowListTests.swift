import XCTest
@testable import ElderlyAssistant

/// T-003 / AM-2 — the additive allow-list extension on the shipped
/// `LogSanitiser`, proven key by key, with the two deliberate decisions
/// recorded rather than widened silently:
///
///  - `cap` is added because the shipped cost governor emits it and the
///    allow-list was dropping it (the family-visible cap signal arrived with
///    no count and no cap);
///  - no metadata `errorCode` twin is added, because the top-level field is
///    the one that is shape-bounded.
///
/// NFR-LCT-012: nothing that existed before this change is removed, renamed
/// or re-meant, and the shipped behaviours are re-pinned here.
final class LiveTranslateAllowListTests: XCTestCase {

    private let sanitiser = LogSanitiser()

    private func event(metadata: [String: String],
                       errorCode: String? = nil) -> ObservabilityEvent {
        ObservabilityEvent(component: "livetranslate",
                           eventType: "probe",
                           durationMs: nil,
                           outcome: "success",
                           errorCode: errorCode,
                           metadata: metadata)
    }

    private func sanitisedMetadata(_ metadata: [String: String]) -> [String: String] {
        sanitiser.sanitise(event(metadata: metadata)).metadata
    }

    /// The shipped allow-list as it stood before this change. Pinned so an
    /// existing key cannot be removed or renamed (NFR-LCT-012).
    private let shippedKeysBeforeThisChange: Set<String> = [
        "entry_id_hash", "contact_id_hash", "refire_count", "entry_count", "alert_type",
        "outcome", "state", "duration_ms", "error_code", "stages",
        "part", "parts", "bytes", "http_status",
        "correction_mode", "correction_state", "correction_lexicon_revision",
        "correction_tokens_considered", "correction_applied_count",
        "correction_threshold_bucket", "correction_reasons", "correction_veto",
        "correction_entry_ids", "correction_classes", "correction_class_origins",
        "correction_best_bucket", "correction_margin_bucket"
    ]

    // MARK: Scenario: existing keys and their meanings are untouched

    func testEveryPreviouslyPresentKeyIsStillAllowed() {
        for key in shippedKeysBeforeThisChange {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "\(key) was in the shipped allow-list and must not be removed")
        }
    }

    func testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList() {
        let added = LogSanitiser.allowedKeys.subtracting(shippedKeysBeforeThisChange)
        // The guard is unchanged — every key beyond the pre-change shipped
        // set must be DECLARED here, so a silent widening still fails — but
        // the declared set is now the union of both declared extensions:
        // this feature's 15 keys plus `provider` / `threshold` /
        // `confidence`, declared by [CLOUD-CASCADE] on master
        // (`cloud_cascade_escalated`: a provider raw value and two 0…1
        // scores). Neither side's entries are dropped and nothing is
        // widened without a name.
        XCTAssertEqual(added, [
            "regionCount", "stringCount", "batchIndex", "batchCount", "resolvedCount",
            "unresolvedCount", "durationMs", "keyCount", "count", "origin", "mode",
            "reason", "disclosureVersion", "cap", "errorCode",
            "provider", "threshold", "confidence",
            // [CASCADE-PROVENANCE] (2026-09-19) Which tier answered a settle.
            "tier",
            // Declared by the work merged since the extension baseline:
            // [MODEL-WARDEN] (slots, reservations, cost model, footprints)
            "slot", "purpose", "priority", "isLargeLoad", "heldSeconds",
            "transientLiveBytes", "liveBytes", "budgetBytes", "ceiling_bytes",
            "working_set_bytes", "phys_footprint", "projected_peak_bytes",
            "load_ms", "freed_bytes", "evicted",
            // [SCOPE-LEDGER] + [DEAD-TAP] + [DECODE-DIAGNOSTIC]
            "calendar", "contacts", "chunks", "decode_detail",
            // [LLAMADEBUG] failure stage + [EMPTY-OVERLAY] region-set hash
            "failureStage", "regionSetHash"
        ], "the extension is exactly the union of the two declared key sets")
        XCTAssertNil(sanitisedMetadata(["somethingNoOneDeclared": "x"])["somethingNoOneDeclared"],
                     "unknown keys are still dropped outright")
    }

    func testTheCamelCaseDurationKeyDidNotReplaceTheShippedSnakeCaseOne() {
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("duration_ms"))
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("durationMs"))
        let clean = sanitisedMetadata(["duration_ms": "12", "durationMs": "34"])
        XCTAssertEqual(clean["duration_ms"], "12")
        XCTAssertEqual(clean["durationMs"], "34")
    }

    // MARK: Scenario: every key the feature emits survives sanitisation
    // (one test per new key, asserting the value and not just the presence)

    func testRegionCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["regionCount": "7"])["regionCount"], "7")
    }

    func testStringCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["stringCount": "5"])["stringCount"], "5")
    }

    func testBatchIndexSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["batchIndex": "1"])["batchIndex"], "1")
    }

    func testBatchCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["batchCount": "3"])["batchCount"], "3")
    }

    func testResolvedCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["resolvedCount": "11"])["resolvedCount"], "11")
    }

    func testUnresolvedCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["unresolvedCount": "2"])["unresolvedCount"], "2")
    }

    func testDurationMsSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["durationMs": "812"])["durationMs"], "812")
    }

    func testKeyCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["keyCount": "4"])["keyCount"], "4")
    }

    func testCountSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["count": "9"])["count"], "9")
    }

    func testOriginSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["origin": "persisted"])["origin"], "persisted")
    }

    func testModeSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["mode": "read_all"])["mode"], "read_all")
    }

    func testReasonSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["reason": "cost_budget_exhausted"])["reason"],
                       "cost_budget_exhausted")
    }

    func testDisclosureVersionSurvivesSanitisation() {
        let version = LiveTranslateConfig.default.disclosureVersion
        XCTAssertEqual(sanitisedMetadata(["disclosureVersion": version])["disclosureVersion"],
                       version,
                       "the version stamp must reach the log surface unredacted")
    }

    /// AM-2 decision: the shipped governor's own metadata key. Its absence
    /// was the defect — `daily_cap_reached` arrived with a count and no cap.
    func testCapSurvivesSanitisation() {
        XCTAssertEqual(sanitisedMetadata(["cap": "200"])["cap"], "200")
    }

    // MARK: AM-2 decision: the code key, allow-listed AND bounded

    /// The key is allowed (the design's catalogue names a content-free code
    /// for the failure events) **and** it carries the same bound as the
    /// top-level field, so allow-listing it cannot become a PII-scrubbed
    /// bypass of the T-050/B2 bound.
    func testErrorCodeSurvivesSanitisationWithItsValue() {
        XCTAssertEqual(sanitisedMetadata(["errorCode": "cloud_rejected_503"])["errorCode"],
                       "cloud_rejected_503")
        XCTAssertEqual(sanitisedMetadata(["errorCode": "consent_record_unreadable"])["errorCode"],
                       "consent_record_unreadable")
    }

    func testTheErrorCodeMetadataKeyIsBoundedToACodeShape() {
        XCTAssertEqual(sanitisedMetadata(["errorCode": "Error Domain=NSURLErrorDomain Code=-1004"])["errorCode"],
                       "[redacted]",
                       "a description is not a code")
        XCTAssertEqual(sanitisedMetadata(["errorCode": "https://example.invalid/?key=AIzaSy"])["errorCode"],
                       "[redacted]",
                       "a URL or key is not a code")
        XCTAssertEqual(sanitisedMetadata(["errorCode": String(repeating: "a", count: 128)])["errorCode"],
                       "[redacted]",
                       "one unbroken run is a key, not a code")
    }

    /// NFR-LCT-012: the shipped snake_case key is **not** re-bounded. It is
    /// already written by shipped emitters, so changing how its values are
    /// treated would be a behaviour change to a shipped component. Pinned for
    /// its real payloads only — the key's pre-existing behaviour for
    /// arbitrary text is not blessed here.
    func testTheShippedSnakeCaseKeyKeepsItsExistingBehaviour() {
        XCTAssertEqual(sanitisedMetadata(["error_code": "model_not_cached"])["error_code"],
                       "model_not_cached")
        XCTAssertEqual(sanitisedMetadata(["error_code": "low_confidence"])["error_code"],
                       "low_confidence")
    }

    func testTheTopLevelErrorCodeRemainsTheBoundedCarrier() {
        XCTAssertTrue(LogSanitiser.allowedKeys.contains("error_code"))
        XCTAssertEqual(sanitiser.sanitise(event(metadata: [:], errorCode: "cloud_rejected_503")).errorCode,
                       "cloud_rejected_503")
        XCTAssertEqual(sanitiser.sanitise(event(metadata: [:],
                                               errorCode: "Error Domain=NSURLErrorDomain Code=-1004")).errorCode,
                       "[redacted]",
                       "the bound still replaces a description rather than logging it")
    }

    // MARK: Where the guard actually is (honesty about the boundary)

    /// `LogSanitiser` is an allow-list plus a PII scrubber: it does not know
    /// what a translation is, so free text under an allowed key **does**
    /// survive it. The guard against recognized or translated text reaching
    /// the log surface is therefore the feature's typed emitters plus the
    /// schema test in `LiveTranslateEventsTests` — not this bus. Pinned here
    /// so no later reader credits the bus with a guarantee it does not make.
    func testTheSanitiserScrubsButDoesNotDropTextUnderAnAllowedKey() {
        XCTAssertEqual(sanitisedMetadata(["reason": "फार्मेसी खुला छ"])["reason"],
                       "फार्मेसी खुला छ")
        // …what it does do is scrub obvious PII shapes even in an allowed key:
        XCTAssertEqual(sanitisedMetadata(["reason": "call +9779812345678"])["reason"],
                       "call [redacted]")
    }

    // MARK: Scenario: the shipped cap events keep their meaning

    /// Drives the **real** `GeminiCostGovernor` over its cap — its own
    /// payload, unchanged — and asserts the two keys it emits now survive the
    /// bus. This is the evidence for the `cap` decision, not a claim about it.
    func testTheShippedCostGovernorCapEventsSurviveIntact() {
        let governorBus = MockObservabilityBus()
        let governor = GeminiCostGovernor(
            storage: GeminiInMemoryStorage(),
            observabilityBus: governorBus,
            now: { Date(timeIntervalSince1970: 1_756_000_000) })
        governor.setSoftDailyCap(10)
        for _ in 0..<10 { governor.recordCall() }

        let warning = governorBus.emittedEvents.first { $0.eventType == "daily_cap_warning" }
        let reached = governorBus.emittedEvents.first { $0.eventType == "daily_cap_reached" }
        XCTAssertNotNil(warning, "the shipped warning still fires")
        XCTAssertNotNil(reached, "the shipped cap signal still fires")

        let cleanWarning = sanitiser.sanitise(warning!)
        let cleanReached = sanitiser.sanitise(reached!)
        XCTAssertEqual(cleanWarning.component, "gemini_cost")
        XCTAssertEqual(cleanReached.component, "gemini_cost")
        XCTAssertEqual(cleanWarning.metadata["count"], "8")
        XCTAssertEqual(cleanWarning.metadata["cap"], "10")
        XCTAssertEqual(cleanReached.metadata["count"], "10")
        XCTAssertEqual(cleanReached.metadata["cap"], "10")
        XCTAssertEqual(cleanReached.outcome, "reached")
        XCTAssertNil(cleanReached.errorCode)
    }

    // MARK: End to end on the real console sink

    /// Everything above runs through `LogSanitiser` directly. This test drives
    /// the feature's emitters through the shipped `ConsoleObservabilityBus`
    /// (the real sink: sanitise + `print`) and reads what was actually
    /// printed, so the claim "the evidence reaches the log surface" is made
    /// against the console and not against an in-memory copy.
    func testTheFeaturesKeysReachTheRealConsoleSink() {
        let printed = captureConsole {
            let bus = ConsoleObservabilityBus()
            let events = LiveTranslateEvents(bus: bus)
            events.consentRecorded()
            events.translationBatchResolved(resolvedCount: 4, unresolvedCount: 1, durationMs: 812)
            events.translationDegraded(reason: .consentNotGranted, regionCount: 1)
            events.textQuarantined(count: 2)
            events.costExhaustedLatched()
        }

        XCTAssertTrue(printed.contains("[livetranslate]"), "no feature event reached the console")
        XCTAssertTrue(printed.contains("disclosureVersion"), "the consent evidence was dropped")
        XCTAssertTrue(printed.contains(LiveTranslateConfig.default.disclosureVersion),
                      "the disclosure version value was dropped or redacted")
        XCTAssertTrue(printed.contains("resolvedCount"), "the batch evidence was dropped")
        XCTAssertTrue(printed.contains("durationMs"), "the batch duration was dropped")
        XCTAssertTrue(printed.contains("consent_not_granted"), "the degradation reason was dropped")
        XCTAssertTrue(printed.contains("[\"count\": \"2\"]"), "the quarantine count was dropped")
        XCTAssertTrue(printed.contains("cost_exhausted_latched"), "the latch event was dropped")

        // And nothing content-shaped reached it: the run above carries
        // recognized text nowhere, so the feature's own console lines must
        // carry none either. Scoped to this feature's lines — another test
        // running concurrently may print whatever it likes.
        let featureLines = printed.split(separator: "\n").filter { $0.contains("[livetranslate]") }
        XCTAssertEqual(featureLines.count, 5, "every emitted event should have reached the console")
        for line in featureLines {
            // By scalar, not by `range(of:options:.regularExpression)`: that
            // API declines a match whose range splits a grapheme cluster, so
            // it cannot see the Devanagari inside `यो` (य + ो) — a leaked
            // sentence in the elder's language would have passed this check
            // (T-033, `specs/T-033-notes.md`).
            XCTAssertFalse(String(line).unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                           "content reached the console: \(line)")
        }
    }

    /// Runs `body` with process stdout redirected to a temp file and returns
    /// what the sink printed.
    private func captureConsole(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/livetranslate-sink-\(UUID().uuidString).log"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }
}
