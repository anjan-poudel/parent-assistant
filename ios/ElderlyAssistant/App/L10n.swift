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

extension ModelCatalogEntry {
    /// Localized model display name: catalog key `model.name.<id>`
    /// resolved in `locale`; falls back to the English `displayName` for
    /// models without a catalog entry (spec §3.2 — no hardcoded English
    /// in the UI).
    func displayName(locale: Locale) -> String {
        let key = "model.name.\(id.rawValue)"
        let value = L10n.str(key, locale: locale)
        return value == key ? displayName : value
    }
}
