import XCTest
@testable import ElderlyAssistant

// [WEATHER-WORDING] The spoken-unit normalizer: raw temperature tokens
// from model free text become the words a synthesizer reads correctly
// (the "15c" field report). English convention: "degrees Celsius" (the
// short "degrees" once the scale is established); Nepali follows the
// house Devanagari-numeral convention (`BikramSambat.devanagariDigits` /
// `TopicPreAnswer`). String-level pins only — the pure formatter's
// contract.
//
// [AUDIT-SPOKEN] (2026-10-14) Extended with the two unit families the
// spoken-response mechanical-phrasing audit added to `SpokenUnits`:
// medication doses (HIGH-1 — "500 mg" was synthesized as "five hundred
// em gee") and general measures (MEDIUM-6 — feeds/news "kg", "500/kg",
// "km/h"). Both are applied to every spoken path by
// `SpokenTextNormalizer` at the speaker seam; the pins here are the
// functions' own contracts.

final class SpokenUnitsTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - The reported raw forms

    func testNormalizesEveryReportedRawForm() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15c outside.", locale: en),
                       "It's 15 degrees Celsius outside.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15C.", locale: en),
                       "It's 15 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15°C and clear.", locale: en),
                       "It's 15 degrees Celsius and clear.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15 °C.", locale: en),
                       "It's 15 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15 C.", locale: en),
                       "It's 15 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15.5c.", locale: en),
                       "It's 15.5 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15°c.", locale: en),
                       "It's 15 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15° C.", locale: en),
                       "It's 15 degrees Celsius.")
    }

    func testNegativeTemperaturesSurvive() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's -5°C.", locale: en),
                       "It's -5 degrees Celsius.")
        // The Unicode minus (U+2212) is preserved, never folded to a hyphen.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's −5°C.", locale: en),
                       "It's −5 degrees Celsius.")
    }

    func testFahrenheitAndSpelledShortForms() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15ºF.", locale: en),
                       "It's 15 degrees Fahrenheit.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15 degrees C.", locale: en),
                       "It's 15 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15 deg C.", locale: en),
                       "It's 15 degrees Celsius.")
        // "degrees Celsius" spelled out is already the spoken form.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It is 45 degrees.", locale: en),
                       "It is 45 degrees.")
    }

    /// A bare "°" carries no scale — the pass must never invent Celsius.
    func testBareDegreeDoesNotInventAScale() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15° outside.", locale: en),
                       "It's 15 degrees outside.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15°.", locale: en),
                       "It's 15 degrees.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15° and 20°C.", locale: en),
                       "It's 15 degrees and 20 degrees Celsius.")
    }

    func testScaleWordRepeatsOnlyOnFirstUse() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15°C now, 10°C tonight.", locale: en),
                       "It's 15 degrees Celsius now, 10 degrees tonight.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "15°C and 15°C.", locale: en),
                       "15 degrees Celsius and 15 degrees.")
        // Scale established in the SOURCE text counts too.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It's 15 degrees Celsius, dropping to 10°C.", locale: en),
                       "It's 15 degrees Celsius, dropping to 10 degrees.")
        // An explicit scale after a DIFFERENT established scale stays explicit.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "60°F and 15°C.", locale: en),
                       "60 degrees Fahrenheit and 15 degrees Celsius.")
    }

    func testDashRangesReadAsSpokenRanges() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It will be 14-22°C.", locale: en),
                       "It will be 14 to 22 degrees Celsius.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "It will be 14–22°C.", locale: en),
                       "It will be 14 to 22 degrees Celsius.")
        // A dash NOT followed by a degree word is not a temperature range.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "See pages 14–22 for details.", locale: en),
                       "See pages 14–22 for details.")
    }

    func testNonTemperaturesPassThroughByteIdentical() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "The cable is 15cm long.", locale: en),
                       "The cable is 15cm long.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "A 15fps video.", locale: en),
                       "A 15fps video.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "That argument is degenerate.", locale: en),
                       "That argument is degenerate.")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "version15c build", locale: en),
                       "version15c build")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "हजुर ठीक छ।", locale: ne),
                       "हजुर ठीक छ।")
    }

    // MARK: - Nepali

    func testNepaliUsesDevanagariNumeralsAndTheHouseUnitWords() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "१५°C छ।", locale: ne),
                       "१५ डिग्री सेल्सियस छ।")
        // ASCII digits arriving from a model convert to Devanagari —
        // the same convention the deterministic weather reply uses.
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "15°C छ।", locale: ne),
                       "१५ डिग्री सेल्सियस छ।")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "१५.५°C छ।", locale: ne),
                       "१५.५ डिग्री सेल्सियस छ।")
    }

    func testNepaliEstablishedScaleAndDashRange() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "१५°C अनि १०°C छ।", locale: ne),
                       "१५ डिग्री सेल्सियस अनि १० डिग्री छ।")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "१४-२२°C हुनेछ।", locale: ne),
                       "१४ देखि २२ डिग्री सेल्सियस हुनेछ।")
    }

    // MARK: - Idempotence

    /// The pass may run behind other stages (and once per delivery path);
    /// its own output is already spoken text and must not be rewritten.
    func testIdempotentOnItsOwnOutput() {
        let samples = [
            "It's 15°C and clear.",
            "It will be 14-22°C.",
            "It's 15°C now, 10°C tonight.",
            "60°F and 15°C.",
            "१४-२२°C हुनेछ।"
        ]
        for sample in samples {
            let isNepali = sample.contains("।")
            let locale = isNepali ? ne : en
            let once = SpokenUnits.normalizeTemperatures(in: sample, locale: locale)
            let twice = SpokenUnits.normalizeTemperatures(in: once, locale: locale)
            XCTAssertEqual(once, twice, "second pass changed its own output for \(sample)")
        }
    }

    func testPlainTextWithoutUnitsPassesThrough() {
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "Hello there, how are you?", locale: en),
                       "Hello there, how are you?")
        XCTAssertEqual(SpokenUnits.normalizeTemperatures(in: "", locale: en), "")
    }

    // MARK: - [AUDIT-SPOKEN] dose units (HIGH-1)

    /// The caregiver's own "500 mg" reaches a synthesizer as "five
    /// hundred em gee" without this — the audit's most frequent
    /// mechanical text (briefing, dose alerts, confirmation challenge).
    func testDoseUnitsExpandToSpokenWords() {
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "Take Amlodipine 500 mg twice a day.", locale: en),
                       "Take Amlodipine 500 milligrams twice a day.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "Take 1 mg daily.", locale: en),
                       "Take 1 milligram daily.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "5 mcg of B12.", locale: en),
                       "5 micrograms of B12.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "500Mg now.", locale: en),
                       "500 milligrams now.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "1 ml dose.", locale: en),
                       "1 millilitre dose.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "2 mls daily.", locale: en),
                       "2 millilitres daily.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "10 IU of insulin.", locale: en),
                       "10 international units of insulin.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "Take 1/2 tablet with water.", locale: en),
                       "Take half tablet with water.")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "Take ½ tablet.", locale: en),
                       "Take half tablet.")
        // A glued "1½" is its own shape — never guessed.
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "1½ cups.", locale: en),
                       "1½ cups.")
    }

    func testDoseUnitsNepali() {
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "अम्लोडिपिन ५०० mg खानुहोस्।", locale: ne),
                       "अम्लोडिपिन ५०० मिलीग्राम खानुहोस्।")
        // ASCII digits convert to the house Devanagari form.
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "500 mg खानुहोस्।", locale: ne),
                       "५०० मिलीग्राम खानुहोस्।")
        XCTAssertEqual(SpokenUnits.normalizeDoseUnits(in: "१/२ चक्की खानुहोस्।", locale: ne),
                       "आधा चक्की खानुहोस्।")
    }

    // MARK: - [AUDIT-SPOKEN] measure units (MEDIUM-6)

    /// Feeds, news and search snippets carry "5 kg", "15cm", "500/kg"
    /// and "km/h" — all read as letters by a synthesizer.
    func testMeasureUnitsExpandToSpokenWords() {
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "You walked 5 km today.", locale: en),
                       "You walked 5 kilometres today.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "1 kg of rice.", locale: en),
                       "1 kilogram of rice.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "It costs Rs. 500/kg.", locale: en),
                       "It costs Rs. 500 per kilogram.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "Rice is ₹80/kg today.", locale: en),
                       "Rice is ₹80 per kilogram today.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "Wind 5 km/h.", locale: en),
                       "Wind 5 kilometres per hour.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "100 mm of rain.", locale: en),
                       "100 millimetres of rain.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "The cable is 15cm long.", locale: en),
                       "The cable is 15 centimetres long.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "500 g of flour.", locale: en),
                       "500 grams of flour.")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "1.5 g of spice.", locale: en),
                       "1.5 grams of spice.")
        // "5G" is a network, never grams.
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "Fast 5G network.", locale: en),
                       "Fast 5G network.")
        // A dose ratio already expanded by the dose pass keeps its /ml
        // spoken ("5 milligrams/ml" suspensions).
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "5 milligrams/ml", locale: en),
                       "5 milligrams per millilitre")
    }

    func testMeasureUnitsNepali() {
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "५ km हिँड्नुभयो।", locale: ne),
                       "५ किलोमिटर हिँड्नुभयो।")
        XCTAssertEqual(SpokenUnits.normalizeMeasureUnits(in: "तौल २ kg छ।", locale: ne),
                       "तौल २ किलोग्राम छ।")
    }

    func testDoseAndMeasureIdempotentOnTheirOwnOutput() {
        let samples = [
            "Take Amlodipine 500 mg twice a day.",
            "1/2 tablet at 8 am",
            "You walked 5 km today.",
            "Wind 5 km/h.",
            "Rice is ₹80/kg today."
        ]
        for sample in samples {
            let once = SpokenUnits.normalizeDoseUnits(
                in: SpokenUnits.normalizeMeasureUnits(in: sample, locale: en), locale: en)
            let twice = SpokenUnits.normalizeDoseUnits(
                in: SpokenUnits.normalizeMeasureUnits(in: once, locale: en), locale: en)
            XCTAssertEqual(once, twice, "second pass changed its own output for \(sample)")
        }
    }
}
