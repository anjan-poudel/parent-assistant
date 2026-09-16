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

    var body: some View {
        LeafScreen(titleKey: "events.title") {
            VStack(spacing: 12) {
                addButton
                if events.isEmpty {
                    emptyState(key: "events.empty")
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
        .sheet(isPresented: $addingEvent) {
            EventFormView(event: nil) { version += 1 }
        }
        .sheet(item: $editingEvent) { event in
            EventFormView(event: event) { version += 1 }
        }
    }

    /// The ＋ row: a full-width ≥44pt capsule rather than a bare glyph —
    /// the same shape the Reminders leaf's photo controls use, and one
    /// the elder cannot miss.
    private var addButton: some View {
        Button {
            addingEvent = true
        } label: {
            Label("events.add", systemImage: "plus.circle.fill")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func eventRow(_ event: FreeFormEvent) -> some View {
        Button {
            editingEvent = event
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 24))
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(Self.whenText(for: event, locale: coordinator.activeLocale))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                    if let address = event.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundStyle(DesignTokens.textSecondary)
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
                        .font(.system(size: 22))
                        .foregroundStyle(DesignTokens.accent)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
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
    private static func weekdayName(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let weekday = Calendar.current.component(.weekday, from: date)
        guard let symbols = formatter.weekdaySymbols,
              weekday >= 1, weekday <= symbols.count else { return "" }
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

    /// nil = add a new event; non-nil = edit that one.
    let event: FreeFormEvent?

    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var form: FreeFormEventForm
    @State private var photoPickerItem: PhotosPickerItem?
    /// The photo currently on the event, if any — shown until replaced.
    @State private var storedPhoto: UIImage?
    @State private var removingStoredPhoto = false

    /// Called after a successful save so the list re-reads.
    private let onSaved: () -> Void

    init(event: FreeFormEvent?, onSaved: @escaping () -> Void) {
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
                addressCard
                notesCard
                saveButton
            }
        }
        .onAppear { loadStoredPhoto() }
        .onChange(of: photoPickerItem) { item in
            loadPickedPhoto(item)
        }
    }

    // MARK: Cards

    private var titleCard: some View {
        TextField(LocalizedStringKey("events.field.title"), text: $form.title)
            .font(.system(size: DesignTokens.minBodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
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
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
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
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
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
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
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
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.accent)
                        .clipShape(Capsule())
                }
                if displayedPhoto != nil, event != nil {
                    Button {
                        form.pickedPhoto = nil
                        removingStoredPhoto = true
                    } label: {
                        Text("events.photo.remove")
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.background)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("events.photo.note")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("events.field.address")
            TextField(LocalizedStringKey("events.field.addressPlaceholder"), text: $form.address)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(14)
                .frame(minHeight: 56)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignTokens.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            Text("events.address.note")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var notesCard: some View {
        TextField(LocalizedStringKey("events.field.notes"), text: $form.notes)
            .font(.system(size: DesignTokens.minBodyPointSize))
            .padding(14)
            .frame(minHeight: 56)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    private var saveButton: some View {
        VStack(spacing: 10) {
            Button {
                save()
            } label: {
                Text(event == nil ? "events.save" : "events.saveChanges")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(form.isValid ? DesignTokens.accent
                                             : DesignTokens.textSecondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(!form.isValid)

            Button {
                dismiss()
            } label: {
                Text("common.cancel")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Pieces

    private func fieldLabel(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundStyle(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerRow(key: String, components: DatePickerComponents,
                           selection: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(key))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
                .environment(\.locale, coordinator.activeLocale)
        }
        .padding(14)
        .frame(minHeight: 56)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignTokens.background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
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
                            .font(.system(size: DesignTokens.minBodyPointSize,
                                          weight: .semibold))
                            .foregroundStyle(isSelected ? .white : DesignTokens.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(isSelected ? DesignTokens.accent
                                                   : DesignTokens.background)
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
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            form.pickedPhoto = DownsampledImageCache.downsampled(
                image, maxPixelEdge: ContactPhotoStore.maxDimension) ?? image
            removingStoredPhoto = false
        }
    }

    // MARK: Saving

    private func save() {
        guard form.isValid else { return }
        guard coordinator.saveFreeFormEvent(form, editing: event?.id) != nil else {
            // Nothing was written — keep the draft so Save can be retried
            // (the appointment form's rule).
            return
        }
        onSaved()
        dismiss()
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

    var body: some View {
        LeafScreen(titleKey: "events.detail.title") {
            VStack(spacing: 14) {
                if let event {
                    detailCards(event)
                } else {
                    // Gone — deleted here, or by the family in their own
                    // Calendar app between the tap and this screen.
                    emptyState(key: "events.detail.gone")
                }
            }
        }
        .task(id: version) { load() }
        .sheet(isPresented: $editing) {
            if let event {
                EventFormView(event: event) {
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

        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(EventsView.whenText(for: event, locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
            if let address = event.address, !address.isEmpty {
                Text(address)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

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
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var editButton: some View {
        Button {
            editing = true
        } label: {
            Text("events.edit")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Text("events.delete")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.stateError)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Text("common.close")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
    }

    // MARK: Loading / mutating

    private func load() {
        event = coordinator.freeFormEvent(id: eventId)
        photo = coordinator.freeFormEventPhoto(forEventId: eventId)
    }

    private func deleteEvent() {
        coordinator.deleteFreeFormEvent(eventId: eventId)
        onChanged()
        onClose()
    }
}
