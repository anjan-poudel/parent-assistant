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
        externalCalendar.locale = activeLocale
        alarmTimersService.locale = activeLocale
        // Voice-OS shell v1: the briefing composes in the app language,
        // same injection pattern as every other locale-aware service.
        morningBriefing?.locale = activeLocale
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
    private let wakeWordEngine: WakeWordEngine
    private let voiceActivityDetector: VoiceActivityDetector
    private var voicePipeline: VoicePipeline!
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
    @Published private(set) var todayBriefing: StoredBriefing?

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
    let searchConfigStore: SearchConfigStore

    /// [TOOL-DEBUG-LOG] (2026-09-07) Encrypted debug log of every
    /// local-tool (weather + web search) request and outcome — the store
    /// behind Settings → Tool requests (review + family export). Same
    /// lazy pattern as the intent-layer stores: `storage` is assigned at
    /// the top of `init`, long before any voice turn can record one, and
    /// `start()` injects it into the `CommandRouter` it builds.
    private(set) lazy var localToolLogStore = LocalToolLogStore(storage: storage)

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

    /// Consulted by the voice pipeline for every idle-state audio chunk
    /// and inbound wake detection: closed while the assistant's own TTS is
    /// playing (self-hearing mitigation — see `WakeWordActivityGate`) or
    /// listening is switched off in Settings. Written on the main queue
    /// (noteSpeakingStarted/Ended, the Settings binding), read on the mic
    /// tap's processing queue — the lock lives inside the gate.
    private let wakeWordActivityGate = WakeWordActivityGate()

    /// Whether the engine built in `init` is a REAL sherpa-onnx KWS engine
    /// (vs the Null fallback). Recorded once so Settings → "Voice
    /// activation" can truthfully distinguish active / needs-setup /
    /// off-at-launch.
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
    private(set) var pluginRegistry: PluginRegistry!

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
    static let defaultBrainModelID = ModelCatalog.llama3_2_1B

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

        // Saved navigation places (directions task, 2026-09-07) —
        // encrypted like the contacts above; loaded immediately so the
        // published list (Settings editor) and the router's candidate
        // list start populated. The store self-heals legacy payloads on
        // this read (hard default-home invariant).
        let placeStore = SavedPlaceStore(storage: storage)
        self.placeStore = placeStore
        self.savedPlaces = placeStore.load()

        // Doctor's appointments (medical task, 2026-09-07) — encrypted
        // like the contacts above; loaded immediately so the published
        // list (Medical leaf) starts populated. The store invokes the
        // `MedicalAppointmentCalendarWriting` seam (calendar-2way) on
        // every save/remove when the toggle below is on; the shipped
        // Noop writer means nothing happens until the integrator swaps
        // in the EventKit backend.
        let appointmentStore = AppointmentStore(storage: storage)
        self.appointmentStore = appointmentStore
        self.appointments = appointmentStore.load()

        // Morning-briefing day slot (briefing persistence task,
        // 2026-09-08) — encrypted like the stores above (the composed
        // text embeds medication names and event titles). Loaded here so
        // a relaunch mid-day still shows the day's stored briefing on
        // Home; `MorningBriefing.fire()` writes through the same
        // instance (passed in `start()`), and every activation + fire
        // completion re-reads it into the published `todayBriefing`.
        let briefingStore = MorningBriefingStore(storage: storage)
        self.morningBriefingStore = briefingStore
        self.todayBriefing = briefingStore.todaysBriefing(now: Date())

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
        let alarmTimersService = AlarmTimersService(
            store: AlarmTimersStore(storage: storage),
            scheduler: AlarmScheduler(
                notifications: UNNotificationCenterScheduler()
            ),
            observabilityBus: bus
        )
        self.alarmTimersService = alarmTimersService

        // Foreground notification delegate for alarms/timers. Constructed
        // and RETAINED here — the center's delegate property is weak, so
        // the coordinator owns the delegate's lifetime. The app had NO
        // notification delegate before this feature (medication/routine
        // banners only ever presented from the OS); this delegate presents
        // alarm/timer notifications while the app is foregrounded and
        // reports timer completions up for spoken output — every other
        // notification keeps its old silent-foreground behavior (see
        // `AlarmTimerNotificationDelegate`). Construction touches no
        // permissions; its completion closure is attached at the end of
        // init because it captures self.
        let alarmTimerDelegate = AlarmTimerNotificationDelegate()
        self.alarmTimerNotificationDelegate = alarmTimerDelegate
        UNUserNotificationCenter.current().delegate = alarmTimerDelegate

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

        // [LOCAL-TOOLS] (2026-09-07): Google Custom Search credentials for
        // the on-device-stack web-search tool (Settings → Web search).
        // Deliberately created BEFORE the router below — the router must
        // receive the store (not nil) or the search hook stays dormant.
        self.searchConfigStore = SearchConfigStore(storage: storage)

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
        let wakeWordLaunch = Self.makeWakeWordEngine(observabilityBus: bus)
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

        // Restore the persisted brain-model choice BEFORE the interpreter
        // is constructed so its base model is the live one from the very
        // first inference. Unknown IDs (a model removed from the catalog,
        // or a bad stored value) are ignored so a stale preference can't
        // wedge the picker — same rule as `sttModelPreference` below.
        // Resolved into a LOCAL: `resolvedBrainModelID` reads `self`,
        // which init may not do before every stored property is set.
        // Sampling is NOT configurable here — every on-device brain runs
        // deterministic temp-0 + fixed-seed sampling through
        // `OnDeviceSampling` ([NO-GIBBERISH] 2026-09-07).
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

        self.llamaCommandInterpreter = LlamaCommandInterpreter(
            modelStore: modelStore,
            observabilityBus: bus,
            preferredBaseId: restoredBrain ?? Self.defaultBrainModelID,
            config: LlamaCommandInterpreter.Config(confidenceThreshold: 0.4,
                                                   maxTokens: 128,
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

        // Restore the persisted cloud-fallback opt-in (default OFF — the
        // strictly-on-device contract) and its provider (default Gemini).
        // These are the properties' ONLY initial assignments, so their
        // didSets do not fire here (same rule as `voiceEngineStack`
        // above); `applyVoiceEngineStack()` — which runs once in the
        // startup callback — applies the restored opt-in for real.
        self.cloudFallbackEnabled = UserDefaults.standard.bool(forKey: Self.cloudFallbackKey)
        self.cloudProvider = UserDefaults.standard.string(forKey: Self.cloudProviderKey)
            .flatMap(CloudProvider.init(rawValue:)) ?? .gemini

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
        }
        // Forward the external calendar service's publishes (Settings
        // status/lead, scan results reaching the Reminders + Calendar
        // leaves) — nested ObservableObject, see the property docs.
        externalCalendarCancellable = externalCalendar.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Forward the alarms/timers service's publishes ([ALARMS-TIMERS]
        // 2026-09-07) — nested ObservableObject, same pattern as the
        // external-calendar forwarding above: the Settings leaf observes
        // the coordinator, so a toggle/delete/timer-start must invalidate
        // it through this sink.
        alarmTimersCancellable = alarmTimersService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Foreground timer-completion reporting ([ALARMS-TIMERS]
        // 2026-09-07): the retained delegate reports finished timers up
        // through this closure — the row is expired and the completion is
        // SPOKEN while the app is active (a chime the user cannot see is
        // useless to someone already looking at the phone). Attached here
        // (not next to the delegate's construction) because the closure
        // captures self.
        alarmTimerNotificationDelegate?.onForegroundTimerFinished = { [weak self] timerID in
            self?.handleForegroundTimerFinished(timerID: timerID)
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

        // Activity history (call-history task, 2026-09-06): prime the
        // leaf's window from disk — rows from previous launches must show
        // even before anything new is recorded this session.
        refreshRecentActivity()

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
        // Same re-queue for alarms + timers ([ALARMS-TIMERS] 2026-09-07 —
        // idempotent: pending requests replace in place by id, and
        // expired timer rows are pruned first).
        alarmTimersService.scheduleAll()

        // Festival notifications (BS calendar, 2026-09-06): day-of for
        // every catalog festival + advance N-day reminders for important
        // ones (default 2, Settings-configurable). Idempotent rebuild.
        festivalCalendar.scheduleAll()

        // Read-only native Calendar/Reminders integration (2026-09-07):
        // launch-time refresh — NO prompts (startIfEnabled only scans
        // when the family already enabled + granted access), then the
        // hourly BGAppRefresh keeps it current while backgrounded.
        Task { await externalCalendar.startIfEnabled() }
        // Mirror staleness fix: re-mirror at launch when enabled (the
        // restored status survives relaunches now), so the family's
        // calendar view of the routine is current from a fresh start.
        if calendarSync.isEnabled {
            calendarSync.syncNow(entries: routineScheduler.entries())
        }

        // Two-way mirroring (calendar-driven task, 2026-09-07): the
        // coordinator relays native edits — family changes made in the
        // Calendar app on Sahayak mirror events — back into
        // RoutineScheduler's mutators, so persistence, re-arming and
        // the mirror re-sync stay on the one mutation path. The
        // Sahayak calendar id (restored from the link store) is
        // excluded from the read-only import: those events ARE the
        // routine, whose alarms fire in-app already.
        calendarSync.entriesProvider = { [weak self] in
            self?.routineScheduler.entries() ?? []
        }
        calendarSync.onNativeChanges = { [weak self] mutations in
            self?.applyNativeCalendarMutations(mutations)
        }
        if let sahayakIdentifier = calendarSync.sahayakCalendarIdentifier {
            externalCalendar.excludedCalendarIdentifiers.insert(sahayakIdentifier)
        }

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
        let registry = SpeechSourceRegistry(observabilityBus: observabilityBus)
        registry.register(notificationReader)
        registry.register(briefing)
        // Single UNUserNotificationCenter delegate (design §2 confirmed
        // decision — verified no other object in the app owns this slot).
        let facade = NotificationFacade(handlers: [notificationReader],
                                         observability: observabilityBus)
        UNUserNotificationCenter.current().delegate = facade
        self.speakQueue = queue
        self.speechSourceRegistry = registry
        self.notificationFacade = facade
        self.morningBriefing = briefing
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
        // Interpreter-availability fix (2026-09-06): restore the
        // assistant-brain model's one-time auto-download. The v2 pivot
        // removed ALL first-run downloads, so the LLaMA stand-in that
        // LocalBrainChain restores below (commit 13ded79) could never
        // come online on a real device — the chain sat empty and every
        // plain utterance fell through to the generic "didn't understand"
        // re-prompt despite a correct transcript. `start()` is idempotent
        // (onboarding wizard and Home both call it) and
        // `ModelDownloadService.start` no-ops while a download is already
        // in flight or completed, so this is safe to run on every launch;
        // when the Gemini stack is live no download starts at all.
        ensureAssistantBrainDownloadIfNeeded()
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
            localToolLogStore: localToolLogStore
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
            // Voice Processing I/O preset A/B (P0, slice C): a flip that
            // landed mid-turn applies now the pipeline has settled back
            // to idle — and only once no reply is playing (every speech
            // end re-runs this case via `noteSpeakingEnded`).
            if pendingVoiceProcessingPresetChange, speakingCount == 0 {
                pendingVoiceProcessingPresetChange = false
                applyVoiceProcessingPresetChange()
            }
        case .capturingCommand:
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
        voicePipeline?.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.voiceState = .idle
            case .failure(let err):
                self.voiceError = "\(err)"
                self.voiceState = .error("\(err)")
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

    // MARK: - Family & friends — curated contacts (spec §4.4.2)

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
                          isEmergencyContact: Bool = false) -> Bool {
        let filename = photo.flatMap { contactPhotoStore.save($0) }
        let contact = FamilyContact(name: name, phone: phone, relationship: relationship,
                                    messengerHandle: messengerHandle,
                                    photoFilename: filename,
                                    nickname: nickname,
                                    address: Self.normalizedOptionalText(address),
                                    isEmergencyContact: isEmergencyContact)
        guard familyContactStore.add(contact) else {
            if let filename { contactPhotoStore.delete(named: filename) }
            return false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.familyContacts = self.familyContactStore.load()
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
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
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
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
            self.familyNotifier.updateContacts(Self.emergencyContacts(from: self.familyContacts))
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

    /// Launches a quick-access app from the Home row / picker, with the
    /// dual-channel honesty every open path holds: probe FIRST, and when
    /// the app is gone (deleted after the row appeared) say so out loud
    /// and show it on the outcome card — never a silent dead tap. One
    /// `app_launcher` event per attempt; the outcome names which surface
    /// appeared (`<id>:opened`) or why nothing did (`<id>:notInstalled`).
    func performAppLaunch(_ app: AppLauncher.App) {
        let locale = activeLocale
        let name = L10n.str(app.nameKey, locale: locale)
        guard isAppInstalled(app) else {
            let text = L10n.fmt("apps.announce.notInstalled", locale: locale, name)
            setOutcome(icon: "exclamationmark.triangle.fill", text: text)
            speak(text: text)
            emitAppLaunch(outcome: "\(app.id):notInstalled")
            return
        }
        appLauncher.open(app)
        let text = L10n.fmt("apps.announce.opened", locale: locale, name)
        setOutcome(icon: app.systemImage, text: text)
        speak(text: text)
        emitAppLaunch(outcome: "\(app.id):opened")
    }

    private func emitAppLaunch(outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "app_launcher",
            eventType: "launch",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]  // catalog app id only — no contact identifiers (C9)
        ))
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
                    : MapsLinks.googleMapsDirectionsURL(address: address,
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
        presentPluginView(AnyView(ApplianceHelperView(session: session)))
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
        presentPluginView(AnyView(ApplianceHelperView(session: session)))
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

    // MARK: - Native Calendar mirroring (v2 design §4.1, 2026-09-06)

    /// EventKit mirror of the unified routine schedule — the app remains
    /// the source of truth; the native Calendar is a read mirror so
    /// family can see the routine in any calendar app. Permission
    /// denial = honest local-only mode, never a crash. Mirrors the
    /// peer reminders-v2 `RoutineEntry` model (which owns categories
    /// natively — the parallel tag-store approach from the same merge
    /// was dropped in favor of it).
    private(set) lazy var calendarSync = CalendarSyncService(observabilityBus: observabilityBus)

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

    /// [ALARMS-TIMERS] (2026-09-07) Foreground presentation for
    /// alarm/timer notifications. RETAINED here — the center's delegate
    /// property is weak, and before this feature the app had no
    /// notification delegate at all (medication/routine reminders
    /// presented via the OS alone). See `AlarmTimerNotificationDelegate`
    /// for what presents and what stays silent.
    private var alarmTimerNotificationDelegate: AlarmTimerNotificationDelegate?

    /// Forwards the alarms/timers service's publishes ([ALARMS-TIMERS]
    /// 2026-09-07): nested ObservableObject — a toggle/delete/timer-start
    /// alone would not invalidate views observing the coordinator (same
    /// pattern as `externalCalendarCancellable`).
    private var alarmTimersCancellable: AnyCancellable?

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
        case .background:
            externalCalendar.submitBackgroundRefresh()
        default:
            break
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
    /// [DIRECTIONS] (2026-09-07) The navigation ambiguity walk pends the
    /// same way — while candidates remain, the router's yes/no parsing
    /// stays in force.
    var isAwaitingConfirmation: Bool {
        pendingConfirmationEntryId != nil || pendingCallAction != nil || pendingRephrase != nil
            || !pendingNavigationWalk.isEmpty
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
        guard let real = WakeWordEngineSelection.make(
            toggleEnabled: WakeWordPreferences().isEnabled,
            sherpaCandidate: {
                SherpaKWSWakeWordEngine.attempt(observabilityBus: observabilityBus)
            }
        ) else {
            print("[AppCoordinator] Wake-word engine: NullWakeWordEngine "
                  + "(toggle off or sherpa model missing) — "
                  + "Talk button + simulate path unchanged")
            return (NullWakeWordEngine(), false)
        }
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

    /// [ALARMS-TIMERS] (2026-09-07) Voice + UI alarm creation — the
    /// router's alarm stage and the Settings leaf both land here. The
    /// notification-permission round-trip happens at point of use inside
    /// the service; the outcome drives the router's honest spoken line
    /// (and the leaf's error text).
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome {
        await alarmTimersService.addAlarm(at: time, label: label)
    }

    /// [ALARMS-TIMERS] (2026-09-07) Voice + UI timer start — same
    /// contract as `requestAlarmSet` for the in-app countdown timers.
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
        await alarmTimersService.startTimer(durationSeconds: durationSeconds, label: label)
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

    /// [ALARMS-TIMERS] (2026-09-07) A timer's completion notification
    /// arrived while the app was foregrounded (the retained
    /// `AlarmTimerNotificationDelegate` closure — possibly off main): the
    /// service expires the row (it dispatches to main itself), then the
    /// completion surfaces as an outcome card and is spoken. The spoken
    /// line matters: a countdown the user set by voice should end in a
    /// voice when they are looking at the phone, not just a banner.
    func handleForegroundTimerFinished(timerID: UUID) {
        alarmTimersService.expireTimer(id: timerID)
        let text = L10n.str("timers.finished", locale: activeLocale)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setOutcome(icon: "timer", text: text, undo: nil)
            self.speak(text: text)
        }
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
