import SwiftUI

// MARK: - Startup boot phase (startup-perf task, 2026-09-09)
//
// Progressive async startup: the app reaches first paint with zero
// heavyweight work on the main thread, and the heavy constructions
// (keychain store loads, first-run bundled-model installs) move to a
// background queue that reports its honest progress through this
// machine; the sherpa KWS ONNX load is deferred to after first paint
// (main thread — the runtime segfaults off-main on the x86_64
// simulator). Home renders a spinner with the current stage's catalog
// key (`startup.*` in Localizable.xcstrings, Nepali + English) and
// dismisses it at `.ready`.
//
// Failures NEVER halt boot: `failedStages` records the honest failure
// and boot continues, so each affected feature degrades exactly as it
// does today when its backing data/model is absent (empty lists, the
// Null wake-word engine) instead of blocking first paint or crashing.

/// The stages a boot progresses through, in order.
enum StartupBootStage: String, CaseIterable, Equatable {
    case restoringData
    case preparingVoice
    /// [WARM-START] Preloads the speech + reply-voice models in the
    /// background so the first conversation doesn't pay the cold-engine
    /// loads. A slow warm is bounded by the coordinator's watchdog —
    /// failures NEVER halt boot, exactly like every other stage.
    case warmingEngines
    case finishingSetup
    case ready

    /// Catalog key for the spinner's honest stage label (Nepali +
    /// English, `startup.*` in Localizable.xcstrings).
    var labelKey: String { "startup.\(rawValue)" }

    /// Forward-progress rank — stage movement is monotonic so concurrent
    /// phase completions can never rewind the spinner.
    var rank: Int {
        switch self {
        case .restoringData: return 0
        case .preparingVoice: return 1
        case .warmingEngines: return 2
        case .finishingSetup: return 3
        case .ready: return 4
        }
    }
}

/// Observable boot progress — the spinner's source of truth. All
/// mutations arrive on the main queue from the coordinator's boot
/// runner (same main-confined contract as `VoiceSessionStateMachine` —
/// not `@MainActor` so it can be composed by the non-isolated
/// coordinator).
final class StartupBoot: ObservableObject {
    /// The stage currently loading. `.ready` = boot finished, spinner
    /// dismissed.
    @Published private(set) var stage: StartupBootStage = .restoringData

    /// Stages whose work failed; boot continued past them (honest
    /// degradation). Each stage is recorded at most once.
    @Published private(set) var failedStages: [StartupBootStage] = []

    /// True once `begin()` was called. The spinner stays hidden until a
    /// boot is actually running — on first run the onboarding wizard
    /// shows for a while BEFORE `start()` boots, and an unstarted spinner
    /// would claim "Loading…" while nothing loads.
    @Published private(set) var hasStarted = false

    var isComplete: Bool { stage == .ready }
    var spinnerVisible: Bool { hasStarted && !isComplete }
    var hasFailures: Bool { !failedStages.isEmpty }

    /// Starts the machine. Idempotent while a boot is in flight; only a
    /// COMPLETED boot may restart (a fresh `.restoringData`).
    func begin() {
        hasStarted = true
        guard stage == .ready else { return }
        stage = .restoringData
        failedStages = []
    }

    /// Advances forward only. A repeated or backward advance is a no-op,
    /// so a late phase completion can never rewind progress.
    func advance(to next: StartupBootStage) {
        guard next.rank >= stage.rank else { return }
        stage = next
    }

    /// Records an honest failure for the given stage; boot keeps moving.
    func recordFailure(_ failed: StartupBootStage) {
        guard !failedStages.contains(failed) else { return }
        failedStages.append(failed)
    }
}

// MARK: - Spinner overlay (Home + onboarding host)

/// The visible startup indicator: a small capsule row listing what is
/// loading, dismissed when the background boot completes. When a stage
/// failed (honest degradation) a short caption surfaces once boot
/// finishes and auto-hides — the app stays fully usable either way.
struct StartupProgressOverlay: View {
    @EnvironmentObject private var boot: StartupBoot
    @State private var showDegradedNotice = false
    @State private var degradedHideToken = 0

    /// Seconds the degraded caption stays visible after boot completes.
    private static let degradedNoticeSeconds: TimeInterval = 6

    var body: some View {
        VStack(spacing: 6) {
            if boot.spinnerVisible {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(LocalizedStringKey(boot.stage.labelKey))
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                )
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(LocalizedStringKey(boot.stage.labelKey)))
            } else if boot.hasFailures && showDegradedNotice {
                Text(LocalizedStringKey("startup.degraded"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                    )
                    .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: boot.spinnerVisible)
        .animation(.easeInOut(duration: 0.2), value: showDegradedNotice)
        .onChange(of: boot.isComplete) { complete in
            guard complete, boot.hasFailures else { return }
            showDegradedNotice = true
            degradedHideToken += 1
            let token = degradedHideToken
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.degradedNoticeSeconds
            ) {
                // Only the LATEST token may hide — a newer notice keeps
                // its full window (same rule as the voice-reset notice).
                guard self.degradedHideToken == token else { return }
                self.showDegradedNotice = false
            }
        }
    }
}
