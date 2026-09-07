import Foundation

/// [INTENT-TOOLS] (2026-09-07) Deterministic spoken-arithmetic calculator,
/// consulted by `CommandRouter` in the pre-route layer — after the safety
/// net and topic pre-answers, before any interpreter — so arithmetic works
/// identically on BOTH voice stacks (Gemini cloud and on-device), with NO
/// model involvement and NO prompt growth. Default-on; deliberately no
/// Settings row (tool use is on "by default").
///
/// Firing contract (all must hold):
///  1. No veto markers: medication/reminder/clock vocabulary ("औषधि",
///     "रिमाइन्डर", "बजे", "मिनेट" …) and call-ish vocabulary ("फोन",
///     "call", …) — a reminder, a dose question, or a call utterance can
///     never be shadowed by a numeric answer (same convention as
///     `TopicPreAnswer`; the call list mirrors
///     `CommandRouter.sensitiveCallPhrases` — keep in sync).
///  2. A full arithmetic expression can be EXTRACTED: digits (Arabic AND
///     Devanagari ०-९), optional decimals, at least one binary operator
///     from + − × ÷ ^ % (symbol AND spoken-word forms), parentheses, or
///     the percent constructions ("१०० को ५० प्रतिशत", "10 percent of
///     200").
///  3. After normalization NOTHING alphabetic remains — any surviving
///     letter kills the parse. That is the injection rejection: the
///     grammar is provably arithmetic-only; there is no eval, no function
///     call, no lookup of any kind.
///
/// Non-firing is the safe default: "कति हुन्छ?" alone, phone numbers
/// (digits but no operator), reminder times ("बिहान ८ बजे"), dates, and
/// any sentence with words outside the small known vocabulary all fall
/// through to the interpreter exactly as before.
///
/// Honesty: division (or modulo) by zero produces the friendly localized
/// `calculator.error.divByZero` decision — never a crash and never a
/// fabricated number. Malformed input, overflow and NaN do NOT fire (the
/// utterance is routed on, as if no calculator existed).
///
/// Result speech: successful computations echo the operation with
/// operator WORDS ("५ जोड ३ बराबर ८ हुन्छ।") so a misheard operand is
/// audible to the user. The echo is only spoken for shapes whose word
/// stream cannot change meaning: no parentheses, no powers/modulo, no
/// unary minus, 2–4 operands ("(२ जोड ३) गुणा ४" must never be read back
/// as "२ जोड ३ गुणा ४" — the word stream would mean 14, not 20).
/// Everything else gets the answer-only form.
///
/// Word-form coverage: verbs जोड/थप/घटाउ/घटाऊ/गुणा/गुणन/भाग (+ English
/// plus/add/minus/subtract/times/multiply/divide/modulo) in infix,
/// verb-first ("जोड ५ र ७", "add 5 and 7"), and verb-last ("५ र ३
/// जोड्नुहोस्") positions; directional ("१० लाई २ ले भाग", "५ मा ३ जोड",
/// "१० बाट ३ घटाउ"); percent ("१०० को ५० प्रतिशत"); power ("२ को घात ३",
/// "2 to the power of 3"). "भाग" deliberately does NOT participate in the
/// verb-first/verb-last conjunction forms — "भाग २ र ३" reads "part 2
/// and 3" (a serial episode), not division.
///
/// Known limitations (deliberate — such utterances fall through to the
/// cloud interpreter, never to a wrong number): spelled-out number words
/// ("पाँच जोड तीन") and currency words between a number and a verb
/// ("५० रुपैयाँ जोड ३० रुपैयाँ"). The deterministic stage must not fake
/// natural-language judgement it does not have.
enum CalculatorTool {

    /// One successfully evaluated computation (operands are normalized
    /// ASCII decimals; locale digit rendering happens at speech time).
    /// Equatable so `Decision` (and tests asserting whole decisions) can
    /// compare values.
    struct Calculation: Equatable {
        let tokens: [Token]
        let result: Double
    }

    enum Decision: Equatable {
        case computed(Calculation)
        /// Division/modulo by zero — the utterance WAS arithmetic but has
        /// no honest numeric answer.
        case divisionByZero
    }

    /// Token produced by the tokenizer. Internal so the reply/echo rules
    /// can be pinned through `reply(for:locale:)`.
    enum Token: Equatable {
        case number(String)
        case op(Character)   // one of + - * / ^ %
        case paren(Character)
    }

    /// The ONLY characters an expression may contain. Anything else —
    /// letters, emoji, quotes — is rejected (injection rejection).
    private static let expressionChars: Set<Character> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        ".", "+", "-", "*", "/", "^", "%", "(", ")"
    ]

    private static let decimal = "(\\d+(?:\\.\\d+)?)"

    // MARK: - Public surface

    /// Returns the calculator decision for an utterance, or nil when the
    /// utterance is not (provably) spoken arithmetic — route it on.
    static func decide(_ raw: String) -> Decision? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Vetoes run BEFORE any parsing so a numeric-sounding reminder or
        // call utterance can never reach the arithmetic stage.
        guard !mentionsVetoVocabulary(text) else { return nil }

        // 1. Devanagari digits → ASCII ("५ जोड ३" → "5 जोड 3").
        var work = mapDevanagariDigits(text)
        // 2. Symbol cleanup (× → *, ÷ → /, minus-like dashes, "x" as
        //    multiplication ONLY between two digits — a bare "x" elsewhere
        //    stays a letter and kills the parse downstream).
        work = mapSymbols(work)
        // 3. Structured phrase forms. Every pattern below is anchored on
        //    digits, so a non-numeric sentence can never match.
        work = rewriteStructuredPhrases(work)
        // 4. Word-verb tokens → operators; drop the known filler/
        //    question-word vocabulary; any OTHER alphabetic text → nil.
        guard let cleaned = mapWordOperatorsAndStripFillers(work) else { return nil }
        // 5. Tokenize + parse (precedence) + evaluate.
        return evaluate(expression: cleaned)
    }

    /// The localized spoken reply for a successful computation. `locale`
    /// decides the digit script (Devanagari under Nepali) and the operator
    /// words.
    static func reply(for calculation: Calculation, locale: Locale) -> String {
        let resultText = formatResult(calculation.result, locale: locale)
        if let echo = spokenEcho(calculation.tokens, locale: locale) {
            return L10n.fmt("calculator.result", locale: locale, echo, resultText)
        }
        return L10n.fmt("calculator.result.general", locale: locale, resultText)
    }

    // MARK: - Veto vocabulary
    // (The call list mirrors CommandRouter.sensitiveCallPhrases and the
    // med/reminder list mirrors TopicPreAnswer.medicationOrReminderMarkers
    // — keep in sync with both; clock words are this tool's own, so a
    // "बिहान ८ बजे" style time can never be read as arithmetic.)

    private static let callVetoWords = [
        "call", "phone", "facetime", "messenger", "whatsapp",
        "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
    ]

    private static let vetoMarkers = [
        "औषधि", "औषधी", "दवाई", "दबाइ", "दवाइ",
        "medicine", "medication", "pill", "dose",
        "reminder", "remind", "alarm", "रिमाइन्डर", "रिमाइन्ड", "अलार्म",
        "बजे", "बज्यो", "बजेर", "मिनेट", "minute", "o'clock", "baje"
    ]

    private static func mentionsVetoVocabulary(_ text: String) -> Bool {
        callVetoWords.contains { text.contains($0) }
            || vetoMarkers.contains { text.contains($0) }
    }

    // MARK: - Normalization passes

    /// ०-९ → 0-9. Other scripts are left untouched (and will kill the
    /// parse downstream — only Devanagari + Arabic are promised).
    private static func mapDevanagariDigits(_ text: String) -> String {
        // ASCII targets ON PURPOSE — Devanagari ०-९ (U+0966–U+096F) map to
        // the equivalent ARABIC digit; the tokenizer and every regex below
        // are ASCII-only. (2026-09-07: the literal was briefly the
        // Devanagari digits themselves — a silent no-op that made every
        // Nepali-digit utterance fall through. The unit suite caught it.)
        let devanagari = Array("0123456789")
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x0966, scalar.value <= 0x096F {
                out.append(devanagari[Int(scalar.value - 0x0966)].unicodeScalars.first!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func mapSymbols(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "×", with: "*")
        s = s.replacingOccurrences(of: "÷", with: "/")
        s = s.replacingOccurrences(of: "−", with: "-")   // U+2212 minus sign
        s = s.replacingOccurrences(of: "–", with: "-")   // en dash
        s = s.replacingOccurrences(of: "—", with: "-")   // em dash
        s = s.replacingOccurrences(
            of: "(\\d)\\s*[xX]\\s*(\\d)",
            with: "$1*$2",
            options: .regularExpression)
        return s
    }

    /// Digit-anchored rewrites for the structured spoken forms whose word
    /// order differs from the symbol expression:
    ///  - directional: "१० लाई २ ले भाग गर" (a÷b), "५ लाई ३ ले गुणा" (a×b),
    ///    "५ मा ३ जोड" (a+b), "१० बाट ३ घटाउ" (a−b),
    ///  - percent: "१०० को ५० प्रतिशत" → 100×50/100,
    ///    "10 percent of 200" → 200×10/100,
    ///  - power: "२ को घात ३", "2 to the power of 3",
    ///  - verb-first: "गुणा गर्नुहोस् ५ र ७" → 5×7,
    ///  - verb-last: "५ र ३ जोड्नुहोस्" → 5+3 (भाग excluded — "भाग २ र ३"
    ///    reads "part/episode 2 and 3", see the type doc).
    private static func rewriteStructuredPhrases(_ input: String) -> String {
        var s = input

        // Directional "<a> लाई <b> ले भाग|गुणा" — politeness tails
        // ("गर", "गर्नुहोस्" …) are consumed by the trailing non-digit
        // class, which can never cross into another number.
        s = s.replacingOccurrences(
            of: decimal + "\\s*लाई\\s*" + decimal + "\\s*ले\\s*भाग(?:\\s*[^\\d\\s]*)*",
            with: "($1/$2)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: decimal + "\\s*लाई\\s*" + decimal + "\\s*ले\\s*गुणा(?:\\s*[^\\d\\s]*)*",
            with: "($1*$2)", options: .regularExpression)
        // "<a> मा <b> जोड|थप" = a+b and "<a> मा <b> घटाउ|घटाऊ" = a−b.
        s = s.replacingOccurrences(
            of: decimal + "\\s*मा\\s*" + decimal + "\\s*(?:जोड|थप)(?:\\s*[^\\d\\s]*)*",
            with: "($1+$2)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: decimal + "\\s*मा\\s*" + decimal + "\\s*(?:घटाउ|घटाऊ)(?:\\s*[^\\d\\s]*)*",
            with: "($1-$2)", options: .regularExpression)
        // "<a> बाट <b> घटाउ|घटाऊ" = a−b ("१० बाट ३ घटाउ" = 7).
        s = s.replacingOccurrences(
            of: decimal + "\\s*बाट\\s*" + decimal + "\\s*(?:घटाउ|घटाऊ)(?:\\s*[^\\d\\s]*)*",
            with: "($1-$2)", options: .regularExpression)
        // Percent-of, Nepali word order: "<base> को <pct> प्रतिशत".
        s = s.replacingOccurrences(
            of: decimal + "\\s*को\\s*" + decimal + "\\s*प्रतिशत",
            with: "(($1*$2)/100)", options: .regularExpression)
        // Percent-of, English order: "<pct> percent of <base>".
        s = s.replacingOccurrences(
            of: decimal + "\\s*percent\\s*of\\s*" + decimal,
            with: "(($2*$1)/100)", options: .regularExpression)
        // Power: "२ को घात ३", "2 to the power of 3".
        s = s.replacingOccurrences(
            of: decimal + "\\s*(?:को\\s*घात|to\\s+the\\s+power\\s+of)\\s*" + decimal,
            with: "($1^$2)", options: .regularExpression)
        // Verb-first with conjunction: "<verb>[ गर्नुहोस्] <a> र/and <b>"
        // = a op b, per family, so a "घटाउ" can never become "+".
        // English "add 5 and 7" rides the same pattern (no leading
        // operand exists for the infix form to anchor on).
        s = rewriteVerbFirst(s, verb: "(?:जोड|थप|plus|add)", op: "+")
        s = rewriteVerbFirst(s, verb: "(?:घटाउ|घटाऊ)", op: "-")
        s = rewriteVerbFirst(s, verb: "(?:गुणा|गुणन)", op: "*")
        // Verb-last with conjunction: "<a> र/and <b> <verb>[्नुहोस्…]"
        // = a op b ("५ र ३ जोड्नुहोस्" = 8, "१० र ४ घटाउनुहोस्" = 6).
        s = rewriteVerbLast(s, verb: "(?:जोड|थप)", suffix: "(?:्नुहोस्|्नु|ेर|े|ौँ)?", op: "+")
        s = rewriteVerbLast(s, verb: "(?:घटाउ|घटाऊ)", suffix: "(?:नुहोस्|नु|एर|ेर|े|ौँ)?", op: "-")
        s = rewriteVerbLast(s, verb: "(?:गुणा|गुणन)", suffix: "", op: "*")
        // English directed forms: "divide 5 by 2" (5÷2), "multiply 5 by
        // 2" (5×2), "subtract 3 from 10" (10−3 = 7).
        s = s.replacingOccurrences(
            of: "divide\\s*" + decimal + "\\s*by\\s*" + decimal,
            with: "($1/$2)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "multiply\\s*" + decimal + "\\s*by\\s*" + decimal,
            with: "($1*$2)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "subtract\\s*" + decimal + "\\s*from\\s*" + decimal,
            with: "($2-$1)", options: .regularExpression)
        // English past-participle forms carry a "by" the infix anchor can
        // never cross ("5 divided by 2" has the digit, verb AND "by" in
        // between) — directed rewrite before the infix loop.
        s = s.replacingOccurrences(
            of: decimal + "\\s*divided\\s*by\\s*" + decimal,
            with: "($1/$2)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: decimal + "\\s*multiplied\\s*by\\s*" + decimal,
            with: "($1*$2)", options: .regularExpression)
        // Infix word forms (both languages), repeated so chains such as
        // "५ जोड ३ जोड ७" collapse left to right.
        let infixPairs: [(verb: String, op: String)] = [
            ("(?:जोड|थप|जोड्नुहोस्|जोड्नु|जोडेर|थप्नुहोस्|plus|add)", "+"),
            ("(?:घटाउ|घटाऊ|घटाउनुहोस्|घटाउनु|घटाएर|minus|subtract)", "-"),
            ("(?:गुणा|गुणन|times|multiply|multiplied)", "*"),
            ("(?:भाग|divide|divided)", "/"),
            ("(?:मोडुलो|modulo|mod)", "%")
        ]
        for pair in infixPairs {
            var previous: String
            repeat {
                previous = s
                s = s.replacingOccurrences(
                    of: decimal + "\\s*" + pair.verb + "\\s*" + decimal,
                    with: "($1" + pair.op + "$2)",
                    options: .regularExpression)
            } while s != previous
        }
        return s
    }

    private static func rewriteVerbFirst(_ text: String, verb: String, op: String) -> String {
        text.replacingOccurrences(
            of: verb + "\\s*(?:गर|गर्नुहोस्|गर्नु|गरिदिनुहोस्|do|it)?\\s*"
                + decimal + "\\s*(?:र|अनि|and)?\\s*" + decimal,
            with: "($1" + op + "$2)",
            options: .regularExpression)
    }

    private static func rewriteVerbLast(_ text: String, verb: String, suffix: String, op: String) -> String {
        text.replacingOccurrences(
            of: decimal + "\\s*(?:र|अनि|and)?\\s*" + decimal + "\\s*"
                + verb + suffix + "(?:\\s*(?:गर|गर्नुहोस्|गरिदिनुहोस्))?",
            with: "($1" + op + "$2)",
            options: .regularExpression)
    }

    /// Whole-word operator vocabulary (mapped to symbols) and the
    /// filler/question vocabulary (dropped). Returns nil when any OTHER
    /// alphabetic text survives — that is the injection rejection.
    private static func mapWordOperatorsAndStripFillers(_ text: String) -> String? {
        // Full-word equality ONLY — never prefix matching, so "जोडी"
        // (spouse) or "भाग्य" (luck) can never map to an operator.
        let operatorWords: [String: String] = [
            "जोड": "+", "जोड्नुहोस्": "+", "जोड्नु": "+", "जोडेर": "+", "जोडौँ": "+",
            "थप": "+", "थप्नुहोस्": "+", "थपेर": "+",
            "घटाउ": "-", "घटाऊ": "-", "घटाउनुहोस्": "-", "घटाउनु": "-", "घटाएर": "-",
            "गुणा": "*", "गुणन": "*",
            "भाग": "/",
            "मोडुलो": "%", "modulo": "%", "mod": "%",
            "plus": "+", "add": "+", "added": "+",
            "minus": "-", "subtract": "-", "subtracted": "-",
            "times": "*", "multiply": "*", "multiplied": "*",
            "divide": "/", "divided": "/"
        ]
        // Tokens dropped entirely: question words, imperatives, politeness
        // particles, and the numeric-case markers (लाई/ले/मा/बाट/र) that
        // the phrase rewrites did not structurally consume.
        let fillerWords: Set<String> = [
            // Nepali
            "कति", "हुन्छ", "हुन्छन्", "हुने", "हुन्न", "होला", "होस्", "छ", "छौँ",
            "गर", "गरौँ", "गर्नुहोस्", "गर्नु", "गरेर", "गरिदिनुहोस्",
            "निकाल", "निकाल्नुहोस्", "निकाल्ने", "निकाल्छ", "निकालिदिनुहोस्",
            "देखाउ", "देखाउनुहोस्", "बताउ", "बताऊ", "बताउनुहोस्", "भन", "भन्नुहोस्",
            "गणना", "हिसाब", "बराबर", "बराबरी", "जवाफ", "उत्तर",
            "कृपया", "है", "पो", "नि", "त", "रे", "भने", "अब",
            "लाई", "ले", "मा", "बाट", "र", "अनि", "अनी",
            "के", "कस्तो", "कुन", "सबै", "दिनुहोस्", "देऊ", "देउ",
            "म", "मलाई", "मेरो", "हो", "छैन", "छैनौँ",
            // English
            "what", "whats", "what's", "is", "are", "was", "be", "the", "of",
            "would", "can", "could", "you", "your", "tell", "me", "how",
            "much", "many", "do", "does", "did", "it", "its", "make",
            "compute", "equals", "equal", "show", "let", "us", "need",
            "want", "give", "some", "my", "a", "an", "to", "for", "this",
            "that", "with", "and", "then", "also", "please", "out", "up",
            "i", "we", "hey", "calculate", "calculator", "result", "answer"
        ]

        var rebuilt: [String] = []
        for rawWord in text.components(separatedBy: .whitespacesAndNewlines) {
            guard !rawWord.isEmpty else { continue }
            let word = stripEdgeNoise(rawWord)
            guard !word.isEmpty else { continue }

            // A token may mix scripts when speech-to-text glues words
            // together ("जोड३", "5plus3"). Split it into homogeneous
            // letter runs and expression runs; EVERY part then goes
            // through the same exact-match tables, so a glued word can
            // never smuggle itself past the letter check.
            for part in homogeneousRuns(of: word) {
                guard !part.isEmpty else { continue }
                let isPureExpression = part.unicodeScalars.allSatisfy {
                    expressionChars.contains(Character($0))
                }
                if isPureExpression {
                    rebuilt.append(part)
                } else if let symbol = operatorWords[part] {
                    rebuilt.append(symbol)
                } else if fillerWords.contains(part) {
                    continue
                } else {
                    return nil   // unknown alphabetic content — not math
                }
            }
        }
        return rebuilt.isEmpty ? nil : rebuilt.joined(separator: " ")
    }

    /// Removes edge characters that can never carry math meaning (',',
    /// '?', '!', quotes, Devanagari danda "।" …) from a whitespace token.
    /// Expression characters — including '.', '-' and parentheses — are
    /// NEVER stripped, so "−५", "(5+3)" and "३?" survive correctly while
    /// "हुन्छ?" and "जोड," normalize.
    private static func stripEdgeNoise(_ token: String) -> String {
        var word = token
        while let last = word.last, isEdgeNoise(last) { word.removeLast() }
        while let first = word.first, isEdgeNoise(first) { word.removeFirst() }
        return word
    }

    private static func isEdgeNoise(_ character: Character) -> Bool {
        if character == "." { return true }   // sentence period at an edge
        guard let scalar = character.unicodeScalars.first else { return false }
        // Hyphen-minus and friends are "punctuation" in Unicode but ARE
        // expression characters here — never strip them.
        if expressionChars.contains(character) { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    /// Splits a token into maximal runs of letters vs. everything else.
    private static func homogeneousRuns(of token: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentIsLetter = false
        for character in token {
            let isLetter = character.unicodeScalars.contains {
                CharacterSet.letters.contains($0)
            }
            if current.isEmpty {
                currentIsLetter = isLetter
            } else if isLetter != currentIsLetter {
                runs.append(current)
                current = ""
                currentIsLetter = isLetter
            }
            current.append(character)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Grammar + evaluation

    private enum EvalFailure: Error {
        case divisionByZero   // honest answer: a division/modulo hit zero
        case malformed        // structural failure → simply do not fire
    }

    /// Tokenizes, parses (^ right-assoc binds tightest, then unary minus,
    /// then * / %, then + −), evaluates. Returns nil for anything not
    /// provably arithmetic; `.divisionByZero` only for an actual
    /// division/modulo by zero.
    private static func evaluate(expression text: String) -> Decision? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Unwrap a fully-wrapped parenthesized group: the phrase rewrites
        // wrap every word-form operation in parens ("५ जोड ३" →
        // "(5+3)"). The wrapping is semantically inert when the WHOLE
        // expression is one group, and unwrapping lets the natural spoken
        // echo ("५ जोड ३ बराबर ८ हुन्छ।") reach the user instead of the
        // answer-only form. Mixed shapes are left untouched: "(5+3)*(2)"
        // is not one group and keeps its parens (no unwrap changes a
        // value — only the fully-wrapped case is touched, repeatedly for
        // "((5+3))" nesting).
        while trimmed.hasPrefix("("), trimmed.hasSuffix(")"),
              isSingleTopLevelGroup(trimmed) {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var tokens: [Token] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let c = trimmed[index]
            if c.isWhitespace {
                index = trimmed.index(after: index)
                continue
            }
            if c == "(" {
                tokens.append(.paren("("))
                index = trimmed.index(after: index)
                continue
            }
            if c == ")" {
                tokens.append(.paren(")"))
                index = trimmed.index(after: index)
                continue
            }
            if "+-*/^%".contains(c) {
                tokens.append(.op(c))
                index = trimmed.index(after: index)
                continue
            }
            if c.isNumber || c == "." {
                var number = ""
                while index < trimmed.endIndex, trimmed[index].isNumber {
                    number.append(trimmed[index])
                    index = trimmed.index(after: index)
                }
                if index < trimmed.endIndex, trimmed[index] == "." {
                    let afterDot = trimmed.index(after: index)
                    if afterDot < trimmed.endIndex, trimmed[afterDot].isNumber {
                        number.append(".")
                        index = afterDot
                        while index < trimmed.endIndex, trimmed[index].isNumber {
                            number.append(trimmed[index])
                            index = trimmed.index(after: index)
                        }
                    } else {
                        return nil   // "5." — not an accepted number form
                    }
                }
                tokens.append(.number(number))
                continue
            }
            return nil   // unknown character — not provable math
        }

        // Fire only when a binary operator actually applies to ≥2 numbers.
        var ops = 0
        var numbers = 0
        for token in tokens {
            switch token {
            case .number: numbers += 1
            case .op: ops += 1
            case .paren: break
            }
        }
        guard ops >= 1, numbers >= 2 else { return nil }

        var position = 0
        do {
            let value = try parseExpression(tokens, &position)
            guard position == tokens.count else { return nil }
            guard value.isFinite, abs(value) < 1e15 else { return nil }
            return .computed(Calculation(tokens: tokens, result: value))
        } catch EvalFailure.divisionByZero {
            return .divisionByZero
        } catch {
            return nil   // any structural failure → do not fire
        }
    }

    /// True when `text` (which starts with "(" and ends with ")") is one
    /// single top-level group — the closing ")" at the end matches the
    /// opening "(" at the start, with nothing outside it.
    private static func isSingleTopLevelGroup(_ text: String) -> Bool {
        var depth = 0
        var index = text.index(after: text.startIndex)
        let lastIndex = text.index(before: text.endIndex)
        while index < lastIndex {
            if text[index] == "(" {
                depth += 1
            } else if text[index] == ")" {
                depth -= 1
                if depth < 0 { return false }   // unbalanced inside
            }
            index = text.index(after: index)
        }
        return depth == 0
    }

    /// expr := term (("+"|"-") term)*
    private static func parseExpression(_ tokens: [Token], _ position: inout Int) throws -> Double {
        var value = try parseTerm(tokens, &position)
        while position < tokens.count {
            if case .op(let op) = tokens[position], op == "+" || op == "-" {
                position += 1
                let rhs = try parseTerm(tokens, &position)
                value = op == "+" ? value + rhs : value - rhs
            } else {
                break
            }
        }
        return value
    }

    /// term := unaryPower (("*"|"/"|"%") unaryPower)*
    private static func parseTerm(_ tokens: [Token], _ position: inout Int) throws -> Double {
        var value = try parseUnaryPower(tokens, &position)
        while position < tokens.count {
            if case .op(let op) = tokens[position], op == "*" || op == "/" || op == "%" {
                position += 1
                let rhs = try parseUnaryPower(tokens, &position)
                switch op {
                case "*":
                    value = value * rhs
                case "/":
                    guard rhs != 0 else { throw EvalFailure.divisionByZero }
                    value = value / rhs
                default:   // "%"
                    guard rhs != 0 else { throw EvalFailure.divisionByZero }
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            } else {
                break
            }
        }
        return value
    }

    /// unaryPower := ("+"|"-") unaryPower | power
    ///
    /// The unary sign WRAPS the whole power, never its base: −2^2 must
    /// read −(2^2) = −4 (the school convention — exponent binds tighter
    /// than the sign), and (−2)^2 = 4 needs parentheses. An exponent may
    /// itself carry a sign ("2^-3") because a power's exponent is a
    /// unaryPower.
    private static func parseUnaryPower(_ tokens: [Token], _ position: inout Int) throws -> Double {
        if position < tokens.count {
            if case .op("+") = tokens[position] {
                position += 1
                return try parseUnaryPower(tokens, &position)
            }
            if case .op("-") = tokens[position] {
                position += 1
                return -(try parseUnaryPower(tokens, &position))
            }
        }
        return try parsePower(tokens, &position)
    }

    /// power := primary ("^" unaryPower)?   — right-associative:
    /// 2^3^2 = 2^(3^2) = 512.
    private static func parsePower(_ tokens: [Token], _ position: inout Int) throws -> Double {
        let base = try parsePrimary(tokens, &position)
        if position < tokens.count, case .op("^") = tokens[position] {
            position += 1
            let exponent = try parseUnaryPower(tokens, &position)
            return pow(base, exponent)
        }
        return base
    }

    private static func parsePrimary(_ tokens: [Token], _ position: inout Int) throws -> Double {
        guard position < tokens.count else { throw EvalFailure.malformed }
        switch tokens[position] {
        case .number(let literal):
            position += 1
            guard let value = Double(literal) else { throw EvalFailure.malformed }
            return value
        case .paren("("):
            position += 1
            let value = try parseExpression(tokens, &position)
            // Guard BEFORE indexing: an unmatched "(" ("(5+3") leaves
            // position AT tokens.count after the inner expression — a
            // direct subscript would trap (index out of range), and a
            // malformed utterance must fall through, never crash
            // (2026-09-07 — caught by the injection-rejection suite).
            guard position < tokens.count, case .paren(")") = tokens[position] else {
                throw EvalFailure.malformed   // unmatched "("
            }
            position += 1
            return value
        default:
            throw EvalFailure.malformed
        }
    }

    // MARK: - Spoken rendering

    /// Echoes the computation with operator WORDS ("५ जोड ३") when the
    /// shape is unambiguous for speech; nil otherwise → answer-only form.
    private static func spokenEcho(_ tokens: [Token], locale: Locale) -> String? {
        var numbers = 0
        var previousWasOperand = false
        var sawUnaryMinus = false
        var sawSpecialShape = false   // parens, ^, % — see the type doc
        for token in tokens {
            switch token {
            case .number:
                numbers += 1
                previousWasOperand = true
            case .paren:
                sawSpecialShape = true
            case .op(let op):
                if op == "^" || op == "%" { sawSpecialShape = true }
                if op == "-", !previousWasOperand { sawUnaryMinus = true }
                previousWasOperand = false
            }
        }
        guard !sawSpecialShape, !sawUnaryMinus, numbers >= 2, numbers <= 4 else {
            return nil
        }
        var parts: [String] = []
        for token in tokens {
            switch token {
            case .number(let literal):
                parts.append(renderDigits(literal, locale: locale))
            case .op(let op):
                parts.append(operatorWord(op, locale: locale))
            case .paren:
                break   // excluded above
            }
        }
        return parts.joined(separator: " ")
    }

    /// The localized spoken operator word for a symbol.
    static func operatorWord(_ op: Character, locale: Locale) -> String {
        let key: String
        switch op {
        case "+": key = "calculator.op.plus"
        case "-": key = "calculator.op.minus"
        case "*": key = "calculator.op.times"
        case "/": key = "calculator.op.dividedBy"
        case "^": key = "calculator.op.power"
        case "%": key = "calculator.op.modulo"
        default: key = "calculator.op.plus"
        }
        let word = L10n.str(key, locale: locale)
        return word == key ? String(op) : word
    }

    /// Result formatting: integers as whole numbers; decimals trimmed to
    /// ≤6 fractional places; digits rendered in the locale's script.
    private static func formatResult(_ value: Double, locale: Locale) -> String {
        let raw: String
        if value == value.rounded() {
            raw = String(Int64(value))
        } else {
            var text = String(format: "%.6f", value)
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
            raw = text
        }
        return renderDigits(raw, locale: locale)
    }

    /// ASCII digits → the locale's digit script (Devanagari under Nepali;
    /// any other locale keeps ASCII). Non-digit characters pass through.
    private static func renderDigits(_ value: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "ne" else { return value }
        let devanagari = Array("०१२३४५६७८९")
        return String(value.map { character in
            guard let ascii = character.wholeNumberValue, (0...9).contains(ascii) else {
                return character
            }
            return devanagari[ascii]
        })
    }
}
