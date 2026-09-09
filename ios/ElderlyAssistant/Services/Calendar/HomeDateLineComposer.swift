import Foundation

/// The calendar the Home top bar's date line leads with (calendar-display
/// task, 2026-09-09). Chosen in Settings → Calendar → Calendar display;
/// a UI preference persisted like every other preference in the house.
enum CalendarDisplayDefault: String, CaseIterable, Identifiable {
    case gregorian
    case nepali

    var id: String { rawValue }

    /// Catalog key for the settings row label ("calendarDisplay.default.*").
    var labelKey: String { "calendarDisplay.default.\(rawValue)" }
}

/// The calendar-display choices behind the Home top bar's date line:
/// which calendar is PRIMARY and which overlay lines ride below it.
struct CalendarDisplaySettings: Equatable {
    var defaultCalendar: CalendarDisplayDefault = .gregorian
    /// Show the Bikram Sambat date under a Gregorian primary.
    /// Deliberately ignored when Nepali is primary — the BS date IS the
    /// primary line then, so an overlay would duplicate it.
    var showBSOverlay = false
    /// Show the day's Hindu tithi + paksha (offline astronomy, see
    /// `TithiCalculator` for the documented accuracy limits).
    var showTithiOverlay = false

    /// The FIRST-EVER defaults, seeded from the app language's locale:
    /// Nepali → BS primary with both overlays ON (the local calendar is
    /// the point of the product); English → Gregorian with overlays OFF.
    /// The locale seeds exactly once — after that, user choices persist
    /// and the locale never overrides them again (see the store).
    static func seeded(for locale: Locale) -> CalendarDisplaySettings {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        return CalendarDisplaySettings(
            defaultCalendar: isNepali ? .nepali : .gregorian,
            showBSOverlay: isNepali,
            showTithiOverlay: isNepali)
    }
}

/// UserDefaults persistence + one-time locale seeding for the calendar
/// display settings (calendar-display task, 2026-09-09). The COORDINATOR
/// owns the @Published didSet persistence for individual edits (house
/// pattern); this store owns the two things that are not plain
/// round-trips — the first-ever locale seed and the init-time load — and
/// is an injectable seam (tests pass a scratch `UserDefaults` suite and
/// verify seeding happens once and that later user edits win over the
/// locale).
struct CalendarDisplaySettingsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let seededKey = "calendarDisplay.seeded.v1"
    static let defaultCalendarKey = "calendarDisplay.defaultCalendar.v1"
    static let bsOverlayKey = "calendarDisplay.bsOverlay.v1"
    static let tithiOverlayKey = "calendarDisplay.tithiOverlay.v1"

    /// Loads the persisted settings; on the first ever load seeds the
    /// locale-based defaults and marks the seed as done.
    func load(locale: Locale) -> CalendarDisplaySettings {
        guard defaults.bool(forKey: Self.seededKey) else {
            let seeded = CalendarDisplaySettings.seeded(for: locale)
            save(seeded)
            defaults.set(true, forKey: Self.seededKey)
            return seeded
        }
        return CalendarDisplaySettings(
            defaultCalendar: defaults.string(forKey: Self.defaultCalendarKey)
                .flatMap(CalendarDisplayDefault.init(rawValue:)) ?? .gregorian,
            showBSOverlay: defaults.bool(forKey: Self.bsOverlayKey),
            showTithiOverlay: defaults.bool(forKey: Self.tithiOverlayKey))
    }

    /// Writes the settings as a whole — the coordinator's didSets call
    /// this too, so the three keys always move together. An explicit
    /// save IS a user choice, so it also marks the first-ever seed as
    /// done: the locale seeds exactly once and can never overwrite a
    /// user's later choices — including when the first write is a save
    /// rather than a load (the load path's seed branch writes through
    /// this same method, so the flag is set either way).
    func save(_ settings: CalendarDisplaySettings) {
        defaults.set(settings.defaultCalendar.rawValue,
                     forKey: Self.defaultCalendarKey)
        defaults.set(settings.showBSOverlay, forKey: Self.bsOverlayKey)
        defaults.set(settings.showTithiOverlay, forKey: Self.tithiOverlayKey)
        defaults.set(true, forKey: Self.seededKey)
    }
}

/// Pure composer for the Home top bar's date line (calendar-display
/// task, 2026-09-09). The greeting + live clock are gone from the top
/// bar; their place is the day's DATE:
///
///   primary   — the default calendar's date for today:
///               Gregorian  → "Mon, Sep 9, 2026" (localized short/full
///                             date, weekday first — elderly users read
///                             the day name first);
///               Nepali     → "भदौ २९, २०८२" per `BikramSambat`'s
///                             existing presentation conventions.
///   overlays  — the enabled secondary lines, in order: the BS date
///               (only while Gregorian is primary — with Nepali primary
///               it would duplicate the primary line), the Hindu
///               tithi + paksha ("एकादशी शुक्ल पक्ष" — TithiCalculator's
///               existing output, Devanagari in both app languages),
///               and the day's festival name when one falls today.
///
/// Everything is computed OFFLINE from the app's own BS table and
/// low-precision tithi astronomy. Honesty: the tithi can differ by a
/// day from a temple panchanga on transition days — the documented
/// limit of `TithiCalculator` (80% exact vs published panchanga data,
/// ±1 day on boundaries). The festival part is date-driven and exact.
/// Nothing here is ever fetched from a network or fabricated.
///
/// Pure: every input arrives as an argument (date, calendar, settings,
/// locale), so the whole surface is unit-testable without a coordinator,
/// device clock, or network.
enum HomeDateLineComposer {

    /// The composed line: the primary date plus its overlay parts.
    /// `joined` is the single-string form (Updates leaf, VoiceOver).
    struct Line: Equatable {
        let primary: String
        let overlays: [String]

        var joined: String {
            ([primary] + overlays).joined(separator: " • ")
        }
    }

    /// Composes today's date line. Returns nil only when Nepali is the
    /// primary calendar and the BS table cannot convert the date (out of
    /// the table's 1978–2099 BS coverage — unreachable for present-day
    /// dates, but never guessed at).
    static func line(on date: Date,
                     calendar: Calendar,
                     settings: CalendarDisplaySettings,
                     locale: Locale,
                     festivalName: String? = nil) -> Line? {
        let bs = BikramSambat.bsDate(from: date, calendar: calendar)

        switch settings.defaultCalendar {
        case .nepali:
            guard let bs else { return nil }
            var overlays: [String] = []
            if settings.showTithiOverlay {
                overlays.append(TithiCalculator.tithi(on: date, calendar: calendar)
                    .displayNepali)
            }
            if let festivalName { overlays.append(festivalName) }
            return Line(primary: BikramSambat.nepaliString(bs), overlays: overlays)

        case .gregorian:
            var overlays: [String] = []
            // The BS overlay only renders under a Gregorian primary —
            // under a Nepali primary the BS date already IS the primary
            // line and an overlay would say it twice.
            if settings.showBSOverlay, let bs {
                overlays.append(BikramSambat.nepaliString(bs))
            }
            if settings.showTithiOverlay {
                overlays.append(TithiCalculator.tithi(on: date, calendar: calendar)
                    .displayNepali)
            }
            if let festivalName { overlays.append(festivalName) }
            return Line(primary: gregorianPrimary(date, calendar: calendar,
                                                  locale: locale),
                        overlays: overlays)
        }
    }

    /// "Mon, Sep 9, 2026" — the localized Gregorian primary. The same
    /// calendar/timezone the BS conversion used are pinned into the
    /// format so the two lines can never describe different days.
    static func gregorianPrimary(_ date: Date,
                                 calendar: Calendar,
                                 locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .none, time: .none,
                                        locale: locale,
                                        calendar: calendar,
                                        timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day().year())
    }
}
