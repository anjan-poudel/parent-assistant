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
// key (`startup.*` in Localizable.xcstrings, Nepali + English).
//
// [BOOT-REVIEW P0-3, 2026-09-10] Spinner timing is DELAYED APPEARANCE,
// not a minimum-display floor. The old rule forced every boot to keep
// the spinner up for `spinnerMinVisibleSeconds` (2.5 s) even after work
// had finished, so a fast boot looked slow. Now:
//
//  - nothing shows for the first `spinnerAppearanceDelaySeconds`,
//  - a boot that finishes inside that window NEVER shows a spinner,
//  - once shown, it dismisses the moment boot reaches `.ready`,
//  - the capsule keeps a fixed row height so appearance/removal does
//    not resize the row itself.
//
// Failures NEVER halt boot: `failedStages` records the honest failure
// and boot continues, so each affected feature degrades exactly as it
// does today when its backing data/model is absent (empty lists, the
// Null wake-word engine) instead of blocking first paint or crashing.
// The user-facing projection of those failures is a PERSISTENT,
// capability-specific state (`StartupDegradation`) with one recovery
// action — never a transient generic capsule.

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

/// Pure timing model for the boot spinner's DELAYED APPEARANCE
/// ([BOOT-REVIEW P0-3], 2026-09-10): the indicator must not appear for
/// the first `delaySeconds` after a boot begins, so work that finishes
/// quickly shows no spinner at all; work that is still running after the
/// delay shows one. Pure and clock-free so tests drive it with injected
/// dates (no real sleeps).
struct SpinnerAppearanceDelay {
    let delaySeconds: TimeInterval

    /// Seconds elapsed since the boot began.
    func elapsed(beganAt: Date, now: Date) -> TimeInterval {
        now.timeIntervalSince(beganAt)
    }

    /// True once the delay has passed — the spinner MAY appear.
    func isElapsed(beganAt: Date, now: Date) -> Bool {
        elapsed(beganAt: beganAt, now: now) >= delaySeconds
    }

    /// Seconds until the delay passes (0 once elapsed).
    func remaining(beganAt: Date, now: Date) -> TimeInterval {
        max(0, delaySeconds - elapsed(beganAt: beganAt, now: now))
    }
}

/// Observable boot progress — the spinner's source of truth. All
/// mutations arrive on the main queue from the coordinator's boot
/// runner (same main-confined contract as `VoiceSessionStateMachine` —
/// not `@MainActor` so it can be composed by the non-isolated
/// coordinator).
final class StartupBoot: ObservableObject {
    /// [BOOT-REVIEW P0-3] Seconds a boot must still be running before the
    /// spinner is allowed to appear. Inside the review's 150–250 ms
    /// window: long enough that an ordinary boot (first frame + cached
    /// stores) never flashes an indicator, short enough that genuinely
    /// slow work still tells the user something is happening.
    static let spinnerAppearanceDelaySeconds: TimeInterval = 0.2

    /// The pure delay model the appearance gate evaluates against.
    private static let appearanceDelay = SpinnerAppearanceDelay(
        delaySeconds: spinnerAppearanceDelaySeconds)

    /// Wall-clock source — injectable so the delay logic is unit-tested
    /// with a fake clock instead of real sleeps.
    private let clock: () -> Date
    /// When the CURRENT boot began (nil until `begin()`).
    private var bootBeganAt: Date?
    /// Invalidates stale appearance timers across restarts (same token
    /// pattern the old dismissal floor used).
    private var appearanceTimerToken = 0

    /// The stage currently loading. `.ready` = boot finished.
    @Published private(set) var stage: StartupBootStage = .restoringData

    /// Stages whose work failed; boot continued past them (honest
    /// degradation). Each stage is recorded at most once. The
    /// user-facing projection is `degradations`.
    @Published private(set) var failedStages: [StartupBootStage] = []

    /// True once `begin()` was called. The spinner stays hidden until a
    /// boot is actually running — on first run the onboarding wizard
    /// shows for a while BEFORE `start()` boots, and an unstarted spinner
    /// would claim "Loading…" while nothing loads.
    @Published private(set) var hasStarted = false

    /// [LAUNCH-SCREEN] Published (previously a computed property): a
    /// fast boot keeps the spinner up until the visibility floor passes,
    /// so dismissal must publish AFTER `.ready` too.
    @Published private(set) var spinnerVisible = false

    var isComplete: Bool { stage == .ready }
    var hasFailures: Bool { !failedStages.isEmpty }

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Starts the machine. Idempotent while a boot is in flight; only a
    /// COMPLETED boot may restart (a fresh `.restoringData`). A restart
    /// opens a FRESH visibility window for the new boot.
    func begin() {
        hasStarted = true
        if stage == .ready {
            stage = .restoringData
            failedStages = []
            spinnerVisible = true
            spinnerFirstVisibleAt = clock()
            dismissalTimerToken += 1
        }
        showSpinnerIfNeeded()
    }

    /// Advances forward only. A repeated or backward advance is a no-op,
    /// so a late phase completion can never rewind progress.
    func advance(to next: StartupBootStage) {
        guard next.rank >= stage.rank else { return }
        stage = next
        if next == .ready {
            dismissSpinnerIfFloorElapsed()
        }
    }

    /// Records an honest failure for the given stage; boot keeps moving.
    func recordFailure(_ failed: StartupBootStage) {
        guard !failedStages.contains(failed) else { return }
        failedStages.append(failed)
    }

    /// The dismissal gate: hides the spinner once boot is complete AND
    /// the minimum-visibility floor has passed. Called when `.ready`
    /// lands, by the scheduled floor timer, and by tests with a fake
    /// clock. Never delays boot — only the spinner's collapse.
    func dismissSpinnerIfFloorElapsed() {
        guard isComplete, spinnerVisible else { return }
        guard let visibleAt = spinnerFirstVisibleAt else {
            spinnerVisible = false
            return
        }
        let now = clock()
        if Self.visibilityFloor.isElapsed(firstVisibleAt: visibleAt, now: now) {
            spinnerVisible = false
        } else {
            scheduleFloorTimer(
                after: Self.visibilityFloor.remaining(firstVisibleAt: visibleAt, now: now))
        }
    }

    /// Shows the spinner the moment a boot is actually running. Guards
    /// so a spinner already up (restart path) never rewinds its window.
    private func showSpinnerIfNeeded() {
        guard hasStarted, stage != .ready, !spinnerVisible else { return }
        spinnerVisible = true
        spinnerFirstVisibleAt = clock()
    }

    /// One-shot real-time timer for the floor remainder (production
    /// only — tests tick the fake clock and call the gate directly).
    private func scheduleFloorTimer(after seconds: TimeInterval) {
        dismissalTimerToken += 1
        let token = dismissalTimerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.dismissalTimerToken == token else { return }
            self.dismissSpinnerIfFloorElapsed()
        }
    }
}

// MARK: - Spinner overlay (Home + onboarding host)

/// The visible startup indicator: a small capsule row listing what is
/// loading, dismissed when the background boot completes. When a stage
/// failed (honest degradation) a short caption surfaces once boot
/// finishes and auto-hides — the app stays fully usable either way.
///
/// [BOOT-LATENCY → LAUNCH-SCREEN] Hosted as an overlay anchored to the
/// talk hero's disc (8pt above its top edge — see `TalkButton`), and as
/// the talk stage's first flow element in the confirmation-chips branch
/// (above the chips, which occupy the hero's position); the hosts own
/// the spacing, so this view carries no self-padding. Renders
/// zero-height while nothing shows.
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
