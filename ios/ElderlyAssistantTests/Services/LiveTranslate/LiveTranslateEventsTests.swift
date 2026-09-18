import XCTest
@testable import ElderlyAssistant

/// T-003 — the feature's events are content-free by schema, every key the
/// emitters use is declared, and the pinned key set cannot drift from the
/// shipped log allow-list (AM-2, CL-5, NFR-LCT-006/007).
final class LiveTranslateEventsTests: XCTestCase {

    /// One bus and one emitter per test: XCTest builds a fresh instance for
    /// every test method, so captured events never leak between tests.
    private lazy var bus = LiveTranslateSanitisingBus()
    private lazy var events = LiveTranslateEvents(bus: bus)

    // MARK: Driving every emitter

    /// Exercises every emitter once, with small fixture values. Every key in
    /// the catalogue is produced by at least one of these calls.
    @discardableResult
    private func driveEveryEmitter() -> LiveTranslateSanitisingBus {
        events.sessionStarted()
        events.sessionEnded()
        events.cameraDenied()
        events.cameraUnavailable(.noCaptureDevice)
        events.cameraInterrupted(.thermal)
        events.cameraResumed(recoveringFrom: .backgrounded)
        events.ocrPass(regionCount: 3)
        events.ocrPass(regionCount: 0)
        events.ocrPassFailed(.ocrPassFailed(.requestFailed))
        events.trackingUnsupported()
        events.objectPass(objectCount: 2)
        events.objectPass(objectCount: 0)
        events.objectPassFailed(.ocrPassFailed(.requestFailed))
        events.objectDetectionUnsupported()
        events.regionAppeared()
        events.regionRemoved()
        events.textChange(regionCount: 2, regionSetHash: 0x1a2b_3c4d)
        events.translationBatchRequested(stringCount: 5, batchIndex: 0, batchCount: 1)
        events.translationBatchResolved(resolvedCount: 4, unresolvedCount: 1, durationMs: 812)
        events.brainTranslationBatch(resolvedCount: 3, unresolvedCount: 1, durationMs: 4200)
        events.brainTranslationUnavailable(.modelNotInstalled, stage: .availability)
        events.translationDegraded(reason: .noNetwork, regionCount: 1)
        events.translationResolved(tier: .cloud, origin: .fresh, count: 2)
        events.translationResolved(tier: .dictionary, origin: .cache, count: 1)
        events.translationDedupeHit(keyCount: 2)
        events.textQuarantined(count: 1)
        events.consentPromptShown()
        events.consentRecorded()
        events.consentDenied()
        events.consentRevoked()
        events.consentUnreadable()
        events.consentWriteFailed()
        events.cloudIndicatorShown()
        events.cloudIndicatorHidden()
        events.costExhaustedLatched()
        events.cacheHit(origin: .persisted, count: 1)
        events.cacheMiss(origin: .curatedDictionary, count: 1)
        events.cacheEvicted(origin: .persisted, count: 2)
        events.cachePayloadReset(.cacheReadFailed(.payloadUnreadable))
        events.cacheWriteFailed(.cacheWriteFailed(.storageUnavailable))
        events.speakRequested(mode: .readAll)
        events.speakFailed(mode: .tap)
        return bus
    }

    // MARK: Scenario: every key the feature emits survives sanitisation

    func testEveryCatalogueMetadataKeySurvivesTheShippedSanitisingBus() {
        let bus = driveEveryEmitter()

        // Every declared key was produced by an emitter…
        for key in LiveTranslateEventCatalogue.allMetadataKeys {
            XCTAssertTrue(bus.events.contains { $0.metadata[key] != nil },
                          "no emitter produced the declared key \(key)")
        }
        // …and every declared key survived with a value.
        for event in bus.events {
            let declared = LiveTranslateEventCatalogue.entries[event.eventType]?.metadataKeys ?? []
            for key in declared {
                XCTAssertNotNil(event.metadata[key],
                                "\(event.eventType): key \(key) was dropped by the sanitiser")
                XCTAssertNotEqual(event.metadata[key], "[redacted]",
                                  "\(event.eventType): value of \(key) was redacted")
            }
        }
    }

    func testObservedMetadataKeysMatchThePinnedCatalogueExactly() {
        let bus = driveEveryEmitter()
        for eventType in bus.eventTypes {
            guard let entry = LiveTranslateEventCatalogue.entries[eventType] else {
                XCTFail("\(eventType) is not declared in the catalogue")
                continue
            }
            XCTAssertEqual(bus.observedMetadataKeys(named: eventType), entry.metadataKeys,
                           "\(eventType): the pinned key set no longer matches the emitter")
        }
    }

    func testEveryObservedOutcomeIsInTheCataloguesOutcomeVocabulary() {
        let bus = driveEveryEmitter()
        for event in bus.events {
            guard let entry = LiveTranslateEventCatalogue.entries[event.eventType] else { continue }
            XCTAssertTrue(entry.outcomes.contains(event.outcome),
                          "\(event.eventType) emitted an undeclared outcome \(event.outcome)")
        }
    }

    func testEveryCatalogueEntryIsActuallyEmitted() {
        let bus = driveEveryEmitter()
        let declared = LiveTranslateEventCatalogue.allEventTypes
        XCTAssertEqual(bus.eventTypes, declared,
                       "a catalogued event with no emitter (or vice versa) is a schema drift")
    }

    // MARK: Scenario: a new key cannot be added without a deliberate decision

    func testTheEmitterKeySetIsPinnedToTheShippedAllowList() {
        for key in LiveTranslateEvents.MetadataKey.allCases {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key.rawValue),
                          "\(key.rawValue) is not in the shipped allow-list — it would be dropped silently")
        }
        XCTAssertEqual(LiveTranslateEventCatalogue.allMetadataKeys,
                       Set(LiveTranslateEvents.MetadataKey.allCases.map(\.rawValue)),
                       "the catalogue and the emitter's key vocabulary must be the same set")
    }

    func testEveryEmittedEventUsesTheFeatureComponent() {
        let bus = driveEveryEmitter()
        for event in bus.events {
            XCTAssertEqual(event.component, "livetranslate")
        }
    }

    // MARK: Scenario: content cannot travel in a metadata value or an error code

    /// Every value the emitters produce is an integer, a closed token or the
    /// version stamp. This is the guard the whole file rests on: the shipped
    /// sanitiser scrubs PII shapes but does **not** drop free text in an
    /// allowed key (asserted separately in `LiveTranslateAllowListTests`), so
    /// the schema here is what keeps recognized and translated text out of
    /// the log surface.
    func testEveryEmittedMetadataValueIsCountTokenOrVersion() {
        let allowedTokens = Set(TranslationUnavailableReason.allCases.map(\.rawValue))
            .union(Set(TranslationTier.allCases.map(\.rawValue)))
            // The on-device translation tier's own closed reason vocabulary:
            // the tokens its `brain_translation_unavailable` event may carry.
            .union(Set(LiveTranslateBrainUnavailableReason.allCases.map(\.rawValue)))
            // …and the stage that says where the attempt stopped — the second
            // closed token on the same event (2026-09-17).
            .union(Set(BrainFailureStage.allCases.map(\.rawValue)))
            .union([
                "no_capture_device", "configuration_failed", "resource_in_use",
                "backgrounded", "system_interruption", "thermal",
                "curated_dictionary", "persisted",
                // [CASCADE-PROVENANCE] translation_resolved.origin tokens.
                "fresh", "cache",
                "tap", "read_all", "repeat_last",
                // T-026 added the command handler's re-prompt to the speech
                // modes; the token joins the closed vocabulary here rather
                // than being spelled at a call site.
                "reprompt"
            ])
            .union([LiveTranslateConfig.default.disclosureVersion])

        let bus = driveEveryEmitter()
        for event in bus.events {
            for (key, value) in event.metadata {
                if Int(value) != nil { continue }
                // The one value that is neither a count nor a closed token: the
                // scene digest (owner device report, 2026-09-18). It is pinned
                // to a *shape* here rather than waved through — eight hex
                // digits around a colon, nine characters in all, built by
                // `regionSetHashHex` from a `UInt32` with no string in reach.
                // Prose, a path, a URL, a key or a recognized string cannot
                // satisfy that pattern.
                if key == LiveTranslateEvents.MetadataKey.regionSetHash.rawValue,
                   value.range(of: "^[0-9a-f]{4}:[0-9a-f]{4}$",
                               options: .regularExpression) != nil { continue }
                XCTAssertTrue(allowedTokens.contains(value),
                              "\(event.eventType).\(key) carries a value outside the closed vocabulary: \(value)")
                XCTAssertFalse(value.contains(" "),
                               "\(event.eventType).\(key) contains whitespace — the shape of prose: \(value)")
                XCTAssertFalse(value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                               "\(event.eventType).\(key) contains Devanagari — content cannot reach metadata")
            }
        }
    }

    func testEveryErrorCodeIsAClosedTokenOrAnIntegerSuffix() {
        let bus = driveEveryEmitter()
        for event in bus.events {
            guard let code = event.errorCode else { continue }
            XCTAssertNotNil(code.range(of: "^[a-z_]+(_[0-9]+)?$", options: .regularExpression),
                            "\(event.eventType) carries a non-token error code: \(code)")
        }
    }

    /// The disclosure version is read from the emitter's own config, so no
    /// call site can pass anything else into that key.
    func testTheDisclosureVersionMetadataComesFromTheConfig() {
        var config = LiveTranslateConfig.default
        config.disclosureVersion = "livetranslate.disclosure.test.r7"
        let customBus = LiveTranslateSanitisingBus()
        let custom = LiveTranslateEvents(bus: customBus, config: config)

        custom.consentPromptShown()
        custom.consentRecorded()
        custom.consentDenied()
        custom.consentRevoked()

        for eventType in ["consent_prompt_shown", "consent_recorded", "consent_denied", "consent_revoked"] {
            let event = customBus.events(named: eventType).first
            XCTAssertEqual(event?.metadata["disclosureVersion"], "livetranslate.disclosure.test.r7",
                           "\(eventType) must carry the config's stamp")
        }
    }

    // MARK: Scenario: the shipped cap events keep their meaning

    /// The family-visible cap signal stays the shipped governor's own events
    /// on component `gemini_cost`; the feature's latch is additional. This
    /// asserts the feature's side of that contract (the governor's payloads
    /// are exercised against the real governor in
    /// `LiveTranslateAllowListTests`).
    func testTheFeatureAddsALatchEventAndNeverReEmitsTheShippedCapEvents() {
        let bus = driveEveryEmitter()
        XCTAssertEqual(bus.events(named: "cost_exhausted_latched").count, 1)
        for shipped in ["daily_cap_warning", "daily_cap_reached"] {
            XCTAssertTrue(bus.events(named: shipped).isEmpty,
                          "the feature must not re-emit the shipped \(shipped) event")
            XCTAssertFalse(LiveTranslateEventCatalogue.allEventTypes.contains(shipped))
        }
    }

    // MARK: Per-event details the catalogue promises

    func testAnEmptyOCRPASSReportsTheEmptyOutcomeRatherThanAFailure() {
        events.ocrPass(regionCount: 0)
        XCTAssertEqual(bus.events(named: "ocr_pass").first?.outcome, "empty")
        XCTAssertNil(bus.events(named: "ocr_pass").first?.errorCode)
    }

    func testAPartiallyResolvedBatchReportsPartial() {
        events.translationBatchResolved(resolvedCount: 4, unresolvedCount: 1, durationMs: 900)
        let event = bus.events(named: "translation_batch_resolved").first
        XCTAssertEqual(event?.outcome, "partial")
        XCTAssertEqual(event?.metadata["durationMs"], "900")
        XCTAssertEqual(event?.durationMs, 900,
                       "the top-level duration and the metadata key come from one parameter")
    }

    func testAFullyResolvedBatchReportsSuccess() {
        events.translationBatchResolved(resolvedCount: 5, unresolvedCount: 0, durationMs: 900)
        XCTAssertEqual(bus.events(named: "translation_batch_resolved").first?.outcome, "success")
    }

    func testQuarantineIsRecordedWithACountAndNothingElse() {
        events.textQuarantined(count: 2)
        let event = bus.events(named: "text_quarantined").first
        XCTAssertEqual(event?.metadata, ["count": "2"])
        XCTAssertNil(event?.errorCode)
    }

    /// The honest event C02's prose requires: an unsupported tracking
    /// request degrades to OCR-only and says so, with the taxonomy's code.
    func testUnsupportedTrackingIsRecordedHonestly() {
        events.trackingUnsupported()
        let event = bus.events(named: "tracking_unsupported").first
        XCTAssertEqual(event?.outcome, "degraded")
        XCTAssertEqual(event?.errorCode, "tracking_unsupported")
        XCTAssertEqual(event?.metadata, [:])
    }

    func testTheDegradedEventCarriesOnlyTheReasonTokenAndARegionCount() {
        events.translationDegraded(reason: .costBudgetExhausted, regionCount: 3)
        let event = bus.events(named: "translation_degraded").first
        XCTAssertEqual(event?.outcome, "degraded")
        XCTAssertEqual(event?.metadata["reason"], "cost_budget_exhausted")
        XCTAssertEqual(event?.metadata["regionCount"], "3")
    }

    // MARK: Scenario: the scene digest is a discriminator, not a content channel

    /// What the owner reads off the next device capture: two four-digit halves,
    /// lowercase hex, one colon, always nine characters — so two lines of a log
    /// can be compared at a glance and neither can be mistaken for prose.
    func testTheSceneDigestRendersAsAFixedWidthHexPair() {
        XCTAssertEqual(LiveTranslateEvents.regionSetHashHex(0x1a2b_3c4d), "1a2b:3c4d")
        XCTAssertEqual(LiveTranslateEvents.regionSetHashHex(0), "0000:0000")
        XCTAssertEqual(LiveTranslateEvents.regionSetHashHex(0xabcd), "0000:abcd")
        XCTAssertEqual(LiveTranslateEvents.regionSetHashHex(0xffff_ffff), "ffff:ffff")
        XCTAssertEqual(LiveTranslateEvents.regionSetHashHex(0x1234_5678).count, 9)
    }

    /// The colon is load-bearing. A digest is a `UInt32` and can be all digits;
    /// the sanitiser's phone-number guard matches a run of seven or more digits
    /// and would redact the whole value, silently turning "the scene is the
    /// same" into "[redacted]" and making a stable scene look like a changing
    /// one. The colon takes the value out of that guard's character class.
    func testAnAllDigitDigestSurvivesTheSanitiserVerbatim() {
        events.textChange(regionCount: 4, regionSetHash: 0x1234_5678)
        let event = bus.events(named: "text_change").first
        XCTAssertEqual(event?.metadata["regionSetHash"], "1234:5678")
        XCTAssertNotEqual(event?.metadata["regionSetHash"], "[redacted]")
        XCTAssertEqual(event?.metadata["regionCount"], "4")
    }

    func testCameraEventsCarryOnlyClosedReasonTokens() {
        events.cameraDenied()
        events.cameraUnavailable(.configurationFailed)
        events.cameraInterrupted(.systemInterruption)
        events.cameraResumed(recoveringFrom: .thermal)
        XCTAssertEqual(bus.events(named: "camera_denied").first?.metadata, [:])
        XCTAssertEqual(bus.events(named: "camera_denied").first?.errorCode, "camera_permission_denied")
        XCTAssertEqual(bus.events(named: "camera_unavailable").first?.metadata["reason"], "configuration_failed")
        XCTAssertEqual(bus.events(named: "camera_interrupted").first?.metadata["reason"], "system_interruption")
        XCTAssertEqual(bus.events(named: "camera_resumed").first?.metadata["reason"], "thermal")
        XCTAssertEqual(bus.events(named: "camera_resumed").first?.outcome, "success")
    }
}
