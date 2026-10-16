import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [FEEDS-FULL-ARTICLE] (2026-09-19) CommandRouter full-article stage
/// unit tests:
///  - every pinned phrase (English, नेपाली, romanized Nepali) fires the
///    coordinator's `readFullFeedArticle()` hook exactly once and emits
///    `feed_full_article_command` — the stage only DECIDES and hands off
///    (the coordinator owns the article, the "only a summary" line and
///    the "nothing in your feed" line),
///  - PRECEDENCE (the reason the stage sits where it does): the Nepali
///    full-article phrasings CONTAIN news phrasings ("समाचार पढ" ⊂
///    "पूरा समाचार पढ"), so the full-article stage must run BEFORE the
///    news digest stage — a full-article request must never be answered
///    with headlines,
///  - NO REGRESSION: the plain news phrasings still fire the news reader
///    and never the full-article hook,
///  - VETOES: a bare "article"/"लेख" mention never fires the stage.
final class FullArticleStageRoutingTests: XCTestCase {

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
        var fullArticleFireCount = 0
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
        func readFullFeedArticle() { fullArticleFireCount += 1 }
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

    func testEveryPinnedPhraseFiresTheFullArticleHook() {
        let phrases = [
            "read the full article", "read the full story",
            "read the whole article", "read the entire article",
            "read full article", "read me the full article",
            "पूरा समाचार पढ", "पूरा समाचार पढ्नुहोस्", "पूरा समाचार सुनाऊ",
            "पूरा खबर पढ", "पूरा खबर सुनाऊ", "पूरा लेख पढ",
            "पूरा लेख पढ्नुहोस्", "पूरा समाचार सुनाउनुहोस्",
            "pura samachar pad", "pura samachar sunau", "pura lekh pad"
        ]
        for phrase in phrases {
            let (router, coordinator, bus) = makeRouter()
            let result = router.route(transcript: phrase)
            XCTAssertEqual(coordinator.fullArticleFireCount, 1,
                           "\(phrase) must fire the full-article hook exactly once")
            XCTAssertEqual(coordinator.newsFireCount, 0,
                           "\(phrase) must never be answered with headlines")
            XCTAssertEqual(coordinator.briefingFireCount, 0, "\(phrase)")
            XCTAssertEqual(result, .unrecognised(transcript: phrase),
                           "the stage hands off and ends the turn — the "
                           + "coordinator speaks")
            XCTAssertTrue(bus.emitted.contains {
                $0.component == "command_router"
                    && $0.eventType == "feed_full_article_command"
                    && $0.outcome == "success"
            }, "\(phrase) must emit the feed_full_article_command event")
        }
    }

    // MARK: - Precedence over the news stage (the load-bearing ordering)

    func testNepaliFullArticlePhraseIsNotSwallowedByTheNewsStage() {
        // "समाचार पढ" is a NEWS phrase and a substring of
        // "पूरा समाचार पढ" — if the news stage ran first this utterance
        // would be answered with a digest.
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "पूरा समाचार पढ")
        XCTAssertEqual(coordinator.fullArticleFireCount, 1)
        XCTAssertEqual(coordinator.newsFireCount, 0,
                       "the full-article stage must run BEFORE the news stage")

        let (router2, coordinator2, _) = makeRouter()
        _ = router2.route(transcript: "पूरा खबर सुनाऊ")
        XCTAssertEqual(coordinator2.fullArticleFireCount, 1)
        XCTAssertEqual(coordinator2.newsFireCount, 0)
    }

    func testPlainNewsPhrasesStillFireTheNewsReaderOnly() {
        let phrases = ["read me the news", "समाचार पढ", "खबर सुनाऊ",
                       "samachar sunau"]
        for phrase in phrases {
            let (router, coordinator, _) = makeRouter()
            _ = router.route(transcript: phrase)
            XCTAssertEqual(coordinator.newsFireCount, 1, "\(phrase)")
            XCTAssertEqual(coordinator.fullArticleFireCount, 0,
                           "\(phrase) asks for the news, not the article")
        }
    }

    // MARK: - Vetoes and matching

    func testBareArticleMentionNeverFiresTheStage() {
        let utterances = [
            "read the article",            // no "full"/"whole"/"entire"
            "I read an article about tea", // a statement, not a request
            "लेख पढ",                       // no "पूरा"
            "article"
        ]
        for utterance in utterances {
            let (router, coordinator, _) = makeRouter()
            _ = router.route(transcript: utterance)
            XCTAssertEqual(coordinator.fullArticleFireCount, 0,
                           "\(utterance) must not hijack the full-article stage")
        }
    }

    func testCaseAndWhitespaceVariationsMatch() {
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "  READ  the  FULL  Article  ")
        XCTAssertEqual(coordinator.fullArticleFireCount, 1,
                       "matching is against the lowercased, "
                       + "whitespace-canonicalized transcript")
    }

    func testGreetingPrefixedRequestStillFiresTheStage() {
        // The stage runs before the topic table, so a greeting-prefixed
        // request is the full-article read, never small talk.
        let (router, coordinator, _) = makeRouter()
        _ = router.route(transcript: "नमस्ते, पूरा समाचार पढ")
        XCTAssertEqual(coordinator.fullArticleFireCount, 1)
        XCTAssertEqual(coordinator.newsFireCount, 0)
    }
}
