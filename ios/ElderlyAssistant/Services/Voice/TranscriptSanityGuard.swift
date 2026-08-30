import Foundation

/// Reject transcripts that look like Whisper hallucinations before we
/// route them to the LLM or the keyword matcher.
///
/// Whisper's known failure modes on noise / non-target-language input are
/// (a) short n-grams that repeat many times ("त्यो त्यो त्यो त्यो …"),
/// (b) very low character diversity (a single glyph spammed), and
/// (c) unbounded length far beyond what a ≤10 s utterance can produce.
///
/// The guard is pure — no I/O, no observability, no threading. Its caller
/// (`CommandRouter`) emits the `gibberish_rejected` event and speaks a
/// re-prompt on a `Rejected` result.
enum TranscriptSanityGuard {

    struct Config {
        /// Consecutive repeats of the same n-gram that count as a loop.
        /// 5 is the number cited in whisper.cpp's own issue tracker for
        /// the noise-induced repetition mode.
        let repetitionThreshold: Int
        /// N-gram sizes to scan for repetition. Loops in the wild are
        /// almost always 2- to 4-word runs.
        let repetitionNGramSizes: [Int]
        /// Minimum unique-character ratio for a transcript to pass the
        /// entropy check. 0.15 catches "षषषषषषष…" without failing a
        /// legitimate 3-word Nepali utterance.
        let minCharacterDiversity: Double
        /// Below this many characters we don't apply the entropy floor
        /// — one-word answers ("हो", "no") legitimately have low
        /// diversity.
        let entropyMinLength: Int
        /// Longer than this and something's wrong: a 10 s utterance can't
        /// legitimately produce this many characters even in Devanagari.
        let maxCharacters: Int

        static let `default` = Config(
            repetitionThreshold: 5,
            repetitionNGramSizes: [2, 3, 4],
            minCharacterDiversity: 0.15,
            entropyMinLength: 12,
            maxCharacters: 300
        )
    }

    enum Reason: String {
        case repetitionLoop = "repetition_loop"
        case lowEntropy = "low_entropy"
        case tooLong = "too_long"
    }

    enum Result: Equatable {
        case pass
        case reject(Reason)
    }

    /// Run the guard. Returns `.pass` for anything that looks like real
    /// speech; `.reject` with a category otherwise. The empty-string
    /// short-circuit is deliberate — an empty transcript is already
    /// caught upstream by `WhisperSpeechRecognizer.empty_transcript`, so
    /// treating it as "pass" here keeps the guard's rejection surface
    /// tied to actual hallucinations.
    static func check(_ transcript: String,
                      config: Config = .default) -> Result {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .pass }

        if trimmed.count > config.maxCharacters {
            return .reject(.tooLong)
        }

        // Entropy runs before repetition so single-glyph spam is labeled
        // "low_entropy" (more informative) rather than "loop" — both
        // trigger rejection either way.
        if trimmed.count >= config.entropyMinLength
            && characterDiversity(trimmed) < config.minCharacterDiversity {
            return .reject(.lowEntropy)
        }

        if hasRepetitionLoop(trimmed,
                             ngramSizes: config.repetitionNGramSizes,
                             threshold: config.repetitionThreshold) {
            return .reject(.repetitionLoop)
        }

        return .pass
    }

    // MARK: - Repetition

    /// True when any n-gram (measured in whitespace-split tokens, or
    /// characters if the transcript has no whitespace — common for
    /// Devanagari hallucinations) repeats `threshold` times in a row.
    private static func hasRepetitionLoop(_ text: String,
                                          ngramSizes: [Int],
                                          threshold: Int) -> Bool {
        let tokens: [String]
        let whitespaceSplit = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if whitespaceSplit.count >= threshold {
            tokens = whitespaceSplit
        } else {
            tokens = text.map { String($0) }
        }
        guard !tokens.isEmpty else { return false }

        for n in ngramSizes where n >= 1 && tokens.count >= n * threshold {
            if consecutiveRepeat(tokens: tokens, ngram: n) >= threshold {
                return true
            }
        }
        return false
    }

    /// Longest run of consecutive equal n-grams anywhere in the sequence.
    private static func consecutiveRepeat(tokens: [String], ngram n: Int) -> Int {
        var best = 0
        var i = 0
        let last = tokens.count - n
        while i <= last {
            let base = tokens[i..<i + n]
            var runs = 1
            var j = i + n
            while j + n <= tokens.count && tokens[j..<j + n].elementsEqual(base) {
                runs += 1
                j += n
            }
            best = max(best, runs)
            i = (runs > 1) ? j : i + 1
        }
        return best
    }

    // MARK: - Entropy

    /// Ratio of distinct characters to total characters, ignoring
    /// whitespace. A "षषषषषषष" transcript scores ≈ 1 / N ≈ 0.05; a real
    /// Nepali sentence scores ≥ 0.4 in practice.
    private static func characterDiversity(_ text: String) -> Double {
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return 1.0 }
        let unique = Set(chars).count
        return Double(unique) / Double(chars.count)
    }
}
