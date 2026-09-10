import Foundation

// MARK: - Capability-specific degraded state (startup review, design item, 2026-09-10)
//
// Replaces the transient generic notice ("Some features are running with
// reduced functionality", auto-hidden after 6 s). That capsule said
// nothing a user could act on: it named no feature, stayed on screen for
// a fixed six seconds regardless of whether the user was reading it, and
// offered no path forward.
//
// The replacement is CAPABILITY-SPECIFIC and PERSISTENT:
//
//  - the named feature ("Voice activation is unavailable"),
//  - one plain sentence about what still works,
//  - exactly ONE recovery action,
//  - a diagnostic line meant for the Settings surface, not the capsule.
//
// A boot failure already records its stage (`StartupBoot.failedStages`)
// and boot never halts — this type is the honest, user-facing projection
// of those stage failures, and it disappears only when the capability
// recovers (`StartupBoot.clearFailure`), never on a timer.

/// One capability that can come up degraded, plus the copy that names it.
/// Keys live under `startup.degraded.*` in `Localizable.xcstrings`
/// (English + Nepali).
struct StartupDegradation: Equatable, Identifiable {
    enum Capability: String, CaseIterable {
        /// Keychain store restore failed — contacts, places, appointments,
        /// briefing, feed config are empty for this launch.
        case savedData
        /// The voice pipeline's start callback failed — manual Talk can
        /// retry, wake word stays off.
        case voiceActivation
        /// The optional speech/reply-voice warm did not finish — engines
        /// load on first use instead.
        case speechEngineWarm
        /// Model housekeeping / the brain-model preparation check failed.
        case modelSetup

        var titleKey: String { "startup.degraded.\(rawValue).title" }
        var detailKey: String { "startup.degraded.\(rawValue).detail" }
        var recoveryKey: String { "startup.degraded.\(rawValue).recovery" }
        /// Settings-level detail — deliberately NOT shown in the capsule.
        var diagnosticKey: String { "startup.degraded.\(rawValue).diagnostic" }

        /// Stable display order: safety-adjacent data first, then voice,
        /// then the optional engine work.
        var rank: Int {
            switch self {
            case .savedData: return 0
            case .voiceActivation: return 1
            case .speechEngineWarm: return 2
            case .modelSetup: return 3
            }
        }

        /// The control the user should see marked as degraded. The
        /// affected surface itself is styled by its owning view; this
        /// only names it for diagnostics/tests.
        var affectedControlKey: String { "startup.degraded.\(rawValue).control" }
    }

    let capability: Capability

    var id: String { capability.rawValue }
    var titleKey: String { capability.titleKey }
    var detailKey: String { capability.detailKey }
    var recoveryKey: String { capability.recoveryKey }
    var diagnosticKey: String { capability.diagnosticKey }
    /// The control whose degradation this state reports. Rendered next to
    /// the detail so the affected control is NAMED where the state shows
    /// (the owning surface styles the control itself).
    var controlKey: String { capability.affectedControlKey }

    /// The boot stage whose failure means this capability is degraded.
    var stage: StartupBootStage {
        switch capability {
        case .savedData: return .restoringData
        case .voiceActivation: return .preparingVoice
        case .speechEngineWarm: return .warmingEngines
        case .modelSetup: return .finishingSetup
        }
    }

    init(capability: Capability) {
        self.capability = capability
    }

    /// Nil for stages that cannot be degraded (`.ready`).
    init?(stage: StartupBootStage) {
        switch stage {
        case .restoringData: self.capability = .savedData
        case .preparingVoice: self.capability = .voiceActivation
        case .warmingEngines: self.capability = .speechEngineWarm
        case .finishingSetup: self.capability = .modelSetup
        case .ready: return nil
        }
    }

    /// Projects the boot machine's failed stages into the user-facing
    /// degradations, de-duplicated and in stable display order.
    static func degradations(forFailedStages stages: [StartupBootStage])
        -> [StartupDegradation] {
        var seen: Set<Capability> = []
        var result: [StartupDegradation] = []
        for stage in stages {
            guard let degradation = StartupDegradation(stage: stage),
                  seen.insert(degradation.capability).inserted else { continue }
            result.append(degradation)
        }
        return result.sorted { $0.capability.rank < $1.capability.rank }
    }
}

/// The recovery-action seam: the overlay's ONE button per degraded
/// capability routes through here, and `AppCoordinator.start()` installs
/// the real handler (the same static-seam pattern as
/// `NewsSourceEditorSeam.makeEditor`). A static seam — rather than an
/// `@EnvironmentObject` lookup — keeps HomeView's existing no-argument
/// `StartupProgressOverlay()` call sites source-compatible, and keeps the
/// recovery behaviour owned by the coordinator, which is the only object
/// that can actually retry the failed work.
enum StartupDegradationRecoverySeam {
    /// Default: nothing (an overlay rendered outside a started
    /// coordinator — e.g. a preview — stays inert rather than crashing).
    static var perform: (StartupDegradation.Capability) -> Void = { _ in }
}
