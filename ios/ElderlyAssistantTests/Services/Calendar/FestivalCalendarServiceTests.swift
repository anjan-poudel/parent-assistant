import XCTest
@testable import ElderlyAssistant

final class FestivalCalendarServiceTests: XCTestCase {

    private func greg(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func makeService() -> FestivalCalendarService {
        FestivalCalendarService(observabilityBus: MockObservabilityBus())
    }

    func testTodayOverlayHasTithiForEveryDay() {
        // A day with NO festival must still produce a tithi (product
        // requirement: tithi AND BS date on every calendar day).
        let overlay = makeService().todayOverlay(on: greg(2026, 9, 7))
        XCTAssertNotNil(overlay)
        XCTAssertTrue(overlay!.festivals.isEmpty, "2026-09-07 has no catalog festival")
        XCTAssertFalse(overlay!.tithi.displayNepali.isEmpty)
        XCTAssertFalse(overlay!.weekdayNepali.isEmpty)
    }

    func testBijayaDashamiOverlay() {
        // Bijaya Dashami 2083 = Ashwin 10, 2083 BS. Compute its AD date
        // via the same table, then check the overlay finds it.
        let bs = BikramSambat.BSDate(year: 2083, month: 6, day: 10)
        let ad = BikramSambat.adDate(from: bs)!
        let overlay = makeService().todayOverlay(on: ad)
        XCTAssertEqual(overlay?.festivals.map(\.id), ["bijaya_dashami"])
        XCTAssertEqual(overlay?.festivals.first?.tithiNepali, "दशमी")
    }

    func testUpcomingFestivalsAreSortedAndFuture() {
        let upcoming = makeService().upcoming(after: greg(2026, 9, 6), limit: 5)
        XCTAssertEqual(upcoming.count, 5)
        for item in upcoming {
            XCTAssertGreaterThanOrEqual(item.daysAway, 0)
        }
        let dates = upcoming.map(\.adDate)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testUpcomingCrossesBSYearBoundary() {
        // Late in the BS year, upcoming must roll into the next year.
        // Chaitra 25, 2083:
        let bs = BikramSambat.BSDate(year: 2083, month: 12, day: 25)
        let ad = BikramSambat.adDate(from: bs)!
        let upcoming = makeService().upcoming(after: ad, limit: 3)
        XCTAssertTrue(upcoming.contains { $0.festival.id == "nepali_new_year" },
                      "crossing into BS 2084 must still find New Year")
    }

    func testFestivalCatalogHasNoDuplicateIds() {
        let ids = NepaliFestivalCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAdvanceReminderDaysDefaultsToTwo() {
        let svc = makeService()
        // Clear any persisted value for a deterministic check.
        UserDefaults.standard.removeObject(forKey: FestivalCalendarService.advanceDaysDefaultsKey)
        XCTAssertEqual(svc.advanceReminderDays, 2)
    }

    func testAdvanceReminderDaysPersists() {
        let svc = makeService()
        svc.advanceReminderDays = 5
        XCTAssertEqual(UserDefaults.standard.integer(forKey: FestivalCalendarService.advanceDaysDefaultsKey), 5)
        svc.advanceReminderDays = 2   // restore default for other tests
    }
}
