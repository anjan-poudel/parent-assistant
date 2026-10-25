import PhotosUI
import SwiftUI
import UIKit

// MARK: - Events leaf (rich-events task, 2026-09-17; design §2)

/// The Events leaf: the household's own appointments — the things that
/// are NOT a routine and NOT a medication, like "डाक्टर भेट" on Tuesday
/// at 11 — listed soonest-first, with a ＋ that opens the add form.
///
/// These events are NATIVE (design §1 decision 4): saving one writes an
/// `EKEvent` to the default calendar, so it shows up in the family's own
/// Calendar app, flows back through the existing import, fires the usual
/// reminder and reaches the Google bridge. The app adds exactly two
/// things EventKit cannot hold — an optional photo and the list itself.
///
/// DESIGN-REVIEW rule this screen keeps (same as `RemindersView`): the
/// list is loaded into `@State` by a `.task`, never built inside `body`.
/// Each row costs an EventKit fetch (and its photo, a file read), and a
/// body evaluation happens on any coordinator publish — reading the
/// calendar from `body` would turn every unrelated notification into a
/// burst of store round-trips.
struct EventsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    /// The loaded list. Bumped-over via `version` after any edit, so the
    /// screen re-reads once per real change rather than per body pass.
    @State private var events: [FreeFormEvent] = []
    @State private var version = 0

    /// The add form; the edit form is item-driven off the row that
    /// opened it, so a swipe-dismiss cannot leave a half-edited event
    /// behind.
    @State private var addingEvent = false
    @State private var editingEvent: FreeFormEvent?
    /// [REMINDERS-INSTRUCTIONS] (T-024) One partial event save's plain line,
    /// shown on the screen the closed form reveals (design §2.10.3). A later
    /// successful save clears it; the row's edit path is the retry.
    @State private var showingPartialSave = false

    var body: some View {
        LeafScreen(titleKey: "events.title") {
            VStack(spacing: 12) {
                addButton
                if showingPartialSave {
                    partialSaveNotice
                }
                if events.isEmpty {
                    emptyState(key: "events.empty", appearance: appearance)
                } else {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .task(id: version) {
            events = coordinator.freeFormEvents()
        }
        // [REMINDERS-INSTRUCTIONS] (T-024) The form ALWAYS closes on a
        // non-nil outcome (design §2.10.2); `partial` only decides whether
        // the one plain line is shown here. No modal, no error dialog.
        .sheet(isPresented: $addingEvent) {
            EventFormView(event: nil) { partial in
                version += 1
                showingPartialSave = partial
            }
        }
        .sheet(item: $editingEvent) { event in
            EventFormView(event: event) { partial in
                version += 1
                showingPartialSave = partial
            }
        }
    }

    /// The one plain line a partial event save shows (design §2.10.3,
    /// §6.1.2): no alert, no error colour, no code. The event and its photo
    /// saved; only the instruction did not, and the existing edit row is
    /// the retry.
    private var partialSaveNotice: some View {
        Text(LocalizedStringKey(EventFormView.partialSaveKey))
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    /// The ＋ row: a full-width ≥44pt capsule rather than a bare glyph —
    /// the same shape the Reminders leaf's photo controls use, and one
    /// the elder cannot miss.
    private var addButton: some View {
        Button {
            showingPartialSave = false
            addingEvent = true
        } label: {
            Label("events.add", systemImage: "plus.circle.fill")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private func eventRow(_ event: FreeFormEvent) -> some View {
        Button {
            showingPartialSave = false
            editingEvent = event
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 24)).foregroundStyle(appearance.colors.accentForeground)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(Self.whenText(for: event, locale: coordinator.activeLocale))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                    if let address = event.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if event.photoFilename != nil {
                    // A glyph, not a thumbnail: drawing the photo here
                    // would mean a file read per row per body pass — the
                    // rule this screen keeps (see the type's comment).
                    Image(systemName: "photo.fill")
                        .font(.system(size: 22)).foregroundStyle(appearance.colors.accentForeground)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize).appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("events.edit"))
        .accessibilityValue(Text(event.title))
    }

    /// "Tue, 17 Sep · 11:00 AM" for a one-off; a series says so instead
    /// of printing the first occurrence's date, which would read as a
    /// past appointment ("every day from 1 Sep") rather than a rule.
    static func whenText(for event: FreeFormEvent, locale: Locale) -> String {
        let clock = event.startDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        switch event.recurrenceChoice {
        case .none:
            let day = event.startDate.formatted(
                Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
            return "\(day) · \(clock)"
        case .daily:
            return L10n.fmt("events.repeats.daily", locale: locale, clock)
        case .weekly:
            return L10n.fmt("events.repeats.weekly",
                            locale: locale,
                            Self.weekdayName(event.startDate, locale: locale),
                            clock)
        }
    }

    /// "Tuesday" in the active language — the same free-localization
    /// trick `RoutinePlugin` uses: Calendar weekday 1...7 indexes
    /// `DateFormatter`'s localized symbols (Sunday-first), so a weekday
    /// needs no catalog key of its own.
    ///
    /// [RESPONSIVENESS] (2026-10-14) The symbols come from the
    /// locale-keyed `LocaleFormatters` cache — the same fix the house
    /// applied to per-row formatters (`ViewCaches.swift`). This used to
    /// build a fresh `DateFormatter` per weekly-recurrence row per body
    /// pass, which is formatter construction (an ICU setup, not a
    /// format) inside view evaluation.
    private static func weekdayName(_ date: Date, locale: Locale) -> String {
        let symbols = LocaleFormatters.longWeekdaySymbols(locale: locale)
        let weekday = Calendar.current.component(.weekday, from: date)
        guard weekday >= 1, weekday <= symbols.count else { return "" }
        return symbols[weekday - 1]
    }
}

// MARK: - Add / edit form

/// The event form, in the house form style (≥44pt targets, body-size
/// text, one card per concern): title, date, time, duration, recurrence,
/// notes, photo, address.
///
/// The form owns a DRAFT and nothing else — saving goes through the
/// coordinator, so the screen never touches EventKit or the stores
/// directly. A failed save leaves the draft on screen (the same rule the
/// appointment and place editors follow): nothing is claimed that did not
/// happen.
struct EventFormView: View {
    @Environment(\.appAppearance) private var appearance
    /// [AX-VIEWPORT] Gates the choice chips' wrapping room.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// nil = add a new event; non-nil = edit that one.
    let event: FreeFormEvent?

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var form: FreeFormEventForm
    @State private var photoPickerItem: PhotosPickerItem?
    /// The photo currently on the event, if any — shown until replaced.
    @State private var storedPhoto: UIImage?
    @State private var removingStoredPhoto = false

    /// [REMINDERS-INSTRUCTIONS] (T-024) The instruction editor's session:
    /// one capture coordinator per presentation (design L2 §2.18), created
    /// on the tap and gone with the sheet. No system surface exists before
    /// the person asks for one.
    @State private var instructionEditorSession: EventInstructionEditorSession?

    /// Called after a non-nil save outcome so the host re-reads; `partial`
    /// is true only when the event saved and its instruction did not
    /// (design §4.8). The form itself renders no notice: it closes, and the
    /// host's screen shows the one plain line (§2.10.2–3).
    private let onSaved: (Bool) -> Void

    init(event: FreeFormEvent?, onSaved: @escaping (Bool) -> Void) {
        self.event = event
        if let event {
            _form = State(initialValue: FreeFormEventForm(event: event))
        } else {
            _form = State(initialValue: FreeFormEventForm())
        }
        self.onSaved = onSaved
    }

    var body: some View {
        LeafScreen(titleKey: event == nil ? "events.form.addTitle" : "events.form.editTitle") {
            VStack(spacing: 14) {
                titleCard
                whenCard
                durationCard
                recurrenceCard
                photoCard
                instructionCard
                addressCard
                notesCard
                shareHintCard
                saveButton
            }
        }
        .onAppear { loadStoredPhoto() }
        .onChange(of: photoPickerItem) { item in
            loadPickedPhoto(item)
        }
        // [REMINDERS-INSTRUCTIONS] (T-024) The shared editor, bound to a
        // local copy: the event form's draft changes only when the editor's
        // own Save accepts it, so Cancel/dismiss writes nothing.
        .sheet(item: $instructionEditorSession) { session in
            EventInstructionEditorSheet(
                capture: session.capture,
                initialDraft: form.instructionDraft,
                onAccept: { edited in
                    form.instructionDraft = edited
                    instructionEditorSession = nil
                },
                onCancel: { instructionEditorSession = nil })
        }
    }

    // MARK: Cards

    private var titleCard: some View {
        TextField(LocalizedStringKey("events.field.title"), text: $form.title)
            .font(.system(size: appearance.typography.bodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    private var whenCard: some View {
        VStack(spacing: 10) {
            pickerRow(key: "medical.appointments.date", components: .date,
                      selection: $form.startDate)
            pickerRow(key: "medical.appointments.time", components: .hourAndMinute,
                      selection: $form.startDate)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("events.field.duration")
            chipRow(options: FreeFormEventForm.durationChoices,
                    selected: form.durationMinutes,
                    label: { FreeFormEventForm.durationLabel(minutes: $0,
                                                            locale: coordinator.activeLocale) },
                    select: { form.durationMinutes = $0 },
                    accessibilityLabel: { FreeFormEventForm.durationLabel(
                        minutes: $0, locale: coordinator.activeLocale) })
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var recurrenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("events.field.recurrence")
            chipRow(options: FreeFormEventRecurrence.allCases,
                    selected: form.recurrence,
                    label: { L10n.str($0.titleKey, locale: coordinator.activeLocale) },
                    select: { form.recurrence = $0 },
                    accessibilityLabel: { L10n.str($0.titleKey,
                                                   locale: coordinator.activeLocale) })
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// Photo controls — the family-form pattern (`PhotosPicker` +
    /// `DownsampledImageCache`), with one honest caption: the photo shows
    /// in THIS app only. EventKit and Google Calendar have no event-photo
    /// API, so a photo the family cannot see in their own calendar would
    /// be a promise the app cannot keep.
    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("events.field.photo")
            HStack(spacing: 12) {
                if let preview = displayedPhoto {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Text(displayedPhoto == nil ? "events.photo.add" : "events.photo.change")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .appSurface(role: .accent, cornerRadius: 999)
                }
                if displayedPhoto != nil, event != nil {
                    Button {
                        form.pickedPhoto = nil
                        removingStoredPhoto = true
                    } label: {
                        Text("events.photo.remove")
                            .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                            .foregroundStyle(appearance.colors.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .appSurface(role: .control, cornerRadius: 999)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("events.photo.note")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// [REMINDERS-INSTRUCTIONS] (T-024) The event's one instruction
    /// (design L2 §2.10.1, §4.8): a plain summary of what the event
    /// currently carries and ONE Add/Change row that opens the shared
    /// editor. The summary never prints a filename or path; an event
    /// without an instruction shows no summary at all.
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("instruction.title")
            instructionSummary
            Button {
                openInstructionEditor()
            } label: {
                Text(LocalizedStringKey(
                    EventFormView.instructionControlKey(for: form.instructionDraft)))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .appSurface(role: .accent,
                                cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey(
                EventFormView.instructionControlKey(for: form.instructionDraft))))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// What the section says about the stored draft. `.text` is the words;
    /// image/video show their caption or, when there is none, the plain
    /// kind noun — never a filename. `.none` adds nothing at all.
    @ViewBuilder
    private var instructionSummary: some View {
        switch EventFormView.formSummaryState(for: form.instructionDraft) {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(_, let caption):
            instructionSummaryLine(caption ?? L10n.str(
                InstructionEditorView.kindKey(for: .image),
                locale: coordinator.activeLocale))
        case .video(_, let caption):
            instructionSummaryLine(caption ?? L10n.str(
                InstructionEditorView.kindKey(for: .video),
                locale: coordinator.activeLocale))
        case .unsupported(let text):
            if let text {
                instructionSummaryLine(text)
            }
            instructionSummaryLine(L10n.str(InstructionSurfaceKeys.unsupported,
                                            locale: coordinator.activeLocale))
        case .removed:
            instructionSummaryLine(L10n.str(InstructionSurfaceKeys.removed,
                                            locale: coordinator.activeLocale))
        }
    }

    private func instructionSummaryLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("events.field.address")
            TextField(LocalizedStringKey("events.field.addressPlaceholder"), text: $form.address)
                .font(.system(size: appearance.typography.bodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
            Text("events.address.note")
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private var notesCard: some View {
        TextField(LocalizedStringKey("events.field.notes"), text: $form.notes)
            .font(.system(size: appearance.typography.bodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// [CALENDAR-POLICY] (2026-09-17) The never-silent caption: sharing
    /// is connected and consented, but every family contact lacks an
    /// email — so THIS event will not invite anyone until an email is
    /// added. Invisible otherwise; nothing is pended or promised when it
    /// shows, the save is still local-first.
    @ViewBuilder
    private var shareHintCard: some View {
        if coordinator.calendarShareService.status.isActive,
           coordinator.familyContacts.allSatisfy({ ($0.email ?? "").isEmpty }) {
            Text(LocalizedStringKey("events.share.noEmails"))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var saveButton: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                Text(event == nil ? "events.save" : "events.saveChanges")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(form.isValid ? appearance.colors.accent
                                             : appearance.colors.textSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(!form.isValid)

            Button {
                dismiss()
            } label: {
                Text("common.cancel")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Pieces

    private func fieldLabel(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
            .foregroundStyle(appearance.colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerRow(key: String, components: DatePickerComponents,
                           selection: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(key))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
            Spacer()
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
                .environment(\.locale, coordinator.activeLocale)
        }
        .padding(14)
        .frame(minHeight: 56)
        .fixedSize(horizontal: false, vertical: true)
        .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
    }

    /// One row of choice capsules (duration, recurrence). Generic over
    /// the option type so the two pickers share one implementation —
    /// selected in accent-on-white, unselected on the card — and both
    /// carry the ≥44pt target the house requires of every tappable.
    private func chipRow<Option: Hashable>(options: [Option],
                                           selected: Option,
                                           label: @escaping (Option) -> String,
                                           select: @escaping (Option) -> Void,
                                           accessibilityLabel: @escaping (Option) -> String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selected
                    Button {
                        select(option)
                    } label: {
                        Text(label(option))
                            .font(.system(size: appearance.typography.bodyPointSize,
                                          weight: .semibold))
                            .foregroundStyle(isSelected ? .white : appearance.colors.textPrimary)
                            .multilineTextAlignment(.center)
                            // [AX-VIEWPORT] At accessibility text sizes
                            // the single-line pill's words touch the
                            // capsule's edges. The label may wrap (the
                            // width cap gives the horizontal scroll a
                            // line to wrap AT — an unbounded line never
                            // wraps), and the capsule gets vertical room
                            // that scales with the type. Standard sizes
                            // keep the one-line chip byte-for-byte.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 200 : nil)
                            .padding(.horizontal, 18)
                            .padding(.vertical, dynamicTypeSize.isAccessibilitySize
                                     ? appearance.typography.captionPointSize * 0.4 : 0)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(isSelected ? appearance.colors.accent
                                                   : appearance.colors.background)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(accessibilityLabel(option)))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Photo plumbing

    /// What the card shows: the just-picked photo, else the stored one
    /// (unless the elder removed it).
    private var displayedPhoto: UIImage? {
        if let picked = form.pickedPhoto { return picked }
        return removingStoredPhoto ? nil : storedPhoto
    }

    private func loadStoredPhoto() {
        guard let event, storedPhoto == nil else { return }
        storedPhoto = coordinator.freeFormEventPhoto(forEventId: event.id)
    }

    /// Same shape as the family-contact picker: load the transferable,
    /// then IMMEDIATELY downsample — a camera-roll image can be tens of
    /// megapixels, and only `ContactPhotoStore.maxDimension` of it is
    /// ever kept.
    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            // [RESPONSIVENESS] (2026-10-14) Decode + downsample OFF the
            // main actor. The old path did `UIImage(data:)` + a renderer
            // pass wherever this Task resumed — main, for a view-owned
            // Task — so the tens-of-megapixels decode ran as a visible
            // hitch between the picker dismissing and the preview
            // appearing. `downsampled(from:)` is ImageIO's thumbnail
            // decode (the full-size bitmap is never materialized), and
            // the detached hop mirrors the house pattern for heavy
            // loads (`SettingsView`'s family picker, the address-book
            // enumerate). Undecodable bytes yield nil → no photo, the
            // same soft failure the old `UIImage(data:)` guard had.
            let thumb = await Task.detached(priority: .userInitiated) {
                DownsampledImageCache.downsampled(
                    from: data, maxPixelEdge: ContactPhotoStore.maxDimension)
            }.value
            guard let thumb else { return }
            form.pickedPhoto = thumb
            removingStoredPhoto = false
        }
    }

    // MARK: Saving

    /// [REMINDERS-INSTRUCTIONS] (T-024) What the person's Save tap should
    /// do with the service's typed outcome (design L2 §4.8 value table).
    /// Pure and total so the surface suite can pin all three rows without
    /// rendering or touching EventKit.
    enum SaveAction: Equatable {
        /// The event was not written: stay open with the draft, no claim.
        case stayOpen
        /// The event and its instruction were written: refresh and close.
        case dismiss
        /// The event WAS written but its instruction was not: close all the
        /// same (§2.10.2) and let the host show ONE plain line on the screen
        /// underneath (§2.10.3). Never a success claim for the instruction
        /// and never an automatic re-submit.
        case dismissReportingPartial
    }

    /// The §4.8 truth table as one total function. `nil` is the only "not
    /// saved" answer; a non-nil outcome always closes the form — the partial
    /// one included, because the event now exists.
    static func saveAction(for outcome: FreeFormEventSaveOutcome?) -> SaveAction {
        guard let outcome else { return .stayOpen }
        return outcome.instructionSaved ? .dismiss : .dismissReportingPartial
    }

    /// The ONE plain line a partial outcome shows (§4.8 row 4). It says the
    /// video could not be saved and asks the person to add it again; it
    /// never claims the instruction saved and carries no error code.
    static let partialSaveKey = "instruction.savePartial"

    /// The form section's summary comes from the same IF-3 mapping every
    /// other surface uses — the draft's original, not its uncommitted
    /// edits. `.none` (a new event, or no instruction) adds no line.
    static func formSummaryState(for draft: InstructionDraft) -> InstructionDisplayState {
        InstructionPresentation.state(for: draft.original, isExpected: false)
    }

    /// Add vs Change, read from IF-1 (`original?.isPresent`), never from
    /// pending edits: an added-but-not-yet-saved instruction is still the
    /// add action for this form session.
    static func instructionControlKey(for draft: InstructionDraft) -> String {
        draft.original?.isPresent == true ? "instruction.change" : "instruction.add"
    }

    /// Opens the shared editor for ONE sheet session with its own capture
    /// coordinator (design L2 §2.18). No system surface exists before this
    /// tap, and the coordinator dies with the sheet.
    private func openInstructionEditor() {
        instructionEditorSession = EventInstructionEditorSession(
            capture: coordinator.instructionCaptureCoordinator(draftSession: .events))
    }

    /// The event form's ONE persistence action (design L2 §4.8). The
    /// instruction travels inside the same form and is written by the
    /// service second; the view adds no second write, no retry and no
    /// success claim. `nil` keeps every field so Save can be tried again;
    /// every non-nil outcome closes the form (§2.10.2), with the partial
    /// flag handed to the host for its one plain line.
    private func save() {
        guard form.isValid else { return }
        let outcome = coordinator.saveFreeFormEvent(form, editing: event?.id)
        switch EventFormView.saveAction(for: outcome) {
        case .stayOpen:
            // Nothing was written — keep the draft so Save can be retried
            // (the appointment form's rule).
            return
        case .dismiss:
            onSaved(false)
            dismiss()
        case .dismissReportingPartial:
            onSaved(true)
            dismiss()
        }
    }
}

// MARK: - Instruction editor sheet (T-024; design L2 §2.10, §4.2, §11.3)

/// One instruction-editor session on the event form.
///
/// The coordinator is created by the Add/Change tap and owned here, so a
/// re-render cannot build a second capture machine while the sheet is up
/// (design §2.18). Identity is the session itself, not the event.
private struct EventInstructionEditorSession: Identifiable {
    let id = UUID()
    let capture: InstructionVideoCaptureCoordinator
}

/// The event-specific half of the shared editor.
///
/// It owns a LOCAL draft seeded from the form's current draft. The shared
/// `InstructionEditorView` mutates only this copy; its Save hands the copy
/// back through `onAccept` and the sub-sheet closes. Nothing is written
/// here — the event form's Save is the one persistence action, and §4.8
/// requires the event to be saved before its instruction. Cancel (button
/// or swipe) calls `onCancel` and writes nothing.
///
/// The only picker is the app's existing out-of-process, permission-free
/// `VisualAidPhotoPicker` with one slot; no URL field, link playback,
/// share sheet, transcode, trimming or Settings deep link exists here.
private struct EventInstructionEditorSheet: View {
    /// The ONE capture coordinator this sheet session owns.
    let capture: InstructionVideoCaptureCoordinator
    let onAccept: (InstructionDraft) -> Void
    let onCancel: () -> Void

    /// The editor's whole state, seeded once from the form's draft.
    @State private var draft: InstructionDraft
    /// The picker's pending completion (`UIImage?`; nil means cancelled).
    /// At most one is held and it is cleared the moment it is used.
    @State private var pendingImageCompletion: ((UIImage?) -> Void)?
    @State private var isPickingImage = false

    init(capture: InstructionVideoCaptureCoordinator,
         initialDraft: InstructionDraft,
         onAccept: @escaping (InstructionDraft) -> Void,
         onCancel: @escaping () -> Void) {
        self.capture = capture
        self.onAccept = onAccept
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        InstructionEditorView(
            draft: $draft,
            capture: capture,
            // This sheet persists nothing, so there is no write failure to
            // report here; a partial event save is surfaced by the form.
            saveFailureKey: nil,
            pickImage: pickImage,
            onSave: { _ in onAccept(draft) },
            onCancel: onCancel
        )
        // The shipping permission-free picker, presented exactly as the
        // photo flow presents it (out of process, no permission prompt).
        // One image only; the editor decides whether the bytes resolve the
        // draft, and Save stays closed until they do.
        .sheet(isPresented: $isPickingImage) {
            VisualAidPhotoPicker(selectionLimit: 1) { picked in
                finishPickedImage(picked)
            }
        }
    }

    /// Presents the shared picker and stores its one callback. The editor
    /// calls this only for an image draft; picking bytes does not by itself
    /// make the draft resolvable — `InstructionDraft` decides that.
    private func pickImage(_ completion: @escaping (UIImage?) -> Void) {
        pendingImageCompletion = completion
        isPickingImage = true
    }

    /// The picker reports a selection with its images IN SELECTION ORDER;
    /// one slot, so `first` is the picked photo.
    private func finishPickedImage(_ picked: [UIImage]) {
        let completion = pendingImageCompletion
        pendingImageCompletion = nil
        completion?(picked.first)
    }
}

// MARK: - Event detail

/// One event, in full: what it is, when, where, the notes, the photo —
/// and the two actions that matter. **Navigate** (only when the event
/// has an address) hands the address to the existing navigation
/// executor, which forward-geocodes it at tap time and auto-starts the
/// family's map app (`MapsLinks` — zero new navigation code, per design
/// §4; a stored coordinate would go stale the moment the family corrects
/// the address in their own Calendar app).
///
/// This is also what a fired reminder's **Open** action opens (S3), and
/// what the fire-time presentation shows when the event has a photo — one
/// screen, so the elder never meets two versions of the same event.
struct EventDetailView: View {
    @Environment(\.appAppearance) private var appearance
    let eventId: String
    /// Called whenever the event changed under the screen (edited or
    /// deleted) so the list can re-read.
    var onChanged: () -> Void = {}
    var onClose: () -> Void = {}

    @EnvironmentObject var coordinator: AppCoordinator

    /// Loaded through the service, never read in `body`.
    @State private var event: FreeFormEvent?
    @State private var photo: UIImage?
    @State private var version = 0
    @State private var editing = false
    @State private var confirmingDelete = false
    /// [REMINDERS-INSTRUCTIONS] (T-024) The one plain line an edit's partial
    /// outcome leaves behind (design §2.10.3): the event and photo saved,
    /// the instruction did not. It is not a modal and not an error dialog;
    /// Edit is the existing retry.
    @State private var showingPartialSave = false

    /// [REMINDERS-INSTRUCTIONS] (T-024) The detail card's seams, all
    /// resolved in `load()` off the draw path: the app's existing
    /// event-photo loader (IF-21), the store's availability answer for a
    /// video (never a file read per body pass — design §11.3 D/F-12), and
    /// the tap's playback controller. Empty state means the card shows no
    /// control it cannot honour.
    @State private var instructionImageLoader: EventPhotoInstructionImageLoader?
    @State private var instructionVideoURL: URL?
    @State private var instructionPlayback: EventInstructionPlayback?

    var body: some View {
        LeafScreen(titleKey: "events.detail.title") {
            VStack(spacing: 14) {
                if let event {
                    detailCards(event)
                } else {
                    // Gone — deleted here, or by the family in their own
                    // Calendar app between the tap and this screen.
                    emptyState(key: "events.detail.gone", appearance: appearance)
                }
            }
        }
        .task(id: version) { load() }
        .sheet(isPresented: $editing) {
            if let event {
                EventFormView(event: event) { partial in
                    showingPartialSave = partial
                    version += 1
                    onChanged()
                }
            }
        }
        .alert("events.delete", isPresented: $confirmingDelete) {
            Button(L10n.str("events.delete", locale: coordinator.activeLocale),
                   role: .destructive) { deleteEvent() }
            Button(L10n.str("common.cancel", locale: coordinator.activeLocale),
                   role: .cancel) {}
        } message: {
            Text("events.deleteConfirm")
        }
        // [REMINDERS-INSTRUCTIONS] (T-024) Playback is tap-driven: the
        // controller is built by `playInstructionVideo` and `start()`
        // happens once the cover appears (design FR-RIE-018 — no autoplay).
        // Closing pauses and releases the player; the cover's own teardown
        // is still the backstop.
        .fullScreenCover(item: $instructionPlayback) { playback in
            InstructionCoverView(
                controller: playback.controller,
                startsWhenPresented: true,
                onClose: {
                    playback.controller.close()
                    instructionPlayback = nil
                })
        }
    }

    @ViewBuilder
    private func detailCards(_ event: FreeFormEvent) -> some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                .accessibilityLabel(Text("events.field.photo"))
        }

        // [REMINDERS-INSTRUCTIONS] (T-024) Design §2.10.4: the instruction
        // card sits under the photo and above the info card. `.none`
        // renders nothing at all — no empty container (design §4.10, P-9)
        // — so an instruction-less event's detail is exactly today's screen.
        instructionCard(event)
        if showingPartialSave {
            partialSaveNotice
        }

        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(EventsView.whenText(for: event, locale: coordinator.activeLocale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
            if let address = event.address, !address.isEmpty {
                Text(address)
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

        if event.hasAddress {
            navigateButton(event)
        }
        editButton
        deleteButton
        closeButton
    }

    /// The Navigate button — present exactly when there is somewhere to
    /// go. No address means no button at all, never a dead one.
    private func navigateButton(_ event: FreeFormEvent) -> some View {
        Button {
            coordinator.navigateToEvent(event)
        } label: {
            Label("events.navigate", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// The one plain line a partial edit leaves on the detail (design
    /// §2.10.3, §6.1.2): no alert, no error colour, no code. Edit — the
    /// button right below — is the existing retry.
    private var partialSaveNotice: some View {
        Text(LocalizedStringKey(EventFormView.partialSaveKey))
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var editButton: some View {
        Button {
            showingPartialSave = false
            editing = true
        } label: {
            Text("events.edit")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Text("events.delete")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Text("common.close")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .semibold)).foregroundStyle(appearance.colors.accentForeground)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    // MARK: Instruction (T-024; design §2.10, §4.10)

    /// The one card this screen adds. Its state is the shared IF-3 mapping,
    /// its image seam the app's existing event-photo loader, and its play
    /// action exists only when the coordinator's playability seam resolved
    /// a playable video in `load()` — otherwise the card shows its plain
    /// unavailable line and no control (no dead button, no autoplay).
    @ViewBuilder
    private func instructionCard(_ event: FreeFormEvent) -> some View {
        let state = EventDetailView.detailState(for: event)
        if state != .none {
            InstructionCardView(
                state: state,
                timeText: nil,
                imageLoader: instructionImageLoader,
                onPlay: EventDetailView.playAction(
                    for: state,
                    playbackURL: instructionVideoURL,
                    play: { url in
                        playInstructionVideo(url: url, title: event.title)
                    }))
        }
    }

    /// The person's Play tap is the only thing that builds a controller
    /// (FR-RIE-018). The URL was resolved in `load()`, so no store read
    /// happens here either.
    private func playInstructionVideo(url: URL, title: String) {
        instructionPlayback = EventInstructionPlayback(
            controller: coordinator.makeInstructionPlayback(url: url, title: title))
    }

    /// The detail's display state — the same total mapping the fired
    /// screen uses, with `isExpected: false`: an event with no instruction
    /// has nothing to say, never a removed notice.
    static func detailState(for event: FreeFormEvent) -> InstructionDisplayState {
        InstructionPresentation.state(for: event.instruction, isExpected: false)
    }

    /// Resolve a video's URL through the IF-10 answer. `availability` is
    /// injected so the rule is pure and the suite can pin all four answers
    /// without constructing a store; production passes the coordinator's
    /// playability seam (the view never reaches the store itself). Only
    /// `.available` yields a URL.
    static func playbackURL(for event: FreeFormEvent,
                            availability: (String) -> InstructionPlaybackAvailability) -> URL? {
        guard case .video(let filename, _) = detailState(for: event) else { return nil }
        guard case .available(let url) = availability(filename) else { return nil }
        return url
    }

    /// The action handed to `InstructionCardView`. Nil for every state but
    /// a video with a resolved playable URL, so the card never composes a
    /// play control that cannot work (design §4.10).
    static func playAction(for state: InstructionDisplayState,
                           playbackURL: URL?,
                           play: @escaping (URL) -> Void) -> ((String) -> Void)? {
        guard case .video = state, let playbackURL else { return nil }
        return { _ in play(playbackURL) }
    }

    // MARK: Loading / mutating

    /// Everything the screen draws is read here, once per `version`, never
    /// in `body`: the event, its photo, the image loader and the video's
    /// availability answer.
    private func load() {
        let loaded = coordinator.freeFormEvent(id: eventId)
        event = loaded
        photo = coordinator.freeFormEventPhoto(forEventId: eventId)
        instructionImageLoader = coordinator.eventInstructionImageLoader
        guard let loaded else {
            instructionVideoURL = nil
            return
        }
        instructionVideoURL = EventDetailView.playbackURL(
            for: loaded,
            availability: { filename in
                coordinator.instructionPlaybackAvailability(
                    filename: filename, owner: .event(loaded.id))
            })
    }

    /// Deletion stays on the existing coordinator path: the service is the
    /// single teardown owner (event, extras, photo, instruction media). The
    /// view adds no second delete and no file work (design §11.3 M).
    private func deleteEvent() {
        coordinator.deleteFreeFormEvent(eventId: eventId)
        onChanged()
        onClose()
    }
}

/// One playback presentation on the event detail: the controller the Play
/// tap built, boxed so `.fullScreenCover(item:)` can drive it. Identity is
/// the presentation, so a second tap after closing builds a fresh one.
private struct EventInstructionPlayback: Identifiable {
    let id = UUID()
    let controller: InstructionPlaybackController
}
