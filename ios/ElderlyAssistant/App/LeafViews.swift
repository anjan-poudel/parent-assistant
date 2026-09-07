import SwiftUI
import UIKit
import AVFoundation
import Speech

/// Shared leaf-screen chrome: huge back button, single-purpose layout
/// (spec §4.3). Every hub leaf uses this.
///
/// Redesign spec §3.2: this is a PLAIN full-screen page — no Talk hero, no
/// hint carousel, no dock. The one exception is the Emergency icon, which
/// persists on every screen because it's a safety invariant, not
/// conversational voice chrome.
struct LeafScreen<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    /// Background theme (skinnable home, 2026-09-07): this is the shared
    /// chrome nearly every full-screen leaf draws its background through,
    /// so the theme reads HERE once instead of in every leaf.
    @EnvironmentObject var coordinator: AppCoordinator
    let titleKey: String
    let content: Content

    init(titleKey: String, @ViewBuilder content: () -> Content) {
        self.titleKey = titleKey
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color(theme: coordinator.appTheme).ignoresSafeArea()
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

// MARK: - Medical (मेडिकल) — spec §4.3 + doctor's appointments
// (medical task, 2026-09-07)

/// The Medical leaf: today's dose list (renamed-tab content — the old
/// "Meds" leaf) PLUS the "Doctor's appointments" section.
///
/// Taking a dose issues the confirmation challenge (FR-D01/FR-D03) and
/// returns to Home, where the yes/no chips appear — unchanged behaviour.
///
/// The appointments section (2026-09-07) shows the encrypted
/// `AppointmentStore` list newest-first with per-row removal, a compact
/// add form (doctor/clinic, optional clinic/place, date, time, optional
/// note), a one-shot honest SMS caption, the calendar auto-add toggle
/// (writer gated inside the store), and the "Paste appointment message"
/// entry that drafts from `MedicalAppointmentParser` and asks for
/// confirmation before saving.
struct MedicalView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine
    @Environment(\.dismiss) private var dismiss

    // MARK: - Add-form draft state

    @State private var doctor = ""
    @State private var clinic = ""
    @State private var note = ""
    /// Defaults to an hour from now — the parser's no-signal fallback
    /// rule (see `MedicalAppointmentParser.resolveDate`), so typed and
    /// pasted appointments agree on the "no time chosen" reading.
    @State private var appointmentDate =
        Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    /// Parser draft awaiting the confirm alert (paste flow, 2026-09-07).
    @State private var pasteDraft: MedicalAppointmentParser.ParsedAppointment?
    @State private var showPasteConfirm = false
    /// Honest no-parse caption under the paste button; cleared on the
    /// next paste attempt.
    @State private var showPasteFailed = false

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private var canAddAppointment: Bool {
        !doctor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        LeafScreen(titleKey: "meds.title") {
            VStack(spacing: 12) {
                if todaysReminders.isEmpty {
                    emptyState(key: "meds.empty")
                } else {
                    VStack(spacing: 12) {
                        ForEach(todaysReminders) { reminder in
                            doseRow(reminder)
                        }
                    }
                }

                appointmentSection
            }
        }
        .alert(pasteAlertTitle, isPresented: $showPasteConfirm) {
            Button(L10n.str("medical.appointments.add", locale: coordinator.activeLocale)) {
                saveParsedDraft()
            }
            Button(L10n.str("common.cancel", locale: coordinator.activeLocale),
                   role: .cancel) {}
        } message: {
            Text(pasteAlertMessage)
        }
    }

    // MARK: - Doctor's appointments section (medical task, 2026-09-07)

    private var appointmentSection: some View {
        VStack(spacing: 12) {
            sectionHeader(key: "medical.appointments.title")

            if coordinator.appointments.isEmpty {
                emptyState(key: "medical.appointments.empty")
            } else {
                VStack(spacing: 12) {
                    ForEach(coordinator.appointments) { appointment in
                        appointmentRow(appointment)
                    }
                }
            }

            // Honest one-shot caption (2026-09-07): the iPhone does not
            // let apps read text messages, so appointment SMSs can never
            // be ingested automatically — shown until dismissed once,
            // then never again (coordinator-persisted).
            if !coordinator.appointmentSmsNoteDismissed {
                smsNoteCard
            }

            // Calendar auto-add toggle (medical task, 2026-09-07):
            // default ON; the store's calendarWritesEnabled gate mirrors
            // this and decides whether the MedicalAppointmentCalendarWriting
            // seam is invoked at all (the calendar-2way task ships the
            // EventKit writer).
            calendarToggleCard

            pasteRow

            addFormCard
        }
    }

    private func appointmentRow(_ appointment: MedicalAppointment) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appointment.doctorOrPlace)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                if let place = appointment.place {
                    Text(place)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                Text(appointment.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                if let note = appointment.note {
                    Text(note)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                coordinator.removeAppointment(id: appointment.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundColor(DesignTokens.stateError)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("medical.appointments.remove"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// The smsNote card: what the iPhone can and cannot do with
    /// appointment texts, plus the manual/voice alternative. Dismissible
    /// once (see the section comment).
    private var smsNoteCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(DesignTokens.textSecondary)
                .padding(.top, 2)
            Text("medical.smsNote")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                coordinator.dismissAppointmentSmsNote()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.close"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Calendar auto-add toggle — mirrors `appointmentsToCalendar` on
    /// the coordinator, which persists it and re-syncs the store gate.
    private var calendarToggleCard: some View {
        Toggle(isOn: Binding(
            get: { coordinator.appointmentsToCalendar },
            set: { coordinator.appointmentsToCalendar = $0 }
        )) {
            Label("medical.calendarToggle", systemImage: "calendar.badge.plus")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
        }
        .tint(DesignTokens.accent)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// "Paste appointment message" (2026-09-07): drafts from whatever
    /// confirmation SMS is on the pasteboard — see `handlePasteTap` for
    /// the privacy rule — then confirms before saving. Failure shows the
    /// honest `medical.pasteFailed` caption instead of an alert.
    private var pasteRow: some View {
        VStack(spacing: 8) {
            Button {
                handlePasteTap()
            } label: {
                Label("medical.pasteAppointment", systemImage: "doc.text.fill")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.chipHeight)
            }
            .buttonStyle(.plain)

            if showPasteFailed {
                Text("medical.pasteFailed")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.stateError)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addFormCard: some View {
        VStack(spacing: 10) {
            TextField(LocalizedStringKey("medical.appointments.doctor"), text: $doctor)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            TextField(LocalizedStringKey("medical.appointments.place"), text: $clinic)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

            pickerRow(key: "medical.appointments.date",
                      components: .date,
                      selection: $appointmentDate)
            pickerRow(key: "medical.appointments.time",
                      components: .hourAndMinute,
                      selection: $appointmentDate)

            TextField(LocalizedStringKey("medical.appointments.note"), text: $note)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(height: 56)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

            Button {
                addFromForm()
            } label: {
                Text("medical.appointments.add")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.chipHeight)
                    .background(canAddAppointment ? DesignTokens.accent : DesignTokens.textSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(!canAddAppointment)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Date/time picker row in the same shape as the medication
    /// schedule editor's time row.
    private func pickerRow(key: String, components: DatePickerComponents,
                           selection: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(key))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer()
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
                .environment(\.locale, coordinator.appLanguage.locale)
        }
        .padding(14)
        .frame(height: 56)
        .background(DesignTokens.background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    private func addFromForm() {
        let trimmedDoctor = doctor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDoctor.isEmpty else { return }
        let trimmedClinic = clinic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = coordinator.addAppointment(
            doctorOrPlace: trimmedDoctor,
            place: trimmedClinic.isEmpty ? nil : trimmedClinic,
            date: appointmentDate,
            note: trimmedNote.isEmpty ? nil : trimmedNote)
        // A failed encrypted-store write keeps the draft on screen —
        // Add again to retry; nothing was claimed that didn't happen
        // (same rule as the places editor).
        if added {
            doctor = ""
            clinic = ""
            note = ""
            appointmentDate = Calendar.current.date(byAdding: .hour, value: 1,
                                                    to: Date()) ?? Date()
        }
    }

    // MARK: - Paste drafting (medical task, 2026-09-07)

    /// Reads the pasteboard and drafts an appointment from it.
    ///
    /// PRIVACY: `UIPasteboard.general.string` is read ONLY here, on the
    /// user's explicit tap of the paste button — never on appear, focus,
    /// or scene changes — so the app never snoops whatever the senior
    /// last copied (a password, a code) without being asked.
    private func handlePasteTap() {
        showPasteFailed = false
        guard let text = UIPasteboard.general.string, !text.isEmpty,
              let parsed = MedicalAppointmentParser.parse(text) else {
            // Honest caption — the message held no appointment the
            // parser could stand behind (see the parser's nil rules).
            showPasteFailed = true
            return
        }
        pasteDraft = parsed
        showPasteConfirm = true
    }

    private func saveParsedDraft() {
        guard let parsed = pasteDraft else { return }
        pasteDraft = nil
        let saved = coordinator.addAppointment(doctorOrPlace: parsed.doctorOrPlace,
                                               place: parsed.place,
                                               date: parsed.date,
                                               note: nil)
        if !saved {
            // e.g. the store's 50-entry cap — same honest caption.
            showPasteFailed = true
        }
    }

    private var pasteAlertTitle: String {
        L10n.str("medical.pasteConfirm", locale: coordinator.activeLocale)
    }

    /// Doctor, place and date-time on separate lines — the summary the
    /// senior confirms before anything is saved.
    private var pasteAlertMessage: String {
        guard let draft = pasteDraft else { return "" }
        let locale = coordinator.activeLocale
        var lines = [draft.doctorOrPlace]
        if let place = draft.place { lines.append(place) }
        lines.append(draft.date.formatted(Date.FormatStyle(date: .abbreviated,
                                                           time: .shortened,
                                                           locale: locale)))
        return lines.joined(separator: "\n")
    }

    private func sectionHeader(key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: - Today's doses (spec §4.3)

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

/// Today's reminders from ALL THREE reminder systems — medication doses
/// (`MedicationScheduler`), routine occurrences (walk, exercise, meals, …
/// from `RoutineScheduler`), and items imported from the native
/// Calendar/Reminders apps (`ExternalCalendarService`, read-only bridge)
/// — plus a manage list where the family enables/disables the seeded
/// routine categories. Native Calendar events from the days ahead sit
/// under an "Upcoming events" section (upcoming-events task, 2026-09-07).
/// Medication management stays on the Medical leaf
/// (the renamed Meds leaf, medical task 2026-09-07) / Settings editor;
/// this screen never mutates medication data.
struct RemindersView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    /// Bumped after a toggle so the computed lists re-read fresh data —
    /// the coordinator exposes reminders as computed vars, not @Published.
    @State private var entriesVersion = 0

    /// One row per today's reminder, all three systems, sorted by time.
    private var todayRows: [TodayRow] {
        _ = entriesVersion
        // One store read for the whole list, not two per row.
        let entriesById = Dictionary(
            uniqueKeysWithValues: coordinator.routineEntries.map { ($0.id, $0) }
        )
        let meds = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .map { TodayRow(id: $0.id.uuidString, scheduledAt: $0.scheduledAt,
                            title: coordinator.medicationName(for: $0.medicationEntryId),
                            systemImage: RoutineCategory.medication.systemImage,
                            isDimmed: false, external: nil) }
        let routines = coordinator.todaysRoutineOccurrences.map { occurrence in
            let entry = entriesById[occurrence.entryId]
            return TodayRow(id: occurrence.id.uuidString, scheduledAt: occurrence.scheduledAt,
                            title: entry?.displayTitle(locale: coordinator.activeLocale)
                                ?? L10n.str("routine.category.custom", locale: coordinator.activeLocale),
                            systemImage: entry?.category.systemImage
                                ?? RoutineCategory.custom.systemImage,
                            isDimmed: occurrence.state != .pending, external: nil)
        }
        // Imported native items (2026-09-07): timed ones are always still
        // ahead (already-started events are dropped at scan time), so
        // never dimmed — but their badge reads secondary, "from outside
        // the app". Tapping opens the native Calendar/Reminders app.
        let externals = coordinator.externalRemindersToday.map { item in
            TodayRow(id: item.id, scheduledAt: item.startDate, title: item.title,
                     systemImage: item.source.systemImage, isDimmed: false,
                     external: item)
        }
        return (meds + routines + externals).sorted { $0.scheduledAt < $1.scheduledAt }
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

                // Native events from the days ahead (upcoming-events
                // task, 2026-09-07) — see `upcomingEventsSection`.
                upcomingEventsSection

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
        let id: String
        let scheduledAt: Date
        let title: String
        let systemImage: String
        /// Past/expired occurrences stay visible but de-emphasised — the
        /// elder still sees "walk was at 5:30" as context for the day.
        let isDimmed: Bool
        /// nil for medication/routine rows. External rows (2026-09-07)
        /// carry the imported native item itself so a tap can open it in
        /// its own app — the read-only bridge's only gesture.
        let external: ExternalReminder?
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
                .foregroundColor(row.isDimmed || row.external != nil
                                 ? DesignTokens.textSecondary : DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(row.isDimmed ? DesignTokens.textSecondary : DesignTokens.textPrimary)
                Text(rowCaption(row))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                // Which native calendar/reminder list the item came from.
                if let external = row.external {
                    Text(external.calendarName)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .contentShape(Rectangle())
        // External rows open their item in the native app (read-only
        // bridge); medication/routine rows stay non-interactive.
        .onTapGesture {
            if let external = row.external {
                coordinator.openExternalReminder(external)
            }
        }
        .accessibilityAddTraits(row.external != nil ? .isButton : [])
    }

    /// All-day external items caption "All day"; everything else the
    /// wall-clock time.
    private func rowCaption(_ row: TodayRow) -> String {
        if let external = row.external, external.isAllDay {
            return L10n.str("externalReminders.allDay", locale: coordinator.activeLocale)
        }
        return row.scheduledAt.formatted(date: .omitted, time: .shortened)
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

    // MARK: - Upcoming native Calendar events (upcoming-events task, 2026-09-07)

    /// The leaf caps the upcoming list at five rows; the "Show more"
    /// capsule into the Calendar leaf appears only when more events
    /// exist than fit.
    private static let upcomingEventsLimit = 5

    /// The next native Calendar-app EVENTS (not Reminders-app items —
    /// those merge into the today rows like everything else): strictly
    /// beyond today, soonest first. Today's still-ahead events live in
    /// the merged list above, so the two sections never show the same
    /// row twice. Backed by `ExternalCalendarService`'s published scan
    /// results (launch/foreground/hourly/store-change), which the
    /// coordinator forwards — the section refreshes when a scan lands.
    private var upcomingEvents: [ExternalReminder] {
        let calendar = Calendar.current
        let tomorrowStart = calendar.date(byAdding: .day, value: 1,
                                          to: calendar.startOfDay(for: Date()))
            ?? Date()
        return coordinator.externalCalendar.reminders
            .filter { $0.source == .event && $0.startDate >= tomorrowStart }
            .sorted { $0.startDate < $1.startDate }
    }

    /// "Upcoming events" — the native events ahead, capped at
    /// `upcomingEventsLimit` rows. Present only while the import is on
    /// (off hides the section — the today rows follow the same rule, so
    /// the screen stays coherent without it); when it IS on, a denied
    /// or failing import says so instead of pretending nothing is
    /// ahead.
    @ViewBuilder
    private var upcomingEventsSection: some View {
        if coordinator.externalCalendar.isEnabled {
            sectionHeader(key: "reminders.upcoming.title")
            switch coordinator.externalCalendar.status {
            case .denied:
                emptyState(key: "externalReminders.statusDenied")
            case .error:
                emptyState(key: "externalReminders.statusError")
            default:
                upcomingEventsContent
            }
        }
    }

    @ViewBuilder
    private var upcomingEventsContent: some View {
        let events = upcomingEvents
        if events.isEmpty {
            emptyState(key: "reminders.upcoming.empty")
        } else {
            ForEach(events.prefix(Self.upcomingEventsLimit)) { event in
                upcomingEventRow(event)
            }
            if events.count > Self.upcomingEventsLimit {
                showMoreUpcomingLink
            }
        }
    }

    /// One upcoming native event — title, when, and the calendar it
    /// lives in. Read-only: no tap action — opening an item in its
    /// native app is the today rows' gesture, and the Calendar leaf is
    /// one tap away via the "Show more" capsule.
    private func upcomingEventRow(_ event: ExternalReminder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: event.source.systemImage)
                .font(.system(size: 24))
                .foregroundColor(DesignTokens.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(upcomingEventTimeText(event))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                Text(event.calendarName)
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

    /// When the event happens: the relative day via `HistoryTimeFormat`
    /// (Tomorrow / a localized short date — today's events never reach
    /// this section), plus the wall-clock time for timed events.
    /// All-day events ARE their day, so the day label alone is their
    /// caption.
    private func upcomingEventTimeText(_ event: ExternalReminder) -> String {
        let locale = coordinator.activeLocale
        let day = HistoryTimeFormat.displayString(for: event.startDate,
                                                  now: Date(),
                                                  calendar: Calendar.current,
                                                  locale: locale)
        if event.isAllDay { return day }
        let clock = event.startDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        return "\(day) · \(clock)"
    }

    /// Capsule into the Calendar leaf when more events are ahead than
    /// the cap shows (the History leaf's show-more pattern).
    private var showMoreUpcomingLink: some View {
        NavigationLink(value: LeafDestination.calendar) {
            Text("history.showMore")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.accent)
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(DesignTokens.accent.opacity(0.35),
                                     lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Call (फोन) — redesign spec §3.2 + system-contacts search (2026-09-06)

/// Replaces the old fail-closed placeholder. `CommandRouter`'s `.call`
/// handling (voice-triggered "call X") stays blocked, unchanged, pending
/// voice-biometric auth — that's a `CommandRouter`/pipeline concern this
/// redesign does not touch. TAPPING a contact here is a different trust
/// model: it's the user's own hand on their own unlocked phone, the same
/// as any contacts app, so it places a real call directly.
///
/// System-contacts search (2026-09-06, task: "sweep all sweepable
/// contacts when searching, sort by most recently used"): the leaf now
/// also searches the SYSTEM address book — which on iOS is the sweep.
/// The system Contacts app already aggregates the user's own entries AND
/// people synced in by third-party apps (WhatsApp, Messenger, …) as
/// plain contacts, so one `CNContactStore` pass reaches every dialable
/// person without any per-app SDK. Matches rank with numbers this app
/// recently called first (`CallRecencyStore`), then alphabetically.
/// Contacts permission is asked at the point of use behind a
/// plain-language card — never silently on appear — and the family
/// tiles below stay fully usable with or without it.
///
/// Curated-first layout (2026-09-07): the leaf now LEADS with the
/// curated Family & friends list — the people the app is configured to
/// call, each tile wearing the contact's own photo thumbnail when one
/// is on file — and the whole-phone-book search collapses into the
/// magnifyingglass on the curated header row. Searching opens the same
/// search surface as before (field, voice search, access cards, ranked
/// rows) as an explicit mode; clearing the field to empty, or tapping
/// the mode's back button, returns to the curated list. The photos come
/// from the coordinator's `contactPhoto(for:)` contract
/// (contact-photos task, 2026-09-07): a photo resolves when the
/// contact has a `photoFilename`, otherwise the initials avatar stays.
struct CallView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private let directory = AddressBookDirectory()

    @State private var searchText = ""
    /// nil while the authorization state is still being read.
    @State private var access: ContactsAccess?
    /// nil = not loaded yet (or load in flight).
    @State private var entries: [AddressBookEntry]?
    @State private var loadFailed = false
    /// Normalized number → last call date; refreshed on appear and after
    /// each dial so the "recently used" ranking stays current.
    @State private var recency: [String: Date] = [:]

    // Voice search (voice-contact-search, 2026-09-07).
    /// One-shot mic-capture phase for the search field's mic button.
    private enum MicPhase { case idle, listening, failed }
    @State private var micPhase: MicPhase = .idle
    /// True once speech/mic permission is denied — the button is honest
    /// dead for this visit (the denial might be reversible in Settings;
    /// next visit re-checks).
    @State private var micHidden = false
    /// The voice-command search this leaf is currently answering
    /// (nil when none): the request id plus the query to announce.
    @State private var voiceRequest: AppCoordinator.ContactSearchRequest?
    /// Guards the spoken announcement to ONCE per request: set when the
    /// result was announced (or the ask became moot — user edited away).
    @State private var announcedVoiceSearchID: UUID?

    // Curated-first mode (2026-09-07): the address-book search lives
    // behind the curated header row's magnifyingglass and is closed by
    // default — the leaf's primary face is the curated Family & friends
    // list. `searchMode` is the open state: set by the header icon tap,
    // set again by a pending voice-command search that carries a query
    // (consumePendingVoiceRequestIfPresent), and cleared by the search
    // mode's back button or by clearing the field to empty — both
    // return to the curated view.
    @State private var searchMode = false

    // Per-row channel handling (channel-chooser task, 2026-09-07).
    /// Bumped after a chooser pick or a saved Messenger handle so the
    /// per-outcome row-state dictionary re-resolves (the coordinator
    /// stores are plain reads, not @Published — same bump pattern as
    /// RemindersView's `entriesVersion`).
    @State private var channelStateVersion = 0
    /// The result row the Messenger-handle sheet is editing (nil =
    /// closed). The sheet is item-driven so a swipe-dismiss also clears
    /// it.
    @State private var handleCaptureTarget: UnifiedContactSearch.Result?
    /// The sheet's draft username, bound to its TextField.
    @State private var handleText = ""

    var body: some View {
        LeafScreen(titleKey: "call.title") {
            VStack(spacing: 12) {
                launchRow
                if searchMode {
                    // Search is an overlay on the leaf (curated-first
                    // layout, 2026-09-07): field + permission/loading
                    // cards up top, ranked rows below once the query is
                    // non-empty. Exit is the row's back button or
                    // clearing the field — both flip `searchMode` and
                    // the curated content below returns.
                    searchArea
                    if isSearching {
                        resultsArea
                    }
                } else {
                    curatedHeaderRow
                    familyArea
                    recentActivitySection
                }
            }
        }
        .onAppear {
            refreshDirectory()
            // A voice command may have pushed this leaf — consume the
            // request and prefill; a fresh publish while the leaf was
            // already open is picked up by the onChange below.
            consumePendingVoiceRequestIfPresent()
        }
        .onChange(of: coordinator.pendingContactSearchRequest?.id) { _ in
            consumePendingVoiceRequestIfPresent()
        }
        .onChange(of: entries) { _ in
            announceVoiceResultIfReady()
        }
        .onChange(of: loadFailed) { _ in
            announceVoiceResultIfReady()
        }
        .onChange(of: searchText) { _ in
            // A change the USER made (typing, clearing) retires the voice
            // ask: the elder is refining by hand, so the results were
            // theirs to see — never speak over them late. Our own prefill
            // sets searchText == voiceRequest.query, which is not a
            // retirement (trimmedQuery matches, so nothing happens here).
            if let voice = voiceRequest, trimmedQuery != voice.query {
                announcedVoiceSearchID = voice.id
            }
            // Clearing the field ends search mode (curated-first layout,
            // 2026-09-07): an empty query has no results to render, so
            // the leaf folds back to the curated list — the same exit the
            // search mode's back button performs. Guarded by `searchMode`
            // so a voice prefill (which never clears) cannot trip it.
            if searchMode && trimmedQuery.isEmpty {
                searchMode = false
            }
        }
        .onChange(of: scenePhase) { phase in
            // Returning from Settings after the access card's
            // "Open Settings" is the denial → grant path; re-check then.
            if phase == .active {
                refreshDirectory()
                // Permission state may have changed in Settings too.
                updateMicVisibility()
            }
        }
        .onDisappear {
            // Never leave the voice suspended and the mic open: a leaf
            // the user walked away from must not keep listening. The
            // capture completion (fires on cancel) restarts the pipeline.
            if micPhase == .listening {
                coordinator.cancelSearchPhraseCapture()
            }
            micPhase = .idle
        }
        // Messenger-handle capture (channel-chooser task, 2026-09-07):
        // item-driven sheet for the row the add-handle button opened.
        // `handleText` is reset when a sheet opens (see
        // `presentHandleCapture`) — never when it dismisses, so a draft
        // survives an accidental swipe and comes back on re-open.
        .sheet(item: $handleCaptureTarget) { target in
            handleCaptureSheet(for: target)
        }
    }

    /// WhatsApp/Messenger expose no API to render their contact lists in
    /// this app, so the Phone leaf takes the elder INTO each app's own
    /// list in one tap (contact-leaf-launch task, 2026-09-07):
    /// `whatsapp://` opens WhatsApp's chat list, `fb-messenger://` opens
    /// Messenger's people list. Reachable with or without contacts
    /// permission — opening another app needs none. The coordinator
    /// openers probe first and announce an absent app aloud (never a
    /// silent dead tap), mirroring the quick-access honesty rules.
    private var launchRow: some View {
        HStack(spacing: 10) {
            contactListButton(titleKey: "call.openWhatsAppContacts",
                              systemImage: "bubble.left.and.bubble.right.fill") {
                coordinator.openWhatsAppContacts()
            }
            contactListButton(titleKey: "call.openMessengerContacts",
                              systemImage: "paperplane.fill") {
                coordinator.openMessengerContacts()
            }
        }
    }

    /// One half-width capsule of `launchRow` (horizontal 16 padding,
    /// card background, Capsule clip, caption-size semibold label over a
    /// ≥44pt target), stretched with `.frame(maxWidth: .infinity)` so
    /// the two share the row. The old top history capsule left the leaf
    /// (Phone review, 2026-09-07) — recent activity now sits at the
    /// bottom; the launch capsules keep this look.
    private func contactListButton(titleKey: String, systemImage: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// WhatsApp present on this phone — the sync hint exists to guide
    /// INTO WhatsApp, so with the app absent the whole card hides
    /// (there is nothing to guide to). Probed live on the main thread
    /// (body evaluation); the `whatsapp` scheme sits in
    /// LSApplicationQueriesSchemes so the probe is honest.
    private var whatsAppInstalled: Bool {
        guard let url = URL(string: "whatsapp://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Big search pill (≥44pt, body-size text, warm card). Search runs as
    /// the user types — no submit step to fumble.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("call.search.placeholder", text: $searchText)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if micButtonVisible {
                micButton
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(Capsule())
    }

    /// In-pill voice-search button (voice-contact-search, 2026-09-07):
    /// one shot captures a name into the search field — refinement when
    /// the elder is already here. ≥44pt tap target (DesignTokens floor).
    /// While listening it becomes the stop control; the caption below
    /// the pill says what the mic is doing.
    private var micButton: some View {
        let listening = micPhase == .listening
        return Button(action: micTapped) {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(listening ? .white : DesignTokens.accent)
                .frame(width: 30, height: 30)
                .background(listening ? DesignTokens.accent : DesignTokens.background)
                .clipShape(Circle())
        }
        .frame(minWidth: DesignTokens.minTapTargetSize,
               minHeight: DesignTokens.minTapTargetSize)
        .accessibilityLabel(Text(LocalizedStringKey(
            listening ? "call.search.micStopLabel" : "call.search.micLabel")))
    }

    /// What the mic is doing right now — a caption under the pill while
    /// listening ("say the name") or after a failed attempt ("the mic
    /// couldn't hear — try again"). Silent otherwise.
    @ViewBuilder
    private var micCaption: some View {
        switch micPhase {
        case .listening:
            Text(L10n.str("call.search.micListening", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .failed:
            Text(L10n.str("call.search.micFailed", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .idle:
            EmptyView()
        }
    }

    private var loadingCard: some View {
        AddressBookLoadingCard()
    }

    private var loadFailedCard: some View {
        AddressBookLoadFailedCard(retry: loadEntries)
    }

    // MARK: Curated header + search-mode entry/exit (2026-09-07)

    /// The curated list's header row (curated-first layout, 2026-09-07):
    /// the "Family and friends" section title on the left — the value
    /// travels on the shared `settings.family.title` key — and the ≥44pt
    /// magnifyingglass that opens the address-book search on the right.
    /// This row is the leaf's only door into search; it is shown exactly
    /// when search mode is closed.
    private var curatedHeaderRow: some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey("settings.family.title"))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer(minLength: 8)
            searchOpenButton
        }
    }

    /// The header row's ≥44pt search button (curated-first layout,
    /// 2026-09-07): a magnifyingglass on the leaf-chrome circle — the
    /// same card-circle look the top bar's back button wears. The tap
    /// opens search mode; VoiceOver reads what the tap does, not the
    /// empty state of the field it reveals.
    private var searchOpenButton: some View {
        Button(action: openSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
                .frame(width: DesignTokens.minTapTargetSize,
                       height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("call.search.openLabel"))
    }

    /// The leaf's search-mode back control (curated-first layout,
    /// 2026-09-07): a ≥44pt chevron circle above the field/access cards
    /// that folds search mode back to the curated list — one tap, even
    /// when no query exists to clear (e.g. the blocked-permission card,
    /// where clearing could never fire). Mirrors the leaf chrome's back
    /// circle so the gesture reads as "one level back" to the list.
    private var searchExitButton: some View {
        Button(action: exitSearch) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .frame(width: DesignTokens.minTapTargetSize,
                       height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("common.back"))
    }

    /// Opens search mode — the curated header's magnifyingglass.
    /// Deliberately does NOT autofocus the field: the elder's two entry
    /// options (type or speak) sit side by side in the pill, and a
    /// keyboard popping up uninvited would crowd the mic-first path
    /// (voice-contact-search) before either is chosen.
    private func openSearch() {
        searchMode = true
    }

    /// Folds search mode back to the curated list — the search-mode back
    /// button. Never leave a listening mic behind (same rule as
    /// `onDisappear`), drop the field text and any pending voice ask, and
    /// close the mode; the curated header + list return.
    private func exitSearch() {
        if micPhase == .listening {
            coordinator.cancelSearchPhraseCapture()
        }
        micPhase = .idle
        voiceRequest = nil
        searchText = ""
        searchMode = false
    }

    // MARK: Permission / loading states

    /// The OPEN search surface — rendered only in search mode
    /// (curated-first layout, 2026-09-07). Same content and order as the
    /// old always-visible search area — field with mic, then the
    /// permission/loading cards — now led by the ≥44pt back-to-list
    /// circle. Because the surface only appears when the elder asks for
    /// search, the access ask fires at that point of use (the header tap
    /// or a voice search), never on leaf appear.
    @ViewBuilder
    private var searchArea: some View {
        HStack(spacing: 10) {
            searchExitButton
            if access == .allowed {
                searchField
            }
        }
        if access == .allowed {
            micCaption
            if entries == nil {
                if loadFailed {
                    loadFailedCard
                } else {
                    loadingCard
                }
            }
        } else if access == .denied {
            AddressBookAccessCard(mode: .blocked)
        } else if access == .notDetermined {
            // The one point-of-use ask — plain-language card first, the
            // system prompt only after the user taps Allow.
            AddressBookAccessCard(mode: .ask, onAllow: grantAccess)
        }
        // access == nil: authorization still being read; render nothing
        // so the ask card can never flash before onAppear resolves it.
    }

    private func refreshDirectory() {
        let status = AddressBookDirectory.access()
        access = status
        guard status == .allowed else { return }
        recency = coordinator.contactCallRecency
        if entries == nil || loadFailed {
            loadEntries()
        }
    }

    /// The user tapped Allow on the access card — the ONE place the
    /// permission prompt may fire (point of use, constitution).
    private func grantAccess() {
        Task {
            let granted = await directory.requestAccess()
            access = AddressBookDirectory.access()
            if granted {
                recency = coordinator.contactCallRecency
                loadEntries()
            }
        }
    }

    private func loadEntries() {
        loadFailed = false
        Task {
            do {
                // A full-book enumerate can take a moment on first
                // access — never block the main thread for it.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try AddressBookDirectory().allEntries()
                }.value
                self.entries = loaded
            } catch {
                self.loadFailed = true
            }
        }
    }

    // MARK: - Voice search (voice-contact-search, 2026-09-07)

    /// True when the mic button may be shown: contacts are searchable and
    /// neither speech nor mic permission is dead. `.notDetermined` counts
    /// as visible — the ask happens at the tap (point of use); a denial
    /// flips `micHidden` for the rest of this visit.
    private var micButtonVisible: Bool {
        guard !micHidden, access == .allowed else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: break
        case .denied, .restricted: return false
        @unknown default: return false
        }
        if micRecordPermissionDenied() { return false }
        return true
    }

    private func updateMicVisibility() {
        // Denied in Settings while this view was alive → hide. Computed
        // fresh each appearance and on scenePhase → .active.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: micHidden = true
        default: break
        }
        if micRecordPermissionDenied() { micHidden = true }
    }

    private func micRecordPermissionDenied() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }

    /// Tap on the mic / stop button. Idle → start listening. Listening →
    /// stop (the capture completion restores the voice pipeline and
    /// returns the phase to idle). Failed → clear the caption and start
    /// again — one tap retries, no intermediate step.
    private func micTapped() {
        switch micPhase {
        case .idle, .failed:
            micPhase = .listening
            startMicCapture()
        case .listening:
            coordinator.cancelSearchPhraseCapture()
        }
    }

    private func startMicCapture() {
        // CallView is a struct — the @State mutations below are captured
        // by value through the binding, so no weak dance is needed (or
        // allowed); the closure only outlives the view briefly while the
        // one-shot capture runs.
        coordinator.startSearchPhraseCapture { result in
            switch result {
            case .success(let text):
                self.micPhase = .idle
                // As-you-type search picks the transcript up from here.
                self.searchText = text
            case .failure(let failure):
                switch failure {
                case .notAuthorized:
                    // Denied at the point of use — the button is honest
                    // dead for this visit (Settings can reverse it).
                    self.micHidden = true
                    self.micPhase = .idle
                case .cancelled, .busy:
                    // User tapped stop, or the assistant is mid-turn —
                    // both transient, both silent.
                    self.micPhase = .idle
                case .noSpeech, .audioUnavailable, .noAudioInput,
                     .recognitionFailed:
                    self.micPhase = .failed
                }
            }
        }
    }

    /// Consumes the coordinator's pending contact-search request (set by
    /// the router keyword pre-route) and applies it: navigate is already
    /// done — HomeView pushed this leaf — so here the query pre-fills the
    /// search field and the results (incl. WhatsApp/Messenger badges)
    /// land on screen, zero-touch. A nil query means "open the screen
    /// unprefilled" — nothing to announce.
    private func consumePendingVoiceRequestIfPresent() {
        guard let request = coordinator.takePendingContactSearchRequest() else { return }
        micPhase = .idle
        guard let query = request.query else {
            voiceRequest = nil
            return
        }
        voiceRequest = AppCoordinator.ContactSearchRequest(query: query)
        searchText = query
        // A voice-commanded search IS a search: open the search surface
        // (curated-first layout, 2026-09-07). The query pre-fills the
        // field, so this never trips the clear-to-empty auto-exit.
        searchMode = true
        // Entries may still be loading (onChange(of: entries) will call
        // back), but when they are here the results are on screen NOW.
        announceVoiceResultIfReady()
    }

    /// Speaks the outcome of a voice-commanded search — once per request
    /// — so the elder hears "मैया फेला पर्‍यो — कल गर्न थिच्नुहोस्"
    /// without looking. Silence unless every condition holds: a real
    /// voice query is pending, results are actually rendered (contacts
    /// allowed, book loaded, no load failure), and the field still holds
    /// the voice query (an edit retires the ask — handled in the
    /// searchText onChange). Runs as the coordinator's TTS — the same
    /// channel the assistant always speaks on.
    private func announceVoiceResultIfReady() {
        guard let voice = voiceRequest,
              announcedVoiceSearchID != voice.id,
              access == .allowed,
              let entries,
              !loadFailed,
              trimmedQuery == voice.query else { return }
        announcedVoiceSearchID = voice.id
        let outcome = UnifiedContactSearch.search(query: trimmedQuery,
                                                  family: coordinator.familyContacts,
                                                  in: entries,
                                                  recency: recency)
        let locale = coordinator.activeLocale
        if let name = outcome.entries.first?.name {
            coordinator.speak(text: L10n.fmt("call.search.spokenFound", locale: locale, name))
        } else {
            coordinator.speak(text: L10n.fmt("call.search.spokenNotFound", locale: locale, trimmedQuery))
        }
    }

    private func dial(_ result: UnifiedContactSearch.Result) {
        coordinator.performSystemContactCall(name: result.name, phone: result.phone)
        // Keep THIS list's ranking current without waiting for the next
        // view appearance; the coordinator store stays the source of
        // truth.
        recency[ContactNumberKey.normalized(result.phone)] = Date()
    }

    /// The row's WhatsApp pill — a chat surface, not a call, so no
    /// recency entry (channel opens are not dials).
    private func whatsApp(_ result: UnifiedContactSearch.Result) {
        coordinator.performSystemContactWhatsApp(name: result.name, phone: result.phone)
    }

    /// Primary-circle dial of a search row (channel-chooser task,
    /// 2026-09-07): the tap opens the row's RESOLVED channel —
    /// `rowChannelState` — over the stored per-contact preference, the
    /// app-wide default channel, and Messenger-handle availability. The
    /// circle and the tap always agree because both read the same state.
    ///
    /// FaceTime resolves to an AUDIO call (`video: false` — the row
    /// circle is a call surface, and FaceTime-audio is its dialable
    /// form; the icon mapping below still wears video.fill per the Phone
    /// review). Messenger opens the person's real thread by the resolved
    /// handle. Each surface goes through the same coordinator method the
    /// family tiles dial with, so every open — and every honest
    /// fallback — is announced exactly as it is. GSM keeps the local
    /// recency bump the old dial gave it.
    private func dialChannel(_ result: UnifiedContactSearch.Result) {
        switch rowChannelState(for: result).resolvedChannel {
        case .phone:
            dial(result)
        case .faceTime:
            coordinator.performFaceTimeCall(name: result.name, phone: result.phone, video: false)
        case .whatsApp:
            whatsApp(result)
        case .messenger:
            guard let handle = resolvedMessengerHandle(for: result) else {
                // Stale state only — resolution forces a handle-less row
                // to phone, so a resolved-messenger row always has a
                // handle; if one somehow vanished, say so honestly.
                let locale = coordinator.activeLocale
                coordinator.speak(text: L10n.fmt("router.call.messengerNoHandle",
                                                 locale: locale, result.name))
                return
            }
            coordinator.performSystemContactMessenger(name: result.name, handle: handle)
        }
    }

    /// The chooser's "make this the row's channel" action (channel-
    /// chooser task, 2026-09-07): remembers the picked app as the row's
    /// stored per-contact preference. Picking only stores — the row's
    /// circle then reflects and dials the new channel. Bumping
    /// `channelStateVersion` re-resolves the per-outcome states so the
    /// circle and the menu's checkmark move together.
    private func chooseChannel(_ app: CallApp, for result: UnifiedContactSearch.Result) {
        let storeKey = ContactNumberKey.normalized(result.phone)
        guard !storeKey.isEmpty else { return }
        coordinator.setChannelPreference(app, forNormalizedPhone: storeKey)
        channelStateVersion += 1
    }

    /// One result row's channel truth for the CURRENT outcome
    /// (channel-chooser task, 2026-09-07): stored preference, resolved
    /// dial channel, handle availability, and the store key they live
    /// under. Computed once per outcome in the results area — never per
    /// row body evaluation — and re-computed there after a chooser pick
    /// or a saved handle (the `channelStateVersion` bump above).
    private func rowChannelState(for result: UnifiedContactSearch.Result) -> RowChannelState {
        _ = channelStateVersion
        let storeKey = ContactNumberKey.normalized(result.phone)
        let storedPreference = storeKey.isEmpty
            ? nil
            : coordinator.storedChannelPreference(forNormalizedPhone: storeKey)
        let hasHandle = resolvedMessengerHandle(for: result) != nil
        let resolvedChannel = AppCoordinator.resolvedCallChannel(
            explicit: storedPreference,
            defaultApp: coordinator.defaultCallApp,
            messengerHandleAvailable: hasHandle)
        return RowChannelState(storedPreference: storedPreference,
                               resolvedChannel: resolvedChannel,
                               hasHandle: hasHandle,
                               storeKey: storeKey)
    }

    /// The usable Messenger handle behind a row's messenger channel —
    /// what earns the row its paperplane and opens its thread
    /// (messenger-gate 2026-09-07, extended by the channel-chooser task
    /// 2026-09-07). Resolution order: the row's OWN handle when the
    /// search layer's availability says it is real
    /// (`Result.messengerAvailable` — family rows: the configured handle
    /// in Messenger's username alphabet; book rows: the derived
    /// Facebook-linkage handle); else a handle the app captured earlier
    /// into `MessengerHandleStore` (keyed by the normalized phone,
    /// validated against Messenger's username alphabet so a corrupt
    /// entry can never earn a paperplane). The store fallback now
    /// applies to ANY row kind whose number normalizes to digits —
    /// handle-less family rows can earn a handle through the row's
    /// add-handle sheet, which writes that same store. Nil means no
    /// Messenger identity exists for the row — a bare phone number is
    /// never one.
    private func resolvedMessengerHandle(for result: UnifiedContactSearch.Result) -> String? {
        if result.messengerAvailable, let own = result.messengerHandle, !own.isEmpty {
            return own
        }
        let storeKey = ContactNumberKey.normalized(result.phone)
        guard !storeKey.isEmpty,
              let stored = coordinator.storedMessengerHandle(forNormalizedPhone: storeKey) else {
            return nil
        }
        let usable = CallLinks.messengerHandle(stored)
        return usable.isEmpty ? nil : usable
    }

    /// Opens the Messenger-handle capture sheet for a handle-less row
    /// (channel-chooser task, 2026-09-07) — the row's `addHandle` action
    /// (person.crop.circle.badge.plus). Draft text always starts clean.
    private func presentHandleCapture(for result: UnifiedContactSearch.Result) {
        handleText = ""
        handleCaptureTarget = result
    }

    /// Save action of the handle-capture sheet: normalize the typed
    /// username, persist it against the row's normalized phone, and
    /// refresh the row state so the Messenger option and paperplane come
    /// alive. A store failure leaves the sheet open with the draft
    /// intact — Save can simply be retried; nothing is claimed that
    /// didn't happen.
    private func saveCapturedHandle() {
        guard let target = handleCaptureTarget else { return }
        let handle = CallLinks.messengerHandle(handleText)
        let storeKey = ContactNumberKey.normalized(target.phone)
        guard !handle.isEmpty, !storeKey.isEmpty else { return }
        if coordinator.storeMessengerHandle(handle, forNormalizedPhone: storeKey) {
            channelStateVersion += 1
            handleCaptureTarget = nil
            handleText = ""
        }
    }

    // MARK: Result / family areas

    @ViewBuilder
    private var resultsArea: some View {
        if let entries {
            let outcome = UnifiedContactSearch.search(query: trimmedQuery,
                                                      family: coordinator.familyContacts,
                                                      in: entries,
                                                      recency: recency)
            if outcome.moreAvailable {
                Text("call.search.moreAvailable")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if outcome.entries.isEmpty {
                // An empty book AND no family at all, vs. a query that
                // simply matched nobody, are different truths — say
                // which one it is.
                if entries.isEmpty && coordinator.familyContacts.isEmpty {
                    emptyState(key: "call.search.bookEmpty")
                } else {
                    emptyState(key: "call.search.noResults")
                }
            } else {
                // Per-row photo thumbnails, resolved ONCE per search
                // outcome next to the channel pass below (contact-photos
                // task, 2026-09-07): only `.family` rows have a photo —
                // `contactPhoto(for:)` is a curated-contact API, book
                // rows get nil — and the rows index this result instead
                // of touching the photo resolver per body evaluation.
                let photos = outcome.entries.reduce(into: [String: UIImage]()) {
                    photos, row in
                    guard case .family(let contact) = row,
                          let image = coordinator.contactPhoto(for: contact) else { return }
                    photos[row.id] = image
                }
                // Per-row channel state, resolved ONCE per search
                // outcome (channel-chooser task, 2026-09-07): the
                // preference store and the captured-handle store are
                // Keychain-backed, so those lookups run here — one pass
                // over the matched rows — and the rows below only index
                // the result. A chooser pick or a saved handle bumps
                // `channelStateVersion`, which re-runs this pass.
                let channelStates = Dictionary(
                    uniqueKeysWithValues: outcome.entries.map {
                        ($0.id, rowChannelState(for: $0))
                    }
                )
                VStack(spacing: 12) {
                    ForEach(outcome.entries) { result in
                        UnifiedContactResultRow(result: result,
                                                photo: photos[result.id],
                                                channelState: channelStates[result.id]
                                                    ?? rowChannelState(for: result),
                                                dial: { dialChannel(result) },
                                                whatsApp: { whatsApp(result) },
                                                chooseChannel: { app in
                                                    chooseChannel(app, for: result)
                                                },
                                                addHandle: { presentHandleCapture(for: result) })
                    }
                }
            }
        }
    }

    /// The in-app family tiles (spec §4.4) — always reachable, with or
    /// without contacts permission or a search query.
    @ViewBuilder
    private var familyArea: some View {
        if coordinator.familyContacts.isEmpty {
            emptyState(key: "call.contactsEmpty")
        } else {
            VStack(spacing: 12) {
                ForEach(coordinator.familyContacts) { contact in
                    ContactTile(contact: contact)
                }
                if let entries, entries.count < 5, whatsAppInstalled {
                    // WhatsApp people only reach the system address book —
                    // which the search above sweeps — after the user turns
                    // on WhatsApp's OWN "Sync contacts" device setting. The
                    // card points at that two-line fix and opens WhatsApp;
                    // a small book is exactly when the hint matters.
                    WhatsAppSyncHintCard(openWhatsApp: coordinator.openWhatsAppContacts)
                }
            }
        }
    }

    // MARK: - Recent activity at the bottom (Phone review, 2026-09-07)

    /// How many of the newest activity entries the Phone screen shows
    /// before it points at the full Recent activity leaf.
    private static let recentActivityLimit = 5

    /// "Recent activity" at the BOTTOM of the not-searching content,
    /// below the family tiles (Phone review, 2026-09-07): the newest of
    /// the assistant's OWN calls and messages — the same store, rows,
    /// and tap-to-redial semantics as the Recent activity leaf (so this
    /// section needs no contacts permission either). Empty → the whole
    /// section hides (no dead header). When the log outgrows the cap, a
    /// "Show more" capsule pushes the full History leaf — its old top
    /// capsule entry left this screen with the review.
    @ViewBuilder
    private var recentActivitySection: some View {
        let activity = coordinator.recentActivity
        if !activity.isEmpty {
            let shown = Array(activity.prefix(Self.recentActivityLimit))
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey("history.title"))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                ForEach(shown) { entry in
                    recentActivityRow(entry)
                }
                if activity.count > Self.recentActivityLimit {
                    NavigationLink(value: LeafDestination.history) {
                        Text(LocalizedStringKey("history.showMore"))
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundColor(DesignTokens.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.card)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(DesignTokens.accent.opacity(0.35),
                                                 lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One Recent activity row — the History leaf's row (channel icon
    /// badge, name, time caption) plus a trailing ≥44pt call-again
    /// circle (Phone review, 2026-09-07). The WHOLE row is the button —
    /// the same trust model as every other dial surface here — and
    /// re-initiates the recorded channel exactly like the leaf's rows
    /// do. The trailing circle is a visual affordance inside that
    /// button, hidden from VoiceOver so the row reads once (label
    /// below).
    private func recentActivityRow(_ entry: AppActivityEntry) -> some View {
        Button {
            initiateRecentActivity(entry)
        } label: {
            HStack(spacing: 12) {
                IconBadge(systemImage: recentChannelIcon(for: entry.channel),
                          tint: recentChannelTint(for: entry.channel),
                          diameter: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ActivityRowText.name(for: entry, locale: coordinator.activeLocale))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text(recentActivityTimeText(entry))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(recentActivityRowLabel(entry)))
    }

    /// Screen-reader label of the row above — HistoryView's split: call
    /// rows say "call <name> back", message rows say "message <name>"
    /// (history.callbackLabel / history.messageLabel), so one gesture
    /// reads the row's action. An UNANSWERED row (missed-calls task,
    /// 2026-09-07) announces what the row is and what its tap does —
    /// "Unanswered call, Open Phone app" (history.unanswered /
    /// history.openPhone) — mirror of HistoryView.rowAccessibilityLabel;
    /// keep in step.
    private func recentActivityRowLabel(_ entry: AppActivityEntry) -> String {
        let locale = coordinator.activeLocale
        if entry.channel == .unanswered {
            return "\(ActivityRowText.name(for: entry, locale: locale)), "
                + L10n.str("history.openPhone", locale: locale)
        }
        if entry.kind == .call {
            return L10n.fmt("history.callbackLabel", locale: locale, entry.contactName)
        }
        return L10n.fmt("history.messageLabel", locale: locale, entry.contactName)
    }

    /// The row's time caption — the leaf's bucketing ("Just now" /
    /// "Today" / "Yesterday" / short date) via `HistoryTimeFormat` with
    /// the same pinned `now`/calendar/locale inputs HistoryView uses.
    private func recentActivityTimeText(_ entry: AppActivityEntry) -> String {
        HistoryTimeFormat.displayString(for: entry.timestamp,
                                        now: Date(),
                                        calendar: Calendar.current,
                                        locale: coordinator.activeLocale)
    }

    /// HistoryView's channel symbols, replicated as a small private
    /// helper per the Phone review ("reuse HistoryView's icon mapping"):
    /// phone.fill for phone AND FaceTime audio (an audio call surface is
    /// a phone surface), video.fill for FaceTime video, the WhatsApp
    /// bubble, the Messenger paperplane, message.fill for SMS, and the
    /// missed-call glyph (phone.arrow.down.left) for unanswered rows
    /// (missed-calls task, 2026-09-07). Keep in step with
    /// `HistoryView.icon(for:)`.
    private func recentChannelIcon(for channel: AppActivityEntry.Channel) -> String {
        switch channel {
        case .phone, .faceTimeAudio: return "phone.fill"
        case .faceTimeVideo: return "video.fill"
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        case .messenger: return "paperplane.fill"
        case .sms: return "message.fill"
        case .unanswered: return "phone.arrow.down.left"
        }
    }

    /// Badge tint mirror of `HistoryView.tint(for:)` — keep in step.
    private func recentChannelTint(for channel: AppActivityEntry.Channel) -> DesignTokens.BadgeTint {
        switch channel {
        case .phone, .faceTimeVideo, .faceTimeAudio: return .call
        case .whatsapp, .messenger, .sms: return .reminders
        case .unanswered: return .call
        }
    }

    /// Tap-to-redial of a Recent activity row — the recorded channel
    /// re-opened EXACTLY as the History leaf re-opens it (mirror of
    /// `HistoryView.initiate(_:)`; keep in step): phone rows dial, SMS
    /// rows re-present the compose sheet, and rows whose stored identity
    /// (number for phone/WhatsApp, handle for Messenger) normalized to
    /// nothing speak the honest line instead of a silent dead tap.
    /// UNANSWERED rows (missed-calls task, 2026-09-07) have no stored
    /// identity at all by design — iOS masks the caller — so their tap
    /// opens the Phone app (Recents is one tab away) rather than
    /// speaking a dead-row line: the dialer open resolves the row
    /// honestly.
    private func initiateRecentActivity(_ entry: AppActivityEntry) {
        let name = entry.contactName
        let phone = entry.phone
        switch entry.channel {
        case .phone:
            guard !phone.isEmpty else {
                honestDeadRecentActivity(entry)
                return
            }
            coordinator.performSystemContactCall(name: name, phone: phone)
        case .faceTimeVideo:
            coordinator.performFaceTimeCall(name: name, phone: phone, video: true)
        case .faceTimeAudio:
            coordinator.performFaceTimeCall(name: name, phone: phone, video: false)
        case .whatsapp:
            guard !phone.isEmpty else {
                honestDeadRecentActivity(entry)
                return
            }
            coordinator.performSystemContactWhatsApp(name: name, phone: phone)
        case .messenger:
            guard let handle = entry.messengerHandle, !handle.isEmpty else {
                // The handle left the row (or was never there — an old
                // voice-path attempt) — say so instead of a silent dead
                // tap; Messenger rows can only be re-opened by handle.
                let locale = coordinator.activeLocale
                coordinator.speak(text: L10n.fmt("router.call.messengerNoHandle",
                                                 locale: locale, name))
                return
            }
            coordinator.performSystemContactMessenger(name: name, handle: handle)
        case .sms:
            coordinator.presentMessageDraft(phone: phone, name: name, body: "")
        case .unanswered:
            // No number exists to dial — the caller is anonymous by
            // platform design (iOS masks identity AND number) — so the
            // row opens the Phone app, where the call genuinely lives in
            // Recents, one tab away (missed-calls task, 2026-09-07).
            // Mirror of HistoryView's `.unanswered` case; keep in step.
            PhoneAppOpener.openDialer()
        }
    }

    /// Honest dead-row line — mirror of `HistoryView.honestDeadRow`: a
    /// number that normalized to nothing dialable must never produce a
    /// silent dead tap (defensive — records never store one, but a
    /// corrupt/hand-edited payload is possible).
    private func honestDeadRecentActivity(_ entry: AppActivityEntry) {
        let locale = coordinator.activeLocale
        coordinator.speak(text: L10n.fmt("call.announce.noPhoneNumber",
                                         locale: locale, entry.contactName))
    }

    /// The Messenger-handle capture sheet (channel-chooser task,
    /// 2026-09-07): the ask ("Enter <name>'s Messenger username"), the
    /// three "where to look" hint lines, the username field, and ≥44pt
    /// Save/Cancel. Save stays disabled while the field holds no usable
    /// username (or the row has no number to key the store on) —
    /// nothing is stored, nothing claimed.
    private func handleCaptureSheet(for result: UnifiedContactSearch.Result) -> some View {
        let locale = coordinator.activeLocale
        let storeKey = ContactNumberKey.normalized(result.phone)
        let canSave = !CallLinks.messengerHandle(handleText).isEmpty && !storeKey.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.fmt("messenger.handlePrompt.title", locale: locale, result.name))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(L10n.str("messenger.handleHints.title", locale: locale))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                ForEach(1...3, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index)")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(DesignTokens.accent)
                            .clipShape(Circle())
                        Text(L10n.str("messenger.handleHints.line\(index)", locale: locale))
                            .font(.system(size: DesignTokens.minBodyPointSize))
                            .foregroundColor(DesignTokens.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                TextField(L10n.str("messenger.handlePrompt.placeholder", locale: locale),
                          text: $handleText)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                HStack(spacing: 10) {
                    Button(L10n.str("messenger.handlePrompt.cancel", locale: locale)) {
                        handleCaptureTarget = nil
                        handleText = ""
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.background)
                    .clipShape(Capsule())
                    Spacer()
                    Button(L10n.str("messenger.handlePrompt.save", locale: locale)) {
                        saveCapturedHandle()
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .foregroundColor(.white)
                    .background(canSave ? DesignTokens.accent : DesignTokens.textSecondary.opacity(0.5))
                    .clipShape(Capsule())
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

/// Permission state card for the contacts search. `.ask` appears while
/// the app may still request access and explains WHY in plain language
/// before the prompt fires (constitution: request at the point of use);
/// `.blocked` appears after a denial or restriction, whose only forward
/// path is the system Settings screen. Either way the family tiles stay
/// visible beneath it — nothing is held hostage to the permission.
private enum AddressBookAccessMode {
    case ask
    case blocked
}

private struct AddressBookAccessCard: View {
    let mode: AddressBookAccessMode
    /// Fires the one-time permission request; used only by `.ask`.
    var onAllow: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(titleKey)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text(bodyKey)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(buttonKey)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var titleKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowTitle" : "call.search.deniedTitle"
    }
    private var bodyKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowBody" : "call.search.deniedBody"
    }
    private var buttonKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowButton" : "call.search.openSettings"
    }

    private func action() {
        if mode == .ask {
            onAllow?()
        } else {
            // Denied/restricted: only the system can lift it.
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }
}

/// WhatsApp contact-sync hint (wa-sync-hint, 2026-09-07): WhatsApp
/// people only reach the system address book — which the Phone leaf's
/// search sweeps — once the user enables WhatsApp's OWN "Sync contacts"
/// device setting (WhatsApp → Settings → Privacy). This app can't flip
/// that setting, only point at it. Mirrors `AddressBookAccessCard`'s
/// look (card background, body text via DesignTokens, one accent
/// button); the button opens WhatsApp, where the fix lives. The card is
/// shown only while a canOpenURL probe says WhatsApp is installed and
/// the loaded book is small; the coordinator re-probes at the tap and
/// announces honestly either way.
private struct WhatsAppSyncHintCard: View {
    /// Opens WhatsApp (the coordinator probes and announces).
    var openWhatsApp: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.accent)
            Text(LocalizedStringKey("call.waSyncHint"))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Button(action: openWhatsApp) {
                Text(LocalizedStringKey("call.openWhatsApp"))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

private struct AddressBookLoadingCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("call.search.loading")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

private struct AddressBookLoadFailedCard: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("call.search.loadFailed")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("call.search.retry")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// One search row's channel truth, resolved ONCE per outcome by CallView
/// (channel-chooser task, 2026-09-07) and handed to the row — the row
/// never touches the stores itself, and row bodies never re-read
/// Keychain-backed state per frame.
private struct RowChannelState {
    /// The row's stored per-contact channel preference (nil = none — the
    /// app-wide default decides then).
    let storedPreference: CallApp?
    /// The channel the primary circle shows and dials —
    /// `AppCoordinator.resolvedCallChannel` over (explicit preference,
    /// app default, Messenger-handle availability).
    let resolvedChannel: CallApp
    /// Whether a usable Messenger handle is on file for this row (its
    /// own linkage or one captured into the store) — enables the
    /// Messenger chooser option and a Messenger resolution.
    let hasHandle: Bool
    /// The normalized-phone key preferences and handles are stored
    /// under. Empty when the row's number has no dialable digits (a
    /// family contact may be configured loosely) — then nothing can be
    /// stored for the row, and the add-handle button is hidden.
    let storeKey: String
}

/// One unified search result — a family member or a system address-book
/// row (family rows wear a small accent "Family" chip so the two read
/// differently). Redesigned for the Phone review (channel-chooser task,
/// 2026-09-07): the WHOLE dial zone — avatar, name/caption, channel
/// circle — is a single button (a target comfortably larger than 44pt
/// for elderly hands) whose circle reflects the row's RESOLVED channel
/// and whose tap dials through that channel, not always GSM. VoiceOver
/// reads it as one "Call <name>" button whose value names the channel
/// when it isn't the dialer.
///
/// Under the dial zone sit the row's channel controls: the WhatsApp pill
/// is kept EXACTLY as before (the official phone-number chat form — the
/// review said the chooser does not replace it); the Messenger pill from
/// messenger-gate is superseded by the chooser (Messenger-by-handle now
/// lives in the per-row channel state). A trailing ellipsis Menu picks
/// the row's channel (Mobile / FaceTime / WhatsApp / Messenger, current
/// one checkmarked; Messenger disabled while the row has no handle), and
/// a handle-less row also wears a person.badge.plus button that opens
/// the leaf's add-handle sheet. All of it is driven by the caller — the
/// row never guesses availability or resolves anything itself.
private struct UnifiedContactResultRow: View {
    let result: UnifiedContactSearch.Result
    /// The row's leading photo thumbnail (contact-photos task,
    /// 2026-09-07): ONLY `.family` rows carry one — the leaf resolves
    /// it once per search outcome from
    /// `AppCoordinator.contactPhoto(for:)` — book rows pass nil and
    /// keep the initials avatar. Caller-driven like everything else in
    /// the row; the row never touches the photo resolver itself.
    let photo: UIImage?
    /// The leaf-resolved channel truth for this row (see `RowChannelState`).
    let channelState: RowChannelState
    /// Dial the RESOLVED channel (`CallView.dialChannel`) — the circle
    /// and the whole dial zone tap this.
    let dial: () -> Void
    /// Open the WhatsApp chat surface (`CallView.whatsApp`) — the kept
    /// pill's action.
    let whatsApp: () -> Void
    /// Store a chooser pick as the row's channel preference
    /// (`CallView.chooseChannel`).
    let chooseChannel: (CallApp) -> Void
    /// Open the Messenger-handle capture sheet (`CallView.presentHandleCapture`).
    let addHandle: () -> Void
    @Environment(\.locale) private var locale

    /// Channel brand colors — kept here, not in DesignTokens: they are
    /// the apps' own identities, not Warm & Soft palette tokens.
    private static let whatsAppGreen = Color(red: 0.145, green: 0.827, blue: 0.4)
    private static let messengerBlue = Color(red: 0.0, green: 0.518, blue: 1.0)

    /// Whether this result is one of the app's own family contacts
    /// (vs. a system address-book row).
    private var isFamily: Bool {
        if case .family = result { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            dialZone
            channelControls
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    /// The wide dial button — tapping anywhere on the face/name zone
    /// (or its trailing channel circle) opens the row's RESOLVED
    /// channel. The circle is the ContactTile-style visual cue for what
    /// will open: white glyph on the channel's own color, ≥44pt.
    private var dialZone: some View {
        Button(action: dial) {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if isFamily {
                            familyChip
                        }
                        Text(result.caption)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: Self.icon(for: channelState.resolvedChannel))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(Self.circleColor(for: channelState.resolvedChannel))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("call.callButtonLabel", locale: locale, result.name)))
        // The value names what the tap actually opens: the number
        // caption when the channel is the dialer, the app's localized
        // name when it is FaceTime/WhatsApp/Messenger — VoiceOver must
        // never imply a GSM call that won't happen.
        .accessibilityValue(Text(resolvedChannelValue))
    }

    /// The row's leading face (contact-photos task, 2026-09-07): the
    /// family row's photo thumbnail when one resolved (see `photo`),
    /// else the initials FaceAvatar — same 52pt circle either way, so
    /// result rows mirror the ContactTile face column. The photo is
    /// decorative for VoiceOver: the dial button already reads the
    /// contact's name and channel, so an unlabelled "image" adds noise.
    @ViewBuilder
    private var avatar: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            FaceAvatar(name: result.name, diameter: 52)
        }
    }

    /// Value text of the dial button (see above).
    private var resolvedChannelValue: String {
        if channelState.resolvedChannel == .phone {
            return result.caption
        }
        return L10n.str(Self.appNameKey(for: channelState.resolvedChannel), locale: locale)
    }

    /// Small accent-tinted "Family" capsule prepended to the caption.
    /// Hidden from VoiceOver so the dial button stays a single read —
    /// the caption already says who this person is.
    private var familyChip: some View {
        Text(L10n.str("call.search.familyChip", locale: locale))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(DesignTokens.accent.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    /// Bottom strip of the card: the kept WhatsApp pill (leading, when
    /// the row's number can build one) and the trailing ≥44pt channel
    /// controls — the add-handle button on handle-less rows, then the
    /// channel chooser.
    private var channelControls: some View {
        HStack(spacing: 8) {
            if result.whatsAppAvailable {
                whatsAppPill
            }
            Spacer(minLength: 0)
            if !channelState.hasHandle, !channelState.storeKey.isEmpty {
                addHandleButton
            }
            channelChooser
        }
        .frame(maxWidth: .infinity)
    }

    /// The WhatsApp pill, byte-for-byte the messenger-gate row's: white
    /// text on WhatsApp green, ≥44pt — the official phone-number chat
    /// surface, which the Phone review said the chooser does not replace.
    private var whatsAppPill: some View {
        Button(action: whatsApp) {
            Text(L10n.str("call.channel.whatsapp", locale: locale))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(Self.whatsAppGreen)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("call.channel.whatsappLabel", locale: locale, result.name)))
    }

    /// The channel chooser (Phone review, 2026-09-07): an
    /// ellipsis.circle ≥44pt button opening a Menu of the four call
    /// channels — Mobile, FaceTime, WhatsApp, Messenger — labeled with
    /// the apps' localized names (`app.name.*`, which ARE their
    /// accessibility labels), the resolved channel checkmarked, and
    /// Messenger disabled (dimmed; VoiceOver hears "dimmed" plus the
    /// body-line hint) while the row has no handle. Picking only stores
    /// the preference — the row's circle moves, the dial follows.
    private var channelChooser: some View {
        Menu {
            channelOption(.phone)
            channelOption(.faceTime)
            channelOption(.whatsApp)
            Button {
                chooseChannel(.messenger)
            } label: {
                Text(L10n.str(Self.appNameKey(for: .messenger), locale: locale))
            }
            .disabled(!channelState.hasHandle)
            .accessibilityHint(Text(L10n.str("messenger.handlePrompt.body", locale: locale)))
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(Circle())
        }
        .accessibilityLabel(Text(L10n.str(Self.appNameKey(for: channelState.resolvedChannel),
                                           locale: locale)))
    }

    /// One enabled chooser option — the channel's app-name text, with a
    /// checkmark when it is the row's resolved channel.
    @ViewBuilder
    private func channelOption(_ app: CallApp) -> some View {
        Button {
            chooseChannel(app)
        } label: {
            if app == channelState.resolvedChannel {
                Label(L10n.str(Self.appNameKey(for: app), locale: locale),
                      systemImage: "checkmark")
            } else {
                Text(L10n.str(Self.appNameKey(for: app), locale: locale))
            }
        }
    }

    /// Add-handle affordance (Phone review, 2026-09-07): on rows with no
    /// Messenger handle, a person.badge.plus ≥44pt button next to the
    /// chooser that opens the leaf's capture sheet — the hints live
    /// there. Its label is the sheet's own ask ("Enter <name>'s
    /// Messenger username"), so VoiceOver already says what the button
    /// is for.
    private var addHandleButton: some View {
        Button(action: addHandle) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
                .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                .background(DesignTokens.background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("messenger.handlePrompt.title", locale: locale, result.name)))
    }

    /// Resolved-channel glyph — the review's mapping: phone.fill for the
    /// dialer, video.fill for FaceTime, the WhatsApp bubble, the
    /// Messenger paperplane.
    private static func icon(for app: CallApp) -> String {
        switch app {
        case .phone: return "phone.fill"
        case .faceTime: return "video.fill"
        case .whatsApp: return "bubble.left.and.bubble.right.fill"
        case .messenger: return "paperplane.fill"
        }
    }

    /// The circle's fill — accent for the dialer, the FaceTime call
    /// blue, and each chat app's own brand color so the glyph reads like
    /// the app it opens.
    private static func circleColor(for app: CallApp) -> Color {
        switch app {
        case .phone: return DesignTokens.accent
        case .faceTime: return DesignTokens.BadgeTint.call.tint
        case .whatsApp: return whatsAppGreen
        case .messenger: return messengerBlue
        }
    }

    /// The localized app-name key for a channel (`app.name.phone` /
    /// `.facetime` / `.whatsapp` / `.messenger`) — chooser option labels
    /// and the dial button's channel value both read these.
    private static func appNameKey(for app: CallApp) -> String {
        switch app {
        case .phone: return "app.name.phone"
        case .faceTime: return "app.name.facetime"
        case .whatsApp: return "app.name.whatsapp"
        case .messenger: return "app.name.messenger"
        }
    }
}

/// Face/photo avatar + name, with per-contact VIDEO and AUDIO call
/// buttons — no list picker in between (redesign spec §3.1 "one face,
/// one tap"; contact-call-buttons task 2026-09-06). Each button opens
/// the contact's preferred app for that call kind (`FamilyContact`
/// carries the per-contact defaults; the personalization editor is a
/// deferred follow-up) through `AppCoordinator.performContactCall`,
/// which also announces the opened surface aloud.
///
/// The leading face (contact-photos task, 2026-09-07) is the contact's
/// own photo thumbnail when the coordinator resolves one from the
/// contact's `photoFilename` (`AppCoordinator.contactPhoto(for:)`),
/// otherwise the initials FaceAvatar — same 52pt circle either way, so
/// a curated row of tiles keeps a uniform face column.
struct ContactTile: View {
    let contact: FamilyContact
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.locale) private var locale

    /// The tile's face circle — photo or initials (see the struct doc).
    /// The photo branch is hidden from VoiceOver: an unlabelled "image"
    /// read would add nothing — the contact's name sits right beside
    /// it. The initials fallback keeps its legacy exposure untouched.
    @ViewBuilder
    private func avatar(for contact: FamilyContact) -> some View {
        if let photo = coordinator.contactPhoto(for: contact) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            FaceAvatar(name: contact.name, diameter: Self.avatarDiameter)
        }
    }

    private static let avatarDiameter: CGFloat = 52

    var body: some View {
        HStack(spacing: 14) {
            avatar(for: contact)
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

    /// One schedule card, all three reminder systems (2026-09-07 fix:
    /// this section used to list medication alone — the app now
    /// schedules three systems and all of them belong in "today's
    /// schedule"). Medication rows are unchanged; routine rows include
    /// only `.pending` occurrences (the reminders leaf keeps the dimmed
    /// history); external rows carry the calendar/checklist badge.
    private var scheduleRows: [ScheduleRow] {
        let entriesById = Dictionary(
            uniqueKeysWithValues: coordinator.routineEntries.map { ($0.id, $0) }
        )
        let meds = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .map { ScheduleRow(id: $0.id.uuidString, scheduledAt: $0.scheduledAt,
                               title: coordinator.medicationName(for: $0.medicationEntryId),
                               systemImage: "clock.fill", isAllDay: false,
                               calendarName: nil) }
        let routines = coordinator.todaysRoutineOccurrences
            .filter { $0.state == .pending }
            .compactMap { occurrence -> ScheduleRow? in
                guard let entry = entriesById[occurrence.entryId] else { return nil }
                return ScheduleRow(id: occurrence.id.uuidString,
                                   scheduledAt: occurrence.scheduledAt,
                                   title: entry.displayTitle(locale: coordinator.activeLocale),
                                   systemImage: entry.category.systemImage,
                                   isAllDay: false, calendarName: nil)
            }
        let externals = coordinator.externalRemindersToday.map { item in
            ScheduleRow(id: item.id, scheduledAt: item.startDate, title: item.title,
                        systemImage: item.source.systemImage, isAllDay: item.isAllDay,
                        calendarName: item.calendarName)
        }
        return (meds + routines + externals).sorted { $0.scheduledAt < $1.scheduledAt }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        if !scheduleRows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("calendar.todaySchedule")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                ForEach(scheduleRows) { row in
                    scheduleRowView(row)
                }
            }
        }
    }

    private func scheduleRowView(_ row: ScheduleRow) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: row.systemImage, tint: .reminders)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(row.isAllDay
                     ? L10n.str("externalReminders.allDay", locale: coordinator.activeLocale)
                     : row.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                if let calendarName = row.calendarName {
                    Text(calendarName)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private struct ScheduleRow: Identifiable {
        let id: String
        let scheduledAt: Date
        let title: String
        let systemImage: String
        /// All-day external items caption "All day" instead of a clock
        /// time (their schedule is their date, not an hour).
        let isAllDay: Bool
        /// Only external rows carry one — the native calendar the item
        /// came from, shown as a second caption line.
        let calendarName: String?
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
