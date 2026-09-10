import XCTest
@testable import ElderlyAssistant

/// [ALARMS-TIMERS] (2026-09-07) Parser tests for the voice alarm + timer
/// commands — en + ne grammar, next-occurrence resolution (pinned `now`),
/// 12-hour period adjustment, the vetoes (questions / cancellations /
/// third-person wake / countdown phrasings), the golden-corpus guard for
/// bare "उठाउनु", and the label extraction. (2026-09-08) Plus hour-unit
/// + compound timer durations (one duration, never truncated, never
/// merged across two commands) and the OFF/SNOOZE parsers — sanctioned
/// shapes and their vetoes (time-qualified cancellations, clock-shaped
/// snoozes, timer-worded snoozes).
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

    func testEnglishHourUnitTimer() {
        let timer = AlarmTimerCommandParser.parseTimer("1 hour timer")
        XCTAssertEqual(timer?.durationSeconds, 3600)
    }

    func testCompoundDurationParsesIntoSingleTimer() {
        // 2026-09-08: compound chains are ONE duration, confirmed whole
        // — never truncated to the first unit.
        let english = AlarmTimerCommandParser.parseTimer("set a timer for 1 hour 30 minutes")
        XCTAssertEqual(english?.durationSeconds, 5400)
        XCTAssertNil(english?.label)
        let nepali = AlarmTimerCommandParser.parseTimer("टाइमर १ घण्टा ३० मिनेट")
        XCTAssertEqual(nepali?.durationSeconds, 5400)
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

    func testTwoSeparateCommandsAreNeverMerged() {
        // Honesty contract: two SEPARATE commands stay two commands —
        // never silently merged into one timer.
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "set a timer for 5 minutes, then one for 3 minutes"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "टाइमर ५ मिनेट, अनि अर्को ३ मिनेट"))
    }

    func testOutOfRangeDurationIsRejected() {
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("timer 25 hours"))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("timer 0 minutes"))
        // Compound totals obey the same bound: 25 h in two units is out.
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("timer 1 hour 24 hours"))
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
        // A clock alarm phrase carries no duration unit — it is never a
        // timer (alarm-worded COUNTDOWNS are the exception; see the
        // [NUMBER-WORDS] doctrine tests below).
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("set an alarm for 6 am"))
    }

    // MARK: - parseAlarmOff

    func testEnglishAlarmOffShapesParse() {
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("turn off the alarm"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("turn the alarm off"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("cancel my alarm"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("switch off the alarm"))
    }

    func testNepaliAlarmOffShapesParse() {
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म बन्द गर"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म बन्द गर्नुहोस्"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म बन्द गरिदिनुहोस्"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म बन्द गर्नुस्"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म रद्द गर"))
        XCTAssertTrue(AlarmTimerCommandParser.parseAlarmOff("अलार्म रद्द गर्नुहोस्"))
    }

    func testAlarmOffVetoes() {
        // Time-qualified cancellations name a specific alarm — the off
        // branch must not guess which one.
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("cancel the 6 am alarm"))
        // Questions and negations are not off commands.
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("when is my alarm?"))
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("don't turn off the alarm"))
        // "went off" is not a command — no verb token.
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("the alarm went off"))
        // No alarm marker — timer/bare-off talk is not this command.
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("turn off the timer"))
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("turn off the light"))
        // No off verb at all.
        XCTAssertFalse(AlarmTimerCommandParser.parseAlarmOff("अलार्म बज्यो"))
    }

    // MARK: - parseAlarmSnooze

    func testBareSnoozeParsesAsDefaultTenMinutes() {
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("snooze"), 10)
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("snooze the alarm"), 10)
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("स्नुज गर"), 10)
    }

    func testSnoozeWithMinutesParses() {
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("snooze for 15 minutes"), 15)
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("स्नुज १५ मिनेट"), 15)
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("snooze 5 mins"), 5)
        // The maximum accepted delay.
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze("snooze for 60 minutes"), 60)
    }

    func testSnoozeVetoes() {
        // Hour/second durations are not "ring again in N minutes".
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze for 2 hours"))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze for 30 seconds"))
        // Out-of-range, multi-duration and clock-shaped snoozes.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze for 90 minutes"))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze 10 minutes 20 minutes"))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze until 6:15"))
        // Questions, negations and timer business.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("how long is the snooze?"))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("don't snooze"))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze("snooze the timer"))
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

    // MARK: - [NUMBER-WORDS] number words (2026-09-10)

    func testBundledLexiconEntriesEachParseToTheirDuration() throws {
        // Data-driven: EVERY word form in the bundled per-locale
        // number-word lexicons must parse, through the unchanged
        // duration grammar, to value × 1 minute. Adding a language or
        // spelling variant = editing the JSON only; this test covers it
        // automatically — no per-word hand-written assertions.
        let cases: [(languageCode: String, locale: Locale, markerPrefix: String, unit: String)] = [
            ("ne", ne, "टाइमर", "मिनेट"),
            ("en", en, "set a timer for", "minutes")
        ]
        for entry in cases {
            guard let lexicon = try NumberWordLexicon.bundled(languageCode: entry.languageCode) else {
                throw XCTSkip("NumberWords/\(entry.languageCode).json not bundled yet")
            }
            XCTAssertFalse(lexicon.words.isEmpty, "the bundled lexicon must carry words")
            for (word, value) in lexicon.words {
                let timer = AlarmTimerCommandParser.parseTimer(
                    "\(entry.markerPrefix) \(word) \(entry.unit)", locale: entry.locale)
                XCTAssertEqual(timer?.durationSeconds, value * 60,
                               "\(word) (locale \(entry.languageCode)) must parse to \(value) minutes")
            }
        }
    }

    func testEnglishDigitWordsParseLikeDigits() {
        // The English fallback the pre-fix grammar never had in the
        // deterministic stage: digit words parse exactly like digits.
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "set a timer for five minutes", locale: en)?.durationSeconds, 300)
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "set a timer for twenty minutes", locale: en)?.durationSeconds, 1200)
    }

    func testNumberWordsMixWithDigitsInCompounds() {
        // A word/digit mix composes through the existing chain grammar,
        // exactly like the all-digit form ("टाइमर १ घण्टा ५ मिनेट").
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "टाइमर १ घण्टा पाँच मिनेट", locale: ne)?.durationSeconds, 3900)
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "टाइमर पांच मिनेट ३० सेकेण्ड", locale: ne)?.durationSeconds, 330)
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "set a timer for 1 hour five minutes", locale: en)?.durationSeconds, 3900)
        // The word forms leave no junk label behind (they normalize to
        // digits, which the label stripper drops).
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "टाइमर पाँच मिनेट", locale: ne)?.label)
    }

    func testSnoozeMinuteWordsParse() {
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze(
            "स्नुज पन्ध्र मिनेट", locale: ne), 15)
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze(
            "snooze for fifteen minutes", locale: en), 15)
        // Hour-worded snoozes stay out — snooze is a minute spec.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarmSnooze(
            "स्नुज एक घण्टा", locale: ne))
    }

    func testNepaliNumberWordAlarmClockTime() {
        let alarm = AlarmTimerCommandParser.parseAlarm(
            "बिहान सात बजे अलार्म लगाऊ", now: now, calendar: calendar, locale: ne)
        XCTAssertEqual(alarm?.time, date(2026, 9, 8, 7, 0))
        let halfPast = AlarmTimerCommandParser.parseAlarm(
            "साढे पाँच बजे अलार्म", now: now, calendar: calendar, locale: ne)
        XCTAssertEqual(halfPast?.time, date(2026, 9, 8, 5, 30))
    }

    func testUserPhrasePanchMinutKoAlarmLagaauParsesAsFiveMinuteTimer() {
        // The user-reported phrase, at the parser level: an alarm-worded
        // countdown with an explicit duration unit is a 5-MINUTE TIMER
        // (doctrine extension) — never a 5 o'clock alarm, whose pre-fix
        // hazard was the digit form falling through the countdown veto
        // while "मिनुट" was missing from the unit vocabulary.
        let timer = AlarmTimerCommandParser.parseTimer(
            "पांच मिनुटको अलार्म लगाऊ", locale: ne)
        XCTAssertEqual(timer?.durationSeconds, 300)
        XCTAssertNil(timer?.label)
        // The alarm parser still vetoes countdowns (safety net), word
        // and digit spellings alike.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "पांच मिनुटको अलार्म लगाऊ", now: now, calendar: calendar, locale: ne))
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "५ मिनुटको अलार्म लगाऊ", now: now, calendar: calendar, locale: ne),
            "the digit spelling must get the same countdown veto")
        // Safety: a bare clock phrase has no duration unit — it is NOT a
        // timer and stays an alarm.
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "५ बजेको अलार्म लगाऊ", locale: ne))
    }

    func testAlarmWordedCountdownsParseAsTimers() {
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "set an alarm in 5 minutes", locale: en)?.durationSeconds, 300)
        XCTAssertEqual(AlarmTimerCommandParser.parseTimer(
            "पाँच मिनेटमा अलार्म लगाऊ", locale: ne)?.durationSeconds, 300)
        // Out-of-range alarm-worded countdowns stay rejected.
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "set an alarm in 25 hours", locale: en))
        // Snooze-worded durations are snooze business, never a timer.
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "snooze the alarm for 5 minutes", locale: en))
        XCTAssertEqual(AlarmTimerCommandParser.parseAlarmSnooze(
            "snooze the alarm for 5 minutes", locale: en), 5)
    }

    func testNumberWordRewritesAreContextGuarded() {
        // The copula "छ" is never a number: "अलार्म छ?" (is there an
        // alarm?) must not become "alarm 6?" → a 6 o'clock alarm.
        XCTAssertEqual(NumberWordNormalizer.normalise("अलार्म छ?", locale: ne),
                       "अलार्म छ?")
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "अलार्म छ?", now: now, calendar: calendar, locale: ne))
        XCTAssertNil(AlarmTimerCommandParser.parseTimer("अलार्म छ?", locale: ne))
        // "एक" inside another word is a different token.
        XCTAssertNil(AlarmTimerCommandParser.parseAlarm(
            "एकछिन पछि अलार्म बजाऊ", now: now, calendar: calendar, locale: ne))
        // Multi-word English numbers are never partially rewritten
        // ("forty five minutes" must not become "forty 5 minutes").
        XCTAssertEqual(NumberWordNormalizer.normalise(
            "timer for forty five minutes", locale: en),
            "timer for forty five minutes")
        XCTAssertNil(AlarmTimerCommandParser.parseTimer(
            "timer for forty five minutes", locale: en))
    }

    func testNumberWordNormalizerIsIdentityWithoutLexicon() {
        // A locale with no bundled lexicon degrades to the identity
        // transform — the utterance falls through exactly as before.
        let unknown = Locale(identifier: "fr-FR")
        XCTAssertEqual(NumberWordNormalizer.normalise("टाइमर पाँच मिनेट", locale: unknown),
                       "टाइमर पाँच मिनेट")
    }
}
