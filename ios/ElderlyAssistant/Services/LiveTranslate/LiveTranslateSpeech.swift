import Foundation

// T-024 — C12's spoken output for the live camera translation feature
// (FR-LCT-021, FR-LCT-023, NFR-LCT-004, NFR-LCT-009, CL-8).
//
// What this file exists to make true:
//
//  1. **Three entry points, and no others.** Tapping a bubble speaks that
//     region's translation; "read this to me" speaks the visible regions
//     top-to-bottom; and a command window that ended in a miss speaks C12's
//     one re-prompt. Nothing else in this feature can construct an
//     `Announcement`: there is no observer on resolution, no property hook,
//     no timer and no `didSet` that enqueues speech — the only three
//     construction sites in the feature are the three handlers below, and a
//     test counts them and fails if a fourth appears. That is how "nothing is
//     spoken automatically" is enforced structurally rather than by
//     convention. (The third site arrived with T-026; the count in T-024's
//     suite was widened deliberately for it, and the re-prompt has exactly one
//     call site, which that suite also asserts.)
//
//  2. **The spoken string is the on-screen string.** The text a region is
//     spoken with is the primary line the placement measured and the overlay
//     draws (T-020/T-021) — the same expression `RegionPresentation` uses for
//     its accessibility label. A translation is never re-derived here, so
//     what the elder hears cannot drift from what the elder sees. A region
//     that has no translation is read as its recognized text (FR-LCT-023) and
//     never as a translation.
//
//  3. **Speech is the shipped speech path.** `Announcement(.interactive)` on
//     the shipped `SpeakQueue`: no second speaker, no second queue, no card
//     (these utterances are speech only). The active-language voice is the
//     queue's own choice (`AppLanguage.persisted()`), which is what
//     NFR-LCT-004 requires and why nothing here names a voice.
//
//  4. **Interruptible at every point.** `stop` and the session's `close` both
//     drain the feature's own announcements from the queue and cancel the one
//     playing — *only* the feature's: a medication reminder queued behind a
//     reading is untouched. `drain(sourceID:)` is the additive queue seam in
//     `Services/Voice/SpeakQueue.swift`; the feature's own announcements all
//     carry this file's `sourceID`.
//
//  5. **Nothing about reading translates, sends or consents.** The spoken
//     plan is built from placements the pipeline already produced; this file
//     holds no client, no cache, no consent gate and no cost governor, so
//     "reading re-translates nothing" is a property of what is in scope here
//     rather than a promise about control flow.
//
//  6. **No content on the log surface.** Every event this file emits is
//     `speak_requested` / `speak_failed` with a `mode` token built from
//     T-003's closed vocabulary (`LiveTranslateSpeechMode`); the text being
//     spoken has no parameter to travel in.

/// The one on-screen string a region is spoken with, and the region it
/// belongs to. The text is exactly the placement's primary line — the string
/// the overlay draws and `RegionPresentation` announces — so a caller cannot
/// speak a translation the pixels do not show.
struct LiveTranslateSpokenRegion: Equatable {
    let regionID: TextRegionStabilizer.RegionIdentity
    let text: String
}

/// The shipped speech path, narrowed to what C12 uses.
///
/// Deliberately *not* a second speech abstraction: `enqueue` is
/// `SpeakQueueProtocol`'s own contract, and `drain` / `isSpeaking(sourceID:)`
/// are the additive source-scoped operations T-024 needs from the queue it
/// already speaks through. A test double implements this protocol; the
/// production conformance is `SpeakQueue`'s (below).
protocol LiveTranslateSpeechPath: AnyObject {
    /// Non-blocking: accepts the announcement and applies lane policy.
    func enqueue(_ announcement: Announcement)
    /// Drops every pending announcement belonging to `sourceID` and cancels
    /// the utterance now playing when it is that source's. Another source's
    /// queued work is never touched.
    func drain(sourceID: String)
    /// True while `sourceID` has an utterance playing or waiting. T-025's
    /// microphone gate reads this: the feature must not listen to itself.
    func isSpeaking(sourceID: String) -> Bool
}

/// The production conformance. `SpeakQueue` is the shipped queue; the
/// protocol above is the feature's view of it, so tests drive a double and
/// production drives the real queue.
extension SpeakQueue: LiveTranslateSpeechPath {}

/// C12's spoken output: tap-to-hear, "read this to me", repeat, stop, close.
///
/// One instance per session (T-026 builds it with the session and closes it
/// with the session) — after `close()` the instance is inert, so a view whose
/// teardown races a tap cannot start speech into a session that has ended.
final class LiveTranslateSpeech {

    /// Every announcement this feature enqueues carries this `sourceID`; it is
    /// the feature's component token (T-003), used as one spelling rather than
    /// two, and it is what makes the source-scoped drain exact.
    static let sourceID = LiveTranslateEventCatalogue.component

    private let path: LiveTranslateSpeechPath
    private let events: LiveTranslateEvents

    /// What the last speaking request said, in the order it said it — the
    /// exact `Announcement` values that were enqueued, so `repeatLast` replays
    /// them rather than reconstructing anything (CL-8: the repeat path adds no
    /// construction site and no work).
    private var lastSpoken: [Announcement] = []

    /// Set by `close()`. A closed session speaks nothing, drains nothing late
    /// and emits no further event.
    private var isClosed = false

    init(path: LiveTranslateSpeechPath, events: LiveTranslateEvents) {
        self.path = path
        self.events = events
    }

    // MARK: - The pure half (what would be said, and in what order)

    /// The visible regions in reading order: top to bottom by the normalized
    /// box's vertical midpoint, ties broken by the horizontal midpoint, then
    /// by identity.
    ///
    /// The ordering is **T-020's**, not a second copy of it: this delegates to
    /// `LiveOverlayPlacement.readingOrder`, which is the placement's own
    /// canonical order, so the reading order and the draw order cannot
    /// disagree (the Gherkin's "order of the region boxes' vertical
    /// midpoints").
    static func orderedForReading(
        _ placed: [LiveOverlayPlacement.PlacedOverlay]
    ) -> [LiveOverlayPlacement.PlacedOverlay] {
        LiveOverlayPlacement.readingOrder(placed)
    }

    /// The on-screen string for a region, or `nil` when there is nothing to
    /// say. The primary line is what the bubble shows and what a screen reader
    /// announces; a region whose line is blank is not spoken as silence.
    static func spokenText(of placement: LiveOverlayPlacement.PlacedOverlay) -> String? {
        let text = (placement.lines.first?.text ?? placement.result.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether "read this to me" speaks this region.
    ///
    /// A resolved region is read as its translation; a degraded region is read
    /// as its recognized text, honestly, because that is what is on screen
    /// (FR-LCT-023). A quarantined region is **never** spoken (NFR-LCT-009) —
    /// its text was withheld from the cloud tier precisely because it is not
    /// safe to handle — and a pending region is not read: it has no settled
    /// outcome yet, and reading the raw recognized text as if it were the
    /// answer would present unfinished work as a result.
    ///
    /// A quarantined region's exclusion is per region: the caller keeps
    /// walking, so one withheld string never silences the rest.
    static func isReadable(_ placement: LiveOverlayPlacement.PlacedOverlay) -> Bool {
        switch placement.result.outcome {
        case .pending:
            return false
        case .resolved:
            return true
        case .degraded(_, let reason):
            return reason != .textQuarantined
        }
    }

    /// Whether tapping this region's bubble speaks it.
    ///
    /// Only a region that actually has a translation is a "hear this"
    /// affordance (T-021's `speaksTranslation`): a bubble with nothing to say
    /// is not a button that does nothing. Tap-to-hear for a region with no
    /// translation is refused, not degraded into reading the original —
    /// reading the original is the *command*'s honest behaviour, and it is
    /// worth saying which one the elder asked for.
    static func isTappableToHear(_ placement: LiveOverlayPlacement.PlacedOverlay) -> Bool {
        placement.result.sourceTier != nil
    }

    /// What "read this to me" will say: the readable regions, in reading
    /// order, each once. Empty when there is nothing safe and settled to read.
    static func spokenPlan(
        _ placed: [LiveOverlayPlacement.PlacedOverlay]
    ) -> [LiveTranslateSpokenRegion] {
        orderedForReading(placed).compactMap { placement in
            guard isReadable(placement), let text = spokenText(of: placement) else { return nil }
            return LiveTranslateSpokenRegion(regionID: placement.region.id, text: text)
        }
    }

    // MARK: - The live half (the two entry points)

    /// Entry point 1 of 3 — the tap handler. Speaks exactly one region: the
    /// one that was tapped. Returns whether speech was requested.
    @discardableResult
    func speakTappedRegion(_ regionID: TextRegionStabilizer.RegionIdentity,
                           in placed: [LiveOverlayPlacement.PlacedOverlay]) -> Bool {
        guard !isClosed else { return false }
        guard let placement = placed.first(where: { $0.region.id == regionID }),
              Self.isTappableToHear(placement),
              let text = Self.spokenText(of: placement) else {
            // Nothing to say for this region — an honest failure rather than
            // a silent success. No retry: nothing about this request will
            // become speakable by asking again.
            events.speakFailed(mode: .tap)
            return false
        }
        let announcement = Announcement(id: UUID(), text: text, priority: .interactive,
                                        sourceID: Self.sourceID, card: nil)
        remember([announcement])
        events.speakRequested(mode: .tap)
        path.enqueue(announcement)
        return true
    }

    /// Entry point 2 of 3 — the command handler's re-prompt (C12's "a miss
    /// re-prompts once and never silently drops the turn").
    ///
    /// It belongs in this file for a structural reason, not a stylistic one:
    /// this type's `isSpeaking` is what T-025's microphone gate reads, so a
    /// sentence spoken *anywhere else* would be spoken without the gate
    /// knowing, and the feature could listen to its own voice. The wording is
    /// the session's (`LiveTranslateSessionModel.repromptText`), because this
    /// type holds no copy.
    ///
    /// Deliberately **not** remembered for `repeatLast`: "say that again"
    /// means the last thing the feature read, and replaying an apology
    /// instead of the translation would answer a different question.
    @discardableResult
    func reprompt(text: String) -> Bool {
        guard !isClosed else { return false }
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else {
            events.speakFailed(mode: .reprompt)
            return false
        }
        let announcement = Announcement(id: UUID(), text: sentence, priority: .interactive,
                                        sourceID: Self.sourceID, card: nil)
        events.speakRequested(mode: .reprompt)
        path.enqueue(announcement)
        return true
    }

    /// Entry point 3 of 3 — "read this to me". Speaks the readable regions
    /// top-to-bottom, each once, sequentially on the shipped queue. Returns
    /// how many regions were spoken.
    @discardableResult
    func readAll(_ placed: [LiveOverlayPlacement.PlacedOverlay]) -> Int {
        guard !isClosed else { return 0 }
        let plan = Self.spokenPlan(placed)
        guard !plan.isEmpty else {
            // Every visible region is pending, quarantined or empty: the elder
            // asked to be read to and there is nothing that may be read. That
            // is a failure of the request, recorded as one.
            events.speakFailed(mode: .readAll)
            return 0
        }
        let announcements = plan.map { region in
            Announcement(id: UUID(), text: region.text, priority: .interactive,
                         sourceID: Self.sourceID, card: nil)
        }
        remember(announcements)
        events.speakRequested(mode: .readAll)
        for announcement in announcements {
            path.enqueue(announcement)
        }
        return announcements.count
    }

    /// The `repeat` command (CL-8): replays what was already spoken.
    ///
    /// The replay re-enqueues the very `Announcement` values the last speaking
    /// request enqueued — no text is re-derived, no translation is re-run and
    /// nothing new is constructed. The feature's own in-flight utterance is
    /// drained first, so "say that again" restarts the reading instead of
    /// queueing a second copy behind the first.
    ///
    /// With nothing spoken yet there is nothing to replay, and saying so is
    /// the honest outcome: no announcement, and `speak_failed` with the
    /// `repeat_last` mode token. A silent no-op would be a turn the elder
    /// spoke into and heard nothing back from.
    @discardableResult
    func repeatLast() -> Bool {
        guard !isClosed else { return false }
        guard !lastSpoken.isEmpty else {
            events.speakFailed(mode: .repeatLast)
            return false
        }
        let replay = lastSpoken
        path.drain(sourceID: Self.sourceID)
        events.speakRequested(mode: .repeatLast)
        for announcement in replay {
            path.enqueue(announcement)
        }
        return true
    }

    /// The `stop` command: speech stops without finishing the current item and
    /// no queued item of the feature's remains to play later. What was already
    /// spoken stays repeatable — "say that again" after "stop" is a coherent
    /// request.
    func stop() {
        guard !isClosed else { return }
        path.drain(sourceID: Self.sourceID)
    }

    /// The session's close, and the `close` command: the same drain, plus the
    /// end of the instance's life. Nothing this object enqueues can outlive
    /// the session, and no later request can start speech into a session the
    /// elder has left.
    func close() {
        guard !isClosed else { return }
        path.drain(sourceID: Self.sourceID)
        lastSpoken = []
        isClosed = true
    }

    /// True while the feature has an utterance playing or waiting. T-025's
    /// capture gate reads this so the microphone never opens on the feature's
    /// own voice.
    var isSpeaking: Bool {
        !isClosed && path.isSpeaking(sourceID: Self.sourceID)
    }

    // MARK: - Bookkeeping

    private func remember(_ announcements: [Announcement]) {
        lastSpoken = announcements
    }
}
