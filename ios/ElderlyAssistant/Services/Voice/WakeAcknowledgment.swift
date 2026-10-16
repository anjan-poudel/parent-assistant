import Foundation

// MARK: - Wake acknowledgment (profile-interview, T-096 / C05)
//
// One short personalized greeting ("Yes, Mum") between wake detection and
// capture, bounded by `wakeAckMaxHoldSeconds`. The pipeline seam
// (`VoicePipeline.wakeAcknowledger`) hands over capture start to the ack's
// completion; this service is the two-state machine that owns that span.
//
// AM-3 (design correction, recorded): the wake gate does NOT close
// synchronously at `begin`. The shipped `noteSpeakingStarted` hook closes
// the listening half inside a main-queue async, so a second detection can
// pass the gate in that narrow window. That interleave lands in the
// `superseded` teardown below: the newer ack cancels the older one, the
// older completion (already stale by generation on the pipeline side) is
// dropped, and the worst observable outcome is a restarted greeting.

/// The seam `VoicePipeline` consumes. `nil` (the shipped default) keeps
/// today's synchronous capture start; when set, capture is started by the
/// completion closure this service calls.
protocol WakeAcknowledging: AnyObject {
    /// Starts the acknowledgment if a term is recorded; calls `completion`
    /// exactly once, on the main queue, within `wakeAckMaxHoldSeconds`.
    /// No term / unresolvable template → completion synchronously.
    /// `cancel()` may drop a pending completion (pipeline stop or a
    /// superseding capture — in both cases the completion is stale by
    /// definition; see the state machine, design-l2 §7.1).
    func begin(completion: @escaping () -> Void)
    /// Cancels any in-flight ack: playback stopped, bookkeeping balanced,
    /// pending completion dropped, no event.
    func cancel()
}

final class WakeAcknowledgmentService: WakeAcknowledging {

    private enum State {
        case idle
        case active
    }

    private enum SettleReason {
        case spoken
        case timeout
        case cancelled
        case superseded

        /// Only a real conclusion calls the pending completion; cancel and
        /// supersede drop it (it is stale by definition — §7.1).
        var callsCompletion: Bool {
            switch self {
            case .spoken, .timeout: return true
            case .cancelled, .superseded: return false
            }
        }
    }

    private let speaker: Speaker
    private let termProvider: () -> String?
    private let localeProvider: () -> Locale
    private let onSpeakingStarted: () -> Void
    private let onSpeakingEnded: () -> Void
    private let wakeAckMaxHoldSeconds: TimeInterval
    private let templateKey: String
    private let observabilityBus: ObservabilityBus?

    // State-machine fields (design-l2 §7.1): idle/active plus the single
    // `settle` exit. Main-thread-only by contract.
    private var state: State = .idle
    private var completion: (() -> Void)?
    private var maxHoldWorkItem: DispatchWorkItem?
    private var speakTask: Task<Void, Never>?
    private var speakingOutstanding = false
    private var startedAt: DispatchTime?
    /// Per-ack epoch: the supersede window (AM-3) leaves the OLD ack's
    /// speak continuation and hold timer in flight; both resume on main
    /// only AFTER the new ack has already gone active, so a bare
    /// `state == .active` check would let them tear the NEW ack down. Each
    /// async tail captures its begin's epoch and is inert once a newer
    /// begin has bumped it. (Field not in §7.1's list — it enforces that
    /// table's "completion at most once per begin" guarantee.)
    private var ackEpoch = 0

    init(speaker: Speaker,
         termProvider: @escaping () -> String?,
         localeProvider: @escaping () -> Locale,
         onSpeakingStarted: @escaping () -> Void,
         onSpeakingEnded: @escaping () -> Void,
         wakeAckMaxHoldSeconds: TimeInterval = 2.5,
         templateKey: String = "wakeAck.personalized",
         observabilityBus: ObservabilityBus? = nil) {
        self.speaker = speaker
        self.termProvider = termProvider
        self.localeProvider = localeProvider
        self.onSpeakingStarted = onSpeakingStarted
        self.onSpeakingEnded = onSpeakingEnded
        self.wakeAckMaxHoldSeconds = wakeAckMaxHoldSeconds
        self.templateKey = templateKey
        self.observabilityBus = observabilityBus
    }

    // MARK: - Entry points (main-thread-only by contract)

    func begin(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        // `begin` while active is unreachable through the pipeline — the
        // seam is only reached from a detection that already passed the
        // gate — but it is reachable in the AM-3 racing window. Defensive
        // teardown of the old ack as superseded (playback cancel, balance
        // speaking, drop old completion, no event); the new one proceeds.
        ackEpoch += 1
        let epoch = ackEpoch
        if state == .active {
            speaker.cancel()
            settle(.superseded, epoch: epoch)
        }

        // No term → today's silent start: completion synchronously, no
        // audio, no event.
        guard let term = termProvider(),
              !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion()
            return
        }
        let locale = localeProvider()
        // Unresolvable template / term not present after formatting → the
        // phrase is unavailable: never speak a key or a placeholder
        // (E5, `wake_ack_failed` `template_missing`), complete
        // synchronously.
        guard let phrase = WakeAcknowledgmentService.phrase(term: term,
                                                            templateKey: templateKey,
                                                            locale: locale) else {
            emit(eventType: "wake_ack_failed",
                 durationMs: nil,
                 outcome: "failure",
                 errorCode: "template_missing")
            completion()
            return
        }

        self.completion = completion
        speakingOutstanding = true
        onSpeakingStarted()
        state = .active
        startedAt = DispatchTime.now()

        // `Speaker.speak` is non-throwing; a synthesis that dies silently
        // inside the speaker presents as the timeout path below (the
        // fallback chain inside the speaker is unchanged). The task hops
        // its settle back to the main queue — this service is
        // main-confined by contract.
        speakTask = Task { [weak self] in
            await self?.speaker.speak(phrase, locale: locale)
            await MainActor.run { [weak self] in
                self?.settle(.spoken, epoch: epoch)
            }
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.ackEpoch == epoch, self.state == .active else { return }
            // The bound was reached: cut playback, report the hold, and
            // let capture start (at worst the user hears a truncated
            // greeting — never a silent stall).
            self.speaker.cancel()
            self.settle(.timeout, epoch: epoch)
        }
        maxHoldWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeAckMaxHoldSeconds,
                                      execute: item)
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .active else { return }
        speaker.cancel()
        settle(.cancelled, epoch: ackEpoch)
    }

    // MARK: - The single exit

    /// Every path out of `active` funnels through here (§7.1): cancel the
    /// timer, balance `onSpeakingEnded` exactly once, clear the fields,
    /// return to idle, emit the outcome event (except cancel/supersede,
    /// which emit nothing), THEN call the pending completion when the
    /// reason says so. A later `settle` from a cancelled or superseded
    /// ack's tail is a no-op: its captured epoch is stale, and only
    /// `active` settles.
    private func settle(_ reason: SettleReason, epoch: Int) {
        guard epoch == ackEpoch, state == .active else { return }
        maxHoldWorkItem?.cancel()
        maxHoldWorkItem = nil
        if speakingOutstanding {
            onSpeakingEnded()
            speakingOutstanding = false
        }
        speakTask = nil
        state = .idle

        let durationMs = startedAt.map {
            Int((DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000)
        }
        switch reason {
        case .spoken:
            emit(eventType: "wake_ack_spoken",
                 durationMs: durationMs,
                 outcome: "success",
                 errorCode: nil)
        case .timeout:
            emit(eventType: "wake_ack_timeout",
                 durationMs: durationMs,
                 outcome: "failure",
                 errorCode: "hold_exceeded")
        case .cancelled, .superseded:
            break // no event — both paths' completions are stale by definition
        }

        let pending = completion
        completion = nil
        startedAt = nil
        if reason.callsCompletion {
            pending?()
        }
    }

    // MARK: - Phrase composition (design-l2 §5.4 contract)

    /// Resolves the template through `L10n.str`; the phrase is nil — and
    /// never spoken — when the resolved string equals the key (unresolved),
    /// carries no `%@`, or the formatted result does not contain the term
    /// verbatim. The term is data: it is filled in, never translated.
    static func phrase(term: String, templateKey: String, locale: Locale) -> String? {
        let template = L10n.str(templateKey, locale: locale)
        guard template != templateKey, template.contains("%@") else { return nil }
        let formatted = String(format: template, term)
        guard formatted.contains(term) else { return nil }
        return formatted
    }

    // MARK: - Events (content-free: outcome / error_code / duration_ms only)

    private func emit(eventType: String,
                      durationMs: Int?,
                      outcome: String,
                      errorCode: String?) {
        observabilityBus?.emit(ObservabilityEvent(
            component: "wake_ack",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
