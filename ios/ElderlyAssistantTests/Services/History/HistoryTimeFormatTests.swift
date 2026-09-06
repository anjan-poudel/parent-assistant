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
