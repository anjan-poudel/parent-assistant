import Foundation

/// Pure normalizer for the appliance CATEGORY dimension — the key a
/// per-category default manual hangs off (2026-09-13, appliance-default-
/// manual task).
///
/// WHY this is its own key space rather than `ApplianceIdentity.category`
/// used raw: the two sides that must meet here speak different dialects.
/// A cached entry carries the category Gemini identified from a photo
/// (prompt-constrained to "microwave", "tv_remote", "smart_hub",
/// "washing_machine", "air_conditioner", "other" — but the model is only
/// prompt-engineered, never schema-enforced), while the voice turn carries
/// the elder's own word for the appliance in `entities["appliance"]`
/// ("माइक्रोवेभ", "tv", "washing machine", "फ्रिज"). "First manual for this
/// category wins" is only true if both spellings fold onto one key.
///
/// Unknown strings pass through NORMALIZED (lowercased, whitespace
/// collapsed) rather than being dropped: a category nobody listed still
/// gets a stable key that matches itself, so a fridge full of future
/// appliance types keeps working with no code change.
///
/// Matching is deliberately coarse — a small EN+NE synonym map, never
/// fuzzy/prefix matching. A too-clever match would serve the WRONG
/// appliance's manual, the same fabricated-answer failure the cache's
/// question keys already guard against (see `ApplianceCache`'s header).
enum ApplianceCategoryKey {

    /// Canonical key for a category string, or nil when there is nothing
    /// to key on (nil/blank/whitespace-only).
    ///
    /// The table's keys are themselves in normalized form, so lookups are
    /// a plain dictionary hit after folding — no case or spacing variant
    /// can slip past it ("Air  Conditioner", "TV", "टिभी ").
    private static let synonyms: [String: String] = [
        // microwave / माइक्रोवेभ — the Devanagari spellings differ by one
        // syllable and both are in live use, so both are listed.
        "microwave": "microwave",
        "माइक्रोवेभ": "microwave",
        "माइक्रोभेभ": "microwave",

        // TV / remote: the appliance photo identifies the device
        // ("tv_remote" is the prompt's own name for it), the elder says
        // "टिभी" or "television" — all one category here, because the
        // manual an elder wants is "how do I work this TV".
        "tv": "tv_remote",
        "टिभी": "tv_remote",
        "television": "tv_remote",
        "tv_remote": "tv_remote",

        "washing machine": "washing_machine",
        "वासिङ मेसिन": "washing_machine",
        "वाशिङ मेसिन": "washing_machine",

        "fridge": "fridge",
        "फ्रिज": "fridge",
        "refrigerator": "fridge",

        "air conditioner": "air_conditioner",
        "एयर कन्डिसन": "air_conditioner",
        "एसी": "air_conditioner",
        "ac": "air_conditioner",

        "stove": "stove",
        "ग्यास": "stove",
        "चुलो": "stove",

        "rice cooker": "rice_cooker",
        "राइस कुकर": "rice_cooker",
    ]

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = trimmed.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return synonyms[folded] ?? folded
    }

    /// Whether this category may carry a DEFAULT manual.
    ///
    /// "other" is the vision prompt's bucket for "Gemini could not tell
    /// what this is", and blank is a payload that identified nothing at
    /// all. Both really mean "unknown", a bucket EVERY unidentifiable
    /// appliance in the household shares — a default stored under one of
    /// them would later be served for a completely different appliance,
    /// the fabricated answer this feature must never produce. Such entries
    /// are still cached and listed (the elder's own work is never thrown
    /// away); they just never become a category's default.
    static func isDefaultEligible(_ raw: String?) -> Bool {
        guard let key = normalize(raw) else { return false }
        return key != "other"
    }
}
