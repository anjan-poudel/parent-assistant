import XCTest
@testable import ElderlyAssistant

final class CommandRouterTests: XCTestCase {

    func testNepaliMedicationAcknowledgementRoutesToOldestPendingReminder() {
        let coordinator = MockVoiceCommandCoordinator()
        let reminderId = UUID()
        coordinator.pendingReminderId = reminderId
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: MockObservabilityBus(),
            speaker: MockSpeaker()
        )

        let result = router.route(transcript: "मैले औषधि खाएँ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.confirmationChallengeEntryIds, [reminderId])
        XCTAssertTrue(coordinator.acknowledgedEntryIds.isEmpty)
        XCTAssertEqual(coordinator.recordedTranscripts, ["मैले औषधि खाएँ"])
    }

    // MARK: - Emergency (deterministic keyword net — see CommandRouter.emergencyPhrases)

    /// Regression for a real bug found via live testing against the Gemini
    /// API (2026-09-04): "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" (help, my
    /// kidney hurts) was classified `health_query` by the LLM, not
    /// `emergency`. This deterministic net must catch it independent of
    /// the LLM's classification, since it never even reaches the LLM
    /// (`NullCommandInterpreter` in this test — the router falls straight
    /// to `routeKeyword`).
    func testDistressPhraseWithSymptomTriggersEmergencyDeterministically() {
        let coordinator = MockVoiceCommandCoordinator()
        let bus = MockObservabilityBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus, speaker: MockSpeaker())

        let result = router.route(transcript: "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_emergency_keyword" })
    }

    func testEnglishHelpPhraseTriggersEmergency() {
        let coordinator = MockVoiceCommandCoordinator()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(), speaker: MockSpeaker())

        let result = router.route(transcript: "please help me")

        XCTAssertEqual(result, .emergencyTriggered)
    }

    func testEmergencyIsCheckedBeforeMedicationAckSoItCannotBeShadowed() {
        // A distress phrase must win even if it happens to also contain an
        // ack-shaped word — emergency is checked first in routeKeyword.
        let coordinator = MockVoiceCommandCoordinator()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(), speaker: MockSpeaker())

        let result = router.route(transcript: "सहयोग गर्नुहोस्, मैले औषधि खाएँ तर लडेँ")

        XCTAssertEqual(result, .emergencyTriggered)
    }

    func testSensitiveCallCommandIsBlockedUntilAuthExists() async {
        let coordinator = MockVoiceCommandCoordinator()
        let speaker = MockSpeaker()
        let bus = MockObservabilityBus()
        let router = CommandRouter(
            coordinator: coordinator,
            observabilityBus: bus,
            speaker: speaker
        )

        let result = router.route(transcript: "छोरालाई फोन गर")
        await Task.yield()

        XCTAssertEqual(result, .blockedSensitiveAction)
        XCTAssertTrue(coordinator.acknowledgedEntryIds.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_sensitive_blocked_auth_unavailable"
        })
    }

    // MARK: - Trial wiring: voice call / send message (LLM-interpreted path)

    func testCallWithResolvedContactPlacesRealCall() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callShouldSucceed = true
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil, medication: nil,
            message: nil, confidence: 0.95, reply: "ठिक छ, फोन गर्दैछु"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई फोन गर")

        XCTAssertEqual(coordinator.placedCalls, ["छोरा"])
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_call_placed" })
    }

    func testCallWithUnresolvedContactStaysBlocked() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callShouldSucceed = false
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "अज्ञात व्यक्ति", time: nil, medication: nil,
            message: nil, confidence: 0.95, reply: "ठिक छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "फोन गर")

        XCTAssertEqual(coordinator.placedCalls, ["अज्ञात व्यक्ति"])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_sensitive_blocked_auth_unavailable"
        })
    }

    func testSendMessageWithResolvedContactPresentsComposeSheet() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.messageShouldSucceed = true
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .sendMessage, entryId: nil, contact: "छोरी", time: nil, medication: nil,
            message: "म राम्रो छु", confidence: 0.95, reply: "सन्देश तयार छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरीलाई सन्देश पठाऊ, म राम्रो छु")

        XCTAssertEqual(coordinator.composedMessages.count, 1)
        XCTAssertEqual(coordinator.composedMessages.first?.contact, "छोरी")
        XCTAssertEqual(coordinator.composedMessages.first?.body, "म राम्रो छु")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_message_composing" })
    }
}

/// Deterministic `CommandInterpreter` double: fires its completion
/// synchronously so tests don't need to await a dispatch gap.
private final class FakeCommandInterpreter: CommandInterpreter {
    var isAvailable = true
    var nextCommand: InterpretedCommand?

    func interpret(transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        completion(nextCommand)
    }
}

private final class MockVoiceCommandCoordinator: VoiceCommandCoordinating {
    var recordedTranscripts: [String] = []
    var pendingReminderId: UUID?
    var acknowledgedEntryIds: [UUID] = []
    var confirmationChallengeEntryIds: [UUID] = []
    var confirmationResponses: [ConfirmationResponse] = []
    var confirmationPrompt: String? = "के तपाईंले औषधि अहिले लिनुभएको हो?"
    var isAwaitingConfirmation = false
    var addedReminders: [(title: String, time: DateComponents)] = []

    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    func recordTranscript(_ text: String) {
        recordedTranscripts.append(text)
    }

    func oldestPendingReminderEntryId() -> UUID? {
        pendingReminderId
    }

    func handleMedicationAcknowledgement(entryId: UUID) {
        acknowledgedEntryIds.append(entryId)
    }

    func startVoiceAckConfirmation(for entryId: UUID) -> String? {
        confirmationChallengeEntryIds.append(entryId)
        isAwaitingConfirmation = confirmationPrompt != nil
        return confirmationPrompt
    }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        confirmationResponses.append(response)
        isAwaitingConfirmation = false
    }

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) {}

    func addVoiceReminder(title: String, time: DateComponents) {
        addedReminders.append((title, time))
    }

    var placedCalls: [String?] = []
    var callShouldSucceed = false
    func placeCall(toContactNamed name: String?) -> Bool {
        placedCalls.append(name)
        return callShouldSucceed
    }

    var composedMessages: [(contact: String?, body: String)] = []
    var messageShouldSucceed = false
    func composeMessage(toContactNamed name: String?, body: String) -> Bool {
        composedMessages.append((name, body))
        return messageShouldSucceed
    }
}

private final class MockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}
