import Foundation

/// A Nepali/Hindu festival or observance, keyed by its Bikram Sambat
/// month+day (which is stable year-over-year for the major observances).
/// BS dates come from the standard Nepali calendar as observed in Nepal;
/// lunar-sighted observances (Holi, Shivaratri, Buddha Purnima) can drift
/// ±1 day in some years — the dataset carries the commonly observed date
/// and `isLunarSighted` marks those so the UI can hedge honestly.
struct NepaliFestival: Codable, Identifiable, Equatable {
    let id: String                 // stable key, e.g. "bijaya_dashami"
    let nameNepali: String
    let nameEnglish: String
    let bsMonth: Int               // 1...12
    let bsDay: Int
    /// Tithi label where well-known (e.g. "त्रितिया", "दशमी", "पूर्णिमा") —
    /// shown as the Hindu-calendar overlay on the festival's day.
    let tithiNepali: String?
    /// Important festivals get an advance notification N days before
    /// (user-configurable, default 2) in addition to the day-of one.
    let isImportant: Bool
    /// True for lunar-sighted dates that may drift ±1 day year to year.
    let isLunarSighted: Bool

    init(id: String, nameNepali: String, nameEnglish: String,
         bsMonth: Int, bsDay: Int, tithiNepali: String? = nil,
         isImportant: Bool = false, isLunarSighted: Bool = false) {
        self.id = id
        self.nameNepali = nameNepali
        self.nameEnglish = nameEnglish
        self.bsMonth = bsMonth
        self.bsDay = bsDay
        self.tithiNepali = tithiNepali
        self.isImportant = isImportant
        self.isLunarSighted = isLunarSighted
    }
}

/// The bundled festival dataset (v1 — static, offline, honest about its
/// boundaries). Daily tithi for ARBITRARY days (real panchanga, e.g.
/// "today is Ekadashi") is deliberately NOT computed here: it requires
/// lunisolar ephemeris data, and faking it would be wrong roughly half
/// the time. The honest v2 path is a daily-panchanga ICS subscription
/// (see docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md §4.2
/// — same conclusion reached there for the religious calendar).
enum NepaliFestivalCatalog {

    static let all: [NepaliFestival] = [
        // Baisakh
        NepaliFestival(id: "nepali_new_year", nameNepali: "नयाँ वर्ष",
                       nameEnglish: "Nepali New Year", bsMonth: 1, bsDay: 1,
                       tithiNepali: "प्रतिपदा", isImportant: true),
        NepaliFestival(id: "buddha_jayanti", nameNepali: "बुद्ध जयन्ती",
                       nameEnglish: "Buddha Jayanti", bsMonth: 1, bsDay: 15,
                       tithiNepali: "पूर्णिमा", isLunarSighted: true),
        // Jestha
        NepaliFestival(id: "gantantra_diwas", nameNepali: "गणतन्त्र दिवस",
                       nameEnglish: "Republic Day", bsMonth: 2, bsDay: 15,
                       isImportant: false),
        // Ashadh
        NepaliFestival(id: "dahichaura", nameNepali: "दहीचिउरा",
                       nameEnglish: "Dahi Chiura (Asar 15)", bsMonth: 3, bsDay: 15),
        // Shrawan
        NepaliFestival(id: "janai_purnima", nameNepali: "जनै पूर्णिमा",
                       nameEnglish: "Janai Purnima / Raksha Bandhan", bsMonth: 4, bsDay: 15,
                       tithiNepali: "पूर्णिमा", isLunarSighted: true),
        // Bhadra
        NepaliFestival(id: "gai_jatra", nameNepali: "गाई जात्रा",
                       nameEnglish: "Gai Jatra", bsMonth: 5, bsDay: 1,
                       tithiNepali: "प्रतिपदा"),
        NepaliFestival(id: "krishna_janmashtami", nameNepali: "कृष्ण जन्माष्टमी",
                       nameEnglish: "Krishna Janmashtami", bsMonth: 5, bsDay: 23,
                       tithiNepali: "अष्टमी", isLunarSighted: true),
        NepaliFestival(id: "haritalika_teej", nameNepali: "हरितालिका तीज",
                       nameEnglish: "Haritalika Teej", bsMonth: 5, bsDay: 3,
                       tithiNepali: "त्रितिया", isImportant: true),
        // Ashwin
        NepaliFestival(id: "ghatasthapana", nameNepali: "घटस्थापना",
                       nameEnglish: "Ghatasthapana (Dashain begins)", bsMonth: 6, bsDay: 1,
                       tithiNepali: "प्रतिपदा", isImportant: true),
        NepaliFestival(id: "sambidhan_diwas", nameNepali: "संविधान दिवस",
                       nameEnglish: "Constitution Day", bsMonth: 6, bsDay: 3),
        NepaliFestival(id: "fulpati", nameNepali: "फूलपाती",
                       nameEnglish: "Fulpati", bsMonth: 6, bsDay: 7,
                       tithiNepali: "सप्तमी", isImportant: true),
        NepaliFestival(id: "maha_astami", nameNepali: "महाअष्टमी",
                       nameEnglish: "Maha Astami", bsMonth: 6, bsDay: 8,
                       tithiNepali: "अष्टमी", isImportant: true),
        NepaliFestival(id: "maha_navami", nameNepali: "महानवमी",
                       nameEnglish: "Maha Navami", bsMonth: 6, bsDay: 9,
                       tithiNepali: "नवमी", isImportant: true),
        NepaliFestival(id: "bijaya_dashami", nameNepali: "विजया दशमी",
                       nameEnglish: "Bijaya Dashami", bsMonth: 6, bsDay: 10,
                       tithiNepali: "दशमी", isImportant: true),
        // Kartik
        NepaliFestival(id: "kag_tihar", nameNepali: "काग तिहार",
                       nameEnglish: "Kag Tihar (Crow)", bsMonth: 7, bsDay: 1,
                       tithiNepali: "प्रतिपदा"),
        NepaliFestival(id: "kukur_tihar", nameNepali: "कुकुर तिहार",
                       nameEnglish: "Kukur Tihar (Dog)", bsMonth: 7, bsDay: 2,
                       tithiNepali: "द्वितीया"),
        NepaliFestival(id: "laxmi_puja", nameNepali: "लक्ष्मी पूजा",
                       nameEnglish: "Laxmi Puja", bsMonth: 7, bsDay: 3,
                       tithiNepali: "त्रितिया", isImportant: true),
        NepaliFestival(id: "govardhan_puja", nameNepali: "गोवर्धन पूजा",
                       nameEnglish: "Govardhan Puja", bsMonth: 7, bsDay: 4,
                       tithiNepali: "चतुर्थी"),
        NepaliFestival(id: "bhai_tika", nameNepali: "भाई टीका",
                       nameEnglish: "Bhai Tika", bsMonth: 7, bsDay: 5,
                       tithiNepali: "पञ्चमी", isImportant: true),
        NepaliFestival(id: "chhath", nameNepali: "छठ",
                       nameEnglish: "Chhath Puja", bsMonth: 7, bsDay: 6,
                       tithiNepali: "षष्ठी", isImportant: true),
        // Mangsir — no major fixed observances
        // Poush
        NepaliFestival(id: "yomari_punhi", nameNepali: "योमरी पुन्हि",
                       nameEnglish: "Yomari Punhi", bsMonth: 9, bsDay: 15,
                       tithiNepali: "पूर्णिमा", isLunarSighted: true),
        // Magh
        NepaliFestival(id: "maghe_sankranti", nameNepali: "माघे सङ्क्रान्ति",
                       nameEnglish: "Maghe Sankranti", bsMonth: 10, bsDay: 1,
                       isImportant: true),
        NepaliFestival(id: "saraswati_puja", nameNepali: "सरस्वती पूजा",
                       nameEnglish: "Saraswati Puja (Shree Panchami)", bsMonth: 10, bsDay: 20,
                       tithiNepali: "पञ्चमी", isLunarSighted: true),
        // Falgun
        NepaliFestival(id: "maha_shivaratri", nameNepali: "महाशिवरात्रि",
                       nameEnglish: "Maha Shivaratri", bsMonth: 11, bsDay: 28,
                       tithiNepali: "चतुर्दशी", isImportant: true, isLunarSighted: true),
        NepaliFestival(id: "holi", nameNepali: "होली",
                       nameEnglish: "Holi", bsMonth: 11, bsDay: 15,
                       tithiNepali: "पूर्णिमा", isImportant: true, isLunarSighted: true),
        // Chaitra
        NepaliFestival(id: "ram_navami", nameNepali: "राम नवमी",
                       nameEnglish: "Ram Navami", bsMonth: 12, bsDay: 9,
                       tithiNepali: "नवमी"),
        NepaliFestival(id: "chaite_dashain", nameNepali: "चैते दशैं",
                       nameEnglish: "Chaite Dashain", bsMonth: 12, bsDay: 10,
                       tithiNepali: "दशमी"),
    ]

    /// Festivals falling on a given BS month/day.
    static func festivals(bsMonth: Int, bsDay: Int) -> [NepaliFestival] {
        all.filter { $0.bsMonth == bsMonth && $0.bsDay == bsDay }
    }
}
