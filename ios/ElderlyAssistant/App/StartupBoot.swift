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

    /// [BOOT-REVIEW P0-3] True while the indicator is on screen. Doors
    /// both ways are gated on real progress: it appears only if the boot
    /// is STILL running after the appearance delay, and it goes away the
    /// moment boot reaches `.ready` (no minimum-display floor).
    @Published private(set) var spinnerVisible = false

    var isComplete: Bool { stage == .ready }
    var hasFailures: Bool { !failedStages.isEmpty }

    /// The capability-specific degraded state the UI renders — persistent
    /// until the capability recovers, never auto-hidden by a timer.
    var degradations: [StartupDegradation] {
        StartupDegradation.degradations(forFailedStages: failedStages)
    }

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Starts the machine. Idempotent while a boot is in flight; only a
    /// COMPLETED boot may restart (a fresh `.restoringData`). A restart
    /// opens a FRESH appearance window for the new boot.
    func begin() {
        hasStarted = true
        // Any pending reveal from a previous boot is stale.
        appearanceTimerToken += 1
        if stage == .ready {
            stage = .restoringData
            failedStages = []
        }
        // Hidden again from zero: the new boot gets its own full delay.
        spinnerVisible = false
        bootBeganAt = clock()
        revealSpinnerIfNeeded()
    }

    /// Advances forward only. A repeated or backward advance is a no-op,
    /// so a late phase completion can never rewind progress. Reaching
    /// `.ready` dismisses the spinner IMMEDIATELY (the moment the
    /// represented capability is ready) — the view animates the change.
    func advance(to next: StartupBootStage) {
        guard next.rank >= stage.rank else { return }
        stage = next
        if next == .ready {
            // A boot that finished before the delay never shows anything;
            // one that did show dismisses now, with no minimum duration.
            appearanceTimerToken += 1
            spinnerVisible = false
        }
    }

    /// Records an honest failure for the given stage; boot keeps moving.
    func recordFailure(_ failed: StartupBootStage) {
        guard !failedStages.contains(failed) else { return }
        failedStages.append(failed)
    }

    /// Clears a recorded failure after the capability actually recovered
    /// (the recovery action's success path) — the degradation disappears
    /// because it is no longer true, not because a timer expired.
    func clearFailure(_ recovered: StartupBootStage) {
        failedStages.removeAll { $0 == recovered }
    }

    /// The appearance gate: shows the spinner only when a boot is still
    /// running AND the appearance delay has passed. Called by `begin()`,
    /// by the scheduled delay timer, and by tests with a fake clock.
    func revealSpinnerIfNeeded() {
        guard hasStarted, !isComplete, !spinnerVisible,
              let beganAt = bootBeganAt else { return }
        let now = clock()
        if Self.appearanceDelay.isElapsed(beganAt: beganAt, now: now) {
            spinnerVisible = true
        } else {
            scheduleAppearanceTimer(
                after: Self.appearanceDelay.remaining(beganAt: beganAt, now: now))
        }
    }

    /// One-shot real-time timer for the remaining delay (production only
    /// — tests tick the fake clock and call the gate directly).
    private func scheduleAppearanceTimer(after seconds: TimeInterval) {
        appearanceTimerToken += 1
        let token = appearanceTimerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.appearanceTimerToken == token else { return }
            self.revealSpinnerIfNeeded()
        }
    }
}
