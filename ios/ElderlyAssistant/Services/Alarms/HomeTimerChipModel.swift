import Foundation
import Combine

/// [HOME-TIMER-CHIP] (2026-09-11) Pure remaining-time computation for the
/// home timer chip — the in-app countdown shown in the hero's empty area
/// while a timer runs, plus the view model the chip drives.
///
/// HONEST LIMITS (by design, not oversight):
///  - The chip and the SYSTEM countdown (the Dynamic Island / Lock Screen
///    widget for AlarmKit-managed timers; the delivered one-shot
///    notification for the UN path) are INDEPENDENT renderings of the same
///    underlying timer. AlarmKit gives no in-view rendering API, so the
///    chip never reads the system's ticking number — it DERIVES remaining
///    from the app-side record: remaining = endsAt − now.
///  - PAUSE IS NOT MODELED. `TimerItem` carries no pause state and the
///    app-side seam (`AlarmKitTimerScheduling`) exposes no system-pause
///    observation, so a countdown paused from the SYSTEM UI leaves
///    `endsAt` stale and the chip would over-report remaining until the
///    row expires (the system reconciliation reconciles it). The app's own
///    stop is CANCEL-only (`AlarmTimersService.cancelTimer`) — that is the
///    only mutation the chip offers.
///  - `endsAt` is the app's creation-time record (`now + duration`), so
///    the derived remaining is an ESTIMATE of the system countdown, not a
///    mirror of it — the two renderings may briefly differ by a second.
enum HomeTimerChipModel {

    /// One computed frame of the chip: the nearest RUNNING timer's
    /// remaining seconds (ceiled, clamped ≥ 0), its label, and how many
    /// timers run in total (the "+N" affordance).
    struct Snapshot: Equatable {
        var timerID: UUID?
        var endsAt: Date?
        var label: String?
        var remaining: TimeInterval
        var activeCount: Int

        static let hidden = Snapshot(timerID: nil, endsAt: nil, label: nil,
                                     remaining: 0, activeCount: 0)

        /// Chip visibility: no running timer → hidden (the view renders
        /// no space for it).
        var isVisible: Bool { timerID != nil }
    }

    /// The chip's state at `now`. A timer counts while `isActive` and its
    /// deadline is still ahead — the same rule as
    /// `AlarmTimersService.activeTimers`, so the chip never shows a row
    /// the Settings list would not. The nearest deadline wins; ties go to
    /// the first row in the list order (deterministic under test). No
    /// active timer → `.hidden`.
    static func snapshot(timers: [TimerItem], at now: Date) -> Snapshot {
        let active = timers.filter { $0.isActive && $0.endsAt > now }
        guard let nearest = active.min(by: { $0.endsAt < $1.endsAt }) else {
            return .hidden
        }
        return Snapshot(
            timerID: nearest.id,
            endsAt: nearest.endsAt,
            label: nearest.label,
            remaining: max(nearest.endsAt.timeIntervalSince(now), 0).rounded(.up),
            activeCount: active.count
        )
    }

    /// Compact clock countdown for the chip's digits — "H:MM:SS" above an
    /// hour, "M:SS" below (Devanagari digits in the Nepali UI, the app's
    /// numeral convention — the same shapes as the Settings timer row).
    /// Negative input clamps to 0:00 (the tick that straddles the
    /// deadline may read 0:00 for a moment before the row expires).
    static func countdownText(remaining: TimeInterval, isNepali: Bool) -> String {
        let total = max(Int(remaining.rounded(.up)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return isNepali ? devanagari(text) : text
    }

    /// Western ASCII digits → Devanagari numerals ("15" → "१५").
    static func devanagari(_ value: String) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(value.map { character in
            guard let ascii = character.wholeNumberValue, (0...9).contains(ascii) else {
                return character
            }
            return digits[ascii]
        })
    }
}

/// [HOME-TIMER-CHIP] (2026-09-11) The chip's view model: nearest-timer
/// selection, visibility and the stop affordance. The display digits tick
/// through the view's `TimelineView` (the house countdown pattern); this
/// model owns only WHICH timer is shown and what stop does.
///
/// Test-friendly by construction: the rows arrive through a provider
/// closure (production: the live `AlarmTimersService.timers`) and stop
/// through an injected action (production:
/// `AlarmTimersService.cancelTimer`), so the tests need no notification
/// center, no store, no AlarmKit. Main-confined by contract — the view
/// and the tests drive it on the main thread, like the service it reads.
final class HomeTimerChipViewModel: ObservableObject {

    @Published private(set) var snapshot: HomeTimerChipModel.Snapshot

    private let rows: () -> [TimerItem]
    private let stopTimer: (UUID) -> Void
    private let now: () -> Date

    init(rows: @escaping () -> [TimerItem],
         stopTimer: @escaping (UUID) -> Void,
         now: @escaping () -> Date = Date.init) {
        self.rows = rows
        self.stopTimer = stopTimer
        self.now = now
        self.snapshot = HomeTimerChipModel.snapshot(timers: rows(), at: now())
    }

    /// Recompute from the live rows — the view calls this whenever the
    /// service publishes (a timer started, cancelled or expired) and the
    /// tests drive it directly.
    func refresh() {
        snapshot = HomeTimerChipModel.snapshot(timers: rows(), at: now())
    }

    /// Chip visibility: no running timer → hidden.
    var isVisible: Bool { snapshot.isVisible }

    /// One-tap STOP: cancels the NEAREST running timer through the
    /// existing cancellation path (`AlarmTimersService.cancelTimer` —
    /// persist removal, cancel the pending notification AND the
    /// system-managed AlarmKit timer when the system owns it). A no-op
    /// while hidden.
    func stopNearest() {
        guard let id = snapshot.timerID else { return }
        stopTimer(id)
    }
}
