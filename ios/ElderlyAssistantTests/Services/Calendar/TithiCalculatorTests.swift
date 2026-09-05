import XCTest
@testable import ElderlyAssistant

final class TithiCalculatorTests: XCTestCase {

    /// The 91 real published-panchanga days the algorithm was validated
    /// against at implementation time (nepalipatro.github.io data,
    /// 2080-01/12 + 2079-12): 80% exact, rest ±1 boundary days. These
    /// entries are the exact-match anchors — regression-guard them.
    private let exactMatches: [(ad: (Int, Int, Int), tithi130: Int)] = [
        ((2023, 4, 14), 24),   // Baisakh 1, 2080
        ((2023, 4, 15), 25),
        ((2023, 4, 27), 7),
        ((2023, 4, 29), 9),
        ((2023, 5, 1), 11),
        ((2023, 5, 5), 15),    // Purnima day
        ((2024, 3, 15), 6),
        ((2024, 3, 16), 7),
        ((2024, 3, 18), 9),
    ]

    func testExactMatchesAgainstPublishedPanchanga() {
        for (ad, expected) in exactMatches {
            XCTAssertEqual(TithiCalculator.tithi130(year: ad.0, month: ad.1, day: ad.2),
                           expected, "tithi mismatch for \(ad)")
        }
    }

    func testTithiNumberAndPaksha() {
        // Purnima (tithi 15, shukla) on 2023-05-05.
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        let date = greg.date(from: DateComponents(year: 2023, month: 5, day: 5))!
        let t = TithiCalculator.tithi(on: date, calendar: greg)
        XCTAssertEqual(t.number, 15)
        XCTAssertTrue(t.isShukla)
        XCTAssertEqual(t.nameNepali, "पूर्णिमा")
    }

    func testAmavasyaNaming() {
        // The amavasya (krishna 15) naming path — tested directly
        // rather than via a real date, since the midnight-UT (Nepal
        // sunrise) convention can legitimately skip a tithi inside a
        // civil day (a real "kshaya tithi", e.g. around 2023-04-19/20,
        // where no midnight falls on tithi 30 at all).
        let t = TithiCalculator.Tithi(number: 15, isShukla: false)
        XCTAssertEqual(t.nameNepali, "अमावस्या")
        XCTAssertEqual(t.displayNepali, "अमावस्या कृष्ण पक्ष")
    }

    func testDisplayNepaliFormat() {
        let t = TithiCalculator.Tithi(number: 3, isShukla: true)
        XCTAssertEqual(t.displayNepali, "त्रितिया शुक्ल पक्ष")
        let k = TithiCalculator.Tithi(number: 8, isShukla: false)
        XCTAssertEqual(k.displayNepali, "अष्टमी कृष्ण पक्ष")
    }

    func testTithiAdvancesRoughlyDaily() {
        // Over any 10-day window, tithi index (1-30) must advance by
        // 10 ± 2 — a coarse sanity check the elongation math is sane.
        let t1 = TithiCalculator.tithi130(year: 2026, month: 9, day: 6)
        let t2 = TithiCalculator.tithi130(year: 2026, month: 9, day: 16)
        let diff = (t2 - t1 + 30) % 30
        XCTAssertTrue((8...12).contains(diff), "tithi advanced by \(diff) in 10 days — implausible")
    }
}
