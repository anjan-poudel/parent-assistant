import XCTest
@testable import ElderlyAssistant

/// `HomeDateLineComposer` + `CalendarDisplaySettingsStore`
/// (calendar-display task, 2026-09-09): the pure composition rules for
/// the Home top bar's date line — locale seeds the first-ever defaults,
/// user choices win thereafter, every default-calendar × overlay
/// combination composes exactly as specified, the festival name rides
/// along, and out-of-table dates degrade honestly instead of guessing.
final class HomeDateLineComposerTests: XCTestCase {

    // Fixed calendar/timezone so every assertion is machine-independent.
    private var kathmandu: Calendar!

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// 2026-09-06 = 2083-05-22 BS (भदौ २२, २०८३), a Sunday — the
    /// BikramSambat anchor family already pinned by BikramSambatTests.
    private var anchorDate: Date!
    private var anchorTithi = ""

    private var store: CalendarDisplaySettingsStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        kathmandu = cal
        anchorDate = date(year: 2026, month: 9, day: 6, in: cal)
        anchorTithi = TithiCalculator.tithi(on: anchorDate, calendar: cal).displayNepali
        suiteName = "home-date-line-composer-tests-\(UUID().uuidString)"
        store = CalendarDisplaySettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func date(year: Int, month: Int, day: Int, in cal: Calendar) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 9
        return cal.date(from: c)!
    }

    private func settings(_ primary: CalendarDisplayDefault,
                          bs: Bool = false, tithi: Bool = false) -> CalendarDisplaySettings {
        CalendarDisplaySettings(defaultCalendar: primary,
                                showBSOverlay: bs, showTithiOverlay: tithi)
    }

    private func line(_ s: CalendarDisplaySettings,
                      locale: Locale,
                      on date: Date? = nil,
                      festival: String? = nil) -> HomeDateLineComposer.Line? {
        HomeDateLineComposer.line(on: date ?? anchorDate,
                                  calendar: kathmandu,
                                  settings: s,
                                  locale: locale,
                                  festivalName: festival)
    }

    // MARK: - First-ever seeding (the locale seeds ONCE)

    func testLocaleSeedsFirstEverDefaults() {
        XCTAssertEqual(CalendarDisplaySettings.seeded(for: ne),
                       CalendarDisplaySettings(defaultCalendar: .nepali,
                                               showBSOverlay: true,
                                               showTithiOverlay: true))
        XCTAssertEqual(CalendarDisplaySettings.seeded(for: en),
                       CalendarDisplaySettings(defaultCalendar: .gregorian,
                                               showBSOverlay: false,
                                               showTithiOverlay: false))
    }

    func testStoreSeedsOnceThenUserChoicesWin() {
        // First ever load under Nepali: seeded BS + both overlays ON.
        let seeded = store.load(locale: ne)
        XCTAssertEqual(seeded, CalendarDisplaySettings.seeded(for: ne))

        // A user override persists — the same store re-loaded under a
        // DIFFERENT locale still returns the user's choices, not a
        // re-seed.
        store.save(CalendarDisplaySettings(defaultCalendar: .gregorian,
                                           showBSOverlay: true,
                                           showTithiOverlay: false))
        let afterOverride = store.load(locale: ne)
        XCTAssertEqual(afterOverride,
                       CalendarDisplaySettings(defaultCalendar: .gregorian,
                                               showBSOverlay: true,
                                               showTithiOverlay: false))
        XCTAssertEqual(store.load(locale: en), afterOverride,
                       "once seeded, the locale never overrides again")
    }

    func testStoreSeedsUnderEnglishAsGregorianNoOverlays() {
        let seeded = store.load(locale: en)
        XCTAssertEqual(seeded,
                       CalendarDisplaySettings(defaultCalendar: .gregorian,
                                               showBSOverlay: false,
                                               showTithiOverlay: false))
    }

    func testStoreRoundTripsPersistedValuesAndFallsBackOnUnknownRaw() {
        store.save(CalendarDisplaySettings(defaultCalendar: .nepali,
                                           showBSOverlay: false,
                                           showTithiOverlay: true))
        XCTAssertEqual(store.load(locale: en).defaultCalendar, .nepali)
        XCTAssertEqual(store.load(locale: en).showTithiOverlay, true)

        // A corrupted/unknown default-calendar raw value falls back to
        // Gregorian instead of trapping.
        UserDefaults(suiteName: suiteName)!.set("bogus",
                                                forKey: CalendarDisplaySettingsStore.defaultCalendarKey)
        XCTAssertEqual(store.load(locale: ne).defaultCalendar, .gregorian)
    }

    // MARK: - Composition: every default × overlay combination

    func testGregorianPrimaryWithoutOverlays() throws {
        let l = try XCTUnwrap(line(settings(.gregorian), locale: en))
        XCTAssertEqual(l.primary, "Sun, Sep 6, 2026")
        XCTAssertEqual(l.overlays, [])
        XCTAssertEqual(l.joined, "Sun, Sep 6, 2026")
    }

    func testGregorianPrimaryWithBSOverlay() throws {
        let l = try XCTUnwrap(line(settings(.gregorian, bs: true), locale: en))
        XCTAssertEqual(l.primary, "Sun, Sep 6, 2026")
        XCTAssertEqual(l.overlays, ["भदौ २२, २०८३"])
    }

    func testGregorianPrimaryWithTithiOverlay() throws {
        let l = try XCTUnwrap(line(settings(.gregorian, tithi: true), locale: en))
        XCTAssertEqual(l.primary, "Sun, Sep 6, 2026")
        XCTAssertEqual(l.overlays, [anchorTithi])
    }

    func testGregorianPrimaryWithBothOverlays() throws {
        let l = try XCTUnwrap(line(settings(.gregorian, bs: true, tithi: true),
                                   locale: en))
        XCTAssertEqual(l.primary, "Sun, Sep 6, 2026")
        XCTAssertEqual(l.overlays, ["भदौ २२, २०८३", anchorTithi])
        XCTAssertEqual(l.joined,
                       "Sun, Sep 6, 2026 • भदौ २२, २०८३ • \(anchorTithi)")
    }

    func testNepaliPrimaryWithoutOverlays() throws {
        let l = try XCTUnwrap(line(settings(.nepali), locale: ne))
        XCTAssertEqual(l.primary, "भदौ २२, २०८३")
        XCTAssertEqual(l.overlays, [])
        XCTAssertEqual(l.joined, "भदौ २२, २०८३")
    }

    func testNepaliPrimaryWithTithiOverlay() throws {
        let l = try XCTUnwrap(line(settings(.nepali, tithi: true), locale: ne))
        XCTAssertEqual(l.primary, "भदौ २२, २०८३")
        XCTAssertEqual(l.overlays, [anchorTithi])
    }

    func testNepaliPrimaryNeverDuplicatesTheBSDate() throws {
        // BS overlay ON under a Nepali primary must NOT repeat the
        // primary line — the BS date already IS the primary.
        let both = try XCTUnwrap(line(settings(.nepali, bs: true, tithi: true),
                                      locale: ne))
        XCTAssertEqual(both.overlays, [anchorTithi])

        let bsOnly = try XCTUnwrap(line(settings(.nepali, bs: true), locale: ne))
        XCTAssertEqual(bsOnly.overlays, [])
    }

    func testGregorianPrimaryIsLocalized() throws {
        // English: exact pinned weekday-first form.
        XCTAssertEqual(
            HomeDateLineComposer.gregorianPrimary(anchorDate, calendar: kathmandu,
                                                  locale: en),
            "Sun, Sep 6, 2026")
        // Nepali locale: a localized (Devanagari) form, never the
        // English one, and stable across calls.
        let nepaliForm = HomeDateLineComposer.gregorianPrimary(
            anchorDate, calendar: kathmandu, locale: ne)
        XCTAssertFalse(nepaliForm.isEmpty)
        XCTAssertNotEqual(nepaliForm, "Sun, Sep 6, 2026")
        XCTAssertEqual(nepaliForm,
                       HomeDateLineComposer.gregorianPrimary(anchorDate,
                                                             calendar: kathmandu,
                                                             locale: ne))
    }

    // MARK: - Festival riding along

    func testFestivalNameAppendsToOverlays() throws {
        let greg = try XCTUnwrap(line(settings(.gregorian, tithi: true),
                                      locale: en, festival: "दशैं"))
        XCTAssertEqual(greg.overlays, [anchorTithi, "दशैं"])

        let nep = try XCTUnwrap(line(settings(.nepali), locale: ne,
                                     festival: "दशैं"))
        XCTAssertEqual(nep.overlays, ["दशैं"])
    }

    // MARK: - Out-of-table honesty

    func testOutOfTableDatesDegradeHonestly() throws {
        let old = date(year: 1900, month: 1, day: 15, in: kathmandu)

        // Gregorian primary always composes; the BS overlay is silently
        // skipped when the table cannot convert — never guessed.
        let greg = try XCTUnwrap(line(settings(.gregorian, bs: true, tithi: true),
                                      locale: en, on: old))
        XCTAssertEqual(greg.primary, "Mon, Jan 15, 1900")
        XCTAssertEqual(greg.overlays,
                       [TithiCalculator.tithi(on: old, calendar: kathmandu).displayNepali])

        // Nepali primary with no convertible BS date returns nil — the
        // caller shows nothing rather than a fabricated date.
        XCTAssertNil(line(settings(.nepali), locale: ne, on: old))
    }

    // MARK: - Catalog keys

    func testCalendarDisplayKeysResolveInBothLanguages() {
        XCTAssertEqual(L10n.str("calendarDisplay.sectionTitle", locale: en),
                       "Calendar display")
        XCTAssertEqual(L10n.str("calendarDisplay.sectionTitle", locale: ne),
                       "पात्रो प्रदर्शन")
        XCTAssertEqual(L10n.str("calendarDisplay.default.gregorian", locale: en),
                       "Gregorian")
        XCTAssertEqual(L10n.str("calendarDisplay.default.nepali", locale: en),
                       "Nepali (BS)")
        for key in ["calendarDisplay.bsOverlay",
                    "calendarDisplay.tithiOverlay",
                    "calendarDisplay.offlineNote",
                    "calendarDisplay.default.nepali"] {
            let english = L10n.str(key, locale: en)
            let nepali = L10n.str(key, locale: ne)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(nepali.isEmpty)
            XCTAssertNotEqual(english, key, "\(key) must resolve in English")
            XCTAssertNotEqual(nepali, key, "\(key) must resolve in Nepali")
        }
        XCTAssertEqual(CalendarDisplayDefault.gregorian.labelKey,
                       "calendarDisplay.default.gregorian")
        XCTAssertEqual(CalendarDisplayDefault.nepali.labelKey,
                       "calendarDisplay.default.nepali")
    }
}
