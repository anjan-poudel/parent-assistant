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

    private func festival(_ id: String) -> NepaliFestival {
        guard let f = NepaliFestivalCatalog.all.first(where: { $0.id == id }) else {
            fatalError("catalog is missing \(id)")
        }
        return f
    }

    private func resolved(_ id: String, _ bsYear: Int) -> NepaliFestival.ResolvedDate? {
        festival(id).resolvedDate(inBSYear: bsYear)
    }

    /// AD date the catalog resolves for a festival's BS year, as
    /// (year, month, day) in the same calendar the service uses.
    private func adComponents(_ id: String, _ bsYear: Int) -> (Int, Int, Int)? {
        guard let resolved = resolved(id, bsYear),
              let ad = BikramSambat.adDate(from: resolved.bsDate) else { return nil }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: ad)
        return (c.year!, c.month!, c.day!)
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

    // MARK: - Teej + Dar Khane Din (the 2026-09-13 audit)

    func testHaritalikaTeejDatesMatchPublishedPanchang() {
        // Haritalika Teej = Bhadra Shukla Tritiya. Sources: the published
        // Nepali patro (nepalicalendar.rat32.com) month pages, and the
        // Nepal government / NRB 2083 holiday list ("हरितालिका (तीज) व्रत
        // — भदौ २९, २०८३", women employees only). The OLD catalog had this
        // on Bhadra 3 — 26 days early in 2083.
        XCTAssertEqual(resolved("haritalika_teej", 2082)?.bsDate,
                       BikramSambat.BSDate(year: 2082, month: 5, day: 10))
        XCTAssertEqual(resolved("haritalika_teej", 2083)?.bsDate,
                       BikramSambat.BSDate(year: 2083, month: 5, day: 29))
        XCTAssertEqual(resolved("haritalika_teej", 2084)?.bsDate,
                       BikramSambat.BSDate(year: 2084, month: 5, day: 18))

        let y = adComponents("haritalika_teej", 2083)
        XCTAssertEqual(y?.0, 2026); XCTAssertEqual(y?.1, 9); XCTAssertEqual(y?.2, 14)
        let prev = adComponents("haritalika_teej", 2082)
        XCTAssertEqual(prev?.0, 2025); XCTAssertEqual(prev?.1, 8); XCTAssertEqual(prev?.2, 26)
        let next = adComponents("haritalika_teej", 2084)
        XCTAssertEqual(next?.0, 2027); XCTAssertEqual(next?.1, 9); XCTAssertEqual(next?.2, 3)
    }

    func testDarKhaneDinIsTheDayBeforeTeej() {
        // Dar Khane Din = Bhadra Shukla Dwitiya — the day before Teej.
        // It was MISSING from the catalog entirely before the audit.
        for year in [2082, 2083, 2084] {
            let dar = resolved("dar_khane_din", year)?.bsDate
            let teej = resolved("haritalika_teej", year)?.bsDate
            XCTAssertNotNil(dar, "Dar Khane Din must resolve for BS \(year)")
            XCTAssertEqual(dar?.year, teej?.year)
            XCTAssertEqual(dar?.month, teej?.month)
            XCTAssertEqual(dar?.day, (teej?.day ?? 0) - 1,
                           "Dar Khane Din BS \(year) must be the day before Teej")
        }
        let y = adComponents("dar_khane_din", 2083)
        XCTAssertEqual(y?.0, 2026); XCTAssertEqual(y?.1, 9); XCTAssertEqual(y?.2, 13)
    }

    func testTeejIsNotOnItsOldFixedBSDay() {
        // The regression this whole change exists for: a fixed Bhadra 3
        // is only right in years where the tithi happens to land there.
        for year in [2082, 2083, 2084] {
            XCTAssertNotEqual(resolved("haritalika_teej", year)?.bsDate,
                              BikramSambat.BSDate(year: year, month: 5, day: 3),
                              "Teej \(year) must be tithi-anchored, not fixed at Bhadra 3")
        }
        XCTAssertFalse(resolved("haritalika_teej", 2083)!.isApproximate,
                       "2083 is table-covered — the date must not be an estimate")
    }

    func testOverlaysFindTeejClusterInBhadra2083() {
        let service = makeService()
        // Kushe Aunsi Bhadra 26 (Sep 11), Dar Khane Din Bhadra 28
        // (Sep 13), Teej Bhadra 29 (Sep 14), Rishi Panchami Bhadra 30
        // (Sep 15).
        XCTAssertEqual(service.todayOverlay(on: greg(2026, 9, 11))?.festivals.map(\.id),
                       ["kushe_aunsi"])
        XCTAssertEqual(service.todayOverlay(on: greg(2026, 9, 13))?.festivals.map(\.id),
                       ["dar_khane_din"])
        XCTAssertEqual(service.todayOverlay(on: greg(2026, 9, 14))?.festivals.map(\.id),
                       ["haritalika_teej"])
        XCTAssertEqual(service.todayOverlay(on: greg(2026, 9, 15))?.festivals.map(\.id),
                       ["rishi_panchami"])
    }

    func testUpcomingFindsTeejAndDarKhaneDin() {
        let upcoming = makeService().upcoming(after: greg(2026, 9, 1), limit: 12)
        let byId = Dictionary(uniqueKeysWithValues: upcoming.map { ($0.festival.id, $0) })
        XCTAssertEqual(byId["dar_khane_din"]?.daysAway, 12)
        XCTAssertEqual(byId["haritalika_teej"]?.daysAway, 13)
        XCTAssertEqual(byId["haritalika_teej"]?.bsDate,
                       BikramSambat.BSDate(year: 2083, month: 5, day: 29))
    }

    // MARK: - Other corrected 2083 dates

    func testDashain2083UsesTithiAnchoredDates() {
        // Kartik 1 = 2026-10-18 (Ashwin 2083 has 31 days: Fulpati is
        // Ashwin 31 = Oct 17). The old catalog had Ghatasthapana on
        // Ashwin 1 and Dashami on Ashwin 10 — a month early.
        let expected: [(String, Int, Int, Int, Int)] = [
            ("ghatasthapana", 2083, 6, 25, 2026),
            ("fulpati",       2083, 6, 31, 2026),
            ("maha_astami",   2083, 7, 1, 2026),
            ("maha_navami",   2083, 7, 3, 2026),
            ("bijaya_dashami", 2083, 7, 4, 2026),
        ]
        for (id, year, month, day, adYear) in expected {
            XCTAssertEqual(resolved(id, year)?.bsDate,
                           BikramSambat.BSDate(year: year, month: month, day: day),
                           "\(id) 2083")
            XCTAssertEqual(adComponents(id, year)?.0, adYear)
            XCTAssertFalse(resolved(id, year)!.isApproximate)
        }
        let dashami = adComponents("bijaya_dashami", 2083)
        XCTAssertEqual(dashami?.1, 10); XCTAssertEqual(dashami?.2, 21)
    }

    func testTihar2083UsesPanchangDates() {
        // Kag Kartik 21 (Nov 7) … Chhath Kartik 29 (Nov 15). Laxmi Puja
        // and Kukur Tihar share Kartik 22 in 2083 (Narak Chaturdashi
        // takes the puja that year — per the government holiday list,
        // दीपावली = कात्तिक २२).
        let expected: [(String, Int, Int, Int, Int)] = [
            ("kag_tihar",      2083, 7, 21, 7),
            ("kukur_tihar",    2083, 7, 22, 8),
            ("laxmi_puja",     2083, 7, 22, 8),
            ("govardhan_puja", 2083, 7, 24, 10),
            ("bhai_tika",      2083, 7, 25, 11),
            ("chhath",         2083, 7, 29, 15),
        ]
        for (id, year, month, day, adDay) in expected {
            XCTAssertEqual(resolved(id, year)?.bsDate,
                           BikramSambat.BSDate(year: year, month: month, day: day),
                           "\(id) 2083")
            XCTAssertEqual(adComponents(id, year)?.2, adDay, "\(id) 2083 AD day")
        }
    }

    func testBhadraAndKartik2083ShiftFromOldFixedDays() {
        // Janmashtami Bhadra 19 (not 23), Gai Jatra Bhadra 13 (not 1),
        // Janai Purnima Bhadra 12 (not Ashadh 15), Yomari Poush 9 (not
        // Poush 15), Holi Chaitra 7 (not Falgun 15).
        let expected: [(String, BikramSambat.BSDate)] = [
            ("janai_purnima", .init(year: 2083, month: 5, day: 12)),
            ("gai_jatra", .init(year: 2083, month: 5, day: 13)),
            ("krishna_janmashtami", .init(year: 2083, month: 5, day: 19)),
            ("yomari_punhi", .init(year: 2083, month: 9, day: 9)),
            ("holi", .init(year: 2083, month: 12, day: 7)),
        ]
        for (id, bs) in expected {
            XCTAssertEqual(resolved(id, 2083)?.bsDate, bs, "\(id) 2083")
        }
    }

    func testNaagPanchamiIsInTheCatalog() {
        // Bhadra 1, 2083 = 2026-08-17 (Shrawan Shukla Panchami lands on
        // the first of Bhadra that year) — another audit find.
        XCTAssertEqual(resolved("naag_panchami", 2083)?.bsDate,
                       BikramSambat.BSDate(year: 2083, month: 5, day: 1))
        XCTAssertEqual(makeService().todayOverlay(on: greg(2026, 8, 17))?.festivals.map(\.id),
                       ["naag_panchami"])
    }

    // MARK: - Fixed (solar) festivals + fallback behaviour

    func testFixedFestivalsStayOnTheirBSSolarDay() {
        for year in [2083, 2084, 2090] {
            XCTAssertEqual(resolved("nepali_new_year", year)?.bsDate,
                           BikramSambat.BSDate(year: year, month: 1, day: 1))
            XCTAssertEqual(resolved("maghe_sankranti", year)?.bsDate,
                           BikramSambat.BSDate(year: year, month: 10, day: 1))
            XCTAssertFalse(resolved("nepali_new_year", year)!.isApproximate)
        }
    }

    func testYearsOutsideTheVerifiedTableAreFlaggedApproximate() {
        // Nothing is table-covered past 2084: the date still resolves
        // (tithi astronomy) but must be flagged, never silently exact.
        let far = resolved("haritalika_teej", 2090)
        XCTAssertNotNil(far, "astronomy fallback must still produce a date")
        XCTAssertTrue(far!.isApproximate)
        XCTAssertFalse(resolved("haritalika_teej", 2084)!.isApproximate)
    }

    func testFestivalsOnDateMatchesResolvedDates() {
        // festivals(onBSDate:) must agree with per-festival resolution,
        // so today's overlay and the upcoming list can never disagree.
        let bs = BikramSambat.BSDate(year: 2083, month: 5, day: 29)
        XCTAssertEqual(NepaliFestivalCatalog.festivals(onBSDate: bs).map(\.id),
                       ["haritalika_teej"])
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

    func testBijayaDashamiOverlay() {
        // Bijaya Dashami 2083 = Kartik 4, 2083 BS = 2026-10-21.
        let bs = BikramSambat.BSDate(year: 2083, month: 7, day: 4)
        let ad = BikramSambat.adDate(from: bs)!
        let overlay = makeService().todayOverlay(on: ad)
        XCTAssertEqual(overlay?.festivals.map(\.id), ["bijaya_dashami"])
        XCTAssertEqual(overlay?.festivals.first?.tithiNepali, "दशमी")
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

    func testServiceLocaleIsRegionQualified() {
        // The service composes notification copy in the active locale;
        // its default must be the region-qualified Nepali (Nepal) — a
        // bare "ne" carries no region and inherits the device's.
        XCTAssertEqual(makeService().locale.identifier, "ne-NP")
    }
}

/// Locale (language vs region) settings — 2026-09-13. Kept in this file
/// because the checked-in pbxproj cannot be regenerated in a worktree
/// (gitignored model resources are absent), so no NEW test file can be
/// added; this class travels with the calendar task, whose festival
/// conventions the region selects.
final class AppLocaleTests: XCTestCase {

    private static let defaultsKey = "appLocale"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        super.tearDown()
    }

    func testNepaliDefaultsToNepalNotIndia() {
        XCTAssertEqual(AppLanguage.nepali.defaultLocale, .nepaliNepal)
        XCTAssertEqual(AppLocale.defaultLocale(for: .nepali).rawValue, "ne-NP")
        let region = AppLocale.defaultLocale(for: .nepali).locale.region?.identifier
        XCTAssertEqual(region, "NP", "ne must default to Nepal (ne-NP), never ne-IN")
    }

    func testEnglishKeepsItsExistingDefault() {
        // Preserve existing behaviour for other languages.
        XCTAssertEqual(AppLanguage.english.defaultLocale, .englishUS)
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en-US")
    }

    func testSupportedRegionsPerLanguage() {
        XCTAssertEqual(AppLocale.supported(for: .nepali), [.nepaliNepal, .nepaliIndia])
        XCTAssertEqual(AppLocale.supported(for: .english), [.englishUS, .englishIndia])
        // Every supported locale really carries its region — the whole
        // point of the fix (a region-less locale inherits the device's).
        for language in AppLanguage.allCases {
            for locale in AppLocale.supported(for: language) {
                XCTAssertNotNil(locale.locale.region,
                                "\(locale.rawValue) must be region-qualified")
                XCTAssertEqual(locale.language, language)
            }
        }
    }

    func testOverrideIsRespectedAndPersisted() {
        XCTAssertEqual(AppLocale.persisted(for: .nepali), .nepaliNepal,
                       "nothing stored → the language default")
        AppLocale.nepaliIndia.persist()
        XCTAssertEqual(AppLocale.persisted(for: .nepali), .nepaliIndia,
                       "a household in India keeps ne-IN across relaunches")
        XCTAssertEqual(AppLocale.persisted(for: .nepali).locale.identifier, "ne-IN")
    }

    func testStoredLocaleDoesNotLeakAcrossLanguages() {
        // A stored en-IN must not survive a switch to Nepali.
        AppLocale.englishIndia.persist()
        XCTAssertEqual(AppLocale.persisted(for: .english), .englishIndia)
        XCTAssertEqual(AppLocale.persisted(for: .nepali), .nepaliNepal)
    }

    func testNepalAndIndiaNepaliDifferInFormatting() {
        // Pins the observable difference the setting exists for.
        XCTAssertEqual(Locale(identifier: "ne-NP").region?.identifier, "NP")
        XCTAssertEqual(Locale(identifier: "ne-IN").region?.identifier, "IN")
        XCTAssertNotEqual(AppLocale.nepaliNepal.locale, AppLocale.nepaliIndia.locale)
    }
}
