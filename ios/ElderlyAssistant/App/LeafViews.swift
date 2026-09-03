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

// MARK: - Reminders (सम्झना) — spec §4.3

struct RemindersView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "reminders.title") {
            if todaysReminders.isEmpty {
                emptyState(key: "reminders.empty")
            } else {
                VStack(spacing: 12) {
                    ForEach(todaysReminders) { reminder in
                        HStack(spacing: 12) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 24))
                                .foregroundColor(DesignTokens.accent)
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

/// Face/initial avatar + name, with a real tap-to-dial action — no list
/// picker in between (redesign spec §3.1 "one face, one tap").
struct ContactTile: View {
    let contact: FamilyContact
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
            Button(action: call) {
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

    private func call() {
        guard let url = PhoneDialer.url(for: contact.phone) else { return }
        UIApplication.shared.open(url)
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
