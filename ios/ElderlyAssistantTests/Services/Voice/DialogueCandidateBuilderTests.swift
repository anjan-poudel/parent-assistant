import XCTest
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10, T-132, design-l2 §10/§18, C-MTC-03) — the
/// focused `DialogueCandidateBuilderTests` suite: the near-match mapping
/// rows (one candidate per domain, the video-without-a-query omission,
/// the rule-token match keys), the hypothesis-last rule (R2: appended
/// last, never alone), the never-fabricate empty list, the cap that
/// keeps near-matches ahead of the hypothesis, and the slot-fill
/// candidates from the catalog group.
///
/// The reading pins used here are cross-checked against the T-130 suite
/// (`KeywordIntentRuleProvenanceTests`) — the builder is a consumer of
/// the near-match reading, and the "Given" of each scenario is made
/// explicit where it is load-bearing.
final class DialogueCandidateBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private let ne = Locale(identifier: "ne")

    private func command(action: InterpretedCommand.Action,
                         message: String? = nil,
                         topic: String? = nil) -> InterpretedCommand {
        InterpretedCommand(action: action, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, topic: topic, confidence: 0.65,
                           reply: "")
    }

    private func musicHypothesis(_ message: String? = "भजन") -> InterpretedCommand {
        command(action: .music, message: message)
    }

    private func videoHypothesis(_ topic: String? = "रामायण") -> InterpretedCommand {
        command(action: .suggestVideo, topic: topic)
    }

    private func build(_ utterance: String,
                       excludingDomain: KeywordIntentRule.Domain? = nil,
                       rephraseHypothesis: InterpretedCommand? = nil,
                       maxCandidates: Int = DialogueConfig.maxCandidates) -> [DialogueCandidate] {
        DialogueCandidateBuilder.build(for: utterance,
                                       excludingDomain: excludingDomain,
                                       rephraseHypothesis: rephraseHypothesis,
                                       maxCandidates: maxCandidates)
    }

    /// The test catalog: the bhajan group with FIVE options (one more
    /// than `DialogueConfig.maxSlotOptions`, so the cap is observable)
    /// plus a two-option group for the whole-group case.
    private static let catalogJSON = """
    {
      "version": 1,
      "groups": [
        {
          "id": "bhajan.deity",
          "questionKey": "dialogue.probe.bhajanKind",
          "matchKeys": ["भजन", "bhajan"],
          "options": [
            { "id": "shiva",  "labelKey": "dialogue.option.bhajan.shiva",
              "query": "shiva bhajan",  "aliases": ["शिव", "shiva"] },
            { "id": "durga",  "labelKey": "dialogue.option.bhajan.durga",
              "query": "durga bhajan",  "aliases": ["दुर्गा", "durga"] },
            { "id": "bishnu", "labelKey": "dialogue.option.bhajan.bishnu",
              "query": "bishnu bhajan", "aliases": ["विष्णु", "bishnu"] },
            { "id": "devi",   "labelKey": "dialogue.option.bhajan.devi",
              "query": "devi bhajan",   "aliases": ["देवी", "devi"] },
            { "id": "extra",  "labelKey": "dialogue.option.anyPlay",
              "query": "extra bhajan",  "aliases": ["अतिरिक्त"] }
          ]
        },
        {
          "id": "bhajan.small",
          "questionKey": "dialogue.probe.musicAny",
          "matchKeys": ["small"],
          "options": [
            { "id": "one", "labelKey": "dialogue.option.anyPlay",
              "query": "one bhajan", "aliases": ["एक"] },
            { "id": "two", "labelKey": "dialogue.option.anyPlay",
              "query": "two bhajan", "aliases": ["दुई"] }
          ]
        }
      ]
    }
    """

    private func catalog() throws -> DialogueOptionCatalog {
        try DialogueOptionCatalog(data: Data(Self.catalogJSON.utf8))
    }

    // MARK: - Near-match mapping (Gherkin 1)
    //
    // One candidate per near-matched domain, each in its own compose
    // form; match keys record the matched rule tokens.

    /// The news row: the `%@`-less template, no query, no appID, and the
    /// reading's own keys.
    func testNewsNearMatchMapsToTheNewsComposeForm() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "समाचार"),
                       [KeywordIntentRule.NearMatch(domain: .news,
                                                    matchedKeys: ["समाचार"],
                                                    appID: nil)],
                       "the Given: the news rule partially co-occurs")

        XCTAssertEqual(build("समाचार"), [
            DialogueCandidate(id: "near.news",
                              labelKey: "dialogue.candidate.news",
                              domain: .news,
                              query: nil,
                              appID: nil,
                              matchKeys: ["समाचार"])
        ])
    }

    /// The video row with a quotable query: `%@` renders from the
    /// utterance's own extracted words, and the match keys record the
    /// rule's own token — never the extracted query.
    func testYoutubeNearMatchMapsTheExtractedQueryAndRuleTokens() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युबमा गीत"),
                       [KeywordIntentRule.NearMatch(domain: .youtube,
                                                    matchedKeys: ["युट्युब"],
                                                    appID: nil)])

        XCTAssertEqual(build("युट्युबमा गीत"), [
            DialogueCandidate(id: "near.youtube",
                              labelKey: "dialogue.candidate.youtube",
                              domain: .youtube,
                              query: "गीत",
                              appID: nil,
                              matchKeys: ["युट्युब"])
        ])
    }

    /// The video row without a quotable query contributes NO candidate
    /// (design-l1 ADR-MTC-07 source 2: an eligible domain must be
    /// executable with the utterance's own extracted query — none is
    /// invented). "युट्युब" alone still reports the youtube reading; the
    /// app-launch reading is what carries the probe.
    func testVideoNearMatchWithoutAQuotableQueryContributesNoCandidate() {
        XCTAssertNil(YouTubeRoute.extractQuery(from: "युट्युब"),
                     "the Given: no quotable video query survives the drop set")
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युब").map(\.domain),
                       [.youtube, .appLaunch])

        let candidates = build("युट्युब")
        XCTAssertFalse(candidates.contains { $0.domain == .youtube },
                       "no video candidate without a quotable query")
        XCTAssertEqual(candidates, [
            DialogueCandidate(id: "near.appLaunch",
                              labelKey: "dialogue.candidate.appLaunch",
                              domain: .appLaunch,
                              query: nil,
                              appID: "youtube",
                              matchKeys: ["युट्युब"])
        ])
    }

    /// The same omission, isolated: with the app-launch reading excluded,
    /// the video reading yields nothing at all — and nothing else may be
    /// fabricated in its place.
    func testVideoOnlyReadingYieldsAnEmptyList() {
        XCTAssertEqual(build("युट्युब", excludingDomain: .appLaunch), [])
    }

    /// The music row: the candidate's query is the extractor's reading of
    /// the same utterance (the user's own words), the match keys the
    /// rule's own marker token.
    func testMusicNearMatchMapsTheExtractedQueryAndRuleTokens() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "दशैं दुर्गा भजन"),
                       [KeywordIntentRule.NearMatch(domain: .music,
                                                    matchedKeys: ["भजन"],
                                                    appID: nil)])
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "दशैं दुर्गा भजन"), "दशैं दुर्गा")

        XCTAssertEqual(build("दशैं दुर्गा भजन"), [
            DialogueCandidate(id: "near.music",
                              labelKey: "dialogue.candidate.music",
                              domain: .music,
                              query: "दशैं दुर्गा",
                              appID: nil,
                              matchKeys: ["भजन"])
        ])
    }

    /// The app-launch row: no query (the label's `%@` renders the primary
    /// match key), the catalog id on `appID`, mirroring `Match.appID`.
    func testAppLaunchNearMatchCarriesTheCatalogAppID() {
        XCTAssertEqual(build("क्यामेरा"), [
            DialogueCandidate(id: "near.appLaunch",
                              labelKey: "dialogue.candidate.appLaunch",
                              domain: .appLaunch,
                              query: nil,
                              appID: "camera",
                              matchKeys: ["क्यामेरा"])
        ])
    }

    /// Four readings are not possible at once on the current table (the
    /// music rule's YouTube-marker exclusion, ADR-SP-06), but a
    /// three-domain utterance pins the order contract: candidates in
    /// rule order (news → video → app), one per domain, each carrying
    /// its own reading's tokens.
    func testMultipleDomainsMapOneCandidateEachInRuleOrder() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युब समाचार").map(\.domain),
                       [.news, .youtube, .appLaunch],
                       "the Given: three domains partially co-occur, in rule order")

        let candidates = build("युट्युब समाचार")
        XCTAssertEqual(candidates.map(\.id), ["near.news", "near.youtube", "near.appLaunch"],
                       "one candidate per domain in rule order")
        XCTAssertEqual(Set(candidates.map(\.domain)).count, candidates.count,
                       "each domain contributes at most one candidate")
        XCTAssertEqual(candidates.map(\.matchKeys),
                       [["समाचार"], ["युट्युब"], ["युट्युब"]],
                       "match keys record the matched rule tokens")
        XCTAssertEqual(candidates.map(\.query), [nil, "समाचार", nil])
        XCTAssertEqual(candidates.map(\.appID), [nil, nil, "youtube"])
    }

    /// A domain whose rule carries more than one partial variant still
    /// contributes AT MOST one candidate ("आजको समाचार सुनाइदिनुस् न" is
    /// the multi-variant reading T-130 pinned deliberately).
    func testADomainContributesAtMostOneCandidateAcrossPartialVariants() {
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "आजको समाचार सुनाइदिनुस् न"),
                       [KeywordIntentRule.NearMatch(domain: .news,
                                                    matchedKeys: ["समाचार"],
                                                    appID: nil)])

        let candidates = build("आजको समाचार सुनाइदिनुस् न")
        XCTAssertEqual(candidates.map(\.id), ["near.news"])
        XCTAssertEqual(candidates.first?.matchKeys, ["समाचार"])
    }

    /// `excludingDomain` skips that domain's near-match reading —
    /// nothing of the excluded domain is re-offered from this source.
    func testExcludingDomainSkipsThatDomainsNearMatch() {
        XCTAssertEqual(build("युट्युब समाचार", excludingDomain: .news).map(\.id),
                       ["near.youtube", "near.appLaunch"])
        XCTAssertEqual(build("समाचार", excludingDomain: .news), [])
    }

    // MARK: - The hypothesis candidate (Gherkin 2)
    //
    // Appended LAST and ONLY alongside near-match candidates; with zero
    // near-match candidates it is never offered alone.

    /// The hypothesis re-offers the denied command's own words, last:
    /// `.music` → `.music` with the `message`, index-word pickable only.
    func testHypothesisIsAppendedLastAlongsideNearMatches() {
        let candidates = build("समाचार", rephraseHypothesis: musicHypothesis("भजन"))

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first?.id, "near.news", "the near-match keeps the lead")
        XCTAssertEqual(candidates.last, DialogueCandidate(id: "hypothesis.music",
                                                          labelKey: "dialogue.candidate.music",
                                                          domain: .music,
                                                          query: "भजन",
                                                          appID: nil,
                                                          matchKeys: []),
                       "the denied hypothesis is re-offered last with its own message")
    }

    /// `.suggestVideo` → the video compose form with the command's topic.
    func testSuggestVideoHypothesisMapsToTheVideoComposeForm() {
        let candidates = build("समाचार", rephraseHypothesis: videoHypothesis("रामायण"))

        XCTAssertEqual(candidates.last, DialogueCandidate(id: "hypothesis.youtube",
                                                          labelKey: "dialogue.candidate.youtube",
                                                          domain: .youtube,
                                                          query: "रामायण",
                                                          appID: nil,
                                                          matchKeys: []))
    }

    /// Any other action is omitted silently (design-l2 §10): the
    /// near-match list stands unchanged.
    func testNonMappedHypothesisActionIsOmittedSilently() {
        let call = command(action: .call)
        XCTAssertEqual(build("समाचार", rephraseHypothesis: call).map(\.id), ["near.news"])
    }

    /// The mapped action without its own field has no renderable label
    /// content — the hypothesis is omitted, never given an invented
    /// query (FR-MTC-004).
    func testHypothesisWithoutItsOwnWordsIsOmitted() {
        for message in [nil, "", "   ", "\n"] {
            XCTAssertEqual(build("समाचार", rephraseHypothesis: musicHypothesis(message)).map(\.id),
                           ["near.news"],
                           "message \(String(describing: message)) names nothing")
        }
        for topic in [nil, "  "] {
            XCTAssertEqual(build("समाचार", rephraseHypothesis: videoHypothesis(topic)).map(\.id),
                           ["near.news"],
                           "topic \(String(describing: topic)) names nothing")
        }
    }

    /// The trap pin (R2/design-l1 line 156): with zero near-match
    /// candidates the hypothesis is NEVER offered alone — neither when
    /// the utterance yields no reading at all, nor when its readings
    /// produce no candidate (the video-only shape).
    func testHypothesisIsNeverOfferedAlone() {
        XCTAssertEqual(build("बजाऊ", rephraseHypothesis: musicHypothesis()), [],
                       "no reading at all: nothing to stand beside")
        XCTAssertEqual(build("युट्युब", excludingDomain: .appLaunch,
                             rephraseHypothesis: musicHypothesis()), [],
                       "a reading with no candidate (no quotable query): still nothing")
    }

    // MARK: - Zero near-matches (Gherkin 3)

    /// An utterance with no near-match readings yields an empty list —
    /// nothing is fabricated (FR-MTC-004 scenario 3), and the caller
    /// arms no frame.
    func testZeroNearMatchesBuildAnEmptyList() {
        for utterance in ["", "   ", "यो के हो", "फेरि भन्छु", "होइन", "बजाऊ", "खोल"] {
            XCTAssertEqual(build(utterance), [], "\"\(utterance)\"")
        }
    }

    /// Medication and call shapes are excluded by construction: the
    /// medication rule's vocabulary is never consulted on this path, and
    /// a call command derives no near-match (T-130's V12 pin) — so no
    /// probe can ever be framed around health or call action.
    func testMedicationAndCallShapesBuildNoCandidates() {
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "रक्तचापको औषधि कस्तो देखिन्छ")
            .isEmpty)
        XCTAssertEqual(build("रक्तचापको औषधि कस्तो देखिन्छ"), [])

        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "मेरो छोरालाई फोन गर").isEmpty)
        XCTAssertEqual(build("मेरे छोरालाई फोन गर"), [])
    }

    /// The structural half of "no frame": an empty candidate list cannot
    /// be armed — `DialogueManager.arm` refuses the no-resolution draft
    /// (design-l2 §8), so the caller (T-134) keeps its existing honest
    /// dead-end line instead of opening a candidateChoice frame. The
    /// line itself is the caller's; this test pins that the empty list
    /// makes "no frame" structural, not a caller convention.
    func testZeroCandidatesCannotArmAFrame() {
        let utterance = "यो के हो"
        let candidates = build(utterance)
        XCTAssertEqual(candidates, [])

        let manager = DialogueManager(answerWindowSeconds: 30)
        XCTAssertThrowsError(try manager.arm(
            DialogueFrame.candidateChoice(candidates: candidates,
                                          sourceTranscript: utterance))) { error in
            XCTAssertEqual(error as? DialogueError, .noResolution,
                           "an empty candidate list has no resolution to arm")
        }
        XCTAssertNil(manager.liveFrame, "no frame is stored — the honest line stands alone")
    }

    // MARK: - The cap (Gherkin 4)

    /// More drafts than the maximum: the retained candidates are the
    /// near-match candidates in rule order; the hypothesis, drafted
    /// last, is the first dropped.
    func testCapKeepsNearMatchesAheadOfTheHypothesis() {
        let candidates = build("युट्युब समाचार", rephraseHypothesis: musicHypothesis("भजन"))

        XCTAssertEqual(candidates.map(\.id), ["near.news", "near.youtube", "near.appLaunch"],
                       "the near-matches keep priority; the hypothesis is dropped first")
        XCTAssertEqual(candidates.count, DialogueConfig.maxCandidates,
                       "size never exceeds the configured maximum")
    }

    /// The cap is the frame config's value passed in as a parameter —
    /// never a literal: any maximum produces its own prefix, and a
    /// non-positive maximum offers nothing (the defensive clamp; prefix
    /// would otherwise trap on a negative count).
    func testTheCapIsAParameterOfTheBuilder() {
        let utterance = "युट्युब समाचार"
        let hypothesis = musicHypothesis("भजन")

        XCTAssertEqual(build(utterance, rephraseHypothesis: hypothesis, maxCandidates: 1).map(\.id),
                       ["near.news"])
        XCTAssertEqual(build(utterance, rephraseHypothesis: hypothesis, maxCandidates: 2).map(\.id),
                       ["near.news", "near.youtube"])
        XCTAssertEqual(build(utterance, rephraseHypothesis: hypothesis, maxCandidates: 0), [])
        XCTAssertEqual(build(utterance, rephraseHypothesis: hypothesis, maxCandidates: 5).map(\.id),
                       ["near.news", "near.youtube", "near.appLaunch", "hypothesis.music"],
                       "with room to spare the hypothesis takes the last position")
    }

    /// The size invariant across sources and caps.
    func testCandidateCountNeverExceedsTheMaximum() {
        let utterances = ["समाचार", "युट्युब", "युट्युब समाचार", "दशैं दुर्गा भजन", "बजाऊ"]
        for utterance in utterances {
            for cap in [0, 1, 2, 3, 7] {
                let candidates = build(utterance,
                                       rephraseHypothesis: musicHypothesis("भजन"),
                                       maxCandidates: cap)
                XCTAssertLessThanOrEqual(candidates.count, cap, "\"\(utterance)\" cap \(cap)")
            }
        }
    }

    // MARK: - Slot-fill candidates (design-l2 §10)

    /// Options map in catalog order with their data verbatim; the slice
    /// stops at `DialogueConfig.maxSlotOptions` (the fifth option is
    /// never offered).
    func testSlotFillCandidatesMapTheCatalogGroupAndCapTheOptions() throws {
        let catalog = try catalog()
        let group = try XCTUnwrap(catalog.group("bhajan.deity"))

        let candidates = DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog)

        XCTAssertEqual(candidates.map(\.id), ["shiva", "durga", "bishnu", "devi"],
                       "ids from the catalog, in file order, capped at maxSlotOptions")
        XCTAssertEqual(candidates.map(\.labelKey),
                       ["dialogue.option.bhajan.shiva", "dialogue.option.bhajan.durga",
                        "dialogue.option.bhajan.bishnu", "dialogue.option.bhajan.devi"])
        XCTAssertEqual(candidates.map(\.query),
                       ["shiva bhajan", "durga bhajan", "bishnu bhajan", "devi bhajan"],
                       "queries are the canonical catalog queries")
        XCTAssertEqual(candidates.map(\.matchKeys),
                       [["शिव", "shiva"], ["दुर्गा", "durga"],
                        ["विष्णु", "bishnu"], ["देवी", "devi"]],
                       "matchKeys are the option's aliases")
        XCTAssertTrue(candidates.allSatisfy { $0.domain == .music },
                      "Phase 1's one slot executes through the music seam")
        XCTAssertTrue(candidates.allSatisfy { $0.appID == nil })
        XCTAssertFalse(candidates.contains { $0.id == "extra" },
                       "over-cap options are never offered")
    }

    /// A group smaller than the cap is served whole.
    func testSlotFillCandidatesServeSmallerGroupsWhole() throws {
        let catalog = try catalog()
        let group = try XCTUnwrap(catalog.group("bhajan.small"))

        XCTAssertEqual(DialogueCandidateBuilder.slotFillCandidates(from: group, catalog: catalog)
            .map(\.id), ["one", "two"])
    }

    /// The catalog is the single source of the option data: the group is
    /// re-resolved by id, so a caller-carried copy cannot smuggle a
    /// non-catalog option into the probe.
    func testSlotFillCandidatesReadTheCatalogAsTheSourceOfTruth() throws {
        let catalog = try catalog()
        let smuggled = DialogueOptionGroup(id: "bhajan.deity",
                                           questionKey: "dialogue.probe.musicAny",
                                           matchKeys: ["भजन"],
                                           options: [DialogueOption(id: "smuggled",
                                                                    labelKey: "irrelevant",
                                                                    query: "q",
                                                                    aliases: ["x"])])

        XCTAssertEqual(DialogueCandidateBuilder.slotFillCandidates(from: smuggled, catalog: catalog)
            .map(\.id), ["shiva", "durga", "bishnu", "devi"],
                       "the catalog's own group wins over the caller's copy")
    }

    /// A group the catalog does not carry yields no candidates — fail
    /// closed; nothing is offered that the catalog does not own.
    func testSlotFillCandidatesForANonCatalogGroupAreEmpty() throws {
        let catalog = try catalog()
        let foreign = DialogueOptionGroup(id: "not.in.catalog",
                                          questionKey: "dialogue.probe.musicAny",
                                          matchKeys: ["x"],
                                          options: [DialogueOption(id: "x",
                                                                   labelKey: "irrelevant",
                                                                   query: "q",
                                                                   aliases: ["x"])])

        XCTAssertEqual(DialogueCandidateBuilder.slotFillCandidates(from: foreign, catalog: catalog),
                       [])
    }

    // MARK: - Composition integration (FR-MTC-004 / FR-MTC-016)

    /// The built candidates render through the T-125 composer into the
    /// did-you-mean probe — the exact spoken line for a music near-match,
    /// with the user's own words in the `%@`.
    func testBuiltMusicCandidateRendersIntoTheDidYouMeanProbe() {
        let frame = DialogueFrame.candidateChoice(candidates: build("दशैं दुर्गा भजन"),
                                                  sourceTranscript: "दशैं दुर्गा भजन")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                    retry: false, locale: ne)

        XCTAssertEqual(probe, "मैले बुझिन। के तपाईंको मतलब दशैं दुर्गा बजाउने हो? हो?")
    }

    /// The app-launch candidate without a query renders its primary match
    /// key — the user's own word, never generated text.
    func testBuiltAppLaunchCandidateRendersThePrimaryMatchKey() {
        let frame = DialogueFrame.candidateChoice(candidates: build("युट्युब"),
                                                  sourceTranscript: "युट्युब")

        let probe = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                    retry: false, locale: ne)

        XCTAssertEqual(probe, "मैले बुझिन। के तपाईंको मतलब युट्युब खोल्ने हो? हो?")
    }

    /// Every compose form's label key resolves in both languages (the
    /// T-129 catalogue) — a typo would render the key itself to the
    /// elder, so this is the cheap guard on the mapping's key strings.
    func testEveryComposeFormKeyResolvesInBothLanguages() {
        let built = build("युट्युब समाचार")
            + [musicHypothesisCandidate()]
        for candidate in built {
            for locale in [Locale(identifier: "ne"), Locale(identifier: "en")] {
                let label = L10n.str(candidate.labelKey, locale: locale)
                XCTAssertFalse(label.isEmpty, "\(candidate.labelKey)")
                XCTAssertNotEqual(label, candidate.labelKey,
                                  "\(candidate.labelKey) must resolve to copy, not the key")
            }
        }
    }

    /// The `%@`-less news key and the three `%@` keys are the T-129
    /// templates verbatim — the copy is never re-worded here (owner copy
    /// review owns the values).
    func testTheComposeFormKeysAreTheShippedDialogueKeys() {
        XCTAssertEqual(build("समाचार").first?.labelKey, "dialogue.candidate.news")
        XCTAssertEqual(build("युट्युबमा गीत").first?.labelKey, "dialogue.candidate.youtube")
        XCTAssertEqual(build("दशैं दुर्गा भजन").first?.labelKey, "dialogue.candidate.music")
        XCTAssertEqual(build("क्यामेरा").first?.labelKey, "dialogue.candidate.appLaunch")
        XCTAssertEqual(build("समाचार", rephraseHypothesis: musicHypothesis()).last?.labelKey,
                       "dialogue.candidate.music")
    }

    // MARK: - Purity

    /// The builder is a pure function: the same input produces the same
    /// list (deterministic ids included), twice, and it holds no state
    /// between calls.
    func testBuildIsDeterministicAcrossCalls() {
        let first = build("युट्युब समाचार", rephraseHypothesis: musicHypothesis("भजन"))
        let second = build("युट्युब समाचार", rephraseHypothesis: musicHypothesis("भजन"))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertFalse(first.isEmpty, "the fixture must build something for this to be a pin")
    }

    // MARK: - Helpers

    private func musicHypothesisCandidate() -> DialogueCandidate {
        DialogueCandidate(id: "hypothesis.music",
                          labelKey: "dialogue.candidate.music",
                          domain: .music,
                          query: "भजन",
                          appID: nil,
                          matchKeys: [])
    }
}
