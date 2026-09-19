import XCTest
@testable import ElderlyAssistant

/// Feeds read-aloud tests (feeds readaloud task, 2026-09-19).
///
/// The read flag means "this was read to me". These tests drive a REAL
/// `SpeakQueue` with a hand-gated speaker and pin the three outcomes at
/// the seam the coordinator uses (`enqueue(_:onSpoken:)`):
///  - heard to the END → the item is marked read, and the mark persists,
///  - a TTS FAILURE → nothing was heard, so nothing is marked,
///  - a safety-lane PREEMPTION → the remainder was never heard, so
///    nothing is marked,
///  - the full-article path really hands the speaker the stored BODY
///    (tag-stripped), never the card's summary.
///
/// Determinism model: the queue's worker advances only when the speaker
/// advances (`ManualSpeaker` parks every utterance until the test finishes
/// or cancels it), and every post-action expectation is polled by
/// `waitUntil`.
@MainActor
final class FeedReadAloudTests: XCTestCase {

    // MARK: - Test doubles

    /// Hand-gated speaker (the `SpeakQueueTests` double): `speak` parks
    /// until the test releases the utterance or the queue preempts it.
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

        /// The queue-initiated preemption path.
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

    /// Reports utterance outcomes, so the queue's failure path (the one
    /// that must NOT mark an item read) is actually exercised.
    private final class ReportingManualSpeaker: ManualSpeaker,
                                                SpeakResultReporting {
        func speakWithResult(_ text: String, locale: Locale) async -> SpeakResult {
            await park(text: text)
        }
    }

    /// Thread-safe event sink.
    private final class RecordingBus: ObservabilityBus {
        private let lock = NSLock()
        private var stored: [ObservabilityEvent] = []

        func emit(_ event: ObservabilityEvent) {
            lock.lock()
            stored.append(event)
            lock.unlock()
        }

        func events(ofType type: String) -> [ObservabilityEvent] {
            lock.lock(); defer { lock.unlock() }
            return stored.filter { $0.eventType == type }
        }
    }

    /// Thread-safe completion counter — the completion seam fires on the
    /// queue's worker thread, so the test cannot read a bare `var`.
    private final class FireCounter {
        private let lock = NSLock()
        private var count = 0

        func fire() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// Lock-guarded in-memory `EncryptedLocalStorage` — the read mark is
    /// written off the main thread by the completion seam, exactly as it
    /// is in production.
    private final class LockedStorage: EncryptedLocalStorage {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            lock.lock(); defer { lock.unlock() }
            do {
                values[key] = try JSONEncoder().encode(value)
                return .success(())
            } catch {
                return .failure(.encryptedWriteFailed)
            }
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            lock.lock(); defer { lock.unlock() }
            guard let data = values[key] else { return .failure(.encryptedReadFailed) }
            do {
                return .success(try JSONDecoder().decode(T.self, from: data))
            } catch {
                return .failure(.encryptedReadFailed)
            }
        }

        func delete(key: String) -> Result<Void, StorageError> {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: key)
            return .success(())
        }
    }

    // MARK: - Fixtures

    private func makeItem(id: String = "item-1",
                          title: String = "Headline",
                          summary: String = "Short blurb",
                          fullText: String = "") -> FeedItem {
        FeedItem(id: id, title: title, summary: summary, kind: .text,
                 publishedAt: nil, linkURL: "https://example.com/a",
                 imageURL: nil, mediaURL: nil, sourceName: "Test Source",
                 fullText: fullText)
    }

    private func makeAnnouncement(_ text: String,
                                  priority: AnnouncementPriority = .interactive)
        -> Announcement {
        Announcement(id: UUID(), text: text, priority: priority,
                     sourceID: "feeds_readaloud", card: nil)
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

    /// Gives a not-yet-observed async effect time to land before a
    /// NEGATIVE assertion — the seam is asynchronous, so "nothing
    /// happened" needs a settle window to be meaningful.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Heard to the end → read

    func testCompletedReadingMarksTheItemReadAndPersists() async {
        let speaker = ManualSpeaker()
        let bus = RecordingBus()
        let queue = SpeakQueue(speaker: speaker, observability: bus)
        let storage = LockedStorage()
        let store = FeedReadStateStore(storage: storage)
        let item = makeItem()
        let counter = FireCounter()

        queue.enqueue(makeAnnouncement("Headline. Short blurb")) {
            counter.fire()
            store.markRead(id: item.id)
        }
        await waitUntil({ speaker.parkedText == "Headline. Short blurb" },
                        "the reading never started")

        // Nothing is marked while the utterance is still in flight.
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(store.load().readIDs.isEmpty,
                      "an item is read only once the reading COMPLETES")

        speaker.finishCurrent()
        await waitUntil({ store.load().readIDs == [item.id] },
                        "the completion seam never marked the item read")

        XCTAssertEqual(counter.value, 1, "the seam fired exactly once")
        // Persistence: a FRESH store over the same storage (the next
        // launch) sees the item as read.
        let reloaded = FeedReadStateStore(storage: storage)
        XCTAssertTrue(reloaded.load().readIDs.contains(item.id),
                      "the read mark must survive the store instance")
        XCTAssertEqual(speaker.finishedTexts, ["Headline. Short blurb"])
        XCTAssertEqual(bus.events(ofType: "speakqueue.speak_failed").count, 0)
    }

    func testEachItemIsMarkedWithItsOwnID() async {
        let speaker = ManualSpeaker()
        let queue = SpeakQueue(speaker: speaker, observability: RecordingBus())
        let store = FeedReadStateStore(storage: LockedStorage())
        let first = makeItem(id: "item-a", title: "A")
        let second = makeItem(id: "item-b", title: "B")

        queue.enqueue(makeAnnouncement("A. Short blurb")) {
            store.markRead(id: first.id)
        }
        await waitUntil({ speaker.parkedText == "A. Short blurb" })
        speaker.finishCurrent()

        queue.enqueue(makeAnnouncement("B. Short blurb")) {
            store.markRead(id: second.id)
        }
        await waitUntil({ speaker.parkedText == "B. Short blurb" })
        speaker.finishCurrent()
        await waitUntil({ store.load().readIDs.count == 2 })

        XCTAssertEqual(store.load().readIDs, ["item-a", "item-b"],
                       "item ids are the read-state keys — never the text")
    }

    // MARK: - Nothing weaker than "heard" marks the item

    func testSpeakerFailureLeavesTheItemUnread() async {
        let speaker = ReportingManualSpeaker()
        let bus = RecordingBus()
        let queue = SpeakQueue(speaker: speaker, observability: bus)
        let store = FeedReadStateStore(storage: LockedStorage())
        let item = makeItem()
        let counter = FireCounter()

        queue.enqueue(makeAnnouncement("Headline. Short blurb")) {
            counter.fire()
            store.markRead(id: item.id)
        }
        await waitUntil({ speaker.parkedText == "Headline. Short blurb" })
        speaker.failCurrent()
        await waitUntil({ !queue.isSpeaking }, "the failed utterance never ended")
        await settle()

        XCTAssertEqual(bus.events(ofType: "speakqueue.speak_failed").count, 1,
                       "the failure path must actually have been taken")
        XCTAssertEqual(counter.value, 0,
                       "a TTS failure means nothing was heard")
        XCTAssertTrue(store.load().readIDs.isEmpty,
                      "a failed reading must not mark the item read")
    }

    func testSafetyPreemptionLeavesTheItemUnread() async {
        let speaker = ManualSpeaker()
        let bus = RecordingBus()
        let queue = SpeakQueue(speaker: speaker, observability: bus)
        let store = FeedReadStateStore(storage: LockedStorage())
        let item = makeItem()
        let counter = FireCounter()

        queue.enqueue(makeAnnouncement("Headline. Short blurb")) {
            counter.fire()
            store.markRead(id: item.id)
        }
        await waitUntil({ speaker.parkedText == "Headline. Short blurb" })

        // A safety lane interrupts the reading mid-utterance.
        queue.enqueue(makeAnnouncement("Smoke alarm", priority: .safety))
        await waitUntil({ speaker.cancelCount == 1
                            && speaker.parkedText == "Smoke alarm" },
                        "the safety lane never preempted the reading")
        speaker.finishCurrent()
        await waitUntil({ !queue.isSpeaking }, "the safety lane never ended")
        await settle()

        XCTAssertEqual(bus.events(ofType: "speakqueue.preempted").count, 1,
                       "the preemption path must actually have been taken")
        XCTAssertEqual(speaker.cancelledTexts, ["Headline. Short blurb"])
        XCTAssertEqual(counter.value, 0,
                       "the elder never heard the reading's end")
        XCTAssertTrue(store.load().readIDs.isEmpty,
                      "a preempted reading must not mark the item read")
    }

    // MARK: - Full article reading

    func testFullArticleReadingSpeaksTheTagStrippedBodyNotTheSummary() async {
        let speaker = ManualSpeaker()
        let queue = SpeakQueue(speaker: speaker, observability: RecordingBus())
        let item = makeItem(summary: "Short blurb",
                            fullText: "<p>Full <b>body</b> paragraph</p>"
                                + "<p>Second para with <a href=\"https://x.example.com\">link</a>.</p>")

        let text = FeedSpeechSanitizer.articleSpeechText(title: item.title,
                                                         summary: item.summary,
                                                         fullText: item.fullText)
        queue.enqueue(makeAnnouncement(text))
        await waitUntil({ speaker.parkedText != nil },
                        "the article reading never started")

        XCTAssertEqual(speaker.startedTexts,
                       ["Headline. Full body paragraph Second para with link."],
                       "the speaker gets the sanitized BODY, block "
                       + "boundaries intact and markup gone")
        XCTAssertFalse(speaker.startedTexts[0].contains("Short blurb"),
                       "the article path must not read the summary")
        XCTAssertFalse(speaker.startedTexts[0].contains("<"),
                       "no markup may reach the speaker")
        XCTAssertFalse(speaker.startedTexts[0].contains("https://"),
                       "no URL may reach the speaker")
    }

    func testSummaryOnlyItemReadsWhatTheSourcePublished() async {
        let speaker = ManualSpeaker()
        let queue = SpeakQueue(speaker: speaker, observability: RecordingBus())
        let item = makeItem(summary: "Short blurb", fullText: "")

        let text = FeedSpeechSanitizer.articleSpeechText(title: item.title,
                                                         summary: item.summary,
                                                         fullText: item.fullText)
        queue.enqueue(makeAnnouncement(text))
        await waitUntil({ speaker.parkedText != nil })

        XCTAssertEqual(speaker.startedTexts, ["Headline. Short blurb"],
                       "with no stored body the option reads the summary — "
                       + "what the source actually published (the card says so)")
    }
}
