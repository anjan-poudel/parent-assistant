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
    /// What the medicine is for ([MED-PURPOSE], 2026-09-17) — folded into
    /// the screen's title with `medicationName` ("रक्तचापको औषधि —
    /// अम्लोडिपिन") when the family filed one, absent otherwise.
    let purpose: String?
    /// Why this screen is up. `.dose` is a fired reminder (prompt + "I took
    /// it"); `.identify` is the elder's own voice question about what a
    /// medicine looks like, where neither belongs.
    let mode: MedicationVisualAidsPresentation.Mode
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

    /// The screen's title: the purpose line and the name ("रक्तचापको औषधि —
    /// अम्लोडिपिन") when the family filed a purpose, the bare name
    /// otherwise — so a household that uses no purposes sees exactly the
    /// screen it saw before this feature.
    private var title: String {
        MedicationVisualAidsPresentation.caption(medicationName: medicationName,
                                                 purpose: purpose,
                                                 locale: locale)
    }

    var body: some View {
        ReminderVisualAidScreen(
            entryId: entryId,
            title: title,
            aids: aids,
            store: store,
            locale: locale,
            onClose: onClose
        ) {
            footer
        }
    }

    /// The dose-only half of the screen. The identify mode shows the photo
    /// and its title and nothing else: a "time to take your medicine" with
    /// an active "I took it" at a moment when nothing is due invites a dose
    /// that was never scheduled, and the double-dose detector would then
    /// block the real one.
    @ViewBuilder
    private var footer: some View {
        if mode == .dose {
            doseFooter
        }
    }

    private var doseFooter: some View {
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
    /// Why the photo is on screen — the one thing the screen's ACTION row
    /// depends on, so it rides the presentation rather than a second
    /// published flag that could disagree with the photo being shown.
    enum Mode: String, Equatable {
        /// A scheduled dose fired: the screen carries the dose prompt and
        /// the elder's "I took it".
        case dose
        /// The elder ASKED what the medicine looks like ([MED-PHOTO],
        /// 2026-09-17). Nothing is due, so the screen is the photo and its
        /// caption only.
        case identify
    }

    let entryId: UUID
    let medicationName: String
    let doseDescription: String
    /// The purpose the family filed this medicine under — a chip id or
    /// their own words, shown and spoken through `caption(locale:)`. nil
    /// (or blank) leaves the caption as the bare name.
    var purpose: String?
    let mode: Mode
    let aids: [VisualAid]

    /// `fullScreenCover(item:)` keys on this. The identity is the ENTRY
    /// *and the reason the screen is up*: a re-fire of the same dose
    /// presents again (same id, the documented behaviour), while a voice
    /// "what does it look like?" for a medicine whose DOSE screen is
    /// already up is a different presentation — one carries the
    /// acknowledge action, the other must not, and a cover that swallowed
    /// the swap would leave the wrong one on screen.
    var id: String { "\(entryId.uuidString)-\(mode.rawValue)" }

    init(entryId: UUID, medicationName: String, doseDescription: String,
         purpose: String? = nil, aids: [VisualAid], mode: Mode = .dose) {
        self.entryId = entryId
        self.medicationName = medicationName
        self.doseDescription = doseDescription
        self.purpose = purpose
        self.aids = aids
        self.mode = mode
    }

    /// Snapshots a live entry's purpose, name, dose line and photos.
    /// Callers take the snapshot when they DECIDE to present, never when
    /// they draw: an entry edited while the screen is up must not silently
    /// swap the dose the elder is looking at.
    init(entry: MedicationEntry, mode: Mode = .dose) {
        self.init(entryId: entry.id,
                  medicationName: entry.medicationName,
                  doseDescription: entry.doseDescription,
                  purpose: entry.purpose,
                  aids: entry.visualAids,
                  mode: mode)
    }

    /// The line the photo carries: the purpose and the name
    /// ("रक्तचापको औषधि — अम्लोडिपिन") when the family filed a purpose,
    /// the bare name otherwise. ONE composition for both surfaces — the
    /// dose that fires and the voice query — so the elder is told the same
    /// thing about the same medicine however the screen appeared.
    static func caption(medicationName: String, purpose: String?,
                        locale: Locale) -> String {
        guard let label = MedicationPurpose.label(forStored: purpose, locale: locale) else {
            return medicationName
        }
        return "\(L10n.fmt("meds.purposeCaption", locale: locale, label)) — \(medicationName)"
    }

    func caption(locale: Locale) -> String {
        Self.caption(medicationName: medicationName, purpose: purpose, locale: locale)
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
                    purpose: fired.purpose,
                    mode: fired.mode,
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
