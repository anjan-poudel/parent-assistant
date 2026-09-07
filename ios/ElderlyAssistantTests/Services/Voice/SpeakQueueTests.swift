import XCTest
@testable import ElderlyAssistant

/// `SpeakQueue` kernel tests (spec §3/§4.1/§6) — priority arbitration,
/// coalescing, depth caps, card lifecycle, and failure handling.
///
/// Determinism model: the queue's worker only advances when the speaker
/// advances, and a resumed continuation runs inline on the resuming
/// thread. `ManualSpeaker` parks each utterance until the test finishes or
/// cancels it (mirroring the shipped speakers, whose `cancel()` resumes
/// the in-flight `speak()`), so the queue state is fully hand-driven.
/// `waitUntil` polls for every post-action expectation so the tests stay
/// deterministic under either execution model.
@MainActor
final class SpeakQueueTests: XCTestCase {

    // MARK: - Test doubles

    /// Hand-gated speaker: `speak` parks until the test releases the
    /// utterance (`finishCurrent` / `failCurrent`) or the queue preempts
    /// it (`cancel`). Mirrors the real speakers' contract: `cancel()`
    /// ends the in-flight utterance and its `speak()` returns.
    private class ManualSpeaker: Speaker {

        private struct Parked {
            let text: String
            let resume: (SpeakResult) -> Void
        }

        private let lock = NSLock()
        private var startedLocked: [String] = []
        private var parkedLocked: Parked?
        private var finishedLocked: [String] = []
        private var cancelledLocked: [String] = []
        private var cancelCountLocked = 0

        var startedTexts: [String] {
            lock.lock(); defer { lock.unlock() }
            return startedLocked
        }
        var parkedText: String? {
            lock.lock(); defer { lock.unlock() }
            return parkedLocked?.text
        }
        var finishedTexts: [String] {
            lock.lock(); defer { lock.unlock() }
            return finishedLocked
        }
        var cancelledTexts: [String] {
            lock.lock(); defer { lock.unlock() }
            return cancelledLocked
        }
        var cancelCount: Int {
            lock.lock(); defer { lock.unlock() }
            return cancelCountLocked
        }

        func speak(_ text: String, locale: Locale) async {
            _ = await park(text: text)
        }

        func park(text: String) async -> SpeakResult {
            lock.lock()
            startedLocked.append(text)
            lock.unlock()
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<SpeakResult, Never>) in
                lock.lock()
                parkedLocked = Parked(text: text) { result in
                    continuation.resume(returning: result)
                }
                lock.unlock()
            }
        }

        /// Ends the in-flight utterance as successfully spoken.
        func finishCurrent() {
            release(.spoken, finishing: true)
        }

        /// Ends the in-flight utterance as a TTS failure.
        func failCurrent() {
            release(.failed, finishing: false)
        }

        /// Speaker requirement: ends the in-flight utterance without
        /// completing it — the queue-initiated preemption path. The
        /// interrupted utterance resolves `.spoken`; the queue tracks the
        /// interruption itself.
        func cancel() {
            lock.lock()
            cancelCountLocked += 1
            guard let parked = parkedLocked else {
                lock.unlock()
                return
            }
            parkedLocked = nil
            cancelledLocked.append(parked.text)
            let resume = parked.resume
            lock.unlock()
            resume(.spoken)
        }

        private func release(_ result: SpeakResult, finishing: Bool) {
            lock.lock()
            guard let parked = parkedLocked else {
                lock.unlock()
                return
            }
            parkedLocked = nil
            if finishing { finishedLocked.append(parked.text) }
            let resume = parked.resume
            lock.unlock()
            resume(result)
        }
    }

    /// Manual speaker that also reports utterance outcomes, exercising
    /// `SpeakQueue`'s `SpeakResultReporting` path (failures are otherwise
    /// unobservable — the shipped speakers absorb them internally).
    private final class ReportingManualSpeaker: ManualSpeaker,
                                                SpeakResultReporting {
        func speakWithResult(_ text: String, locale: Locale) async -> SpeakResult {
            await park(text: text)
        }
    }

    /// Thread-safe event sink for the queue's observability events.
    private final class RecordingBus: ObservabilityBus {
        private let lock = NSLock()
        private var stored: [ObservabilityEvent] = []

        func emit(_ event: ObservabilityEvent) {
            lock.lock()
            stored.append(event)
            lock.unlock()
        }

        var allEvents: [ObservabilityEvent] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func events(ofType type: String) -> [ObservabilityEvent] {
            allEvents.filter { $0.eventType == type }
        }
    }

    // MARK: - Fixtures

    private func makeAnnouncement(_ text: String,
                                  priority: AnnouncementPriority = .interactive,
                                  sourceID: String = "test.source",
                                  card: AnnouncementCard? = nil) -> Announcement {
        Announcement(id: UUID(), text: text, priority: priority,
                     sourceID: sourceID, card: card)
    }

    private func makeCard(_ title: String) -> AnnouncementCard {
        AnnouncementCard(title: title, body: "body-\(title)", symbolName: "bell")
    }

    private func makeHarness(_ speaker: ManualSpeaker = ManualSpeaker())
        -> (queue: SpeakQueue, speaker: ManualSpeaker, bus: RecordingBus) {
        let bus = RecordingBus()
        let queue = SpeakQueue(speaker: speaker, observability: bus)
        return (queue, speaker, bus)
    }

    private func waitUntil(_ condition: () -> Bool,
                           _ message: @autoclosure () -> String
                               = "condition never became true",
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail(message(), file: file, line: line)
        }
    }

    /// Finishes `count` utterances one by one, waiting for each to park
    /// first so a release never races a not-yet-started utterance.
    private func releaseAll(_ count: Int, speaker: ManualSpeaker) async {
        for _ in 0..<count {
            await waitUntil({ speaker.parkedText != nil },
                            "expected a parked utterance to release")
            speaker.finishCurrent()
        }
    }

    // MARK: - Lane preemption matrix (spec §3)

    func testLanePreemptionMatrixEachHigherPriorityAgainstEachLower() async {
        // Interrupt policy, from spec §3's interrupt-policy column:
        //   .emergency preempts all (non-cancellable once active);
        //   .safety preempts everything below it;
        //   .briefing waits for the current utterance to finish;
        //   .notification never interrupts speech;
        //   .interactive runs to completion once started.
        let pairs: [(higher: AnnouncementPriority,
                     lower: AnnouncementPriority,
                     preempts: Bool)] = [
            (.notification, .interactive, false),
            (.briefing, .interactive, false),
            (.briefing, .notification, false),
            (.safety, .interactive, true),
            (.safety, .notification, true),
            (.safety, .briefing, true),
            (.emergency, .interactive, true),
            (.emergency, .notification, true),
            (.emergency, .briefing, true),
            (.emergency, .safety, true),
        ]

        for (index, pair) in pairs.enumerated() {
            let label = "\(pair.higher)-vs-\(pair.lower) (#\(index))"
            let harness = makeHarness()
            let queue = harness.queue
            let speaker = harness.speaker
            let bus = harness.bus
            let lowerText = "lower-\(index)"
            let higherText = "higher-\(index)"

            // The lower lane is being spoken when the higher lane arrives.
            queue.enqueue(makeAnnouncement(lowerText, priority: pair.lower))
            await waitUntil({ speaker.parkedText == lowerText },
                            "\(label): lower utterance never started")
            queue.enqueue(makeAnnouncement(higherText, priority: pair.higher))

            if pair.preempts {
                await waitUntil({ speaker.cancelCount == 1
                                    && speaker.parkedText == higherText },
                                "\(label): higher lane did not preempt")
                XCTAssertEqual(speaker.startedTexts, [lowerText, higherText],
                               label)
                XCTAssertEqual(speaker.cancelledTexts, [lowerText],
                               "\(label): interrupted utterance must be cancelled")
                XCTAssertEqual(bus.events(ofType: "speakqueue.preempted").count, 1,
                               label)
                let preempted = bus.events(ofType: "speakqueue.preempted")[0]
                XCTAssertEqual(preempted.metadata["state"],
                               "\(pair.lower)_by_\(pair.higher)", label)
                speaker.finishCurrent()
                await waitUntil({ !queue.isSpeaking }, label)
                XCTAssertEqual(speaker.finishedTexts, [higherText],
                               "\(label): only the preempting utterance finishes")
            } else {
                // Lower lanes wait: nothing is cancelled, no preemption
                // event, and the higher lane speaks only after the current
                // utterance finishes (queue order, spec §3).
                XCTAssertEqual(speaker.cancelCount, 0, label)
                XCTAssertEqual(speaker.parkedText, lowerText, label)
                XCTAssertEqual(speaker.startedTexts, [lowerText], label)
                XCTAssertEqual(bus.events(ofType: "speakqueue.preempted").count, 0,
                               label)
                speaker.finishCurrent()
                await waitUntil({ speaker.parkedText == higherText },
                                "\(label): waiting lane never spoke")
                XCTAssertEqual(speaker.startedTexts, [lowerText, higherText],
                               label)
                speaker.finishCurrent()
                await waitUntil({ !queue.isSpeaking }, label)
            }
            XCTAssertEqual(bus.events(ofType: "speakqueue.speak_failed").count, 0,
                           label)
            XCTAssertEqual(bus.events(ofType: "speakqueue.dropped").count, 0,
                           label)
        }
    }

    // MARK: - Same-priority order (FIFO) and non-blocking enqueue

    func testSamePriorityAnnouncementsSpeakInEnqueueOrderWithoutBlocking() async {
        let harness = makeHarness()
        let queue = harness.queue
        let speaker = harness.speaker

        queue.enqueue(makeAnnouncement("first", priority: .interactive))
        await waitUntil({ speaker.parkedText == "first" },
                        "first utterance never started")

        // enqueue returns immediately while the first utterance is still
        // in flight — the later ones must not have started.
        queue.enqueue(makeAnnouncement("second", priority: .interactive))
        queue.enqueue(makeAnnouncement("third", priority: .interactive))
        XCTAssertEqual(speaker.startedTexts, ["first"],
                       "enqueue must not block or start later utterances")

        await releaseAll(3, speaker: speaker)
        await waitUntil({ !queue.isSpeaking })
        XCTAssertEqual(speaker.startedTexts, ["first", "second", "third"])
        XCTAssertEqual(speaker.finishedTexts, ["first", "second", "third"])
        XCTAssertEqual(speaker.cancelCount, 0)
    }

    // MARK: - Coalescing (spec §4.1)

    private func makeTimeControlledHarness()
        -> (harness: (queue: SpeakQueue, speaker: ManualSpeaker, bus: RecordingBus),
            advance: (TimeInterval) -> Void) {
        var fakeNow = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = makeHarness()
        harness.queue.nowProvider = { fakeNow }   // captured by reference
        return (harness, { fakeNow += $0 })
    }

    func testNotificationsWithinWindowCoalesceIntoSingleSummary() async {
        let (harness, advance) = makeTimeControlledHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus
        let cardN1 = makeCard("n1")
        let cardN2 = makeCard("n2")

        // A briefing is being spoken while two notifications arrive.
        queue.enqueue(makeAnnouncement("briefing-blocker", priority: .briefing))
        await waitUntil({ speaker.parkedText == "briefing-blocker" })

        advance(1)
        queue.enqueue(makeAnnouncement("n1", priority: .notification,
                                       sourceID: "family", card: cardN1))
        advance(2)
        queue.enqueue(makeAnnouncement("n2", priority: .notification,
                                       sourceID: "family", card: cardN2))

        let coalesced = bus.events(ofType: "speakqueue.coalesced")
        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(coalesced[0].metadata["entry_count"], "2")
        XCTAssertEqual(coalesced[0].metadata["state"], "notification")

        speaker.finishCurrent()   // briefing finishes
        await waitUntil({ speaker.parkedText != nil })
        let spoken = speaker.startedTexts
        XCTAssertEqual(spoken.count, 2, "blocker + ONE summary utterance")
        XCTAssertEqual(spoken[1],
                       SpeakQueue.summaryText(count: 2,
                                              locale: AppLanguage.persisted().locale))
        XCTAssertNotEqual(spoken[1], "n1")
        XCTAssertNotEqual(spoken[1], "n2",
                          "individual texts are replaced by the summary")
        XCTAssertEqual(queue.currentCard, cardN2,
                       "summary surfaces the newest member's card")

        speaker.finishCurrent()
        await waitUntil({ !queue.isSpeaking })
    }

    func testCoalescedSummaryAccumulatesFurtherInWindowArrivals() async {
        let (harness, advance) = makeTimeControlledHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus

        queue.enqueue(makeAnnouncement("briefing-blocker", priority: .briefing))
        await waitUntil({ speaker.parkedText == "briefing-blocker" })

        advance(1)
        queue.enqueue(makeAnnouncement("n1", priority: .notification))
        advance(1)
        queue.enqueue(makeAnnouncement("n2", priority: .notification))
        advance(1)
        queue.enqueue(makeAnnouncement("n3", priority: .notification))

        XCTAssertEqual(bus.events(ofType: "speakqueue.coalesced").count, 2)
        XCTAssertEqual(bus.events(ofType: "speakqueue.coalesced")[1]
                                .metadata["entry_count"], "3")

        speaker.finishCurrent()
        await waitUntil({ speaker.parkedText != nil })
        XCTAssertEqual(speaker.startedTexts.count, 2,
                       "blocker + ONE summary utterance")
        XCTAssertEqual(speaker.parkedText,
                       SpeakQueue.summaryText(count: 3,
                                              locale: AppLanguage.persisted().locale))
        speaker.finishCurrent()
        await waitUntil({ !queue.isSpeaking })
    }

    func testNotificationsOutsideCoalescingWindowStaySeparate() async {
        let (harness, advance) = makeTimeControlledHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus

        queue.enqueue(makeAnnouncement("briefing-blocker", priority: .briefing))
        await waitUntil({ speaker.parkedText == "briefing-blocker" })

        advance(1)
        queue.enqueue(makeAnnouncement("n1", priority: .notification))
        advance(SpeakQueue.notificationCoalescingWindow + 1)
        queue.enqueue(makeAnnouncement("n2", priority: .notification))

        XCTAssertEqual(bus.events(ofType: "speakqueue.coalesced").count, 0,
                       "61 s apart is outside the 60 s window")

        speaker.finishCurrent()
        await releaseAll(2, speaker: speaker)
        await waitUntil({ !queue.isSpeaking })
        XCTAssertEqual(speaker.startedTexts,
                       ["briefing-blocker", "n1", "n2"],
                       "both notifications read individually, in order")
    }

    // MARK: - Depth caps (spec §4.1, §6)

    func testNotificationLaneDropsOldestBeyondDepthCap() async {
        let (harness, advance) = makeTimeControlledHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus

        queue.enqueue(makeAnnouncement("briefing-blocker", priority: .briefing))
        await waitUntil({ speaker.parkedText == "briefing-blocker" })

        // Spaced 61 s apart so each stays its own item (no coalescing).
        for index in 1...9 {
            advance(SpeakQueue.notificationCoalescingWindow + 1)
            queue.enqueue(makeAnnouncement("notif-\(index)",
                                           priority: .notification))
        }

        XCTAssertEqual(bus.events(ofType: "speakqueue.dropped").count, 1,
                       "one drop when the lane exceeds its depth limit")
        XCTAssertEqual(bus.events(ofType: "speakqueue.enqueued")
                                .filter { $0.metadata["state"] == "notification" }
                                .count, 9)

        speaker.finishCurrent()
        await releaseAll(8, speaker: speaker)
        await waitUntil({ !queue.isSpeaking })

        XCTAssertFalse(speaker.startedTexts.contains("notif-1"),
                       "the OLDEST pending notification is the dropped one")
        XCTAssertEqual(speaker.startedTexts,
                       ["briefing-blocker"] + (2...9).map { "notif-\($0)" })
    }

    func testSafetyAndEmergencyAreNeverDropped() async {
        // Phase 1: a safety burst far beyond the notification lane's depth
        // limit must never drop anything.
        let (harness, _) = makeTimeControlledHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus

        queue.enqueue(makeAnnouncement("emergency-blocker",
                                       priority: .emergency))
        await waitUntil({ speaker.parkedText == "emergency-blocker" })
        for index in 1...12 {
            queue.enqueue(makeAnnouncement("safety-\(index)",
                                           priority: .safety))
        }
        XCTAssertEqual(bus.events(ofType: "speakqueue.dropped").count, 0)
        XCTAssertEqual(bus.events(ofType: "speakqueue.preempted").count, 0,
                       "safety never interrupts an active emergency")

        await releaseAll(13, speaker: speaker)
        await waitUntil({ !queue.isSpeaking })
        XCTAssertEqual(speaker.startedTexts,
                       ["emergency-blocker"] + (1...12).map { "safety-\($0)" },
                       "every safety announcement is spoken, in order")

        // Phase 2: an emergency arriving while the notification lane is at
        // its depth limit is enqueued, never dropped.
        let second = makeTimeControlledHarness()
        let queue2 = second.harness.queue
        let speaker2 = second.harness.speaker
        let bus2 = second.harness.bus
        let advance2 = second.advance

        queue2.enqueue(makeAnnouncement("briefing-blocker",
                                        priority: .briefing))
        await waitUntil({ speaker2.parkedText == "briefing-blocker" })
        for index in 1...8 {
            advance2(SpeakQueue.notificationCoalescingWindow + 1)
            queue2.enqueue(makeAnnouncement("notif-\(index)",
                                            priority: .notification))
        }
        advance2(SpeakQueue.notificationCoalescingWindow + 1)
        queue2.enqueue(makeAnnouncement("late-emergency",
                                        priority: .emergency))
        XCTAssertEqual(bus2.events(ofType: "speakqueue.dropped").count, 0,
                       "emergency arrival must not evict the notification lane")

        speaker2.finishCurrent()
        await waitUntil({ speaker2.parkedText == "late-emergency" },
                        "the emergency speaks before the queued notifications")
        XCTAssertEqual(bus2.events(ofType: "speakqueue.enqueued")
                                .filter { $0.metadata["state"] == "emergency" }
                                .count, 1)
        await releaseAll(9, speaker: speaker2)
        await waitUntil({ !queue2.isSpeaking })
        XCTAssertEqual(speaker2.startedTexts.count, 10)
    }

    // MARK: - currentCard lifecycle

    func testCurrentCardSetWhileSpeakingAndClearedAfterSpeech() async {
        let harness = makeHarness()
        let queue = harness.queue
        let speaker = harness.speaker
        let card = makeCard("outcome")

        queue.enqueue(makeAnnouncement("carded", card: card))
        await waitUntil({ speaker.parkedText == "carded" })
        XCTAssertEqual(queue.currentCard, card)
        XCTAssertTrue(queue.isSpeaking)

        speaker.finishCurrent()
        await waitUntil({ queue.currentCard == nil },
                        "card must clear after speech")
        await waitUntil({ !queue.isSpeaking })

        // A speech-only announcement never surfaces a card.
        queue.enqueue(makeAnnouncement("cardless"))
        await waitUntil({ speaker.parkedText == "cardless" })
        XCTAssertNil(queue.currentCard)
        speaker.finishCurrent()
        await waitUntil({ !queue.isSpeaking })
    }

    // MARK: - Speak failure (spec §6)

    func testFailedSpeechEmitsEventAndKeepsCardAsCardOnlyFallback() async {
        let harness = makeHarness(ReportingManualSpeaker())
        let queue = harness.queue
        let speaker = harness.speaker
        let bus = harness.bus
        let card = makeCard("medication")

        queue.enqueue(makeAnnouncement("medicine-time",
                                       priority: .briefing, card: card))
        await waitUntil({ speaker.parkedText == "medicine-time" })
        XCTAssertNil(bus.events(ofType: "speakqueue.speak_failed").first)

        // The utterance ends as a TTS failure.
        speaker.failCurrent()

        // Same-executor resumption is enqueued, not inline: wait for the
        // queue's worker to observe the failure before reading the bus.
        await waitUntil({ bus.events(ofType: "speakqueue.speak_failed").count == 1 },
                        "failure event must be emitted after the utterance fails")

        let failures = bus.events(ofType: "speakqueue.speak_failed")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].outcome, "failure")
        XCTAssertEqual(failures[0].metadata["state"], "briefing")
        XCTAssertEqual(queue.currentCard, card,
                       "card stays up: card-only fallback, never fake speech")

        // The queue keeps serving after a failure.
        queue.enqueue(makeAnnouncement("next-reply", priority: .interactive))
        await waitUntil({ speaker.parkedText == "next-reply" },
                        "queue must not stall after a failed utterance")
        XCTAssertNil(queue.currentCard)
        speaker.finishCurrent()
        await waitUntil({ !queue.isSpeaking })
        XCTAssertEqual(speaker.finishedTexts, ["next-reply"])
    }
}
