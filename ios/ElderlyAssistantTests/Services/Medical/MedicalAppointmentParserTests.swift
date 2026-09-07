import XCTest
@testable import ElderlyAssistant

/// Tests for `MedicalAppointmentParser` (medical task + SMS-confirmation
/// scope extension, 2026-09-07). `now` is injected — Monday
/// 2026-09-07 04:00 UTC — so every relative day and weekday expectation
/// is deterministic.
final class MedicalAppointmentParserTests: XCTestCase {

    // MARK: - Fixed clock

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: utcCalendar(),
                       timeZone: TimeZone(secondsFromGMT: 0)!,
                       year: year, month: month, day: day,
                       hour: hour, minute: minute).date!
    }

    private static let now = date(2026, 9, 7, 4, 0) // Monday 04:00 UTC

    private static func parse(_ text: String) -> MedicalAppointmentParser.ParsedAppointment? {
        MedicalAppointmentParser.parse(text, now: now, calendar: utcCalendar())
    }

    // MARK: - The two mandated SMS-confirmation shapes

    func testEnglishConfirmationSMSExample() {
        // The exact shape from the scope extension.
        let parsed = Self.parse("hi joe, this is to confirm you have appointment "
                                + "with Dr Jane tomorrow at 2.30pm at Xyz medical centre")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "Dr Jane")
        XCTAssertEqual(parsed?.place, "Xyz medical centre")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 14, 30),
                       "tomorrow 2.30pm = Tuesday 14:30")
    }

    func testNepaliConfirmationSMSExample() {
        // The exact Nepali shape — Devanagari digits, possessive
        // particle on the doctor, locative on the venue.
        let parsed = Self.parse("डा. जेनसँग भोलि २:३० बजे Xyz मेडिकल सेन्टरमा भेट छ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "डा. जेन",
                       "the सँग particle is stripped from the name")
        XCTAssertEqual(parsed?.place, "Xyz मेडिकल सेन्टर",
                       "the locative मा is stripped from the venue")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 14, 30),
                       "२:३० = 14:30, भोलि = the 8th")
    }

    // MARK: - Voice-phrase shape ("…on Friday at 3")

    func testDoctorAppointmentOnFridayAtThree() {
        let parsed = Self.parse("doctor appointment on Friday at 3")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "Doctor")
        XCTAssertNil(parsed?.place)
        // Bare "3" after lunch hours reads 15:00 (clinic-hours
        // heuristic); Friday is 2026-09-11, the next one after Monday.
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 11, 15, 0))
    }

    func testBareThreeWithEveningPeriodWordReadsEvening() {
        // "बेलुका ३ बजे" — the period word forces the afternoon shift.
        let parsed = Self.parse("बेलुका ३ बजे डा. जेनसँग भेट छ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "डा. जेन")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 7, 15, 0))
    }

    // MARK: - Day words and fallbacks

    func testTodayAtThreePM() {
        let parsed = Self.parse("appointment today at 3pm")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 7, 15, 0))
    }

    func testExplicitAMIsNeverAfternoonShifted() {
        // An explicit "am" beats the clinic-hours heuristic: 03:00, not
        // 15:00.
        let parsed = Self.parse("appointment at 3am")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 3, 0),
                       "3am today already passed (now 04:00) — pushed to tomorrow 03:00")
    }

    func testBareClockTimeWithoutDayStaysTodayWhenAhead() {
        let parsed = Self.parse("appointment at 2.30pm")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 7, 14, 30),
                       "no day word, 14:30 still ahead of now — today")
    }

    func testDayAfterTomorrowAtTen() {
        let parsed = Self.parse("appointment day after tomorrow at 10")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 9, 10, 0))
    }

    func testTomorrowAtNineAMSpacedSuffix() {
        let parsed = Self.parse("appointment tomorrow at 9 am")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 9, 0))
    }

    func testRelativeDayWithoutTimeDefaultsToNoon() {
        let parsed = Self.parse("appointment tomorrow")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 12, 0))
    }

    func testWeekdayWithoutTimeDefaultsToNoon() {
        let parsed = Self.parse("doctor appointment on Saturday")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 12, 12, 0),
                       "next Saturday after Monday the 7th is the 12th")
    }

    // MARK: - Doctor and venue resolution

    func testGenericDoctorWordFallsBackToDoctorLabel() {
        // No name after "with" — the article is stripped and the draft
        // honestly says "Doctor".
        let parsed = Self.parse("appointment with the doctor tomorrow at 2")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "Doctor")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 14, 0),
                       "bare 'at 2' reads 14:00")
    }

    func testNepaliDoctorWordWithoutName() {
        // "डाक्टरसँग" is its own token — the possessive is stripped and
        // the generic label survives.
        let parsed = Self.parse("डाक्टरसँग भोलि २ बजे अस्पतालमा भेट छ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "डाक्टर")
        XCTAssertEqual(parsed?.place, "अस्पताल")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 14, 0))
    }

    func testVenueOnlyMessageFoldsVenueIntoLabel() {
        // No doctor mentioned at all — the venue IS the label.
        let parsed = Self.parse("your appointment tomorrow at 2.30pm at Xyz medical centre")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "Xyz medical centre")
        XCTAssertNil(parsed?.place)
    }

    func testDandaTimeSeparatorNormalises() {
        // "८॥३०" folds to "8:30" via NepaliTimeParser.normalise.
        let parsed = Self.parse("आज ८॥३० बजे डा. जेनसँग भेट छ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.doctorOrPlace, "डा. जेन")
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 7, 8, 30))
    }

    func testPhoneNumberRunIsNotATime() {
        // A 10-digit run must not be read as a clock; the day word still
        // resolves — noon, not some hour derived from digits.
        let parsed = Self.parse("call 9841234567 about my appointment tomorrow")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.date, Self.date(2026, 9, 8, 12, 0))
    }

    // MARK: - Honest nil rules

    func testNoAppointmentMarkerReturnsNil() {
        XCTAssertNil(Self.parse("please call me back at 3"))
        XCTAssertNil(Self.parse("भोलि २ बजे फोन गर्नुहोस्"))
    }

    func testMarkerWithoutAnyDateOrTimeSignalReturnsNil() {
        XCTAssertNil(Self.parse("your appointment is confirmed"),
                     "a confirmation line with no day/time is not actionable")
    }

    func testVoiceAddPhraseReturnsNilAsFormSignal() {
        // The Medical leaf's own voice prompt must NOT draft a save —
        // the CommandRouter hook documents nil here as "open the form".
        XCTAssertNil(Self.parse("add a doctor appointment"))
        XCTAssertNil(Self.parse("डाक्टरको भेटघाट थप्नुहोस्"))
    }
}
