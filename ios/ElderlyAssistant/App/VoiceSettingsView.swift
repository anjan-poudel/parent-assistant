import SwiftUI
import UIKit
import AVFoundation

// MARK: - Voice personalization ([VOICE-SETTINGS])
//
// Settings leaf for the three recently-shipped voice features: the noise
// filter A/B toggle, the accent-biasing toggle, and the voice-fingerprint
// enroll/status/clear surface. Everything the screen claims is carried by
// `voiceSettings.*` copy in Localizable.xcstrings (en + ne) — honest
// about experimental status, defaults, battery, and on-device handling.
//
// State logic lives in `VoiceSettingsModel` / `VoiceEnrollmentSession`
// (Services/Voice/VoiceSettingsModel.swift, unit-tested); this file only
// maps state to cards, colors, and keys — the same split the Wake Word
// screen uses with `WakeWordStatusResolver`.

/// Status colors + labels shared by this screen's banner and failure
/// lines. The mapping under test is `VoiceBiometricPresentation`
/// (VoiceSettingsModelTests); only presentation lives here.
extension VoiceBiometricPresentation {
    var statusColor: Color {
        switch self {
        case .enrolled: return DesignTokens.accent
        case .needsReenrollment, .templateUnreadable: return DesignTokens.stateListening
        case .disabled: return DesignTokens.stateStopped
        case .notEnrolled: return DesignTokens.textSecondary
        }
    }

    var statusTitleKey: String {
        switch self {
        case .enrolled: return "voiceSettings.biometric.status.enrolled"
        case .needsReenrollment: return "voiceSettings.biometric.status.needsReenrollment"
        case .templateUnreadable: return "voiceSettings.biometric.status.unreadable"
        case .disabled: return "voiceSettings.biometric.status.disabled"
        case .notEnrolled: return "voiceSettings.biometric.status.notEnrolled"
        }
    }

    var statusDetailKey: String? {
        switch self {
        case .enrolled: return nil // count-aware detail, see the view
        case .needsReenrollment: return "voiceSettings.biometric.status.needsReenrollment.detail"
        case .templateUnreadable: return "voiceSettings.biometric.status.unreadable.detail"
        case .disabled: return "voiceSettings.biometric.status.disabled.detail"
        case .notEnrolled: return "voiceSettings.biometric.status.notEnrolled.detail"
        }
    }
}

struct VoicePersonalizationSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings: VoiceSettingsModel
    @StateObject private var enrollment: VoiceEnrollmentSession

    /// Whether the enrollment panel is expanded (tapped "Enroll voice").
    @State private var enrollFlowVisible = false
    @State private var showClearConfirm = false

    /// Mic permission, read at the point of use (never on appear).
    private enum MicAccess {
        case unknown, granted, notDetermined, denied
    }
    @State private var micAccess: MicAccess = .unknown

    init(coordinator: AppCoordinator) {
        // Screen-local production service: MFCC embedder (the shipped
        // frontend) + Keychain-backed template store. No bus — the
        // service's own events still flow wherever its owner provides
        // one; status here is derived, not logged.
        let service = SpeakerBiometricService(
            embedder: SpeakerEmbedderSelection.make(),
            store: .makeKeychainBacked())
        _settings = StateObject(wrappedValue:
            VoiceSettingsModel(noiseFilterController: coordinator,
                               warmStartController: coordinator))
        _enrollment = StateObject(wrappedValue: VoiceEnrollmentSession(
            service: service,
            recorder: coordinator.makeEnrollmentSampleRecorder(),
            pipelineSuspender: coordinator))
    }

    var body: some View {
        LeafScreen(titleKey: "voiceSettings.title") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("voiceSettings.explanation")
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)

                    noiseFilterCard
                    accentBiasCard
                    warmStartCard
                    timingDebugCard
                    biometricSection

                    Text("voiceSettings.privacy")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            refreshMicAccess()
            enrollment.refreshStatus()
        }
        .onChange(of: scenePhase) { phase in
            // Returning from the system Settings app after the "Open
            // Settings" card is the denial → grant path; re-check then.
            if phase == .active {
                refreshMicAccess()
            }
        }
        .onDisappear {
            // Backing out mid-recording must not leave the pipeline
            // suspended or the mic tap installed — stopRecording is a
            // no-op unless a sample is actually being recorded.
            Task { await enrollment.stopRecording() }
        }
        .confirmationDialog("voiceSettings.biometric.removeConfirm",
                            isPresented: $showClearConfirm) {
            Button("voiceSettings.biometric.remove", role: .destructive) {
                enrollment.clearProfile()
            }
            Button("common.back", role: .cancel) {}
        }
    }

    // MARK: - Noise filter (experimental, default OFF)

    private var noiseFilterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.noiseFilterEnabled) {
                Text("voiceSettings.noise.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("voiceSettings.noise.caption")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Accent biasing (default ON)

    private var accentBiasCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.accentBiasEnabled) {
                Text("voiceSettings.accent.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("voiceSettings.accent.caption")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Warm start (default ON)

    private var warmStartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.warmStartEnabled) {
                Text("voiceSettings.warmStart.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("voiceSettings.warmStart.caption")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var timingDebugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.timingDebugEnabled) {
                Text("voiceSettings.timing.title")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            .tint(DesignTokens.accent)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Text("voiceSettings.timing.caption")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Voice fingerprint: status + enroll + clear

    private var biometricSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("voiceSettings.biometric.title")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .padding(.top, 8)

            statusCard

            if enrollment.biometricPresentation == .disabled {
                // Nothing to enroll in this build — no dead button.
            } else if !enrollFlowVisible {
                Button {
                    enrollFlowVisible = true
                } label: {
                    Text("voiceSettings.biometric.enrollButton")
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
            } else {
                enrollPanel
            }

            if case .enrolled = enrollment.biometricPresentation {
                removeVoiceRow
            }

            Text("voiceSettings.biometric.privacy")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
            Text("voiceSettings.biometric.battery")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
        }
    }

    private var statusCard: some View {
        let presentation = enrollment.biometricPresentation
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(presentation.statusColor)
                    .frame(width: 12, height: 12)
                Text(LocalizedStringKey(presentation.statusTitleKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            if case .enrolled(let count) = presentation {
                Text(L10n.fmt("voiceSettings.biometric.status.enrolled.detail",
                              locale: coordinator.activeLocale, count))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            } else if let detailKey = presentation.statusDetailKey {
                Text(LocalizedStringKey(detailKey))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Enrollment panel (press-to-record, 3 samples)

    private var enrollPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The progress line means "sample N of M"; after the flow is
            // done it would claim "1 of 3" — hidden so completion reads
            // as completion, not as a reset flow.
            if case .ready = enrollment.phase {
                EmptyView()
            } else {
                Text(L10n.fmt("voiceSettings.biometric.enroll.progress",
                              locale: coordinator.activeLocale,
                              sampleNumber, VoiceEnrollmentSession.requiredSampleCount))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
            }

            switch enrollment.phase {
            case .recording:
                Text("voiceSettings.biometric.enroll.recordingHint")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.stateListening)
            case .processing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("voiceSettings.biometric.enroll.processing")
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            case .failed(let failure):
                failureLine(failure)
            case .idle:
                Text("voiceSettings.biometric.enroll.hint")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            case .ready:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        // Caption-token status glyph (DESIGN-REVIEW): 18pt
                        // floor and Dynamic Type aware, like the label it
                        // sits beside — was a fixed 16pt.
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.accent)
                    Text("voiceSettings.biometric.enroll.done")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            }

            recordButton

            switch micAccess {
            case .notDetermined:
                askMicCard
            case .denied:
                blockedMicCard
            case .unknown, .granted:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// 1-based number of the sample being recorded next (or the one just
    /// banked while `.idle`).
    private var sampleNumber: Int {
        switch enrollment.phase {
        case .recording:
            return enrollment.collectedCount + 1
        case .idle, .processing, .failed, .ready:
            return min(enrollment.collectedCount + 1,
                       VoiceEnrollmentSession.requiredSampleCount)
        }
    }

    private var recordButton: some View {
        let isRecording: Bool
        let isProcessing: Bool
        let isComplete: Bool
        switch enrollment.phase {
        case .recording: isRecording = true; isProcessing = false; isComplete = false
        case .processing: isRecording = false; isProcessing = true; isComplete = false
        case .idle, .failed: isRecording = false; isProcessing = false; isComplete = false
        // After completion the record button would be a dead press
        // (startRecording guards on .idle/.failed) — it becomes Close;
        // the status card and Remove row now tell the truth.
        case .ready: isRecording = false; isProcessing = false; isComplete = true
        }
        return Button {
            if isComplete { enrollFlowVisible = false } else { recordPressed() }
        } label: {
            Text(LocalizedStringKey(isComplete ? "common.close"
                                    : isRecording
                                        ? "voiceSettings.biometric.enroll.stop"
                                        : "voiceSettings.biometric.enroll.record"))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(isRecording ? DesignTokens.stateError : DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
    }

    /// Press-to-record: recording → stop; else start (mic permission is
    /// asked at the point of use, behind the plain-language card).
    private func recordPressed() {
        if case .recording = enrollment.phase {
            Task { await enrollment.stopRecording() }
            return
        }
        switch micAccess {
        case .granted:
            Task { await enrollment.startRecording() }
        case .notDetermined:
            // First tap reveals the ask card; its Allow button triggers
            // the system prompt (the constitution's ask-first pattern).
            break
        case .denied:
            break
        case .unknown:
            refreshMicAccess()
        }
    }

    private func grantMicAndRecord() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            micAccess = granted ? .granted : .denied
            if granted {
                Task { await enrollment.startRecording() }
            }
        }
    }

    private func refreshMicAccess() {
        // iOS 17 renamed the API AND its permission enum type, so the
        // two switch blocks cannot share one variable (LeafViews'
        // direct-comparison pattern, spelled out here).
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: micAccess = .granted
            case .denied: micAccess = .denied
            case .undetermined: micAccess = .notDetermined
            @unknown default: micAccess = .notDetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: micAccess = .granted
            case .denied: micAccess = .denied
            case .undetermined: micAccess = .notDetermined
            @unknown default: micAccess = .notDetermined
            }
        }
    }

    // MARK: - Failure / permission cards

    private func failureLine(_ failure: VoiceEnrollmentSession.VoiceEnrollmentFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                // Caption-token failure glyph (DESIGN-REVIEW) — was 16pt.
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.stateError)
            Text(failureText(failure))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Resolved failure copy; sample numbers are 1-based for people.
    /// Resolution goes through `L10n.str`/`fmt` so the catalog lookup
    /// honors the app language (the String-variable `Text` init renders
    /// the result verbatim, never as a key).
    private func failureText(_ failure: VoiceEnrollmentSession.VoiceEnrollmentFailure) -> String {
        switch failure {
        case .assistantBusy:
            return L10n.str("voiceSettings.biometric.enroll.failed.busy",
                            locale: coordinator.activeLocale)
        case .microphonePermissionDenied:
            return L10n.str("voiceSettings.biometric.enroll.failed.micDenied",
                            locale: coordinator.activeLocale)
        case .noAudioInput:
            return L10n.str("voiceSettings.biometric.enroll.failed.noInput",
                            locale: coordinator.activeLocale)
        case .audioUnavailable:
            return L10n.str("voiceSettings.biometric.enroll.failed.audioUnavailable",
                            locale: coordinator.activeLocale)
        case .sampleQualityFailed(let index, let issue):
            let sample = index + 1
            switch issue {
            case .speechTooShort:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.speechTooShort",
                                locale: coordinator.activeLocale, sample)
            case .tooNoisy:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.tooNoisy",
                                locale: coordinator.activeLocale, sample)
            case .tooQuiet:
                return L10n.fmt("voiceSettings.biometric.enroll.failed.tooQuiet",
                                locale: coordinator.activeLocale, sample)
            case .none:
                return L10n.str("voiceSettings.biometric.enroll.failed.processing",
                                locale: coordinator.activeLocale)
            }
        case .sampleInconsistent(let index):
            return L10n.fmt("voiceSettings.biometric.enroll.failed.inconsistent",
                            locale: coordinator.activeLocale, index + 1)
        case .serviceDisabled:
            return L10n.str("voiceSettings.biometric.enroll.failed.disabled",
                            locale: coordinator.activeLocale)
        case .saveFailed:
            return L10n.str("voiceSettings.biometric.enroll.failed.save",
                            locale: coordinator.activeLocale)
        case .processingFailed:
            return L10n.str("voiceSettings.biometric.enroll.failed.processing",
                            locale: coordinator.activeLocale)
        }
    }

    /// The one point-of-use mic ask — plain-language card first, the
    /// system prompt only after the user taps Allow (constitution).
    private var askMicCard: some View {
        VStack(spacing: 12) {
            Text("voiceSettings.mic.askTitle")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("voiceSettings.mic.askBody")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                grantMicAndRecord()
            } label: {
                Text("voiceSettings.mic.allow")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Denied: the honest blocked line — only the system Settings screen
    /// can lift it, so the card points there (and the session stays
    /// safely idle).
    private var blockedMicCard: some View {
        VStack(spacing: 12) {
            Text("voiceSettings.mic.deniedTitle")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("voiceSettings.mic.deniedBody")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("call.search.openSettings")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    // MARK: - Remove voice

    private var removeVoiceRow: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Text("voiceSettings.biometric.remove")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.stateError)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}
