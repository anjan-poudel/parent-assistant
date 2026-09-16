import SwiftUI

// MARK: - Elder-facing presentation (the dose firing screen)

/// The screen a medication reminder fires into (medication-visual-aids
/// task, 2026-09-16): the box photo LARGE at the top, the medication name
/// under it, then the prompt, the dose line and one big "I took it".
///
/// Built on `ReminderVisualAidScreen` — the routine reminder's firing
/// screen — so the photo pager, its disk loading, the caption, the page
/// indicator and the escape chevron are literally the same code on both
/// surfaces. This view adds only what is medication-specific: the dose
/// text and the acknowledge action, passed through the shared screen's
/// `footer`.
///
/// The acknowledge action deliberately routes through the coordinator's
/// existing dose-confirmation path (`confirmMedicationDose`), the same one
/// the Meds leaf's "I took it" row uses: the dementia-aware challenge
/// gate (FR-D01) and the recorded acknowledgement are unchanged. This
/// screen is a presentation of the reminder, never a second way to
/// acknowledge one.
struct MedicationDoseFireScreen: View {
    /// The dose's own text: the medication name, the optional dose
    /// description the family configured, and the photos.
    let medicationName: String
    let doseDescription: String
    let aids: [VisualAid]
    let entryId: UUID
    /// The MEDICATION photo store (`AppCoordinator.medicationVisualAidStore`)
    /// — dose photos live under their own prefixed directory, never the
    /// routine store's.
    let store: VisualAidStore
    let locale: Locale
    /// The elder took the dose. The caller records it and gets this screen
    /// out of the way.
    let onAcknowledge: () -> Void
    let onClose: () -> Void

    /// The dose line, trimmed — the settings editor creates entries with no
    /// description, and an empty line must not reserve space.
    private var doseText: String {
        doseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ReminderVisualAidScreen(
            entryId: entryId,
            title: medicationName,
            aids: aids,
            store: store,
            locale: locale,
            onClose: onClose
        ) {
            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("meds.firePrompt")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !doseText.isEmpty {
                Text(doseText)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: onAcknowledge) {
                Text("meds.iTookIt")
                    .font(.system(size: DesignTokens.minBodyPointSize + 4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.minTapTargetSize + 12)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        .padding(.top, 4)
    }
}

/// One medication entry's photos and dose text, snapshotted for a
/// full-screen presentation — what the app shows when a dose FIRES with
/// photos, and equally what the Meds leaf shows when the elder taps a
/// dose's thumbnail. `Identifiable` so it can drive a
/// `fullScreenCover(item:)`, keyed by the medication entry (the same entry
/// fires again tomorrow).
struct MedicationVisualAidsPresentation: Identifiable, Equatable {
    let entryId: UUID
    let medicationName: String
    let doseDescription: String
    let aids: [VisualAid]
    var id: UUID { entryId }

    init(entryId: UUID, medicationName: String, doseDescription: String,
         aids: [VisualAid]) {
        self.entryId = entryId
        self.medicationName = medicationName
        self.doseDescription = doseDescription
        self.aids = aids
    }

    /// Snapshots a live entry's name, dose line and photos. Callers take
    /// the snapshot when they DECIDE to present, never when they draw: an
    /// entry edited while the screen is up must not silently swap the dose
    /// the elder is looking at.
    init(entry: MedicationEntry) {
        self.init(entryId: entry.id,
                  medicationName: entry.medicationName,
                  doseDescription: entry.doseDescription,
                  aids: entry.visualAids)
    }
}

/// Host for the fired-dose screen, mounted at the app root beside
/// `RoutineVisualAidOverlay` and `TimerAlarmOverlay`. Transparent while
/// nothing has fired; presents the dose screen the moment a medication
/// reminder whose entry carries photos arrives.
///
/// Only entries that carry photos ever set the presentation, so a
/// household that never adds a photo to a medication sees exactly today's
/// behaviour (banner + read-aloud).
struct MedicationVisualAidOverlay: View {
    let presentation: MedicationVisualAidsPresentation?
    let store: VisualAidStore
    let locale: Locale
    /// The elder took the dose from this screen — records it through the
    /// coordinator's existing dose path and clears the presentation.
    let onAcknowledge: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(item: Binding(
                get: { presentation },
                set: { newValue in if newValue == nil { onClose() } }
            )) { fired in
                MedicationDoseFireScreen(
                    medicationName: fired.medicationName,
                    doseDescription: fired.doseDescription,
                    aids: fired.aids,
                    entryId: fired.entryId,
                    store: store,
                    locale: locale,
                    onAcknowledge: { onAcknowledge(fired.entryId) },
                    onClose: onClose
                )
            }
    }
}
