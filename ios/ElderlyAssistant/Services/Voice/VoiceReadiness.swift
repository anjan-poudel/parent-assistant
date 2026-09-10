import Foundation
import Combine

// MARK: - Voice readiness (startup-r2 task, 2026-09-10)
//
// CONSTANT-TIME UI LOAD: first paint never depends on a subsystem, and
// features enable progressively as their engines come ready. The Talk
// hero is the first consumer: while the voice stack is still loading it
// is DISABLED with the honest "Preparing voice…" label, and it enables
// the moment the stack is live.
//
// Shape of the pattern (not ad-hoc flags):
//  - Each subsystem owns ONE readiness signal — `preparing` until it is
//    genuinely usable, then `ready`, or `failed(reason)` when it cannot
//    be. Sources ATTACH to the tracker under a stable id, so future
//    subsystems (wake word, TTS, the LLM interpreter) plug into the
//    same machine with no new plumbing: `setSignal(id:_:)`.
//  - `VoiceReadiness` folds every attached source's latest signal into
//    one published status (the single source of truth the UI binds to):
//    `.ready` only when EVERY source is ready, `.degraded(reason)` when
//    any source failed, `.preparing` otherwise.
//  - Boot NEVER waits on any source: the tracker just re-folds when a
//    signal arrives, exactly the progressive-enablement contract.
//
// The coordinator is the only writer today: it registers the "pipeline"
// source (voiceState == .idle ⇒ the voice stack is live) and latches it
// so runtime talk cycles (idle → capturing → routing → idle) never
// re-gate the button.

/// One readiness source's honest signal. The failure reason is a
/// machine string (event/log copy), never user-facing text.
enum ReadinessSignal: Equatable {
    case preparing
    case ready
    case failed(reason: String)
}

/// The folded, published status consumers bind to. `.degraded` means a
/// source failed and voice works in reduced form — the Talk hero stays
/// TAPPABLE there (its tap is the retry path), unlike `.preparing`.
enum VoiceReadinessStatus: Equatable {
    case preparing
    case ready
    case degraded(reason: String)
}

/// Pure fold over the attached sources' latest signals. Clock-free and
/// side-effect-free so tests drive it directly.
enum VoiceReadinessFold {
    /// Ready only when every source is ready; any failure degrades;
    /// an empty or mixed set is still preparing.
    static func status(for signals: [ReadinessSignal]) -> VoiceReadinessStatus {
        guard !signals.isEmpty else { return .preparing }
        for signal in signals {
            if case .failed(let reason) = signal {
                return .degraded(reason: reason)
            }
        }
        return signals.allSatisfy { $0 == .ready } ? .ready : .preparing
    }
}

/// Observable aggregator of readiness sources. Sources attach by id and
/// push their current signal; the published `status` re-folds on every
/// update. Main-confined like the other UI-facing machines
/// (`VoiceSessionStateMachine`, `StartupBoot`).
final class VoiceReadiness: ObservableObject {
    @Published private(set) var status: VoiceReadinessStatus = .preparing

    /// Latest signal per attached source id. Iteration order is not
    /// part of the contract — the fold is order-independent by design.
    private var signals: [String: ReadinessSignal] = [:]

    func setSignal(id: String, _ signal: ReadinessSignal) {
        signals[id] = signal
        status = VoiceReadinessFold.status(for: Array(signals.values))
    }

    /// The named source's latest signal (nil = never attached). Test +
    /// diagnostics seam.
    func signal(for id: String) -> ReadinessSignal? {
        signals[id]
    }
}

// MARK: - Talk-hero gating (pure mapping)

/// [STARTUP-R2] Pure mapping for the Talk hero's enabled/disabled state
/// and its honest status line, so the gating is unit-tested without a
/// view tree. HomeView's `TalkButton` is the only consumer.
struct TalkHeroGating {
    let readiness: VoiceReadinessStatus
    let sessionState: VoiceSessionState

    /// Disabled exactly while the voice stack is preparing, or the
    /// confirmation chips own the UI. NOT disabled on `.degraded`: a
    /// failed boot-time pipeline start keeps the hero tappable because
    /// the tap IS the retry (`recoverVoiceCycle`), exactly today's
    /// behavior. Runtime states (error/stopped mid-session) keep their
    /// existing affordances — readiness only gates the boot window.
    var isDisabled: Bool {
        readiness == .preparing || sessionState == .awaitingConfirmation
    }

    /// True while the hero's status line shows the honest preparing
    /// label instead of the state's own text.
    var showsPreparingStatus: Bool { readiness == .preparing }
}
