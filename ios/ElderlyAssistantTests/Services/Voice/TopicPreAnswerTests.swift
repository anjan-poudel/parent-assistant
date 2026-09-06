import XCTest
@testable import ElderlyAssistant

/// [NO-GIBBERISH] (2026-09-07) Unit tests for the deterministic topic
/// pre-answer table (`TopicPreAnswer`) that `CommandRouter` consults
/// before any model: weather / time / date / greeting questions must match
/// conservatively (whole-token semantics for topic words, substring for
/// multi-word phrases, safety-critical vetoes) and the replies must be
/// deterministic — the exact spoken sentence is pinned below with an
/// injected clock and time zone.
final class TopicPreAnswerTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en-US")

    // MARK: - Weather matching

    func testWeatherNepali() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "भोलिको मौसम कस्तो छ?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "भोलि मौसम कस्तो हुन्छ"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "आज मौसम राम्रो छ"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "पानी पर्छ कि पर्दैन?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "आज घाम लाग्यो कि?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "बादल लागेको छ, हिउँ पर्ने हो?"), .weather)
    }

    func testWeatherEnglish() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "what's the weather like today?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Will it rain tomorrow?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "is it raining outside"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "check the forecast for me"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Is it sunny in Kathmandu?"), .weather)
    }

    func testWeatherWordInsideLongerWordDoesNotMatch() {
        // Whole-token semantics: "मौसमी" (seasonal) must not match
        // "मौसम", and no weather phrase is contained either.
        XCTAssertNil(TopicPreAnswer.match(transcript: "मौसमी फल किन्ने हो"))
    }

    // MARK: - Time matching

    func testTimeNepali() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "अहिले कति बजे भयो?"), .time)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "कति बजेको छ?"), .time)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "के समय भयो?"), .time)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "अहिलेको समय के हो?"), .time)
    }

    func testTimeEnglish() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "What time is it?"), .time)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Do you know the time?"), .time)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Tell me the current time"), .time)
    }

    // MARK: - Date matching

    func testDateNepali() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "आज कति गते हो?"), .date)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "आज कुन दिन हो?"), .date)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "कुन तारिख परेको छ?"), .date)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "अहिले कति साल चलेको छ?"), .date)
    }

    func testDateEnglish() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "What's the date today?"), .date)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "What day is today?"), .date)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Tell me today's date"), .date)
    }

    // MARK: - Greeting matching

    func testGreeting() {
        XCTAssertEqual(TopicPreAnswer.match(transcript: "नमस्ते"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "नमस्कार दाई!"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "सुप्रभात"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "hello"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "Hi, are you there?"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "good morning"), .greeting)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "  NAMASTE  "), .greeting)
    }

    // MARK: - Compound utterances: the most specific topic wins

    func testCompoundGreetingPlusWeatherResolvesToWeather() {
        // Weather is matched before greeting, so a greeting prefix can
        // never shadow a real question.
        XCTAssertEqual(TopicPreAnswer.match(transcript: "नमस्ते, भोलिको मौसम कस्तो छ?"), .weather)
        XCTAssertEqual(TopicPreAnswer.match(transcript: "hello! will it rain today?"), .weather)
    }

    // MARK: - Safety vetoes: medication/reminder talk is NOT small talk

    func testMedicationVetoKeepsDoseTalkOffTheSmallTalkTable() {
        XCTAssertNil(TopicPreAnswer.match(transcript: "औषधि कति बजे खाने?"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "दवाई कति गते सकिन्छ?"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "मेरो औषधिको समय के हो?"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "when is my next dose?"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "set a reminder at 8"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "बिहान ८ बजे रिमाइन्डर सेट गर"))
    }

    func testWeatherIsNotVetoedByMedicationMarker() {
        // Weather tokens are distinctive enough that the veto does not
        // apply — a weather question wins even if medication words occur
        // in the same utterance (medication markers veto time/date/
        // greeting only).
        XCTAssertEqual(TopicPreAnswer.match(transcript: "मौसम कस्तो छ, औषधि लिएर हिँड्ने बेला भयो?"), .weather)
    }

    func testUnrelatedUtterancesDoNotMatch() {
        XCTAssertNil(TopicPreAnswer.match(transcript: "केही राम्रो कथा सुनाउनुस्"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "मलाई एउटा भजन बजाउनुस्"))
        XCTAssertNil(TopicPreAnswer.match(transcript: "भोलि काठमाडौं जाने हो"))
        XCTAssertNil(TopicPreAnswer.match(transcript: ""))
    }

    // MARK: - Reply determinism (injected clock + time zone)

    /// 2026-09-06 (Sunday) at the given hour/minute in Asia/Kathmandu.
    private func ktm(_ hour: Int, _ minute: Int) -> (Date, TimeZone) {
        let tz = TimeZone(identifier: "Asia/Kathmandu")!
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 6
        c.hour = hour; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return (cal.date(from: c)!, tz)
    }

    func testTimeReplyNepaliOnTheHour() {
        let (now, tz) = ktm(9, 0)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: now, timeZone: tz),
                       "अहिले बिहान ९ बजेको छ।")
    }

    func testTimeReplyNepaliWithMinutes() {
        let (now, tz) = ktm(9, 30)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: now, timeZone: tz),
                       "अहिले बिहान ९ बजेर ३० मिनेट भयो।")
    }

    func testTimeReplyNepaliEveningAndNight() {
        let (evening, tzE) = ktm(18, 15)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: evening, timeZone: tzE),
                       "अहिले बेलुका ६ बजेर १५ मिनेट भयो।")
        let (night, tzN) = ktm(21, 45)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: night, timeZone: tzN),
                       "अहिले राति ९ बजेर ४५ मिनेट भयो।")
    }

    func testTimeReplyNepaliNoonUsesTwelve() {
        // 12:00 → hour12 is 12 (not 0), and the afternoon period starts
        // at 12.
        let (noon, tz) = ktm(12, 0)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: noon, timeZone: tz),
                       "अहिले दिउँसो १२ बजेको छ।")
    }

    func testTimeReplyNepaliMidnight() {
        let (midnight, tz) = ktm(0, 30)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: ne, now: midnight, timeZone: tz),
                       "अहिले राति १२ बजेर ३० मिनेट भयो।")
    }

    func testTimeReplyEnglishPinsMeridiemPhrasing() {
        let (now, tz) = ktm(14, 5)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: en, now: now, timeZone: tz),
                       "It's 2:05 in the afternoon.")
        let (morning, tzM) = ktm(9, 0)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: en, now: morning, timeZone: tzM),
                       "It's 9 in the morning.")
        let (night, tzN) = ktm(22, 40)
        XCTAssertEqual(TopicPreAnswer.reply(for: .time, locale: en, now: night, timeZone: tzN),
                       "It's 10:40 at night.")
    }

    func testDateReplyNepaliPinsWeekdayAndBikramSambat() {
        // 2026-09-06 is a Sunday = आइतबार; per the BikramSambat anchor
        // table (BikramSambatTests.testTodayIsExpectedBSDate) it is
        // भदौ २१, २०८३.
        //
        // The date is built in the HOST calendar (like BikramSambatTests'
        // greg helper) and the reply reads it in that same `.current`
        // time zone — BikramSambat.bsDate re-bases its fixed anchor into
        // the CALENDAR's time zone, so injecting a time zone that differs
        // from the host's (e.g. Asia/Kathmandu on a UTC host) shifts the
        // day count by one. Production calls this with `.current`, so the
        // test must too.
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 6; c.hour = 10
        let now = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(TopicPreAnswer.reply(for: .date, locale: ne, now: now),
                       "आज आइतबार, भदौ २१, २०८३ हो।")
    }

    func testDateReplyEnglishPinsGregorianFullDate() {
        let (now, tz) = ktm(10, 0)
        let reply = TopicPreAnswer.reply(for: .date, locale: en, now: now, timeZone: tz)
        XCTAssertTrue(reply.hasPrefix("Today is "), "unexpected: \(reply)")
        XCTAssertTrue(reply.contains("Sunday, September 6, 2026"),
                      "full Gregorian date expected, got: \(reply)")
    }

    // MARK: - Fixed-topic replies resolve from the catalog

    func testWeatherAndGreetingRepliesAreTheCatalogText() {
        XCTAssertEqual(TopicPreAnswer.reply(for: .weather, locale: ne),
                       L10n.str("topic.weather.unavailable", locale: ne))
        XCTAssertEqual(TopicPreAnswer.reply(for: .weather, locale: en),
                       L10n.str("topic.weather.unavailable", locale: en))
        XCTAssertEqual(TopicPreAnswer.reply(for: .greeting, locale: ne),
                       L10n.str("topic.greeting", locale: ne))
        XCTAssertNotEqual(TopicPreAnswer.reply(for: .weather, locale: ne),
                          TopicPreAnswer.reply(for: .greeting, locale: ne))
    }
}
