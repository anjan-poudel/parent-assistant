import XCTest
@testable import ElderlyAssistant

/// Spoken-time task, 2026-09-08 — `SpokenTime` unit tests. Every voice
/// line that embeds a wall-clock time formats through this helper so the
/// TTS never receives a clock string it reads as digits ("13:00" →
/// "thirteen hundred"). The reported bug: the Nepali locale's
/// `Date.FormatStyle .shortened` produced "१३:००".
///
/// Pinned conventions:
///  - English: 12-hour + lowercase space-separated am/pm ("1 pm",
///    "1:30 pm"); minutes omitted on the hour.
///  - Nepali: day-period word + Devanagari digits + बजे (minutes:
///    "बजेर N मिनेट"); NEVER ASCII digits, NEVER a colon. Period windows
///    match `TopicPreAnswer` (`periodKey` is the shared single source of
///    truth).
final class SpokenTimeTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    private func time(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 6
        components.hour = hour
        components.minute = minute
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - English (the reported "13:00" bug family)

    func testEnglishNeverSpeaks24HourClock() {
        XCTAssertEqual(SpokenTime.string(hour: 13, minute: 0, locale: en), "1 pm")
        XCTAssertEqual(SpokenTime.string(hour: 17, minute: 0, locale: en), "5 pm")
        XCTAssertEqual(SpokenTime.string(hour: 9, minute: 0, locale: en), "9 am")
    }

    func testEnglishNoonAndMidnight() {
        XCTAssertEqual(SpokenTime.string(hour: 12, minute: 0, locale: en), "12 pm")
        XCTAssertEqual(SpokenTime.string(hour: 0, minute: 0, locale: en), "12 am")
    }

    func testEnglishMinutesAreSpokenWithMinutePair() {
        XCTAssertEqual(SpokenTime.string(hour: 13, minute: 30, locale: en), "1:30 pm")
        XCTAssertEqual(SpokenTime.string(hour: 7, minute: 5, locale: en), "7:05 am")
        XCTAssertEqual(SpokenTime.string(hour: 23, minute: 59, locale: en), "11:59 pm")
    }

    func testEnglishDateFormReadsTheClockViaTheHostCalendar() {
        XCTAssertEqual(SpokenTime.string(from: time(13, 0), locale: en), "1 pm")
        XCTAssertEqual(SpokenTime.string(from: time(7, 30), locale: en), "7:30 am")
    }

    // MARK: - Nepali (the reported "१३:००" bug family)

    func testNepaliUsesPeriodWordDevanagariAndBaje() {
        XCTAssertEqual(SpokenTime.string(hour: 13, minute: 0, locale: ne), "दिउँसो १ बजे")
        XCTAssertEqual(SpokenTime.string(hour: 17, minute: 0, locale: ne), "बेलुका ५ बजे")
        XCTAssertEqual(SpokenTime.string(hour: 8, minute: 0, locale: ne), "बिहान ८ बजे")
        XCTAssertEqual(SpokenTime.string(hour: 22, minute: 0, locale: ne), "राति १० बजे")
    }

    func testNepaliMinutesUseBajeraMinuteForm() {
        XCTAssertEqual(SpokenTime.string(hour: 7, minute: 30, locale: ne), "बिहान ७ बजेर ३० मिनेट")
        XCTAssertEqual(SpokenTime.string(hour: 23, minute: 45, locale: ne), "राति ११ बजेर ४५ मिनेट")
        XCTAssertEqual(SpokenTime.string(hour: 12, minute: 15, locale: ne), "दिउँसो १२ बजेर १५ मिनेट")
    }

    func testNepaliHourTwelveDialForMidnight() {
        XCTAssertEqual(SpokenTime.string(hour: 0, minute: 30, locale: ne), "राति १२ बजेर ३० मिनेट")
    }

    func testNepaliOutputNeverContainsAsciiDigitsOrColons() {
        let samples = [(0, 5), (4, 59), (7, 0), (7, 5), (12, 0), (13, 45), (16, 0), (23, 59)]
        for (hour, minute) in samples {
            let spoken = SpokenTime.string(hour: hour, minute: minute, locale: ne)
            for character in spoken {
                if character.isASCII, character.isNumber || character == ":" {
                    XCTFail("ASCII digit or colon in Nepali output: \(spoken)")
                }
            }
            XCTAssertTrue(spoken.contains("बजे"), "missing बजे in: \(spoken)")
        }
    }

    func testNepaliDateFormReadsTheClockViaTheHostCalendar() {
        XCTAssertEqual(SpokenTime.string(from: time(6, 0), locale: ne), "बिहान ६ बजे")
        XCTAssertEqual(SpokenTime.string(from: time(17, 30), locale: ne), "बेलुका ५ बजेर ३० मिनेट")
    }

    // MARK: - Day periods (shared single source of truth)

    func testPeriodWindowsMatchTopicPreAnswerTable() {
        XCTAssertEqual(SpokenTime.periodKey(hour: 4), "topic.time.period.night")
        XCTAssertEqual(SpokenTime.periodKey(hour: 5), "topic.time.period.morning")
        XCTAssertEqual(SpokenTime.periodKey(hour: 11), "topic.time.period.morning")
        XCTAssertEqual(SpokenTime.periodKey(hour: 12), "topic.time.period.afternoon")
        XCTAssertEqual(SpokenTime.periodKey(hour: 15), "topic.time.period.afternoon")
        XCTAssertEqual(SpokenTime.periodKey(hour: 16), "topic.time.period.evening")
        XCTAssertEqual(SpokenTime.periodKey(hour: 19), "topic.time.period.evening")
        XCTAssertEqual(SpokenTime.periodKey(hour: 20), "topic.time.period.night")
        XCTAssertEqual(SpokenTime.periodKey(hour: 23), "topic.time.period.night")
        XCTAssertEqual(SpokenTime.periodKey(hour: 0), "topic.time.period.night")
    }
}
