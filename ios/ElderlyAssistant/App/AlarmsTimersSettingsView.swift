import SwiftUI

/// [ALARMS-TIMERS] (2026-09-07) Settings leaf behind "Alarms & timers" —
/// the visual home for the voice-set alarms and in-app countdown timers.
/// Voice is the primary surface; this screen is where the rows live
/// (toggle an alarm off for the day, delete one, watch a timer count
/// down, cancel it) and where a new alarm can be added by hand
/// (DatePicker — a time already past today rolls to tomorrow at the same
/// minute, matching the voice parser's next-occurrence rule).
///
/// The caption below the lists is the platform-honesty note: iOS does not
/// let third-party apps write into the built-in Clock app, so an alarm
/// here rings as the app's own daily notification.
struct AlarmsTimersSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @State private var time = Date()
    @State private var errorKey: String?

    var body: some View {
        LeafScreen(titleKey: "alarms.list.title") {
            VStack(spacing: 12) {
                if coordinator.alarms.isEmpty && coordinator.activeTimers.isEmpty {
                    Text("alarms.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                }
                if !coordinator.alarms.isEmpty {
                    ForEach(coordinator.alarms) { alarm in
                        alarmRow(alarm)
                    }
                }
                if !coordinator.activeTimers.isEmpty {
                    ForEach(coordinator.activeTimers) { timer in
                        timerRow(timer)
                    }
                }
                addForm
                Text("alarms.honestyNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Alarm row — time-of-day, optional voice label, daily-repeat
    // toggle, delete. The toggle re-arms/cancels the pending daily
    // notification (see `AlarmTimersService.setAlarmEnabled`).

    private func alarmRow(_ alarm: Alarm) -> some View {
        HStack(spacing: 12) {
            Image(systemName: alarm.isEnabled ? "alarm.fill" : "alarm")
                .font(.system(size: 22))
                .foregroundStyle(alarm.isEnabled ? DesignTokens.accent
                                                 : DesignTokens.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText(alarm.time))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                if let label = alarm.label {
                    Text(label)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { alarm.isEnabled },
                set: { newValue in coordinator.toggleAlarm(id: alarm.id, enabled: newValue) }
            ))
            .labelsHidden()
            .tint(DesignTokens.accent)
            .accessibilityLabel(Text("settings.alarms.title"))
            Button {
                coordinator.removeAlarm(id: alarm.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.stateError)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("alarms.delete"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: Timer row — live countdown (ticks every second via
    // TimelineView), optional voice label, cancel.

    private func timerRow(_ timer: TimerItem) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(countdownText(remaining: timer.endsAt.timeIntervalSince(context.date)))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .monospacedDigit()
                    if let label = timer.label {
                        Text(label)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    coordinator.cancelTimer(id: timer.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(DesignTokens.stateError)
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("timers.cancel"))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
    }

    // MARK: Add-alarm form

    private var addForm: some View {
        VStack(spacing: 10) {
            Text("alarms.new")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text("alarms.time")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer()
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.locale, coordinator.appLanguage.locale)
            }
            .padding(14)
            // DESIGN-REVIEW: was a fixed 56pt — a minimum keeps the row
            // tall by default and lets it grow with the label + picker at
            // Accessibility XXXL instead of clipping them.
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignTokens.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

            if let errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
            }

            Button {
                saveNewAlarm()
            } label: {
                Text("alarms.save")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    // DESIGN-REVIEW: minHeight + fixedSize (was a fixed
                    // 60pt chip) so the action label wraps/grows rather
                    // than clipping at Accessibility XXXL.
                    .frame(minHeight: DesignTokens.chipHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func saveNewAlarm() {
        Task {
            let outcome = await coordinator.requestAlarmSet(at: time, label: nil)
            errorKey = Self.errorKey(for: outcome)
        }
    }

    /// Outcome → honest inline error text (the voice path speaks these
    /// lines; the leaf shows them under the form).
    private static func errorKey(for outcome: AlarmTimerSetOutcome) -> String? {
        switch outcome {
        case .scheduled: return nil
        case .permissionDenied: return "alarms.permissionDenied"
        case .atCapacity: return "alarms.capacity"
        case .failed: return "alarms.setFailed"
        }
    }

    // MARK: Text helpers

    /// DESIGN-REVIEW (P2): the row used to build a `DateFormatter` per
    /// render — once per alarm, per body evaluation, for an answer that
    /// only depends on the locale. `LocaleFormatters` builds it once per
    /// locale and hands back the same instance (see `ViewCaches.swift`).
    private func timeText(_ date: Date) -> String {
        LocaleFormatters.shortTime(locale: coordinator.appLanguage.locale).string(from: date)
    }

    /// Compact clock countdown — "H:MM:SS" above an hour, "M:SS" below
    /// (Devanagari digits in the Nepali UI, matching the app's numeral
    /// convention — see the spoken `durationText`).
    private func countdownText(remaining: TimeInterval) -> String {
        let total = max(Int(remaining.rounded(.up)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let isNepali = coordinator.appLanguage.locale.language.languageCode?.identifier == "ne"
        let text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return isNepali ? Self.devanagari(text) : text
    }

    private static func devanagari(_ value: String) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(value.map { character in
            guard let ascii = character.wholeNumberValue, (0...9).contains(ascii) else {
                return character
            }
            return digits[ascii]
        })
    }
}
