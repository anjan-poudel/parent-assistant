import Foundation
import AVFoundation
import BackgroundTasks
import Combine
import UserNotifications
import UIKit
import MessageUI
import SwiftUI

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
        routineAlarmScheduler.locale = activeLocale
        routineScheduler.locale = activeLocale
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
    /// Progressively-revealed transcript while the collapsed Gemini call
    /// streams (live captions, spec §3.3) — nil once the utterance
    /// settles and `lastTranscript` takes over. The caption pill binds
    /// `livePartialTranscript ?? lastTranscript`.
    @Published var livePartialTranscript: String?

    // MARK: - Conversation history & outcome (redesign spec §3.1, §5)

    /// The persisted exchange model lives in `ChatHistoryStore`
    /// (local-cache-chat task, 2026-09-06) — it must be Codable to
    /// round-trip under the store's single storage key. These aliases
    /// keep every existing call site (`AppCoordinator.Exchange`,
    /// `AppCoordinator.ExchangeRole`) source-compatible.
    typealias Exchange = ChatHistoryStore.Exchange
    typealias ExchangeRole = ChatHistoryStore.ExchangeRole

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

    /// Window over `chatHistoryStore` for the Home UI and the history
    /// sheet's first page (redesign spec §3.1) — always the LAST
    /// `ChatHistoryStore.pageSize` (20) exchanges, oldest → newest. The
    /// pre-persistence ring buffer behaved exactly like this; persistence
    /// (local-cache-chat task, 2026-09-06) only added the 200-entry
    /// on-disk layer that the window now slices from. Home's existing
    /// behavior (outcome-card fallback, `historyChip` empty-check) is
    /// unchanged.
    @Published private(set) var conversationHistory: [Exchange] = []

    /// Encrypted, bounded (200-entry) history behind the window above —
    /// loaded in `start()`, written through on every append. Lazy like
    /// the intent-layer stores below: `storage` is assigned at the top of
    /// `init`, long before anything can record a turn.
    private lazy var chatHistoryStore = ChatHistoryStore(storage: storage)

    @Published var lastOutcome: OutcomeSummary?

    /// Records one turn in the persisted history and refreshes the
    /// published window. Always called on the main queue (the two callers
    /// dispatch to main first), so the store is only ever touched from
    /// main.
    private func appendHistory(_ role: ExchangeRole, _ text: String) {
        chatHistoryStore.append(Exchange(role: role, text: text, timestamp: Date()))
        conversationHistory = chatHistoryStore.recent()
    }

    /// Paged read for the history sheet's "Show more" button
    /// (local-cache-chat task, 2026-09-06): up to `limit` exchanges
    /// strictly OLDER than the one with id `boundaryID` — the oldest row
    /// the sheet currently shows — oldest → newest (the sheet flips the
    /// page below its list). Reads the FULL persisted history (≤200),
    /// not just the 20-row window. Empty when nothing older exists, or
    /// when the boundary exchange left the store (trimmed past the cap)
    /// — the sheet hides the button on both.
    func olderHistory(than boundaryID: UUID, limit: Int = ChatHistoryStore.pageSize) -> [Exchange] {
        chatHistoryStore.older(than: boundaryID, limit: limit)
    }

    /// Whether exchanges older than `boundaryID` still exist — keeps the
    /// sheet's "Show more" button visible exactly until the history is
    /// exhausted, with no wasted page fetch.
    func hasOlderHistory(than boundaryID: UUID) -> Bool {
        chatHistoryStore.countOlder(than: boundaryID) > 0
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

    /// Generalised routine reminders (v2 pivot Phase 1 — walk, exercise,
    /// meals, bedtime, …). NOT safety-critical: no ack window, no
    /// escalation. Medication stays with `medicationScheduler` above,
    /// untouched.
    private let routineScheduler: RoutineScheduler
    private let routineAlarmScheduler: UNRoutineNotificationScheduler
    /// Kept so the medication-summary provider can be attached at the end
    /// of init — plugin registration runs before `self` is fully
    /// initialised, so the closure can't be captured at registration time.
    private let routinePlugin: RoutinePlugin

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
    /// Forwards the wake-word access-key store's publishes (2026-09-06):
    /// `wakeWordAccessKeyStore` is a nested ObservableObject, so a
    /// save/clear alone would not invalidate views observing the
    /// coordinator — the Settings "Voice activation" status derives from
    /// the store's `accessKey` and must refresh the moment the family
    /// member saves (or removes) the key.
    private var wakeWordKeyStoreCancellable: AnyCancellable?
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
    /// Daily Gemini call budget (open item #5, 2026-09-06): the shared
    /// per-day counter + family-editable soft cap wired into
    /// `GeminiClient`. Exposed for the Settings → Gemini AI screen
    /// (today's usage + cap editor).
    let geminiCostGovernor: GeminiCostGovernor
    private let geminiClient: GeminiClient
    private let geminiSpeechRecognizer: GeminiSpeechRecognizer

    // MARK: - Wake word ("Hey Sahayak", open item #4)
    //
    // Three moving parts: `wakeWordAccessKeyStore` (the Settings paste-in
    // field's home — Keychain-backed, same pattern as geminiConfigStore),
    // `wakeWordEnabled` (the persisted Settings toggle), and the launch
    // engine built in init. The pure logic behind these lives in
    // Services/Voice/WakeWordConfig.swift so it is unit-testable without
    // the Porcupine SPM package linked.

    /// Picovoice access key the family pastes into Settings → "Voice
    /// activation". `makeWakeWordEngine()` reads it as the FALLBACK when
    /// the build-time Info.plist key (`PicovoiceAccessKey`) is absent.
    let wakeWordAccessKeyStore: WakeWordAccessKeyStore

    /// Persisted "listen for Hey Sahayak" UI preference — UserDefaults
    /// (not a secret), same shape as `sttModelPreference` /
    /// `voiceEngineStack`. Defaults ON: inert until the key + .ppn exist
    /// (the Null engine is in place regardless), then listening starts at
    /// the next launch — see `WakeWordPreferences` for the rationale.
    /// didSet persists AND closes/opens the live audio gate so the
    /// Settings toggle acts immediately (no relaunch needed to STOP).
    @Published var wakeWordEnabled: Bool {
        didSet {
            wakeWordPreferences.setEnabled(wakeWordEnabled)
            wakeWordActivityGate.setEnabled(wakeWordEnabled)
        }
    }
    private let wakeWordPreferences = WakeWordPreferences()

    /// Consulted by the voice pipeline for every idle-state audio chunk
    /// and inbound wake detection: closed while the assistant's own TTS is
    /// playing (self-hearing mitigation — see `WakeWordActivityGate`) or
    /// listening is switched off in Settings. Written on the main queue
    /// (noteSpeakingStarted/Ended, the Settings binding), read on the mic
    /// tap's processing queue — the lock lives inside the gate.
    private let wakeWordActivityGate = WakeWordActivityGate()

    /// Whether the engine built in `init` is a REAL Porcupine engine (vs
    /// the Null fallback). Recorded once so Settings → "Voice activation"
    /// can truthfully distinguish active / needs-setup / off-at-launch.
    private let wakeWordEngineRealAtLaunch: Bool

    /// On-device LLaMA interpreter — the "LLaMA today" half of the local
    /// brain (spec 2026-09-05 §4.0): `LocalBrainChain`'s stand-in while
    /// the fine-tuned intent GGUF isn't cached. Constructed up-front like
    /// `whisperSpeechRecognizer`; `isAvailable` stays false until both the
    /// LLM.swift runtime is linked and its model is cached (see
    /// `LlamaCommandInterpreter.isAvailable`). When unavailable the
    /// chain's slot is simply empty and the router's cloud layer / keyword
    /// fallback carry the turn.
    private let llamaCommandInterpreter: LlamaCommandInterpreter
    /// The fine-tuned intent model (spec 2026-09-05 §8) — the local brain
    /// `IntentRouter` prefers once its GGUF is cached (the preferred half
    /// of `LocalBrainChain`). Until the bake-off artifact ships,
    /// `isAvailable` is false and the chain delegates to the LLaMA
    /// stand-in, keeping an on-device interpretation path alive.
    private let localIntentInterpreter: LocalIntentInterpreter
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
    /// Numbers this app has genuinely dialed, newest first — the ranking
    /// index for the Phone leaf's system-contacts search ("most recently
    /// used first", system-contacts search task 2026-09-06). Same
    /// encrypted storage channel as the repetition guard above.
    private lazy var callRecencyStore = CallRecencyStore(storage: storage)
    /// Flywheel intent log (spec §11) — feeds the family review screen
    /// (Settings) and the export→retrain loop.
    private(set) lazy var intentLogStore = IntentLogStore()
    /// Deep-link builder/opener for the call & message flows (v2 pivot
    /// Phase 2, §4.3) — FaceTime video/audio, WhatsApp text, tel:.
    /// Stateless, so no lazy needed; tests fake it via `CallLinkOpening`.
    private let callLinks = CallLinks()

    /// The plugin registry backing `.plugin` intent dispatch and plugin
    /// prompt composition (design doc 2026-09-05).
    private(set) var pluginRegistry: PluginRegistry!

    /// Legacy v1 on-device model catalog — kept only so the buried
    /// "AI मोडेल" settings screen still functions as a manual fallback.
    /// No longer downloaded automatically at first run (v2 pivot).
    ///
    /// The downloads-management rows must cover EVERY STT engine the
    /// picker can select (anything selectable has to be fetchable), so
    /// this mirrors `ModelCatalog.availableSTTEntries` (all catalog
    /// whisper-base entries minus placeholder-only models), then the
    /// assistant-brain and voice rows the screen has always managed.
    let requiredModelIds: [ModelID] =
        ModelCatalog.availableSTTEntries.map(\.id)
        + [ModelCatalog.llama3_2_1B, ModelCatalog.piperNepali]

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

        // Routine reminders (v2 pivot Phase 1): the medication path's
        // proven shape — encrypted store, UN notifications, occurrences
        // persisted before alarms arm, re-queue on launch — minus the
        // safety-critical escalation machinery. Seeded once with the
        // brief's category defaults (medication excluded: that system
        // owns medication, and a parallel one would double-prompt doses).
        let routineAlarmScheduler = UNRoutineNotificationScheduler()
        self.routineAlarmScheduler = routineAlarmScheduler
        let routineStore = RoutineStore(storage: storage)
        routineStore.seedDefaultsIfNeeded()
        let routineScheduler = RoutineScheduler(
            store: routineStore,
            alarmScheduler: routineAlarmScheduler,
            observabilityBus: bus
        )
        self.routineScheduler = routineScheduler
        self.routinePlugin = RoutinePlugin(scheduler: routineScheduler)

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
        // Cost governance (open item #5, 2026-09-06): ONE governor for
        // every billable Gemini call in the app. Voice, plugins, and
        // vision all share `geminiClient`, so they inherit the cap with
        // no per-plugin special-casing.
        let costGovernor = GeminiCostGovernor(storage: storage, observabilityBus: bus)
        self.geminiCostGovernor = costGovernor
        self.geminiClient = GeminiClient(configStore: geminiConfig, observabilityBus: bus,
                                         costGovernor: costGovernor)
        self.geminiSpeechRecognizer = GeminiSpeechRecognizer(client: geminiClient, observabilityBus: bus)

        // Wake word (#4): the access-key store the Settings paste-in field
        // writes to. makeWakeWordEngine() reads it as the fallback when
        // the build-time Info.plist `PicovoiceAccessKey` is absent.
        self.wakeWordAccessKeyStore = WakeWordAccessKeyStore(storage: storage)

        // Voice pipeline. Uses NullWakeWordEngine unless the Porcupine SPM
        // package is present AND the Settings toggle is ON AND a valid
        // access key / .ppn file are found — see Services/Voice/
        // WakeWordEngine.swift and docs/wake-word-setup.md for the
        // enablement steps. The launch outcome is recorded so Settings →
        // "Voice activation" can report an honest status.
        self.audioEngine = AVAudioEngine()
        self.audioSessionManager = AudioSessionManager(observabilityBus: bus)
        let wakeWordLaunch = Self.makeWakeWordEngine(accessKeyStore: wakeWordAccessKeyStore)
        self.wakeWordEngine = wakeWordLaunch.engine
        self.wakeWordEngineRealAtLaunch = wakeWordLaunch.isReal
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

        // Plugin registry (design: docs/superpowers/specs/
        // 2026-09-05-plugin-architecture-design.md). Built-ins are
        // registered here; both interpreters get it for prompt
        // composition, and CommandRouter gets it for .plugin dispatch.
        let pluginRegistry = PluginRegistry(observabilityBus: bus)
        pluginRegistry.register(NepaliCalendarPlugin(storage: storage))
        pluginRegistry.register(ApplianceHelperPlugin(storage: storage))
        pluginRegistry.register(routinePlugin)
        self.pluginRegistry = pluginRegistry

        self.llamaCommandInterpreter = LlamaCommandInterpreter(
            modelStore: modelStore,
            observabilityBus: bus,
            config: LlamaCommandInterpreter.Config(confidenceThreshold: 0.4,
                                                   maxTokens: 128,
                                                   temperature: 0.2,
                                                   timeoutSeconds: 10),
            pluginRegistry: pluginRegistry
        )
        self.localIntentInterpreter = LocalIntentInterpreter(
            modelStore: modelStore,
            observabilityBus: bus,
            config: LocalIntentInterpreter.Config(confidenceThreshold: 0.4,
                                                  maxTokens: 192,
                                                  timeoutSeconds: 3)
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

        // Restore the persisted wake-word listening preference (default
        // ON — inert until the access key + .ppn exist, see
        // `WakeWordPreferences`). This is the property's ONLY initial
        // assignment, so its didSet does not fire here (same rule as
        // `voiceEngineStack` above) — the live audio gate is synced
        // explicitly instead, or a stored OFF would sit on the gate's
        // default ON until the first Settings toggle.
        self.wakeWordEnabled = wakeWordPreferences.isEnabled
        wakeWordActivityGate.setEnabled(wakeWordEnabled)

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
                self.pendingRephrase = nil
                self.speak(key: "router.confirmationTimeout")
            }
        }

        // All stored properties are initialised — push the restored
        // language into services that build user-facing strings.
        syncServiceLocales()

        // Forward the wake-word access-key store's publishes (2026-09-06):
        // `wakeWordAccessKeyStore` is a nested ObservableObject, so a
        // save/clear alone would not invalidate views observing the
        // coordinator — the Settings "Voice activation" status derives
        // from the store's `accessKey` and must refresh the moment the
        // family member saves (or removes) the key. Placed here (not next
        // to the store's init) because the closure captures self.
        wakeWordKeyStoreCancellable = wakeWordAccessKeyStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Fold today's medication reminders into the routine plugin's
        // "what are my reminders today" answer — the user's mental model
        // is ONE reminder list spanning both systems. Attached here (not
        // at plugin registration) because the closure captures self.
        routinePlugin.medicationSummaryProvider = { [weak self] in
            self?.todayMedicationSummaryLines() ?? []
        }
    }

    func start() {
        guard !started else { return }
        started = true

        // Restore the persisted conversation history (local-cache-chat
        // task, 2026-09-06). Nothing records a turn before this point —
        // the router that calls recordTranscript/noteAssistantSpoke is
        // only built below — so the window stays empty until the store
        // has loaded. Corrupt or missing data loads as an empty history,
        // never a crash.
        chatHistoryStore.load()
        conversationHistory = chatHistoryStore.recent()

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
        // Same re-queue for routine reminders (FR-025)
        routineScheduler.scheduleAll()

        // Festival notifications (BS calendar, 2026-09-06): day-of for
        // every catalog festival + advance N-day reminders for important
        // ones (default 2, Settings-configurable). Idempotent rebuild.
        festivalCalendar.scheduleAll()

        // Voice pipeline is built lazily here so the CommandRouter can hold a
        // weak ref back to this fully-initialised coordinator.
        let systemSpeaker = SystemSpeechSpeaker(observabilityBus: observabilityBus)
        // PiperVoiceSpeaker is the production speaker: on-device Piper
        // VITS via sherpa-onnx (Nepali + English voices bundled), with
        // SystemSpeechSpeaker as the automatic fallback whenever a voice
        // is not installed — see docs/tts-implementation-plan.md.
        let speaker: Speaker = PiperVoiceSpeaker(
            fallback: systemSpeaker,
            observabilityBus: observabilityBus,
            modelStore: modelStore
        )
        self.speaker = speaker
        // The registry is built in init but the speaker only exists now —
        // hand it to the appliance plugin so guidance summaries are spoken
        // by the same voice everything else uses.
        pluginRegistry.plugins
            .compactMap { $0 as? ApplianceHelperPlugin }
            .forEach { $0.speaker = speaker }
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
            config: GeminiCommandInterpreter.Config(confidenceThreshold: 0.4),
            pluginRegistry: pluginRegistry
        )
        self.geminiCommandInterpreter = geminiInterpreter
        let router3 = IntentRouter(cache: intentCache, observabilityBus: observabilityBus)
        // Local brain = the fine-tuned intent model while its GGUF is
        // cached (spec §8), else the LLaMA interpreter as the spec's
        // "LLaMA today" stand-in. Installing the fine-tuned model bare
        // (as the merge that introduced it did) left no brain at all in
        // configurations that can't reach the cloud — the on-device
        // Whisper stack, or Gemini without a key — because the GGUF is
        // still a placeholder: every utterance fell to the generic
        // "didn't understand" re-prompt despite correct transcription.
        // `LocalBrainChain` consults the stand-in only while the
        // preferred model is unavailable, so nothing changes once the
        // fine-tuned GGUF ships.
        router3.localBrain = LocalBrainChain(preferred: localIntentInterpreter,
                                             standIn: llamaCommandInterpreter)
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
        geminiSpeechRecognizer.onPartialTranscript = { [weak self] partial in
            DispatchQueue.main.async { self?.livePartialTranscript = partial }
        }
        let router = CommandRouter(
            coordinator: self,
            observabilityBus: observabilityBus,
            speaker: speaker,
            interpreter: router3,
            pluginRegistry: pluginRegistry,
            geminiClient: geminiClient
        )
        // Start with the fallback STT. Gemini is swapped in below once an
        // API key is configured.
        voicePipeline = VoicePipeline(
            audioSession: audioSessionManager,
            audioEngine: audioEngine,
            wakeWordEngine: wakeWordEngine,
            wakeWordGate: wakeWordActivityGate,
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
            // captured — clear BOTH transcript buffers at the start of
            // every capture cycle. livePartialTranscript matters too: a
            // failed/cancelled capture skips recordTranscript's clear, so
            // the last Gemini partial survives into every later capture
            // and pins the pill to the first conversation forever
            // (2026-09-06 field report).
            lastTranscript = nil
            livePartialTranscript = nil
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
    ///
    /// 2026-09-06 (wake word #4): both functions also close/open the
    /// `WakeWordActivityGate`, which the voice pipeline consults before
    /// feeding mic audio to the wake-word engine. Self-hearing
    /// mitigation: the audio session is `.measurement` mode without AEC
    /// (AudioSessionManager), so while the assistant's own reply plays
    /// the mic hears it — including the phrase "Hey Sahayak" if the reply
    /// contained it. We suppress HERE (per-reply, reversible) rather than
    /// switching the global audio-session mode, which is a regression
    /// risk for the always-on tap and the recognizers that share it. The
    /// gate is opened on the LAST speaker finishing (speech can nest —
    /// multiple speak()s overlap during a busy turn). One benign race:
    /// `speak()` launches the TTS Task before the main-async block below
    /// runs, so the first milliseconds of a reply may not be suppressed —
    /// Porcupine needs ~a second of audio to fire the keyword, so no
    /// practical window.
    func noteSpeakingStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speakingCount += 1
            self.wakeWordActivityGate.setSpeaking(true)
            self.handlePipelineState(self.lastPipelineState)
        }
    }

    func noteSpeakingEnded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speakingCount = max(0, self.speakingCount - 1)
            self.wakeWordActivityGate.setSpeaking(self.speakingCount > 0)
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
    ///
    /// Internal (not private) because the Settings model screen calls it
    /// when a download completes — installing a model can change which
    /// recognizer/model the label should claim (e.g. a finished
    /// WhisperKit install makes the ANE recognizer available).
    func updateActiveSTTName() {
        if voiceEngineStack == .gemini, geminiSpeechRecognizer.isAvailable {
            activeSTTNameKey = "stt.name.gemini"
            return
        }
        // WhisperKit (ANE) wins the label whenever it's the recognizer the
        // on-device stack will actually use.
        if voiceEngineStack == .onDevice, whisperKitSpeechRecognizer.isAvailable {
            activeSTTNameKey = sttNameKey(for: ModelCatalog.whisperKitNepaliMedium)
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
        case ModelCatalog.whisperKitNepaliMedium:
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
        case ModelCatalog.whisperLargeV3NepaliV2:
            return "stt.name.whisperLargeNepaliV2"
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
            self?.livePartialTranscript = nil
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
    func addFamilyContact(name: String, phone: String, relationship: String,
                          messengerHandle: String? = nil) -> Bool {
        let contact = FamilyContact(name: name, phone: phone, relationship: relationship,
                                    messengerHandle: messengerHandle)
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
        /// through (e.g. "viber"), so we fell back to FaceTime —
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

    /// Rephrase-as-question state (spec §4 decision #6): a mid-band
    /// tier-`free` interpretation pended as a yes/no question. Mutually
    /// exclusive with the other pending confirmations by construction
    /// (only one is ever set at a time).
    private var pendingRephrase: (command: InterpretedCommand, sourceTranscript: String?)?
    var pendingRephraseCommand: InterpretedCommand? { pendingRephrase?.command }

    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {
        pendingRephrase = (command, sourceTranscript)
        DispatchQueue.main.async { [weak self] in
            self?.voiceSession.transition(to: .awaitingConfirmation)
        }
        speak(key: "router.rephrase.question")
    }

    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? {
        let taken = pendingRephrase
        pendingRephrase = nil
        DispatchQueue.main.async { [weak self] in
            self?.voiceSession.transition(to: .idle)
        }
        return taken
    }

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
        // Messenger needs a per-contact handle (username/user-id), not a
        // phone number — and most contacts won't have one yet. Caught
        // HERE, before the confirmation question, so the elder is never
        // asked to yes/no an action that can only fail (mirrors the
        // .ambiguous path above: nothing pended, and the returned line
        // tells them what actually unblocks it). The same normalization
        // the opener uses decides "usable", so the two checks can't
        // disagree.
        if resolved.method == .messengerAudio || resolved.method == .messengerVideo,
           CallLinks.messengerHandle(contact.messengerHandle ?? "").isEmpty {
            return L10n.fmt("router.call.messengerNoHandle", locale: activeLocale, contact.name)
        }
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
        // The requestCallConfirmation no-handle gate applies to overrides
        // too: amending to Messenger for a contact with no usable handle
        // would re-confirm an action that can only fail — the exact
        // yes/no trap that gate exists to prevent. The ORIGINAL action
        // stays pending, so "हो" still places it and a further correction
        // ("फेसटाइममा गर") still re-plans.
        if override == .messengerAudio || override == .messengerVideo,
           CallLinks.messengerHandle(action.contact.messengerHandle ?? "").isEmpty {
            speak(text: L10n.fmt("router.call.messengerNoHandle", locale: activeLocale, action.contact.name))
            return true
        }
        let amended = PendingCallAction(contact: action.contact,
                                        method: override,
                                        unsupportedRequestedApp: nil,
                                        sourceTranscript: action.sourceTranscript,
                                        sourceCommand: action.sourceCommand)
        pendingCallAction = amended
        // Flywheel gold (spec §11): original plan → corrected plan.
        intentLogStore.append(IntentLogStore.Record(
            path: "override", action: "call",
            slots: ["contact": action.contact.name, "method": action.method.rawValue],
            outcome: "corrected",
            correctedTo: ["method": override.rawValue]))
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
        case .messengerAudio: methodKey = "router.call.methodMessengerAudio"
        case .messengerVideo: methodKey = "router.call.methodMessengerVideo"
        }
        let methodText = L10n.str(methodKey, locale: locale)
        parts.append(L10n.fmt("router.call.confirmQuestion", locale: locale, action.contact.name, methodText))
        return parts.joined(separator: " ")
    }

    /// Actually places the call/opens the chat — only ever reached after
    /// the user said yes (`handleConfirmationResponse`). All URLs are
    /// built and opened by `CallLinks` (one tested home for handle
    /// normalization and app-absent decisions). Never claims WhatsApp
    /// "called" — it only opened a chat, and says so; a FaceTime
    /// link that can't open says THAT, instead of claiming a call; and
    /// Messenger "calls" are announced as an OPENED THREAD with the call
    /// button one tap away, never as a call in progress — no documented
    /// scheme can start one (see `CallLinks.messengerThreadURL`).
    private func performCallAction(_ action: PendingCallAction) {
        let locale = activeLocale
        switch action.method {
        case .phone:
            callLinks.openPhone(action.contact.phone)
            contactNumberUsed(action.contact.phone)
            setOutcome(icon: "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
            noteConfirmedCallExecution(action)
        case .facetimeVideo, .facetimeAudio:
            let isVideo = action.method == .facetimeVideo
            switch callLinks.openFaceTime(handle: action.contact.phone, video: isVideo) {
            case .opened:
                setOutcome(icon: isVideo ? "video.fill" : "phone.fill",
                           text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
                contactNumberUsed(action.contact.phone)
            case .unavailable, .invalidHandle:
                // FaceTime absent is near-impossible on a real iPhone but
                // real on simulator — say what actually happened, and
                // record NOTHING: teaching the method history / intent
                // cache from a failed open would repeat the failure.
                setOutcome(icon: "exclamationmark.triangle.fill",
                           text: L10n.str("router.call.facetimeUnavailable", locale: locale))
                speak(text: L10n.str("router.call.facetimeUnavailable", locale: locale))
            }
        case .whatsappChat:
            callLinks.openWhatsAppChat(action.contact.phone)
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, action.contact.name))
            speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, action.contact.name))
            noteConfirmedCallExecution(action)
        case .messengerAudio, .messengerVideo:
            switch callLinks.openMessengerThread(handle: action.contact.messengerHandle ?? "") {
            case .openedThread:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.messengerOpened", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
            case .fellBackToWeb:
                // Messenger app absent — the m.me chat opened in Safari
                // instead. A real surface appeared (the user CAN reach the
                // thread there), so the confirmed execution still teaches
                // the history — the disclosure is the speech, not silence.
                setOutcome(icon: "safari.fill",
                           text: L10n.fmt("home.outcome.messengerWebFallback", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.messengerWebFallback", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
            case .invalidHandle:
                // The handle went missing/invalid between confirmation and
                // execution — say what happened, record NOTHING (same rule
                // as FaceTime .unavailable: never teach from a failure).
                setOutcome(icon: "exclamationmark.triangle.fill",
                           text: L10n.fmt("router.call.messengerNoHandle", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.messengerNoHandle", locale: locale, action.contact.name))
            }
        }
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
        intentLogStore.append(IntentLogStore.Record(
            path: "model", action: "call",
            slots: ["contact": action.contact.name, "method": action.method.rawValue],
            outcome: "confirmed"))
    }

    /// Tap-originated call from a ContactTile video/audio button
    /// (contact-call-buttons task, 2026-09-06). The tap IS the
    /// confirmation (redesign precedent: the user's own hand on their own
    /// unlocked phone — the same trust model as any contacts app), so
    /// unlike the voice flow there is no PendingCallAction: resolve the
    /// contact's preferred app (contact preference → global default,
    /// baked into the model) and open it immediately, announcing aloud
    /// which surface actually appeared — the same dual-channel honesty
    /// `performCallAction` holds to. No method-history learning here:
    /// the contact's stored preference IS this path's source of truth,
    /// and `CallMethod` has no messenger case to record.
    func performContactCall(_ contact: FamilyContact, kind: ContactCallKind) {
        let locale = activeLocale
        let app = kind == .video ? contact.resolvedVideoApp : contact.resolvedAudioApp
        observabilityBus.emit(ObservabilityEvent(
            component: "contact_call_buttons",
            eventType: "tap",
            durationMs: nil,
            outcome: "\(kind == .video ? "video" : "audio"):\(app.rawValue)",
            errorCode: nil,
            metadata: [:]  // no contact identifiers — C9 policy
        ))
        switch app {
        case .faceTime:
            // Video-only in the button vocabulary; `resolvedVideoApp`
            // already guarantees an audio tap never lands here.
            switch callLinks.openFaceTime(handle: contact.phone, video: true) {
            case .opened:
                setOutcome(icon: "video.fill",
                           text: L10n.fmt("home.outcome.callPlaced", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.faceTimeVideo", locale: locale, contact.name))
                contactNumberUsed(contact.phone)
            case .unavailable, .invalidHandle:
                setOutcome(icon: "exclamationmark.triangle.fill",
                           text: L10n.str("router.call.facetimeUnavailable", locale: locale))
                speak(text: L10n.str("router.call.facetimeUnavailable", locale: locale))
            }
        case .phone:
            guard callLinks.openPhone(contact.phone) else {
                announceNoUsableNumber(contact: contact, locale: locale)
                return
            }
            contactNumberUsed(contact.phone)
            setOutcome(icon: "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, contact.name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, contact.name))
        case .messenger:
            switch callLinks.openMessengerChat(phone: contact.phone) {
            case .openedApp:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.messenger", locale: locale, contact.name))
            case .openedWebChat:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.messengerWebFallback", locale: locale, contact.name))
            case .invalidHandle:
                announceNoUsableNumber(contact: contact, locale: locale)
            }
        case .whatsApp:
            switch callLinks.openWhatsAppCallChat(contact.phone) {
            case .openedChat:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, contact.name))
            case .needsNativeCompose:
                // WhatsApp absent → native Messages sheet to the same
                // number (task's sms/copy chain), disclosed out loud.
                presentMessageDraft(contact: contact, body: "")
                speak(text: L10n.fmt("call.announce.whatsAppSmsFallback", locale: locale, contact.name))
            case .copiedNumber:
                setOutcome(icon: "doc.on.doc.fill",
                           text: L10n.fmt("home.outcome.numberCopied", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.whatsAppCopiedFallback", locale: locale, contact.name))
            case .invalidPhone:
                announceNoUsableNumber(contact: contact, locale: locale)
            }
        }
    }

    /// Dial a SYSTEM-address-book search result (Phone leaf search,
    /// system-contacts search task 2026-09-06) — plain GSM audio call,
    /// the one surface a random phone-book row implies (there is no
    /// per-contact `FamilyContact` preference behind it). Dialed through
    /// `PhoneDialer.url(for:)`, the helper the emergency icon in the same
    /// leaf chrome already uses (`RedesignComponents`) — per the task;
    /// the family paths keep dialing via `CallLinks`, which builds the
    /// same `tel:` with stricter '+' handling. A dialable row can't
    /// really fail, but if it somehow does, say so aloud instead of
    /// going silent. The number enters the recency ranking only after
    /// the dial actually opened.
    func performSystemContactCall(name: String, phone: String) {
        guard let url = PhoneDialer.url(for: phone) else {
            setOutcome(icon: "exclamationmark.triangle.fill",
                       text: L10n.fmt("call.announce.noPhoneNumber", locale: activeLocale, name))
            speak(text: L10n.fmt("call.announce.noPhoneNumber", locale: activeLocale, name))
            return
        }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
        contactNumberUsed(phone)
        setOutcome(icon: "phone.fill",
                   text: L10n.fmt("home.outcome.callPlaced", locale: activeLocale, name))
        speak(text: L10n.fmt("router.call.calling", locale: activeLocale, name))
    }

    /// WhatsApp surface for a SYSTEM-address-book search row (unified
    /// contact search, 2026-09-06). No `FamilyContact` preference stands
    /// behind a phone-book row, so the tap opens WhatsApp's chat to the
    /// number when the app is installed, and otherwise walks the same
    /// absent-app chain as `performContactCall`'s whatsApp case —
    /// native Messages sheet, else the number on the pasteboard — each
    /// swap disclosed out loud. No recency entry: opening a chat is not
    /// a call (consistent with the family whatsApp button).
    func performSystemContactWhatsApp(name: String, phone: String) {
        let locale = activeLocale
        switch callLinks.openWhatsAppCallChat(phone) {
        case .openedChat:
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, name))
            speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, name))
            noteSearchChannelTap(outcome: "whatsapp:openedChat")
        case .needsNativeCompose:
            // WhatsApp absent → the same native Messages sheet to the
            // same number the family whatsApp button falls back to.
            presentMessageDraft(phone: phone, name: name, body: "")
            speak(text: L10n.fmt("call.announce.whatsAppSmsFallback", locale: locale, name))
            noteSearchChannelTap(outcome: "whatsapp:needsNativeCompose")
        case .copiedNumber:
            setOutcome(icon: "doc.on.doc.fill",
                       text: L10n.fmt("home.outcome.numberCopied", locale: locale, name))
            speak(text: L10n.fmt("call.announce.whatsAppCopiedFallback", locale: locale, name))
            noteSearchChannelTap(outcome: "whatsapp:copiedNumber")
        case .invalidPhone:
            // The number normalized to nothing dialable — defensive (the
            // search layer filters such rows), never a silent dead tap.
            setOutcome(icon: "exclamationmark.triangle.fill",
                       text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, name))
            speak(text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, name))
            noteSearchChannelTap(outcome: "whatsapp:invalidPhone")
        }
    }

    /// Messenger thread for a SYSTEM-address-book search row — the
    /// messenger analogue of `performSystemContactWhatsApp`, keyed on
    /// the person's Messenger handle (a row shows the pill only when one
    /// is on file). Same tap model and disclosures as `performContactCall`'s
    /// messenger case: the thread opens in-app when Messenger is
    /// installed, as the m.me web chat in Safari when it is not, and a
    /// missing handle opens nothing and says so. No recency entry.
    func performSystemContactMessenger(name: String, handle: String) {
        let locale = activeLocale
        switch callLinks.openMessengerThread(handle: handle) {
        case .openedThread:
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.messengerOpened", locale: locale, name))
            speak(text: L10n.fmt("call.announce.messenger", locale: locale, name))
            noteSearchChannelTap(outcome: "messenger:openedThread")
        case .fellBackToWeb:
            // Messenger absent — the m.me chat opened in Safari instead;
            // the same web-fallback disclosure the family messenger
            // path speaks, so the user knows which surface appeared.
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.messengerOpened", locale: locale, name))
            speak(text: L10n.fmt("call.announce.messengerWebFallback", locale: locale, name))
            noteSearchChannelTap(outcome: "messenger:fellBackToWeb")
        case .invalidHandle:
            // Handle missing or unusable — nothing opened; say what
            // happened (same line `performContactCall` speaks for an
            // unusable messenger handle), never teach from a failure.
            setOutcome(icon: "exclamationmark.triangle.fill",
                       text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, name))
            speak(text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, name))
            noteSearchChannelTap(outcome: "messenger:invalidHandle")
        }
    }

    /// One observability event per channel tap from the unified search
    /// rows, the outcome naming which surface actually appeared (or
    /// which fallback ran).
    private func noteSearchChannelTap(outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "contact_search_channels",
            eventType: "tap",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]  // no contact identifiers — C9 policy
        ))
    }

    /// Recency hook for the Phone leaf's search ranking: every number a
    /// call was genuinely placed to from this app — voice flow, family
    /// tiles, system-contact search rows — lands in `callRecencyStore`.
    /// One line per OPENED call, never for a failed one: a call that
    /// didn't happen must not make its number look recently used.
    private func contactNumberUsed(_ phone: String) {
        callRecencyStore.record(phone: phone)
    }

    /// Normalized-number → last-call-date index for ranking search
    /// results ("most recently used first"). The CallView loads it once
    /// per screen visit, not per keystroke.
    var contactCallRecency: [String: Date] { callRecencyStore.recentCalls() }

    /// Shared honest line for a contact whose stored phone normalizes to
    /// nothing dialable — defensive (the editors require a number), but a
    /// silent dead button is exactly what this feature must never ship.
    private func announceNoUsableNumber(contact: FamilyContact, locale: Locale) {
        setOutcome(icon: "exclamationmark.triangle.fill",
                   text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, contact.name))
        speak(text: L10n.fmt("call.announce.noPhoneNumber", locale: locale, contact.name))
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

    /// Asks the registered NepaliCalendarPlugin a question and returns
    /// its spoken answer, or nil when the plugin doesn't apply (non-
    /// Nepali locale), the assistant isn't configured, or the call
    /// fails — callers must treat nil as "hide this", never show an
    /// error string for a decorative display.
    func nepaliCalendarAnswer(question: String) async -> String? {
        guard let plugin = pluginRegistry?.plugin(handling: "nepali_calendar.query",
                                                  locale: activeLocale),
              geminiConfigStore.isConfigured else { return nil }
        let command = PluginCommand(actionName: "nepali_calendar.query",
                                    transcript: "",
                                    entities: ["question": question],
                                    confidence: 1.0)
        let context = PluginExecutionContext(locale: activeLocale,
                                             geminiClient: geminiClient,
                                             observabilityBus: observabilityBus)
        let result = await plugin.handle(command, context: context)
        switch result {
        case .spoken(let text), .spokenAndPresented(let text):
            return text
        case .failed:
            return nil
        }
    }

    /// One line with today's Nepali (Bikram Sambat) and Hindu calendar
    /// dates, for the Home top strip (2026-09-06). Fetched at most once
    /// per calendar day via a single search-grounded call, cached in
    /// UserDefaults (not secret); nil when unavailable, and the strip
    /// simply hides.
    @Published private(set) var homeCalendarLine: String?
    private static let homeCalendarLineDefaultsKey = "homeCalendarLine.v1"

    /// Refreshes `homeCalendarLine` — fully OFFLINE since the BS
    /// calendar work (2026-09-06): BS date + tithi + any festival today,
    /// computed locally (BikramSambat/TithiCalculator/FestivalCalendarService).
    /// No network, no cache, no cost, correct every day. The previous
    /// search-grounded answer was slower, cost a call a day, and couldn't
    /// show tithi at all.
    func refreshHomeCalendarLineIfNeeded() {
        guard homeCalendarLine == nil else { return }
        guard let overlay = festivalCalendar.todayOverlay() else { return }
        var parts = ["\(overlay.weekdayNepali), \(BikramSambat.nepaliString(overlay.bsDate))"]
        parts.append(overlay.tithi.displayNepali)
        if let festival = overlay.festivals.first {
            parts.append(festival.nameNepali)
        }
        homeCalendarLine = parts.joined(separator: " • ")
    }

    /// A plugin-provided view awaiting presentation (`.plugin` intent,
    /// `PluginResult.spokenAndPresented`) — ContentView renders it as a
    /// sheet, same pattern as `pendingMessageDraft`.
    struct PluginPresentation: Identifiable {
        let id = UUID()
        let view: AnyView
    }
    @Published var pendingPluginPresentation: PluginPresentation?

    /// `VoiceCommandCoordinating.presentPluginView` — a plugin's
    /// `presentationView(for:)` result, published for ContentView.
    func presentPluginView(_ view: AnyView) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingPluginPresentation = PluginPresentation(view: view)
        }
    }

    /// Design §4 "Show Me" button path: a dock tile presents the
    /// appliance camera surface directly with no question attached —
    /// skipping the LLM round trip entirely (the tap IS the intent, so
    /// there is no ambiguity to resolve). The voice path goes through
    /// `ApplianceHelperPlugin.handle` instead. 2026-09-06: until now only
    /// the voice path existed; the dock tile was designed but unbuilt.
    func presentApplianceHelper(question: String?) {
        guard geminiClient.isAvailable else {
            speak(text: L10n.str("plugin.applianceHelper.notConfigured", locale: activeLocale))
            return
        }
        let session = ApplianceHelperSession(question: question,
                                             locale: activeLocale,
                                             geminiClient: geminiClient,
                                             cache: ApplianceCache(storage: storage),
                                             observabilityBus: observabilityBus,
                                             speaker: speaker)
        presentPluginView(AnyView(ApplianceHelperView(session: session)))
    }

    /// `send_message` (v2 pivot Phase 2, §4.3). Every surface ends with
    /// the user's own tap on Send — that tap IS the `.confirm`-tier
    /// confirmation, exactly as the shipped SMS flow models it:
    ///  - WhatsApp named ("वाट्सएपमा मेसेज पठा") → `whatsapp://send` deep
    ///    link with the body pre-filled; app-absent falls back to the
    ///    native Messages sheet, then to a pasteboard copy — each
    ///    disclosed out loud, never silently swapped.
    ///  - nothing named → the native compose sheet (shipped behavior).
    func composeMessage(toContactNamed query: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome {
        let locale = activeLocale
        if let app = requestedApp, !app.isEmpty, CallLinks.isWhatsAppName(app) {
            guard let query, let contact = resolveSingleContact(query) else { return .contactNotFound }
            switch callLinks.openWhatsAppText(contact.phone, text: body) {
            case .openedWhatsApp:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.whatsappMessageReady", locale: locale, contact.name))
                speak(text: L10n.fmt("router.message.whatsappReady", locale: locale, contact.name))
                return .whatsAppChatOpened
            case .needsNativeCompose:
                presentMessageDraft(contact: contact, body: body)
                speak(text: L10n.fmt("router.message.whatsappMissingFallback", locale: locale, contact.name))
                return .fellBackToNativeCompose
            case .copiedText:
                setOutcome(icon: "doc.on.doc.fill",
                           text: L10n.fmt("home.outcome.messageCopied", locale: locale, contact.name))
                speak(text: L10n.fmt("router.message.copiedFallback", locale: locale, contact.name))
                return .copiedTextOnly
            case .invalidPhone:
                return .contactNotFound
            }
        }
        guard MFMessageComposeViewController.canSendText(),
              let query, let contact = resolveSingleContact(query) else { return .contactNotFound }
        presentMessageDraft(contact: contact, body: body)
        return .nativeComposePresented
    }

    /// Presents the native compose sheet pre-filled (shipped SMS path,
    /// extracted so the WhatsApp-absent fallback lands on the exact same
    /// surface). The phone/name variant below serves rows that carry no
    /// `FamilyContact` (system address-book search) — this one delegates.
    private func presentMessageDraft(contact: FamilyContact, body: String) {
        presentMessageDraft(phone: contact.phone, name: contact.name, body: body)
    }

    /// Phone/name variant of `presentMessageDraft(contact:body:)` — same
    /// sheet, same outcome line, no `FamilyContact` required.
    private func presentMessageDraft(phone: String, name: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingMessageDraft = MessageDraft(recipients: [phone], body: body)
        }
        setOutcome(icon: "message.fill",
                   text: L10n.fmt("home.outcome.messageReady", locale: activeLocale, name))
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
        calendarSync.syncNow(entries: routineScheduler.entries())
        return nil
    }

    /// Removes a medication entry and re-arms (spec §4.4.3).
    func removeMedication(id: UUID) {
        var entries = medicationScheduler.medicationEntries()
        entries.removeAll { $0.id == id }
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
        calendarSync.syncNow(entries: routineScheduler.entries())
    }

    // MARK: - Native Calendar mirroring (v2 design §4.1, 2026-09-06)

    /// EventKit mirror of the unified routine schedule — the app remains
    /// the source of truth; the native Calendar is a read mirror so
    /// family can see the routine in any calendar app. Permission
    /// denial = honest local-only mode, never a crash. Mirrors the
    /// peer reminders-v2 `RoutineEntry` model (which owns categories
    /// natively — the parallel tag-store approach from the same merge
    /// was dropped in favor of it).
    private(set) lazy var calendarSync = CalendarSyncService(observabilityBus: observabilityBus)

    /// Offline Bikram Sambat + tithi + festival overlay and festival
    /// notification scheduling (2026-09-06 BS calendar feature).
    private(set) lazy var festivalCalendar = FestivalCalendarService(observabilityBus: observabilityBus)

    /// Settings toggle handler: enable calendar mirroring (requests
    /// EventKit access at point of use) or disable it.
    func setCalendarSyncEnabled(_ enabled: Bool) async {
        calendarSync.isEnabled = enabled
        if enabled {
            await calendarSync.enableAndSync(entries: routineScheduler.entries())
        }
    }

    // MARK: - Routine reminder surface (v2 pivot Phase 1)

    /// All configured routine entries (seeded categories + voice-created)
    /// — the Reminders leaf's manage list.
    var routineEntries: [RoutineEntry] { routineScheduler.entries() }

    /// Today's routine occurrences, sorted — listed in the Reminders
    /// leaf alongside the medication doses.
    var todaysRoutineOccurrences: [RoutineOccurrence] {
        routineScheduler.todaysOccurrences()
    }

    func routineEntry(for id: UUID) -> RoutineEntry? {
        routineScheduler.entry(for: id)
    }

    /// Enable/disable a routine entry from the Reminders leaf toggle;
    /// persists and re-arms through the scheduler.
    func setRoutineEntryEnabled(_ entryId: UUID, enabled: Bool) {
        routineScheduler.setEnabled(entryId, enabled: enabled)
    }

    /// Today's medication reminders as localized "name — time" lines for
    /// the routine plugin's `routine.query` answer — one spoken list
    /// spanning both reminder systems.
    private func todayMedicationSummaryLines() -> [String] {
        medicationScheduler.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .map { reminder in
                let name = medicationName(for: reminder.medicationEntryId)
                let time = reminder.scheduledAt.formatted(
                    Date.FormatStyle(date: .omitted, time: .shortened).locale(activeLocale))
                return "\(name) — \(time)"
            }
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
    var isAwaitingConfirmation: Bool {
        pendingConfirmationEntryId != nil || pendingCallAction != nil || pendingRephrase != nil
    }

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
            self?.routineScheduler.scheduleAll()
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Wake-word engine selection & status (open item #4)

    /// Builds the launch wake-word engine and reports whether it is REAL
    /// (Porcupine) or the Null fallback — Settings → "Voice activation"
    /// needs that truth for its status row.
    ///
    /// Decision order (2026-09-06):
    ///  1. The persisted Settings toggle is the master switch: OFF means
    ///     NullWakeWordEngine even when an access key + .ppn are both
    ///     present (the open-item requirement — disabled must behave
    ///     exactly like today).
    ///  2. Access key: build-time Info.plist `PicovoiceAccessKey`, else
    ///     the Settings paste-in value in `EncryptedLocalStorage`
    ///     (`wakeWordAccessKeyStore` — Keychain, Data Protection
    ///     Complete).
    ///  3. The trained keyword file must be in the bundle
    ///     (hey-sahayak_ios.ppn).
    ///  4. Porcupine init must succeed (a malformed key throws).
    ///
    /// The pure decision table lives in `WakeWordEngineSelection`
    /// (unit-tested without the Porcupine package linked); only the real
    /// engine's construction is Porcupine-guarded, below.
    private static func makeWakeWordEngine(accessKeyStore: WakeWordAccessKeyStore)
        -> (engine: WakeWordEngine, isReal: Bool) {
        guard let real = WakeWordEngineSelection.make(
            toggleEnabled: WakeWordPreferences().isEnabled,
            accessKey: configuredAccessKey(accessKeyStore: accessKeyStore),
            keywordPath: WakeWordModelFile.bundledPath(),
            build: buildRealWakeWordEngine
        ) else {
            print("[AppCoordinator] Wake-word engine: NullWakeWordEngine "
                  + "(toggle off, artifact missing, or Porcupine init failed) — "
                  + "Talk button + simulate path unchanged")
            return (NullWakeWordEngine(), false)
        }
        return (real, true)
    }

    /// The Picovoice access key for this build: the Info.plist value
    /// (`PicovoiceAccessKey`, embedded at build time for team builds)
    /// wins; otherwise the Settings paste-in value. The precedence rule
    /// itself is `WakeWordAccessKeyStore.resolvedAccessKey` (unit-tested).
    private static func configuredAccessKey(accessKeyStore: WakeWordAccessKeyStore) -> String? {
        WakeWordAccessKeyStore.resolvedAccessKey(
            plistKey: Bundle.main.object(forInfoDictionaryKey: "PicovoiceAccessKey") as? String,
            storedKey: accessKeyStore.accessKey
        )
    }

    #if canImport(Porcupine)
    /// Attempts the real engine — compiles only when the Porcupine SPM
    /// package is linked into the build (project.yml keeps it commented
    /// until a key + trained .ppn exist — docs/wake-word-setup.md).
    private static func buildRealWakeWordEngine(accessKey: String, keywordPath: String) -> WakeWordEngine? {
        try? PorcupineWakeWordEngine(accessKey: accessKey, keywordPath: keywordPath)
    }
    #else
    /// Porcupine is not linked into this build — the selection logic above
    /// still runs so Settings can report the honest "runtime missing"
    /// status, but no real engine can be built.
    private static func buildRealWakeWordEngine(accessKey: String, keywordPath: String) -> WakeWordEngine? {
        nil
    }
    #endif

    /// Compile-time: is the Porcupine runtime linked into THIS build?
    /// Mirrors the `#if canImport(Porcupine)` around the real engine so
    /// the Settings status can never claim "Active" for a build whose
    /// engine is Null by construction.
    static var isWakeWordRuntimeLinked: Bool {
        #if canImport(Porcupine)
        return true
        #else
        return false
        #endif
    }

    /// True when an access key is available to this build — the build-time
    /// Info.plist value, or the Settings paste-in (EncryptedLocalStorage).
    var isWakeWordAccessKeyConfigured: Bool {
        Self.configuredAccessKey(accessKeyStore: wakeWordAccessKeyStore) != nil
    }

    /// True when THIS build has everything the real engine needs: runtime
    /// linked, an access key, and the bundled keyword file — the same
    /// inputs `makeWakeWordEngine()` decides on, so the status row and the
    /// actually-built engine cannot disagree.
    var isWakeWordProvisioned: Bool {
        Self.isWakeWordRuntimeLinked
            && Self.configuredAccessKey(accessKeyStore: wakeWordAccessKeyStore) != nil
            && WakeWordModelFile.bundledPath() != nil
    }

    /// Honest state for the Settings "Voice activation" row/screen
    /// (derivation unit-tested in `WakeWordStatusResolver`).
    var wakeWordStatus: WakeWordStatus {
        WakeWordStatusResolver.status(
            enabled: wakeWordEnabled,
            isProvisioned: isWakeWordProvisioned,
            realEngineAtLaunch: wakeWordEngineRealAtLaunch
        )
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
