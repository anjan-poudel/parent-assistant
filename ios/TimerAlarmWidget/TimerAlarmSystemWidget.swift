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
@main
struct TimerAlarmSystemWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerAlarmSystemActivityWidget()
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
                Text(remaining(context.state))
                    .font(.caption.monospacedDigit())
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

    /// Remaining countdown as m:ss while counting down; the alert title
    /// once alerting.
    private func remaining(_ state: AlarmPresentationState) -> String {
        if case .countdown(let countdown) = state.mode {
            let seconds = max(0, Int(countdown.fireDate.timeIntervalSinceNow))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return ""
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
            if case .countdown(let countdown) = context.state.mode {
                Text(remaining(countdown))
                    .font(.title2.monospacedDigit())
                    .contentTransition(.numericText())
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

    private func remaining(_ countdown: AlarmPresentationState.Mode.Countdown) -> String {
        let seconds = max(0, Int(countdown.fireDate.timeIntervalSinceNow))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
