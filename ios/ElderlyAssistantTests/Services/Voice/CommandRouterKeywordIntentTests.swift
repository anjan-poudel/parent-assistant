import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [INTENT-KEYWORDS] (2026-09-11) Router wiring for the relaxed keyword
/// co-occurrence stage: utterances the strict form-gates decline are
/// resolved from their keyword sets, the same handlers fire as the
/// strict stages, every relaxed claim emits `intent_keyword_match`
/// (domain + matched keys), and the safety ladder keeps strict
/// utterances ahead of the table.
final class CommandRouterKeywordIntentTests: XCTestCase {

    private final class MockCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }
        var newsFireCount = 0
        var briefingFireCount = 0

        func recordTranscript(_ text: String) {}
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) {}
        func noteGenericReply(_ text: String) {}
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?,
                                     requestedApp: String?,
                                     sourceTranscript: String?,
                                     sourceCommand: InterpretedCommand?) -> String? { nil }
        var pendingRephraseCommand: InterpretedCommand? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
        func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        func fireMorningBriefing() { briefingFireCount += 1 }
        func fireNewsReader() { newsFireCount += 1 }
    }

    private final class MockBus: ObservabilityBus {
        var emitted: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { emitted.append(event) }
    }

    private final class MockSpeaker: Speaker {
        func speak(_ text: String, locale: Locale) async {}
        func cancel() {}
    }

    private final class FakeOpener: CallLinkOpening {
        var canOpen = true
        private(set) var opened: [URL] = []
        func canOpenURL(_ url: URL) -> Bool { canOpen }
        func open(_ url: URL) { opened.append(url) }
    }

    private func makeRouter(_ coordinator: MockCoordinator,
                            opener: FakeOpener? = nil)
        -> (CommandRouter, MockBus) {
        let bus = MockBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   interpreter: NullCommandInterpreter(),
                                   youtubeLinkOpener: opener)
        return (router, bus)
    }

    private func keywordMatchEvents(_ bus: MockBus) -> [ObservabilityEvent] {
        bus.emitted.filter { $0.eventType == "intent_keyword_match" }
    }

    // MARK: - Relaxed news claims utterances the strict form-gates decline

    func testRelaxedNewsFiresTheReaderAndEmitsKeywordMatch() {
        let coordinator = MockCoordinator()
        let (router, bus) = makeRouter(coordinator)
        let utterance = "हजुर, आजको समाचार सुनाइदिनुस् न"

        let result = router.route(transcript: utterance)

        XCTAssertEqual(coordinator.newsFireCount, 1)
        XCTAssertEqual(result, .unrecognised(transcript: utterance),
                       "the relaxed stage hands off and ends the turn — the reader speaks")
        let events = keywordMatchEvents(bus)
        XCTAssertEqual(events.count, 1, "a relaxed claim must be observable exactly once")
        XCTAssertEqual(events.first?.metadata["domain"], "news")
        XCTAssertEqual(events.first?.metadata["matched_keys"], "समाचार,सुनाइदिनुस्")
        XCTAssertTrue(bus.emitted.contains {
            $0.eventType == "news_reader_command" && $0.outcome == "success"
        })
    }

    func testBareSamacharWithGreetingFiresTheNewsReader() {
        let coordinator = MockCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "नमस्ते, समाचार")

        XCTAssertEqual(coordinator.newsFireCount, 1)
        XCTAssertEqual(keywordMatchEvents(bus).first?.metadata["domain"], "news")
    }

    func testStrictNewsMatchNeverEmitsKeywordMatch() {
        // A strict phrase ("read me the news") is claimed by the strict
        // stage — the relaxed event must not fire for it.
        let coordinator = MockCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "read me the news")

        XCTAssertEqual(coordinator.newsFireCount, 1)
        XCTAssertTrue(keywordMatchEvents(bus).isEmpty,
                      "strict matches stay strict — no relaxed event")
    }

    // MARK: - Relaxed YouTube claims utterances the strict gate declines

    func testRelaxedYouTubeOpensSearchAndEmitsKeywordMatch() {
        let coordinator = MockCoordinator()
        let opener = FakeOpener()
        let (router, bus) = makeRouter(coordinator, opener: opener)

        _ = router.route(transcript: "search songs on youtube")

        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "songs")])
        let events = keywordMatchEvents(bus)
        XCTAssertEqual(events.count, 1, "a relaxed claim must be observable exactly once")
        XCTAssertEqual(events.first?.metadata["domain"], "youtube")
        XCTAssertEqual(events.first?.metadata["matched_keys"], "youtube,search")
        XCTAssertTrue(bus.emitted.contains {
            $0.component == "youtube" && $0.eventType == "youtube_search"
        })
    }

    func testDeviceUtteranceResolvesYouTubeNotNews() {
        // "हाम्लाई युट्युबमा नेपाली न्युज चलाइदिनुस् न है त" — the
        // utterance the directive names. The strict YouTube stage claims
        // it first (चलाइदिनुस् is an enumerated form); either way it
        // must resolve to a YouTube play, never the news digest.
        let coordinator = MockCoordinator()
        let opener = FakeOpener()
        let (router, _) = makeRouter(coordinator, opener: opener)

        _ = router.route(transcript: "हाम्लाई युट्युबमा नेपाली न्युज चलाइदिनुस् न है त")

        XCTAssertEqual(coordinator.newsFireCount, 0,
                       "the utterance carries a YouTube verb, not a news verb — the news rule must not claim it")
        XCTAssertEqual(opener.opened.count, 1,
                       "the utterance must open exactly one YouTube surface")
    }

    func testStrictYouTubeMatchNeverEmitsKeywordMatch() {
        let coordinator = MockCoordinator()
        let opener = FakeOpener()
        let (router, bus) = makeRouter(coordinator, opener: opener)

        _ = router.route(transcript: "play bhajan on youtube")

        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertTrue(keywordMatchEvents(bus).isEmpty,
                      "strict matches stay strict — no relaxed event")
    }

    // MARK: - Safety pins: strict stages always win over the relaxed table

    func testEmergencyWinsOverRelaxedKeywordSets() {
        let coordinator = MockCoordinator()
        let opener = FakeOpener()
        let (router, bus) = makeRouter(coordinator, opener: opener)

        let result = router.route(transcript: "help me play news on youtube")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertEqual(coordinator.newsFireCount, 0)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(bus.emitted.contains { $0.eventType == "command_emergency_keyword" })
        XCTAssertTrue(keywordMatchEvents(bus).isEmpty,
                      "the safety net claims the utterance before the relaxed table is consulted")
    }

    func testMedicationAckWinsOverRelaxedNewsKeywords() {
        let coordinator = MockCoordinator()
        let (router, _) = makeRouter(coordinator)

        let result = router.route(transcript: "मैले औषधि खाएँ, समाचार सुनाऊ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.newsFireCount, 0,
                       "the med-ack safety net runs before the relaxed table, always")
    }

    func testConfirmationFlowWinsOverRelaxedKeywords() {
        let coordinator = MockCoordinator()
        coordinator.isAwaitingConfirmation = true
        let opener = FakeOpener()
        let (router, _) = makeRouter(coordinator, opener: opener)

        _ = router.route(transcript: "समाचार युट्युबमा सुनाऊ")

        XCTAssertEqual(coordinator.newsFireCount, 0)
        XCTAssertTrue(opener.opened.isEmpty,
                      "an outstanding confirmation owns the next transcript, whatever keywords it carries")
    }

    func testAlarmAndTimerVocabularyNeverReachesTheRelaxedTable() {
        let coordinator = MockCoordinator()
        let opener = FakeOpener()
        let (router, bus) = makeRouter(coordinator, opener: opener)

        _ = router.route(transcript: "अलार्म बजाऊ")
        _ = router.route(transcript: "पाँच मिनेटको टाइमर लगाऊ")

        XCTAssertEqual(coordinator.newsFireCount, 0)
        XCTAssertTrue(opener.opened.isEmpty,
                      "alarm/timer vocabulary carries no relaxed keyword set — the table can never claim it")
        XCTAssertTrue(keywordMatchEvents(bus).isEmpty)
    }

    // MARK: - Topic pre-answers: already keywordish (verified — no relaxation needed)

    func testTopicPreAnswersAlreadyResolveNoisyUtterances() {
        // The weather/time/date/greeting table matches on keyword
        // co-occurrence already (token/phrase, no form validation) — a
        // noisy greeting-prefixed question must still answer from the
        // table, with no relaxed rule involved.
        let coordinator = MockCoordinator()
        let (router, bus) = makeRouter(coordinator)

        _ = router.route(transcript: "नमस्ते हजुर, आजको मौसम कस्तो छ है?")
        _ = router.route(transcript: "अहिले कति बजेको छ हजुर?")

        XCTAssertTrue(bus.emitted.contains {
            $0.eventType == "topic_pre_answer" && $0.metadata["topic"] == "weather"
        })
        XCTAssertTrue(bus.emitted.contains {
            $0.eventType == "topic_pre_answer" && $0.metadata["topic"] == "time"
        })
        XCTAssertTrue(keywordMatchEvents(bus).isEmpty,
                      "the topic table is keywordish already — relaxed rules must not be involved")
        XCTAssertEqual(coordinator.newsFireCount, 0)
    }
}
