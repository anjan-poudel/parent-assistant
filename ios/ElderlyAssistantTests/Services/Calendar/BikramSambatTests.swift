import XCTest
@testable import ElderlyAssistant

final class BikramSambatTests: XCTestCase {

    private func greg(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Anchor + verified conversions

    func testAnchorConvertsBothWays() {
        let bs = BikramSambat.bsDate(from: greg(1921, 4, 13))
        XCTAssertEqual(bs, .init(year: 1978, month: 1, day: 1))

        let ad = BikramSambat.adDate(from: .init(year: 1978, month: 1, day: 1))
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: ad!)
        XCTAssertEqual(comps.year, 1921)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 13)
    }

    func testNepaliNewYear2083() {
        // Nepali New Year 2083 = April 14, 2026 (independently known).
        let bs = BikramSambat.bsDate(from: greg(2026, 4, 14))
        XCTAssertEqual(bs, .init(year: 2083, month: 1, day: 1))
    }

    func testNepaliNewYear2082() {
        let bs = BikramSambat.bsDate(from: greg(2025, 4, 14))
        XCTAssertEqual(bs, .init(year: 2082, month: 1, day: 1))
    }

    func testTodayIsExpectedBSDate() {
        // 2026-09-06 → Bhadra 21, 2083 (verified against the canonical
        // table's own math at implementation time).
        let bs = BikramSambat.bsDate(from: greg(2026, 9, 6))
        XCTAssertEqual(bs, .init(year: 2083, month: 5, day: 21))
    }

    func testRoundTripAcrossTable() {
        // Sample one date per BS month across several years: BS→AD→BS
        // must come back identical.
        for year in [1978, 2000, 2050, 2083, 2099] {
            guard let months = BikramSambat.monthLengths[year] else { continue }
            for (index, length) in months.enumerated() {
                let bs = BikramSambat.BSDate(year: year, month: index + 1, day: min(length, 15))
                guard let ad = BikramSambat.adDate(from: bs),
                      let back = BikramSambat.bsDate(from: ad) else {
                    XCTFail("conversion failed for \(bs)")
                    return
                }
                XCTAssertEqual(back, bs, "round trip failed for \(bs)")
            }
        }
    }

    func testOutOfCoverageReturnsNil() {
        XCTAssertNil(BikramSambat.bsDate(from: greg(1900, 1, 1)))
        XCTAssertNil(BikramSambat.bsDate(from: greg(2200, 1, 1)))
        XCTAssertNil(BikramSambat.adDate(from: .init(year: 2100, month: 1, day: 1)))
    }

    func testInvalidBSDayReturnsNil() {
        // Day 32 in a month that has only 31 days.
        let months = BikramSambat.monthLengths[2083]!
        let shortMonth = months.firstIndex(of: 29)! + 1
        XCTAssertNil(BikramSambat.adDate(from: .init(year: 2083, month: shortMonth, day: 32)))
    }

    func testDevanagariDigits() {
        XCTAssertEqual(BikramSambat.devanagariDigits(2083), "२०८३")
        XCTAssertEqual(BikramSambat.devanagariDigits(15), "१५")
        XCTAssertEqual(BikramSambat.devanagariDigits(0), "०")
    }

    func testNepaliString() {
        let s = BikramSambat.nepaliString(.init(year: 2083, month: 6, day: 10))
        XCTAssertTrue(s.contains("असोज"))
        XCTAssertTrue(s.contains("१०"))
        XCTAssertTrue(s.contains("२०८३"))
    }
}
