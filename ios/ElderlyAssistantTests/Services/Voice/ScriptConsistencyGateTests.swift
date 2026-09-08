import XCTest
@testable import ElderlyAssistant

/// [SCRIPT-REGRESSION] Script-consistency gate for dialect decode
/// biasing.
///
/// The regression: after commit 30bf919 (accent-adaptation decode
/// biasing) merged, Nepali ASR transcripts regressed from Devanagari to
/// roman-script. Mechanism: `DialectBiasComposer` fed the decoder prompt
/// with roman-script profile terms (contact names straight from the
/// address book, app names like "WhatsApp", medication names) — as
/// `DecodingOptions.promptTokens` (WhisperKit) and `initial_prompt`
/// (whisper.cpp). Whisper conditions generation on the prompt, so a
/// roman-heavy prompt pulls Nepali output into roman script.
///
/// The fix, pinned here:
/// 1. Only Devanagari-script terms may enter the prompt
///    (`isDevanagariTerm` gate in `DialectBiasComposer.sanitizedTerms`;
///    roman terms are dropped, not transliterated — they lose lexical
///    biasing honestly until a transliteration layer exists).
/// 2. Both recognizers force Nepali ("ne") while a bias plan is active,
///    so the decoder stays in Nepali-language mode: WhisperKit
///    `decodeLanguageCode` / whisper.cpp `decodeAdaptation` (which also
///    refuses a roman-only prompt as defence in depth).
final class ScriptConsistencyGateTests: XCTestCase {

    // MARK: - Fixtures

    private func makePlan(state: DialectBiasPlan.State = .active,
                          promptText: String?,
                          calibratedTokenIds: [Int] = []) -> DialectBiasPlan {
        DialectBiasPlan(state: state,
                        label: .doteli,
                        promptText: promptText,
                        calibratedTokenIds: calibratedTokenIds,
                        lexiconPhraseCount: promptText == nil ? 0 : 1,
                        contactCount: 0,
                        medicationCount: 0,
                        appCount: 0)
    }

    private func makeProfile(contacts: [String] = [],
                             medications: [String] = [],
                             apps: [String] = []) -> DialectBiasProfile {
        var profile = DialectBiasProfile()
        profile.contactNames = contacts
        profile.medicationNames = medications
        profile.appNames = apps
        return profile
    }

    // MARK: - isDevanagariTerm unit tests

    func testPureDevanagariTermAccepted() {
        for term in ["सीता", "भइछ", "रह्याको", "ख", "राम बहादुर"] {
            XCTAssertTrue(DialectBiasComposer.isDevanagariTerm(term),
                          "pure Devanagari must pass: \(term)")
        }
    }

    func testNepaliDigitsAccepted() {
        // U+0966–U+096F are inside the Devanagari block and legal in
        // profile terms (e.g. "औषधि२" transcriptions).
        for term in ["औषधि१२३", "सन्२०८०", "नम्बर६"] {
            XCTAssertTrue(DialectBiasComposer.isDevanagariTerm(term),
                          "Nepali digits must pass: \(term)")
        }
    }

    func testLatinTermRejected() {
        for term in ["Sita", "WhatsApp", "Metformin", "Ram Bahadur"] {
            XCTAssertFalse(DialectBiasComposer.isDevanagariTerm(term),
                           "Latin-script term must be rejected: \(term)")
        }
    }

    func testMixedScriptTermRejected() {
        // The regression's exact failure shape: Nepanglish names and
        // half-transliterated spellings. Any Latin character poisons the
        // term — the gate is all-or-nothing, never a cleanup.
        for term in ["Sita सीता", "सीताSita", "व्हाट्सएप2", "डा. शर्मा"] {
            XCTAssertFalse(DialectBiasComposer.isDevanagariTerm(term),
                           "mixed-script term must be rejected: \(term)")
        }
    }

    func testEmptyAndWhitespaceRejected() {
        for term in ["", " ", "  ", "\t", "\n", " \t\n "] {
            XCTAssertFalse(DialectBiasComposer.isDevanagariTerm(term),
                           "empty/whitespace must be rejected: \(String(reflecting: term))")
        }
    }

    func testLatinDigitsRejected() {
        // ASCII digits are outside U+0900–U+097F — only Nepali digits
        // (U+0966+) are legal in a Devanagari term.
        XCTAssertFalse(DialectBiasComposer.isDevanagariTerm("123"))
    }

    func testContainsDevanagariTerm() {
        XCTAssertTrue(DialectBiasComposer.containsDevanagariTerm("भया रह्याको"))
        XCTAssertTrue(DialectBiasComposer.containsDevanagariTerm(
            "डोटेली भाषा, सुदूरपश्चिम नेपाल"),
            "tag-line punctuation must not hide the Devanagari words")
        XCTAssertFalse(DialectBiasComposer.containsDevanagariTerm("Sita WhatsApp"))
        XCTAssertFalse(DialectBiasComposer.containsDevanagariTerm(""))
        XCTAssertFalse(DialectBiasComposer.containsDevanagariTerm("   "))
    }

    // MARK: - Composer gate

    func testRomanContactsDroppedDevanagariMedicationsKept() {
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: nil,
            lexicon: nil,
            profile: makeProfile(contacts: ["Sita", "Ram"],
                                 medications: ["मेटफर्मिन"]),
            enabled: true)
        XCTAssertEqual(plan.state, .active)
        XCTAssertEqual(plan.promptText, "मेटफर्मिन",
                       "ONLY Devanagari terms may enter the prompt")
        XCTAssertEqual(plan.contactCount, 0, "roman contacts are dropped")
        XCTAssertEqual(plan.medicationCount, 1)
    }

    func testAllRomanProfileLeavesOnlyLexiconMaterial() {
        let lexicon = DialectLexicon(
            formatVersion: 1,
            generation: DialectLexicon.Generation(status: "SEED-LEXICON",
                                                  path: "test",
                                                  date: nil),
            entries: [DialectLexicon.Entry(dialect: "doteli",
                                           tagLine: "डोटेली भाषा",
                                           phrases: ["भया"])])
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: nil,
            lexicon: lexicon,
            profile: makeProfile(contacts: ["Sita"],
                                 medications: ["Metformin"],
                                 apps: ["WhatsApp"]),
            enabled: true)
        XCTAssertEqual(plan.state, .active, "lexicon material still biases")
        XCTAssertEqual(plan.promptText, "भया डोटेली भाषा",
                       "no material from the roman profile sources")
        XCTAssertEqual(plan.contactCount, 0)
        XCTAssertEqual(plan.medicationCount, 0)
        XCTAssertEqual(plan.appCount, 0)
        XCTAssertEqual(plan.lexiconPhraseCount, 1)
    }

    func testAllRomanProfileWithNoLexiconFiresNoMaterial() {
        // Nothing Devanagari remains: the honest noMaterial path fires
        // instead of a guess — the recognizers then apply NOTHING.
        let plan = DialectBiasComposer.plan(
            label: .doteli,
            table: nil,
            lexicon: nil,
            profile: makeProfile(contacts: ["Sita"],
                                 medications: ["Metformin"],
                                 apps: ["WhatsApp", "Viber"]),
            enabled: true)
        XCTAssertEqual(plan.state, .noMaterial)
        XCTAssertNil(plan.promptText)
        XCTAssertTrue(plan.hasNoMaterial)
    }

    /// REGRESSION PIN [SCRIPT-REGRESSION] — commit 30bf919 made Nepali
    /// transcripts regress from Devanagari to roman-script: the composed
    /// bias prompt carried roman-script profile names ("Sita",
    /// "WhatsApp"), biasing the whisper decoder toward roman-script
    /// output. With the gate, a roman-only profile contributes NOTHING to
    /// the prompt — the plan biases with Devanagari material only, or
    /// honestly applies nothing.
    func testRomanOnlyProfileProducesNoBiasPrompt() {
        let romanProfile = makeProfile(contacts: ["Sita", "Ram Bahadur"],
                                       medications: ["Metformin"],
                                       apps: ["WhatsApp", "Viber"])
        // (a) With lexicon material: the plan stays active on lexicon
        // material only — not a single roman character in the prompt.
        let withLexicon = DialectBiasComposer.plan(
            label: .doteli,
            table: nil,
            lexicon: makeLexicon(),
            profile: romanProfile,
            enabled: true)
        XCTAssertEqual(withLexicon.state, .active)
        let text = try! XCTUnwrap(withLexicon.promptText)
        XCTAssertEqual(text, "भया रह्याको डोटेली भाषा, सुदूरपश्चिम नेपाल")
        for roman in ["Sita", "Ram Bahadur", "Metformin", "WhatsApp", "Viber"] {
            XCTAssertFalse(text.contains(roman),
                           "roman term '\(roman)' must never reach the prompt")
        }
        XCTAssertEqual(withLexicon.contactCount, 0)
        XCTAssertEqual(withLexicon.medicationCount, 0)
        XCTAssertEqual(withLexicon.appCount, 0)
        // (b) No lexicon and no calibrated ids: nothing Devanagari
        // remains — the honest noMaterial path fires.
        let noLexicon = DialectBiasComposer.plan(
            label: .doteli,
            table: nil,
            lexicon: nil,
            profile: romanProfile,
            enabled: true)
        XCTAssertEqual(noLexicon.state, .noMaterial)
        XCTAssertNil(noLexicon.promptText)
        XCTAssertTrue(noLexicon.hasNoMaterial)
    }

    private func makeLexicon() -> DialectLexicon {
        DialectLexicon(
            formatVersion: 1,
            generation: DialectLexicon.Generation(status: "SEED-LEXICON",
                                                  path: "test",
                                                  date: nil),
            entries: [DialectLexicon.Entry(dialect: "doteli",
                                           tagLine: "डोटेली भाषा, सुदूरपश्चिम नेपाल",
                                           phrases: ["भया", "रह्याको"])])
    }

    // MARK: - WhisperKit seam (static, no model)

    func testPromptTokensNeverEmitForRomanOnlyPromptText() {
        // Defence in depth at the recognizer seam: even a hand-built plan
        // bypassing the composer must not bias the decoder with roman
        // text. Placeholder tokenizer (like the seam tests in
        // DialectBiasComposerTests) — it must never even be called.
        let plan = makePlan(promptText: "Sita WhatsApp")
        var tokenizerCalls = 0
        XCTAssertEqual(WhisperKitSpeechRecognizer.promptTokens(
            for: plan,
            tokenizer: { _ in tokenizerCalls += 1; return [1, 2, 3] }),
            .notApplied("non_devanagari_prompt"))
        XCTAssertEqual(tokenizerCalls, 0)
    }

    func testPromptTokensRomanOnlyFallsBackToCalibratedIds() {
        // Calibrated ids come from the server-verified centroid table —
        // they stay legitimate even when the text prompt is roman-only.
        let plan = makePlan(promptText: "Sita WhatsApp",
                            calibratedTokenIds: [500])
        XCTAssertEqual(WhisperKitSpeechRecognizer.promptTokens(
            for: plan,
            tokenizer: { _ in [1, 2, 3] }),
            .applied([500]))
    }

    func testPromptTokensDevanagariPromptStillTokenizes() {
        let plan = makePlan(promptText: "भया रह्याको")
        switch WhisperKitSpeechRecognizer.promptTokens(
            for: plan,
            tokenizer: { text in text.split(separator: " ").count > 0 ? [9] : [] }) {
        case .applied(let tokens):
            XCTAssertEqual(tokens, [9])
        case .notApplied(let reason):
            XCTFail("expected applied, got \(reason)")
        }
    }

    func testWhisperKitLanguageForcedNepaliExactlyWhenPlanActive() {
        // While a plan is active the decoder MUST run language "ne" —
        // together with the prompt gate this keeps transcripts Devanagari.
        XCTAssertEqual(WhisperKitSpeechRecognizer.decodeLanguageCode(
            biasPlanState: .active), "ne")
        // Inactive states keep the pre-existing unconditional "ne" force
        // byte-identically (auto-detect on short utterances produced
        // English output before this recognizer shipped).
        for state in [DialectBiasPlan.State.disabledByUser,
                      .defaultLabel,
                      .noMaterial] {
            XCTAssertEqual(WhisperKitSpeechRecognizer.decodeLanguageCode(
                biasPlanState: state), "ne",
                "inactive behavior must be preserved for \(state)")
        }
    }

    // MARK: - whisper.cpp seam

    // The whisper.cpp half (language force + prompt refusal via
    // `WhisperSpeechRecognizer.decodeAdaptation`) is pinned in
    // WhisperSpeechRecognizerTests — the suite that owns that
    // recognizer's static seams.
}
