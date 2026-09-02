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
}

private final class MockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}
