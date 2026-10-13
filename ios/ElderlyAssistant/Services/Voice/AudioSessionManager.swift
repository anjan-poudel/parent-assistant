import Foundation
import AVFoundation

/// Smallest seam for testing `AudioSessionManager` without a real audio
/// session or engine (slice C of voice-personalisation P0 — preset
/// selection must be testable with fakes; no real audio in tests).
/// The production implementation wraps `AVAudioSession` + the voice
/// pipeline's shared `AVAudioEngine`.
protocol AudioSessionControlling: AnyObject {
    /// True when an input route exists (mic available). Check this BEFORE
    /// touching `AVAudioEngine.inputNode`: when the audio server is
    /// unresponsive, accessing inputNode ABORTS the process via
    /// AudioToolbox's _ReportRPCTimeout (uncatchable — 2026-09-02).
    var isInputAvailable: Bool { get }
    /// The object interruption/route notifications post on (the shared
    /// `AVAudioSession` in production) — passed as the observer `object`.
    var notificationSource: AnyObject? { get }
    /// Requests record permission; the callback is guaranteed to run on
    /// the main queue. Uses AVAudioApplication on iOS 17+ (the renamed
    /// API) and the session's own request otherwise.
    func requestRecordPermission(_ callback: @escaping (Bool) -> Void)
    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool,
                   options: AVAudioSession.SetActiveOptions) throws
    /// Enables/disables Voice Processing I/O on the engine's input node
    /// (AVAudioIONode.setVoiceProcessingEnabled — iOS 13+; only while the
    /// engine is stopped, never in manual rendering mode). Throws when
    /// the current route/session configuration cannot do it.
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
}

enum AudioSessionControllingError: Error {
    /// No input route — the one case where the real controller refuses to
    /// touch `inputNode` (the _ReportRPCTimeout abort guard above).
    case inputUnavailable
}

/// Production `AudioSessionControlling`: forwards to the shared
/// `AVAudioSession` and the voice pipeline's single `AVAudioEngine`
/// (the same instance `VoicePipeline` installs its tap on, so the
/// node-level voice-processing flag lands on the engine that actually
/// feeds the recognizers).
private final class SystemAudioSessionController: AudioSessionControlling {

    private let session: AVAudioSession
    private let audioEngine: AVAudioEngine

    init(session: AVAudioSession, audioEngine: AVAudioEngine) {
        self.session = session
        self.audioEngine = audioEngine
    }

    var isInputAvailable: Bool { session.isInputAvailable }

    var notificationSource: AnyObject? { session }

    func requestRecordPermission(_ callback: @escaping (Bool) -> Void) {
        // iOS 17 renamed the API; support both. The main-queue hop
        // mirrors the manager's pre-seam contract.
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { callback(granted) }
            }
        } else {
            session.requestRecordPermission { granted in
                DispatchQueue.main.async { callback(granted) }
            }
        }
    }

    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool,
                   options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        // Hard repo rule (2026-09-02): never touch inputNode without the
        // input-availability check — accessing it with the audio server
        // unresponsive aborts the process.
        guard session.isInputAvailable else {
            throw AudioSessionControllingError.inputUnavailable
        }
        if enabled {
            // Research P0 recipe (docs/research-sections/noise-filter.md):
            // iOS 17+ ducking configuration — .min so concurrently played
            // audio (including the assistant's own TTS) stays loud instead
            // of being ducked like a phone call. No-op below iOS 17.
            if #available(iOS 17.0, *) {
                var configuration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
                configuration.enableAdvancedDucking = false
                configuration.duckingLevel = .min
                audioEngine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    configuration
            }
        }
        try audioEngine.inputNode.setVoiceProcessingEnabled(enabled)
    }
}

/// Owns the `AVAudioSession` configuration for always-on voice.
///
/// Configured for `.playAndRecord` with `.measurement` mode so the input tap
/// gets low-latency, minimally-processed mic audio suitable for wake-word
/// detection and speech recognition. Handles interruptions and route changes
/// (headset plug, phone call, Siri) so the pipeline resumes automatically.
///
/// Requires `audio` in `UIBackgroundModes` (already declared in Info.plist)
/// so the tap keeps running when the screen locks.
///
/// Voice-personalisation P0 (slice C, 2026-09-08): a switchable preset
/// behind the persisted `voiceProcessingEnabled` A/B toggle (default OFF).
/// When ON, activation uses Voice Processing I/O instead: `.voiceChat` mode
/// plus `AVAudioIONode.setVoiceProcessingEnabled(true)` on the shared
/// engine's input node — the only Apple lever that puts AEC + built-in
/// noise suppression below the tap (mode alone does nothing; `.measurement`
/// disables system processing by design). When OFF every call sequence,
/// event, and failure path is byte-identical to the pre-A/B behavior.
/// VPIO is phone-call-tuned (AGC/EQ, ~85-95 ms round trip, HFP-implied
/// routes) — which is exactly why this is an A/B gate, not a switch.
final class AudioSessionManager {

    enum ActivationError: Error {
        case sessionConfigurationFailed(Error)
        case activationFailed(Error)
        case microphonePermissionDenied
    }

    private let session: AudioSessionControlling
    private let observabilityBus: ObservabilityBus
    private let defaults: UserDefaults
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// A/B toggle: Voice Processing I/O preset (voice-personalisation P0,
    /// slice C). Default OFF — activation then behaves byte-identically to
    /// the pre-A/B `.measurement` config. Persisted in UserDefaults (a UI
    /// preference, not a secret — same house pattern as the coordinator's
    /// toggles); the AppCoordinator mirrors this property and re-activates
    /// the session when it changes.
    var voiceProcessingEnabled: Bool {
        didSet {
            defaults.set(voiceProcessingEnabled,
                         forKey: Self.voiceProcessingEnabledDefaultsKey)
        }
    }
    static let voiceProcessingEnabledDefaultsKey = "voiceProcessingEnabled"

    /// True once VPIO was actually enabled on the node in THIS process —
    /// an OFF activation then disables it explicitly (the node's flag
    /// survives engine stop/start), while a plain OFF-from-launch lifetime
    /// never makes an extra call (the byte-identical guarantee).
    private var voiceProcessingEnabledInProcess = false

    // MARK: - Response playback loudness ([LOUD-TTS], 2026-09-11;
    //          [LOUD-TTS-CATEGORY], 2026-10-14)
    //
    // While the assistant SPEAKS, the session switches to the BELL's
    // proven-loud configuration: category `.playback` (media-volume gain
    // staging), mode `.default`, options `[.duckOthers,
    // .defaultToSpeaker]` — byte-identical to `TimerAlarmBellPlayer`,
    // the one audio path the field calls LOUD. The original mode-only
    // switch to `.voicePrompt` did not move loudness: under
    // `.playAndRecord` the output stays on call/voice gain staging,
    // which plays far below media apps (field report 2026-10-14:
    // replies < 50 % of other apps' loudness even at max boost).
    //
    // Trade, accepted (the bell's own doc spells it out): `.playback`
    // has no input, so the mic is unavailable for the reply's duration.
    // That is acceptable — wake-word processing is suppressed while the
    // assistant speaks (AppCoordinator's wake gate), so no listening
    // feature is lost — and the capture preset (`.measurement` /
    // `.voiceChat` + VPIO) is restored IN PLACE the moment playback
    // settles, the session left active (deactivating it would strand
    // the voice pipeline's engine). Wake-latency after restore is the
    // device-validation gate for this change (STT is the invariant).
    //
    // Depth-counted, not stacked: Piper falling back to the system
    // speaker nests begin/end, and only the OUTERMOST end restores the
    // capture preset.

    private var playbackModeDepth = 0

    /// The loud playback configuration — the bell's exact config
    /// (`TimerAlarmBellPlayer`), the app's proven-loud audio path.
    private static let playbackCategory: AVAudioSession.Category = .playback
    private static let playbackMode: AVAudioSession.Mode = .default
    private static let playbackOptions: AVAudioSession.CategoryOptions =
        [.duckOthers, .defaultToSpeaker]

    func beginResponsePlayback() {
        if playbackModeDepth == 0 {
            do {
                // setCategory on an ACTIVE session throws on iOS 26
                // (NSOSStatusErrorDomain — observed on Anzaan
                // 2026-10-14, the first device field test: every begin
                // failed and replies kept call-gain staging). Activation
                // works because the session is inactive there, so cycle
                // active off → category → active on. The pipeline's
                // engine keeps running; its input resumes on the
                // reactivation (wake processing is gated during replies
                // anyway — see the MARK header).
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
                try session.setCategory(Self.playbackCategory,
                                        mode: Self.playbackMode,
                                        options: Self.playbackOptions)
                try session.setActive(true, options: [])
                emit(eventType: "audio_response_playback", outcome: "began")
            } catch {
                // Never leave the session deactivated after a partial
                // failure — the mic pipeline is the invariant.
                try? session.setActive(true, options: [])
                emit(eventType: "audio_response_playback", outcome: "failed",
                     errorCode: "\((error as NSError).domain)")
            }
        }
        playbackModeDepth += 1
    }

    func endResponsePlayback() {
        guard playbackModeDepth > 0 else { return }
        playbackModeDepth -= 1
        guard playbackModeDepth == 0 else { return }
        restoreCapturePreset()
        emit(eventType: "audio_response_playback", outcome: "restored")
    }

    /// Re-arms the active capture preset after a reply, in place — the
    /// session ends active (deactivating it would strand the voice
    /// pipeline's engine). Same active-session rule as begin: deactivate
    /// first, then configure. The VPIO branch re-runs the full
    /// activate-time sequence (category → node enable, with its honest
    /// measurement fallback) because the node's voice-processing flag is
    /// not guaranteed to survive the category round-trip.
    private func restoreCapturePreset() {
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            emit(eventType: "audio_response_playback",
                 outcome: "restore_failed",
                 errorCode: "\((error as NSError).domain)")
            return
        }
        if voiceProcessingEnabled {
            do {
                try configureVoiceProcessingPreset()
            } catch {
                // configureVoiceProcessingPreset's own fallback
                // reactivates the session; this catch is the case where
                // even its category step threw — re-arm activation.
                try? session.setActive(true, options: [.notifyOthersOnDeactivation])
                emit(eventType: "audio_response_playback",
                     outcome: "restore_failed",
                     errorCode: "\((error as NSError).domain)")
            }
            return
        }
        do {
            try session.setCategory(Self.measurementCategory,
                                    mode: Self.measurementMode,
                                    options: Self.measurementOptions)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            try? session.setActive(true, options: [.notifyOthersOnDeactivation])
            emit(eventType: "audio_response_playback",
                 outcome: "restore_failed",
                 errorCode: "\((error as NSError).domain)")
        }
    }

    /// Today's (pre-A/B) session configuration — `.measurement` mode.
    private static let measurementCategory: AVAudioSession.Category = .playAndRecord
    private static let measurementMode: AVAudioSession.Mode = .measurement
    private static let measurementOptions: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    /// The VPIO preset's session configuration: `.voiceChat` chat mode so
    /// the node-level voice processing actually engages (research: chat
    /// modes without VP enabled on the IO nodes do NOT load AEC/AGC).
    /// Same options as today plus `.defaultToSpeaker` (already present) —
    /// route/ducking side effects (A2DP loss, HFP-implied routes) are
    /// structural VPIO costs the A/B exists to measure, not to paper over.
    private static let voiceProcessingCategory: AVAudioSession.Category = .playAndRecord
    private static let voiceProcessingMode: AVAudioSession.Mode = .voiceChat
    private static let voiceProcessingOptions: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    /// Designated initializer — test seam: injects the session fake and a
    /// disposable UserDefaults suite; the production convenience
    /// initializer below supplies the real controller + `.standard`.
    init(observabilityBus: ObservabilityBus,
         audioSession: AudioSessionControlling,
         defaults: UserDefaults = .standard) {
        self.observabilityBus = observabilityBus
        self.session = audioSession
        self.defaults = defaults
        self.voiceProcessingEnabled =
            defaults.bool(forKey: Self.voiceProcessingEnabledDefaultsKey)
    }

    /// Production: wraps the shared `AVAudioSession` and the voice
    /// pipeline's engine (the engine must be the SAME instance the
    /// pipeline installs its tap on — the VP flag is per-node).
    convenience init(observabilityBus: ObservabilityBus,
                     audioEngine: AVAudioEngine,
                     defaults: UserDefaults = .standard) {
        self.init(observabilityBus: observabilityBus,
                  audioSession: SystemAudioSessionController(
                      session: AVAudioSession.sharedInstance(),
                      audioEngine: audioEngine),
                  defaults: defaults)
    }

    deinit {
        [interruptionObserver, routeChangeObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    /// True when an input route exists (mic available). Check this BEFORE
    /// touching AVAudioEngine.inputNode: when the audio server is
    /// unresponsive, accessing inputNode ABORTS the process via
    /// AudioToolbox's _ReportRPCTimeout (uncatchable — 2026-09-02).
    var isInputAvailable: Bool {
        session.isInputAvailable
    }

    /// Requests mic permission and activates the audio session. The
    /// completion runs on the main queue.
    func activate(completion: @escaping (Result<Void, ActivationError>) -> Void) {
        session.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emit(eventType: "audio_activate", outcome: "denied")
                completion(.failure(.microphonePermissionDenied))
                return
            }

            do {
                // Owns the FULL sequence (category → activation, and for
                // the VP preset the node enable + honest fallback) so the
                // error mapping below is the single legacy contract.
                try self.configureSession()
            } catch {
                self.emit(eventType: "audio_activate", outcome: "failure",
                          errorCode: "activation_failed")
                completion(.failure(.activationFailed(error)))
                return
            }

            self.subscribeToInterruptions()
            self.emit(eventType: "audio_activate", outcome: "success")
            completion(.success(()))
        }
    }

    /// Applies the active preset's full session sequence (category →
    /// activation; plus the node step and honest fallback for the VP
    /// preset). Errors thrown here are the legacy activation-failure
    /// contract; VPIO-specific failures fall back INSIDE the preset
    /// branch, never out of `activate`.
    private func configureSession() throws {
        if voiceProcessingEnabled {
            try configureVoiceProcessingPreset()
        } else {
            // OFF: byte-identical to the pre-A/B sequence — except when
            // this process enabled VPIO earlier and is now transitioning
            // off: the node flag survives engine stop/start, so drop it
            // explicitly (best-effort — the engine is stopped at every
            // activate() call site, which the API requires).
            if voiceProcessingEnabledInProcess {
                try? session.setVoiceProcessingEnabled(false)
                voiceProcessingEnabledInProcess = false
                emit(eventType: "audio_session_preset_changed",
                     outcome: "applied",
                     metadata: ["state": "off"])
            }
            try session.setCategory(Self.measurementCategory,
                                    mode: Self.measurementMode,
                                    options: Self.measurementOptions)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
        }
    }

    /// The VPIO preset. Honest fallback contract: if the route/device or
    /// session configuration cannot do VPIO, activation STILL succeeds —
    /// reconfigured to today's `.measurement` preset — and the event says
    /// so. No crash paths: the only node access is guarded by the
    /// controller's input-availability check.
    private func configureVoiceProcessingPreset() throws {
        try session.setCategory(Self.voiceProcessingCategory,
                                mode: Self.voiceProcessingMode,
                                options: Self.voiceProcessingOptions)
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
        do {
            try session.setVoiceProcessingEnabled(true)
            voiceProcessingEnabledInProcess = true
            emit(eventType: "audio_session_preset_changed", outcome: "applied",
                 metadata: ["state": "on"])
        } catch {
            // Unsupported here and now (no input route, unsupported
            // route/device, or a session config VPIO refuses). Fall back
            // to today's config and stay activated — the session works,
            // it is just unprocessed.
            voiceProcessingEnabledInProcess = false
            try? session.setVoiceProcessingEnabled(false)
            try? session.setActive(false, options: [])
            try session.setCategory(Self.measurementCategory,
                                    mode: Self.measurementMode,
                                    options: Self.measurementOptions)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            let reason: String
            if let error = error as? AudioSessionControllingError,
               case .inputUnavailable = error {
                reason = "input_unavailable"
            } else {
                reason = "enable_failed"
            }
            emit(eventType: "audio_session_vpio_unavailable",
                 outcome: "fallback",
                 metadata: ["state": "on", "reason": reason])
        }
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        emit(eventType: "audio_deactivate", outcome: "success")
    }

    // MARK: - Interruption handling

    private func subscribeToInterruptions() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session.notificationSource,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.emit(eventType: "audio_interruption_began", outcome: "info")
            case .ended:
                try? self.session.setActive(true, options: [])
                self.emit(eventType: "audio_interruption_ended", outcome: "info")
            @unknown default:
                break
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session.notificationSource,
            queue: .main
        ) { [weak self] _ in
            self?.emit(eventType: "audio_route_changed", outcome: "info")
        }
    }

    private func emit(eventType: String, outcome: String,
                      errorCode: String? = nil,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "audio_session",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}
