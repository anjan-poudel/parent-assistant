import XCTest
@testable import ElderlyAssistant

/// [CNR-GUARD] (T-169, feature `conversational-nepali-replies`) The grammar
/// guard's contract: a pure, total, synchronous verdict — pass, flag with the
/// failing check classes, or unavailable with a reason — and NO rewrite path
/// (FR-CNR-005). The suite pins, in-process and against the style spec:
///
///   * each check class flags on its own evidence (honorific agreement,
///     Devanagari purity, dangling particles);
///   * the particle budget boundary (one occurrence passes, two flag) and
///     longest-match counting ("हुन्छ नि" is one occurrence, not two);
///   * the positional rule the spec's particles section states — a particle
///     with no clause to attach to (the reply's first token, or one following
///     only a sentence terminator) is dangling;
///   * script honesty: romanized input and letterless input degrade to
///     `unavailable` — never a false flag, never a false pass;
///   * the lexicon-load failure path: `unavailable`, never pass, never flag;
///   * the verdict carries no text and no corrected-output API exists;
///   * determinism and idempotence across repeated calls;
///   * the data tables are traceable to the spec: the embedded blocks and the
///     cited rule text equal the spec artifact byte-for-byte, and the decoded
///     tables equal the spec's own values.
///
/// The fixture strings mirror the eval's canonical fixtures
/// (tools/train-intent/tests/test_chat_golden.py) so the guard's two
/// execution sites are pinned against the same text.
final class NepaliGrammarGuardTests: XCTestCase {

    // MARK: - Entry point: a clean reply passes

    func testCleanReplyPasses() {
        XCTAssertEqual(verdict("नमस्ते हजुर। तपाईंलाई कस्तो छ?"), .pass)
        XCTAssertEqual(verdict("आज बाहिर चिसो छ हजुर।"), .pass)
        XCTAssertEqual(verdict("औषधि खानुभयो नि हजुर?"), .pass,
                       "a check-in whose single particle is attached passes")
    }

    // MARK: - Each check class flags on its own evidence

    func testFamiliarVerbFlagsHonorificAgreementOnItsOwnEvidence() {
        XCTAssertEqual(verdict("उहाँले यो कुरा भन्यो।"),
                       .flag(classes: [.honorificAgreement]),
                       "the curated banned verb list, exactly token membership")
    }

    func testForbiddenAddressFormFlagsHonorificAgreementOnItsOwnEvidence() {
        XCTAssertEqual(verdict("तिमी कहाँ छौ?"),
                       .flag(classes: [.honorificAgreement]),
                       "the तिमी-family address class")
        XCTAssertEqual(verdict("तिम्रो नाम के हो?"),
                       .flag(classes: [.honorificAgreement]))
    }

    func testAmbiguousPairTableFormsAreNotFlagged() {
        // The register section: भयो and छ stay in the pair table but out of
        // the banned list; forms outside the curated list are NOT caught.
        // The guard is a lexicon-bounded floor, and the bound is pinned here
        // so the honest limit is a documented property, not an accident.
        for form in ["भयो", "छ", "गर्छ", "खान्छ", "आउँछ", "जान्छ"] {
            XCTAssertEqual(verdict("हजुर, \(form)।"), .pass,
                           "pair-table-only form \(form) must not be flagged")
        }
    }

    func testLatinRunFlagsDevanagariPurityOnItsOwnEvidence() {
        XCTAssertEqual(verdict("तपाईंको BP ठीक छ।"),
                       .flag(classes: [.devanagariPurity]),
                       "a bare Latin run in a Nepali reply is a defect")
    }

    func testMixedScriptTokenFlagsDevanagariPurity() {
        XCTAssertEqual(verdict("तपाईंको चार्जer ठीक छ।"),
                       .flag(classes: [.devanagariPurity]),
                       "a token carrying both scripts is a defect on its own evidence")
    }

    func testTheLatinAllowlistIsSpecDataNotHardCoded() throws {
        // Same text, same guard pipeline, mutated lexicon data: the
        // allowance is the spec's list, read — not an exception list baked
        // into the check. With "BP" allowed the Latin run passes; "ECG",
        // which no allowlist admits, still flags.
        let allowed = try decodeWithRealBlocks(
            guardChecks: #"{"checks": [{"id": "devanagariPurity", "sources": []}], "latin_allowlist": ["BP"]}"#)
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "तपाईंको BP ठीक छ।",
                                                  locale: "ne",
                                                  lexicons: .success(allowed)),
                       .pass)
        XCTAssertEqual(verdict("तपाईंको ECG ठीक छ।"),
                       .flag(classes: [.devanagariPurity]),
                       "the shipped empty allowlist still flags any Latin run")
    }

    func testParticleOverBudgetFlagsDanglingParticle() {
        XCTAssertEqual(verdict("हो नि हजुर। अनि फेरि भन्नुहोस्।"),
                       .flag(classes: [.danglingParticle]),
                       "two occurrences exceed the budget of one")
    }

    func testAllThreeClassesFlagInCanonicalOrder() {
        XCTAssertEqual(verdict("ल BP भन्यो।"),
                       .flag(classes: [.honorificAgreement,
                                       .devanagariPurity,
                                       .danglingParticle]),
                       "flag carries the failing classes in GrammarCheckClass order")
    }

    // MARK: - Particle budget boundary and longest-match counting

    func testParticleBudgetBoundaryOneVersusTwo() throws {
        let spec = try styleSpecLines()
        let particles = try blockJSON("particles", in: spec)
        XCTAssertEqual(particles["budget"] as? Int, 1,
                       "the boundary is pinned against the spec's own budget")

        // One occurrence passes (the multi-word unit counts once — were it
        // counted as two, this would exceed the budget of one).
        XCTAssertEqual(verdict("हुन्छ नि हजुर।"), .pass)
        // A second, attached occurrence flags — a count failure, not a
        // positional one.
        XCTAssertEqual(verdict("हुन्छ नि हजुर। ठीक छ है।"),
                       .flag(classes: [.danglingParticle]))
        // A single attached clitic alone passes.
        XCTAssertEqual(verdict("ठीक छ है।"), .pass)
    }

    func testBudgetIsSpecDataNotHardCoded() throws {
        // Same text, same guard pipeline, mutated lexicon data: with the
        // budget raised to 2 the two-occurrence reply passes. The budget is
        // data drawn from the spec, not a constant baked into the rules.
        let two = try decodeWithRealBlocks(
            particles: #"{"budget": 2, "units": ["हुन्छ नि", "होला नि", "हो नि", "छ नि", "अनि", "है", "नि", "ला", "ल"]}"#)
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "हुन्छ नि हजुर। ठीक छ है।",
                                                  locale: "ne",
                                                  lexicons: .success(two)),
                       .pass)
        XCTAssertEqual(verdict("हुन्छ नि हजुर। ठीक छ है।"),
                       .flag(classes: [.danglingParticle]),
                       "the shipped budget of one still flags the same text")
    }

    func testMultiWordUnitAtReplyStartIsNotDangling() {
        // "हुन्छ" is a clause head; the positional rule is defined for a
        // particle with no clause to attach to. The reviewed golden replies
        // open with multi-word units and never with a bare clitic — this
        // test is the boundary that evidence pinned.
        XCTAssertEqual(verdict("हुन्छ नि हजुर, ठीक छ।"), .pass)
        XCTAssertEqual(verdict("हो नि हजुर।"), .pass)
        XCTAssertEqual(verdict("होला नि हजुर।"), .pass)
    }

    func testBareCliticAtReplyStartIsDangling() {
        // The particles section: "never open a reply with one: a particle
        // with no clause to attach to (the first token of the reply ...) is
        // dangling and reads as noise." The spec's coverage block carries
        // "ल, म बिदा हुन्छु हजुर।" as an illustrative farewell example, and
        // this guard flags it: the rule text is the contract, the example is
        // illustrative (recorded in the T-169 notes).
        XCTAssertEqual(verdict("ल, म बिदा हुन्छु हजुर।"),
                       .flag(classes: [.danglingParticle]),
                       "a bare clitic as the reply's first token is dangling")
        XCTAssertEqual(verdict("अनि फेरि भन्नुहोस्।"),
                       .flag(classes: [.danglingParticle]))
    }

    func testCliticFollowingOnlyASentenceTerminatorIsDangling() {
        // Count is 1 (within budget); the flag is positional: the clitic
        // follows only "। " — no clause to attach to.
        XCTAssertEqual(verdict("हुन्छ हजुर। ल, भोलि भेटौंला।"),
                       .flag(classes: [.danglingParticle]))
    }

    func testTheReviewedGoldenSetsOpeningParticlesFlagUnderThePositionalRule() {
        // EVIDENCE, cross-checked against the real golden set outside the
        // suite (486/490 reviewed replies pass; exactly these four flag):
        // cg-b026-06, cg-b034-02, cg-b034-09, cg-b035-10. Each carries ONE
        // particle (within budget): the flag is the spec's positional rule —
        // "never open a reply with one: a particle with no clause to attach
        // to (the first token of the reply, or one following only a sentence
        // terminator) is dangling". The golden set's own review executes the
        // count only, so this is the guard's stricter reading of the same
        // section, pinned here as a deliberate property: if the wave decides
        // the openers are intended, the SPEC's rule text changes first and
        // this pin moves with it — never a code exception.
        let goldenOpenings = [
            "भात खान मन छ? ल, म तपाईंलाई भात दिन्छु।",       // cg-b026-06
            "अनि, के भन्नुभएको थियो हजुर छोरीले?",            // cg-b034-02
            "अनि, के भयो कुरा अगाडि बढ्यो?",                 // cg-b034-09
            "अनि कहिले आउँदैछ हजुर?",                        // cg-b035-10
        ]
        for reply in goldenOpenings {
            XCTAssertEqual(verdict(reply), .flag(classes: [.danglingParticle]),
                           "the positional rule flags this opening: \(reply)")
        }
    }

    func testMultiWordUnitDoesNotSpanASentenceTerminator() {
        // "हुन्छ। नि" is NOT the "हुन्छ नि" tag: the words sit in different
        // clauses, and the "नि" follows only a sentence terminator — the
        // spec's dangling definition, applied to the later word on its own
        // position. (Were the run matched as one unit, this would pass: the
        // false pass the contiguity rule closes.)
        XCTAssertEqual(verdict("हुन्छ। नि, ठीक छ।"),
                       .flag(classes: [.danglingParticle]))
        XCTAssertEqual(verdict("ठीक छ हजुर! नि, फेरि भन्नुहोस्।"),
                       .flag(classes: [.danglingParticle]))
        // A comma is not a sentence terminator: the tag reads as one
        // attached unit and stays within the budget.
        XCTAssertEqual(verdict("हुन्छ, नि हजुर।"), .pass)
    }

    func testPartialParticleSubstringsInsideLargerWordsDoNotCount() {
        // Token equality, not substring containment: a word that merely
        // carries a particle as a prefix or inside it is not an occurrence.
        // A substring scan would count 2 on each of these and false-flag.
        XCTAssertEqual(verdict("औषधि खानुभयो नि। नियम पाल्नुभयो हजुर।"), .pass)
        XCTAssertEqual(verdict("अनिवार्य रूपमा औषधि खानुभयो नि हजुर।"), .pass)
        XCTAssertEqual(verdict("निद्रा लाग्यो हजुर।"), .pass,
                       "words opening with a particle's letters are not particles")
    }

    func testTokenizationKeepsDevanagariConjunctsWhole() {
        // The grapheme boundary the longest-match count depends on: the
        // "न्छ" conjunct stays inside "हुन्छ" (one token), "नि" is its own
        // token, and a different word ("हुन्छु", "नियम") never splits into
        // — or matches — a particle.
        XCTAssertEqual(NepaliGrammarGuard.tokenize("हुन्छ नि।").map(\.text),
                       ["हुन्छ", "नि"])
        XCTAssertEqual(NepaliGrammarGuard.tokenize("हुन्छु").map(\.text), ["हुन्छु"])
        XCTAssertEqual(NepaliGrammarGuard.tokenize("नियम, लाग्यो!").map(\.text),
                       ["नियम", "लाग्यो"])
    }

    // MARK: - Script honesty: romanized and letterless input decline

    func testRomanizedReplyDeclinesNeverFlagsNeverPasses() {
        let romanized = "Tapai kasto chha? Ma thik chhu."
        XCTAssertEqual(verdict(romanized),
                       .unavailable(reason: "inputNotDevanagari"),
                       "a romanized reply is outside the guard's competence — the P2 seam")
        XCTAssertEqual(verdict("Hello, how are you?"),
                       .unavailable(reason: "inputNotDevanagari"))
    }

    func testMixedReplyWithDevanagariIsJudged() {
        // One Devanagari letter makes the reply judgeable; its Latin runs are
        // then the purity check's evidence (never a silent pass).
        XCTAssertEqual(verdict("तपाईंको BP ठीक छ।"),
                       .flag(classes: [.devanagariPurity]))
    }

    func testLatinRunExtractionAgreesWithTheEvalRegexClass() {
        // Maximal [A-Za-z]+ runs, in order — the eval's `_LATIN_RUN_RE`
        // class, so the two execution sites see the same runs.
        XCTAssertEqual(NepaliGrammarGuard.latinRuns(in: "तपाईंको BP ठीक छ।"), ["BP"])
        XCTAssertEqual(NepaliGrammarGuard.latinRuns(in: "चार्जer र phone ठीक।"),
                       ["er", "phone"])
        XCTAssertEqual(NepaliGrammarGuard.latinRuns(in: "शुद्ध नेपाली वाक्य।"), [])
    }

    func testLetterlessInputDeclinesAsEmptyInput() {
        for text in ["", "   ", "12345 ...", "।।?!"] {
            XCTAssertEqual(verdict(text),
                           .unavailable(reason: "inputEmpty"),
                           "no letters is nothing to verify: \(text.debugDescription)")
        }
    }

    func testNonNepaliLocaleDeclines() {
        for locale in ["en", "EN-US", "fr", ""] {
            XCTAssertEqual(
                NepaliGrammarGuard.verdict(spokenText: "नमस्ते हजुर।", locale: locale),
                .unavailable(reason: "localeNotNepali"),
                "locale \(locale.debugDescription) is not a Nepali session")
        }
        for locale in ["ne", "ne-NP", "ne_NP", "NE"] {
            XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "नमस्ते हजुर।", locale: locale),
                           .pass,
                           "locale \(locale.debugDescription) is a Nepali session")
        }
    }

    // MARK: - Failure path: lexicons that fail to load

    func testLexiconLoadFailureIsUnavailableNeverPassNeverFlag() {
        let failure = NepaliGrammarGuard.LexiconLoadFailure
            .malformedJSON(block: "particles", detail: "test fixture")
        // A would-be clean reply: unavailable, not pass.
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "नमस्ते हजुर।",
                                                  locale: "ne",
                                                  lexicons: .failure(failure)),
                       .unavailable(reason: "lexiconsUnavailable"))
        // A would-be flagged reply: still unavailable — "not verified" is
        // never laundered into a verdict.
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "ल BP भन्यो।",
                                                  locale: "ne",
                                                  lexicons: .failure(failure)),
                       .unavailable(reason: "lexiconsUnavailable"))
        // The locale gate runs first: a non-Nepali session declines by locale.
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: "नमस्ते हजुर।",
                                                  locale: "en",
                                                  lexicons: .failure(failure)),
                       .unavailable(reason: "localeNotNepali"))
    }

    func testLexiconDecodeRejectsMalformedData() throws {
        // Each mutation must be a load failure — no default substitution,
        // no crash, no quiet acceptance.
        let cases: [(name: String, particles: String)] = [
            ("boolean budget", #"{"budget": true, "units": ["नि"]}"#),
            ("fractional budget", #"{"budget": 1.5, "units": ["नि"]}"#),
            ("missing units", #"{"budget": 1}"#),
            ("empty units", #"{"budget": 1, "units": []}"#),
            ("not longest-match-first", #"{"budget": 1, "units": ["छ नि", "हुन्छ नि"]}"#),
            ("not JSON", #"not json"#),
            ("top level not an object", #"["नि"]"#),
        ]
        for (name, particles) in cases {
            let result = NepaliGrammarGuard.decodeLexicons(
                registerBlock: NepaliGrammarGuard.registerBlockJSON,
                particlesBlock: particles,
                codeSwitchBlock: NepaliGrammarGuard.codeSwitchBlockJSON,
                guardChecksBlock: NepaliGrammarGuard.guardChecksBlockJSON)
            guard case .failure = result else {
                return XCTFail("\(name) must be a lexicon load failure")
            }
        }
    }

    func testLexiconDecodeRejectsMissingRegisterFieldsAndLatinRenderings() {
        let missingField = NepaliGrammarGuard.decodeLexicons(
            registerBlock: #"{"attention_marker": "हजुर", "honorific_pairs": [["भन्यो", "भन्नुभयो"]], "non_honorific_verb_forms": ["भन्यो"], "forbidden_address_forms": ["तिमी"]}"#,
            particlesBlock: NepaliGrammarGuard.particlesBlockJSON,
            codeSwitchBlock: NepaliGrammarGuard.codeSwitchBlockJSON,
            guardChecksBlock: NepaliGrammarGuard.guardChecksBlockJSON)
        guard case .failure(let failure) = missingField else {
            return XCTFail("a missing register field must be a load failure")
        }
        XCTAssertEqual(failure, .missingField(block: "register", field: "address_pronoun"))

        // The code_switch section: the renderings are Devanagari, which is
        // WHY no Latin exception list is needed. A spec that broke that
        // property degrades the guard instead of false-flagging nouns.
        let latinRendering = NepaliGrammarGuard.decodeLexicons(
            registerBlock: NepaliGrammarGuard.registerBlockJSON,
            particlesBlock: NepaliGrammarGuard.particlesBlockJSON,
            codeSwitchBlock: #"{"nouns": [{"english": "phone", "spoken": "phone"}], "mirror_user_register": true}"#,
            guardChecksBlock: NepaliGrammarGuard.guardChecksBlockJSON)
        guard case .failure = latinRendering else {
            return XCTFail("a Latin code-switch rendering must be a load failure")
        }
    }

    // MARK: - The verdict is the only output: no text, no rewrite path

    func testVerdictIsAClosedClassificationCarryingNoText() {
        for text in probeCorpus {
            let classification = classification(of: verdict(text))
            XCTAssertTrue(classification.unicodeScalars.allSatisfy { $0.isASCII },
                          "no verdict shape may carry content: \(classification)")
        }
    }

    func testEveryObservedUnavailableReasonIsAClosedSetMember() {
        // The exhaustive switch in `classification(of:)` is the compile-time
        // pin (a new case breaks the build); these observable checks pin the
        // contract at run time.
        XCTAssertEqual(Set(GrammarGuardUnavailableReason.allCases.map(\.rawValue)),
                       ["localeNotNepali", "lexiconsUnavailable",
                        "inputNotDevanagari", "inputEmpty"],
                       "the unavailable reasons are the closed design §7.4 set")
        XCTAssertEqual(GrammarCheckClass.allCases.map(\.rawValue),
                       ["honorificAgreement", "devanagariPurity", "danglingParticle"],
                       "the check classes are the closed design §7.2 set")
    }

    func testNoRewriteOrCorrectionEntryPointExists() throws {
        // The structural proof is `testVerdictIsAClosedClassificationCarryingNoText`
        // plus the exhaustive switch in `classification(of:)`: the verdict
        // has no text payload, and no code path can return a corrected word
        // through it. This scan is the API-surface tripwire beside it — a
        // declaration that names a rewrite/correction/substitution/
        // truncation entry point would be a new code road, and none exists.
        // Scoped to declarations: legitimate calls like the locale's
        // `.replacingOccurrences(of: "_", with: "-")` are not entry points.
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift")
        let code = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(code.isEmpty, "the scan must read the guard source")
        let names = "(?:rewrite|correct|substitut|replac|sanitiz|truncat|repair)"
        let declaration = "(?i)(?:func|var|let|case)\\s+\\w*(?:\(names))\\w*"
        XCTAssertNil(FeatureSourceScan.firstMatch(of: declaration, in: code),
                     "no rewrite/correction road may exist in the guard")
    }

    func testGuardSourceCarriesNoConsoleWriteNoIOAndNoNondeterminism() throws {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift")
        let code = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(code.isEmpty, "the scan must read the guard source")
        let forbidden = ["print(", "debugPrint(", "NSLog(", "os_log(", "fputs(", "dump(",
                         "FileManager", "contentsOf", "write(to:", "URLSession",
                         "Date(", "Random", "arc4random", "async", "await"]
        for token in forbidden {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: NSRegularExpression.escapedPattern(for: token),
                                                      in: code),
                         "the guard must write nothing and read nothing (\(token))")
        }
    }

    // MARK: - Determinism and idempotence

    func testDeterministicAndIdempotentAcrossRepeatedCalls() throws {
        for text in probeCorpus {
            let first = verdict(text)
            XCTAssertEqual(verdict(text), first, "repeated calls must agree: \(text)")
            XCTAssertEqual(verdict(text), first)
        }
        // A flagged case and an unavailable case, three runs each.
        for _ in 0..<3 {
            XCTAssertEqual(verdict("उहाँले यो कुरा भन्यो।"),
                           .flag(classes: [.honorificAgreement]))
            XCTAssertEqual(verdict("Tapai kasto chha?"),
                           .unavailable(reason: "inputNotDevanagari"))
        }
    }

    func testTheCompiledTablesAreAReproducibleFunctionOfTheSpecBytes() {
        // No in-process cache stands between the spec bytes and the verdict:
        // recompiling from the same embedded bytes yields the identical
        // tables, so a fresh process decodes the same guard (NFR-CNR-001's
        // cross-session stability, as far as an in-process test can see it).
        XCTAssertEqual(NepaliGrammarGuard.compiledLexicons,
                       NepaliGrammarGuard.decodeLexicons(
                           registerBlock: NepaliGrammarGuard.registerBlockJSON,
                           particlesBlock: NepaliGrammarGuard.particlesBlockJSON,
                           codeSwitchBlock: NepaliGrammarGuard.codeSwitchBlockJSON,
                           guardChecksBlock: NepaliGrammarGuard.guardChecksBlockJSON))
    }

    // MARK: - Spec traceability (the T-170 drift-check seam)

    func testEmbeddedBlocksEqualTheSpecBlocksByteForByte() throws {
        let spec = try styleSpecLines()
        XCTAssertEqual(NepaliGrammarGuard.registerBlockJSON, try blockBody("register", in: spec))
        XCTAssertEqual(NepaliGrammarGuard.particlesBlockJSON, try blockBody("particles", in: spec))
        XCTAssertEqual(NepaliGrammarGuard.codeSwitchBlockJSON, try blockBody("code_switch", in: spec))
        XCTAssertEqual(NepaliGrammarGuard.guardChecksBlockJSON, try blockBody("guard_checks", in: spec))
    }

    func testCitationMarkersCarryTheSpecRuleTextByteForByte() throws {
        // The in-repo equivalent of `style_spec.py --check-consumers`: every
        // cited section is byte-identical to the spec, comment prefix and at
        // most one space stripped, exactly as the loader normalizes.
        let spec = try styleSpecLines()
        let sourceURL = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift")
        let lines = try String(contentsOf: sourceURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for section in ["register", "particles", "code_switch", "guard_checks"] {
            let start = try XCTUnwrap(
                lines.firstIndex { $0.contains("@style-spec-section: \(section)") },
                "the \(section) citation marker is missing")
            let end = try XCTUnwrap(
                lines[(start + 1)...].firstIndex {
                    $0.contains("@style-spec-section-end: \(section)")
                },
                "the \(section) end marker is missing")
            let cited = lines[(start + 1)..<end].map { line -> String in
                var text = line
                if let range = text.range(of: "///") {
                    text = String(text[range.upperBound...])
                    if text.hasPrefix(" ") { text.removeFirst() }
                }
                return text
            }.joined(separator: "\n")
            XCTAssertEqual(cited, try sectionText(section, in: spec),
                           "the \(section) citation must equal the spec section byte-for-byte")
        }
    }

    func testCompiledTablesEqualTheSpecsOwnValues() throws {
        let spec = try styleSpecLines()
        guard case .success(let tables) = NepaliGrammarGuard.compiledLexicons else {
            return XCTFail("the embedded spec blocks must compile")
        }
        let register = try blockJSON("register", in: spec)
        let particles = try blockJSON("particles", in: spec)
        let guardChecks = try blockJSON("guard_checks", in: spec)
        let codeSwitch = try blockJSON("code_switch", in: spec)

        XCTAssertEqual(tables.addressPronoun, register["address_pronoun"] as? String)
        XCTAssertEqual(tables.attentionMarker, register["attention_marker"] as? String)
        XCTAssertEqual(tables.forbiddenAddressForms, register["forbidden_address_forms"] as? [String])
        XCTAssertEqual(tables.nonHonorificVerbForms, register["non_honorific_verb_forms"] as? [String])
        let pairs = try XCTUnwrap(register["honorific_pairs"] as? [[String]])
        XCTAssertEqual(tables.honorificPartners,
                       Dictionary(uniqueKeysWithValues: pairs.map { ($0[0], $0[1]) }))

        XCTAssertEqual(tables.particleBudget, particles["budget"] as? Int)
        XCTAssertEqual(tables.particleUnits, particles["units"] as? [String])

        XCTAssertEqual(tables.latinAllowlist, guardChecks["latin_allowlist"] as? [String])
        XCTAssertEqual(tables.latinAllowlist, [], "empty by the spec, and never omitted")

        let nouns = try XCTUnwrap(codeSwitch["nouns"] as? [[String: String]])
        XCTAssertEqual(tables.codeSwitchNouns.map(\.english),
                       nouns.compactMap { $0["english"] },
                       "every rendering's English name comes from the spec")
        XCTAssertEqual(tables.codeSwitchNouns.map(\.spoken),
                       nouns.compactMap { $0["spoken"] },
                       "every Devanagari rendering comes from the spec")
    }

    func testCheckInventoryMatchesTheSpecsGuardChecksBlock() throws {
        let spec = try styleSpecLines()
        let guardChecks = try blockJSON("guard_checks", in: spec)
        let checks = try XCTUnwrap(guardChecks["checks"] as? [[String: Any]])
        XCTAssertEqual(GrammarCheckClass.allCases.map(\.rawValue),
                       checks.compactMap { $0["id"] as? String },
                       "the guard's check inventory IS the spec's inventory, in order")
    }

    func testHonorificPartnersBackEveryBannedFormInTheShippedSpec() throws {
        // The register section: the banned list is "familiar past-tense forms
        // whose subject could only be the elder", each with an honorific
        // partner in the pair table. On the shipped spec the two sets align —
        // pinned here as a data property (the executable rule is the banned
        // list plus the address class, exactly as the eval checks it).
        guard case .success(let tables) = NepaliGrammarGuard.compiledLexicons else {
            return XCTFail("the embedded spec blocks must compile")
        }
        for form in tables.nonHonorificVerbForms {
            XCTAssertNotNil(tables.honorificPartners[form],
                            "banned form \(form) has an honorific partner")
        }
        XCTAssertFalse(tables.nonHonorificVerbForms.contains("भयो"),
                       "the ambiguous forms stay out of the banned list")
        XCTAssertFalse(tables.nonHonorificVerbForms.contains("छ"))
    }

    // MARK: - Fixtures and helpers

    /// Texts exercising every verdict shape; used for determinism and the
    /// no-text-surface pins. Mirrors the eval's canonical fixtures.
    private let probeCorpus: [String] = [
        "नमस्ते हजुर। तपाईंलाई कस्तो छ?",
        "उहाँले यो कुरा भन्यो।",
        "तिमी कहाँ छौ?",
        "तपाईंको BP ठीक छ।",
        "हुन्छ नि हजुर।",
        "हो नि हजुर। अनि फेरि भन्नुहोस्।",
        "ल, म बिदा हुन्छु हजुर।",
        "Tapai kasto chha?",
        "",
        "12345 ...",
    ]

    private func verdict(_ text: String, locale: String = "ne") -> GrammarGuardVerdict {
        NepaliGrammarGuard.verdict(spokenText: text, locale: locale)
    }

    /// Maps a verdict to its classification string, asserting the closed-set
    /// invariants on the way. The switch is exhaustive by design: a new
    /// verdict case fails to compile here, and message checks use this
    /// helper so no test can pass against a shape the contract forbids.
    private func classification(of verdict: GrammarGuardVerdict) -> String {
        switch verdict {
        case .pass:
            return "pass"
        case .flag(let classes):
            XCTAssertFalse(classes.isEmpty, "a flag carries at least one class")
            XCTAssertEqual(Set(classes).count, classes.count, "no duplicate classes")
            for checkClass in classes {
                XCTAssertTrue(GrammarCheckClass.allCases.contains(checkClass))
            }
            XCTAssertEqual(classes,
                           GrammarCheckClass.allCases.filter { classes.contains($0) },
                           "classes are in the canonical GrammarCheckClass order")
            return "flag:" + classes.map(\.rawValue).joined(separator: ",")
        case .unavailable(let reason):
            XCTAssertTrue(GrammarGuardUnavailableReason.allCases.map(\.rawValue).contains(reason),
                          "unavailable carries a closed-set reason, never free text: \(reason)")
            return "unavailable:" + reason
        }
    }

    private func decodeWithRealBlocks(
        particles: String = NepaliGrammarGuard.particlesBlockJSON,
        guardChecks: String = NepaliGrammarGuard.guardChecksBlockJSON
    ) throws -> NepaliGrammarGuard.Lexicons {
        let result = NepaliGrammarGuard.decodeLexicons(
            registerBlock: NepaliGrammarGuard.registerBlockJSON,
            particlesBlock: particles,
            codeSwitchBlock: NepaliGrammarGuard.codeSwitchBlockJSON,
            guardChecksBlock: guardChecks)
        guard case .success(let lexicons) = result else {
            throw NSError(domain: "NepaliGrammarGuardTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture lexicons failed to compile",
            ])
        }
        return lexicons
    }

    private func styleSpecURL(file: StaticString = #filePath) -> URL {
        FeatureSourceScan.iosDirectory(file: file)
            .deletingLastPathComponent()
            .appendingPathComponent("tools/train-intent/seeds/nepali-chat-style-spec")
    }

    private func styleSpecLines(file: StaticString = #filePath) throws -> [String] {
        let url = styleSpecURL(file: file)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The spec's fenced block body, exactly as the loader slices it.
    private func blockBody(_ name: String, in lines: [String]) throws -> String {
        let start = try XCTUnwrap(lines.firstIndex(of: "```json " + name),
                                  "no fenced block \(name) in the spec")
        let close = try XCTUnwrap(lines[(start + 1)...].firstIndex(of: "```"),
                                  "block \(name) is never closed")
        return lines[(start + 1)..<close].joined(separator: "\n")
    }

    private func blockJSON(_ name: String, in lines: [String]) throws -> [String: Any] {
        let body = try blockBody(name, in: lines)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return try XCTUnwrap(object as? [String: Any], "block \(name) is not an object")
    }

    /// The section's rule text, resolved the way the loader does: prose lines
    /// only (fenced blocks excluded), joined with newlines and stripped of
    /// leading/trailing newlines.
    private func sectionText(_ name: String, in lines: [String]) throws -> String {
        let start = try XCTUnwrap(lines.firstIndex(of: "## section: " + name),
                                  "no section \(name) in the spec")
        var prose: [String] = []
        var inFence = false
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## section:") { break }
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            prose.append(line)
        }
        var text = prose.joined(separator: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
