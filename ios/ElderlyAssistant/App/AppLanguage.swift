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

    /// The locale this language resolves to. `ne` → `ne-NP`, `en` → `en-US`.
    var locale: Locale {
        switch self {
        case .nepali: return Locale(identifier: "ne-NP")
        case .english: return Locale(identifier: "en-US")
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
