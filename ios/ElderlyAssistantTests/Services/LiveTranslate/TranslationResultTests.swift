import CoreGraphics
import XCTest
@testable import ElderlyAssistant

/// T-002 — truthful tier attribution and honest degradation are structural
/// (FR-LCT-008 as amended 2026-09-17, FR-LCT-018, NFR-LCT-010).
final class TranslationResultTests: XCTestCase {

    private let source = "फार्मेसी"

    // MARK: Scenario: a tier that did not translate cannot be named

    func testADegradedResultNamesNoTierAndHonestlyShowsTheOriginal() {
        for reason in TranslationUnavailableReason.allCases {
            let result = TranslationResult.degraded(originalText: source, reason: reason)
            XCTAssertNil(result.sourceTier,
                         "a tier that did not translate must not be nameable (\(reason))")
            XCTAssertTrue(result.degraded)
            XCTAssertTrue(result.isFinal)
            XCTAssertEqual(result.text, source, "the honest fallback is the original text")
            XCTAssertEqual(result.originalText, source)
        }
    }

    // MARK: Scenario: a pending region claims nothing

    func testAPendingResultClaimsNothing() {
        let result = TranslationResult.pending(source)
        XCTAssertEqual(result.outcome, .pending(originalText: source))
        XCTAssertNil(result.sourceTier)
        XCTAssertFalse(result.isFinal)
        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.text, source)
    }

    // MARK: Scenario: a resolved outcome names the tier that produced it

    func testAResolvedResultNamesTheTierThatActuallyProducedIt() {
        let result = TranslationResult.resolved(originalText: source,
                                                translation: "Pharmacy",
                                                tier: .dictionary)
        XCTAssertEqual(result.sourceTier, .dictionary)
        XCTAssertFalse(result.degraded)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.text, "Pharmacy")
        XCTAssertEqual(result.originalText, source)
    }

    func testACloudResolutionNamesTheCloudTierAndNotTheDictionary() {
        let result = TranslationResult(.resolved(originalText: source,
                                                 translation: "Pharmacy",
                                                 tier: .cloud))
        XCTAssertEqual(result.sourceTier, .cloud)
        XCTAssertNotEqual(result.sourceTier, .dictionary,
                          "tier attribution must be what happened, not what is convenient")
    }

    /// The accessors are computed from the enum: there is no second stored
    /// state that could disagree with it. Each expectation below is derived
    /// from the outcome **independently** of the type under test, so a stored
    /// cache added later would fail here rather than agreeing with itself.
    func testTheAccessorsAreDerivedFromTheOutcomeAlone() {
        let outcomes: [TranslationOutcome] = [
            .pending(originalText: source),
            .resolved(originalText: source, translation: "Pharmacy", tier: .dictionary),
            // The on-device brain is a tier that translated, so it names
            // itself through exactly the same accessors as the other two.
            .resolved(originalText: source, translation: "Pharmacy", tier: .onDeviceBrain),
            .resolved(originalText: source, translation: "Pharmacy", tier: .cloud),
            .degraded(originalText: source, reason: .noNetwork)
        ]
        for outcome in outcomes {
            let result = TranslationResult(outcome)

            let expectedText: String
            let expectedTier: TranslationTier?
            let expectedIsFinal: Bool
            let expectedDegraded: Bool
            switch outcome {
            case .pending(let text):
                expectedText = text; expectedTier = nil
                expectedIsFinal = false; expectedDegraded = false
            case .resolved(let text, let translation, let tier):
                expectedText = translation; expectedTier = tier
                expectedIsFinal = true; expectedDegraded = false
                _ = text
            case .degraded(let text, _):
                expectedText = text; expectedTier = nil
                expectedIsFinal = true; expectedDegraded = true
            }

            XCTAssertEqual(result.text, expectedText)
            XCTAssertEqual(result.sourceTier, expectedTier)
            XCTAssertEqual(result.isFinal, expectedIsFinal)
            XCTAssertEqual(result.degraded, expectedDegraded)
            XCTAssertEqual(result.originalText, source)
        }
    }

    // MARK: Scenario: the on-device tier exists, and only as a nameable result

    /// The amended vocabulary (FR-LCT-008, 2026-09-17): three tiers, one per
    /// source that can actually produce a translation. The ordinal rule is
    /// untouched — a tier is named, never numbered — and every case must be
    /// producible, because a case no code path can produce is the "stubbed
    /// deferred capability" the amendment still forbids.
    func testTheTierTypeHasExactlyThreeCasesOnePerProducingSource() {
        XCTAssertEqual(TranslationTier.allCases.count, 3)
        XCTAssertEqual(Set(TranslationTier.allCases), [.dictionary, .onDeviceBrain, .cloud])
        XCTAssertEqual(Set(TranslationTier.allCases.map(\.rawValue)),
                       ["dictionary", "onDeviceBrain", "cloud"])

        for raw in TranslationTier.allCases.map(\.rawValue) {
            XCTAssertFalse(raw.contains("tier"), "ordinals are prose, never a case: \(raw)")
            XCTAssertNil(Int(raw), "no ordinal tier number is reserved as a case: \(raw)")
            XCTAssertFalse(raw.lowercased().contains("nmt"),
                           "the tier is named for the app's brain, not for an NMT pipeline: \(raw)")
        }
        // Tier attribution is only worth anything if each case can be
        // produced by a real path: the dictionary by `ApplianceLabelLocalizer`
        // + the cache, the brain by `LocalBrainTranslationTier`, the cloud by
        // `CloudTranslationTier`. A case with no producer would be the
        // "stubbed deferred capability" this requirement still forbids, so the
        // brain tier's own suite drives all three end to end.
    }

    /// The renderer contract the owner fixed together with the tier's name: a
    /// brain translation is NOT curated, so it may never take the in-place
    /// form that replaces a sign's own text with an unvetted model output
    /// (FR-LCT-015, D1). Pinned here rather than left to the placement suite
    /// because it is a statement about the TIER — "the guard happens to
    /// exclude it today" is exactly what a later refactor removes.
    func testAnOnDeviceBrainTranslationIsNeverInPlaceEligible() {
        let policy = LiveTranslateOverlaySurface.policy(config: .default,
                                                        alwaysShowOriginal: false)
        let regionRect = CGRect(x: 0, y: 0, width: 400, height: 200)

        for tier in TranslationTier.allCases where tier != .dictionary {
            XCTAssertNotEqual(
                LiveOverlayPlacement.inPlaceEligibility(source: "Light",
                                                        translation: "बत्ती",
                                                        regionRect: regionRect,
                                                        policy: policy,
                                                        tier: tier),
                .eligible,
                "only the curated tier may replace a sign's text in place (\(tier))")
        }
        // …while the curated dictionary, the one tier that may, still may:
        // the guard above is a tier rule, not an unusually small rect.
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(source: "Light",
                                                              translation: "बत्ती",
                                                              regionRect: regionRect,
                                                              policy: policy,
                                                              tier: .dictionary),
                       .eligible)
    }

    // MARK: Scenario: state transitions are monotone

    func testAResolvedRegionNeverReturnsToPendingWhileItsTextIsUnchanged() {
        let resolved = TranslationResult.resolved(originalText: source,
                                                  translation: "Pharmacy",
                                                  tier: .dictionary)
        let republished = resolved.applying(.pending(originalText: source))
        XCTAssertEqual(republished, resolved, "a terminal outcome never flickers back to pending")
        XCTAssertFalse(republished.degraded)
        XCTAssertEqual(republished.sourceTier, .dictionary)
    }

    func testADegradedRegionNeverReturnsToPendingWhileItsTextIsUnchanged() {
        let degraded = TranslationResult.degraded(originalText: source, reason: .noNetwork)
        XCTAssertEqual(degraded.applying(.pending(originalText: source)), degraded)
    }

    func testATextChangeReplacesTheOutcomeRatherThanMergingWithIt() {
        let resolved = TranslationResult.resolved(originalText: source,
                                                  translation: "Pharmacy",
                                                  tier: .dictionary)
        let changed = resolved.applying(.pending(originalText: "खुला छ"))
        XCTAssertEqual(changed, TranslationResult.pending("खुला छ"))
        XCTAssertNotEqual(changed.sourceTier, .dictionary,
                          "the previous outcome is replaced, not merged")
        XCTAssertEqual(changed.text, "खुला छ")
    }

    func testPendingBecomesResolvedThroughTheSameTransition() {
        let pending = TranslationResult.pending(source)
        let resolved = pending.applying(.resolved(originalText: source,
                                                  translation: "Pharmacy",
                                                  tier: .cloud))
        XCTAssertEqual(resolved.sourceTier, .cloud)
        XCTAssertTrue(resolved.isFinal)
        XCTAssertFalse(resolved.degraded)
    }

    // MARK: The closed reason vocabulary

    func testTheUnavailableReasonVocabularyIsClosedAndStable() {
        let tokens = Set(TranslationUnavailableReason.allCases.map(\.rawValue))
        XCTAssertEqual(tokens, [
            "no_network",
            "provider_not_configured",
            "consent_not_granted",
            "cost_budget_exhausted",
            "provider_rejected",
            "text_quarantined",
            "deadline_exceeded",
            "no_tier_resolved"
        ])
    }

    /// The reason is a token, never upstream text: every raw value is a
    /// lower-case ASCII token with no whitespace.
    func testNoReasonCanCarryUpstreamText() {
        for reason in TranslationUnavailableReason.allCases {
            XCTAssertNotNil(reason.rawValue.range(of: "^[a-z_]+$", options: .regularExpression),
                            "\(reason.rawValue) is not a closed-vocabulary token")
        }
    }
}
