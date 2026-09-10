import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [VOICE-ACK] (2026-09-11) Seam tests for the pre-acknowledgment lane: a
/// short warm "एक छिन…" / "one moment…" spoken BEFORE a slow stage's
/// result, committed through the serial `ReplySpeakLane`. Pins the
/// approved contract: ack-before-result ordering, rotating variants,
/// instant-answer and confirmation-challenge skips, slow-stage acks, and
/// the voiceAck.* catalog keys (en + ne).
final class CommandRouterPreAckTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en")

    private func ackVariant(_ n: Int, locale: Locale) -> String {
        L10n.str("voiceAck.moment\(n)", locale: locale)
    }

    private func makeRouter(
        _ coordinator: MockPreAckCoordinator,
        interpreter: CommandInterpreter = NullCommandInterpreter()
    ) -> (CommandRouter, MockPreAckBus) {
        let bus = MockPreAckBus()
        let router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: MockPreAckSpeaker(), interpreter: interpreter)
        return (router, bus)
    }

    private func waitForAsyncSpeak() {
        let exp = expectation(description: "async speak settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    // MARK: - Ack-before-result ordering

    func testTimerStartSpeaksAckBeforeConfirmation() {
        let coordinator = MockPreAckCoordinator()
        coordinator.timerStartOutcome = .scheduled
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set a timer for 5 minutes")
        waitForAsyncSpeak()

        let ack = ackVariant(1, locale: ne)
        let confirmation = L10n.fmt("timers.started", locale: ne,
                                    AlarmTimerCommandParser.durationText(seconds: 300, locale: ne))
        XCTAssertEqual(coordinator.assistantSpoken, [ack, confirmation],
                       "the ack must be committed before the arming round-trip, the confirmation after")
        XCTAssertEqual(coordinator.timerStartRequests.map(\.durationSeconds), [300])
    }

    func testAlarmSetSpeaksAckBeforeConfirmation() {
        let coordinator = MockPreAckCoordinator()
        coordinator.alarmSetOutcome = .scheduled
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "set an alarm for 6 am")
        waitForAsyncSpeak()

        let ack = ackVariant(1, locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken.first, ack,
                       "the alarm arm must be acked before its outcome line")
        XCTAssertEqual(coordinator.assistantSpoken.count, 2)
    }

    func testAckVariantsRotateAcrossSlowTurns() {
        let coordinator = MockPreAckCoordinator()
        coordinator.timerStartOutcome = .scheduled
        let (router, _) = makeRouter(coordinator)

        for _ in 0..<4 {
            _ = router.route(transcript: "set a timer for 5 minutes")
        }
        waitForAsyncSpeak()

        // The acks commit synchronously during each route; the
        // confirmations land from the async arming Tasks, so acks and
        // confirmations can interleave. Pin the ack subsequence and the
        // totals — never a fixed interleaving.
        let m1 = ackVariant(1, locale: ne), m2 = ackVariant(2, locale: ne)
        let m3 = ackVariant(3, locale: ne)
        let acks = coordinator.assistantSpoken.filter { $0 == m1 || $0 == m2 || $0 == m3 }
        XCTAssertEqual(acks, [m1, m2, m3, m1],
                       "variants rotate 1→2→3→1 per slow turn")
        XCTAssertEqual(coordinator.assistantSpoken.count, 8,
                       "each of the four turns speaks ack + confirmation")
    }

    func testReplySpeakLaneDrainsInCommitOrder() async {
        let speaker = MockPreAckSpeaker()
        let lane = ReplySpeakLane(speaker: speaker)
        await lane.enqueue("first", locale: ne)
        await lane.enqueue("second", locale: ne)
        await lane.enqueue("third", locale: ne)
        XCTAssertEqual(speaker.utterances.map(\.text), ["first", "second", "third"],
                       "the lane is FIFO — commit order is speak order")
    }

    // MARK: - Slow-stage acks

    func testLLMPathSpeaksAckBeforeModelReply() {
        let coordinator = MockPreAckCoordinator()
        let interpreter = MockPreAckInterpreter()
        let modelReply = "कथाको सुरुवात: एक देशमा एउटा बूढो बाबा थिए।"
        let (router, _) = makeRouter(coordinator, interpreter: interpreter)

        _ = router.route(transcript: "छोरालाई फोन गर")
        waitForAsyncSpeak()
        XCTAssertEqual(coordinator.assistantSpoken, [ackVariant(1, locale: ne)],
                       "the ack must be committed while the model is still thinking")
        XCTAssertTrue(router.isTurnReplyPending)

        interpreter.completeNext(with: InterpretedCommand(
            action: .query, entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, pluginAction: nil,
            pluginEntities: nil, confidence: 0.95, reply: modelReply))
        waitForAsyncSpeak()

        XCTAssertEqual(coordinator.assistantSpoken,
                       [ackVariant(1, locale: ne), modelReply],
                       "ack first, model reply second — the lane orders them")
        XCTAssertFalse(router.isTurnReplyPending)
    }

    func testYouTubeStageSpeaksAckBeforeOutcomeLine() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)   // dormant seams — honest fallback

        _ = router.route(transcript: "युट्युबमा भजन चलाऊ")
        waitForAsyncSpeak()

        let fallback = L10n.str("youtube.unavailable", locale: ne)
        XCTAssertEqual(coordinator.assistantSpoken, [ackVariant(1, locale: ne), fallback])
    }

    func testDirectionsNavigateSpeaksAck() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "मलाई घर लैजाऊ")

        XCTAssertEqual(coordinator.navigationRequests, [.defaultHome],
                       "the bare-home request must still reach the coordinator")
        XCTAssertEqual(coordinator.assistantSpoken, [ackVariant(1, locale: ne)],
                       "navigation's map-surface chain is acked")
    }

    func testBriefingStageSpeaksAck() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "read me my briefing")

        XCTAssertEqual(coordinator.morningBriefingFires, 1)
        XCTAssertEqual(coordinator.assistantSpoken, [ackVariant(1, locale: ne)],
                       "the digest composition is acked before it starts")
    }

    func testNewsStageSpeaksAck() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "read me the news")

        XCTAssertEqual(coordinator.newsFires, 1)
        XCTAssertEqual(coordinator.assistantSpoken, [ackVariant(1, locale: ne)],
                       "the news fetch + compose is acked before it starts")
    }

    // MARK: - Instant answers and challenges never ack

    func testGreetingInstantAnswerHasNoAck() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "नमस्ते")

        XCTAssertEqual(coordinator.assistantSpoken.count, 1,
                       "a greeting speaks exactly its own reply")
        let variants = (1...3).map { ackVariant($0, locale: ne) }
        XCTAssertFalse(variants.contains(coordinator.assistantSpoken.first ?? ""),
                       "instant answers must not be acked")
    }

    func testCalculatorInstantAnswerHasNoAck() {
        let coordinator = MockPreAckCoordinator()
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "५ जोड ३ कति हुन्छ?")

        XCTAssertEqual(coordinator.assistantSpoken.count, 1,
                       "a provable computation speaks exactly its own reply")
        let variants = (1...3).map { ackVariant($0, locale: ne) }
        XCTAssertFalse(variants.contains(coordinator.assistantSpoken.first ?? ""),
                       "calculator answers must not be acked")
    }

    func testConfirmationChallengeHasNoAck() {
        let coordinator = MockPreAckCoordinator()
        coordinator.isAwaitingConfirmation = true
        let (router, _) = makeRouter(coordinator)

        _ = router.route(transcript: "हो")

        XCTAssertEqual(coordinator.assistantSpoken,
                       [L10n.str("router.confirmationYes", locale: ne)],
                       "a challenge answer speaks only the confirmation line — no ack")
    }

    // MARK: - Catalog keys

    func testVoiceAckKeysResolvePerLocale() {
        XCTAssertEqual(L10n.str("voiceAck.moment1", locale: en), "one moment…")
        XCTAssertEqual(L10n.str("voiceAck.moment2", locale: en), "just a moment…")
        XCTAssertEqual(L10n.str("voiceAck.moment3", locale: en), "okay, one moment…")
        XCTAssertEqual(L10n.str("voiceAck.moment1", locale: ne), "एक छिन…")
        XCTAssertEqual(L10n.str("voiceAck.moment2", locale: ne), "एक छिन है…")
        XCTAssertEqual(L10n.str("voiceAck.moment3", locale: ne), "हुन्छ, एकछिन…")
    }
}

// MARK: - Doubles

/// Records every spoken line at commit time (the router calls
/// `noteAssistantSpoke` synchronously inside `speak`) — the exact-order
/// twin of the async speaker recordings.
private final class MockPreAckCoordinator: VoiceCommandCoordinating {
    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    var assistantSpoken: [String] = []
    func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteGenericReply(_ text: String) {}

    var timerStartOutcome: AlarmTimerSetOutcome = .scheduled
    var timerStartRequests: [(durationSeconds: Int, label: String?)] = []
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        timerStartRequests.append((durationSeconds, label))
        return timerStartOutcome
    }

    var alarmSetOutcome: AlarmTimerSetOutcome = .scheduled
    var alarmSetRequests: [(time: Date, label: String?)] = []
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome {
        alarmSetRequests.append((time, label))
        return alarmSetOutcome
    }

    var navigationRequests: [DirectionsRoute.PlaceTarget] = []
    func requestNavigation(to target: DirectionsRoute.PlaceTarget) {
        navigationRequests.append(target)
    }

    var morningBriefingFires = 0
    func fireMorningBriefing() { morningBriefingFires += 1 }
    var newsFires = 0
    func fireNewsReader() { newsFires += 1 }

    func recordTranscript(_ text: String) {}
    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func addVoiceReminder(title: String, time: DateComponents) {}
    var pendingRephraseCommand: InterpretedCommand? { nil }
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? { nil }
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
    func presentPluginView(_ view: AnyView) {}
    func requestContactSearch(query: String?) {}
}

private final class MockPreAckSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []
    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }
    func cancel() {}
}

private final class MockPreAckBus: ObservabilityBus {
    var emittedEvents: [ObservabilityEvent] = []
    func emit(_ event: ObservabilityEvent) {
        emittedEvents.append(event)
    }
}

/// Holds the interpreter completion so tests can pin the "model is
/// thinking" window — the ack must be committed while nothing else has
/// been spoken yet.
private final class MockPreAckInterpreter: CommandInterpreter {
    var isAvailable = true
    private var held: [(String, InterpreterContext, (InterpretedCommand?) -> Void)] = []

    func interpret(transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        held.append((transcript, context, completion))
    }

    func completeNext(with command: InterpretedCommand?) {
        held.removeFirst().2(command)
    }
}
