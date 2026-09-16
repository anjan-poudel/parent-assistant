import SwiftUI

/// "Notify caregivers" settings leaf (caregiver event-notifications task,
/// 2026-09-13) — the per-event-type switches for the family alerts.
///
/// Three toggles, one per firing system (medicine / daily routine /
/// calendar event), all defaulting OFF: sharing what the elder is doing
/// with their family is opt-in, and the app never turns it on for them.
/// The preference is a TYPE-level "when this kind of reminder rings,
/// tell my family", not a per-reminder flag — so nothing needs editing
/// when a new medication or routine is added later, and every switch
/// takes effect on the very next fire.
///
/// Two captions below the rows, both load-bearing for trust:
///  - the CHANNEL hint says WHERE alerts go (the app the elder already
///    calls that person with — see `NotifyChannel`), so the family
///    isn't surprised by a WhatsApp message from an unknown sender;
///  - the HONESTY hint states the limit of what is shared, which is the
///    same discipline the notifier's payload follows (no medicine names,
///    no event content on the wire).
///
/// The settings object is INJECTED (not read off the coordinator) so the
/// toggles bind straight to the same instance the fire sites read:
/// `@ObservedObject` makes the row re-render the moment it is written,
/// with no forwarding hop in between.
struct CaregiverNotifySettingsView: View {
    @ObservedObject var settings: CaregiverNotifySettings

    var body: some View {
        LeafScreen(titleKey: "settings.notifyCaregivers.title") {
            VStack(spacing: 12) {
                settingsCard
            }
        }
    }

    /// Card layout follows `CalendarSettingsView`'s cards verbatim — same
    /// paddings, same card background/corner radius, same caption
    /// typography (the house pattern for a settings group).
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow("settings.notifyCaregivers.medication",
                      icon: "pills.fill",
                      isOn: $settings.medicationReminders)
            Divider().background(DesignTokens.textSecondary.opacity(0.2))
            toggleRow("settings.notifyCaregivers.routine",
                      icon: "figure.walk",
                      isOn: $settings.routineReminders)
            Divider().background(DesignTokens.textSecondary.opacity(0.2))
            toggleRow("settings.notifyCaregivers.calendar",
                      icon: "calendar",
                      isOn: $settings.calendarEvents)

            Text("settings.notifyCaregivers.channelHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("settings.notifyCaregivers.hint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // The second channel these same choices drive (calendar &
            // family sharing task, 2026-09-16). Load-bearing for trust in
            // the other direction from the hint above: the toggles now
            // decide who gets a CALENDAR INVITATION as well as who gets
            // told when a reminder rings, and an invitation is visible to
            // the family long after the alert would have been — so the
            // screen says so instead of leaving it to be discovered.
            Text("caregiverNotify.shareHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// One switch row: localized label + SF Symbol, the label in the
    /// body-point floor the senior-friendly design system sets, and the
    /// row sized to the minimum tap target (a switch an elder can't hit
    /// is not a setting).
    private func toggleRow(_ key: String,
                           icon: String,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(LocalizedStringKey(key), systemImage: icon)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .tint(DesignTokens.accent)
        .frame(minHeight: DesignTokens.minTapTargetSize)
    }
}
