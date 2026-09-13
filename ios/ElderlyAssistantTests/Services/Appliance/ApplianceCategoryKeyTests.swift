import XCTest
@testable import ElderlyAssistant

/// `ApplianceCategoryKey` — the pure category normalizer the per-category
/// default manual keys on (2026-09-13, appliance-default-manual).
///
/// The stakes are asymmetric, so the map is pinned in BOTH languages: the
/// elder's word ("माइक्रोवेभ") and the vision prompt's category
/// ("microwave") MUST land on one key, while a near miss ("microwave
/// oven") must NOT fold onto a canonical one — a wrong fold would serve
/// the wrong appliance's manual.
final class ApplianceCategoryKeyTests: XCTestCase {

    // MARK: - English synonyms

    func testEnglishSynonymsFoldOntoTheirCanonicalKey() {
        XCTAssertEqual(ApplianceCategoryKey.normalize("microwave"), "microwave")
        XCTAssertEqual(ApplianceCategoryKey.normalize("tv"), "tv_remote",
                       "the elder says TV, the vision prompt says tv_remote — one category")
        XCTAssertEqual(ApplianceCategoryKey.normalize("television"), "tv_remote")
        XCTAssertEqual(ApplianceCategoryKey.normalize("tv_remote"), "tv_remote",
                       "the prompt's own spelling must survive the fold unchanged")
        XCTAssertEqual(ApplianceCategoryKey.normalize("washing machine"), "washing_machine")
        XCTAssertEqual(ApplianceCategoryKey.normalize("fridge"), "fridge")
        XCTAssertEqual(ApplianceCategoryKey.normalize("refrigerator"), "fridge")
        XCTAssertEqual(ApplianceCategoryKey.normalize("air conditioner"), "air_conditioner")
        XCTAssertEqual(ApplianceCategoryKey.normalize("ac"), "air_conditioner")
        XCTAssertEqual(ApplianceCategoryKey.normalize("stove"), "stove")
        XCTAssertEqual(ApplianceCategoryKey.normalize("rice cooker"), "rice_cooker")
    }

    // MARK: - Nepali synonyms

    func testNepaliSynonymsFoldOntoTheSameKeysAsEnglish() {
        XCTAssertEqual(ApplianceCategoryKey.normalize("माइक्रोवेभ"), "microwave")
        XCTAssertEqual(ApplianceCategoryKey.normalize("माइक्रोभेभ"), "microwave",
                       "the second in-use Devanagari spelling")
        XCTAssertEqual(ApplianceCategoryKey.normalize("टिभी"), "tv_remote")
        XCTAssertEqual(ApplianceCategoryKey.normalize("वासिङ मेसिन"), "washing_machine")
        XCTAssertEqual(ApplianceCategoryKey.normalize("वाशिङ मेसिन"), "washing_machine")
        XCTAssertEqual(ApplianceCategoryKey.normalize("फ्रिज"), "fridge")
        XCTAssertEqual(ApplianceCategoryKey.normalize("एयर कन्डिसन"), "air_conditioner")
        XCTAssertEqual(ApplianceCategoryKey.normalize("एसी"), "air_conditioner")
        XCTAssertEqual(ApplianceCategoryKey.normalize("ग्यास"), "stove")
        XCTAssertEqual(ApplianceCategoryKey.normalize("चुलो"), "stove")
        XCTAssertEqual(ApplianceCategoryKey.normalize("राइस कुकर"), "rice_cooker")
    }

    /// The meeting point of the whole feature: a manual saved for
    /// Gemini's "microwave" category must be found by a voice turn whose
    /// appliance entity is the elder's "माइक्रोवेभ".
    func testTheElderWordAndTheModelCategoryMeetOnOneKey() {
        XCTAssertEqual(ApplianceCategoryKey.normalize("माइक्रोवेभ"),
                       ApplianceCategoryKey.normalize("microwave"))
        XCTAssertEqual(ApplianceCategoryKey.normalize("टिभी"),
                       ApplianceCategoryKey.normalize("tv_remote"))
    }

    // MARK: - Case and whitespace

    func testCaseAndWhitespaceAreFoldedBeforeTheLookup() {
        XCTAssertEqual(ApplianceCategoryKey.normalize("MICROWAVE"), "microwave")
        XCTAssertEqual(ApplianceCategoryKey.normalize("  Washing   Machine  "), "washing_machine",
                       "internal runs of whitespace collapse, edges trim")
        XCTAssertEqual(ApplianceCategoryKey.normalize("Air\nConditioner"), "air_conditioner",
                       "a newline is whitespace like any other")
        XCTAssertEqual(ApplianceCategoryKey.normalize("टिभी "), "tv_remote",
                       "Devanagari has no case, but it still trims")
    }

    func testBlankAndNilNormalizeToNothingToKeyOn() {
        XCTAssertNil(ApplianceCategoryKey.normalize(nil))
        XCTAssertNil(ApplianceCategoryKey.normalize(""))
        XCTAssertNil(ApplianceCategoryKey.normalize("   \n\t "))
    }

    // MARK: - Unknown passthrough

    func testUnknownCategoriesPassThroughNormalized() {
        // A real category the map does not list (the vision prompt allows
        // "smart_hub") still gets a stable key that matches itself — the
        // default-manual rule keeps working for appliance types nobody
        // enumerated here.
        XCTAssertEqual(ApplianceCategoryKey.normalize("Smart  Hub"), "smart hub")
        XCTAssertEqual(ApplianceCategoryKey.normalize("SMART_HUB"), "smart_hub")
        XCTAssertEqual(ApplianceCategoryKey.normalize("  Toaster  "), "toaster")
    }

    func testUnknownCategoriesAreNeverFuzzyMatched() {
        // Deliberately NOT folded: guessing that "microwave oven" means
        // "microwave" is the kind of cleverness that eventually serves the
        // wrong appliance's manual. Unlisted spellings stay distinct until
        // someone adds them to the map on purpose.
        XCTAssertEqual(ApplianceCategoryKey.normalize("microwave oven"), "microwave oven")
        XCTAssertNotEqual(ApplianceCategoryKey.normalize("microwave oven"),
                          ApplianceCategoryKey.normalize("microwave"))
    }

    // MARK: - Default eligibility

    func testBlankAndOtherAreNotEligibleForDefaults() {
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible(nil))
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible(""))
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible("   "))
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible("other"),
                       "\"other\" is every unidentified appliance's bucket")
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible("OTHER"),
                       "case folds BEFORE the eligibility check")
        XCTAssertFalse(ApplianceCategoryKey.isDefaultEligible(" Other "))
    }

    func testRealCategoriesAreEligibleForDefaults() {
        XCTAssertTrue(ApplianceCategoryKey.isDefaultEligible("माइक्रोवेभ"))
        XCTAssertTrue(ApplianceCategoryKey.isDefaultEligible("tv"))
        XCTAssertTrue(ApplianceCategoryKey.isDefaultEligible("smart_hub"),
                      "an unlisted but REAL category still carries a default")
    }
}
