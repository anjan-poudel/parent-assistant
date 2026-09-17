import Foundation
import AVFoundation
import BackgroundTasks
import Combine
import UserNotifications
import UIKit
import MessageUI
import SwiftUI
// [TIMER-ALARM] AlarmKit (iOS 26) — used only inside `@available`-gated
// code; the import itself is inert on older deployment targets.
import AlarmKit

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
            // Model preferences only churn on a REAL change: re-tapping the
            // already-selected language must not override a deliberate
            // model pick (e.g. an English STT chosen while running Nepali).
            if appLanguage != oldValue {
                syncModelPreferencesToLanguage()
            }
        }
    }

    /// The locale every piece of non-View code (router speech, formatters)
    /// resolves against.
    var activeLocale: Locale { appLanguage.locale }

    /// [LIVE-TRANSLATE T-015] The consent prompt/control state, shared by the
    /// session view's prompt and the Settings leaf so both drive the one gate
    /// above. Built on first use, on the main actor, against the language in
    /// force at that moment; the locale is refreshed when the surfaces appear.
    @MainActor
    func liveTranslateConsentController() -> ConsentPromptController {
        if let existing = consentController { return existing }
        let controller = ConsentPromptController(gate: liveTranslateConsentGate,
                                                 observabilityBus: observabilityBus,
                                                 locale: activeLocale)
        consentController = controller
        return controller
    }

    /// [LIVE-TRANSLATE T-014] The consent gate itself — the decision the cloud
    /// tier must ask for. Read-only for callers: recording and revocation go
    /// through the prompt/control, which is the only pair of writers the
    /// design sanctions.
    var liveTranslateConsentDecision: LiveTranslateConsentGate.Decision {
        liveTranslateConsentGate.currentDecision()
    }

    /// The region-qualified app locale — the Settings locale row's
    /// binding (encoder-branch SettingsView, 2026-09-14). Bridged to
    /// `AppLocale`'s own UserDefaults persistence; `activeLocale` keeps
    /// following the language default until the locale-override wiring is
    /// completed by the encoder-branch work.
    var appLocale: AppLocale {
        get { AppLocale.persisted(for: appLanguage) }
        set { newValue.persist() }
    }

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
        externalCalendar.locale = activeLocale
        alarmTimersService.locale = activeLocale
        alarmTimersService.setSystemSchedulerLocale(activeLocale)
        // Voice-OS shell v1: the briefing composes in the app language,
        // same injection pattern as every other locale-aware service.
        morningBriefing?.locale = activeLocale
        // [NEWS-READER] (2026-09-08) The news digest composes in the app
        // language too — same injection pattern.
        newsReader?.locale = activeLocale
    }

    /// Language-aware model selection (2026-09-13): the app language picks
    /// the models too, not just the strings.
    ///
    /// Runs on every app-language change (from `appLanguage`'s didSet,
    /// next to `syncServiceLocales()`) and re-resolves the three stored
    /// model preferences through `LanguageModelResolver`:
    ///   - STT (`sttModelPreference`),
    ///   - brain (`brainModelPreference`),
    ///   - reply voice (`ResponseVoiceSelection`, the `ttsResponseVoiceSelection`
    ///     UserDefaults payload).
    ///
    /// A preference whose model is tagged for other languages only
    /// switches to the per-kind default for the new language (a Nepali
    /// Whisper engine cannot transcribe English, and vice versa). A
    /// language-neutral (`[]`) or matching model is left exactly alone —
    /// a user's chosen intent brain survives every switch to a language it
    /// serves. A `nil` preference ("Automatic") is never touched: it is
    /// the user's statement that the app should decide.
    ///
    /// Writes go through the published properties, so the existing
    /// side-effect chains run unchanged: the STT pick reaches the
    /// recognizer (`sttModelPreference` didSet), the brain pick hot-swaps
    /// the interpreter and starts the model's download when it is not
    /// cached (`brainModelPreference` didSet — the same contract as a
    /// manual pick), and the voice pick persists + sanitation-checks
    /// through `ResponseVoiceSelection`. The voice re-pick prefers the
    /// language's REMEMBERED user choice over the default map (fix 2), so
    /// an en→ne→en round trip returns to the household's own voice; that
    /// memory is written only by the Settings picker (`remember`), never
    /// by this automatic switch.
    ///
    /// [MODEL-MEMORY 2026-09-16] The STT and brain re-picks now prefer the
    /// language's remembered pick the same way (`ModelPreferenceMemory`,
    /// PR 1 of the settings/models reorg): before this, the single stored
    /// STT/brain preference was flattened to the per-language default on
    /// every switch, so a ne→en→ne round trip destroyed an explicit engine
    /// choice. That memory too is written ONLY by the Settings pickers —
    /// this switch reads it, never writes it.
    ///
    /// Note this deliberately does NOT run at launch: the init-time
    /// restore assigns the preferences directly (house pattern), and a
    /// launch-time reconciliation — a language stored in a previous
    /// version of the app against a now-incompatible model — is a separate
    /// follow-up, not wired into the boot phases here.
    private func syncModelPreferencesToLanguage() {
        let language = appLanguage.rawValue
        if let resolved = LanguageModelResolver.resolvedPreference(
            current: sttModelPreference,
            language: language,
            remembered: ModelPreferenceMemory.rememberedSTT()),
           resolved != sttModelPreference {
            sttModelPreference = resolved
        }
        if let resolved = LanguageModelResolver.resolvedPreference(
            current: brainModelPreference,
            language: language,
            remembered: ModelPreferenceMemory.rememberedBrain()),
           resolved != brainModelPreference {
            brainModelPreference = resolved
        }
        let voice = ResponseVoiceSelection.persisted()
        if let resolved = LanguageModelResolver.resolvedVoicePreference(
            current: voice,
            language: language,
            remembered: ResponseVoiceSelection.rememberedVoices()),
           resolved != voice {
            ResponseVoiceSelection.apply(resolved)
        }
    }

    /// First-run onboarding progress (spec §4.2). Persisted per step.
    let onboardingState = OnboardingState()

    /// UI-facing voice session machine (spec §3.3). Mutations are confined
    /// to the main queue (this class routes every published mutation
    /// through `DispatchQueue.main.async` — review H1).
    let voiceSession = VoiceSessionStateMachine()

    /// [STARTUP-PERF] Progressive startup progress — the Home spinner's
    /// honest stage labels and failure degradation. Injected into the
    /// environment by `ElderlyAssistantApp` next to `voiceSession`.
    let startupBoot = StartupBoot()

    /// [STARTUP-PERF] Serial queue for the heavy boot phases (keychain
    /// store loads, first-run bundled-model installs). Every PUBLISHED
    /// assignment still hops to main; this queue only carries
    /// thread-safe store/file work. (The sherpa KWS build is deliberately
    /// NOT here — the runtime segfaults off-main on the x86_64
    /// simulator; see `bootPrepareVoiceEngine`.)
    private let bootQueue = DispatchQueue(label: "senios.startup.boot",
                                          qos: .userInitiated)

    /// [BOOT-REVIEW P1-5] Utility-QoS serial queue for model
    /// housekeeping — stale-encoder cleanup and the bundled STT model's
    /// first-use install. Housekeeping is explicitly NOT user-blocking
    /// work: it must never sit on the boot queue (which gates `.ready`)
    /// or on main.
    private let modelHousekeepingQueue = DispatchQueue(
        label: "senios.models.housekeeping",
        qos: .utility
    )
    /// One bundled-STT install at a time (the install is idempotent, but
    /// re-entrancy would queue a second useless copy attempt).
    private var bundledSTTInstallInFlight = false

    /// [STT-RESTORE] Watches `ModelDownloadService` for a landed ANE
    /// artifact so the restored engine reaches the live pipeline (see
    /// `observeSTTArtifactCompletion`).
    private var sttArtifactCompletionCancellable: AnyCancellable?

    /// User's STT model pick from the UI. Nil = automatic selection.
    /// Persisted in UserDefaults (a UI preference, not a secret) and
    /// pushed to WhisperSpeechRecognizer so it survives restarts.
    /// (Spec §4.4.4 — the Settings AI मोडेल section is this picker's home.)
    @Published var sttModelPreference: ModelID? {
        didSet {
            UserDefaults.standard.set(sttModelPreference?.rawValue,
                                      forKey: Self.sttPreferenceKey)
            whisperSpeechRecognizer.setPreferredModel(sttModelPreference)
            // [STT-SWITCHER] The ANE (WhisperKit) recognizer takes the pick
            // too — without this line the selection never reached the
            // engine DEVICES actually run (`OnDeviceSTTSelection` favors
            // WhisperKit whenever it is available), so the status caption
            // kept naming the v3 default while the user's pick was
            // ignored. The recognizer adopts the id only when it names a
            // WhisperKit-delivered artifact; a ggml pick stays with the
            // CPU recognizer above (see `setPreferredModel`).
            //
            // The lazy accessor may be FORCED here on the first pick
            // change. That is accepted (it mirrors the whisper.cpp line
            // above, which forces its own recognizer + `modelStore` the
            // same way, and `updateActiveSTTName()` below already touches
            // this lazy) and cannot run during `init()`: a property
            // observer never fires for the init-time restore assignment,
            // so the factory's `sttModelPreference` read always happens
            // after the restore.
            whisperKitSpeechRecognizer.setPreferredModel(sttModelPreference)
            updateActiveSTTName()
        }
    }
    private static let sttPreferenceKey = "sttModelPreference"
    private static let noiseFilterEnabledKey = "noiseFilterEnabled"

    /// The app-wide background theme (skinnable home, 2026-09-07) — a UI
    /// preference, not a secret, persisted in UserDefaults the same way as
    /// `sttModelPreference`. Every screen draws its background from this
    /// through the `Color(theme:)` helper, so one change re-skins the
    /// whole app at once. didSet persists; the init-time restore assigns
    /// directly (house pattern — didSet does not fire there).
    @Published var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: Self.themeKey)
        }
    }
    private static let themeKey = "appTheme"

    /// The app an ADDRESS-BOOK row's call button opens when the row has no
    /// per-contact channel pick saved — per-row picks live in
    /// `channelPreferenceStore`, and a row without one resolves here
    /// (Phone-tab redesign, 2026-09-07). The Settings → Calling screen's
    /// picker binds this. A UI preference, not a secret — persisted in
    /// UserDefaults the same way as `appTheme`. didSet persists; the
    /// init-time restore assigns directly (house pattern — didSet does
    /// not fire there).
    @Published var defaultCallApp: CallApp {
        didSet {
            UserDefaults.standard.set(defaultCallApp.rawValue, forKey: Self.defaultCallAppKey)
        }
    }
    private static let defaultCallAppKey = "defaultCallApp"

    /// Which map surface voice navigation opens (directions task,
    /// 2026-09-07) — Settings → Places. `.auto` (the default) opens
    /// Google Maps when installed, else Apple Maps, else the in-app map;
    /// the override expresses PREFERENCE, never a promise — the open
    /// decision re-derives installed-ness at request time via
    /// `NavigationMapPolicy` (a deleted Google Maps falls through, it
    /// never dead-ends). A UI preference, not a secret — persisted in
    /// UserDefaults the same way as `appTheme`. didSet persists; the
    /// init-time restore assigns directly (house pattern — didSet does
    /// not fire there).
    @Published var navigationMapApp: NavigationMapApp {
        didSet {
            UserDefaults.standard.set(navigationMapApp.rawValue, forKey: Self.navigationMapAppKey)
        }
    }
    private static let navigationMapAppKey = "navigationMapApp"

    /// Which brain model the local LLaMA interpreter runs (Settings →
    /// "AI मोडेल" → Assistant brain, 2026-09-06). nil = the default
    /// (`defaultBrainModelID`). Persisted in UserDefaults the same way
    /// as `sttModelPreference` — a UI preference, not a secret. Setting
    /// this hot-swaps the interpreter's base model and starts the chosen
    /// model's download when it isn't cached (the STT picker's contract:
    /// a fresh pick works immediately).
    @Published var brainModelPreference: ModelID? {
        didSet {
            UserDefaults.standard.set(brainModelPreference?.rawValue,
                                      forKey: Self.brainPreferenceKey)
            applyBrainModel()
        }
    }
    private static let brainPreferenceKey = "brainModelPreference"

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

    /// Whether the ON-DEVICE stack may escalate questions its local
    /// chain cannot answer (an abstention / mid-band drop) to the cloud
    /// brain (cloud-fallback task, 2026-09-07) — a second, OPT-IN layer
    /// on top of `voiceEngineStack`. OFF by default: the old "strictly
    /// on-device" contract survives until the household switches this
    /// on, and even then escalation happens ONLY while the Gemini
    /// interpreter is actually available (see
    /// `CloudProvider.cloudFallbackEngages`) — the .gemini stack's
    /// hybrid behavior is untouched and ignores this flag. A UI
    /// preference, not a secret — persisted in UserDefaults the same
    /// way as `voiceEngineStack`. didSet persists AND re-applies the
    /// stack, so flipping the toggle in Settings acts immediately (the
    /// same instant-apply rule as the engine toggle itself).
    @Published var cloudFallbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cloudFallbackEnabled, forKey: Self.cloudFallbackKey)
            applyVoiceEngineStack()
        }
    }
    private static let cloudFallbackKey = "cloudFallbackEnabled"

    /// Voice Processing I/O A/B gate (voice-personalisation P0, slice C,
    /// 2026-09-08): when ON, the audio session activates with the VPIO
    /// preset (`.voiceChat` mode + `setVoiceProcessingEnabled(true)` on
    /// the engine's input node — AEC + built-in noise suppression below
    /// the tap, phone-call-tuned). Default OFF: today's `.measurement`
    /// behavior stays byte-identical. The persisted source of truth lives
    /// on `AudioSessionManager` (its `voiceProcessingEnabled`, under
    /// UserDefaults "voiceProcessingEnabled"); this published mirror is
    /// the composition-root seam a Settings row / remote-config A/B flips.
    /// didSet pushes the new value to the manager (which persists it) AND
    /// re-applies the preset — the session re-activates under the new
    /// configuration immediately (see `applyVoiceProcessingPresetChange`).
    /// The init-time restore assigns the mirror directly (house pattern —
    /// didSet does not fire there) after the manager composed above has
    /// already read the persisted value.
    @Published var voiceProcessingEnabled: Bool {
        didSet {
            guard voiceProcessingEnabled != oldValue else { return }
            audioSessionManager.voiceProcessingEnabled = voiceProcessingEnabled
            applyVoiceProcessingPresetChange()
        }
    }

    /// Spectral-gate noise filter A/B gate ([NOISE-FILTER] P1 front-end,
    /// 2026-09-08). ON = the voice pipeline's CAPTURE stream runs through
    /// `SpectralGateDenoiser` — the model-free classic DSP spectral gate
    /// (conservative stationary-noise suppression; NOT DeepFilterNet3 —
    /// that needs model artifacts, P1 step 2 — see the gap note in
    /// SpectralGateDenoiser). The VPIO session preset is untouched by
    /// this toggle (independent A/B arms). Default OFF: the capture path
    /// is byte-identical to today's. Unlike the VPIO preset, this stage
    /// hot-swaps WITHOUT a pipeline recycle (`setNoiseSuppressor`).
    /// Persisted under UserDefaults "noiseFilterEnabled" (a UI
    /// preference, not a secret — house pattern).
    @Published var noiseFilterEnabled: Bool {
        didSet {
            guard noiseFilterEnabled != oldValue else { return }
            UserDefaults.standard.set(noiseFilterEnabled,
                                      forKey: Self.noiseFilterEnabledKey)
            applyNoiseFilterChange()
        }
    }

    /// Which cloud provider an opted-in on-device escalation may reach
    /// (cloud-fallback task, 2026-09-07). Provider-ready for a future
    /// Settings dropdown: today only `.gemini` exists, but the choice is
    /// persisted as a raw-value string under "cloudProvider" so a later
    /// provider needs no migration. A UI preference, not a secret.
    /// didSet persists only — the provider takes effect the next time
    /// `applyVoiceEngineStack()` runs (nothing needs a live switch until
    /// a second provider exists to switch between).
    @Published var cloudProvider: CloudProvider {
        didSet {
            UserDefaults.standard.set(cloudProvider.rawValue, forKey: Self.cloudProviderKey)
        }
    }
    private static let cloudProviderKey = "cloudProvider"

    /// [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier's confidence
    /// threshold — the internal Settings card's ± row, shown as a
    /// percentage (97 % ↔ 0.97). When the large local brain answers BELOW
    /// this while an online provider is configured, the turn goes to the
    /// cloud (with the spoken hold cue first). Persisted through
    /// `CloudCascadeSettings` (UserDefaults, clamped on read AND write —
    /// a UI preference, not a secret). didSet persists AND re-arms the
    /// tier, so a ± press in Settings takes effect on the NEXT utterance
    /// (the same instant-apply rule `cloudFallbackEnabled` follows).
    /// Init-time restore assigns the property directly (house pattern —
    /// didSet does not fire there).
    @Published var cloudCascadeThreshold: Double {
        didSet {
            guard cloudCascadeThreshold != oldValue else { return }
            CloudCascadeSettings.setThreshold(cloudCascadeThreshold)
            applyCloudCascadeConfiguration()
        }
    }

    /// [CLOUD-CASCADE] The internal card's switch — ON by default (the
    /// tier's rule is the requested behaviour and it stays inert on its
    /// own wherever no provider is configured), OFF to hold the ladder
    /// local-first on purpose. Persisted through `CloudCascadeSettings`.
    @Published var cloudCascadeEnabled: Bool {
        didSet {
            guard cloudCascadeEnabled != oldValue else { return }
            CloudCascadeSettings.setEnabled(cloudCascadeEnabled)
            applyCloudCascadeConfiguration()
        }
    }

    /// The user's favourite apps for the Home quick-access row
    /// (quick-access-apps task, 2026-09-06), in stored order.
    /// `private(set)`: mutation is confined to `addFavoriteApp` /
    /// `removeFavoriteApp`, which validate. Persisted in UserDefaults the
    /// same way as the other UI preferences — the ids are catalog keys,
    /// not secrets. Mutating the array REPLACES it (never in-place), so
    /// the didSet always sees the new value.
    @Published private(set) var favoriteAppIDs: [String] {
        didSet {
            UserDefaults.standard.set(favoriteAppIDs, forKey: Self.quickAccessAppsKey)
        }
    }
    private static let quickAccessAppsKey = "quickAccessApps"

    /// The favourited catalog apps in stored order — what the Home row
    /// and the picker's "Your apps" section render. Stale ids (an app
    /// removed from the catalog) never surface (`AppLauncher.apps(for:)`
    /// is stale-proof).
    var favoriteApps: [AppLauncher.App] {
        AppLauncher.apps(for: favoriteAppIDs)
    }

    /// Catalog + scheme launcher for the quick-access feature. Shares the
    /// `CallLinkOpening` seam the call/message flows use, so the same
    /// fake covers both in tests. Stateless, so no lazy needed.
    private let appLauncher = AppLauncher()

    /// Last user utterance and assistant reply — the Home conversation
    /// card (spec §4.1.4).
    @Published var lastTranscript: String?
    @Published var lastAssistantReply: String?
    /// Progressively-revealed transcript while the collapsed Gemini call
    /// streams (live captions, spec §3.3) — nil once the utterance
    /// settles and `lastTranscript` takes over. The caption pill binds
    /// `livePartialTranscript ?? lastTranscript`.
    @Published var livePartialTranscript: String?

    /// [TURN-TIMING] Compact per-stage timing caption for the LATEST
    /// turn (`"asr 120ms · llm 2.4s · tts 310ms"`), set by the tracer's
    /// finalize callback. Nil until a turn finalizes, and nil again when
    /// a turn produced no measurable reply speech. Diagnostics only —
    /// shown under the assistant reply in the transcript when
    /// `voiceTimingDebugEnabled` is ON.
    @Published private(set) var lastTurnTimingCaption: String?
    /// The assistant exchange the caption belongs to — the transcript
    /// sheet renders the caption only under this row.
    @Published private(set) var lastTurnTimingExchangeID: UUID?

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
    ///
    /// The card always reads user-then-assistant (conversation-panel fix,
    /// 2026-09-06): `transcript` — the user utterance this outcome
    /// answers, captured by `setOutcome` from `lastTranscript` at
    /// creation time — is rendered ABOVE `text`. It is nil only when
    /// nothing was heard for this outcome (a touch/chip-initiated action
    /// after a silent session, or a blank utterance), in which case the
    /// card shows the response alone.
    struct OutcomeSummary: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let transcript: String?
        let timestamp: Date
        let undo: (() -> Void)?

        /// One text row of the outcome card, top to bottom — a user
        /// transcript row always precedes the assistant response row.
        /// Hashable so `OutcomeCardView` can `ForEach` it by identity.
        enum Row: Hashable {
            case user(String)
            case assistant(String)
        }

        /// Composes the card's text rows from the raw transcript and the
        /// assistant's response: the "you said" row first (omitted when
        /// the transcript is nil/blank — sanitized by
        /// `sanitizedTranscript`), the response row last. Every
        /// outcome-producing path funnels through this via `setOutcome`,
        /// so a response is never shown without its command above it.
        /// Pure — unit-tested without SwiftUI (repo pattern).
        static func rows(transcript raw: String?, response: String) -> [Row] {
            var rows: [Row] = []
            if let heard = sanitizedTranscript(raw) {
                rows.append(.user(heard))
            }
            rows.append(.assistant(response))
            return rows
        }

        /// The transcript trimmed for display — nil when absent or blank
        /// so the card never draws an empty "you said" row.
        static func sanitizedTranscript(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
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

    // MARK: - Assistant activity history + live-call detection
    // (call-history task, 2026-09-06; unanswered-call capture,
    // missed-calls task, 2026-09-07)

    /// Encrypted, bounded (100-entry) log of what THIS app itself
    /// called/messaged — the Recent activity leaf's source of truth.
    /// Never the system call log, never other apps' messages (iOS
    /// platform wall). The ONE exception is the anonymous unanswered-call
    /// row (missed-calls task, 2026-09-07): a presence-only fact the
    /// live-call observer saw — a call ended without ever connecting —
    /// recorded with no name and no number, never the identity the
    /// system call log would carry (iOS does not expose it). Lazy like
    /// `chatHistoryStore`: `storage` is assigned at the top of `init`,
    /// long before any call/message path can record. Main-queue confined
    /// by contract.
    private(set) lazy var activityLog = AppActivityLog(storage: storage)

    /// Published window over `activityLog`, newest first — the leaf's
    /// read side. Mirrors the `conversationHistory` window pattern:
    /// the store stays the source of truth and `recordActivity` refreshes
    /// this window after every write, so a row recorded while the leaf is
    /// open (a re-initiated call/message, or a call that just went
    /// unanswered) appears without a re-push.
    @Published private(set) var recentActivity: [AppActivityEntry] = []

    /// True while a call is connected (CXCallObserver via
    /// `liveCallDetector`). Identity-free BY PLATFORM DESIGN: iOS masks
    /// calls that involve other apps — no handle, number, or identity is
    /// ever delivered, so this flag says "a call is in progress" and the
    /// app never learns (or claims) whose. The observer's ONLY other
    /// output is the unanswered event (missed-calls task, 2026-09-07),
    /// recorded by `recordUnansweredCall` — one anonymous "ended without
    /// connecting" row, still no identity or number.
    @Published private(set) var liveCallActive = false

    /// Edge-triggered detector; armed (constructed) in `start()`. Lazy
    /// so it is created only after init has finished and on the main
    /// queue, where it stays confined.
    private(set) lazy var liveCallDetector = makeLiveCallDetector()

    @Published var lastOutcome: OutcomeSummary?

    /// [DESIGN-REVIEW] Explicit outcome dismissal — clears the published
    /// outcome so Home's feedback region hands the strip back to the
    /// optional-setup affordance for the rest of the session (the
    /// stand-down is permanent, not timer-bound).
    func dismissOutcome() {
        lastOutcome = nil
    }

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
    ///
    /// Composition is UNIFORM for every outcome (conversation-panel fix,
    /// 2026-09-06): the card shows the user's transcript — `lastTranscript`,
    /// recorded by `recordTranscript` at the top of every `route()` call —
    /// above `text`, so no single path (medication ack, reminder set,
    /// call/message, generic reply) renders the response without the
    /// command that produced it. The transcript is snapshotted
    /// synchronously — at outcome-creation time, on whatever queue the
    /// caller runs — before the main-queue hop, and sanitized: nil/blank
    /// (a touch-initiated outcome with nothing heard this session) simply
    /// yields a card without the "you said" row.
    private func setOutcome(icon: String, text: String, undo: (() -> Void)? = nil) {
        let transcript = OutcomeSummary.sanitizedTranscript(lastTranscript)
        DispatchQueue.main.async { [weak self] in
            self?.lastOutcome = OutcomeSummary(icon: icon, text: text,
                                               transcript: transcript,
                                               timestamp: Date(), undo: undo)
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
    /// Only the REPLY text is passed here — the card composition is now
    /// uniform, so the transcript handling this method used to do inline
    /// (repeated field reports, 2026-09-04, made clear that showing only
    /// the ASSISTANT's reply, with the user's transcript visible for
    /// barely a second during capture and never again, reads as "no
    /// transcript showing" even though routing worked correctly) moved
    /// into `setOutcome`: it attaches `lastTranscript` — already set by
    /// `recordTranscript` at the top of every `route()` call — to EVERY
    /// outcome, and `OutcomeCardView` renders it as a "you said" row
    /// above the response (2026-09-06 conversation-panel fix).
    func noteGenericReply(_ text: String) {
        guard !text.isEmpty else { return }
        setOutcome(icon: "bubble.left.and.bubble.right.fill", text: text)
    }

    /// While non-nil, a confirmation challenge is awaiting the user's
    /// yes/no follow-up. Set by `startVoiceAckConfirmation`, cleared by
    /// `handleConfirmationResponse` or the session-machine timeout (C12).
    @Published var pendingConfirmationEntryId: UUID?

    /// [BOOT-REVIEW P1-6] The app's encrypted storage, routed per key by
    /// `StoragePlacementPolicy`: small secrets (the Gemini/Search/YouTube
    /// credentials, the chosen model) stay in the Keychain, and every
    /// structured payload — contacts, places, appointments, briefing,
    /// feed config, histories, reminder state, caches — lives in an
    /// encrypted file under Application Support with Data Protection
    /// Complete. Payloads written before the split are copied across on
    /// first read, transactionally, by `MigratingEncryptedStorage`.
    ///
    /// The concrete type (not `EncryptedLocalStorage`) so the boot restore
    /// can read the phase-1 keys through ONE store opening
    /// (`withReadSnapshot`); every store still receives it as the protocol
    /// and cannot tell which channel it is on.
    private let storage: MigratingEncryptedStorage
    private let observabilityBus: ObservabilityBus
    /// [LIVE-TRANSLATE T-013] The app's ONE label-translation store: the
    /// live camera-translation pipeline resolves and records through it, and
    /// the appliance helper's label seam reads the same instance, which is
    /// what makes "a translation cached on one surface is reused by the
    /// other with no network call" (FR-LCT-020) true by construction rather
    /// than by convention. Constructed in init — that is an empty dictionary
    /// and a lock, no I/O; the payload is read lazily on the first lookup —
    /// and never a second one anywhere.
    private let labelTranslationCache: LabelTranslationCache
    /// [LIVE-TRANSLATE T-015] The app's ONE consent gate: the cloud tier
    /// asks it for permission, and the only things that ever write it are the
    /// consent prompt and the revocation control — both of which drive THIS
    /// instance, so a decision made in Settings is the decision in force over
    /// the session view, with no restart and no second record. Constructed in
    /// init (a lock and a closure, no I/O; nothing is read until a decision
    /// is asked for) and never a second one anywhere.
    private let liveTranslateConsentGate: LiveTranslateConsentGate
    /// [LIVE-TRANSLATE T-015] The prompt/control state shared by the session
    /// view's prompt and the Settings leaf. Created on the main actor on
    /// first use — it is view state, so it is born where views live.
    private var consentController: ConsentPromptController?
    /// [TURN-TIMING] Turn-scoped stage tracer — created in init (after
    /// the bus) and injected into the pipeline/router/speaker composition
    /// in `start()` and the recognizers below.
    private let turnTracer: VoiceTurnLatencyTracer

    /// [TURN-TIMING-BREAKDOWN] The per-turn stage stopwatch behind the
    /// intent-model timing breakdown. Non-nil only on a build that
    /// compiles `INTENT_ENCODER` in (`IntentEncoderFeature.isEnabled` is
    /// a compile-time constant, so a build that drops the condition
    /// constructs neither the recorder nor the reporter and every
    /// instrumented call site sees nil). [ENCODER-ALWAYS-ON] Every build
    /// of this target carries the condition by default, so the
    /// instrumentation is live here — the same compile-time gate that
    /// makes the encoder card render, and the card's "Last turn"
    /// breakdown is what reads it. Injected into the encoder, the picker
    /// brain, the cascade chain and the speaker; the coordinator itself
    /// never reads a stage.
    private let turnTimingRecorder: TurnTimingRecorder?
    /// [PIPELINE-TRACE] The full-width debug trace's recorder: one row per
    /// pipeline gate (input, output, decision, ms) for the LAST turn,
    /// in memory only. Gated exactly like the timing recorder above (the
    /// same compile-time condition, so a build without `INTENT_ENCODER`
    /// constructs neither), and injected into every gate that can describe
    /// its own step: the pipeline (STT), the encoder (its three stages),
    /// the cascade chain, the picker brain, the router's band policy and
    /// the speaker. The coordinator only PUBLISHES the assembled trace
    /// (`lastPipelineTrace`) — it never reads a row.
    private let pipelineTraceRecorder: PipelineTraceRecorder?
    /// [TURN-TIMING-BREAKDOWN] The breakdown's single emission point —
    /// attached to `turnTracer` in `composePostFirstFrame()`, where the
    /// tracer's handlers are wired. Nil exactly when the recorder is.
    private let turnLatencyReporter: TurnLatencyReporter?
    private let medicationScheduler: MedicationScheduler
    private let alarmScheduler: UNNotificationScheduler
    private let familyNotifier: APNsFamilyNotifier
    /// [CAREGIVER-EVENTS] (2026-09-13) Per-event-type caregiver
    /// notification preferences (Settings → "Notify caregivers"). Owned
    /// here because three separate services read it at fire time
    /// (`MedicationScheduler`, `RoutineScheduler`, and the event fire
    /// handler); `SettingsView` binds the same instance, so a toggle flip
    /// takes effect on the very next fire with no propagation step.
    let caregiverNotifySettings: CaregiverNotifySettings

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
    /// [BOOT-M1M2] The reminders persistence facade is retained so
    /// `start()` can run the first-run seed on the boot queue — the seed
    /// used to run in `init` (keychain IO before first paint, which the
    /// constant-time startup contract forbids).
    private let routineStore: RoutineStore

    /// Reminder photo store (photo-visual-aids task, 2026-09-16) —
    /// `Application Support/VisualAids/<entryId>/<file>.jpg`. One shared
    /// instance: the view layer renders from it, the routine scheduler
    /// reads attachments out of it, and deleting a reminder clears its
    /// folder through it. Stateless (a directory URL plus JPEG helpers),
    /// and its `init` performs NO disk IO — a path lookup only, so
    /// building it here keeps the constant-time boot contract
    /// (`NoIOInInitTests`). The directory appears on the first save.
    let visualAidStore = VisualAidStore()

    /// The MEDICATION photo store (medication-visual-aids task,
    /// 2026-09-16) — the same `VisualAidStore`, built with the medication
    /// directory prefix so dose photos land at
    /// `Application Support/VisualAids/med-<entryId>/<file>.jpg` and can
    /// never resolve into a routine entry's folder. A second INSTANCE, not
    /// a second implementation: compression, the picker's cap and the
    /// failure-soft file handling are one code path for both systems.
    /// Like its sibling, `init` is a path lookup with no disk IO.
    let medicationVisualAidStore =
        VisualAidStore(directoryPrefix: VisualAidStore.medicationDirectoryPrefix)

    /// The curated "Family and friends" list (spec §4.4.2) — persisted
    /// encrypted, feeds the notifier whenever the list changes.
    let familyContactStore: FamilyContactStore
    @Published private(set) var familyContacts: [FamilyContact]

    /// Saved places for voice navigation (directions task, 2026-09-07) —
    /// see `SavedPlaceStore` for the cap and the default-home rules.
    /// Loaded once in `init`; every mutation below (Settings editor)
    /// refreshes the published list from the store, so views and the
    /// router's navigation-candidate list read the same truth.
    let placeStore: SavedPlaceStore
    @Published private(set) var savedPlaces: [SavedPlace]

    /// Doctor's appointments (medical task, 2026-09-07) — the Medical
    /// leaf's list, persisted encrypted under `medical.appointments` by
    /// `AppointmentStore` (same shape as `familyContactStore` above).
    /// Loaded once in `init`; every mutation below (Medical leaf add/remove
    /// and the paste-confirmation flow) refreshes the published list from
    /// the store, so the leaf and any future voice route read one truth.
    /// The store also hands every saved appointment to the
    /// `MedicalAppointmentCalendarWriting` seam — the calendar-2way task's
    /// EventKit backend replaces the shipped no-op; see
    /// `calendarWritesEnabled` in the store and the toggle below.
    let appointmentStore: AppointmentStore
    @Published private(set) var appointments: [MedicalAppointment]

    /// Whether saved appointments are ALSO written to the native iPhone
    /// Calendar (medical task, 2026-09-07) — the Medical leaf's toggle
    /// `medical.calendarToggle`, default ON. A UI preference, not a
    /// secret — persisted in UserDefaults the same way as `appTheme`.
    /// didSet persists AND re-syncs the store's `calendarWritesEnabled`
    /// gate, so flipping the toggle acts immediately (the same
    /// instant-apply rule as `cloudFallbackEnabled`). The init-time
    /// restore assigns directly and syncs the gate by hand (house
    /// pattern — didSet does not fire there).
    @Published var appointmentsToCalendar: Bool {
        didSet {
            UserDefaults.standard.set(appointmentsToCalendar,
                                      forKey: Self.appointmentsToCalendarKey)
            appointmentStore.calendarWritesEnabled = appointmentsToCalendar
        }
    }
    private static let appointmentsToCalendarKey = "appointmentsToCalendar"

    /// One-shot honest SMS caption (medical task, 2026-09-07): the
    /// Medical leaf shows "the iPhone does not let apps read your text
    /// messages…" once, until the senior (or family) dismisses it — a
    /// preference, not a secret, persisted like `appTheme`. Dismissal is
    /// confined to `dismissAppointmentSmsNote`.
    @Published private(set) var appointmentSmsNoteDismissed: Bool {
        didSet {
            UserDefaults.standard.set(appointmentSmsNoteDismissed,
                                      forKey: Self.appointmentSmsNoteDismissedKey)
        }
    }
    private static let appointmentSmsNoteDismissedKey = "appointmentSmsNoteDismissed.v1"

    // Voice
    private let audioEngine: AVAudioEngine
    private let audioSessionManager: AudioSessionManager
    /// [STARTUP-PERF → STARTUP-R2] Starts as the honest Null engine; the
    /// real sherpa engine (its ONNX load is the expensive part) is built
    /// AFTER first paint AND after the speak affordance is live (the
    /// post-ready deferral in `scheduleDeferredKWSBuildIfNeeded`, main
    /// thread — the ONNX runtime segfaults off-main on the x86_64
    /// simulator), then hot-swapped into the running pipeline — the
    /// pre-paint model load is gone and the build never contributes to
    /// perceived startup.
    private var wakeWordEngine: WakeWordEngine
    private let voiceActivityDetector: VoiceActivityDetector
    private var voicePipeline: VoicePipeline!
    /// [BOOT-REVIEW P0-2] MANUAL-TALK readiness on the contract the
    /// startup review specifies: the hero renders it from the very first
    /// frame (`.loading(.starting)`), it reaches `.ready` ONLY from a real
    /// `voicePipeline.start` success callback, and a failure is NEVER
    /// auto-recovered by a timer or another boot phase. Wake-word engine
    /// state cannot move it in either direction (wake-word is a separate
    /// capability; manual Talk must come up even when KWS degrades to the
    /// Null engine).
    ///
    /// The state machine is a plain value type (`ManualTalkReadinessState`)
    /// so its rules are unit-tested without a coordinator; the coordinator
    /// is its only writer and publishes the value here.
    ///
    /// Manual Talk is deliberately pipeline-only: once audio activation,
    /// speech authorization and the mic tap succeed, the button is live.
    /// STT/TTS/LLM warming and KWS construction continue independently;
    /// none can hold the user's explicit tap behind a multi-second load.
    @Published private(set) var voicePipelineReadiness: VoicePipelineReadiness =
        ManualTalkReadinessState.initial
    private var manualTalkReadiness = ManualTalkReadinessState()
    /// Monotonic launch timestamp for the one-shot manual-Talk duration.
    private var manualTalkStartupStartedAt: UInt64?
    /// Background engine-settlement telemetry. Warm plan outcomes and KWS
    /// settlement land here, but never gate manual Talk readiness.
    private var talkBootContract = TalkBootContractState()
    /// Independent backstop for a warm/KWS publisher that never settles.
    /// It closes background readiness telemetry; it does not enable Talk.
    private let talkContractWatchdog = TalkBootWatchdog()
    /// The settle event (`talk_boot_contract`) fired at most once per
    /// contract.
    private var talkContractSettled = false
    /// [LAT-M1/LAT-EVIDENCE] The post-turn whisper residency cycle —
    /// TTL-hold after each held transcript, release + background re-warm
    /// when the TTL lapses (see `WhisperResidencyCycle` /
    /// `WhisperPostTurnPolicy`). The re-warm is NEVER gated on the
    /// warm-start preference — the toggle gates the BOOT warm only.
    private lazy var whisperResidencyCycle = WhisperResidencyCycle(
        onRelease: { [weak self] in
            DispatchQueue.main.async { self?.releaseHeldWhisperWeights() }
        },
        onReWarmRequired: { [weak self] in
            DispatchQueue.main.async { self?.runBackgroundWhisperReWarm() }
        })
    /// [STARTUP-R2] True once the deferred KWS build has been scheduled
    /// (or run) this launch — the one-shot guard for the post-ready
    /// wake-word build.
    private var deferredKWSBuildScheduled = false
    /// [VAD-RT] True when the deferred KWS build found a live voice turn
    /// and deferred itself — `handlePipelineState`'s `.idle` case
    /// re-schedules it so the main-thread (simulator) sherpa session
    /// construction can never overlap a capture's `vad_end` main hop.
    private var deferredKWSBuildPendingWhileBusy = false
    /// [STARTUP-R2] The short main-thread deferral between the speak
    /// affordance going live and the sherpa KWS build starting — the
    /// build never contributes to perceived startup; wake-word
    /// detection arrives moments later (documented honest limit).
    private static let deferredKWSBuildDelaySeconds: TimeInterval = 2.0
    /// [STARTUP-PERF] The `CommandRouter` built in `start()` — retained so
    /// the boot's `.preparingVoice` phase can hand it to the pipeline it
    /// constructs (the pipeline build moved out of `start()`'s tail).
    private var commandRouter: CommandRouter?
    private var voiceStateCancellable: AnyCancellable?
    private var geminiSwapCancellable: AnyCancellable?
    private var speaker: Speaker?

    // Voice-OS shell v1 (composition — built in `start()`, nil until then
    // like `speaker` itself): the speak queue that now owns all speech,
    // the speech-source registry, the morning-briefing source, and the
    // single `UNUserNotificationCenter` delegate facade. `speakQueue` is
    // retained here so the coordinator stays the composition root; the
    // facade is retained because the notification center holds its
    // delegate weakly. `shellCardCancellable` forwards the queue's
    // announcement cards to the existing outcome-card presentation.
    private var speakQueue: SpeakQueue?
    private var speechSourceRegistry: SpeechSourceRegistry?
    private var morningBriefing: MorningBriefing?
    private var newsReader: NewsReader?
    private var notificationFacade: NotificationFacade?
    private var shellCardCancellable: AnyCancellable?

    /// The morning briefing's day slot (briefing persistence task,
    /// 2026-09-08) — the same encrypted store instance `MorningBriefing`
    /// writes on `fire()`. Loaded once in `init` so the published
    /// `todayBriefing` (the Home widget + briefing leaf's source of
    /// truth) starts populated on relaunch, and re-read on every app
    /// activation + after every fire so presence tracks the store.
    private let morningBriefingStore: MorningBriefingStore
    /// Today's stored briefing (briefing persistence task, 2026-09-08) —
    /// non-nil only while a briefing was composed for the CURRENT
    /// calendar day. Mutations are main-confined through
    /// `refreshTodayBriefing()` (called on the main actor in
    /// `handleScenePhase`, and via `MainActor.run` after async fires).
    /// Drives the Today's-briefing Home widget presence and the briefing
    /// leaf; the leaf's "Speak again" replays this stored text.
    /// [BOOT-REVIEW P1-7] A briefing landing/expiring is one of the two
    /// inputs of the derived notification count, so it refreshes here —
    /// and nowhere else in the publish path.
    @Published private(set) var todayBriefing: StoredBriefing? {
        didSet {
            guard todayBriefing != oldValue else { return }
            refreshActiveNotificationCount()
        }
    }
    // Feed agent (feed-agent task, 2026-09-08): the feed's composition
    // root lives here like every other store/service — the Settings leaf
    // edits through the coordinator's mutation methods, the Feed leaf
    // renders the published state, and the service itself publishes
    // nothing (its results forward through `refreshFeed()`).
    ///
    /// [BOOT-REVIEW P0-1] Both are built on FIRST USE. The feed is a
    /// secondary capability: nothing on the first frame (Home, Settings,
    /// Emergency) renders feed state, and the configuration these read
    /// only arrives with the boot's restore phase — so neither object
    /// needs to exist before first paint. `start()` touches both on main
    /// before the off-main restore reads the store (lazy initialization
    /// is not thread-safe).
    private lazy var feedSettingsStore = FeedSettingsStore(storage: storage)
    private lazy var feedService = FeedService(settings: feedSettingsStore,
                                               transport: URLSession.shared,
                                               observability: observabilityBus)

    /// The configured feed sources — the Settings leaf's list (published
    /// so add/remove re-renders it live).
    @Published private(set) var feedSources: [FeedSource] = []
    /// The configured topic keywords — same contract as `feedSources`.
    @Published private(set) var feedTopics: [String] = []
    /// The composed feed items (newest first).
    @Published private(set) var feedItems: [FeedItem] = []
    /// The Feed leaf's load state (idle/loading/loaded/failed).
    @Published private(set) var feedLoadState: FeedLoadState = .idle
    /// Source display names that failed the last refresh (honest partial
    /// failure caption; empty = all sources reached).
    @Published private(set) var feedFailedSourceNames: [String] = []
    // Feed translation (feed translation task, 2026-09-08) — per-item,
    // ON ASK only (a card's Translate button; the feed never translates
    // automatically). `feedTranslations` is the item-id cache AND the
    // single source the cards read; the other two sets drive the card's
    // in-flight spinner and its honest-failure caption.
    /// [BOOT-REVIEW P0-1] FIRST USE (it rides `geminiClient`). A card's
    /// Translate tap is the only entry point, and that is always long
    /// after the first frame.
    private lazy var feedTranslator = FeedTranslator(client: geminiClient,
                                                     observability: observabilityBus)
    @Published private(set) var feedTranslations: [String: FeedTranslation] = [:]
    @Published private(set) var feedTranslatingIDs: Set<String> = []
    @Published private(set) var feedTranslationFailedIDs: Set<String> = []



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
    private enum VoiceStartWatchdogError: Error { case noResponse }
    /// Permission decisions happen during onboarding; a post-onboarding
    /// pipeline callback that is silent this long is wedged, not user input.
    private static let voiceStartWatchdogSeconds: TimeInterval = 3.0

    /// Transient localized notice shown on the Talk button's status line
    /// after a long-press reset (TALK-CRASH-FIX, 2026-09-07) — e.g.
    /// "Voice reset. I'm ready." Cleared after `voiceResetNoticeSeconds`
    /// and whenever a NEW capture begins (handlePipelineState
    /// .capturingCommand), so a live cycle never shares its line with
    /// stale feedback.
    @Published private(set) var voiceResetNotice: String?
    /// Token-guards the auto-clear: only the timer issued by the LATEST
    /// show may clear — a repeat reset inside the window must not have
    /// its fresh notice wiped by the previous notice's timer.
    private var voiceResetNoticeToken = 0
    /// Seconds the post-reset notice stays on the status line — long
    /// enough for a slow read, short enough not to linger into the next
    /// turn.
    private static let voiceResetNoticeSeconds: TimeInterval = 4

    /// `start()` is idempotent — the onboarding wizard and Home both call
    /// it (spec §4.2: wizard runs before voice engages).
    private var started = false

    // Model store — kept for now (v1 on-device Whisper/LLaMA machinery is
    // superseded, not deleted, by the v2 Gemini pivot; see
    // docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md §8).
    // Nothing in `start()` requires these anymore — the onboarding models
    // step no longer downloads anything by default (see
    // `OnboardingWizardView.ModelsStep`, repurposed for the Gemini API key).
    ///
    /// [BOOT-REVIEW P0-1] Both are built on FIRST USE. `ModelStore.init`
    /// resolves Application Support and prepares its directory tree —
    /// filesystem work that must not sit between launch and the first
    /// frame, and that nothing on the first frame needs: model paths are
    /// only resolved by the boot's voice phase, the warm, and downloads.
    lazy var modelStore: ModelStore = {
        do {
            return try ModelStore(observabilityBus: observabilityBus)
        } catch {
            fatalError("Cannot initialise ModelStore: \(error)")
        }
    }()
    lazy var modelDownloadService = ModelDownloadService(
        store: modelStore,
        observabilityBus: observabilityBus
    )
    /// [BOOT-REVIEW P0-1] FIRST USE, not `init()`: constructing either
    /// recognizer forces `modelStore` (filesystem) and, for WhisperKit,
    /// the ANE model lookup. The boot's voice phase is what actually
    /// needs them; the first frame does not. The factory attaches
    /// `turnTracer` and the dialect-bias provider so the instance arrives
    /// fully configured, exactly as the old init-time wiring did.
    private lazy var whisperSpeechRecognizer: WhisperSpeechRecognizer = {
        let recognizer = WhisperSpeechRecognizer(modelStore: modelStore,
                                                 observabilityBus: observabilityBus)
        recognizer.turnTracer = turnTracer
        recognizer.biasProfileProvider = makeDialectBiasProfileProvider()
        return recognizer
    }()
    private lazy var fallbackSpeechRecognizer = OnDeviceSpeechRecognizer(
        audioEngine: audioEngine,
        observabilityBus: observabilityBus,
        pushMode: true
    )
    /// ANE WhisperKit runtime (memory: ios-stt-runtime-decision). Preferred
    /// over the CPU whisper.cpp recognizer whenever its model artifact is
    /// installed (`ModelStore.directoryURL(for: .whisperKitNepali)`) or a
    /// bench override is set — same hot-swap mechanism, GPU/ANE compute.
    ///
    /// [BOOT-REVIEW P0-1] FIRST USE, not `init()` (it forces `modelStore`,
    /// and the bench env probe + tracer/bias wiring live in the factory
    /// so the instance is fully configured on arrival).
    ///
    /// [STT-SWITCHER] The factory seeds the persisted pick, so the very
    /// first load is the model the Settings picker already shows —
    /// `sttModelPreference` is restored in `init()` (a DIRECT assignment
    /// there: a didSet never fires during initialization, which is also
    /// why the pick is not pushed through `setPreferredModel` before this
    /// factory runs). Safe by construction: nothing in `init()` (or in any
    /// other stored property's initializer) touches this lazy, so the
    /// first evaluation is the boot's voice phase — provably after the
    /// restore. `nil` (never picked) keeps the engine's own default.
    private lazy var whisperKitSpeechRecognizer: WhisperKitSpeechRecognizer = {
        let recognizer = WhisperKitSpeechRecognizer(
            observabilityBus: observabilityBus,
            modelStore: modelStore,
            preferredModelID: sttModelPreference ?? ModelCatalog.whisperKitNepaliMedium
        )
        // [TURN-TIMING] Both whisper recognizers mark `asr_loaded` with
        // their measured load ms when a load happens inside a live turn.
        recognizer.turnTracer = turnTracer
        recognizer.biasProfileProvider = makeDialectBiasProfileProvider()
        // Bench hook (debug): point the ANE runtime at a sideloaded model
        // folder or a WhisperKit-named model via scheme env vars —
        // WHISPERKIT_MODEL_FOLDER / WHISPERKIT_MODEL_NAME. Production
        // selection uses the installed catalog artifact instead.
        let wkEnv = ProcessInfo.processInfo.environment
        if let folder = wkEnv["WHISPERKIT_MODEL_FOLDER"] {
            recognizer.modelFolderURL = URL(fileURLWithPath: folder)
        } else if let name = wkEnv["WHISPERKIT_MODEL_NAME"] {
            recognizer.modelName = name
        }
        return recognizer
    }()

    /// v2: the Gemini API key + client (see `GeminiConfigStore`,
    /// `GeminiClient`). `geminiConfigStore` is exposed for the Settings
    /// screen that lets a family member paste in the key.
    ///
    /// [BOOT-REVIEW P0-1] The four objects below are built on FIRST USE.
    /// `GeminiCostGovernor.init` reads the persisted spend counters from
    /// the Keychain (a real `SecItemCopyMatching` round-trip), and the
    /// client/recognizer/translator are pure consumers of it — none of
    /// them is reachable from the first frame. `start()` still kicks the
    /// key restore on the boot queue (`loadPersistedValues`), which is
    /// where the store's own read happens.
    private(set) lazy var geminiConfigStore = GeminiConfigStore(storage: storage)
    private(set) lazy var geminiCostGovernor = GeminiCostGovernor(
        storage: storage,
        observabilityBus: observabilityBus
    )
    private lazy var geminiClient = GeminiClient(configStore: geminiConfigStore,
                                                 observabilityBus: observabilityBus,
                                                 costGovernor: geminiCostGovernor)
    private lazy var geminiSpeechRecognizer = GeminiSpeechRecognizer(
        client: geminiClient,
        observabilityBus: observabilityBus
    )

    // MARK: - Wake phrase ("ये कान्छी", open item #4)
    //
    // Two moving parts: `wakeWordEnabled` (the persisted Settings toggle)
    // and the launch engine built in init (sherpa-onnx KWS when the model
    // is bundled, Null otherwise). The pure logic behind these lives in
    // Services/Voice/WakeWordConfig.swift so it is unit-testable without
    // the sherpa-onnx SPM package linked.

    // MARK: - Local tools (weather + web search, on-device stack)

    /// [LOCAL-TOOLS] (2026-09-07) Google Custom Search credentials
    /// (API key + engine ID) for the on-device-stack web-search tool —
    /// the same Keychain `EncryptedLocalStorage` pattern as
    /// `geminiConfigStore` above; a family member enters them via
    /// Settings → Web search. Exposed for that Settings screen;
    /// `CommandRouter` consults `isConfigured` before the search tool may
    /// ever fire.
    ///
    /// [BOOT-REVIEW P0-1] FIRST USE, not `init()`: the store's
    /// constructor reads BOTH credentials from the Keychain (two
    /// `SecItemCopyMatching` round-trips), which is exactly the kind of
    /// pre-first-frame work that used to sit between launch and paint.
    /// Nothing on the first frame reads a search credential — Settings
    /// and the router (which is built post-first-frame in `start()`) do.
    private(set) lazy var searchConfigStore = SearchConfigStore(storage: storage)

    /// [YOUTUBE] (2026-09-08) YouTube Data API v3 key for the voice
    /// YouTube feature — the same Keychain `EncryptedLocalStorage`
    /// pattern as `searchConfigStore`; a family member enters it via
    /// Settings → YouTube. OPTIONAL: without it the voice command opens
    /// the YouTube search deeplink instead of resolving + playing the
    /// top result. Exposed for that Settings screen; `CommandRouter`
    /// consults `apiKey` at stage time.
    ///
    /// [BOOT-REVIEW P0-1] FIRST USE, not `init()` — same reason as
    /// `searchConfigStore` above (its constructor reads the key from the
    /// Keychain).
    private(set) lazy var youtubeConfigStore = YouTubeConfigStore(storage: storage)

    /// [TOOL-DEBUG-LOG] (2026-09-07) Encrypted debug log of every
    /// local-tool (weather + web search) request and outcome — the store
    /// behind Settings → Tool requests (review + family export). Same
    /// lazy pattern as the intent-layer stores: `storage` is assigned at
    /// the top of `init`, long before any voice turn can record one, and
    /// `start()` injects it into the `CommandRouter` it builds.
    private(set) lazy var localToolLogStore = LocalToolLogStore(storage: storage)

    /// [NEWS-READER] (2026-09-08) Configured news sources + curated
    /// defaults (REPLACE rule — configured sources are THE news) for the
    /// voice digest, and the store the feeds-settings agent's Settings →
    /// Feeds editor binds to. Same Keychain `EncryptedLocalStorage`
    /// pattern and lazy timing as `localToolLogStore` above: `storage` is
    /// assigned at the top of `init`, long before any voice turn can
    /// read it.
    private(set) lazy var newsSourceStore = NewsSourceStore(storage: storage)

    /// Persisted "listen for ये कान्छी" UI preference — UserDefaults
    /// (not a secret), same shape as `sttModelPreference` /
    /// `voiceEngineStack`. Defaults ON: with the sherpa model bundled,
    /// listening is genuinely active from the next launch on (the engine
    /// is fixed per launch); without a model the Null engine is in place
    /// regardless — see `WakeWordPreferences` for the rationale.
    /// didSet persists AND closes/opens the live audio gate so the
    /// Settings toggle acts immediately (no relaunch needed to STOP).
    @Published var wakeWordEnabled: Bool {
        didSet {
            wakeWordPreferences.setEnabled(wakeWordEnabled)
            wakeWordActivityGate.setEnabled(wakeWordEnabled)
        }
    }
    private let wakeWordPreferences = WakeWordPreferences()

    /// [WARM-START] Persisted warm-start preference — Settings → Voice
    /// personalization, UserDefaults "warmStartEngines", default ON: the
    /// boot's `.warmingEngines` phase preloads the speech + reply-voice
    /// models so the first conversation starts fast. didSet persists; the
    /// init-time restore assigns directly (house pattern — didSet does
    /// not fire there). Warm runs only during boot, so a flip applies
    /// from the next launch (the Settings copy says so).
    @Published var warmStartEnabled: Bool {
        didSet {
            UserDefaults.standard.set(warmStartEnabled,
                                      forKey: Self.warmStartEnginesKey)
        }
    }
    private static let warmStartEnginesKey = "warmStartEngines"

    /// Consulted by the voice pipeline for every idle-state audio chunk
    /// and inbound wake detection: closed while the assistant's own TTS is
    /// playing (self-hearing mitigation — see `WakeWordActivityGate`) or
    /// listening is switched off in Settings. Written on the main queue
    /// (noteSpeakingStarted/Ended, the Settings binding), read on the mic
    /// tap's processing queue — the lock lives inside the gate.
    private let wakeWordActivityGate = WakeWordActivityGate()

    /// Whether the engine built for THIS launch is a REAL sherpa-onnx KWS
    /// engine (vs the Null fallback). [STARTUP-PERF] Assigned when the
    /// boot's voice phase completes (background engine construction), so
    /// Settings → "Voice activation" can truthfully distinguish active /
    /// needs-setup / off-at-launch; published so the row re-renders when
    /// the background build lands.
    @Published private(set) var wakeWordEngineRealAtLaunch = false

    /// On-device LLaMA interpreter — the "LLaMA today" half of the local
    /// brain (spec 2026-09-05 §4.0): `LocalBrainChain`'s stand-in while
    /// the fine-tuned intent GGUF isn't cached. Constructed up-front like
    /// `whisperSpeechRecognizer`; `isAvailable` stays false until both the
    /// LLM.swift runtime is linked and its model is cached (see
    /// `LlamaCommandInterpreter.isAvailable`). When unavailable the
    /// chain's slot is simply empty and the router's cloud layer / keyword
    /// fallback carry the turn.
    ///
    /// [BOOT-REVIEW P0-1] FIRST USE, not `init()`: both interpret the
    /// user's commands, so the earliest they can be needed is the first
    /// voice turn — far past the first frame — and constructing them
    /// forces `modelStore` (filesystem) plus, transitively, the plugin
    /// registry. `preferredBaseId` reads the RESTORED brain preference at
    /// factory time, so a stored choice still wins over the default.
    private lazy var llamaCommandInterpreter = LlamaCommandInterpreter(
        modelStore: modelStore,
        observabilityBus: observabilityBus,
        preferredBaseId: resolvedBrainModelID,
        config: LlamaCommandInterpreter.Config(confidenceThreshold: 0.4,
                                               maxTokens: 128,
                                               timeoutSeconds: 10),
        pluginRegistry: pluginRegistry,
        // [TURN-TIMING-BREAKDOWN] Nil on every build but an
        // `INTENT_ENCODER` one — the picker brain's prompt-build and
        // inference spans cost a nil check there.
        timingRecorder: turnTimingRecorder,
        // [PIPELINE-TRACE] …and the picker brain's two trace rows.
        traceRecorder: pipelineTraceRecorder
    )
    /// [ENCODER-RUNTIME-TOGGLE] Settings → AI मोडेल (hidden) → the
    /// internal-testing switch that lets the encoder take the local-brain
    /// slot. Persisted under
    /// `IntentEncoderPreferences.enabledKey` ("intentEncoder.enabled"),
    /// **default OFF** — a flagged build ships the incumbent brain until a
    /// tester opts in, and flipping the switch ACTS ON THE NEXT TURN (no
    /// relaunch): the didSet persists and re-installs the slot through the
    /// SAME `installLocalBrainSlot` the composition used.
    ///
    /// OFF is a silent fall-through, never an error surface: the picker
    /// brain (`localIntentInterpreter`, or the LLaMA stand-in when it
    /// cannot serve) answers exactly as it does on a non-gated build.
    @Published var intentEncoderEnabled: Bool = false {
        didSet {
            intentEncoderPreferences.setEnabled(intentEncoderEnabled)
            guard oldValue != intentEncoderEnabled else { return }
            reinstallLocalBrainSlotIfGated()
        }
    }

    /// [ENCODER-RUNTIME-CASCADE] Settings → AI मोडेल (hidden) → the
    /// cascade switch, on the SAME internal card as the enable switch.
    /// Persisted under `IntentEncoderPreferences.cascadeKey`
    /// ("intentEncoder.cascade"), **default OFF**.
    ///
    /// OFF (the default) is `intentEncoderEnabled`'s own behaviour: the
    /// encoder holds the local slot alone, so an abstention falls through
    /// to the router's band/cloud policy as it always has. ON widens the
    /// turn: the encoder answers first and the picker brain (the model
    /// selected above it) answers the SAME turn — one turn, one answer, no
    /// second prompt — whenever the encoder abstains or comes back below
    /// the router's ACCEPT band. Nothing changes downstream: the keyword
    /// safety net still runs upstream of this chain, and the cloud layer
    /// still receives whatever the local slot does not answer.
    ///
    /// Ignored while the enable switch is OFF (`servingMode` collapses to
    /// the picker brain), which is why the UI disables the row until the
    /// encoder is on. Same hot-swap contract as the enable switch: the
    /// didSet persists and re-installs the slot, so a flip acts on the
    /// NEXT TURN, not the next launch.
    @Published var intentEncoderCascadeEnabled: Bool = false {
        didSet {
            intentEncoderPreferences.setCascadeEnabled(intentEncoderCascadeEnabled)
            guard oldValue != intentEncoderCascadeEnabled else { return }
            reinstallLocalBrainSlotIfGated()
        }
    }

    /// [CORRECTION-TOGGLES] Settings → AI मोडेल (hidden) → the SAME internal
    /// card, third switch: the STT-error corrector, the layer that runs
    /// FIRST at the intent seam (§6.1 `sanitise → correct → canonicalize →
    /// tokenize`). Persisted under
    /// `IntentEncoderPreferences.correctorKey` ("intentEncoder.corrector"),
    /// **default OFF**.
    ///
    /// Unlike the two switches above there is no slot to re-install and no
    /// `didSet` sequencing: the corrector is not a brain, and it resolves
    /// its policy from the stored key on EVERY turn
    /// (`STTCorrector.Policy.runtime` through the local slot's input seam,
    /// `IntentEncoderWiring.localSlotInputSeam`), so the flip acts on the
    /// next turn by itself. The didSet persists and stops.
    ///
    /// ON rewrites the LOCAL BRAIN'S input only: nothing downstream branches
    /// on the result (A-14 — no band, no cache, no route, and the chain's
    /// routing decisions and `CommandRouter` are untouched), and the keyword
    /// safety net keeps reading the ORIGINAL transcript
    /// (`IntentTranscriptPair.safetyNetInput`, D-1).
    ///
    /// [CORRECTION-ANYBRAIN] The row is NOT gated on the encoder switch: the
    /// layer acts at the local slot's input, so it corrects what the picker
    /// brain reads too — which is what lets a tester run the corrector alone
    /// against the 1.7B. The layer's own compile gate still applies
    /// (`STTCorrector.Policy.runtime`), so a build without `INTENT_ENCODER`
    /// stays inert whatever this switch says.
    @Published var intentCorrectorEnabled: Bool = false {
        didSet { intentEncoderPreferences.setCorrectorEnabled(intentCorrectorEnabled) }
    }

    /// [CORRECTION-TOGGLES] …and the card's fourth switch: the dialect
    /// canonicalizer, which runs SECOND — on the CORRECTOR's output, never
    /// on the raw transcript. Same key shape
    /// (`IntentEncoderPreferences.canonicalizerKey`,
    /// "intentEncoder.canonicalizer"), same default OFF, and the same
    /// per-turn resolution through `DialectCanonicalizer.Policy.runtime`.
    ///
    /// Deliberately a SEPARATE switch from the corrector's: the two layers
    /// are independently observable, and the card has to be able to run the
    /// whole matrix — corrector only, canonicalizer only, both, neither —
    /// each combination exercising the real seam in the intended order.
    /// Safety is unchanged in every one of them: `original` (what the
    /// safety net, the emergency path and the med-ack path read) is the
    /// sanitised transcript, untouched by either layer.
    ///
    /// [CORRECTION-ANYBRAIN] Same rule as the corrector's row: it acts at the
    /// local slot's input, so it is not gated on the encoder switch, and with
    /// the encoder off it canonicalizes what the picker brain reads (in the
    /// matrix's intended order — on the CORRECTOR's output, never on the raw
    /// transcript).
    @Published var intentCanonicalizerEnabled: Bool = false {
        didSet { intentEncoderPreferences.setCanonicalizerEnabled(intentCanonicalizerEnabled) }
    }

    /// [TURN-TIMING-BREAKDOWN] The LAST finalized turn's stage breakdown,
    /// behind the internal-testing card's "Last turn" readout: each stage
    /// the turn actually spent time in, with its milliseconds.
    ///
    /// IN MEMORY ONLY — never persisted, never written to the encrypted
    /// stores, never logged. The value holds stage names and numbers by
    /// construction (`TurnTimingStage` is a fixed enum), so it cannot
    /// carry transcript, entity or reply content; it is diagnostic state
    /// for the tester holding the device, and it disappears with the
    /// process. Nil until the first turn with instrumentation active
    /// finalizes — and permanently nil on a non-gated build, where no
    /// reporter exists to fill it.
    @Published private(set) var lastTurnTimingBreakdown: TurnTimingBreakdown?

    /// [PIPELINE-TRACE] The LAST finalized turn's full pipeline trace,
    /// behind the internal-testing card's "Pipeline trace" section: one row
    /// per gate — STT, corrector, canonicalizer, the encoder's three
    /// stages, the band policy, the cascade, the picker brain's prompt and
    /// its FINAL LLM round-trip, and the TTS start — each with its input
    /// summary, output summary, decision token and milliseconds.
    ///
    /// IN MEMORY ONLY — never persisted, never written to the encrypted
    /// stores. Unlike the breakdown above, the rows MAY name words (the
    /// recognised text, a corrected form, a decoded slot, the spoken
    /// reply): the card is the debugger's view on the device, the same
    /// disclosure posture the "Last correction" line above already ships,
    /// and the value disappears with the process. The observability
    /// events are the count-only half — see `PipelineTrace.eventMetadata`.
    @Published private(set) var lastPipelineTrace: PipelineTrace?

    /// [TG-12] The LAST turn's correction readout, behind the
    /// internal-testing card's "Last correction" line — the same shape and
    /// the same rules as `lastTurnTimingBreakdown` above.
    ///
    /// IN MEMORY ONLY — never persisted, never written to the encrypted
    /// stores, never logged, and NOT what the `turn_correction` event carries
    /// (the event carries `CorrectionResult.observabilityMetadata`, which is
    /// count-only and PII-free; this is the debugger's view and it may name
    /// the words being rewritten, to the person holding the device). Nil
    /// until a turn runs with the corrector switched on — and permanently
    /// nil on a non-gated build, where no interpreter and no card exist.
    @Published private(set) var lastCorrectionReadout: CorrectionReadout?

    /// Both internal-testing switches act through here. Non-gated builds
    /// never reach it (no UI exposes the switches), but the guard keeps
    /// the invariant local: only a build that compiles the encoder in may
    /// touch the slot.
    private func reinstallLocalBrainSlotIfGated() {
        guard IntentEncoderFeature.isEnabled else { return }
        if let intentRouter {
            installLocalBrainSlot(on: intentRouter)
        }
    }

    private let intentEncoderPreferences = IntentEncoderPreferences()

    /// [T-037-a] The on-device CoreML intent encoder (internal testing
    /// only; artifact pinned to the T-036 v0 export). Deliberately NOT
    /// constructed on normal builds: every reference to it is guarded by
    /// `IntentEncoderFeature.isEnabled` (the serving decision and the
    /// re-arm path additionally by `intentEncoderEnabled`), so the `lazy`
    /// factory never runs without the `INTENT_ENCODER` compilation
    /// condition — and, with the compile condition present, still not
    /// until a tester switches the encoder on. Its
    /// `isAvailable` is false unless the artifact is installed in
    /// `ModelStore` AND both bundled resources load — the Swift XLM-R
    /// tokenizer ([ENCODER-RUNTIME-READY]) with the artifact's companion
    /// meta.json. When either resource is unavailable,
    /// `IntentEncoderRuntime.load` returns the explicit UNAVAILABLE pair,
    /// so the shipped behaviour is unchanged.
    private lazy var intentEncoderInterpreter: IntentEncoderInterpreter = {
        let resources = IntentEncoderRuntime.load()
        let interpreter = IntentEncoderInterpreter(
            modelStore: modelStore,
            observabilityBus: observabilityBus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: resources.manifest,
            tokenizer: resources.tokenizer,
            config: .default,
            artifactInstaller: IntentEncoderSpikeInstaller(
                modelStore: modelStore,
                observabilityBus: observabilityBus,
                downloadService: modelDownloadService),
            // [TURN-TIMING-BREAKDOWN] The encoder's three stage spans
            // (tokenizer / CoreML forward / decode). Non-nil exactly when
            // this build compiles `INTENT_ENCODER` in — the encoder is
            // only ever constructed on such a build anyway.
            timingRecorder: turnTimingRecorder,
            // [PIPELINE-TRACE] …and the same three stages' trace rows
            // (token count / decoded intent+slots / decision).
            traceRecorder: pipelineTraceRecorder
        )
        // [TG-12] The corrector's readout for the card's "Last correction"
        // line, wired at construction exactly as the turn-timing reporter is
        // (see `turnLatencyReporter?.onReported` below): the interpreter hands
        // it over on the calling thread and the publish hops to main. In
        // memory only — see `lastCorrectionReadout`.
        interpreter.onCorrection = { [weak self] readout in
            DispatchQueue.main.async {
                self?.lastCorrectionReadout = readout
            }
        }
        return interpreter
    }()
    /// Level-2 memory-warning observer for the encoder (nil unless the
    /// internal-testing gate is on).
    private var intentEncoderMemoryObserver: NSObjectProtocol?
    /// [MODEL-LIFECYCLE] Level-2 observer for the residency ledger (STT +
    /// brain eviction). Installed in every build.
    private var modelLifecycleObserver: NSObjectProtocol?

    /// True once the encoder has actually been OFFERED the slot, i.e. the
    /// lazy instance exists. A/B means a tester can switch the encoder on
    /// and then off again WITHOUT the process ending, which leaves a
    /// constructed, idle encoder holding its CoreML weights: the release
    /// half of the memory-pressure contract must still reach it. The flag
    /// is what distinguishes that case from "never constructed", where the
    /// same call would construct the object it is trying to free.
    private var intentEncoderOffered = false

    /// [T-037-a]/[ENCODER-RUNTIME-TOGGLE] Installs the local-brain slot:
    /// the encoder when the compilation condition is present AND the
    /// tester's toggle is ON AND the artifact can serve, else the
    /// incumbent brain untouched. Called once at composition time and
    /// again on every toggle flip — that re-entry is what makes the
    /// Settings switch act on the next turn instead of the next launch.
    ///
    /// The decision is `IntentEncoderWiring`'s (a pure, tested function
    /// set); this method only sequences it and emits the selection event,
    /// so the shipped call site is what the wiring tests exercise.
    ///
    /// [ENCODER-RUNTIME-READY] Readiness is requested at the moment the
    /// encoder is OFFERED the local-brain slot: this resolves the tester's
    /// own copy of the pinned zip (the app's `Documents/` copy by default —
    /// no environment variable needed — or the `INTENT_ENCODER_SPIKE_ZIP`
    /// path when one is set) and starts a background install through
    /// ModelStore's strict sha256 path. A missing file is an explicit
    /// `zip_missing` failure; only an explicitly blanked override is a
    /// no-op decision. No UI, no network — and with the toggle off nothing
    /// here runs at all, which is why switching the encoder ON is also what
    /// starts its install.
    ///
    /// The slot itself is the DEFERRED pair, so an install that lands
    /// after the switch is flipped is picked up on the next turn without
    /// a relaunch; while the encoder is unavailable the chain serves
    /// exactly the fallback the selection event describes.
    ///
    /// [ENCODER-RUNTIME-CASCADE] The second switch only chooses the slot's
    /// SHAPE (standalone vs. encoder-first with a same-turn escalation to
    /// the picker brain); it never changes which brain is offered, never
    /// constructs anything, and is ignored unless the enable switch is on.
    private func installLocalBrainSlot(on router: IntentRouter) {
        let servingEnabled = IntentEncoderWiring.isServingEnabled(
            isToggleOn: intentEncoderEnabled)
        let offeredEncoder = IntentEncoderWiring.gatedEncoder(
            isEnabled: servingEnabled
        ) {
            intentEncoderInterpreter
        }
        if let offeredEncoder {
            intentEncoderOffered = true
            // [MODEL-LIFECYCLE] The encoder now exists, so its bytes are
            // real: give the residency ledger a row for them. Placed here
            // (not in `start()`) so a launch that never builds the encoder
            // never declares it.
            registerEncoderSlotIfNeeded()
            offeredEncoder.requestReadiness()
        }
        // "Can it serve now?" — decides the selection event, unchanged
        // (and unchanged in meaning with the toggle off: no encoder is
        // offered, so no event is emitted for a slot it does not hold).
        let encoderAvailableNow = IntentEncoderWiring.preferredLocalBrain(
            encoder: offeredEncoder,
            fallback: localIntentInterpreter)
        if let selectionMetadata = IntentEncoderWiring.selectionEventMetadata(
                preferred: encoderAvailableNow, encoder: offeredEncoder) {
            observabilityBus.emit(ObservabilityEvent(
                component: "intent_encoder_wiring",
                eventType: "encoder_selected_as_local_brain",
                durationMs: nil,
                outcome: "info",
                errorCode: nil,
                metadata: selectionMetadata
            ))
        }
        // [ENCODER-RUNTIME-CASCADE] The slot's SHAPE follows the two
        // switches: standalone (the encoder alone — the pre-cascade
        // behaviour, and the default), or encoder-first with the picker
        // brain escalating on the same turn. The decision is the pure
        // `servingMode`; this call site only feeds it the switches, so the
        // mode truth table the tests pin IS the shipped one.
        let mode = IntentEncoderWiring.servingMode(
            isEnabled: servingEnabled,
            isCascadeOn: intentEncoderCascadeEnabled)
        router.localBrain = IntentEncoderWiring.localBrainSlot(
            mode: mode,
            encoder: offeredEncoder,
            encoderFallback: encoderAvailableNow,
            pickerBrain: llamaCommandInterpreter,
            // [TURN-TIMING-BREAKDOWN] The cascade's decision span rides
            // the chain that owns the decision; nil on non-gated builds.
            timingRecorder: turnTimingRecorder,
            // [CORRECTION-ANYBRAIN] The slot's input seam: the corrector and
            // the canonicalizer run HERE, once per turn, so the two layer
            // switches act whichever brain answers — including the picker
            // brain with the encoder off. Unconditional: the seam is inert
            // while both switches read OFF (the shipped default), and it is
            // what makes those switches independent of the encoder switch.
            //
            // [PIPELINE-TRACE] The trace recorder rides the seam it
            // traces: the corrector and canonicalizer rows are opened
            // inside `IntentInputCanonicalization.prepare`, which moved
            // here with the seam — handing the recorder to the chain
            // alone would leave both rows off on every production turn.
            inputSeam: IntentEncoderWiring.localSlotInputSeam(
                traceRecorder: pipelineTraceRecorder),
            // [PIPELINE-TRACE] …and the cascade's trace row.
            traceRecorder: pipelineTraceRecorder,
            onEscalated: { [weak self] reason in
                self?.emitEncoderEscalatedToPickerBrain(reason)
            })
    }

    /// [ENCODER-RUNTIME-CASCADE] The A/B evidence for a cascade turn: the
    /// encoder did not serve (abstained, failed, or answered below the
    /// ACCEPT band) and the picker brain answered instead. Fixed
    /// vocabulary only — the reason enum and a literal — never transcript
    /// or reply content (C9 policy). Pair it with `encoder_inference_*`
    /// to tell "the encoder answered" from "the encoder was overruled".
    private func emitEncoderEscalatedToPickerBrain(_ reason: LocalBrainChain.EscalationReason) {
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_encoder_wiring",
            eventType: "encoder_escalated_to_picker_brain",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["reason": reason.rawValue]
        ))
    }

    /// The fine-tuned intent model (spec 2026-09-05 §8) — the local brain
    /// `IntentRouter` prefers once its GGUF is cached (the preferred half
    /// of `LocalBrainChain`). Until the bake-off artifact ships,
    /// `isAvailable` is false and the chain delegates to the LLaMA
    /// stand-in, keeping an on-device interpretation path alive.
    private lazy var localIntentInterpreter = LocalIntentInterpreter(
        modelStore: modelStore,
        observabilityBus: observabilityBus,
        config: LocalIntentInterpreter.Config(confidenceThreshold: 0.4,
                                              maxTokens: 192,
                                              // [LAT-EVIDENCE] 3 s
                                              // contradicted the
                                              // coupled-numbers family
                                              // (llama ≤ 10 s) and timed
                                              // out real generations —
                                              // the device log showed
                                              // `inference_timeout` at
                                              // ~3 s with truncated
                                              // JSON. 10 s aligns with
                                              // the llama bound.
                                              timeoutSeconds: 10)
    )
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

    /// Per-contact Messenger handles for ADDRESS-BOOK people, keyed by
    /// normalized phone (Messenger deep-link fix, 2026-09-07) — Messenger
    /// has NO phone-number thread link, so a captured handle is what
    /// opens a book row's real thread. The capture prompt is gone
    /// (messenger-gate, 2026-09-07); `storedMessengerHandle` still READS
    /// this so a previously captured handle keeps its pill. (Family
    /// handles live on `FamilyContact`, not here.)
    private(set) lazy var messengerHandleStore = MessengerHandleStore(storage: storage)

    /// Per-contact calling-channel preferences for ADDRESS-BOOK people,
    /// keyed by normalized phone (Phone-tab redesign, 2026-09-07) — the
    /// row's channel chooser persists the user's pick here, and rows
    /// without an entry resolve to the global `defaultCallApp`. Lazy
    /// like `messengerHandleStore`: `storage` is assigned at the top of
    /// `init`, long before any row can query or write a preference. UI
    /// code goes through the `storedChannelPreference` /
    /// `setChannelPreference` helpers in this class, never this store
    /// directly.
    private(set) lazy var channelPreferenceStore = ChannelPreferenceStore(storage: storage)

    /// The plugin registry backing `.plugin` intent dispatch and plugin
    /// prompt composition (design doc 2026-09-05).
    ///
    /// [BOOT-REVIEW P0-1] Built on FIRST USE, with every built-in
    /// registered inside the factory — the appliance/calendar plugins
    /// hold storage-backed state and the YouTube plugin holds the Keychain
    /// config store, none of which the first frame touches. Construction
    /// is forced by the interpreter/router composition in `start()`,
    /// which hands the registry to each of them.
    private(set) lazy var pluginRegistry = makePluginRegistry()

    /// The DEFAULT assistant-brain model `start()` auto-downloads when
    /// an interpreter is needed (interpreter-availability fix 2026-09-06):
    /// LLaMA 3.2 1B Instruct Q4_K_M GGUF from HuggingFace (bartowski),
    /// ~807 MB, sha256-verified, catalog kind `.llamaBase`. This is the
    /// "default LLM that was the default before" the v2 pivot — the
    /// brain `LlamaCommandInterpreter` (LocalBrainChain's stand-in)
    /// runs when no explicit choice is stored. Since brain
    /// selectability (2026-09-06) the Settings "AI मोडेल" screen offers
    /// every `ModelCatalog.availableBrainEntries` model; the LIVE
    /// choice is `resolvedBrainModelID`.
    // [DEFAULT-BRAIN 2026-09-16] The gate-passing slot-canonical Qwen 4B
    // (v16) is the default brain — the same model the curated brain list
    // leads with and the per-language ne pick names, so the value no longer
    // straddles a superseded entry (`intentQwen4BS43`, kept in the catalog
    // for devices that cached it). The pre-Qwen LLaMA 1B this comment used
    // to describe is hidden from the picker.
    static let defaultBrainModelID = ModelCatalog.intentQwen4BSlotCanon

    /// The brain model the interpreter actually uses: the stored
    /// preference when it names a real catalog entry, else the default.
    /// (A stale stored value — model removed from the catalog — falls
    /// back rather than wedge the picker.)
    var resolvedBrainModelID: ModelID {
        brainModelPreference.flatMap { ModelCatalog.entry(for: $0) != nil ? $0 : nil }
            ?? Self.defaultBrainModelID
    }

    /// Hot-swaps the interpreter's base model and starts the chosen
    /// model's download when it isn't cached — the brain picker's
    /// contract. The interpreter drops its loaded llama.cpp handle on
    /// the swap, so the next inference loads the new model. Only ever
    /// runs from `brainModelPreference`'s didSet (real user changes,
    /// post-`start()`); the init-time restore assigns directly and
    /// `ensureAssistantBrainDownloadIfNeeded()` covers the first launch.
    private func applyBrainModel() {
        let resolved = resolvedBrainModelID
        llamaCommandInterpreter.switchBaseModel(to: resolved)
        if !modelStore.isCached(resolved) {
            modelDownloadService.start(resolved)
        }
    }

    /// Whether `start()` should kick the assistant-brain model's one-time
    /// download: the model isn't cached AND no live cloud brain exists.
    /// The on-device stack always needs the local model (this decision
    /// runs BEFORE `applyVoiceEngineStack()` applies any cloud-fallback
    /// opt-in, so the router is still strict here — `cloudEnabled` is
    /// false for the on-device stack regardless of the opt-in), and
    /// the Gemini stack needs it too while no key is configured, which is
    /// exactly the shape of the reported bug (correct transcript, apology
    /// reply, nothing listening). Pure static so the decision is
    /// unit-testable without an AppCoordinator instance (same seam as
    /// `isWakeWordRuntimeLinked`). Downloads are NOT Gemini calls — the
    /// cost governor caps billable cloud calls and is deliberately
    /// untouched by this restore.
    static func shouldAutoDownloadAssistantBrain(modelCached: Bool,
                                                 cloudEnabled: Bool,
                                                 cloudBrainAvailable: Bool) -> Bool {
        guard !modelCached else { return false }
        return !(cloudEnabled && cloudBrainAvailable)
    }

    /// Resolves which channel an ADDRESS-BOOK row's call button opens
    /// (Phone-tab redesign, 2026-09-07): the row's explicit per-contact
    /// pick wins, else the global default (`defaultCallApp`). One hard
    /// rule on top of the fallback chain — never resolve to a channel
    /// the row cannot open: a `.messenger` result needs an on-file
    /// handle (Messenger addresses people by username, not number), so
    /// without one the result drops to `.phone` rather than dead-ending
    /// the tap. Pure static so the whole matrix is unit-testable without
    /// an AppCoordinator instance (same seam as
    /// `shouldAutoDownloadAssistantBrain`).
    static func resolvedCallChannel(explicit: CallApp?,
                                    defaultApp: CallApp,
                                    messengerHandleAvailable: Bool) -> CallApp {
        let resolved = explicit ?? defaultApp
        if resolved == .messenger && !messengerHandleAvailable { return .phone }
        return resolved
    }

    /// Compile-time: is the vendored LLM.swift runtime linked into THIS
    /// build? Mirrors the `#if canImport(LLM)` inside
    /// `LlamaCommandInterpreter.isAvailable` (and the shape of
    /// `isWakeWordRuntimeLinked`), so the auto-download policy never
    /// fetches an ~807 MB GGUF for a build whose interpreter could not
    /// run it.
    static var isLLMRuntimeLinked: Bool {
        #if canImport(LLM)
        return true
        #else
        return false
        #endif
    }

    /// Legacy v1 on-device model catalog — kept only so the buried
    /// "AI मोडेल" settings screen still functions as a manual fallback.
    /// STT models are no longer downloaded automatically at first run
    /// (v2 pivot); the assistant-brain model above IS, via
    /// `ensureAssistantBrainDownloadIfNeeded()` (interpreter-availability
    /// fix 2026-09-06).
    ///
    /// The downloads-management rows must cover EVERY STT engine the
    /// picker can select (anything selectable has to be fetchable), so
    /// this mirrors `ModelCatalog.availableSTTEntries`, then every
    /// selectable brain model (`availableBrainEntries` — same rule:
    /// anything the picker offers must be fetchable) and the voice rows
    /// the screen has always managed.
    let requiredModelIds: [ModelID] =
        ModelCatalog.availableSTTEntries.map(\.id)
        + ModelCatalog.availableBrainEntries.map(\.id)
        + [ModelCatalog.piperNepali]

    // MARK: - First-use factories ([BOOT-REVIEW P0-1])

    /// Builds the plugin registry WITH its built-ins registered (design:
    /// docs/superpowers/specs/2026-09-05-plugin-architecture-design.md) —
    /// the `.plugin` dispatch table and the interpreters' prompt
    /// composition both read it. Kept out of `init()` because the
    /// built-ins are storage-backed services the first frame never
    /// touches; `routinePlugin` is constructed eagerly (safety-adjacent
    /// reminders) and simply handed over here.
    private func makePluginRegistry() -> PluginRegistry {
        let registry = PluginRegistry(observabilityBus: observabilityBus)
        registry.register(NepaliCalendarPlugin(storage: storage))
        registry.register(ApplianceHelperPlugin(storage: storage,
                                                labelCache: labelTranslationCache))
        registry.register(routinePlugin)
        // [YOUTUBE] (2026-09-08) The interpreter-side twin of the
        // router's deterministic YouTube stage — same `YouTubeTool`
        // behavior (shared config store + transport + opener seams).
        registry.register(YouTubePlugin(configStore: youtubeConfigStore))
        // [LIVE-TRANSLATE T-027] The live-camera-translation plugin. It is
        // registered with a *factory* and nothing else: no camera session,
        // no detector, no client and no session model is built here, so
        // registering at launch costs nothing and an app that never opens
        // the feature never creates any of them (NFR-LCT-012). The factory
        // runs on the one path that opens it — the voice entry inside
        // `handle`, the Home tile inside `presentLiveTranslate()`.
        registry.register(LiveTranslatePlugin(
            observabilityBus: observabilityBus,
            makeDependencies: { [weak self] locale in
                self?.makeLiveTranslateDependencies(locale: locale)
            }))
        // [APP-LAUNCHER] (2026-09-16) "क्यामेरा खोल" / "open WhatsApp":
        // the plugin resolves the entity against the catalog and asks this
        // coordinator to pend the launch — the confirmation machinery, the
        // 45 s window and the open all live here, where the call and
        // calendar-event confirmations already do (wired weak so the
        // registry never keeps the coordinator alive).
        //
        // The hop is part of the seam's contract: the router dispatches
        // plugins inside a `Task`, so `handle` — and this closure — can run
        // off the main thread, while the pending launch, its @Published
        // state and the session's confirmation window are all
        // main-confined (every other `request…Confirmation` here is called
        // synchronously from `route`, i.e. already on main). The line must
        // come back synchronously, so this is a sync hop rather than an
        // async one; `isMainThread` keeps it deadlock-free if the dispatch
        // context ever changes.
        registry.register(AppLauncherPlugin { [weak self] appID, confidence in
            let requestOnMain = { [weak self] () -> String in
                self?.requestAppLaunch(appID: appID, confidence: confidence)
                    ?? L10n.str("router.pluginUnavailable",
                                locale: self?.activeLocale ?? Locale(identifier: "ne-NP"))
            }
            return Thread.isMainThread ? requestOnMain()
                                       : DispatchQueue.main.sync(execute: requestOnMain)
        })
        return registry
    }

    /// [LIVE-TRANSLATE T-027] Assembles one live-translation session (C13).
    ///
    /// Called only when the feature is opened, and it is the only place a
    /// capture session, a detector, a recognition request or a tier is built
    /// for this feature. The two stores it hands over are the process's own
    /// instances (`labelTranslationCache`, `liveTranslateConsentGate`, both
    /// built in `init` over the same cipher) — the session never constructs
    /// storage and never constructs a second gate.
    ///
    /// `nil` when the shell's speech queue does not exist yet. That queue is
    /// built in `start()`; both entry points are downstream of it, so this is
    /// the pre-`start()` state and is not reachable from either. Returning
    /// `nil` rather than a session without speech is deliberate: the plugin
    /// turns it into the spoken apology the design's failure table specifies,
    /// instead of a session that silently cannot talk.
    private func makeLiveTranslateDependencies(locale: Locale) -> LiveTranslateSessionDependencies? {
        guard let queue = speakQueue else { return nil }
        return LiveTranslateSessionDependencies(
            locale: locale,
            camera: LiveCameraSession(observabilityBus: observabilityBus),
            detector: LiveTextDetector(observabilityBus: observabilityBus),
            cache: labelTranslationCache,
            consentGate: liveTranslateConsentGate,
            costGovernor: geminiCostGovernor,
            client: geminiClient,
            // The shell's one queue, through the feature's own protocol: the
            // session's speech is the assistant's speech, on the interactive
            // lane, and T-025's microphone gate can see it (C12).
            speechPath: queue,
            // The shipped one-shot microphone, the same instance the Phone
            // leaf's search uses: one mic stack, one arbitration.
            captureDevice: searchPhraseCapture,
            audioSession: audioSessionManager,
            // A struct over `UserDefaults`: one store, so the session's
            // toggle and Settings read and write the same preference.
            settings: LiveTranslateSettings(),
            observabilityBus: observabilityBus)
    }

    /// [LIVE-TRANSLATE T-027] The Home feature tile's entry (FR-LCT-001).
    ///
    /// Like the appliance tile, the tap IS the intent: no encoder round trip,
    /// no question, just the session. It goes through the plugin rather than
    /// building the view here, so the tile and the voice entry cannot end up
    /// presenting two different sessions.
    @MainActor
    func presentLiveTranslate() {
        let locale = activeLocale
        guard let plugin = pluginRegistry.plugins.compactMap({ $0 as? LiveTranslatePlugin }).first else {
            // Unreachable: the registry always registers it (see
            // `makePluginRegistry`). Reported rather than swallowed, because
            // a tile that does nothing is the one outcome nobody can debug.
            observabilityBus.emit(ObservabilityEvent(
                component: "plugin_live_translate",
                eventType: "live_translate_open_failed",
                durationMs: nil,
                outcome: "failure",
                errorCode: "plugin_not_registered",
                metadata: [:]
            ))
            speak(text: L10n.str(LiveTranslatePlugin.unavailableKey, locale: locale))
            return
        }
        guard let view = plugin.tileView(locale: locale) else {
            speak(text: L10n.str(LiveTranslatePlugin.unavailableKey, locale: locale))
            return
        }
        presentPluginView(view)
    }

    /// [ACCENT-ADAPT] per-user decode-biasing terms (doc
    /// accent-adaptation.md P0.3): contact names + medication names +
    /// supported app names compose into the dialect prompt once the
    /// user's dialect is identified (a `.default` label keeps STT
    /// byte-identical). Runs on the recognizer's inference/attempt
    /// queue, never main; `DialectBiasComposer` caps + sanitises.
    /// Contacts require permission — a denied/absent address book is an
    /// honest empty list, never a failure.
    ///
    /// Held WEAKLY on the scheduler: it outlives the coordinator and
    /// never references it back, so no retain cycle is possible. The
    /// factory runs at first recognizer use (post-`init`), so the
    /// definite-initialization restriction that forced a local alias
    /// inside `init` no longer applies.
    private func makeDialectBiasProfileProvider() -> () -> DialectBiasProfile {
        let scheduler = medicationScheduler
        return { [weak scheduler] in
            var profile = DialectBiasProfile()
            if let entries = try? AddressBookDirectory().allEntries() {
                profile.contactNames = entries.map(\.name)
            }
            profile.medicationNames = scheduler?.medicationEntries()
                .map(\.medicationName) ?? []
            profile.appNames = DialectBiasProfile.standardSupportedAppNames
            return profile
        }
    }

    init() {
        // [BOOT-REVIEW P0 item 1] `bootstrap-init` — the composition root's
        // own cost, measured separately from every other startup metric:
        // this is what runs before the app exists at all (the App struct's
        // `@StateObject` initializer), so it can never include work that
        // only happens after the first frame.
        StartupSignposts.begin(.bootstrapInit)
        // Core infrastructure. Storage is encrypted at rest at Data
        // Protection class Complete, per constitution §Security — the
        // Keychain for small secrets, encrypted files under Application
        // Support for everything structured ([BOOT-REVIEW P1-6]; the
        // routing + migration rules live in `StoragePlacementPolicy` and
        // `MigratingEncryptedStorage`). Observability goes through the
        // log sanitiser so no PII leaks into device logs.
        let bus = ConsoleObservabilityBus(sanitiser: LogSanitiser())
        let storage = MigratingEncryptedStorage()
        self.storage = storage
        self.observabilityBus = bus
        // [LIVE-TRANSLATE T-032] The feature's two payloads (the translation
        // cache and the consent record) are sealed with AES-GCM before they
        // reach the file channel — Data Protection Complete alone is "locked
        // device", not "a cipher" (security review, AM-10). The decorator is
        // applied HERE and to these two consumers only, so every other
        // feature's on-disk format is unchanged and no migration is needed.
        let liveTranslateStorage = LiveTranslateCipherStorage(wrapping: storage)
        // [LIVE-TRANSLATE T-013] The shared store is built here, next to the
        // storage it writes through, so exactly one instance exists for the
        // process lifetime (see the property doc). Construction performs no
        // I/O; nothing is read until a label is actually resolved.
        self.labelTranslationCache = LabelTranslationCache(storage: liveTranslateStorage,
                                                           observabilityBus: bus)
        // [LIVE-TRANSLATE T-015] The consent gate lives next to the store it
        // writes through: one instance, for the process lifetime. It is the
        // only thing in the app that records or revokes consent.
        self.liveTranslateConsentGate = LiveTranslateConsentGate(storage: liveTranslateStorage,
                                                                 observabilityBus: bus)
        // [TURN-TIMING] The turn tracer lives as long as the app: every
        // voice component (pipeline, router, speaker, recognizers) shares
        // it. Its finalize callback (the transcript caption) is wired in
        // `start()` — a self-capturing closure cannot be assigned before
        // init finishes (definite-initialization).
        self.turnTracer = VoiceTurnLatencyTracer(observabilityBus: bus)
        // [TURN-TIMING-BREAKDOWN] Built only when the internal-testing
        // encoder is compiled in — `turnTimingRecorder` and
        // `turnLatencyReporter` stay nil everywhere else, which is what
        // makes the instrumentation genuinely zero-cost on a shipped
        // build (see the property docs).
        let timingRecorder: TurnTimingRecorder? =
            IntentEncoderFeature.isEnabled ? TurnTimingRecorder() : nil
        self.turnTimingRecorder = timingRecorder
        // [PIPELINE-TRACE] The debug trace's recorder, gated by the same
        // flag and handed to the reporter below so its turn edges ride the
        // SAME attach point the timing recorder's do — the two can never
        // disagree about where a turn began.
        let traceRecorder: PipelineTraceRecorder? =
            IntentEncoderFeature.isEnabled ? PipelineTraceRecorder() : nil
        self.pipelineTraceRecorder = traceRecorder
        self.turnLatencyReporter = timingRecorder.map {
            TurnLatencyReporter(observabilityBus: bus, recorder: $0,
                                traceRecorder: traceRecorder)
        }
        self.alarmScheduler = UNNotificationScheduler()
        // [STARTUP-PERF] The keychain-backed stores below are CREATED
        // here (cheap objects) but their loads moved to the background
        // boot phase (`bootRestoreData`) — a dozen SecItemCopyMatching
        // round-trips no longer sit between app launch and first paint.
        // Published windows start empty and populate within the boot
        // phase; the stores keep their self-heal/cap rules because the
        // SAME `load()` calls run, just off-main.
        let contactStore = FamilyContactStore(storage: storage)
        self.familyContactStore = contactStore
        self.familyContacts = []
        self.familyNotifier = APNsFamilyNotifier(
            contacts: [],
            apnsProvider: APNsProvider(),
            // The bus exists by now (the init snippet above creates it
            // first) — `family_event_alerted` is the only evidence a
            // caregiver alert was even attempted, since the APNs
            // provider is still the stub.
            observabilityBus: bus
        )

        // [CAREGIVER-EVENTS] (2026-09-13) Preferences before the two
        // schedulers that read them at fire time. Standard defaults, no
        // keychain: UI preferences, not secrets.
        let caregiverNotifySettings = CaregiverNotifySettings()
        self.caregiverNotifySettings = caregiverNotifySettings

        // Saved navigation places (directions task, 2026-09-07) —
        // encrypted like the contacts above; the store self-heals legacy
        // payloads on read (hard default-home invariant) — the read now
        // happens in the boot phase.
        let placeStore = SavedPlaceStore(storage: storage)
        self.placeStore = placeStore
        self.savedPlaces = []

        // Doctor's appointments (medical task, 2026-09-07) — encrypted
        // like the contacts above; loaded in the boot phase so the
        // published list (Medical leaf) starts populated moments after
        // first paint. The store invokes the
        // `MedicalAppointmentCalendarWriting` seam (calendar-2way) on
        // every save/remove when the toggle below is on; the shipped
        // Noop writer means nothing happens until the integrator swaps
        // in the EventKit backend.
        let appointmentStore = AppointmentStore(storage: storage)
        self.appointmentStore = appointmentStore
        self.appointments = []

        // Morning-briefing day slot (briefing persistence task,
        // 2026-09-08) — encrypted like the stores above (the composed
        // text embeds medication names and event titles). Loaded in the
        // boot phase so a relaunch mid-day still shows the day's stored
        // briefing on Home; `MorningBriefing.fire()` writes through the
        // same instance (passed in `start()`), and every activation +
        // fire completion re-reads it into the published `todayBriefing`.
        let briefingStore = MorningBriefingStore(storage: storage)
        self.morningBriefingStore = briefingStore

        // Feed agent (feed-agent task, 2026-09-08) — encrypted config
        // (sources + topics) like the stores above, loaded in the boot
        // phase so the published lists start populated moments after
        // first paint, and the bounded-fetch service (TTL cache,
        // per-source timeout, PII-free logging). Created after the bus
        // exists, same as every bus consumer.
        // [BOOT-REVIEW P0-1] `feedSettingsStore` / `feedService` are NOT
        // constructed here any more — both are first-use lazy (see their
        // property docs); the boot's restore phase is their first reader.

        // Calendar auto-add toggle (medical task, 2026-09-07) — default
        // ON when no value was ever stored. This is the property's ONLY
        // initial assignment, so its didSet does not fire here; the
        // store's calendar gate is synced by hand (same rule as
        // `appTheme` above).
        let appointmentsToCalendarValue =
            UserDefaults.standard.object(forKey: Self.appointmentsToCalendarKey) as? Bool ?? true
        self.appointmentsToCalendar = appointmentsToCalendarValue
        appointmentStore.calendarWritesEnabled = appointmentsToCalendarValue
        self.appointmentSmsNoteDismissed =
            UserDefaults.standard.bool(forKey: Self.appointmentSmsNoteDismissedKey)

        // Safety-critical service (no LLM dependency)
        self.medicationScheduler = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarmScheduler,
            observabilityBus: bus,
            familyNotifier: familyNotifier,
            caregiverNotifySettings: caregiverNotifySettings,
            // [MED-PHOTO-AIDS] Two jobs, matching the routine scheduler's:
            // arming a dose notification with the entry's first photo as a
            // banner attachment (the Lock Screen case), and clearing the
            // entry's photo folder when the medication is deleted. Built
            // with the MEDICATION prefix, so dose photos never resolve
            // into a routine entry's folder.
            visualAidStore: medicationVisualAidStore
        )

        // Routine reminders (v2 pivot Phase 1): the medication path's
        // proven shape — encrypted store, UN notifications, occurrences
        // persisted before alarms arm, re-queue on launch — minus the
        // safety-critical escalation machinery. Seeded once with the
        // brief's category defaults (medication excluded: that system
        // owns medication, and a parallel one would double-prompt doses).
        let routineAlarmScheduler = UNRoutineNotificationScheduler()
        self.routineAlarmScheduler = routineAlarmScheduler
        // [BOOT-M1M2] Construction only — the first-run seed moved to
        // `start()` on the boot queue (constant-time init: no keychain
        // IO before first paint; see RoutineStore.seedDefaultsIfNeeded).
        self.routineStore = RoutineStore(storage: storage)
        let routineScheduler = RoutineScheduler(
            store: routineStore,
            alarmScheduler: routineAlarmScheduler,
            observabilityBus: bus,
            // [CAREGIVER-EVENTS] (2026-09-13) Routines had NO caregiver
            // notification path at all; `markDelivered` is where the
            // alert now fires from.
            familyNotifier: familyNotifier,
            caregiverNotifySettings: caregiverNotifySettings,
            // [PHOTO-AIDS] Two jobs: arming a notification with the
            // entry's first photo as a banner attachment, and clearing
            // the entry's photo folder when the entry is deleted.
            visualAidStore: visualAidStore
        )
        self.routineScheduler = routineScheduler
        self.routinePlugin = RoutinePlugin(scheduler: routineScheduler)

        // Read-only native Calendar/Reminders integration (2026-09-07).
        // Created here (right after the bus exists) so the language
        // sync below reaches it; no permissions are touched by
        // construction — enablement is a Settings toggle + point-of-use
        // ask.
        let externalCalendar = ExternalCalendarService(observabilityBus: bus)
        self.externalCalendar = externalCalendar

        // Alarms + timers (alarms-timers task, 2026-09-07). One service
        // behind the voice stage, the Settings leaf and the launch +
        // BGTask re-queue; locale starts at the scheduler default and is
        // pushed to the service by `syncServiceLocales()` below (this
        // runs before the persisted app language is restored).
        // [ALARMKIT-ALARMS] (2026-09-10) `makeDefault` picks the ALARM
        // backend per runtime: AlarmKit system alarms on iOS 26+, the UN
        // notification fallback before. Construction touches no
        // permissions — the point-of-use ask still happens at the first
        // alarm/timer creation.
// [TIMER-ALARM] (2026-09-10) The AlarmKit seam (nil pre-iOS-26):
        // timers then become SYSTEM-managed on iOS 26 and fall back to
        // the UN path everywhere else / on denial.
        let alarmTimersService = AlarmTimersService(
            store: AlarmTimersStore(storage: storage),
            scheduler: AlarmScheduler.makeDefault(
                notifications: UNNotificationCenterScheduler()
            ),
            observabilityBus: bus,
            systemScheduler: Self.makeAlarmKitSystemScheduler()
        )
        self.alarmTimersService = alarmTimersService

        // [TIMER-ALARM] (2026-09-10) The in-app ringing engine. The old
        // AlarmTimerNotificationDelegate is gone — since the voice-OS
        // shell, `NotificationFacade` (installed in `start()`) is the
        // single UNUserNotificationCenter delegate, which made the old
        // delegate's foreground timer path dead code: timers only ever
        // popped a notification, nobody waited for it. The engine now
        // rings a LOUD LOOPING bell in the foreground until the user
        // presses STOP (and routes tapped timer notifications into the
        // ringing screen as a facade handler). Construction touches no
        // permissions or storage; the ring-start closure is attached at
        // the end of init because it captures self.
        let timerAlarmEngine = TimerAlarmEngine(
            audio: TimerAlarmBellPlayer(observabilityBus: bus),
            observabilityBus: bus
        )
        self.timerAlarmEngine = timerAlarmEngine

        // Language — restore the persisted choice, defaulting to the Nepali
        // pilot language (spec §3.2).
        self.appLanguage = AppLanguage.persisted()

        // Theme — restore the persisted background theme (skinnable home,
        // 2026-09-07). Unknown/missing raw values fall back to `.cream`
        // (`AppTheme(rawOrDefault:)`). This is the property's ONLY initial
        // assignment, so its didSet does not fire here — nothing needs to
        // react to the restored value (same rule as `voiceEngineStack`).
        self.appTheme = AppTheme(rawOrDefault:
            UserDefaults.standard.string(forKey: Self.themeKey))

        // Calendar display (calendar-display task, 2026-09-09) — the
        // default calendar + overlay toggles behind the Home top bar's
        // date line. The store seeds the FIRST-EVER defaults from the app
        // language's locale (Nepali → BS primary with both overlays ON;
        // English → Gregorian with overlays OFF); after that the
        // persisted user choices win, the locale never re-seeds. These
        // are the properties' ONLY initial assignments, so their didSets
        // do not fire here (house pattern) — nothing needs to react: the
        // date line composes lazily on the first refresh.
        let calendarDisplayStore = CalendarDisplaySettingsStore()
        self.calendarDisplayStore = calendarDisplayStore
        // AppLanguage.persisted() (not self.appLanguage) — init is
        // not complete at this point, so the property read is illegal;
        // the persisted value IS what the property will hold.
        let calendarDisplay = calendarDisplayStore.load(locale: AppLanguage.persisted().locale)
        self.calendarDisplayDefault = calendarDisplay.defaultCalendar
        self.showBSOverlay = calendarDisplay.showBSOverlay
        self.showTithiOverlay = calendarDisplay.showTithiOverlay

        // Default call channel (Phone-tab redesign, 2026-09-07) — restore
        // the persisted default call app; missing/unknown raw values fall
        // back to `.phone`, the zero-assumption channel that works for
        // every row. This is the property's ONLY initial assignment, so
        // its didSet does not fire here (same rule as `appTheme` above) —
        // nothing needs to react to the restored value.
        self.defaultCallApp = UserDefaults.standard
            .string(forKey: Self.defaultCallAppKey)
            .flatMap(CallApp.init(rawValue:)) ?? .phone

        // Default map surface (directions task, 2026-09-07) — restore
        // the persisted map-app override; missing/unknown raw values fall
        // back to `.auto`, the preference that opens whatever is actually
        // installed at request time. This is the property's ONLY initial
        // assignment, so its didSet does not fire here (same rule as
        // `appTheme` above) — nothing reacts to the restored value.
        self.navigationMapApp = UserDefaults.standard
            .string(forKey: Self.navigationMapAppKey)
            .flatMap(NavigationMapApp.init(rawValue:)) ?? .auto

        // [BOOT-REVIEW P0-1] The model store + download service, the
        // Gemini key/cost/client trio and the search + YouTube credential
        // stores are ALL first-use lazy now (see their property docs):
        // each of them either hits the filesystem or the Keychain, which
        // is precisely the pre-first-frame work this item removes. They
        // are forced on main by `start()` before the boot queue reads
        // them (lazy initialization is not thread-safe).

        // Voice pipeline. Uses the sherpa-onnx KWS engine when the
        // Settings toggle is ON and the KWS model directory is bundled
        // (see Services/Voice/SherpaKWSWakeWordEngine.swift +
        // tools/fetch-kws-model.sh), else NullWakeWordEngine. The launch
        // outcome is recorded so Settings → "Voice activation" can report
        // an honest status.
        self.audioEngine = AVAudioEngine()
        // The manager shares THIS engine (not its own): the VPIO node
        // flag must land on the instance the pipeline installs its tap
        // on (voice-personalisation P0, slice C).
        self.audioSessionManager = AudioSessionManager(observabilityBus: bus,
                                                       audioEngine: audioEngine)
        // [STARTUP-PERF] The sherpa KWS engine's ONNX load used to run
        // here, BEFORE first paint. The Null stand-in keeps every
        // honest-unavailable path identical until the boot's voice phase
        // builds the real engine after first paint (Settings toggle on +
        // model bundled — same decision as `makeWakeWordEngine` always
        // made) and swaps it in before the pipeline is constructed.
        self.wakeWordEngine = NullWakeWordEngine()
        self.wakeWordEngineRealAtLaunch = false
        self.voiceActivityDetector = EnergyVAD()
        // [BOOT-REVIEW P0-1] The three STTs (fallback SFSpeechRecognizer +
        // both Whisper paths) and the plugin registry are first-use lazy
        // now — see their property docs. Construction is what forces
        // `modelStore` (filesystem) and the registry's storage-backed
        // plugins, and the boot's voice phase is the first thing that
        // genuinely needs them. The recognizer factories carry the
        // `turnTracer`, dialect-bias-provider and bench-env wiring that
        // used to run here, so the instances arrive exactly as before.
        //
        // The fallback recognizer keeps its PUSH-MODE contract (audio
        // arrives via feed() from the pipeline's permanent tap): owned-tap
        // mode made the recognizer tear down and reinstall the shared tap
        // + restart the engine on every utterance — that churn wedged the
        // audio server and AudioToolbox's _ReportRPCTimeout then ABORTED
        // the process (7 crash reports, 2026-09-02).

        // [ACCENT-ADAPT] The per-user decode-biasing provider is attached
        // by the recognizer factories above; its composition (contact
        // names + medication names + supported app names → the dialect
        // prompt, `.default` keeps STT byte-identical) lives in
        // `makeDialectBiasProfileProvider()`.

        // Restore the persisted brain-model choice BEFORE any interpreter
        // can be constructed (the lazy factory reads
        // `resolvedBrainModelID`) so its base model is the live one from
        // the very first inference. Unknown IDs (a model removed from the
        // catalog, or a bad stored value) are ignored so a stale
        // preference can't wedge the picker — same rule as
        // `sttModelPreference` below. Resolved into a LOCAL: `self` reads
        // are illegal during init. Sampling is NOT configurable here —
        // every on-device brain runs deterministic temp-0 + fixed-seed
        // sampling through `OnDeviceSampling` ([NO-GIBBERISH] 2026-09-07).
        let restoredBrain: ModelID?
        if let raw = UserDefaults.standard.string(forKey: Self.brainPreferenceKey) {
            let stored = ModelID(rawValue: raw)
            restoredBrain = ModelCatalog.entry(for: stored) != nil ? stored : nil
        } else {
            restoredBrain = nil
        }
        if let restoredBrain {
            self.brainModelPreference = restoredBrain
        }

        // Restore the persisted voice-engine stack choice (default: the
        // live v2 Gemini pivot, matching today's always-Gemini behavior for
        // anyone who's never touched the toggle). Applied for real once
        // `start()` has built the pipeline + switchable interpreter — see
        // `applyVoiceEngineStack()`. This is the property's ONLY initial
        // assignment, so (like `appLanguage` above) its didSet does not
        // fire here.
        self.voiceEngineStack = UserDefaults.standard.string(forKey: Self.voiceEngineStackKey)
            .flatMap(VoiceEngineStack.init(rawValue:)) ?? .gemini

        // Restore the persisted cloud-fallback opt-in (default OFF — the
        // strictly-on-device contract) and its provider (default Gemini).
        // These are the properties' ONLY initial assignments, so their
        // didSets do not fire here (same rule as `voiceEngineStack`
        // above); `applyVoiceEngineStack()` — which runs once in the
        // startup callback — applies the restored opt-in for real.
        self.cloudFallbackEnabled = UserDefaults.standard.bool(forKey: Self.cloudFallbackKey)
        self.cloudProvider = UserDefaults.standard.string(forKey: Self.cloudProviderKey)
            .flatMap(CloudProvider.init(rawValue:)) ?? .gemini

        // Restore the persisted cloud-cascade tier settings ([CLOUD-CASCADE],
        // 2026-09-16 — default threshold 0.97, default ON). These are the
        // properties' ONLY initial assignments, so their didSets do not fire
        // here (same rule as `voiceEngineStack` above); the tier itself is
        // armed by `applyCloudCascadeConfiguration()`, reached from
        // `applyVoiceEngineStack()` once `start()` has built the pipeline.
        self.cloudCascadeThreshold = CloudCascadeSettings.threshold()
        self.cloudCascadeEnabled = CloudCascadeSettings.isEnabled()

        // Restore the persisted Voice Processing I/O preset mirror
        // (voice-personalisation P0, slice C — default OFF, the A/B
        // gate). The manager composed above already read the persisted
        // value in its own init; this is the mirror's ONLY initial
        // assignment, so its didSet does not fire here (same rule as
        // `voiceEngineStack` above) — the pipeline's own start applies
        // the restored preset at launch.
        self.voiceProcessingEnabled = audioSessionManager.voiceProcessingEnabled

        // Restore the persisted noise-filter A/B mirror ([NOISE-FILTER]
        // P1 front-end — default OFF). This is the mirror's ONLY initial
        // assignment (didSet does not fire here); the restored stage is
        // attached to the pipeline at its construction below.
        self.noiseFilterEnabled =
            UserDefaults.standard.bool(forKey: Self.noiseFilterEnabledKey)

        // Restore the persisted quick-access favourites (quick-access-apps
        // task, 2026-09-06). Pure prune — dedupe, drop ids naming no
        // catalog app, cap at 8 — with NO scheme probes at launch, so no
        // main-thread requirement. This is the property's ONLY initial
        // assignment, so its didSet does not fire here (same rule as
        // `voiceEngineStack` above) — nothing else needs to react to the
        // restored list.
        self.favoriteAppIDs = AppLauncher.validatedFavouriteIDs(
            UserDefaults.standard.stringArray(forKey: Self.quickAccessAppsKey) ?? []
        )

        // Restore the persisted wake-word listening preference (default
        // ON — with the sherpa model bundled it is genuinely active from
        // the next launch on; see `WakeWordPreferences`). This is the
        // property's ONLY initial assignment, so its didSet does not fire
        // here (same rule as `voiceEngineStack` above) — the live audio
        // gate is synced explicitly instead, or a stored OFF would sit on
        // the gate's default ON until the first Settings toggle.
        // Restore the warm-start preference (default ON — see the
        // property). The property's ONLY initial assignment, so its
        // didSet does not fire here (same rule as `voiceEngineStack`
        // above); the boot's warm phase reads the restored value. Must
        // land before the wake-word restore below, which reads `self`.
        self.warmStartEnabled =
            UserDefaults.standard.object(forKey: Self.warmStartEnginesKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.warmStartEnginesKey)

        self.wakeWordEnabled = wakeWordPreferences.isEnabled
        wakeWordActivityGate.setEnabled(wakeWordEnabled)

        // [ENCODER-RUNTIME-TOGGLE] Restore the persisted internal-testing
        // encoder switch (default OFF). Assigned directly — the house
        // pattern: didSet does not fire in init. The slot is installed
        // later, in `composePostFirstFrame()`, which reads this value; on
        // a build without `INTENT_ENCODER` nothing reads it at all.
        self.intentEncoderEnabled = intentEncoderPreferences.isEnabled
        // [ENCODER-RUNTIME-CASCADE] …and its cascade sibling (same
        // default OFF, same restore rule). Restored even while the enable
        // switch is off: the value is irrelevant in that state, and the
        // tester's choice must survive an off/on round trip.
        self.intentEncoderCascadeEnabled = intentEncoderPreferences.isCascadeEnabled
        // [CORRECTION-TOGGLES] …and the two pre-intent layers' switches on
        // that same card (same default OFF, same restore rule). Neither
        // touches the local-brain slot, so nothing else has to be
        // re-installed for them to act: the policies they gate are resolved
        // per turn.
        self.intentCorrectorEnabled = intentEncoderPreferences.isCorrectorEnabled
        self.intentCanonicalizerEnabled = intentEncoderPreferences.isCanonicalizerEnabled

        // Restore the persisted STT model choice. The didSet observer
        // pushes it to the recognizer and refreshes the label. Unknown
        // IDs (a model removed from the catalog, or a bad stored value)
        // are ignored so a stale preference can't wedge the picker.
        // Superseded ids migrate forward through `migratedSTTPreference`.
        if let raw = UserDefaults.standard.string(forKey: Self.sttPreferenceKey),
           ModelCatalog.entry(for: ModelID(rawValue: raw)) != nil {
            self.sttModelPreference = Self.migratedSTTPreference(
                ModelID(rawValue: raw))
        }

        // C12: the confirmation challenge expires — clear the pending entry
        // and tell the user (spec §3.3). The machine already dispatches to
        // main; keep this body main-safe regardless.
        voiceSession.onConfirmationTimeout = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // [INTENTLOG-CAPTURE] A window that expired unanswered is
                // a verdict too — the one that says "this question was
                // too hard / too slow to answer", which is what the
                // accept-band and the 45 s budget are tuned against.
                self.recordConfirmationTimeout()
                self.pendingConfirmationEntryId = nil
                self.pendingRephrase = nil
                // [APP-LAUNCHER] (2026-09-16) An unanswered launch question
                // is DISMISSED, never launched late (design §Error
                // handling: "Confirmation timeout → auto-dismiss; never
                // launch"). Clearing the pending launch here is what makes
                // that true — a later "यो" would otherwise still find it
                // pended once the session had returned to idle — and the
                // timeout line says plainly that nothing was opened
                // (the medication-flavored "I'll remind you again" would be
                // a promise about an app launch that nobody keeps).
                let pendedLaunchID = self.pendingAppLaunch?.appID
                self.pendingAppLaunch = nil
                // [APP-LAUNCHER F13] A launch question that expired is a
                // terminal outcome like every other one, so it gets the
                // same two treatments the tap paths get: an observability
                // event (`launch_timeout`) and a card that says what
                // happened. Before this, the timeout spoke a line and left
                // the question card — "Should I open Camera?" — sitting on
                // screen as if it were still pending, with no record on the
                // bus that the question had ever been asked. The card is
                // replaced rather than cleared because the elder must still
                // be able to see WHAT was not opened after the speech has
                // faded.
                if let appID = pendedLaunchID {
                    self.emitAppLaunch(eventType: Self.LaunchTimeout.eventType,
                                       outcome: Self.LaunchTimeout.outcome(appID: appID))
                    self.setOutcome(icon: Self.LaunchTimeout.icon,
                                    text: L10n.str(Self.LaunchTimeout.speechKey,
                                                   locale: self.activeLocale))
                }
                self.speak(key: pendedLaunchID != nil ? Self.LaunchTimeout.speechKey
                                                      : "router.confirmationTimeout")
            }
        }

        // [APP-LAUNCHER] (2026-09-16) The camera capture flow (T4): the
        // system picker + the add-only photo write, plus the channel
        // closures that put the flow's words on the same three surfaces
        // every other reply uses (speech, the outcome card, the
        // observability bus). Built here — the cost is three object
        // allocations and no I/O — so the flow is ready before the first
        // "क्यामेरा खोल"; the presenter resolves its host at presentation
        // time, not now.
        cameraCapture = makeCameraCaptureFlow()

        // All stored properties are initialised — push the restored
        // language into services that build user-facing strings.
        syncServiceLocales()

        // Fold today's medication reminders into the routine plugin's
        // "what are my reminders today" answer — the user's mental model
        // is ONE reminder list spanning both systems. Attached here (not
        // at plugin registration) because the closure captures self.
        routinePlugin.medicationSummaryProvider = { [weak self] in
            self?.todayMedicationSummaryLines() ?? []
        }
        // Same fold for imported native Calendar/Reminders items — one
        // spoken list spanning all three reminder systems.
        routinePlugin.externalSummaryProvider = { [weak self] in
            self?.externalCalendar.todaysSpokenLines(locale: self?.activeLocale
                                                     ?? Locale(identifier: "en")) ?? []
        }
        // Mirror staleness seam (calendar-driven task, 2026-09-07): every
        // routine mutation re-mirrors the schedule — one seam covering
        // the voice path (RoutinePlugin.handleSet → addEntry) and the
        // Reminders leaf toggles alike.
        routineScheduler.onScheduleChanged = { [weak self] in
            self?.calendarSync.syncNow(entries: self?.routineScheduler.entries() ?? [])
            // [CALENDAR-SHARE] (2026-09-16) Same seam, second consumer: the
            // routine schedule's shared twins. Enqueue-only and cheap when
            // sharing is off (the service gates before it touches storage),
            // so no toggle check is needed here — and reading the toggle
            // here would be one more place to get the gate wrong.
            if let entries = self?.routineScheduler.entries() {
                self?.calendarShareService.reconcileRoutines(entries)
            }
        }
        // [CALENDAR-SHARE] (2026-09-16) Medication needed its own seam:
        // `MedicationScheduler` had no change notification at all, so its
        // shared twins were added along with one (`onScheduleChanged`,
        // fired at the end of `loadSchedule`) — the single funnel every
        // medication write path already goes through.
        medicationScheduler.onScheduleChanged = { [weak self] entries in
            self?.calendarShareService.reconcileMedication(entries)
            // [RICH-EVENTS] (2026-09-17) Same seam, second consumer: the
            // Sahayak mirror of the dose times (design §3). `syncNow`
            // reads the medication list back through the provider wired
            // below rather than taking it here, so there is exactly one
            // path that decides what the mirror should contain.
            self?.calendarSync.syncNow(entries: self?.routineScheduler.entries() ?? [])
        }
        // Forward the external calendar service's publishes (Settings
        // status/lead, scan results reaching the Reminders + Calendar
        // leaves) — nested ObservableObject, see the property docs.
        //
        // [BOOT-REVIEW P1-7] Forwarded through the COALESCING seam, not
        // straight to `objectWillChange`: a scan publishes per-item, and
        // every forwarded publish invalidates every coordinator observer
        // (HomeView included). One invalidation per main-runloop turn is
        // the same information with a fraction of the fan-out — observers
        // re-read current values, and the turn always completes before the
        // next frame is rendered.
        externalCalendarCancellable = externalCalendar.objectWillChange
            .sink { [weak self] _ in
                self?.noteForwardedStateChanged()
            }

        // Forward the alarms/timers service's publishes ([ALARMS-TIMERS]
        // 2026-09-07) — nested ObservableObject, same pattern (and the same
        // coalescing seam) as the external-calendar forwarding above: the
        // Settings leaf observes the coordinator, so a toggle/delete/
        // timer-start must invalidate it through this sink.
        alarmTimersCancellable = alarmTimersService.objectWillChange
            .sink { [weak self] _ in
                self?.noteForwardedStateChanged()
            }

        // [CAREGIVER-EVENTS] (2026-09-13) Forward the caregiver-notify
        // settings' publishes — nested ObservableObject, same pattern (and
        // the same coalescing seam) as the two above: the Settings leaf
        // observes the coordinator, so a toggle flip must invalidate it
        // through this sink; the schedulers read the same instance at
        // fire time and need no notification at all.
        caregiverNotifySettingsCancellable = caregiverNotifySettings.objectWillChange
            .sink { [weak self] _ in
                self?.noteForwardedStateChanged()
            }

        // [TIMER-ALARM] (2026-09-10) Ring-start hook: the looping bell
        // takes over from the OS one-shot notification sound (cancel the
        // pending UN request so the two never double up), and any spoken
        // output stops so the alarm owns the phone. Attached here (not
        // next to the engine's construction) because the closure captures
        // self.
        timerAlarmEngine.onRingStarted = { [weak self] timerID in
            self?.alarmTimersService.cancelPendingNotification(id: timerID)
            self?.speaker?.cancel()
        }
        // [TIMER-ALARM] Tap-path lookup: resolves the row for a tapped
        // timer notification even after its deadline passed (the row
        // survives the prune grace window for exactly this) — but never
        // for system-managed timers (the system presents those itself).
        timerAlarmEngine.timerLookup = { [weak self] id in
            guard let self,
                  let timer = self.alarmTimersService.timer(with: id),
                  timer.isActive,
                  !self.alarmTimersService.systemManagedTimerIDs.contains(timer.id)
            else { return nil }
            return timer
        }

        // [BOOT-REVIEW P1-7] Coalescing seam for the two nested-object
        // forwards above.
        //
        // The forwarded services publish once PER ITEM they mutate (a
        // calendar scan walks N events, each one a separate
        // `objectWillChange`), and a raw forward turns each of those into
        // a full coordinator invalidation — every observer of the
        // coordinator (HomeView's whole tree included) re-evaluates per
        // item, for state that is only meaningful once the scan settles.
        //
        // The contract kept here: an observer that re-reads current
        // values after any one invalidation sees the SAME state as after
        // the last one, so collapsing a burst into a single invalidation
        // is lossless — and the invalidation lands on the next main-run-
        // loop turn, before SwiftUI renders the following frame.
        //
        // Deliberately NOT a timer/debounce: nothing is delayed past the
        // current turn, so a single publish (a Settings toggle) still
        // invalidates within the same frame as before. The seam itself
        // (`noteForwardedStateChanged`) lives next to the init's closing
        // brace, below.

        // [BOOT-REVIEW P0 item 1] End of the composition root. [BOOT-REVIEW
        // P0-1] Everything past this point — store loads, model paths, AI
        // runtimes, second-frame composition — is first-use lazy or
        // deferred to `start()`, so this interval stays short by
        // construction.
        StartupSignposts.end(.bootstrapInit)
    }

    /// True while a coalesced forwarded invalidation is already queued for
    /// this main-runloop turn.
    private var forwardedInvalidationPending = false

    /// One invalidation per main-runloop turn, no matter how many nested
    /// publishes arrive ([BOOT-REVIEW P1-7]). Main-confined; off-main
    /// callers hop first (Combine sinks can fire on the publisher's
    /// thread, and the forwarded services are not main-only by contract).
    private func noteForwardedStateChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.noteForwardedStateChanged()
            }
            return
        }
        guard !forwardedInvalidationPending else { return }
        forwardedInvalidationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.forwardedInvalidationPending = false
            self.objectWillChange.send()
        }
    }

    /// Starts the app's post-first-frame composition. Called from
    /// `ContentView.onAppear` (and from the onboarding wizard's finish
    /// path); idempotent.
    ///
    /// [BOOT-REVIEW P0-1] This method is deliberately TINY. Everything it
    /// used to do synchronously (live-call detector, background-task
    /// registration, the safety-reminder re-arms, the whole voice +
    /// speaker + briefing + router composition) now runs one main-actor
    /// turn LATER, in `composePostFirstFrame()`. `onAppear` runs inside
    /// the same update transaction that renders the first frame, so
    /// synchronous work here delays the frame that is supposed to show
    /// the loading state; yielding one turn first lets SwiftUI commit it.
    ///
    /// What stays: the boot machine's `begin()` (the spinner's appearance
    /// window opens now, so an indicator appears only if work is genuinely
    /// still running) and the two static seams the UI reaches through —
    /// both are a handful of instructions.
    func start() {
        guard !started else { return }
        started = true

        // News reader editor seam (news-reader task, 2026-09-08):
        // the Feeds settings leaf hosts the news-source editor through
        // this static hook — assigned once the store exists.
        NewsSourceEditorSeam.makeEditor = { [newsSourceStore] in
            AnyView(NewsSourcesSettingsView(store: newsSourceStore))
        }
        // [LOUD-TTS] Response-playback loudness seam: while the assistant
        // speaks, the shared session switches to .voicePrompt (loud,
        // speech-optimized playback) and returns to the capture preset
        // the moment playback settles.
        ResponsePlaybackModeSeam.begin = { [weak self] in
            self?.audioSessionManager.beginResponsePlayback()
        }
        ResponsePlaybackModeSeam.end = { [weak self] in
            self?.audioSessionManager.endResponsePlayback()
        }
        // [BOOT-REVIEW, design item] The degraded-state recovery seam:
        // the persistent capability capsule's ONE button routes here, so
        // the recovery is owned by the coordinator (the only object that
        // can retry the failed work) without HomeView needing a
        // coordinator reference.
        StartupDegradationRecoverySeam.perform = { [weak self] capability in
            self?.recoverDegradedCapability(capability)
        }

        // [BOOT-REVIEW P0-1 fix] BGTaskScheduler REQUIRES every launch
        // handler to be registered before the app finishes launching
        // (platform contract — the deferred composition below tripped
        // NSInternalInconsistencyException "All launch handlers must be
        // registered before application finishes launching" in the unit
        // test host). Registration is two cheap identifier calls and
        // captures only; the expensive composition stays deferred.
        registerBackgroundTasks()

        // [BOOT-REVIEW P0-1] Boot begins BEFORE the composition, so the
        // spinner's appearance delay is measured from the true start of
        // startup work.
        startupBoot.begin()
        // [BOOT-REVIEW P0 item 1] `safety-data-restored` opens here and
        // closes when the restore batch is published.
        StartupSignposts.begin(.safetyDataRestored)
        // Launch-to-manual-Talk latency: closes on the real pipeline start
        // callback, independent of model warms and wake-word construction.
        StartupSignposts.begin(.manualTalkReady)
        manualTalkStartupStartedAt = DispatchTime.now().uptimeNanoseconds
        print("[AppCoordinator] startup boot begin — restoring data off-main")

        // [BOOT-REVIEW P0-1] Yield exactly one main-actor turn: SwiftUI
        // commits the first frame (loading state included) before the
        // synchronous composition below runs. Everything that follows is
        // post-first-frame by construction.
        DispatchQueue.main.async { [weak self] in
            self?.composePostFirstFrame()
        }
    }

    /// The synchronous composition `start()` used to run inline, now one
    /// main-actor turn after the first frame ([BOOT-REVIEW P0-1]).
    /// Main-confined; runs exactly once per launch (`start()`'s guard).
    private func composePostFirstFrame() {
        // [STARTUP-PERF] Conversation + activity history, the keychain
        // store loads, the KWS engine build and the bundled-model
        // housekeeping moved OFF the main thread into the progressive
        // boot below (`.restoringData` → `.preparingVoice` →
        // `.finishingSetup` → `.ready`). The published windows stay empty
        // until the boot's restore phase lands moments after first paint
        // — corrupt or missing data still loads as empty, never a crash,
        // because the same `load()`/`recent()`/`entries()` calls run, on
        // the boot queue instead of main.

        // Live-call detection (call-history task, 2026-09-06): force the
        // lazy detector to construct + subscribe so `liveCallActive`
        // tracks reality from launch. Pause/resume of spoken output
        // around calls: SKIPPED — the voice stack exposes no clean pause
        // API to hang this on (Speaker = speak/cancel only; VoicePipeline
        // = start/stop with no pause state; VoiceSessionStateMachine has
        // no pause transition; the AVSpeechSynthesizer is private inside
        // SystemSpeechSpeaker). It is also unnecessary: a real call
        // interrupts the app's audio session at the OS level
        // (AudioSessionManager already observes AVAudioSession
        // interruptions), which stops in-flight TTS — nothing in the app
        // talks over an active call, so a half-broken teardown would buy
        // nothing.
        _ = liveCallDetector

        // Background-task registration lives in `start()`'s synchronous
        // section (platform contract: before launch finishes) — see the
        // [BOOT-REVIEW P0-1 fix] note there.

        // [BOOT-REVIEW P1-7] Day rollover for the derived notification
        // count ("X of Y doses taken today" is date-dependent). Installed
        // here — post-first-frame, like every other observer — not in
        // `init()`.
        observeCalendarDayChange()
        // [T-037-a] Encoder memory-pressure lifecycle (no-op unless the
        // internal-testing INTENT_ENCODER gate is compiled in).
        observeIntentEncoderMemoryPressure()
        // [MODEL-LIFECYCLE] The residency ledger: light-slot registration,
        // the level-2 observer that evicts heavy models, and the idle
        // sweep. Installed post-first-frame like every other observer.
        startModelLifecycle()

        // Restore and re-arm any outstanding medication reminders
        medicationScheduler.scheduleAll()
        // Same re-queue for routine reminders (FR-025).
        // [BOOT-M1M2] The first-run seed moved off init: seed THEN
        // re-arm, on the boot queue (seed first — the defaults must
        // exist before scheduleAll regenerates the window; the re-arm
        // itself stays main-confined). Order preserved from the old
        // init-seed → start-rearm sequence, a few ms later.
        bootQueue.async { [weak self] in
            guard let self else { return }
            self.routineStore.seedDefaultsIfNeeded()
            DispatchQueue.main.async { self.routineScheduler.scheduleAll() }
        }
        // Same re-queue for alarms + timers ([ALARMS-TIMERS] 2026-09-07 —
        // idempotent: pending requests replace in place by id, and
        // expired timer rows are pruned first).
        // [BOOT-M1M2] Load-then-arm on the boot queue (constant-time
        // init): the persisted lists restore OFF init, and the re-arm
        // runs only after they land — arming against an unloaded list
        // would sweep the stored rows (the prune persists the in-memory
        // list).
        bootQueue.async { [weak self] in
            self?.alarmTimersService.restoreAndScheduleAll()
        }

        // Festival notifications (BS calendar, 2026-09-06): day-of for
        // every catalog festival + advance N-day reminders for important
        // ones (default 2, Settings-configurable). Idempotent rebuild.
        festivalCalendar.scheduleAll()

        // Read-only native Calendar/Reminders integration (2026-09-07):
        // launch-time refresh — NO prompts (startIfEnabled only scans
        // when the family already enabled + granted access), then the
        // hourly BGAppRefresh keeps it current while backgrounded.
        Task { await externalCalendar.startIfEnabled() }
        // Two-way mirroring (calendar-driven task, 2026-09-07): the
        // coordinator relays native edits — family changes made in the
        // Calendar app on Sahayak mirror events — back into
        // RoutineScheduler's mutators, so persistence, re-arming and
        // the mirror re-sync stay on the one mutation path. The
        // Sahayak calendar id (restored from the link store) is
        // excluded from the read-only import: those events ARE the
        // routine, whose alarms fire in-app already.
        //
        // [RICH-EVENTS] (2026-09-17) Wired BEFORE the launch pass below
        // rather than after it: the pass reads both providers, and one
        // that ran without the medication one would judge every dose
        // mirror undesired and prune its link.
        calendarSync.entriesProvider = { [weak self] in
            self?.routineScheduler.entries() ?? []
        }
        calendarSync.onNativeChanges = { [weak self] mutations in
            self?.applyNativeCalendarMutations(mutations)
        }
        // Medications ride the same mirror (design §3): one recurring
        // event per dose in the Sahayak calendar, reconciled in both
        // directions. The provider is the scheduler's own list, so the
        // mirror can never describe a dose the app would not fire.
        calendarSync.medicationEntriesProvider = { [weak self] in
            self?.medicationScheduler.medicationEntries() ?? []
        }
        calendarSync.onMedicationNativeChanges = { [weak self] mutations in
            self?.applyMedicationCalendarMutations(mutations)
        }
        if let sahayakIdentifier = calendarSync.sahayakCalendarIdentifier {
            externalCalendar.excludedCalendarIdentifiers.insert(sahayakIdentifier)
        }

        // Mirror staleness fix: re-mirror at launch when enabled (the
        // restored status survives relaunches now), so the family's
        // calendar view of the routine is current from a fresh start.
        // [RICH-EVENTS] (2026-09-17) The SEAMS are wired first, a few
        // lines up, precisely so this first pass already knows about
        // medications — a pass that cannot see them would judge their
        // mirror events undesired and would prune their links.
        if calendarSync.isEnabled {
            calendarSync.syncNow(entries: routineScheduler.entries())
        }
        // [CALENDAR-SHARE] (2026-09-16) Launch pass for the share layer —
        // after the medication restore above (it reads the restored
        // entries) and post-first-frame like everything else here, so no
        // network work delays the first paint.
        syncCalendarShare()

        // Voice pipeline is built lazily here so the CommandRouter can hold a
        // weak ref back to this fully-initialised coordinator.
        let systemSpeaker = SystemSpeechSpeaker(observabilityBus: observabilityBus)
        // PiperVoiceSpeaker is the production speaker: on-device Piper
        // VITS via sherpa-onnx (Nepali + English voices bundled), with
        // SystemSpeechSpeaker as the automatic fallback whenever a voice
        // is not installed — see docs/tts-implementation-plan.md.
        // [TURN-TIMING] Finalize callback → transcript caption. Wired
        // here (not in init): a self-capturing closure assigned during
        // init is rejected by definite-initialization, and the caption
        // only matters once the voice composition exists anyway.
        turnTracer.onTurnFinalized = { [weak self] stages, _ in
            DispatchQueue.main.async {
                self?.applyTurnTimingCaption(stages)
            }
        }
        // [TURN-TIMING-BREAKDOWN] Attach AFTER the caption hook above:
        // `attach` CHAINS to the handler already installed, so the caption
        // and the breakdown both fire on every finalized turn. One
        // `turn_latency`/`turn_timing_breakdown` event per turn; the
        // breakdown itself is published for the internal-testing card
        // (in-memory only — see `lastTurnTimingBreakdown`).
        turnLatencyReporter?.onReported = { [weak self] breakdown in
            DispatchQueue.main.async {
                self?.lastTurnTimingBreakdown = breakdown
            }
        }
        // [PIPELINE-TRACE] The trace's readout, published on the same
        // hop: the reporter assembles it on the finalizing thread and this
        // hands it to the "Pipeline trace" section (in-memory only — see
        // `lastPipelineTrace`).
        turnLatencyReporter?.onTraceReported = { [weak self] trace in
            DispatchQueue.main.async {
                self?.lastPipelineTrace = trace
            }
        }
        turnLatencyReporter?.attach(to: turnTracer)
        // [LAT-M2] Ack fast lane: one shared file-backed pre-ack cache —
        // the speaker pre-synthesizes the ack variants into it at warm
        // time (see `maybeStartAckCacheWarm`), the player below reads
        // the cached WAVs on the ack path. Files are the shared state.
        let ackAudioCache = AckAudioCache()
        let speaker: Speaker = PiperVoiceSpeaker(
            fallback: systemSpeaker,
            observabilityBus: observabilityBus,
            modelStore: modelStore,
            turnTracer: turnTracer,
            // [TURN-TIMING-BREAKDOWN] The speaker's `tts_start` ramp
            // (handed-to-speaker → audio start). Nil on non-gated builds.
            timingRecorder: turnTimingRecorder,
            // [PIPELINE-TRACE] …and the trace's `tts` row.
            traceRecorder: pipelineTraceRecorder,
            ackCache: ackAudioCache
        )
        let ackFastLanePlayer = AckFastLanePlayer(cache: ackAudioCache,
                                                  observabilityBus: observabilityBus)
        self.speaker = speaker
        // The registry is built in init but the speaker only exists now —
        // hand it to the appliance plugin so guidance summaries are spoken
        // by the same voice everything else uses.
        pluginRegistry.plugins
            .compactMap { $0 as? ApplianceHelperPlugin }
            .forEach { $0.speaker = speaker }
        // Voice-OS shell v1 — push-speech composition (design §3–§5).
        // The SpeakQueue now owns the single shared speaker for every
        // utterance: push sources (notification read-aloud, morning
        // briefing) enqueue here, and coordinator-level replies enter on
        // the `.interactive` lane through the `speak(text:)` shim below.
        // `SpeechNoteForwarder` keeps the wake-word gate and the
        // voice-session speaking count balanced per utterance — the same
        // note pair the direct-speak path fired, so nesting/cancellation
        // behavior is unchanged.
        let speechNoter = SpeechNoteForwarder(speaker: speaker) { [weak self] in
            self?.noteSpeakingStarted()
        } onEnded: { [weak self] in
            self?.noteSpeakingEnded()
        }
        let queue = SpeakQueue(speaker: speechNoter, observability: observabilityBus)
        let notificationReader = NotificationReader(queue: queue, observability: observabilityBus)
        let briefing = MorningBriefing(
            queue: queue,
            observability: observabilityBus,
            routineSource: routineScheduler,
            medicationSource: medicationScheduler,
            calendarSource: externalCalendar,
            briefingStore: morningBriefingStore,
            locale: activeLocale
        )
        // [NEWS-READER] (2026-09-08) The news digest source: same shell
        // queue + observability bus, the Keychain source store (REPLACE
        // rule), and the shared bounded-fetch seam (URLSession — 8 s
        // per source). Fired by the router's deterministic news stage via
        // `fireNewsReader()` below.
        let newsReader = NewsReader(
            queue: queue,
            observability: observabilityBus,
            store: newsSourceStore,
            transport: URLSession.shared,
            locale: activeLocale
        )
        let registry = SpeechSourceRegistry(observabilityBus: observabilityBus)
        registry.register(notificationReader)
        registry.register(briefing)
        registry.register(newsReader)
        // Single UNUserNotificationCenter delegate (design §2 confirmed
        // decision — verified no other object in the app owns this slot).
        // [TIMER-ALARM] The ringing engine is the FIRST handler: it claims
        // timer-completion notifications, so the reader never speaks over
        // the bell, and routes a tap on a delivered timer notification
        // into the ringing alarm screen.
        // [CAREGIVER-EVENTS] (2026-09-13) Third handler: turns a delivered
        // routine/calendar event notification into a caregiver alert. It
        // ALWAYS declines to claim (`willPresent` returns false), so the
        // reader below it is never suppressed and the banners keep
        // appearing — registration order here is for the read-aloud
        // allowlist, not for claiming precedence.
        let caregiverEventHandler = CaregiverEventFireHandler(
            routineScheduler: routineScheduler,
            familyNotifier: familyNotifier,
            settings: caregiverNotifySettings,
            // Resolved at FIRE time, exactly like the settings gate: the
            // item may have been deleted (nil → the alert falls back to
            // the notification's own body) or retitled by the family in
            // the native app since the scan.
            externalItemLookup: { [weak externalCalendar = self.externalCalendar] stableKey in
                externalCalendar?.reminders.first { $0.id == stableKey }
            },
            observability: observabilityBus
        )
        // [PHOTO-AIDS] The reminder's photos at the moment it fires: a
        // routine notification whose entry carries a visual aid presents
        // the full-screen elder-facing view. Registered beside the reader
        // and the caregiver handler and claims nothing, so delivery and
        // read-aloud are untouched (see the handler's own contract).
        let routineVisualAidFireHandler = RoutineVisualAidFireHandler(
            entryLookup: { [weak routineScheduler] entryId in
                routineScheduler?.entry(for: entryId)
            },
            onFire: { [weak self] entry in
                self?.presentRoutineVisualAids(for: entry)
            }
        )
        // [MED-PHOTO-AIDS] The dose's photos at the moment it fires
        // (medication-visual-aids task, 2026-09-16): a medication
        // notification whose entry carries a photo presents the
        // full-screen dose screen. Claims nothing (delivery and read-aloud
        // unchanged), exactly like its routine sibling — but it MUST be
        // registered BEFORE `notificationReader`: "MEDICATION_REMINDER" is
        // the one category the reader allowlists, and the facade stops
        // consulting handlers at the first claim, so a dose reaching this
        // handler at all depends on this position in the array.
        let medicationVisualAidFireHandler = MedicationVisualAidFireHandler(
            entryLookup: { [weak medicationScheduler] entryId in
                medicationScheduler?.medicationEntry(for: entryId)
            },
            onFire: { [weak self] entry in
                self?.presentMedicationVisualAids(for: entry)
            }
        )
        // [RICH-EVENTS] The free-form event's own reminder (rich-events
        // task, 2026-09-17; design §4): an event with a photo presents the
        // app's event detail at fire time, and the banner's Open action (or
        // a plain tap) deep-links to the same screen. Claims nothing —
        // delivery, read-aloud and the caregiver alert are untouched —
        // and needs no position rule of its own: its category
        // ("EVENT_REMINDER") is not on the reader's allowlist, so no other
        // handler can claim a notification before this one sees it. The
        // lookups run through the coordinator's LAZY service, so wiring
        // this handler still constructs nothing at launch.
        let freeFormEventFireHandler = FreeFormEventFireHandler(
            eventLookup: { [weak self] eventId in
                self?.freeFormEventService.event(withId: eventId)
            },
            onFire: { [weak self] eventId in
                self?.openEventDetail(eventId: eventId)
            }
        )
        let facade = NotificationFacade(handlers: [timerAlarmEngine,
                                                   medicationVisualAidFireHandler,
                                                   notificationReader, caregiverEventHandler,
                                                   routineVisualAidFireHandler,
                                                   freeFormEventFireHandler],
                                         observability: observabilityBus)
        UNUserNotificationCenter.current().delegate = facade
        // [TIMER-ALARM] Foreground driver: evaluates the ringing engine
        // twice a second while the app runs (plus a tick on
        // scene-phase .active). Cheap — a snapshot adopt + one deadline
        // compare while idle.
        let alarmDriver = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.timerAlarmEngine.tick(
                activeTimers: self.alarmTimersService.engineManagedActiveTimers)
        }
        RunLoop.main.add(alarmDriver, forMode: .common)
        self.timerAlarmDriver = alarmDriver
        // [TIMER-ALARM] iOS 26: mirror system-side timer dismissals (the
        // Lock Screen alert's Stop, the Dynamic Island dismiss) into the
        // timer rows — the system record is the truth.
        if #available(iOS 26.0, *) {
            observeSystemTimerUpdates()
        }
        self.speakQueue = queue
        self.speechSourceRegistry = registry
        self.notificationFacade = facade
        self.morningBriefing = briefing
        self.newsReader = newsReader
        // Push-speech cards surface through the EXISTING Home outcome-card
        // presentation (speech + card, spec §4.6). Interactive replies
        // carry nil cards and never touch this outcome. The card persists
        // after speech ends — the queue clears only its own state.
        shellCardCancellable = queue.$currentCard
            .compactMap { $0 }
            .sink { [weak self] card in
                self?.presentShellCard(card)
            }
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
        let router3 = IntentRouter(cache: intentCache, observabilityBus: observabilityBus,
                                   // [PIPELINE-TRACE] The band policy's own
                                   // row (score in, branch out); nil on
                                   // non-gated builds.
                                   traceRecorder: pipelineTraceRecorder)
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
        //
        // [T-037-a] Internal-testing encoder slot: when the INTENT_ENCODER
        // compilation condition is present AND the ModelStore artifact is
        // installed AND the bundled resources load, the encoder takes the
        // `preferred` slot; otherwise the chain serves
        // `localIntentInterpreter` UNCHANGED (the shipped default). The
        // stand-in (`llamaCommandInterpreter`) and every other layer are
        // untouched — the keyword safety net still runs upstream of this
        // whole chain.
        //
        // [ENCODER-RUNTIME-READY] The slot is wired through
        // `deferredEncoderPreference`, so availability is re-read every
        // turn: a tester whose artifact installs after launch (the
        // readiness request below) gets the encoder on the next turn
        // instead of needing a relaunch.
        //
        // `gatedEncoder` is what protects the lazy factory: the closure is
        // evaluated only when the gate is on, so a non-gated build never
        // even CONSTRUCTS the interpreter (see the lazy var's docs). The
        // wiring decision and the selection event both live in
        // `IntentEncoderWiring`, so the shipped call site is the tested one.
        // [ENCODER-RUNTIME-TOGGLE] The decision moved into a method because
        // the tester can now flip the encoder on and off at runtime: the
        // Settings switch re-runs this same installation, so the slot is
        // hot-swapped on the next turn rather than frozen at boot.
        installLocalBrainSlot(on: router3)
        router3.cloudBrain = geminiInterpreter
        router3.cloudEnabled = (voiceEngineStack == .gemini)
        // [LAT-M3] (2026-09-11) Cloud-FIRST open-domain interpretation
        // (latency plan M3): armed here; the per-turn selector inside
        // `IntentRouter` then picks cloud vs local from the SAME inputs
        // the rest of the app consults — the stack's cloud consent
        // (`cloudEnabled`, maintained by `applyVoiceEngineStack`) plus
        // the Gemini key plus the day's cost budget. On the on-device
        // stack `cloudEnabled` stays false (absent the cloud-fallback
        // opt-in) and the legacy local-first ladder runs unchanged;
        // with the opt-in — or on the Gemini stack — a configured key
        // and an open budget make every LLM-bound utterance answer from
        // the cloud (~1.5–2.5 s) with a time-bounded llama fallback on
        // failure.
        router3.cloudFirstEnabled = true
        router3.geminiKeyConfigured = { [weak self] in
            self?.geminiConfigStore.isConfigured ?? false
        }
        router3.geminiCostAllows = { [weak self] in
            self?.geminiCostGovernor.allowsCall() ?? false
        }
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
            geminiClient: geminiClient,
            // [LOCAL-TOOLS] (2026-09-07) Live weather/search seams for the
            // on-device stack: the search credential store, a fresh
            // LocationFetcher per weather question (one request per
            // instance — see LocationFetcher's doc), and URLSession for
            // both transports (each tool's request carries its own
            // timeout; see WeatherTool + the router's search timeout).
            // [TOOL-DEBUG-LOG] (2026-09-07) The encrypted request log
            // store — the router records one entry per weather/search
            // attempt (see CommandRouter.logToolRequest).
            searchConfigStore: searchConfigStore,
            locationFetcherFactory: { LocationFetcher() },
            weatherTransport: URLSession.shared,
            searchTransport: URLSession.shared,
            localToolLogStore: localToolLogStore,
            // [YOUTUBE] (2026-09-08) YouTube stage seams: the Data API
            // key store, URLSession for the lookup round-trip (the
            // tool's request carries its own timeout), and the same
            // call-link opener seam the call/message flows use for
            // canOpenURL probing + opening (youtube:// → https
            // fallback).
            youtubeConfigStore: youtubeConfigStore,
            youtubeTransport: URLSession.shared,
            youtubeLinkOpener: SystemCallLinkOpener(),
            // [LAT-M2] Ack fast lane: cached-WAV playback on the pre-ack
            // path (miss → synthesis fallback + `ack_cache_miss`).
            preAckPlayer: ackFastLanePlayer,
            turnTracer: turnTracer
        )
        // [STARTUP-PERF] Retained for the boot's pipeline build.
        commandRouter = router
        // Hot-swap trigger: as soon as a Gemini API key is saved (Settings
        // or onboarding), swap the fallback SFSpeechRecognizer for the real
        // recognizer without tearing down the wake-word loop. Attached here
        // (like the router wiring above) so a key change can never race
        // the boot's pipeline build.
        geminiSwapCancellable = geminiConfigStore.$apiKey
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.trySwapToGemini()
            }
        // [STT-RESTORE] Companion subscription for the ANE auto-restore:
        // a landed artifact re-applies the stack (see
        // `observeSTTArtifactCompletion`).
        observeSTTArtifactCompletion()

        // [STARTUP-PERF] The voice pipeline (which needs the KWS engine
        // the boot builds off-main) is constructed and started in the
        // boot's `.preparingVoice` phase. Everything above stays
        // synchronous so `handleScenePhase`'s morning-briefing fire and
        // the talk cycle see the same composition as before.
        isInitialized = true
        print("[AppCoordinator] Elderly AI Assistant started")

        // Hand phase 1 (store loads) to the boot queue; every published
        // assignment hops back to main. The boot machine itself was begun
        // in `start()` — before this composition, so its spinner window
        // measures real startup work.
        //
        // [BOOT-REVIEW P0-1] The FIRST-USE LAZY stores/services the boot
        // queue touches are forced to construct HERE, on main (lazy
        // initialization is not thread-safe — the house rule every lazy
        // store in this file already follows). Everything forced below is
        // cheap by construction: the Gemini/config Keychain reads moved
        // to the boot queue's own `load`, and the model store's paths are
        // only resolved when a model is actually needed.
        _ = chatHistoryStore
        _ = activityLog
        _ = feedSettingsStore
        _ = modelStore
        // [BOOT-M1M2] Gemini key/model restore, same discipline: the
        // kick runs on MAIN here (the store's @Published values are
        // main-confined), the keychain reads run on the boot queue and
        // the published values land back on main.
        geminiConfigStore.loadPersistedValues(on: bootQueue)
        bootQueue.async { [weak self] in
            self?.bootRestoreData()
        }
    }

    // MARK: - Progressive startup boot (startup-perf task, 2026-09-09)

    /// Phase 1 — restore persisted data on the boot queue: the keychain
    /// stores + the conversation/activity windows. The stores are
    /// thread-safe (each `load()` is an independent
    /// `SecItemCopyMatching` + decode with empty-on-error semantics);
    /// the published windows are assigned on main afterwards.
    private func bootRestoreData() {
        let batch = StartupDataBatch.load(
            contactStore: familyContactStore,
            placeStore: placeStore,
            appointmentStore: appointmentStore,
            briefingStore: morningBriefingStore,
            feedSettingsStore: feedSettingsStore,
            chatHistoryStore: chatHistoryStore,
            activityLog: activityLog,
            storage: storage,
            now: Date()
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = batch.contacts
            self.familyNotifier.updateContacts(
                Self.emergencyContacts(from: batch.contacts,
                                       defaultCallApp: self.defaultCallApp))
            self.savedPlaces = batch.places
            self.appointments = batch.appointments
            self.todayBriefing = batch.briefing
            self.feedSources = batch.feedSources
            self.feedTopics = batch.feedTopics
            self.conversationHistory = batch.history
            self.recentActivity = batch.activity
            // [BOOT-REVIEW P1-7] The restore moved both of the derived
            // count's inputs (a stored briefing + today's restored dose
            // list) — recompute once, here, instead of leaving the badge
            // stale until the next reminder edit.
            self.refreshActiveNotificationCount()
            // [BOOT-REVIEW P0 item 1] Safety-critical data is live the
            // moment these windows are published (contacts feed the
            // emergency path, appointments/places the care flows); the
            // interval ends HERE — after the restore, before the voice
            // phase — so it measures restoration alone.
            StartupSignposts.end(
                .safetyDataRestored,
                note: "contacts=\(batch.contacts.count) places=\(batch.places.count) appointments=\(batch.appointments.count)"
            )
            self.startupBoot.advance(to: .preparingVoice)
            // Phase 2 runs on MAIN (see bootPrepareVoiceEngine — the
            // sherpa runtime segfaults off-main on the x86_64 simulator).
            self.bootPrepareVoiceEngine()
        }
    }

    /// Phase 2 — construct + start the voice pipeline, then hand the
    /// file-heavy phase 3 to the boot queue. The pipeline is constructed
    /// with the honest `NullWakeWordEngine` — the sherpa KWS build (its
    /// ONNX load is the expensive part) is DEFERRED until after the
    /// speak affordance is live (`updateVoiceReadiness` schedules it
    /// post-ready, still on MAIN: the sherpa-onnx/onnxruntime session
    /// creation segfaulted off-main on the x86_64 simulator —
    /// EXC_BAD_ACCESS in ConstantFolding, crash 2026-09-09 204647,
    /// faulting queue `senios.startup.boot`). The real engine is then
    /// hot-swapped into the running pipeline via
    /// `VoicePipeline.setWakeWordEngine` — the two engine shapes share
    /// the 16 kHz / 512-frame audio contract, so the installed mic tap
    /// needs no reconfiguration. A failed deferred build keeps the
    /// existing honest Null-engine behavior, and a failed pipeline start
    /// surfaces exactly as it always did (voice error state) and is
    /// recorded on the boot machine.
    ///
    /// Issue the real pipeline request first. Engine warming begins only
    /// after its callback settles, so model IO/CPU cannot compete with
    /// audio-session activation on first load.
    private func bootPrepareVoiceEngine() {
        StartupSignposts.begin(.voicePipelineStartRequested)
        // Null KWS + fallback STT are sufficient for explicit manual Talk.
        // Preferred engines hot-swap after this pipeline is live.
        self.buildAndStartVoicePipeline()
    }

    // MARK: - Voice readiness ([STARTUP-R2])

    /// Pipeline state only drives the separately deferred KWS build. An
    /// idle pipeline already means manual Talk is enabled; wake-word status
    /// arrives independently and can never move that readiness backward.
    private func updateVoiceReadiness() {
        if case .idle = voiceState {
            print("[AppCoordinator] voice pipeline idle — KWS build eligible")
            scheduleDeferredKWSBuildIfNeeded()
        }
    }

    // MARK: - Manual-Talk readiness ([BOOT-REVIEW P0-2])
    //
    // The four `voicePipeline.start` call sites funnel through these
    // three helpers, so the published `voicePipelineReadiness` can only
    // move along the contract's edges:
    //
    //   request  → stays `.loading` (a REQUEST is not a START),
    //   success  → `.ready`            (the one and only path),
    //   failure  → `.failed(reason)`   (persists until a real retry),
    //
    // and they carry the two voice signpost intervals the review asks
    // for: `voice-pipeline-start-requested` (boot → request issued) and
    // `voice-pipeline-callback-completed` (request → callback answered).

    /// The pipeline-start REQUEST was just issued. Never moves a settled
    /// value: `.ready` stays ready, `.failed` stays failed until the new
    /// callback answers (the retry is honest).
    private func noteVoicePipelineStartRequested() {
        manualTalkReadiness.noteStartRequested()
        StartupSignposts.end(.voicePipelineStartRequested, note: "request-issued")
        StartupSignposts.begin(.voicePipelineCallbackCompleted)
        publishManualTalkReadiness()
    }

    /// The pipeline-start callback SUCCEEDED — the contract's only path
    /// to `.ready`, for the boot start and for every later recycle,
    /// search-capture resume and enrollment resume alike (a retry that
    /// works is genuinely ready again).
    private func noteVoicePipelineStartSucceeded() {
        manualTalkReadiness.noteStartSucceeded()
        StartupSignposts.end(.voicePipelineCallbackCompleted, note: "success")
        StartupSignposts.end(.manualTalkReady, note: "success")
        finishManualTalkStartup(outcome: "success")
        // [BOOT-REVIEW, design item] A capability that comes back
        // DEGRADES no longer: the recorded boot failure is cleared by the
        // success that proves it (never by a timer), so the persistent
        // "Voice activation is unavailable" state disappears here.
        startupBoot.clearFailure(.preparingVoice)
        publishManualTalkReadiness()
    }

    /// The pipeline-start callback FAILED. The failure is sticky: it is
    /// surfaced to the user (Talk hero + `startup.degraded.*` capability
    /// state) and cleared only by a retry that actually succeeds.
    private func noteVoicePipelineStartFailed(_ error: Error) {
        manualTalkReadiness.noteStartFailed(reason: "\(error)")
        StartupSignposts.end(.voicePipelineCallbackCompleted, note: "failure")
        StartupSignposts.end(.manualTalkReady, note: "failure")
        finishManualTalkStartup(outcome: "failure")
        publishManualTalkReadiness()
    }
    /// Emits one PII-free launch duration. Later pipeline recycle/retry
    /// callbacks do not overwrite the first-load metric.
    private func finishManualTalkStartup(outcome: String) {
        guard let beganAt = manualTalkStartupStartedAt else { return }
        manualTalkStartupStartedAt = nil
        let elapsed = DispatchTime.now().uptimeNanoseconds - beganAt
        let durationMs = Int(elapsed / 1_000_000)
        observabilityBus.emit(ObservabilityEvent(
            component: "voice_pipeline",
            eventType: "manual_talk_ready",
            durationMs: durationMs,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]))
        print("[AppCoordinator] manual_talk_ready duration_ms=\(durationMs) outcome=\(outcome)")
    }


    /// Publishes the real manual capability: the pipeline's own callback.
    /// Warm engines and wake word have separate state and metrics.
    private func publishManualTalkReadiness() {
        let value = manualTalkReadiness.value
        if Thread.isMainThread {
            voicePipelineReadiness = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.voicePipelineReadiness = value
            }
        }
    }

    /// Records background warm/KWS settlement independently from manual
    /// Talk. The watchdog bounds telemetry only; it never controls the UI.
    private func noteTalkContractChanged() {
        if talkBootContract.isComplete {
            if !talkContractSettled {
                talkContractSettled = true
                talkContractWatchdog.cancel()
                observabilityBus.emit(ObservabilityEvent(
                    component: "talk_boot_contract",
                    eventType: "settled",
                    durationMs: nil,
                    outcome: talkBootContract.isSatisfied ? "ready" : "degraded",
                    errorCode: nil,
                    metadata: [
                        "cold_features": talkBootContract.coldFeatures
                            .map(\.rawValue).joined(separator: ",")
                    ]))
            }
        } else {
            // [CONTRACT-FIX] Belt-and-braces: ANY feed of an open
            // contract guarantees the settlement backstop is armed. The
            // arm is idempotent (first arm wins), so a feed path that
            // runs without `startBootWarmPhase`'s explicit arm still
            // gets the deadline — the contract can never await a signal
            // with no bound.
            armTalkContractWatchdog()
        }
    }

    /// [LAT-M1] Arms the talk watchdog once per contract (boot warm
    /// phase or the degraded-state warm retry — re-arming is a no-op on
    /// an already-settled contract). Main-confined.
    /// [CONTRACT-FIX] The deadline runs on an INDEPENDENT scheduler
    /// (main) — never the warm queue — so a hung warm can never delay
    /// settlement past the deadline. Idempotent: the deadline is measured
    /// from the FIRST arm; a retry re-plan cannot extend the wait.
    private func armTalkContractWatchdog() {
        guard !talkBootContract.isComplete else { return }
        talkContractWatchdog.arm(
            after: TalkBootContractState.talkWatchdogSeconds
        ) { [weak self] in
            guard let self else { return }
            guard !self.talkBootContract.isComplete else { return }
            print("[AppCoordinator] talk contract watchdog — degrading "
                + "pending features honestly")
            // [CONTRACT-FIX] The machine re-reads CURRENT state: only
            // features still `.pending` settle here, so any real settle
            // that landed before the deadline is honored, never
            // overwritten.
            self.talkBootContract.noteTalkWatchdogExpired()
            self.noteTalkContractChanged()
        }
    }

    // MARK: - Degraded-capability recovery ([BOOT-REVIEW, design item])

    /// The ONE recovery action each persistent `StartupDegradation` offers
    /// — installed as `StartupDegradationRecoverySeam.perform` by
    /// `start()`. Every branch retries the REAL work the failed boot stage
    /// was doing, and the recorded failure is cleared by that work
    /// actually succeeding (or by the voice callback's success above) —
    /// never by a timer. The degraded capsule disappears because the
    /// capability recovered.
    ///
    /// Main-confined (button tap path).
    private func recoverDegradedCapability(_ capability: StartupDegradation.Capability) {
        switch capability {
        case .savedData:
            // Re-run the restore batch off-main — the same call the boot
            // makes, so self-heal/cap semantics are identical — then clear
            // the failure once the published windows are repopulated.
            bootQueue.async { [weak self] in
                guard let self else { return }
                self.bootRestoreData()
                DispatchQueue.main.async {
                    self.startupBoot.clearFailure(.restoringData)
                }
            }
        case .voiceActivation:
            // The Talk hero's own retry path: recycle the pipeline. The
            // start callback settles both the readiness machine and the
            // recorded failure (success clears it, failure re-records it).
            recoverVoiceCycle()
        case .speechEngineWarm:
            // Re-plan and re-run the warm from LIVE config. The boot is
            // already `.ready` here, so this cannot rewind a stage — and
            // `advancePastWarmPhase` skips phase 3 for a post-boot warm.
            startBootWarmPhase(isRetry: true)
        case .modelSetup:
            // Re-run the file-heavy housekeeping phase, then clear the
            // failure on completion. Idempotent by construction (the
            // installs no-op when their target exists).
            bootQueue.async { [weak self] in
                guard let self else { return }
                self.bootFinishSetup()
                DispatchQueue.main.async {
                    self.startupBoot.clearFailure(.finishingSetup)
                }
            }
        }
    }

    /// [STARTUP-R2] Schedules the sherpa KWS build on MAIN, a short
    /// delay after the speak affordance first goes ready — the build
    /// never contributes to perceived startup, and wake-word detection
    /// arrives moments later (documented honest limit). One-shot per
    /// launch. Called only from `updateVoiceReadiness` on `.idle`, so a
    /// pipeline that never reaches idle (boot start failure) never
    /// builds the engine; a hot-swap into a recycled pipeline re-starts
    /// the engine through the swap itself.
    private func scheduleDeferredKWSBuildIfNeeded() {
        guard !deferredKWSBuildScheduled else { return }
        deferredKWSBuildScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.deferredKWSBuildDelaySeconds
        ) { [weak self] in
            self?.buildDeferredWakeWordEngine()
        }
    }

    /// The deferred KWS build: same honest decision as the old eager
    /// `bootPrepareVoiceEngine` call (`makeWakeWordEngine` — toggle on +
    /// bundled sherpa model ⇒ real engine, else Null), executed after
    /// the speak affordance is live and hot-swapped into the running
    /// pipeline. `wakeWordEngineRealAtLaunch` is published here so the
    /// Settings "Voice activation" status flips to "active" the moment
    /// the real engine lands — no restart needed. The pipeline swap is
    /// skipped when the pipeline is gone (recycled mid-build) or not
    /// settled: the Null engine's no-op behavior then applies exactly
    /// as it does pre-build.
    ///
    /// [BOOT-REVIEW P0-4] WHERE the build runs is now platform-specific:
    ///
    ///  - OFF the main thread on a physical device, on this type's ONE
    ///    dedicated serial executor (`wakeWordBuildQueue`). The KWS
    ///    session build (model resolution + ONNX session/tokenizer
    ///    construction) is CPU- and IO-heavy: on the main thread it is a
    ///    visible hitch, and the whole point of the deferred slot was to
    ///    keep wake-word work off the critical path. One SERIAL executor
    ///    means two builds can never overlap (the shared model directory
    ///    plus the memory spike are single-build resources).
    ///
    ///  - ON the main thread in the simulator ONLY, behind
    ///    `#if targetEnvironment(simulator)`: the sherpa-onnx /
    ///    onnxruntime session creation segfaults off-main on the x86_64
    ///    simulator (EXC_BAD_ACCESS in ConstantFolding, crash 2026-09-09
    ///    204647, faulting queue `senios.startup.boot`). That workaround
    ///    is a SIMULATOR defect, so it is scoped to the simulator — a
    ///    device build never takes the main-thread path.
    ///
    /// Only wake-word STATUS is gated on this build (`wakeWordEngine` /
    /// `wakeWordEngineRealAtLaunch`, and the pipeline's engine swap when
    /// it is still idle). Manual Talk readiness is deliberately NOT —
    /// wake-word and manual Talk are separate capabilities.
    private func buildDeferredWakeWordEngine() {
        guard voicePipeline != nil else {
            // [CONTRACT-FIX] The pipeline is gone (recycled mid-deferral)
            // and `deferredKWSBuildScheduled` is one-shot — this build
            // can never run again, so the contract would wait on a
            // settle that can never arrive. Tell it the honest truth:
            // the Null engine's no-op behavior applies exactly as it
            // does pre-build (the same `noteKWSApplied(isReal: false)`
            // the Null fallback emits) — settled, never awaited, never a
            // Talk degradation. The talk watchdog stays armed as the
            // backstop for everything else.
            talkBootContract.noteKWSApplied(isReal: false)
            noteTalkContractChanged()
            print("[AppCoordinator] deferred KWS build: pipeline gone — "
                + "contract KWS settled as Null fallback")
            return
        }
        // [VAD-RT] A live voice turn must never share the main thread
        // with the KWS session build. The DEVICE path already runs the
        // build on `wakeWordBuildQueue` (off-main — the sherpa ONNX
        // off-main segfault is an x86_64 SIMULATOR defect, so the device
        // build stays on the background executor); only `applyWakeWord
        // Engine` lands on main there and it is cheap. The SIMULATOR
        // path constructs the session ON MAIN (the segfault workaround)
        // and that can take seconds — exactly the window in which
        // `finishCaptureFromVAD`'s main hop waits, delaying the
        // capture's `vad_end`/`finish()` by the whole build. When a
        // capture is live here, defer until the pipeline is idle again:
        // the retry hook lives in `handlePipelineState`'s `.idle` case.
        guard voicePipeline?.state == .idle else {
            deferredKWSBuildPendingWhileBusy = true
            print("[AppCoordinator] deferred KWS build: voice turn live — "
                + "deferring until idle")
            return
        }
        #if targetEnvironment(simulator)
        applyWakeWordEngine(Self.makeWakeWordEngine(observabilityBus: observabilityBus))
        #else
        wakeWordBuildQueue.async { [weak self] in
            guard let self else { return }
            let launch = Self.makeWakeWordEngine(observabilityBus: self.observabilityBus)
            DispatchQueue.main.async {
                self.applyWakeWordEngine(launch)
            }
        }
        #endif
    }

    /// The KWS build's ONE dedicated serial executor ([BOOT-REVIEW
    /// P0-4]): user-initiated QoS (the user is waiting on wake word at
    /// most as a background affordance, never for a reply), serial so
    /// builds queue instead of overlapping.
    private let wakeWordBuildQueue = DispatchQueue(
        label: "senios.startup.kws",
        qos: .userInitiated
    )

    /// Main-confined landing of a finished KWS build: publishes the
    /// honest engine status, tells the manual-Talk machine the wake-word
    /// engine settled (deliberately a no-op there — see
    /// `ManualTalkReadinessState.noteWakeWordEngineSettled`), and swaps
    /// the engine into a still-idle pipeline.
    private func applyWakeWordEngine(_ launch: (engine: WakeWordEngine, isReal: Bool)) {
        self.wakeWordEngine = launch.engine
        self.wakeWordEngineRealAtLaunch = launch.isReal
        manualTalkReadiness.noteWakeWordEngineSettled(isReal: launch.isReal)
        // Background KWS telemetry settles HERE. A real engine is ready;
        // Null is a satisfied skip. Neither changes manual Talk readiness.
        talkBootContract.noteKWSApplied(isReal: launch.isReal)
        noteTalkContractChanged()
        print("[AppCoordinator] deferred KWS build settled real=\(launch.isReal)")
        guard launch.isReal,
              voicePipeline?.state == .idle else { return }
        voicePipeline?.setWakeWordEngine(launch.engine)
    }

    // MARK: - Boot phase 2.5 — engine warm-start ([WARM-START])

    /// Main-confined flag: the warm phase settled (finished or watchdog)
    /// — guards the two completion paths against double-advancing boot.
    private var warmPhaseSettled = false
    /// Guards the callback-time start plus watchdog fallback from launching
    /// the large warm plan twice.
    private var bootWarmPhaseStarted = false
    private var warmWatchdogWork: DispatchWorkItem?
    /// ONE runner for both warm slices: a post-boot warm dispatched
    /// while a boot warm is still finishing queues BEHIND it on the
    /// same serial queue — two engine constructions never overlap, so
    /// the memory spike stays bounded (the runner's own contract).
    private lazy var warmRunner = WarmStartRunner(
        stt: whisperKitSpeechRecognizer,
        tts: speaker as? TTSVoiceWarming,
        // [LAT-M1] The llama warm seam — the interpreter loads its
        // weights + context at boot so the first interpret skips the
        // load.
        llm: llamaCommandInterpreter,
        observabilityBus: observabilityBus)
    /// The plan slice deferred past `.ready` (secondary voices,
    /// simulator TTS warms). Consumed exactly once — boot runs once per
    /// launch.
    private var postBootWarmSteps: [WarmStartStep] = []

    /// Plans the warm from live config (resolved HERE on main), splits
    /// the plan on its lifecycle slots, reports the boot slice's
    /// progress through the spinner's `.warmingEngines` stage, and hands
    /// execution to `WarmStartRunner` on its own queue. The post-boot
    /// slice runs after `.ready` (`startDetachedPostBootWarm`) — same
    /// settings gates, only the slot moved, so it can never delay boot.
    private func startBootWarmPhase(isRetry: Bool = false) {
        if !isRetry {
            guard !bootWarmPhaseStarted else { return }
            bootWarmPhaseStarted = true
        }
        warmPhaseSettled = false
        let config = WarmStartConfig(
            enabled: warmStartEnabled,
            stack: voiceEngineStack,
            whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
            whisperCppAvailable: whisperSpeechRecognizer.isAvailable,
            availableTTSVoices: Self.availableWarmTTSVoices(modelStore: modelStore,
                                                            bundle: .main),
            selectedNepaliVoiceID: ResponseVoiceSelection.persisted()?.voiceID
                ?? ModelCatalog.piperNepali,
            llamaAvailable: llamaCommandInterpreter.isAvailable,
            wakeWordEnabled: wakeWordEnabled,
            isSimulator: Self.isSimulator
        )
        let plan = WarmStartPlanner.plan(for: config)
        let bootPlan = plan.filter { $0.phase == .boot }
        postBootWarmSteps = plan.filter { $0.phase == .postBoot }
        // Feed independent background engine-readiness telemetry before
        // any early return. This contract bounds and reports warm/KWS
        // settlement only; manual Talk is already governed by the pipeline
        // callback and never waits here.
        for step in plan {
            talkBootContract.noteWarmPlanStep(step)
        }
        talkBootContract.settleUnplannedWarmFeatures()
        armTalkContractWatchdog()
        noteTalkContractChanged()
        guard !bootPlan.isEmpty else {
            // Nothing warms during boot (preference off, or the whole
            // plan deferred — the simulator defers every TTS warm) —
            // skip the stage entirely so the spinner never flashes it.
            advancePastWarmPhase()
            return
        }
        self.startupBoot.advance(to: .warmingEngines)
        // [BOOT-REVIEW P0 item 1] `warm-engines-completed` — begun with
        // the real warm (not the skipped-plan path) and ended at settle,
        // whichever path settles it.
        StartupSignposts.begin(.warmEnginesCompleted)
        warmRunner.run(plan: bootPlan) { [weak self] outcomes in
            DispatchQueue.main.async {
                guard let self, !self.warmPhaseSettled else { return }
                // [LAT-M1] Feed the contract first: every boot-slice
                // outcome settles its feature (ready / failed — skip
                // steps were already settled at plan time and the
                // machine ignores their nil results).
                for outcome in outcomes {
                    guard let feature = TalkBootContractState.feature(
                        for: outcome.step.engine),
                        let result = outcome.result else { continue }
                    self.talkBootContract.noteWarmOutcome(feature: feature,
                                                          result: result)
                }
                if outcomes.contains(where: {
                    if case .failed = $0.result { return true }
                    return false
                }) {
                    // Honest degradation — a failed warm means the first
                    // conversation pays the load, i.e. today's behavior.
                    self.startupBoot.recordFailure(.warmingEngines)
                }
                // [LAT-M2] The TTS warm step (if any) settled — build
                // the pre-ack cache on its heels. Detached: never holds
                // the boot; the ack path falls back to synthesis until
                // it lands.
                self.maybeStartAckCacheWarm()
self.noteTalkContractChanged()
                self.advancePastWarmPhase()
            }
        }
        // The budget watchdog: a warm that outlives the short boot
        // budget must never hold the spinner (the startup-perf contract
        // — failures never halt boot). Boot advances; the warm finishes
        // detached on the warm queue and still caches its engine.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.warmPhaseSettled else { return }
            print("[AppCoordinator] warm-start budget reached — boot advances; warm finishes detached")
            self.startupBoot.recordFailure(.warmingEngines)
            self.advancePastWarmPhase(outcome: "watchdog")
        }
        warmWatchdogWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WarmStartPlanner.bootWarmBudgetSeconds,
            execute: work)
    }

    /// Settles the warm phase exactly once and hands phase 3 to the boot
    /// queue. Main-confined.
    private func advancePastWarmPhase(outcome: String = "settled") {
        warmPhaseSettled = true
        warmWatchdogWork?.cancel()
        warmWatchdogWork = nil
        // [BOOT-REVIEW P0 item 1] No-op when the warm plan was empty
        // (nothing was begun) — the interval only ever covers real warm
        // work.
        StartupSignposts.end(.warmEnginesCompleted, note: outcome)
        self.startupBoot.advance(to: .finishingSetup)
        // Phase 3 only exists while the boot is still running: a WARM
        // RETRY after `.ready` (the degraded-state recovery action)
        // settles the warm without re-running the model housekeeping.
        guard !startupBoot.isComplete else { return }
        self.bootQueue.async { [weak self] in
            self?.bootFinishSetup()
        }
    }

    /// TTS voice ids the warm seam can actually load: the directory is
    /// installed, or the bundled resource is present (the warm seam
    /// installs it idempotently — the same lazy install the speak path
    /// performs, so warm works on first run too).
    private static func availableWarmTTSVoices(modelStore: ModelStore,
                                               bundle: Bundle) -> Set<ModelID> {
        var ids: Set<ModelID> = []
        for id in [ModelCatalog.piperNepali,
                   ModelCatalog.piperNepaliChitwan,
                   ModelCatalog.piperEnglishUS] {
            if modelStore.ttsVoiceDirectory(for: id) != nil {
                ids.insert(id)
                continue
            }
            guard let entry = ModelCatalog.entry(for: id),
                  let name = entry.bundledResourceName,
                  bundle.url(forResource: name, withExtension: nil,
                             subdirectory: "tts") != nil else { continue }
            ids.insert(id)
        }
        return ids
    }

    private static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// [STARTUP-R2] Resolves the on-device stack's STT engine through
    /// the pure selection table (see OnDeviceSTTSelection). Static +
    /// parameterized so the decision is unit-tested without a
    /// coordinator.
    static func onDeviceSTTChoice(whisperKitAvailable: Bool,
                                  whisperCppAvailable: Bool,
                                  isSimulator: Bool = AppCoordinator.isSimulator)
        -> OnDeviceSTTSelection.Choice {
        OnDeviceSTTSelection.choose(
            whisperKitAvailable: whisperKitAvailable,
            whisperCppAvailable: whisperCppAvailable,
            isSimulator: isSimulator)
    }

    /// Reports WHY the ANE/whisper path lost (PII-free, machine copy
    /// only) — the selection table's honest reason string, mirroring
    /// the warm plan's "simulator" skip event.
    private static func emitSTTSelectionReason(_ reason: String,
                                               bus: ObservabilityBus) {
        bus.emit(ObservabilityEvent(
            component: "stt_selection",
            eventType: "engine_chosen",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["reason": reason]
        ))
    }

    /// Phase 3 — file-heavy model housekeeping on the boot queue: the
    /// bundled-encoder repair + bundled-model install (a FIRST-RUN copy
    /// of the 586 MB default medium GGUF that used to freeze the main
    /// thread for seconds) + stale-encoder cleanup. Then the gated
    /// assistant-brain download check — still strictly after first
    /// paint, still skipped on the Gemini stack / cached model, so no
    /// new network activity happens at launch.
    private func bootFinishSetup() {
        // [BOOT-REVIEW P1-5] The old per-entry `installBundledModel` +
        // `installBundledCoreMLEncoder` loop is GONE from this slot. That
        // loop copied the app-bundled 560 MB default ggml into Application
        // Support on EVERY launch's boot ("first run never downloads it" —
        // by copying hundreds of MB instead). Normal startup now copies
        // nothing: the one bundled artifact the app can run (the default
        // Nepali medium, `bundledResourceName != nil`) is installed only
        // when the stack that needs it is actually selected, on the
        // utility-QoS housekeeping queue (see
        // `installBundledSTTModelIfNeeded`).
        //
        // What is left here is BOUNDED and idempotent: delete stale CoreML
        // encoder directories (entries we no longer ship an encoder for —
        // large-v3's CoreML path hangs on-device — would otherwise be
        // auto-loaded by whisper.cpp). Every catalog entry currently
        // declares `coreMLEncoderBundledName: nil`, so in this build the
        // pass removes leftovers from older installs and nothing else.
        // [BOOT-REVIEW P1-5] Runs at UTILITY QoS: this is housekeeping,
        // not user-blocking work, and boot must never wait on it.
        modelHousekeepingQueue.async { [weak self] in
            self?.modelStore.removeStaleCoreMLBundles()
        }

        // Interpreter-availability fix (2026-09-06): restore the
        // assistant-brain model's one-time auto-download. `start()` is
        // idempotent (onboarding wizard and Home both call it) and
        // `ModelDownloadService.start` no-ops while a download is already
        // in flight or completed, so this is safe to run on every launch;
        // when the Gemini stack is live no download starts at all.
        // [STARTUP-PERF] Runs at the END of the boot (idle after first
        // paint) — same gate, later slot — and hops to main first:
        // `ModelDownloadService`'s task bookkeeping stays main-confined
        // exactly as it was when this ran inside `start()`.
        DispatchQueue.main.async { [weak self] in
            self?.ensureAssistantBrainDownloadIfNeeded()
            self?.startupBoot.advance(to: .ready)
            // [BOOT-LATENCY] Deferred warm slice: secondary voices (and
            // every TTS warm on the simulator) run NOW — detached,
            // post-spinner, gated by the same settings the boot slice
            // used. They never delay `.ready`.
            self?.startDetachedPostBootWarm()
            print("[AppCoordinator] startup boot complete — spinner dismissed")
        }
    }

    /// Runs the deferred warm slice after the boot completes: detached
    /// on the same serial warm queue, same settings gates — only the
    /// slot moved, so these steps can never delay `.ready`. A boot warm
    /// that outlived the budget is already running on the shared queue,
    /// so these steps queue behind it instead of overlapping it.
    private func startDetachedPostBootWarm() {
        let steps = postBootWarmSteps
        postBootWarmSteps = []
        guard !steps.isEmpty else {
            // [LAT-M2] Empty post-boot slice (warm disabled, or the boot
            // slice consumed the whole plan) — the ack-cache hook still
            // runs so a warm-eligible boot path that skipped the stage
            // does not also skip the pre-acks.
            maybeStartAckCacheWarm()
            return
        }
        warmRunner.run(plan: steps) { [weak self] _ in
            // Detached by design: the runner reports each engine's
            // outcome on the ObservabilityBus; nothing gates on them.
            DispatchQueue.main.async {
                self?.maybeStartAckCacheWarm()
            }
        }
    }

    /// [LAT-M2] Builds the pre-synthesized ack cache once per launch,
    /// after the warm plan's TTS step settled (the runner completion
    /// fires after every step — so the engine the build uses is the
    /// warmed one). Gated exactly like the TTS warm itself: the
    /// warm-start preference (a disabled warm means the user declined
    /// engine loads at boot — pre-synthesis would load it anyway) and
    /// the simulator (sherpa engine construction there is the slow
    /// sim-only cost the warm already skips, see
    /// `WarmStartPlanner.ttsSteps`). Main-confined; idempotent.
    private var ackCacheWarmStarted = false
    private func maybeStartAckCacheWarm() {
        guard !ackCacheWarmStarted, warmStartEnabled, !Self.isSimulator,
              let warmer = speaker as? AckCachePreSynthesizing else { return }
        ackCacheWarmStarted = true
        let locale = activeLocale
        warmer.buildAckCache(locale: locale) { _ in
            // Per-build outcomes are reported on the ObservabilityBus by
            // the speaker seam (`ack_cache`/`warm`); a miss until it
            // lands is the designed fallback (`ack_cache_miss`).
        }
    }

    /// Constructs + starts the voice pipeline (the old synchronous tail
    /// of `start()`). Runs on main in the boot's `.preparingVoice` phase
    /// so the engine swap above is visible before audio starts.
    private func buildAndStartVoicePipeline() {
        guard voicePipeline == nil, let router = commandRouter else { return }
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
            observabilityBus: observabilityBus,
            turnTracer: turnTracer,
            // [PIPELINE-TRACE] The pipeline is the one place the
            // recognizer's result exists, so the `.stt` row is recorded
            // there; nil on non-gated builds.
            traceRecorder: pipelineTraceRecorder
        )
        // [NOISE-FILTER] Attach the restored A/B stage (nil when OFF —
        // the hot-swap seam emits the honest engine name either way).
        voicePipeline?.setNoiseSuppressor(makeNoiseSuppressor())
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
        // [BOOT-REVIEW P0-2] The boot's start REQUEST: the published
        // manual-Talk readiness stays `.loading` until the callback below
        // answers — that callback, and only that callback, decides
        // `.ready` / `.failed`.
        noteVoicePipelineStartRequested()
        voicePipeline.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
                self.noteVoicePipelineStartSucceeded()
                // Return from the callback with Talk enabled. Preferred
                // engines and warms begin next main turn and hot-swap into
                // the already-live fallback pipeline.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyVoiceEngineStack()
                    self.startBootWarmPhase()
                }
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
                self.noteVoicePipelineStartFailed(err)
                self.startupBoot.recordFailure(.preparingVoice)
                // Global boot still completes even when voice activation
                // failed; background warm telemetry is not a Talk gate.
                DispatchQueue.main.async { [weak self] in
                    self?.startBootWarmPhase()
                }
            }
        }
    }

    /// [STARTUP-PERF] The boot's phase-1 payload: every persisted window
    /// the coordinator used to load synchronously (init + `start()`),
    /// now read on the boot queue in one pass. Each store call is the
    /// SAME call the old code made — empty-on-error semantics included —
    /// so failure degrades honestly instead of crashing. Internal (not
    /// private) so the seam is unit-testable off-main.
    struct StartupDataBatch {
        var contacts: [FamilyContact] = []
        var places: [SavedPlace] = []
        var appointments: [MedicalAppointment] = []
        var briefing: StoredBriefing?
        var feedSources: [FeedSource] = []
        var feedTopics: [String] = []
        var history: [Exchange] = []
        var activity: [AppActivityEntry] = []

        static func load(contactStore: FamilyContactStore,
                         placeStore: SavedPlaceStore,
                         appointmentStore: AppointmentStore,
                         briefingStore: MorningBriefingStore,
                         feedSettingsStore: FeedSettingsStore,
                         chatHistoryStore: ChatHistoryStore,
                         activityLog: AppActivityLog,
                         storage: MigratingEncryptedStorage? = nil,
                         now: Date) -> StartupDataBatch {
            // [BOOT-REVIEW P1-6] ONE transactional open/read of the file
            // store for the whole batch: the snapshot above pays a single
            // directory pass and one read per key, instead of each store
            // opening the store again for its own read.
            guard let storage else { return read(contactStore: contactStore,
                                                 placeStore: placeStore,
                                                 appointmentStore: appointmentStore,
                                                 briefingStore: briefingStore,
                                                 feedSettingsStore: feedSettingsStore,
                                                 chatHistoryStore: chatHistoryStore,
                                                 activityLog: activityLog,
                                                 now: now) }
            return storage.withReadSnapshot(keys: snapshotKeys) {
                read(contactStore: contactStore,
                     placeStore: placeStore,
                     appointmentStore: appointmentStore,
                     briefingStore: briefingStore,
                     feedSettingsStore: feedSettingsStore,
                     chatHistoryStore: chatHistoryStore,
                     activityLog: activityLog,
                     now: now)
            }
        }

        /// The store keys phase 1 reads through the file store. Literals
        /// because each store keeps its own key `private`; a drift here is
        /// a missed optimization, never a correctness problem — a key that
        /// is not snapshotted simply reads through normally.
        static let snapshotKeys = [
            "family.contacts",
            "places.saved",
            "medical.appointments",
            "morningBriefing.current",
            "feeds.config.v1",
            "chat.history",
            "app.activity.log",
        ]

        private static func read(contactStore: FamilyContactStore,
                                 placeStore: SavedPlaceStore,
                                 appointmentStore: AppointmentStore,
                                 briefingStore: MorningBriefingStore,
                                 feedSettingsStore: FeedSettingsStore,
                                 chatHistoryStore: ChatHistoryStore,
                                 activityLog: AppActivityLog,
                                 now: Date) -> StartupDataBatch {
            var batch = StartupDataBatch()
            batch.contacts = contactStore.load()
            batch.places = placeStore.load()
            batch.appointments = appointmentStore.load()
            batch.briefing = briefingStore.todaysBriefing(now: now)
            let feedConfig = feedSettingsStore.load()
            batch.feedSources = feedConfig.sources
            batch.feedTopics = feedConfig.topics
            chatHistoryStore.load()
            batch.history = chatHistoryStore.recent()
            batch.activity = activityLog.entries()
            return batch
        }
    }

    // MARK: - Voice session state (spec §3.3)

    /// Maps pipeline states onto the UI session machine. `speaking` is
    /// derived from the speaker lifecycle; `awaitingConfirmation` owns the
    /// UI until yes/no/timeout (pipeline events don't clobber it).
    private func handlePipelineState(_ state: VoicePipeline.State) {
        lastPipelineState = state
        voiceState = state
        // Idle drives deferred KWS eligibility only; manual Talk readiness
        // is published directly by the pipeline start callback.
        updateVoiceReadiness()
        guard voiceSession.state != .awaitingConfirmation else { return }
        switch state {
        case .stopped:
            voiceSession.transition(to: .stopped)
            cancelVoiceWatchdog()
        case .idle:
            // [LAUNCH-TRANSITION-FIX] `.error → .speaking` has no direct
            // edge (pipeline error at boot, then `.idle` while push
            // speech plays); the machine bridges through `.idle`, where
            // both edges are legal.
            voiceSession.transitionViaIdle(to: speakingCount > 0 ? .speaking : .idle)
            cancelVoiceWatchdog()
            cancelVoiceStartWatchdog()
            // [VAD-RT] A deferred KWS build that dodged a live capture
            // (see `buildDeferredWakeWordEngine`) re-schedules now the
            // pipeline has settled back to idle — the main-thread
            // simulator session construction can never overlap a
            // capture's `vad_end` main hop.
            if deferredKWSBuildPendingWhileBusy {
                deferredKWSBuildPendingWhileBusy = false
                deferredKWSBuildScheduled = false
                scheduleDeferredKWSBuildIfNeeded()
            }
            // Voice Processing I/O preset A/B (P0, slice C): a flip that
            // landed mid-turn applies now the pipeline has settled back
            // to idle — and only once no reply is playing (every speech
            // end re-runs this case via `noteSpeakingEnded`).
            if pendingVoiceProcessingPresetChange, speakingCount == 0 {
                pendingVoiceProcessingPresetChange = false
                applyVoiceProcessingPresetChange()
            }
        case .capturingCommand:
            // [T-037-a] The next use after a memory-pressure unload: clear
            // the encoder's hold so the first interpret() reloads. No-op
            // in builds without the internal-testing gate.
            rearmIntentEncoderIfEnabled()
            // A fresh capture supersedes any post-reset notice: the
            // status line must speak for the LIVE cycle, not the last
            // reset (TALK-CRASH-FIX, 2026-09-07).
            clearVoiceResetNotice()
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
            // [LAUNCH-TRANSITION-FIX] A capture event can land while the
            // session is still `.stopped`/`.error` (recycle + immediate
            // capture); `→ .listening` has no direct edge from either —
            // bridge through `.idle`, where both edges are legal.
            voiceSession.transitionViaIdle(to: .listening)
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
    /// break a wedged *capture*: if the session is still `.listening`
    /// `voiceWatchdogSeconds` (60 s since [VAD-TUNE]) after the tap, the
    /// mic pipeline never moved on — recycle and re-prompt. It
    /// deliberately does NOT fire on `.transcribing` or `.understanding`:
    /// transcription of a long utterance on the CPU-pinned distilled
    /// model takes well over 15 s on device, and recycling mid-flight
    /// there was exactly the "stuck/sorry-please-say-again" failure this
    /// cycle guard was mis-firing on. Recovery for a genuinely wedged
    /// transcription is owned by the STT layer (its own 30 s inference
    /// timeout + 2-strike throttle), and routing has its own deadlines;
    /// those layers settle the cycle without this UI guard.
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
    ///
    /// [VAD-TUNE] Raised 40 -> 60 on 2026-09-11: the capture cap went
    /// 8 -> 22 s (VoicePipeline.captureTimeoutSeconds), so the worst
    /// legitimate turn is now 22 s capture + 25 s Gemini HTTP = 47 s —
    /// above the old 40 s value, which would have recycled mid-turn.
    /// 60 s = 47 s + 13 s margin. The pipeline's internal wedge guard
    /// (22 + 25 = 47 s) still flips the session out of `.listening`
    /// before this watchdog can fire on a capture that is merely slow,
    /// not wedged.
    private static let voiceWatchdogSeconds: TimeInterval = 60

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

    /// Stops and restarts the voice pipeline — the ONE recovery core for
    /// a wedged or cancelled talk cycle. Every recycle path runs through
    /// here: the "stuck in listening" watchdog, the Talk-button tap
    /// escape hatch (`recoverVoiceCycle`) and the Talk-button long-press
    /// reset (`resetVoiceActivation`). One teardown sequence means one
    /// set of cancel-safe semantics to reason about (a `stop()` during an
    /// in-flight capture bumps the pipeline's capture generation, so the
    /// cancelled capture's stale completion tails are dropped instead of
    /// being run against the stopped session — TALK-CRASH-FIX,
    /// 2026-09-07).
    ///
    /// Speaks nothing itself; the caller supplies the follow-up on the
    /// restart completion (re-prompt on tap, status notice on long-press
    /// reset). Called from main (button/watchdog paths); the start
    /// completion arrives on main.
    private func recycleVoicePipeline(
        onRestart completion: @escaping (Result<Void, Error>) -> Void
    ) {
        cancelVoiceWatchdog()
        print("[AppCoordinator] recycling voice pipeline")
        voicePipeline?.stop()
        armVoiceStartWatchdog()
        // [BOOT-REVIEW P0-2] A RECYCLE is a retry: the readiness machine
        // reports it honestly (either outcome), so a failed boot start
        // upgrades to `.ready` the moment a real restart succeeds.
        noteVoicePipelineStartRequested()
        voicePipeline?.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
                self.noteVoicePipelineStartSucceeded()
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
                self.noteVoicePipelineStartFailed(err)
            }
            completion(result)
        }
    }

    /// Tap escape hatch + watchdog recovery: recycle the pipeline, and —
    /// once the restart has actually landed (`.idle`) — speak the
    /// re-prompt so the user knows the assistant is listening again.
    ///
    /// 2026-09-07 (TALK-CRASH-FIX): the re-prompt used to be spoken
    /// BEFORE the restart completed. `speak()` then ran while the session
    /// was still `.stopped`; when the restart delivered `.idle`,
    /// `handlePipelineState` mapped it through `speakingCount > 0` to
    /// `.speaking` — a `.stopped → .speaking` transition the state
    /// machine then rejected (DEBUG assertionFailure crash; the second
    /// half of the Talk-button crash). Deferring the speech to the
    /// restart completion still orders the re-prompt AFTER the recycle
    /// has landed (`.stopped → .idle → .speaking`). The table has
    /// admitted `.stopped → .speaking` since STOPPED-SPEAKING-FIX
    /// (2026-09-08) — push speech such as the launch morning briefing
    /// may start before the pipeline is primed — but deferral stays: the
    /// user hears "I'm listening again" only once the assistant is.
    func recoverVoiceCycle() {
        cancelVoiceWatchdog()
        print("[AppCoordinator] recovering voice cycle — recycling pipeline")
        recycleVoicePipeline { [weak self] result in
            guard let self, case .success = result else { return }
            self.speak(key: "router.reprompt")
        }
    }

    /// Long-press reset of the Talk button (TALK-CRASH-FIX, 2026-09-07):
    /// the "give up and go home" path. Holding the hero ~2 s cancels the
    /// current talk cycle (or re-primes a dead/errored pipeline) through
    /// the SAME `recycleVoicePipeline` core as a tap — but a reset must
    /// not talk AT the user (it usually follows a wedged cycle they are
    /// trying to silence), so instead of a spoken re-prompt it shows the
    /// transient `voiceResetNotice` on the button's status line. The hero
    /// itself passes through the recycle's brief `.stopped` ("Voice off")
    /// flip before the restarted pipeline lands `.idle` — the honest
    /// "reset happened" visual.
    ///
    /// Offered from `.idle`, `.listening`, `.transcribing`,
    /// `.understanding`, `.error` and `.stopped` — see
    /// `VoiceSessionState.supportsTalkReset`. The Home view gates the
    /// gesture on that property too; the guard here is the
    /// coordinator-side backstop (`.speaking` / `.awaitingConfirmation`
    /// keep their plain tap semantics).
    func resetVoiceActivation() {
        guard voiceSession.state.supportsTalkReset else { return }
        print("[AppCoordinator] talk long-press reset — recycling pipeline to idle")
        recycleVoicePipeline { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.showVoiceResetNotice()
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
            }
        }
    }

    private func showVoiceResetNotice() {
        voiceResetNoticeToken += 1
        let token = voiceResetNoticeToken
        voiceResetNotice = L10n.str("voice.resetDone", locale: activeLocale)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.voiceResetNoticeSeconds) { [weak self] in
            guard let self, self.voiceResetNoticeToken == token else { return }
            self.voiceResetNotice = nil
        }
    }

    private func clearVoiceResetNotice() {
        voiceResetNoticeToken += 1
        voiceResetNotice = nil
    }

    // MARK: - Pipeline start watchdog

    /// If a pipeline start produces no outcome after onboarding, fail the
    /// readiness contract explicitly instead of leaving Talk spinning. The
    /// late callback may still upgrade the failure to ready.
    private func armVoiceStartWatchdog() {
        cancelVoiceStartWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.voiceSession.state == .stopped else { return }
            print("[AppCoordinator] voice start watchdog fired — no pipeline outcome")
            self.voiceError = "audio session: no response"
            self.voiceSession.transition(to: .error)
            self.noteVoicePipelineStartFailed(VoiceStartWatchdogError.noResponse)
            self.startupBoot.recordFailure(.preparingVoice)
            self.startBootWarmPhase()
        }
        voiceStartWatchdog = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.voiceStartWatchdogSeconds,
            execute: work)
    }

    private func cancelVoiceStartWatchdog() {
        voiceStartWatchdog?.cancel()
        voiceStartWatchdog = nil
    }

    // MARK: - One-shot search-phrase capture (Phone leaf mic button)

    /// The leaf-owned capture runs while the always-on voice pipeline is
    /// SUSPENDED — the pipeline's tap is the shared engine's single tap
    /// slot (see `SearchPhraseCapture`'s design note, 2026-09-07). True
    /// when we stopped a LIVE pipeline that must be restarted once the
    /// capture completes; false when the pipeline was already stopped.
    private var voiceWasSuspendedForSearchCapture = false
    private var searchPhraseCaptureActive = false

    /// A Voice Processing I/O preset flip (P0, slice C) that landed while
    /// the pipeline was busy (mid-capture, mid-reply, mid-recycle) and
    /// must apply once it next settles to `.idle` — see
    /// `applyVoiceProcessingPresetChange` and the `.idle` case of
    /// `handlePipelineState`.
    private var pendingVoiceProcessingPresetChange = false

    private lazy var searchPhraseCapture = SearchPhraseCapture(
        audioSession: audioSessionManager,
        audioEngine: audioEngine,
        recognizer: fallbackSpeechRecognizer
    )

    /// Begins a one-shot mic capture for the Phone leaf's search field
    /// (`VoiceCommandCoordinating` peers — the leaf drives this directly,
    /// not through the router). Refuses (`.busy`) while a talk cycle is
    /// mid-flight or the assistant is mid-reply: deactivating the audio
    /// session then would tear down the wake-word capture in progress or
    /// cut the TTS mid-utterance and strand the speaking state. The
    /// pipeline is stopped for the capture's duration and restarted
    /// afterwards — the resume path mirrors `recoverVoiceCycle` minus
    /// the spoken re-prompt and the start watchdog (mic permission was
    /// just exercised by the capture, so the async start gap is a
    /// dispatch, not a 10-second question mark).
    func startSearchPhraseCapture(completion: @escaping (Result<String, SearchPhraseCapture.Failure>) -> Void) {
        guard !searchPhraseCaptureActive else {
            completion(.failure(.busy))
            return
        }
        guard let voicePipeline else {
            completion(.failure(.audioUnavailable))
            return
        }
        switch voicePipeline.state {
        case .idle:
            guard speakingCount == 0 else {
                completion(.failure(.busy))
                return
            }
            voiceWasSuspendedForSearchCapture = true
            voicePipeline.stop()
        case .capturingCommand, .processing, .routing:
            completion(.failure(.busy))
            return
        case .stopped, .error:
            // Nothing to suspend, but stop anyway: a half-failed start
            // (.error paths can leave the engine running with a tap
            // installed) must never collide with the capture's own tap.
            voiceWasSuspendedForSearchCapture = false
            voicePipeline.stop()
        }
        searchPhraseCaptureActive = true
        searchPhraseCapture.start { [weak self] result in
            guard let self else { return }
            self.searchPhraseCaptureActive = false
            self.resumeVoiceAfterSearchCaptureIfNeeded()
            completion(result)
        }
    }

    /// Ends an in-flight capture early (user tapped stop, or the leaf
    /// disappeared). The capture's own completion — which restarts a
    /// suspended pipeline — still fires.
    func cancelSearchPhraseCapture() {
        searchPhraseCapture.cancel()
    }

    private func resumeVoiceAfterSearchCaptureIfNeeded() {
        guard voiceWasSuspendedForSearchCapture else { return }
        voiceWasSuspendedForSearchCapture = false
        // [BOOT-REVIEW P0-2] Same honest reporting as the recycle above.
        noteVoicePipelineStartRequested()
        voicePipeline?.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
                self.noteVoicePipelineStartSucceeded()
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
                self.noteVoicePipelineStartFailed(err)
            }
        }
    }

    // MARK: - Enrollment sample capture ([VOICE-SETTINGS])

    /// The press-to-record capture behind Voice personalization →
    /// "Enroll voice": the SAME shared audio engine and session manager
    /// as the pipeline and the search-phrase capture — one tap slot
    /// doctrine, so `suspendForSampleCapture` (the `VoicePipelineSuspending`
    /// conformance at the bottom of this file) must have run first;
    /// `VoiceEnrollmentSession` enforces that order.
    private lazy var enrollmentRecorder = VoiceEnrollmentRecorder(
        audioEngine: audioEngine,
        audioSession: audioSessionManager
    )

    /// The recorder the Voice personalization screen's enrollment
    /// session captures through (see `VoiceEnrollmentSession`).
    func makeEnrollmentSampleRecorder() -> VoiceEnrollmentRecorder {
        enrollmentRecorder
    }

    /// True when we stopped a LIVE pipeline for an enrollment sample
    /// that must be restarted once the sample is banked (parallel to
    /// `voiceWasSuspendedForSearchCapture`).
    private var voiceWasSuspendedForEnrollmentSample = false

    /// Called by `CommandRouter` when a speak begins/ends — drives the
    /// derived `speaking` state. Callers may be on any queue; mutations
    /// are pinned to main (H1).
    ///
    /// 2026-09-06 (wake word #4): both functions also close/open the
    /// `WakeWordActivityGate`, which the voice pipeline consults before
    /// feeding mic audio to the wake-word engine. Self-hearing
    /// mitigation: the audio session is `.measurement` mode without AEC
    /// (AudioSessionManager), so while the assistant's own reply plays
    /// the mic hears it — including the phrase "ये कान्छी" if the reply
    /// contained it. We suppress HERE (per-reply, reversible) rather than
    /// switching the global audio-session mode, which is a regression
    /// risk for the always-on tap and the recognizers that share it. The
    /// gate is opened on the LAST speaker finishing (speech can nest —
    /// multiple speak()s overlap during a busy turn). One benign race:
    /// `speak()` launches the TTS Task before the main-async block below
    /// runs, so the first milliseconds of a reply may not be suppressed —
    /// the keyword spotter needs ~a second of audio to fire, so no
    /// practical window.
    func noteSpeakingStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speakingCount += 1
            self.wakeWordActivityGate.setSpeaking(true)
            // Promote straight to .speaking when TTS starts during the
            // busy pre-speech states (call-ui fix, 2026-09-07): the old
            // path re-ran handlePipelineState(lastPipelineState), whose
            // .capturingCommand/.processing/.routing cases map back to
            // .listening/.transcribing/.understanding regardless of
            // speakingCount — so the hero kept showing the "listening"
            // visuals after the reply's speech had actually begun, until
            // the pipeline eventually emitted .idle. All three pre-speech
            // states legally transition to .speaking (VoiceSessionState
            // transition table).
            //
            // Else-branch push speech (STOPPED-SPEAKING-FIX, 2026-09-08):
            // when the utterance starts from a NON pre-speech state — the
            // session still `.stopped`, because push speech (launch
            // briefing, read-aloud) beat the pipeline's start — the
            // handlePipelineState re-run below promotes through
            // `speakingCount > 0` to `.speaking`. `.stopped → .speaking`
            // is legal by table (mirrors `.idle`), so no DEBUG trap; the
            // round trip closes on noteSpeakingEnded once the pipeline
            // reports.
            let preSpeech: Set<VoiceSessionState> = [.listening, .transcribing, .understanding]
            if preSpeech.contains(self.voiceSession.state) {
                self.voiceSession.transition(to: .speaking)
            } else {
                self.handlePipelineState(self.lastPipelineState)
            }
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

    // MARK: - Turn timing ([TURN-TIMING], 2026-09-09)

    /// Whether the transcript shows the per-stage timing caption. Read
    /// live from UserDefaults (the Voice personalization toggle's key) so
    /// the sheet always sees the current setting.
    var voiceTimingDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: VoiceSettingsModel.timingDebugKey)
    }

    /// Main-queue entry point of the tracer's finalize callback: derives
    /// the compact caption and pins it to the newest assistant exchange.
    private func applyTurnTimingCaption(_ stages: [VoiceTurnLatencyTracer.StageTiming]) {
        let caption = VoiceTurnLatencyTracer.caption(stages: stages)
        guard !caption.isEmpty else {
            lastTurnTimingCaption = nil
            lastTurnTimingExchangeID = nil
            return
        }
        lastTurnTimingCaption = caption
        // The turn's reply is the newest assistant exchange by the time
        // the turn finalizes (speech finished — every reply line was
        // already appended by `noteAssistantSpoke`).
        lastTurnTimingExchangeID = conversationHistory
            .last(where: { $0.role == .assistant })?.id
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
        if let queue = speakQueue {
            // Voice-OS shell v1: coordinator-level replies enter the
            // speak queue on the `.interactive` lane — lowest priority,
            // never preempted once started, announcement carries NO card
            // (speech only), so the existing outcome-card flow is
            // untouched. Zero policy change for the utterance itself: the
            // queue owns the shared speaker and the speech notes fire
            // around each utterance via `SpeechNoteForwarder`.
            guard !text.isEmpty else { return }
            noteAssistantSpoke(text)
            queue.enqueue(Announcement(
                id: UUID(),
                text: text,
                priority: .interactive,
                sourceID: "coordinator_reply",
                card: nil
            ))
            return
        }
        // Pre-`start()` fallback — verbatim original direct-speak path
        // (the queue only exists once `start()` has composed it).
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
        // The cloud brain is now live — the local brain model's one-time
        // download (if any) is redundant on this stack (2026-09-06).
        cancelAssistantBrainDownloadIfRedundant()
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
            // Strictly on-device STT + local brain — with an OPT-IN
            // cloud escalation (cloud-fallback task, 2026-09-07): the
            // "Ask Gemini when I can't answer" Settings toggle
            // intentionally reverses the old rule that the on-device
            // stack keeps a configured Gemini key out of the chain — by
            // explicit user opt-in only (constitution-consistent:
            // opt-in, disclosed in the Settings leaf). Escalation is
            // provider-shaped for the future dropdown: which cloud brain
            // may receive an abstained question is `cloudProvider`'s
            // job — new providers plug in as new cases here, each gated
            // on its own interpreter's availability. The STT recognizer
            // is NEVER swapped in this branch — a Gemini recognizer
            // stays a `.gemini`-stack privilege (`trySwapToGemini()`
            // guards on the stack).
            switch cloudProvider {
            case .gemini:
                // Gemini is the only provider today. Availability =
                // `geminiCommandInterpreter.isAvailable` — the same
                // gate `IntentRouter` applies to its cloud layer.
                let fallbackEngages = CloudProvider.cloudFallbackEngages(
                    enabled: cloudFallbackEnabled,
                    geminiAvailable: geminiCommandInterpreter?.isAvailable ?? false
                )
                intentRouter?.cloudEnabled = fallbackEngages
                // Observability: report the on-device chain's cloud
                // state each time it applies, so a dashboard can tell an
                // opted-in escalation from a strictly-local run (C9 —
                // no utterance content, provider id only).
                observabilityBus.emit(ObservabilityEvent(
                    component: "cloud_fallback",
                    eventType: "state",
                    durationMs: nil,
                    outcome: fallbackEngages ? "enabled" : "disabled",
                    errorCode: nil,
                    metadata: ["provider": cloudProvider.rawValue]
                ))
            }
            // Whisper engine selection is the pure table in
            // `OnDeviceSTTSelection` ([STARTUP-R2]): devices favor ANE
            // WhisperKit (the medium-class models are unusable on CPU —
            // 128 s for a 2.1 s clip, 2026-09-05 — but conversational on
            // ANE); the simulator forces the cheaper whisper.cpp path
            // when its bundled model is available (reason "simulator":
            // the CPU-only WhisperKit prepare is a minutes-scale load
            // that never helps a sim conversation). whisper.cpp when its
            // model is cached; else the SFSpeechRecognizer fallback
            // rather than silently doing nothing (spec §7: no dead-end
            // states).
            switch Self.onDeviceSTTChoice(
                whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
                whisperCppAvailable: whisperSpeechRecognizer.isAvailable
            ) {
            case .whisperKit:
                voicePipeline?.setSpeechRecognizer(whisperKitSpeechRecognizer)
                // Absorb model load + CoreML specialization now so the
                // first utterance doesn't pay it. DEVICE ONLY — the sim
                // prepare is skipped (see OnDeviceSTTSelection).
                if OnDeviceSTTSelection.shouldPrepareWhisperKit(isSimulator: Self.isSimulator) {
                    whisperKitSpeechRecognizer.prepare()
                }
            case .whisperCpp(let reason):
                voicePipeline?.setSpeechRecognizer(whisperSpeechRecognizer)
                Self.emitSTTSelectionReason(reason, bus: observabilityBus)
            case .fallback(let reason):
                voicePipeline?.setSpeechRecognizer(fallbackSpeechRecognizer)
                Self.emitSTTSelectionReason(reason, bus: observabilityBus)
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateActiveSTTName()
            }
            // [BOOT-REVIEW P1-5] The on-device stack is live and
            // whisper.cpp may be missing its one bundled model — install
            // it NOW, at first use, instead of copying hundreds of MB
            // during boot. Post-first-frame by construction: the stack is
            // applied from the boot's voice-start callback (or a Settings
            // toggle), never from `init`.
            installBundledSTTModelIfNeeded()
            // [STT-RESTORE] …and the ANE artifact a fresh container wiped
            // is restored the same way: a background download of the
            // language default, so the on-device stack climbs back to the
            // ANE path without a Settings trip (2026-09-16 device bug).
            restoreWhisperKitArtifactIfNeeded()
        }
        // [CLOUD-CASCADE] Last: (re-)arm the cascade tier on the fresh
        // stack. It reads the provider seam + the two persisted settings,
        // so it belongs to the same "apply the stack" pass as
        // `cloudEnabled` above — one place decides what the ladder may
        // reach, and this call can never arm a tier the stack just
        // declined (it is gated on the same `cloudEnabled`).
        applyCloudCascadeConfiguration()
    }

    /// [CLOUD-CASCADE] (2026-09-16) Arms the cloud cascade tier on
    /// `intentRouter` from the SAME inputs the rest of the app consults:
    /// the Gemini interpreter the boot built, `GeminiConfigStore.isConfigured`
    /// (the key) and `GeminiCostGovernor.allowsCall()` (the day's budget) —
    /// so a Settings promise can never outrun what the tier would do, and
    /// an unconfigured household gets a nil tier (no cue, no event, no log,
    /// no activity row: silent, exactly as the ladder behaved before the
    /// tier existed).
    ///
    /// Called from `applyVoiceEngineStack()` (once at startup, and again on
    /// every stack / opt-in / threshold / switch change). No-ops before
    /// `start()` has built the pipeline and the interpreter — the same
    /// tolerance `applyVoiceEngineStack()` itself holds.
    ///
    /// The tier is inert unless the cloud is REACHABLE at all
    /// (`cloudEnabled`, which `applyVoiceEngineStack()` has just decided
    /// from the stack + the opt-in), so this can never be the one path that
    /// puts a cloud on the wire behind the household's back (OD-12's
    /// consent posture is decided there, not here).
    private func applyCloudCascadeConfiguration() {
        guard let router = intentRouter, let gemini = geminiCommandInterpreter else {
            return
        }
        let providers = CloudBrainProviders(gemini: CloudBrainRegistration(
            interpreter: gemini,
            isConfigured: { [weak self] in self?.geminiConfigStore.isConfigured ?? false },
            costAllows: { [weak self] in self?.geminiCostGovernor.allowsCall() ?? false }
        ))
        // Resolved through the seam — the coordinator never names a cloud
        // interpreter for a provider id; the registry does (adding a
        // provider is a case + a registration, not a branch here).
        guard let endpoint = providers.endpoint(for: cloudProvider) else {
            router.cloudCascade = nil
            return
        }
        router.cloudCascade = CloudCascadeConfiguration(
            endpoint: endpoint,
            threshold: cloudCascadeThreshold,
            isEnabled: cloudCascadeEnabled,
            holdCue: { [weak self] in
                self?.commandRouter?.speakCloudCascadeHoldCue()
            },
            onEscalated: { [weak self] escalation in
                self?.recordCloudCascadeEscalation(escalation)
            }
        )
    }

    /// [BOOT-REVIEW P1-5] Installs the ONE app-bundled STT model (the
    /// Nepali medium ggml — the only catalog entry with a
    /// `bundledResourceName`) the first time the household's OWN pick
    /// needs it, so a normal launch copies NOTHING. The old boot loop
    /// copied the 586 MB ggml into Application Support on every launch,
    /// gating `.ready` behind a multi-second disk write.
    ///
    /// Gates, in order:
    ///  - the on-device stack is ACTIVE (a Gemini household never pays
    ///    for a model it will not use),
    ///  - [CPU-SAFETY 2026-09-16] the bundled medium is the household's
    ///    EXPLICIT pick (`sttModelPreference`). It is no longer part of
    ///    the automatic whisper.cpp order — running it on a CPU-only
    ///    fresh install is the ~1 GB cold load that SIGKILLed the app
    ///    (2026-09-16) — so copying it for any other reason buys nothing
    ///    and costs 586 MB. The bundled copy stays the offline-friendly
    ///    install path for the one household that asks for it.
    ///  - whisper.cpp is what the pure selection table would pick once a
    ///    model IS present (an ANE device with WhisperKit installed runs
    ///    WhisperKit — no copy),
    ///  - the model is genuinely absent (idempotent), no install already
    ///    in flight.
    ///
    /// The copy runs at UTILITY QoS on `modelHousekeepingQueue` — never
    /// on the boot queue, which gates `.ready`, and never on main — and
    /// reports determinate byte progress through `ModelDownloadService`,
    /// so the model-specific UI shows the same bar a download shows.
    /// When it lands, the stack is re-applied so whisper.cpp takes over
    /// from the SFSpeechRecognizer fallback the missing model forced.
    private func installBundledSTTModelIfNeeded() {
        guard voiceEngineStack == .onDevice else { return }
        let bundled = ModelCatalog.whisperMediumFinetunedNepali
        guard sttModelPreference == bundled,
              !modelStore.isCached(bundled),
              !bundledSTTInstallInFlight,
              bundledSTTModelIsTheNextChoice() else { return }
        bundledSTTInstallInFlight = true
        // Force both lazy services HERE, on main: the copy's progress
        // callbacks fire on the housekeeping queue and must not touch an
        // uninitialised `lazy var`.
        let downloads = modelDownloadService
        let store = modelStore
        downloads.reportBundledInstallProgress(
            bundled,
            received: 0,
            totalBytes: ModelCatalog.entry(for: bundled)?.sizeBytes ?? 0)
        modelHousekeepingQueue.async { [weak self] in
            let installed = store.installBundledModel(for: bundled) {
                received, total in
                downloads.reportBundledInstallProgress(
                    bundled, received: received, totalBytes: total)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.bundledSTTInstallInFlight = false
                downloads.reportBundledInstallOutcome(
                    bundled, installed: installed != nil)
                guard installed != nil else {
                    print("[AppCoordinator] bundled STT install failed")
                    return
                }
                print("[AppCoordinator] bundled STT model installed — re-applying stack")
                // The recognizer is only now `isAvailable`, so the table
                // can finally choose whisper.cpp over SFSpeechRecognizer.
                self.applyVoiceEngineStack()
            }
        }
    }

    /// True when granting whisper.cpp a usable model would make the pure
    /// selection table pick it — i.e. the bundled copy is the engine this
    /// device would actually run. Reuses the SAME table the live swap
    /// consults (`applyVoiceEngineStack`), so the install gate and the
    /// engine choice can never disagree.
    private func bundledSTTModelIsTheNextChoice() -> Bool {
        if case .whisperCpp = Self.onDeviceSTTChoice(
            whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
            whisperCppAvailable: true) {
            return true
        }
        return false
    }

    // MARK: - Missing ANE artifact (PR 3, 2026-09-16)

    /// [STT-RESTORE] A fresh install (or an app update, which gives the
    /// app a new container) has no WhisperKit ANE artifact, and the
    /// artifact is a DOWNLOAD: without this, the on-device stack would
    /// sink to whisper.cpp — the 2026-09-16 device report, where the
    /// bundled medium's ~1 GB CPU cold load SIGKILLed the app — and stay
    /// there until someone walked into Settings. Kicks the standard
    /// `ModelDownloadService` download at first voice readiness instead.
    ///
    /// The decision itself is the pure table
    /// (`OnDeviceSTTSelection.restoreAction`): simulator, an installed
    /// artifact, an explicit whisper.cpp pick, an in-flight download and
    /// a language with no ANE build (`en`) all answer `.none`. Called
    /// from `applyVoiceEngineStack()` — once at the boot's voice start,
    /// and again on every stack / language change — so it is deliberately
    /// cheap and idempotent: the in-flight set comes straight from the
    /// service's published states, and a completed install short-circuits
    /// on `isAvailable` before the table is even consulted.
    private func restoreWhisperKitArtifactIfNeeded() {
        switch OnDeviceSTTSelection.restoreAction(
            whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
            preferredModel: sttModelPreference,
            isSimulator: Self.isSimulator,
            inFlight: downloadsInFlight,
            language: appLanguage.rawValue,
            iOS18OrLater: Self.isIOS18OrLater
        ) {
        case .none:
            break
        case .download(let id):
            // [STT-RESTORE] Point the ANE engine at what it is about to
            // receive BEFORE the bytes move, or the landed artifact would
            // change nothing: `WhisperKitSpeechRecognizer.isAvailable` and
            // `loadDescriptor()` resolve `directoryURL(for:
            // preferredModelID)`, and with no stored pick that pref is the
            // engine's init default — the v3 medium, NOT PR 1's per-language
            // default. A restored v6 would land on disk and stay invisible,
            // leaving the household on the fallback forever. With an
            // explicit ANE pick the recognizer already holds this id (the
            // adoption rule), so this call is a no-op; a ggml pick never
            // reaches this branch (the table answers `.none` for it), so no
            // engine is ever repointed away from a model it can run. Only
            // the engine's target moves — `sttModelPreference` stays nil
            // ("Automatic"), so the picker keeps saying Automatic rather
            // than claiming a pick the household never made.
            whisperKitSpeechRecognizer.setPreferredModel(id)
            observabilityBus.emit(ObservabilityEvent(
                component: "model_download",
                eventType: "stt_ane_restore_started",
                durationMs: nil,
                outcome: "info",
                errorCode: nil,
                metadata: ["state": id.rawValue]
            ))
            print("[AppCoordinator] ANE STT artifact missing — restoring \(id.rawValue)")
            modelDownloadService.start(id)
        }
    }

    /// The downloads `ModelDownloadService` currently owns, as the
    /// restore table's "do not re-kick" set: `queued` → `completed` is an
    /// attempt that is live or done, while `notStarted` / `failed` /
    /// `cancelled` is an attempt that is OVER — a transient failure is
    /// retried on the next stack apply instead of being abandoned for the
    /// life of the install.
    private var downloadsInFlight: Set<ModelID> {
        Self.inFlightModels(from: modelDownloadService.states)
    }

    /// Pure form of the set above — a static seam so the retry semantics
    /// are pinned by a test rather than by the comment alone.
    static func inFlightModels(from states: [ModelID: ModelDownloadState]) -> Set<ModelID> {
        Set(states.compactMap { entry -> ModelID? in
            switch entry.value {
            case .queued, .downloading, .verifying, .completed: return entry.key
            case .notStarted, .failed, .cancelled: return nil
            }
        })
    }

    /// [STT-RESTORE] Re-applies the stack when an ANE artifact lands, so
    /// the restore actually reaches the live pipeline: nothing else
    /// re-applies on a download completion (the Settings screen's own
    /// `$states` observer only recomputes the caption), so a restored
    /// artifact used to need a relaunch to take effect. The selection
    /// table decides whether the completion changes the engine, so a
    /// download for an unrelated WhisperKit model costs one idempotent
    /// pass.
    private func observeSTTArtifactCompletion() {
        sttArtifactCompletionCancellable = modelDownloadService.$states
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                guard let self, self.started else { return }
                let landed = states.contains {
                    $0.value == .completed
                        && WhisperKitSpeechRecognizer.isWhisperKitArtifact($0.key)
                }
                guard landed else { return }
                self.applyVoiceEngineStack()
            }
    }

    /// Whether this OS can load the CoreML spec-v9 (palettized) ANE
    /// builds — the same gate `ModelDownloadService` applies before
    /// spending ~767 MB on one, so the auto-restore never picks an
    /// artifact the service would refuse on this device.
    private static let isIOS18OrLater: Bool = ProcessInfo.processInfo
        .isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0))

    /// The stored STT pick this build runs, migrating superseded ids
    /// forward.
    ///
    /// [CPU-SAFETY 2026-09-16] The small fine-tunes migrate to their q8_0
    /// SIBLING (same checkpoint, better quality), never to the medium
    /// fine-tune they used to map to: the medium is no longer
    /// auto-runnable on CPU (see
    /// `OnDeviceSTTSelection.whisperCppAutomaticOrder`), and a migration
    /// that writes it into `sttModelPreference` would both install the
    /// 586 MB bundled copy and hand the household a model it never chose.
    /// A migration stays inside the class the household picked.
    static func migratedSTTPreference(_ stored: ModelID?) -> ModelID? {
        if stored == ModelCatalog.whisperSmallNepali
            || stored == ModelCatalog.whisperFinetunedNepali {
            return ModelCatalog.whisperFinetunedNepaliQ8
        }
        return stored
    }

    /// Re-applies the audio-session preset after `voiceProcessingEnabled`
    /// changed (voice-personalisation P0, slice C). A preset change needs
    /// the engine stopped — the manager's VPIO node call refuses a
    /// running engine — and the ONLY restart path that owns the
    /// session + engine lifecycle together is the pipeline recycle, so a
    /// flip recycles the always-on pipeline through its canonical
    /// stop/start core (`recycleVoicePipeline`, same one the cycle
    /// watchdog and Talk-button reset use). The recycle's start
    /// re-activates the session, and `AudioSessionManager.activate`
    /// applies the preset the flag now requests; failures surface
    /// through the recycle's own state mapping. Timing:
    ///  - pipeline settled idle, nobody speaking → recycle immediately;
    ///  - mid-turn (capture/reply/recycle) → defer via
    ///    `pendingVoiceProcessingPresetChange`, applied when the pipeline
    ///    next reports `.idle` (the manager flag is already set, so any
    ///    activation in between — e.g. a search-phrase capture's resume —
    ///    already uses the new preset);
    ///  - a search-phrase capture holds the engine → leave it alone; its
    ///    own resume activation picks up the new preset.
    private func applyVoiceProcessingPresetChange() {
        guard started else { return }
        guard !searchPhraseCaptureActive else { return }
        guard let voicePipeline, voicePipeline.state != .stopped else { return }
        if voicePipeline.state == .idle && speakingCount == 0 {
            pendingVoiceProcessingPresetChange = false
            recycleVoicePipeline { _ in }
        } else {
            pendingVoiceProcessingPresetChange = true
        }
    }

    /// [NOISE-FILTER] Builds the denoising stage the A/B toggle selects:
    /// nil (legacy capture path) when OFF, the spectral-gate denoiser
    /// when ON. A DeepFilterNet3-class suppressor (P1 step 2 — model
    /// artifacts + ModelStore delivery) would slot in here once it lands.
    private func makeNoiseSuppressor() -> NoiseSuppressor? {
        guard noiseFilterEnabled else { return nil }
        return SpectralGateDenoiser(observabilityBus: observabilityBus)
    }

    /// [NOISE-FILTER] Applies the A/B toggle immediately: the stage is a
    /// pipeline-level injection with its own hot-swap seam, so unlike the
    /// VPIO preset this needs NO pipeline recycle — a mid-session flip
    /// takes effect on the very next capture (the stage's streaming
    /// state starts cold, warmup passthrough included).
    private func applyNoiseFilterChange() {
        voicePipeline?.setNoiseSuppressor(makeNoiseSuppressor())
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

    /// [LAT-M3] (2026-09-11) Honest Settings caption state: whether
    /// open-domain interpretation actually runs through the CLOUD
    /// interpreter right now — the exact inputs the per-turn
    /// `InterpreterSelector` in `IntentRouter` consults (the stack's
    /// cloud consent, the Gemini key, the day's cost budget), so the
    /// caption can never disagree with what the chain will do on the
    /// next utterance.
    var isCloudInterpreterActive: Bool {
        guard intentRouter?.cloudFirstEnabled == true,
              intentRouter?.cloudEnabled == true else { return false }
        let selection = InterpreterSelector.select(
            keyConfigured: geminiConfigStore.isConfigured,
            costAllows: geminiCostGovernor.allowsCall())
        return selection == .cloud
    }

    /// Interpreter-chain status for `CommandRouter`'s no-brain fallback
    /// speech (spec §7 "no dead ends"; interpreter-availability fix
    /// 2026-09-06). Derivation mirrors the EXACT layer ladder the router
    /// consults so the spoken message and the routing outcome can never
    /// disagree: the local chain (preferred intent GGUF / LLaMA stand-in)
    /// counts when `isAvailable`; the cloud brain counts only when
    /// `cloudEnabled` (the on-device stack keeps a configured Gemini key
    /// out of the chain unless the household opted into cloud fallback —
    /// same guard as `IntentRouter`'s escalation). The model-download
    /// state supplies the distinction between the two honest no-brain
    /// messages (downloading vs setup needed).
    var brainReadiness: BrainReadiness {
        BrainReadiness.resolve(
            localBrainAvailable: intentRouter?.localBrain?.isAvailable ?? false,
            cloudEnabled: intentRouter?.cloudEnabled ?? false,
            cloudBrainAvailable: intentRouter?.cloudBrain?.isAvailable ?? false,
            brainDownloadInFlight: isAssistantBrainDownloadInFlight
        )
    }

    /// [INTENT-TOOLS] (2026-09-07) Live-web answering capability for
    /// `CommandRouter`'s tool wiring. True ONLY when the cloud brain is
    /// actually in the chain — the derivation mirrors the exact escalation
    /// guard `IntentRouter` applies at route time (`cloudEnabled` AND the
    /// cloud brain available), so the router's weather yield can never
    /// disagree with what the chain would do next: on the on-device stack
    /// a configured Gemini key stays out of the chain (`cloudEnabled` is
    /// false, absent the cloud-fallback opt-in) and this is false → the
    /// deterministic weather pre-answer stands; on the Gemini stack with
    /// the key configured this is true → weather questions fall through
    /// to the search-grounded interpreter.
    var canAnswerLiveQuestionsFromWeb: Bool {
        (intentRouter?.cloudEnabled ?? false)
            && (intentRouter?.cloudBrain?.isAvailable ?? false)
    }

    /// [LOCAL-TOOLS] (2026-09-07) Local-tools stack gate for
    /// `CommandRouter`. True only when the voice engine is the ON-DEVICE
    /// stack — the live weather/search tools fire exclusively there,
    /// because the Gemini stack answers open-domain questions natively
    /// (search-grounded interpreter) and the tools would be redundant.
    /// Mirrors the `voiceEngineStack` toggle directly, so flipping the
    /// stack in Settings gates the tools with no other wiring.
    var isOnDeviceStack: Bool { voiceEngineStack == .onDevice }

    /// Whether the assistant-brain model is currently arriving (queued /
    /// downloading / verifying) — the one state that turns `.needsSetup`
    /// into `.downloadingBrain` for the router's fallback speech.
    private var isAssistantBrainDownloadInFlight: Bool {
        switch modelDownloadService.states[resolvedBrainModelID] ?? .notStarted {
        case .queued, .downloading, .verifying: return true
        case .notStarted, .completed, .failed, .cancelled: return false
        }
    }

    /// Kicks the assistant-brain model's one-time download when the
    /// interpreter chain needs it and the model isn't cached (policy in
    /// `shouldAutoDownloadAssistantBrain`). `start()` is idempotent and
    /// `ModelDownloadService.start` no-ops while a download is in flight
    /// or completed, so this re-runs safely on every launch — and a
    /// `.failed` attempt is retried by the next launch. Silent when the
    /// LLM runtime isn't linked (nothing could run the model) or a cloud
    /// brain is live (nothing needs it).
    private func ensureAssistantBrainDownloadIfNeeded() {
        guard Self.isLLMRuntimeLinked else { return }
        guard Self.shouldAutoDownloadAssistantBrain(
            modelCached: modelStore.isCached(resolvedBrainModelID),
            cloudEnabled: intentRouter?.cloudEnabled ?? false,
            cloudBrainAvailable: geminiCommandInterpreter?.isAvailable ?? false
        ) else { return }
        modelDownloadService.start(resolvedBrainModelID)
    }

    /// A newly-configured Gemini key makes the local brain model redundant
    /// on the Gemini stack — stop an in-flight one-time download instead
    /// of letting ~807 MB finish arriving over the elder's data plan (the
    /// model row re-downloads on demand if the stack ever switches to
    /// on-device). No-op when nothing is in flight; the on-device stack is
    /// never touched because it needs the local model regardless of keys.
    private func cancelAssistantBrainDownloadIfRedundant() {
        guard voiceEngineStack == .gemini,
              !modelStore.isCached(resolvedBrainModelID),
              isAssistantBrainDownloadInFlight else { return }
        modelDownloadService.cancel(resolvedBrainModelID)
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
        // on-device stack will actually use. [STT-SWITCHER] The name comes
        // from the recognizer's EFFECTIVE artifact — it used to be the
        // hardcoded `whisperKitNepaliMedium` default, which is why a
        // v6-medium pick still read "v3" below the picker.
        if voiceEngineStack == .onDevice, whisperKitSpeechRecognizer.isAvailable {
            activeSTTNameKey = sttNameKey(for: whisperKitSpeechRecognizer.effectiveModelID)
            return
        }
        let resolved = sttModelPreference
            .flatMap { modelStore.isCached($0) ? $0 : nil }
            ?? whisperSpeechRecognizer.currentModelID()
        activeSTTNameKey = sttNameKey(for: resolved)
    }

    /// Catalog key naming the active STT (resolved in the UI's locale).
    ///
    /// Every Whisper-family engine the picker can select needs a case
    /// here — a fall-through labels the row "SFSpeechRecognizer (English
    /// fallback)", which is simply wrong for any of them (the v5/v6 ids
    /// used to land there). The `stt.name.*` values mirror the catalog
    /// `model.name.*` names (catalog declutter, 2026-09-12).
    private func sttNameKey(for id: ModelID?) -> String {
        switch id {
        case ModelCatalog.whisperKitNepaliMedium:
            return "stt.name.whisperKitNepali"
        case ModelCatalog.whisperKitMediumV6:
            return "stt.name.whisperKitMediumV6"
        case ModelCatalog.whisperKitMediumV5:
            return "stt.name.whisperKitMediumV5"
        case ModelCatalog.whisperKitNepali:
            return "stt.name.whisperKitTeacher"
        case ModelCatalog.whisperKitNepaliLargeBase:
            return "stt.name.whisperKitLargeBase"
        case ModelCatalog.whisperMediumV6:
            return "stt.name.whisperMediumV6"
        case ModelCatalog.whisperMediumV5:
            return "stt.name.whisperMediumV5"
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
    /// TTS/notification path for visible feedback.
    ///
    /// [LAT-M1/LAT-EVIDENCE] The whisper release goes through the
    /// post-turn policy (`WhisperPostTurnPolicy.transcriptAction`):
    /// TTL-hold whenever the weights fit under the current RAM ceiling
    /// (back-to-back turns skip the reload), release-only when the
    /// probe is critical, and the unconditional release (today's exact
    /// behavior) when the policy does not apply. The warm-start
    /// preference is NOT consulted — it gates the BOOT warm only;
    /// post-turn residency is the invariance contract.
    func recordTranscript(_ text: String) {
        applyPostTranscriptWhisperPolicy()
        DispatchQueue.main.async { [weak self] in
            self?.livePartialTranscript = nil
            self?.lastTranscript = text
            self?.appendHistory(.user, text)
        }
    }

    // MARK: - Post-turn whisper weights ([LAT-M1])

    /// The whisper weights' live footprint, read from the LEDGER — the one
    /// place that knows which artifact the recognizer actually loads.
    ///
    /// [MODEL-WARDEN] Step 0, closing H5. This used to be a `static let`
    /// resolving `ModelCatalog.whisperKitNepaliMedium` — the *superseded
    /// fp16 v3* entry, 1.6 GB — while the shipping recognizer loads
    /// `whisperKitMediumV6` (800 MB on disk, 1.00 GB live: weights + KV +
    /// overhead). Every hold and re-warm decision in this file was therefore
    /// made against 1.6× the real number, which is why the field log shows
    /// `post_transcript outcome=released (ram_critical)` on a device that
    /// had room to keep the weights — the exact reload the invariance
    /// contract exists to prevent.
    ///
    /// The ledger resolved the real model id when the recognizer registered
    /// the slot, so asking it removes the second, drifting copy of the
    /// number rather than correcting it to a third value that can drift
    /// again.
    private var whisperFootprintBytes: UInt64 {
        if let registered = ModelLifecycleManager.shared
            .footprint(of: .speechToText)?.liveBytes, registered > 0 {
            return registered
        }
        // Nothing registered yet — a launch where the recognizer has not
        // been constructed. Resolve the same way the registration will,
        // from the inventory and the recognizer's own preferred model id.
        return ModelLifecycleInventory.footprint(
            for: .speechToText,
            modelID: whisperKitSpeechRecognizer.preferredModelID).liveBytes
    }

    /// True while WhisperKit is the STT the on-device selection table
    /// would actually run — the only recognizer whose weights can be
    /// held/re-warmed (whisper.cpp loads a fresh context per attempt).
    private var whisperKitIsActiveSTT: Bool {
        guard voiceEngineStack == .onDevice else { return false }
        if case .whisperKit = Self.onDeviceSTTChoice(
            whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
            whisperCppAvailable: whisperSpeechRecognizer.isAvailable) {
            return true
        }
        return false
    }

    /// Applies the post-transcript policy to the whisper weights (any
    /// queue — the recognizer's release is queue-agnostic, the hold's
    /// expiry and the re-warm landing marshal to main).
    private func applyPostTranscriptWhisperPolicy() {
        // whisper.cpp loads a FRESH context per attempt by design — a
        // held context could never be reused. It always releases.
        whisperSpeechRecognizer.releaseModel()
        // [LAT-EVIDENCE] The warm-start preference is deliberately NOT
        // an input — the toggle gates the BOOT warm only; post-turn
        // residency is the invariance contract's back-to-back half.
        let action = WhisperPostTurnPolicy.transcriptAction(
            config: WhisperPostTurnPolicy.ResidencyConfig(
                stack: voiceEngineStack,
                whisperKitIsActiveSTT: whisperKitIsActiveSTT,
                whisperKitAvailable: whisperKitSpeechRecognizer.isAvailable,
                isModelLoaded: whisperKitSpeechRecognizer.isModelLoaded),
            availableBytes: MemoryProbe.availableProcessMemoryBytes,
            whisperFootprintBytes: whisperFootprintBytes)
        switch action {
        case .hold:
            // The probe allows the weights to stay resident across the
            // LLM inference of this turn: hold them for the TTL so a
            // back-to-back turn reuses the instance and skips the load.
            // The TTL expiry releases and re-warms in the background.
            whisperResidencyCycle.arm()
            emitWhisperWeightsEvent(
                eventType: "post_transcript", outcome: "held",
                metadata: ["ttl_s": "\(Int(WhisperPostTurnPolicy.ttlSeconds))"])
        case .releaseOnly:
            // Critically tight: release and stay released — a reload
            // would endanger the app. The next turn pays the load.
            whisperResidencyCycle.cancel()
            whisperKitSpeechRecognizer.releaseModel()
            emitWhisperWeightsEvent(
                eventType: "post_transcript", outcome: "released",
                metadata: ["reason": "ram_critical"])
        case .notApplicable:
            // Not the on-device WhisperKit stack, or nothing loaded (a
            // fallback STT served the turn) — today's release applies.
            whisperResidencyCycle.cancel()
            whisperKitSpeechRecognizer.releaseModel()
        }
    }

    /// The TTL lapsed with no new transcript: release the weights (the
    /// re-warm half runs separately via the residency cycle's
    /// `onReWarmRequired` — the next turn must not pay the cold load).
    private func releaseHeldWhisperWeights() {
        whisperKitSpeechRecognizer.releaseModel()
        emitWhisperWeightsEvent(eventType: "ttl_expired", outcome: "released")
    }

    /// [LAT-EVIDENCE] The background re-warm (runs when the TTL hold
    /// lapses, main-confined): re-probes at execution time — only a
    /// critical ceiling skips it (the safety valve), and the warm-start
    /// preference NEVER gates it. On success the re-warmed weights
    /// re-arm the same TTL hold, so the residency cycle repeats and the
    /// next turn is warm.
    private func runBackgroundWhisperReWarm() {
        guard voiceEngineStack == .onDevice,
              whisperKitIsActiveSTT,
              whisperKitSpeechRecognizer.isAvailable else { return }
        guard MemoryProbe.availableProcessMemoryBytes
                >= whisperFootprintBytes else {
            emitWhisperWeightsEvent(
                eventType: "rewarm", outcome: "skipped",
                metadata: ["reason": "ram_critical"])
            return
        }
        emitWhisperWeightsEvent(eventType: "rewarm", outcome: "started")
        whisperKitSpeechRecognizer.warm { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .ready:
                    self.emitWhisperWeightsEvent(
                        eventType: "rewarm", outcome: "ready")
                    // The weights are resident again — re-arm the same
                    // TTL hold so back-to-back turns skip the load.
                    self.whisperResidencyCycle.arm()
                case .failed(let reason):
                    self.emitWhisperWeightsEvent(
                        eventType: "rewarm", outcome: "failed",
                        metadata: ["reason": reason])
                }
            }
        }
    }

    /// The post-turn whisper weights events: component `whisper_weights`
    /// (PII-free — outcomes/reasons only, never audio or transcripts).
    private func emitWhisperWeightsEvent(eventType: String,
                                         outcome: String,
                                         metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "whisper_weights",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }

    // MARK: - Family & friends — curated contacts (spec §4.4.2)

    /// Maps stored family contacts onto the notifier's contact type.
    /// Device tokens stay unprovisioned until the broker relay exists
    /// (review C6) — the list itself is real and wired.
    ///
    /// [CAREGIVER-EVENTS] (2026-09-13) Each contact also resolves its
    /// EVENT-ALERT channel from the calling preference the elder already
    /// chose: a contact the app calls on WhatsApp gets event alerts on
    /// WhatsApp, one it calls on Messenger gets Messenger (and falls back
    /// to SMS when no handle is on file — Messenger addresses people by
    /// username, the same pre-gate `resolvedCallChannel` applies to the
    /// call button), everything else rides SMS. `preferredCallApp` is
    /// optional and per-contact, so the app-wide default fills in —
    /// `notifyChannel` is a pure function of the two, kept out of this
    /// mapper so the matrix is testable without constructing a contact.
    ///
    /// Note the deliberate hardcode below is NOT the pre-existing
    /// `isEmergencyContact: true` one (out of scope here): the fallback
    /// chain is explicit because a curated contact that is not a family
    /// target still has to resolve to SOMETHING for the type's
    /// non-optional field.
    private static func emergencyContacts(from contacts: [FamilyContact],
                                          defaultCallApp: CallApp) -> [EmergencyContact] {
        contacts.map { contact in
            let channel = NotifyChannel.resolve(
                preferred: contact.preferredCallApp,
                defaultApp: defaultCallApp,
                messengerHandleAvailable: !(contact.messengerHandle ?? "").isEmpty
            )
            return EmergencyContact(
                id: contact.id,
                displayName: contact.name,
                deviceToken: "",
                isEmergencyContact: true,
                isFamilyNotificationTarget: true,
                notifyChannel: channel
            )
        }
    }

    /// Photo thumbnails for curated contacts (family-and-friends task,
    /// 2026-09-07). Lazy like the intent-layer stores: nothing touches
    /// Application Support paths before launch completes. Photos are
    /// best-effort visuals — the store is non-throwing, and every call
    /// site below tolerates a nil filename.
    lazy var contactPhotoStore = ContactPhotoStore()

    /// The stored thumbnail for a curated contact, or nil when none is
    /// on file (or the file vanished) — the single lookup every row
    /// renders through, so the Photo-tab UI needs nothing but a contact.
    func contactPhoto(for contact: FamilyContact) -> UIImage? {
        contactPhotoStore.load(named: contact.photoFilename)
    }

    /// Adds a curated contact (spec §4.4.2). `photo`, when given, is
    /// persisted to `ContactPhotoStore` FIRST and its file name stored
    /// on the contact — and if the store rejects the contact (list full)
    /// the just-written file is deleted again, so a failed add never
    /// orphans a photo on disk.
    ///
    /// `nickname` (family-wizard task, 2026-09-07): the optional
    /// informal name from the wizard's last step; defaulted so the
    /// onboarding call site (which never collects one) is unchanged.
    ///
    /// `address` (directions task, 2026-09-07) is the contact's optional
    /// home address for voice navigation — blank text is stored as nil.
    ///
    /// `isEmergencyContact` (family-emergency task, 2026-09-07): whether
    /// the wizard's "Emergency contact" toggle was on — the Emergency
    /// affordance prefers flagged contacts (see `emergencyContact`).
    /// Defaulted so the onboarding call site (which has no toggle) is
    /// unchanged; an add written before the flag simply stores false.
    @discardableResult
    func addFamilyContact(name: String, phone: String, relationship: String,
                          messengerHandle: String? = nil,
                          photo: UIImage? = nil,
                          nickname: String? = nil,
                          address: String? = nil,
                          email: String? = nil,
                          isEmergencyContact: Bool = false) -> Bool {
        let filename = photo.flatMap { contactPhotoStore.save($0) }
        let contact = FamilyContact(name: name, phone: phone, relationship: relationship,
                                    messengerHandle: messengerHandle,
                                    photoFilename: filename,
                                    nickname: nickname,
                                    address: Self.normalizedOptionalText(address),
                                    email: FamilyContactValidation.normalizedEmail(email),
                                    isEmergencyContact: isEmergencyContact)
        guard familyContactStore.add(contact) else {
            if let filename { contactPhotoStore.delete(named: filename) }
            return false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts,
                                   defaultCallApp: self.defaultCallApp))
        }
        return true
    }

    /// Field edit of a curated contact (family-and-friends task,
    /// 2026-09-07 — the Settings editor's five-step add/edit wizard).
    /// The photo arguments express the wizard's three intents exactly:
    /// `photo` non-nil REPLACES the stored photo, `removingPhoto` clears
    /// it, and both nil keeps whatever is on file. The record save is
    /// the commit point — a written replacement file is deleted again
    /// when the store write fails, and the old photo file is only
    /// deleted after the new record is safely persisted, so a failed
    /// edit never loses the photo the contact already had.
    ///
    /// `nickname` (family-wizard task, 2026-09-07): the wizard's
    /// optional informal name; nil clears a stored one, defaulted so
    /// pre-wizard callers compile unchanged.
    ///
    /// `isEmergencyContact` (family-emergency task, 2026-09-07): the
    /// editor's current "Emergency contact" toggle value — the save
    /// REPLACES the stored flag, so un-toggling an emergency contact is
    /// an ordinary edit. The wizard — the only caller — always passes
    /// it on every save, and an edit loads the stored flag into the
    /// toggle first, so a flag the user did not touch survives. The
    /// false default exists only so pre-toggle call sites compile
    /// unchanged; a caller that omits it means "not flagged".
    @discardableResult
    func updateFamilyContact(id: UUID, name: String, phone: String, relationship: String,
                             messengerHandle: String?,
                             photo: UIImage? = nil, removingPhoto: Bool = false,
                             nickname: String? = nil,
                             address: String? = nil,
                             email: String? = nil,
                             isEmergencyContact: Bool = false) -> Bool {
        guard var contact = familyContacts.first(where: { $0.id == id }) else { return false }
        contact.name = name
        contact.phone = phone
        contact.relationship = relationship
        contact.messengerHandle = messengerHandle
        contact.nickname = nickname
        contact.isEmergencyContact = isEmergencyContact
        // The editor passes the CURRENT text each save; blank clears the
        // stored address (nil), so "remove the address" is an edit, not a
        // separate affordance (directions task, 2026-09-07).
        contact.address = Self.normalizedOptionalText(address)
        // Same rule for the Google address (calendar & family sharing,
        // 2026-09-16): blank clears it, and the editor's emergency gate
        // is what makes a blank impossible while the contact is flagged
        // — this normalizes, it does not enforce.
        contact.email = FamilyContactValidation.normalizedEmail(email)

        let oldFilename = contact.photoFilename
        var newFilename = oldFilename
        if removingPhoto {
            newFilename = nil
        } else if let photo {
            // A failed thumbnail write KEEPS the photo the contact
            // already had — a pick that couldn't be stored is a failed
            // replacement, never a removal. (Only a first add with no
            // old photo proceeds photo-less.)
            if let saved = contactPhotoStore.save(photo) {
                newFilename = saved
            }
        }

        var all = familyContactStore.load()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            if let newFilename, newFilename != oldFilename {
                contactPhotoStore.delete(named: newFilename)
            }
            return false
        }
        contact.photoFilename = newFilename
        all[index] = contact
        guard familyContactStore.save(all) else {
            if let newFilename, newFilename != oldFilename {
                contactPhotoStore.delete(named: newFilename)
            }
            return false
        }
        // The new record is safely on disk — the replaced/removed old
        // file can go now.
        if let oldFilename, oldFilename != newFilename {
            contactPhotoStore.delete(named: oldFilename)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts,
                                   defaultCallApp: self.defaultCallApp))
        }
        return true
    }

    func removeFamilyContact(id: UUID) {
        // The photo file is deleted with its contact — a removed person's
        // thumbnail must not linger on disk.
        let removed = familyContacts.first { $0.id == id }
        familyContactStore.remove(id: id)
        if let filename = removed?.photoFilename {
            contactPhotoStore.delete(named: filename)
        }
        callMethodPreferences.removeAll(for: id)
        confirmedMethodHistory.removeAll(for: id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts,
                                   defaultCallApp: self.defaultCallApp))
        }
    }

    // MARK: - Saved places (directions task, 2026-09-07)

    /// Blank-or-whitespace optional text (an editor field the user left
    /// empty) is stored as nil — shared by the contact-address and
    /// saved-place writes so "no address" is always `nil`, never `""`.
    private static func normalizedOptionalText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Adds a saved place (Settings → Places editor). The store enforces
    /// the cap and the default-home rules (first `.home` auto-promotes);
    /// on success the published list refreshes from the store so views
    /// and the router's candidate list see the same truth. UI-thread
    /// callers only (Settings), so the published mutation stays on main.
    @discardableResult
    func addPlace(name: String, address: String, category: SavedPlace.Category,
                  isDefaultHome: Bool) -> Bool {
        let normalized = Self.normalizedOptionalText(address) ?? ""
        let place = SavedPlace(name: name, address: normalized,
                               category: category, isDefaultHome: isDefaultHome)
        guard placeStore.add(place) else { return false }
        savedPlaces = placeStore.load()
        return true
    }

    /// Field edit of a saved place (the Settings editor's save). The
    /// default-home toggle wins exactly like the store's rule: a `.home`
    /// saved with the flag set becomes THE default, and a demoted save
    /// of the current default auto-promotes the next `.home`.
    @discardableResult
    func updatePlace(id: UUID, name: String, address: String, category: SavedPlace.Category,
                     isDefaultHome: Bool) -> Bool {
        guard savedPlaces.contains(where: { $0.id == id }) else { return false }
        let normalized = Self.normalizedOptionalText(address) ?? ""
        let place = SavedPlace(id: id, name: name, address: normalized,
                               category: category, isDefaultHome: isDefaultHome)
        guard placeStore.update(place) else { return false }
        savedPlaces = placeStore.load()
        return true
    }

    /// Removes a saved place. Removing the current default auto-promotes
    /// the first remaining `.home` (store rule); an important-place-only
    /// list simply has no default, and the router speaks the honest
    /// `directions.noHome` line until one is saved.
    func removePlace(id: UUID) {
        placeStore.remove(id: id)
        savedPlaces = placeStore.load()
    }

    /// Makes the `.home` place with `id` THE default home ("take me
    /// home" target). Returns false when no such `.home` place exists.
    @discardableResult
    func setDefaultHomePlace(id: UUID) -> Bool {
        guard placeStore.setDefaultHome(id: id) else { return false }
        savedPlaces = placeStore.load()
        return true
    }

    // MARK: - Emergency (redesign spec §3.1/§3.2 — persistent icon everywhere)

    /// The contact the Emergency affordance calls (family-emergency
    /// task, 2026-09-07): the first contact flagged
    /// `isEmergencyContact` — whichever person the family marked with
    /// the wizard's "Emergency contact" toggle — else the first
    /// configured contact, the pre-flag behavior kept as the fallback
    /// so an unflagged list still dials somebody. Nil when none is
    /// configured, which the view surfaces honestly instead of
    /// pretending an action is available. The rule itself is the pure
    /// `preferredEmergencyContact(_:)` below so tests can pin it
    /// without an instance.
    var emergencyContact: FamilyContact? {
        Self.preferredEmergencyContact(familyContacts)
    }

    /// The emergency-preference rule as a pure function
    /// (family-emergency task, 2026-09-07): contacts flagged
    /// `isEmergencyContact` win, in list order (the FIRST flag is THE
    /// number — the toggle's caption promises "dials this person
    /// first"); an all-unflagged list falls back to the first contact,
    /// exactly what `emergencyContact` resolved before the flag
    /// existed; an empty list resolves nil. Pinned by tests.
    static func preferredEmergencyContact(_ contacts: [FamilyContact]) -> FamilyContact? {
        contacts.first(where: \.isEmergencyContact) ?? contacts.first
    }

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

    // MARK: - Quick access apps (Home row + Settings picker, 2026-09-06)

    /// Honest installed probe for a catalog app — `canOpenURL` on its
    /// declared scheme (iOS cannot enumerate installed apps; the schemes
    /// live in Info.plist LSApplicationQueriesSchemes and every catalog
    /// scheme is pinned by AppLauncherTests). Main-thread safe
    /// (`SystemCallLinkOpener` hops to main for the system probe).
    func isAppInstalled(_ app: AppLauncher.App) -> Bool {
        appLauncher.isInstalled(app)
    }

    /// Adds `app` to the quick-access favourites. Every precondition is
    /// re-validated here — the picker gates its buttons on the same
    /// checks, but the coordinator is the backstop (a scheme probe can
    /// go stale between the row's appearance and the tap): catalog
    /// membership, genuinely installed on this phone, room under the
    /// cap, not already favourited. Returns false (and changes nothing)
    /// when any check fails.
    @discardableResult
    func addFavoriteApp(_ app: AppLauncher.App) -> Bool {
        guard AppLauncher.app(for: app.id) != nil,
              !favoriteAppIDs.contains(app.id),
              favoriteAppIDs.count < AppLauncher.maxFavourites,
              isAppInstalled(app) else { return false }
        favoriteAppIDs.append(app.id)
        return true
    }

    /// Removes `app` from the quick-access favourites. No-op when it
    /// isn't there (the picker and a stale row can both call it).
    func removeFavoriteApp(_ app: AppLauncher.App) {
        favoriteAppIDs.removeAll { $0 == app.id }
    }

    /// Launches a quick-access app — the Home row / picker tile tap AND
    /// the confirmed voice launch (`launcher.open`) share this ONE
    /// executor, so the two paths can never drift apart in what they
    /// probe, say, or claim.
    ///
    /// Dual-channel honesty as before: probe FIRST, and when the app is
    /// gone (deleted after the row appeared) say so out loud and show it
    /// on the outcome card — never a silent dead tap. An absent app that
    /// HAS a web fallback (Facebook, Instagram, YouTube, WhatsApp — the
    /// four the design gives one) opens its website and discloses the
    /// swap; an absent app without one hears the honest not-installed
    /// line rather than being sent to Safari on an unrelated page. One
    /// `app_launcher` event per attempt; the outcome names which surface
    /// appeared (`<id>:opened`, `<id>:openedWebFallback`) or why nothing
    /// did (`<id>:notInstalled`, `<id>:cameraUnavailable`).
    ///
    /// The camera entry never reaches the URL branch: it has no URL
    /// (`AppLauncher.Kind.camera`) and is answered by the in-app capture
    /// flow, which is why a `.camera` tile is no longer a tap that
    /// announces "Opening Camera" over a screen that never appears.
    func performAppLaunch(_ app: AppLauncher.App) {
        // [APP-LAUNCHER F6] A tap IS an answer. Resolving the outstanding
        // question first is what keeps the tile from racing the 45 s
        // window it pends: the question is cleared (and its window closed)
        // before the app opens, so the elder can never hear "Time is up, I
        // won't open it" over an app they are already looking at.
        resolveLaunchQuestion(openedBy: app.id)
        switch app.kind {
        case .camera:
            presentCameraCapture(app)
        case .url:
            launchURLApp(app)
        }
    }

    /// The `.url` half of the executor: probe, open, and speak the surface
    /// that actually appeared.
    private func launchURLApp(_ app: AppLauncher.App) {
        let locale = activeLocale
        let name = L10n.str(app.nameKey, locale: locale)
        // [F9] The probe, the web fallback and the Settings fallback are
        // resolved in ONE place (`AppLauncher.launchPlan`) so the tile, the
        // voice request and this executor can never decide differently
        // about what a launch opens.
        switch appLauncher.launchPlan(for: app) {
        case .app:
            appLauncher.open(app)
            let text = L10n.fmt("apps.announce.opened", locale: locale, name)
            setOutcome(icon: app.systemImage, text: text)
            speak(text: text)
            emitAppLaunch(outcome: "\(app.id):opened")
        case .webFallback:
            // The web fallback is a REAL surface (Safari, or the app's own
            // universal link when it turns out to be installed after all),
            // disclosed out loud — never a silent substitution.
            guard appLauncher.openWebFallback(app) else {
                return announceNotInstalled(app, name: name, locale: locale)
            }
            let text = L10n.fmt("apps.announce.openingWeb", locale: locale, name)
            setOutcome(icon: app.systemImage, text: text)
            speak(text: text)
            emitAppLaunch(outcome: "\(app.id):openedWebFallback")
        case .settingsFallback:
            // [F9] The pane's private App-Prefs URL did not answer; the
            // public Settings deep link always does. Same disclosure rule
            // as the web fallback — the elder is told which surface
            // actually appeared, and the outcome names it too.
            guard appLauncher.openSettingsFallback() else {
                return announceNotInstalled(app, name: name, locale: locale)
            }
            let text = L10n.str("apps.announce.openingSettings", locale: locale)
            setOutcome(icon: app.systemImage, text: text)
            speak(text: text)
            emitAppLaunch(outcome: "\(app.id):openedSettingsFallback")
        case .unavailable:
            announceNotInstalled(app, name: name, locale: locale)
        case .camera:
            // `performAppLaunch` routes `.camera` before it reaches this
            // executor (see its `switch`); a caller that reaches it anyway
            // lands on the honest capture path rather than a silent no-op.
            presentCameraCapture(app)
        }
    }

    /// The honest absent-app line, spoken and carded (the same surface
    /// every other failed launch uses) — shared by the three plans that
    /// can end with nothing opened.
    private func announceNotInstalled(_ app: AppLauncher.App, name: String,
                                      locale: Locale) {
        let text = L10n.fmt("apps.announce.notInstalled", locale: locale, name)
        setOutcome(icon: "exclamationmark.triangle.fill", text: text)
        speak(text: text)
        emitAppLaunch(outcome: "\(app.id):notInstalled")
    }

    /// The camera half of the executor (launcher plan T4 owns the system
    /// picker behind this seam). Everything the capture flow says — the
    /// saved / save-failed / no-camera / permission-denied lines — is
    /// spoken by the flow through these channels, so the coordinator adds
    /// no claim of its own: an unset seam means no presenter is installed
    /// and the honest answer is that nothing can be captured here, never
    /// an "Opening Camera" over a screen that does not appear.
    private func presentCameraCapture(_ app: AppLauncher.App) {
        guard let cameraCapture else {
            let text = L10n.str("apps.camera.unavailable", locale: activeLocale)
            setOutcome(icon: "exclamationmark.triangle.fill", text: text)
            speak(text: text)
            emitAppLaunch(outcome: "\(app.id):cameraUnavailable")
            return
        }
        cameraCapture.start()
    }

    /// The camera-capture seam: presenter + photo writer + the flow that
    /// speaks the outcome. A stored, assignable property so a test can put
    /// a scripted flow in its place; production value is built once in
    /// `init` (see `makeCameraCaptureFlow`). Nil would mean no presenter is
    /// installed: see `presentCameraCapture`.
    var cameraCapture: CameraCaptureFlow?

    /// Builds the production capture flow (T4): the system picker
    /// (`PhotoCameraPresenter`) and the add-only library write
    /// (`PhotosLibraryPhotoSaver`) behind the two injectable seams, with
    /// this coordinator's own speech / outcome-card / bus channels.
    ///
    /// Deliberately cheap and I/O-free: constructing it resolves no window
    /// and asks no permission (the presenter probes both at presentation
    /// time), so it is safe in `init` before the UI exists.
    private func makeCameraCaptureFlow() -> CameraCaptureFlow {
        CameraCaptureFlow(
            presenter: PhotoCameraPresenter(),
            saver: PhotosLibraryPhotoSaver(),
            locale: { [weak self] in
                self?.activeLocale ?? Locale(identifier: "ne-NP")
            },
            channels: CameraCaptureFlow.Channels(
                speak: { [weak self] text in
                    self?.speak(text: text)
                },
                announce: { [weak self] icon, text in
                    self?.setOutcome(icon: icon, text: text)
                },
                emit: { [weak self] eventType, outcome in
                    self?.emitAppLaunch(eventType: eventType, outcome: outcome)
                }
            )
        )
    }

    private func emitAppLaunch(eventType: String = "launch", outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "app_launcher",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]  // catalog app id only — no contact identifiers (C9)
        ))
    }

    // MARK: - Voice app launcher (launcher.open plugin, 2026-09-16)
    //
    // The confirmation half of the voice launch (design D3: confirm-first
    // before EVERY external launch). It reuses the router's existing
    // confirmation-follow-up machinery rather than adding a parallel one:
    // `requestAppLaunch` pends a launch and returns the question,
    // `isAwaitingAppLaunchConfirmation` widens `CommandRouter.route`'s
    // yes/no path, `handleConfirmationResponse` executes or cancels, and
    // the session's existing 45 s window auto-dismisses (below, in
    // `voiceSession.onConfirmationTimeout`) — the same four seams the
    // call / calendar-event / navigation confirmations ride.

    /// [APP-LAUNCHER F1] Who owns the elder's NEXT yes/no when a launch
    /// question and a medication dose-challenge are both outstanding.
    ///
    /// The two flows share one confirmation window
    /// (`VoiceSessionState.awaitingConfirmation`) and one router yes/no
    /// parse, so exactly one of them may own the answer. The medication
    /// challenge wins, always. It is the dementia-aware FR-D01
    /// double-dose gate (spec §3.3), and the whole point of the window is
    /// that a "हो" lands in `medicationScheduler.acknowledgeWithConfirmation`
    /// where the double-dose check can see it; a launch, by contrast, can
    /// simply be asked again. The failure mode this prevents is the
    /// dangerous one: a dose question answered yes while the launch block
    /// returns early means the dose is never recorded and the elder is
    /// told (by the launch's own line) that something was opened.
    ///
    /// Pure policy so the rule is testable without an AppCoordinator —
    /// the same shape as the other extracted helper types in this file.
    enum ConfirmationArbitration {
        enum Owner: Equatable {
            case appLaunch
            case medication
            case none
        }

        static func owner(pendingAppLaunch: String?,
                          hasMedicationChallenge: Bool) -> Owner {
            if hasMedicationChallenge { return .medication }
            return pendingAppLaunch == nil ? .none : .appLaunch
        }

        /// [APP-LAUNCHER F6] What a launch performed by a TAP means for the
        /// question still pended. The same app is the question being
        /// answered yes (`.confirmed`); a different app is that question
        /// being superseded, which is the unanswered verdict the flywheel
        /// already understands (`.superseded` → recorded as a timeout).
        enum TileResolution: Equatable {
            case confirmed
            case superseded
        }

        static func tileResolution(pending: String, opened: String) -> TileResolution {
            pending == opened ? .confirmed : .superseded
        }
    }

    /// [APP-LAUNCHER F13] The launch question's expiry, named in one place.
    ///
    /// A launch question that runs out its 45 s is a terminal outcome like
    /// the yes and the no, so it gets the same three treatments they get:
    /// a spoken line, a card that says what happened, and one
    /// `app_launcher` event. It used to get only the first — the question
    /// card ("Should I open Camera?") stayed on screen as if still
    /// pending, and the bus carried no record that a question had been
    /// asked and dropped. The constants live together so the handler, the
    /// event and the test can never drift apart.
    enum LaunchTimeout {
        static let eventType = "launch_timeout"
        static let icon = "clock.badge.exclamationmark"
        static let speechKey = "launcher.timeout"
        static func outcome(appID: String) -> String { "\(appID):timeout" }
    }

    /// A launch pended for the elder's spoken yes/no. Mirrors
    /// `PendingCallAction`: the pending state, the flywheel identity and
    /// the question→verdict clock all live together, so a verdict can
    /// never be recorded against a launch that was never asked about.
    struct PendingAppLaunch {
        let appID: String
        /// The interpreted command's confidence, when the launch came from
        /// the model (nil for the keyword/plugin seams that don't carry
        /// one) — the flywheel's accept-band input.
        let confidence: Double?
        /// [INTENTLOG-CAPTURE] When the confirmation question was asked —
        /// the flywheel's latency start (question → verdict).
        let requestedAt: Date = Date()

        /// [APP-LAUNCHER F10] Which routing stage asked the question — the
        /// flywheel's PATH label, and the reason this is derived here
        /// rather than defaulted at the recording site.
        ///
        /// `IntentLogStore.Capture`'s path defaults to "model", which is
        /// right for everything the interpreter or a plugin produced but
        /// WRONG for the deterministic keyword fast path: a
        /// `KeywordIntentRule` hit never saw a model, and labelling it
        /// "model" teaches the accept-band statistics that the model
        /// proposed launches it never saw. That stage is exactly the one
        /// that carries no confidence (`CommandRouter` passes
        /// `confidence: nil` from its `.appLaunch` stage; every
        /// interpreter/plugin command has one by construction), so nil IS
        /// the keyword signature.
        var capturePath: String { confidence == nil ? "keyword" : "model" }

        /// This launch's flywheel identity. The slot is the catalog app id
        /// — a public catalog key, never user content (C9).
        var capture: IntentLogStore.Capture {
            IntentLogStore.Capture(action: "launcher.open",
                                   slots: ["app": appID],
                                   confidence: confidence,
                                   requestedAt: requestedAt)
        }
    }

    @Published private(set) var pendingAppLaunch: PendingAppLaunch?

    /// Router-side twin of `pendingAppLaunch != nil` — the router skips its
    /// generic medication-flavored yes/no speech while a launch is pended
    /// (see `VoiceCommandCoordinating.isAwaitingAppLaunchConfirmation`)
    /// and reports `.appLaunchConfirmed` for the yes.
    ///
    /// [APP-LAUNCHER F1] …but never while a dose challenge is pended: the
    /// launch does not own that answer (see `ConfirmationArbitration`), so
    /// the router must not treat the utterance as a launch confirmation
    /// NOR suppress the medication line.
    var isAwaitingAppLaunchConfirmation: Bool {
        ConfirmationArbitration.owner(
            pendingAppLaunch: pendingAppLaunch?.appID,
            hasMedicationChallenge: pendingConfirmationEntryId != nil) == .appLaunch
    }

    /// Pends a catalog app for the elder's spoken yes/no and returns the
    /// line to speak — the `app_launcher` plugin's single seam (voice) and
    /// the API a deterministic keyword stage can call the same way.
    ///
    /// Two refusals to ASK, both deliberate (the call path's
    /// messenger-no-handle gate, same rationale): a launch that can only
    /// fail must never be turned into a yes/no question. An app that is not
    /// installed AND has no web fallback is answered with the honest
    /// not-installed line, nothing pended. An app that is not installed but
    /// HAS a web fallback IS asked about — the launch can still succeed
    /// (Safari) — with the swap disclosed in the question itself, so the
    /// "yes" the elder gives is a yes to what actually happens.
    ///
    /// The camera entry is always asked about: it needs no installed app
    /// (the capture is in-process), and whether the DEVICE can capture is
    /// answered after the yes, where the failure is.
    func requestAppLaunch(appID: String, confidence: Double?) -> String {
        let locale = activeLocale
        guard let app = AppLauncher.app(for: appID) else {
            // No catalog entry: nothing to ask about, and the caller speaks
            // this honest line instead (the plugin's own unknown-app case
            // is caught before it gets here — this is the same line, from
            // the layer that knows the catalog).
            emitAppLaunch(eventType: "launch_request", outcome: "unknownApp")
            return L10n.fmt("launcher.unknownApp", locale: locale, appID)
        }
        let name = L10n.str(app.nameKey, locale: locale)
        // [F9] Same single resolution the executor uses: what this launch
        // can actually open decides which question is asked — or whether
        // one is asked at all.
        switch appLauncher.launchPlan(for: app) {
        case .app, .camera:
            pendAppLaunch(appID: app.id, confidence: confidence)
            emitAppLaunch(eventType: "launch_request", outcome: "\(app.id):pending")
            return L10n.fmt("launcher.confirmOpen", locale: locale, name)
        case .webFallback:
            pendAppLaunch(appID: app.id, confidence: confidence)
            emitAppLaunch(eventType: "launch_request", outcome: "\(app.id):webFallbackPending")
            return L10n.fmt("launcher.confirmOpenWeb", locale: locale, name)
        case .settingsFallback:
            // [F9] A pane whose private App-Prefs URL did not answer is
            // still launchable — the public Settings deep link opens the
            // Settings app. The swap is disclosed in the question itself,
            // so the elder's "yes" is a yes to what actually happens (the
            // same contract as the web-fallback question above). The line
            // names no pane: for the Settings ROOT entry the fallback is
            // the same screen, and "I can't open that exact screen" is
            // true in every case.
            pendAppLaunch(appID: app.id, confidence: confidence)
            emitAppLaunch(eventType: "launch_request",
                          outcome: "\(app.id):settingsFallbackPending")
            return L10n.str("launcher.confirmOpenSettings", locale: locale)
        case .unavailable:
            // A launch that can only fail is never turned into a yes/no
            // question: the honest not-installed line, nothing pended.
            emitAppLaunch(eventType: "launch_request", outcome: "\(app.id):notInstalled")
            return L10n.fmt("apps.announce.notInstalled", locale: locale, name)
        }
    }

    /// Pends the launch and arms the session's existing confirmation
    /// window (the 45 s budget in `VoiceSessionStateMachine`) — nothing is
    /// opened until the elder says yes.
    ///
    /// [APP-LAUNCHER F14] The window is opened in the SAME breath as the
    /// pend (`openConfirmationWindow`), not by a bare `transition(to:)`
    /// that could no-op: a launch question may arrive while the session
    /// sits in a state the transition table does not let reach
    /// `.awaitingConfirmation` directly (`.error` after a pipeline
    /// failure, `.stopped` before the pipeline is primed), and a pend with
    /// no window is a pend with no timer and no clearer — the question
    /// would sit on screen forever, answered only by chance.
    private func pendAppLaunch(appID: String, confidence: Double?) {
        pendingAppLaunch = PendingAppLaunch(appID: appID, confidence: confidence)
        openConfirmationWindow()
    }

    /// [APP-LAUNCHER F14] Guarantees the confirmation window is open —
    /// the session machine bridges through `.idle` when the current state
    /// cannot reach `.awaitingConfirmation` directly, and the machine
    /// reports whether it got there. Main-queue confinement is preserved
    /// by the same hop the callers used before; when the caller is already
    /// on main (the usual case — the router and the tile both are) the
    /// window opens synchronously, so there is no instant in which the
    /// caller has pended work but no timer exists for it.
    private func openConfirmationWindow() {
        if Thread.isMainThread {
            voiceSession.openConfirmationWindow()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.voiceSession.openConfirmationWindow()
            }
        }
    }

    /// [APP-LAUNCHER F6] A launch performed OUTSIDE the spoken yes/no —
    /// the Home quick-access tile, or the executor reached from any other
    /// tap — resolves the launch question that is still on screen.
    ///
    /// Without this the question stayed pended over a live camera with
    /// its 45 s window still armed: the elder tapped the tile, the app
    /// opened, and 45 seconds later the assistant announced "Time is up, I
    /// won't open it" over the app they were looking at. The tile IS an
    /// answer, and it is a CONFIRMED one when it names the same app (the
    /// question was "should I open X?" and X is what opened); a tile for a
    /// DIFFERENT app supersedes the question the same way a new question
    /// does, and is recorded as the unanswered verdict it is.
    ///
    /// The window is closed with the pend (when no other flow is riding on
    /// it) so the timer cannot fire at all: `VoiceSessionStateMachine` only
    /// reports an expiry for a window that is still open, so a closed one
    /// stays silent even if its callback was already in flight.
    private func resolveLaunchQuestion(openedBy appID: String) {
        guard let launch = pendingAppLaunch else { return }
        pendingAppLaunch = nil
        switch ConfirmationArbitration.tileResolution(pending: launch.appID,
                                                      opened: appID) {
        case .confirmed:
            appendCapture(launch.capture, .confirmed, path: launch.capturePath)
            emitAppLaunch(eventType: "launch_confirmed",
                          outcome: "\(launch.appID):confirmedByTile")
        case .superseded:
            appendCapture(launch.capture, .timeout, path: launch.capturePath)
            emitAppLaunch(eventType: "launch_superseded",
                          outcome: "\(launch.appID):supersededByTile")
        }
        // Close the window only when nothing else pended is riding on it —
        // closing it under a medication challenge would leave that pend
        // with no timer (the F14 failure mode in mirror image).
        if !isAwaitingConfirmation, voiceSession.state == .awaitingConfirmation {
            voiceSession.transition(to: .idle)
        }
    }

    /// Confirmed: resolve the pended id through the catalog and hand it to
    /// the SAME executor the Home tile uses. A catalog id that no longer
    /// resolves (catalog changed between the question and the yes) speaks
    /// the honest unknown-app line rather than opening a guess.
    private func executePendingAppLaunch(_ launch: PendingAppLaunch) {
        guard let app = AppLauncher.app(for: launch.appID) else {
            // The catalog changed between the question and the yes: say so
            // honestly, and record NOTHING — a confirmed verdict that
            // could not be executed teaches the flywheel nothing (the same
            // rule the calendar write and the call path hold for a failed
            // open).
            replyHonestly(key: "launcher.noApp")
            return
        }
        performAppLaunch(app)
        // Recorded on the launch, exactly like the call path's confirmed
        // execution: by construction every pended launch was launchable
        // when it was asked about (installed, or carrying a web fallback,
        // or the in-process camera), so the elder's yes is the verdict the
        // executor acts on. A device that refuses the CAMERA after the yes
        // is a separate, honestly-reported outcome (its own
        // `camera_capture_*` event) — the interpretation was still right.
        appendCapture(launch.capture, .confirmed, path: launch.capturePath)
    }

    // MARK: - Phone-leaf contact-list launches (contact-leaf-launch task,
    // 2026-09-07)

    /// Opens WhatsApp's own chat list — the Phone leaf's "WhatsApp
    /// contacts" button (contact-leaf-launch task, 2026-09-07). The app
    /// has no API to render a WhatsApp contact list in-process, so one
    /// tap hands the elder INTO WhatsApp: its scheme root IS the chat
    /// list. Same dual-channel honesty as `performAppLaunch` — probe
    /// `canOpenURL` first, and when WhatsApp is gone say so aloud with a
    /// failure outcome, never a silent dead tap.
    func openWhatsAppContacts() {
        let locale = activeLocale
        let name = L10n.str("app.name.whatsapp", locale: locale)
        // Scheme root is a compile-time constant — the unwrap can never
        // trap (same rationale as `AppLauncher.App.rootURL`).
        let url = URL(string: "whatsapp://")!
        guard canOpenURLOnMain(url) else {
            let text = L10n.fmt("apps.announce.notInstalled", locale: locale, name)
            setOutcome(icon: "exclamationmark.triangle.fill", text: text)
            speak(text: text)
            emitContactLeafLaunch(outcome: "whatsapp:notInstalled")
            return
        }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
        let text = L10n.fmt("apps.announce.opened", locale: locale, name)
        setOutcome(icon: "bubble.left.and.bubble.right.fill", text: text)
        speak(text: text)
        emitContactLeafLaunch(outcome: "whatsapp:opened")
    }

    /// Messenger analogue of `openWhatsAppContacts` — `fb-messenger://`
    /// (its scheme root) opens Messenger's people list. Same
    /// probe-first, announce-honestly, never-silent-dead-tap contract.
    func openMessengerContacts() {
        let locale = activeLocale
        let name = L10n.str("app.name.messenger", locale: locale)
        // Scheme root is a compile-time constant — the unwrap can never
        // trap (same rationale as `AppLauncher.App.rootURL`).
        let url = URL(string: "fb-messenger://")!
        guard canOpenURLOnMain(url) else {
            let text = L10n.fmt("apps.announce.notInstalled", locale: locale, name)
            setOutcome(icon: "exclamationmark.triangle.fill", text: text)
            speak(text: text)
            emitContactLeafLaunch(outcome: "messenger:notInstalled")
            return
        }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
        let text = L10n.fmt("apps.announce.opened", locale: locale, name)
        setOutcome(icon: "paperplane.fill", text: text)
        speak(text: text)
        emitContactLeafLaunch(outcome: "messenger:opened")
    }

    /// `UIApplication.shared.canOpenURL` is main-thread bound — hop to
    /// main when a caller runs off it (the same shape as
    /// `SystemCallLinkOpener`). View taps arrive on main already; this
    /// covers any other caller.
    private func canOpenURLOnMain(_ url: URL) -> Bool {
        if Thread.isMainThread { return UIApplication.shared.canOpenURL(url) }
        return DispatchQueue.main.sync { UIApplication.shared.canOpenURL(url) }
    }

    private func emitContactLeafLaunch(outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "contact_leaf_launch",
            eventType: "tap",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]  // app id only — no contact identifiers (C9)
        ))
    }

    // MARK: - Voice-triggered calendar event (caregiver event-notifications, 2026-09-13)

    /// A `create_calendar_event` interpretation pended for confirmation.
    /// Holds the RESOLVED start instant, never the raw time expression:
    /// the router parses once (`NepaliTimeParser` +
    /// `CalendarEventTimeResolver`), so the confirmation prompt, the
    /// written event and the spoken outcome can never disagree about
    /// when the event is.
    struct PendingCalendarEvent {
        let title: String
        let startDate: Date
        /// [INTENTLOG-CAPTURE] When the confirmation question was asked —
        /// the flywheel's latency start (question → verdict).
        let requestedAt: Date = Date()

        /// This event's flywheel identity, for whichever verdict lands
        /// (confirmed / denied / timeout). Deliberately carries NO slots:
        /// the title is user content with no reviewed capture policy
        /// (contact names are the only slot values the log stores by
        /// design), so the record says which ACTION the elder confirmed,
        /// never what it was about.
        var capture: IntentLogStore.Capture {
            IntentLogStore.Capture(action: "create_calendar_event",
                                   requestedAt: requestedAt)
        }
    }

    @Published private(set) var pendingCalendarEvent: PendingCalendarEvent?

    /// [CALENDAR-EVENTS] (2026-09-13) Router-side twin of
    /// `pendingCalendarEvent != nil` — the router skips its generic
    /// medication-flavored yes/no speech while an event is pended (see
    /// `VoiceCommandCoordinating.isAwaitingCalendarEventConfirmation`).
    var isAwaitingCalendarEventConfirmation: Bool { pendingCalendarEvent != nil }

    /// The EventKit write seam for voice-created events — LAZY like
    /// `calendarSync`: constructing it touches no permissions, and
    /// nothing here runs until the elder actually asks for an event.
    /// Unlike `calendarSync` it is NOT the mirror: it writes one-off
    /// events to the user's DEFAULT calendar (see
    /// `VoiceCalendarEventWriter`), which is what makes them flow back
    /// through the external-calendar import and fire the caregiver
    /// alert like any other calendar reminder.
    private(set) lazy var voiceCalendarEventWriter: CalendarEventWriting =
        EventKitCalendarEventWriter()

    /// `create_calendar_event` (real executor — replaces the stub it
    /// shared with `suggest_video`). Pends the resolved event, puts the
    /// session in awaiting-confirmation and returns the prompt to speak;
    /// nil when the calendar cannot be written at all right now, so the
    /// router speaks its honest unavailable line instead of asking the
    /// elder to confirm an action that can only fail.
    ///
    /// The spoken time is `SpokenTime`'s, never a `DateFormatter`'s: the
    /// promise of the feature is that an elder HEARS "भोलि बिहान ८ बजे"
    /// and can say yes to it, and a clock string read out as digits is
    /// exactly the bug `SpokenTime` exists to prevent.
    func requestCalendarEventConfirmation(title: String, startDate: Date) -> String? {
        guard canWriteCalendarEvents else { return nil }
        let event = PendingCalendarEvent(title: title, startDate: startDate)
        pendingCalendarEvent = event
        DispatchQueue.main.async { [weak self] in
            self?.voiceSession.transition(to: .awaitingConfirmation)
        }
        return L10n.fmt("router.calendarEventConfirm",
                        locale: activeLocale,
                        event.title,
                        SpokenTime.string(from: event.startDate, locale: activeLocale))
    }

    /// Whether a voice-created event can plausibly be written WITHOUT
    /// prompting. `.writeOnly` counts — the voice flow only ever CREATES,
    /// which is precisely what a write-only grant permits — and
    /// `.notDetermined` counts because that is the one case where the
    /// point-of-use ask (which happens AFTER the elder has confirmed)
    /// can still succeed; refusing to ask would make the feature
    /// unreachable on a fresh install. Only `denied`/`restricted` are
    /// dead ends, and those must never be papered over with a
    /// confirmation question.
    private var canWriteCalendarEvents: Bool {
        switch voiceCalendarEventWriter.eventsAccess {
        case .fullAccess, .writeOnly, .notDetermined:
            return true
        case .denied, .restricted:
            return false
        }
    }

    /// Confirmed: ask if never asked, write, then speak the honest
    /// outcome. Both halves are off-main (the access ask is a suspension
    /// point, and `EKEventStore.save` is blocking IO) and the result
    /// returns to the main queue to touch published state.
    ///
    /// The event is written to the DEFAULT calendar, so the normal
    /// external-calendar import picks it up and arms its reminder — a
    /// rescan here just makes that immediate instead of waiting for the
    /// next foreground/BGTask scan. That is also the honest limit of
    /// this path: if the family has the external-calendar import toggled
    /// OFF, the event exists in the native calendar but the app has no
    /// reminder to fire from (and therefore no caregiver alert either) —
    /// the written event is still correct, and `router.calendarEventCreated`
    /// claims only that it was added to the calendar.
    private func executePendingCalendarEvent(_ event: PendingCalendarEvent) {
        Task { [weak self] in
            guard let self else { return }
            if self.voiceCalendarEventWriter.eventsAccess == .notDetermined {
                _ = await self.voiceCalendarEventWriter.requestAccess()
            }
            // [CALENDAR-SHARE] (2026-09-16) Attached here, not at
            // construction, to keep the writer lazy (its property doc
            // explains why) — and re-attached each write, which is
            // harmless because the closure is the same every time.
            self.voiceCalendarEventWriter.onEventCreated = { [weak self] creation in
                self?.calendarShareService.eventCreated(
                    localEventId: creation.localEventId,
                    title: creation.title,
                    startDate: creation.startDate,
                    durationMinutes: creation.durationMinutes)
            }
            let created = self.voiceCalendarEventWriter.create(
                title: event.title,
                startDate: event.startDate,
                durationMinutes: EventKitCalendarEventWriter.defaultDurationMinutes
            )
            DispatchQueue.main.async {
                self.finishCalendarEventWrite(event, created: created)
            }
        }
    }

    /// Shared tail of a confirmed calendar write. A REFUSED write (access
    /// vanished between the prompt and the save, or EventKit rejected it)
    /// gets the honest unavailable line — never a success claim. No
    /// PII event: only the outcome, and the event id hash never leaves
    /// the alert context in any case.
    private func finishCalendarEventWrite(_ event: PendingCalendarEvent, created: Bool) {
        guard created else {
            emitCalendarEvent(eventType: "command_calendar_event_write_failed",
                              outcome: "blocked")
            replyHonestly(key: "router.calendarEventCalendarUnavailable")
            return
        }
        let text = L10n.fmt("router.calendarEventCreated",
                            locale: activeLocale,
                            event.title,
                            SpokenTime.string(from: event.startDate, locale: activeLocale))
        setOutcome(icon: "calendar.badge.plus", text: text)
        speak(text: text)
        // [INTENTLOG-CAPTURE] The confirmed verdict is recorded on the
        // WRITE, not on the "yes": a confirmed event that EventKit
        // refused taught the system nothing (same rule the call path
        // holds for a failed open).
        appendCapture(event.capture, .confirmed)
        Task { await externalCalendar.rescan() }
    }

    /// Observability for the calendar-event write path. Metadata-free by
    /// construction (constitution C9): the event TITLE is user content
    /// and never reaches the bus.
    private func emitCalendarEvent(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "app_coordinator",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
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
        /// [INTENTLOG-CAPTURE] When the confirmation question was asked —
        /// the flywheel's latency start (question → verdict). Reset when
        /// a correction re-pends an amended action: the elder is being
        /// asked a NEW question, so the new question's clock is the one
        /// the answer belongs to.
        let requestedAt: Date = Date()

        /// This action's flywheel identity, for whichever verdict lands
        /// (confirmed / denied / corrected / timeout). The slots are the
        /// two values the confirmation question named (who, and through
        /// which app); the confidence is the interpreted command's — nil
        /// for a touch-originated action, which no interpreter produced.
        var capture: IntentLogStore.Capture {
            IntentLogStore.Capture(
                action: "call",
                slots: ["contact": contact.name, "method": method.rawValue],
                confidence: sourceCommand?.confidence,
                requestedAt: requestedAt)
        }
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
        // Flywheel gold (spec §11): original plan → corrected plan. The
        // capture is the ORIGINAL action's — the plan the elder rejected
        // — with the amendment in `correctedTo`, so its slots and its
        // confidence are the misheard interpretation's, which is exactly
        // the training pair the miner wants.
        appendCapture(action.capture, .corrected,
                      path: "override",
                      correctedTo: ["method": override.rawValue])
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
            recordActivity(kind: .call, channel: .phone,
                           contactName: action.contact.name,
                           phone: action.contact.phone)
        case .facetimeVideo, .facetimeAudio:
            let isVideo = action.method == .facetimeVideo
            switch callLinks.openFaceTime(handle: action.contact.phone, video: isVideo) {
            case .opened:
                setOutcome(icon: isVideo ? "video.fill" : "phone.fill",
                           text: L10n.fmt("home.outcome.callPlaced", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.calling", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
                contactNumberUsed(action.contact.phone)
                recordActivity(kind: .call,
                               channel: isVideo ? .faceTimeVideo : .faceTimeAudio,
                               contactName: action.contact.name,
                               phone: action.contact.phone)
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
            // The wa.me chat opened — a genuine MESSAGE surface (the only
            // one WhatsApp exposes to a deep link; see Channel.whatsapp).
            recordActivity(kind: .message, channel: .whatsapp,
                           contactName: action.contact.name,
                           phone: action.contact.phone)
        case .messengerAudio, .messengerVideo:
            switch callLinks.openMessengerThread(handle: action.contact.messengerHandle ?? "") {
            case .openedThread:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.messengerOpened", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
                // A call request resolves to the opened thread — recorded
                // honestly as the attempt it was (the app never claims a
                // Messenger "call"; no documented scheme can start one).
                recordActivity(kind: .call, channel: .messenger,
                               contactName: action.contact.name,
                               phone: action.contact.phone,
                               messengerHandle: action.contact.messengerHandle)
            case .fellBackToWeb:
                // Messenger app absent — the m.me chat opened in Safari
                // instead. A real surface appeared (the user CAN reach the
                // thread there), so the confirmed execution still teaches
                // the history — the disclosure is the speech, not silence.
                setOutcome(icon: "safari.fill",
                           text: L10n.fmt("home.outcome.messengerWebFallback", locale: locale, action.contact.name))
                speak(text: L10n.fmt("router.call.messengerWebFallback", locale: locale, action.contact.name))
                noteConfirmedCallExecution(action)
                // Same attempt recorded for the web surface that opened.
                recordActivity(kind: .call, channel: .messenger,
                               contactName: action.contact.name,
                               phone: action.contact.phone,
                               messengerHandle: action.contact.messengerHandle)
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
        appendCapture(action.capture, .confirmed)
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
                recordActivity(kind: .call, channel: .faceTimeVideo,
                               contactName: contact.name, phone: contact.phone)
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
            recordActivity(kind: .call, channel: .phone,
                           contactName: contact.name, phone: contact.phone)
        case .messenger:
            switch callLinks.openMessengerChat(phone: contact.phone) {
            case .openedApp:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.messenger", locale: locale, contact.name))
                recordActivity(kind: .call, channel: .messenger,
                               contactName: contact.name, phone: contact.phone,
                               messengerHandle: contact.messengerHandle)
            case .openedWebChat:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.messengerOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("call.announce.messengerWebFallback", locale: locale, contact.name))
                recordActivity(kind: .call, channel: .messenger,
                               contactName: contact.name, phone: contact.phone,
                               messengerHandle: contact.messengerHandle)
            case .invalidHandle:
                announceNoUsableNumber(contact: contact, locale: locale)
            }
        case .whatsApp:
            switch callLinks.openWhatsAppCallChat(contact.phone) {
            case .openedChat:
                setOutcome(icon: "message.fill",
                           text: L10n.fmt("home.outcome.whatsappOpened", locale: locale, contact.name))
                speak(text: L10n.fmt("router.call.whatsappOpened", locale: locale, contact.name))
                recordActivity(kind: .message, channel: .whatsapp,
                               contactName: contact.name, phone: contact.phone)
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
        recordActivity(kind: .call, channel: .phone,
                       contactName: name, phone: phone)
    }

    /// FaceTime re-initiation for a Recent activity row (call-history
    /// task, 2026-09-06): the row stored the number a FaceTime link
    /// opened before, and tapping it opens FaceTime again — the same
    /// genuine-open path performContactCall's faceTime case uses, with
    /// the same "record only a real open" rule.
    func performFaceTimeCall(name: String, phone: String, video: Bool) {
        let locale = activeLocale
        switch callLinks.openFaceTime(handle: phone, video: video) {
        case .opened:
            setOutcome(icon: video ? "video.fill" : "phone.fill",
                       text: L10n.fmt("home.outcome.callPlaced", locale: locale, name))
            speak(text: L10n.fmt("router.call.calling", locale: locale, name))
            contactNumberUsed(phone)
            recordActivity(kind: .call,
                           channel: video ? .faceTimeVideo : .faceTimeAudio,
                           contactName: name, phone: phone)
        case .unavailable, .invalidHandle:
            // Same honest line the tiles speak when FaceTime can't open.
            setOutcome(icon: "exclamationmark.triangle.fill",
                       text: L10n.str("router.call.facetimeUnavailable", locale: locale))
            speak(text: L10n.str("router.call.facetimeUnavailable", locale: locale))
        }
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
            recordActivity(kind: .message, channel: .whatsapp,
                           contactName: name, phone: phone)
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

    /// The Messenger handle the app captured for a book-row contact —
    /// `MessengerHandleStore`, keyed by the normalized phone (messenger-
    /// gate, 2026-09-07: the old capture prompt is gone; the Phone-tab
    /// redesign's add-handle sheet writes again via
    /// `storeMessengerHandle`). The Phone leaf's messenger pill and tap
    /// resolve it for book rows whose record itself carries no Facebook
    /// linkage. Nil when none was ever saved.
    func storedMessengerHandle(forNormalizedPhone normalized: String) -> String? {
        messengerHandleStore.handle(forNormalizedPhone: normalized)
    }

    /// Saves the Messenger handle a book-row contact's add-handle sheet
    /// captured (Phone-tab redesign, 2026-09-07). RE-ADDED: messenger-
    /// gate removed this when it deleted the old capture prompt; the
    /// redesign's sheet brings the write side back — a saved handle is
    /// what keeps the row's messenger pill and opens the real thread.
    /// The caller has already validated the username; this just persists
    /// via the encrypted `MessengerHandleStore` and returns whether the
    /// write landed.
    @discardableResult
    func storeMessengerHandle(_ handle: String, forNormalizedPhone normalized: String) -> Bool {
        messengerHandleStore.set(handle: handle, forNormalizedPhone: normalized)
    }

    /// The per-contact calling channel the Phone-tab row's channel
    /// chooser saved for an ADDRESS-BOOK row (Phone-tab redesign,
    /// 2026-09-07) — nil when the user never picked one (or the stored
    /// value is corrupt), in which case the row resolves to the global
    /// `defaultCallApp` via `resolvedCallChannel`.
    func storedChannelPreference(forNormalizedPhone normalized: String) -> CallApp? {
        channelPreferenceStore.preference(forNormalizedPhone: normalized)
    }

    /// Persists the row's channel-chooser pick for an ADDRESS-BOOK row
    /// (Phone-tab redesign, 2026-09-07). Returns whether the encrypted
    /// write landed — the chooser can surface a failed write honestly
    /// instead of silently showing a pick that won't survive relaunch.
    @discardableResult
    func setChannelPreference(_ app: CallApp, forNormalizedPhone normalized: String) -> Bool {
        channelPreferenceStore.set(app, forNormalizedPhone: normalized)
    }

    /// Messenger thread for a SYSTEM-address-book search row — the
    /// messenger analogue of `performSystemContactWhatsApp`, keyed on
    /// the person's Messenger handle (a row shows the pill only when a
    /// usable handle is on file — the row's own, or one the app
    /// captured earlier; see `storedMessengerHandle`). Same tap model
    /// and disclosures as `performContactCall`'s messenger case: the
    /// thread opens in-app when Messenger is installed, as the m.me web
    /// chat in Safari when it is not, and a missing handle opens nothing
    /// and says so. No recency entry.
    func performSystemContactMessenger(name: String, handle: String) {
        let locale = activeLocale
        switch callLinks.openMessengerThread(handle: handle) {
        case .openedThread:
            setOutcome(icon: "message.fill",
                       text: L10n.fmt("home.outcome.messengerOpened", locale: locale, name))
            speak(text: L10n.fmt("call.announce.messenger", locale: locale, name))
            noteSearchChannelTap(outcome: "messenger:openedThread")
            // A thread (chat) surface opened — recorded as the message
            // channel it is; no phone number rides on this API, the
            // handle is what re-opening needs.
            recordActivity(kind: .message, channel: .messenger,
                           contactName: name, messengerHandle: handle)
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

    // MARK: - Activity recording + live-call wiring (call-history task,
    // 2026-09-06)

    /// One line in the Recent activity log, per GENUINE channel open.
    /// Every call site pairs a `recordActivity` with the outcome branch
    /// that actually opened a surface — never with a failure branch:
    /// recording an open that didn't happen would lie about what the
    /// assistant did (the same honesty rule `contactNumberUsed` holds
    /// to). `timestamp` defaults to now and is overridden only by the
    /// unanswered-call path, which records the moment the live-call
    /// observer reported the call's end (missed-calls task, 2026-09-07).
    /// Called on the main queue only.
    private func recordActivity(kind: AppActivityEntry.Kind,
                                channel: AppActivityEntry.Channel,
                                contactName: String,
                                phone: String = "",
                                messengerHandle: String? = nil,
                                body: String? = nil,
                                timestamp: Date = Date()) {
        // Message text is stored only when it is non-blank (a pre-filled
        // draft is content; an empty compose sheet is not).
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedBody = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        activityLog.append(AppActivityEntry(timestamp: timestamp,
                                            kind: kind, channel: channel,
                                            contactName: contactName,
                                            phone: phone,
                                            messengerHandle: messengerHandle,
                                            body: storedBody))
        refreshRecentActivity()
    }

    /// Records one ANONYMOUS unanswered call — the coordinator side of
    /// the live-call detector's `onUnanswered` (missed-calls task,
    /// 2026-09-07). Fired when CXCallObserver reported a call that ended
    /// without ever connecting: a missed or declined incoming call, or
    /// an attempted outgoing call nobody picked up. iOS masks calls that
    /// involve other apps so completely that these are
    /// indistinguishable — this row claims only the shared fact, "a call
    /// ended unanswered". `contactName` and `phone` are EMPTY ON
    /// PURPOSE: the caller's identity AND number are masked by iOS —
    /// there is no name to store, no number to look up or dial, and no
    /// address-book match is possible — and the UI renders the localized
    /// "Unanswered call" label (`history.unanswered`) instead of a
    /// stored locale string. The row's action opens the Phone app
    /// (`PhoneAppOpener`), where the caller's identity genuinely lives
    /// (its Recents tab, one tap from the dialer).
    private func recordUnansweredCall(at timestamp: Date) {
        recordActivity(kind: .call, channel: .unanswered,
                       contactName: "", phone: "", timestamp: timestamp)
    }

    /// [CLOUD-CASCADE] (2026-09-16) Records one turn the cloud cascade tier
    /// sent to the ONLINE brain — the coordinator half of the tier's
    /// `onEscalated` seam, run once per escalated turn, right after the
    /// observability event and BEFORE the cloud call.
    ///
    /// Two trails, and neither one carries the utterance (C9 policy):
    ///  · an activity-log row (`Kind.cloudEscalation` / `Channel.cloud`)
    ///    with an EMPTY contact and number — the household can see that a
    ///    turn reached the cloud, and nothing about what was said;
    ///  · an app log line naming the escalation unmistakably, with the
    ///    provider id and the two scores only (the same numbers the
    ///    observability event carries — read this line and the
    ///    `cloud_cascade_escalated` event side by side to tell a
    ///    cloud-answered turn from an on-device one).
    ///
    /// Main queue by contract (the tier's completion runs there, like every
    /// other brain in the ladder → `recordActivity`'s rule).
    private func recordCloudCascadeEscalation(_ escalation: CloudCascadeEscalation) {
        recordActivity(kind: .cloudEscalation, channel: .cloud, contactName: "")
        // Numbers and a provider id only — never what the user said or what
        // the assistant answered (C9 policy; the same rule the
        // `cloud_cascade_escalated` event holds to). Note the Release-log
        // privacy gate (tools/check-release-log-safety.sh) rejects any
        // non-DEBUG print whose statement names the utterance's text, so
        // this line is deliberately vocabulary-clean.
        print("[cloud_cascade] LOCAL ANSWER OVERRULED — this turn goes to the ONLINE brain "
              + "provider=\(escalation.provider) "
              + "threshold=\(PipelineTraceSummary.score(escalation.threshold)) "
              + "local_confidence=\(PipelineTraceSummary.score(escalation.localConfidence)) "
              + "(numbers only — no utterance or reply content)")
    }

    /// Refreshes the published window from the store (see
    /// `recentActivity`). Main queue.
    private func refreshRecentActivity() {
        recentActivity = activityLog.entries()
    }

    /// Builds the live-call detector. Instance method (not a closure over
    /// `self` in the lazy declaration) so the closures can hold `self`
    /// weakly without capture-list gymnastics in a lazy initializer.
    /// Main queue by contract — CXCallStateProvider's delegate is
    /// `.main`, and `liveCallActive`/`recentActivity` are main-queue
    /// confined.
    private func makeLiveCallDetector() -> LiveCallDetector {
        let detector = LiveCallDetector(
            provider: CXCallStateProvider(),
            onChange: { [weak self] active in
                DispatchQueue.main.async { self?.liveCallActive = active }
            },
            onUnanswered: { [weak self] timestamp in
                // Record the anonymous unanswered row (missed-calls task,
                // 2026-09-07). Same main-hop rule as onChange: the store
                // is main-queue confined, whatever queue the provider
                // fired on.
                DispatchQueue.main.async { self?.recordUnansweredCall(at: timestamp) }
            }
        )
        // Initial state: a call already connected at launch must show on
        // the leaf immediately (the detector does not fire onChange for
        // its initial snapshot — that is exactly what this read is for).
        liveCallActive = detector.hasActiveCall
        return detector
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
        guard let plugin = pluginRegistry.plugin(handling: "nepali_calendar.query",
                                                 locale: activeLocale),
              geminiConfigStore.isConfigured else { return nil }
        // Screen-initiated call, not a voice turn: the contract's
        // transcript field is the sanitised utterance and stays empty
        // here — the question travels in the plugin's own entity.
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

    // MARK: - Calendar display (calendar-display task, 2026-09-09)

    /// The settings-driven "today" line for the Home top bar: the
    /// default calendar's date plus the enabled overlays (BS date while
    /// Gregorian is primary, tithi + paksha, and today's festival when
    /// one falls). The pure composition lives in `HomeDateLineComposer`;
    /// the coordinator publishes the composed result so the top bar and
    /// the Updates leaf share ONE computation. Refreshed on appear, on
    /// the day's rollover while Home is open, on foreground, and on
    /// every calendar-display setting change — all through
    /// `refreshHomeCalendarLineIfNeeded`, whose equality guard keeps the
    /// repeated re-checks publish-free.
    @Published private(set) var homeDateLine: HomeDateLineComposer.Line?

    /// The single-string form ("Sun, Sep 6, 2026 • भदौ २२, २०८३ • दशमी
    /// कृष्ण पक्ष") — the Updates leaf's Today row and
    /// `HomeWidgetDataSource` read this, exactly as before.
    var homeCalendarLine: String? { homeDateLine?.joined }

    /// UserDefaults load + first-run locale seeding for the calendar
    /// display settings (an injectable seam — see the store type).
    private let calendarDisplayStore: CalendarDisplaySettingsStore

    /// Which calendar the Home date line (and the calendar leaf's
    /// default reading) leads with. A UI preference, not a secret —
    /// house didSet persistence; a change recomposes the date line
    /// immediately. The init-time restore assigns directly (house
    /// pattern — didSet does not fire there).
    @Published var calendarDisplayDefault: CalendarDisplayDefault {
        didSet {
            guard calendarDisplayDefault != oldValue else { return }
            persistCalendarDisplaySettings()
            refreshHomeCalendarLineIfNeeded()
        }
    }

    /// "Nepali (BS) date overlay" toggle. Independent of the other two;
    /// under a Nepali primary the composer skips it (the BS date already
    /// IS the primary line — no duplicate). Same didSet contract as
    /// `calendarDisplayDefault`.
    @Published var showBSOverlay: Bool {
        didSet {
            guard showBSOverlay != oldValue else { return }
            persistCalendarDisplaySettings()
            refreshHomeCalendarLineIfNeeded()
        }
    }

    /// "Hindu tithi overlay" toggle. Same didSet contract as
    /// `calendarDisplayDefault`.
    @Published var showTithiOverlay: Bool {
        didSet {
            guard showTithiOverlay != oldValue else { return }
            persistCalendarDisplaySettings()
            refreshHomeCalendarLineIfNeeded()
        }
    }

    private func persistCalendarDisplaySettings() {
        calendarDisplayStore.save(CalendarDisplaySettings(
            defaultCalendar: calendarDisplayDefault,
            showBSOverlay: showBSOverlay,
            showTithiOverlay: showTithiOverlay))
    }

    /// Recomputes `homeDateLine` — fully OFFLINE (BikramSambat table +
    /// TithiCalculator astronomy + festival catalog): no network, no
    /// cost, correct every day. No-op while the composition is unchanged
    /// (same day, same settings, same locale). Callers: Home on appear +
    /// midnight rollover, Updates on appear, scene-foreground, and the
    /// calendar-display didSets.
    func refreshHomeCalendarLineIfNeeded() {
        let now = Date()
        let calendar = Calendar.current
        let overlay = festivalCalendar.todayOverlay(on: now, calendar: calendar)
        let settings = CalendarDisplaySettings(
            defaultCalendar: calendarDisplayDefault,
            showBSOverlay: showBSOverlay,
            showTithiOverlay: showTithiOverlay)
        let line = HomeDateLineComposer.line(
            on: now, calendar: calendar, settings: settings,
            locale: activeLocale,
            festivalName: overlay?.festivals.first?.nameNepali)
        guard line != homeDateLine else { return }
        homeDateLine = line
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

    // MARK: - Contact-search requests (voice-contact-search, 2026-09-07)

    /// A voice command routed to contact search ("मैयाको फोन नम्बर खोज" —
    /// `VoiceContactSearchRoute`). HomeView observes the `id` and pushes
    /// the Phone leaf; the leaf consumes the query via
    /// `takePendingContactSearchRequest` and runs the search so results
    /// (incl. WhatsApp/Messenger badges) are on screen, zero-touch.
    /// Nothing is spoken here — the leaf announces the outcome.
    struct ContactSearchRequest: Identifiable, Equatable {
        let id = UUID()
        let query: String?
    }
    @Published var pendingContactSearchRequest: ContactSearchRequest?

    /// `VoiceCommandCoordinating.requestContactSearch`. Publishes a
    /// fresh request — safe from any queue (observable mutation is
    /// pinned to main, H1). A repeated utterance while one request is
    /// still pending replaces it; the leaf consumes whatever is newest.
    func requestContactSearch(query: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingContactSearchRequest = ContactSearchRequest(query: query)
        }
    }

    /// Consumes and clears the pending request — called by the Phone
    /// leaf once it has applied the query, so a stale request can never
    /// push a second Phone screen. Main queue only (observable mutation).
    func takePendingContactSearchRequest() -> ContactSearchRequest? {
        let request = pendingContactSearchRequest
        pendingContactSearchRequest = nil
        return request
    }

    // MARK: - Voice-driven navigation (directions task, 2026-09-07)

    /// A navigation session awaiting sheet presentation — ContentView
    /// renders it, same pattern as `pendingPluginPresentation`. The
    /// session is created FRESH per request (its fetcher/geocoder/
    /// calculator seams are all one-request-per-instance) and is
    /// `@MainActor`-isolated, so it is born inside the main-queue hop
    /// below.
    struct NavigationPresentation: Identifiable {
        let id = UUID()
        let session: InAppNavigationSession
    }
    @Published var pendingNavigationPresentation: NavigationPresentation?

    /// The ambiguity walk's remaining candidates, top-scored first
    /// (`DirectionsRoute` already sorted them). While non-empty, the
    /// router treats the next transcript as the yes/no answer — see
    /// `handleConfirmationResponse`'s navigation branch. Mutually
    /// exclusive with the other pending confirmations by construction
    /// (the directions stage only runs while nothing else is pending).
    private var pendingNavigationWalk: [DirectionsCandidate] = []

    /// `VoiceCommandCoordinating.navigationCandidates` — every saved
    /// place and every family contact that carries a NON-EMPTY address
    /// (blank text was stored as nil by `normalizedOptionalText`; the
    /// decider re-filters defensively anyway). Address-less entries are
    /// deliberately absent: the pipeline never promises a route it
    /// cannot draw.
    var navigationCandidates: [DirectionsCandidate] {
        var candidates: [DirectionsCandidate] = []
        for place in savedPlaces where !place.address.isEmpty {
            candidates.append(DirectionsCandidate(id: place.id, source: .savedPlace,
                                                  name: place.name, address: place.address,
                                                  relationship: nil))
        }
        for contact in familyContacts {
            guard let address = contact.address, !address.isEmpty else { continue }
            candidates.append(DirectionsCandidate(id: contact.id, source: .familyContact,
                                                  name: contact.name, address: address,
                                                  relationship: contact.relationship))
        }
        return candidates
    }

    /// `VoiceCommandCoordinating.isAwaitingNavigationDisambiguation`.
    var isAwaitingNavigationDisambiguation: Bool { !pendingNavigationWalk.isEmpty }

    /// `VoiceCommandCoordinating.requestNavigationDisambiguation` — pends
    /// the walk and returns the FIRST candidate's localized yes/no
    /// question for the router to speak. Subsequent candidates are asked
    /// by `handleConfirmationResponse` as the walk proceeds; an exhausted
    /// walk speaks the honest `directions.cancelled` line.
    func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? {
        guard let first = targets.first else { return nil }
        pendingNavigationWalk = targets
        DispatchQueue.main.async { [weak self] in
            self?.voiceSession.transition(to: .awaitingConfirmation)
        }
        return navigationQuestion(for: first)
    }

    /// The yes/no question the ambiguity walk asks for one candidate —
    /// shape matches the call-confirmation prompts ("के … लैजाने?") and
    /// ends with the answer hint so the elder knows yes/no is expected.
    private func navigationQuestion(for candidate: DirectionsCandidate) -> String {
        L10n.fmt("directions.disambiguateAsk", locale: activeLocale, candidate.name)
    }

    /// `VoiceCommandCoordinating.requestNavigation` — a resolved
    /// navigation request (router already decided; nothing is pended).
    func requestNavigation(to target: DirectionsRoute.PlaceTarget) {
        executeNavigation(to: target)
    }

    // MARK: - Touch wrappers for the Directions leaf (directions-screen
    // task, 2026-09-07)

    /// Navigates to the saved place with `id` — thin named surface for
    /// the Directions leaf's जाऊ buttons. Delegates straight into the
    /// shared navigation executor (`requestNavigation`), so map-app
    /// policy, geocode/open fallbacks, in-app presentation and the
    /// honest spoken lines all stay owned in exactly one place; a
    /// missing id resolves honestly (`directions.placeNotFound`) instead
    /// of dead-ending.
    func navigateToPlace(id: UUID) {
        requestNavigation(to: .place(id))
    }

    /// Navigates to the family contact with `id` — thin named surface
    /// for the Directions leaf's जाऊ buttons (same single-executor
    /// rule as `navigateToPlace(id:)`).
    func navigateToFamilyContact(id: UUID) {
        requestNavigation(to: .familyContact(id))
    }

    /// Drives to the default home — thin named surface for the "take me
    /// home" path every caller reaches for by name. With no `.home`
    /// place saved the executor speaks the honest `directions.noHome`
    /// fallback.
    func navigateHome() {
        requestNavigation(to: .defaultHome)
    }

    /// Navigates to a free-form event's address — the detail screen's Go
    /// button (rich-events task, 2026-09-17; design §4), and the route a
    /// fired reminder's Open action leads into.
    ///
    /// A free-form event has no saved-place id, so — unlike the three
    /// wrappers above — this one carries the name and address straight
    /// into the shared executor. That is the whole feature: geocoding at
    /// TAP time, map-app policy, the in-app fallback and the honest
    /// spoken lines all stay `launchNavigation`'s, already built and
    /// already audited, so an event behaves exactly like a saved place.
    /// Nothing is stored: whatever the family last corrected in their own
    /// Calendar app is what gets geocoded.
    func navigateToEvent(_ event: FreeFormEvent) {
        guard let address = event.address?
            .trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            // The Go button is not even drawn without an address, so this
            // is only reachable by a race — the family cleared the
            // address while the screen was open. Honest line, no dead end.
            emitDirections(eventType: "command", outcome: "place_missing")
            replyHonestly(key: "directions.placeNotFound")
            return
        }
        launchNavigation(name: event.title, address: address)
    }

    /// The core navigation executor — shared by `requestNavigation` and
    /// the ambiguity walk's yes branch. Resolves the target to a concrete
    /// destination, then launches the map surface the current override
    /// + installed-ness picks. Every resolution failure speaks an honest
    /// visible line — never a silent no-op.
    private func executeNavigation(to target: DirectionsRoute.PlaceTarget) {
        let destination: (name: String, address: String)
        switch target {
        case .defaultHome:
            guard let home = placeStore.defaultHome else {
                emitDirections(eventType: "command", outcome: "no_home")
                replyHonestly(key: "directions.noHome")
                return
            }
            destination = (home.name, home.address)
        case .place(let id):
            guard let place = savedPlaces.first(where: { $0.id == id }) else {
                emitDirections(eventType: "command", outcome: "place_missing")
                replyHonestly(key: "directions.placeNotFound")
                return
            }
            destination = (place.name, place.address)
        case .familyContact(let id):
            guard let contact = familyContacts.first(where: { $0.id == id }) else {
                emitDirections(eventType: "command", outcome: "place_missing")
                replyHonestly(key: "directions.placeNotFound")
                return
            }
            destination = (contact.name, contact.address ?? "")
        }
        guard !destination.address.isEmpty else {
            // A candidate with an empty address can only have raced a
            // concurrent edit — resolve honestly, never dead-end.
            emitDirections(eventType: "command", outcome: "place_missing")
            replyHonestly(key: "directions.placeNotFound")
            return
        }
        launchNavigation(name: destination.name, address: destination.address)
    }

    /// Picks the map surface and opens it. The probe-based resolve never
    /// returns a surface that cannot open: `.auto`/override falls
    /// through Google → Apple → the in-app map, and `.inApp` needs no
    /// external app at all — so the walk always terminates somewhere
    /// real.
    private func launchNavigation(name: String, address: String) {
        let locale = activeLocale
        let resolved = NavigationMapPolicy.resolve(
            override: navigationMapApp,
            googleMapsInstalled: canOpenURLOnMain(MapsLinks.googleMapsProbeURL),
            appleMapsInstalled: canOpenURLOnMain(MapsLinks.appleMapsProbeURL)
        )
        switch resolved {
        case .googleMaps:
            emitDirections(eventType: "launch", outcome: "googleMaps")
            setOutcome(icon: "map.fill",
                       text: L10n.fmt("directions.outcome.opening", locale: locale, name))
            speak(text: L10n.fmt("directions.openingGoogleMaps", locale: locale, name))
            openExternalNavigation(app: .googleMaps, name: name, address: address)
        case .appleMaps:
            emitDirections(eventType: "launch", outcome: "appleMaps")
            setOutcome(icon: "map.fill",
                       text: L10n.fmt("directions.outcome.opening", locale: locale, name))
            speak(text: L10n.fmt("directions.openingAppleMaps", locale: locale, name))
            openExternalNavigation(app: .appleMaps, name: name, address: address)
        case .inApp:
            emitDirections(eventType: "launch", outcome: "inApp")
            speak(text: L10n.fmt("directions.openingInApp", locale: locale, name))
            presentInAppNavigation(name: name, address: address)
        case .auto:
            return   // resolve never returns .auto — it always falls through
        }
    }

    /// External map app: forward-geocode the address to coordinates
    /// FIRST (both map apps take a coordinate `daddr` reliably), then
    /// open the coordinate URL. Geocode failure is an honest degradation,
    /// never a dead end: Apple Maps opens the address STRING (it resolves
    /// address text well) and Google Maps gets the same documented
    /// fallback form.
    private func openExternalNavigation(app: NavigationMapApp, name: String, address: String) {
        // The Google surface's `hl` deep-link ask carries the app's active
        // language — "ne" under Nepali, "en" under English — resolved from
        // the same locale every user-facing string uses, once per launch.
        // Apple Maps' scheme exposes no language parameter (its UI follows
        // the device and Maps' own settings — nothing to send, and none is
        // invented), so this code feeds the Google builders only.
        let mapsUILanguageCode = activeLocale.languageCode ?? appLanguage.rawValue
        let geocoder = NavigationGeocoder()
        geocoder.geocode(address: address) { [weak self] result in
            guard let self else { return }
            let url: URL?
            switch result {
            case .success(let destination):
                self.emitDirections(eventType: "geocode", outcome: "ok")
                url = MapsLinks.directionsURL(for: app,
                                              latitude: destination.latitude,
                                              longitude: destination.longitude,
                                              uiLanguageCode: mapsUILanguageCode)
            case .failure:
                self.emitDirections(eventType: "geocode", outcome: "fallback_address")
                url = app == .appleMaps
                    ? MapsLinks.appleMapsDirectionsURL(address: address)
                    : MapsLinks.googleMapsWalkingNavigateURL(address: address,
                                                            uiLanguageCode: mapsUILanguageCode)
            }
            guard let url else {
                // No URL at all (both builders refused the input) — say
                // so honestly; the in-app map is the standing fallback.
                self.emitDirections(eventType: "open", outcome: "map_missing")
                self.replyHonestly(key: "directions.mapMissing")
                return
            }
            // The geocoder delivers on the main queue — the probe was
            // already done; this open is the same main-bound UIApplication
            // hop the call/message flows use.
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
    }

    /// The in-app MapKit fallback sheet (static route — no live
    /// re-routing, plan constraint). A fresh `LocationFetcher` +
    /// `NavigationGeocoder` + `MapKitDirectionsCalculator` are born with
    /// the session (all one-request-per-instance), the app's speaker is
    /// handed over for the spoken steps, and ContentView's sheet renders
    /// the session. Created on the main actor: `CLLocationManager` must
    /// be born on the main thread (delegate runloop rule).
    private func presentInAppNavigation(name: String, address: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let session = InAppNavigationSession(
                destinationName: name,
                destinationAddress: address,
                locationFetcher: LocationFetcher(),
                geocoder: NavigationGeocoder(),
                directionsCalculator: MapKitDirectionsCalculator(),
                speaker: self.speaker ?? NullSpeaker(),
                locale: self.activeLocale
            )
            self.pendingNavigationPresentation = NavigationPresentation(session: session)
        }
    }

    /// Honest visible fallback lines (noHome / placeNotFound /
    /// mapMissing / cancelled): carded AND spoken, same dual-channel
    /// delivery the router's `speakWithVisibleOutcome` uses — the
    /// live-caption pill is gone by the time these land.
    private func replyHonestly(key: String) {
        let text = L10n.str(key, locale: activeLocale)
        guard !text.isEmpty else { return }
        noteGenericReply(text)
        speak(text: text)
    }

    /// `directions` observability events — every navigation outcome that
    /// matters is observable; no metadata keys are attached, so nothing
    /// user-identifying (names, addresses, coordinates) ever reaches the
    /// bus (constitution C9).
    private func emitDirections(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "directions",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
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
        presentPluginView(AnyView(ApplianceHelperView(session: session,
                                                      labelCache: labelTranslationCache)))
    }

    /// Opens a bundled default manual from the Settings → Manuals leaf.
    /// The session is armed already in `.guidance`, so the presented
    /// sheet renders the manual's step cards immediately and never shows
    /// the camera-capture state (ApplianceHelperView's auto-open camera is
    /// gated on `.capturing`). Not gated on `geminiClient.isAvailable` —
    /// unlike `presentApplianceHelper`, bundled content must work first
    /// launch, offline, with no key configured.
    ///
    /// Returns false when the manual's overview image is unavailable — the
    /// caller stays on the browse list and shows an honest failure.
    @MainActor
    func presentBundledManual(_ manual: BundledManual) -> Bool {
        let session = ApplianceHelperSession(question: nil,
                                             locale: activeLocale,
                                             geminiClient: geminiClient,
                                             cache: ApplianceCache(storage: storage),
                                             observabilityBus: observabilityBus,
                                             speaker: speaker)
        guard session.presentBundledManual(manual, locale: activeLocale) else { return false }
        presentPluginView(AnyView(ApplianceHelperView(session: session,
                                                      labelCache: labelTranslationCache)))
        return true
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
                // The WhatsApp chat with the pre-filled body opened — a
                // genuine message surface (FR-049 completeness: the
                // send_message path is an assistant action like any other).
                recordActivity(kind: .message, channel: .whatsapp,
                               contactName: contact.name, phone: contact.phone,
                               body: body)
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
    /// sheet, same outcome line, no `FamilyContact` required. Internal
    /// since call-history task, 2026-09-06: the Recent activity leaf's
    /// SMS rows re-open drafts through this entry point.
    func presentMessageDraft(phone: String, name: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingMessageDraft = MessageDraft(recipients: [phone], body: body)
            // The compose sheet IS a genuine open of the SMS channel
            // (call-history task, 2026-09-06) — recorded inside this
            // block so the row lands after the sheet is actually up.
            // `recordActivity` prunes blank bodies itself.
            self?.recordActivity(kind: .message, channel: .sms,
                                 contactName: name, phone: phone,
                                 body: body)
        }
        setOutcome(icon: "message.fill",
                   text: L10n.fmt("home.outcome.messageReady", locale: activeLocale, name))
    }

    // MARK: - Medication schedule surface (spec §4.3, §4.4.3)

    /// Reminders currently waiting (pending or fired, not yet completed).
    var pendingReminders: [ScheduledReminder] { medicationScheduler.pendingReminders }

    /// Configured medication entries — read-only view for the Settings
    /// editor and the Medical leaf (the renamed Meds leaf, medical task
    /// 2026-09-07).
    var medicationEntries: [MedicationEntry] { medicationScheduler.medicationEntries() }

    func medicationName(for entryId: UUID) -> String {
        medicationScheduler.medicationEntries()
            .first { $0.id == entryId }?
            .medicationName ?? ""
    }

    /// One medication entry by id (medication-visual-aids task,
    /// 2026-09-16) — the Settings photo editor and the Reminders leaf read
    /// an entry's photos through this. Nil when the entry is gone.
    func medicationEntry(for entryId: UUID) -> MedicationEntry? {
        medicationScheduler.medicationEntry(for: entryId)
    }

    /// A medication entry's photos, snapshotted for presentation — the
    /// tap-to-view paths (the Meds leaf's dose thumbnail, the Reminders
    /// leaf's dose rows) share the fired-dose screen's presentation type,
    /// so all three draw the same screen from the same values. Nil when
    /// the entry is gone or carries no photos, which is also the answer to
    /// "is there anything to tap": callers gate the thumbnail on this, not
    /// on a separate `isEmpty` check that could drift from it.
    func medicationVisualAidsPresentation(for entryId: UUID)
        -> MedicationVisualAidsPresentation? {
        guard let entry = medicationEntry(for: entryId),
              !entry.visualAids.isEmpty else { return nil }
        return MedicationVisualAidsPresentation(entry: entry)
    }

    // MARK: - Derived notification count ([BOOT-REVIEW P1-7])

    /// The bell badge's derived count — how many notification rows the
    /// Updates leaf lists — published as STORED state.
    ///
    /// The row-presence inputs are exactly two (`HomeWidgetRegistry`'s
    /// built-ins): `todayBriefing` (`TodayBriefingWidget`) and
    /// `pendingReminders` (`MedsStatusWidget`, "X of Y doses taken
    /// today"). The count is therefore recomputed ONLY from the seams that
    /// move one of those — medication schedule edits, dose
    /// acknowledgements, routine/native-calendar mutations, a stored
    /// briefing landing, the boot restore, and the calendar-day rollover
    /// ("today's doses" is date-dependent). It is deliberately NOT
    /// recomputed on unrelated invalidations (feed translation, download
    /// progress, voice timing, settings toggles), so a view that reads
    /// this value does not re-filter/re-sort widget rows per render the
    /// way a live computation must.
    ///
    /// The seam is `refreshActiveNotificationCount()`; nothing else writes
    /// this property, and an unchanged recomputation does not publish.
    @Published private(set) var activeNotificationCount: Int = 0

    /// Registry used for the derivation. Stateless widgets — HomeView
    /// keeps its own registry for the leaf's rows, and both derive the
    /// same list from the same state.
    private lazy var notificationCountRegistry = HomeWidgetRegistry()

    /// Day-rollover observer: "today's doses" changes at midnight with no
    /// mutation to hang off, so the derived count would otherwise go
    /// stale until the next reminder edit.
    private var dayChangeObserver: NSObjectProtocol?

    /// Recomputes + publishes the derived count. Main-confined by
    /// contract (it reads main-confined coordinator state and publishes);
    /// callers on the voice/acknowledgement paths hop here first. An
    /// unchanged result is a no-op, so repeated calls are free.
    ///
    /// The derivation itself lives on `HomeWidgetRegistry` and is
    /// `@MainActor` (it builds view-facing rows) — one source of truth with
    /// the Updates leaf, which is the whole point of this seam. Reaching it
    /// from this nonisolated, main-confined method therefore costs ONE
    /// main-actor turn: the count is derived UI state that nothing latches
    /// on synchronously, and the mutation the call follows is already
    /// published by the caller, so the badge simply lands in the same
    /// frame's update cycle.
    func refreshActiveNotificationCount() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshActiveNotificationCount()
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let source: any HomeWidgetDataSource = self
            let next = self.notificationCountRegistry.activeNotificationCount(
                coordinator: source)
            guard next != self.activeNotificationCount else { return }
            self.activeNotificationCount = next
        }
    }

    /// Installs the day-rollover refresh. Called from `start()` — never
    /// from `init()` (a notification observer is startup work with no
    /// first-frame value).
    private func observeCalendarDayChange() {
        guard dayChangeObserver == nil else { return }
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshActiveNotificationCount()
        }
    }

    /// [T-037-a] Level-2 memory warning → release the intent encoder's
    /// CoreML weights. Installed only on an `INTENT_ENCODER` build, so a
    /// normal build adds no observer and touches no encoder object.
    ///
    /// Release is one half of the contract; the other half is the re-arm
    /// in `handlePipelineState(.capturingCommand)`: the NEXT voice turn
    /// clears the hold and the first `interpret()` reloads the weights
    /// from ModelStore on its own queue — never on the main thread, and
    /// never a crash from a stale handle.
    private func observeIntentEncoderMemoryPressure() {
        guard IntentEncoderFeature.isEnabled, intentEncoderMemoryObserver == nil else {
            return
        }
        intentEncoderMemoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleIntentEncoderMemoryPressureIfEnabled()
        }
    }

    /// [ENCODER-RUNTIME-TOGGLE] The observer is installed once (under the
    /// compile gate) and this body decides whether the message applies: an
    /// encoder that was never offered holds nothing, and must not be
    /// CONSTRUCTED just to find that out — but one that a tester switched
    /// on and then off is still resident and must release.
    private func handleIntentEncoderMemoryPressureIfEnabled() {
        guard IntentEncoderFeature.isEnabled, intentEncoderOffered else { return }
        intentEncoderInterpreter.handleMemoryPressure()
    }

    // MARK: - Model lifecycle ([MODEL-LIFECYCLE])

    /// Level-2 observer for the residency ledger.
    ///
    /// Installed unconditionally, unlike the encoder's gate-scoped observer
    /// below: the models it evicts (STT, the brain) are in EVERY build, so
    /// a build without the internal-testing encoder gate still needs the
    /// OOM protection. Two observers on the same notification is fine —
    /// the encoder's handler releases only the encoder, and the manager
    /// leaves light slots alone, so neither can undo the other.
    private func observeModelLifecycleMemoryPressure() {
        guard modelLifecycleObserver == nil else { return }
        modelLifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            ModelLifecycleManager.shared.handleMemoryPressure()
        }
    }

    /// Registers the slots the coordinator itself owns and starts the idle
    /// sweep. The heavy slots (STT, brain) register themselves at their own
    /// load sites, because a slot must describe the engine that is actually
    /// about to load.
    private func startModelLifecycle() {
        let lifecycle = ModelLifecycleManager.shared
        observeModelLifecycleMemoryPressure()

        // The encoder slot is NOT registered here. `intentEncoderInterpreter`
        // is a `lazy var` built only when the encoder gate AND the runtime
        // toggle both allow it, and touching it here would defeat that gate
        // by constructing the object in every launch. `installLocalBrainSlot`
        // registers it at the moment `gatedEncoder` actually resolves it —
        // see `registerEncoderSlotIfNeeded()`.

        // The corrector is NOT a model — it is a ~2.6 MB JSON lexicon in a
        // process-wide `static let`. Registered ownerless and un-evictable
        // so the ledger's total is honest and the next reader does not have
        // to rediscover that.
        lifecycle.register(
            slot: .sttCorrector,
            modelID: nil,
            owner: nil,
            evictable: false
        ) {}

        // [TRUNCATION-FIX] Bridge the ledger's decisions to the
        // observability bus — `onEvent` used to be assigned only in
        // tests, so a field capture of the "दशैँ कहिले हो" kill showed
        // no trace of which model was evicted or admitted.
        lifecycle.onEvent = { [weak self] event in
            self?.relayModelLifecycleEvent(event)
        }

        lifecycle.startIdleTimer()

        // [MODEL-WARDEN] Step 0 — the kernel's own pressure signal, alongside
        // `didReceiveMemoryWarning`. `.warning` routes to the existing
        // squeeze; `.critical` additionally cancels every pending reservation
        // and evicts the light residents the squeeze spares.
        //
        // The three residents Step 0 brings into the ledger — the TTS voice
        // cache, the wake-word spotter, the VAD — are NOT registered here:
        // each registers at the object that actually allocates it
        // (`PiperVoiceSpeaker`, `SherpaKWSWakeWordEngine`, `SileroONNXVAD`),
        // the same convention the heavy slots already follow, so a row only
        // exists while the bytes it describes do. Registering the shipped
        // `EnergyVAD` here, for instance, would add 0.9 MB of Silero ONNX
        // bytes the build does not hold — the ledger's total has to stay
        // checkable against `phys_footprint`.
        lifecycle.startMemoryPressureMonitor()
    }

    /// Observability bridge for `ModelLifecycleEvent` — component
    /// "model_lifecycle", one event type per decision, metadata carries
    /// the slot/reason/bytes.
    private func relayModelLifecycleEvent(_ event: ModelLifecycleEvent) {
        let type: String
        let metadata: [String: String]
        switch event {
        case .admitted(let slot, let liveBytes, let evicted):
            type = "admitted"
            metadata = ["slot": slot.rawValue,
                        "liveBytes": String(liveBytes),
                        "evicted": evicted.map(\.rawValue).joined(separator: ",")]
        case .denied(let slot, let reason):
            type = "denied"
            metadata = ["slot": slot.rawValue, "reason": reason.rawValue]
        case .evicted(let slot, let reason):
            type = "evicted"
            metadata = ["slot": slot.rawValue, "reason": reason.rawValue]
        case .soloOverBudget(let slot, let liveBytes, let budgetBytes):
            type = "solo_over_budget"
            metadata = ["slot": slot.rawValue,
                        "liveBytes": String(liveBytes),
                        "budgetBytes": String(budgetBytes)]
        case .memoryPressure(let budgetBytes, let evicted):
            type = "memory_pressure"
            metadata = ["budgetBytes": String(budgetBytes),
                        "evicted": evicted.map(\.rawValue).joined(separator: ",")]
        // [MODEL-WARDEN] Step 1 — the reservation layer. Every value below is
        // a slot name, a closed token or a byte count; nothing here can carry
        // content, and every key is in `LogSanitiser.allowedKeys` (a test
        // pins that claim, because a silently dropped key is how the memory
        // story arrived at the field with no bytes in it the first time).
        case .reserved(let slot, let liveBytes, let purpose, let isLargeLoad):
            type = "reserved"
            metadata = ["slot": slot.rawValue,
                        "liveBytes": String(liveBytes),
                        "purpose": purpose.rawValue,
                        "isLargeLoad": String(isLargeLoad)]
        case .reservationDenied(let slot, let reason, let purpose):
            type = "reservation_denied"
            metadata = ["slot": slot.rawValue,
                        "reason": reason.token,
                        "purpose": purpose.rawValue]
        case .reservationCommitted(let slot, let heldSeconds):
            type = "reservation_committed"
            metadata = ["slot": slot.rawValue,
                        "heldSeconds": String(format: "%.2f", heldSeconds)]
        case .reservationAbandoned(let slot, let reason):
            type = "reservation_abandoned"
            metadata = ["slot": slot.rawValue, "reason": reason.rawValue]
        case .footprintSample(let physFootprintBytes, let ceilingBytes,
                              let residentLiveBytes, let transientLiveBytes):
            type = "footprint_sample"
            metadata = ["phys_footprint": String(physFootprintBytes),
                        "ceiling_bytes": String(ceilingBytes),
                        "liveBytes": String(residentLiveBytes),
                        "transientLiveBytes": String(transientLiveBytes)]
        }
        observabilityBus.emit(ObservabilityEvent(
            component: "model_lifecycle",
            eventType: type,
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: metadata
        ))
    }

    /// Declares the encoder's ledger row the first time the encoder is
    /// actually constructed. Idempotent — `register` overwrites the slot's
    /// footprint and closure, so calling it again on a re-install is
    /// harmless.
    ///
    /// The encoder is LIGHT (≈ 140 MB) and already has a complete
    /// unload/re-arm contract of its own, so it is registered for the
    /// ledger's sake but excluded from eviction — its residency is the
    /// [T-037-a] observer's business, and routing it through the idle sweep
    /// would trip the pressure flag on a timer.
    private func registerEncoderSlotIfNeeded() {
        ModelLifecycleManager.shared.register(
            slot: .intentEncoder,
            modelID: ModelCatalog.intentEncoderSpike,
            owner: intentEncoderInterpreter,
            evictable: false
        ) { [weak intentEncoderInterpreter] in
            intentEncoderInterpreter?.handleMemoryPressure()
        }
    }

    /// Re-arms the encoder after a memory-pressure unload at the start of
    /// a voice turn (no-op unless the internal-testing gate is on AND the
    /// runtime toggle is ON, so the lazy encoder object is never even
    /// constructed otherwise).
    private func rearmIntentEncoderIfEnabled() {
        guard IntentEncoderFeature.isEnabled, intentEncoderEnabled else { return }
        intentEncoderInterpreter.rearmAfterMemoryPressure()
    }

    /// Adds or validates a medication schedule entry from the Settings
    /// editor. Returns a catalog key on validation failure, nil on success.
    /// Success persists via `loadSchedule` and re-arms alarms (spec §4.4.3).
    ///
    /// `purpose` ([MED-PURPOSE], 2026-09-17) is what the medicine is for —
    /// a `MedicationPurpose` chip id or the family's own words, exactly as
    /// `MedicationPurposeDraft.storedValue` resolved it. Defaulted nil so
    /// every pre-purpose caller (the voice `set_reminder` path, every test
    /// fixture) keeps compiling and keeps creating the entry it always
    /// did; blank is normalized to nil rather than stored as an empty
    /// string, the same rule `normalizedOptionalText` applies everywhere
    /// else in this file.
    @discardableResult
    func addMedication(name: String, time: DateComponents,
                       purpose: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "settings.meds.nameRequired" }
        let duplicate = medicationScheduler.medicationEntries().contains { entry in
            entry.medicationName == trimmed && entry.scheduleTimes.contains(time)
        }
        guard !duplicate else { return "settings.meds.duplicateError" }
        let trimmedPurpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines)

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
            confirmationDescription: nil,
            purpose: (trimmedPurpose?.isEmpty ?? true) ? nil : trimmedPurpose
        )
        entries.append(entry)
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
        calendarSync.syncNow(entries: routineScheduler.entries())
        // [BOOT-REVIEW P1-7] A schedule edit changes today's dose total —
        // one of the count's two inputs.
        refreshActiveNotificationCount()
        return nil
    }

    /// Removes a medication entry and re-arms (spec §4.4.3).
    func removeMedication(id: UUID) {
        var entries = medicationScheduler.medicationEntries()
        entries.removeAll { $0.id == id }
        medicationScheduler.loadSchedule(entries: entries)
        medicationScheduler.scheduleAll()
        // The dose's photos go WITH the medication (medication-visual-aids
        // task, 2026-09-16): a picture of a box the household no longer
        // takes must not outlive the entry, and nothing else can find
        // those files afterwards. Same rule the routine scheduler applies
        // when a reminder is removed.
        medicationVisualAidStore.deleteAll(for: id)
        calendarSync.syncNow(entries: routineScheduler.entries())
        // [BOOT-REVIEW P1-7] Removing an entry can empty today's doses —
        // the row hides itself, so the count must follow.
        refreshActiveNotificationCount()
    }

    // MARK: - Doctor's appointments (medical task, 2026-09-07)

    /// Adds an appointment from the Medical leaf's add form or the
    /// paste-confirmation flow. Blank labels are stored as nil via
    /// `normalizedOptionalText` (house rule — blank text is not stored);
    /// the store rejects the write at its cap (50) and returns false.
    /// Success persists, refreshes the published list (newest first),
    /// and — when the calendar toggle is on — hands the appointment to
    /// the `MedicalAppointmentCalendarWriting` seam inside the store.
    @discardableResult
    func addAppointment(doctorOrPlace: String, place: String?, date: Date,
                        note: String?) -> Bool {
        let trimmed = doctorOrPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let appointment = MedicalAppointment(
            doctorOrPlace: trimmed,
            place: Self.normalizedOptionalText(place),
            date: date,
            note: Self.normalizedOptionalText(note)
        )
        guard appointmentStore.add(appointment) else { return false }
        self.appointments = appointmentStore.load()
        return true
    }

    /// Removes an appointment from the Medical leaf (store-remove; the
    /// calendar-2way seam mirrors the removal when the toggle is on).
    func removeAppointment(id: UUID) {
        appointmentStore.remove(id: id)
        self.appointments = appointmentStore.load()
    }

    /// Dismisses the one-shot SMS caption on the Medical leaf; persisted
    /// so it never nags again (the store keeps the truth; this is a
    /// preference).
    func dismissAppointmentSmsNote() {
        appointmentSmsNoteDismissed = true
    }

    // MARK: - Free-form events (rich-events task, 2026-09-17; design §2)

    /// The household's own events — the ones that are neither a routine
    /// nor a medication ("डाक्टर भेट, मंगलबार ११ बजे").
    ///
    /// The app owns no event store for these: a free-form event IS a
    /// native `EKEvent` in the default calendar (design §1 decision 4),
    /// so the family's Calendar app, the app's own import, the reminder
    /// that fires and the Google bridge all see the same event, and a
    /// family edit is simply an edit. `FreeFormEventService` is the thin
    /// read/write face over EventKit plus the encrypted side index that
    /// holds the ONE field the platform cannot (`EventExtrasStore` →
    /// `EventExtras.photoFilename`).
    ///
    /// LAZY like the calendar services around it: constructing it opens
    /// an `EKEventStore` and reads one encrypted payload, so it belongs
    /// off the launch path. Nothing here requests permission — the Events
    /// screens ask through the same EventKit prompt every other calendar
    /// surface uses, and a denial reads as an empty list, never a crash.
    private(set) lazy var freeFormEventService = FreeFormEventService(
        extras: EventExtrasStore(storage: storage),
        observability: observabilityBus
    )

    /// The Events leaf's list: the app's own events, soonest first.
    /// Loaded from the leaf's `.task`, never its `body` — every row is an
    /// EventKit fetch (see the service's note).
    func freeFormEvents() -> [FreeFormEvent] {
        freeFormEventService.upcoming()
    }

    /// One event for the detail screen, or nil when it is gone (deleted
    /// here, or by the family in their own Calendar app).
    func freeFormEvent(id: String) -> FreeFormEvent? {
        freeFormEventService.event(withId: id)
    }

    /// The event's photo, or nil when it has none. Read through the
    /// service, so the screens never touch a file store themselves.
    func freeFormEventPhoto(forEventId eventId: String) -> UIImage? {
        freeFormEventService.photo(forEventId: eventId)
    }

    /// Saves the Events form — creating when `eventId` is nil — and tells
    /// the Google bridge, answering the native identifier. nil means
    /// nothing was written, which is the form's cue to stay open with its
    /// draft rather than claim a save that did not happen.
    ///
    /// Create AND edit both go through `eventCreated`, and that is the
    /// whole edit-reconcile (design §3): the call rebuilds the twin's
    /// draft from the event's CURRENT values and the service's
    /// fingerprint diff decides whether anything changed — so an edit
    /// that alters nothing sends no request, and one that moves the time
    /// queues exactly one PUT.
    @discardableResult
    func saveFreeFormEvent(_ form: FreeFormEventForm,
                           editing eventId: String? = nil) -> String? {
        guard let savedId = freeFormEventService.save(form, editing: eventId) else {
            return nil
        }
        // Read back through the service rather than the form: what was
        // actually written is the honest thing to share (the gateway
        // normalizes blank notes and address to nil on the way in).
        if let saved = freeFormEventService.event(withId: savedId) {
            calendarShareService.eventCreated(localEventId: savedId,
                                              title: saved.title,
                                              startDate: saved.startDate,
                                              durationMinutes: saved.durationMinutes,
                                              location: saved.address)
        }
        return savedId
    }

    /// Deletes the event natively, then tells the Google bridge — so the
    /// family's copy does not keep an appointment the elder removed. The
    /// bridge's tombstone is gated on sharing being ON (`canShare`), so
    /// no queue row accumulates while the family has not made a decision;
    /// `cleanupVanishedEvents()` queues the same tombstone on the first
    /// pass after they switch it on.
    ///
    /// Answers whether the native event was actually removed — a false
    /// still means "gone from this app" (the index row and the photo go
    /// either way), so the UI treats both as deleted.
    @discardableResult
    func deleteFreeFormEvent(eventId: String) -> Bool {
        let removed = freeFormEventService.delete(eventId: eventId)
        calendarShareService.eventDeleted(localEventId: eventId)
        return removed
    }

    /// A sheet-presents-this request for the Event detail screen, in the
    /// `pendingPluginPresentation` shape so ContentView stays the only
    /// place that knows how a screen is put on top.
    struct EventDetailPresentation: Identifiable, Equatable {
        let id = UUID()
        let eventId: String
    }
    @Published var pendingEventDetail: EventDetailPresentation?

    /// Opens the detail screen for `eventId` — the reminder notification's
    /// **Open** action (design §4), and the same screen the Events list
    /// opens for an edit, so an event never has two faces.
    ///
    /// The id is carried through, not a copy of the event: the calendar
    /// may have changed since the notification was armed, and the detail
    /// screen re-reads from the service when it appears.
    func openEventDetail(eventId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingEventDetail = EventDetailPresentation(eventId: eventId)
        }
    }

    /// The detail sheet's close button — clears the request so the sheet
    /// cannot reappear on the next body pass.
    func dismissEventDetail() {
        pendingEventDetail = nil
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

    // MARK: - Calendar & family sharing (2026-09-16)

    /// The Google Calendar bridge (design §4.1). LAZY like `calendarSync`
    /// above: constructing it reads a bundle key, an `EKEventStore` and
    /// three local stores and touches no permission and no network. Its
    /// first real work is `syncCalendarShare()` in
    /// `composePostFirstFrame` — post-first-frame, so nothing here delays
    /// the first paint.
    ///
    /// A missing OAuth client id is NOT a construction failure. The
    /// session reports `isConfigured == false`, the service reports
    /// `.notConfigured`, and the Settings card says so in words — which
    /// is the state the app ships in until the family provides a client
    /// (design §0). Graceful degradation here is the difference between
    /// "sharing is not set up" and a crash on launch.
    ///
    /// No `objectWillChange` forward is installed for it, unlike the
    /// eager nested services above: the Settings card observes the
    /// service directly (`@ObservedObject`), and no coordinator state is
    /// derived from it, so a forward would only invalidate every
    /// coordinator observer for nothing — and installing one would force
    /// this lazy service to exist at boot.
    private(set) lazy var calendarShareService = CalendarShareService(
        session: calendarShareSession,
        gateway: calendarShareGateway,
        store: LocalGoogleEventMappingStore(storage: storage),
        consent: CalendarShareConsent(),
        notifySettings: caregiverNotifySettings,
        observabilityBus: observabilityBus,
        contactsProvider: { [weak self] in self?.familyContacts ?? [] }
    )

    /// The Google account session — separate from the service so sign-out
    /// is one call on one object, and so the presenter (a UI concern the
    /// service must not know about) lives with the composition root that
    /// can actually reach the window.
    private(set) lazy var calendarShareSession: GoogleAccountSession = {
        let session = GoogleAccountSession(observabilityBus: observabilityBus)
        // Resolved at PRESENT time, never captured: the window scene does
        // not exist when the composition root runs, and a controller
        // captured then would be a detached one.
        session.presenter = { [weak self] in self?.topPresentingViewController() }
        return session
    }()

    /// The Calendar v3 / People v1 REST client over the session above.
    private(set) lazy var calendarShareGateway = GoogleCalendarGateway(
        session: calendarShareSession,
        observabilityBus: observabilityBus
    )

    /// The topmost view controller Google's sign-in sheet presents from.
    /// Walks past anything already presented so the sheet never lands
    /// under an open modal. Returns nil before the scene exists, which
    /// the session reports as a failed sign-in rather than a crash.
    private func topPresentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Read-only native Calendar/Reminders integration (2026-09-07): the
    /// REVERSE direction of `calendarSync` — native events/reminders
    /// import as in-app reminders with notifications, and rows open the
    /// native app (never written back). Eager (not lazy) because the
    /// objectWillChange forwarding below must observe it from init;
    /// constructing it touches no permissions.
    private(set) var externalCalendar: ExternalCalendarService

    /// Forwards the external calendar service's publishes (2026-09-07):
    /// it is a nested ObservableObject, so a scan/status/lead change
    /// alone would not invalidate views observing the coordinator — the
    /// Settings card, Reminders leaf and Calendar leaf must refresh the
    /// moment a scan lands (same nested-ObservableObject forwarding
    /// pattern as `geminiSwapCancellable`).
    private var externalCalendarCancellable: AnyCancellable?

    /// Alarms + timers (alarms-timers task, 2026-09-07): owns the
    /// voice-set alarms and the in-app countdown timers — one service
    /// behind the router's alarm/timer stage, the Settings leaf, the
    /// launch + BGTask re-queue (FR-025) and the foreground completion
    /// speech. Eager (not lazy) because the language sync, the
    /// objectWillChange forwarding and the delegate closure below must
    /// reach it from init. See `AlarmScheduler` for the platform-honesty
    /// contract (iOS does not write to the built-in Clock app — the
    /// "alarm" is a daily-repeating local notification).
    private(set) var alarmTimersService: AlarmTimersService

    /// [TIMER-ALARM] (2026-09-10) The in-app timer-alarm engine — the
    /// idle → ringing → stopped state machine that drives the full-screen
    /// alarm overlay and the looping loud bell for UN-path timers (the
    /// pre-iOS-26 / AlarmKit-denied foreground fallback). On iOS 26 with
    /// AlarmKit authorized its feed is empty (system-managed timers ring
    /// through the SYSTEM's own full-screen alert), so the two never
    /// double-ring. Also the notification facade handler that routes a
    /// tapped timer notification into the ringing screen.
    private(set) var timerAlarmEngine: TimerAlarmEngine

    /// [TIMER-ALARM] Foreground driver: a main-runloop timer evaluating
    /// the engine twice a second while the app runs.
    private var timerAlarmDriver: Timer?

    /// [TIMER-ALARM] iOS 26 only — the AlarmKit `alarmUpdates`
    /// observation that mirrors system-side dismissals into timer rows.
    private var systemTimerUpdatesTask: Task<Void, Never>?

    /// Forwards the alarms/timers service's publishes ([ALARMS-TIMERS]
    /// 2026-09-07): nested ObservableObject — a toggle/delete/timer-start
    /// alone would not invalidate views observing the coordinator (same
    /// pattern as `externalCalendarCancellable`).
    private var alarmTimersCancellable: AnyCancellable?

    /// Forwards the caregiver-notify settings' publishes
    /// ([CAREGIVER-EVENTS] 2026-09-13): nested ObservableObject — a
    /// toggle flip alone would not invalidate views observing the
    /// coordinator, so the Settings leaf's switch would not move until
    /// something else repainted (same pattern as
    /// `externalCalendarCancellable`).
    private var caregiverNotifySettingsCancellable: AnyCancellable?

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

    // MARK: - Two-way calendar mirroring (calendar-driven task, 2026-09-07)

    /// Settings toggle handler for two-way mirroring (default OFF):
    /// ON ensures the mirror is on first, requests FULL calendar
    /// access at point of use (read access is what lets native edits
    /// reconcile back), then mirrors the schedule into the dedicated
    /// "Sahayak" calendar; OFF removes the Sahayak events (the legacy
    /// mode-switch wipe) and falls back to the one-way default-calendar
    /// mirror. The Sahayak id feeds the import's calendar-id exclusion
    /// in every direction.
    func setCalendarTwoWayEnabled(_ enabled: Bool) async {
        if enabled {
            if !calendarSync.isEnabled {
                calendarSync.isEnabled = true
                await calendarSync.enableAndSync(entries: routineScheduler.entries())
            }
            await calendarSync.enableTwoWayAndSync(entries: routineScheduler.entries())
        } else {
            calendarSync.disableTwoWayAndSyncIfMirrorEnabled(entries: routineScheduler.entries())
        }
        if let sahayakIdentifier = calendarSync.sahayakCalendarIdentifier {
            externalCalendar.excludedCalendarIdentifiers.insert(sahayakIdentifier)
        }
    }

    /// Applies native-calendar edits to the app's routine schedule —
    /// the `onNativeChanges` relay. Runs off any gesture (the family
    /// edits in another app; the store-change notification delivers it
    /// here), so the republish below is what refreshes views.
    private func applyNativeCalendarMutations(
        _ mutations: [CalendarSyncService.RoutineCalendarMutation]) {
        for mutation in mutations {
            switch mutation {
            case .dropSlot(let entryId, let hour, let minute):
                routineScheduler.dropSlot(entryId: entryId, hour: hour, minute: minute)
            case .retimeSlot(let entryId, let fromHour, let fromMinute,
                             let toHour, let toMinute):
                routineScheduler.retimeSlot(entryId: entryId, fromHour: fromHour,
                                            fromMinute: fromMinute,
                                            toHour: toHour, toMinute: toMinute)
            case .setRecurrence(let entryId, let frequency, let weekdays):
                routineScheduler.updateRecurrence(entryId: entryId,
                                                  frequency: frequency,
                                                  weekdays: weekdays)
            case .disableEntry(let entryId):
                routineScheduler.setEnabled(entryId, enabled: false)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        // [BOOT-REVIEW P1-7] Native-calendar edits reach the app's
        // reminder schedule, so the derived count follows them.
        refreshActiveNotificationCount()
    }

    /// Applies family edits to the dose mirror — the
    /// `onMedicationNativeChanges` relay (rich-events task, 2026-09-17).
    /// The scheduler's mutator writes through `loadSchedule`, which
    /// re-persists the entry, re-arms every dose and fires
    /// `onScheduleChanged`: the Google twins follow from there, and the
    /// mirror re-syncs over the new times, so a retime converges in one
    /// pass instead of two apps disagreeing until the next launch.
    private func applyMedicationCalendarMutations(
        _ mutations: [CalendarSyncService.MedicationCalendarMutation]) {
        for mutation in mutations {
            switch mutation {
            case .setScheduleTimes(let entryId, let times):
                medicationScheduler.setScheduleTimes(times, entryId: entryId)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        refreshActiveNotificationCount()
    }

    // MARK: - Read-only external Calendar/Reminders surface (2026-09-07)

    /// Settings toggle handler for the native-item import: ON asks for
    /// calendar + reminders access at point of use and scans; OFF
    /// cancels every notification this feature armed (scoped — the
    /// medication/routine alarms on the same center are untouched).
    func setExternalCalendarEnabled(_ enabled: Bool) async {
        if enabled {
            await externalCalendar.enable()
        } else {
            await externalCalendar.disable()
        }
    }

    /// Today's imported native items (events + due reminders, oldest
    /// first) — merged into the Reminders leaf's today list and the
    /// Calendar leaf's schedule section.
    var externalRemindersToday: [ExternalReminder] {
        externalCalendar.todaysItems()
    }

    /// Tap on an external row — read-only integration: opens the item's
    /// native app (Calendar `calshow:` / Reminders `x-apple-reminderkit://`),
    /// best-effort behind canOpenURL.
    func openExternalReminder(_ item: ExternalReminder) {
        externalCalendar.open(item)
    }

    /// Scene-phase reactions wired from `ContentView`: foreground
    /// rescans (family edits in the native apps land immediately —
    /// the import's scan AND the two-way mirror's reconciliation),
    /// background submits the hourly BGAppRefresh that keeps scans
    /// coming while the app isn't running.
    func handleScenePhase(_ phase: ScenePhase) {
        guard started else { return }   // start() already refreshes
        switch phase {
        case .active:
            // [TIMER-ALARM] Immediate re-evaluation on activation — a
            // UN-path timer that elapsed while the app was backgrounded
            // rings the moment the user returns (the OS notification was
            // the background fallback; in the foreground the looping bell
            // is the honest timer behavior).
            timerAlarmEngine.tick(
                activeTimers: alarmTimersService.engineManagedActiveTimers)
            // The top-bar date line may be a day stale after a long
            // background stretch — the offline recompose is cheap and
            // its equality guard makes the everyday case a no-op.
            refreshHomeCalendarLineIfNeeded()
            Task { await externalCalendar.startIfEnabled() }
            Task {
                await calendarSync.reconcileNativeChanges(entries: routineScheduler.entries())
            }
            // Voice-OS shell v1 — proactive morning briefing (design
            // §4.4 trigger a): fires on the first app activation inside
            // the wake window, once per calendar day. Idempotent —
            // `shouldFireOnActivation` + `fire()` share the same
            // once-per-day budget as the spoken command, so repeated
            // activations never double-speak. After the fire completes,
            // the stored slot is re-read into `todayBriefing` (a same-day
            // no-op leaves the earlier composition untouched).
            // activations never double-speak.
            //
            // Launch ordering (STOPPED-SPEAKING-FIX, 2026-09-08): this
            // fire is deliberately NOT serialized behind the voice
            // pipeline's start — the briefing Task can beat pipeline
            // start (observed log order briefing_fired →
            // pipeline_started) and speak while the session is still
            // `.stopped`. That is legal by design: the session table
            // admits `.stopped → .speaking` for push speech that starts
            // before the pipeline is primed, so start() needs no
            // reordering.
            if let briefing = morningBriefing,
               briefing.shouldFireOnActivation(now: Date(),
                                               calendar: Calendar.current) {
                Task {
                    await briefing.fire()
                    await MainActor.run { self.refreshTodayBriefing() }
                }
            }
            // Unconditional re-read of the day slot on every activation
            // (briefing persistence task, 2026-09-08): cheap, keeps the
            // Home widget presence + briefing leaf truthful even when no
            // fire ran, and any refresh racing the task above is
            // superseded by the task's post-fire read.
            refreshTodayBriefing()
            // [CALENDAR-SHARE] (2026-09-16) Same activation, the share
            // layer's pass: reconcile both schedules, drain the queue,
            // pull invitations the family sent. Runs here rather than on
            // its own timer because a foreground return is the only
            // moment the elder's device is reliably online.
            syncCalendarShare()
        case .background:
            // [MODEL-WARDEN] Step 0/1 — the scene-phase hook. A backgrounded
            // app is judged against a much smaller jetsam limit and its
            // in-flight work may never be resumed, so a permission to
            // allocate must not outlive the foreground: every uncommitted
            // reservation is withdrawn here (a committed one is resident,
            // and residency is the eviction policy's business, not the
            // scene's). The next activation re-issues the load through the
            // same gate, which is why this is a cancellation and not a
            // state change.
            ModelLifecycleManager.shared
                .cancelPendingReservations(reason: .backgrounded)
            externalCalendar.submitBackgroundRefresh()
        default:
            break
        }
    }

    // MARK: - Calendar & family sharing (2026-09-16)

    /// The share layer's launch/foreground pass.
    ///
    /// The reconciling is here, not only on the schedulers' change
    /// seams, for one reason: those seams fire on CHANGES, so a schedule
    /// that already existed before the family connected Google would
    /// never be shared at all. Reconcile is fingerprint-diffed and
    /// enqueue is the only thing that can produce work, so an unchanged
    /// schedule costs a few local reads and zero requests — which is
    /// what makes it safe to run on every activation.
    ///
    /// [GOOGLE-RESTORE] (2026-09-17) The SDK's stored session is restored
    /// FIRST, and the pass is SEQUENCED behind it rather than raced with
    /// it. Every gate in the pass reads `session.isSignedIn`, which is
    /// nil in a cold process until a restore has run — so a pass that
    /// went first would judge a connected household signed out,
    /// reconcile nothing and drain nothing, and the family's already
    /// queued events would wait for the next activation (the
    /// silent-skip this change exists to remove). The restore is
    /// idempotent, so the cost of this on every activation is one
    /// in-memory check.
    func syncCalendarShare() {
        let share = calendarShareService
        share.locale = activeLocale
        // Idempotent assignment: the closure is the same every pass, and
        // setting it here (rather than at construction) is what keeps
        // the service lazy until the first pass.
        share.onLocalEventImported = { [weak self] in
            // An accepted invitation now sits in the native calendar;
            // the existing import is what turns it into an armed
            // reminder that fires and alerts a caregiver.
            Task { await self?.externalCalendar.rescan() }
        }
        Task { [weak self] in
            // Nothing may present from here: a restore takes no
            // presenter and shows no sheet, which is what makes it safe
            // at launch — before the window the sign-in flow needs
            // exists.
            await share.restoreSession()
            await MainActor.run { self?.runCalendarSharePass() }
        }
    }

    /// The reconcile/flush half of `syncCalendarShare()`, run once the
    /// session restore has landed.
    ///
    /// Main-confined: it reads the coordinator's published schedules and
    /// the free-form event index, both of which are only ever mutated on
    /// the main queue.
    private func runCalendarSharePass() {
        let share = calendarShareService
        share.reconcileMedication(medicationScheduler.medicationEntries())
        share.reconcileRoutines(routineScheduler.entries())
        // Swept BEFORE the flush, so a twin whose local event the elder
        // deleted natively in the same window is deleted from the family
        // calendar by this pass rather than the next one.
        share.cleanupVanishedEvents()
        // And the free-form events' CURRENT native state, for the same
        // window and the same reason: an event retimed by the family in
        // their own Calendar app is an edit to the one native event this
        // app reads back, so it belongs in this pass rather than only at
        // the form's save seam. The key set is the side INDEX (not the
        // ledger) because the ledger also holds invitations this device
        // imported, whose twin belongs to the organizer.
        share.reconcileFreeFormEvents(trackedEventIds: freeFormEventService.trackedEventIds)
        Task {
            await share.flushPending()
            await share.syncInbound()
        }
    }

    // MARK: - Today's briefing slot (briefing persistence task, 2026-09-08)

    /// Re-reads the encrypted day slot into the published `todayBriefing`.
    /// Main-confined: called synchronously from `init` / `handleScenePhase`
    /// (SwiftUI main thread) and from `MainActor.run` after async fires —
    /// the only two places the store's contents can change (a fire writes
    /// the day's slot) or staleness could matter (midnight rollover, where
    /// the stale slot stops matching the new day and the Home widget hides
    /// itself until tomorrow's composition).
    private func refreshTodayBriefing() {
        todayBriefing = morningBriefingStore.todaysBriefing(now: Date())
    }

    // MARK: - Routine reminder surface (v2 pivot Phase 1)

    /// A routine reminder that just fired WITH photos, presented full
    /// screen for the person the reminder is for (photo-visual-aids task,
    /// 2026-09-16). Set by `RoutineVisualAidFireHandler` — the app's only
    /// in-app firing surface for reminders, since routine reminders
    /// otherwise deliver as text-only notification banners. Nil (the
    /// normal state) means nothing to present; entries without photos
    /// never set it, so their behaviour is byte-for-byte unchanged.
    @Published private(set) var firedRoutineVisualAids: FiredRoutineVisualAids?

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
        // [BOOT-REVIEW P1-7] Routine mutations land in the same reminder
        // surface the derived count reads.
        refreshActiveNotificationCount()
    }

    /// Replaces a routine's photos (the photo editor's save path).
    /// Files are already written by `VisualAidStore` before this is
    /// called; this persists the model payload and re-arms, so a photo
    /// edit and a time edit take the same path. Re-arming matters here:
    /// the fired notification carries the first photo, so a photo added
    /// to an already-armed reminder only reaches the banner through the
    /// reschedule.
    func setRoutineVisualAids(_ entryId: UUID, aids: [VisualAid]) {
        routineScheduler.setVisualAids(aids, entryId: entryId)
    }

    /// The presentation is dismissed (Close button, or the cover's own
    /// swipe) — clearing the item is what actually dismisses it.
    func dismissFiredRoutineVisualAids() {
        firedRoutineVisualAids = nil
    }

    /// `RoutineVisualAidFireHandler`'s presentation sink, on the main
    /// queue. Reads the title through `activeLocale` at fire time — the
    /// language the app is in NOW, not the one it was in when the
    /// notification was armed.
    private func presentRoutineVisualAids(for entry: RoutineEntry) {
        firedRoutineVisualAids = FiredRoutineVisualAids(
            entryId: entry.id,
            title: entry.displayTitle(locale: activeLocale),
            aids: entry.visualAids
        )
    }

    // MARK: - Medication dose surface (medication-visual-aids, 2026-09-16)

    /// A medication reminder that just fired WITH photos, presented full
    /// screen for the person the dose is for. Set by
    /// `MedicationVisualAidFireHandler` — nil (the normal state) means
    /// nothing to present, and entries without photos never set it, so
    /// their delivery is exactly what it was before this feature.
    @Published private(set) var firedMedicationVisualAids: MedicationVisualAidsPresentation?

    /// Replaces a medication's photos (the photo editor's save path).
    /// Files are already written by `VisualAidStore` before this is
    /// called; this persists the entry payload only — a photo edit is not
    /// a schedule edit, so no alarm is re-armed and no escalation state is
    /// touched (see `MedicationScheduler.setVisualAids`; the dose screen
    /// reads the entry at fire time, so the photo is live either way).
    func setMedicationVisualAids(_ entryId: UUID, aids: [VisualAid]) {
        medicationScheduler.setVisualAids(aids, entryId: entryId)
    }

    /// The presentation is dismissed (Close button, or the cover's own
    /// swipe) — clearing the item is what actually dismisses it.
    func dismissFiredMedicationVisualAids() {
        firedMedicationVisualAids = nil
    }

    /// The elder tapped "I took it" on the fired-dose screen. Runs the same
    /// dose path as the Meds leaf row (`confirmMedicationDose`: the FR-D01
    /// challenge gate first, then the baseline acknowledgement) and clears
    /// the presentation: when a challenge was issued the Home chips own the
    /// follow-up, and when the dose was recorded the Home outcome caption
    /// behind this screen is what the elder should now see.
    func confirmFiredMedicationDose(entryId: UUID) {
        confirmMedicationDose(entryId: entryId)
        firedMedicationVisualAids = nil
    }

    /// The elder's "I took it" from an elder-facing dose surface — the
    /// Meds leaf's dose row and the fired-dose screen share this one path,
    /// so the safety gate cannot drift between them. Returns true when the
    /// dementia-aware confirmation challenge was issued (the caller's
    /// surface gets out of the way; the Home chips own the answer).
    @discardableResult
    func confirmMedicationDose(entryId: UUID) -> Bool {
        if startVoiceAckConfirmation(for: entryId) != nil {
            return true
        }
        handleMedicationAcknowledgement(entryId: entryId)
        speak(key: "router.confirmationYes")
        return false
    }

    /// `MedicationVisualAidFireHandler`'s presentation sink, on the main
    /// queue. Snapshots the name and dose line at FIRE time — the entry
    /// may be edited (or deleted) while the screen is up, and the dose the
    /// elder is being shown must be the one that fired.
    private func presentMedicationVisualAids(for entry: MedicationEntry) {
        firedMedicationVisualAids = MedicationVisualAidsPresentation(entry: entry)
    }

    // MARK: - The voice photo query ([MED-PHOTO], 2026-09-17)

    /// The live medication schedule as the voice photo query sees it — the
    /// `VoiceCommandCoordinating` seam the router reads ONCE per turn: the
    /// keyword rule builds its vocabulary from these entries (name +
    /// purpose keys per `MedicationVoiceVocabulary`), and the matched key
    /// is resolved back against the same list. Nothing is cached: a
    /// medicine added or deleted a moment ago is already in (or gone from)
    /// the answer.
    var medicationVoiceEntries: [MedicationEntry] { medicationScheduler.medicationEntries() }

    /// The elder asked what a medicine looks like ("रक्तचापको औषधि कस्तो
    /// छ?"). Presents the same full-screen photo surface a fired dose uses
    /// — in its IDENTIFY mode, so nothing about a dose appears: no "time to
    /// take your medicine", no "I took it". Nothing is due; a dose prompt
    /// with an active acknowledge button at a moment when no dose was
    /// scheduled is exactly how a dose gets recorded that was never taken
    /// (the double-dose detector would then block the real one).
    ///
    /// Returns the line to speak: the photo's caption ("रक्तचापको औषधि —
    /// अम्लोडिपिन", the same line the fired dose's screen shows), the
    /// honest "no photo yet" line when the entry carries none, and nil when
    /// the entry is gone (nothing to show, nothing to claim).
    func showMedicationPhoto(entryId: UUID) -> String? {
        guard let entry = medicationEntry(for: entryId) else {
            emitMedicationPhotoQuery(outcome: "entryGone", entryId: nil)
            return nil
        }
        let presentation = MedicationVisualAidsPresentation(entry: entry, mode: .identify)
        guard !entry.visualAids.isEmpty else {
            // The honest line, never a blank screen with a promise: the
            // family can add the photo, and this says where.
            emitMedicationPhotoQuery(outcome: "noPhoto", entryId: entry.id)
            return L10n.str("meds.photoMissing", locale: activeLocale)
        }
        firedMedicationVisualAids = presentation
        emitMedicationPhotoQuery(outcome: "presented", entryId: entry.id)
        return presentation.caption(locale: activeLocale)
    }

    /// Observability for the voice photo query — the outcome and, when an
    /// entry resolved, its HASH. Never the medicine's name, its purpose or
    /// the transcript: the medication privacy rule every other event in
    /// this file follows (`setVisualAids` logs an `entry_id_hash` for the
    /// same reason). The hash is what lets a "she asked and got the honest
    /// no-photo line three times this week" observation be made at all.
    private func emitMedicationPhotoQuery(outcome: String, entryId: UUID?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "medication_photo",
            eventType: "medication_photo_query",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: entryId.map { ["entry_id_hash": IdHashing.shortHash(of: $0)] } ?? [:]
        ))
    }

    /// Today's medication reminders as localized "name — time" lines for
    /// the routine plugin's `routine.query` answer — one spoken list
    /// spanning both reminder systems. Spoken-form times (spoken-time
    /// task, 2026-09-08): these lines are read aloud, so they share the
    /// `SpokenTime` helper; UI display formatting is untouched.
    private func todayMedicationSummaryLines() -> [String] {
        medicationScheduler.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .map { reminder in
                let name = medicationName(for: reminder.medicationEntryId)
                let time = SpokenTime.string(from: reminder.scheduledAt, locale: activeLocale)
                return "\(name) — \(time)"
            }
    }

    // MARK: - Public API for voice commands

    /// BASELINE ack, used for non-dementia flows and as an explicit fallback.
    /// Voice path should use `startVoiceAckConfirmation` instead so that
    /// FR-D01 (challenge) and FR-D03 (double-dose check) actually run.
    func handleMedicationAcknowledgement(entryId: UUID) {
        _ = medicationScheduler.acknowledge(entryId: entryId, at: Date())
        // [BOOT-REVIEW P1-7] Acknowledged doses move the derived count.
        refreshActiveNotificationCount()
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
        // [BOOT-REVIEW P1-7] Same count seam as the BASELINE ack above.
        refreshActiveNotificationCount()
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
        // [APP-LAUNCHER F1] The dose challenge takes the window — and the
        // question it displaces is dropped BEFORE the challenge is armed,
        // so the two can never be pended at once (the invariant
        // `ConfirmationArbitration.owner` encodes).
        dropLaunchSupersededByMedicationChallenge()
        DispatchQueue.main.async { [weak self] in
            self?.pendingConfirmationEntryId = entryId
            self?.openConfirmationWindow()
        }
        return prompt
    }

    /// [APP-LAUNCHER F1] Drops a pended launch because a dose challenge is
    /// taking the confirmation window. The launch is recorded as the
    /// unanswered verdict it now is (`timeout` — the question expired
    /// without an answer) and announced on the bus; nothing is opened. The
    /// alternative — leaving it pended — is the bug this fixes: the next
    /// "हो" would then be spent on the launch, and the FR-D03 double-dose
    /// gate would never run on a dose the elder had just been asked about.
    private func dropLaunchSupersededByMedicationChallenge() {
        guard let launch = pendingAppLaunch else { return }
        pendingAppLaunch = nil
        appendCapture(launch.capture, .timeout, path: launch.capturePath)
        emitAppLaunch(eventType: "launch_superseded",
                      outcome: "\(launch.appID):supersededByMedicationChallenge")
    }

    // MARK: - [INTENTLOG-CAPTURE] Flywheel capture (T-054 precursor)

    /// The flywheel's single capture seam (spec 2026-09-05 §11). Every
    /// confirm-tier verdict — confirmed, denied, corrected, timeout —
    /// travels through here, so the log can no longer record two of its
    /// four outcomes. The record's SHAPE belongs to
    /// `IntentLogStore.Capture` (and to each pending action's own
    /// `capture` property); this only writes it.
    private func appendCapture(_ capture: IntentLogStore.Capture,
                               _ verdict: IntentLogStore.Verdict,
                               path: String = "model",
                               correctedTo: [String: String]? = nil) {
        intentLogStore.append(capture.record(verdict, path: path, correctedTo: correctedTo))
    }

    /// A confirm-tier confirmation whose 45 s window expired (C12). The
    /// action stays pended exactly as before — this records the verdict,
    /// it does not change what the flow does with it. The medication
    /// challenge is NOT captured: that flow is `neverGated` and its
    /// pending entry is a dose, not a confirm-tier intent.
    private func recordConfirmationTimeout() {
        if let action = pendingCallAction {
            appendCapture(action.capture, .timeout)
        } else if let event = pendingCalendarEvent {
            appendCapture(event.capture, .timeout)
        } else if let launch = pendingAppLaunch {
            appendCapture(launch.capture, .timeout)
        }
    }

    /// User's yes/no follow-up to a pending confirmation challenge.
    /// Routes through the scheduler's dementia path so the double-dose
    /// check fires and the log is written with `confirmationPassed`
    /// reflecting reality. The session machine returns to idle (and its
    /// timeout timer is cancelled — C12).
    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        // Navigation ambiguity walk (directions task, 2026-09-07) — an
        // additive flow like the call branch below: checked first and
        // returned early so the medication path is completely untouched.
        // Yes → execute the TOP candidate (never guess a place — the
        // decider only pends when it cannot pick); no → ask the next
        // candidate, or speak the honest cancelled line when the walk is
        // exhausted. The voice session stays `.awaitingConfirmation`
        // while candidates remain, and returns to idle when the walk
        // resolves.
        if !pendingNavigationWalk.isEmpty {
            let answered = pendingNavigationWalk.removeFirst()
            switch response {
            case .yes:
                pendingNavigationWalk = []
                executeNavigation(to: answered.target)
            case .no:
                if let next = pendingNavigationWalk.first {
                    speak(text: navigationQuestion(for: next))
                } else {
                    emitDirections(eventType: "command", outcome: "cancelled")
                    replyHonestly(key: "directions.cancelled")
                }
            }
            if pendingNavigationWalk.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.voiceSession.transition(to: .idle)
                }
            }
            return
        }
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
                // [INTENTLOG-CAPTURE] A declined confirmation is signal —
                // the negative half of the flywheel. Recorded BEFORE the
                // speech so the verdict can never be lost to a speaker
                // failure.
                appendCapture(action.capture, .denied)
                speak(text: L10n.fmt("router.call.cancelled", locale: activeLocale, action.contact.name))
            }
            DispatchQueue.main.async { [weak self] in
                self?.voiceSession.transition(to: .idle)
            }
            return
        }
        // Calendar-event confirmations (caregiver event-notifications,
        // 2026-09-13): same additive shape as the call block above —
        // checked and returned early, so the medication path below stays
        // untouched. A YES writes the event; a NO speaks the honest
        // cancellation (same as the call and directions paths — an elder
        // who says "होइन" must hear that they were heard, not silence).
        if let event = pendingCalendarEvent {
            pendingCalendarEvent = nil
            if case .yes = response {
                emitCalendarEvent(eventType: "command_calendar_event_confirmed",
                                  outcome: "success")
                executePendingCalendarEvent(event)
            } else {
                emitCalendarEvent(eventType: "command_calendar_event_cancelled",
                                  outcome: "cancelled")
                // [INTENTLOG-CAPTURE] Same negative-half capture as the
                // call path above.
                appendCapture(event.capture, .denied)
                speak(text: L10n.str("router.calendarEventCancelled", locale: activeLocale))
            }
            DispatchQueue.main.async { [weak self] in
                self?.voiceSession.transition(to: .idle)
            }
            return
        }
        // App-launch confirmations (voice app launcher, 2026-09-16): the
        // same additive shape as the call and calendar-event blocks above
        // — checked and returned early, so the medication path below stays
        // untouched for every confirmation EXCEPT a simultaneous dose
        // challenge, which outranks the launch (F1). A YES hands the pended app to the shared launch
        // executor (which speaks the surface that actually appeared); a NO
        // speaks the honest cancellation, because an elder who answers
        // "होइन" must hear that they were heard. Nothing is opened on a no.
        //
        // [APP-LAUNCHER F1] ONLY when the launch owns this answer. A
        // medication dose-challenge that is pended at the same time takes
        // precedence (`ConfirmationArbitration`), so the block falls
        // through to the medication path below — which is where the FR-D03
        // double-dose check lives. This early return used to swallow it:
        // the launch was answered, the launch was opened, and the dose the
        // elder had just confirmed was never recorded.
        let confirmationOwner = ConfirmationArbitration.owner(
            pendingAppLaunch: pendingAppLaunch?.appID,
            hasMedicationChallenge: pendingConfirmationEntryId != nil)
        if confirmationOwner == .appLaunch, let launch = pendingAppLaunch {
            pendingAppLaunch = nil
            if case .yes = response {
                emitAppLaunch(eventType: "launch_confirmed", outcome: "\(launch.appID):confirmed")
                executePendingAppLaunch(launch)
            } else {
                // [INTENTLOG-CAPTURE] Same negative-half capture as the
                // call path above — a declined launch is flywheel signal.
                appendCapture(launch.capture, .denied, path: launch.capturePath)
                emitAppLaunch(eventType: "launch_cancelled", outcome: "\(launch.appID):cancelled")
                speak(text: L10n.str("launcher.cancelled", locale: activeLocale))
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
        // [BOOT-REVIEW P1-7] The voice confirmation's ack moves the
        // derived count exactly like the BASELINE ack does.
        refreshActiveNotificationCount()
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
    /// [DIRECTIONS] (2026-09-07) The navigation ambiguity walk pends the
    /// same way — while candidates remain, the router's yes/no parsing
    /// stays in force.
    var isAwaitingConfirmation: Bool {
        pendingConfirmationEntryId != nil || pendingCallAction != nil || pendingRephrase != nil
            || pendingCalendarEvent != nil
            || !pendingNavigationWalk.isEmpty
            || pendingAppLaunch != nil
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
        // BGTaskScheduler registration raises an NSException on the
        // simulator (background tasks are device-only); skip there so a
        // sim launch can never abort in this call (crash 2026-09-11).
        #if targetEnvironment(simulator)
        return
        #endif
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.elderlyassistant.medication.check",
            using: nil
        ) { [weak self] task in
            self?.medicationScheduler.scheduleAll()
            self?.routineScheduler.scheduleAll()
            // Same re-queue for alarms + timers ([ALARMS-TIMERS]
            // 2026-09-07): the handler dispatches to main, where it is
            // idempotent (requests replace in place by id).
            self?.alarmTimersService.scheduleAll()
            task.setTaskCompleted(success: true)
        }
        // External calendar rescan (calendar-driven task, 2026-09-07):
        // the handler IS a rescan pass — same idempotent scan as the
        // foreground refresh, so the native Calendar/Reminders changes
        // a family member made while the app sat backgrounded land
        // within the hourly cadence.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ExternalCalendarService.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                await self.externalCalendar.rescan()
                // [CALENDAR-SHARE] (2026-09-16) The share layer's INTERVAL
                // pass (design §2.5: "foreground + interval"). It rides
                // this handler rather than a task identifier of its own:
                // the identifier set is fixed in Info.plist, the cadence
                // wanted is exactly this one, and this handler is already
                // awake with the app free to use the network.
                //
                // The hop is not cosmetic — the handler fires on a
                // background queue and the share service is main-confined
                // (it reads schedulers and settings and, on an import,
                // kicks the rescan that touches the UI's published state).
                await MainActor.run { self.syncCalendarShare() }
                task.setTaskCompleted(success: true)
            }
        }
    }

    // MARK: - Wake-word engine selection & status (open item #4)

    /// Builds the launch wake-word engine and reports whether it is REAL
    /// (sherpa-onnx KWS) or the Null fallback — Settings → "Voice
    /// activation" needs that truth for its status row.
    ///
    /// Decision order (2026-09-08, P0 slice A + settings cleanup):
    ///  1. The persisted Settings toggle is the master switch: OFF means
    ///     NullWakeWordEngine even when a KWS model is bundled (disabled
    ///     must behave exactly like today).
    ///  2. The sherpa-onnx candidate runs: `SherpaKWSWakeWordEngine
    ///     .attempt()` builds a live engine when the model directory is
    ///     bundled and loadable and emits an honest observability event
    ///     (`kws_engine_ready` / `kws_engine_unavailable`) when it cannot —
    ///     no access key, no `.ppn`, nothing else to configure.
    ///
    /// The pure decision table lives in `WakeWordEngineSelection`
    /// (unit-tested without the sherpa package linked); only the real
    /// engine's construction is sherpa-guarded, inside `attempt()`.
    private static func makeWakeWordEngine(observabilityBus: ObservabilityBus)
        -> (engine: WakeWordEngine, isReal: Bool) {
        // [BOOT-REVIEW P0 item 1] The KWS interval spans exactly the
        // expensive half: the bundled-model resolution + the sherpa
        // session/tokenizer construction. It is begun here (not at the
        // call site) because this factory is the one place both the
        // simulator's main-thread path and the device's serial-executor
        // path run through.
        StartupSignposts.begin(.kwsSessionReady)
        guard let real = WakeWordEngineSelection.make(
            toggleEnabled: WakeWordPreferences().isEnabled,
            sherpaCandidate: {
                SherpaKWSWakeWordEngine.attempt(observabilityBus: observabilityBus)
            }
        ) else {
            StartupSignposts.end(.kwsSessionReady, note: "null-engine")
            print("[AppCoordinator] Wake-word engine: NullWakeWordEngine "
                  + "(toggle off or sherpa model missing) — "
                  + "Talk button + simulate path unchanged")
            return (NullWakeWordEngine(), false)
        }
        StartupSignposts.end(.kwsSessionReady, note: "real-engine")
        return (real, true)
    }

    /// Compile-time: is the sherpa-onnx runtime linked into THIS build?
    /// Mirrors the `#if canImport(SherpaOnnx)` guard inside
    /// `SherpaKWSWakeWordEngine` (project.yml pins the package today), so
    /// the Settings status can never claim "Active" for a build whose
    /// engine is Null by construction.
    static var isWakeWordRuntimeLinked: Bool {
        #if canImport(SherpaOnnx)
        return true
        #else
        return false
        #endif
    }

    /// True when THIS build has everything the real engine needs: the
    /// sherpa runtime linked AND the KWS model directory bundled — the
    /// same inputs `makeWakeWordEngine()` decides on, so the status row
    /// and the actually-built engine cannot disagree.
    var isWakeWordProvisioned: Bool {
        Self.isWakeWordRuntimeLinked
            && SherpaKWSModelFile.bundledDirectory() != nil
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

// MARK: - [ALARMS-TIMERS] Alarms + timers (voice stage + Settings leaf)

extension AppCoordinator {

    /// Settings-leaf access to the service's lists. The leaf observes the
    /// coordinator; the service's publishes reach it through
    /// `alarmTimersCancellable` (see the property docs).
    var alarms: [Alarm] { alarmTimersService.alarms }
    var activeTimers: [TimerItem] { alarmTimersService.activeTimers }

    /// [ALARMKIT-ALARMS] (2026-09-10) The backend arming alarms on THIS
    /// device — AlarmKit system alarms on iOS 26+, UN notifications
    /// before. The Settings leaf labels each alarm row from this.
    var alarmSchedulingKind: AlarmBackendKind { alarmTimersService.alarmSchedulingKind }

    /// [ALARMKIT-ALARMS] (2026-09-10) Alarm-permission status for the
    /// Settings leaf — a `.denied` shows the honest caption.
    var alarmAuthorizationStatus: AlarmAuthorizationStatus {
        alarmTimersService.alarmAuthorizationStatus
    }

    /// [ALARMS-TIMERS] (2026-09-07) Voice + UI alarm creation — the
    /// router's alarm stage and the Settings leaf both land here. The
    /// notification-permission round-trip happens at point of use inside
    /// the service; the outcome drives the router's honest spoken line
    /// (and the leaf's error text).
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome {
        await alarmTimersService.addAlarm(at: time, label: label)
    }

    /// [ALARMKIT-ALARMS] (2026-09-10) The honest denial key when an
    /// alarm-set hits a permission denial — AlarmKit-specific copy on
    /// iOS 26+ (the system-alarm permission), the notification copy
    /// before. `VoiceCommandCoordinating` requirement with the inert
    /// default in the protocol extension, so mocks keep their historical
    /// line; the router and the Settings leaf both resolve through this.
    var alarmPermissionDeniedKey: String {
        alarmSchedulingKind == .alarmKit
            ? "alarmAlarmKit.permissionDenied"
            : "alarms.permissionDenied"
    }

    /// [ALARMS-TIMERS] (2026-09-07) Voice + UI timer start — same
    /// contract as `requestAlarmSet` for the in-app countdown timers.
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        await alarmTimersService.startTimer(durationSeconds: durationSeconds, label: label)
    }

    /// [ALARMS-TIMERS] (2026-09-08) Voice alarm OFF — resolves the most
    /// recently rung enabled alarm and disables it (persist off, cancel
    /// the pending daily + any snooze). Synchronous; the router speaks
    /// the returned outcome. A nil target (no enabled alarms) reports
    /// `.noAlarm` so the router speaks the honest "no alarms" line.
    func requestAlarmOff() -> AlarmOffOutcome {
        guard let target = alarmTimersService.mostRecentlyRungEnabledAlarm() else {
            return .noAlarm
        }
        return alarmTimersService.disableAlarm(id: target.id)
    }

    /// [ALARMS-TIMERS] (2026-09-08) Voice SNOOZE — arms the one-shot
    /// re-wake notification for the most recently rung enabled alarm
    /// without touching its daily repeat. Same synchronous,
    /// outcome-returning contract as `requestAlarmOff`.
    func requestAlarmSnooze(minutes: Int) -> AlarmSnoozeOutcome {
        guard let target = alarmTimersService.mostRecentlyRungEnabledAlarm() else {
            return .noAlarm
        }
        return alarmTimersService.snoozeAlarm(id: target.id, minutes: minutes)
    }

    /// [HOME-TIMER-CHIP] (2026-09-11) Voice timer CANCEL ("cancel the
    /// timer", "टाइमर बन्द गर") — cancels the NEAREST running timer
    /// (soonest deadline) through the existing cancel path: persist
    /// removal, then cancel the pending notification and, when
    /// system-managed, the AlarmKit timer. Synchronous, same
    /// outcome-returning contract as `requestAlarmOff`; the router
    /// speaks the returned outcome.
    func requestTimerCancel() -> TimerCancelOutcome {
        alarmTimersService.cancelNearestTimer()
    }

    /// Settings-leaf mutations (main-confined — the leaf's buttons run on
    /// main). Toggle re-arms/cancels the pending daily notification;
    /// remove/cancel persist the removal before cancelling the OS request.
    func toggleAlarm(id: UUID, enabled: Bool) {
        alarmTimersService.setAlarmEnabled(id: id, enabled: enabled)
    }

    func removeAlarm(id: UUID) {
        alarmTimersService.removeAlarm(id: id)
    }

    func cancelTimer(id: UUID) {
        alarmTimersService.cancelTimer(id: id)
    }

    /// [TIMER-ALARM] (2026-09-10) The alarm screen's single STOP button:
    /// ends the looping bell and expires the timer row. Main-confined
    /// (the button runs on main).
    func stopTimerAlarm() {
        if let timerID = timerAlarmEngine.stopRinging() {
            alarmTimersService.expireTimer(id: timerID)
        }
    }

    /// [TIMER-ALARM] iOS 26: subscribes to `AlarmManager.alarmUpdates`
    /// and mirrors system-side dismissals/cancellations into the timer
    /// rows via the service's `noteSystemTimerUpdates` (main-confined).
    /// The system is the source of truth for system-managed timers; the
    /// app never outlives it.
    @available(iOS 26.0, *)
    private func observeSystemTimerUpdates() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await alarms in AlarmManager.shared.alarmUpdates {
                let ids = Set(alarms.map(\.id))
                self.alarmTimersService.noteSystemTimerUpdates(systemTimerIDs: ids)
            }
        }
        systemTimerUpdatesTask = task
    }

    /// [TIMER-ALARM] The AlarmKit seam factory — nil on iOS < 26 (the
    /// service then stays on the pure UN path, which every pre-26 test
    /// pins). Constructing the adapter touches no authorization state.
    private static func makeAlarmKitSystemScheduler() -> AlarmKitTimerScheduling? {
        if #available(iOS 26.0, *) {
            return AlarmKitSystemScheduler()
        }
        return nil
    }
}

extension AppCoordinator: VoiceCommandCoordinating {
    /// [MORNING-BRIEFING] (2026-09-07) Voice-OS shell v1 — the router's
    /// "read me my briefing" hook. `fire()` is idempotent per calendar
    /// day and shares its once-per-day budget with the activation
    /// trigger, so command + activation can never double-speak.
    func fireMorningBriefing() {
        guard let morningBriefing else { return }
        Task {
            await morningBriefing.fire()
            // Briefing persistence task, 2026-09-08: surface the composed
            // day slot on Home right away (a same-day no-op re-reads the
            // earlier composition — never clobbers it).
            await MainActor.run { self.refreshTodayBriefing() }
        }
    }

    /// [NEWS-READER] (2026-09-08) The router's "read me the news" hook.
    /// The reader announces its checking line, fetches and speaks the
    /// digest — all through the shell's speak queue, with its own card.
    /// On-demand: no once-per-day budget; the reader's own in-flight
    /// guard makes a repeat command an honest "already fetching" line.
    func fireNewsReader() {
        guard let newsReader else { return }
        Task {
            await newsReader.fire()
        }
    }
}

// MARK: - Voice-OS shell v1: push-speech card presentation

extension AppCoordinator {
    /// Surfaces the speak queue's announcement card through the EXISTING
    /// Home outcome-card presentation (speech + card, spec §4.6). The
    /// card IS the content of a push announcement (briefing composition,
    /// notification read-aloud) — there is no user command behind it —
    /// so the transcript row is always omitted and the icon/text come
    /// from the announcement. Cards persist after speech ends: the queue
    /// clears only its own `currentCard`, never this outcome.
    fileprivate func presentShellCard(_ card: AnnouncementCard) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastOutcome = OutcomeSummary(
                icon: card.symbolName,
                text: card.body.isEmpty ? card.title : card.body,
                transcript: nil,
                timestamp: Date(),
                undo: nil
            )
        }
    }
}

// MARK: - Voice-OS shell v1: speech-note forwarder (SpeakQueue adapter)

/// Adapts the coordinator's per-utterance speech notes (wake-word gate,
/// voice-session speaking state) onto the `Speaker` instance the
/// `SpeakQueue` owns, so pushed announcements and interactive replies
/// keep the same note balance as the direct-speak path. Speech nests and
/// queue-initiated preemption cancels mid-utterance: the note pair fires
/// around every single `speak` call, so `speakingCount` always returns
/// to zero.
fileprivate final class SpeechNoteForwarder: Speaker {
    private let inner: Speaker
    private let onStarted: () -> Void
    private let onEnded: () -> Void

    init(speaker: Speaker,
         onStarted: @escaping () -> Void,
         onEnded: @escaping () -> Void) {
        self.inner = speaker
        self.onStarted = onStarted
        self.onEnded = onEnded
    }

    func speak(_ text: String, locale: Locale) async {
        onStarted()
        await inner.speak(text, locale: locale)
        onEnded()
    }

    func cancel() {
        inner.cancel()
    }
}

// MARK: - [FEED-AGENT] Feed agent (feed leaf + Settings → Feeds)

extension AppCoordinator {

    /// Full refresh WITH the loading state (feed-agent task, 2026-09-08)
    /// — the Refresh/Retry buttons, where the user asked for a fetch and
    /// deserves the visible "loading" feedback.
    func refreshFeed() async {
        guard feedLoadState != .loading else { return }
        feedLoadState = .loading
        await performFeedRefresh()
    }

    /// Refresh-on-appear with TTL: the leaf's `.task` calls this so the
    /// service can serve its cache while fresh — the network is never
    /// thrashed by re-entry, and the loading card only shows for the
    /// FIRST load (re-appearing with content on screen refreshes
    /// silently behind the existing cards).
    func refreshFeedIfNeeded() async {
        guard feedLoadState != .loading else { return }
        if feedLoadState == .idle {
            feedLoadState = .loading
        }
        await performFeedRefresh()
    }

    /// The shared fetch + state mapping. Post-await published updates
    /// hop to the main actor so SwiftUI observes them coherently (the
    /// house `refreshTodayBriefing` pattern).
    private func performFeedRefresh() async {
        let result = await feedService.refresh()
        await MainActor.run { [self] in
            feedItems = FeedLanguageSorter.sort(result.items, app: appLanguage)
            feedFailedSourceNames = result.failedSourceNames
            // Honest state mapping: empty + failures = the failed card
            // (something is wrong); empty + clean = the honest
            // "nothing here" empty state.
            feedLoadState = result.items.isEmpty && !result.failedSourceNames.isEmpty
                ? .failed : .loaded
        }
        // Progressive translation (feed translation task, 2026-09-09):
        // the items above published FIRST — cards always render the
        // original text immediately — and this pass then translates the
        // visible batch of fallback-language items in the background;
        // each translation swaps in when it lands. Nepali locale only
        // (gated inside); an English locale translates nothing.
        if appLanguage == .nepali {
            await translateVisibleFeedItems()
        }
    }

    /// Progressive translation pass (feed translation task, 2026-09-09):
    /// ONE batched provider call for the first `FeedTranslator.batchSize`
    /// NOT-yet-translated Latin-script items of the composed feed — the
    /// visible page — run automatically after every refresh on a Nepali
    /// locale. Later batches follow on later passes (the item-id cache
    /// skips what is done, so repeated leaf visits converge the whole
    /// bottom group). Per-item failures keep the original + the honest
    /// caption; the per-item retry path (`translateFeedItem`) covers
    /// anything the user asks for explicitly.
    private func translateVisibleFeedItems() async {
        let candidates: [FeedItem] = await MainActor.run {
            let selected = Array(feedItems.filter { item in
                FeedLanguageDetector.language(of: item) == .latin
                    && feedTranslations[item.id] == nil
                    && !feedTranslatingIDs.contains(item.id)
            }.prefix(FeedTranslator.batchSize))
            for item in selected {
                feedTranslatingIDs.insert(item.id)
                feedTranslationFailedIDs.remove(item.id)
            }
            return selected
        }
        guard !candidates.isEmpty else { return }
        let results = await feedTranslator.translateBatch(candidates,
                                                          language: .nepali)
        await MainActor.run { [self] in
            for (item, outcome) in results {
                switch outcome {
                case .success(let translation):
                    feedTranslations[item.id] = translation
                    feedTranslationFailedIDs.remove(item.id)
                case .failure:
                    feedTranslationFailedIDs.insert(item.id)
                }
                feedTranslatingIDs.remove(item.id)
            }
            feedTranslations = FeedTranslator.trimmed(feedTranslations)
        }
    }

    /// Adds a feed source (Settings → Feeds). False keeps the form's
    /// draft on screen (duplicate/invalid/cap/storage failure — the
    /// store is the gate; nothing is claimed that didn't happen).
    @discardableResult
    func addFeedSource(name: String, urlString: String) -> Bool {
        let added = feedSettingsStore.addSource(name: name, urlString: urlString)
        reloadFeedConfig()
        return added
    }

    func removeFeedSource(id: String) {
        feedSettingsStore.removeSource(id: id)
        reloadFeedConfig()
    }

    /// Adds a topic keyword. Same honest-false contract as the source
    /// add (duplicate/cap/empty rejected by the store).
    @discardableResult
    func addFeedTopic(_ topic: String) -> Bool {
        let added = feedSettingsStore.addTopic(topic)
        reloadFeedConfig()
        return added
    }

    func removeFeedTopic(_ topic: String) {
        feedSettingsStore.removeTopic(topic)
        reloadFeedConfig()
    }

    /// Re-reads the store into the published lists after any mutation —
    /// the single path both the Settings leaf and the next refresh's
    /// config read through, so UI and service can never disagree.
    private func reloadFeedConfig() {
        let config = feedSettingsStore.load()
        feedSources = config.sources
        feedTopics = config.topics
    }

    // MARK: Feed translation (on-ask, feed translation task 2026-09-08)

    /// The cached translation for an item (nil = not translated in this
    /// session) — the card's display resolution and toggle read this.
    func feedTranslation(for item: FeedItem) -> FeedTranslation? {
        feedTranslations[item.id]
    }

    /// True while the item's Translate request is in flight — the card's
    /// button shows a spinner and ignores taps.
    func isFeedItemTranslating(_ item: FeedItem) -> Bool {
        feedTranslatingIDs.contains(item.id)
    }

    /// True when the item's last Translate attempt FAILED — the card's
    /// honest caption (`feeds.translationUnavailable`); the original
    /// text stays visible.
    func feedTranslationFailed(for item: FeedItem) -> Bool {
        feedTranslationFailedIDs.contains(item.id)
    }

    /// Translate-on-ask: the card's Translate button is the ONLY trigger
    /// (no auto-translation anywhere in the refresh path). Success
    /// caches under the item id (session scope, capped); failure
    /// records the item so the card shows the honest caption and a tap
    /// retries. Either way the ORIGINAL text stays on screen until a
    /// real translation exists — nothing is ever fabricated.
    func translateFeedItem(_ item: FeedItem) async {
        guard !feedTranslatingIDs.contains(item.id) else { return }
        feedTranslatingIDs.insert(item.id)
        feedTranslationFailedIDs.remove(item.id)
        do {
            let translation = try await feedTranslator.translate(
                title: item.title, summary: item.summary, language: appLanguage)
            await MainActor.run { [self] in
                feedTranslations[item.id] = translation
                feedTranslations = FeedTranslator.trimmed(feedTranslations)
                feedTranslatingIDs.remove(item.id)
            }
        } catch {
            await MainActor.run { [self] in
                feedTranslationFailedIDs.insert(item.id)
                feedTranslatingIDs.remove(item.id)
            }
        }
    }
}

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

// MARK: - Voice personalization seams ([VOICE-SETTINGS])

/// Noise-filter toggle: the coordinator's `@Published noiseFilterEnabled`
/// already persists the UserDefaults key AND hot-swaps the pipeline's
/// `NoiseSuppressor` — the single writer the Voice personalization
/// screen binds through.
extension AppCoordinator: NoiseFilterPreferenceControlling {}

// [WARM-START] The coordinator owns the warm-start preference (persists
// the UserDefaults key AND is the value the boot's warm phase reads) —
// the Settings model only forwards, exactly like the noise toggle.
extension AppCoordinator: WarmStartPreferenceControlling {}

/// Pipeline suspension around one enrollment sample: the same
/// stop → capture → start cycle as `startSearchPhraseCapture`, minus
/// the capture itself (the enrollment session owns that). Refuses while
/// a talk cycle is mid-flight or the assistant is mid-reply — the same
/// `.busy` reasoning as the search capture.
extension AppCoordinator: VoicePipelineSuspending {

    func suspendForSampleCapture() -> Bool {
        guard let voicePipeline else { return true }
        switch voicePipeline.state {
        case .idle:
            guard speakingCount == 0 else { return false }
            voiceWasSuspendedForEnrollmentSample = true
            voicePipeline.stop()
            return true
        case .capturingCommand, .processing, .routing:
            return false
        case .stopped, .error:
            // Nothing to suspend, but stop anyway: a half-failed start
            // (.error paths can leave the engine running with a tap
            // installed) must never collide with the capture's own tap.
            voiceWasSuspendedForEnrollmentSample = false
            voicePipeline.stop()
            return true
        }
    }

    func resumeAfterSampleCapture() {
        guard voiceWasSuspendedForEnrollmentSample else { return }
        voiceWasSuspendedForEnrollmentSample = false
        // [BOOT-REVIEW P0-2] Same honest reporting as the recycle above.
        noteVoicePipelineStartRequested()
        voicePipeline?.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
                self.noteVoicePipelineStartSucceeded()
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
                self.noteVoicePipelineStartFailed(err)
            }
        }
    }
}
