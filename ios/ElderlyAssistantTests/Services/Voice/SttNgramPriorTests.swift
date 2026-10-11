import XCTest
@testable import ElderlyAssistant

// [CORRECTION-REVIVE] The additive n-gram/symspell bank: decode, band
// validation, the symmetric-delete tier and the prior's normalisation.
// The BANDED-GATE behaviour (judge-eligible classification, the pinned
// silent-apply set) lives in DialectIdentifierTests, which owns the
// corrector fixtures.

final class SttNgramPriorTests: XCTestCase {

    /// A minimal coherent bank: three lexicon tokens, delete-forms that
    /// exercise BOTH symspell lookups (the direct truncation hit and the
    /// delete-form hit), one floor-kept bigram, and the pinned bands.
    private func makeBankJSON(
        bands: (surfaceFloor: Double, applyTotal: Double, judgeMin: Double)
            = (0.8125, 0.8125, 0.40)
    ) -> Data {
        let json = """
        {
          "formatVersion": 1,
          "tableID": "stt-ngram-prior",
          "generation": { "runRevision": "correction-banks/v4#fixture",
                          "corpusRevision": "fixture-corpus" },
          "corpus": { "rows": 100, "revision": "fixture-corpus" },
          "lexicon": [
            { "token": "सुनाउनुहोस्", "occurrences": 25 },
            { "token": "खाना", "occurrences": 30 },
            { "token": "समाचार", "occurrences": 40 }
          ],
          "bigrams": { "समाचार\\u0001सुनाउनुहोस्": 12 },
          "trigrams": {},
          "totals": { "unigrams": 95, "bigrams": 100, "trigrams": 0 },
          "symspell": { "maxEdit": 1, "lexiconCount": 3,
            "deletes": {
              "सुनाउनुहोस": [0],
              "खान": [1],
              "खना": [1],
              "समाचार": [2]
            }
          },
          "bands": { "surfaceFloor": \(bands.surfaceFloor),
                     "applyTotal": \(bands.applyTotal),
                     "judgeMin": \(bands.judgeMin),
                     "origin": "fixture" }
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Decode + bands

    func testDecodesAFixtureBank() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        XCTAssertEqual(bank.lexiconCount, 3)
        XCTAssertTrue(bank.bands.isActive)
        XCTAssertEqual(bank.corpusRevision, "fixture-corpus")
        XCTAssertTrue(bank.contains("खाना"))
        XCTAssertEqual(bank.occurrences(of: "समाचार"), 40)
        XCTAssertEqual(bank.ordinal(of: "सुनाउनुहोस्"), 0)
    }

    func testRefusesOutOfOrderBands() {
        XCTAssertNil(NgramPrior.decode(makeBankJSON(
            bands: (surfaceFloor: 0.8125, applyTotal: 0.8125, judgeMin: 0.9))),
            "a judge floor ABOVE the surface floor is an insane operating "
            + "point and refuses the whole bank")
        XCTAssertNil(NgramPrior.decode(makeBankJSON(
            bands: (surfaceFloor: 0.8125, applyTotal: 0.5, judgeMin: 0.4))),
            "applyTotal below the surface floor refuses the whole bank")
    }

    func testRefusesAnEmptyIndex() {
        let json = """
        {
          "formatVersion": 1, "tableID": "stt-ngram-prior",
          "generation": { "runRevision": "v", "corpusRevision": "c" },
          "corpus": { "rows": 1, "revision": "c" },
          "lexicon": [],
          "bigrams": {}, "trigrams": {},
          "totals": { "unigrams": 0, "bigrams": 0, "trigrams": 0 },
          "symspell": { "maxEdit": 1, "lexiconCount": 0, "deletes": {} },
          "bands": { "surfaceFloor": 0.8125, "applyTotal": 0.8125,
                     "judgeMin": 0.40, "origin": "fixture" }
        }
        """
        XCTAssertNil(NgramPrior.decode(Data(json.utf8)))
    }

    // MARK: - SymSpell tier

    func testSymSpellFindsTheTruncatedQueryDirectly() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        // "सुनाउनुहोस" is the lexicon word "सुनाउनुहोस्" minus the halanta —
        // the DIRECT lookup (the query IS the word's delete-form), which is
        // the truncation class the corrector exists to repair.
        XCTAssertEqual(bank.symSpellCandidates(for: "सुनाउनुहोस"),
                       ["सुनाउनुहोस्"])
    }

    func testSymSpellFindsCandidatesViaTheQuerysDeleteForms() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        // "खाना" and "खनात" are one substitution apart — the deletion-only
        // lemma reaches that through the delete-form BOTH share: "खना".
        // The query's own delete-forms are the lookup keys, so the index
        // must carry the shared form, not only the truncation form "खान".
        XCTAssertTrue(bank.symSpellCandidates(for: "खनात").contains("खाना"))
    }

    func testSymSpellReturnsNothingForForeignTokens() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        XCTAssertEqual(bank.symSpellCandidates(for: "zzz"), [])
    }

    // MARK: - Prior scoring

    func testPriorScoreUsesTheStrongestBigramFitNormalised() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        // The fixture's only floor-kept bigram: समाचार → सुनाउनुहोस् (12 of
        // 100 total) — so the candidate "सुनाउनुहोस्" after "समाचार" scores
        // 0.12, and an unseen pair scores 0.
        let hit = bank.priorScore(forCandidate: "सुनाउनुहोस्",
                                  neighbours: ["समाचार", "आज"])
        XCTAssertEqual(hit, 0.12, accuracy: 0.0001)
        let miss = bank.priorScore(forCandidate: "खाना",
                                   neighbours: ["समाचार"])
        XCTAssertEqual(miss, 0)
    }

    func testPriorScoreCapsAtOne() throws {
        let bank = try XCTUnwrap(NgramPrior.decode(makeBankJSON()))
        // A count above the total must not produce a score above 1.0.
        let json = makeBankJSON()
        _ = json
        let overBank = try XCTUnwrap(NgramPrior.decode(Data("""
        {
          "formatVersion": 1, "tableID": "stt-ngram-prior",
          "generation": { "runRevision": "v", "corpusRevision": "c" },
          "corpus": { "rows": 1, "revision": "c" },
          "lexicon": [ { "token": "सुनाउनुहोस्", "occurrences": 25 } ],
          "bigrams": { "समाचार\\u0001सुनाउनुहोस्": 500 },
          "trigrams": {},
          "totals": { "unigrams": 25, "bigrams": 100, "trigrams": 0 },
          "symspell": { "maxEdit": 1, "lexiconCount": 1,
            "deletes": { "सुनाउनुहोस": [0] } },
          "bands": { "surfaceFloor": 0.8125, "applyTotal": 0.8125,
                     "judgeMin": 0.40, "origin": "fixture" }
        }
        """.utf8)))
        XCTAssertEqual(overBank.priorScore(forCandidate: "सुनाउनुहोस्",
                                           neighbours: ["समाचार"]), 1.0)
        _ = bank
    }

    // MARK: - The shipped bank

    func testTheShippedBankLoadsFromTheBundle() throws {
        // The real corpus bank ships in VariantTables (generated on the
        // training server, `correction-banks/v4`). A load failure here
        // would silently serve the legacy gate in production — the
        // additive bank's absence never complains.
        let bank = try XCTUnwrap(NgramPrior.bundled,
                                 "the shipped stt-ngram-prior.json must decode")
        XCTAssertTrue(bank.bands.isActive)
        XCTAssertGreaterThan(bank.lexiconCount, 3000,
                             "the corpus bank's expanded vocabulary")
        XCTAssertTrue(bank.revision.hasPrefix("correction-banks/v4#"))
        XCTAssertFalse(bank.corpusRevision.isEmpty)
    }

    // MARK: - Delete-one forms (the runtime twin of the pipeline's index)

    func testDeleteOneFormsAreScalarBased() {
        // होस् = ह ो स ् — four scalars, four forms; the halanta deletes on
        // its own, exactly like the Python builder's token[:i] + token[i+1:].
        let forms = STTCorrector.deleteOneForms(of: "होस्")
        XCTAssertEqual(forms.count, 4)
        XCTAssertTrue(forms.contains("होस"))
        XCTAssertTrue(forms.contains("हो्"))
        XCTAssertEqual(STTCorrector.deleteOneForms(of: "ह"), [],
                       "a single-scalar token has no delete forms")
    }
}
