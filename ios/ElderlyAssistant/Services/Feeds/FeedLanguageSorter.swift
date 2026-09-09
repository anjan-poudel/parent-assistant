import Foundation

// MARK: - Language-aware feed ordering (feed language task, 2026-09-08)

/// Script-based language attribution for one feed item, detected from
/// its ORIGINAL title+summary — the language-aware sort's only input.
/// Deliberately NOT derived from translations: the sort is computed
/// from the source content, so a translated English item stays at the
/// bottom of a Nepali feed (translate-on-ask never re-sorts).
enum FeedItemLanguage: Equatable {
    /// Devanagari script present — a Nepali-content item.
    case devanagari
    /// Latin script present and no Devanagari — an English-content
    /// item (accented Latin like "CAFÉ" stays Latin).
    case latin
    /// No letters of either script (symbols/digits only) — cannot be
    /// attributed to a language. Sorted with the non-matching group:
    /// an unattributable item is never claimed as the selected
    /// language (honesty rule).
    case undetermined
}

/// Pure script detection (grapheme-safe: scalar inspection only, never
/// scalar surgery — text is never rewritten).
enum FeedLanguageDetector {

    /// Devanagari main block (U+0900–U+097F).
    private static let devanagariRange: ClosedRange<UInt32> =
        (0x0900 as UInt32)...0x097F
    /// Basic Latin letters, Latin-1 Supplement, and Latin Extended A/B
    /// (so accented English titles still read as Latin).
    private static let latinRanges: [ClosedRange<UInt32>] = [
        (0x0041 as UInt32)...0x005A,
        (0x0061 as UInt32)...0x007A,
        (0x00C0 as UInt32)...0x00FF,
        (0x0100 as UInt32)...0x024F
    ]

    /// Devanagari WINS when both scripts appear: a Nepali headline that
    /// quotes an English name is still a Nepali item — it must never be
    /// relegated to the fallback group over one Latin word.
    static func language(of item: FeedItem) -> FeedItemLanguage {
        let text = "\(item.title) \(item.summary)"
        if isDevanagari(text) { return .devanagari }
        if isLatin(text) { return .latin }
        return .undetermined
    }

    static func isDevanagari(_ text: String) -> Bool {
        contains(text, in: [devanagariRange])
    }

    static func isLatin(_ text: String) -> Bool {
        contains(text, in: latinRanges)
    }

    private static func contains(_ text: String,
                                 in ranges: [ClosedRange<UInt32>]) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return ranges.contains { $0.contains(value) }
        }
    }
}

// MARK: - Language grouping

/// Stable language grouping (feed language task, 2026-09-08): items in
/// the SELECTED language come FIRST; fallback-language (and
/// unattributable) items go to the BOTTOM. The partition is STABLE —
/// input order is preserved inside each group, and the input is
/// `FeedComposer`'s newest-first list, so within-group order IS the
/// recency order (the spec's "then relevance": recency is the
/// within-group relevance signal). The topic filter runs earlier
/// (FeedService, before compose) — these semantics are unchanged, only
/// the presentation order differs.
///
/// English locale = the DEFAULT language: grouping does not apply
/// (pinned as identity) — for an English user every item is already in
/// the selected language, and the original newest-first order is the
/// previous behavior preserved.
enum FeedLanguageSorter {

    /// True when the item's script matches the selected language.
    static func matches(language: FeedItemLanguage, app: AppLanguage) -> Bool {
        switch app {
        case .nepali: return language == .devanagari
        case .english: return language == .latin
        }
    }

    /// The grouped list. Identity for English; a stable partition for
    /// Nepali (matched first, everything else after).
    static func sort(_ items: [FeedItem], app: AppLanguage) -> [FeedItem] {
        guard app == .nepali else { return items }
        return items.filter { matches(language: FeedLanguageDetector.language(of: $0),
                                      app: app) }
            + items.filter { !matches(language: FeedLanguageDetector.language(of: $0),
                                      app: app) }
    }
}
