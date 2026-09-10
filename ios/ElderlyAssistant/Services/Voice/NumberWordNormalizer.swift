import Foundation

/// [NUMBER-WORDS] (2026-09-10) Spoken number-WORD → digit rewriter for the
/// voice alarm/timer stage. The duration grammar (`countdownSeconds` /
/// `amountImmediatelyBefore`) reads DIGITS only, so "पाँच मिनेट" / "five
/// minutes" never parsed — the user report this task fixes ("पांच मिनुटको
/// अलार्म लगाऊ" → "I don't understand").
///
/// Design (per the number-words architecture review):
///  - LANGUAGE DATA, NOT CODE: the word tables live in
///    `Resources/NumberWords/<language-code>.json` (one flat map of
///    word + spelling variants → integer per locale; `NumberWordLexicon`
///    below). Adding a language or a spelling variant = editing/dropping
///    a JSON file — no parser changes. The bundled folder lands in the
///    app bundle as `NumberWords/` (blue folder reference in project.yml,
///    same rationale as `Manuals/`).
///  - ONE generic pass: `NumberWordNormalizer.normalise(_:locale:)` runs
///    on the already-`NepaliTimeParser.normalise`d text, UPSTREAM of the
///    existing duration grammar, so every downstream rule (units,
///    amounts, compounds, snooze minutes, alarm clock times) works
///    untouched. Word-digit mixes fall out of the same pass ("१ घण्टा
///    पाँच मिनेट" → "1 घण्टा 5 मिनेट").
///  - CONTEXT-GUARDED rewrite: a lexicon word is replaced ONLY when the
///    next token begins with a duration-unit or clock word — the word
///    must NAME an amount. This shields homographs: ne "छ" is also the
///    copula ("अलार्म छ?" = "is there an alarm?" must never become
///    "alarm 6?"), and "एक" inside "एकछिन"/"एकदम" is a different token
///    anyway. A word following another lexicon word or an English tens
///    word is also skipped, so multi-word numbers are never partially
///    rewritten ("forty five minutes" must not become "forty 5
///    minutes" → a false 300 s).
///  - Emits ASCII digits (not Devanagari): `amountImmediatelyBefore` and
///    `firstInteger` round-trip through `Int(String)`, which parses
///    ASCII digits only.
///
/// Honest limits (kept out of the lexicons on purpose — such utterances
/// fall through to the interpreter exactly as before):
///  - numbers above the table (बीस/तीस/पन्ध्र/पैंतालीस are in; पचास,
///    compound tens like एक्काइस/अठ्ठाइस, and hundreds are out),
///  - multi-token English compounds ("forty five", "forty-five" — the
///    hyphen splits it into two tokens on the punctuation boundary),
///  - "एक घण्टा" = 60 minutes is COMPOSED by the existing unit grammar
///    (एक → 1 + the घण्टा unit) — no lexicon entry needed.

// MARK: - Bundled per-locale number-word lexicons

/// The bundled per-locale number-word map (`Resources/NumberWords/*.json`):
/// `{ "formatVersion": 1, "locale": "ne", "words": { "पाँच": 5, … } }`.
/// Content, not code — the same shape as `DialectLexicon`. Missing or
/// corrupt lexicons degrade to the identity transform (the interpreter
/// sees the utterance, as today); they must never crash a parse.
struct NumberWordLexicon: Decodable, Sendable {
    let formatVersion: Int
    let locale: String
    /// Word + attested spelling variants → integer value.
    let words: [String: Int]

    /// Bundle subdirectory the per-locale JSONs live in.
    static let subdirectory = "NumberWords"

    /// Loads the lexicon for a language code ("ne", "en") from the given
    /// bundle. Nil when the resource is absent; throws when it exists but
    /// cannot decode.
    static func bundled(languageCode: String,
                        in bundle: Bundle = .main) throws -> NumberWordLexicon? {
        guard let url = bundle.url(forResource: languageCode,
                                   withExtension: "json",
                                   subdirectory: subdirectory) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NumberWordLexicon.self, from: data)
    }

    /// Process-wide cache keyed by language code. Missing/corrupt caches
    /// as nil — the normalizer then degrades to the identity transform.
    private static let cacheLock = NSLock()
    private static var cache: [String: NumberWordLexicon?] = [:]

    static func cached(languageCode: String) -> NumberWordLexicon? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[languageCode] { return hit }
        let loaded = try? bundled(languageCode: languageCode)
        cache[languageCode] = loaded
        return loaded
    }
}

// MARK: - The normalizer

enum NumberWordNormalizer {

    /// Rewrites spoken number words to ASCII digits where they name an
    /// amount (see the file header for the guard rules). Runs on text
    /// that `NepaliTimeParser.normalise` has already lowercased and
    /// digit-normalized, so lexicon lookups are case-stable and the
    /// emitted digits stay the one canonical script the grammar parses.
    /// The identity transform when the locale has no bundled lexicon.
    static func normalise(_ text: String, locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier,
              let lexicon = NumberWordLexicon.cached(languageCode: code),
              !lexicon.words.isEmpty else { return text }

        let tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard tokens.count > 1 else { return text }   // no unit can follow

        var rewritten: [String] = []
        rewritten.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let core = Self.core(token)
            var replaced = false
            if let value = lexicon.words[core] {
                let next = index + 1 < tokens.count ? Self.core(tokens[index + 1]) : nil
                let previous = index > 0 ? Self.core(tokens[index - 1]) : nil
                let amountContext = next.map { Self.followsNumberWord($0) } ?? false
                let partOfLargerNumber = previous.map {
                    Self.englishTensWords.contains($0) || lexicon.words[$0] != nil
                } ?? false
                if amountContext && !partOfLargerNumber {
                    rewritten.append(String(value))
                    replaced = true
                }
            }
            if !replaced { rewritten.append(token) }
        }
        return rewritten.joined(separator: " ")
    }

    /// A token minus leading/trailing punctuation ("पाँच," → "पाँच") so
    /// ASR punctuation never hides a lexicon word.
    private static func core(_ token: String) -> String {
        var trimmed = token
        while let first = trimmed.first, first.isPunctuation {
            trimmed.removeFirst()
        }
        while let last = trimmed.last, last.isPunctuation {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// The next-token license list: a number word names an amount only
    /// when one of these follows. Nepali entries match by PREFIX — the
    /// को/का/मा/सम्म postpositions glue onto the noun ("मिनेटको",
    /// "मिनेटमा", "बजेसम्म"). English entries match EXACTLY, so "am" can
    /// never fire inside "amazing" and "min" can never fire inside
    /// "mink".
    private static let neUnitPrefixes = [
        "बजे", "घण्टा", "घन्टा", "मिनेट", "मिनुट", "मिनिट", "सेकेण्ड", "सेकेन्ड"
    ]
    private static let enUnitWords = [
        "minute", "minutes", "hour", "hours", "second", "seconds",
        "min", "mins", "sec", "secs", "am", "pm"
    ]

    private static func followsNumberWord(_ next: String) -> Bool {
        if neUnitPrefixes.contains(where: { next.hasPrefix($0) }) { return true }
        return enUnitWords.contains(next)
    }

    /// English tens words that prefix multi-word numbers ("forty five")
    /// — a lexicon word after one of these is part of the SAME number
    /// and must not be rewritten alone.
    private static let englishTensWords = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"
    ]
}
