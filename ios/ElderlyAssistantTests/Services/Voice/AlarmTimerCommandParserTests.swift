import XCTest
@testable import ElderlyAssistant

/// [ALARMS-TIMERS] (2026-09-07) Parser tests for the voice alarm + timer
/// commands — en + ne grammar, next-occurrence resolution (pinned `now`),
/// 12-hour period adjustment, the vetoes (questions / cancellations /
/// third-person wake / countdown phrasings), the golden-corpus guard for
/// bare "उठाउनु", and the label extraction.
///
/// Time-of-day phrases only: `NepaliTimeParser` reads the real clock for
/// its "अब"/relative-day paths, so those shapes are not pinned here.
final class AlarmTimerCommandParserTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// "Now" = 2026-09-07 10:00 local — before noon, after 6–9 am, so the
    /// next-occurrence direction of every assertion below is pinned.
    private var now: Date {
        date(2026, 9, 7, 10, 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private var en: Locale { Locale(identifier: "en-US") }
    private var ne: Locale { Locale(identifier: "ne-NP") }

    // MARK: - parseAlarm: English

    func testEnglishSixAmResolvesToNextMorning() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 6 am", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 6, 0))
        XCTAssertNil(alarm?.label)
    }

    func testNineAmAlreadyPassedRollsToTomorrow() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 9 am", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 9, 0))
    }

    func testEightPMResolvesToSameDayEvening() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm at 8 pm", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 20, 0))
    }

    func testTwelveAmIsMidnightNotNoon() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 12 am", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 0, 0))
    }

    func testTwelvePmStaysNoon() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "alarm at 12 pm", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 12, 0))
    }

    func testEnglishPeriodWordEveningAddsTwelveHours() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 8 in the evening", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 20, 0))
    }

    func testNightWordAddsTwelveHours() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 8 at night", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 20, 0))
    }

    func testColonTimeWithMinutes() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for 6:30 in the evening", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 18, 30))
    }

    func testWakeMeUpPhrase() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "wake me up at 7:30", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 7, 30))
    }

    func testTomorrowResolvesToEveningSix() {
        // Relative days are resolved by `NepaliTimeParser` against the
        // REAL clock, not the injected `now` — so the exact date is not
        // pinned here. The resulting day is always after the fixed `now`
        // (this suite runs on/after 2026-09-07), and the clock time is
        // deterministic: 6 pm, post-adjusted from the wordless "6 pm".
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm for tomorrow 6 pm", now: now, calendar: calendar)
        guard let time = alarm?.time else {
            return XCTFail("expected a resolved alarm")
        }
        let components = calendar.dateComponents([.hour, .minute], from: time)
        XCTAssertEqual(components.hour, 18)
        XCTAssertEqual(components.minute, 0)
        XCTAssertGreaterThan(time, now)
    }

    func testEnglishLabelExtraction() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "set an alarm at 6:30 am for yoga", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 6, 30))
        XCTAssertEqual(alarm?.label, "yoga")
    }

    func testWakeLabelExtraction() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "wake me up at 6 for yoga", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.label, "yoga")
    }

    // MARK: - parseAlarm: Nepali

    func testNepaliMorningAlarm() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बिहान ६ बजे अलार्म लगाऊ", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 6, 0))
        XCTAssertNil(alarm?.label)
    }

    func testNepaliEveningAlarm() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बेलुका ७ बजे अलार्म", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 7, 19, 0))
    }

    func testNepaliWakeHonorificIsAnAlarm() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बिहान ६ बजे उठाउनुहोस्", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 6, 0))
    }

    func testNepaliWakeDoForMeFormIsAnAlarm() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बिहान ७ बजे उठाइदिनुहोस्", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 7, 0))
    }

    func testNepaliLabelExtraction() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बिहान ७ बजे अलार्म लगाऊ, मेडिसिन", now: now, calendar: calendar)
        XCTAssertEqual(alarm?.label, "मेडिसिन")
    }

    // MARK: - parseAlarm: vetoes

    func testBareWakeInfinitiveIsNotAnAlarm() {
        // Golden-corpus guard: "बिहान ६ बजे उठाउनु" is the reminder
        // corpus's set_reminder utterance — only the honorific do-for-me
        // wake forms are alarm commands.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "बिहान ६ बजे उठाउनु", now: now, calendar: calendar))
    }

    func testThirdPersonWakeIsNotAnAlarm() {
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "wake my grandson at 7", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "छोरालाई बिहान ६ बजे उठाउनुहोस्", now: now, calendar: calendar))
    }

    func testAlarmQuestionIsVetoed() {
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "when is my alarm set?", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "कति बजेको अलार्म छ?", now: now, calendar: calendar))
    }

    func testAlarmCancellationIsVetoed() {
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "cancel my alarm for 6 am", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "अलार्म बन्द गर", now: now, calendar: calendar))
    }

    func testCountdownPhrasingIsVetoed() {
        // "alarm in N minutes" is a countdown — timer territory. The
        // router parses timer commands first; the alarm parser must never
        // silently turn it into a time-of-day alarm.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "set an alarm in 5 minutes", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "२ घण्टा पछि अलार्म", now: now, calendar: calendar))
    }

    func testNoMarkerNeverParses() {
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "hello how are you", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "remind me at 8", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "call the doctor", now: now, calendar: calendar))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "", now: now, calendar: calendar))
    }

    // MARK: - parseTimer

    func testNepaliTimerFiveMinutes() {
        let timer = AlarmTimerCommandParser.parseTimer("टाइमर ५ मिनेट")
        XCTAssertEqual(timer?.durationSeconds, 300)
        XCTAssertNil(timer?.label)
    }

    func testNepaliTimerUnitSuffixedForm() {
        let timer = AlarmTimerCommandParser.parseTimer("५ मिनेटको टाइमर लगाऊ")
        XCTAssertEqual(timer?.durationSeconds, 300)
    }

    func testNepaliTimerHours() {
        let timer = AlarmTimerCommandParser.parseTimer("टाइमर ३ घण्टा")
        XCTAssertEqual(timer?.durationSeconds, 10_800)
    }

    func testEnglishTimerMinutes() {
        let timer = AlarmTimerCommandParser.parseTimer("set a timer for 5 minutes")
        XCTAssertEqual(timer?.durationSeconds, 300)
        XCTAssertNil(timer?.label)
    }

    func testEnglishTimerHours() {
        let timer = AlarmTimerCommandParser.parseTimer("set a timer for 2 hours")
        XCTAssertEqual(timer?.durationSeconds, 7200)
    }

    func testTimerSeconds() {
        let timer = AlarmTimerCommandParser.parseTimer("timer 30 seconds")
        XCTAssertEqual(timer?.durationSeconds, 30)
    }

    func testTimerMinuteAbbreviation() {
        let timer = AlarmTimerCommandParser.parseTimer("timer 5 mins")
        XCTAssertEqual(timer?.durationSeconds, 300)
    }

    func testTimerLabelExtraction() {
        let timer = AlarmTimerCommandParser.parseTimer("boil the eggs timer 6 minutes")
        XCTAssertEqual(timer?.durationSeconds, 360)
        XCTAssertEqual(timer?.label, "boil eggs")
    }

    func testCompoundDurationIsRejectedNotTruncated() {
        // Honesty contract: never confirm only the first unit of "1 hour
        // 30 minutes".
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("set a timer for 1 hour 30 minutes"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "set a timer for 5 minutes, then one for 3 minutes"))
    }

    func testOutOfRangeDurationIsRejected() {
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("timer 25 hours"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("timer 0 minutes"))
    }

    func testTimerQuestionAndCancellationAreVetoed() {
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("कति मिनेटको टाइमर?"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("cancel the timer"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("टाइमर बन्द गर"))
    }

    func testNoTimerMarkerNeverParses() {
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("remind me in 5 minutes"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("what is 5 minutes in seconds"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(""))
    }

    func testAlarmPhrasingIsNeverATimer() {
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("set an alarm for 6 am"))
    }

    // MARK: - durationText

    func testDurationTextEnglish() {
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 300, locale: en),
                       "5 minutes")
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 5400, locale: en),
                       "1 hour 30 minutes")
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 3665, locale: en),
                       "1 hour 1 minute 5 seconds")
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 45, locale: en),
                       "45 seconds")
    }

    func testDurationTextNepaliUsesDevanagari() {
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 300, locale: ne),
                       "५ मिनेट")
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 7200, locale: ne),
                       "२ घण्टा")
        XCTAssertEqual(AlarmTimerCommandParser.durationText(seconds: 3665, locale: ne),
                       "१ घण्टा १ मिनेट ५ सेकेण्ड")
    }
}
