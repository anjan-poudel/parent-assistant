import Foundation

/// Catalog-key resolution for non-View code (router speech, notifications,
/// services). Views resolve keys through the environment `.locale`; this
/// helper exists for code that must resolve against an explicit locale —
/// per spec §3.2, `AppLanguage` is the source of truth `.locale` is derived
/// from, and this is the single place non-View code resolves strings.
enum L10n {
    /// lproj-direct resolution, cached per language. Verified empirically:
    /// `String(localized:locale:)` IGNORES the locale for key lookup (its
    /// locale parameter only formats %@ arguments) — on an English-system
    /// simulator it returned "Talk" for a complete ne.lproj. Reading the
    /// language's lproj bundle directly is the only path that honors the
    /// app language for key resolution.
    private static let bundleCacheLock = NSLock()
    private static var bundleCache: [String: Bundle?] = [:]

    static func str(_ key: String, locale: Locale) -> String {
        // 1. Language-level lproj (e.g. "ne" for ne-NP).
        if let language = locale.language.languageCode?.identifier,
           let value = lookup(key, lproj: language) {
            return value
        }
        // 2. Full-identifier lproj (region-specific overrides).
        if let value = lookup(key, lproj: locale.identifier) {
            return value
        }
        // 3. Last resort: the standard API (system language).
        return String(localized: String.LocalizationValue(key), locale: locale)
    }

    private static func lookup(_ key: String, lproj name: String) -> String? {
        let bundle: Bundle?
        bundleCacheLock.lock()
        if let cached = bundleCache[name] {
            bundle = cached
            bundleCacheLock.unlock()
        } else {
            bundleCacheLock.unlock()
            bundle = Bundle.main.path(forResource: name, ofType: "lproj")
                .flatMap(Bundle.init(path:))
            bundleCacheLock.lock()
            bundleCache[name] = bundle
            bundleCacheLock.unlock()
        }
        guard let bundle else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
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
