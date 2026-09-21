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
///
/// **The danda and the exclamation marks always end a piece. The period does
/// not** (review finding 9). It is the one terminator with other jobs, and a
/// crop is exactly where those jobs show up: `8.30 बजे` is a time, `Dr. Sharma`
/// is a name, `Rs. 250` is a price, and a fallback that broke after every dot
/// handed the tiers "8." and "30" as two strings — ids, cache keys and region
/// multiplicities all built on the halves of a number. The rules for a period
/// are the three shapes a crop carries (a decimal, an in-word or abbreviated
/// dot, a repeated mark), stated in `endsSentence(after:at:in:)`; everything
/// else the period does is a sentence end, including after a number ("it was
/// 2024. Then…"). Nothing here consults a locale or a model: the marks are the
/// input's, the rules are the same on every OS, and the sequence still rejoins
/// to the input.
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

    /// The tokens whose own trailing period is part of the token, not the end
    /// of a sentence — matched against the letters before the dot, lowercased,
    /// with the dots inside the token removed (so "Dr." reads as `dr` and
    /// "e.g." as `eg`; see `tokenBefore(_:in:)`).
    ///
    /// The list is short and deliberately so: each entry is a token that is
    /// **never** a sentence's last word on its own, because suppressing a real
    /// break joins two sentences and that is the failure this fallback exists
    /// to fix. It is sized for the domain the focus capture reads — letters,
    /// labels, prescriptions and signs — which is where "Dr. Sharma",
    /// "Rs. 250", "etc." and "approx." actually appear.
    static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "vs", "etc", "eg", "ie",
        "rs", "approx", "fig", "dept", "govt", "ltd", "pvt",
    ]

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

    /// The deterministic fallback: break **after** each terminator that ends a
    /// sentence, keep the terminator on the piece it ended, and drop only
    /// whitespace. No model, no locale, no state — the same input produces the
    /// same pieces on every OS and every run, which is what a device capture
    /// needs to be comparable to the next one.
    static func deterministicSentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            if terminators.contains(character), endsSentence(after: character, at: index, in: text) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { sentences.append(piece) }
                current = ""
            }
            index = text.index(after: index)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Whether the terminator just consumed ends a sentence.
    ///
    /// Everything but the period always does: the danda and the double danda
    /// are written for nothing else, and `!`/`?` are sentence-final in every
    /// script this feature reads. The period is the one mark with other jobs,
    /// and these are the four shapes a crop carries that are **not** a
    /// boundary (review finding 9):
    ///
    ///  - **a decimal point** — a digit on the far side and a digit (or
    ///    nothing, as in "`.5 mg`") on the near one: "8.30", "1.5 mg";
    ///  - **a dot inside a token** — a letter immediately on both sides, which
    ///    is how an acronym or a closed-up initial is written: "e.g.",
    ///    "U.S.A.", "J.Sharma";
    ///  - **an abbreviation's own dot** — the token before it is in
    ///    `abbreviations`: "Dr.", "Rs. 250";
    ///  - **a repeated mark** — an ellipsis or a doubled dot is one
    ///    terminator, not a sentence each: "wait…", "hmm.."
    ///
    /// A single letter before the dot is treated as an initial ("J. Sharma")
    /// and does not break: on the letters and forms this path reads, an
    /// initial is far more common than a one-letter word ending a sentence,
    /// and joining two sentences is the lesser failure — the joined piece is
    /// still translated, while a split initial is a name cut in half.
    ///
    /// Everything else is a boundary, **including a period after a number**
    /// ("it was 2024. Then we left"): a rule that refused every digit-adjacent
    /// period would join those two sentences, and the fallback exists to take
    /// them apart.
    private static func endsSentence(after mark: Character,
                                     at index: String.Index,
                                     in text: String) -> Bool {
        guard mark == "." else { return true }
        let next = text.index(after: index)
        let nextCharacter = next < text.endIndex ? text[next] : nil

        // A decimal point: a digit across it, and a digit or the string's own
        // start before it.
        if let nextCharacter, nextCharacter.isNumber,
           index == text.startIndex || text[text.index(before: index)].isNumber {
            return false
        }
        // A dot inside a token, an abbreviation's dot, or an initial's.
        if let nextCharacter, nextCharacter.isLetter,
           index > text.startIndex, text[text.index(before: index)].isLetter {
            return false
        }
        let token = tokenBefore(index, in: text)
        if abbreviations.contains(token) || token.count == 1 { return false }
        // An ellipsis, or any repeated dot: one terminator.
        if nextCharacter == "." { return false }
        if index > text.startIndex, text[text.index(before: index)] == "." { return false }
        return true
    }

    /// The token immediately before `index`, lowercased, with the dots that sit
    /// **inside** it dropped — so "Dr." reads as `dr` and "e.g." as `eg`. A dot
    /// counts as part of the token only when it has a letter before it (the
    /// letter after it is the one this walk has just consumed), which is what
    /// makes "J.Sharma" one token while "…tea. A" is two.
    private static func tokenBefore(_ index: String.Index, in text: String) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let before = text.index(before: cursor)
            let character = text[before]
            if character.isLetter {
                letters.append(character)
                cursor = before
                continue
            }
            // An in-word dot — a letter on its far side, and the character
            // after it is the letter just consumed — is walked over and
            // dropped.
            guard character == ".", before > text.startIndex,
                  text[text.index(before: before)].isLetter else { break }
            cursor = before
        }
        return String(letters.reversed()).lowercased()
    }
}
