import Foundation
import AVFoundation
import BackgroundTasks
import Combine
import UserNotifications
import UIKit
import MessageUI

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

    /// Which voice engine stack is active: on-device Whisper+LLaMA, or the
    /// cloud Gemini pivot (default). A UI preference, not a secret —
    /// persisted in UserDefaults the same way as `sttModelPreference` — so
    /// the household can A/B test both without rebuilding. Setting this
    /// hot-swaps both the STT (`voicePipeline.setSpeechRecognizer`, the
    /// same mechanism `trySwapToGemini()` already uses) and the LLM
    /// interpreter (via `switchableInterpreter`, since `CommandRouter`
    /// holds its interpreter as an immutable `private let`).
    @Published var voiceEngineStack: VoiceEngineStack {
        didSet {
            UserDefaults.standard.set(voiceEngineStack.rawValue, forKey: Self.voiceEngineStackKey)
            applyVoiceEngineStack()
        }
    }
    private static let voiceEngineStackKey = "voiceEngineStack"

    /// Last user utterance and assistant reply — the Home conversation
    /// card (spec §4.1.4).
    @Published var lastTranscript: String?
    @Published var lastAssistantReply: String?

    // MARK: - Conversation history & outcome (redesign spec §3.1, §5)

    enum ExchangeRole { case user, assistant }

    struct Exchange: Identifiable {
        let id = UUID()
        let role: ExchangeRole
        let text: String
        let timestamp: Date
    }

    /// A concrete, real result of a voice action — shown as the Home
    /// outcome card (redesign spec §3.1). `undo` is non-nil ONLY when a
    /// genuine reversible operation backs it (e.g. a just-created voice
    /// reminder); it stays nil for actions with no real undo path (e.g.
    /// medication acknowledgement) rather than faking one (redesign spec
    /// §6).
    struct OutcomeSummary: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let timestamp: Date
        let undo: (() -> Void)?
    }

    /// Ring buffer backing the on-demand history sheet (redesign spec
    /// §3.1) — replaces the old always-visible conversation card.
    @Published private(set) var conversationHistory: [Exchange] = []
    private static let maxHistory = 20

    @Published var lastOutcome: OutcomeSummary?

    private func appendHistory(_ role: ExchangeRole, _ text: String) {
        conversationHistory.append(Exchange(role: role, text: text, timestamp: Date()))
        if conversationHistory.count > Self.maxHistory {
            conversationHistory.removeFirst(conversationHistory.count - Self.maxHistory)
        }
    }

    /// Sets the Home outcome card. Always dispatched to main (H1) since
    /// callers may run on the router's queue, not just main.
    private func setOutcome(icon: String, text: String, undo: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.lastOutcome = OutcomeSummary(icon: icon, text: text, timestamp: Date(), undo: undo)
        }
    }

    /// Generic dual-channel confirmation for replies that aren't a
    /// specific tracked action (general Q&A `query`/`none`, and the
    /// `health_query`/`music` stub replies) — without this, only
    /// medication-ack/reminder-set/call/message ever produced a visible
    /// outcome card, leaving the single most common interaction (plain
    /// conversation) with no visual trace at all, defeating the whole
    /// "don't rely on hearing alone" point of the redesign. Called
    /// explicitly by `CommandRouter` only for those specific cases (not
    /// from `noteAssistantSpoke` generally) so it can never clobber a
    /// more specific outcome set moments earlier in the same turn.
    ///
    /// Includes `lastTranscript` (already set by `recordTranscript` at the
    /// top of every `route()` call, so it's available here) alongside the
    /// reply — repeated field reports (2026-09-04) made clear that only
    /// ever showing the ASSISTANT's reply, with the user's own transcript
    /// visible for barely a second during capture and never again, reads
    /// as "no transcript showing" even though routing worked correctly.
    /// Showing both together, persistently, is the actual fix — not a UI
    /// timing tweak.
    func noteGenericReply(_ text: String) {
        guard !text.isEmpty else { return }
        let display: String
        if let heard = lastTranscript, !heard.isEmpty {
            display = "\u{201C}\(heard)\u{201D}\n\(text)"
        } else {
            display = text
        }
        setOutcome(icon: "bubble.left.and.bubble.right.fill", text: display)
    }

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
    private var geminiSwapCancellable: AnyCancellable?
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

    // Model store — kept for now (v1 on-device Whisper/LLaMA machinery is
    // superseded, not deleted, by the v2 Gemini pivot; see
    // docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md §8).
    // Nothing in `start()` requires these anymore — the onboarding models
    // step no longer downloads anything by default (see
    // `OnboardingWizardView.ModelsStep`, repurposed for the Gemini API key).
    let modelStore: ModelStore
    let modelDownloadService: ModelDownloadService
    private let whisperSpeechRecognizer: WhisperSpeechRecognizer
    private let fallbackSpeechRecognizer: OnDeviceSpeechRecognizer
    /// ANE WhisperKit runtime (memory: ios-stt-runtime-decision). Preferred
    /// over the CPU whisper.cpp recognizer whenever its model artifact is
    /// installed (`ModelStore.directoryURL(for: .whisperKitNepali)`) or a
    /// bench override is set — same hot-swap mechanism, GPU/ANE compute.
    private let whisperKitSpeechRecognizer: WhisperKitSpeechRecognizer

    /// v2: the Gemini API key + client (see `GeminiConfigStore`,
    /// `GeminiClient`). `geminiConfigStore` is exposed for the Settings
    /// screen that lets a family member paste in the key.
    let geminiConfigStore: GeminiConfigStore
    private let geminiClient: GeminiClient
    private let geminiSpeechRecognizer: GeminiSpeechRecognizer

    /// On-device LLM interpreter (v1 stack, kept alive for the
    /// on-device/Gemini A/B toggle — `voiceEngineStack`). Constructed
    /// up-front like `whisperSpeechRecognizer`; `isAvailable` stays false
    /// until both the LLM.swift runtime is linked and its model is cached
    /// (see `LlamaCommandInterpreter.isAvailable`), in which case
    /// `CommandRouter`'s existing keyword fallback takes over — unchanged.
    private let llamaCommandInterpreter: LlamaCommandInterpreter
    /// Set once in `start()`. `geminiCommandInterpreter` is the concrete
    /// Gemini-backed interpreter — one of the two optional BRAINS behind
    /// `intentRouter` (spec 2026-09-05 §4.0), never installed in the
    /// router directly. `intentRouter` is the single `CommandInterpreter`
    /// handed to `CommandRouter`: keyword net → intent→command cache →
    /// cloud preparse → local brain → cloud brain (only when
    /// `cloudEnabled`). The `voiceEngineStack` toggle now flips
    /// `intentRouter.cloudEnabled` rather than swapping interpreters.
    private var geminiCommandInterpreter: GeminiCommandInterpreter!
    private(set) var intentRouter: IntentRouter?

    // MARK: - Intent layer services (spec 2026-09-05)
    /// Deterministic slot resolution + learning stores. Lazy so `storage`
    /// and `familyContacts` exist before first use.
    private lazy var contactResolver = ContactResolver { [weak self] in self?.familyContacts ?? [] }
    private lazy var callMethodPreferences = CallMethodPreferenceStore(storage: storage)
    private lazy var confirmedMethodHistory = ConfirmedMethodHistoryStore(storage: storage)
    private lazy var methodResolver = MethodResolver(preferenceStore: callMethodPreferences,
                                                     historyStore: confirmedMethodHistory)
    private lazy var intentCache = IntentCommandCache(storage: storage)
    private lazy var repetitionGuard = RepetitionGuard(storage: storage)

    /// Legacy v1 on-device model catalog — kept only so the buried
    /// "AI मोडेल" settings screen still functions as a manual fallback.
    /// No longer downloaded automatically at first run (v2 pivot).
    let requiredModelIds: [ModelID] = [
        ModelCatalog.whisperMediumFinetunedNepali,
        ModelCatalog.whisperSmallMultilingual,
        ModelCatalog.llama3_2_1B,
        ModelCatalog.piperNepali,
        ModelCatalog.whisperFinetunedNepaliQ8,
        ModelCatalog.whisperLargeV3Nepali,
        // Placeholder entry — not a real download yet. See the TODO comment
        // on this entry in ModelCatalog.swift.
        ModelCatalog.whisperKitNepali
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

        // v2 pivot: Gemini API key + client. The key is entered via
        // Settings (or the repurposed onboarding "models" step) by a
        // family member — see GeminiConfigStore's doc comment.
        let geminiConfig = GeminiConfigStore(storage: storage)
        self.geminiConfigStore = geminiConfig
        self.geminiClient = GeminiClient(configStore: geminiConfig, observabilityBus: bus)
        self.geminiSpeechRecognizer = GeminiSpeechRecognizer(client: geminiClient, observabilityBus: bus)

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
        self.whisperKitSpeechRecognizer = WhisperKitSpeechRecognizer(
            observabilityBus: bus,
            modelStore: modelStore
        )
        // Bench hook (debug): point the ANE runtime at a sideloaded model
        // folder or a WhisperKit-named model via scheme env vars —
        // WHISPERKIT_MODEL_FOLDER / WHISPERKIT_MODEL_NAME. Production
        // selection uses the installed catalog artifact instead.
        let wkEnv = ProcessInfo.processInfo.environment
        if let folder = wkEnv["WHISPERKIT_MODEL_FOLDER"] {
            whisperKitSpeechRecognizer.modelFolderURL =
                URL(fileURLWithPath: folder)
        } else if let name = wkEnv["WHISPERKIT_MODEL_NAME"] {
            whisperKitSpeechRecognizer.modelName = name
        }
        self.llamaCommandInterpreter = LlamaCommandInterpreter(
            modelStore: modelStore,
            observabilityBus: bus,
            config: LlamaCommandInterpreter.Config(confidenceThreshold: 0.4,
                                                   maxTokens: 128,
                                                   temperature: 0.2,
                                                   timeoutSeconds: 10)
        )

        // Restore the persisted voice-engine stack choice (default: the
        // live v2 Gemini pivot, matching today's always-Gemini behavior for
        // anyone who's never touched the toggle). Applied for real once
        // `start()` has built the pipeline + switchable interpreter — see
        // `applyVoiceEngineStack()`. This is the property's ONLY initial
        // assignment, so (like `appLanguage` above) its didSet does not
        // fire here.
        self.voiceEngineStack = UserDefaults.standard.string(forKey: Self.voiceEngineStackKey)
            .flatMap(VoiceEngineStack.init(rawValue:)) ?? .gemini

        // Restore the persisted STT model choice. The didSet observer
        // pushes it to the recognizer and refreshes the label. Unknown
        // IDs (a model removed from the catalog, or a bad stored value)
        // are ignored so a stale preference can't wedge the picker.
        // Migration: the mid-training distill is superseded by the
        // stage-4 fine-tune.
        if let raw = UserDefaults.standard.string(forKey: Self.sttPreferenceKey),
           ModelCatalog.entry(for: ModelID(rawValue: raw)) != nil {
            let stored = ModelID(rawValue: raw)
            // Superseded models migrate forward to the current default:
            // mid-training distill → stage-4 fine-tune → medium fine-tune.
            self.sttModelPreference =
                (stored == ModelCatalog.whisperSmallNepali
                 || stored == ModelCatalog.whisperFinetunedNepali)
                ? ModelCatalog.whisperMediumFinetunedNepali
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
            // Bundled ggml models (the default medium) install the same
            // way — first run never downloads them.
            modelStore.installBundledModel(for: entry.id)
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
        // v2 pivot: Gemini interpreter. `isAvailable` stays false until an
        // API key is configured (GeminiConfigStore) — CommandRouter treats
        // that exactly like the old "LLM not linked" case: fall through to
        // keyword matching.
        // Brains are constructed with their confidence threshold at the
        // REPHRASE floor (0.4) so mid-confidence commands reach
        // `IntentRouter`, which owns the band policy (spec §4): ≥0.7
        // dispatches, 0.4–0.7 dispatches only tier-`confirm` actions
        // (their confirmation question verifies aloud), below → abstain.
        let geminiInterpreter = GeminiCommandInterpreter(
            client: geminiClient,
            observabilityBus: observabilityBus,
            config: GeminiCommandInterpreter.Config(confidenceThreshold: 0.4)
        )
        self.geminiCommandInterpreter = geminiInterpreter
        let router3 = IntentRouter(cache: intentCache, observabilityBus: observabilityBus)
        router3.localBrain = llamaCommandInterpreter
        router3.cloudBrain = geminiInterpreter
        router3.cloudEnabled = (voiceEngineStack == .gemini)
        self.intentRouter = router3
        // Collapse #1 (spec §4): when the Gemini recognizer is the active
        // STT, ONE understand call does STT + intent; the command half is
        // waiting in `intentRouter` when the transcript half routes.
        geminiSpeechRecognizer.collapseContextProvider = { [weak self] in
            InterpreterContext(pendingMedications: [],
                               userLanguageHint: self?.activeLocale.languageCode ?? "ne")
        }
        geminiSpeechRecognizer.onUnderstanding = { [weak self] transcript, command in
            self?.intentRouter?.noteCloudPreparsed(transcript: transcript, command: command)
        }
        let router = CommandRouter(
            coordinator: self,
            observabilityBus: observabilityBus,
            speaker: speaker,
            interpreter: router3
        )
        // Start with the fallback STT. Gemini is swapped in below once an
        // API key is configured.
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
                // One-shot at startup: puts the STT + interpreter in the
                // state `voiceEngineStack` says they should be in (e.g. a
                // Gemini key already saved, or the on-device stack picked
                // last session).
                self.applyVoiceEngineStack()
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
            }
        }

        // Hot-swap trigger: as soon as a Gemini API key is saved (Settings
        // or onboarding), swap the fallback SFSpeechRecognizer for the real
        // recognizer without tearing down the wake-word loop.
        geminiSwapCancellable = geminiConfigStore.$apiKey
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.trySwapToGemini()
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
            // Redesign spec §3.1/§6: the live-caption pill must not show
            // the PREVIOUS utterance's transcript while a new one is being
            // captured — clear it at the start of every capture cycle.
            lastTranscript = nil
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
    /// MUST stay longer than (max speech capture time) + (GeminiClient's
    /// own HTTP timeout) — i.e. longer than the worst-case legitimate
    /// duration of a single turn — or this destructive watchdog (full
    /// pipeline stop/restart + spoken reprompt) fires on a request that
    /// was still genuinely working, not actually wedged.
    ///
    /// This exact bug happened twice in a row (2026-09-04): first when
    /// `VoicePipeline`'s internal 18s wedge-guard window was widened for
    /// Gemini but this watchdog was left at the old 15s, so it fired
    /// FIRST and tore down in-flight requests before the (harmless)
    /// internal one ever got a chance to just flip the UI to
    /// `.transcribing`. Then again after bumping `GeminiClient`'s HTTP
    /// timeout from 6s to 25s for the (slower) gemini-2.5-pro model —
    /// confirmed via a real device log showing `NSURLErrorDomain
    /// Code=-1001 "The request timed out."` — without also widening this
    /// watchdog to match. The three numbers (this constant,
    /// `VoicePipeline`'s capture+wedge-guard window, and
    /// `GeminiClient.Config.timeoutSeconds`) are coupled and MUST be
    /// re-checked together any time one of them changes.
    private static let voiceWatchdogSeconds: TimeInterval = 40

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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.voiceWatchdogSeconds, execute: work)
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
            self?.appendHistory(.assistant, text)
        }
    }

    /// Speaks a catalog key in the active language (used by the yes/no
    /// chips and the confirmation timeout — router speech goes through the
    /// same `speak` helper there).
    func speak(key: String) {
        guard let speaker else { return }
        let text = L10n.str(key, locale: activeLocale)
        speak(text: text)
    }

    /// Speaks dynamic, already-resolved text (e.g. a call-confirmation
    /// prompt built from a contact's name) — no catalog lookup.
    func speak(text: String) {
        guard let speaker, !text.isEmpty else { return }
        noteAssistantSpoke(text)
        noteSpeakingStarted()
        let locale = activeLocale
        Task {
            await speaker.speak(text, locale: locale)
            self.noteSpeakingEnded()
        }
    }

    /// Attempts to move the pipeline off the SFSpeechRecognizer fallback
    /// onto the Gemini recognizer (v2 pivot). Idempotent. Guarded on
    /// `voiceEngineStack` so that saving/rotating a Gemini API key while
    /// the user has explicitly picked the on-device stack doesn't silently
    /// yank them back onto Gemini — `applyVoiceEngineStack()` is what
    /// actually decides which stack is live.
    private func trySwapToGemini() {
        guard voiceEngineStack == .gemini, geminiSpeechRecognizer.isAvailable else { return }
        voicePipeline?.setSpeechRecognizer(geminiSpeechRecognizer)
        DispatchQueue.main.async { [weak self] in
            self?.updateActiveSTTName()
        }
    }

    /// Applies `voiceEngineStack` to both halves of the pipeline: the STT
    /// (hot-swapped via `VoicePipeline.setSpeechRecognizer`, same
    /// mechanism `trySwapToGemini()` uses) and the LLM interpreter (via
    /// `switchableInterpreter.current`, since `CommandRouter` can't have
    /// its interpreter swapped directly). Called once at startup and again
    /// on every `voiceEngineStack` change. No-ops harmlessly if called
    /// before `start()` has built the pipeline/switchable interpreter.
    private func applyVoiceEngineStack() {
        switch voiceEngineStack {
        case .gemini:
            // Local-first hybrid with cloud fallback (spec §4.0): the
            // local brain answers what it can, Gemini takes the rest.
            intentRouter?.cloudEnabled = true
            trySwapToGemini()
        case .onDevice:
            // Strictly on-device: no cloud brain even if a key exists.
            intentRouter?.cloudEnabled = false
            // Whisper if its model is actually cached and the runtime is
            // linked; else the SFSpeechRecognizer fallback rather than
            // silently doing nothing (spec §7: no dead-end states).
            if whisperKitSpeechRecognizer.isAvailable {
                // ANE WhisperKit first — the medium-class models are
                // unusable on CPU (128 s for a 2.1 s clip, 2026-09-05)
                // but conversational on ANE.
                voicePipeline?.setSpeechRecognizer(whisperKitSpeechRecognizer)
                // Absorb model load + CoreML specialization now so the
                // first utterance doesn't pay it.
                whisperKitSpeechRecognizer.prepare()
            } else {
                // CPU whisper.cpp when its model is cached; else the
                // SFSpeechRecognizer fallback rather than silently doing
                // nothing (spec §7: no dead-end states).
                voicePipeline?.setSpeechRecognizer(
                    whisperSpeechRecognizer.isAvailable ? whisperSpeechRecognizer : fallbackSpeechRecognizer
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateActiveSTTName()
            }
        }
    }

    /// Whether the on-device stack (Whisper STT + LLaMA interpreter) is
    /// actually ready to use — both its runtime package linked AND its
    /// model downloaded (see `LlamaCommandInterpreter.isAvailable` /
    /// `WhisperSpeechRecognizer.isAvailable`). Exposed for the Settings
    /// voice-engine picker, which points the user at the buried "AI
    /// मोडेल" screen when this is false rather than silently switching to
    /// a non-functional stack.
    var isOnDeviceStackReady: Bool {
        llamaCommandInterpreter.isAvailable
            && (whisperSpeechRecognizer.isAvailable || whisperKitSpeechRecognizer.isAvailable)
    }

    /// Model the legacy on-device recognizer would use if manually
    /// selected from the buried "AI मोडेल" screen — exposed for that
    /// screen's ANE/CPU label. Irrelevant once Gemini is configured.
    var resolvedSTTModelID: ModelID? {
        whisperSpeechRecognizer.currentModelID()
    }

    /// Keeps `activeSTTNameKey` honest: Gemini when that's the selected
    /// stack AND it's configured (v2 pivot), else whatever the on-device
    /// picker resolves to, else the SFSpeech fallback. Checking
    /// `voiceEngineStack` (not just `isAvailable`) matters once the
    /// on-device/Gemini toggle exists — a configured Gemini key shouldn't
    /// make this claim "Gemini" while the user has explicitly picked
    /// on-device.
    private func updateActiveSTTName() {
        if voiceEngineStack == .gemini, geminiSpeechRecognizer.isAvailable {
            activeSTTNameKey = "stt.name.gemini"
            return
        }
        // WhisperKit (ANE) wins the label whenever it's the recognizer the
        // on-device stack will actually use.
        if voiceEngineStack == .onDevice, whisperKitSpeechRecognizer.isAvailable {
            activeSTTNameKey = sttNameKey(for: ModelCatalog.whisperKitNepali)
            return
        }
        let resolved = sttModelPreference
            .flatMap { modelStore.isCached($0) ? $0 : nil }
            ?? whisperSpeechRecognizer.currentModelID()
        activeSTTNameKey = sttNameKey(for: resolved)
    }

    /// Catalog key naming the active STT (resolved in the UI's locale).
    private func sttNameKey(for id: ModelID?) -> String {
        switch id {
        case ModelCatalog.whisperKitNepali:
            return "stt.name.whisperKitNepali"
        case ModelCatalog.whisperMediumFinetunedNepali:
            return "stt.name.whisperMediumFinetunedNepali"
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
        whisperKitSpeechRecognizer.releaseModel()
        DispatchQueue.main.async { [weak self] in
            self?.lastTranscript = text
            self?.appendHistory(.user, text)
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
        callMethodPreferences.removeAll(for: id)
        confirmedMethodHistory.removeAll(for: id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
        }
    }

    // MARK: - Emergency (redesign spec §3.1/§3.2 — persistent icon everywhere)

    /// The contact the Emergency affordance calls. Every stored family
    /// contact is already treated as an emergency target (see
    /// `emergencyContacts(from:)` above) — there's no separate
    /// "designate as emergency contact" flag yet, so this is simply the
    /// first configured contact. Nil when none is configured, which the
    /// view surfaces honestly instead of pretending an action is available.
    var emergencyContact: FamilyContact? { familyContacts.first }

    /// Posts the same local notification `CommandRouter` already posts for
    /// a voice-triggered emergency, and speaks the ack — reused here so the
    /// touch and voice paths produce identical, real behavior. Does NOT
    /// place the call itself (that's a `UIApplication.open(tel:)` at the
    /// view layer, same pattern as `CallView`'s tap-to-dial) since this
    /// class stays UIKit-free.
    func emergencyNotify() {
        let locale = activeLocale
        let content = UNMutableNotificationContent()
        content.title = L10n.str("notif.emergencyAck.title", locale: locale)
        content.body = L10n.str("notif.emergencyAck.body", locale: locale)
        content.sound = .defaultCritical
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        speak(key: "router.emergencyAck")
    }

    // MARK: - Voice-triggered call & message (trial wiring)
    //
    // Deliberately scoped to the LLM-interpreted path only —
    // `CommandRouter.routeKeyword`'s blunt "call"/"phone" catch-all stays
    // blocked unconditionally (constitution: no auth yet), because it has
    // no entity extraction and can't identify a specific target. These
    // only act when a specific, resolvable contact was named.

    /// Single-contact resolution for flows that can't disambiguate aloud
    /// (message compose). Backed by `ContactResolver` (spec §6.1) — the
    /// deterministic, scoring-based matcher that replaced the bare
    /// substring check. Ambiguous → nil: the caller speaks its generic
    /// not-found, which is honest (it can't name who it would have used).
    private func resolveSingleContact(_ query: String?) -> FamilyContact? {
        guard case .one(let contact) = contactResolver.resolve(query) else { return nil }
        return contact
    }

    struct PendingCallAction {
        let contact: FamilyContact
        let method: CallMethod
        /// Set when the user asked for an app we can't actually call
        /// through (e.g. "messenger"), so we fell back to FaceTime —
        /// named here so the confirmation prompt can disclose it.
        let unsupportedRequestedApp: String?
        /// The original utterance + interpreted command this action came
        /// from — threaded through so a CONFIRMED execution can teach the
        /// intent→command cache (spec §4.2). Nil for touch-originated
        /// actions; overrides inherit them from the action they amend.
        let sourceTranscript: String?
        let sourceCommand: InterpretedCommand?
    }

    @Published private(set) var pendingCallAction: PendingCallAction?
    var isAwaitingCallConfirmation: Bool { pendingCallAction != nil }

    /// `call` intent — resolves the contact (ContactResolver, spec §6.1)
    /// and picks the best REAL method (MethodResolver chain, spec §6.2),
    /// then asks for voice confirmation before doing anything. Returns
    /// the prompt to speak; nil if no contact could be resolved, so the
    /// caller falls back to its existing blocked/unrecognised message.
    /// An AMBIGUOUS contact is not nil: no action is pended, and the
    /// returned prompt asks for a fuller name instead (guessing a person
    /// is the worst resolution error — spec §6.1).
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? {
        guard let contactQuery else { return nil }
        let contact: FamilyContact
        switch contactResolver.resolve(contactQuery) {
        case .one(let match):
            contact = match
        case .ambiguous(let matches):
            let names = matches.prefix(2).map(\.name).joined(separator: ", ")
            return L10n.fmt("router.call.disambiguate", locale: activeLocale, names)
        case .none:
            return nil
        }
        let resolved = methodResolver.resolve(contactId: contact.id,
                                              requestedApp: requestedApp,
                                              callType: callType)
        let action = PendingCallAction(contact: contact,
                                       method: resolved.method,
                                       unsupportedRequestedApp: resolved.unsupportedRequestedApp,
                                       sourceTranscript: sourceTranscript,
                                       sourceCommand: sourceCommand)
        pendingCallAction = action
        // Dementia-loop guard (spec §7.2): same target called again
        // within the window → the confirmation prompt says so out loud.
        let isRepeat = repetitionGuard.isRepeat(actionKey: "call", targetId: contact.id.uuidString)
        DispatchQueue.main.async { [weak self] in
            self?.voiceSession.transition(to: .awaitingConfirmation)
        }
        return confirmationPrompt(for: action, isRepeat: isRepeat)
    }

    /// Call-confirmation correction protocol (spec §7.2): the user
    /// answered the confirmation question with a METHOD amendment
    /// ("होइन, फोन नै गर" — no, plain phone). Rebuilds the pending action
    /// with the overridden method and re-confirms once — the yes/no that
    /// follows executes as normal, and the override pair is exactly the
    /// flywheel's gold sample. Returns false when the utterance carries
    /// no method keyword, so the router runs the normal yes/no flow.
    func handleCallConfirmationOverride(_ utterance: String) -> Bool {
        guard let action = pendingCallAction,
              let override = CallOverrideParser.parseMethodOverride(utterance) else { return false }
        let amended = PendingCallAction(contact: action.contact,
                                        method: override,
                                        unsupportedRequestedApp: nil,
                                        sourceTranscript: action.sourceTranscript,
                                        sourceCommand: action.sourceCommand)
        pendingCallAction = amended
        speak(text: confirmationPrompt(for: amended, isRepeat: false))
        return true
    }

    private func confirmationPrompt(for action: PendingCallAction, isRepeat: Bool) -> String {
        let locale = activeLocale
        var parts: [String] = []
        if isRepeat {
            parts.append(L10n.fmt("router.call.recentRepeatNotice", locale: locale, action.contact.name))
        }
        if let unsupported = action.unsupportedRequestedApp {
            parts.append(L10n.fmt("router.call.appUnsupportedNotice", locale: locale, unsupported))
        }
        let methodKey: String
        switch action.method {
        case .phone: methodKey = "router.call.methodPhone"
        case .facetimeVideo: methodKey = "router.call.methodVideo"
        case .facetimeAudio: methodKey = "router.call.methodVoice"
        case .whatsappChat: methodKey = "router.call.methodWhatsAppChat"
        }
        let methodText = L10n.str(methodKey, locale: locale)
        parts.append(L10n.fmt("router.call.confirmQuestion", locale: locale, action.contact.name, methodText))
        return parts.joined(separator: " ")
    }

    /// Actually places the call/opens the chat — only ever reached after
    /// the user said yes (`handleConfirmationResponse`). Never claims
    /// WhatsApp "called" — it only opened a chat, and says so.
    private func performCallAction(_ action: PendingCallAction) {
        let locale = activeLocale
        switch action.method {
        case .phone:
            let digits = action.contact.phone.filter { $0.isNumber || $0 == "+" }
            if !digits.isEmpty, let url = URL(string: "tel:\(digits)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
            setOutcome(icon: "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
        case .facetimeVideo, .facetimeAudio:
            let scheme = action.method == .facetimeVideo ? "facetime" : "facetime-audio"
            let digits = action.contact.phone.filter { $0.isNumber || $0 == "+" }
            if !digits.isEmpty, let url = URL(string: "\(scheme)://\(digits)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
            setOutcome(icon: action.method == .facetimeVideo ? "video.fill" : "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
        case .whatsappChat:
            let digits = action.contact.phone.filter { $0.isNumber }
            if !digits.isEmpty, let url = URL(string: "https://wa.me/\(digits)") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, action.contact.name))
        }
        noteConfirmedCallExecution(action)
    }

    /// Post-execution learning (spec §4.2 + §6.2): a CONFIRMED call is
    /// the system's highest-quality signal — it updates the confirmed-
    /// method history (step 3 of the method chain), feeds the dementia
    /// repetition guard, and teaches the intent→command cache with the
    /// original utterance (so next time the SAME words resolve with no
    /// model at all — confirmation still applies on every cache hit).
    private func noteConfirmedCallExecution(_ action: PendingCallAction) {
        confirmedMethodHistory.record(action.method, for: action.contact.id)
        repetitionGuard.record(actionKey: "call", targetId: action.contact.id.uuidString)
        if let transcript = action.sourceTranscript, let command = action.sourceCommand {
            intentRouter?.recordConfirmedExecution(transcript: transcript, command: command)
        }
    }

    /// A pending SMS draft — presented as `MessageComposeView` from
    /// `ContentView`. Never auto-sent: `MFMessageComposeViewController`
    /// requires the user's own tap on Send (Apple platform constraint,
    /// not a design choice), so this is as real as the feature can be.
    struct MessageDraft: Identifiable {
        let id = UUID()
        let recipients: [String]
        let body: String
    }
    @Published var pendingMessageDraft: MessageDraft?

    func composeMessage(toContactNamed query: String?, body: String) -> Bool {
        guard MFMessageComposeViewController.canSendText(),
              let query, let contact = resolveSingleContact(query) else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.pendingMessageDraft = MessageDraft(recipients: [contact.phone], body: body)
        }
        setOutcome(icon: "message.fill",
                   text: L10n.fmt("home.outcome.messageReady", locale: activeLocale, contact.name))
        return true
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
        // No undo here — the scheduler has no reversal operation for a
        // recorded dose, and faking one would be exactly the kind of mocked
        // affordance the redesign is trying to avoid (spec §6).
        setOutcome(icon: "checkmark.circle.fill",
                   text: L10n.fmt("home.outcome.medAck", locale: activeLocale,
                                  medicationName(for: entryId)))
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
        // Call confirmations are a separate, additive flow (2026-09-05) —
        // checked first and returned early so the medication path below
        // is completely untouched (safety-critical, 100%-covered code;
        // not worth any risk to it for an unrelated feature).
        if let action = pendingCallAction {
            pendingCallAction = nil
            switch response {
            case .yes:
                performCallAction(action)
            case .no:
                speak(text: L10n.fmt("router.call.cancelled", locale: activeLocale, action.contact.name))
            }
            DispatchQueue.main.async { [weak self] in
                self?.voiceSession.transition(to: .idle)
            }
            return
        }
        guard let entryId = pendingConfirmationEntryId else { return }
        _ = medicationScheduler.acknowledgeWithConfirmation(
            entryId: entryId,
            at: Date(),
            confirmationResponse: response
        )
        let name = medicationName(for: entryId)
        switch response {
        case .yes:
            setOutcome(icon: "checkmark.circle.fill",
                       text: L10n.fmt("home.outcome.medAck", locale: activeLocale, name))
        case .no:
            setOutcome(icon: "xmark.circle.fill",
                       text: L10n.fmt("home.outcome.medDenied", locale: activeLocale, name))
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingConfirmationEntryId = nil
            self?.voiceSession.transition(to: .idle)
        }
    }

    /// Whether a confirmation follow-up is currently expected.
    var isAwaitingConfirmation: Bool { pendingConfirmationEntryId != nil || pendingCallAction != nil }

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
        // Genuinely reversible — `removeMedication` already exists and
        // re-arms alarms, so the outcome card's undo link does real work
        // (redesign spec §6), unlike the medication-ack outcomes above.
        let entryId = entry.id
        setOutcome(icon: "clock.badge.checkmark.fill",
                   text: L10n.fmt("home.outcome.reminderSet", locale: activeLocale, title),
                   undo: { [weak self] in
                       self?.removeMedication(id: entryId)
                       self?.setOutcome(icon: "arrow.uturn.backward.circle.fill",
                                         text: L10n.str("home.outcome.undone", locale: self?.activeLocale ?? Locale(identifier: "ne-NP")))
                   })
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
