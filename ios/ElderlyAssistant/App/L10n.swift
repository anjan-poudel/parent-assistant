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
        // 3. Last resort: the standard API (system language). A total
        //    miss returns the KEY itself — [AUDIT-SPOKEN] never let that
        //    reach a synthesizer or a card: return "" instead, so the
        //    emptiness guards at the speech seams (CommandRouter.speak,
        //    NotificationReader) turn a miss into silence rather than
        //    reading the key aloud, and display callers fall back to
        //    their own defaults instead of rendering "router.x.y".
        let fallback = String(localized: String.LocalizationValue(key), locale: locale)
        return fallback == key ? "" : fallback
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
    /// Used for keys containing %@ / %lld placeholders. A total miss
    /// yields "" (see `str`) — callers must treat empty as
    /// nothing-to-say, not as a format string.
    static func fmt(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        let format = str(key, locale: locale)
        return String(format: format, arguments: arguments)
    }
}

// MARK: - Cloud-chat safe templates (T-171; design-l1 §17)

extension L10n {
    /// The bounded, spec-authored safe-template set (design-l1 §17:
    /// `chat.safeTemplate.<class>` plus a generic entry; FR-CNR-006). The
    /// guard's check classes (T-169's `GrammarCheckClass` raw values, the
    /// style spec's `guard_checks` ids) map 1:1 onto the class cases. The
    /// set is CLOSED on purpose: the fallback text spoken when a flagged
    /// reply cannot be escalated is always one of these catalogue values —
    /// never free-form text generated at runtime, and never the flagged
    /// reply itself.
    enum SafeTemplate: String, CaseIterable {
        case generic
        case honorificAgreement
        case devanagariPurity
        case danglingParticle

        /// The catalogue key that carries this template's copy.
        var catalogKey: String { "chat.safeTemplate.\(rawValue)" }
    }

    /// Deterministic selection keyed by the guard's flagging check classes
    /// (T-174 consumes this at the dispatch seam): the FIRST known class
    /// wins — the guard reports classes in its own fixed order — and a
    /// flag with no known class resolves to `generic`. Unknown names are
    /// dropped, never echoed into a key: the set stays bounded.
    static func safeTemplate(forCheckClasses classes: [String]) -> SafeTemplate {
        for name in classes {
            if let template = SafeTemplate(rawValue: name) { return template }
        }
        return .generic
    }

    /// Resolves a safe template's copy in `locale` (the `str` contract:
    /// a total miss yields "" — callers treat that as nothing-to-say; the
    /// catalogue coverage suite is what keeps a miss from shipping).
    static func safeTemplate(_ template: SafeTemplate, locale: Locale) -> String {
        str(template.catalogKey, locale: locale)
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
        // `L10n.str` returns "" on a total miss (never the raw key); an
        // empty resolution or a literal key-shaped value both mean "no
        // catalog entry" and fall back to the English displayName.
        return value.isEmpty || value == key ? displayName : value
    }
}
