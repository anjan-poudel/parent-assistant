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
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.9, reply: "भोलि घाम लाग्नेछ।"))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        let exp = expectation(description: "async dispatch")
        DispatchQueue.main.async {
            if !coordinator.genericReplies.isEmpty { exp.fulfill() }
        }
        _ = router.route(transcript: "भोलि मौसम कस्तो हुन्छ")

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
        let interpreter = StubCommandInterpreter(
            result: makeCommand(action: .query, confidence: 0.5, reply: "भोलि घाम लाग्नेछ।"))
        let (router, coordinator, _) = makeRouter(interpreter: interpreter)

        var exp = expectation(description: "question")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        _ = router.route(transcript: "मौसम कस्तो होला")
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
