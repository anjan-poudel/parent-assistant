import Foundation

/// A tithi within a paksha — the Hindu lunar day a festival is anchored to.
struct PakshaTithi: Equatable {
    let isShukla: Bool
    let number: Int   // 1...15 (15 = पूर्णिमा / अमावस्या)

    static let shuklaPurnima = PakshaTithi(isShukla: true, number: 15)
    static let krishnaAunsi = PakshaTithi(isShukla: false, number: 15)
}

/// How a festival's date is derived for a given Bikram Sambat year.
///
/// The distinction is the whole point of the 2026-09-13 festival-audit
/// fix: the ORIGINAL catalog keyed every festival to a fixed BS month/day,
/// which is only valid for the solar (sankranti-anchored) observances.
/// Tithi-anchored festivals drift against the solar BS months by roughly
/// -11 days a year (and snap forward ~+19 days across a year that carries
/// an extra lunar month), so a fixed BS day is wrong by up to three weeks:
/// Haritalika Teej 2083 (Bhadra Shukla Tritiya) is Bhadra **29**, not
/// Bhadra 3 as the fixed table claimed, and Bijaya Dashami 2083 is Kartik
/// 4, not Ashwin 10.
enum FestivalDateRule: Equatable {
    /// A date the solar Bikram Sambat calendar fixes: the sankranti-based
    /// administrative observances (New Year = Baisakh 1, Maghe Sankranti =
    /// Magh 1) that never move year to year.
    case fixedBS(month: Int, day: Int)

    /// A tithi-anchored (lunisolar) observance, named by the tithi it
    /// follows. `month` is the BS month the festival is *named* for and is
    /// used only to place the astronomy fallback — the observed day can
    /// legitimately fall in the next BS month (Holi 2083 = Chaitra 7, the
    /// lunar Falgun purnima landing after the solar Falgun ended).
    ///
    /// `table` carries the dates verified against a published Nepali
    /// panchang for the years we have them (see `NepaliFestivalCatalog`'s
    /// source note). Years outside the table are resolved by
    /// `TithiCalculator` astronomy and flagged `isApproximate`.
    case lunar(month: Int, tithi: PakshaTithi, table: [Int: BikramSambat.BSDate])
}

/// A Nepali/Hindu festival or observance.
struct NepaliFestival: Identifiable, Equatable {
    let id: String                 // stable key, e.g. "haritalika_teej"
    let nameNepali: String
    let nameEnglish: String
    /// Tithi label where well-known (e.g. "त्रितिया", "दशमी", "पूर्णिमा") —
    /// shown as the Hindu-calendar overlay on the festival's day.
    let tithiNepali: String?
    /// Important festivals get an advance notification N days before
    /// (user-configurable, default 2) in addition to the day-of one.
    let isImportant: Bool
    /// How the date is derived. Replaces the old static `isLunarSighted`
    /// flag (nothing read it; the rule is what decides), and the
    /// per-year `ResolvedDate.isApproximate` is the honest signal for
    /// years the verified table does not cover.
    let rule: FestivalDateRule

    init(id: String, nameNepali: String, nameEnglish: String,
         rule: FestivalDateRule, tithiNepali: String? = nil,
         isImportant: Bool = false) {
        self.id = id
        self.nameNepali = nameNepali
        self.nameEnglish = nameEnglish
        self.rule = rule
        self.tithiNepali = tithiNepali
        self.isImportant = isImportant
    }

    // MARK: - Date resolution

    /// A resolved observance: the BS date it falls on, plus whether that
    /// date is TABLE-BACKED (verified against a published panchang) or
    /// ASTRONOMY-ONLY (the fallback for years the table does not cover,
    /// good to about ±1 day — the documented limit of `TithiCalculator`).
    struct ResolvedDate: Equatable {
        let bsDate: BikramSambat.BSDate
        let isApproximate: Bool
    }

    /// The BS date this festival falls on in `bsYear`.
    func resolvedDate(inBSYear year: Int,
                      calendar: Calendar = .current) -> ResolvedDate? {
        switch rule {
        case .fixedBS(let month, let day):
            let bs = BikramSambat.BSDate(year: year, month: month, day: day)
            // Validate against the year's month lengths — a fixed rule must
            // never silently produce an impossible date.
            guard BikramSambat.adDate(from: bs, calendar: calendar) != nil else { return nil }
            return ResolvedDate(bsDate: bs, isApproximate: false)

        case .lunar(let month, let tithi, let table):
            if let verified = table[year] {
                return ResolvedDate(bsDate: verified, isApproximate: false)
            }
            guard let approximate = Self.lunarFallback(year: year, month: month,
                                                       tithi: tithi, table: table,
                                                       calendar: calendar) else { return nil }
            return ResolvedDate(bsDate: approximate, isApproximate: true)
        }
    }

    /// Astronomy fallback for a BS year the verified table does not cover.
    ///
    /// Estimate the day, then snap to it: the estimate is a table year
    /// shifted by whole mean lunar years (354.37 days — one lunation year,
    /// which is what keeps the *lunar* month aligned when the BS year
    /// changes), or mid-BS-month when the festival has no table entry at
    /// all. The closest day within ±20 whose sunrise tithi matches is the
    /// answer. Documented limit: on a year carrying an extra lunar month
    /// (adhik maas) this can land a lunation out — the honest reason the
    /// verified table, not the math, is the source of truth.
    private static func lunarFallback(year: Int, month: Int, tithi: PakshaTithi,
                                      table: [Int: BikramSambat.BSDate],
                                      calendar: Calendar) -> BikramSambat.BSDate? {
        var estimate: Date?
        if let nearest = table.keys.min(by: { abs($0 - year) < abs($1 - year) }),
           let anchorAD = BikramSambat.adDate(from: table[nearest]!, calendar: calendar) {
            let lunarYears = Double(year - nearest) * 354.37
            estimate = calendar.date(byAdding: .day, value: Int(lunarYears.rounded()),
                                     to: anchorAD)
        }
        if estimate == nil,
           let monthStart = BikramSambat.adDate(from: BikramSambat.BSDate(year: year, month: month, day: 1),
                                                calendar: calendar) {
            estimate = calendar.date(byAdding: .day, value: 15, to: monthStart)
        }
        guard let estimate else { return nil }

        var best: (date: Date, distance: Int)?
        for offset in -20...20 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: estimate) else { continue }
            let candidateTithi = TithiCalculator.tithi(on: candidate, calendar: calendar)
            guard candidateTithi.isShukla == tithi.isShukla,
                  candidateTithi.number == tithi.number else { continue }
            if best == nil || abs(offset) < best!.distance {
                best = (candidate, abs(offset))
            }
        }
        // No tithi match in the window (possible across an adhik maas):
        // keep the estimate rather than dropping the festival from the
        // calendar — it is flagged approximate either way.
        let chosen = best?.date ?? estimate
        return BikramSambat.bsDate(from: chosen, calendar: calendar)
    }
}

/// The bundled festival dataset (v2 — rules + verified tables, 2026-09-13).
/// Daily tithi for ARBITRARY days is still `TithiCalculator`'s job; this
/// catalog is about which DAY each festival is observed on.
///
/// SOURCE OF THE VERIFIED TABLES: the published Nepali patro at
/// nepalicalendar.rat32.com (month pages for 2082/2083/2084 BS), whose
/// per-day festival listings are the commonly observed Nepal dates, not
/// the Indian panchang's. Cross-checked for the festival the audit was
/// raised on — Haritalika Teej 2083 = Bhadra 29 = 2026-09-14 — against
/// independent reporting (ekantipur.com, 2025-08-26: "Haritalika Teej
/// today" = Bhadra 10, 2082) and Nepal Rastra Bank's 2083 BS holiday list
/// (Bhadra 29: Haritalika Teej, women employees only).
///
/// A year that is NOT in a table resolves by tithi astronomy and is
/// reported as `isApproximate` — extend the tables from a fresh panchang
/// (the sites above publish each year's) rather than trusting the math
/// across an adhik maas.
enum NepaliFestivalCatalog {

    /// Verified BS dates, keyed by BS year. Kept in one place so the
    /// source note above is the single citation for every entry.
    enum VerifiedDates {
        // Bhadra Shukla 2/3/5 — the festival cluster the 2026-09-13 audit
        // was raised on (Dar Khane Din and Teej are the two days before
        // Rishi Panchami).
        static let darKhaneDin: [Int: BikramSambat.BSDate] = [
            2082: BikramSambat.BSDate(year: 2082, month: 5, day: 9),    // 2025-08-25
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 28),   // 2026-09-13
            2084: BikramSambat.BSDate(year: 2084, month: 5, day: 17),   // 2027-09-02
        ]
        static let haritalikaTeej: [Int: BikramSambat.BSDate] = [
            2082: BikramSambat.BSDate(year: 2082, month: 5, day: 10),   // 2025-08-26
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 29),   // 2026-09-14
            2084: BikramSambat.BSDate(year: 2084, month: 5, day: 18),   // 2027-09-03
        ]
        static let rishiPanchami: [Int: BikramSambat.BSDate] = [
            2082: BikramSambat.BSDate(year: 2082, month: 5, day: 12),   // 2025-08-28
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 30),   // 2026-09-15
            2084: BikramSambat.BSDate(year: 2084, month: 5, day: 20),   // 2027-09-05
        ]
        static let kusheAunsi: [Int: BikramSambat.BSDate] = [
            2082: BikramSambat.BSDate(year: 2082, month: 5, day: 7),    // 2025-08-23
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 26),   // 2026-09-11
        ]
        static let naagPanchami: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 1),    // 2026-08-17
        ]
        static let janaiPurnima: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 12),   // 2026-08-28
        ]
        static let gaiJatra: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 13),   // 2026-08-29
        ]
        static let krishnaJanmashtami: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 5, day: 19),   // 2026-09-04
        ]
        static let ghatasthapana: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 6, day: 25),   // 2026-10-11
        ]
        static let fulpati: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 6, day: 31),   // 2026-10-17
        ]
        static let mahaAstami: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 1),    // 2026-10-18
        ]
        static let mahaNavami: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 3),    // 2026-10-20
        ]
        static let bijayaDashami: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 4),    // 2026-10-21
        ]
        static let kagTihar: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 21),   // 2026-11-07
        ]
        static let kukurTihar: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 22),   // 2026-11-08
        ]
        static let laxmiPuja: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 22),   // 2026-11-08
        ]
        static let govardhanPuja: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 24),   // 2026-11-10
        ]
        static let bhaiTika: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 25),   // 2026-11-11
        ]
        static let chhath: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 7, day: 29),   // 2026-11-15
        ]
        static let yomariPunhi: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 9, day: 9),    // 2026-12-24
        ]
        static let saraswatiPuja: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 10, day: 28),  // 2027-02-11
        ]
        static let mahaShivaratri: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 11, day: 22),  // 2027-03-06
        ]
        static let holi: [Int: BikramSambat.BSDate] = [
            2083: BikramSambat.BSDate(year: 2083, month: 12, day: 7),   // 2027-03-21
        ]
    }

    static let all: [NepaliFestival] = [
        // Baisakh
        NepaliFestival(id: "nepali_new_year", nameNepali: "नयाँ वर्ष",
                       nameEnglish: "Nepali New Year",
                       rule: .fixedBS(month: 1, day: 1),
                       tithiNepali: "प्रतिपदा", isImportant: true),
        NepaliFestival(id: "buddha_jayanti", nameNepali: "बुद्ध जयन्ती",
                       nameEnglish: "Buddha Jayanti",
                       rule: .lunar(month: 1, tithi: .shuklaPurnima, table: [:]),
                       tithiNepali: "पूर्णिमा"),
        // Jestha
        NepaliFestival(id: "gantantra_diwas", nameNepali: "गणतन्त्र दिवस",
                       nameEnglish: "Republic Day",
                       rule: .fixedBS(month: 2, day: 15)),
        // Ashadh
        NepaliFestival(id: "dahichaura", nameNepali: "दहीचिउरा",
                       nameEnglish: "Dahi Chiura (Asar 15)",
                       rule: .fixedBS(month: 3, day: 15)),
        // Shrawan
        NepaliFestival(id: "naag_panchami", nameNepali: "नाग पञ्चमी",
                       nameEnglish: "Naag Panchami",
                       rule: .lunar(month: 4, tithi: PakshaTithi(isShukla: true, number: 5),
                                    table: VerifiedDates.naagPanchami),
                       tithiNepali: "पञ्चमी"),
        NepaliFestival(id: "janai_purnima", nameNepali: "जनै पूर्णिमा",
                       nameEnglish: "Janai Purnima / Raksha Bandhan",
                       rule: .lunar(month: 4, tithi: .shuklaPurnima,
                                    table: VerifiedDates.janaiPurnima),
                       tithiNepali: "पूर्णिमा"),
        // Bhadra
        NepaliFestival(id: "gai_jatra", nameNepali: "गाई जात्रा",
                       nameEnglish: "Gai Jatra",
                       rule: .lunar(month: 5, tithi: PakshaTithi(isShukla: false, number: 1),
                                    table: VerifiedDates.gaiJatra),
                       tithiNepali: "प्रतिपदा"),
        NepaliFestival(id: "krishna_janmashtami", nameNepali: "कृष्ण जन्माष्टमी",
                       nameEnglish: "Krishna Janmashtami",
                       rule: .lunar(month: 5, tithi: PakshaTithi(isShukla: false, number: 8),
                                    table: VerifiedDates.krishnaJanmashtami),
                       tithiNepali: "अष्टमी"),
        NepaliFestival(id: "kushe_aunsi", nameNepali: "कुशे औंसी",
                       nameEnglish: "Kushe Aunsi (Father's Day)",
                       rule: .lunar(month: 5, tithi: .krishnaAunsi,
                                    table: VerifiedDates.kusheAunsi),
                       tithiNepali: "अमावस्या"),
        NepaliFestival(id: "dar_khane_din", nameNepali: "दर खाने दिन",
                       nameEnglish: "Dar Khane Din",
                       rule: .lunar(month: 5, tithi: PakshaTithi(isShukla: true, number: 2),
                                    table: VerifiedDates.darKhaneDin),
                       tithiNepali: "द्वितीया", isImportant: true),
        NepaliFestival(id: "haritalika_teej", nameNepali: "हरितालिका तीज",
                       nameEnglish: "Haritalika Teej",
                       rule: .lunar(month: 5, tithi: PakshaTithi(isShukla: true, number: 3),
                                    table: VerifiedDates.haritalikaTeej),
                       tithiNepali: "त्रितिया", isImportant: true),
        NepaliFestival(id: "rishi_panchami", nameNepali: "ऋषि पञ्चमी",
                       nameEnglish: "Rishi Panchami",
                       rule: .lunar(month: 5, tithi: PakshaTithi(isShukla: true, number: 5),
                                    table: VerifiedDates.rishiPanchami),
                       tithiNepali: "पञ्चमी"),
        // Ashwin — Ghatasthapana opens Dashain; the main days fall in
        // Kartik when Ashwin runs short (as in 2083).
        NepaliFestival(id: "ghatasthapana", nameNepali: "घटस्थापना",
                       nameEnglish: "Ghatasthapana (Dashain begins)",
                       rule: .lunar(month: 6, tithi: PakshaTithi(isShukla: true, number: 1),
                                    table: VerifiedDates.ghatasthapana),
                       tithiNepali: "प्रतिपदा", isImportant: true),
        NepaliFestival(id: "sambidhan_diwas", nameNepali: "संविधान दिवस",
                       nameEnglish: "Constitution Day",
                       rule: .fixedBS(month: 6, day: 3)),
        NepaliFestival(id: "fulpati", nameNepali: "फूलपाती",
                       nameEnglish: "Fulpati",
                       rule: .lunar(month: 6, tithi: PakshaTithi(isShukla: true, number: 7),
                                    table: VerifiedDates.fulpati),
                       tithiNepali: "सप्तमी", isImportant: true),
        NepaliFestival(id: "maha_astami", nameNepali: "महाअष्टमी",
                       nameEnglish: "Maha Astami",
                       rule: .lunar(month: 6, tithi: PakshaTithi(isShukla: true, number: 8),
                                    table: VerifiedDates.mahaAstami),
                       tithiNepali: "अष्टमी", isImportant: true),
        NepaliFestival(id: "maha_navami", nameNepali: "महानवमी",
                       nameEnglish: "Maha Navami",
                       rule: .lunar(month: 6, tithi: PakshaTithi(isShukla: true, number: 9),
                                    table: VerifiedDates.mahaNavami),
                       tithiNepali: "नवमी", isImportant: true),
        NepaliFestival(id: "bijaya_dashami", nameNepali: "विजया दशमी",
                       nameEnglish: "Bijaya Dashami",
                       rule: .lunar(month: 6, tithi: PakshaTithi(isShukla: true, number: 10),
                                    table: VerifiedDates.bijayaDashami),
                       tithiNepali: "दशमी", isImportant: true),
        // Kartik
        NepaliFestival(id: "kag_tihar", nameNepali: "काग तिहार",
                       nameEnglish: "Kag Tihar (Crow)",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: false, number: 13),
                                    table: VerifiedDates.kagTihar),
                       tithiNepali: "त्रयोदशी"),
        NepaliFestival(id: "kukur_tihar", nameNepali: "कुकुर तिहार",
                       nameEnglish: "Kukur Tihar (Dog)",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: false, number: 14),
                                    table: VerifiedDates.kukurTihar),
                       tithiNepali: "चतुर्दशी"),
        // Nepal performs Laxmi Puja on Narak Chaturdashi when the amavasya
        // does not prevail through the evening — 2083 is such a year, and
        // the government holiday list (`दीपावली (लक्ष्मी पूजा) — कात्तिक २२`)
        // puts it on the SAME day as Kukur Tihar. Years where it lands on
        // amavasya are a day later; the per-year table carries that.
        NepaliFestival(id: "laxmi_puja", nameNepali: "लक्ष्मी पूजा",
                       nameEnglish: "Laxmi Puja",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: false, number: 14),
                                    table: VerifiedDates.laxmiPuja),
                       tithiNepali: "चतुर्दशी", isImportant: true),
        NepaliFestival(id: "govardhan_puja", nameNepali: "गोवर्धन पूजा",
                       nameEnglish: "Govardhan Puja / Mha Puja",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: true, number: 1),
                                    table: VerifiedDates.govardhanPuja),
                       tithiNepali: "प्रतिपदा"),
        NepaliFestival(id: "bhai_tika", nameNepali: "भाई टीका",
                       nameEnglish: "Bhai Tika",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: true, number: 2),
                                    table: VerifiedDates.bhaiTika),
                       tithiNepali: "द्वितीया", isImportant: true),
        NepaliFestival(id: "chhath", nameNepali: "छठ",
                       nameEnglish: "Chhath Puja",
                       rule: .lunar(month: 7, tithi: PakshaTithi(isShukla: true, number: 6),
                                    table: VerifiedDates.chhath),
                       tithiNepali: "षष्ठी", isImportant: true),
        // Mangsir — no major fixed observances
        // Poush
        NepaliFestival(id: "yomari_punhi", nameNepali: "योमरी पुन्हि",
                       nameEnglish: "Yomari Punhi",
                       rule: .lunar(month: 9, tithi: .shuklaPurnima,
                                    table: VerifiedDates.yomariPunhi),
                       tithiNepali: "पूर्णिमा"),
        // Magh
        NepaliFestival(id: "maghe_sankranti", nameNepali: "माघे सङ्क्रान्ति",
                       nameEnglish: "Maghe Sankranti",
                       rule: .fixedBS(month: 10, day: 1),
                       isImportant: true),
        NepaliFestival(id: "saraswati_puja", nameNepali: "सरस्वती पूजा",
                       nameEnglish: "Saraswati Puja (Shree Panchami)",
                       rule: .lunar(month: 10, tithi: PakshaTithi(isShukla: true, number: 5),
                                    table: VerifiedDates.saraswatiPuja),
                       tithiNepali: "पञ्चमी"),
        // Falgun
        NepaliFestival(id: "maha_shivaratri", nameNepali: "महाशिवरात्रि",
                       nameEnglish: "Maha Shivaratri",
                       rule: .lunar(month: 11, tithi: PakshaTithi(isShukla: false, number: 14),
                                    table: VerifiedDates.mahaShivaratri),
                       tithiNepali: "चतुर्दशी", isImportant: true),
        NepaliFestival(id: "holi", nameNepali: "होली",
                       nameEnglish: "Holi",
                       rule: .lunar(month: 11, tithi: .shuklaPurnima,
                                    table: VerifiedDates.holi),
                       tithiNepali: "पूर्णिमा", isImportant: true),
        // Chaitra
        NepaliFestival(id: "ram_navami", nameNepali: "राम नवमी",
                       nameEnglish: "Ram Navami",
                       rule: .lunar(month: 12, tithi: PakshaTithi(isShukla: true, number: 9),
                                    table: [:]),
                       tithiNepali: "नवमी"),
        NepaliFestival(id: "chaite_dashain", nameNepali: "चैते दशैं",
                       nameEnglish: "Chaite Dashain",
                       rule: .lunar(month: 12, tithi: PakshaTithi(isShukla: true, number: 10),
                                    table: [:]),
                       tithiNepali: "दशमी"),
    ]

    /// Festivals falling on a given BS date — resolved per festival, since
    /// a tithi-anchored date moves against the BS months year to year.
    static func festivals(onBSDate bs: BikramSambat.BSDate,
                          calendar: Calendar = .current) -> [NepaliFestival] {
        all.filter { $0.resolvedDate(inBSYear: bs.year, calendar: calendar)?.bsDate == bs }
    }
}
