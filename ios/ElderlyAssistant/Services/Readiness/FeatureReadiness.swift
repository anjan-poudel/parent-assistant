import Foundation
import Combine

/// [BOOT-M1] Feature readiness — the honest-status spine of the
/// constant-time startup architecture.
///
/// Startup is constant-time: `AppCoordinator.init` performs no storage
/// IO and no engine construction; everything real happens in a
/// progressive boot after first paint. This file is the SOURCE OF TRUTH
/// for how ready each feature is at any moment:
///
///  - `FeatureID` — the full feature catalog (one case per feature in
///    the design).
///  - `FeatureReadiness` — the four honest states: the feature does not
///    exist on this build (`unavailable`), is still booting
///    (`preparing`), is fully usable (`ready`), or tried and failed
///    (`failed`).
///  - `FeaturePreparing` — the contract a feature's preparer adopts so
///    the boot machine can drive it uniformly (boot phase, post-boot
///    warm phase, or first-touch lazy).
///  - `ReadinessRegistry` — the single ObservableObject every surface
///    reads (injected into the SwiftUI environment next to
///    `startupBoot`), with the state machine rules: `.preparing` until
///    the first write, and failure monotonicity (`failed → preparing`
///    is only reachable through the explicit `retry(id:)` API).
///
/// Pure by construction: no storage, no UIKit, no dispatch — unit-test
/// the whole state machine without any seam.

/// The full feature catalog (constant-time startup design §readiness).
/// `CaseIterable` lets the boot UI and diagnostics render honest status
/// for every feature without a hand-maintained list.
enum FeatureID: String, CaseIterable, Sendable {
    case voicePipeline
    case wakeWord
    case stt
    case tts
    case brain
    case medications
    case routines
    case alarmsTimers
    case briefing
    case biometrics
    case feeds
    case calendarImport
    case calendarMirror
    case history
    case contacts
    case places
    case appointments
    case modelHousekeeping
    case notifications
}

/// One feature's honest status. Equatable with the reason strings — a
/// `failed`/`unavailable` state is never silent: the reason is part of
/// the state, so a user-visible surface can always say WHY.
enum FeatureReadiness: Equatable {
    /// The feature does not exist on this build/device (e.g. the Gemini
    /// stack with no API key, the KWS engine with no bundled model).
    case unavailable(reason: String?)
    /// Boot/preparation is underway — nothing honest to report yet.
    case preparing
    /// Fully usable.
    case ready
    /// Preparation ran and failed; the reason is surfaced verbatim.
    case failed(reason: String)
}

/// When a feature's preparation runs, relative to the progressive boot.
enum PreparationPhase: Sendable {
    /// Part of the boot sequence (before `.ready` on the boot machine).
    case boot
    /// Detached warm-up after boot completes — must never gate `.ready`.
    case postBoot
    /// First-touch: the feature prepares itself when first used.
    case lazy
}

/// The contract a feature's preparer adopts so the boot machine can
/// register and drive it uniformly. Conformers report `prepare(on:)`
/// completion through the registry (`set(_:_:)` on main) — the registry
/// is the single place every surface consults.
protocol FeaturePreparing {
    var featureID: FeatureID { get }
    var phase: PreparationPhase { get }
    /// Runs the preparation work; MUST be safe to call on the given
    /// queue (the boot queue for `.boot`, the warm runner for
    /// `.postBoot`, or the main thread for `.lazy`). State transitions
    /// land in the registry on main.
    func prepare(on queue: DispatchQueue)
}

/// The single source of truth for feature readiness. Injected into the
/// SwiftUI environment (ElderlyAssistantApp) next to `startupBoot` —
/// every surface reads `state(of:)` for an honest, live answer.
final class ReadinessRegistry: ObservableObject {
    @Published private(set) var states: [FeatureID: FeatureReadiness] = [:]

    /// Before the first write every feature reads `.preparing` — the
    /// honest default: nothing is ready until someone has said so, and
    /// nothing claims failure before it has tried.
    func state(of feature: FeatureID) -> FeatureReadiness {
        states[feature] ?? .preparing
    }

    /// Main-confined write (the registry feeds SwiftUI; the boot
    /// machine hops to main before reporting — same contract as the
    /// coordinator's published windows).
    ///
    /// Failure is monotonic through `set`: a `.failed` feature cannot
    /// slide back to `.preparing` silently — recovery is the explicit
    /// `retry(id:)` API. A later success (`set(_, .ready)`) is always
    /// allowed: success wins.
    func set(_ feature: FeatureID, _ readiness: FeatureReadiness) {
        assert(Thread.isMainThread,
               "ReadinessRegistry.set is main-confined (the registry feeds SwiftUI)")
        if case .failed = states[feature], case .preparing = readiness {
            return // monotonicity: failed → preparing requires retry(id:)
        }
        states[feature] = readiness
    }

    /// The ONLY path back from `.failed`/`.unavailable` to `.preparing`
    /// — an explicit retry decision, never an accidental overwrite. A
    /// no-op from `.preparing`/`.ready` (nothing to retry). Main-
    /// confined, same contract as `set`.
    func retry(id feature: FeatureID) {
        assert(Thread.isMainThread,
               "ReadinessRegistry.retry is main-confined (the registry feeds SwiftUI)")
        switch states[feature] {
        case .failed, .unavailable:
            states[feature] = .preparing
        default:
            break
        }
    }
}
