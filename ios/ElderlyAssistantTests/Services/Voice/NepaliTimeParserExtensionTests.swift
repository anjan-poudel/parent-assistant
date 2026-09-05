import XCTest
@testable import ElderlyAssistant

/// Spec §6.3 extensions: relative days, weekday names, hours-later, and
/// the हरेक recurrence marker. Existing behavior (periods, साढे, digits,
/// hour/minute-only results) is covered by NepaliTimeParserTests and is
/// unchanged — day words are what attach Y/M/D.
final class NepaliTimeParserExtensionTests: XCTestCase {

    func testTomorrowAttachesTomorrowDate() {
        let c = NepaliTimeParser.parse("भोलि बिहान ८ बजे")
        XCTAssertEqual(c?.hour, 8)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let tc = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        XCTAssertEqual(c?.year, tc.year)
        XCTAssertEqual(c?.month, tc.month)
        XCTAssertEqual(c?.day, tc.day)
    }

    func testDayAfterTomorrow() {
        let c = NepaliTimeParser.parse("पर्सि बेलुका ७ बजे")
        XCTAssertEqual(c?.hour, 19)
        let expected = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        XCTAssertEqual(c?.day, Calendar.current.component(.day, from: expected))
    }

    func testTodayKeepsCurrentDate() {
        let c = NepaliTimeParser.parse("आज दिउँसो २ बजे")
        XCTAssertEqual(c?.hour, 14)
        XCTAssertEqual(c?.day, Calendar.current.component(.day, from: Date()))
        XCTAssertNotNil(c?.year)
    }

    func testWeekdayResolvesToNextOccurrence() {
        for (word, expected) in [("आइतबार", 1), ("शुक्रबार", 6), ("monday", 2)] as [(String, Int)] {
            let c = NepaliTimeParser.parse("\(word) बिहान ९ बजे")
            XCTAssertEqual(c?.hour, 9, word)
            XCTAssertEqual(c?.weekday, expected, word)
            // Must be in the future (or later today if today IS the day).
            let date = Calendar.current.date(from: c!)!
            XCTAssertGreaterThan(date.timeIntervalSinceNow, 0, word)
        }
    }

    func testHoursLaterReturnsAbsoluteTimestamp() {
        let before = Date()
        let c = NepaliTimeParser.parse("२ घण्टा पछि")
        XCTAssertNotNil(c?.hour)
        let date = Calendar.current.date(from: c!)!
        let delta = date.timeIntervalSince(before)
        XCTAssertGreaterThan(delta, 1.9 * 3600)
        XCTAssertLessThan(delta, 2.1 * 3600)
        XCTAssertNotNil(c?.day)
    }

    func testEnglishHoursLater() {
        XCTAssertNotNil(Calendar.current.date(from: NepaliTimeParser.parse("in 3 hours")!))
    }

    func testHarekDoesNotBreakTimeParse() {
        // हरेक (every) is a recurrence marker — the scheduler side already
        // fires daily; the parser's job is just the time.
        let c = NepaliTimeParser.parse("हरेक बिहान ८ बजे")
        XCTAssertEqual(c?.hour, 8)
        XCTAssertEqual(c?.minute, 0)
    }

    func testPlainTimeStillHourMinuteOnly() {
        // No day words → historical shape preserved (existing callers
        // treat missing Y/M/D as "today").
        let c = NepaliTimeParser.parse("बिहान ८ बजे")
        XCTAssertEqual(c?.hour, 8)
        XCTAssertNil(c?.year)
        XCTAssertNil(c?.day)
    }

    func testDevanagariDigitHoursLater() {
        XCTAssertNotNil(NepaliTimeParser.parse("३ घण्टा पछि"))
    }
}
