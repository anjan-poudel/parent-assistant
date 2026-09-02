import Foundation
import AVFoundation
import BackgroundTasks
import Combine

/// Central coordinator that wires all services together.
/// Starts safety-critical services first (medication scheduler, health monitor),
/// then voice pipeline, then LLM.
///
/// UI/UX spec (docs/superpowers/specs/2026-09-02-ui-ux-and-intents-design-claude.md):
/// the coordinator is the composition root for `AppLanguage` (§3.2), the
/// `VoiceSessionState` machine (§3.3), and `OnboardingState` (§4.2).
final class AppCoordinator: ObservableObject {
    @Published var isInitialized = false
    @Published var voiceState: VoicePipeline.State = .stopped
    @Published var voiceError: String?

    /// How a voice START failure should be presented (spec §7: error
    /// surfaces are localized and say what actually happened).
    enum VoiceErrorKind {
        /// Mic/speech permission denied — show Settings guidance.
        case permission
        /// Audio session / input unavailable — transient, retry later.
        case audioUnavailable
        /// Anything else — the generic re-prompt.
        case other
    }

    var voiceErrorKind: VoiceErrorKind {
        guard let voiceError else { return .other }
        let lower = voiceError.lowercased()
        if lower.contains("denied") || lower.contains("notauthorized") {
            return .permission
        }
        if lower.contains("audio session") || lower.contains("mic tap") {
            return .audioUnavailable
        }
        return .other
    }
    /// Catalog KEY naming the active STT — resolved in the UI's locale
    /// (spec §3.2; no hardcoded English labels).
    @Published var activeSTTNameKey: String = "stt.name.sfs"

    /// Active display/spoken language (spec §3.2). Single source of truth
    /// for the `.locale` injected at the app root; persisted in UserDefaults.
    /// On change, the user-facing strings built by non-View services
    /// (notifications, spoken challenges, family alerts) follow along.
    @Published var appLanguage: AppLanguage {
        didSet {
            appLanguage.persist()
            syncServiceLocales()
        }
    }

    /// The locale every piece of non-View code (router speech, formatters)
    /// resolves against.
    var activeLocale: Locale { appLanguage.locale }

    /// Pushes the active language into the services that build user-facing
    /// strings at call time — platform notifications, spoken confirmation
    /// challenges, and family alert payloads (spec §3.2). Runs once at the
    /// end of `init` (after the persisted language is restored; didSet does
    /// not fire for the initial assignment) and on every language change.
    private func syncServiceLocales() {
        alarmScheduler.locale = activeLocale
        medicationScheduler.locale = activeLocale
        familyNotifier.locale = activeLocale
    }

    /// First-run onboarding progress (spec §4.2). Persisted per step.
    let onboardingState = OnboardingState()

    /// UI-facing voice session machine (spec §3.3). Mutations are confined
    /// to the main queue (this class routes every published mutation
    /// through `DispatchQueue.main.async` — review H1).
    let voiceSession = VoiceSessionStateMachine()

    /// User's STT model pick from the UI. Nil = automatic selection.
    /// Persisted in UserDefaults (a UI preference, not a secret) and
    /// pushed to WhisperSpeechRecognizer so it survives restarts.
    /// (Spec §4.4.4 — the Settings AI मोडेल section is this picker's home.)
    @Published var sttModelPreference: ModelID? {
        didSet {
            UserDefaults.standard.set(sttModelPreference?.rawValue,
                                      forKey: Self.sttPreferenceKey)
            whisperSpeechRecognizer.setPreferredModel(sttModelPreference)
            updateActiveSTTName()
        }
    }
    private static let sttPreferenceKey = "sttModelPreference"

    /// Last user utterance and assistant reply — the Home conversation
    /// card (spec §4.1.4).
    @Published var lastTranscript: String?
    @Published var lastAssistantReply: String?

    /// While non-nil, a confirmation challenge is awaiting the user's
    /// yes/no follow-up. Set by `startVoiceAckConfirmation`, cleared by
    /// `handleConfirmationResponse` or the session-machine timeout (C12).
    @Published var pendingConfirmationEntryId: UUID?

    private let storage: EncryptedLocalStorage
    private let observabilityBus: ObservabilityBus
    private let medicationScheduler: MedicationScheduler
    private let alarmScheduler: UNNotificationScheduler
    private let familyNotifier: APNsFamilyNotifier

    /// Family contacts (spec §4.4.2) — persisted encrypted, feeds the
    /// notifier whenever the list changes.
    let familyContactStore: FamilyContactStore
    @Published private(set) var familyContacts: [FamilyContact]

    // Voice
    private let audioEngine: AVAudioEngine
    private let audioSessionManager: AudioSessionManager
    private let wakeWordEngine: WakeWordEngine
    private let voiceActivityDetector: VoiceActivityDetector
    private var voicePipeline: VoicePipeline!
    private var voiceStateCancellable: AnyCancellable?
    private var whisperSwapCancellable: AnyCancellable?
    private var speaker: Speaker?

    /// Voice-session derivation state (spec §3.3): the last pipeline state
    /// plus how many `speak()` calls are currently in flight. `speaking`
    /// is derived, not a pipeline state.
    private var lastPipelineState: VoicePipeline.State = .stopped
    private var speakingCount = 0
    private var voiceWatchdog: DispatchWorkItem?
    /// Guards `VoicePipeline.start`: its only async gap is the
    /// mic-permission callback, which can silently never fire — leaving
    /// the session stuck in `.stopped` with no outcome. The watchdog
    /// surfaces that as an error with a truthful caption.
    private var voiceStartWatchdog: DispatchWorkItem?

    /// `start()` is idempotent — the onboarding wizard and Home both call
    /// it (spec §4.2: wizard runs before voice engages).
    private var started = false

    // Model store — exposed to the UI for download/selection surfaces.
    let modelStore: ModelStore
    let modelDownloadService: ModelDownloadService
    private let whisperSpeechRecognizer: WhisperSpeechRecognizer
    private let fallbackSpeechRecognizer: OnDeviceSpeechRecognizer

    /// The IDs the first-run flow will download by default. Order matters —
    /// STT unlocks the whole voice path so the distilled small Nepali
    /// model goes first (~327 MB, fast on Metal). The 1.9 GB large-v3
    /// Nepali fine-tune stays in the list (user-choosable, per the
    /// model-picker decision) but last so it never blocks the
    /// LLM/TTS downloads; it can be cancelled from the UI.
    let requiredModelIds: [ModelID] = [
        ModelCatalog.whisperFinetunedNepali,
        ModelCatalog.whisperSmallMultilingual,
        ModelCatalog.llama3_2_1B,
        ModelCatalog.piperNepali,
        ModelCatalog.whisperFinetunedNepaliQ8,
        ModelCatalog.whisperLargeV3Nepali
    ]

    init() {
        // Core infrastructure. Storage uses the Keychain (Data Protection class
        // Complete, per constitution §Security). Observability goes through the
        // log sanitiser so no PII leaks into device logs.
        let bus = ConsoleObservabilityBus(sanitiser: LogSanitiser())
        self.storage = KeychainEncryptedStorage()
        self.observabilityBus = bus
        self.alarmScheduler = UNNotificationScheduler()
        let contactStore = FamilyContactStore(storage: storage)
        self.familyContactStore = contactStore
        let loadedContacts = contactStore.load()
        self.familyContacts = loadedContacts
        self.familyNotifier = APNsFamilyNotifier(
            contacts: Self.emergencyContacts(from: loadedContacts),
            apnsProvider: APNsProvider()
        )

        // Safety-critical service (no LLM dependency)
        self.medicationScheduler = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarmScheduler,
            observabilityBus: bus,
            familyNotifier: familyNotifier
        )

        // Language — restore the persisted choice, defaulting to the Nepali
        // pilot language (spec §3.2).
        self.appLanguage = AppLanguage.persisted()

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
        //   downloading. PUSH MODE: audio arrives via feed() from the
        //   pipeline's permanent tap. Owned-tap mode made the recognizer
        //   tear down and reinstall the shared tap + restart the engine on
        //   every utterance — that churn wedged the audio server and
        //   AudioToolbox's _ReportRPCTimeout then ABORTED the process
        //   (7 crash reports, 2026-09-02).
        // - Whisper — used once its model is cached; push mode + VAD-gated.
        self.fallbackSpeechRecognizer = OnDeviceSpeechRecognizer(
            audioEngine: audioEngine,
            observabilityBus: bus,
            pushMode: true
        )
        self.whisperSpeechRecognizer = WhisperSpeechRecognizer(
            modelStore: modelStore,
            observabilityBus: bus
        )

        // Restore the persisted STT model choice. The didSet observer
        // pushes it to the recognizer and refreshes the label. Unknown
        // IDs (a model removed from the catalog, or a bad stored value)
        // are ignored so a stale preference can't wedge the picker.
        // Migration: the mid-training distill is superseded by the
        // stage-4 fine-tune.
        if let raw = UserDefaults.standard.string(forKey: Self.sttPreferenceKey),
           ModelCatalog.entry(for: ModelID(rawValue: raw)) != nil {
            let stored = ModelID(rawValue: raw)
            self.sttModelPreference = (stored == ModelCatalog.whisperSmallNepali)
                ? ModelCatalog.whisperFinetunedNepali
                : stored
        }

        // C12: the confirmation challenge expires — clear the pending entry
        // and tell the user (spec §3.3). The machine already dispatches to
        // main; keep this body main-safe regardless.
        voiceSession.onConfirmationTimeout = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingConfirmationEntryId = nil
                self.speak(key: "router.confirmationTimeout")
            }
        }

        // All stored properties are initialised — push the restored
        // language into services that build user-facing strings.
        syncServiceLocales()
    }

    func start() {
        guard !started else { return }
        started = true

        // Register background tasks (iOS)
        registerBackgroundTasks()

        // Repair encoder installs from older builds: the bundled-encoder
        // copy step normally runs at download finalize, so models cached
        // before a naming fix (or before the encoder existed) sit without
        // one. Idempotent — no-op when the target already exists.
        for entry in ModelCatalog.entries(kind: .whisperBase) {
            modelStore.installBundledCoreMLEncoder(for: entry.id)
        }
        // And the reverse: entries we no longer ship an encoder for
        // (large-v3 — its CoreML path hangs on-device) get their stale
        // encoder dir deleted, or whisper.cpp auto-loads it anyway.
        modelStore.removeStaleCoreMLBundles()

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
        self.speaker = speaker
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
            interpreter: interpreter
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
            .sink { [weak self] state in
                self?.handlePipelineState(state)
            }
        voicePipeline.onSTTError = { [weak self] msg in
            guard let self else { return }
            // Spec §7: error surfaces are localized, not raw pipeline text.
            DispatchQueue.main.async {
                self.voiceError = msg
                self.lastTranscript = L10n.str("state.error.status",
                                               locale: self.activeLocale)
            }
        }
        armVoiceStartWatchdog()
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
                if states[ModelCatalog.whisperSmallNepali] == .completed ||
                   states[ModelCatalog.whisperLargeV3Nepali] == .completed ||
                   states[ModelCatalog.whisperSmallMultilingual] == .completed {
                    self.trySwapToWhisper()
                }
            }

        isInitialized = true
        print("[AppCoordinator] Elderly AI Assistant started")
    }

    // MARK: - Voice session state (spec §3.3)

    /// Maps pipeline states onto the UI session machine. `speaking` is
    /// derived from the speaker lifecycle; `awaitingConfirmation` owns the
    /// UI until yes/no/timeout (pipeline events don't clobber it).
    private func handlePipelineState(_ state: VoicePipeline.State) {
        lastPipelineState = state
        voiceState = state
        guard voiceSession.state != .awaitingConfirmation else { return }
        switch state {
        case .stopped:
            voiceSession.transition(to: .stopped)
            cancelVoiceWatchdog()
        case .idle:
            voiceSession.transition(to: speakingCount > 0 ? .speaking : .idle)
            cancelVoiceWatchdog()
            cancelVoiceStartWatchdog()
        case .capturingCommand:
            voiceSession.transition(to: .listening)
            armVoiceWatchdog()
        case .processing:
            voiceSession.transition(to: .transcribing)
        case .routing:
            voiceSession.transition(to: .understanding)
        case .error:
            voiceSession.transition(to: .error)
            cancelVoiceWatchdog()
            cancelVoiceStartWatchdog()
        }
    }

    // MARK: - Voice cycle watchdog ("stuck in listening" guard)

    /// Arms a watchdog when a talk cycle starts. Its job is narrowly to
    /// break a wedged *capture*: if the session is still `.listening` 15s
    /// after the tap, the mic pipeline never moved on — recycle and
    /// re-prompt. It deliberately does NOT fire on `.transcribing` or
    /// `.understanding`: transcription of a long utterance on the
    /// CPU-pinned distilled model takes well over 15s on device, and
    /// recycling mid-flight there was exactly the "stuck/sorry-please-
    /// say-again" failure this cycle guard was mis-firing on. Recovery for
    /// a genuinely wedged transcription is owned by the STT layer (its own
    /// 30s inference timeout + 2-strike throttle), and routing has its own
    /// deadlines; those layers settle the cycle without this UI guard.
    private func armVoiceWatchdog() {
        cancelVoiceWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.voiceSession.state == .listening {
                print("[AppCoordinator] voice cycle watchdog fired — recycling pipeline")
                self.recoverVoiceCycle()
            }
        }
        voiceWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func cancelVoiceWatchdog() {
        voiceWatchdog?.cancel()
        voiceWatchdog = nil
    }

    /// Stops and restarts the voice pipeline — the recovery path for a
    /// wedged talk cycle. Also the manual escape hatch: the Talk button
    /// calls this when tapped mid-cycle. Spoken re-prompt included so the
    /// user knows the assistant is listening again.
    func recoverVoiceCycle() {
        cancelVoiceWatchdog()
        print("[AppCoordinator] recovering voice cycle — recycling pipeline")
        voicePipeline?.stop()
        armVoiceStartWatchdog()
        voicePipeline?.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
            }
        }
        speak(key: "router.reprompt")
    }

    // MARK: - Pipeline start watchdog

    /// If a pipeline start attempt produces no outcome within 10s (the
    /// mic-permission callback can silently never fire), surface an error
    /// state with the audio-unavailable caption instead of leaving the
    /// session silently stuck in `.stopped`.
    private func armVoiceStartWatchdog() {
        cancelVoiceStartWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.voiceSession.state == .stopped else { return }
            print("[AppCoordinator] voice start watchdog fired — no pipeline outcome")
            self.voiceError = "audio session: no response"
            self.voiceSession.transition(to: .error)
        }
        voiceStartWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func cancelVoiceStartWatchdog() {
        voiceStartWatchdog?.cancel()
        voiceStartWatchdog = nil
    }

    /// Called by `CommandRouter` when a speak begins/ends — drives the
    /// derived `speaking` state. Callers may be on any queue; mutations
    /// are pinned to main (H1).
    func noteSpeakingStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speakingCount += 1
            self.handlePipelineState(self.lastPipelineState)
        }
    }

    func noteSpeakingEnded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speakingCount = max(0, self.speakingCount - 1)
            self.handlePipelineState(self.lastPipelineState)
        }
    }

    /// Called by `CommandRouter` with the text being spoken so the Home
    /// conversation card can show the assistant's reply (spec §4.1.4).
    func noteAssistantSpoke(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastAssistantReply = text
        }
    }

    /// Speaks a catalog key in the active language (used by the yes/no
    /// chips and the confirmation timeout — router speech goes through the
    /// same `speak` helper there).
    func speak(key: String) {
        guard let speaker else { return }
        let text = L10n.str(key, locale: activeLocale)
        guard !text.isEmpty else { return }
        noteAssistantSpoke(text)
        noteSpeakingStarted()
        let locale = activeLocale
        Task {
            await speaker.speak(text, locale: locale)
            self.noteSpeakingEnded()
        }
    }

    /// Attempts to move the pipeline off the SFSpeechRecognizer fallback
    /// onto WhisperSpeechRecognizer. Idempotent.
    private func trySwapToWhisper() {
        guard whisperSpeechRecognizer.isAvailable else { return }
        voicePipeline?.setSpeechRecognizer(whisperSpeechRecognizer)
        DispatchQueue.main.async { [weak self] in
            self?.updateActiveSTTName()
        }
    }

    /// Model the recognizer will use for the next utterance — the user's
    /// pick when cached, else the automatic order. Exposed for the UI's
    /// ANE/CPU label so it reports the engine that will actually run.
    var resolvedSTTModelID: ModelID? {
        whisperSpeechRecognizer.currentModelID()
    }

    /// Keeps `activeSTTNameKey` honest: explicit pick first, then whatever
    /// the recognizer would auto-select, then the SFSpeech fallback.
    private func updateActiveSTTName() {
        let resolved = sttModelPreference
            .flatMap { modelStore.isCached($0) ? $0 : nil }
            ?? whisperSpeechRecognizer.currentModelID()
        activeSTTNameKey = sttNameKey(for: resolved)
    }

    /// Catalog key naming the active STT (resolved in the UI's locale).
    private func sttNameKey(for id: ModelID?) -> String {
        switch id {
        case ModelCatalog.whisperFinetunedNepali:
            return "stt.name.whisperFinetunedNepali"
        case ModelCatalog.whisperFinetunedNepaliQ8:
            return "stt.name.whisperFinetunedNepaliQ8"
        case ModelCatalog.whisperSmallNepali:
            return "stt.name.whisperNepaliSmall"
        case ModelCatalog.whisperLargeV3Nepali:
            return "stt.name.whisperLargeNepali"
        case ModelCatalog.whisperSmallMultilingual:
            return "stt.name.whisperMultilingual"
        case ModelCatalog.whisperBaseEn:
            return "stt.name.whisperEnglish"
        default:
            return "stt.name.sfs"
        }
    }

    /// Called by CommandRouter with the raw transcript so the Home
    /// conversation card can display it. Avoids depending on the
    /// TTS/notification path for visible feedback. Also drops the Whisper
    /// context — its ~1.5 GB (large-v3) would otherwise stay resident
    /// while LLaMA runs and crash llama.cpp's output buffer reservation
    /// on 6 GB devices.
    func recordTranscript(_ text: String) {
        whisperSpeechRecognizer.releaseModel()
        DispatchQueue.main.async { [weak self] in
            self?.lastTranscript = text
        }
    }

    // MARK: - Family contacts (spec §4.4.2)

    /// Maps stored family contacts onto the notifier's contact type.
    /// Device tokens stay unprovisioned until the broker relay exists
    /// (review C6) — the list itself is real and wired.
    private static func emergencyContacts(from contacts: [FamilyContact]) -> [EmergencyContact] {
        contacts.map {
            EmergencyContact(
                id: $0.id,
                displayName: $0.name,
                deviceToken: "",
                isEmergencyContact: true,
                isFamilyNotificationTarget: true
            )
        }
    }

    @discardableResult
    func addFamilyContact(name: String, phone: String, relationship: String) -> Bool {
        let contact = FamilyContact(name: name, phone: phone, relationship: relationship)
        guard familyContactStore.add(contact) else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
        }
        return true
    }

    func removeFamilyContact(id: UUID) {
        familyContactStore.remove(id: id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
        }
    }

    // MARK: - Medication schedule surface (spec §4.3, §4.4.3)

    /// Reminders currently waiting (pending or fired, not yet completed).
    var pendingReminders: [ScheduledReminder] { medicationScheduler.pendingReminders }

    /// Configured medication entries — read-only view for the Settings
    /// editor and the Meds leaf.
    var medicationEntries: [MedicationEntry] { medicationScheduler.medicationEntries() }

    func medicationName(for entryId: UUID) -> String {
        medicationScheduler.medicationEntries()
            .first { $0.id == entryId }?
            .medicationName ?? ""
    }

    /// Adds or validates a medication schedule entry from the Settings
    /// editor. Returns a catalog key on validation failure, nil on success.
    /// Success persists via `loadSchedule` and re-arms alarms (spec §4.4.3).
    @discardableResult
    func addMedication(name: String, time: DateComponents) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "settings.meds.nameRequired" }
        let duplicate = medicationScheduler.medicationEntries().contains { entry in
            entry.medicationName == trimmed && entry.scheduleTimes.contains(time)
        }
        guard !duplicate else { return "settings.meds.duplicateError" }

        var entries = medicationScheduler.medicationEntries()
        let entry = MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: trimmed,
            doseDescription: "",
            scheduleTimes: [time],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil
        )
        entries.append(entry)
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
        return nil
    }

    /// Removes a medication entry and re-arms (spec §4.4.3).
    func removeMedication(id: UUID) {
        var entries = medicationScheduler.medicationEntries()
        entries.removeAll { $0.id == id }
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
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
            self?.voiceSession.transition(to: .awaitingConfirmation)
        }
        return prompt
    }

    /// User's yes/no follow-up to a pending confirmation challenge.
    /// Routes through the scheduler's dementia path so the double-dose
    /// check fires and the log is written with `confirmationPassed`
    /// reflecting reality. The session machine returns to idle (and its
    /// timeout timer is cancelled — C12).
    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        guard let entryId = pendingConfirmationEntryId else { return }
        _ = medicationScheduler.acknowledgeWithConfirmation(
            entryId: entryId,
            at: Date(),
            confirmationResponse: response
        )
        DispatchQueue.main.async { [weak self] in
            self?.pendingConfirmationEntryId = nil
            self?.voiceSession.transition(to: .idle)
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

    /// Creates a reminder entry through the scheduler storage (spec §5.1,
    /// `set_reminder`). Builds a `MedicationEntry` so the existing
    /// scheduler handles alarm + escalation for it.
    func addVoiceReminder(title: String, time: DateComponents) {
        var entries = medicationScheduler.medicationEntries()
        let entry = MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: title,
            doseDescription: "",
            scheduleTimes: [time],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil
        )
        entries.append(entry)
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
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
