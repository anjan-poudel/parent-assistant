import WidgetKit
import SwiftUI
import ActivityKit
import AlarmKit

/// [TIMER-ALARM] (2026-09-10) The widget extension that hosts the
/// AlarmKit alarm presentation — REQUIRED for system-managed timers to
/// present (Apple, WWDC25 session "Bring alarms and timers to your app
/// with AlarmKit": the system presents a scheduled AlarmKit timer as a
/// Live Activity whose attributes type is
/// `AlarmAttributes<TimerAlarmSystemMetadata>`; the app must ship a
/// widget extension declaring an `ActivityConfiguration` for exactly
/// that type).
///
/// The system matches the scheduled alarm to this widget by the
/// ATTRIBUTES TYPE NAME — both the app and this extension compile the
/// same shared file (`Services/Alarms/TimerAlarmSystemShared.swift`,
/// declared in both targets in project.yml), the standard Live Activity
/// pattern.
///
/// What this widget renders: the compact countdown presentation (Lock
/// Screen banner, Dynamic Island, StandBy, Watch). The full-screen
/// alert at fire time is SYSTEM UI (like the Clock app's alarm) — the
/// presentation configured by the app at schedule time
/// (`AlarmPresentation`), not rendered here.
///
/// [TIMER-DEBUG] (2026-09-11) Countdown rendering FIX: Live Activity
/// content is a STATIC SNAPSHOT — the system re-renders it only when
/// `AlarmPresentationState` changes (mode transitions: countdown →
/// alert, pause/resume), never once per second. The previous view
/// computed the remaining time into a plain string at render time, so
/// the countdown FROZE at whatever second the snapshot was taken
/// ("4:59" for a fresh 5-minute timer — the on-device report). The
/// countdown text must be SELF-TICKING: `Text(timerInterval:)` is the
/// Live-Activity countdown primitive — the render server ticks it
/// every second without any content update.
@main
struct TimerAlarmSystemWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerAlarmSystemActivityWidget()
        TimerAlarmSystemAlarmWidget()
    }
}

struct TimerAlarmSystemActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TimerAlarmSystemMetadata>.self) { context in
            TimerAlarmActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                        Text(title(context.attributes))
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                compactTrailing(context.state)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    /// The alert/countdown title from the app-configured presentation —
    /// already localized by the app at schedule time.
    private func title(_ attributes: AlarmAttributes<TimerAlarmSystemMetadata>) -> String {
        if let countdownTitle = attributes.presentation.countdown?.title {
            return String(localized: countdownTitle)
        }
        return String(localized: attributes.presentation.alert.title)
    }

    /// The Dynamic Island compact trailing slot: the SELF-TICKING
    /// countdown while counting down (see the class doc — a plain
    /// computed string freezes here, it did on-device), static remaining
    /// text while paused.
    @ViewBuilder
    private func compactTrailing(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: countdown.startDate...countdown.fireDate,
                 countsDown: true)
                .font(.caption.monospacedDigit())
        case .paused(let paused):
            Text(staticRemaining(total: paused.totalCountdownDuration,
                                 previouslyElapsed: paused.previouslyElapsedDuration))
                .font(.caption.monospacedDigit())
        case .alert:
            Image(systemName: "timer")
        }
    }

    /// "M:SS" from the paused snapshot — a paused countdown has no
    /// `fireDate`, so a static string is the honest form (a paused timer
    /// does not tick anyway).
    private func staticRemaining(total: TimeInterval, previouslyElapsed: TimeInterval) -> String {
        let seconds = max(0, Int(total - previouslyElapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// [TIMER-DEBUG] (2026-09-11) The DAILY-ALARM side's ActivityConfiguration.
/// The alarm backend (`AlarmKitAlarmBackend`) schedules system alarms with
/// `AlarmAttributes<AlarmKitMetadata>` — and an AlarmKit alarm WITHOUT a
/// widget ActivityConfiguration for its attributes type has no
/// presentation host: same bug class as the frozen timer countdown.
/// `AlarmKitMetadata` therefore also lives in the shared file now
/// (`TimerAlarmSystemShared.swift`), compiled by both targets so the
/// type name matches exactly.
struct TimerAlarmSystemAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<AlarmKitMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "alarm.fill")
                        .foregroundColor(context.attributes.tintColor)
                    Text(String(localized: context.attributes.presentation.alert.title))
                        .font(.headline)
                        .lineLimit(2)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.4))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                        Text(String(localized: context.attributes.presentation.alert.title))
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
            } compactTrailing: {
                Image(systemName: "alarm.fill")
            } minimal: {
                Image(systemName: "alarm.fill")
            }
        }
    }
}

/// The Lock Screen / StandBy rendering: title + live remaining time.
struct TimerAlarmActivityView: View {
    let context: ActivityViewContext<AlarmAttributes<TimerAlarmSystemMetadata>>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundColor(context.attributes.tintColor)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
            }
            switch context.state.mode {
            case .countdown(let countdown):
                // [TIMER-DEBUG] Self-ticking: the render server keeps
                // this countdown live without any content-state update.
                // (The previous plain-string form froze at the snapshot
                // second — "4:59" on a fresh 5-minute timer.)
                Text(timerInterval: countdown.startDate...countdown.fireDate,
                     countsDown: true)
                    .font(.title2.monospacedDigit())
                    .contentTransition(.numericText())
            case .paused(let paused):
                Text(staticRemaining(paused))
                    .font(.title2.monospacedDigit())
            case .alert:
                EmptyView()
            }
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.4))
        .activitySystemActionForegroundColor(.white)
    }

    private var title: String {
        if let countdownTitle = context.attributes.presentation.countdown?.title {
            return String(localized: countdownTitle)
        }
        return String(localized: context.attributes.presentation.alert.title)
    }

    /// "M:SS" from the paused snapshot — a paused countdown has no
    /// `fireDate`, so a static string is the honest form (a paused timer
    /// does not tick anyway).
    private func staticRemaining(_ paused: AlarmPresentationState.Mode.Paused) -> String {
        let seconds = max(0, Int(paused.totalCountdownDuration
                                 - paused.previouslyElapsedDuration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
