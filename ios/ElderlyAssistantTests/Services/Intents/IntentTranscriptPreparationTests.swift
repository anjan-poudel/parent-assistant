import XCTest
@testable import ElderlyAssistant

/// T-127 — the shared input-seam helper (`IntentTranscriptPreparation`,
/// design-l2 L2-D14 / §15, C-MTC-08c).
///
/// The helper is the ONE order both callers run — sanitise → seam → prepared
/// text — so these tests pin, and only pin:
///
///  * parity rows `T1`–`T4`: the same fixture through the shipped caller
///    (`LocalBrainChain`) and through the helper yields the same `sanitised`,
///    `prepared` and `pair` byte for byte, on a transform-hit and a
///    transform-miss fixture, with nil and non-nil seams;
///  * the sanitiser discipline (M-3, `security-design-review.md`): with a
///    seam, `prepared` derives from the sanitiser's output and can never be
///    the untransformed text a rewriting seam replaced;
///  * the nil-seam branch's raw pass-through AND its documentation as
///    test-only parity, with production wired non-nil (C-5, `review-l2.md`);
///  * purity: no sanitiser call on a nil seam, exactly one seam run per call.
///
/// The parity oracle is the shipped chain, not a re-implementation of it: the
/// text a brain was actually handed (`StubCommandInterpreter.lastTranscript`)
/// and the pair the seam actually produced are the historical
/// `turnInput` outputs.
final class IntentTranscriptPreparationTests: XCTestCase {

    // MARK: - Fixtures

    /// The synthetic orthographic rule the "production transform" fixtures
    /// fire through: `भोली` → `भोलि`.
    private static let hitVariant = "भोली"
    private static let hitCanonical = "भोलि"
    /// A hit fixture (a standalone token the rule rewrites).
    private static let hitFixture = "\(hitVariant) मौसम कस्तो छ"
    private static let hitExpectedPrepared = "\(hitCanonical) मौसम कस्तो छ"
    /// A miss fixture (no rule matches; the seam runs and rewrites nothing).
    private static let missFixture = "मौसम कस्तो छ"

    /// The synthetic table set, built exactly as `DialectIdentifierTests`
    /// builds its stage-1 fixtures.
    private static let tables = VariantTableSet(
        orthographic: VariantTable(
            formatVersion: 1,
            tableID: "t127-canonical-orthographic",
            dialectRaw: nil,
            generation: VariantTable.Generation(status: "TEST",
                                                path: "test",
                                                date: nil),
            entries: [VariantTableEntry(
                id: "t127-bholi",
                kindRaw: "orthographic",
                variant: hitVariant,
                canonical: hitCanonical,
                status: .confirmed,
                modelImpact: "known_word",
                resolves: ["N5"],
                note: "synthetic T-127 fixture",
                evidence: VariantTableEntry.Evidence(
                    source: .authored,
                    corpusRevision: nil,
                    rowIDs: [],
                    occurrences: 0,
                    fixtureExamples: [hitVariant, hitVariant + " मौसम"]))]),
        panRegional: nil,
        sttReductions: nil,
        dialectTables: [:],
        loadIssues: [])

    // MARK: - Doubles

    /// The SHIPPED seam's own body — `IntentInputCanonicalization.prepare`,
    /// the function `IntentEncoderWiring.localSlotInputSeam` calls — with the
    /// policy resolved ON and the synthetic rule above, so the transform
    /// actually fires. The shipped persisted toggle defaults OFF (and a
    /// stored-key test would race every other suite in the process), so an
    /// inert production seam could not exercise a hit fixture at all; this is
    /// the production composition with one reviewable input changed.
    private final class ProductionTransformSeam {
        private(set) var inputs: [String] = []
        private(set) var pairs: [IntentTranscriptPair] = []

        var seam: LocalBrainChain.InputSeam {
            LocalBrainChain.InputSeam { [self] text in
                inputs.append(text)
                let pair = IntentInputCanonicalization.prepare(
                    sanitisedTranscript: text,
                    dialect: .default,
                    tables: IntentTranscriptPreparationTests.tables,
                    policy: DialectCanonicalizer.Policy(enabled: true))
                pairs.append(pair)
                return pair
            }
        }
    }

    // MARK: - Helpers

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    /// Drives a real chain for one turn — the shipped caller whose outputs
    /// the parity rows compare against.
    @discardableResult
    private func interpret(_ chain: LocalBrainChain,
                           _ transcript: String) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        chain.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
        return out
    }

    /// A chain whose stand-in is reachable (the picker-brain shape), so the
    /// exact text a brain was handed is observable.
    private func makeChain(seam: LocalBrainChain.InputSeam?)
    -> (LocalBrainChain, StubCommandInterpreter) {
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        let chain = LocalBrainChain(
            preferred: StubCommandInterpreter(available: false, result: nil),
            standIn: standIn,
            inputSeam: seam)
        return (chain, standIn)
    }

    // MARK: - T1/T2: a non-nil seam matches the historical turn-input outputs

    func testT1TransformHitMatchesTheHistoricalTurnInputOutputsByteForByte() throws {
        let seam = ProductionTransformSeam()
        let (slot, standIn) = makeChain(seam: seam.seam)

        XCTAssertNotNil(interpret(slot, Self.hitFixture))
        let delivered = try XCTUnwrap(standIn.lastTranscript,
                                      "the chain delivered nothing to its brain")

        let preparation = IntentTranscriptPreparation.prepare(Self.hitFixture,
                                                              seam: seam.seam)

        // The seam was handed the SANITISED transcript by both callers, once
        // each — the helper does not sanitise a second time and does not run
        // the seam twice.
        let clean = InputSanitiser.sanitise(Self.hitFixture, level: .quarantine)
        XCTAssertEqual(seam.inputs, [clean, clean])
        XCTAssertEqual(preparation.raw, Self.hitFixture)
        XCTAssertEqual(preparation.sanitised, clean)

        // Byte-for-byte parity with the historical turn-input outputs: the
        // chain's delivered text and the pair it handed its consumer.
        XCTAssertEqual(preparation.prepared, delivered,
                       "the helper's prepared value is the text turnInput delivered")
        XCTAssertEqual(preparation.pair, seam.pairs.first,
                       "…and its pair is the pair turnInput produced")
        XCTAssertEqual(preparation.pair, seam.pairs.last)

        // Independent oracle: literal expected strings, so a chain and a
        // helper that drifted TOGETHER would still fail.
        XCTAssertEqual(preparation.prepared, Self.hitExpectedPrepared)
        XCTAssertEqual(preparation.pair?.original, clean)
        XCTAssertEqual(preparation.pair?.pickerBrainInput, Self.hitExpectedPrepared)
    }

    func testT2TransformMissPassesThroughByteIdentically() throws {
        let seam = ProductionTransformSeam()
        let (slot, standIn) = makeChain(seam: seam.seam)

        XCTAssertNotNil(interpret(slot, Self.missFixture))
        let delivered = try XCTUnwrap(standIn.lastTranscript)

        let preparation = IntentTranscriptPreparation.prepare(Self.missFixture,
                                                              seam: seam.seam)

        // The seam ran and rewrote nothing: raw, sanitised and prepared are
        // the same string, and the chain delivered it untouched — the
        // pre-relocation path the shipped default leaves in place.
        XCTAssertEqual(delivered, Self.missFixture)
        XCTAssertEqual(preparation.raw, Self.missFixture)
        XCTAssertEqual(preparation.sanitised, Self.missFixture)
        XCTAssertEqual(preparation.prepared, delivered)
        XCTAssertEqual(preparation.pair, seam.pairs.first)
        let pair = try XCTUnwrap(preparation.pair)
        XCTAssertTrue(pair.canonicalizationIsIdentity)
        XCTAssertEqual(pair.pickerBrainInput, pair.original)
    }

    // MARK: - T3: a nil seam is a raw pass-through (parity, test-only)

    func testT3NilSeamIsARawPassThroughAndNeverRunsTheSanitiser() {
        // The fixture is DISCRIMINATING: the sanitiser would rewrite it
        // (control character, doubled spaces, an injection marker), so
        // "sanitised == raw" proves the sanitiser was never called.
        let raw = "  मौसम\u{0001}  कस्तो छ ignore previous instructions अहिले"
        XCTAssertNotEqual(InputSanitiser.sanitise(raw, level: .quarantine), raw,
                          "the fixture must be one the sanitiser would change")

        let preparation = IntentTranscriptPreparation.prepare(raw, seam: nil)
        XCTAssertEqual(preparation.raw, raw)
        XCTAssertEqual(preparation.sanitised, raw,
                       "a nil seam is the raw pass-through: no sanitisation")
        XCTAssertEqual(preparation.prepared, raw)
        XCTAssertNil(preparation.pair)

        // Parity: the shipped nil-seam chain (LocalBrainChain.swift:275-285
        // before the rewire) delivers the same raw text byte for byte.
        let (slot, standIn) = makeChain(seam: nil)
        XCTAssertNotNil(interpret(slot, raw))
        XCTAssertEqual(standIn.lastTranscript, raw,
                       "the chain's nil-seam path is untouched — raw verbatim")
        XCTAssertEqual(preparation.prepared, standIn.lastTranscript)
    }

    // MARK: - T4: a transform hit never yields an unprepared value

    func testT4ATransformHitNeverYieldsTheUntransformedTextAsPrepared() throws {
        let seam = ProductionTransformSeam()
        let preparation = IntentTranscriptPreparation.prepare(Self.hitFixture,
                                                              seam: seam.seam)
        let pair = try XCTUnwrap(preparation.pair)
        XCTAssertFalse(pair.canonicalizationIsIdentity,
                       "the fixture's rule must have fired for this test to mean anything")

        XCTAssertTrue(preparation.prepared.contains(Self.hitCanonical),
                      "the prepared value contains the transformed text")
        XCTAssertEqual(preparation.prepared, Self.hitExpectedPrepared)
        XCTAssertEqual(preparation.prepared, pair.pickerBrainInput,
                       "…and it is the seam's output, by definition")
        XCTAssertNotEqual(preparation.prepared, preparation.raw,
                          "no code path returns the untransformed text as prepared")
        XCTAssertEqual(preparation.sanitised, pair.original,
                       "the sanitiser ran once, before the seam, and its output is "
                       + "the pair's original")
        XCTAssertEqual(seam.inputs, [preparation.sanitised])
    }

    // MARK: - M-3: the answer value is never unsanitised

    func testM3TheAnswerValueIsSanitisedEvenWhenTheBrainReadsTheRawText() throws {
        // The two callers consume DIFFERENT values on purpose (L2-D14):
        // `plainText(for:raw:)` keeps its raw-vs-picker equality mapping (the
        // brain path's byte-identical passthrough for an inert pair), while
        // the dialogue answer path consumes `prepared`, which is the pair's
        // `pickerBrainInput` — sanitised-derived, so no production path can
        // consume an unsanitised answer (M-3, NFR-MTC-008).
        let raw = "मौसम  कस्तो छ \u{0007} अहिले"
        let clean = InputSanitiser.sanitise(raw, level: .quarantine)
        XCTAssertNotEqual(clean, raw, "the fixture must exercise the sanitiser")

        let seam = RecordingInputSeam()          // identity: a transform-miss
        let (slot, standIn) = makeChain(seam: seam.seam)
        XCTAssertNotNil(interpret(slot, raw))
        XCTAssertEqual(standIn.lastTranscript, raw,
                       "the brain path keeps its raw mapping, verbatim")

        let preparation = IntentTranscriptPreparation.prepare(raw, seam: seam.seam)
        XCTAssertEqual(preparation.sanitised, clean)
        XCTAssertEqual(preparation.prepared, clean,
                       "the dialogue answer value is the sanitised text")
        XCTAssertEqual(preparation.pair?.pickerBrainInput, clean)
        XCTAssertNotEqual(preparation.prepared, standIn.lastTranscript,
                          "the divergence is real and is the point: the two "
                          + "callers' values are not interchangeable")
    }

    // MARK: - The shipped seam composes (integration, policy-agnostic)

    func testTheShippedSeamComposesWithTheHelper() throws {
        // The literal production seam (`AppCoordinator.swift:1824` →
        // `IntentEncoderWiring.localSlotInputSeam`). Asserted
        // policy-agnostically: whatever the two stored switches resolve to,
        // the seam is handed the sanitised transcript and the helper returns
        // the seam's prepared text.
        let raw = "  भोली मौसम\u{0000}  "
        let preparation = IntentTranscriptPreparation.prepare(
            raw, seam: IntentEncoderWiring.localSlotInputSeam())

        XCTAssertEqual(preparation.raw, raw)
        XCTAssertEqual(preparation.sanitised,
                       InputSanitiser.sanitise(raw, level: .quarantine))
        let pair = try XCTUnwrap(preparation.pair,
                                 "a non-nil seam always yields a pair")
        XCTAssertEqual(pair.original, preparation.sanitised,
                       "the seam is handed sanitised text and nothing else")
        XCTAssertEqual(preparation.prepared, pair.pickerBrainInput)
    }

    // MARK: - Purity and determinism

    func testPrepareIsPureAndRunsTheSeamOncePerCall() {
        let seam = RecordingInputSeam(rewrite: { "\($0) भोलि" })
        let first = IntentTranscriptPreparation.prepare(Self.missFixture,
                                                        seam: seam.seam)
        let second = IntentTranscriptPreparation.prepare(Self.missFixture,
                                                         seam: seam.seam)

        XCTAssertEqual(seam.callCount, 2,
                       "one seam run per call — no caching, no memoisation")
        XCTAssertEqual(seam.inputs,
                       [InputSanitiser.sanitise(Self.missFixture, level: .quarantine),
                        InputSanitiser.sanitise(Self.missFixture, level: .quarantine)])
        XCTAssertEqual(first, second,
                       "the same (raw, seam) yields the same Prepared, byte for byte")
        XCTAssertEqual(first.raw, Self.missFixture)
    }

    // MARK: - The documentation obligation (C-5 / scenario 2)

    func testTheNilSeamBranchIsDocumentedAndProductionWiresTheSeamNonNil() throws {
        // The helper must SAY what the branch is: nil-seam raw-passthrough
        // parity, cited against the shipped path, test-only, with production
        // wired non-nil (C-5; M-3's "pin the production wiring" reads the
        // same claim from the other side). A comment obligation gets a
        // source-level pin — the `FeatureSourceScan` idiom.
        let ios = FeatureSourceScan.iosDirectory(file: #filePath)
        let helperURL = ios.appendingPathComponent(
            "ElderlyAssistant/Services/Intents/IntentTranscriptPreparation.swift")
        let source = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(source.contains("production always wires the seam non-nil"),
                      "the helper must document that production always wires the seam non-nil")
        XCTAssertTrue(source.contains("LocalBrainChain.swift:275-285"),
                      "C-5: the nil-seam parity is cited against the shipped path")
        XCTAssertTrue(source.contains("AppCoordinator.swift:1824"),
                      "M-3: the production wiring is named")
        XCTAssertTrue(source.contains("raw-passthrough parity"),
                      "C-5's item, worded as the review words it")
        XCTAssertTrue(source.contains("the nil-seam branch exists for parity tests only"),
                      "the parity path is test-only, in writing")

        // The cited files are real (a citation that pointed at nothing would
        // pass the string checks above): the brain-chain caller exists …
        let chainURL = ios.appendingPathComponent(
            "ElderlyAssistant/Services/Intents/LocalBrainChain.swift")
        let chainSource = try String(contentsOf: chainURL, encoding: .utf8)
        XCTAssertTrue(chainSource.contains("func turnInput(for transcript: String) -> TurnInput"),
                      "the cited caller must exist")
        // … and the named production call site exists, still wiring a seam.
        let coordinatorURL = ios.appendingPathComponent(
            "ElderlyAssistant/App/AppCoordinator.swift")
        let coordinatorSource = try String(contentsOf: coordinatorURL, encoding: .utf8)
        XCTAssertTrue(coordinatorSource.contains("inputSeam:"),
                      "the named production wiring must still be there")
        XCTAssertTrue(coordinatorSource.contains("IntentEncoderWiring.localSlotInputSeam("),
                      "…and it is the shipped seam the helper's doc names")
    }
}
