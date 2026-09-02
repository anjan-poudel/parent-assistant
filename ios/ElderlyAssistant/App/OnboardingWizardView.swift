import SwiftUI
import AVFoundation
import UserNotifications

/// First-run onboarding (spec §4.2): four steps, EVERY step skippable —
/// no hard gate anywhere. Skipped steps surface as a Home reminder card.
///
/// भाषा → अनुमति → परिवारको सम्पर्क → तयारी
///
/// The wizard runs before voice engages: `coordinator.start()` is only
/// called on the final "घर जानुहोस्" (or by Home once onboarding is seen).
struct OnboardingWizardView: View {
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
            DesignTokens.background.ignoresSafeArea()
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
        HStack {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .frame(width: DesignTokens.minTapTargetSize,
                           height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.card)
                    .clipShape(Circle())
            }
            Spacer()
            Button(action: skipCurrentStep) {
                Text("onboarding.skip")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: DesignTokens.minTapTargetSize)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .language: LanguageStep(onNext: advanceAfterCompleting)
        case .permissions: PermissionsStep(onNext: advanceAfterCompleting)
        case .familyContact: FamilyContactStep(onNext: advanceAfterCompleting)
        case .models: ModelsStep(onFinish: finishOnboarding)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == stepIndex ? DesignTokens.accent : DesignTokens.textSecondary.opacity(0.35))
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
    @EnvironmentObject var coordinator: AppCoordinator
    let onNext: (OnboardingState.Step) -> Void

    @State private var selection: AppLanguage = .nepali

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepLanguage.title")
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepLanguage.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    languageCard(language)
                }
            }
            primaryButton(key: "onboarding.next") {
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
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? DesignTokens.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
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
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
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
            primaryButton(key: "onboarding.next") {
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
                    .foregroundColor(DesignTokens.accent)
                Text(LocalizedStringKey(bodyKey))
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            switch status {
            case .notAsked:
                Button(action: action) {
                    Text("onboarding.stepPermissions.allow")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: DesignTokens.chipHeight)
                        .background(DesignTokens.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
            case .granted:
                Label("model.ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
            case .denied:
                Text("onboarding.stepPermissions.deniedHint")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.stateError)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
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

// MARK: - Step 3: Family contact (skippable — no hard gate)

private struct FamilyContactStep: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let onNext: (OnboardingState.Step) -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepFamily.title")
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepFamily.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                field(placeholderKey: "onboarding.stepFamily.name", text: $name)
                field(placeholderKey: "onboarding.stepFamily.phone", text: $phone)
                    .keyboardType(.phonePad)
                field(placeholderKey: "onboarding.stepFamily.relationship", text: $relationship)
            }
            VStack(spacing: 14) {
                primaryButton(key: "onboarding.stepFamily.save") {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        coordinator.addFamilyContact(
                            name: name,
                            phone: phone,
                            relationship: relationship
                        )
                    }
                    onNext(.familyContact)
                }
                Text("onboarding.stepFamily.laterNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func field(placeholderKey: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(placeholderKey), text: text)
            .font(.system(size: DesignTokens.minBodyPointSize))
            .padding(16)
            .frame(height: 60)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }
}

// MARK: - Step 4: Models (default model only — no variant picker)

private struct ModelsStep: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let onFinish: () -> Void

    @State private var started = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("onboarding.stepModels.title")
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text("onboarding.stepModels.body")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            // Spec §4.5: default model progress only — no variant picker
            // at first run (that lives in Settings → AI मोडेल).
            VStack(spacing: 12) {
                if let entry = ModelCatalog.entry(for: ModelCatalog.whisperSmallNepali) {
                    ModelProgressRow(
                        entry: entry,
                        state: coordinator.modelDownloadService.states[ModelCatalog.whisperSmallNepali]
                            ?? (coordinator.modelStore.isCached(ModelCatalog.whisperSmallNepali)
                                ? .completed : .notStarted)
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

            primaryButton(key: "onboarding.stepModels.goHome", action: onFinish)
        }
        .onAppear {
            guard !started else { return }
            started = true
            let id = ModelCatalog.whisperSmallNepali
            let already = coordinator.modelStore.isCached(id)
                || coordinator.modelDownloadService.states[id] != nil
            if !already {
                coordinator.modelDownloadService.start(id)
            }
        }
    }
}

// MARK: - Shared pieces

private struct ModelProgressRow: View {
    @Environment(\.locale) private var locale
    let entry: ModelCatalogEntry
    let state: ModelDownloadState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName(locale: locale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            switch state {
            case .notStarted:
                Text("model.notDownloaded")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            case .queued:
                Text("model.queued")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            case .downloading(let received, let total):
                let ratio = total > 0 ? Double(received) / Double(total) : 0
                ProgressView(value: ratio)
                    .tint(DesignTokens.accent)
                Text("\(bytes(received)) / \(bytes(total))")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            case .verifying:
                Text("model.verifying")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            case .completed:
                Label("model.ready", systemImage: "checkmark.seal.fill")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
            case .failed(let reason):
                Text(L10n.fmt("model.failed", locale: locale, reason))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.stateError)
            case .cancelled:
                Text("model.cancelled")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: n)
    }
}

/// Big primary button used across the wizard — ≥60pt tall (spec §4.2).
private func primaryButton(key: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(LocalizedStringKey(key))
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(DesignTokens.accent)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .shadow(color: DesignTokens.accent.opacity(0.35), radius: 8, y: 3)
    }
    .buttonStyle(.plain)
}
