import XCTest
@testable import ElderlyAssistant

/// T-096: the ack state machine (design-l2 §7.1 verbatim) with a
/// controllable fake speaker. Every Gherkin scenario of the task is
/// covered here; the racing-detection pair's pipeline half lives in
/// `WakeAcknowledgmentSeamTests`, and the coordinator-wiring half
/// ("base speaker, never the forwarder") is one construction line in
/// `AppCoordinator.start()` — cited in the implementation notes.
///
/// The completion contract is "exactly once, on the main queue, within
/// `wakeAckMaxHoldSeconds`" for every path except `cancel()` (and its
/// supersede teardown), which drops a completion that is stale by
/// definition.
final class WakeAcknowledgmentServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { events.append(event) }
        func eventTypes() -> [String] { events.map(\.eventType) }
    }

    /// Controllable `Speaker`: `speak` records the utterance and suspends
    /// until `finish()` (a normal played-out end) or `cancel()` (which
    /// resumes it exactly like the real speaker whose `speak` returns when
    /// playback is cancelled). A cancel that lands BEFORE `speak` even
    /// started is honoured by the ticket check, so no continuation ever
    /// dangles.
    private final class ControllableSpeaker: Speaker {
        private let lock = NSLock()
        private(set) var utterances: [(text: String, locale: Locale)] = []
        private(set) var cancelCalls = 0
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var cancelCount = 0

        func speak(_ text: String, locale: Locale) async {
            lock.lock()
            utterances.append((text, locale))
            let ticket = cancelCount
            lock.unlock()
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelCount > ticket {
                    lock.unlock()
                    continuation.resume()
                } else {
                    pending.append(continuation)
                    lock.unlock()
                }
            }
        }

        func cancel() {
            lock.lock()
            cancelCalls += 1
            cancelCount += 1
            let continuations = pending
            pending = []
            lock.unlock()
            for continuation in continuations { continuation.resume() }
        }

        /// Resumes every in-flight `speak` as a normal, played-out finish.
        func finish() {
            lock.lock()
            let continuations = pending
            pending = []
            lock.unlock()
            for continuation in continuations { continuation.resume() }
        }
    }

    // MARK: - Helpers

    private func waitUntil(_ timeout: TimeInterval = 2,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func makeService(speaker: Speaker,
                             term: String?,
                             locale: Locale = Locale(identifier: "en"),
                             bus: RecordingBus,
                             onStarted: @escaping () -> Void = {},
                             onEnded: @escaping () -> Void = {},
                             maxHold: TimeInterval = 2.5,
                             templateKey: String = "wakeAck.personalized")
        -> WakeAcknowledgmentService {
        WakeAcknowledgmentService(
            speaker: speaker,
            termProvider: { term },
            localeProvider: { locale },
            onSpeakingStarted: onStarted,
            onSpeakingEnded: onEnded,
            wakeAckMaxHoldSeconds: maxHold,
            templateKey: templateKey,
            observabilityBus: bus
        )
    }

    // MARK: - Scenario: a recorded term is acknowledged, capture follows

    func testARecordedTermIsSpokenVerbatimAndSettlesOnce() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var started = 0
        var ended = 0
        var completionCount = 0
        var completionOnMain = false
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  onStarted: { started += 1 },
                                  onEnded: { ended += 1 })

        let begin = Date()
        service.begin {
            completionCount += 1
            completionOnMain = Thread.isMainThread
        }
        XCTAssertEqual(started, 1, "speaking-started fires once, before playback")
        XCTAssertTrue(waitUntil { speaker.utterances.count == 1 },
                      "playback must begin")
        XCTAssertEqual(speaker.utterances.first?.text, "Yes, Mum",
                       "the en template with the stored term verbatim")
        XCTAssertEqual(ended, 0, "not settled while playback is running")

        speaker.finish()
        XCTAssertTrue(waitUntil { completionCount == 1 },
                      "the completion follows the played-out utterance")
        let elapsed = Date().timeIntervalSince(begin)
        XCTAssertLessThan(elapsed, 2.5, "settled within wakeAckMaxHoldSeconds")
        XCTAssertTrue(completionOnMain, "completion runs on the main queue")
        XCTAssertEqual(started, 1)
        XCTAssertEqual(ended, 1, "speaking balance restored exactly once")
        XCTAssertEqual(bus.eventTypes(), ["wake_ack_spoken"])
        XCTAssertEqual(bus.events.first?.outcome, "success")
        XCTAssertNotNil(bus.events.first?.durationMs, "the hold is reported")
        XCTAssertEqual(bus.events.first?.metadata, [:], "no content, ever")
    }

    func testTheNepaliTemplatePlacesTheTermVerbatim() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var completionCount = 0
        let service = makeService(speaker: speaker, term: "आमा",
                                  locale: Locale(identifier: "ne"), bus: bus)
        service.begin { completionCount += 1 }
        XCTAssertTrue(waitUntil { speaker.utterances.count == 1 })
        let spoken = speaker.utterances.first?.text ?? ""
        XCTAssertTrue(spoken.hasPrefix("हजुर "), spoken)
        XCTAssertTrue(spoken.contains("आमा"),
                      "the term is data, never translated")
        speaker.finish()
        XCTAssertTrue(waitUntil { completionCount == 1 })
    }

    func testPhraseCompositionFillsTheTermAndNeverTheKey() {
        let en = Locale(identifier: "en")
        let ne = Locale(identifier: "ne")
        XCTAssertEqual(
            WakeAcknowledgmentService.phrase(term: "Mum",
                                             templateKey: "wakeAck.personalized",
                                             locale: en),
            "Yes, Mum")
        XCTAssertEqual(
            WakeAcknowledgmentService.phrase(term: "Mum",
                                             templateKey: "wakeAck.personalized",
                                             locale: ne),
            "हजुर Mum", "the template is localized; the term is not")
        XCTAssertNil(
            WakeAcknowledgmentService.phrase(term: "Mum",
                                             templateKey: "wakeAck.no.such.key",
                                             locale: en),
            "an unresolved key is never spoken")
    }

    // MARK: - Scenario: no term means today's silent start

    func testNoTermCompletesSynchronouslyAndSilently() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var completionCount = 0
        let service = makeService(speaker: speaker, term: nil, bus: bus)
        service.begin { completionCount += 1 }
        XCTAssertEqual(completionCount, 1, "synchronous — no runloop needed")
        XCTAssertTrue(speaker.utterances.isEmpty, "no audio plays")
        XCTAssertTrue(bus.events.isEmpty, "no event for the silent path")
    }

    func testABlankTermIsTreatedAsNoTerm() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var completionCount = 0
        let service = makeService(speaker: speaker, term: "   \n", bus: bus)
        service.begin { completionCount += 1 }
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(speaker.utterances.isEmpty)
        XCTAssertTrue(bus.events.isEmpty)
    }

    // MARK: - Scenario: an unresolvable template is never spoken

    func testAnUnresolvableTemplateFailsLoudlyAndSilently() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var completionCount = 0
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  templateKey: "wakeAck.does.not.exist")
        service.begin { completionCount += 1 }
        XCTAssertEqual(completionCount, 1, "synchronous")
        XCTAssertTrue(speaker.utterances.isEmpty, "a key is never spoken")
        XCTAssertEqual(bus.eventTypes(), ["wake_ack_failed"])
        XCTAssertEqual(bus.events.first?.errorCode, "template_missing")
        XCTAssertEqual(bus.events.first?.outcome, "failure")
    }

    func testATemplateWithoutThePlaceholderIsAlsoUnavailable() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var completionCount = 0
        // Any catalogued key WITHOUT %@ resolves but cannot carry a term.
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  templateKey: "onboarding.next")
        service.begin { completionCount += 1 }
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(speaker.utterances.isEmpty)
        XCTAssertEqual(bus.events.first?.errorCode, "template_missing")
    }

    // MARK: - Scenario: a slow synthesis is cut at the bound

    func testTheHoldBoundCutsPlaybackWithBalancedBookkeeping() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var started = 0
        var ended = 0
        var completionCount = 0
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  onStarted: { started += 1 },
                                  onEnded: { ended += 1 },
                                  maxHold: 0.01)
        service.begin { completionCount += 1 }

        XCTAssertTrue(waitUntil { completionCount == 1 },
                      "the bound is the worst-case hold")
        XCTAssertEqual(speaker.cancelCalls, 1, "playback is cut")
        XCTAssertEqual(bus.eventTypes(), ["wake_ack_timeout"])
        XCTAssertEqual(bus.events.first?.errorCode, "hold_exceeded")
        XCTAssertEqual(bus.events.first?.outcome, "failure")
        if let duration = bus.events.first?.durationMs {
            XCTAssertGreaterThanOrEqual(duration, 5, "the hold, in ms")
            XCTAssertLessThan(duration, 1_000)
        } else {
            XCTFail("duration_ms must report the hold")
        }
        XCTAssertTrue(waitUntil { ended == 1 })
        XCTAssertEqual(started, 1)
        // The cancelled speak's tail settles later and must be inert.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(completionCount, 1, "completion exactly once")
        XCTAssertEqual(bus.eventTypes(), ["wake_ack_timeout"],
                       "the late tail adds no event")
    }

    // MARK: - Scenario: cancel drops the pending completion

    func testCancelStopsPlaybackAndDropsTheCompletion() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var started = 0
        var ended = 0
        var completionCount = 0
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  onStarted: { started += 1 },
                                  onEnded: { ended += 1 })
        service.begin { completionCount += 1 }
        XCTAssertTrue(waitUntil { speaker.utterances.count == 1 })

        service.cancel()
        XCTAssertEqual(speaker.cancelCalls, 1, "playback stopped")
        XCTAssertEqual(ended, 1, "balance restored exactly once")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(completionCount, 0, "the stale completion is dropped")
        XCTAssertTrue(bus.events.isEmpty, "cancel emits no event")
        XCTAssertEqual(started, 1)
    }

    // MARK: - Scenario: a superseding begin tears the old ack down

    func testASupersedingBeginDropsTheOldAckAndProceeds() {
        let bus = RecordingBus()
        let speaker = ControllableSpeaker()
        var started = 0
        var ended = 0
        var firstCompletions = 0
        var secondCompletions = 0
        let service = makeService(speaker: speaker, term: "Mum", bus: bus,
                                  onStarted: { started += 1 },
                                  onEnded: { ended += 1 })
        service.begin { firstCompletions += 1 }
        XCTAssertTrue(waitUntil { speaker.utterances.count == 1 })

        // The AM-3 racing window: a second begin lands while the first is
        // active (the gate has not closed yet on the pipeline side).
        service.begin { secondCompletions += 1 }
        XCTAssertEqual(speaker.cancelCalls, 1, "the old ack's playback is cut")
        XCTAssertEqual(ended, 1, "old ack's balance restored")
        XCTAssertEqual(firstCompletions, 0, "old completion dropped")
        XCTAssertTrue(bus.events.isEmpty, "supersede emits no event")
        XCTAssertTrue(waitUntil { speaker.utterances.count == 2 },
                      "the new ack proceeds normally")
        XCTAssertEqual(started, 2)

        speaker.finish()
        XCTAssertTrue(waitUntil { secondCompletions == 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(firstCompletions, 0, "the stale tail stayed inert")
        XCTAssertEqual(bus.eventTypes(), ["wake_ack_spoken"],
                       "exactly one settle event — the new ack's")
        XCTAssertEqual(ended, 2, "both acks balanced")
    }
}
