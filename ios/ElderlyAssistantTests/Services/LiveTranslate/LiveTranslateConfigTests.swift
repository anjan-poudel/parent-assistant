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
        // The reading consensus (owner device report, 2026-09-19): the number
        // of consecutive passes a new reading must be seen in before it is the
        // region's reading, and the confidence gain that lets an unmistakably
        // better reading through without waiting. The first is the same 2 the
        // appearance hysteresis uses, and for the same reason — one pass is a
        // claim about the recognition, not about the sign; the second is the
        // width of "substantially surer", and it is pinned because a run of
        // readings that differ by a hundredth must not be able to switch the
        // reading on confidence alone.
        XCTAssertEqual(config.readingConsensusPasses, 2)
        XCTAssertEqual(config.readingConfidenceGain, 0.15)

        // The dispatch pacing (owner device report, 2026-09-19): the window a
        // burst of pending strings accumulates inside before it is dispatched
        // as one batch, and the window a brain generation is spaced by. Pinned
        // because both are read as escape hatches by the suites — the pipeline
        // harness zeroes them so its scenarios are about content and order, not
        // about waiting — so the shipped values have to be asserted somewhere,
        // and this is that place.
        XCTAssertEqual(config.translationDispatchMinInterval, 1.5)
        XCTAssertEqual(config.brainAttemptMinInterval, 8)

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

    /// The green highlight's three values (owner spec, 2026-09-18: "the
    /// bounding box can be TRANSPARENT GREEN with DARK COLORED TEXT … stabilise
    /// the overlay"). Pinned, because each one is a look the owner approved on
    /// a device rather than a number that can drift: how heavy the wash is, how
    /// much air the detected text is given around it, and how far the drawn box
    /// travels toward a new measurement on each frame.
    func testTheGreenHighlightDefaultsAreTheOwnersNumbers() {
        let config = LiveTranslateConfig.default

        XCTAssertEqual(config.overlayHighlightOpacity, 0.4,
                       "two fifths green: the print underneath still reads through it")
        XCTAssertEqual(config.overlayHighlightPadding, 5,
                       "the owner's 'small padding ~5pt' around the detected text")
        XCTAssertEqual(config.overlayBoxLerpFactor, 0.3,
                       "three tenths of the remaining distance per frame: a glide, not a landing")
        // Bands, not just pins: each is the range in which the look still works,
        // and a device check may move its value inside one.
        XCTAssertGreaterThanOrEqual(config.overlayHighlightOpacity, 0.25,
                                    "below this the box stops reading as a highlight at arm's length")
        XCTAssertLessThanOrEqual(config.overlayHighlightOpacity, 0.5,
                                 "above this the wash starts to bury the printed text")
        XCTAssertGreaterThanOrEqual(config.overlayHighlightPadding, 3)
        XCTAssertLessThanOrEqual(config.overlayHighlightPadding, 8,
                                 "more than this and the box stops hugging the words it is about")
        XCTAssertGreaterThan(config.overlayBoxLerpFactor, 0)
        XCTAssertLessThan(config.overlayBoxLerpFactor, 1,
                          "1 is the jump the rework removed; 0 freezes a box mid-flight")
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
        config.brainTranslationCriticalPressureWindowSeconds = 5

        XCTAssertNotEqual(config, LiveTranslateConfig.default)
        XCTAssertEqual(config.stableSampleInterval, 1.5)
        XCTAssertEqual(config.trackingMaxRectanglesPerPass, 2)
    }

    /// [PRESSURE-SAFE LOAD] The window a `.critical` keeps refusing loads in,
    /// after the kernel has gone quiet — the third case the pressure level
    /// cannot express on its own.
    ///
    /// The number is deliberately between two facts: the forensic capture of
    /// 2026-09-19 died about five seconds after its first critical, so the
    /// window has to cover "the kill is being decided" rather than only "the
    /// level is critical"; and a device that has recovered must not be
    /// refusing loads for the rest of the session, which is why it is not
    /// minutes. It lives in the config because it is a resource bound like the
    /// others (`testTheResourceBoundsAreConfigurableAndNotLiterals`), not a
    /// literal at the comparison site.
    func testTheCriticalPressureWindowIsThirtySeconds() {
        XCTAssertEqual(LiveTranslateConfig.default.brainTranslationCriticalPressureWindowSeconds, 30)
        XCTAssertGreaterThan(
            LiveTranslateConfig.default.brainTranslationCriticalPressureWindowSeconds,
            LiveTranslateConfig.default.brainTranslationIdleUnloadSeconds,
            "the window outlives the idle unload: a handle released on idle is not a device "
            + "that stopped being starved")
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

    /// The picture's own stabilization (owner device verdict, 2026-09-18:
    /// "the text is still shaky and jittery and unstable — STABILISE THE IMAGE
    /// FIRST"). Pinned, and pinned *coherently*: the four numbers are one
    /// mechanism, and a household that changes one has to keep the mechanism
    /// working. The relations below are the ones that make it a stabilizer —
    /// a dead zone wider than the window's travel cannot be absorbed, a reject
    /// threshold inside the travel would re-anchor on every deliberate pan, and
    /// a follow factor of 1 leaves no motion for the elder to see.
    func testTheFrameStabilizationDefaultsAreTheOwnersNumbers() {
        var config = LiveTranslateConfig.default

        XCTAssertTrue(config.frameStabEnabled)
        XCTAssertEqual(config.frameStabDeadZone, 0.01)
        XCTAssertEqual(config.frameStabFollowFactor, 0.4)
        XCTAssertEqual(config.frameStabMargin, 0.03)
        XCTAssertEqual(config.frameStabRejectDelta, 0.2)
        XCTAssertEqual(config.frameStabAnchorSeconds, 2.0)
        XCTAssertEqual(config.frameStabRegistrationSide, 256)

        XCTAssertGreaterThan(config.frameStabDeadZone, 0,
                             "a zero dead zone is a stabilizer with nothing to absorb")
        XCTAssertLessThanOrEqual(config.frameStabDeadZone, config.frameStabMargin,
                                 "a tremor wider than the window's travel cannot be absorbed")
        XCTAssertGreaterThan(config.frameStabFollowFactor, 0)
        XCTAssertLessThan(config.frameStabFollowFactor, 1,
                          "1 follows a deliberate movement exactly, which is no motion at all")
        XCTAssertGreaterThan(config.frameStabMargin, 0)
        XCTAssertLessThan(config.frameStabMargin, 0.25,
                          "a window inset this far is a different picture, not the same one held still")
        XCTAssertGreaterThan(config.frameStabRejectDelta, config.frameStabMargin,
                             "a threshold inside the travel would re-anchor on every deliberate pan")
        XCTAssertGreaterThan(config.frameStabAnchorSeconds, 0,
                             "an anchor taken and replaced in the same instant measures nothing")
        XCTAssertGreaterThanOrEqual(config.frameStabRegistrationSide, 32,
                                    "below this there is no texture left to register")

        // The policy is the config's own numbers, read in the estimator's
        // vocabulary — not a second set of defaults living beside it.
        let policy = FrameStabilizationPolicy(config: config)
        XCTAssertEqual(policy.deadZone, config.frameStabDeadZone)
        XCTAssertEqual(policy.followFactor, config.frameStabFollowFactor)
        XCTAssertEqual(policy.margin, config.frameStabMargin)
        XCTAssertEqual(policy.rejectDelta, config.frameStabRejectDelta)

        // A key outside the range the law can honour arrives clamped rather than
        // trusted: the window is geometry, and a margin of three frames is not.
        config.frameStabMargin = 3
        config.frameStabFollowFactor = 4
        config.frameStabDeadZone = -1
        let clamped = FrameStabilizationPolicy(config: config)
        XCTAssertLessThanOrEqual(clamped.margin, 0.25)
        XCTAssertLessThanOrEqual(clamped.followFactor, 1)
        XCTAssertEqual(clamped.deadZone, 0)
    }

    /// The stabilization's knobs are knobs, and they are the *resource* knobs'
    /// neighbours: a device that cannot afford the extra pass turns the feature
    /// off or shrinks the buffer, and neither of those needs a code change.
    func testTheFrameStabilizationKnobsAreConfigurableAndNotLiterals() {
        var config = LiveTranslateConfig.default
        config.frameStabEnabled = false
        config.frameStabDeadZone = 0.02
        config.frameStabFollowFactor = 0.5
        config.frameStabMargin = 0.05
        config.frameStabRejectDelta = 0.3
        config.frameStabAnchorSeconds = 3
        config.frameStabRegistrationSide = 128

        XCTAssertNotEqual(config, LiveTranslateConfig.default)
        XCTAssertFalse(FrameStabilizationPolicy(config: config).enabled)
        XCTAssertEqual(FrameStabilizationPolicy(config: config).registrationSide, 128)
        XCTAssertEqual(config.frameStabAnchorSeconds, 3)
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

    // MARK: Tier 1's model list, newest first (round-2b ship, 2026-09-18)

    /// The list is `installedModel()`'s whole input (`first { isAvailable }`),
    /// so its ORDER is the ship decision: the round-2b EN→NE translation
    /// fine-tune leads, and the two pre-translation brains stay as the
    /// fallbacks a device that has one but not the head keeps working on.
    func testTheTranslationListLeadsWithTheShippedTranslationModel() {
        let ids = LiveTranslateConfig.default.brainTranslationModelIDs
        XCTAssertEqual(ids, [ModelCatalog.nmtEnNeQwen17bR2bQ4,
                             ModelCatalog.nmtEnNeQwen17bR2bQ8,
                             ModelCatalog.intentQwen4BSlotCanon,
                             ModelCatalog.intentQwen4BS43],
                       "the Q5 test quant leads (owner device test, 2026-09-19), "
                       + "then the Q8 ship quant; the intent brains stay behind "
                       + "as fallbacks")
        // A list is only a list if every entry can be resolved — an id with
        // no catalog entry can never be installed and would silently be a
        // hole in the order.
        for id in ids {
            XCTAssertNotNil(ModelCatalog.entry(for: id),
                            "\(id.rawValue) is in the tier list but not in "
                            + "the catalog")
        }
        // The head is a TRANSLATION model, not an assistant brain: it must
        // never be offered to `LlamaCommandInterpreter`'s picker, whose
        // prompt this artifact was not trained on.
        XCTAssertFalse(ModelCatalog.availableBrainEntries.contains {
            $0.id == ModelCatalog.nmtEnNeQwen17bR2bQ8
        }, "the translation model is not an assistant-brain choice")
    }

    /// The shipped artifact itself: the digest the 1.83 GB download is
    /// verified against (`ModelStore.finalize` fails on any other bytes), the
    /// exact release asset, and the single-file delivery. A drift in any of
    /// these ships a model nobody can install (2026-09-14's 18-byte
    /// "reassembly" is the precedent for pinning the URL, not just the id).
    func testTheShippedTranslationArtifactIsPinned() throws {
        let entry = try XCTUnwrap(
            ModelCatalog.entry(for: ModelCatalog.nmtEnNeQwen17bR2bQ8),
            "the tier's head model must exist in the catalog")
        XCTAssertEqual(ModelCatalog.nmtEnNeQwen17bR2bQ8.rawValue,
                       "nmt-en-ne-qwen17b-r2b-q8_0")
        XCTAssertEqual(entry.kind, .llamaBase)
        XCTAssertEqual(entry.filename, "translate-en-ne-qwen17b-r2b-q8_0.gguf")
        XCTAssertEqual(entry.sizeBytes, 1_834_426_080,
                       "the shipped round-2b Q8_0 artifact's size on disk")
        XCTAssertEqual(entry.sha256,
                       "cae02965ab261a16fd375de12ecc012a1138d0f589fd74386b14aa058b2690b3",
                       "the server original and the release asset agree on "
                       + "this digest — the downloader verifies it")
        XCTAssertEqual(entry.sha256.count, 64)
        XCTAssertNotEqual(entry.sha256, ModelCatalogEntry.pendingSHA256,
                          "a placeholder can only ever fail `finalize`")
        XCTAssertEqual(entry.minDeviceRAMBytes, 4_000_000_000,
                       "the same 4 GB floor the other >1 GB brains carry")
        XCTAssertEqual(entry.languages, ["ne"])
        XCTAssertNil(entry.dependsOn)

        // The asset is ONE file: 1.83 GB is under GitHub's 2 GiB per-asset
        // cap, so there is nothing for the multipart path to reassemble.
        XCTAssertLessThan(Int64(entry.sizeBytes), 2_147_483_648,
                          "over the cap the release would need part assets")
        XCTAssertNil(entry.downloadPartURLs,
                     "a single-asset delivery must not carry part URLs")
        XCTAssertEqual(entry.downloadURL.absoluteString,
                       "https://github.com/anjan-poudel/elderly-ai-assistant-models"
                       + "/releases/download/v18/translate-en-ne-qwen17b-r2b-q8_0.gguf",
                       "the release the artifact was published to (v18)")
        XCTAssertEqual(entry.downloadURL.lastPathComponent, entry.filename,
                       "the asset name is the on-disk name, so "
                       + "`LlamaBrainTextGenerator.modelID(forURL:)` resolves "
                       + "the id from the installed file")
    }

    /// The head's admission — which phones can run the model this list
    /// leads with — is a policy verdict, and it is pinned where the policy
    /// lives: `ModelBudgetPolicyTests`
    /// (`testTheTranslationBrainIsOverTheStandardClassAndAdmittedOnlyOnRoomy`).
    /// The short version, because it is the reason this list has fallbacks
    /// at all: the 1.83 GB file takes the 3B weight band's 800 MB overhead
    /// (2.63 GB live), which is over the compact budget and over the
    /// standard budget beside a warm STT — so on a 6 GB phone the warden
    /// refuses the head's load and the strings go to the cloud tier.
    func testTheTranslationHeadsClassVerdictIsOutOfThisSuitesHands() {
        let head = ModelCatalog.entry(for: ModelCatalog.nmtEnNeQwen17bR2bQ8)!
        XCTAssertEqual(ModelLifecycleInventory
            .footprint(for: .translateBrain, modelID: head.id).liveBytes,
                       2_634_426_080,
                       "the arithmetic the policy verdicts are derived from")
        XCTAssertFalse(ModelBudgetPolicy.standard
            .availability(of: head, physicalMemoryBytes: 6_000_000_000)
            .isAvailable,
                       "a 6 GB phone does not run the head — see "
                       + "ModelBudgetPolicyTests for the reason")
        XCTAssertTrue(ModelBudgetPolicy.roomy
            .availability(of: head, physicalMemoryBytes: 8_000_000_000)
            .isAvailable)
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
        XCTAssertFalse(config.extractModeDefault,
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
