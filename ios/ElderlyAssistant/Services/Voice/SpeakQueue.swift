import Foundation
import Combine

/// Outcome of one utterance for speakers that can report one.
enum SpeakResult: Equatable {
    case spoken
    case failed
}

/// Optional refinement of `Speaker` that reports whether an utterance was
/// actually spoken.
///
/// The shipped speakers (`PiperVoiceSpeaker`, `SystemSpeechSpeaker`,
/// `NullSpeaker`) absorb TTS failures internally — Piper falls back to the
/// system voice, and Nepali without a Piper voice degrades to silence plus
/// an internal observability event — so none implement this today and
/// `SpeakQueue` degrades to assuming success on the plain `Speaker` path.
/// Failure-aware speakers (test doubles today, future speakers with an
/// honest outcome) opt in; the queue then emits `speakqueue.speak_failed`
/// and keeps the announcement card up (card-only fallback, spec §6)
/// instead of treating silence as speech.
protocol SpeakResultReporting: AnyObject {
    /// Speaks `text` in `locale` and reports how the utterance ended.
    /// Cancellation (queue-initiated preemption) resolves as `.spoken` —
    /// the queue tracks interruptions itself.
    func speakWithResult(_ text: String, locale: Locale) async -> SpeakResult
}

/// The kernel speak-queue capability surface. Sources (NotificationReader,
/// MorningBriefing, the router's `.interactive` shims) depend on this —
/// never on `SpeakQueue` directly (spec §3).
protocol SpeakQueueProtocol: AnyObject {
    /// Non-blocking: accepts the announcement, applies lane policy
    /// (coalescing, depth caps, preemption), and returns once the
    /// utterance is scheduled. When the queue was idle the first utterance
    /// may begin speaking inline on the calling thread (continuation
    /// resumption), still without ever blocking on the speaker.
    func enqueue(_ announcement: Announcement)
    /// True while an utterance is actually being spoken.
    var isSpeaking: Bool { get }
    /// Card of the currently spoken announcement. Cleared after speech;
    /// kept after a failed utterance so the content stays readable
    /// (card-only fallback, spec §6).
    var currentCard: AnnouncementCard? { get }
}

/// Priority arbitration, coalescing, and depth caps for all push speech
/// (spec §3, §4.1). Owns the single shared `Speaker` instance.
///
/// Model:
/// - One worker drains a priority-ordered queue: the highest-priority
///   pending announcement speaks next; equal priorities are FIFO.
/// - While queued, lanes are ordered by `AnnouncementPriority`. While
///   SPEAKING, only `.safety` and `.emergency` may interrupt (spec §3
///   interrupt-policy column: `.notification` never interrupts speech,
///   `.briefing` waits for the current utterance to finish, and the
///   `.interactive` reply runs to completion). Interruption = cancellation
///   of the lower utterance, not a pause — its remaining content is not
///   re-read. `.emergency` itself is non-cancellable.
/// - `.notification` announcements arriving within
///   `notificationCoalescingWindow` of the newest pending `.notification`
///   merge into ONE summary announcement ("You have N new notifications"),
///   so a notification storm reads as a single utterance. An announcement
///   that already STARTED speaking is never folded in — its text was (or is
///   being) read aloud, and merging would double-announce it.
/// - The `.notification` lane drops oldest-first beyond
///   `notificationLaneDepthLimit`. `.safety` and `.emergency` are NEVER
///   dropped (acceptance gate §8) and no other lane has a depth cap.
/// - Every admission/arbitration decision emits a PII-free observability
///   event (lane names and counts only — never announcement text).
final class SpeakQueue: SpeakQueueProtocol, ObservableObject {

    @Published private(set) var currentCard: AnnouncementCard?

    /// `.notification` arrivals within this window of the most recent
    /// pending `.notification` merge into one summary utterance (spec
    /// §4.1).
    static let notificationCoalescingWindow: TimeInterval = 60

    /// `.notification` lane depth cap: pending items beyond this are
    /// dropped oldest-first. A merged summary counts as ONE item. Other
    /// lanes are unbounded.
    static let notificationLaneDepthLimit = 8

    /// Test seam: time source for the coalescing window and depth-cap
    /// bookkeeping. Real time by default.
    var nowProvider: () -> Date = Date.init

    private let speaker: Speaker
    private let observability: ObservabilityBus

    private struct PendingItem {
        var announcement: Announcement
        /// Enqueue time of the item's NEWEST member — the sliding
        /// coalescing window anchors on this.
        var arrivedAt: Date
        /// 1 = plain announcement; ≥ 2 = summary of `mergedCount`
        /// coalesced `.notification` announcements.
        var mergedCount: Int
    }

    /// All mutable state below is guarded by `lock`. Side effects (event
    /// emission, `speaker.cancel`, worker wake-up) always run AFTER the
    /// lock is released: a resumed continuation executes inline on the
    /// resuming thread and must never re-enter the lock.
    private let lock = NSLock()
    private var pending: [PendingItem] = []
    private var active: Announcement?
    private var workerParked = false
    private var workerWake: CheckedContinuation<Announcement?, Never>?
    private var workerTask: Task<Void, Never>?

    init(speaker: Speaker, observability: ObservabilityBus) {
        self.speaker = speaker
        self.observability = observability
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    // MARK: - SpeakQueueProtocol

    func enqueue(_ announcement: Announcement) {
        let now = nowProvider()
        var events: [AdmissionEvent] = []
        var preemptedLane: AnnouncementPriority?
        var wake: CheckedContinuation<Announcement?, Never>?

        lock.lock()

        if announcement.priority == .notification {
            enqueueNotificationLocked(announcement, now: now, events: &events)
        } else {
            pending.append(PendingItem(announcement: announcement,
                                       arrivedAt: now,
                                       mergedCount: 1))
            events.append(.enqueued(announcement.priority))
        }

        // Lane preemption: only safety-critical lanes interrupt an
        // utterance that is already being spoken (spec §3). The Speaker
        // API permits this — every shipped speaker's `cancel()` resumes
        // its pending `speak()`, so the worker re-picks and the incoming
        // higher lane speaks next.
        if let current = active,
           Self.mayInterrupt(announcement.priority, current: current.priority) {
            preemptedLane = current.priority
        }

        // Wake a parked worker. Safe under the lock: the worker parks only
        // after finding `pending` empty, so an append here is always
        // visible to it.
        if workerParked {
            workerParked = false
            wake = workerWake
            workerWake = nil
        }

        lock.unlock()

        for event in events {
            switch event {
            case .enqueued(let lane): emitEnqueued(lane)
            case .coalesced(let count): emitCoalesced(count: count)
            case .dropped: emitDropped()
            }
        }
        if let preemptedLane {
            emitPreempted(preemptedLane: preemptedLane,
                          preemptingLane: announcement.priority)
            speaker.cancel()
        }
        wake?.resume(returning: nil)
    }

    var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    // MARK: - Lane policy

    /// Interrupt policy (spec §3, interrupt-policy column): only the
    /// safety-critical lanes preempt. `.safety` cancels any utterance
    /// below it; `.emergency` cancels everything below it and is itself
    /// non-cancellable. `.briefing` waits for `.interactive` to finish
    /// (and for everything else — proactive compositions never cut speech
    /// short, and a cancelled utterance loses its unspoken remainder),
    /// `.notification` never interrupts speech, and `.interactive` always
    /// runs to completion once started.
    static func mayInterrupt(_ incoming: AnnouncementPriority,
                             current: AnnouncementPriority) -> Bool {
        switch incoming {
        case .emergency: return current != .emergency
        case .safety:
            return current == .briefing
                || current == .notification
                || current == .interactive
        case .briefing, .notification, .interactive:
            return false
        }
    }

    private func enqueueNotificationLocked(_ announcement: Announcement,
                                           now: Date,
                                           events: inout [AdmissionEvent]) {
        // Coalescing (spec §4.1): merge into the most recent pending
        // .notification item when it arrived within the window. The
        // merged item is reworded as ONE summary announcement, so a storm
        // reads as a single utterance.
        if let target = lastPendingNotificationIndexLocked(),
           now.timeIntervalSince(pending[target].arrivedAt)
                <= Self.notificationCoalescingWindow {
            let count = pending[target].mergedCount + 1
            pending[target] = PendingItem(
                announcement: Self.summaryAnnouncement(
                    merging: announcement,
                    into: pending[target].announcement,
                    count: count
                ),
                arrivedAt: now,
                mergedCount: count
            )
            events.append(.coalesced(count: count))
        } else {
            pending.append(PendingItem(announcement: announcement,
                                       arrivedAt: now,
                                       mergedCount: 1))
            events.append(.enqueued(.notification))
        }
        // Depth cap: drop oldest while the lane is over its limit. Only
        // this lane drops (never .safety/.emergency).
        while notificationItemCountLocked() > Self.notificationLaneDepthLimit,
              let oldest = firstPendingNotificationIndexLocked() {
            pending.remove(at: oldest)
            events.append(.dropped)
        }
    }

    /// The coalesced summary announcement: one utterance describing
    /// `count` pending `.notification` announcements. Keeps the bucket's
    /// id/sourceID; the newest member's card wins (freshest content).
    private static func summaryAnnouncement(merging incoming: Announcement,
                                            into bucket: Announcement,
                                            count: Int) -> Announcement {
        Announcement(
            id: bucket.id,
            text: summaryText(count: count, locale: AppLanguage.persisted().locale),
            priority: .notification,
            sourceID: bucket.sourceID,
            card: incoming.card ?? bucket.card
        )
    }

    /// Localized one-line summary for `count` coalesced notifications.
    /// Key pinned in the implementation plan (values en + ne land with
    /// the wiring agent). Resolved through `L10n` — the single path
    /// non-View code resolves strings — against the same language the
    /// queue speaks, so the summary and its TTS never disagree.
    static func summaryText(count: Int, locale: Locale) -> String {
        L10n.fmt("notification.read.summary", locale: locale, count)
    }

    // MARK: - Worker

    private func runWorker() async {
        while !Task.isCancelled {
            guard let next = await waitForNextAnnouncement() else {
                continue   // woke up with an empty queue: re-park
            }
            await deliver(next)
            lock.lock()
            active = nil
            lock.unlock()
        }
    }

    /// Parks the worker when nothing is pending; otherwise claims the
    /// highest-priority item (FIFO among equals) as the active utterance.
    private func waitForNextAnnouncement() async -> Announcement? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Announcement?, Never>) in
            lock.lock()
            if let item = takeBestPendingLocked() {
                lock.unlock()
                continuation.resume(returning: item)
            } else {
                workerParked = true
                workerWake = continuation
                lock.unlock()
            }
        }
    }

    private func takeBestPendingLocked() -> Announcement? {
        guard !pending.isEmpty else { return nil }
        var best = 0
        for index in 1..<pending.count
        where pending[index].announcement.priority
                > pending[best].announcement.priority {
            best = index
        }
        // Strictly-greater replacement keeps the earliest item on ties,
        // so equal priorities speak in enqueue order (FIFO).
        active = pending[best].announcement
        return pending.remove(at: best).announcement
    }

    private func deliver(_ announcement: Announcement) async {
        setCard(announcement.card)
        let locale = AppLanguage.persisted().locale
        let result = await performSpeak(announcement.text, locale: locale)
        if result == .failed {
            // Card-only fallback (spec §6): the content was NOT spoken —
            // keep the card up so it stays readable; the observability
            // event below is the failure signal. Never fake speech.
            emitSpeakFailed(lane: announcement.priority)
        } else {
            setCard(nil)   // cleared after speech (or after preemption)
        }
    }

    private func performSpeak(_ text: String, locale: Locale) async -> SpeakResult {
        if let reporting = speaker as? SpeakResultReporting {
            return await reporting.speakWithResult(text, locale: locale)
        }
        await speaker.speak(text, locale: locale)
        return .spoken   // legacy speakers absorb failures internally
    }

    /// The card is UI state: publish directly when already on the main
    /// thread (the common inline-resumption case), otherwise hop.
    private func setCard(_ card: AnnouncementCard?) {
        if Thread.isMainThread {
            currentCard = card
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.currentCard = card
            }
        }
    }

    // MARK: - Pending .notification lane helpers (lock held)

    private func lastPendingNotificationIndexLocked() -> Int? {
        pending.lastIndex { $0.announcement.priority == .notification }
    }

    private func firstPendingNotificationIndexLocked() -> Int? {
        pending.firstIndex { $0.announcement.priority == .notification }
    }

    private func notificationItemCountLocked() -> Int {
        pending.lazy
            .filter { $0.announcement.priority == .notification }
            .count
    }

    // MARK: - Observability (PII-free: lane names + counts only)

    private enum AdmissionEvent {
        case enqueued(AnnouncementPriority)
        case coalesced(count: Int)
        case dropped
    }

    private func emitEnqueued(_ lane: AnnouncementPriority) {
        emit("speakqueue.enqueued", outcome: "success", state: "\(lane)")
    }

    private func emitCoalesced(count: Int) {
        emit("speakqueue.coalesced", outcome: "success",
             state: "notification", entryCount: count)
    }

    private func emitDropped() {
        emit("speakqueue.dropped", outcome: "failure", state: "notification")
    }

    private func emitPreempted(preemptedLane: AnnouncementPriority,
                               preemptingLane: AnnouncementPriority) {
        emit("speakqueue.preempted", outcome: "success",
             state: "\(preemptedLane)_by_\(preemptingLane)")
    }

    private func emitSpeakFailed(lane: AnnouncementPriority) {
        emit("speakqueue.speak_failed", outcome: "failure", state: "\(lane)")
    }

    private func emit(_ eventType: String,
                      outcome: String,
                      state: String,
                      entryCount: Int? = nil) {
        var metadata: [String: String] = ["state": state]
        if let entryCount {
            metadata["entry_count"] = String(entryCount)
        }
        observability.emit(ObservabilityEvent(
            component: "speakqueue",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
