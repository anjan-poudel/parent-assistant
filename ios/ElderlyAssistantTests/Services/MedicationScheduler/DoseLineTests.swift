import XCTest
@testable import ElderlyAssistant

/// Dose-line composition (T-002 — FR-MSR-003; design-l2 C2, IF-5; L1 §4.6):
/// the four composition rules as a truth table, the localized unit label in
/// both shipped languages (ne resolves to Devanagari copy, differing from
/// en), the numeric determinism pin, the nil-quantity edge that invents
/// nothing, and the never-guess honesty for a stored unit token outside the
/// built-in set.
///
/// The pins below read `DoseLine.compose` — the pure composer the save path
/// (T-017) calls — and the exact en/ne unit labels the T-012 catalog ships,
/// resolved through the same `L10n.str` lproj path the app renders with. A
/// later unit-label wording change is a deliberate catalog edit, not drift:
/// these pins fail loudly, which is the point.
final class DoseLineTests: XCTestCase {

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    // MARK: - Rules 1 and 2

    /// Scenario: a stored quantity of 2 with a known dose unit — the line
    /// renders the value and the localized unit label, and the ne
    /// resolution differs from the en one (Devanagari, never copy-pasted
    /// English). Rule 2 keeps a non-blank dose text (a scanned strength)
    /// after the fixed separator.
    func testComposeRendersValueAndLocalizedUnit() {
        let quantity = MedicationQuantity(amount: 2, unit: "tablet")

        // Rule 1 — quantity only.
        let en = DoseLine.compose(quantity: quantity, doseText: "", locale: english)
        let ne = DoseLine.compose(quantity: quantity, doseText: "", locale: nepali)
        XCTAssertEqual(en, "2 tablet")
        XCTAssertEqual(ne, "2 चक्की")
        XCTAssertNotEqual(en, ne,
                          "the ne resolution must differ from the en one")
        XCTAssertTrue(Self.containsDevanagari(ne),
                      "the ne unit label is Devanagari catalog copy")
        XCTAssertTrue(en.contains("2"), "the stored value is rendered")
        XCTAssertTrue(ne.contains("2"))

        // The label comes from the catalog key through the shipped L10n
        // path — never a hardcoded literal. (If the key missed, `L10n.str`
        // would answer "" and the composer would fall back to the raw
        // token; this equality would fail.)
        XCTAssertEqual(String(en.dropFirst(2)),
                       L10n.str("meds.unit.tablet", locale: english))

        // Rule 1 trims: a blank (whitespace-only) dose text composes the
        // quantity alone — no dangling separator.
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "  \n ",
                                        locale: english),
                       "2 tablet")

        // Rule 2 — the scanned strength is kept after the fixed ", "
        // separator (design-l2 C2): nothing the family saw is dropped.
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "500 mg",
                                        locale: english),
                       "2 tablet, 500 mg")
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "500 mg",
                                        locale: nepali),
                       "2 चक्की, 500 mg")

        // Surrounding whitespace in the dose text trims (the shipped
        // save-path normalization: `storedStrength`,
        // `AppCoordinator.addMedication`).
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "  500 mg  ",
                                        locale: english),
                       "2 tablet, 500 mg")

        // Singular amount and another unit: the same two rules, two more
        // rows — en and ne both.
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 1, unit: "capsule"),
            doseText: "", locale: english), "1 capsule")
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 1, unit: "capsule"),
            doseText: "", locale: nepali), "1 क्याप्सुल")
    }

    // MARK: - Grammatical number

    /// The composer owns grammatical number, and its answer is pinned here:
    /// the shipped catalog holds ONE label per unit (T-012 pins exactly
    /// `meds.unit.tablet|…|sachet`; no plural variants exist in the file)
    /// and this unit may not hardcode user-visible copy, so the label
    /// renders verbatim at every amount and ONLY the numeral changes. A
    /// naive English suffix would corrupt the catalog's own abbreviation
    /// ("2 mls") and Nepali unit nouns take no suffix in this construction
    /// ("2 चक्की"); either defect fails this test loudly. A future plural
    /// form is a T-012 catalog edit resolved through the composer's one
    /// label seam — never morphology invented here.
    func testComposeSingularVersusPlural() {
        // The truth table: singular, plural and a larger count, both
        // languages — same label, numeral as stored.
        let rows: [(amount: Int, en: String, ne: String)] = [
            (1, "1 tablet", "1 चक्की"),
            (2, "2 tablet", "2 चक्की"),
            (10, "10 tablet", "10 चक्की"),
        ]
        for row in rows {
            let quantity = MedicationQuantity(amount: row.amount,
                                              unit: "tablet")
            XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                            doseText: "", locale: english),
                           row.en)
            XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                            doseText: "", locale: nepali),
                           row.ne)
        }

        // The singular and plural lines differ only by the numeral.
        let singular = DoseLine.compose(
            quantity: MedicationQuantity(amount: 1, unit: "tablet"),
            doseText: "", locale: english)
        let plural = DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "tablet"),
            doseText: "", locale: english)
        XCTAssertNotEqual(singular, plural)

        // The abbreviation a naive plural suffix corrupts stays intact:
        // the catalog ships "ml", and "ml" is what renders.
        let milliliters = DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "milliliter"),
            doseText: "", locale: english)
        XCTAssertEqual(milliliters, "2 ml")
        XCTAssertFalse(milliliters.hasSuffix("s"))

        // A corrupt stored 0 (positivity is the editor's validation; the
        // composer never repairs) renders as stored — never "1", never a
        // quantity-less line. Nothing is invented.
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 0, unit: "tablet"),
            doseText: "", locale: english), "0 tablet")
    }

    // MARK: - Determinism

    /// Scenario: composing the same quantity again yields the identical
    /// line. The composer reads no state, no clock and no store, so
    /// repetition, interleaving and separately constructed equal values
    /// all compose byte-identical lines — in both locales.
    func testComposeIsDeterministic() {
        let quantity = MedicationQuantity(amount: 3, unit: "capsule")
        let en = DoseLine.compose(quantity: quantity,
                                  doseText: "250 mg", locale: english)
        let ne = DoseLine.compose(quantity: quantity,
                                  doseText: "250 mg", locale: nepali)
        XCTAssertEqual(en, "3 capsule, 250 mg")
        XCTAssertEqual(ne, "3 क्याप्सुल, 250 mg")
        XCTAssertNotEqual(en, ne)

        // Repeated calls ride the same result.
        for _ in 0..<100 {
            XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                            doseText: "250 mg",
                                            locale: english), en)
        }

        // A separately constructed, equal value composes identically.
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 3, unit: "capsule"),
            doseText: "250 mg", locale: english), en)

        // Interleaving other composes — another quantity, the other
        // locale, the nil-quantity path — changes nothing about either
        // line.
        _ = DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "tablet"),
            doseText: "", locale: nepali)
        _ = DoseLine.compose(quantity: nil,
                             doseText: "half tablet", locale: english)
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "250 mg",
                                        locale: english), en)
        XCTAssertEqual(DoseLine.compose(quantity: quantity,
                                        doseText: "250 mg",
                                        locale: nepali), ne)
    }

    // MARK: - Rules 3 and 4

    /// Scenario: an entry saved without a quantity — the composer returns
    /// no line and nothing is invented or inferred: no default amount, no
    /// unit, no separator. A legacy free-text dose still renders verbatim
    /// (rule 3), in either language, unmodified.
    func testNilQuantityComposesNothing() {
        // Nothing stored → nothing composed.
        let nothing = DoseLine.compose(quantity: nil,
                                       doseText: "", locale: english)
        XCTAssertEqual(nothing, "")
        XCTAssertTrue(nothing.isEmpty)

        // Whitespace-only dose text is blank too (the shipped trim
        // convention): still no line — never a stray separator or a lone
        // numeral.
        XCTAssertEqual(DoseLine.compose(quantity: nil,
                                        doseText: "   \n ",
                                        locale: english), "")
        XCTAssertEqual(DoseLine.compose(quantity: nil,
                                        doseText: "\t",
                                        locale: nepali), "")

        // Rule 3: the family's own words are the line — "half tablet"
        // stays "half tablet", never "1 tablet", and no quantity context
        // is bolted on.
        let freeText = DoseLine.compose(quantity: nil,
                                        doseText: "half tablet",
                                        locale: english)
        XCTAssertEqual(freeText, "half tablet")
        XCTAssertNotEqual(freeText, "1 tablet")
        XCTAssertFalse(freeText.contains(","),
                       "no separator appears without a composed quantity")

        // Verbatim in either language: a stored free text is not
        // translated and is not re-composed under the ne locale either.
        XCTAssertEqual(DoseLine.compose(quantity: nil,
                                        doseText: "half tablet",
                                        locale: nepali), "half tablet")
        XCTAssertEqual(DoseLine.compose(quantity: nil,
                                        doseText: "आधा चक्की",
                                        locale: nepali), "आधा चक्की")
        XCTAssertEqual(DoseLine.compose(quantity: nil,
                                        doseText: "आधा चक्की",
                                        locale: english), "आधा चक्की")
    }

    // MARK: - Unknown stored unit

    /// A stored unit token outside the built-in set is the family's own
    /// words: rendered as-is, never mapped onto another unit, and never
    /// "fixed up" — case or plural near misses are free text too (exact
    /// match only, the chip-or-free-text precedent).
    func testUnknownStoredUnitRendersHonestly() {
        // A custom token renders verbatim, in both languages.
        let custom = MedicationQuantity(amount: 1, unit: "spoon")
        let en = DoseLine.compose(quantity: custom,
                                  doseText: "", locale: english)
        XCTAssertEqual(en, "1 spoon")
        XCTAssertFalse(en.contains("teaspoon"),
                       "a custom token is never mapped onto a built-in unit")
        XCTAssertFalse(en.contains("tablet"))
        XCTAssertFalse(en.contains("capsule"))
        XCTAssertEqual(DoseLine.compose(quantity: custom,
                                        doseText: "", locale: nepali),
                       "1 spoon",
                       "the family's own words are not translated")

        // A Devanagari custom token survives as typed.
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "डब्बी"),
            doseText: "", locale: nepali), "2 डब्बी")

        // Near misses are NOT mapped onto a case — matching is exact, so
        // these render as typed.
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "tablets"),
            doseText: "", locale: english), "2 tablets")
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "Tablet"),
            doseText: "", locale: english), "2 Tablet")

        // A built-in token renders its LOCALIZED label, never the stored
        // raw token (the raw value is a storage detail, not copy).
        let milliliters = DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "milliliter"),
            doseText: "", locale: english)
        XCTAssertEqual(milliliters, "2 ml")
        XCTAssertNotEqual(milliliters, "2 milliliter")
        XCTAssertEqual(DoseLine.compose(
            quantity: MedicationQuantity(amount: 2, unit: "milliliter"),
            doseText: "", locale: nepali), "2 मि.ली.")
    }

    // MARK: - Helpers

    /// The catalog's Nepali values are Devanagari (the coverage-suite
    /// convention): U+0900–U+097F.
    private static func containsDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }
}
