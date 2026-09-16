import SwiftUI

// MARK: - Daily routines settings (routine-settings move, 2026-09-17)

/// The routine configuration surface — per-routine enable/disable toggles
/// and photo management — moved out of the Reminders leaf (सम्झना) onto
/// the Settings hub's Reminders tab (routine-settings move, 2026-09-17).
/// The Reminders leaf still shows today's routine occurrences; this is the
/// CONFIGURATION half, where the family enables/disables the seeded
/// routine categories and attaches each routine's photos.
///
/// The same DESIGN-REVIEW (P2 — "keep encrypted storage reads out of
/// `body`") discipline as the Reminders leaf applies: every
/// `coordinator.routineEntries` access is a Keychain read plus a JSON
/// decode (`RoutineStore.loadEntries` → `EncryptedLocalStorage`), so the
/// roster and summaries live in state, rebuilt by the `.task` below when
/// the underlying data actually changes; the body only reads them.
struct RoutineSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    /// Bumped after a toggle or photo edit so the cached lists re-read
    /// fresh data — the coordinator exposes routines as computed vars,
    /// not @Published.
    @State private var entriesVersion = 0
    @State private var routineEntries: [RoutineEntry] = []
    /// Each row's subtitle ("Sun, Tue · 9:00 AM"), built with the rows so
    /// no formatter work runs while drawing.
    @State private var routineSummaries: [UUID: String] = [:]
    /// The routine whose photos are being managed (photo-visual-aids task,
    /// 2026-09-16) — the photo half of a routine's configuration, reached
    /// from its manage row. Held as the full entry so the sheet renders
    /// without a store read of its own.
    @State private var photoEditorEntry: RoutineEntry?

    /// Everything the cached rows depend on: an in-screen toggle or photo
    /// save, a voice turn (a routine can be added by asking), and the
    /// app's language (the rows carry localized titles). Counting these
    /// is cheap; re-reading the stores is not.
    private var refreshKey: String {
        "\(entriesVersion)|\(coordinator.conversationHistory.count)"
            + "|\(coordinator.activeLocale.identifier)"
    }

    var body: some View {
        LeafScreen(titleKey: "settings.routines.title") {
            VStack(spacing: 12) {
                if routineEntries.isEmpty {
                    Text("settings.routines.empty")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .background(DesignTokens.card)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                } else {
                    ForEach(routineEntries) { entry in
                        routineManageRow(entry)
                    }
                }
            }
        }
        .task(id: refreshKey) {
            let roster = coordinator.routineEntries
            routineEntries = roster
            routineSummaries = Dictionary(
                uniqueKeysWithValues: roster.map { ($0.id, scheduleSummary($0)) }
            )
        }
        // Manage one routine's photos. Edits persist as they happen, so
        // the only thing dismissal has to do is refresh the cached rows.
        .sheet(item: $photoEditorEntry) { entry in
            ReminderVisualAidEditorView(
                entryId: entry.id,
                title: entry.displayTitle(locale: coordinator.activeLocale),
                aids: entry.visualAids,
                store: coordinator.visualAidStore,
                locale: coordinator.activeLocale,
                // The editor owns its draft; this only persists. The
                // captured `entry` is the one the sheet opened with —
                // its id is all this needs.
                onSave: { aids in
                    coordinator.setRoutineVisualAids(entry.id, aids: aids)
                },
                onClose: {
                    photoEditorEntry = nil
                    entriesVersion += 1
                }
            )
        }
    }

    private func routineManageRow(_ entry: RoutineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.systemImage)
                .font(.system(size: 24))
                .foregroundStyle(DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle(locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(routineSummaries[entry.id] ?? "")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer()
            // Photos live behind this row: the family's configuration
            // surface for a routine (photo-visual-aids task, 2026-09-16).
            Button {
                photoEditorEntry = entry
            } label: {
                Image(systemName: entry.visualAids.isEmpty ? "photo.badge.plus" : "photo.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.accent)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("visualAid.add"))
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    coordinator.setRoutineEntryEnabled(entry.id, enabled: enabled)
                    entriesVersion += 1
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// "7:00 AM, 4:00 PM" for daily entries; weekly entries prefix the
    /// localized weekday names ("Sun, Tue · 9:00 AM").
    ///
    /// Moved with the manage rows from the Reminders leaf — including its
    /// DESIGN-REVIEW (P2) formatter discipline: formatters come from the
    /// locale-keyed cache in `ViewCaches.swift`, and the times format in
    /// the app's ACTIVE language rather than the device locale, matching
    /// how the rest of the app renders time.
    private func scheduleSummary(_ entry: RoutineEntry) -> String {
        let locale = coordinator.activeLocale
        let calendar = Calendar.current
        let timeFormatter = LocaleFormatters.shortTime(locale: locale)
        let times = entry.scheduleTimes.compactMap { components -> String? in
            calendar.date(from: components).map { timeFormatter.string(from: $0) }
        }
        let timesText = times.joined(separator: ", ")
        guard entry.frequency == .weekly, !entry.weekdays.isEmpty else { return timesText }
        let symbols = LocaleFormatters.shortWeekdaySymbols(locale: locale)
        guard !symbols.isEmpty else { return timesText }
        let days = entry.weekdays.sorted().compactMap { weekday -> String? in
            weekday >= 1 && weekday <= symbols.count ? symbols[weekday - 1] : nil
        }
        return days.joined(separator: ", ") + " · " + timesText
    }
}
