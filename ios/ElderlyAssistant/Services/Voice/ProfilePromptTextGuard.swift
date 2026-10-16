import Foundation

// MARK: - Profile prompt-text guard (profile-interview, T-091, C07)
//
// The one profile string that may enter a prompt — the address-as term —
// is user-entered and attacker-influenceable. This guard applies the
// project's existing injection discipline at the READ seam, before any
// prompt context is constructed, in the fixed order of design-l2 §9.3:
//
//   quarantine (InputSanitiser.sanitise, level .quarantine: control strip,
//   whitespace collapse, marker REMOVAL, clamp 200)
//     → strip-then-detect (a marker SHAPE left after the quarantine action
//       trips `InputSanitiser.containsInjectionMarker` — a shape can
//       re-form when one removal splices its neighbours into another
//       entry's text; the entries themselves are never restated here)
//     → Character-boundary clamp to `maxPromptTermGraphemes`
//     → quote-slot neutralisation (the quote family and the backtick
//       become a plain apostrophe, prompt-side only)
//     → nil on any residual.
//
// CONTAINMENT (AM-1, SD-1) — where the safety actually lives:
//
//  - the quarantine ACTION applies to input that trips the shared
//    InputSanitiser table: such a term is dropped for the turn and the
//    assistant runs un-personalized (FR-PI-011);
//  - out-of-table instruction shapes (including non-English ones, which
//    the English/transliterated table does not know) are NOT detected and
//    are instead contained as DATA: the value can only appear inside the
//    fixed quoted slot of the `addressAsClause` framing ("Address them as
//    \"…\""), the 24-grapheme bound caps its size, and the guard is
//    structurally INCAPABLE of any effect beyond the prompt string — it
//    holds no reference to routing, reply-style rules, authentication,
//    safety behavior, or the store, and can therefore cause no action, no
//    routing change and no profile write;
//  - the stored and spoken term is never altered by any of this — the
//    neutralisation below is applied to a prompt-side copy only (AM-2,
//    ADR-09), so the wake acknowledgment still speaks what the user
//    recorded.
//
// The marker table itself stays private in `InputSanitiser` by
// prohibition: this file asks its accessors and never copies its entries
// (SD-1 records that its coverage is bounded, and extending it is a
// project-level decision outside this feature).

/// Shared Character-boundary clamp. Used by the guard here and by the
/// entry UI (T-098) so the entry bound and the composition bound can
/// never drift apart.
enum ProfileText {
    /// A `Character`-boundary prefix: grapheme clusters (including
    /// Devanagari conjuncts) are never split. A non-positive bound
    /// clamps to the empty string.
    static func clamped(_ value: String, maxGraphemes: Int) -> String {
        guard maxGraphemes > 0 else { return "" }
        return String(value.prefix(maxGraphemes))
    }
}

struct ProfilePromptTextGuard {

    /// Composition bound (L1 §11 `maxPromptTermGraphemes`). Default is
    /// the entry bound, so a stored term is never truncated at
    /// composition.
    let maxPromptTermGraphemes: Int

    init(maxPromptTermGraphemes: Int = 24) {
        self.maxPromptTermGraphemes = maxPromptTermGraphemes
    }

    /// nil in → nil out. nil out when:
    ///  - the value is empty/whitespace after quarantine,
    ///  - the quarantine action left a residual injection-marker shape
    ///    (strip-then-detect via InputSanitiser's single-sourced table),
    ///  - the bounded value is empty.
    /// Quote-slot neutralisation: the quote family (U+0022, U+2018,
    /// U+2019, U+201C, U+201D) and the backtick become `'` (U+0027) so
    /// the term can never terminate the clause's quoted slot (AM-2).
    /// Prompt-side only — the stored and spoken term is untouched
    /// (FR-PI-010, ADR-09).
    func guarded(_ value: String?) -> String? {
        guard let value else { return nil }

        let quarantined = InputSanitiser.sanitise(value, level: .quarantine)
        guard !quarantined.isEmpty else { return nil }

        // Strip-then-detect: ask the single-sourced table whether a
        // marker shape SURVIVED the quarantine action.
        guard !InputSanitiser.containsInjectionMarker(quarantined) else {
            return nil
        }

        let bounded = ProfileText.clamped(quarantined,
                                          maxGraphemes: maxPromptTermGraphemes)
        let neutralised = Self.neutraliseQuotes(bounded)
        guard !neutralised.isEmpty else { return nil }
        return neutralised
    }

    /// The quote family and the backtick → plain apostrophe. Character
    /// level, so a Devanagari term is untouched by construction.
    private static func neutraliseQuotes(_ value: String) -> String {
        let replacements: Set<Character> = [
            "\u{0022}",  // " quotation mark
            "\u{2018}",  // ' left single quotation mark
            "\u{2019}",  // ' right single quotation mark
            "\u{201C}",  // " left double quotation mark
            "\u{201D}",  // " right double quotation mark
            "\u{0060}",  // ` grave accent
        ]
        return String(value.map { replacements.contains($0) ? "'" : $0 })
    }
}
