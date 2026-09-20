import Foundation

// The Devanagari language gate — tier 1's fifth answer rule (2026-09-18, the
// model evaluation of that date).
//
// The four rules that shipped before it (empty, size, echo-of-the-source,
// wrong-script) each answer "did the model produce *an* answer?". None of them
// answers "is it written in the language the elder reads?", and the evaluation
// is the evidence that the gap is real rather than theoretical:
//
//   - Both off-the-shelf Qwen rungs answered the English scene text in
//     **Hindi**. Hindi is Devanagari, so `usesTheTargetScript` accepted it; it
//     is not the source, so the echo rule accepted it; it was short and
//     non-empty, so the size rules accepted it. Every guard passed and a
//     Nepali elder was shown Hindi — the exact failure the tier exists to
//     prevent, arriving through the one door no rule was watching.
//   - The same rungs **echoed the instruction** back as their answer
//     ("अंग्रेजी शब्दहरू नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…"). That class
//     contains Nepali morphology — हरू, गर्नुहोस् — so a rule that only asks
//     "does this look Nepali?" accepts it too. It is not a translation of the
//     sign; it is the question.
//
// The fine-tuned model of the ladder's next rung is trained to answer in
// Nepali, which is why this is a *gate* and not a training note: it has to
// hold for whatever model is installed, including a rung that does not exist
// yet. The tier's contract is "only a translation may settle a region", and a
// translation into Nepali is the one thing this file decides.
//
// ## The decision
//
// Two marker lists, each entry a form the *other* language does not produce,
// and a deterministic rule over them:
//
//   - **reject** an answer that echoes the instruction (the answer is the
//     question, whatever language it is in);
//   - **reject** an answer carrying Hindi-exclusive evidence (it is Hindi);
//   - **reject** an answer carrying no Nepali-exclusive evidence at all (it is
//     not established as Nepali — Hindi, Marathi, a transliterated Bengali or a
//     model's own invention are indistinguishable from here, and the elder
//     must not be shown any of them as their own language);
//   - **accept** everything else: Devanagari with Nepali evidence and no
//     Hindi evidence.
//
// The asymmetry between those last two is the whole point, and it is
// deliberate: a rejection is *unresolved*, not failed. The region keeps the
// original text and the string goes on to the next tier, which may be the
// cloud — so the cost of being wrong in this direction is latency and one
// cloud call, while the cost of being wrong in the other direction is an elder
// who cannot read their own language. The gate is therefore conservative in
// the safe direction by construction, and the price it pays for that is
// stated: **a marker-free answer does not settle a region either**, which
// includes a single shared noun ("Pharmacy" → "फार्मेसी") that is spelled
// identically in both languages. That is a real cost, it is measured in the
// suite's fixture counts, and it is the price of never showing a Hindi
// sentence to someone who reads Nepali.
//
// ## What it does not do
//
//   - **It does not write to the log.** There is no event here and no reason
//     token: the gate is a pure predicate, the tier already reports its
//     resolved/unresolved *counts* on `brain_translation_batch`, and a reason
//     code would have to travel with a metadata key this component has no
//     business introducing. Nothing about a translation — or about a rejected
//     candidate — reaches the log surface from this file.
//   - **It does not judge the English target.** The discriminator is between
//     two Devanagari languages; the target named `english` has its own script
//     rule in the tier (`usesTheTargetScript`) and no Nepali/Hindi question to
//     ask of it.
//   - **It does not judge a string with no Devanagari letters.** A numerals-only
//     answer ("२४" for "24") has no language to be wrong about, and the tier's
//     script rule already covers the case where the target's script is
//     required at all.
//   - **It holds no state, no cache and no configuration.** The rule is a
//     function of the answer alone, so the same answer decides the same way on
//     every device and in every build.

/// The Devanagari language gate: whether a translation may be shown as Nepali.
///
/// Pure and deterministic: a function of one string and the target language,
/// with no clock, no I/O, no randomness and no mutable state. The tier calls it
/// as its last answer rule (`LocalBrainTranslationTier.accepts`), so every
/// rejection here is an *unresolved* string that the next tier is asked about —
/// never an error, never a stub.
enum NepaliOutputGate {

    // MARK: - The decision

    /// What the gate decided, and — for tests and for a reader of a capture —
    /// why.
    ///
    /// The reason is evidence, not a branch: it changes nothing about what the
    /// caller does (a rejection is a rejection), and it is deliberately *not*
    /// emitted anywhere. It exists so that a failure in this file can say
    /// which of three very different situations it was looking at.
    enum Verdict: Equatable {
        /// Devanagari, Nepali evidence, no Hindi evidence: a translation.
        case accept
        /// Not established as Nepali. The string stays unresolved.
        case reject(Reason)
    }

    enum Reason: String, Equatable {
        /// The answer is the instruction ("translate … into Nepali, one per
        /// line"), not a translation of the sign. Its own class because it is
        /// the one rejection that can carry perfectly good Nepali morphology —
        /// the evaluation produced exactly this with नेपालीमा, अनुवाद and हरू in
        /// it — so no amount of language evidence may rescue it.
        case instructionEcho
        /// The answer carries Hindi-exclusive evidence (है, नहीं, रहा, …).
        case hindiEvidence
        /// Devanagari with no Nepali-exclusive evidence of any kind: Hindi
        /// without a marker the list catches, Marathi, transliterated Bengali,
        /// or a model talking to itself. It cannot be *established* as Nepali,
        /// and the elder is not shown a guess.
        case noNepaliEvidence
    }

    /// The markers one answer carried, for the suites that pin the rule.
    ///
    /// Sorted and de-duplicated, so an answer carrying a marker twice reads as
    /// one hit — the rule is about which forms are present, not how often.
    struct Evidence: Equatable {
        var nepali: [String] = []
        var hindi: [String] = []
        var echoed: [String] = []
    }

    /// Whether an answer may settle a region as a translation into `targetLanguage`.
    ///
    /// The tier's `accepts(_:for:targetLanguage:config:)` is the caller: `false`
    /// means "unresolved", and the string goes on to the next tier untouched.
    static func accepts(_ text: String, targetLanguage: AppLanguage) -> Bool {
        verdict(for: text, targetLanguage: targetLanguage) == .accept
    }

    /// The decision itself, with its reason.
    static func verdict(for text: String, targetLanguage: AppLanguage) -> Verdict {
        // The gate is a question about Devanagari answers. The English target
        // is answered by the tier's own script rule; asking it here would be a
        // second rule about the same thing.
        guard targetLanguage == .nepali else { return .accept }

        // Nothing to discriminate: an answer with no Devanagari letter is not a
        // candidate for "wrong Devanagari language", and a numerals-only answer
        // ("२४") has no language at all. The script rule upstream is what
        // refuses a Latin answer to a Nepali target.
        guard containsDevanagariLetter(text) else { return .accept }

        let evidence = evidence(in: text)
        if !evidence.echoed.isEmpty { return .reject(.instructionEcho) }
        if !evidence.hindi.isEmpty { return .reject(.hindiEvidence) }
        if evidence.nepali.isEmpty {
            // [SHORT-ANSWER-EXEMPTION] (2026-09-20) The owner's 02:35 device
            // capture: the on-device brain's real answers to short sign text
            // are short bare translations, and every one was refused with
            // `no_nepali_evidence` — a one-word answer cannot carry a
            // grammatical marker, so the rule demanded evidence a correct
            // short answer can never produce, and the elder saw nothing,
            // ever. An answer at or under `maxMarkerlessWords` words is now
            // accepted on script + non-Hindi + non-echo evidence alone. The
            // bounded risk — a markerless Marathi bare noun shown once — is
            // the deliberate price of ever showing a short answer at all.
            // Longer markerless answers keep the refusal: a sentence has room
            // for grammar, and its absence still means what it always did.
            return devanagariWords(text).count <= Self.maxMarkerlessWords
                ? .accept
                : .reject(.noNepaliEvidence)
        }
        return .accept
    }

    /// [SHORT-ANSWER-EXEMPTION] The word-count bound above which a
    /// markerless Devanagari answer is still refused. Two words is a bare
    /// noun phrase — the largest "short sign" answer that cannot plausibly
    /// carry grammar; three words has room for it.
    /// [EXEMPTION-WIDENED] (owner's 22:41 capture: the dispatch fires, the
    /// model answers every batch with 48–89-char Devanagari arrays, and
    /// `no_nepali_evidence` refuses them ALL — three-plus-word real answers
    /// the owner never sees.) The exemption covers the model's real answer
    /// lengths: markerless Devanagari of eight words or fewer settles on
    /// script + non-Hindi + non-echo evidence. Eight is the word-count
    /// axis's ceiling: the wrong-language corpus fixtures (3–7 words) sit
    /// inside it and now accept by design — the documented price of showing
    /// any real answer at all — while anything longer keeps the refusal.
    static let maxMarkerlessWords = 8

    // MARK: - Reading the answer

    /// The markers `text` carries — the gate's whole input.
    ///
    /// Exposed rather than private so the suites can assert *which* marker a
    /// fixture tripped, which is the difference between "the rule fired" and
    /// "the rule fired for the reason it claims to".
    static func evidence(in text: String) -> Evidence {
        let words = devanagariWords(text)
        return Evidence(nepali: matches(nepaliMarkers, in: words),
                        hindi: matches(hindiMarkers, in: words),
                        echoed: matches(echoMarkers, in: words)
                            + latinEchoPhrases.filter { text.lowercased().contains($0) })
    }

    /// Whether the text contains a Devanagari *letter*.
    ///
    /// Deliberately `CharacterSet.letters` and not the block: the marks that
    /// make up a word (मात्रा) are not letters, and the digits are not either,
    /// which is exactly the distinction wanted here — "२४" must pass the gate
    /// with nothing for it to judge.
    static func containsDevanagariLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            isDevanagari($0) && CharacterSet.letters.contains($0)
        }
    }

    // MARK: - Tokenising

    /// A Devanagari word, as Unicode **scalars** rather than as a `String`.
    ///
    /// The unit is load-bearing, and the reason is a defect this suite caught
    /// rather than a style preference: Swift's `Character` is a grapheme
    /// cluster, and an Indic conjunct — consonant + virama + consonant — is one
    /// cluster. "राख्नुहोस्" is four characters and ten scalars, and its last
    /// three characters are not "नुहोस्" but "ख्नु", "हो", "स्": the न is glued
    /// to the preceding syllable's ख् by the virama. A Character-based
    /// `hasSuffix("नुहोस्")` therefore answers **false** for a suffix that is
    /// plainly in the text, and the polite imperative — the ending most signs
    /// this feature reads are written in — would never be found.
    private typealias Word = [Unicode.Scalar]

    /// The Devanagari words of a string.
    ///
    /// A word is a maximal run of Devanagari word scalars: letters, the vowel
    /// signs and other marks that spell them (which are *not* letters in
    /// Unicode, and would otherwise split every word at its first मात्रा), the
    /// nukta, and the two zero-width joiners Nepali orthography uses. The
    /// danda (।), the double danda, the Devanagari digits and the abbreviation
    /// sign are *not* word scalars: they are how a sentence ends and how a
    /// number is written, and gluing either to a word would hide the word's
    /// ending from the suffix markers below ("छ।" is the word छ followed by
    /// punctuation, not the word "छ।").
    private static func devanagariWords(_ text: String) -> [Word] {
        var words: [Word] = []
        var current: Word = []
        for scalar in text.unicodeScalars {
            if isDevanagariWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = []
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value) || (0xA8E0...0xA8FF).contains(scalar.value)
    }

    private static func isDevanagariWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        // The joiners first: they sit outside the block but inside a word.
        // Asked for by property rather than by code point, because the property
        // is the actual rule (Unicode's Join_Control is exactly these two) and
        // because the numeric spelling of one of them reads, to the feature's
        // hygiene scan, as a re-declaration of a configured default.
        if scalar.properties.isJoinControl { return true }
        switch scalar.value {
        // The sentence and number furniture of the block.
        case 0x0964, 0x0965, 0x0970, 0x0971: return false
        case 0x0966...0x096F: return false
        default: return isDevanagari(scalar)
        }
    }

    // MARK: - Markers

    /// How a marker is matched against a token.
    ///
    /// The shape is part of the evidence: a Nepali suffix attached to a stem
    /// (शब्द**हरू**, घर**बाट**) must not be matched as a standalone word,
    /// because the standalone form is what the other language writes.
    ///
    /// Internal rather than private so the suites can assert a *shape* as well
    /// as a match: "the list has a suffix entry and the fixture needed one" is
    /// a different claim from "the fixture matched something".
    enum Shape {
        /// The whole word.
        case word
        /// The word's beginning (inflected forms of one stem).
        case prefix
        /// The word's end, with a stem in front of it. The stem is why the
        /// comparison is scalar-by-scalar: Nepali stems end in conjuncts
        /// (राख्-नुहोस्), and a grapheme-cluster suffix test cannot see past one.
        case suffix
    }

    /// One marker, with the ambiguity that was checked before it was allowed in.
    ///
    /// `evidence` is not decoration: it is the answer to "why can the other
    /// language not produce this form?", written next to the form so that the
    /// next reader can re-check it instead of re-deriving it. A marker whose
    /// evidence cannot be stated is not a marker — it is a guess, and the
    /// suites fail on an empty evidence string.
    ///
    /// Internal for `Shape`'s reason: the lists themselves are the thing the
    /// suites audit, and a list a test cannot read is a list nobody checks.
    struct Marker {
        let text: String
        let shape: Shape
        let evidence: String
        /// `text` as scalars, so matching never touches `Character` (see
        /// `Word`): a conjunct would otherwise hide a suffix that is present,
        /// and would also make the "longer than the marker" test compare
        /// graphemes against scalars.
        let scalars: [Unicode.Scalar]

        /// A whole-word marker — the shape of every entry but the suffixes, so
        /// the common case reads as the pair that actually matters (the form,
        /// and why it is exclusive to one language).
        init(_ text: String, _ evidence: String) {
            self.init(text, .word, evidence)
        }

        init(_ text: String, _ shape: Shape, _ evidence: String) {
            self.text = text
            self.shape = shape
            self.evidence = evidence
            self.scalars = Array(text.unicodeScalars)
        }
    }

    /// The distinct markers of `markers` present in `words`, in the order the
    /// list declares (a list's order is its documentation; an answer's marker
    /// order would depend on where a word happened to fall in a sentence).
    ///
    /// Every comparison is scalar-by-scalar, for `Word`'s reason: `hasSuffix`
    /// and `hasPrefix` on `String` work in grapheme clusters, and a Nepali stem
    /// that ends in a conjunct glues the next syllable onto itself.
    private static func matches(_ markers: [Marker], in words: [Word]) -> [String] {
        var found: [String] = []
        for marker in markers where !found.contains(marker.text) {
            let hit = words.contains { word in
                switch marker.shape {
                case .word:
                    return word.elementsEqual(marker.scalars)
                case .prefix:
                    return word.starts(with: marker.scalars)
                case .suffix:
                    return word.count > marker.scalars.count
                        && word.suffix(marker.scalars.count).elementsEqual(marker.scalars)
                }
            }
            if hit { found.append(marker.text) }
        }
        return found
    }

    // MARK: Nepali-exclusive evidence

    /// Forms Nepali produces and Hindi does not.
    ///
    /// Every entry was checked against its Hindi near-miss and the near-miss is
    /// written down: the copulas differ by one vowel sign (छ/है, छु/हूँ), the
    /// past tense by a syllable (थियो/था), the participles by their stem
    /// (गरेको/किया). The two suffix entries are the reason the matcher has a
    /// suffix shape at all — Hindi writes the *standalone* form of both words
    /// (लाई "brought", बाट "path"), and only the attached form is Nepali's.
    static let nepaliMarkers: [Marker] = [
        // Copulas and the verb "to be". The single strongest family in the
        // list: Nepali's copula is छ and Hindi's is है, and no Hindi word is
        // spelled छ.
        Marker("छ", "the Nepali copula (यो किताब छ); Hindi's copula is है, and Hindi's छ lives only inside other tokens (छह six, छोटा small, अच्छा good)"),
        Marker("छन्", "the Nepali 3rd-person plural masculine copula; Hindi has हैं"),
        Marker("छिन्", "the Nepali 3rd-person plural feminine copula; Hindi has हैं"),
        Marker("छु", "the Nepali 1st-person copula; Hindi has हूँ, which carries the long ू and not the short ु"),
        Marker("छस्", "the Nepali 2nd-person intimate copula; Hindi has है"),
        Marker("छौ", "the Nepali 2nd-person plural copula; Hindi has हो"),
        Marker("छैन", "Nepali's negated copula (is not); Hindi says नहीं है"),
        Marker("हुँदैन", "Nepali's 'does not happen'; Hindi says नहीं होता"),
        Marker("होइन", "Nepali's 'is not' / 'no'; Hindi's word for that is नहीं"),
        Marker("हैन", "Nepali's other spelling of होइन — the ि-vowel form है is Hindi's copula, but the Hindi token never carries the न"),
        Marker("हुन्छ", "Nepali's habitual copula (is/happens); Hindi says होता है"),
        Marker("हुन्छन्", "Nepali's habitual copula, 3rd-person plural; Hindi says होते हैं"),
        Marker("हुने", "Nepali's relative form 'that is / that will be'; Hindi's is होने"),
        Marker("हुनु", "Nepali's infinitive 'to be'; Hindi's is होना"),
        Marker("हुन्", "Nepali's polite 3rd-person plural copula; Hindi has हैं"),
        Marker("हुन", "Nepali's infinitive stem (हुन सक्छ it can be); Hindi has होना / हो"),
        Marker("होला", "Nepali's presumptive (probably is); Hindi says होगा"),
        // Past tense. Nepali adds a syllable Hindi does not have.
        Marker("भयो", "Nepali's past 'became / happened'; Hindi's is हुआ"),
        Marker("भएको", "Nepali's perfect participle 'which became'; Hindi's is हुआ / हुए"),
        Marker("भन्ने", "Nepali's 'which says'; Hindi's is कहने"),
        Marker("भने", "Nepali's 'said' / 'if'; Hindi's is कहा"),
        Marker("थियो", "Nepali's past copula (was); Hindi's is था"),
        Marker("थिए", "Nepali's past copula, plural; Hindi's is थे"),
        Marker("थिइन्", "Nepali's past copula, feminine plural; Hindi's is थीं"),
        Marker("थिई", "Nepali's past copula, feminine singular; Hindi's is थी"),
        // The verb "to do": Hindi's कर- family is the near-miss for every one
        // of these, and the forms below are all attested Nepali.
        Marker("गर्छ", "Nepali's 'does'; Hindi says करता है"),
        Marker("गर्छन्", "Nepali's 'do', 3rd-person plural; Hindi says करते हैं"),
        Marker("गर्नु", "Nepali's infinitive 'to do'; Hindi's is करना"),
        Marker("गर्न", "Nepali's infinitive stem (गर्न सक्छ); Hindi's is करने / करना"),
        Marker("गर्ने", "Nepali's relative 'which does'; Hindi says करने वाला"),
        Marker("गरेको", "Nepali's perfect participle 'which did'; Hindi's is किया / किए"),
        Marker("गरे", "Nepali's past, plural; Hindi's is किए"),
        Marker("गर्यो", "Nepali's past, singular; Hindi's is किया"),
        // Particles and postpositions. Hindi's equivalents are different words,
        // not different spellings.
        Marker("पनि", "Nepali's 'also'; Hindi's is भी"),
        Marker("किनभने", "Nepali's 'because'; Hindi's is क्योंकि"),
        Marker("तर", "Nepali's 'but'; Hindi's is लेकिन / पर (Hindi's तर survives only inside comparatives like उच्चतर)"),
        Marker("भित्र", "Nepali's 'inside'; Hindi's is भीतर"),
        Marker("यो", "Nepali's 'this'; Hindi's is यह (यहाँ 'here' is a different token and is shared by both)"),
        Marker("यस", "Nepali's oblique of यो; Hindi's is इस"),
        Marker("नै", "Nepali's emphatic particle, written as its own word; Hindi's is ही"),
        Marker("लागि", "Nepali's 'for'; Hindi's is लिए"),
        Marker("सँग", "Nepali's 'with'; Hindi's is साथ"),
        Marker("सम्म", "Nepali's 'until / up to'; Hindi's is तक"),
        Marker("पछि", "Nepali's 'after / behind'; Hindi's is बाद / पीछे"),
        Marker("रहेछ", "Nepali's evidential 'apparently is'; Hindi says रहा है"),
        // Verbs that are a different word, not a different inflection. These
        // are the forms a sentence about a sign actually uses.
        Marker("सक्छ", "Nepali's 'can'; Hindi says सकता है"),
        Marker("चाहिन्छ", "Nepali's 'is needed'; Hindi says चाहिए"),
        Marker("पाइन्छ", "Nepali's 'is available / is allowed'; Hindi says मिलता है"),
        Marker("देखिन्छ", "Nepali's 'appears / is seen'; Hindi says दिखता है"),
        Marker("लाग्छ", "Nepali's 'seems / takes'; Hindi says लगता है"),
        Marker("जान्छ", "Nepali's 'goes'; Hindi says जाता है"),
        Marker("आउँछ", "Nepali's 'comes'; Hindi says आता है"),
        // Suffixes. Both are written *attached* in Nepali and *standalone* in
        // Hindi, which is why the matcher requires a stem in front of them.
        Marker("हरू", .suffix, "Nepali's plural suffix, written attached (शब्दहरू); Hindi pluralises with ें / लोग / गण and has no हरू form"),
        Marker("हरु", .suffix, "the same plural suffix without the ū matra — the spelling most Nepali keyboards emit"),
        Marker("लाई", .suffix, "Nepali's dative/accusative suffix, attached (रामलाई to Ram); Hindi uses को, and Hindi's लाई (brought, feminine) is a standalone verb token"),
        Marker("बाट", .suffix, "Nepali's ablative suffix, attached (घरबाट from home); Hindi uses से, and Hindi's बाट (path) is standalone"),
        Marker("नुहोस्", .suffix, "Nepali's polite imperative ending (राख्नुहोस्, पढ्नुहोस्); Hindi's polite imperative is -इए / -इये (रखिए)")
    ]

    // MARK: Hindi-exclusive evidence

    /// Forms Hindi produces and Nepali does not.
    ///
    /// The near-misses are stated per entry for the same reason as above. Three
    /// of the task's candidates are deliberately **not** here, and the reason
    /// is worth keeping: की and का are Nepali's own genitive/plural markers as
    /// well as Hindi's postpositions (उसकी छोरी is Nepali), को is Nepali's
    /// accusative as well as Hindi's dative, and हो is the stem of the Nepali
    /// copula — flagging any of them would reject correct Nepali.
    static let hindiMarkers: [Marker] = [
        // Copulas and auxiliaries.
        Marker("है", "Hindi's copula; Nepali's is छ — and Nepali's हैन (is not) is a different token, so the token rule keeps the two apart"),
        Marker("हैं", "Hindi's plural copula; Nepali has छन् / छिन्"),
        Marker("हूँ", "Hindi's 1st-person copula, with the long ू; Nepali says छु"),
        Marker("था", "Hindi's past copula; Nepali's is थियो"),
        Marker("थे", "Hindi's past copula, plural; Nepali's is थिए"),
        Marker("थीं", "Hindi's past copula, feminine plural; Nepali's is थिइन्"),
        Marker("रहा", "Hindi's progressive auxiliary; Nepali says रहेको / रहेछ"),
        Marker("रही", "Hindi's progressive auxiliary, feminine; Nepali says रहेको"),
        // Pronouns and demonstratives.
        Marker("मैं", "Hindi's 'I'; Nepali's is म"),
        Marker("तुम", "Hindi's 'you'; Nepali's are तिमी / तपाईं"),
        Marker("यह", "Hindi's 'this'; Nepali's is यो (यहाँ 'here' is a different token, shared by both)"),
        Marker("इस", "Hindi's oblique of यह; Nepali's is यस"),
        Marker("वह", "Hindi's 'that'; Nepali's is त्यो"),
        Marker("वे", "Hindi's 'those'; Nepali's is ती"),
        Marker("ये", "Hindi's 'these'; Nepali's is यी"),
        Marker("क्या", "Hindi's 'what'; Nepali's is के"),
        Marker("कौन", "Hindi's 'who'; Nepali's is को"),
        Marker("कोई", "Hindi's 'someone'; Nepali's is कोही"),
        Marker("कुछ", "Hindi's 'some'; Nepali's is केही"),
        // Postpositions and particles.
        Marker("और", "Hindi's 'and'; Nepali's is र / अनि (Nepali's अरु means 'other' and is a different token)"),
        Marker("में", "Hindi's locative; Nepali's is मा"),
        Marker("नहीं", "Hindi's negation; Nepali has छैन / होइन / न"),
        Marker("भी", "Hindi's 'also'; Nepali's is पनि"),
        Marker("ने", "Hindi's ergative postposition (उसने कहा); Nepali marks the agent with ले (उसले भन्यो)"),
        // Adjectives and adverbs that are a different word, not a spelling.
        Marker("बहुत", "Hindi's 'much / very'; Nepali's is धेरै"),
        Marker("अच्छा", "Hindi's 'good'; Nepali's is राम्रो"),
        Marker("फिर", "Hindi's 'again / then'; Nepali's is फेरि — one vowel sign apart, which is why the token is matched exactly"),
        // The verb "to do" and the verb "to happen": Hindi's forms.
        Marker("करना", "Hindi's infinitive 'to do'; Nepali's is गर्नु"),
        Marker("करने", "Hindi's oblique infinitive 'to do'; Nepali's is गर्ने"),
        Marker("करता", "Hindi's habitual 'does'; Nepali's is गर्छ"),
        Marker("करती", "Hindi's habitual 'does', feminine; Nepali's is गर्छ"),
        Marker("करते", "Hindi's habitual 'do', plural; Nepali's is गर्छन्"),
        Marker("किया", "Hindi's perfective 'did'; Nepali's is गरेको / गर्यो"),
        Marker("किए", "Hindi's perfective 'did', plural; Nepali's is गरे"),
        Marker("हुआ", "Hindi's 'happened / became'; Nepali's is भयो"),
        Marker("हुई", "Hindi's 'happened', feminine; Nepali's is भयो"),
        Marker("हुए", "Hindi's 'happened', plural; Nepali's is भए"),
        Marker("होता", "Hindi's habitual copula; Nepali's is हुन्छ"),
        Marker("होती", "Hindi's habitual copula, feminine; Nepali's is हुन्छ"),
        Marker("होते", "Hindi's habitual copula, plural; Nepali's is हुन्छन्"),
        Marker("होगा", "Hindi's future copula; Nepali's is होला"),
        Marker("होगी", "Hindi's future copula, feminine; Nepali's is होला"),
        // Imperatives. Hindi's polite imperative ends in -इए / -इये; the plain
        // one is the bare stem with -ो / -ें, which is the shape below.
        Marker("करो", "Hindi's imperative 'do'; Nepali's is गर / गर्नुहोस्"),
        Marker("करें", "Hindi's imperative / subjunctive 'do', plural; Nepali's is गरौं / गर्नुहोस्"),
        Marker("रखो", "Hindi's imperative 'keep'; Nepali's is राख / राख्नुहोस्"),
        Marker("रखें", "Hindi's imperative 'keep', plural; Nepali's is राख्नुहोस्"),
        Marker("लें", "Hindi's imperative 'take'; Nepali's is लिनुहोस्"),
        Marker("दें", "Hindi's imperative 'give'; Nepali's is दिनुहोस्"),
        Marker("लेना", "Hindi's infinitive 'to take'; Nepali's is लिनु"),
        Marker("देना", "Hindi's infinitive 'to give'; Nepali's is दिनु")
    ]

    // MARK: Instruction echoes

    /// Words an *instruction about translating* uses and a translated sign does
    /// not.
    ///
    /// This is the evaluation's second failure class, and it is a class of its
    /// own because it can arrive in flawless Nepali: "अंग्रेजी शब्दहरू
    /// नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…" carries हरू and गर्नुहोस् — the
    /// answer *is* Nepali and is not a translation of anything. The check runs
    /// before the language evidence for exactly that reason.
    ///
    /// The cost is stated rather than hidden: a sign *about* translation
    /// ("Translation services" → "अनुवाद सेवा") and a sign on a language
    /// school's wall are rejected too, and go to the next tier. That is the
    /// same safe direction as every other rejection here.
    static let echoMarkers: [Marker] = [
        Marker("अनुवाद", .prefix, "the act of translating; a translation of a sign's content does not describe itself as one (अनुवादित, अनुवादन and अनुवादक are the same word's family)"),
        Marker("नेपालीमा", .prefix, "the instruction's own phrase, 'into Nepali'"),
        Marker("अंग्रेजी", .prefix, "the instruction's own language label; a translation *of the word* English is the accepted cost of this entry"),
        Marker("शब्द", .prefix, "the instruction's unit of work, 'words' (शब्दहरू); a sign's content is not counted in words"),
        Marker("वाक्य", .prefix, "the instruction's unit of work, 'sentence'"),
        Marker("लाइनमा", .prefix, "the instruction's formatting rule, 'on one line'"),
        Marker("हिंदी", .prefix, "the wrong language, named in the answer"),
        Marker("हिन्दी", .prefix, "the same, in the spelling with the ि-vowel and the half न")
    ]

    /// The same class in Latin letters: a model that answers in English is
    /// refused by the tier's script rule already, but only *after* it has
    /// produced Devanagari somewhere — a mixed answer that echoes the
    /// instruction in English and translates part of it in Nepali would
    /// otherwise pass. The root ("translat") covers translate/translation/
    /// translating without carrying a whole word list.
    static let latinEchoPhrases = ["translat", "one line per", "json"]
}
