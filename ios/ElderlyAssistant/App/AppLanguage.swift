import Foundation

/// The app's active display/spoken language (spec §3.2).
///
/// Nepali (`ne`) is the pilot language; English ships as a development and
/// fallback language. Adding a language later means: one case here + catalog
/// entries in `Localizable.xcstrings` — no other code changes.
///
/// `AppLanguage` is the single source of truth for the `.locale` environment
/// value injected at the app root; views read `@Environment(\.locale)` and
/// get String-Catalog lookup plus correct date/number formatting for free.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case nepali = "ne"
    case english = "en"

    var id: String { rawValue }

    /// The locale this language resolves to by DEFAULT — `ne` → Nepali
    /// (Nepal), `en` → English (United States). A household in the Indian
    /// Nepali community can override this in Settings (`AppLocale`);
    /// formatting locale is a separate setting from display language
    /// (2026-09-13: the two were conflated, and `Locale(identifier: "ne")`
    /// used at fallback call sites carried NO region at all, so it
    /// silently inherited the device region — Indian numbering on an
    /// India-region device).
    var locale: Locale { defaultLocale.locale }

    /// The region-qualified default locale for this language.
    var defaultLocale: AppLocale {
        switch self {
        case .nepali: return .nepaliNepal
        case .english: return .englishUS
        }
    }

    /// Catalog key for the endonym — resolve via the environment locale
    /// like every other string (views use `Text(LocalizedStringKey)`).
    var displayNameKey: String {
        switch self {
        case .nepali: return "language.nepali"
        case .english: return "language.english"
        }
    }

    private static let defaultsKey = "appLanguage"

    static func persisted() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let language = AppLanguage(rawValue: raw) else {
            return .nepali   // pilot language default
        }
        return language
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The app's formatting locale: language + REGION, e.g. `ne-NP` (Nepali
/// in Nepal — the default for `ne`) vs `ne-IN` (Nepali in India, the
/// diaspora convention). Drives date, time and NUMBER formatting as well
/// as which regional festival conventions apply.
///
/// Language and locale are deliberately independent settings (2026-09-13):
/// switching display language re-defaults the locale (ne → ne-NP,
/// en → en-US) but a household can then override the region on its own —
/// a Nepali-speaking family in India picks `ne-IN` and keeps Nepali UI.
enum AppLocale: String, CaseIterable, Identifiable, Codable {
    case nepaliNepal = "ne-NP"
    case nepaliIndia = "ne-IN"
    case englishUS = "en-US"
    case englishIndia = "en-IN"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    /// The display language this locale belongs to.
    var language: AppLanguage {
        switch self {
        case .nepaliNepal, .nepaliIndia: return .nepali
        case .englishUS, .englishIndia: return .english
        }
    }

    /// Short region label for the picker (region names are localized via
    /// the String Catalog, so English UI shows "Nepal", Nepali UI "नेपाल").
    var regionDisplayNameKey: String {
        switch self {
        case .nepaliNepal: return "locale.region.nepal"
        case .nepaliIndia, .englishIndia: return "locale.region.india"
        case .englishUS: return "locale.region.unitedStates"
        }
    }

    /// The locale a language resets to when the language changes.
    static func defaultLocale(for language: AppLanguage) -> AppLocale {
        language.defaultLocale
    }

    /// The regions offered for a language, in display order.
    static func supported(for language: AppLanguage) -> [AppLocale] {
        switch language {
        case .nepali: return [.nepaliNepal, .nepaliIndia]
        case .english: return [.englishUS, .englishIndia]
        }
    }

    private static let defaultsKey = "appLocale"

    /// The persisted locale, if it is still valid for `language` —
    /// otherwise the language's region default. A stored locale for a
    /// language the user has since switched away from must not leak
    /// across (e.g. `en-IN` surviving a switch to Nepali).
    static func persisted(for language: AppLanguage) -> AppLocale {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let stored = AppLocale(rawValue: raw),
              stored.language == language else {
            return defaultLocale(for: language)
        }
        return stored
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
