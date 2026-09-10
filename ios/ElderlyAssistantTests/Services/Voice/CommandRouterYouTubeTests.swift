import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [YOUTUBE] (2026-09-08) Wiring of the deterministic YouTube stage:
/// `YouTubeRoute` decides after the safety net, confirmation flow,
/// contact search, directions, alarms/timers and the morning briefing —
/// and before the topic table + interpreter. Keyless utterances open the
/// SEARCH deeplink (the accepted search-only MVP); keyed utterances
/// fetch the top result and open the WATCH link; every failure speaks
/// the honest localized fallback. The title-bearing confirmation is
/// SPOKEN ONLY — never carded, never logged. Ordering proofs: emergency
/// and a bare "play" (no YouTube word) never reach the stage, and a
/// "search youtube for X" utterance reaches THIS stage, never the
/// contact-search screen that runs earlier in the ladder.
final class CommandRouterYouTubeTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private func makeRouter(_ coordinator: MockVoiceCommandCoordinator,
                            youtubeConfigStore: YouTubeConfigStore? = nil,
                            youtubeTransport: LocalToolTransport? = nil,
                            youtubeLinkOpener: CallLinkOpening? = nil,
                            localToolLogStore: LocalToolLogStore? = nil)
        -> (CommandRouter, MockObservabilityBus, MockSpeaker) {
        let bus = MockObservabilityBus()
        let speaker = MockSpeaker()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: NullCommandInterpreter(),
                                   localToolLogStore: localToolLogStore,
                                   youtubeConfigStore: youtubeConfigStore,
                                   youtubeTransport: youtubeTransport,
                                   youtubeLinkOpener: youtubeLinkOpener)
        return (router, bus, speaker)
    }

    private func makeConfigStore(apiKey: String? = nil) -> YouTubeConfigStore {
        let store = YouTubeConfigStore(storage: GeminiInMemoryStorage())
        if let apiKey { store.saveAPIKey(apiKey) }
        return store
    }

    private func makeLogStore() -> LocalToolLogStore {
        LocalToolLogStore(storage: GeminiInMemoryStorage())
    }

    private var topResultJSON: Data {
        Data(#"{"items": [{"id": {"kind": "youtube#video", "videoId": "abc123"},"#.utf8)
            + Data(#" "snippet": {"title": "Bhajan Ganga"}}]}"#.utf8)
    }

    private func waitForDelivery() {
        let exp = expectation(description: "youtube async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    // MARK: - Keyless path (search deeplink — the accepted MVP)

    func testKeylessPlayOpensSearchDeeplinkAndSpeaksHonestLine() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, bus, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        let result = router.route(transcript: "play bhajan on youtube")

        XCTAssertEqual(result, .unrecognised(transcript: "play bhajan on youtube"))
        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "bhajan")],
                       "without a key the SEARCH deeplink is the whole feature")
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne),
                        L10n.fmt("youtube.openingSearch", locale: ne, "bhajan")],
                       "the YouTube stage is acked before its outcome line")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "youtube" && $0.eventType == "youtube_search"
                && $0.outcome == "opened_app"
        })
        XCTAssertTrue(bus.emittedEvents.allSatisfy { $0.metadata.isEmpty },
                      "no query or title may reach the bus")
    }

    func testKeylessAppAbsentOpensWebSearchURL() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: false)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        router.route(transcript: "youtube news")

        XCTAssertEqual(opener.opened, [YouTubeTool.webSearchURL(query: "news")],
                       "an absent app takes the https search fallback")
    }

    func testNepaliUtteranceOpensSearchWithDevanagariQuery() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        router.route(transcript: "युट्युबमा गीत चलाऊ")

        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "गीत")])
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne),
                        L10n.fmt("youtube.openingSearch", locale: ne, "गीत")])
    }

    // MARK: - Keyed path (Data API top result → watch link)

    func testKeyedPlayOpensWatchURLAndSpeaksTitleSpokenOnly() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let transport = StubYouTubeTransport(data: topResultJSON, statusCode: 200)
        let logStore = makeLogStore()
        let (router, bus, _) = makeRouter(coordinator,
                                          youtubeConfigStore: makeConfigStore(apiKey: "k123"),
                                          youtubeTransport: transport,
                                          youtubeLinkOpener: opener,
                                          localToolLogStore: logStore)

        router.route(transcript: "play bhajan on youtube")
        waitForDelivery()

        XCTAssertEqual(opener.opened, [YouTubeTool.appWatchURL(videoID: "abc123")],
                       "the resolved video opens through the native watch link")
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne),
                        L10n.str("youtube.looking", locale: ne),
                        L10n.fmt("youtube.playing", locale: ne, "Bhajan Ganga")])
        XCTAssertTrue(coordinator.genericReplies.isEmpty,
                      "the title-bearing confirmation is SPOKEN ONLY — never carded")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "youtube" && $0.eventType == "youtube_play"
                && $0.outcome == "opened_app"
        })
        let entries = logStore.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.kind, .youtube)
        XCTAssertEqual(entry.query, "bhajan")
        XCTAssertEqual(entry.outcome, "ok")
        XCTAssertEqual(entry.statusCode, 200)
        XCTAssertEqual(entry.response, "",
                       "the title must never be logged — the ok entry keeps an empty response by design")
        // The API request itself carried the key + query.
        let requestURL = transport.capturedRequests.first?.url
        XCTAssertEqual(requestURL?.host, "www.googleapis.com")
        let requestItems = requestURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }
        XCTAssertEqual(requestItems?.first { $0.name == "key" }?.value, "k123")
    }

    func testKeyedAppAbsentOpensWebWatchURL() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: false)
        let transport = StubYouTubeTransport(data: topResultJSON, statusCode: 200)
        let (router, _, _) = makeRouter(coordinator,
                                        youtubeConfigStore: makeConfigStore(apiKey: "k123"),
                                        youtubeTransport: transport,
                                        youtubeLinkOpener: opener)

        router.route(transcript: "play bhajan on youtube")
        waitForDelivery()

        XCTAssertEqual(opener.opened, [YouTubeTool.webWatchURL(videoID: "abc123")])
        XCTAssertEqual(coordinator.assistantSpoken.last,
                       L10n.fmt("youtube.playing", locale: ne, "Bhajan Ganga"),
                       "the confirmation is the same either way — the open decision is not a lie about autoplay")
    }

    // MARK: - Honest failure lines (never fabricate)

    func testQuotaFailureSpeaksUnavailableFallback() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let transport = StubYouTubeTransport(data: Data(), statusCode: 403)
        let logStore = makeLogStore()
        let (router, bus, _) = makeRouter(coordinator,
                                          youtubeConfigStore: makeConfigStore(apiKey: "k123"),
                                          youtubeTransport: transport,
                                          youtubeLinkOpener: opener,
                                          localToolLogStore: logStore)

        router.route(transcript: "play bhajan on youtube")
        waitForDelivery()

        XCTAssertTrue(opener.opened.isEmpty, "a failed lookup must open nothing")
        let fallback = L10n.str("youtube.unavailable", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne),
                        L10n.str("youtube.looking", locale: ne), fallback])
        XCTAssertTrue(coordinator.genericReplies.contains(fallback),
                      "the honest fallback is also visible")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "youtube" && $0.eventType == "youtube"
                && $0.outcome == "fail"
        })
        let entry = logStore.entries().first
        XCTAssertEqual(entry?.outcome, "fail")
        XCTAssertEqual(entry?.statusCode, 403)
        XCTAssertEqual(entry?.response, fallback)
    }

    func testEmptyResultsSpeakNotFoundFallback() {
        let coordinator = MockVoiceCommandCoordinator()
        let transport = StubYouTubeTransport(data: Data(#"{"items": []}"#.utf8), statusCode: 200)
        let (router, _, _) = makeRouter(coordinator,
                                        youtubeConfigStore: makeConfigStore(apiKey: "k123"),
                                        youtubeTransport: transport,
                                        youtubeLinkOpener: FakeLinkOpener(canOpen: true))

        router.route(transcript: "play bhajan on youtube")
        waitForDelivery()

        let notFound = L10n.str("youtube.notFound", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken.last, notFound)
        XCTAssertTrue(coordinator.genericReplies.contains(notFound))
    }

    func testTransportFailureSpeaksUnavailableFallback() {
        struct Boom: Error {}
        let coordinator = MockVoiceCommandCoordinator()
        let transport = StubYouTubeTransport(data: Data(), statusCode: 200, error: Boom())
        let (router, _, _) = makeRouter(coordinator,
                                        youtubeConfigStore: makeConfigStore(apiKey: "k123"),
                                        youtubeTransport: transport,
                                        youtubeLinkOpener: FakeLinkOpener(canOpen: true))

        router.route(transcript: "play bhajan on youtube")
        waitForDelivery()

        XCTAssertEqual(coordinator.assistantSpoken.last,
                       L10n.str("youtube.unavailable", locale: ne))
    }

    func testDormantSeamsSpeakUnavailableAndOpenNothing() {
        // No opener injected (pre-existing construction sites): the
        // stage must stay honest, never crash, never open anything.
        let coordinator = MockVoiceCommandCoordinator()
        let (router, bus, _) = makeRouter(coordinator)

        router.route(transcript: "play bhajan on youtube")

        let fallback = L10n.str("youtube.unavailable", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne), fallback])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "youtube" && $0.outcome == "fail"
        })
    }

    // MARK: - Ordering proofs

    func testBarePlayWithoutYouTubeWordNeverReachesTheStage() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        router.route(transcript: "play some music")

        XCTAssertTrue(opener.opened.isEmpty,
                      "a play request without a YouTube word must fall through to the existing ladder")
        XCTAssertEqual(coordinator.assistantSpoken, [L10n.str("router.reprompt", locale: ne)])
    }

    func testSearchYouTubeUtteranceReachesYouTubeNotContactSearch() {
        // The contact-search stage runs EARLIER in the ladder and would
        // swallow "search youtube for ram" without its YouTube veto —
        // the YouTube stage must receive the whole query instead.
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        router.route(transcript: "search youtube for ram")

        XCTAssertTrue(coordinator.contactSearchRequests.isEmpty,
                      "a YouTube search must never open the Phone screen")
        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "ram")])
    }

    func testNepaliYoutubeSearchUtteranceReachesYouTubeNotContactSearch() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        router.route(transcript: "युट्युबमा गीत खोज")

        XCTAssertTrue(coordinator.contactSearchRequests.isEmpty)
        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "गीत")])
    }

    func testEmergencyStillWinsOverYouTubeMarker() {
        let coordinator = MockVoiceCommandCoordinator()
        let opener = FakeLinkOpener(canOpen: true)
        let (router, _, _) = makeRouter(coordinator, youtubeLinkOpener: opener)

        let result = router.route(transcript: "help, play bhajan on youtube")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(opener.opened.isEmpty,
                      "the safety net outranks the YouTube stage, always")
    }
}

// MARK: - Doubles

private final class MockVoiceCommandCoordinator: VoiceCommandCoordinating {
    var recordedTranscripts: [String] = []
    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    var assistantSpoken: [String] = []
    var genericReplies: [String] = []
    var contactSearchRequests: [String?] = []
    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) { recordedTranscripts.append(text) }
    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
    func noteGenericReply(_ text: String) { genericReplies.append(text) }
    func addVoiceReminder(title: String, time: DateComponents) {}
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? { nil }
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
    func presentPluginView(_ view: AnyView) {}
    func requestContactSearch(query: String?) { contactSearchRequests.append(query) }
}

private final class MockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

private final class StubYouTubeTransport: LocalToolTransport {
    private(set) var capturedRequests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int
    private let error: Error?

    init(data: Data, statusCode: Int, error: Error? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.error = error
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.local")!,
                                       statusCode: statusCode,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (data, response)
    }
}

private final class FakeLinkOpener: CallLinkOpening {
    let canOpen: Bool
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    init(canOpen: Bool) {
        self.canOpen = canOpen
    }

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return canOpen
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}
