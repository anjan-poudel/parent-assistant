import Foundation

// MARK: - Dose line composition (FR-MSR-003; design-l2 C2 / IF-5)
//
// The entry model renders ONE dose line everywhere: the fired-dose screen,
// the spoken briefing and the editor's scanned-strength display all read
// `MedicationEntry.doseDescription` (Models.swift :30). This file is the
// single composer that turns the structured quantity (T-001's
// `MedicationQuantity` value + unit) into that line at save — design-l2 C2
// and L1 §4.6's four rules, nothing more. No other file in the feature
// composes dose text, and this one is pure: no state, no IO, no clock, no
// storage (persistence is T-017's save gate).

/// Composes the stored dose line from a structured quantity and the
/// family's dose text (design-l2 IF-5, signature verbatim).
///
/// The composed string IS the stored `doseDescription` (design-l2 C2: "the
/// composed string is the stored `doseDescription`"), so every downstream
/// surface keeps reading the same field it reads today.
enum DoseLine {

    /// The fixed separator between the composed quantity and a non-blank
    /// dose text. Design-l2 C2 pins it as `", "` (implementation-fixed per
    /// L1 §4.6 rule 2: `"1 tablet, 500 mg"` — nothing the family saw in the
    /// form is dropped). Punctuation only: deliberately NOT a catalog key,
    /// because it carries no words and is identical in both languages.
    private static let separator = ", "

    /// Composes the single dose line the entry stores.
    ///
    /// Rules (L1 §4.6, the one documented, deterministic composition):
    ///
    /// 1. quantity set, dose text blank → `"<amount> <unit label>"`;
    /// 2. quantity set, dose text non-blank → the composed quantity, then
    ///    the fixed separator, then the dose text (`"1 tablet, 500 mg"`) —
    ///    the scanned strength the form showed is never dropped;
    /// 3. quantity nil → the dose text itself (today's path: "half tablet"
    ///    and every legacy entry);
    /// 4. both empty → the empty string (today's behaviour for a dose-less
    ///    entry).
    ///
    /// Blank means whitespace-and-newline-trimmed empty, and the returned
    /// dose text is its trimmed form — exactly the shipped save path's
    /// normalization (`MedicationEditorDraft.storedStrength`,
    /// `AppCoordinator.addMedication` :11647 trims before storing), so
    /// composing an already-stored value is a no-op and re-saving a legacy
    /// entry changes nothing the family can see.
    ///
    /// The amount renders as stored, as ASCII digits (the `%lld` count-copy
    /// convention this catalog already ships). It is never repaired:
    /// positivity is the editor's validation (the `MedicationQuantity`
    /// contract, T-001), so a corrupt stored 0 renders `"0 <unit>"` and is
    /// never silently turned into 1 or into a quantity-less line — nothing
    /// is invented or inferred.
    ///
    /// Deterministic by construction — same inputs, same line, every call,
    /// in any order: the function reads no state, no `Date`, no store, and
    /// mutates nothing, so it is safe to call from the save path without a
    /// view and to call again for the identical result.
    static func compose(quantity: MedicationQuantity?,
                        doseText: String,
                        locale: Locale) -> String {
        let text = doseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quantity else {
            // Rules 3 and 4: no quantity keeps the family's dose text
            // (trimmed) and invents nothing — no default amount, no unit,
            // no separator.
            return text
        }
        let label = unitLabel(for: quantity.unit, locale: locale)
        let rendered = label.isEmpty
            ? "\(quantity.amount)"
            : "\(quantity.amount) \(label)"
        return text.isEmpty ? rendered : rendered + Self.separator + text
    }

    /// The localized label for a stored unit token.
    ///
    /// A token matching a `MedicationDoseUnit` raw value — exact match
    /// after trimming, the `MedicationPurposeDraft` chip-or-free-text
    /// precedent — resolves through the T-012 catalog key
    /// `meds.unit.<unit>`, the ONLY source of unit labels. Any other token
    /// is the family's own words and renders verbatim, never mapped onto
    /// another unit (the scanner's never-guess stance: a custom token is
    /// not "fixed up" into a built-in one, and near misses — different
    /// case, a plural form — are free text too).
    ///
    /// Grammatical number: the shipped catalog holds ONE label per unit —
    /// T-012 pins exactly `meds.unit.tablet|…|sachet` and the file carries
    /// no plural variants — while this unit may not hardcode user-visible
    /// copy. The composer's answer is therefore: the label renders the same
    /// at every amount ("1 tablet" and "2 tablet"; "2 ml", never a naive
    /// English "s" glued onto the catalog's own abbreviation) and ONLY the
    /// numeral changes. Nepali unit nouns take no suffix in this
    /// construction either ("2 चक्की"), so no language needs invented
    /// morphology. A plural form, if it is ever wanted, is a T-012 catalog
    /// edit resolved through this one seam — never a suffix invented here.
    ///
    /// A total catalog miss — the coverage suite (`L10nCatalogCoverageTests`,
    /// T-012) is what prevents one shipping in either language — falls back
    /// to the stored token rather than composing a dangling number: the
    /// line never loses the unit the family chose. A blank token (corrupt;
    /// the editor never saves a quantity without a unit) yields no unit
    /// part at all, so no trailing separator and no invented word appears.
    private static func unitLabel(for unit: String, locale: Locale) -> String {
        let token = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let known = MedicationDoseUnit(rawValue: token) else {
            return token
        }
        let key = "meds.unit." + known.rawValue
        let resolved = L10n.str(key, locale: locale)
        return resolved.isEmpty ? token : resolved
    }
}
