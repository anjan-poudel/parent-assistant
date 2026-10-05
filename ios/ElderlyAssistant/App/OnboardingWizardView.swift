import SwiftUI
import AVFoundation
import UserNotifications

/// First-run onboarding (spec §4.2): seven steps (profile-interview
/// T-102 inserted the three interview steps after permissions), EVERY
/// step skippable — no hard gate anywhere, though About-you gates its OWN
/// Next button while name/address-as are missing (FR-PI-002, soft-skip
/// preserved through the shell's Skip). Skipped steps surface as a Home
/// reminder card.
///
/// भाषा → अनुमति → तपाईंको बारेमा → परिवारको सम्पर्क → आपत्कालीन सम्पर्क
/// → तपाईंको आवाज → तयारी
///
/// The wizard runs before voice engages: `coordinator.start()` is only
/// called on the final "घर जानुहोस्" (or by Home once onboarding is seen).
struct OnboardingWizardView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    /// First step to show — defaults to the first pending step (Home
    /// reminder-card reopen path).
    var startingAt: OnboardingState.Step? = nil

    @State private var stepIndex: Int

    init(startingAt: OnboardingState.Step? = nil) {
        self.startingAt = startingAt
        _stepIndex = State(initialValue: OnboardingState.Step.allCases.firstIndex(
            of: startingAt ?? .language) ?? 0)
    }

    private var steps: [OnboardingState.Step] { OnboardingState.Step.allCases }
    private var currentStep: OnboardingState.Step { steps[stepIndex] }

    var body: some View {
        ZStack {
            VoiceBridgeBackground(theme: coordinator.appTheme)
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                stepContent
                Spacer(minLength: 0)
                progressDots
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header (skip top-right, back top-left)

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .card, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            Spacer(minLength: 8)
            Button(action: skipCurrentStep) {
                Text("onboarding.skip")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .language: LanguageStep(onNext: advanceAfterCompleting)
        case .permissions: PermissionsStep(onNext: advanceAfterCompleting)
        // [PROFILE-INTERVIEW T-099/T-100/T-101] The three interview steps
        // (bodies in ProfileInterviewSteps.swift). About-you saves through
        // the coordinator's single writer; emergency-contacts designates
        // kin at tap and saves GP/hospital on Next; voice fingerprint runs
        // the existing enrollment session and always allows Next.
        case .aboutYou: AboutYouStep(onNext: advanceAfterCompleting)
        case .familyContact: FamilyContactStep(onNext: advanceAfterCompleting)
        case .emergencyContacts: EmergencyContactsStep(onNext: advanceAfterCompleting)
        case .voiceFingerprint: VoiceFingerprintStep(coordinator: coordinator,
                                                     onNext: advanceAfterCompleting)
        case .models: ModelsStep(onFinish: finishOnboarding)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == stepIndex ? appearance.colors.accent : appearance.colors.textSecondary.opacity(0.35))
                    .frame(width: index == stepIndex ? 14 : 10,
                           height: index == stepIndex ? 14 : 10)
            }
        }
        .padding(.vertical, 12)
        .accessibilityHidden(true)
    }

    // MARK: - Navigation

    private func advanceAfterCompleting(_ step: OnboardingState.Step) {
        coordinator.onboardingState.markCompleted(step)
        advance()
    }

    private func skipCurrentStep() {
        coordinator.onboardingState.markSkipped(currentStep)
        advance()
    }

    private func advance() {
        if stepIndex < steps.count - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { stepIndex += 1 }
        } else {
            finishOnboarding()
        }
    }

    private func goBack() {
        if stepIndex > 0 {
            withAnimation(.easeInOut(duration: 0.2)) { stepIndex -= 1 }
        } else {
            dismiss()
        }
    }

    private func finishOnboarding() {
        coordinator.onboardingState.markCompleted(.models)
        coordinator.onboardingState.finish()
        // Spec §4.2: voice engages only after the wizard has been run
        // through. `start()` is idempotent.
        coordinator.start()
        dismiss()
    }
}

// MARK: - Step 1: Language

private struct LanguageStep: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    let onNext: (OnboardingState.Step) -> Void

    @State private var selection: AppLanguage = .nepali

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepLanguage.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepLanguage.body")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    languageCard(language)
                }
            }
            primaryButton(key: "onboarding.next", typography: appearance.typography) {
                coordinator.appLanguage = selection
                onNext(.language)
            }
        }
    }

    private func languageCard(_ language: AppLanguage) -> some View {
        let isSelected = language == selection
        return Button {
            selection = language
        } label: {
            HStack {
                Text(LocalizedStringKey(language.displayNameKey))
                    .font(.system(size: appearance.typography.scaled(22), weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(appearance.colors.accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    @Environment(\.appAppearance) private var appearance
    let onNext: (OnboardingState.Step) -> Void

    @State private var micStatus: PermissionStatus = .notAsked
    @State private var notifStatus: PermissionStatus = .notAsked

    enum PermissionStatus {
        case notAsked, granted, denied
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepPermissions.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 16) {
                permissionCard(
                    icon: "mic.fill",
                    bodyKey: "onboarding.stepPermissions.micBody",
                    status: micStatus,
                    action: requestMic
                )
                permissionCard(
                    icon: "bell.badge.fill",
                    bodyKey: "onboarding.stepPermissions.notifBody",
                    status: notifStatus,
                    action: requestNotifications
                )
            }
            primaryButton(key: "onboarding.next", typography: appearance.typography) {
                onNext(.permissions)
            }
        }
        .onAppear(perform: refreshPermissionStatuses)
    }

    private func permissionCard(icon: String, bodyKey: String,
                                status: PermissionStatus,
                                action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(appearance.colors.accent)
                Text(LocalizedStringKey(bodyKey))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            switch status {
            case .notAsked:
                Button(action: action) {
                    Text("onboarding.stepPermissions.allow")
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.chipHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
                }
                .buttonStyle(.plain)
            case .granted:
                Label("model.ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                    .foregroundStyle(appearance.colors.accent)
            case .denied:
                Text("onboarding.stepPermissions.deniedHint")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(DesignTokens.stateError)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
    }

    private func requestMic() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                micStatus = granted ? .granted : .denied
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                notifStatus = granted ? .granted : .denied
            }
        }
    }

    private func refreshPermissionStatuses() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: micStatus = .granted
        case .denied: micStatus = .denied
        default: micStatus = .notAsked
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    notifStatus = .granted
                case .denied:
                    notifStatus = .denied
                default:
                    notifStatus = .notAsked
                }
            }
        }
    }
}

// MARK: - Step 3: Family & friends (skippable — no hard gate)
//
// (family-and-friends task, 2026-09-07) Comment/step-name refresh: the
// collected person is now framed as the start of the curated "Family
// and friends" list (spec §4.4.2), which the Settings editor grows to
// `FamilyContactStore.maxContacts`.

private struct FamilyContactStep: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    let onNext: (OnboardingState.Step) -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""
    @State private var messengerHandle = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepFamily.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepFamily.body")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                field(placeholderKey: "onboarding.stepFamily.name", text: $name)
                field(placeholderKey: "onboarding.stepFamily.phone", text: $phone)
                    .keyboardType(.phonePad)
                field(placeholderKey: "onboarding.stepFamily.relationship", text: $relationship)
                field(placeholderKey: "onboarding.stepFamily.messenger", text: $messengerHandle)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("onboarding.stepFamily.messengerHint")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            // [PROFILE-INTERVIEW T-100] The store's contacts, read-only —
            // a confirmation of who is already in the list (or the empty
            // copy when the list is still empty). Writes stay unchanged:
            // only the form above adds.
            VStack(alignment: .leading, spacing: 8) {
                if coordinator.familyContacts.isEmpty {
                    Text("settings.family.empty")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                } else {
                    ForEach(coordinator.familyContacts) { contact in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(appearance.colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(.system(size: DesignTokens.minBodyPointSize,
                                                  weight: .semibold))
                                    .foregroundStyle(appearance.colors.textPrimary)
                                if !contact.relationship.isEmpty {
                                    Text(contact.relationship)
                                        .font(.system(size: DesignTokens.minCaptionPointSize))
                                        .foregroundStyle(appearance.colors.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 14) {
                primaryButton(key: "onboarding.stepFamily.save", typography: appearance.typography) {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        let handle = messengerHandle.trimmingCharacters(in: .whitespacesAndNewlines)
                        coordinator.addFamilyContact(
                            name: name,
                            phone: phone,
                            relationship: relationship,
                            messengerHandle: handle.isEmpty ? nil : handle
                        )
                    }
                    onNext(.familyContact)
                }
                Text("onboarding.stepFamily.laterNote")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func field(placeholderKey: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(placeholderKey), text: text)
            .font(.system(size: appearance.typography.bodyPointSize))
            .padding(16)
            .frame(minHeight: 60)
            .fixedSize(horizontal: false, vertical: true)
            .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
    }
}

// MARK: - Step 4: Gemini API key (v2 pivot — replaces the v1 model-download
// step; see docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md)

private struct ModelsStep: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator
    let onFinish: () -> Void

    @State private var draftKey: String = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepModels.title")
                    .font(DesignTokens.greetingFont(size: appearance.typography.titlePointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepModels.body")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("settings.gemini.fieldLabel")
                    .font(.system(size: appearance.typography.captionPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textSecondary)
                SecureField("settings.gemini.fieldPlaceholder", text: $draftKey)
                    .font(.system(size: appearance.typography.bodyPointSize, design: .monospaced))
                    .padding(14)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .appSurface(role: .control, cornerRadius: DesignTokens.bubbleCornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                            .stroke(appearance.colors.textSecondary.opacity(0.25), lineWidth: 1)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if coordinator.geminiConfigStore.isConfigured {
                    Label("settings.gemini.statusConnected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                        .foregroundStyle(appearance.colors.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)

            primaryButton(key: "onboarding.stepModels.goHome", typography: appearance.typography) {
                if !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    coordinator.geminiConfigStore.save(draftKey)
                }
                onFinish()
            }
        }
    }
}

// MARK: - Shared pieces

/// Big primary button used across the wizard — ≥60pt tall (spec §4.2).
/// Internal (not private) since T-099/100/101: the interview steps in
/// ProfileInterviewSteps.swift share it, so every step's Next/Save is
/// the same button.
func primaryButton(key: String, typography: AppTypography, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(LocalizedStringKey(key))
            .font(.system(size: typography.scaled(22), weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .fixedSize(horizontal: false, vertical: true).appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
    }
    .buttonStyle(.plain)
}
