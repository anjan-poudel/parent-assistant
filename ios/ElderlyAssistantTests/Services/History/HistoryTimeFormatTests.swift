import XCTest
@testable import ElderlyAssistant

/// Time bucketing for Recent activity rows (call-history task,
/// 2026-09-06). `HistoryTimeFormat.displayString(for:now:calendar:locale:)`
/// is pure — `now` and the calendar are injected — so these tests pin a
/// fixed "now" (2026-09-06 12:00 UTC, Gregorian) and assert the buckets
/// in BOTH catalog languages.
final class HistoryTimeFormatTests: XCTestCase {

    /// Gregorian calendar in UTC — buckets must not depend on the
    /// machine's local timezone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-09-06 12:00:00 UTC.
    private var now: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 6,
                                              hour: 12, minute: 0, second: 0))!
    }

    private func date(daysAgo: Int, secondsFromNoon: TimeInterval = 0) -> Date {
        let day = utcCalendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return day.addingTimeInterval(secondsFromNoon)
    }

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Buckets

    func testUnderMinuteIsJustNowInBothLanguages() {
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 0, secondsFromNoon: -30),
                                                       now: now, calendar: utcCalendar, locale: en),
                       "Just now")
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 0, secondsFromNoon: -30),
                                                       now: now, calendar: utcCalendar, locale: ne),
                       "भर्खरै")
    }

    /// A timestamp less than a minute into the FUTURE (clock skew) must
    /// not render "Just now" — it falls through to the same-day bucket.
    func testFutureSubMinuteFallsToTodayNotJustNow() {
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 0, secondsFromNoon: 30),
                                                       now: now, calendar: utcCalendar, locale: en),
                       "Today")
    }

    func testSameDayIsTodayInBothLanguages() {
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 0, secondsFromNoon: -2 * 3600),
                                                       now: now, calendar: utcCalendar, locale: en),
                       "Today")
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 0, secondsFromNoon: -2 * 3600),
                                                       now: now, calendar: utcCalendar, locale: ne),
                       "आज")
    }

    func testYesterdayIsYesterdayInBothLanguages() {
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 1),
                                                       now: now, calendar: utcCalendar, locale: en),
                       "Yesterday")
        XCTAssertEqual(HistoryTimeFormat.displayString(for: date(daysAgo: 1),
                                                       now: now, calendar: utcCalendar, locale: ne),
                       "हिजो")
    }

    // MARK: - Older fallback (localized short date)

    /// Older rows fall back to a SHORT DATE in the requested locale —
    /// never to an English default and never to a bucket word. Expected
    /// string is computed with the same DateFormatter configuration the
    /// implementation uses, so the assertion pins the LOCALE flow (and
    /// timezone behavior) without hardcoding ICU output.
    func testOlderThanYesterdayFallsBackToShortDateInLocale() {
        let timestamp = date(daysAgo: 3)
        let enResult = HistoryTimeFormat.displayString(for: timestamp,
                                                       now: now, calendar: utcCalendar, locale: en)
        XCTAssertEqual(enResult, shortDate(timestamp, locale: en))
        XCTAssertNotEqual(enResult, "Today")
        XCTAssertNotEqual(enResult, "Yesterday")

        let neResult = HistoryTimeFormat.displayString(for: timestamp,
                                                       now: now, calendar: utcCalendar, locale: ne)
        XCTAssertEqual(neResult, shortDate(timestamp, locale: ne))
        XCTAssertNotEqual(neResult, "आज")
        XCTAssertNotEqual(neResult, "हिजो")
    }

    /// The boundary itself: exactly 24h+ back but crossing into the day
    /// before yesterday is "older" (isDateInYesterday is day-based).
    func testDayBeforeYesterdayIsOlderFallback() {
        let timestamp = date(daysAgo: 2)
        XCTAssertEqual(HistoryTimeFormat.displayString(for: timestamp,
                                                       now: now, calendar: utcCalendar, locale: en),
                       shortDate(timestamp, locale: en))
    }

    private func shortDate(_ timestamp: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: timestamp)
    }
}

/// The minutes-aware line the Home missed-call tile renders
/// (call-tracking task, 2026-09-13) — same purity contract as
/// `displayString`: `now`, the calendar and the locale are injected, so a
/// pinned "now" fully determines the answer. Nepali numerals follow the
/// app's spoken convention (SpokenTime): Devanagari digits.
final class HistoryTimeFormatRelativeTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 6,
                                              hour: 12, minute: 0, second: 0))!
    }

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    private func secondsAgo(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    /// Under a minute stays "Just now" (the same bucket the rows use) in
    /// both languages.
    func testSubMinuteStaysJustNow() {
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(30), now: now,
                                                        calendar: utcCalendar, locale: en),
                       "Just now")
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(30), now: now,
                                                        calendar: utcCalendar, locale: ne),
                       "भर्खरै")
    }

    /// Minutes below the hour, with Devanagari numerals in Nepali — the
    /// tile's headline case ("छुटेको कल: बुबा · १० मिनेट अघि").
    func testMinutesBucketInBothLanguages() {
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(600), now: now,
                                                        calendar: utcCalendar, locale: en),
                       "10 minutes ago")
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(600), now: now,
                                                        calendar: utcCalendar, locale: ne),
                       "१० मिनेट अघि")
    }

    /// One minute is the first minute bucket (60s exactly) and reads
    /// singular; 59 minutes is still minutes — the hour boundary belongs
    /// to the hours bucket.
    func testMinuteBucketBoundaries() {
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(60), now: now,
                                                        calendar: utcCalendar, locale: en),
                       "1 minute ago")
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(3599), now: now,
                                                        calendar: utcCalendar, locale: en),
                       "59 minutes ago")
    }

    /// Hours below the day bucket, Devanagari in Nepali, singular at one.
    func testHoursBucketInBothLanguages() {
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(3600), now: now,
                                                        calendar: utcCalendar, locale: en),
                       "1 hour ago")
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: secondsAgo(3 * 3600), now: now,
                                                        calendar: utcCalendar, locale: ne),
                       "३ घण्टा अघि")
    }

    /// Older than a day falls back to `displayString`'s day buckets — the
    /// relative line never claims precision it does not have ("Yesterday",
    /// then a date).
    func testOlderThanADayFallsBackToDayBuckets() {
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: yesterday, now: now,
                                                        calendar: utcCalendar, locale: en),
                       "Yesterday")
        let threeDaysAgo = utcCalendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: threeDaysAgo, now: now,
                                                        calendar: utcCalendar, locale: en),
                       shortDate(threeDaysAgo, locale: en))
    }

    /// A timestamp a little into the future (clock skew) never renders
    /// "Just now" — it takes the same-day bucket, exactly as
    /// `displayString` does.
    func testFutureTimestampFallsToToday() {
        XCTAssertEqual(HistoryTimeFormat.relativeString(for: now.addingTimeInterval(30),
                                                        now: now, calendar: utcCalendar, locale: en),
                       "Today")
    }

    private func shortDate(_ timestamp: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: timestamp)
    }
}

/// The Home missed-call tile's data source (call-tracking task,
/// 2026-09-13): the log lookup, resolved into the two lines the tile
/// renders. Drives `AppActivityLog.lastMissedCall` and
/// `MissedCallPresentation.resolve` together, the way HomeView wires
/// them, so the tile's content is pinned without building a coordinator
/// (which the tests cannot do).
final class MissedCallTileSourceTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 6,
                                              hour: 12, minute: 0, second: 0))!
    }

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    private func missedRow(name: String, secondsAgo: TimeInterval) -> AppActivityEntry {
        AppActivityEntry(timestamp: now.addingTimeInterval(-secondsAgo),
                         kind: .call, channel: .unanswered,
                         contactName: name, phone: name.isEmpty ? "" : "9812345678")
    }

    /// The headline case, verbatim: an attributed missed call ten minutes
    /// ago reads "छुटेको कल: बुबा · १० मिनेट अघि" in Nepali.
    func testAttributedMissedCallRendersLabelNameAndRelativeTime() {
        let entry = missedRow(name: "बुबा", secondsAgo: 600)
        let presentation = MissedCallPresentation.resolve(entry, now: now,
                                                          calendar: utcCalendar, locale: ne)

        XCTAssertEqual(presentation.title, "छुटेको कल: बुबा")
        XCTAssertEqual(presentation.time, "१० मिनेट अघि")
        XCTAssertEqual(presentation.line, "छुटेको कल: बुबा · १० मिनेट अघि")
    }

    /// The anonymous shape: no name exists (iOS masked it), so the label
    /// stands alone — the tile never invents a caller.
    func testAnonymousMissedCallRendersLabelAlone() {
        let entry = missedRow(name: "", secondsAgo: 120)
        let presentation = MissedCallPresentation.resolve(entry, now: now,
                                                          calendar: utcCalendar, locale: en)

        XCTAssertEqual(presentation.title, "Missed call")
        XCTAssertEqual(presentation.time, "2 minutes ago")
        XCTAssertEqual(presentation.line, "Missed call · 2 minutes ago")
    }

    /// End to end over the tile's real data source: the newest missed
    /// call inside the window is the one the tile would show, and a log
    /// with only older/non-missed rows yields no tile at all.
    func testTileSourcePicksTheNewestMissedCallInsideTheWindow() {
        let entries = [
            missedRow(name: "", secondsAgo: 40),
            AppActivityEntry(timestamp: now.addingTimeInterval(-60), kind: .call,
                             channel: .phone, contactName: "बुबा", phone: "9812345678"),
            missedRow(name: "बुबा", secondsAgo: 600)
        ]
        let entry = AppActivityLog.lastMissedCall(in: entries, now: now)
        XCTAssertEqual(entry?.contactName, "")

        let presentation = MissedCallPresentation.resolve(entry!, now: now,
                                                          calendar: utcCalendar, locale: en)
        XCTAssertEqual(presentation.line, "Missed call · Just now")
    }

    /// No missed call in the window → no presentation → Home renders no
    /// tile (the no-mockups rule the briefing panel follows too).
    func testNoMissedCallInsideWindowYieldsNoTile() {
        let stale = [missedRow(name: "बुबा",
                               secondsAgo: AppActivityLog.missedCallWindow + 60)]
        XCTAssertNil(AppActivityLog.lastMissedCall(in: stale, now: now))

        let onlyAnswered = [AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                             kind: .call, channel: .phone,
                                             contactName: "बुबा", phone: "9812345678")]
        XCTAssertNil(AppActivityLog.lastMissedCall(in: onlyAnswered, now: now))
    }
}

/// The shared row text both call surfaces render (call-tracking task,
/// 2026-09-13): the name line and the caption that now marks a missed row
/// explicitly.
final class ActivityRowTextTests: XCTestCase {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 6,
                                              hour: 12, minute: 0, second: 0))!
    }

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// An anonymous missed row keeps the localized "Unanswered call" name
    /// line (it has no stored name); an attributed one shows its contact.
    func testNameLineDistinguishesAnonymousFromAttributed() {
        let anonymous = AppActivityEntry(kind: .call, channel: .unanswered,
                                         contactName: "", phone: "")
        let attributed = AppActivityEntry(kind: .call, channel: .unanswered,
                                          contactName: "बुबा", phone: "9812345678")

        XCTAssertEqual(ActivityRowText.name(for: anonymous, locale: ne), "नउठाएको कल")
        XCTAssertEqual(ActivityRowText.name(for: attributed, locale: ne), "बुबा")
    }

    /// The caption marks a missed row explicitly — "Missed call · Just now"
    /// — while call and message rows keep their kind label. Fixtures sit
    /// 30s back on purpose: `displayString`'s "Just now" bucket is strictly
    /// under a minute, so an even-60s row would already read "Today".
    func testCaptionMarksMissedRowsAndKeepsKindLabels() {
        let missed = AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                      kind: .call, channel: .unanswered,
                                      contactName: "बुबा", phone: "9812345678")
        let call = AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                    kind: .call, channel: .phone,
                                    contactName: "बुबा", phone: "9812345678")
        let message = AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                                       kind: .message, channel: .whatsapp,
                                       contactName: "सीता", phone: "9800000000")

        XCTAssertEqual(ActivityRowText.caption(for: missed, now: now,
                                               calendar: utcCalendar, locale: en),
                       "Missed call · Just now")
        XCTAssertEqual(ActivityRowText.caption(for: missed, now: now,
                                               calendar: utcCalendar, locale: ne),
                       "छुटेको कल · भर्खरै")
        XCTAssertEqual(ActivityRowText.caption(for: call, now: now,
                                               calendar: utcCalendar, locale: en),
                       "Call · Just now")
        XCTAssertEqual(ActivityRowText.caption(for: message, now: now,
                                               calendar: utcCalendar, locale: en),
                       "Message · Just now")
    }
}
