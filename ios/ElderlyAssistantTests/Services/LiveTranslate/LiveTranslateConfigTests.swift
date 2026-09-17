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

        // Decluttering (OD5), both re-tuned by the 2026-09-17 UX rework: a
        // wider merge (clustered same-string boxes become one overlay) and a
        // smaller cap (fewer, larger, stable elements on the glance surface).
        XCTAssertEqual(config.declutterMergeCentroidDistance, 0.12)
        XCTAssertEqual(config.declutterMaxRegions, 6)

        // Overlay (D1, OD2)
        XCTAssertEqual(config.inPlaceMinPointSize, 16)
        XCTAssertEqual(config.inPlaceMaxGrowth, 1.4)
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
}
