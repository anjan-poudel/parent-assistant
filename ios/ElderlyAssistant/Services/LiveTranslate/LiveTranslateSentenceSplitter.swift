import Foundation
import NaturalLanguage

/// [FOCUS-CAPTURE] Splits one recognized block into sentence-sized pieces.
///
/// The focus capture reads **one** crop, and OCR hands back whatever the box
/// contained: a label, a sign, or a paragraph of medical directions. The
/// device tier is proven on short strings (`TranslationReliabilityRouter`'s
/// `provenShortForm` class is ≤ 4 words / ≤ 40 characters) and the round-4
/// verdict sharpened that: the shipped prompt's gate is measured per string,
/// and a multi-sentence paragraph handed over whole is a string neither tier
/// is being measured on. Splitting the crop into sentences is what lets each
/// piece be planned, batched and answered on the class it actually belongs to.
///
/// **Where this lives is part of the contract.** The splitter is a *caller*
/// utility: `LiveTranslateFocusCapture` runs it, and the tiers never see it.
/// A tier that split its inputs would be changing the strings a caller asked
/// about — the ids, the cache keys and the region multiplicities all key on
/// the text — and `LocalBrainTranslationTier.batchPrefixLength`'s whole
/// contract is that it bounds *the strings it was handed*. Splitting behind a
/// caller's back would bound a batch the caller never asked for.
///
/// **Why not `NepaliTextNormalizer`.** That type's job is to make two spellings
/// of the same string compare equal, and to do it it **strips the danda** —
/// the very character that marks a Nepali sentence boundary. Splitting on a
/// punctuation mark a normaliser has already removed is a no-op, so this type
/// reads the **raw** recognized text and keeps every mark it splits on.
///
/// The split is two-stage, in this order:
///
///  1. **Foundation's sentence tokenizer** (`NLTokenizer(unit: .sentence)`),
///     which is right about English and about the Latin scripts the feature
///     reads, and is the platform's own model rather than a second rule set.
///  2. **A deterministic Devanagari fallback**, applied only when the
///     tokenizer returns a single sentence that is longer than the threshold —
///     the shape a Nepali paragraph takes, because Foundation's sentence model
///     does not treat `।` (danda) and `॥` (double danda) as terminators on
///     every OS the app ships on. The fallback is deliberately dumb and
///     order-preserving: it breaks **after** each terminator, so the marks stay
///     on the piece they ended and the sequence rejoins to the input.
///
/// The fallback is not a second opinion applied unconditionally: a string the
/// tokenizer already split correctly is left alone, and a short Nepali string
/// is left alone even when it carries a danda (a one-sentence crop is a
/// one-sentence crop). Only the ambiguous case — one sentence, over the
/// threshold — is re-examined.
enum LiveTranslateSentenceSplitter {

    /// The length, in characters, above which a *single* tokenizer sentence is
    /// treated as a failed split rather than a long sentence.
    ///
    /// Sized against both bounds the tiers apply to a string: the reliability
    /// router's `maxProvenCharacters` is 40, and `SceneTextSanitiser`'s
    /// per-string bound (`sceneTextMaxLength`) is 120. The threshold sits above
    /// the router's class boundary — so it never re-splits a piece the device
    /// is *proven* on — and below the sanitiser's bound, which is the point at
    /// which a "sentence" this long is being truncated rather than read.
    ///
    /// A *default*, not a constant the call site may not move: the parameter
    /// exists so a caller with its own bound (a config value) passes it, and
    /// nothing here reads a second source of truth.
    static let fallbackThresholdCharacters = 80

    /// The terminators the deterministic fallback breaks after.
    ///
    /// `।` (U+0964 DEVANAGARI DANDA) and `॥` (U+0965 DEVANAGARI DOUBLE DANDA)
    /// are the two that make this type necessary; `.`, `!` and `?` are included
    /// because the fallback runs on mixed text (a Nepali sentence carrying an
    /// English abbreviation, a sign that ends a line in both scripts) and
    /// breaking on only half the marks would leave the other half's sentences
    /// joined.
    static let terminators: Set<Character> = ["।", "॥", ".", "!", "?"]

    /// One recognized block as sentence-sized pieces, in the order they were
    /// read. Empty and whitespace-only input yields no pieces — an empty crop
    /// asks the tiers nothing.
    ///
    /// The pieces are **trimmed** but otherwise unmodified: no normalization,
    /// no case folding, no punctuation removal. What the caller sends is what
    /// the recogniser read, which is the property the cache keys and the
    /// evidence both rest on.
    static func sentences(in text: String,
                          minimumFallbackLength: Int = fallbackThresholdCharacters) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenized = tokenizedSentences(in: trimmed)
        // The ambiguous case, and the only one the fallback touches: the
        // tokenizer claims this is one sentence, and it is longer than a
        // sentence this feature is prepared to hand a tier whole.
        if tokenized.count <= 1, trimmed.count > minimumFallbackLength {
            let deterministic = deterministicSentences(in: trimmed)
            // A fallback that also finds nothing leaves the tokenizer's answer
            // — one honest long sentence — rather than an empty list: a crop
            // with text on it is never "nothing to translate".
            return deterministic.count > 1 ? deterministic : tokenized
        }
        return tokenized
    }

    /// Foundation's sentence tokenizer, over the raw text. Empty pieces are
    /// dropped: `NLTokenizer` emits a range for trailing whitespace, and a
    /// blank "sentence" is an id the tiers would be asked to translate.
    static func tokenizedSentences(in text: String) -> [String] {
        var tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            return true
        }
        return sentences
    }

    /// The deterministic fallback: break **after** each terminator, keep the
    /// terminator on the piece it ended, and drop only whitespace. No model, no
    /// locale, no state — the same input produces the same pieces on every OS
    /// and every run, which is what a device capture needs to be comparable to
    /// the next one.
    static func deterministicSentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            guard terminators.contains(character) else { continue }
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
