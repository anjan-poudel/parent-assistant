import Foundation

// MARK: - Reader display text (news-feed-images task, 2026-10-14)

/// The tap-through article reader's DISPLAY text assembly — the visual
/// sibling of `FeedSpeechSanitizer`'s speech paths, keeping the same
/// editing rules (markup and URL tokens are removed; nothing is ever
/// invented) and differing only in LAYOUT: the speech path collapses
/// every block boundary to a space so the voice reads one flowing run,
/// while the display path turns each block into its own paragraph — the
/// structure is the reader's whole point.
///
/// Pure String work (grapheme-safe, no scalar surgery), so Devanagari
/// passes through untouched. The reader and the voice button on it stay
/// in agreement about the WORDS: both take the source's body when it
/// published one beyond the summary (`FeedSpeechSanitizer.
/// hasFullArticle`), and both fall back to the published summary
/// otherwise — the reader shows it as a single paragraph, the voice
/// reads it as the full-article path's own fallback.
enum FeedArticleText {

    /// The reader body: one trimmed, stripped string per paragraph.
    ///
    /// Article bodies are block-structured HTML ("<p>one</p><p>two</p>").
    /// Raw whitespace runs (source pretty-printing) are layout, not
    /// structure — HTML collapses them — so they collapse FIRST; after
    /// that the only line breaks in the text are the ones the block tags
    /// became (`replacingBlockTagsWithNewline`), and each resulting line
    /// is stripped of inline tags and URL tokens and whitespace-
    /// collapsed. Blank blocks never produce empty paragraphs.
    ///
    /// `summary` supplies the fallback body when the source published no
    /// distinct article text — exactly the fallback the full-article
    /// READING takes, so a summary-only item's reader shows, and its
    /// voice button reads, the same published words.
    static func bodyParagraphs(summary: String, fullText: String) -> [String] {
        guard FeedSpeechSanitizer.hasFullArticle(summary: summary,
                                                 fullText: fullText) else {
            let single = FeedSpeechSanitizer.stripped(summary)
            return single.isEmpty ? [] : [single]
        }
        return paragraphs(fromBody: fullText)
    }

    /// The paragraph split of an article body — see `bodyParagraphs` for
    /// the rules.
    static func paragraphs(fromBody html: String) -> [String] {
        let normalized = FeedSpeechSanitizer.collapseWhitespace(html)
        let marked = FeedSpeechSanitizer.replacingBlockTagsWithNewline(normalized)
        return marked
            .components(separatedBy: "\n")
            .map { piece in
                FeedSpeechSanitizer.collapseWhitespace(
                    FeedSpeechSanitizer.stripURLTokens(
                        FeedSpeechSanitizer.stripHTMLTags(piece)))
            }
            .filter { !$0.isEmpty }
    }
}
