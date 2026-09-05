import SwiftUI
import UIKit

/// Shared leaf-screen chrome: huge back button, single-purpose layout
/// (spec §4.3). Every hub leaf uses this.
///
/// Redesign spec §3.2: this is a PLAIN full-screen page — no Talk hero, no
/// hint carousel, no dock. The one exception is the Emergency icon, which
/// persists on every screen because it's a safety invariant, not
/// conversational voice chrome.
struct LeafScreen<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let titleKey: String
    let content: Content

    init(titleKey: String, @ViewBuilder content: () -> Content) {
        self.titleKey = titleKey
        self.content = content()
    }

    var body: some View {
        ZStack {
            DesignTokens.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(DesignTokens.textPrimary)
                            .frame(width: DesignTokens.minTapTargetSize,
                                   height: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.card)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(Text("common.back"))
                    Text(LocalizedStringKey(titleKey))
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                ScrollView {
                    content
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Meds (औषधि) — spec §4.3

/// Today's dose list with a big "लिएँ" button per pending dose. Taking a
/// dose issues the confirmation challenge (FR-D01/FR-D03) and returns to
/// Home, where the yes/no chips appear.
struct MedsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine
    @Environment(\.dismiss) private var dismiss

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "meds.title") {
            if todaysReminders.isEmpty {
                emptyState(key: "meds.empty")
            } else {
                VStack(spacing: 12) {
                    ForEach(todaysReminders) { reminder in
                        doseRow(reminder)
                    }
                }
            }
        }
    }

    private func doseRow(_ reminder: ScheduledReminder) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.medicationName(for: reminder.medicationEntryId))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(reminder.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button {
                takeDose(reminder)
            } label: {
                Text("meds.iTookIt")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Baseline ack or challenge → Home for the yes/no chips. The
    /// confirmation answer is handled by the chips/voice on Home.
    private func takeDose(_ reminder: ScheduledReminder) {
        let entryId = reminder.medicationEntryId
        if coordinator.startVoiceAckConfirmation(for: entryId) != nil {
            // Challenge issued — chips now own the UI on Home.
            dismiss()
        } else {
            coordinator.handleMedicationAcknowledgement(entryId: entryId)
            coordinator.speak(key: "router.confirmationYes")
        }
    }
}

// MARK: - Reminders (सम्झना) — spec §4.3 + v2 pivot Phase 1

/// Today's reminders from BOTH reminder systems — medication doses
/// (`MedicationScheduler`) and routine occurrences (walk, exercise,
/// meals, … from `RoutineScheduler`) — plus a manage list where the
/// family enables/disables the seeded routine categories. Medication
/// management stays on the Meds leaf / Settings editor; this screen
/// never mutates medication data.
struct RemindersView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    /// Bumped after a toggle so the computed lists re-read fresh data —
    /// the coordinator exposes reminders as computed vars, not @Published.
    @State private var entriesVersion = 0

    /// One row per today's reminder, both systems, sorted by time.
    private var todayRows: [TodayRow] {
        _ = entriesVersion
        // One store read for the whole list, not two per row.
        let entriesById = Dictionary(
            uniqueKeysWithValues: coordinator.routineEntries.map { ($0.id, $0) }
        )
        let meds = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .map { TodayRow(id: $0.id, scheduledAt: $0.scheduledAt,
                            title: coordinator.medicationName(for: $0.medicationEntryId),
                            systemImage: RoutineCategory.medication.systemImage,
                            isDimmed: false) }
        let routines = coordinator.todaysRoutineOccurrences.map { occurrence in
            let entry = entriesById[occurrence.entryId]
            return TodayRow(id: occurrence.id, scheduledAt: occurrence.scheduledAt,
                            title: entry?.displayTitle(locale: coordinator.activeLocale)
                                ?? L10n.str("routine.category.custom", locale: coordinator.activeLocale),
                            systemImage: entry?.category.systemImage
                                ?? RoutineCategory.custom.systemImage,
                            isDimmed: occurrence.state != .pending)
        }
        return (meds + routines).sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "reminders.title") {
            VStack(spacing: 12) {
                if todayRows.isEmpty {
                    emptyState(key: "reminders.empty")
                } else {
                    sectionHeader(key: "reminders.todaySection")
                    ForEach(todayRows) { row in
                        todayRowView(row)
                    }
                }

                if !coordinator.routineEntries.isEmpty {
                    sectionHeader(key: "reminders.routinesSection")
                    ForEach(coordinator.routineEntries) { entry in
                        routineManageRow(entry)
                    }
                }
            }
        }
    }

    private struct TodayRow: Identifiable {
        let id: UUID
        let scheduledAt: Date
        let title: String
        let systemImage: String
        /// Past/expired occurrences stay visible but de-emphasised — the
        /// elder still sees "walk was at 5:30" as context for the day.
        let isDimmed: Bool
    }

    private func sectionHeader(key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func todayRowView(_ row: TodayRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 24))
                .foregroundColor(row.isDimmed ? DesignTokens.textSecondary : DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(row.isDimmed ? DesignTokens.textSecondary : DesignTokens.textPrimary)
                Text(row.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func routineManageRow(_ entry: RoutineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.systemImage)
                .font(.system(size: 24))
                .foregroundColor(DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle(locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(scheduleSummary(entry))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
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
    private func scheduleSummary(_ entry: RoutineEntry) -> String {
        let calendar = Calendar.current
        let times = entry.scheduleTimes.compactMap { components -> String? in
            calendar.date(from: components)?.formatted(date: .omitted, time: .shortened)
        }
        let timesText = times.joined(separator: ", ")
        guard entry.frequency == .weekly, !entry.weekdays.isEmpty else { return timesText }
        let formatter = DateFormatter()
        formatter.locale = coordinator.activeLocale
        guard let symbols = formatter.shortWeekdaySymbols else { return timesText }
        let days = entry.weekdays.sorted().compactMap { weekday -> String? in
            weekday >= 1 && weekday <= symbols.count ? symbols[weekday - 1] : nil
        }
        return days.joined(separator: ", ") + " · " + timesText
    }
}

// MARK: - Call (फोन) — redesign spec §3.2

/// Replaces the old fail-closed placeholder. `CommandRouter`'s `.call`
/// handling (voice-triggered "call X") stays blocked, unchanged, pending
/// voice-biometric auth — that's a `CommandRouter`/pipeline concern this
/// redesign does not touch. TAPPING a contact here is a different trust
/// model: it's the user's own hand on their own unlocked phone, the same
/// as any contacts app, so it places a real call directly.
struct CallView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "call.title") {
            if coordinator.familyContacts.isEmpty {
                Text("call.contactsEmpty")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            } else {
                VStack(spacing: 12) {
                    ForEach(coordinator.familyContacts) { contact in
                        ContactTile(contact: contact)
                    }
                }
            }
        }
    }
}

/// Face/initial avatar + name, with per-contact VIDEO and AUDIO call
/// buttons — no list picker in between (redesign spec §3.1 "one face,
/// one tap"; contact-call-buttons task 2026-09-06). Each button opens
/// the contact's preferred app for that call kind (`FamilyContact`
/// carries the per-contact defaults; the personalization editor is a
/// deferred follow-up) through `AppCoordinator.performContactCall`,
/// which also announces the opened surface aloud.
struct ContactTile: View {
    let contact: FamilyContact
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 14) {
            FaceAvatar(name: contact.name, diameter: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(contact.relationship)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button(action: videoCall) {
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.BadgeTint.call.tint)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.fmt("call.videoCallButtonLabel", locale: locale, contact.name)))
            Button(action: audioCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.fmt("call.callButtonLabel", locale: locale, contact.name)))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    private func videoCall() {
        coordinator.performContactCall(contact, kind: .video)
    }

    private func audioCall() {
        coordinator.performContactCall(contact, kind: .audio)
    }
}

// MARK: - Calendar (पात्रो) — 2026-09-06

/// Today's date + the day's actual schedule (from the coordinator's
/// real reminder/medication data), plus today's Nepali calendar date
/// when the NepaliCalendarPlugin applies and can answer. No mock data
/// anywhere: sections that have no real content are simply omitted.
struct CalendarView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "calendar.title") {
            VStack(spacing: 12) {
                bsDateCard
                if !(coordinator.festivalCalendar.todayOverlay()?.festivals.isEmpty ?? true) {
                    festivalTodayCard
                }
                upcomingCard
                scheduleSection
            }
        }
    }

    /// The BS-first date card (2026-09-06 product direction: Nepali
    /// calendar shows Bikram Sambat dates, not Gregorian, in Nepali
    /// numerals — with the Hindu tithi overlay on every day).
    private var bsDateCard: some View {
        let overlay = coordinator.festivalCalendar.todayOverlay()
        return VStack(spacing: 8) {
            if let overlay {
                Text(overlay.weekdayNepali)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                Text(BikramSambat.nepaliString(overlay.bsDate))
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                // Tithi overlay — every day, per product requirement.
                Text(overlay.tithi.displayNepali)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                Text(Date().formatted(.dateTime.day().month(.wide).year().locale(coordinator.activeLocale)))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            } else {
                Text("calendar.bsUnavailable")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Festival(s) falling today, with their tithi labels.
    private var festivalTodayCard: some View {
        let festivals = coordinator.festivalCalendar.todayOverlay()?.festivals ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("calendar.festivalToday")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(festivals, id: \.id) { festival in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundColor(DesignTokens.accent)
                    Text(festival.nameNepali)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    if let tithi = festival.tithiNepali {
                        Text(tithi)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Upcoming festivals (next 5) with BS dates and days-away.
    private var upcomingCard: some View {
        let upcoming = coordinator.festivalCalendar.upcoming(limit: 5)
        return VStack(alignment: .leading, spacing: 10) {
            Text("calendar.upcomingFestivals")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(upcoming, id: \.festival.id) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.festival.nameNepali)
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textPrimary)
                        Text(BikramSambat.nepaliString(item.bsDate))
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                    Spacer()
                    Text(daysAwayText(item.daysAway))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func daysAwayText(_ days: Int) -> String {
        if days == 0 { return L10n.str("calendar.today", locale: coordinator.activeLocale) }
        if days == 1 { return L10n.str("calendar.tomorrow", locale: coordinator.activeLocale) }
        return L10n.fmt("calendar.inDays", locale: coordinator.activeLocale,
                        BikramSambat.devanagariDigits(days))
    }

    @ViewBuilder
    private var scheduleSection: some View {
        if !todaysReminders.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("calendar.todaySchedule")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                ForEach(todaysReminders) { reminder in
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "clock.fill", tint: .reminders)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.medicationName(for: reminder.medicationEntryId))
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                                .foregroundColor(DesignTokens.textPrimary)
                            Text(reminder.scheduledAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: DesignTokens.minCaptionPointSize))
                                .foregroundColor(DesignTokens.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                }
            }
        }
    }
}

// MARK: - Shared

private func emptyState(key: String) -> some View {
    Text(LocalizedStringKey(key))
        .font(.system(size: DesignTokens.minBodyPointSize))
        .foregroundColor(DesignTokens.textSecondary)
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
}
