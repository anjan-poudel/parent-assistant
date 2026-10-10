import XCTest
@testable import ElderlyAssistant

/// [MTC] (2026-10-10, T-130) The keyword rule's provenance surface —
/// the readings the dialogue feature consumes, split out from the
/// keyword table's own suite so the byte-parity corpus stays where it
/// always lived.
///
/// Three readings live here:
///  - the extractor's provenance, one test per fallback step
///    (design-l2 §13a; FR-MTC-002);
///  - the capture vectors' provenance readings (design-l2 §22 `V1`–`V14`):
///    one named test per vector, pinning THIS unit's contribution to the
///    vector — the keyword reading, the extractor provenance, the
///    scaffold/marker split, the near-match set. The classifier outcome
///    each vector asserts belongs to `DialogueAnswerPathTests` (T-131)
///    and is deliberately not duplicated here;
///  - the bounded near-match reading's boundary rows (design-l2 §13b).
final class KeywordIntentRuleProvenanceTests: XCTestCase {

    // MARK: - One provenance test per fallback step (design-l2 §13a)

    /// Step 1 — tokens survive the drop sets: `.content`, the only
    /// non-degenerate provenance.
    func testProvenanceStepContent() {
        let cases: [(String, String)] = [
            ("रामायणको भजन लगाइदेऊ", "रामायणको"),
            ("पुरानो हिन्दी गीत बजाऊ", "पुरानो हिन्दी"),
            ("old hindi song play", "old hindi"),
            ("दशैं दुर्गा भजन बजाऊ", "दशैं दुर्गा")
        ]
        for (utterance, query) in cases {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: utterance)
            XCTAssertEqual(outcome.provenance, .content, "\(utterance)")
            XCTAssertEqual(outcome.query, query, "\(utterance)")
            XCTAssertFalse(outcome.isDegenerate, "\(utterance) names its own query")
        }
    }

    /// Step 2 — every token is scaffolding, and the FIRST marker token
    /// is chosen: `.markerFallback`, degenerate, query = the bare
    /// marker (the never-empty fallback of design L2-D10).
    func testProvenanceStepMarkerFallback() {
        let cases: [(String, String)] = [
            ("भजन बजाऊ", "भजन"),
            ("गीत चलाऊ", "गीत"),
            ("गीत भजन बजाऊ", "गीत"),
            ("play a song", "song"),
            ("स्पोटिफाइमा गीत चलाऊ", "गीत")
        ]
        for (utterance, query) in cases {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: utterance)
            XCTAssertEqual(outcome.provenance, .markerFallback, "\(utterance)")
            XCTAssertEqual(outcome.query, query,
                           "\(utterance): the first marker token stands in")
            XCTAssertTrue(outcome.isDegenerate,
                          "\(utterance): a bare marker is not a search request")
        }
    }

    /// Step 3 — every token is scaffolding and NO marker token exists:
    /// `.transcriptFallback` with the raw transcript's tokens as the
    /// stand-in query — the shipped L2-D10 shape ("चलाऊ" → "चलाऊ"),
    /// degenerate because the stand-in is framing, not a query.
    func testProvenanceStepTranscriptFallback() {
        let cases: [(String, String)] = [
            ("चलाऊ", "चलाऊ"),
            ("कृपया बजाऊ", "कृपया बजाऊ"),
            ("play", "play")
        ]
        for (utterance, query) in cases {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: utterance)
            XCTAssertEqual(outcome.provenance, .transcriptFallback, "\(utterance)")
            XCTAssertEqual(outcome.query, query,
                           "\(utterance): the raw transcript's tokens stand in")
            XCTAssertTrue(outcome.isDegenerate, "\(utterance)")
        }
    }

    /// The canonical-empty input is step 3 with no tokens at all:
    /// `.transcriptFallback` and `query == nil` — the one case where
    /// the query is genuinely absent.
    func testProvenanceStepCanonicalEmpty() {
        for empty in ["", "   ", "\n", "। ॥", " ।  ॥ "] {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: empty)
            XCTAssertEqual(outcome.provenance, .transcriptFallback, "\"\(empty)\"")
            XCTAssertNil(outcome.query, "\"\(empty)\"")
            XCTAssertTrue(outcome.isDegenerate, "\"\(empty)\"")
        }
    }

    /// The `isDegenerate` truth table (design-l2 §23): only `.content`
    /// WITH a query is a real search; everything else probes.
    func testDegenerateFlagTruthTable() {
        let cases: [(String, Bool)] = [
            ("रामायणको भजन लगाइदेऊ", false),
            ("भजन बजाऊ", true),
            ("चलाऊ", true),
            ("", true)
        ]
        for (utterance, degenerate) in cases {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: utterance)
            XCTAssertEqual(outcome.isDegenerate, degenerate, "\"\(utterance)\"")
            XCTAssertEqual(outcome.isDegenerate,
                           outcome.provenance != .content || outcome.query == nil,
                           "\"\(utterance)\": the pinned isDegenerate expression")
        }
    }

    // MARK: - Capture-vector provenance readings (design-l2 §22, V1–V14)
    //
    // Each vector below is the classifier's input/outcome pair. The
    // test pins what the KEYWORD RULE contributes to that vector — the
    // keyword reading, the extractor provenance, the scaffold/marker
    // split or the near-match set. The classifier assertion itself is
    // `DialogueAnswerPathTests`' (T-131).

    /// `V1` — slotFill; "पहिलो" ⇒ `.answer("shiva bhajan", .indexWord,
    /// .catalog)`. This unit contributes nothing: an index word is not
    /// keyword vocabulary and derives no near-match.
    func testVectorV1IndexWordProducesNoKeywordReading() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "पहिलो"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "पहिलो").isEmpty)
    }

    /// `V2` — slotFill; "दुर्गा" ⇒ `.answer("durga bhajan", .optionName,
    /// .catalog)`. The catalog alias is not keyword vocabulary, and it
    /// derives no near-match: the option-name capture is the answer
    /// path's own table.
    func testVectorV2OptionNameProducesNoKeywordReading() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "दुर्गा"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "दुर्गा").isEmpty)
    }

    /// `V3` — slotFill; "दुर्गा भजन बजाऊ" ⇒ `.answer("durga bhajan",
    /// .repetition, .catalog)`. This unit supplies the repetition
    /// split: the scaffold strip keeps the marker, the marker-dropped
    /// variant is exactly the दुर्गा alias; the request itself is a
    /// content query, and the fully-matched music rule yields no
    /// near-match.
    func testVectorV3RepetitionScaffoldThenMarkerSplit() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "दुर्गा भजन बजाऊ")?.domain, .music)
        let tokens = "दुर्गा भजन बजाऊ".split(separator: " ").map(String.init)
        let scaffoldStripped = tokens.filter { !KeywordIntentRule.isMusicScaffoldToken($0) }
        XCTAssertEqual(scaffoldStripped, ["दुर्गा", "भजन"])
        XCTAssertEqual(scaffoldStripped.filter { !KeywordIntentRule.isMusicMarkerToken($0) },
                       ["दुर्गा"], "the marker-dropped variant is the alias the capture matches")
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "दुर्गा भजन बजाऊ")
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertEqual(outcome.query, "दुर्गा")
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "दुर्गा भजन बजाऊ").isEmpty)
    }

    /// `V4` — slotFill; "दशैं दुर्गा भजन" ⇒ `.answer("दशैं दुर्गा भजन",
    /// .freeText, .freeText)` (markers kept). The keyword table claims
    /// nothing (no verb), the scaffold strip is the identity — so the
    /// marker survives into the free-text value — and the music family
    /// reads as a partial near-match.
    func testVectorV4FreeTextKeepsMarkersAndReportsTheMusicNearMatch() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "दशैं दुर्गा भजन"))
        let tokens = "दशैं दुर्गा भजन".split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.filter { !KeywordIntentRule.isMusicScaffoldToken($0) }, tokens,
                       "no scaffold token — markers are kept in the free-text fallback")
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "दशैं दुर्गा भजन"), [
            KeywordIntentRule.NearMatch(domain: .music, matchedKeys: ["भजन"], appID: nil)
        ])
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "दशैं दुर्गा भजन")
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertEqual(outcome.query, "दशैं दुर्गा")
    }

    /// `V5` — slotFill; "गीत चलाऊ" ⇒ `.invalid(.degenerateAnswer)`
    /// (marker-only survives). This unit's marker-only reading: the
    /// music rule fires, the extraction is the bare marker fallback and
    /// the degenerate flag is set.
    func testVectorV5MarkerOnlyIsDegenerate() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "गीत चलाऊ")?.domain, .music)
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "गीत चलाऊ")
        XCTAssertEqual(outcome.provenance, .markerFallback)
        XCTAssertEqual(outcome.query, "गीत")
        XCTAssertTrue(outcome.isDegenerate)
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "गीत चलाऊ").isEmpty,
                      "the fully-matched music rule is not a near-match")
    }

    /// `V6` — slotFill; "कस्तो भजन" ⇒ `.invalid(.degenerateAnswer)`
    /// (probe-echo + marker). This unit supplies the marker half: भजन
    /// is a marker token and "कस्तो" is NOT its scaffold — the
    /// probe-echo vocabulary is the answer path's own layer (T-131),
    /// and the extractor therefore still sees "कस्तो" as content.
    func testVectorV6ProbeEchoIsNotAScaffoldToken() {
        XCTAssertTrue(KeywordIntentRule.isMusicMarkerToken("भजन"))
        XCTAssertFalse(KeywordIntentRule.isMusicScaffoldToken("कस्तो"),
                       "probe-echo words are the answer vocabulary's, not the drop sets'")
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "कस्तो भजन")
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertEqual(outcome.query, "कस्तो")
    }

    /// `V7` — slotFill(defaultQuery "भजन"); "जे पनि बजाऊ" ⇒
    /// `.answer("भजन", .optionName, .defaultQuery)`. This unit claims
    /// nothing: the any-play label fires no rule and no near-match — the
    /// default-query resolution is the answer vocabulary's (T-131).
    func testVectorV7AnyPlayProducesNoNearMatch() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "जे पनि बजाऊ"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "जे पनि बजाऊ").isEmpty,
                      "the any-play label must never seed a candidate probe")
        XCTAssertTrue(KeywordIntentRule.isMusicScaffoldToken("बजाऊ"))
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "जे पनि बजाऊ")
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertEqual(outcome.query, "जे पनि")
    }

    /// `V8` — slotFill; "फेरि भन्छु" ⇒ `.escape`. The escape phrase is
    /// the answer vocabulary's (T-131); this unit claims nothing and
    /// derives no near-match from it.
    func testVectorV8EscapePhraseClaimsNothing() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "फेरि भन्छु"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "फेरि भन्छु").isEmpty)
    }

    /// `V9` — any frame; "होइन" ⇒ `.cancel`. The cancel token is the
    /// answer vocabulary's; the keyword rule reads nothing from it.
    func testVectorV9CancelWordClaimsNothing() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "होइन"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "होइन").isEmpty)
    }

    /// `V10` — slotFill; "होइन, दुर्गा भजन" ⇒ the amendment's remainder
    /// resolves as `V3`'s repetition. This unit's reading of the whole
    /// utterance: no rule fires, the music family partially matches, and
    /// the scaffold/marker split treats "होइन" as content.
    func testVectorV10AmendmentKeepsTheRepetitionSplit() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "होइन, दुर्गा भजन"))
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "होइन, दुर्गा भजन"), [
            KeywordIntentRule.NearMatch(domain: .music, matchedKeys: ["भजन"], appID: nil)
        ])
        XCTAssertFalse(KeywordIntentRule.isMusicScaffoldToken("होइन"))
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "होइन, दुर्गा भजन")
        XCTAssertEqual(outcome.query, "होइन दुर्गा")
    }

    /// `V11` — slotFill; "दुर्गा होइन" ⇒ NOT a cancel (non-leading
    /// negation) ⇒ `.answer(.freeText)`. This unit keeps the whole
    /// phrase as content — nothing partial matches.
    func testVectorV11NonLeadingNegationIsContent() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "दुर्गा होइन"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "दुर्गा होइन").isEmpty)
        XCTAssertEqual(KeywordIntentRule.musicQueryOutcome(from: "दुर्गा होइन").provenance,
                       .content)
    }

    /// `V12` — any frame; "मेरो छोरालाई फोन गर" ⇒ `.bargeIn` (B3). The
    /// safety pin: a call command derives NO near-match candidate, so no
    /// probe can ever be framed around it.
    func testVectorV12CallCommandProducesNoNearMatch() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "मेरो छोरालाई फोन गर"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "मेरो छोरालाई फोन गर").isEmpty)
    }

    /// `V13` — candidateChoice; "युट्युब" with a youtube candidate ⇒
    /// `.candidatePick(index, .optionName)`. This unit supplies the
    /// candidate's origin: the bare YouTube word partially matches both
    /// the youtube rule and the youtube APP's launcher rule — two
    /// domains, one entry each.
    func testVectorV13BareYoutubeWordIsAYoutubeNearMatch() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "युट्युब"))
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युब"), [
            KeywordIntentRule.NearMatch(domain: .youtube, matchedKeys: ["युट्युब"], appID: nil),
            KeywordIntentRule.NearMatch(domain: .appLaunch, matchedKeys: ["युट्युब"], appID: "youtube")
        ])
    }

    /// `V14` — any frame; a 201-Character raw answer ⇒
    /// `.invalid(.overLength)`. The length guard is the classifier's
    /// (T-131); this unit's contribution is that an over-bound input is
    /// still read deterministically — no rule fires, no near-match, and
    /// the extractor caps its query exactly as `musicQuery` always has.
    func testVectorV14OverLongInputStaysCappedAndDeterministic() {
        let long = Array(repeating: "रामायण", count: 60).joined(separator: " ")
        XCTAssertGreaterThan(long.count, 200)
        XCTAssertNil(KeywordIntentRule.match(transcript: long))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: long).isEmpty)
        let outcome = KeywordIntentRule.musicQueryOutcome(from: long)
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertEqual(outcome.query?.count, KeywordIntentRule.maxMusicQueryLength)
    }

    // MARK: - Near-match boundary rows (design-l2 §13b)

    /// The music rule's ADR-SP-06 exclusion applies to the near-match
    /// reading exactly as it applies to `match`: an explicit YouTube
    /// marker disqualifies the whole rule — the marker token does not
    /// even seed a music candidate.
    func testNearMatchExclusionAppliesExactlyAsInMatch() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युबमा गीत"), [
            KeywordIntentRule.NearMatch(domain: .youtube, matchedKeys: ["युट्युब"], appID: nil)
        ])
        for utterance in ["युट्युबमा गीत सुनाऊ", "youtube song singing", "on youtube music listen"] {
            XCTAssertFalse(KeywordIntentRule.nearMatches(transcript: utterance)
                .contains { $0.domain == .music },
                "\(utterance) carries a YouTube marker — never a music near-match")
        }
    }

    /// A domain the rule fully matches is not a near-match — but a
    /// DIFFERENT domain's partial variant in the same utterance still
    /// reports: "युट्युब चलाऊ" fires the youtube rule and partially
    /// matches the youtube app's launcher rule (no open verb), so the
    /// launch candidate is legally offered alongside.
    func testNearMatchesFollowTheRulesNotTheUtteranceClaim() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "युट्युब चलाऊ")?.domain, .youtube)
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युब चलाऊ"), [
            KeywordIntentRule.NearMatch(domain: .appLaunch, matchedKeys: ["युट्युब"], appID: "youtube")
        ])
        // Single-variant domains: a full match leaves no partial variant
        // behind.
        for utterance in ["गीत चलाऊ", "क्यामेरा खोल", "युट्युबमा गीत चलाइदिनुस् न है त"] {
            XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: utterance).isEmpty,
                          "\(utterance) is fully claimed — no near-match reading")
        }
        // The news rule's second variant (bare noun + greeting) is
        // partial even when the verb variant fully claimed the
        // utterance — the pinned reading counts each VARIANT, so one
        // entry per domain still reports. Unreachable on the live
        // did-you-mean path (a fully matched utterance never gets
        // there); pinned so the reading cannot drift silently.
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "आजको समाचार सुनाइदिनुस् न"), [
            KeywordIntentRule.NearMatch(domain: .news, matchedKeys: ["समाचार"], appID: nil)
        ])
    }

    /// A bare action verb seeds nothing: the variant's groups are read
    /// in their declared order (specific word first, action verb last),
    /// so "the user named a thing without saying what to do" is the
    /// near-match shape, while a lone "बजाऊ"/"खोल" is exactly as silent
    /// as it is in `match`.
    func testBareVerbIsNotANearMatch() {
        for utterance in ["बजाऊ", "चलाऊ", "खोल", "सुनाऊ", "गर", "play", "open"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance), "\(utterance)")
            XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: utterance).isEmpty,
                          "\(utterance) is a bare verb — no domain partially co-occurs")
        }
    }

    /// The festival domain is excluded by the four-domain set even when
    /// its rule partially matches ("कहिले" alone), and an empty input
    /// reads as no near-match at all.
    func testNonFramableDomainsAndEmptyInputsYieldNoNearMatch() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "कहिले"))
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "कहिले").isEmpty,
                      "festivalDate is not a framable candidate domain")
        for empty in ["", "   ", "। ॥"] {
            XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: empty).isEmpty, "\"\(empty)\"")
        }
    }
}
