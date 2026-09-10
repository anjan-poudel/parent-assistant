import SwiftUI

/// Calendar settings leaf (calendar-settings task, 2026-09-07) — the
/// three native-calendar bridge cards that used to crowd the Medication
/// schedule settings leaf, moved here wholesale (the meds leaf now edits
/// medications and festival advance reminders alone):
///   1. `calendarDisplayCard`  — the Calendar display card (added with
///                               the calendar-display task, 2026-09-09):
///                               the default-calendar picker + the BS and
///                               tithi overlay toggles behind the Home
///                               top bar's date line.
///   2. `calendarSyncCard`   — mirror the routine OUT to the Calendar app.
///   3. `twoWayCard`         — mirror events live in a Sahayak calendar and
///                             native edits apply back (default off).
///   4. `externalCalendarCard` — import native Calendar events / Reminders
///                             items IN (in-app reminders + lists).
/// Cards and their status captions are verbatim carries from the meds
/// leaf — same coordinator calls, same intent-vs-OS-truth split each
/// card documents on itself.
struct CalendarSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.calendar.title") {
            VStack(spacing: 12) {
                calendarDisplayCard
                calendarSyncCard
                twoWayCard
                externalCalendarCard
            }
        }
    }

    /// Calendar display (calendar-display task, 2026-09-09): the
    /// default-calendar picker + overlay toggles that drive the Home top
    /// bar's date line. Two big checkmark rows (the language picker's
    /// house style — senior-friendly) and two independent toggles. The
    /// app language seeded the FIRST-ever defaults (Nepali → BS primary
    /// with both overlays ON; English → Gregorian with overlays OFF);
    /// every choice here persists from then on and the language never
    /// overrides it again.
    private var calendarDisplayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("calendarDisplay.sectionTitle")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textSecondary)
            VStack(spacing: 8) {
                defaultCalendarRow(.gregorian)
                defaultCalendarRow(.nepali)
            }
            Toggle(isOn: Binding(
                get: { coordinator.showBSOverlay },
                set: { coordinator.showBSOverlay = $0 }
            )) {
                Text("calendarDisplay.bsOverlay")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Toggle(isOn: Binding(
                get: { coordinator.showTithiOverlay },
                set: { coordinator.showTithiOverlay = $0 }
            )) {
                Text("calendarDisplay.tithiOverlay")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("calendarDisplay.offlineNote")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// One default-calendar row — big, checkmarked, bordered when
    /// selected (the language picker's house style).
    private func defaultCalendarRow(_ option: CalendarDisplayDefault) -> some View {
        let isSelected = coordinator.calendarDisplayDefault == option
        return Button {
            coordinator.calendarDisplayDefault = option
        } label: {
            HStack {
                Text(LocalizedStringKey(option.labelKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(DesignTokens.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                    .stroke(isSelected ? DesignTokens.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// EventKit mirror toggle (v2 design §4.1) — requests calendar
    /// access at point of use; denial leaves the app fully working in
    /// local-only mode, honestly reported.
    private var calendarSyncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.calendarSync.isEnabled },
                set: { newValue in
                    Task { await coordinator.setCalendarSyncEnabled(newValue) }
                }
            )) {
                Label("calendarSync.toggle", systemImage: "calendar")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            Text(statusText)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Two-way mirroring (calendar-driven task, 2026-09-07) — the
    /// default-OFF extension of the mirror card above: mirrored
    /// routine events live in a dedicated "Sahayak" calendar, and
    /// edits the family makes THERE — time changes, daily↔weekly
    /// changes, deletions, even the whole calendar — apply back to the
    /// app's schedule. FULL access is requested only at the point of
    /// use (this toggle turning ON — reconciliation must READ events,
    /// which write-only access cannot); the caption below follows
    /// `twoWaySyncDecision` (toggle intent vs the OS's permission
    /// truth). Disabled while the mirror itself is off — two-way is a
    /// mode of the mirror.
    private var twoWayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.calendarSync.twoWayEnabled },
                set: { newValue in
                    Task { await coordinator.setCalendarTwoWayEnabled(newValue) }
                }
            )) {
                Label("calendar.twoWay.title", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .disabled(!coordinator.calendarSync.isEnabled)
            Text(twoWayStatusText)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var twoWayStatusText: String {
        let sync = coordinator.calendarSync
        switch CalendarSyncService.twoWaySyncDecision(
            eventsAccess: sync.currentEventsAccess,
            twoWayEnabled: sync.twoWayEnabled) {
        case .idle:
            return L10n.str("calendar.twoWay.hint", locale: coordinator.activeLocale)
        case .sync:
            return L10n.str("calendar.twoWay.caption", locale: coordinator.activeLocale)
        case .needsFullAccessPrompt, .unavailable:
            return L10n.str("calendar.twoWay.denied", locale: coordinator.activeLocale)
        }
    }

    /// Native Calendar/Reminders import (calendar-driven task,
    /// 2026-09-07) — the mirror card above writes the app's schedule
    /// OUT to EventKit; this card reads the family's native events and
    /// due reminders IN (in-app notifications + today's lists). Ask
    /// happens at point of use (the toggle); the app never writes back.
    /// Same intent-vs-truth split as the mirror: the toggle is intent,
    /// the status line is the OS's answer.
    private var externalCalendarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { coordinator.externalCalendar.isEnabled },
                set: { newValue in
                    Task { await coordinator.setExternalCalendarEnabled(newValue) }
                }
            )) {
                Label("externalReminders.toggle", systemImage: "calendar.badge.clock")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)

            if coordinator.externalCalendar.isEnabled {
                HStack {
                    Text("externalReminders.leadTitle")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Spacer()
                    // Setting the lead re-scans immediately (the
                    // service's didSet) so armed notifications follow.
                    Stepper(value: Binding(
                        get: { coordinator.externalCalendar.leadMinutes },
                        set: { coordinator.externalCalendar.leadMinutes = $0 }
                    ), in: 0...ExternalCalendarService.maxLeadMinutes) {
                        Text(BikramSambat.devanagariDigits(coordinator.externalCalendar.leadMinutes))
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundStyle(DesignTokens.accent)
                    }
                }
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

                Text(L10n.fmt("externalReminders.leadHint", locale: coordinator.activeLocale,
                              BikramSambat.devanagariDigits(coordinator.externalCalendar.leadMinutes)))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }

            Text(externalStatusText)
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var externalStatusText: String {
        switch coordinator.externalCalendar.status {
        case .enabled: return L10n.str("externalReminders.statusOn", locale: coordinator.activeLocale)
        case .partial: return L10n.str("externalReminders.statusPartial", locale: coordinator.activeLocale)
        case .denied: return L10n.str("externalReminders.statusDenied", locale: coordinator.activeLocale)
        case .error: return L10n.str("externalReminders.statusError", locale: coordinator.activeLocale)
        case .notRequested: return L10n.str("externalReminders.statusHint", locale: coordinator.activeLocale)
        }
    }

    private var statusText: String {
        switch coordinator.calendarSync.status {
        case .enabled: return L10n.str("calendarSync.statusOn", locale: coordinator.activeLocale)
        case .denied: return L10n.str("calendarSync.statusDenied", locale: coordinator.activeLocale)
        case .error: return L10n.str("calendarSync.statusError", locale: coordinator.activeLocale)
        case .notRequested: return L10n.str("calendarSync.statusHint", locale: coordinator.activeLocale)
        }
    }
}
