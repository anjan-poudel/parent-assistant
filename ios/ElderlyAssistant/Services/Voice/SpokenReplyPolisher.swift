import Foundation

// [REPLY-POLISH] (2026-10-14, owner: "responses are mechanical and
// verbose and sometimes grammatically incorrect") The DETERMINISTIC
// spoken-reply polisher: every model-generated reply passes through it
// before it reaches the speaker, whichever model produced it.
//
// WHAT IT DOES — cleanup only, never rewriting:
//   - collapses whitespace runs and trims;
//   - collapses repeated terminal punctuation (।।→।, !!, ??, ..);
//   - strips per-sentence enumeration artifacts ("१.", "2)", "-", "•");
//   - de-duplicates adjacent repeated words ("हजुर हजुर" → "हजुर");
//   - enforces the brevity ceiling: at most two sentences, at most
//     `maxWords` words — the tail is cut at the sentence/word boundary,
//     no ellipsis, no filler.
//
// WHAT IT NEVER DOES — grammar rewriting. A verb-form table would be
// context-dependent ("काम भयो" ≠ "भन्नुभयो"), so grammar stays the
// models' job, hardened via prompts; this layer guarantees cleanliness
// and brevity for every model at once.
//
// Pure and total: every input produces a String; the empty result is
// the caller's signal to use its honest fallback.

enum SpokenReplyPolisher {

    /// The reply profile: confirmations stay tight, substantive answers
    /// (queries, chat, health, news) get room to actually answer. The
    /// owner's verbosity complaint is about mechanical confirmations,
    /// not about truncating a real answer mid-thought.
    enum Profile {
        case brief       // 2 sentences, 25 words
        case standard    // 4 sentences, 45 words

        var maxSentences: Int {
            switch self {
            case .brief: return 2
            case .standard: return 4
            }
        }

        var maxWords: Int {
            switch self {
            case .brief: return 25
            case .standard: return 45
            }
        }
    }

    static let maxSentences = 2
    static let maxWords = 30

    /// The full polish pipeline under a profile's brevity ceiling.
    static func polish(_ text: String, profile: Profile = .standard) -> String {
        var value = text
        value = collapseWhitespace(value)
        value = collapseRepeatedTerminalPunctuation(value)
        value = stripEnumerationArtifacts(value)
        value = dedupeAdjacentWords(value)
        value = enforceBrevity(value, profile: profile)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Stages

    /// Whitespace runs → one space, ends trimmed.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Terminal-punctuation runs collapse to one mark: "।।" → "।",
    /// "!!" → "!", "??" → "?", ".." → ".", and mixed danda/bang runs
    /// keep their last mark.
    static func collapseRepeatedTerminalPunctuation(_ text: String) -> String {
        let marks = Set("।!?.".unicodeScalars)
        var out = Array(text.unicodeScalars)
        var index = 0
        var write = 0
        while index < out.count {
            let scalar = out[index]
            if marks.contains(scalar) {
                var lastMark = scalar
                var cursor = index + 1
                while cursor < out.count, marks.contains(out[cursor]) {
                    lastMark = out[cursor]
                    cursor += 1
                }
                out[write] = lastMark
                write += 1
                index = cursor
            } else {
                out[write] = scalar
                write += 1
                index += 1
            }
        }
        out.removeSubrange(write...)
        return String(String.UnicodeScalarView(out))
    }

    /// Leading enumeration artifacts per sentence — "१.", "2)", "·",
    /// "-", "•" — are dropped. A real ordinal inside prose ("म २ वर्षको…")
    /// is not at the sentence head, so it survives.
    static func stripEnumerationArtifacts(_ text: String) -> String {
        let sentences = splitSentences(text)
        let cleaned = sentences.compactMap { sentence -> String? in
            let scalars = Array(sentence.unicodeScalars)
            // Skip the leading whitespace the split leaves behind, THEN
            // drop a leading Devanagari/ASCII digit + a following .)। mark.
            var start = 0
            while start < scalars.count, isSpace(scalars[start]) {
                start += 1
            }
            if start < scalars.count, isDigit(scalars[start]) {
                start += 1
                if start < scalars.count, isEnumerationMark(scalars[start]) {
                    start += 1
                } else {
                    start -= 1   // not an enumeration — restore
                }
            }
            if start < scalars.count, isBullet(scalars[start]) {
                start += 1
            }
            let rest = scalars[start...].map { Character(String($0)) }
            let result = String(rest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A sentence that was ONLY an enumeration marker leaves
            // nothing behind — drop it, never rejoin a stray space.
            return result.isEmpty ? nil : result
        }
        return sentences.isEmpty ? text : cleaned.joined(separator: " ")
    }

    /// Adjacent identical words collapse to one ("हजुर हजुर" →
    /// "हजुर"). Applies to any repeated word, which is the safe
    /// direction for spoken text: a stutter is never informative. The
    /// comparison ignores a TRAILING terminal mark, so "हजुर हजुर।"
    /// collapses too (the mark belongs to the sentence, not the word).
    static func dedupeAdjacentWords(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        func key(_ word: String) -> String {
            var scalars = Array(word.unicodeScalars)
            let marks = CharacterSet(charactersIn: "।!?.")
            while let last = scalars.last, marks.contains(last) {
                scalars.removeLast()
            }
            return String(String.UnicodeScalarView(scalars))
        }
        var out: [String] = []
        for word in words {
            if out.isEmpty || key(word) != key(out[out.count - 1]) {
                out.append(word)
            } else {
                // The duplicate is dropped, but the NEW occurrence wins
                // the slot: it carries the sentence's terminal mark
                // ("हजुर हजुर।" → "हजुर।", never a mark-less tail).
                out[out.count - 1] = word
            }
        }
        return out.joined(separator: " ")
    }

    /// The brevity ceiling: the first `profile.maxSentences` sentences,
    /// the last kept sentence capped at `profile.maxWords` words.
    static func enforceBrevity(_ text: String,
                               profile: Profile = .standard) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return text }
        var kept = sentences.prefix(profile.maxSentences).map { sentence in
            var words = sentence.split(separator: " ").map(String.init)
            if words.count > profile.maxWords {
                words = Array(words.prefix(profile.maxWords))
            }
            return words.joined(separator: " ")
        }
        if kept.isEmpty { kept = [""] }
        return kept.joined(separator: " ")
    }

    // MARK: - Sentence split (shared with the stages above)

    /// Splits on terminal punctuation marks, keeping each mark on its
    /// sentence. The final mark of the last sentence is retained so the
    /// TTS intonation lands naturally.
    static func splitSentences(_ text: String) -> [String] {
        let marks = CharacterSet(charactersIn: "।!?.")
        var sentences: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if marks.contains(scalar) {
                sentences.append(current)
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)          // 0-9
            || (0x0966...0x096F).contains(scalar.value)   // ०-९
    }

    private static func isEnumerationMark(_ scalar: Unicode.Scalar) -> Bool {
        Set(".।)".unicodeScalars).contains(scalar)
    }

    private static func isBullet(_ scalar: Unicode.Scalar) -> Bool {
        Set("-•·".unicodeScalars).contains(scalar)
    }
}
