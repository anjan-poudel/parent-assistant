import Foundation

/// [VOICE-ACK] (2026-09-11) Serial FIFO lane for the router's interactive
/// reply speech.
///
/// Historically each `CommandRouter.speak` fired its own `Task` — two
/// utterances committed in one turn (the pre-acknowledgment "एक छिन…" and
/// the slow stage's result reply) had no ordering guarantee, and the ack
/// could land AFTER the result. This lane chains utterances: every
/// enqueue awaits the previous utterance's speaker call, so speech drains
/// in commit order — ack first, result second.
///
/// `enqueue` is awaitable so the router keeps its per-utterance contract
/// exactly: `noteSpeakingEnded` and the turn tracer's speak-finished mark
/// still fire when THIS utterance's speech finished, never when a later
/// queued one did. The lane is the router's own; the shell `SpeakQueue`
/// (push speech) is untouched — both share the one Piper speaker whose
/// synthesis is itself serialized.
///
/// Failure/cancellation stays the speaker's business (Piper absorbs TTS
/// failures internally, the system voice falls back) — the lane adds no
/// policy, only ordering.
actor ReplySpeakLane {

    private let speaker: Speaker
    private var previous: Task<Void, Never>?

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    /// Queues `text` behind every utterance already committed and
    /// suspends until this utterance's speech call has returned.
    /// FIFO within the lane: call order == speak order.
    func enqueue(_ text: String, locale: Locale) async {
        let prior = previous
        let current = Task { [speaker] in
            await prior?.value
            await speaker.speak(text, locale: locale)
        }
        previous = current
        await current.value
    }
}
