import Foundation

/// Catalog-key resolution for non-View code (router speech, notifications,
/// services). Views resolve keys through the environment `.locale`; this
/// helper exists for code that must resolve against an explicit locale —
/// per spec §3.2, `AppLanguage` is the source of truth `.locale` is derived
/// from, and this is the single place non-View code resolves strings.
enum L10n {
    static func str(_ key: String, locale: Locale) -> String {
        String(localized: String.LocalizationValue(key), locale: locale)
    }

    /// Resolves `key` and applies `arguments` with `String(format:)`.
    /// Used for keys containing %@ / %lld placeholders.
    static func fmt(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        let format = str(key, locale: locale)
        return String(format: format, arguments: arguments)
    }
}
