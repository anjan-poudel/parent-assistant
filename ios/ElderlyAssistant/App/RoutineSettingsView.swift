import Foundation
import SwiftUI
import UIKit

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
    @Environment(\.appAppearance) private var appearance
    /// The app's active language for the instruction row's VoiceOver label
    /// (T-023; design L2 §10.5) — the same `.locale` every instruction
    /// surface resolves its catalogue keys through.
    @Environment(\.locale) private var locale
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
    /// The routine whose instruction is being edited (T-023; design L2
    /// §2.9) — held as a whole presentation so the ONE capture coordinator
    /// this sheet session owns is created on the tap and reused by every
    /// re-render; a save failure keeps the same presentation (and draft)
    /// alive.
    @State private var instructionEditor: RoutineInstructionEditorPresentation?

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
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
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
        // Manage one routine's instruction (T-023; design L2 §2.9). The
        // shared editor owns the draft; a successful save dismisses and
        // refreshes the cached rows, a failure leaves this sheet open with
        // the draft intact and one plain line (T-018's editor renders it).
        .sheet(item: $instructionEditor) { presentation in
            RoutineInstructionEditorSheet(
                entry: presentation.entry,
                capture: presentation.capture,
                onSaved: {
                    instructionEditor = nil
                    entriesVersion += 1
                },
                onClose: { instructionEditor = nil }
            )
        }
    }

    private func routineManageRow(_ entry: RoutineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.systemImage)
                .font(.system(size: 24)).foregroundStyle(appearance.colors.accentForeground)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle(locale: coordinator.activeLocale))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Text(routineSummaries[entry.id] ?? "")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
            }
            Spacer()
            // Photos live behind this row: the family's configuration
            // surface for a routine (photo-visual-aids task, 2026-09-16).
            Button {
                photoEditorEntry = entry
            } label: {
                Image(systemName: entry.visualAids.isEmpty ? "photo.badge.plus" : "photo.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.colors.accentForeground)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("visualAid.add"))
            // The instruction half of a routine's configuration (T-023).
            // Its own sheet and its own capture session; it never shares a
            // draft with the photo flow above, so either can be edited
            // without disturbing the other.
            Button {
                instructionEditor = RoutineInstructionEditorPresentation(
                    entry: entry,
                    capture: coordinator.instructionCaptureCoordinator(draftSession: .routines))
            } label: {
                Image(systemName: RoutineSettingsView.instructionButtonSymbol(
                    hasInstruction: RoutineSettingsView.hasInstruction(entry)))
                    .font(.system(size: 22))
                    .foregroundStyle(appearance.colors.accentForeground)
                    .frame(minWidth: RoutineSettingsView.instructionTapTarget,
                           minHeight: RoutineSettingsView.instructionTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.str(
                RoutineSettingsView.instructionButtonKey(
                    hasInstruction: RoutineSettingsView.hasInstruction(entry)),
                locale: locale)))
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
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// IF-1 reused without a second definition: the row's label is the
    /// model's answer to "is there something to render", never a store
    /// read (design L2 §3.4.1, §4.10).
    private static func hasInstruction(_ entry: RoutineEntry) -> Bool {
        entry.instruction?.isPresent == true
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

    // MARK: - Pure seams (T-023; pinned by RoutineSettingsInstructionTests)

    /// The instruction row's catalogue key (design L2 §10.5 rows 2–3): the
    /// action the person can take now, not the stored state's name.
    static func instructionButtonKey(hasInstruction: Bool) -> String {
        hasInstruction ? "instruction.change" : "instruction.add"
    }

    /// A quote/text bubble either way; filled once an instruction exists, so
    /// the row reads as a state and not by colour alone (design §10.1).
    static func instructionButtonSymbol(hasInstruction: Bool) -> String {
        hasInstruction ? "text.bubble.fill" : "text.bubble"
    }

    /// The row control's tap floor (design §10.1: 44×44 pt).
    static let instructionTapTarget: CGFloat = DesignTokens.minTapTargetSize

    /// What one save attempt means for the sheet. Success dismisses and
    /// refreshes the cached rows; every typed failure maps through
    /// `InstructionMessageKey` to EXACTLY ONE plain catalogue key and leaves
    /// the sheet — and the draft it holds — open (§11.3, T-023). The reducer
    /// carries no draft, so a failure cannot clear or reseed it.
    enum SaveOutcome: Equatable {
        case dismissAndRefresh
        case showFailure(String)
    }

    static func saveOutcome(_ result: Result<Void, InstructionWriteError>) -> SaveOutcome {
        switch result {
        case .success:
            return .dismissAndRefresh
        case .failure(let error):
            return .showFailure(InstructionMessageKey.forWrite(error))
        }
    }

    /// One instruction-editor sheet session: the entry as it was when the
    /// row was tapped plus the ONE capture coordinator that session owns
    /// (T-023; design L2 §2.9). Held in `@State`, so re-rendering the
    /// settings list can neither recreate the coordinator nor lose the
    /// draft; dismissing and reopening the sheet starts a fresh session.
    struct RoutineInstructionEditorPresentation: Identifiable {
        let entry: RoutineEntry
        let capture: InstructionVideoCaptureCoordinator

        var id: UUID { entry.id }
    }
}

// MARK: - Routine instruction sheet (T-023; design L2 §2.9, §4.2, §11.3)

/// C09 — the routine settings instruction sheet.
///
/// It is the routine-specific half of the shared editor: one draft seeded
/// from the entry's stored instruction, one save-failure key, one pick-image
/// completion and one write path. Every authored value, control and copy line
/// belongs to T-018's `InstructionEditorView`; this type adds no second
/// editor.
///
/// The capture coordinator arrives in `RoutineInstructionEditorPresentation`
/// — one per sheet session, created by the row's tap — so no re-render builds
/// another. Saving calls ONLY `coordinator.saveRoutineInstruction(_:entryId:)`;
/// success dismisses and refreshes through `onSaved`, a typed failure shows
/// one plain line through T-018's `saveFailureKey` and leaves the draft
/// untouched. Cancelling calls `onClose` and never the save seam; the
/// editor's own cancel/`onDisappear` tears the capture session down.
///
/// It holds no scheduler, video store, file manager or second coordinator,
/// and no Settings deep link, photo-library permission path, share sheet or
/// second visual-aid editor exists here (§11.3 M/O/Q). Its only picker is the
/// app's existing out-of-process, permission-free `VisualAidPhotoPicker`.
struct RoutineInstructionEditorSheet: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    /// The entry the sheet opened with; its id is all the save seam needs.
    let entry: RoutineEntry
    /// The ONE capture coordinator this sheet session owns.
    let capture: InstructionVideoCaptureCoordinator
    let onSaved: () -> Void
    let onClose: () -> Void

    /// The editor's whole state. Seeded once from the stored instruction
    /// (design §4.2) and owned here; a failure never reseeds it.
    @State private var draft: InstructionDraft
    /// The one plain line a failed write shows; nil shows no line.
    @State private var saveFailureKey: String?
    /// The picker's pending completion (`UIImage?`; nil means cancelled).
    /// At most one is held and it is cleared the moment it is used.
    @State private var pendingImageCompletion: ((UIImage?) -> Void)?
    @State private var isPickingImage = false

    init(entry: RoutineEntry,
         capture: InstructionVideoCaptureCoordinator,
         onSaved: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.entry = entry
        self.capture = capture
        self.onSaved = onSaved
        self.onClose = onClose
        _draft = State(initialValue: InstructionDraft.loaded(instruction: entry.instruction))
    }

    var body: some View {
        InstructionEditorView(
            draft: $draft,
            capture: capture,
            saveFailureKey: saveFailureKey,
            pickImage: pickImage,
            onSave: save,
            onCancel: onClose
        )
        // The shipping permission-free picker, presented exactly as the
        // photo flow presents it (out of process, no permission prompt).
        // One image only; the editor decides whether the resulting bytes
        // resolve the draft, and Save stays closed until they do.
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

    /// The only write path: one resolved commit through the coordinator's
    /// single routine seam. Success dismisses and refreshes the cached rows;
    /// a typed failure shows its one plain line and keeps the sheet open
    /// with the draft intact — no retry, no alert, no second write.
    private func save(_ commit: InstructionCommit) {
        switch RoutineSettingsView.saveOutcome(
            coordinator.saveRoutineInstruction(commit, entryId: entry.id)) {
        case .dismissAndRefresh:
            onSaved()
        case .showFailure(let key):
            saveFailureKey = key
        }
    }
}
