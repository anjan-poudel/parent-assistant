import XCTest
@testable import ElderlyAssistant

/// The 2026-09-05 routing-ladder reorder (spec §4): the deterministic
/// safety net — emergency + explicit med-ack + the denial guard — runs
/// BEFORE any model, so a CONFIDENT wrong model answer can never swallow
/// a safety-critical utterance (the live 2026-09-04 failure: Gemini
/// classified "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" as health_query).
final class CommandRouterSafetyNetTests: XCTestCase {

    private func makeRouter(interpreter: CommandInterpreter)
    -> (CommandRouter, StubCoordinator, RecordingObservabilityBus) {
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: nil,
                                   interpreter: interpreter)
        return (router, coordinator, bus)
    }

    func testEmergencyKeywordFiresBeforeConfidentInterpreter() {
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .healthQuery, confidence: 0.99))
        let (router, _, bus) = makeRouter(interpreter: interpreter)

        let result = router.route(transcript: "मद्दत गर्नुहोस्")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertEqual(interpreter.callCount, 0,
                       "emergency must never wait on — or be swallowed by — a model")
        XCTAssertTrue(bus.contains("command_emergency_keyword"))
    }

    func testExplicitAckFiresBeforeInterpreter() {
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.99))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)
        let entryId = UUID()
        coordinator.pendingEntryId = entryId

        let result = router.route(transcript: "औषधि खाएँ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(interpreter.callCount, 0)
        XCTAssertEqual(coordinator.challengeIssuedFor, entryId)
    }

    func testDenialGuardFiresBeforeInterpreter() {
        // "नखाए" contains the ack token "खाए" — the denial guard must run
        // first or a refusal becomes a recorded dose.
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .ackMed, confidence: 0.99))
        let (router, coordinator, bus) = makeRouter(interpreter: interpreter)
        coordinator.pendingEntryId = UUID()

        _ = router.route(transcript: "औषधि खाएको छैन")

        XCTAssertEqual(interpreter.callCount, 0)
        XCTAssertNil(coordinator.challengeIssuedFor)
        XCTAssertTrue(bus.contains("command_ack_denied_keyword"))
    }

    func testNonSafetyUtteranceStillReachesInterpreter() {
        // [NO-GIBBERISH] (2026-09-07) Transcript switched from a weather
        // question to a neutral open request: weather ("भोलि मौसम कस्तो
        // हुन्छ") is now a deterministic TopicPreAnswer that intercepts
        // BEFORE the interpreter, so it would no longer exercise the
        // model path this test pins.
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.9, reply: "भोलि घाम लाग्नेछ।"))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        let exp = expectation(description: "async dispatch")
        DispatchQueue.main.async {
            if !coordinator.genericReplies.isEmpty { exp.fulfill() }
        }
        _ = router.route(transcript: "केही राम्रो कथा सुनाउनुस्")

        XCTAssertEqual(interpreter.callCount, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(coordinator.genericReplies, ["भोलि घाम लाग्नेछ।"])
    }

    func testInterpreterAbstainFallsToKeywordRemainder() {
        // Interpreter available but abstains → the REMAINDER of the
        // keyword layer (not the safety net — that already ran) handles
        // it: a call-ish phrase with no entity extraction stays blocked.
        let interpreter = StubCommandInterpreter(result: nil)
        let (router, _, bus) = makeRouter(interpreter: interpreter)

        let exp = expectation(description: "async fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: "कसैलाई फोन गर")
        waitForExpectations(timeout: 2)

        XCTAssertTrue(bus.contains("command_sensitive_blocked_auth_unavailable"))
    }
}

extension CommandRouterSafetyNetTests {

    /// REPHRASE-as-question (spec §4 decision #6): a mid-band tier-free
    /// command is stated as a yes/no question, not dropped, not dispatched.
    func testMidBandTierFreeBecomesAQuestion() {
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .music, confidence: 0.5))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        let exp = expectation(description: "async interpret")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: "केही भजन जस्तो बजाउनुस्")
        waitForExpectations(timeout: 2)

        XCTAssertNotNil(coordinator.rephrasePended,
                        "mid-band tier-free must pend as a question, not dispatch")
        XCTAssertEqual(coordinator.rephrasePended?.sourceTranscript, "केही भजन जस्तो बजाउनुस्")
    }

    func testRephraseYesDispatchesThePendedCommand() {
        // [NO-GIBBERISH] (2026-09-07) Transcript switched from "मौसम कस्तो
        // होला" to a neutral request — weather is now a deterministic
        // TopicPreAnswer and would be intercepted before the mid-band
        // rephrase flow this test pins.
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.5, reply: "भोलि घाम लाग्नेछ।"))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        var exp = expectation(description: "question")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: "केही राम्रो कुरा बताउनुस्")
        waitForExpectations(timeout: 2)
        XCTAssertNotNil(coordinator.rephrasePended)

        exp = expectation(description: "dispatch after yes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        _ = router.route(transcript: "हो")
        waitForExpectations(timeout: 2)

        XCTAssertNil(coordinator.rephrasePended)
        XCTAssertEqual(coordinator.genericReplies, ["भोलि घाम लाग्नेछ।"],
                       "a yes must dispatch the pended command's reply")
    }

    func testRephraseNoDiscardsWithoutDispatch() {
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.5, reply: "kehi"))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        var exp = expectation(description: "question")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: "kehi question hola")
        waitForExpectations(timeout: 2)

        exp = expectation(description: "discard after no")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        _ = router.route(transcript: "होइन")
        waitForExpectations(timeout: 2)

        XCTAssertNil(coordinator.rephrasePended)
        XCTAssertTrue(coordinator.genericReplies.isEmpty,
                      "a no must discard without dispatching")
    }
}

// MARK: - TG-12: the canonicalizer's freeze vs. the shipped net

/// `CanonicalSafetyFreeze` (TG-12, `DialectCanonicalizer.swift`) decides which
/// variant rules may fire by mirroring the routing vocabulary it must not
/// disturb. The router's lists are `private` (`CommandRouter.swift:1468-1534`),
/// so the mirror is a hand-copy, and a hand-copy can drift.
///
/// These tests are the drift alarm. Every member of every frozen list is driven
/// through the SHIPPED `route()` and must produce the decision the list exists
/// for: an emergency must still trigger, a denial must still outrank an ack, an
/// ack must still land. A member the net no longer honours fails here, which is
/// the moment the mirror stopped describing the router.
///
/// The other direction — a phrase ADDED to the router's lists — is invisible to
/// in-process code (private storage, no accessor), so it is kept by citation
/// instead: a diff that touches `CommandRouter.swift:1468-1534` must carry the
/// matching change to `CanonicalSafetyFreeze` in the same commit. The freeze's
/// doc comments name the line range each list mirrors for exactly that review.
extension CommandRouterSafetyNetTests {

    /// The emergency list (`CanonicalSafetyFreeze.emergencyList` ↔
    /// `CommandRouter.swift:1468-1473`) — the constitution's "never blocked, by
    /// anything, ever" vocabulary.
    func testCanonicalizerFreezeEmergencyListStillTripsTheShippedNet() {
        for phrase in CanonicalSafetyFreeze.emergencyList {
            let interpreter = StubCommandInterpreter(
                result: makeCommand(action: .healthQuery, confidence: 0.99))
            let (router, _, bus) = makeRouter(interpreter: interpreter)

            let result = router.route(transcript: phrase)

            XCTAssertEqual(result, .emergencyTriggered,
                           "frozen emergency phrase no longer trips the net: \(phrase)")
            XCTAssertEqual(interpreter.callCount, 0,
                           "emergency must never wait on a model: \(phrase)")
            XCTAssertTrue(bus.contains("command_emergency_keyword"))
        }
    }

    /// The denial guard (`CanonicalSafetyFreeze.denialPhrases` ↔
    /// `CommandRouter.swift:1508-1512`). Each member must reach the denial
    /// branch and never the ack branch: `नखाए` contains the ack token `खाए`, and
    /// a refusal recorded as a dose is the failure this list exists to prevent.
    func testCanonicalizerFreezeDenialListStillDeniesBeforeItAcknowledges() {
        for phrase in CanonicalSafetyFreeze.denialPhrases {
            let interpreter = StubCommandInterpreter(
                result: makeCommand(action: .ackMed, confidence: 0.99))
            let (router, coordinator, bus) = makeRouter(interpreter: interpreter)
            coordinator.pendingEntryId = UUID()

            let result = router.route(transcript: phrase)

            XCTAssertNotEqual(result, .acknowledgedMedication,
                              "frozen denial phrase was acknowledged: \(phrase)")
            XCTAssertEqual(interpreter.callCount, 0,
                           "the denial guard must not wait on a model: \(phrase)")
            XCTAssertNil(coordinator.challengeIssuedFor,
                         "a refusal must not open a dose challenge: \(phrase)")
            XCTAssertTrue(bus.contains("command_ack_denied_keyword"),
                          "denial branch not taken for: \(phrase)")
        }
    }

    /// The acknowledgement lists (`CanonicalSafetyFreeze.acknowledgementPhrases`
    /// / `.acknowledgementTokens` ↔ `CommandRouter.swift:1519-1529`). Every
    /// member must still be acknowledged — and with a pending reminder, must
    /// still open the FR-D01 challenge rather than recording the dose outright.
    func testCanonicalizerFreezeAckListsStillAcknowledge() {
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .ackMed, confidence: 0.99))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)
        let entryId = UUID()
        coordinator.pendingEntryId = entryId

        for phrase in CanonicalSafetyFreeze.acknowledgementPhrases {
            XCTAssertEqual(router.route(transcript: phrase), .acknowledgedMedication,
                           "frozen ack phrase no longer acknowledges: \(phrase)")
            XCTAssertEqual(coordinator.challengeIssuedFor, entryId,
                           "ack must open the dose challenge: \(phrase)")
        }
        for token in CanonicalSafetyFreeze.acknowledgementTokens {
            XCTAssertEqual(router.route(transcript: token), .acknowledgedMedication,
                           "frozen ack token no longer acknowledges: \(token)")
            XCTAssertEqual(coordinator.challengeIssuedFor, entryId,
                           "ack must open the dose challenge: \(token)")
        }
        XCTAssertEqual(interpreter.callCount, 0,
                       "the safety net must never wait on a model")
    }

    /// Whitespace parity. The net collapses interior whitespace before its
    /// emergency check (`CommandRouter.swift:606-620` — the STT joins
    /// per-segment text with single spaces), and the freeze's matchers fold the
    /// same way. A transcript one of them ruled an emergency and the other did
    /// not is exactly the mismatch the freeze exists to prevent: the
    /// canonicalizer would then be licensed to rewrite a distress utterance the
    /// net is about to act on.
    func testTheFreezesWhitespaceFoldMatchesTheNets() {
        let multiSegment = "मद्दत  गर्नुहोस्"
        let interpreter = StubCommandInterpreter(result: nil)
        let (router, _, _) = makeRouter(interpreter: interpreter)

        XCTAssertEqual(router.route(transcript: multiSegment), .emergencyTriggered)
        XCTAssertEqual(interpreter.callCount, 0)
        XCTAssertTrue(CanonicalSafetyFreeze.matchedClauses(in: multiSegment).contains(.emergency),
                      "the freeze must read the same transcript the net acted on")
    }

    // MARK: Composition (design §4.6, D-1)

    /// The `भया → भयो` row as an authored table — T-062's confirmed Doteli
    /// past-tense drift, and the fixture for the containment hazard §4.7 names:
    /// `भयो` is an acknowledgement TOKEN (`CommandRouter.swift:1528-1529`), so a
    /// rule that fired would turn a sentence the net ignores into a recorded
    /// dose.
    ///
    /// Built here rather than imported from the shipped banks because the
    /// shipped banks must not contain it: `VariantTable.issues()` refuses this
    /// row (`negationMarkerTouched`), which is why the table is inert and the
    /// assertion below is "nothing was rewritten".
    private func bhayaTableSet() -> VariantTableSet {
        let entry = VariantTableEntry(
            id: "dot-past-bhaya",
            kindRaw: "lexical",
            variant: "भया",
            canonical: "भयो",
            status: .confirmed,
            modelImpact: "known_word",
            resolves: ["N3"],
            note: "synthetic: the refused T-062 row, used as the D-1 fixture",
            evidence: VariantTableEntry.Evidence(source: .authored,
                                                 corpusRevision: nil,
                                                 rowIDs: [],
                                                 occurrences: 0,
                                                 fixtureExamples: ["भया", "हो, म भया"])
        )
        let table = VariantTable(
            formatVersion: 1,
            tableID: "canonical-doteli",
            dialectRaw: DialectLabel.doteli.rawValue,
            generation: VariantTable.Generation(status: "TEST", path: "test", date: nil),
            entries: [entry]
        )
        return VariantTableSet(orthographic: nil,
                               panRegional: nil,
                               sttReductions: nil,
                               dialectTables: [.doteli: table],
                               loadIssues: [])
    }

    /// D-1 at the seam, in both directions.
    ///
    /// The hazard is real — routing the CANONICAL form records a dose — and the
    /// ORIGINAL, which is what the router is handed, does not. With the
    /// canonicalizer inert this is also the shipped behaviour; the test fails
    /// the moment the canonical form is allowed to reach a safety consumer.
    func testSafetyNetSeesTheOriginalTranscriptNotACanonicalForm() {
        // Direction 1: the canonical form IS an acknowledgement, so a
        // canonicalizing safety net would record a dose here.
        let (ackingRouter, ackingCoordinator, _) = makeRouter(
            interpreter: StubCommandInterpreter())
        ackingCoordinator.pendingEntryId = UUID()
        XCTAssertEqual(ackingRouter.route(transcript: "भयो"), .acknowledgedMedication)

        // Direction 2: the table that would produce it is refused, and the pair
        // hands the net the original regardless.
        let tables = bhayaTableSet()
        XCTAssertEqual(tables.dialectTables[.doteli]?.issues().count, 1,
                       "the भया → भयो row must be refused by the freeze")
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: "हो, म भया",
            dialect: .doteli,
            tables: tables,
            policy: IntentInputCanonicalization.Policy(
                enabled: true, orthographicOnly: false, includeConditionalTables: true))

        XCTAssertEqual(pair.original, "हो, म भया")
        XCTAssertEqual(pair.modelInput, "हो, म भया",
                       "a refused table must canonicalize nothing")
        XCTAssertTrue(pair.isIdentity)
        XCTAssertEqual(pair.safetyNetInput, pair.original)

        let interpreter = StubCommandInterpreter(result: nil)
        let (router, coordinator, bus) = makeRouter(interpreter: interpreter)
        coordinator.pendingEntryId = UUID()
        let result = router.route(transcript: pair.safetyNetInput)

        XCTAssertNotEqual(result, .acknowledgedMedication)
        XCTAssertNil(coordinator.challengeIssuedFor)
        XCTAssertFalse(bus.contains("command_ack_challenge_issued"))
        XCTAssertFalse(bus.contains("command_ack_medication_baseline"))
    }

    /// A synthetic orthographic rule — `केही → केहि` — that genuinely rewrites
    /// the text a MODEL reads while changing no keyword-layer clause. Built
    /// here because every SHIPPED rule is required to leave the clause sets
    /// alone, so no shipped table can demonstrate "the model input differs and
    /// the safety input does not".
    private func kehiTableSet() -> VariantTableSet {
        let entry = VariantTableEntry(
            id: "test-orth-kehi",
            kindRaw: "orthographic",
            variant: "केही",
            canonical: "केहि",
            status: .confirmed,
            modelImpact: "known_word",
            resolves: [],
            note: "synthetic: a rewrite with no routing consequence",
            evidence: VariantTableEntry.Evidence(
                source: .authored,
                corpusRevision: nil,
                rowIDs: [],
                occurrences: 0,
                fixtureExamples: ["केही राम्रो कथा", "केही भन्नुहोस्"])
        )
        let table = VariantTable(
            formatVersion: 1,
            tableID: "canonical-orthographic",
            dialectRaw: nil,
            generation: VariantTable.Generation(status: "TEST", path: "test", date: nil),
            entries: [entry]
        )
        return VariantTableSet(orthographic: table,
                               panRegional: nil,
                               sttReductions: nil,
                               dialectTables: [:],
                               loadIssues: [])
    }

    /// The composition's whole point, with the two inputs actually differing:
    /// the pair carries a canonical form that is NOT the original, the safety
    /// consumer is handed the original, and the model consumer's string is the
    /// one the interpreter would tokenize.
    func testTheRouterIsHandedTheOriginalWhileTheModelGetsTheCanonical() {
        let utterance = "केही राम्रो कथा सुनाउनुस्"
        let pair = IntentInputCanonicalization.prepare(
            sanitisedTranscript: utterance,
            dialect: .default,
            tables: kehiTableSet(),
            policy: IntentInputCanonicalization.Policy(enabled: true))

        XCTAssertEqual(pair.modelInput, "केहि राम्रो कथा सुनाउनुस्",
                       "the fixture must actually rewrite, or this test proves nothing")
        XCTAssertNotEqual(pair.modelInput, pair.original)
        XCTAssertEqual(pair.safetyNetInput, utterance)
        XCTAssertEqual(pair.pickerBrainInput, utterance,
                       "the picker brain reads the original too (§4.6)")
        XCTAssertTrue(CanonicalSafetyFreeze.isKeywordLayerLossless(
            original: pair.original, canonical: pair.modelInput),
            "a legal rule must change no routing clause")

        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.9, reply: "ठीक छ"))
        let (router, _, _) = makeRouter(interpreter: interpreter)

        let exp = expectation(description: "async interpret")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: pair.safetyNetInput)
        waitForExpectations(timeout: 2)

        XCTAssertEqual(interpreter.lastTranscript, pair.original,
                       "the router hands the interpreter the ORIGINAL transcript")
        XCTAssertNotEqual(interpreter.lastTranscript, pair.modelInput,
                          "the canonical form must not reach the router")
    }
}
