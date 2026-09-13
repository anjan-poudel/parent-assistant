import XCTest
@testable import ElderlyAssistant

final class NepaliTimeParserTests: XCTestCase {

    func testMorningPeriodWordWithHour() {
        XCTAssertEqual(NepaliTimeParser.parse("बिहान ८ बजे"),
                       DateComponents(hour: 8, minute: 0))
    }

    func testAfternoonPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("दिउँसो २ बजे"),
                       DateComponents(hour: 14, minute: 0))
    }

    func testEveningPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("बेलुका ७ बजे"),
                       DateComponents(hour: 19, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("साँझ ५ बजे"),
                       DateComponents(hour: 17, minute: 0))
    }

    func testNightPeriodWordAdjustsTo24Hour() {
        XCTAssertEqual(NepaliTimeParser.parse("राति ९ बजे"),
                       DateComponents(hour: 21, minute: 0))
    }

    func testSaadheMeansHalfPast() {
        XCTAssertEqual(NepaliTimeParser.parse("साढे ८"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testClockStringWithColon() {
        XCTAssertEqual(NepaliTimeParser.parse("8:30"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testDandaClockString() {
        XCTAssertEqual(NepaliTimeParser.parse("८॥३०"),
                       DateComponents(hour: 8, minute: 30))
    }

    func testAmPmSuffixes() {
        XCTAssertEqual(NepaliTimeParser.parse("8 am"),
                       DateComponents(hour: 8, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("1 pm"),
                       DateComponents(hour: 13, minute: 0))
    }

    func testPeriodWordAloneUsesRepresentativeTime() {
        XCTAssertEqual(NepaliTimeParser.parse("बिहान"), DateComponents(hour: 8, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("दिउँसो"), DateComponents(hour: 12, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("साँझ"), DateComponents(hour: 17, minute: 0))
        XCTAssertEqual(NepaliTimeParser.parse("राति"), DateComponents(hour: 20, minute: 0))
    }

    func testAbMeansNow() {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let parsed = NepaliTimeParser.parse("अब १० मिनेटपछि सम्झाउनु")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.hour, now.hour)
        XCTAssertEqual(parsed?.minute, now.minute)
    }

    func testDevanagariDigits() {
        XCTAssertEqual(NepaliTimeParser.parse("१० बजे औषधि सम्झाउनु"),
                       DateComponents(hour: 10, minute: 0))
    }

    func testNonTimeTextReturnsNil() {
        XCTAssertNil(NepaliTimeParser.parse("भोलि मौसम कस्तो छ"))
        XCTAssertNil(NepaliTimeParser.parse(""))
        XCTAssertNil(NepaliTimeParser.parse("छोरालाई फोन गर"))
    }

    // MARK: - Relative-day resolution (day-carrying questions, 2026-09-13)

    /// The day a question is ABOUT, resolved without any clock time —
    /// the weather path's seam ("भोलि मौसम कस्तो हुन्छ" carries a day but
    /// no clock time, so `parse` returns nil by design and the day used
    /// to be lost entirely: every trace of भोलि/पर्सि dropped before the
    /// forecast request, which then answered with today's reading).
    func testRelativeDayOffsetResolvesNepaliDayWords() {
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "आजको मौसम कस्तो छ?"), 0)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "भोलिको मौसम कस्तो छ?"), 1)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "भोलि मौसम कस्तो हुन्छ"), 1)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "पर्सिको मौसम कस्तो छ?"), 2)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "पर्सि पानी पर्छ कि?"), 2)
    }

    func testRelativeDayOffsetResolvesEnglishDayWords() {
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "what's the weather today?"), 0)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "will it rain tomorrow?"), 1)
        XCTAssertEqual(NepaliTimeParser.relativeDayOffset(in: "the day after tomorrow"), 2)
    }

    func testRelativeDayOffsetIsNilWithoutADayWord() {
        XCTAssertNil(NepaliTimeParser.relativeDayOffset(in: "मौसम कस्तो छ?"))
        XCTAssertNil(NepaliTimeParser.relativeDayOffset(in: ""))
    }

    /// The device repro: "भोलि मौसम कस्तो हुन्छ" must resolve to
    /// TOMORROW's date — not today's.
    func testTomorrowQuestionResolvesToTomorrowsDateNotToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13,
                                                     hour: 10, minute: 30))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: today)!

        XCTAssertEqual(NepaliTimeParser.resolveRelativeDay(in: "भोलि मौसम कस्तो हुन्छ",
                                                           now: now, calendar: calendar),
                       tomorrow)
        XCTAssertNotEqual(NepaliTimeParser.resolveRelativeDay(in: "भोलि मौसम कस्तो हुन्छ",
                                                              now: now, calendar: calendar),
                          today,
                          "a भोलि question must never resolve to today")
        // Sanity: आज stays today, पर्सि is the day after tomorrow.
        XCTAssertEqual(NepaliTimeParser.resolveRelativeDay(in: "आजको मौसम कस्तो छ?",
                                                           now: now, calendar: calendar),
                       today)
        XCTAssertEqual(NepaliTimeParser.resolveRelativeDay(in: "पर्सिको मौसम कस्तो छ?",
                                                           now: now, calendar: calendar),
                       dayAfter)
        XCTAssertNil(NepaliTimeParser.resolveRelativeDay(in: "मौसम कस्तो छ?",
                                                         now: now, calendar: calendar))
    }
}
