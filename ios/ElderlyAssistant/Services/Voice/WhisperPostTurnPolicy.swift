import Foundation

// MARK: - Post-turn whisper weights policy ([LAT-M1] 2026-09-11,
// [LAT-EVIDENCE] 2026-09-12)
//
// The invariance contract's back-to-back half: after `recordTranscript`,
// the whisper weights must stay RESIDENT across turns so the NEXT turn
// never pays the cold load (device evidence: turn 2 paid a 135 s reload
// with `MILCompilerForANE error: failed to compile ANE model`).
//
// [LAT-EVIDENCE] Device-log findings that reshape the policy:
//
//  1. The [LAT-M1] hold gate — `available >= footprint + llama headroom`
//     — NEVER held on device: `os_proc_available_memory()` reports the
//     app's CURRENT ceiling (typically 1–3 GB), so a 2.8 GB hold gate
//     (1.6 GB weights + 1.2 GB "llama headroom") is unreachable. The log
//     shows the consequence: `post_transcript outcome=released
//     (ram_headroom)` after turn 1, then `rewarm outcome=skipped
//     (ram_headroom)` when the re-warm re-probed against the SAME gate.
//     The hold is now: HELD whenever the whisper weights themselves fit
//     under the current ceiling; RELEASED ONLY when RAM is critical
//     (`available < footprint` — a reload would endanger the app). The
//     probe is the safety valve, and it moves with OS pressure.
//
//  2. When the TTL hold lapses, the weights are released AND a
//     background re-warm MUST follow (never skipped by policy) — the
//     re-warm's own probe is the only gate — so the next turn is warm
//     again. The re-warmed weights re-arm the same TTL hold.
//
//  3. The warm-start preference gates the BOOT warm ONLY
//     (`WarmStartPlanner.plan(for:)`). Post-turn residency is the
//     invariance contract's back-to-back half and must NOT depend on the
//     toggle — `ResidencyConfig` below has no warm input by
//     construction, pinned by tests.
//
// The policy runs only for the on-device stack's WhisperKit choice —
// whisper.cpp loads a FRESH context per attempt by design (a held
// context could never be reused), so it always releases exactly as
// before.
//
// Honest limits: the probe (`MemoryProbe.availableProcessMemoryBytes`)
// measures the app's CURRENT ceiling — it varies with the OS's pressure,
// so the same device may hold sometimes and release others. A release
// is never a regression: it is today's exact behavior.

/// The pure decision + TTL policy (no IO — the coordinator probes).
enum WhisperPostTurnPolicy {

    /// [LAT-M1] Seconds the whisper weights stay held after the last
    /// transcript before they are released again (the TTL-hold window
    /// for back-to-back turns). Chosen so a normal back-and-forth
    /// conversation (a reply plays, the user answers) lands well inside
    /// the hold.
    static let ttlSeconds: TimeInterval = 60.0

    enum Decision: Equatable {
        /// Keep the weights resident (TTL-hold).
        case hold
        /// Release now and stay released — the ceiling is so tight the
        /// weights themselves do not fit (a reload would endanger the
        /// app, jetsam risk); the next turn pays the load.
        case releaseOnly
    }

    /// [LAT-EVIDENCE] The pure decision table: the weights stay held
    /// whenever THEY fit under the current ceiling; only a critical
    /// ceiling releases them. The [LAT-M1] `footprint + llama headroom`
    /// hold gate is gone — unreachable on device (see the header) — and
    /// so is the middle `releaseAndReWarm` tier: a marginal ceiling no
    /// longer forces a release + finalize-time re-warm.
    static func decide(availableBytes: UInt64,
                       whisperFootprintBytes: UInt64) -> Decision {
        availableBytes >= whisperFootprintBytes ? .hold : .releaseOnly
    }

    /// [LAT-EVIDENCE] Pure inputs to the post-transcript decision (the
    /// coordinator resolves them; no IO here). NOTE: `warmStartEnabled`
    /// is deliberately ABSENT — the warm toggle gates the BOOT warm
    /// only (`WarmStartPlanner`); post-turn residency must not depend
    /// on it (device evidence: with the toggle off the weights were
    /// released and the next turn paid the cold load).
    struct ResidencyConfig: Equatable {
        /// The active voice-engine stack.
        var stack: VoiceEngineStack
        /// The coordinator's WhisperKit-is-the-active-STT check (only
        /// the on-device stack's ANE recognizer can hold weights).
        var whisperKitIsActiveSTT: Bool
        /// WhisperKit's own availability (installed catalog artifact).
        var whisperKitAvailable: Bool
        /// Whether the model is resident — a fallback STT serving the
        /// turn leaves nothing to hold or re-warm.
        var isModelLoaded: Bool
    }

    /// What `recordTranscript` does with the whisper weights.
    enum TranscriptAction: Equatable {
        /// Keep the weights resident and arm the TTL hold.
        case hold
        /// Critical RAM — release and stay released (the next turn pays
        /// the load).
        case releaseOnly
        /// The policy does not apply (wrong stack, not the active STT,
        /// not loaded) — today's unconditional release applies.
        case notApplicable
    }

    /// The pure post-transcript decision: applies only for the
    /// on-device stack's live WhisperKit recognizer with weights
    /// resident; then hold unless the probe is critical.
    static func transcriptAction(
        config: ResidencyConfig,
        availableBytes: UInt64,
        whisperFootprintBytes: UInt64) -> TranscriptAction {
        guard config.stack == .onDevice,
              config.whisperKitIsActiveSTT,
              config.whisperKitAvailable else { return .notApplicable }
        guard config.isModelLoaded else { return .notApplicable }
        switch decide(availableBytes: availableBytes,
                      whisperFootprintBytes: whisperFootprintBytes) {
        case .hold: return .hold
        case .releaseOnly: return .releaseOnly
        }
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

// MARK: - Residency cycle (TTL hold + expiry re-warm, [LAT-EVIDENCE])

/// Owns the post-turn residency cycle: each held transcript arms the TTL
/// hold; when it lapses the weights are released AND the background
/// re-warm is REQUIRED — never skipped by policy (the re-warm's own
/// probe is the only gate, and the warm-start preference NEVER gates it)
/// — so the next turn is warm again. The coordinator supplies the two
/// side effects; tests drive the whole cycle with an injected clock (no
/// real sleeps) and pin that expiry releases exactly once and requests
/// the re-warm exactly once.
final class WhisperResidencyCycle {

    /// The underlying TTL hold (exposed so the coordinator can also
    /// inspect/cancel it directly).
    let hold: WhisperWeightsHold

    private let onRelease: () -> Void
    private let onReWarmRequired: () -> Void

    init(clock: @escaping () -> Date = { Date() },
         onRelease: @escaping () -> Void,
         onReWarmRequired: @escaping () -> Void) {
        self.hold = WhisperWeightsHold(clock: clock)
        self.onRelease = onRelease
        self.onReWarmRequired = onReWarmRequired
    }

    /// Arms the TTL from the last transcript. When it lapses the weights
    /// are released and a re-warm is owed to the background.
    func arm() {
        hold.arm(ttl: WhisperPostTurnPolicy.ttlSeconds) { [weak self] in
            self?.holdExpired()
        }
    }

    /// Clears the hold WITHOUT the expiry side effects — the weights
    /// were released by another path (a policy change, a critical probe).
    func cancel() {
        hold.cancel()
    }

    private func holdExpired() {
        onRelease()
        onReWarmRequired()
    }
}
