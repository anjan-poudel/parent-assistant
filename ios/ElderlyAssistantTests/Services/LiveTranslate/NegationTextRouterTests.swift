import XCTest
@testable import ElderlyAssistant

/// [NEGATION-ROUTER] (owner decision, 2026-09-19) — the source-side negation
/// router, pinned string by string.
///
/// The decision this suite defends: the standard-class quant (r2b Q5_K_M,
/// 1.17 GB, 85.3% usable) failed two held-out probe rows, both
/// negation-bearing safety instructions, and answered the *positive*
/// instruction instead. A wrong translation of a sign is a bad translation; a
/// wrong translation of a negation is the opposite instruction, and the elder
/// acts on it. So a negation-bearing source string is never handed to the
/// local tier. The two probe classes are spelled out below, because "which
/// strings this must never let local" is the whole requirement:
///
///   - **storage / bathroom**: "Do not store the medicine in the bathroom"
///     (the row the model actually failed — it returned the positive storage
///     instruction);
///   - **child safety**: "Keep away from children", whose polarity lives
///     entirely in a preposition and carries no negative particle at all.
///
/// The bias is stated as a rule and tested as one: a false positive (a
/// positive string routed away) costs one cloud call; a false negative (a
/// negation answered locally) costs the elder a wrong safety instruction. The
/// two are not comparable, so anything that looks like a negation routes away,
/// and the tests below assert the safe side of every boundary rather than the
/// linguistically tidy one (`testTheBoundaryPhrasingsAreClassifiedOnTheSafeSide`).
///
/// The suite is deliberately pure: no bus, no config, no model, no clock. The
/// call site's behaviour (zero local-tier calls, the count-only event, the
/// dictionary's exemption) is pinned in `LiveTranslationPipelineTests`.
final class NegationTextRouterTests: XCTestCase {

    // MARK: Scenario: the probe classes never reach the local tier

    /// The measured failure, verbatim. This is the string the Q5 answered as
    /// the positive storage instruction, and the reason the router exists.
    func testTheBathroomStorageProbeRoutesAway() {
        let probe = "Do not store the medicine in the bathroom"
        XCTAssertTrue(NegationTextRouter.routesAway(probe),
                      "THE probe row — a local answer here is the opposite instruction")
        XCTAssertEqual(NegationTextRouter.match(in: probe), .word("not"),
                       "the marker is the 'not' the model dropped")
    }

    /// The second probe class: a complete prohibition with no negation token
    /// in it. A router built only on negation words would let every one of
    /// these through.
    func testTheChildSafetyProbeClassRoutesAway() {
        let probes = [
            "Keep away from children",
            "Keep out of reach of children",
            "Store out of reach of children",
            "Keep away"
        ]
        for probe in probes {
            XCTAssertTrue(NegationTextRouter.routesAway(probe),
                          "\"\(probe)\" is a prohibition with no negative particle; "
                          + "a local answer inverts it")
        }
    }

    /// The rest of the eval set's negation-bearing safety classes, in the
    /// shapes the set actually carries (storage, heat, expiry, bathroom).
    func testTheRemainingProbeShapesRouteAway() {
        let probes = [
            "Do not heat the container in the microwave",
            "Do not use after the expiry date",
            "Never put water in the oil",
            "Avoid contact with eyes",
            "Keep away from heat",
            "Use without water",
            "Nothing on top of the microwave",
            "No open flame",
            "Unsuitable for children"
        ]
        for probe in probes {
            XCTAssertTrue(NegationTextRouter.routesAway(probe),
                          "\"\(probe)\" carries a prohibition; it must not be answered locally")
        }
    }

    // MARK: Scenario: an ordinary positive string is still answered on device

    /// The router is not a pessimist: the strings the tier is being measured
    /// on must still go local, or the feature has traded its cloud bill for
    /// nothing. Same classes as the probes above, positive polarity.
    func testPositiveApplianceAndLabelSentencesStayLocal() {
        let positives = [
            "Store in a cool dry place",
            "Keep warm",
            "Push the green button",
            "Members only beyond this point",
            "Wash at low temperature",
            "Best before the end of the year",
            "Use in a well ventilated room",
            "Close the door before starting",
            "Light",
            "Start"
        ]
        for positive in positives {
            XCTAssertFalse(NegationTextRouter.routesAway(positive),
                           "\"\(positive)\" is positive; routing it away spends a cloud call "
                           + "the device could have answered for free")
            XCTAssertNil(NegationTextRouter.match(in: positive))
        }
    }

    // MARK: Scenario: the boundaries, decided on the safe side

    /// The boundary cases the requirement names, each asserted in the
    /// direction the safe-side rule chooses rather than the direction a
    /// linguist might.
    func testTheBoundaryPhrasingsAreClassifiedOnTheSafeSide() {
        // "not hot" is a negation about a state — routes away, and the
        // conservative reading is the point: a "not hot" answered as "hot" is
        // a burn.
        XCTAssertEqual(NegationTextRouter.match(in: "The surface is not hot"), .word("not"))
        // "do not heat" — the instruction form of the same words.
        XCTAssertEqual(NegationTextRouter.match(in: "Do not heat"), .word("not"))
        // "does not open while running" — the negation-modality shape
        // ("not … while") with no phrase entry of its own, caught by the
        // token rule.
        XCTAssertEqual(NegationTextRouter.match(in: "The door does not open while running"),
                       .word("not"))
        // …and the honest boundary: a positive warning label and an
        // opposite-action verb are NOT this router's scope (see the file
        // header — the router keys on negation and claims nothing wider). A
        // test that asserted otherwise would be a claim the component does
        // not make.
        XCTAssertFalse(NegationTextRouter.routesAway("Hot surface"),
                       "a positive warning label is outside the router's stated scope")
        XCTAssertFalse(NegationTextRouter.routesAway("Unplug before cleaning"),
                       "\"unplug\" is an opposite action, not a negation — the table has no "
                       + "general \"un-\" rule, and this test is where that stays true")
        // "Keep warm" is a curated dictionary KEY. A prohibition table built
        // on the bare word "keep" would have routed a reviewed tier-0
        // translation away from a tier that never sees it.
        XCTAssertFalse(NegationTextRouter.routesAway("Keep warm"),
                       "the curated key \"keep warm\" must survive the phrase table")
    }

    /// The negative determiner is the router's noisiest marker and it is kept
    /// on purpose. "No signal" is not a prohibition; it costs one cloud call.
    /// The alternative — a determiner rule with a scope check — is the kind of
    /// cleverness that misses a real prohibition.
    func testTheDeterminerNoRoutesEvenWhenItIsProbablyHarmless() {
        for harmless in ["No signal", "No. 5", "No service in this area"] {
            XCTAssertTrue(NegationTextRouter.routesAway(harmless),
                          "\"\(harmless)\" routes away: a false positive costs a cloud call, "
                          + "a false negative costs the elder the instruction")
        }
    }

    // MARK: Scenario: a word that merely contains a marker is not a negation

    /// The token rule, and the reason it is a token rule. Substring matching
    /// is how a router becomes wrong in *both* directions at once: every word
    /// here contains a marker's letters and none of them is a negation — and
    /// "note" is a curated dictionary key (`नोट`), so a substring rule would
    /// also have routed a reviewed tier-0 translation.
    func testAWordThatMerelyContainsAMarkerIsNotNegation() {
        let safeStrings = [
            "Note", "Note: clean the filter", "normal", "notice", "knot",
            "Normal cycle", "North side", "Nos. 1 to 5", "A knot in the cord",
            "Notion", "The north door is open"
        ]
        for text in safeStrings {
            XCTAssertNil(NegationTextRouter.match(in: text),
                         "\"\(text)\" contains a marker's letters but is not a negation")
        }
    }

    /// The contraction rule is a suffix over the token, not a list of
    /// spellings — and the suffix carries the apostrophe, so ordinary words
    /// that end in the same letters are untouched.
    func testTheContractionSuffixDoesNotMatchWordsWithoutTheApostrophe() {
        for word in ["pint", "front", "plant", "went", "count", "point"] {
            XCTAssertNil(NegationTextRouter.match(in: word),
                         "\"\(word)\" ends in nt, not in n't")
        }
    }

    func testEveryContractionSpellingRoutesAway() {
        let contractions = ["Don't touch the wires", "Doesn't include batteries",
                            "Can't be used outdoors", "Won't fit in the drawer",
                            "Shouldn't be covered", "Mustn't block the vent",
                            "Isn't suitable for children", "Haven't tested"]
        for text in contractions {
            XCTAssertTrue(NegationTextRouter.routesAway(text), "\"\(text)\" is a negation")
        }
    }

    /// Recognition and print both produce the typographic apostrophe, so the
    /// same negation arrives in two spellings. Both route, and the marker
    /// reports the folded token rather than the raw spelling.
    func testBothApostropheSpellingsOfAContractionRouteAway() {
        let ascii = "Don't use near water"
        let typographic = "Don’t use near water"
        XCTAssertEqual(NegationTextRouter.match(in: ascii), .contraction("don't"))
        XCTAssertEqual(NegationTextRouter.match(in: typographic), .contraction("don't"),
                       "U+2019 is the same negation as U+0027")
        XCTAssertEqual(NegationTextRouter.normalised(typographic),
                       NegationTextRouter.normalised(ascii))
        XCTAssertEqual(NegationTextRouter.words(in: typographic), ["don't", "use", "near", "water"])
    }

    /// Hyphens split, on purpose: "do-not" is a spelling a label or a
    /// recognition pass can produce, and the compound must not hide the
    /// marker inside it.
    func testAHyphenatedCompoundCannotHideAMarker() {
        for text in ["do-not-use near water", "not-hot", "Do-Not-Enter"] {
            XCTAssertTrue(NegationTextRouter.routesAway(text),
                          "\"\(text)\" hides a marker inside a hyphenated compound")
        }
    }

    /// Punctuation and line breaks between a phrase's words do not defeat the
    /// phrase rule — the phrase table is matched against the token stream,
    /// not against the raw string.
    func testAProhibitionPhraseSurvivesPunctuationAndLineBreaks() {
        for text in ["Keep away, not near children", "keep\naway from\nchildren",
                     "Keep  away   from  children", "STORE AWAY FROM HEAT"] {
            XCTAssertTrue(NegationTextRouter.routesAway(text),
                          "\"\(text)\" carries the phrase; punctuation is not a hole")
        }
    }

    // MARK: Scenario: the curated tables are exercised, entry by entry

    /// Every entry of both tables is observed firing. A curated table is only
    /// load-bearing if a marker that was renamed or dropped fails a test, and
    /// this is that test: the sentence templates below reach each entry from a
    /// shape that actually occurs on a label.
    func testEveryCuratedMarkerIsExercised() {
        // One sentence per entry, keyed by the entry itself, so an entry with
        // no sentence is a test failure rather than a silent hole.
        let sentences: [String: String] = [
            "not": "Do not store the medicine in the bathroom",
            "no": "No open flame",
            "never": "Never put water in the oil",
            "without": "Use without water",
            "avoid": "Avoid direct sunlight",
            "cannot": "Cannot be used with a timer",
            "nor": "Nor should it be covered while running",
            "none": "None of the vents may be blocked",
            "neither": "Neither child nor pet should enter",
            "nothing": "Nothing on top of the microwave",
            "unsafe": "Unsafe with pacemakers",
            "unsuitable": "Unsuitable for children"
        ]
        XCTAssertEqual(Set(sentences.keys), NegationTextRouter.negationWords,
                       "every curated negation word has a sentence, and every sentence "
                       + "has a curated entry — a word added to the table fails here "
                       + "until it is exercised")

        for (entry, sentence) in sentences {
            XCTAssertEqual(NegationTextRouter.match(in: sentence), .word(entry),
                           "the token table entry \"\(entry)\" no longer fires: \(sentence)")
        }

        // The contraction rule, as the class it is.
        XCTAssertEqual(NegationTextRouter.match(in: "Don't use near water"),
                       .contraction("don't"))

        // …and every phrase, with the phrase reported rather than a word (its
        // whole point is that it has no word to report).
        let phrases: [String: String] = [
            "away from": "Keep away from children",
            "keep away": "Keep away",
            "keep out": "Keep out of reach of children",
            "out of reach": "Store out of reach of children"
        ]
        XCTAssertEqual(Set(phrases.keys), Set(NegationTextRouter.prohibitionPhrases),
                       "every curated phrase has a sentence")
        for (entry, sentence) in phrases {
            XCTAssertEqual(NegationTextRouter.match(in: sentence), .phrase(entry),
                           "the phrase table entry \"\(entry)\" no longer fires: \(sentence)")
        }
    }

    /// A table's shape is part of its meaning: phrases are matched against
    /// lower-cased tokens joined by single spaces, and the suffix rule is the
    /// contraction's own. An entry that cannot match is a hole that looks like
    /// coverage.
    func testTheCuratedTablesAreWellFormed() {
        for phrase in NegationTextRouter.prohibitionPhrases {
            XCTAssertEqual(phrase, phrase.lowercased(), "\"\(phrase)\" can never match: tokens are lower-cased")
            XCTAssertFalse(phrase.isEmpty)
            XCTAssertFalse(phrase.hasPrefix(" "), "\"\(phrase)\" has padding the matcher never produces")
            XCTAssertFalse(phrase.hasSuffix(" "))
            XCTAssertFalse(phrase.contains("  "), "\"\(phrase)\" has a double space the join never produces")
        }
        for word in NegationTextRouter.negationWords {
            XCTAssertEqual(word, word.lowercased(), "\"\(word)\" can never match: tokens are lower-cased")
            XCTAssertFalse(word.contains(" "), "\"\(word)\" is not a whole token")
            XCTAssertFalse(word.contains("'"), "\"\(word)\" belongs to the contraction rule, not the word table")
            XCTAssertGreaterThan(word.count, 1)
        }
        XCTAssertEqual(NegationTextRouter.negationContractionSuffix, "n't")
        XCTAssertTrue(NegationTextRouter.prohibitionPhrases.allSatisfy { $0.contains(" ") },
                      "a one-word prohibition is the token table's job, not the phrase table's")
    }

    /// The marker that fired is reported for tests and for a reader; it is
    /// never a log value (the routing event carries counts only, pinned in
    /// `LiveTranslationPipelineTests` and `LiveTranslateEventsTests`).
    func testTheMarkerReportsTheEntryThatFired() {
        XCTAssertEqual(NegationTextRouter.match(in: "Do not heat")?.spelling, "not")
        XCTAssertEqual(NegationTextRouter.match(in: "Don't heat")?.spelling, "don't")
        XCTAssertEqual(NegationTextRouter.match(in: "Keep away from children")?.spelling, "away from")
        XCTAssertNil(NegationTextRouter.match(in: "Push the green button")?.spelling)
    }

    /// The first marker in the sentence wins, and the word table is consulted
    /// before the phrase table. The order is a convenience for a reader —
    /// `routesAway` is the answer that matters and any marker is enough of one
    /// — but a reader of the marker should get the leftmost one.
    func testTheFirstMarkerInTheSentenceIsTheOneReported() {
        XCTAssertEqual(NegationTextRouter.match(in: "Do not keep away from children"),
                       .word("not"))
        XCTAssertEqual(NegationTextRouter.match(in: "Keep away from any open flame"),
                       .phrase("away from"))
    }

    // MARK: Scenario: the partition, which is what the dispatch consumes

    /// `partition` is the shape the dispatch's filter is built on: both halves
    /// in the caller's order, and nothing dropped. A dispatch that lost a
    /// string would leave a region pending with no tier ever asked about it.
    func testThePartitionSplitsInOrderAndDropsNothing() {
        let texts = ["Start", "Do not store in the bathroom", "Hot surface",
                     "Keep away from children", "Push the green button"]
        let split = NegationTextRouter.partition(texts)

        XCTAssertEqual(split.local, ["Start", "Hot surface", "Push the green button"])
        XCTAssertEqual(split.routed,
                       ["Do not store in the bathroom", "Keep away from children"])
        XCTAssertEqual(split.local + split.routed, [texts[0], texts[2], texts[4], texts[1], texts[3]],
                       "order is kept within each half")
        XCTAssertEqual(Set(split.local).union(split.routed), Set(texts),
                       "nothing is dropped and nothing is invented")
        XCTAssertEqual(split.local.count + split.routed.count, texts.count)
    }

    func testAnEmptyScenePartitionsIntoTwoEmptyHalves() {
        XCTAssertEqual(NegationTextRouter.partition([]),
                       NegationTextRouter.Partition(local: [], routed: []))
    }

    func testAnEmptyOrScriptOnlyTextCarriesNoMarker() {
        for text in ["", "   ", "\n", "फार्मेसी खुला छ", "सुरु गर्ने"] {
            XCTAssertNil(NegationTextRouter.match(in: text),
                         "\"\(text)\" carries no English negation; it keeps the behaviour "
                         + "it had before the router existed")
        }
    }

    // MARK: Scenario: the router stays a decision about a string

    /// The configuration knob's default lives on `LiveTranslateConfig` (the
    /// call site reads it, not the router). It is pinned here because this is
    /// the suite that owns the router's behaviour: on by default is the
    /// shipped decision, and off is the pre-router cascade exactly.
    func testTheRouterIsOnByDefault() {
        XCTAssertTrue(LiveTranslateConfig.default.negationRouterEnabled,
                      "the router ships on: the thing it prevents is a wrong safety instruction")
    }

    // MARK: Scenario: the curated tier is exempt, and stays exempt

    /// Tier 0 is reviewed Nepali, including — if the table ever carries one —
    /// a reviewed negation. The dispatch's exemption is structural (a curated
    /// hit is settled before the router runs, pinned in
    /// `LiveTranslationPipelineTests`); what this test adds is the *premise*
    /// the exemption rests on today: no curated entry is negation-bearing, so
    /// nothing reviewed is being routed away by accident. The day one is
    /// added, this fails and the author must decide deliberately whether the
    /// router may overrule a reviewed translation.
    func testNoCuratedDictionaryEntryIsNegationBearing() {
        let offenders = ApplianceLabelLocalizer.dictionary.keys
            .filter { NegationTextRouter.routesAway($0) }
            .sorted()
        XCTAssertEqual(offenders, [],
                       "a curated entry became negation-bearing: the router's exemption "
                       + "for tier 0 needs a decision, not a silent pass")
        // The near-misses are why the matching is whole-token: "note" and
        // "keep warm" are curated keys whose letters open a marker.
        XCTAssertTrue(ApplianceLabelLocalizer.dictionary.keys.contains("note"))
        XCTAssertTrue(ApplianceLabelLocalizer.dictionary.keys.contains("keep warm"))
    }
}
