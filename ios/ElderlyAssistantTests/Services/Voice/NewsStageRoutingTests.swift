import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [NEWS-READER] (2026-09-08) CommandRouter news-stage unit tests:
///  - every pinned phrase (English, नेपाली, romanized Nepali) fires the
///    coordinator's `fireNewsReader()` hook exactly once and emits
///    `news_reader_command` — the stage only DECIDES and hands off, it
///    adds no speech and no card of its own,
///  - VETOES: the bare word "news" / "समाचार" never fires (full-phrase
///    containment only), and a briefing utterance never hijacks the news
///    stage (news sits AFTER the briefing stage),
///  - a greeting-prefixed request is news, never small talk (the stage
///    runs BEFORE the topic table),
///  - stage order: safety-net / confirmation utterances still win over
///    a news-shaped utterance.
final class NewsStageRoutingTests: XCTestCase {

    private final class MockSpeaker: Speaker {
        func speak(_ text: String, locale: Locale) async {}
        func cancel() {}
    }

    private final class MockBus: ObservabilityBus {
        var emitted: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { emitted.append(event) }
    }

    private final class MockCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale = Locale(identifier: "ne-NP")
        var newsFireCount = 0
        var briefingFireCount = 0
        var confirmationResponses: [ConfirmationResponse] = []

        func recordTranscript(_ text: String) {}
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {
            confirmationResponses.append(response)
        }
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

    private func makeRouter() -> (CommandRouter, MockCoordinator, MockBus) {
        let coordinator = MockCoordinator()
        let bus = MockBus()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: MockSpeaker(),
                                   interpreter: NullCommandInterpreter())
        return (router, coordinator, bus)
    }

    // MARK: - Phrase table

    func testEveryPinnedPhraseFiresTheNewsReader() {
        let phrases = [
            "read me the news", "read the news", "tell me the news",
            "what's the news", "whats the news", "what is the news",
            "समाचार सुनाऊ", "समाचार सुनाउनुहोस्", "समाचार पढ",
            "खबर सुनाऊ", "खबर सुनाउनुहोस्", "खबर पढ",
            "samachar sunau", "samachar sunaunuhos", "khabar sunau"
        ]
        for phrase in phrases {
            let (router, coordinator, bus) = makeRouter()
            let result = router.route(transcript: phrase)
            XCTAssertEqual(coordinator.newsFireCount, 1,
                           "\(phrase) must fire the news reader exactly once")
            XCTAssertEqual(result, .unrecognised(transcript: phrase),
                           "the stage hands off and ends the turn — the reader speaks")
            XCTAssertTrue(bus.emitted.contains {
                $0.component == "command_router" && $0.eventType == "news_reader_command"
                    && $0.outcome == "success"
            }, "\(phrase) must emit the news_reader_command event")
        }
    }

    func testCaseAndWhitespaceVariationsMatch() {
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "  READ me the NEWS  ")
        XCTAssertEqual(coordinator.newsFireCount, 1,
                       "matching is against the lowercased trimmed transcript")
    }

    func testNoiseFilteredIrregularSpacingTranscriptStillMatches() {
        // [NEWS-READER][NOISE-FILTER] (2026-09-08) The STT joins
        // per-segment text with single spaces while each segment's text
        // carries its own leading/trailing spaces (WhisperKit segment
        // decode, pinned rev ea872ffd), so multi-segment utterances —
        // exactly what the noise-filter front-end's altered segmentation
        // produces — arrive with interior whitespace runs. They look
        // "clear" on the caption, but a raw substring match against the
        // single-spaced phrase list misses and the utterance falls
        // through to the "didn't understand" re-prompt (device report
        // 2026-09-08). The stage must canonicalize interior whitespace
        // before matching, for English AND नेपाली alike.
        let utterances = [
            "read  me  the   news",
            "read me the  news",
            "read  me the news",
            "tell  me the news",
            "what's  the news",
            "whats   the news",
            "what  is the news",
            "समाचार  सुनाऊ",
            "समाचार   सुनाउनुहोस्",
            "खबर  सुनाऊ",
            "samachar  sunau"
        ]
        for utterance in utterances {
            let (router, coordinator, bus) = makeRouter()
            let result = router.route(transcript: utterance)
            XCTAssertEqual(coordinator.newsFireCount, 1,
                           "\(utterance) must fire the news reader — interior whitespace runs are STT segment artifacts, not user errors")
            XCTAssertEqual(result, .unrecognised(transcript: utterance),
                           "the stage hands off and ends the turn — the reader speaks")
            XCTAssertTrue(bus.emitted.contains {
                $0.component == "command_router" && $0.eventType == "news_reader_command"
                    && $0.outcome == "success"
            }, "\(utterance) must emit the news_reader_command event")
        }
    }

    func testGreetingPrefixedRequestIsNewsNeverSmallTalk() {
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "नमस्ते, खबर सुनाऊ")
        XCTAssertEqual(coordinator.newsFireCount, 1,
                       "the news stage runs BEFORE the topic table — a greeting prefix can never turn a news request into small talk")
    }

    // MARK: - Vetoes

    func testBareNewsWordNeverFires() {
        for utterance in ["news", "the news", "समाचार", "खबर", "news please"] {
            let (router, coordinator, _) = makeRouter()
            _ = router.route(transcript: utterance)
            XCTAssertEqual(coordinator.newsFireCount, 0,
                           "bare '\(utterance)' is a mention, not a request — full-phrase containment only")
        }
    }

    func testBriefingUtteranceNeverFiresTheNewsReader() {
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "read me my briefing")
        XCTAssertEqual(coordinator.briefingFireCount, 1)
        XCTAssertEqual(coordinator.newsFireCount, 0,
                       "the briefing stage runs BEFORE the news stage and owns its phrases")
    }

    func testConfirmationResponseWinsOverNewsShapedUtterance() {
        // An utterance during an outstanding confirmation challenge is the
        // challenge's response — the news stage never sees it. (A news
        // phrase is neither yes nor no, so the challenge re-prompts and
        // no confirmation is recorded — but the news reader stays unfired.)
        let (router, coordinator, _) = makeRouter()
        coordinator.isAwaitingConfirmation = true
        let result = router.route(transcript: "read me the news")
        XCTAssertEqual(coordinator.newsFireCount, 0,
                       "confirmation follow-ups run before every deterministic stage")
        XCTAssertTrue(coordinator.confirmationResponses.isEmpty,
                      "neither yes nor no — the challenge re-prompts without recording a response")
        XCTAssertEqual(result, .unrecognised(transcript: "read me the news"))
    }

    func testEmergencyWinsOverNewsShapedUtterance() {
        let (router, coordinator, bus) = makeRouter()
        let result = router.route(transcript: "मद्दत गर्नुहोस् खबर सुनाऊ")
        XCTAssertEqual(coordinator.newsFireCount, 0)
        XCTAssertEqual(result, .emergencyTriggered,
                       "the safety net outranks the news stage, always")
        XCTAssertTrue(bus.emitted.contains { $0.eventType == "command_emergency_keyword" })
    }
}
