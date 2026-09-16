import Foundation

/// The appliance helper's label presentation seam (T-013, FR-LCT-020, R8).
///
/// One caller-side resolver, so a label the helper presents is resolved
/// against the **same** dictionary and the **same** persisted store the live
/// translation path uses — and so "a translation cached in one surface is
/// reused by the other with no network call" is true by construction rather
/// than by convention.
///
/// The ordering is what keeps the shipped helper honest (NFR-LCT-012, R8):
///
///  1. `ApplianceLabelLocalizer.display(for:locale:)` runs **first**, and
///     whenever it produces a translation its result *is* the answer. The
///     cache can never override a translation the localizer produced.
///  2. The shared store is consulted only where the localizer passes the
///     label through — under a Nepali-active locale, for a label that is not
///     already Devanagari, and only for a **persisted** entry.
///  3. Otherwise the localizer's own result is returned untouched.
///
/// Every label the helper *translates* today therefore renders identically.
/// The one behavioural delta is the class R8 records: a label the localizer
/// passes through whose normalized form is already in the persisted layer
/// from a prior live-translation resolution now renders that cached
/// translation. The dictionary-extension delta (new curated labels) is
/// additive data, not a sharing delta.
///
/// A dictionary-layer hit is deliberately **not** accepted here. The
/// localizer has just consulted that same table with its own rule (trim +
/// case-fold); the cache's layer A reaches it through the feature
/// normalization, which also collapses internal whitespace. Accepting it
/// would render a translation for a label the localizer passes through —
/// a delta outside the class R8 reviewed — so the localizer's pass-through
/// stands and layer A is left to the live path, which has no localizer in
/// front of it.
///
/// The helper gains nothing else: no cloud tier, no consent gate, no cost
/// latch, no overlay behaviour. Shared dictionary and shared storage, not
/// shared translation policy. The seam makes no request and stores no entry:
/// it only calls the cache's lookup, which — as for any caller — may move
/// that entry's ordering counter and persist the coalesced payload. No
/// translation data is added, changed or removed by the helper path.
enum ApplianceLabelResolver {

    /// What the helper renders for one label — and which layer produced it,
    /// so a test (or a later surface) can assert the two surfaces agree.
    struct Resolution: Equatable {
        /// Exactly the shape the shipped view renders from.
        let display: ApplianceLabelLocalizer.Display
        /// The layer that produced the rendered form; `nil` when the label
        /// passes through untranslated, which is the shipped behaviour.
        let origin: LabelTranslationCache.Origin?
        /// The tier that produced the string: tier 0 for a curated entry,
        /// the cloud tier for a persisted one (with no request made).
        var tier: TranslationTier? { origin?.tier }
    }

    /// Resolves a printed label for the helper's presentation path.
    ///
    /// `cache` is the app's one shared store; `nil` means the composition
    /// root has not wired one, in which case this is exactly the shipped
    /// localizer call (the parameter exists so the seam is injectable and
    /// the shipped call sites keep compiling unchanged).
    static func resolve(label: String,
                        locale: Locale,
                        cache: LabelTranslationCache?) -> Resolution {
        let local = ApplianceLabelLocalizer.display(for: label, locale: locale)

        // 1. The localizer translated it: that result is the answer.
        if local.secondary != nil {
            return Resolution(display: local, origin: .curatedDictionary)
        }

        // 2. The helper augments only under a Nepali-active locale...
        guard ApplianceLabelLocalizer.isNepali(locale) else {
            return Resolution(display: local, origin: nil)
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // ...and never re-translates a label that is already Devanagari.
        guard !trimmed.isEmpty, !ApplianceLabelLocalizer.containsDevanagari(trimmed) else {
            return Resolution(display: local, origin: nil)
        }

        guard let cache else { return Resolution(display: local, origin: nil) }

        switch cache.lookup(text: trimmed) {
        case .success(.some(let hit)) where hit.origin == .persisted:
            // The same Display shape the localizer produces for an applied
            // translation: the translation, with the printed English kept as
            // the reference line.
            let display = ApplianceLabelLocalizer.Display(primary: hit.translation,
                                                          secondary: trimmed)
            return Resolution(display: display, origin: hit.origin)
        default:
            // A miss, a dictionary-layer hit, or a self-healed read fault:
            // the shipped pass-through stands, and nothing is surfaced.
            return Resolution(display: local, origin: nil)
        }
    }
}
