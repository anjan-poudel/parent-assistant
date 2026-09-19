import XCTest
@testable import ElderlyAssistant

/// The Devanagari language gate (C18, 2026-09-18) — the answer rule that
/// separates Nepali from the other languages that share its script.
///
/// Every fixture here is a **real sentence** rather than a marker with
/// whitespace around it, and that is the point of the suite: a rule about a
/// language cannot be checked against the words it was built from. The
/// evaluation that asked for this rule produced Devanagari Hindi and echoed
/// instructions, so the Hindi side of the table is those outputs (and their
/// close relatives); the Nepali side is what a Nepali sign actually says; and
/// the near-miss pairs — हैन/hै, फेरि/फिर, थिई/थीं, हुँ/हूँ — sit between them,
/// because a token rule that cannot tell those apart is a rule that rejects
/// correct Nepali.
///
/// The suite ends with the trade-off stated as a number: the conservative half
/// of the rule (an answer with no Nepali evidence does not settle a region) is
/// measured on a fixture set rather than described, so the cost of never
/// showing an elder Hindi is visible in the counts and not only in a comment.
final class NepaliOutputGateTests: XCTestCase {

    private func accepts(_ text: String) -> Bool {
        NepaliOutputGate.accepts(text, targetLanguage: .nepali)
    }

    // MARK: - Fixtures

    /// Nepali sentences — what the gate exists to let through.
    ///
    /// Signs, packets and instructions of the kind this feature reads, each
    /// with the Nepali evidence the gate is looking for (a copula, an
    /// infinitive, a plural, an imperative). None of them carries a form from
    /// the Hindi list.
    private let nepaliReferences = [
        "यो औषधि खानु अघि पढ्नुहोस्।",           // read this before taking the medicine
        "भित्र पस्न मनाही छ।",                    // entering inside is prohibited
        "खुला छ।",                                // it is open
        "यहाँ भित्र प्रवेश मात्र",                // the tier's own suite's fixture
        "पानी नजिक बिजुलीका उपकरण नराख्नुहोस्।", // do not keep electrical appliances near water
        "यो दरवाजा बन्द गर्नुहोस्।",             // please close this door
        "फार्मेसी यहाँ छ।",                       // the pharmacy is here
        "सबै सामान बाहिर राख्नुहोस्।",            // keep all the goods outside
        "रामको घर यहाँ छ।",                       // Ram's house is here — को is shared, and is not evidence
        "औषधि पसल छ।",                            // there is a medicine shop
        "बत्ती निभाउनुहोस्।",                     // switch off the light
        "यो प्याकेटको म्याद सकिएको छ।"            // this packet has expired
    ]

    /// The instruction-echo class — what the evaluation actually produced when
    /// it echoed the prompt back instead of translating. The first is the
    /// evaluated output verbatim.
    private let instructionEchoes = [
        "अंग्रेजी शब्दहरू नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…",
        "यो अंग्रेजी वाक्य नेपालीमा अनुवाद गर्नुहोस्।",
        "शब्दहरूको सूची अनुवाद गरिएको छ।",
        "लाइनमा एक अनुवाद दिनुहोस्।",
        "Translate the sign into Nepali. यो फार्मेसी छ।"
    ]

    /// Hindi outputs. The first is the evaluated output verbatim; the rest are
    /// the same language's ordinary sign and packet sentences.
    private let hindiAnswers = [
        "जल के निकट विद्युत उपकरण रखो नहीं।",
        "खुला है।",
        "यह दवा खाने से पहले लें।",
        "दरवाजा बंद करो।",
        "सभी सामान बाहर रखें।",
        "मैं यह काम नहीं कर सकता।",
        "पानी के पास बिजली का सामान मत रखो।",
        "यहाँ पानी पीने की अनुमति नहीं है।",
        "इस दवा को ठंडे स्थान पर रखें।",
        "वह बहुत अच्छा है।",
        "बच्चों को दूध देना जरूरी है।"
    ]

    /// The third wrong-Devanagari class, and the reason the rule cannot be
    /// "reject Hindi": Marathi is Devanagari too, and a transliterated Bengali
    /// is Devanagari in a Nepali model's hands. Neither carries a Hindi marker,
    /// so only "no Nepali evidence" catches them.
    private let otherDevanagari = [
        "पाणी जवळ विजेची उपकरणे ठेवू नका.",       // Marathi: do not keep appliances near water
        "प्रवेश बंद आहे.",                        // Marathi: the entry is closed
        "जोलेर काछे बिद्युत जोन्त्रो राखबेन ना।" // Bengali, transliterated into Devanagari
    ]

    /// Correct translations the gate ACCEPTS on purpose since the
    /// short-answer exemption (2026-09-20): single shared nouns and a bare
    /// noun phrase, spelled identically in Hindi and Nepali, so nothing in
    /// the string establishes the elder's language. Declining them was the
    /// cost of never showing the elder Hindi — until the owner's device
    /// capture showed the real price: every real short answer refused, and
    /// the elder shown nothing, ever. The count below pins the acceptance.
    private let markerFreeAnswers = [
        "फार्मेसी",        // Pharmacy
        "प्रवेश निषेध",     // No entry
        "औषधि",           // medicine
        "नमस्ते",         // hello
        "बत्ती"           // light
    ]

    // MARK: - The rule

    func testNepaliSentencesAreAccepted() {
        for sentence in nepaliReferences {
            XCTAssertTrue(accepts(sentence),
                          "a Nepali sentence was not established as Nepali: \(sentence) "
                          + "— evidence: \(NepaliOutputGate.evidence(in: sentence))")
        }
    }

    func testHindiAnswersAreRejected() {
        for answer in hindiAnswers {
            XCTAssertFalse(accepts(answer),
                           "Hindi Devanagari would have settled a region as a Nepali translation: \(answer)")
        }
    }

    func testInstructionEchoesAreRejected() {
        for echo in instructionEchoes {
            XCTAssertFalse(accepts(echo),
                           "the instruction echoed back would have settled a region: \(echo)")
        }
    }

    /// The echo class is not a special case of "not Nepali", and this is the
    /// fixture that says so: the evaluated echo carries हरू and गर्नुहोस्, so
    /// the language evidence would *accept* it. Only the echo rule may decide.
    func testAnEchoCarriesNepaliEvidenceAndIsStillRejected() {
        let echo = instructionEchoes[0]
        let evidence = NepaliOutputGate.evidence(in: echo)
        XCTAssertFalse(evidence.nepali.isEmpty,
                       "the fixture must be the hard case — Nepali morphology in the answer")
        XCTAssertEqual(NepaliOutputGate.verdict(for: echo, targetLanguage: .nepali),
                       .reject(.instructionEcho),
                       "the echo rule runs before the language rule, or this answer is accepted")
    }

    func testOtherDevanagariLanguagesAreRejected() {
        for answer in otherDevanagari {
            XCTAssertFalse(accepts(answer),
                           "a non-Nepali Devanagari answer would have settled a region: \(answer)")
        }
    }

    /// The three rejections are told apart, because they are three different
    /// facts about a session: an echo says the model did not answer, the Hindi
    /// one says it answered in the wrong language, and the third says the
    /// answer could not be established as any language at all.
    func testTheThreeReasonsAreDistinguished() {
        XCTAssertEqual(NepaliOutputGate.verdict(for: hindiAnswers[0], targetLanguage: .nepali),
                       .reject(.hindiEvidence))
        XCTAssertEqual(NepaliOutputGate.verdict(for: instructionEchoes[0], targetLanguage: .nepali),
                       .reject(.instructionEcho))
        XCTAssertEqual(NepaliOutputGate.verdict(for: otherDevanagari[0], targetLanguage: .nepali),
                       .reject(.noNepaliEvidence))
        XCTAssertEqual(NepaliOutputGate.verdict(for: nepaliReferences[0], targetLanguage: .nepali),
                       .accept)
    }

    /// The Hindi-to-Nepali near-misses, one at a time. Each pair is one vowel
    /// sign or one syllable apart, and the pair is the reason the matcher works
    /// on tokens rather than on substrings.
    func testNearMissesAreToldApart() {
        // हैन (Nepali "is not") contains है (Hindi's copula) as its first two
        // scalars: as a token it is not that word, and it must not be read as
        // Hindi evidence.
        XCTAssertTrue(NepaliOutputGate.evidence(in: "हैन").hindi.isEmpty,
                      "हैन is Nepali; the Hindi copula inside it is not a word")
        XCTAssertTrue(NepaliOutputGate.evidence(in: "हैन").nepali.contains("हैन"))
        XCTAssertTrue(accepts("यो सत्य हैन।"), "Nepali's 'is not' must not be read as Hindi")

        // हूँ (Hindi, long ū) against हुँ (Nepali, short u) — one code point
        // apart and impossible to see in most typefaces.
        XCTAssertTrue(NepaliOutputGate.evidence(in: "हूँ").hindi.contains("हूँ"))
        XCTAssertTrue(NepaliOutputGate.evidence(in: "हुँ").hindi.isEmpty,
                      "the Nepali spelling must not be flagged as the Hindi one")

        // फिर (Hindi) against फेरि (Nepali).
        XCTAssertTrue(NepaliOutputGate.evidence(in: "फिर").hindi.contains("फिर"))
        XCTAssertTrue(NepaliOutputGate.evidence(in: "फेरि").hindi.isEmpty)

        // थिई (Nepali, feminine past) against थीं (Hindi).
        XCTAssertTrue(NepaliOutputGate.evidence(in: "थिई").hindi.isEmpty)
        XCTAssertTrue(NepaliOutputGate.evidence(in: "थी").hindi.isEmpty,
                      "थी is not on the list on purpose — Nepali writes it too")
        XCTAssertTrue(NepaliOutputGate.evidence(in: "थीं").hindi.contains("थीं"))
    }

    /// The discriminating code points, pinned as numbers.
    ///
    /// A language rule built on one-vowel-sign differences is only as good as
    /// its encoding: a font, an editor or a copy-paste that quietly unified
    /// either pair would not fail any other test in this repository, and the
    /// gate would start accepting Hindi. These assertions are the ones that
    /// fail if that ever happens.
    func testTheDiscriminatingPairsAreOneCodePointApart() {
        let hindi = Array("हूँ".unicodeScalars).map(\.value)
        let nepali = Array("हुँ".unicodeScalars).map(\.value)
        XCTAssertEqual(hindi, [0x0939, 0x0942, 0x0901], "हूँ is ह + the long ū + the candrabindu")
        XCTAssertEqual(nepali, [0x0939, 0x0941, 0x0901], "हुँ is ह + the short u + the candrabindu")
        XCTAssertNotEqual(hindi, nepali)

        XCTAssertEqual(Array("छ".unicodeScalars).map(\.value), [0x091B])
        XCTAssertEqual(Array("है".unicodeScalars).map(\.value), [0x0939, 0x0948])
        XCTAssertEqual(Array("हैन".unicodeScalars).map(\.value), [0x0939, 0x0948, 0x0928])
        XCTAssertEqual(Array("फिर".unicodeScalars).map(\.value), [0x092B, 0x093F, 0x0930])
        XCTAssertEqual(Array("फेरि".unicodeScalars).map(\.value), [0x092B, 0x0947, 0x0930, 0x093F])
        XCTAssertEqual(Array("थिई".unicodeScalars).map(\.value), [0x0925, 0x093F, 0x0908])
        XCTAssertEqual(Array("थीं".unicodeScalars).map(\.value), [0x0925, 0x0940, 0x0902])
    }

    /// A marker is matched against a whole word, never against a coincidence
    /// inside one: छ is Nepali's copula, and अच्छा (Hindi "good") merely
    /// contains it.
    func testMarkersAreMatchedOnWordBoundaries() {
        let inside = NepaliOutputGate.evidence(in: "अच्छा")
        XCTAssertFalse(inside.nepali.contains("छ"),
                       "छ inside अच्छा is not the copula")

        // The plural and the two postpositions are written attached in Nepali
        // and standalone in Hindi, so a standalone occurrence is not evidence.
        XCTAssertTrue(NepaliOutputGate.evidence(in: "हरू").nepali.isEmpty,
                      "the plural suffix alone is not a Nepali word")
        XCTAssertTrue(NepaliOutputGate.evidence(in: "लाई").nepali.isEmpty,
                      "Hindi's लाई (brought) is a standalone verb, so standalone is not Nepali evidence")
        XCTAssertTrue(NepaliOutputGate.evidence(in: "बाट").nepali.isEmpty)
        XCTAssertTrue(NepaliOutputGate.evidence(in: "शब्दहरू").nepali.contains("हरू"))
        XCTAssertTrue(NepaliOutputGate.evidence(in: "रामलाई").nepali.contains("लाई"))
        XCTAssertTrue(NepaliOutputGate.evidence(in: "घरबाट").nepali.contains("बाट"))
        XCTAssertTrue(NepaliOutputGate.evidence(in: "राख्नुहोस्").nepali.contains("नुहोस्"))
    }

    /// The conjunct hazard, pinned as a regression.
    ///
    /// This is the one assertion in the suite that caught a real defect rather
    /// than confirming a decision: the suffix rule shipped comparing *Strings*,
    /// and `String.hasSuffix` works in grapheme clusters — so a Nepali stem
    /// ending in a conjunct hid the suffix behind it. "राख्नुहोस्" is four
    /// clusters, because ख् + न is a single one, and the last three clusters are
    /// "ख्नु", "हो", "स्". The polite imperative is how most signs this feature
    /// reads are written ("…नराख्नुहोस्" is on every appliance warning), so the
    /// Character-based rule refused exactly the sentences the feature exists
    /// for — which is why the rule counts scalars, and why this test states the
    /// cluster arithmetic next to the assertion that depends on it.
    func testTheSuffixRuleSeesPastAConjunct() {
        XCTAssertEqual("राख्नुहोस्".count, 4, "four grapheme clusters")
        XCTAssertEqual("राख्नुहोस्".unicodeScalars.count, 10, "and ten scalars")
        XCTAssertFalse("राख्नुहोस्".hasSuffix("नुहोस्"),
                       "a Character-based suffix test answers false for a suffix that is in the text")
        XCTAssertTrue(NepaliOutputGate.evidence(in: "राख्नुहोस्").nepali.contains("नुहोस्"),
                      "the rule matches the word's scalars, so the imperative is found")
        XCTAssertTrue(accepts("राख्नुहोस्"),
                      "and the sign that ends in it is accepted rather than sent to the cloud")
    }

    /// The marks a sentence ends with are not part of its last word: a danda
    /// glued to a copula would hide the copula from the matcher, and every
    /// fixture in the suite carries one.
    func testSentencePunctuationIsNotPartOfTheToken() {
        XCTAssertEqual(NepaliOutputGate.evidence(in: "खुला छ।").nepali, ["छ"])
        XCTAssertEqual(NepaliOutputGate.evidence(in: "भित्र पस्न मनाही छ।").nepali, ["छ", "भित्र"])
        XCTAssertTrue(NepaliOutputGate.evidence(in: "है।").hindi.contains("है"),
                      "the same rule has to hold on the Hindi side, or punctuation hides the wrong answer")
    }

    // MARK: - What the gate does not judge

    /// The English target is the tier's script rule's business: there is no
    /// Nepali/Hindi question to ask of a Latin answer, and the gate must not
    /// start refusing one.
    func testTheGateIsSilentForTheEnglishTarget() {
        XCTAssertTrue(NepaliOutputGate.accepts("Chemist shop", targetLanguage: .english))
        XCTAssertTrue(NepaliOutputGate.accepts("जल के निकट विद्युत उपकरण रखो नहीं।",
                                               targetLanguage: .english),
                      "the English target's rule is its script, not this gate")
    }

    /// A string with no Devanagari letter has no language to be wrong about.
    /// "२४" is the answer to a numerals-only sign: the Devanagari digits are
    /// not letters, so there is nothing here to discriminate and the gate says
    /// nothing.
    func testLetterlessAnswersAreNotJudged() {
        XCTAssertTrue(accepts("२४"))
        XCTAssertTrue(accepts("1,200"))
        XCTAssertFalse(NepaliOutputGate.containsDevanagariLetter("२४"))
        XCTAssertTrue(NepaliOutputGate.containsDevanagariLetter("छ"))
        XCTAssertTrue(NepaliOutputGate.containsDevanagariLetter("फार्मेसी"),
                      "the vowel signs are not letters, so a word of them still counts")
    }

    // MARK: - The evidence the list is built from

    /// Every marker carries the reason it is allowed to be a marker. A list
    /// entry whose ambiguity was never checked is a guess, and this test is
    /// what stops one from being added quietly.
    func testEveryMarkerCarriesTheAmbiguityEvidenceThatAdmitsIt() {
        let lists: [(name: String, markers: [NepaliOutputGate.Marker])] = [
            ("Nepali", NepaliOutputGate.nepaliMarkers),
            ("Hindi", NepaliOutputGate.hindiMarkers),
            ("echo", NepaliOutputGate.echoMarkers)
        ]
        for list in lists {
            XCTAssertFalse(list.markers.isEmpty, "the \(list.name) list must not be empty")
            for marker in list.markers {
                XCTAssertFalse(marker.evidence.isEmpty,
                               "\(list.name) marker \(marker.text) is admitted with no recorded reason")
                XCTAssertFalse(marker.text.isEmpty)
            }
        }
        // The two shapes are both load-bearing, and both are used: without the
        // word entries the rule cannot read a sentence, and without the suffix
        // entries it cannot read Nepali's plural or its two attached
        // postpositions without also flagging Hindi's standalone words.
        XCTAssertTrue(NepaliOutputGate.nepaliMarkers.contains { $0.shape == .suffix })
        XCTAssertTrue(NepaliOutputGate.hindiMarkers.allSatisfy { $0.shape == .word },
                      "every Hindi entry is a whole word today; a looser shape needs its own justification")
    }

    /// The markers a fixture trips, named — the difference between "the rule
    /// fired" and "the rule fired for the reason it claims to". The gate's
    /// rejection reason is evidence for a capture reader, so what it counted
    /// has to be the thing it says.
    ///
    /// The order is the *list's*, not the sentence's: a marker list is also its
    /// documentation, and the evidence reads in the order the reasons are
    /// written down rather than the order a word happened to fall in an answer.
    func testTheEvidenceNamesTheMarkersTheAnswerActuallyCarries() {
        XCTAssertEqual(NepaliOutputGate.evidence(in: "जल के निकट विद्युत उपकरण रखो नहीं।").hindi,
                       ["नहीं", "रखो"])
        XCTAssertEqual(NepaliOutputGate.evidence(in: "मैं यह काम नहीं कर सकता।").hindi,
                       ["मैं", "यह", "नहीं"])
        XCTAssertEqual(NepaliOutputGate.evidence(in: "यो दरवाजा बन्द गर्नुहोस्।").nepali,
                       ["यो", "नुहोस्"])
        XCTAssertEqual(NepaliOutputGate.evidence(in: "अंग्रेजी शब्दहरू नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…").echoed,
                       ["अनुवाद", "नेपालीमा", "अंग्रेजी", "शब्द", "लाइनमा"])
    }

    /// The words the two languages genuinely share are not evidence in either
    /// direction. को, का, की, हो, मा, जो and the rest are the reason the Hindi
    /// list has no को/की/का/हो entry: flagging them would refuse this sentence,
    /// which is correct Nepali.
    func testSharedVocabularyIsNotEvidence() {
        let sentence = "रामको घर यहाँ छ, र उसकी आमा पनि आउँछिन्।"
        let evidence = NepaliOutputGate.evidence(in: sentence)
        XCTAssertFalse(evidence.nepali.isEmpty, "the sentence carries Nepali evidence")
        XCTAssertTrue(evidence.hindi.isEmpty,
                      "को / की / हो / मा are shared forms and must not be Hindi evidence: \(evidence.hindi)")
        XCTAssertTrue(accepts(sentence))
    }

    // MARK: - The trade-off, as a number

    /// The conservative half of the rule, measured rather than described.
    ///
    /// Three counts, and the third is the cost:
    ///
    ///   - **0 false rejects** on the Nepali references: every correct Nepali
    ///     sentence in the corpus settles a region offline, which is the tier's
    ///     whole purpose.
    ///   - **0 false accepts** on the wrong-language corpus (Hindi, the
    ///     instruction echoes, Marathi and transliterated Bengali): no answer
    ///     that is not Nepali may settle a region, which is the rule's whole
    ///     purpose.
    ///   - **5 false rejects** on the marker-free corpus: correct translations
    ///     that are a single shared noun do not settle either. That is the
    ///     stated price of the second count — such a string goes to the next
    ///     tier instead, and the elder reads the original until the cloud
    ///     answers. This number is pinned so that a later change which moves it
    ///     (a relaxation, or a new marker that makes one of these settle) has
    ///     to update this test and say so.
    func testTheCorpusCountsAreZeroFalseAcceptsZeroFalseRejectsOnReferencesAndFiveOnSharedNouns() {
        let acceptedNepali = nepaliReferences.filter { accepts($0) }.count
        let acceptedWrong = (hindiAnswers + instructionEchoes + otherDevanagari).filter { accepts($0) }.count
        let acceptedMarkerFree = markerFreeAnswers.filter { accepts($0) }.count

        XCTAssertEqual(acceptedNepali, nepaliReferences.count,
                       "false rejects on the Nepali reference corpus: "
                       + "\(nepaliReferences.count - acceptedNepali) of \(nepaliReferences.count)")
        XCTAssertEqual(acceptedWrong, 0,
                       "false accepts on the wrong-language corpus: "
                       + "\(acceptedWrong) of \(hindiAnswers.count + instructionEchoes.count + otherDevanagari.count)")
        // [SHORT-ANSWER-EXEMPTION] (2026-09-20) The deliberate relaxation,
        // restated: every fixture here is at or under the two-word bound, so
        // all of them settle. The trade-off — a markerless Marathi bare noun
        // shown once — is the price of ever showing a short answer at all,
        // which the owner's 02:35 capture proved the old rule never did.
        XCTAssertEqual(acceptedMarkerFree, markerFreeAnswers.count,
                       "the short-answer exemption: every marker-free fixture is inside the "
                       + "two-word bound, so all of them settle now — if one stops settling, "
                       + "the bound moved without moving this pin")

        // And the same numbers, by reason, so a future change that keeps the
        // totals but swaps which rule fires still has to look here. The
        // long markerless answers live in `otherDevanagari` (three words and
        // up) — they still carry the refusal this fixture no longer does.
        XCTAssertEqual(markerFreeAnswers.filter {
            NepaliOutputGate.verdict(for: $0, targetLanguage: .nepali) == .reject(.noNepaliEvidence)
        }.count, 0)
        XCTAssertEqual(hindiAnswers.filter {
            NepaliOutputGate.verdict(for: $0, targetLanguage: .nepali) == .reject(.hindiEvidence)
        }.count, hindiAnswers.count)
    }
}
