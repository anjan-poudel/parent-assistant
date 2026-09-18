import XCTest
@testable import ElderlyAssistant

/// T-001 — every operational constant resolves from one value with the
/// design's documented default, and the cloud base timeout has exactly one
/// source of truth (NFR-LCT-011, CL-8).
final class LiveTranslateConfigTests: XCTestCase {

    // MARK: Scenario: every parameter resolves from one value

    /// The pin against the design's parameter table
    /// (`specs/design-component.md` § "Configurable parameters and
    /// timeouts"). A silent drift in any default fails here.
    func testDefaultsMatchTheDesignsParameterTableExactly() {
        let config = LiveTranslateConfig.default

        // Detection cadence (OD1)
        XCTAssertEqual(config.ocrSampleInterval, 0.25)
        XCTAssertEqual(config.thermalCadenceFactor, 2.0)
        XCTAssertEqual(config.thermalStateThreshold, .serious)

        // Tracking / stabilisation
        XCTAssertTrue(config.trackingEnabled)
        XCTAssertEqual(config.regionMatchIoU, 0.3)
        XCTAssertEqual(config.regionMatchCentroidDistance, 0.35)
        XCTAssertEqual(config.regionAppearPasses, 2)
        XCTAssertEqual(config.regionMissPasses, 2)
        // The departure bound (owner device verdict, 2026-09-17): above the
        // nominal pass interval, so one dropped frame at full cadence is still
        // not a departure, and well under the 1.4 s two misses cost at the
        // reduced one.
        XCTAssertEqual(config.overlayDepartureGraceSeconds, 1.2)

        // Decluttering (OD5), both re-tuned by the 2026-09-17 UX rework: a
        // wider merge (clustered same-string boxes become one overlay) and a
        // smaller cap (fewer, larger, stable elements on the glance surface).
        XCTAssertEqual(config.declutterMergeCentroidDistance, 0.12)
        XCTAssertEqual(config.declutterMaxRegions, 6)

        // Overlay (D1, OD2)
        XCTAssertEqual(config.inPlaceMinPointSize, 16)
        XCTAssertEqual(config.inPlaceMaxGrowth, 1.4)
        XCTAssertEqual(config.panelMaxHeightFraction, 0.45,
                       "the bounded panel's cap (owner refinement, 2026-09-18)")
        XCTAssertEqual(config.overlayMinPointSize, 18)
        XCTAssertFalse(config.alwaysShowOriginalDefault)

        // Tier 2
        XCTAssertEqual(config.cloudDeadlineGraceSeconds, 5)
        XCTAssertEqual(config.cloudMaxRetries, 1)
        XCTAssertEqual(config.cloudBatchMaxStrings, 12)
        XCTAssertEqual(config.cloudBatchMaxCharacters, 1200)
        XCTAssertEqual(config.sceneTextMaxLength, 120)
        XCTAssertEqual(config.translationMaxLengthRatio, 4.0)
        XCTAssertEqual(config.translationMaxLengthAllowance, 64)

        // Cache
        XCTAssertEqual(config.cacheGeneralEntryLimit, 200)
        XCTAssertTrue(config.cacheTouchCoalescing)

        // Disclosure
        XCTAssertFalse(config.disclosureVersion.isEmpty)

        // The resource rework (2026-09-17). The device's own crash reports are
        // the parameter table for these: two `cpu_resource_fatal` kills at
        // ~99% CPU over 49 s and footprints of 1.4 GB, with the hottest stack
        // in the vision runtime and a 4B brain resident behind it.
        XCTAssertEqual(config.frameSignatureSide, 64)
        XCTAssertEqual(config.frameChangeThreshold, 0.02)
        XCTAssertEqual(config.stableSampleInterval, 0.7)
        XCTAssertEqual(config.stalePassesBeforeReducedCadence, 3)
        XCTAssertEqual(config.trackingMaxRectanglesPerPass, 6)
        XCTAssertEqual(config.brainTranslationIdleUnloadSeconds, 5)
        XCTAssertEqual(config.brainTranslationHeadroomFactor, 1.0)
        XCTAssertTrue(config.brainTranslationDefersToResidentBrain)
    }

    /// The resource knobs have to be *knobs*: a device that idles differently,
    /// or a scene that changes faster than these assume, is tuned by changing
    /// one value and not by editing the components.
    func testTheResourceBoundsAreConfigurableAndNotLiterals() {
        var config = LiveTranslateConfig.default
        config.stableSampleInterval = 1.5
        config.frameChangeThreshold = 0.05
        config.stalePassesBeforeReducedCadence = 5
        config.trackingMaxRectanglesPerPass = 2
        config.brainTranslationIdleUnloadSeconds = 1
        config.brainTranslationHeadroomFactor = 1.5
        config.brainTranslationDefersToResidentBrain = false

        XCTAssertNotEqual(config, LiveTranslateConfig.default)
        XCTAssertEqual(config.stableSampleInterval, 1.5)
        XCTAssertEqual(config.trackingMaxRectanglesPerPass, 2)
    }

    /// The brain stage's deadline is derived from the two values that own it,
    /// the same shape the cloud deadline has — so a caller that bounds its
    /// wait cannot drift from the timeout the generation was given.
    func testTheBrainStageDeadlineIsDerivedFromTheTwoOwnedValues() {
        let config = LiveTranslateConfig.default
        XCTAssertEqual(config.brainTranslationStageDeadlineSeconds,
                       config.brainTranslationTimeoutSeconds + config.brainTranslationStageGraceSeconds)
        XCTAssertEqual(config.brainTranslationStageDeadlineSeconds, 28)
        XCTAssertGreaterThan(config.brainTranslationStageDeadlineSeconds,
                             config.brainTranslationTimeoutSeconds,
                             "the stage must outlive the generation's own timeout, or the "
                             + "timeout's report would never be the one that lands")
    }

    /// The reduced cadence is a bound on idling: a value at or under the
    /// nominal cadence would make it a no-op, and a value at or over the
    /// snapshot's refresh would make the still scene stop being refreshed.
    func testTheReducedCadenceIsSlowerThanTheNominalOneAndFinite() {
        let config = LiveTranslateConfig.default
        XCTAssertGreaterThan(config.stableSampleInterval, config.ocrSampleInterval,
                             "the reduced cadence has to be slower than the nominal one to mean anything")
    }

    func testDefaultIsTheDocumentedNominalValueBundle() {
        XCTAssertEqual(LiveTranslateConfig.default, LiveTranslateConfig())
    }

    // MARK: Scenario: the cloud base timeout has exactly one source of truth

    func testCloudBaseTimeoutIsTheShippedClientConfigAndIsNotDuplicated() {
        XCTAssertEqual(LiveTranslateConfig.default.cloudRequestTimeout,
                       GeminiClient.Config.default.timeoutSeconds,
                       "the client's config is the one owner of the base timeout")
        XCTAssertEqual(LiveTranslateConfig.default.cloudRequestTimeout, 25)
    }

    func testCloudDeadlineIsDerivedFromTheTwoOwnedValues() {
        let config = LiveTranslateConfig.default
        XCTAssertEqual(config.cloudDeadlineSeconds,
                       config.cloudRequestTimeout + config.cloudDeadlineGraceSeconds)
        XCTAssertEqual(config.cloudDeadlineSeconds, 30)
    }

    /// The derived property has no setter surface of its own: the only way to
    /// change it is to change the shipped client's config, which is what the
    /// design's change-requires column says.
    func testTheRequestTimeoutCannotBeGivenASecondDivergentValue() {
        var config = LiveTranslateConfig.default
        config.cloudMaxRetries = 0
        // `cloudRequestTimeout` is computed, so it tracks the shipped client
        // config through any mutation of the feature's own config.
        XCTAssertEqual(config.cloudRequestTimeout, GeminiClient.Config.default.timeoutSeconds)
        XCTAssertEqual(config, LiveTranslateConfig(cloudMaxRetries: 0))
    }

    // MARK: The camera quality knobs (owner report, 2026-09-17)

    /// The zoom, lens-switching and focus defaults, in one place. The owner's
    /// report is "blurry and not sharp enough for small packaging text", so
    /// the shipped values are the *sharper* ones: the bigger frame, the wide
    /// camera's native view as the floor, and the near-range focus search on.
    func testTheCameraQualityDefaultsAreTheShippedOnes() {
        let config = LiveTranslateConfig.default

        XCTAssertEqual(config.cameraQuality, .high)
        XCTAssertEqual(config.minVideoZoom, 1.0)
        XCTAssertEqual(config.maxVideoZoom, 8.0)
        XCTAssertEqual(config.initialVideoZoom, 1.0)
        XCTAssertEqual(config.zoomStep, 0.5)
        XCTAssertEqual(config.zoomSwitchSnapTolerance, 0.08)

        // The zoom keys are in the *readout's* unit — the numbers the elder
        // reads, which are the numbers the system camera prints for the same
        // lens — and the shipped floor is the wide camera's own view: 0.5 there
        // is the ultra-wide, which is the worst of the three lenses for a line
        // of small print. The conversion into the device's factors is the
        // model's (`LiveCameraZoomModelTests`).
        XCTAssertGreaterThanOrEqual(config.minVideoZoom, 1.0,
                                    "the floor is the wide camera's view, never the ultra-wide")

        XCTAssertEqual(config.focusPointOfInterest, CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(config.focusNearRangeRestriction,
                      "the owner's report is small print on a packet held close: the near range is where it is")
        XCTAssertFalse(config.smoothAutoFocus,
                       "a smooth focus is an unhurried focus; reading a label is not video")
        XCTAssertFalse(config.focusLockDefault,
                       "the camera searches until the elder says hold still")
        XCTAssertTrue(config.subjectAreaChangeMonitoring)
        XCTAssertTrue(config.automaticVideoHDR,
                      "HDR keeps highlights on a glossy packet from swallowing dark type")
    }

    /// The values have to be *coherent*, not merely present: a range that runs
    /// backwards, a step that is not a step or a focus point outside the
    /// device's own normalized space is a configuration defect no test of one
    /// number would catch.
    func testTheZoomAndFocusDefaultsAreInternallyCoherent() {
        let config = LiveTranslateConfig.default

        XCTAssertLessThan(config.minVideoZoom, config.maxVideoZoom,
                          "an upside-down range traps the model's clamp")
        XCTAssertGreaterThan(config.zoomStep, 0, "a zero step is a dead control")
        XCTAssertLessThanOrEqual(config.zoomStep, config.maxVideoZoom - config.minVideoZoom,
                                 "a step larger than the whole range is not a step")
        XCTAssertTrue((config.minVideoZoom...config.maxVideoZoom).contains(config.initialVideoZoom),
                      "the session must open inside the range it will be held to")
        XCTAssertGreaterThan(config.zoomSwitchSnapTolerance, 0,
                             "0 would make the release-snap to a lens switch-over a no-op")
        XCTAssertLessThan(config.zoomSwitchSnapTolerance, 1,
                          "1 would snap every release onto the nearest switch, however far")
        for axis in ["x", "y"] {
            let value = axis == "x" ? config.focusPointOfInterest.x : config.focusPointOfInterest.y
            XCTAssertTrue((0...1).contains(value),
                          "a device point is normalized: \(axis) is \(value), outside 0...1")
        }
    }

    /// The knobs are knobs: a household with a different phone, or an owner who
    /// wants the ultra-wide's field of view, changes one value here and not an
    /// expression in a component.
    func testTheCameraQualityKnobsAreConfigurableAndNotLiterals() {
        var config = LiveTranslateConfig.default
        config.cameraQuality = .standard
        config.minVideoZoom = 0.5
        config.maxVideoZoom = 4
        config.initialVideoZoom = 2
        config.zoomStep = 0.25
        config.zoomSwitchSnapTolerance = 0.02
        config.focusPointOfInterest = CGPoint(x: 0.25, y: 0.25)
        config.focusNearRangeRestriction = false
        config.smoothAutoFocus = true
        config.focusLockDefault = true
        config.subjectAreaChangeMonitoring = false
        config.automaticVideoHDR = false

        XCTAssertNotEqual(config, LiveTranslateConfig.default)
        XCTAssertEqual(config.minVideoZoom, 0.5)
        XCTAssertEqual(config.zoomStep, 0.25)
        XCTAssertEqual(config.focusPointOfInterest, CGPoint(x: 0.25, y: 0.25))
        XCTAssertFalse(config.automaticVideoHDR)
    }

    // MARK: OD7 — the cost cap is not owned here

    /// Mirror-based, so it fails if a second cap is added under any name:
    /// the design is explicit that `GeminiCostGovernor.softDailyCap` is
    /// consumed as shipped and this feature adds no cap of its own (OD7).
    func testNoCostCapIsOwnedByThisFeature() {
        let offenders = Mirror(reflecting: LiveTranslateConfig.default)
            .children
            .compactMap(\.label)
            .filter { $0.lowercased().contains("cap") }
        XCTAssertEqual(offenders, [],
                       "the cost cap stays the shipped family-editable governor's (OD7)")
    }

    /// There is no user-facing configuration surface in v1: every member is a
    /// plain stored constant or a derived property — no UI binding type, no
    /// publisher, no observation.
    func testTheConfigIsAPlainValueTypeWithNoIOSurface() {
        let mirror = Mirror(reflecting: LiveTranslateConfig.default)
        XCTAssertGreaterThan(mirror.children.count, 20,
                             "the value owns the feature's whole constant set")
        for child in mirror.children {
            let type = String(describing: type(of: child.value))
            XCTAssertFalse(type.contains("Publisher"), "unexpected UI surface: \(type)")
            XCTAssertFalse(type.contains("Observable"), "unexpected UI surface: \(type)")
        }
    }

    /// Value semantics: a component that mutates its injected copy cannot
    /// move `default` under every other component's feet.
    func testMutatingACopyDoesNotChangeTheSharedDefault() {
        var copy = LiveTranslateConfig.default
        copy.ocrSampleInterval = 9.0
        copy.thermalStateThreshold = .critical
        XCTAssertEqual(LiveTranslateConfig.default.ocrSampleInterval, 0.25)
        XCTAssertEqual(LiveTranslateConfig.default.thermalStateThreshold, .serious)
        XCTAssertNotEqual(copy, LiveTranslateConfig.default)
    }

    // MARK: The OCR-first rework (owner verdict, 2026-09-18)

    /// The recognition settings' defaults, pinned the same way the rest of the
    /// table is: "forget translation, it's doing very poor OCR" is answered by
    /// specific values, and a silent drift in any of them is the failure mode
    /// this test exists for.
    func testTheRecognitionDefaultsAreTheOnesTheOCRFirstReworkChose() {
        let config = LiveTranslateConfig.default

        XCTAssertTrue(config.ocrAppliesLanguageCorrection,
                      "the recognizer's language model is what turns a compound label "
                      + "read as two words back into the word that is printed")
        XCTAssertTrue(config.ocrAutomaticallyDetectsLanguage,
                      "the scene decides the language; the request is not held to English")
        XCTAssertEqual(config.ocrCorrectionLanguages, ["en-US"],
                       "read only when detection is unavailable: the fallback language")
        XCTAssertEqual(config.ocrMinimumTextHeight, 0,
                       "no floor: a fraction-of-image floor is exactly what makes small print "
                       + "invisible to the pass, which is the complaint")
        XCTAssertTrue(config.ocrUsesLabelVocabulary)
        XCTAssertTrue(config.ocrLargeTextRetryEnabled)
        XCTAssertTrue(config.extractModeDefault,
                      "a session opens showing the recognized text (owner verdict, 2026-09-18)")
    }

    /// The vocabulary is *derived*, from the two sources that own words: the
    /// curated dictionary's keys and the packaging supplement. It is not a
    /// second copy of either, so this test reads the same sources the config
    /// does and fails the moment the list stops tracking them.
    func testTheLabelVocabularyTracksTheCuratedDictionaryPlusThePackagingSupplement() {
        let vocabulary = LiveTranslateConfig.labelVocabulary

        XCTAssertFalse(vocabulary.isEmpty)
        XCTAssertEqual(vocabulary, vocabulary.sorted(), "one canonical order, so two builds agree")
        XCTAssertEqual(Set(vocabulary).count, vocabulary.count, "no word is listed twice")

        for key in ApplianceLabelLocalizer.dictionary.keys {
            XCTAssertTrue(vocabulary.contains(key),
                          "\"\(key)\" is printed on an appliance's face and is in the curated "
                          + "table; the recognizer's vocabulary must carry it")
        }
        for word in LiveTranslateConfig.packagingVocabulary {
            XCTAssertTrue(vocabulary.contains(word))
            XCTAssertFalse(ApplianceLabelLocalizer.dictionary.keys.contains(word),
                           "\"\(word)\" is in the supplement only because the dictionary does "
                           + "not carry it")
        }

        // The switch is a real switch: off means the engine is handed no words
        // rather than the engine deciding what to do with them.
        var off = LiveTranslateConfig.default
        off.ocrUsesLabelVocabulary = false
        XCTAssertTrue(off.ocrVocabulary.isEmpty)
        XCTAssertEqual(LiveTranslateConfig.default.ocrVocabulary, vocabulary)

        // The dictionary is read, never written: a key added to it flows
        // through both the vocabulary and the recognizer with no second edit.
        XCTAssertTrue(LiveTranslateConfig.labelVocabulary.contains("defrost"),
                      "the owner's own example of a word the pass must get right")
    }
}
