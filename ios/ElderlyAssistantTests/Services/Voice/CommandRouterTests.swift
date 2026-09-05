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

    /// 2026-09-05: calling now asks for confirmation FIRST — the router's
    /// job is just to request it and speak the prompt. Nothing is dialed
    /// at this layer; `AppCoordinator.handleConfirmationResponse` does
    /// that only after the user says yes (covered by AppCoordinator-level
    /// testing, not here — this test is about CommandRouter's contract).
    func testCallWithResolvedContactRequestsConfirmationNotADial() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = "छोरालाई फोन गर्ने हो?"
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "छोरा", time: nil, medication: nil,
            message: nil, callType: "voice", requestedApp: nil, confidence: 0.95, reply: "ठिक छ, फोन गर्दैछु"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई फोन गर")

        XCTAssertEqual(coordinator.callConfirmationRequests.count, 1)
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.contact, "छोरा")
        XCTAssertEqual(coordinator.callConfirmationRequests.first?.callType, "voice")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "command_call_confirmation_requested" })
    }

    func testCallWithUnresolvedContactStaysBlocked() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.callConfirmationPrompt = nil
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .call, entryId: nil, contact: "अज्ञात व्यक्ति", time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, confidence: 0.95, reply: "ठिक छ"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "फोन गर")

        XCTAssertEqual(coordinator.callConfirmationRequests.first?.contact, "अज्ञात व्यक्ति")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "command_sensitive_blocked_auth_unavailable"
        })
    }

    /// The yes/no follow-up to a call confirmation must NOT speak the
    /// generic medication-flavored "confirmationYes" text — AppCoordinator
    /// owns that response for calls (see `isAwaitingCallConfirmation`).
    func testCallConfirmationYesDoesNotSpeakGenericMedicationText() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.isAwaitingConfirmation = true
        coordinator.isAwaitingCallConfirmation = true
        let speaker = MockSpeaker()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(),
                                   speaker: speaker)

        let result = router.route(transcript: "हजुर")

        XCTAssertEqual(result, .callConfirmed)
        XCTAssertEqual(coordinator.confirmationResponses, [.yes])
        XCTAssertTrue(speaker.utterances.isEmpty,
                      "CommandRouter must not also speak — AppCoordinator speaks its own call-specific response")
    }

    /// Regression: a plain Q&A reply (`.query`/`.none`) previously had NO
    /// visible trace at all — only the tracked actions (ack/reminder/
    /// call/message) produced an outcome card. Found via a real device
    /// test where the user reported "no transcript got written" for an
    /// ordinary question.
    func testQueryReplyProducesAVisibleGenericOutcome() {
        let coordinator = MockVoiceCommandCoordinator()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, confidence: 0.9, reply: "आज घमाइलो छ।"
        )
        let router = CommandRouter(coordinator: coordinator, observabilityBus: MockObservabilityBus(),
                                   speaker: MockSpeaker(), interpreter: interpreter)

        _ = router.route(transcript: "आजको मौसम कस्तो छ")

        XCTAssertEqual(coordinator.genericReplies, ["आज घमाइलो छ।"])
    }

    func testSendMessageWithResolvedContactPresentsComposeSheet() {
        let coordinator = MockVoiceCommandCoordinator()
        coordinator.messageShouldSucceed = true
        let bus = MockObservabilityBus()
        let interpreter = FakeCommandInterpreter()
        interpreter.nextCommand = InterpretedCommand(
            action: .sendMessage, entryId: nil, contact: "छोरी", time: nil, medication: nil,
            message: "म राम्रो छु", callType: nil, requestedApp: nil, confidence: 0.95, reply: "सन्देश तयार छ"
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
    var genericReplies: [String] = []
    func noteGenericReply(_ text: String) { genericReplies.append(text) }

    func addVoiceReminder(title: String, time: DateComponents) {
        addedReminders.append((title, time))
    }

    var isAwaitingCallConfirmation = false
    var callConfirmationPrompt: String? = "फोन गर्ने हो?"
    var callConfirmationRequests: [(contact: String?, callType: String?, requestedApp: String?)] = []
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?) -> String? {
        callConfirmationRequests.append((contactQuery, callType, requestedApp))
        return callConfirmationPrompt
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
