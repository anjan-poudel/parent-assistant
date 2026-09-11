import Foundation

// MARK: - Post-turn whisper weights policy ([LAT-M1], 2026-09-11)
//
// The invariance contract's back-to-back half: after `recordTranscript`
// releases the whisper weights (the RAM contract — llama.cpp's context
// reservation crashes on tight devices with Whisper resident), the NEXT
// turn must not pay the cold load. Two-layer policy:
//
//  1. TTL-HOLD (PRIMARY) — instead of an unconditional release, the
//     weights are HELD for `ttlSeconds` after the last transcript. A
//     back-to-back turn inside the TTL reuses the resident instance
//     (`WhisperKitSpeechRecognizer.loadKit` returns the cached kit) and
//     skips the load entirely; the TTL then re-arms from the new
//     transcript. The hold is allowed ONLY when the RAM probe says the
//     whisper weights + the llama runtime fit under the process's
//     available-memory ceiling — the probe is the safety gate that keeps
//     the hold from recreating the 6 GB crash class.
//
//  2. RE-WARM (FALLBACK) — when the probe refuses the hold, the weights
//     are released at the transcript (today's behavior) and a background
//     re-warm is scheduled for after the turn finalizes (the reply
//     speech has ended and the LLM's memory has settled), re-probed at
//     execution time. The re-warmed weights are then held under the same
//     TTL.
//
// Both paths are gated on the warm-start preference (the same settings
// disclosure as the boot warm: extra idle memory for faster
// conversations) and only run for the on-device stack's WhisperKit
// choice — whisper.cpp loads a FRESH context per attempt by design (a
// held context could never be reused), so it always releases exactly as
// before.
//
// Honest limits: the probe (`MemoryProbe.availableProcessMemoryBytes`)
// measures the app's CURRENT ceiling — it varies with the OS's pressure,
// so the same device may hold sometimes and release others. A release is
// never a regression: it is today's exact behavior.

/// The pure decision + TTL policy (no IO — the coordinator probes).
enum WhisperPostTurnPolicy {

    /// [LAT-M1] Seconds the whisper weights stay held after the last
    /// transcript before they are released again (the TTL-hold window
    /// for back-to-back turns). Chosen so a normal back-and-forth
    /// conversation (a reply plays, the user answers) lands well inside
    /// the hold, while idle RAM returns to the pre-warm contract.
    static let ttlSeconds: TimeInterval = 60.0

    /// Estimated llama.cpp runtime footprint the hold must leave room
    /// for (1B Q4 weights ~0.8 GB + context/compute buffers + iOS
    /// headroom). An ESTIMATE by design — the probe's ceiling already
    /// moves with OS pressure, so a fixed generous margin is the honest
    /// comparator.
    static let llamaRuntimeHeadroomBytes: UInt64 = 1_200_000_000

    enum Decision: Equatable {
        /// Keep the weights resident (TTL-hold).
        case hold
        /// Release now, re-warm after the turn finalizes.
        case releaseAndReWarm
        /// Release now and skip the re-warm — the ceiling is so tight a
        /// reload would endanger the app (jetsam risk); the next turn
        /// pays the load.
        case releaseOnly
    }

    /// The pure decision table: the probe result + the whisper
    /// footprint decide whether the weights may stay resident across the
    /// LLM inference of the current turn (hold), must go but may return
    /// after the turn (releaseAndReWarm), or must stay gone
    /// (releaseOnly).
    static func decide(availableBytes: UInt64,
                       whisperFootprintBytes: UInt64) -> Decision {
        if availableBytes >= whisperFootprintBytes + llamaRuntimeHeadroomBytes {
            return .hold
        }
        if availableBytes >= whisperFootprintBytes {
            return .releaseAndReWarm
        }
        return .releaseOnly
    }
}

// MARK: - TTL hold (production timer + injected-clock test seam)

/// Owns the TTL window for held whisper weights: armed after each
/// transcript (re-arming EXTENDS — the TTL runs from the LAST
/// transcript), fires `onExpire` exactly once when it lapses. The
/// production path is a real one-shot timer; tests drive the pure
/// expiry gate (`expireIfNeeded(now:)`) with a fake clock — the same
/// injected-clock doctrine as `StartupBoot`.
final class WhisperWeightsHold {

    private let clock: () -> Date
    private var expiresAt: Date?
    private var token = 0
    private var expiryWork: DispatchWorkItem?
    /// Fired (on the expiry queue — main, via the arm-site's closure)
    /// when the hold lapses or `expireIfNeeded` forces it.
    private var onExpire: (() -> Void)?

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Test-observable: the wall-clock moment the current hold expires
    /// (nil = not holding).
    var holdsUntil: Date? { expiresAt }

    var isHolding: Bool { expiresAt != nil }

    /// (Re-)arms the hold for `ttl` from NOW. A re-arm inside an
    /// existing hold EXTENDS it — the TTL always runs from the LAST
    /// transcript.
    func arm(ttl: TimeInterval, onExpire: @escaping () -> Void) {
        token += 1
        let myToken = token
        self.onExpire = onExpire
        expiresAt = clock().addingTimeInterval(ttl)
        expiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.token == myToken else { return }
            _ = self.expireIfNeeded(now: self.clock())
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: work)
    }

    /// Clears the hold WITHOUT firing — the weights were released by
    /// another path (a policy change, a re-warm failure, a recycle).
    func cancel() {
        token += 1
        expiryWork?.cancel()
        expiryWork = nil
        expiresAt = nil
        onExpire = nil
    }

    /// The pure expiry gate: while holding and `now` is at/past the
    /// expiry, clears the hold and fires the callback exactly once.
    /// Returns true when it actually expired. The production path is the
    /// scheduled work item; tests tick a fake clock and call this
    /// directly (no real sleeps).
    @discardableResult
    func expireIfNeeded(now: Date) -> Bool {
        guard let expiresAt, now >= expiresAt else { return false }
        let callback = onExpire
        token += 1
        expiryWork?.cancel()
        expiryWork = nil
        self.expiresAt = nil
        self.onExpire = nil
        callback?()
        return true
    }
}
