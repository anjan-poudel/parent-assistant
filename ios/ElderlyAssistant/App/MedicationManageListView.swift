import SwiftUI

/// [T-023] Settings → Medications: the MANAGE screen (owner-directed,
/// amendment 6).
///
/// The owner's first device report — "the Settings medication UI always
/// shows the add-new-medication form and never shows existing schedules" —
/// was the shipped leaf's layout itself: one inline form was the whole
/// screen, and the entry rows sat above it in the same `VStack` while the
/// form dominated the viewport. This screen inverts the composition:
///
///  - the household's existing schedules are the SCREEN — one row per
///    entry, each stating the medicine's name, its dose line, its time of
///    day (slot + meal context, or the stored clock times for a legacy
///    entry) and its purpose caption;
///  - an explicit add control (`settings.meds.add`) opens the new-entry
///    form — the form is NEVER what Settings → Medications shows on
///    arrival (the arrival is the list, or the honest empty card);
///  - tapping a row opens the SAME form pre-filled through the shipped
///    T-018 conversion (`MedicationScheduleSettingsView.draft(from:)` +
///    `editingEntryId` — a call into the shipped seams, never a rebuilt
///    copy), so saving edits that entry rather than creating a duplicate;
///  - the Medicine-times card and its one-shot retime note (T-020) stay
///    REACHABLE ON THIS SCREEN — the card is rendered inside this leaf,
///    not buried one presentation down inside the editor;
///  - a saved entry is visible IMMEDIATELY, without a relaunch: the
///    coordinator's `medicationScheduleRevision` (a `@Published` counter
///    bumped on the committed-write seam) is read in this screen's body
///    path, so the list's own answer to "what is scheduled" re-draws the
///    moment a save, an edit, a removal or a voice reminder lands.
///
/// Nothing here writes: the coordinator is the one writer, and every
/// failure it reports is surfaced as a line (the shipped failed-save key)
/// — a failed delete leaves the row (and its photos and evidence) exactly
/// as it was, and says so.
///
/// Floors (NFR-MSR-005, FR-MSR-021): every interactive element carries the
/// 44pt tap target (`DesignTokens.minTapTargetSize`), and every
/// user-visible line draws through the appearance typography tokens (the
/// 18pt floor by construction). The style follows the shipped medication
/// leaf: token fonts, `appSurface` cards, `LeafScreen` chrome.
struct MedicationManageListView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    /// The editor's presentation target — `nil` on arrival and at every
    /// moment except between an explicit tap and the editor's dismissal.
    /// No `onAppear`, no task, no body expression ever populates it, so
    /// the add form cannot be the screen the family arrives at.
    @State private var editorTarget: EditorTarget?

    /// The medication whose photos are being managed (medication-visual-
    /// aids task, 2026-09-16) — held as the full entry so the sheet renders
    /// without a store read of its own.
    @State private var photoEditorEntry: MedicationEntry?

    /// The last failure the coordinator reported for an action taken on
    /// THIS screen (a refused delete) — a catalog key, rendered in the
    /// active locale. The editor's own failures stay on the editor's own
    /// error line.
    @State private var errorKey: String?

    /// The presentation value for the editor cover: WHICH entry the form
    /// was opened for (`nil` = the new-entry form). A fresh identity per
    /// presentation, so two taps on the same row present twice.
    private struct EditorTarget: Identifiable {
        let id = UUID()
        let entry: MedicationEntry?
    }

    var body: some View {
        LeafScreen(titleKey: "settings.meds.title") {
            VStack(spacing: 12) {
                if listEntries.isEmpty {
                    // The shipped empty message, exactly: "No medications
                    // scheduled yet". The add control below is the way
                    // out — the form never opens itself.
                    Text("settings.meds.empty")
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
                } else {
                    ForEach(listEntries) { entry in
                        row(entry)
                    }
                }
                if let errorKey {
                    Text(LocalizedStringKey(errorKey))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                        .multilineTextAlignment(.center)
                }
                addControl
                // [MED-SLOT] (T-020) The household's OWN times, reachable
                // on the MANAGE screen — the family may set its times
                // before the first medicine exists, and the one-shot
                // retime note (m-5) renders here too. The card is drawn
                // by the shipped leaf struct's `.medicineTimesCard` arm,
                // so its words, keys and reads stay the ones the shipped
                // suite pins.
                MedicationScheduleSettingsView(screen: .medicineTimesCard)
            }
        }
        .fullScreenCover(item: $editorTarget) { target in
            editor(for: target)
        }
        // A medicine's photos, edited by the family (medication-visual-aids
        // task, 2026-09-16) — the SAME editor the routine reminders use,
        // with the medication photo store instead of the routine one.
        // Edits persist as they happen, so dismissal only has to close the
        // sheet; the list re-draws off the coordinator's revision when a
        // photo save lands.
        .sheet(item: $photoEditorEntry) { entry in
            ReminderVisualAidEditorView(
                entryId: entry.id,
                title: entry.medicationName,
                aids: entry.visualAids,
                store: coordinator.medicationVisualAidStore,
                locale: coordinator.activeLocale,
                onSave: { aids in
                    coordinator.setMedicationVisualAids(entry.id, aids: aids)
                },
                onClose: { photoEditorEntry = nil }
            )
        }
    }

    /// The list's content, read against the EXPLICIT redraw signal.
    ///
    /// `coordinator.medicationEntries` is computed over the scheduler, so
    /// it holds no observable state of its own: without this read the
    /// screen would depend on incidental `@Published` churn (a dose-count
    /// refresh that happens to change, a calendar sync) to notice that a
    /// save landed — which is exactly the "it just disappeared"
    /// (display-half) defect. `medicationScheduleRevision` is bumped on
    /// every COMMITTED medication write and nothing else, so the list's
    /// dependency is the schedule itself.
    private var listEntries: [MedicationEntry] {
        _ = coordinator.medicationScheduleRevision
        return coordinator.medicationEntries
    }

    // MARK: - Rows

    /// One schedule's row: the tap door (the entry's own text, as the
    /// button's label) plus the shipped photo and delete controls, which
    /// keep living here — this screen is where the family configures a
    /// medicine, so it is where the medicine's picture and its removal
    /// belong.
    private func row(_ entry: MedicationEntry) -> some View {
        let lines = Self.rowLines(for: entry, locale: coordinator.activeLocale)
        return HStack(spacing: 12) {
            // A Button rather than a tap gesture, so VoiceOver announces
            // a control; the button's label is the row's own text, so
            // nothing new is said.
            Button {
                editorTarget = EditorTarget(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lines.name)
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    if let doseLine = lines.doseLine {
                        Text(doseLine)
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                    if !lines.whenLine.isEmpty {
                        Text(lines.whenLine)
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                    if let purpose = lines.purpose {
                        Text(purpose)
                            .font(.system(size: appearance.typography.captionPointSize))
                            .foregroundStyle(appearance.colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
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
            // A refused REMOVAL is loud and complete: on a failed persist
            // the coordinator removes nothing (the entry, its alarms, its
            // photos and its evidence all stay), and the failure line
            // below the list says so instead of a row that silently
            // snaps back.
            Button(role: .destructive) {
                if !coordinator.removeMedication(id: entry.id) {
                    errorKey = "settings.meds.saveFailed"
                }
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22)).foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("settings.meds.delete"))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    /// The explicit add control — the ONLY way to the new-entry form from
    /// this screen. Deliberately the shipped `settings.meds.add` label the
    /// editor's own reset already uses: one phrase for one act.
    private var addControl: some View {
        Button {
            editorTarget = EditorTarget(entry: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                Text("settings.meds.add")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
            }.foregroundStyle(appearance.colors.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize + 12)
            .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
    }

    // MARK: - The editor presentation

    /// The presented editor — the shipped form, in the mode the target
    /// names. Both arms hand the SAME `onSaveLanded` closure, so a landed
    /// save dismisses the cover and a failed one leaves it up (the
    /// editor's own error line carries the failure; the list re-draws
    /// off the revision bump the committed write fired).
    @ViewBuilder
    private func editor(for target: EditorTarget) -> some View {
        if let entry = target.entry {
            MedicationScheduleSettingsView(editing: entry,
                                           locale: coordinator.activeLocale,
                                           onSaveLanded: { editorTarget = nil })
        } else {
            MedicationScheduleSettingsView(onSaveLanded: { editorTarget = nil })
        }
    }

    // MARK: - The row's pure seams ([T-023]; the T-018 statics idiom)

    /// One row's four lines, resolved once per draw.
    struct RowLines: Equatable {
        /// The medicine's name — always drawn.
        let name: String
        /// The composed dose line (C2), or nil when there is nothing to
        /// draw (an entry with a blank dose line draws no dose line).
        let doseLine: String?
        /// The "when" line: slot + meal context for a slot entry, the
        /// stored clock times for a legacy one. Empty only for an entry
        /// whose stored times yield no text.
        let whenLine: String
        /// The purpose caption, or nil when the entry files no purpose.
        let purpose: String?
    }

    /// The row's composition, as one pure function — the view-testable
    /// seam this screen's named test drives without a renderer.
    static func rowLines(for entry: MedicationEntry, locale: Locale) -> RowLines {
        RowLines(name: entry.medicationName,
                 doseLine: doseLineText(for: entry, locale: locale),
                 whenLine: whenLine(for: entry, locale: locale),
                 purpose: MedicationPurpose.label(forStored: entry.purpose, locale: locale))
    }

    /// The dose line the row draws.
    ///
    /// For an entry whose stored line is exactly the C2 composition of its
    /// own structured quantity and a text half in the caller's locale
    /// (the T-018 `doseTextHalf` recognition — the shipped seam, a CALL),
    /// the line is drawn through `DoseLine.compose`, the one documented
    /// composition: the recomposition is provably the stored line, and
    /// composing it here keeps this row on the same single composer as
    /// the save path instead of a second string assembly.
    ///
    /// Every other line — a legacy entry's, a foreign one, a line whose
    /// halves do not align — renders EXACTLY as stored, verbatim, trimmed
    /// only for the emptiness test. Nothing is re-composed from prose:
    /// rule 3 of the composer re-saves such a line unchanged, and this
    /// row shows the family the same words.
    static func doseLineText(for entry: MedicationEntry, locale: Locale) -> String? {
        if let textHalf = MedicationScheduleSettingsView.doseTextHalf(of: entry, locale: locale) {
            let composed = DoseLine.compose(quantity: entry.quantity,
                                            doseText: textHalf, locale: locale)
            return composed.isEmpty ? nil : composed
        }
        let stored = entry.doseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? nil : stored
    }

    /// The "when" line: the shipped statics do the naming — the slot and
    /// meal keys through `MedicationScheduleSettingsView.slotKey/mealKey`
    /// (the ONE mapping, the same keys the editor's chips and context
    /// line resolve through), and a legacy entry's stored clock times
    /// through `MedicationScheduleSettingsView.timesText` — exactly as
    /// shipped, no mapping consulted, no mirror drawn (D2).
    static func whenLine(for entry: MedicationEntry, locale: Locale) -> String {
        guard let slot = entry.slot else {
            return MedicationScheduleSettingsView.timesText(entry.scheduleTimes)
        }
        var parts = [L10n.str(MedicationScheduleSettingsView.slotKey(for: slot), locale: locale)]
        if let meal = entry.mealRelation {
            parts.append(L10n.str(MedicationScheduleSettingsView.mealKey(for: meal), locale: locale))
        }
        return parts.joined(separator: " · ")
    }
}
