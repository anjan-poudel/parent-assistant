import Foundation
import SwiftUI

// MARK: - Seam

/// [TIMER-ALARM] (2026-09-10) AlarmKit authorization state, mirrored from
/// `AlarmManager.AuthorizationState` (iOS 26) but declared on the seam so
/// the service and its tests never import AlarmKit (the service supports
/// iOS 16 at build time).
enum AlarmKitTimerAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
}

/// [TIMER-ALARM] (2026-09-10) Test seam over AlarmKit's `AlarmManager`
/// (iOS 26+, public framework — no special entitlement). The production
/// adapter is `AlarmKitSystemScheduler`; tests inject a recording fake so
/// the service's path selection (system-managed vs UN fallback) is
/// asserted without touching the real system alarm database.
///
/// What the system-managed timer BUYS (Apple, WWDC25 "Bring alarms and
/// timers to your app with AlarmKit"): rings through silent mode and
/// Focus, presents the full-screen alert on the Lock Screen like the
/// Clock app, shows the countdown in Dynamic Island / StandBy / Watch,
/// and keeps running even when the app is terminated. It is the honest
/// "timer behaves like a timer" answer on iOS 26; the in-app engine and
/// the UN notification remain the fallback path for older systems and
/// for an AlarmKit denial.
protocol AlarmKitTimerScheduling: AnyObject {
    /// The current AlarmKit authorization (separate from notification
    /// permission; the system remembers denials).
    var authorizationState: AlarmKitTimerAuthorization { get }
    /// Point-of-use ask; iOS prompts only while `.notDetermined`, so
    /// repeat calls are cheap and honest (same contract as the UN seam).
    func requestAuthorization() async -> AlarmKitTimerAuthorization
    /// Schedules a system-managed timer that rings after `duration`
    /// seconds. The alarm's id IS the persisted `TimerItem.id`, so the
    /// launch reconciliation matches them 1:1. Throws on failure (e.g.
    /// `AlarmManager.AlarmError.maximumLimitReached`) — the caller falls
    /// back to the UN path.
    func scheduleTimer(id: UUID, duration: TimeInterval, label: String?) async throws
    /// Removes the system-managed timer (no-op when absent).
    func cancelTimer(id: UUID)
    /// Ids of every alarm/timer AlarmKit currently manages — the launch
    /// reconciliation's source of truth for which persisted rows are
    /// system-managed (those are NOT re-armed by `scheduleAll`; the
    /// system owns them across app terminations).
    func systemTimerIDs() -> Set<UUID>
}

// MARK: - Production adapter (iOS 26)

/// Production `AlarmKitTimerScheduling` over `AlarmManager.shared`.
/// Construction is cheap and touches no authorization state.
@available(iOS 26.0, *)
final class AlarmKitSystemScheduler: AlarmKitTimerScheduling {
    private let manager = AlarmManager.shared

    /// Locale for the alarm presentation copy; kept in sync by
    /// `AppCoordinator` when the app language changes (same contract as
    /// `AlarmScheduler.locale`). Titles are resolved AT SCHEDULE TIME via
    /// `L10n.str` into plain `LocalizedStringResource`s — the system
    /// process rendering the alert gets already-localized text, so no
    /// system-side catalog lookup is needed and the alarm keeps the
    /// language it was armed in until the next re-arm (the same honest
    /// contract the UN notification content has).
    var locale: Locale

    init(locale: Locale = Locale(identifier: "en")) {
        self.locale = locale
    }

    var authorizationState: AlarmKitTimerAuthorization {
        switch manager.authorizationState {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> AlarmKitTimerAuthorization {
        do {
            let state = try await manager.requestAuthorization()
            switch state {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            print("[AlarmKitSystemScheduler] Authorization request failed: \(error)")
            return .denied
        }
    }

    func scheduleTimer(id: UUID, duration: TimeInterval, label: String?) async throws {
        let attributes = AlarmAttributes<TimerAlarmSystemMetadata>(
            presentation: AlarmPresentation(
                alert: AlarmPresentation.Alert(
                    title: LocalizedStringResource(
                        stringLiteral: L10n.str("timerAlarm.title", locale: locale)
                    )
                ),
                countdown: AlarmPresentation.Countdown(
                    title: LocalizedStringResource(
                        stringLiteral: label ?? L10n.str("timerAlarm.countdownTitle", locale: locale)
                    )
                )
            ),
            metadata: TimerAlarmSystemMetadata(),
            tintColor: .orange
        )
        // The system rings with its own alarm sound — the loudest,
        // silent-mode-proof option that exists. `.default` sound config.
        _ = try await manager.schedule(
            id: id,
            configuration: .timer(duration: duration, attributes: attributes)
        )
    }

    func cancelTimer(id: UUID) {
        try? manager.cancel(id: id)
    }

    func systemTimerIDs() -> Set<UUID> {
        Set((try? manager.alarms.map(\.id)) ?? [])
    }
}
