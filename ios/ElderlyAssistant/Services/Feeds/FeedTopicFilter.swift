import Foundation

// MARK: - Topic matching (feed-agent task, 2026-09-08)

/// Case- and diacritic-insensitive topic-keyword match against an item's
/// title + summary, safe for Devanagari.
///
/// Matching is SUBSTRING matching on `String` — every operation here
/// (`folding`, `range(of:)`) is grapheme-cluster (Character) based,
/// never scalar/UTF-16 surgery. Two consequences, both pinned by tests:
///
/// 1. Devanagari clusters match exactly as they read: the topic "का"
///    (क + ा) matches "नेपालका समाचार", and the conjunct ष्ट्र never
///    confuses राष्ट्र with रास्ट्र — the grapheme-cluster lesson.
/// 2. Diacritic folding targets Latin marks ("CAFÉ" ↔ "cafe"). Verified
///    empirically (2026-09-08): `folding(.diacriticInsensitive)` passes
///    Devanagari through byte-exact — matras and chandrabindu are not
///    combining diacritics in the folding tables.
///
/// Semantics: a topic matches when it appears ANYWHERE in the folded
/// text ("cat" matches "catalogue") — substring search, documented and
/// pinned, chosen over word-boundary search because Nepali has no
/// reliable word boundaries for tokenization.
///
/// An EMPTY topic list matches everything (no filtering) — the settings
/// hint states this so an empty topic list is the user's explicit
/// "show me everything".
enum FeedTopicFilter {

    /// True when the item passes the configured topics: any topic's
    /// folded form is a substring of the folded title+summary.
    static func matches(_ item: FeedItem, topics: [String]) -> Bool {
        let trimmed = topics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return true }

        let haystack = folded("\(item.title) \(item.summary)")
        return trimmed.contains { topic in
            haystack.range(of: folded(topic)) != nil
        }
    }

    /// Case- and diacritic-insensitive, Character-safe fold. Locale
    /// pinned to `en_US_POSIX` so folding is deterministic on every
    /// device (folding is locale-independent in practice, but pinning
    /// removes the last variance source).
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
