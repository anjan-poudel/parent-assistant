import Foundation

// MARK: - Voice personalization settings model
//
// [VOICE-SETTINGS] The view-model layer behind the Settings →
// "Voice personalization" screen: two persisted A/B toggles (noise
// filter, accent biasing) and the voice-fingerprint enroll/status/clear
// flow. Everything here is free of audio and view types so the logic is
// unit-testable with fakes (see VoiceSettingsModelTests); the SwiftUI
// presentation lives in App/VoiceSettingsView.swift.
//
// Honesty contract (constitution): every claim the screen makes about
// battery, privacy, and what a toggle actually does is carried by the
// copy in Localizable.xcstrings — no silent claims, no green dots for
// features that are not wired.

// MARK: - Noise filter toggle (seam to AppCoordinator)

/// Read/write seam for the noise-filter A/B toggle. `AppCoordinator`
/// conforms: its `@Published noiseFilterEnabled` persists the
/// UserDefaults key AND hot-swaps the pipeline's `NoiseSuppressor`
/// (the side effect this model must never duplicate — one writer).
protocol NoiseFilterPreferenceControlling: AnyObject {
    var noiseFilterEnabled: Bool { get set }
}

/// The toggle state + persistence owner the Voice personalization screen
/// binds to. Accent biasing persists through `DialectBiasSettings`
/// (UserDefaults, injected for hermetic tests); the noise toggle writes
/// through the injected controller so the coordinator's hot-swap fires.
@MainActor
final class VoiceSettingsModel: ObservableObject {

    /// Persisted through the coordinator (UserDefaults "noiseFilterEnabled",
    /// default OFF) — `didSet` here only forwards; the coordinator owns
    /// persistence and the pipeline hot-swap.
    @Published var noiseFilterEnabled: Bool {
        didSet {
            guard noiseFilterEnabled != oldValue else { return }
            noiseFilterController.noiseFilterEnabled = noiseFilterEnabled
        }
    }

    /// Persisted under "dialectBiasEnabled" (default ON — the toggle is
    /// an inspection/escape hatch, not an opt-in gate).
    @Published var accentBiasEnabled: Bool {
        didSet {
            guard accentBiasEnabled != oldValue else { return }
            DialectBiasSettings.setEnabled(accentBiasEnabled, defaults: defaults)
        }
    }

    /// [WARM-START] Persisted through the coordinator (UserDefaults
    /// "warmStartEngines", default ON — see AppCoordinator.warmStartEnabled):
    /// the boot's warm phase preloads the speech + reply-voice models so
    /// the first conversation starts fast. Warm runs only during boot, so
    /// a flip applies from the next launch (the card's copy says so).
    @Published var warmStartEnabled: Bool {
        didSet {
            guard warmStartEnabled != oldValue else { return }
            warmStartController.warmStartEnabled = warmStartEnabled
        }
    }

/// [TURN-TIMING] Persisted under "voiceTimingDebug" (default OFF) —
    /// diagnostics-only: shows a per-stage timing caption under the
    /// assistant's reply in the conversation transcript. One writer =
    /// this model; `AppCoordinator` reads the key when rendering the
    /// caption. The `voice_turn_timing` console event itself fires
    /// regardless of this toggle (remote debugging evidence).
    @Published var timingDebugEnabled: Bool {
        didSet {
            guard timingDebugEnabled != oldValue else { return }
            defaults.set(timingDebugEnabled, forKey: Self.timingDebugKey)
        }
    }

    static let timingDebugKey = "voiceTimingDebug"

    private let noiseFilterController: NoiseFilterPreferenceControlling
    private let warmStartController: WarmStartPreferenceControlling
    private let defaults: UserDefaults

    init(noiseFilterController: NoiseFilterPreferenceControlling,
         warmStartController: WarmStartPreferenceControlling,
         defaults: UserDefaults = .standard) {
        self.noiseFilterController = noiseFilterController
        self.warmStartController = warmStartController
        self.defaults = defaults
        self.noiseFilterEnabled = noiseFilterController.noiseFilterEnabled
        self.accentBiasEnabled = DialectBiasSettings.isEnabled(defaults: defaults)
        self.warmStartEnabled = warmStartController.warmStartEnabled

self.timingDebugEnabled = defaults.bool(forKey: Self.timingDebugKey)
    }
}

// MARK: - Voice fingerprint: status presentation

/// What the Voice personalization screen's fingerprint row can show,
/// flattened from `VoiceBiometricStatus` + the stored profile so the
/// view switches on one type and the mapping is pinned by tests.
enum VoiceBiometricPresentation: Equatable {
    /// Voice login disabled in this build (Null embedder).
    case disabled
    case notEnrolled
    case enrolled(utteranceCount: Int)
    /// Template exists but the current embedder cannot score it.
    case needsReenrollment
    /// Marker present, payload unreadable — re-enrollment is the only
    /// recovery (Keychain, this-device-only).
    case templateUnreadable

    static func from(status: VoiceBiometricStatus,
                     profile: EnrolledVoiceProfile?) -> VoiceBiometricPresentation {
        switch status {
        case .disabled:
            return .disabled
        case .notEnrolled:
            return .notEnrolled
        case .enrolled:
            return .enrolled(utteranceCount: profile?.utteranceCount ?? 0)
        case .needsReenrollment:
            return .needsReenrollment
        case .templateUnreadable:
            return .templateUnreadable
        }
    }
}

// MARK: - Enrollment service seam

/// The slice of `SpeakerBiometricService` the enrollment flow needs —
/// declared so the state machine runs against a fake in tests.
protocol VoiceEnrollmentServicing: AnyObject {
    var isEnabled: Bool { get }
    var currentEmbedderID: String { get }
    func loadProfile() -> Result<EnrolledVoiceProfile?, StorageError>
    func clearProfile() -> Result<Void, StorageError>
    func enroll(samples: [[Int16]], sampleRate: Double) async
        -> Result<EnrolledVoiceProfile, EnrollmentError>
}

/// The production service already implements every requirement
/// (isEnabled / currentEmbedderID / loadProfile / clearProfile /
/// enroll) — the Settings seam its header points at.
extension SpeakerBiometricService: VoiceEnrollmentServicing {}

// MARK: - Sample capture seam

enum VoiceSampleCaptureError: Error, Equatable {
    case microphonePermissionDenied
    /// No input route — the recorder refuses to touch `inputNode`
    /// (AudioToolbox _ReportRPCTimeout abort guard, 2026-09-02).
    case noAudioInput
    case audioUnavailable
}

/// One press-to-record enrollment sample: 16 kHz int16 mono PCM, the
/// pipeline's capture format. Production is `VoiceEnrollmentRecorder`;
/// the state machine only ever sees this seam.
protocol VoiceSampleRecorder: AnyObject {
    /// Requests mic permission, activates the session, installs the tap
    /// and starts the engine. Completion runs on the main queue.
    func startCapture() async throws
    /// Tears the capture down and returns the recorded samples.
    func stopCapture() -> [Int16]
}

/// Suspends/resumes the always-on voice pipeline around a leaf capture.
/// `AppCoordinator` conforms with the same cycle as
/// `startSearchPhraseCapture` (coordinator stop → the only tap →
/// coordinator start): the pipeline's tap and the enrollment tap share
/// one audio engine, so they must never run at the same time.
protocol VoicePipelineSuspending: AnyObject {
    /// Returns false when the assistant is busy (mid-turn / mid-reply)
    /// and the capture must not start.
    func suspendForSampleCapture() -> Bool
    func resumeAfterSampleCapture()
}

// MARK: - Enrollment flow state machine

/// Press-to-record enrollment of N samples (3 minimum — the service's
/// policy). The flow: record samples one at a time; once N exist the
/// service's `enroll` runs every gate (quality + same-speaker
/// consistency, doc §7.4); on a per-sample refusal the offending sample
/// is dropped and the user re-records it. The old template is untouched
/// until a full fresh session passes (the service's own rule).
@MainActor
final class VoiceEnrollmentSession: ObservableObject {

    enum Phase: Equatable {
        /// Nothing in flight. `collectedCount` samples are banked.
        case idle
        /// Recording the next sample (index = `collectedCount`).
        case recording(sampleIndex: Int)
        /// The final `enroll` call is running.
        case processing
        /// Enrollment completed; the new template is persisted.
        case ready(EnrolledVoiceProfile)
        /// Terminal until the user acts again (record or dismiss).
        case failed(VoiceEnrollmentFailure)
    }

    enum VoiceEnrollmentFailure: Equatable {
        /// The assistant was mid-turn/mid-reply — transient; try again.
        case assistantBusy
        case microphonePermissionDenied
        case noAudioInput
        case audioUnavailable
        /// The sample at `sampleIndex` (0-based) failed a quality gate;
        /// it was dropped, so re-record one sample.
        case sampleQualityFailed(sampleIndex: Int, issue: UtteranceQuality.Issue)
        /// The sample at `sampleIndex` scored below the same-speaker
        /// consistency floor; dropped, re-record one sample.
        case sampleInconsistent(sampleIndex: Int)
        /// Voice login disabled in this build.
        case serviceDisabled
        /// The Keychain write failed — nothing was claimed.
        case saveFailed
        case processingFailed
    }

    /// The service's own enrollment minimum (3).
    static let requiredSampleCount = SpeakerBiometricService.minimumEnrollmentSamples

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var biometricStatus: VoiceBiometricStatus = .notEnrolled

    private let service: VoiceEnrollmentServicing
    private let recorder: VoiceSampleRecorder
    private weak var pipelineSuspender: VoicePipelineSuspending?
    private var collected: [[Int16]] = []
    private var enrolledProfile: EnrolledVoiceProfile?

    init(service: VoiceEnrollmentServicing,
         recorder: VoiceSampleRecorder,
         pipelineSuspender: VoicePipelineSuspending? = nil) {
        self.service = service
        self.recorder = recorder
        self.pipelineSuspender = pipelineSuspender
        refreshStatus()
    }

    /// Samples banked so far (drives the "Sample 1 of 3" line).
    var collectedCount: Int { collected.count }

    /// UI state flattened from status + profile; the mapping under test.
    var biometricPresentation: VoiceBiometricPresentation {
        VoiceBiometricPresentation.from(status: biometricStatus,
                                        profile: enrolledProfile)
    }

    /// Re-derives the honest status from the service's own facts
    /// (enabled + profile load + current embedder id) — the same inputs
    /// the future owner-only paths will score against.
    func refreshStatus() {
        let load = service.loadProfile()
        if case .success(.some(let profile)) = load {
            enrolledProfile = profile
        } else if case .success(nil) = load {
            enrolledProfile = nil
        }
        biometricStatus = VoiceBiometricStatusResolver.status(
            enabled: service.isEnabled,
            profileLoad: load,
            currentEmbedderID: service.currentEmbedderID)
    }

    /// "Remove voice" — idempotent (the service clears both keys and
    /// succeeds when nothing is enrolled).
    func clearProfile() {
        _ = service.clearProfile()
        collected = []
        enrolledProfile = nil
        phase = .idle
        refreshStatus()
    }

    /// Press-to-record: suspend the pipeline, activate the mic, start
    /// capturing. Re-recordable from `.failed` (the intent to try again
    /// is the act itself).
    func startRecording() async {
        guard phase == .idle || phase.isFailed else { return }
        guard pipelineSuspender?.suspendForSampleCapture() ?? true else {
            phase = .failed(.assistantBusy)
            return
        }
        do {
            try await recorder.startCapture()
            phase = .recording(sampleIndex: collected.count)
        } catch let error as VoiceSampleCaptureError {
            pipelineSuspender?.resumeAfterSampleCapture()
            phase = .failed(Self.failure(for: error))
        } catch {
            pipelineSuspender?.resumeAfterSampleCapture()
            phase = .failed(.audioUnavailable)
        }
    }

    /// Second press: tear the capture down, bank the sample, and — once
    /// the minimum is reached — run the service's enrollment gates.
    func stopRecording() async {
        guard case .recording = phase else { return }
        let pcm = recorder.stopCapture()
        pipelineSuspender?.resumeAfterSampleCapture()
        collected.append(pcm)
        if collected.count >= Self.requiredSampleCount {
            await runEnrollment()
        } else {
            phase = .idle
        }
    }

    /// Leaves a `.failed` state without recording (the "Got it" path).
    func dismissFailure() {
        guard phase.isFailed else { return }
        phase = .idle
    }

    // MARK: - Enrollment execution

    private func runEnrollment() async {
        phase = .processing
        switch await service.enroll(samples: collected, sampleRate: 16_000) {
        case .success(let profile):
            collected = []
            enrolledProfile = profile
            phase = .ready(profile)
            refreshStatus()
        case .failure(.qualityGateFailed(let index, let issue)):
            dropSample(at: index)
            phase = .failed(.sampleQualityFailed(sampleIndex: index, issue: issue))
        case .failure(.inconsistentSample(let index)):
            dropSample(at: index)
            phase = .failed(.sampleInconsistent(sampleIndex: index))
        case .failure(.disabled):
            phase = .failed(.serviceDisabled)
        case .failure(.persistenceFailed):
            phase = .failed(.saveFailed)
        case .failure(.tooFewSamples), .failure(.embeddingFailed):
            phase = .failed(.processingFailed)
        }
    }

    /// Removes the refused sample so the next recording replaces it; the
    /// banked good samples are kept (order-independent centroid).
    private func dropSample(at index: Int) {
        guard collected.indices.contains(index) else { return }
        collected.remove(at: index)
    }

    private static func failure(for error: VoiceSampleCaptureError) -> VoiceEnrollmentFailure {
        switch error {
        case .microphonePermissionDenied: return .microphonePermissionDenied
        case .noAudioInput: return .noAudioInput
        case .audioUnavailable: return .audioUnavailable
        }
    }
}

private extension VoiceEnrollmentSession.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
