import Foundation
import AVFoundation
import BackgroundTasks
import Combine

/// Central coordinator that wires all services together.
/// Starts safety-critical services first (medication scheduler, health monitor),
/// then voice pipeline, then LLM.
final class AppCoordinator: ObservableObject {
    @Published var isInitialized = false
    @Published var voiceState: VoicePipeline.State = .stopped
    @Published var voiceError: String?
    @Published var activeSTTName: String = "SFSpeechRecognizer (English fallback)"
    @Published var lastTranscript: String?
    /// While non-nil, a confirmation challenge is awaiting the user's
    /// yes/no follow-up. Set by `startVoiceAckConfirmation` and cleared by
    /// `handleConfirmationResponse`. Voice router uses this to route the
    /// next transcript as a confirmation answer instead of a new command.
    @Published var pendingConfirmationEntryId: UUID?

    private let storage: EncryptedLocalStorage
    private let observabilityBus: ObservabilityBus
    private let medicationScheduler: MedicationScheduler
    private let alarmScheduler: PlatformAlarmScheduler
    private let familyNotifier: APNsFamilyNotifier

    // Voice
    private let audioEngine: AVAudioEngine
    private let audioSessionManager: AudioSessionManager
    private let wakeWordEngine: WakeWordEngine
    private let voiceActivityDetector: VoiceActivityDetector
    private var voicePipeline: VoicePipeline!
    private var voiceStateCancellable: AnyCancellable?
    private var whisperSwapCancellable: AnyCancellable?

    // Model store — exposed to ContentView for the first-run download UI.
    let modelStore: ModelStore
    let modelDownloadService: ModelDownloadService
    private let whisperSpeechRecognizer: WhisperSpeechRecognizer
    private let fallbackSpeechRecognizer: OnDeviceSpeechRecognizer

    /// The IDs the first-run flow will download by default. Order matters —
    /// STT unlocks the whole Nepali path so it goes first.
    let requiredModelIds: [ModelID] = [
        ModelCatalog.whisperLargeV3Nepali,
        ModelCatalog.whisperSmallMultilingual,
        ModelCatalog.llama3_2_1B,
        ModelCatalog.piperNepali
    ]

    init() {
        // Core infrastructure. Storage uses the Keychain (Data Protection class
        // Complete, per constitution §Security). Observability goes through the
        // log sanitiser so no PII leaks into device logs.
        let bus = ConsoleObservabilityBus(sanitiser: LogSanitiser())
        self.storage = KeychainEncryptedStorage()
        self.observabilityBus = bus
        self.alarmScheduler = UNNotificationScheduler()
        self.familyNotifier = APNsFamilyNotifier(
            contacts: [],
            apnsProvider: APNsProvider()
        )

        // Safety-critical service (no LLM dependency)
        self.medicationScheduler = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarmScheduler,
            observabilityBus: bus,
            familyNotifier: familyNotifier
        )

        // Model store + download service. First-run UI drives downloads
        // via `modelDownloadService`; the coordinator watches state changes
        // and hot-swaps Whisper into the voice pipeline when its model is
        // ready.
        do {
            self.modelStore = try ModelStore(observabilityBus: bus)
        } catch {
            fatalError("Cannot initialise ModelStore: \(error)")
        }
        self.modelDownloadService = ModelDownloadService(
            store: modelStore,
            observabilityBus: bus
        )

        // Voice pipeline. Uses NullWakeWordEngine unless the Porcupine SPM
        // package is present AND a valid access key / .ppn file are found —
        // see Services/Voice/WakeWordEngine.swift for the enablement steps.
        self.audioEngine = AVAudioEngine()
        self.audioSessionManager = AudioSessionManager(observabilityBus: bus)
        self.wakeWordEngine = Self.makeWakeWordEngine()
        self.voiceActivityDetector = EnergyVAD()
        // Two STTs are constructed up-front:
        // - fallback (SFSpeechRecognizer, en-US) — used while Whisper is
        //   downloading; owns its input tap.
        // - Whisper — used once its model is cached; push mode + VAD-gated.
        self.fallbackSpeechRecognizer = OnDeviceSpeechRecognizer(
            audioEngine: audioEngine,
            observabilityBus: bus
        )
        self.whisperSpeechRecognizer = WhisperSpeechRecognizer(
            modelStore: modelStore,
            observabilityBus: bus
        )
    }

    func start() {
        // Register background tasks (iOS)
        registerBackgroundTasks()

        // Restore and re-arm any outstanding medication reminders
        medicationScheduler.scheduleAll()

        // Voice pipeline is built lazily here so the CommandRouter can hold a
        // weak ref back to this fully-initialised coordinator.
        let systemSpeaker = SystemSpeechSpeaker(observabilityBus: observabilityBus)
        // PiperVoiceSpeaker is a Phase-4 stub — it just delegates to system
        // TTS today. Wired here so upstream code lives against the same
        // `Speaker` type it will use in production.
        let speaker: Speaker = PiperVoiceSpeaker(
            fallback: systemSpeaker,
            observabilityBus: observabilityBus
        )
        // LLM interpreter. `isAvailable` stays false until (a) the model is
        // cached, (b) the llama.cpp SPM package is linked. Router treats
        // that as "fall through to keyword matching".
        let interpreter = LlamaCommandInterpreter(
            modelStore: modelStore,
            observabilityBus: observabilityBus
        )
        let router = CommandRouter(
            coordinator: self,
            observabilityBus: observabilityBus,
            speaker: speaker,
            interpreter: interpreter,
            replyLocale: Locale(identifier: "ne-NP")
        )
        // Start with the fallback STT. Whisper is swapped in below when
        // (a) its model is cached AND (b) the whisper runtime is linked.
        voicePipeline = VoicePipeline(
            audioSession: audioSessionManager,
            audioEngine: audioEngine,
            wakeWordEngine: wakeWordEngine,
            speechRecognizer: fallbackSpeechRecognizer,
            voiceActivityDetector: voiceActivityDetector,
            router: router,
            observabilityBus: observabilityBus
        )
        voiceStateCancellable = voicePipeline.$state
            .receive(on: DispatchQueue.main)
            .assign(to: \.voiceState, on: self)
        voicePipeline.onSTTError = { [weak self] msg in
            self?.lastTranscript = "⚠️ \(msg)"
        }
        voicePipeline.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
                self.trySwapToWhisper()  // one-shot at startup
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
            }
        }

        // Hot-swap trigger: whenever the whisper model transitions to
        // "completed" via ModelDownloadService, retry the swap.
        whisperSwapCancellable = modelDownloadService.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                guard let self else { return }
                if states[ModelCatalog.whisperLargeV3Nepali] == .completed ||
                   states[ModelCatalog.whisperSmallMultilingual] == .completed {
                    self.trySwapToWhisper()
                }
            }

        isInitialized = true
        print("[AppCoordinator] Elderly AI Assistant started")
    }

    /// Attempts to move the pipeline off the SFSpeechRecognizer fallback
    /// onto WhisperSpeechRecognizer. Idempotent.
    private func trySwapToWhisper() {
        guard whisperSpeechRecognizer.isAvailable else { return }
        voicePipeline?.setSpeechRecognizer(whisperSpeechRecognizer)
        DispatchQueue.main.async { [weak self] in
            if self?.modelStore.isCached(ModelCatalog.whisperLargeV3Nepali) == true {
                self?.activeSTTName = "Whisper (Nepali large v3)"
            } else {
                self?.activeSTTName = "Whisper (multilingual fallback)"
            }
        }
    }

    /// Called by CommandRouter with the raw transcript so ContentView can
    /// display it. Avoids depending on the TTS/notification path for
    /// visible feedback.
    func recordTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastTranscript = text
        }
    }

    // MARK: - Public API for voice commands

    /// BASELINE ack, used for non-dementia flows and as an explicit fallback.
    /// Voice path should use `startVoiceAckConfirmation` instead so that
    /// FR-D01 (challenge) and FR-D03 (double-dose check) actually run.
    func handleMedicationAcknowledgement(entryId: UUID) {
        _ = medicationScheduler.acknowledge(entryId: entryId, at: Date())
    }

    func handleMedicationConfirmation(entryId: UUID, response: ConfirmationResponse) {
        _ = medicationScheduler.acknowledgeWithConfirmation(
            entryId: entryId,
            at: Date(),
            confirmationResponse: response
        )
    }

    /// Dementia-aware voice ack: issues the FR-D01 confirmation challenge
    /// for `entryId`, returns the prompt the assistant should speak, and
    /// stores `pendingConfirmationEntryId` so the next voice input routes
    /// to `handleConfirmationResponse`.
    ///
    /// Returns nil if the challenge could not start (e.g. entry not
    /// pending). Callers should fall back to `handleMedicationAcknowledgement`.
    func startVoiceAckConfirmation(for entryId: UUID) -> String? {
        guard let prompt = medicationScheduler.startConfirmationChallenge(for: entryId) else {
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingConfirmationEntryId = entryId
        }
        return prompt
    }

    /// User's yes/no follow-up to a pending confirmation challenge.
    /// Routes through the scheduler's dementia path so the double-dose
    /// check fires and the log is written with `confirmationPassed`
    /// reflecting reality.
    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        guard let entryId = pendingConfirmationEntryId else { return }
        _ = medicationScheduler.acknowledgeWithConfirmation(
            entryId: entryId,
            at: Date(),
            confirmationResponse: response
        )
        DispatchQueue.main.async { [weak self] in
            self?.pendingConfirmationEntryId = nil
        }
    }

    /// Whether a confirmation follow-up is currently expected.
    var isAwaitingConfirmation: Bool { pendingConfirmationEntryId != nil }

    /// Used by `CommandRouter` to identify what "I took my medication" refers
    /// to when the user hasn't specified which reminder.
    func oldestPendingReminderEntryId() -> UUID? {
        medicationScheduler.pendingReminders
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .first?
            .medicationEntryId
    }

    /// Called by the debug button in `ContentView` to test the pipeline
    /// end-to-end without a trained wake-word model.
    func simulateWakeWordDetection() {
        voicePipeline?.simulateWakeWordDetection()
    }

    // MARK: - Background tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.elderlyassistant.medication.check",
            using: nil
        ) { [weak self] task in
            self?.medicationScheduler.scheduleAll()
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Wake-word engine selection

    private static func makeWakeWordEngine() -> WakeWordEngine {
        #if canImport(Porcupine)
        // Look for the Picovoice access key + trained .ppn. If either is
        // missing, fall back to the null engine so the app still boots.
        if let accessKey = Bundle.main.object(forInfoDictionaryKey: "PicovoiceAccessKey") as? String,
           !accessKey.isEmpty,
           let keywordPath = Bundle.main.path(forResource: "hey-sahayak_ios", ofType: "ppn"),
           let engine = try? PorcupineWakeWordEngine(accessKey: accessKey, keywordPath: keywordPath) {
            return engine
        }
        print("[AppCoordinator] Porcupine present but access key or .ppn missing — using NullWakeWordEngine")
        #endif
        return NullWakeWordEngine()
    }
}

extension AppCoordinator: VoiceCommandCoordinating {}

// MARK: - ConsoleObservabilityBus (routes every event through LogSanitiser)

final class ConsoleObservabilityBus: ObservabilityBus {
    private let sanitiser: LogSanitiser

    init(sanitiser: LogSanitiser = LogSanitiser()) {
        self.sanitiser = sanitiser
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func emit(_ event: ObservabilityEvent) {
        let clean = sanitiser.sanitise(event)
        let err = clean.errorCode.map { " errorCode=\($0)" } ?? ""
        let ts = Self.logFormatter.string(from: Date())
        print("[\(ts)][\(clean.component)] \(clean.eventType) outcome=\(clean.outcome)\(err) metadata=\(clean.metadata)")
    }
}
