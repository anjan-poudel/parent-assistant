import XCTest
@testable import ElderlyAssistant

/// Devanagari numeral rendering for step badges (e.g. "1" → "१").
final class DevanagariNumeralsTests: XCTestCase {

    func testSingleDigits() {
        XCTAssertEqual(DevanagariNumerals.string(0), "०")
        XCTAssertEqual(DevanagariNumerals.string(1), "१")
        XCTAssertEqual(DevanagariNumerals.string(7), "७")
        XCTAssertEqual(DevanagariNumerals.string(9), "९")
    }

    func testMultiDigitNumbers() {
        XCTAssertEqual(DevanagariNumerals.string(10), "१०")
        XCTAssertEqual(DevanagariNumerals.string(14), "१४")
        XCTAssertEqual(DevanagariNumerals.string(100), "१००")
        XCTAssertEqual(DevanagariNumerals.string(2083), "२०८३")
    }

    func testMatchesBikramSambatConverter() {
        // The calendar service carries its own copy of this conversion —
        // keep the two implementations in agreement.
        for value in [1, 7, 14, 31, 2083, 4096] {
            XCTAssertEqual(DevanagariNumerals.string(value),
                           BikramSambat.devanagariDigits(value))
        }
    }

    func testNegativeKeepsMinusSign() {
        XCTAssertEqual(DevanagariNumerals.string(-5), "-५")
    }
}
