import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// T-098: the shared address-as input's data seams.
///
/// `AddressAsPresets` is pure data and is pinned here term-for-term: a
/// chip's term IS the stored term (ADR-05 / FR-PI-010) — the presets are
/// never routed through the catalog. The free-text clamp is exercised
/// through `ProfileText.clamped` at the field's own bound
/// (`ProfileEntryBounds.default.addressAsMaxGraphemes`), Devanagari
/// conjunct fixture included.
///
/// The chip target scenario has no view-introspection harness in this
/// target (no snapshot library): the chips frame themselves with
/// `DesignTokens.minTapTargetSize` in BOTH axes and label themselves with
/// the term (`AddressAsField.chip(_:)` — asserted by inspection in the
/// implementation notes), so the constant chain is pinned here and the
/// 44 pt application is a code-inspection obligation.
final class AddressAsFieldTests: XCTestCase {

    // MARK: - Presets are data, per language (Scenario: chips write data)

    func testTheNepaliSetIsTheShippedDataSet() {
        XCTAssertEqual(AddressAsPresets.terms(for: "ne"),
                       ["आमा", "ममी", "बुबा", "दाइ", "दिदी",
                        "बजै", "हजुरबुबा", "हजुरआमा"])
    }

    func testTheEnglishSetIsTheShippedDataSet() {
        XCTAssertEqual(AddressAsPresets.terms(for: "en"),
                       ["Mum", "Mom", "Dad", "Grandma", "Grandpa"])
    }

    func testAnUnknownLanguageFallsBackToTheEnglishSet() {
        for code in ["fr", "new", ""] {
            XCTAssertEqual(AddressAsPresets.terms(for: code),
                           AddressAsPresets.terms(for: "en"),
                           "unknown code \(code.isEmpty ? "<empty>" : code) "
                           + "falls back to the en set")
        }
    }

    func testEveryPresetTermSurvivesTheFieldsOwnClampVerbatim() {
        // A chip can never write a value the free-text bound would clamp:
        // every shipped term is within the bound and clamps to itself.
        let bound = ProfileEntryBounds.default.addressAsMaxGraphemes
        for code in ["ne", "en"] {
            for term in AddressAsPresets.terms(for: code) {
                XCTAssertLessThanOrEqual(term.count, bound,
                                         "\(term) exceeds the bound")
                XCTAssertEqual(ProfileText.clamped(term, maxGraphemes: bound),
                               term,
                               "a chip writes its term verbatim")
            }
        }
    }

    // MARK: - Free-text clamp on grapheme boundaries (Scenario: R10)

    /// क्ष (KA + VIRAMA + SSA) is a single Character — the exact cluster
    /// shape R10 protects. 28 of them must clamp to 24 WHOLE clusters.
    func testTheFieldBoundClampsOnCharacterBoundaries() {
        let conjunct = "\u{0915}\u{094D}\u{0937}"
        let term = String(repeating: conjunct, count: 28)
        XCTAssertEqual(term.count, 28, "28 single-Character clusters")

        let clamped = ProfileText.clamped(
            term, maxGraphemes: ProfileEntryBounds.default.addressAsMaxGraphemes)

        XCTAssertEqual(clamped.count, 24)
        XCTAssertEqual(clamped, String(repeating: conjunct, count: 24),
                       "no cluster is ever split by the clamp")
        XCTAssertEqual(clamped.unicodeScalars.last?.value, 0x0937,
                       "the value ends on the SSA, never on a dangling virama")
    }

    func testTheBoundIsExactAndTolerantBelowIt() {
        let bound = ProfileEntryBounds.default.addressAsMaxGraphemes
        let exact = String(repeating: "अ", count: bound)
        XCTAssertEqual(ProfileText.clamped(exact, maxGraphemes: bound), exact,
                       "an exact-bound value is untouched")
        XCTAssertEqual(ProfileText.clamped("", maxGraphemes: bound), "")
        let over = exact + "अ"
        XCTAssertEqual(ProfileText.clamped(over, maxGraphemes: bound), exact,
                       "one past the bound drops exactly the last Character")
    }

    // MARK: - The tap target the chips are framed with (Scenario: 44 pt)

    func testTheChipTapTargetConstantIsAtLeastFortyFourPoints() {
        // `AddressAsField.chip(_:)` sets
        // `.frame(minWidth: DesignTokens.minTapTargetSize,
        //        minHeight: DesignTokens.minTapTargetSize)`,
        // so the 44 pt floor holds in both axes exactly when this holds.
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
    }
}
