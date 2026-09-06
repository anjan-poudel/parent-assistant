import Foundation

/// [NO-GIBBERISH] (2026-09-07) Sanity gate for model-generated text that
/// is about to be SPOKEN ALOUD (or shown as the visible reply).
///
/// Invariant: the assistant must NEVER speak garbage. The on-device 1B
/// model is untrustworthy — even grammar-constrained, its JSON `response`
/// field can hold an echo of the prompt, leftover JSON structure, decoder
/// repetition loops, or symbol/digit soup. Every model-text speech site in
/// `CommandRouter` runs the text through `rejectionReason` first; a
/// rejection routes to an honest pre-written fallback (accompanied by a
/// `llama_response_rejected_sanity` observability event carrying the
/// reason code) — the raw text never reaches the speaker or the visible
/// card.
///
/// Deliberately conservative: a false rejection costs one honest
/// re-prompt; a false acceptance costs the invariant. Note on the
/// language check: Devanagari is full of combining marks (matras/virama —
/// roughly a third of the glyphs in a typical Nepali sentence), so
/// "letter-ish" below counts alphabetic scalars AND combining marks, and
/// the check demands a strict majority of letter-ish content over all
/// non-whitespace content. Pure-digit answers ("९:३०", "2026") fail the
/// language check on purpose — the deterministic time/date pre-answers in
/// `TopicPreAnswer` exist precisely so the model never needs to produce a
/// bare-number reply.
enum ReplySanityGate {

    /// Machine-readable rejection reason — travels as the observability
    /// event's `errorCode`.
    enum Reason: String, Equatable {
        /// Empty (or whitespace-only) after trimming.
        case empty
        /// ASCII control characters (C0/C1) anywhere in the text.
        case controlCharacters
        /// Structure remnants: quotes, braces, brackets, backslash — plus
        /// the whole-token placeholder answers "null"/"nil"/"none".
        case jsonRemnant
        /// Obvious repetition: the same token more than 3 times, or one
        /// character repeated more than 8 times in a row (decoder loop
        /// signature).
        case repetition
        /// Not language-shaped: no letter-ish majority over non-whitespace
        /// content (symbol/digit/emoji soup).
        case nonLanguage
    }

    /// Returns the reason the text must NOT be delivered, or nil when the
    /// text is safe to speak. Pure and total.
    static func rejectionReason(_ text: String) -> Reason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // A model that "answered" with a placeholder instead of a reply.
        let lower = trimmed.lowercased()
        if lower == "null" || lower == "nil" || lower == "none" {
            return .jsonRemnant
        }

        // Control characters (C0 + C1) — never speakable.
        if trimmed.unicodeScalars.contains(where: {
            let v = Int($0.value)
            return v < 0x20 || (0x7F...0x9F).contains(v)
        }) {
            return .controlCharacters
        }

        // Structural remnants: ASCII quotes/braces/brackets/backslash
        // belong to JSON syntax, not to spoken language (apostrophes and
        // Unicode curly quotes are fine). The grammar constrains the
        // answer to a JSON string, so these characters cannot appear
        // legitimately — their presence means the model leaked structure
        // or echoed its prompt.
        let structural: Set<Character> = ["\"", "{", "}", "[", "]", "\\"]
        if trimmed.contains(where: { structural.contains($0) }) {
            return .jsonRemnant
        }

        // Repetition loops — the classic small-model decode failure.
        let tokens = trimmed.split { $0.isWhitespace || $0.isPunctuation }
        var counts: [Substring: Int] = [:]
        for t in tokens { counts[t, default: 0] += 1 }
        if counts.values.contains(where: { $0 > 3 }) { return .repetition }
        if longestConsecutiveRun(in: trimmed) > 8 { return .repetition }

        // Unspaced syllable/word loops — one whitespace-free block
        // repeated verbatim 4+ times with no separators ("हाहाहाहाहा",
        // "नमस्तेनमस्तेनमस्तेनमस्ते"). The token rule above cannot see
        // these (they are a single token) and the run rule cannot either
        // (Devanagari loops alternate consonant/matra scalars, so no
        // identical-scalar run forms). Deliberately whole-string only:
        // reduplication inside a real sentence ("बिस्तारै बिस्तारै") is
        // spaced and fine; a legit sentence that is EXACTLY one
        // whitespace-free block repeated 4+ times does not exist.
        let compactScalars = Array(trimmed.unicodeScalars.filter { !$0.properties.isWhitespace })
        if compactScalars.count >= 8 {
            let maxUnitLength = min(compactScalars.count / 4, 8)
            for unitLength in 1...maxUnitLength where compactScalars.count % unitLength == 0 {
                let unit = compactScalars[0..<unitLength]
                var idx = unitLength
                var isLoop = true
                while idx < compactScalars.count {
                    if compactScalars[idx..<(idx + unitLength)] != unit {
                        isLoop = false
                        break
                    }
                    idx += unitLength
                }
                if isLoop && compactScalars.count / unitLength >= 4 {
                    return .repetition
                }
            }
        }

        // Language check: strict letter-ish majority over all
        // non-whitespace scalars.
        var letterish = 0
        var meaningful = 0
        for scalar in trimmed.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            meaningful += 1
            if scalar.properties.isAlphabetic
                || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark {
                letterish += 1
            }
        }
        guard meaningful > 0, letterish * 2 > meaningful else {
            return .nonLanguage
        }
        return nil
    }

    /// Longest run of one identical scalar (any character class).
    private static func longestConsecutiveRun(in text: String) -> Int {
        var best = 0
        var current = 0
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == previous {
                current += 1
            } else {
                current = 1
            }
            if current > best { best = current }
            previous = scalar
        }
        return best
    }
}
