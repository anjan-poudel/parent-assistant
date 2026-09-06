import XCTest
@testable import ElderlyAssistant

/// The daily-cap honesty fix (2026-09-06) through `CommandRouter`'s real
/// fallback flow: when the day's Gemini budget is gone, a plain query —
/// which has NO deterministic keyword match — must come back as the
/// spoken cap message, NOT the generic "I didn't understand" re-prompt.
/// The cap is a budget state, not a comprehension failure; telling the
/// user the assistant "didn't understand" when it transcribed perfectly
/// was the reported bug's companion lie.
final class CappedGeminiRouterTests: XCTestCase {

    /// A configured-but-capped text-interpretation brain, exactly as a
    /// Whisper-STT + Gemini-interpretation session hits mid-day after the
    /// budget is exhausted (the collapsed STT path is not involved — the
    /// transcript arrives via a local recognizer).
    private func makeCappedInterpreter(bus: RecordingObservabilityBus)
    -> GeminiCommandInterpreter {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(),
                                          observabilityBus: MockObservabilityBus())
        governor.setSoftDailyCap(10)
        for _ in 0..<10 { governor.recordCall() }
        XCTAssertFalse(governor.allowsCall())
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: transport, costGovernor: governor)
        return GeminiCommandInterpreter(client: client, observabilityBus: bus)
    }

    func testCappedPlainQuerySpeaksCapMessageNotGenericReprompt() {
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: nil,
                                   interpreter: makeCappedInterpreter(bus: bus))

        let exp = expectation(description: "async dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        _ = router.route(transcript: "भोलि मौसम कस्तो हुन्छ?")
        waitForExpectations(timeout: 2)

        let capText = L10n.str("router.capReached", locale: Locale(identifier: "ne"))
        XCTAssertEqual(coordinator.genericReplies, [capText],
                       "a real reply path exists (the cap message) — the reply must be spoken, not the re-prompt")
        XCTAssertFalse(capText.isEmpty)
        XCTAssertNotEqual(capText, L10n.str("router.reprompt", locale: Locale(identifier: "ne")))
        XCTAssertTrue(bus.contains("command_llm_no_action"),
                      "the cap message dispatches as a spoken no-action reply")
        XCTAssertFalse(bus.contains("command_unrecognised"),
                       "the generic 'didn't understand' path must not run for a capped plain query")
    }
}
