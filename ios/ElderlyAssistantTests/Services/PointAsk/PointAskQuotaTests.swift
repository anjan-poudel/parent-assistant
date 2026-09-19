import XCTest
@testable import ElderlyAssistant

/// [POINT-TAP-ASK] (2026-09-19) Daily attempt-cap contract — a mirror of
/// the `SearchQuota` battery:
///  - 50/day is the shipped limit;
///  - the bucket stamps are yyyyMMdd day stamps;
///  - only today's bucket eats today's budget — a previous-day count
///    rolls over on read AND on increment, and remaining clamps at 0;
///  - `reset` zeroes the bucket.
final class PointAskQuotaTests: XCTestCase {

    private var quotaDefaults: UserDefaults!
    private var quotaSuiteName: String!

    /// UTC Gregorian — the bucket stamps are pure date math; pinning the
    /// calendar keeps assertions independent of the test machine's zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    override func setUp() {
        super.setUp()
        quotaSuiteName = "PointAskQuotaTests.\(UUID().uuidString)"
        quotaDefaults = UserDefaults(suiteName: quotaSuiteName)
    }

    override func tearDown() {
        quotaDefaults.removePersistentDomain(forName: quotaSuiteName)
        quotaDefaults = nil
        quotaSuiteName = nil
        super.tearDown()
    }

    func testDayStampFormatsUtcGregorianDate() {
        let utc = utcCalendar
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PointAskQuota.dayStamp(for: epoch, calendar: utc), "19700101")
        XCTAssertEqual(PointAskQuota.dayStamp(for: epoch.addingTimeInterval(86_400), calendar: utc),
                       "19700102")
        XCTAssertEqual(PointAskQuota.dailyLimit, 50, "50/day is the shipped cap")
    }

    func testRemainingIsFullLimitOnFreshDefaults() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PointAskQuota.remaining(today: today,
                                               count: PointAskQuota.readCount(defaults: quotaDefaults),
                                               limit: PointAskQuota.dailyLimit,
                                               defaults: quotaDefaults,
                                               calendar: utcCalendar),
                       PointAskQuota.dailyLimit)
    }

    func testRemainingCountsOnlyTodaysConsumption() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        quotaDefaults.set(PointAskQuota.dayStamp(for: today, calendar: utc),
                          forKey: PointAskQuota.dayKey)
        quotaDefaults.set(3, forKey: PointAskQuota.countKey)

        XCTAssertEqual(PointAskQuota.remaining(today: today, count: 3, limit: 50,
                                               defaults: quotaDefaults, calendar: utc),
                       47)
    }

    func testRemainingNeverGoesBelowZero() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        quotaDefaults.set(PointAskQuota.dayStamp(for: today, calendar: utc),
                          forKey: PointAskQuota.dayKey)
        quotaDefaults.set(60, forKey: PointAskQuota.countKey)

        XCTAssertEqual(PointAskQuota.remaining(today: today, count: 60, limit: 50,
                                               defaults: quotaDefaults, calendar: utc),
                       0, "the cap is a hard ceiling — remaining clamps at zero")
    }

    func testStalePreviousDayCountDoesNotConsumeTodaysBudget() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        // 49 attempts yesterday — a fresh day must not inherit them.
        quotaDefaults.set(PointAskQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: PointAskQuota.dayKey)
        quotaDefaults.set(49, forKey: PointAskQuota.countKey)

        XCTAssertEqual(PointAskQuota.remaining(today: today, count: 49, limit: 50,
                                               defaults: quotaDefaults, calendar: utc),
                       50, "a previous-day count never eats today's budget")
    }

    func testIncrementAccumulatesWithinTheDay() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(PointAskQuota.increment(defaults: quotaDefaults,
                                               now: today, calendar: utc), 1)
        XCTAssertEqual(PointAskQuota.increment(defaults: quotaDefaults,
                                               now: today, calendar: utc), 2)
        XCTAssertEqual(PointAskQuota.readCount(defaults: quotaDefaults), 2)
        XCTAssertEqual(PointAskQuota.remaining(today: today, count: 2, limit: 50,
                                               defaults: quotaDefaults, calendar: utc),
                       48)
        XCTAssertEqual(quotaDefaults.string(forKey: PointAskQuota.dayKey),
                       PointAskQuota.dayStamp(for: today, calendar: utc))
    }

    func testIncrementStartsANewBucketOnTheNextDay() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        quotaDefaults.set(PointAskQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: PointAskQuota.dayKey)
        quotaDefaults.set(49, forKey: PointAskQuota.countKey)

        // Rollover-safe: the first attempt of the new day is 1, never
        // yesterday's total + 1.
        XCTAssertEqual(PointAskQuota.increment(defaults: quotaDefaults,
                                               now: today, calendar: utc), 1)
        XCTAssertEqual(quotaDefaults.string(forKey: PointAskQuota.dayKey),
                       PointAskQuota.dayStamp(for: today, calendar: utc))
    }

    func testReadCountIsRawAndResetClearsEverything() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        quotaDefaults.set(PointAskQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: PointAskQuota.dayKey)
        quotaDefaults.set(49, forKey: PointAskQuota.countKey)

        // readCount is the RAW stored count — day normalization belongs
        // to `remaining`.
        XCTAssertEqual(PointAskQuota.readCount(defaults: quotaDefaults), 49)

        PointAskQuota.reset(defaults: quotaDefaults)
        XCTAssertEqual(PointAskQuota.readCount(defaults: quotaDefaults), 0)
        XCTAssertNil(quotaDefaults.string(forKey: PointAskQuota.dayKey))
        XCTAssertEqual(PointAskQuota.remaining(today: today, count: 0, limit: 50,
                                               defaults: quotaDefaults, calendar: utc),
                       50)
    }
}
