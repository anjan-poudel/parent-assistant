import Foundation

// MARK: - TTS-friendly feed text (feed-agent task, 2026-09-08)

/// Turns feed title+summary into text the TTS engine reads naturally —
/// the house rule "every spoken output TTS-friendly" applied to the feed.
/// All of it is pure String/Character work (grapheme-safe, no scalar
/// surgery) so Devanagari passes through untouched.
///
/// What gets removed before speech:
/// - residual HTML tags (the parser already decodes entities/CDATA, but
///   summaries often embed markup),
/// - URL tokens (https://…, www.…) — a TTS reads them as gibberish,
/// - extra whitespace/newlines (collapsed to single spaces).
///
/// Truncation is a HARD CAP at `maxSpeechLength` Characters — a feed
/// summary is not a podcast. Nothing is added, so no meaning is
/// fabricated; the same sanitizer feeds the on-card display text.
///
/// The FULL-ARTICLE path (feeds readaloud task, 2026-09-19) is the same
/// pipeline over the item's stored body, with one addition: block-level
/// HTML tags become a space (never punctuation) before the shared strip,
/// so paragraphs that were separated by markup are not glued into one
/// word. Its cap is `maxArticleSpeechLength` — larger, still bounded.
enum FeedSpeechSanitizer {

    /// Spoken (and displayed) length cap, in Characters.
    static let maxSpeechLength = 500

    /// Full-article reading cap, in Characters (feeds readaloud task,
    /// 2026-09-19): deliberately longer than the card cap — this IS the
    /// article the elder asked for — and still bounded, so one item can
    /// never hold the speaker for an unbounded time. Nothing is cut
    /// mid-sentence by the cap alone (a body longer than this simply
    /// stops where the stored text stops, and the stored text is itself
    /// capped by `FeedRSSParser.maxFullTextLength`).
    static let maxArticleSpeechLength = 4000

    /// The composed read-aloud text for an item: "Title. Summary" with
    /// both sanitized, title-only or summary-only when the other side is
    /// empty, "" when both are. Capped at `maxSpeechLength`.
    static func speechText(title: String, summary: String) -> String {
        let cleanTitle = stripped(title)
        let cleanSummary = stripped(summary)
        let composed: String
        switch (cleanTitle.isEmpty, cleanSummary.isEmpty) {
        case (false, false): composed = "\(cleanTitle). \(cleanSummary)"
        case (true, false): composed = cleanSummary
        case (false, true): composed = cleanTitle
        case (true, true): return ""
        }
        return capped(composed, at: maxSpeechLength)
    }

    // MARK: - Full article (feeds readaloud task, 2026-09-19)

    /// True when the item carries article text the summary does not
    /// already say — the UI's full-article affordance and the reading
    /// path's "is there more?" gate. False for an item whose feed
    /// published only a summary (or a body identical to it): the card
    /// then shows `feeds.summaryOnly` instead of offering a longer read
    /// that does not exist.
    static func hasFullArticle(summary: String, fullText: String) -> Bool {
        let body = articleBody(fullText)
        guard !body.isEmpty else { return false }
        return body != stripped(summary)
    }

    /// The full-article reading text: "Title. Body", sanitized through
    /// the article path (block boundaries preserved as spaces, tags and
    /// URLs stripped, whitespace collapsed), capped at
    /// `maxArticleSpeechLength`.
    ///
    /// When the item has no distinct body this returns `speechText` —
    /// the summary, i.e. what the source actually published. The option
    /// therefore always reads something real; the UI says which of the
    /// two it got.
    static func articleSpeechText(title: String, summary: String,
                                  fullText: String) -> String {
        guard hasFullArticle(summary: summary, fullText: fullText) else {
            return speechText(title: title, summary: summary)
        }
        let cleanTitle = stripped(title)
        let body = articleBody(fullText)
        let composed = cleanTitle.isEmpty ? body : "\(cleanTitle). \(body)"
        return capped(composed, at: maxArticleSpeechLength)
    }

    /// Article bodies are block-structured HTML ("<p>one</p><p>two</p>").
    /// `stripHTMLTags` removes a tag WITHOUT leaving a boundary, which
    /// glues "…one" and "two…" into a single word for such a body. This
    /// pass gives every block-level tag a SPACE first — whitespace only,
    /// never invented punctuation (the house rule: nothing is added, so
    /// no meaning is fabricated) — and the shared strip then removes
    /// residual markup, URL tokens and whitespace runs.
    static func articleBody(_ html: String) -> String {
        stripped(replacingBlockTagsWithSpace(html))
    }

    /// Block-level (and line-break) tags → " ". Inline tags stay for the
    /// shared strip to remove without a boundary, exactly as before.
    /// `<br>` splits a sentence the source wrote as two lines; list items
    /// and paragraphs are the same case.
    private static let blockTagPattern =
        "(?i)<\\s*/?\\s*(p|div|li|ul|ol|br|h[1-6]|tr|td|th|blockquote|section|"
        + "article|figure|figcaption|table|pre)\\b[^>]*>"

    static func replacingBlockTagsWithSpace(_ html: String) -> String {
        html.replacingOccurrences(of: blockTagPattern, with: " ",
                                  options: .regularExpression)
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// Plain display/speech text: strips HTML tags, URL tokens, and
    /// collapses whitespace.
    static func stripped(_ text: String) -> String {
        collapseWhitespace(stripURLTokens(stripHTMLTags(text)))
    }

    // MARK: - Passes (pure, individually pinned by tests)

    /// Removes `<...>` runs that look like tags (opened by a letter, "/",
    /// "!" or "?") — so real markup goes, while honest prose like
    /// "2 < 3" (no ">") or "a > b" (no "<") survives untouched.
    static func stripHTMLTags(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<",
               let close = text[index...].firstIndex(of: ">") {
                let content = text[text.index(after: index)..<close]
                let tagLike = content.first.map {
                    $0.isLetter || $0 == "/" || $0 == "!" || $0 == "?"
                } ?? false
                if tagLike {
                    index = text.index(after: close)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    /// Drops whitespace-separated tokens that are URLs (http://, https://,
    /// www.). A URL glued to punctuation is dropped with it — a read
    /// aloud never reads a URL aloud.
    static func stripURLTokens(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { token in
                let lower = token.lowercased()
                return !(lower.hasPrefix("http://")
                         || lower.hasPrefix("https://")
                         || lower.hasPrefix("www."))
            }
            .joined(separator: " ")
    }

    /// Collapses any whitespace/newline run to a single space (TTS pause
    /// hint) and trims the ends.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
