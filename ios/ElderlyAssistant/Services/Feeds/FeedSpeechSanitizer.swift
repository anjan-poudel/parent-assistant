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
enum FeedSpeechSanitizer {

    /// Spoken (and displayed) length cap, in Characters.
    static let maxSpeechLength = 500

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
        if composed.count > maxSpeechLength {
            return String(composed.prefix(maxSpeechLength))
        }
        return composed
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
