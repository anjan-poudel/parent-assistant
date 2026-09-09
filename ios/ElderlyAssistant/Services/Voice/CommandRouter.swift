import Foundation
import UserNotifications
import SwiftUI

/// Honest interpreter-chain status for the router's no-brain fallback
/// (spec §7 "no dead ends"; interpreter-availability fix 2026-09-06).
///
/// Before this type existed, `routeKeywordRemainder` spoke the generic
/// "didn't understand" re-prompt whenever interpretation came back nil —
/// a lie when the transcript was correct and NO interpreter existed to
/// hear the utterance at all (the on-device stack before the LLaMA GGUF
/// is cached; the Gemini stack before an API key is configured). The
/// coordinator owns the chain wiring AND the model-download state, so it
/// derives the readiness the router speaks against:
///
///  - `.available` — a real brain can answer. A nil interpretation here
///    means the brain genuinely didn't understand, so the generic
///    re-prompt stays honest and is what the router speaks.
///  - `.downloadingBrain` — no brain yet, but the assistant-brain model
///    is downloading (one-time, ~1 GB). Say THAT instead of pretending
///    the user misspoke.
///  - `.needsSetup` — no brain and nothing in flight (download failed or
///    gated, runtime missing). The unblock is Settings (model download
///    or Gemini key), and the message says so.
enum BrainReadiness: Equatable {
    case available
    case downloadingBrain
    case needsSetup

    /// Mirrors the exact layer ladder `IntentRouter` consults at route
    /// time: the local brain, else the cloud brain ONLY when the stack
    /// allows cloud (`cloudEnabled` — the on-device stack ignores a
    /// configured Gemini key, exactly like the router's escalation
    /// guard does). `brainDownloadInFlight` is what distinguishes the
    /// two honest no-brain messages.
    static func resolve(localBrainAvailable: Bool,
                        cloudEnabled: Bool,
                        cloudBrainAvailable: Bool,
                        brainDownloadInFlight: Bool) -> BrainReadiness {
        if localBrainAvailable || (cloudEnabled && cloudBrainAvailable) {
            return .available
        }
        return brainDownloadInFlight ? .downloadingBrain : .needsSetup
    }
}

protocol VoiceCommandCoordinating: AnyObject {
    var isAwaitingConfirmation: Bool { get }
    /// Interpreter-chain status for the router's fallback speech (spec
    /// §7 no dead ends; 2026-09-06) — the coordinator derives it because
    /// it owns the chain wiring and the model-download state; the router
    /// only decides which (localized) message to speak. See
    /// `BrainReadiness` for the three states and their speech.
    var brainReadiness: BrainReadiness { get }
    /// True only while a `call` intent is specifically awaiting its
    /// yes/no — lets `CommandRouter` skip its generic confirmation speech
    /// and let the coordinator speak its own call-specific response
    /// instead, without touching the existing medication-confirmation
    /// wiring at all.
    var isAwaitingCallConfirmation: Bool { get }
    /// The locale all spoken replies resolve against (spec §3.2 — the
    /// coordinator's `AppLanguage` is the source of truth).
    var activeLocale: Locale { get }

    func recordTranscript(_ text: String)
    func oldestPendingReminderEntryId() -> UUID?
    func handleMedicationAcknowledgement(entryId: UUID)
    func startVoiceAckConfirmation(for entryId: UUID) -> String?
    func handleConfirmationResponse(_ response: ConfirmationResponse)

    // Voice-session feedback (spec §3.3): the derived `speaking` state and
    // the Home conversation card's assistant bubble.
    func noteSpeakingStarted()
    func noteSpeakingEnded()
    func noteAssistantSpoke(_ text: String)

    /// Generic dual-channel confirmation for replies with no more specific
    /// tracked outcome (plain Q&A, stub replies) — see
    /// `AppCoordinator.noteGenericReply` for why this exists.
    func noteGenericReply(_ text: String)

    /// `set_reminder` intent: creates a reminder through scheduler storage.
    func addVoiceReminder(title: String, time: DateComponents)

    /// `call` intent (2026-09-05: "ai determines intent, then ask
    /// permission and execute"). Resolves `name` (a contact's name OR
    /// relationship, e.g. "छोरा") against family contacts, picks the best
    /// REAL method for `requestedApp`/`callType` (see
    /// `AppCoordinator.CallMethod`), and returns the confirmation prompt
    /// to speak. Returns nil when no contact can be resolved — the router
    /// falls back to the existing blocked/unrecognised message rather
    /// than claiming success. Nothing is dialed until the user says yes.
    /// `sourceTranscript` + `sourceCommand` thread the ORIGINAL utterance
    /// through so a confirmed execution can teach the intent→command
    /// cache (spec 2026-09-05 §4.2: the cache learns from confirmed
    /// executions only) — nil when the call didn't originate from an
    /// interpreted transcript.
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String?

    /// Rephrase-as-question (spec §4 REPHRASE band, open decision #6):
    /// a mid-confidence tier-`free` interpretation is stated as a yes/no
    /// question instead of being dropped. The coordinator pends the
    /// command, speaks the question; on yes the router takes it back via
    /// `takePendingRephraseCommand` and dispatches it normally.
    var pendingRephraseCommand: InterpretedCommand? { get }
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?)
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)?

    /// Call-confirmation correction hook (spec §7.2 correction protocol).
    /// While a call confirmation is outstanding, the router hands each
    /// response utterance here FIRST: an utterance carrying a method
    /// override ("होइन, फोन नै गर") rebuilds the pending call and
    /// re-confirms. Returns true when it handled the utterance; false
    /// means "not an override — run the normal yes/no flow".
    func handleCallConfirmationOverride(_ utterance: String) -> Bool

    /// `send_message` intent. iOS never lets a third-party app send a
    /// message silently — every surface ends with the user's own tap on
    /// Send, which IS the confirmation for the `.confirm` tier (same
    /// model the SMS compose sheet shipped with). `requestedApp` routes
    /// the surface: WhatsApp named → `whatsapp://send` deep link with the
    /// body pre-filled (app-absent fallbacks disclosed inside, v2 §4.3);
    /// otherwise the native compose sheet. The returned outcome says
    /// which surface actually appeared, so the router can emit the right
    /// event and leave the honest spoken line to the coordinator.
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome

    /// `.plugin` intent: presents a plugin-provided view (e.g. the
    /// appliance photo + overlay). AppCoordinator publishes it;
    /// ContentView renders the sheet.
    func presentPluginView(_ view: AnyView)

    /// Voice-driven contact search (voice-contact-search, 2026-09-07):
    /// the keyword pre-route ("मैयाको फोन नम्बर खोज" / "maiya ko phone
    /// khoja") requests a Phone-screen search. The coordinator publishes
    /// it so HomeView can push the Call leaf and the leaf can prefill
    /// its search field with `query` (nil = navigate but leave the
    /// field empty). Zero-touch hands-free: nothing is spoken here —
    /// the leaf announces the result once the search has run.
    func requestContactSearch(query: String?)

    /// [INTENT-TOOLS] (2026-09-07) Tool-capability surface. True only when
    /// the coordinator's interpreter chain can answer open-domain
    /// questions from LIVE web data (Gemini Google-Search grounding). The
    /// router yields the deterministic weather pre-answer ("weather data
    /// is unavailable on-device") to the interpreter when this is true —
    /// with the cloud on, a forecast question deserves a real grounded
    /// forecast, not the no-data answer; with it false (on-device stack,
    /// cloud disabled, or brain unavailable), the honest deterministic
    /// answer stands. Deliberately a REQUIREMENT with the default in the
    /// extension below: an extension-only member (no requirement) binds
    /// statically when looked up through a protocol-typed reference, and
    /// `CommandRouter` holds its coordinator as `VoiceCommandCoordinating?`
    /// — the extension default would then shadow `AppCoordinator`'s
    /// opt-in and the weather yield could never fire in production.
    var canAnswerLiveQuestionsFromWeb: Bool { get }

    /// [LOCAL-TOOLS] (2026-09-07) Local-tools stack surface. True only when
    /// the coordinator's voice engine is the ON-DEVICE stack
    /// (`VoiceEngineStack == .onDevice`). The router fires the live
    /// weather/search tools only on that stack: the Gemini cloud stack
    /// answers open-domain questions natively (grounded search), so the
    /// local tools would be redundant — and gated off — there. Same
    /// requirement-with-extension-default pattern as
    /// `canAnswerLiveQuestionsFromWeb` (see above for why a requirement is
    /// mandatory when the router holds the coordinator as a protocol
    /// reference).
    var isOnDeviceStack: Bool { get }

    /// [DIRECTIONS] (2026-09-07) Navigation-target surface: the places a
    /// voice-navigation request may drive to — saved places and family
    /// contacts that carry a non-empty address, merged and trimmed by the
    /// coordinator (`AppCoordinator` builds this from `SavedPlaceStore`
    /// + `FamilyContactStore`). Requirement-with-extension-default pattern
    /// like the tool surfaces above: the router holds the coordinator as
    /// a protocol reference, so an extension-only member would bind
    /// statically and the coordinator's candidates could never reach the
    /// directions stage. The default `[]` keeps every conformer that does
    /// not opt in (existing mocks) on exactly the pre-directions
    /// behavior — with no candidates the stage can only resolve the bare
    /// home, and its default handlers stay silent.
    var navigationCandidates: [DirectionsCandidate] { get }

    /// [DIRECTIONS] (2026-09-07) Executes a resolved navigation request
    /// (default home / a saved place / a relative's address). The
    /// coordinator resolves the target to a concrete address, picks the
    /// map surface (`NavigationMapPolicy`), and owns every spoken line —
    /// including the honest fallbacks (`directions.noHome` when no home
    /// is saved, `directions.mapMissing` when no surface opens).
    func requestNavigation(to target: DirectionsRoute.PlaceTarget)

    /// [DIRECTIONS] (2026-09-07) Ambiguity walk: the decider found
    /// several candidates close to the spoken name ("मैया" — a saved
    /// place AND a relative), and the coordinator must never guess a
    /// PLACE any more than the call path guesses a person. The
    /// coordinator pends the candidates (setting
    /// `isAwaitingNavigationDisambiguation`), and RETURNS the localized
    /// yes/no question the router speaks — the first candidate asked
    /// first ("के मैयाको घर लैजाऊँ?"). Returns nil when it could not
    /// pend; the router then ends the turn without speech rather than
    /// route a directions utterance onward.
    func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String?

    /// [DIRECTIONS] (2026-09-07) True while a navigation ambiguity walk
    /// is outstanding. Widens the router's confirmation path exactly like
    /// `isAwaitingCallConfirmation`: the yes/no on the next transcript
    /// goes to `handleConfirmationResponse` (which walks the pending
    /// candidates), and the generic medication-flavored confirmation
    /// speech is skipped.
    var isAwaitingNavigationDisambiguation: Bool { get }

    /// [ALARMS-TIMERS] (2026-09-07) Requests an ALARM at `time` (already
    /// the next future occurrence; only its hour/minute-of-day matters —
    /// the OS alarm is a DAILY-repeating local notification, see
    /// `AlarmScheduler`; iOS does not let third-party apps write to the
    /// built-in Clock). ASYNC because notification permission is requested
    /// at POINT OF USE (the first alarm/timer set asks). The coordinator
    /// persists + arms and returns the outcome so the router speaks the
    /// honest line — a success confirmation only once the alarm actually
    /// rings, the denial fallback when notifications are off. Same
    /// requirement-with-extension-default pattern as the tool surfaces
    /// above: the router holds the coordinator as a protocol reference,
    /// so an extension-only member would bind statically and the
    /// coordinator's implementation could never be reached.
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome

    /// [ALARMS-TIMERS] (2026-09-07) Requests an in-app countdown TIMER of
    /// `durationSeconds` (1…86400; the countdown lives in the app, its
    /// completion fires a one-shot notification and — while the app is
    /// foregrounded — a spoken "Timer finished."). Same point-of-use
    /// permission, persist-then-arm contract and outcome contract as
    /// `requestAlarmSet`.
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome

    /// [ALARMS-TIMERS] (2026-09-08) Voice alarm OFF ("turn off the
    /// alarm", "अलार्म बन्द गर"): disables the most recently rung
    /// enabled alarm — persists `enabled=false`, clears any snooze and
    /// cancels the pending daily notification — and returns the honest
    /// outcome so the router speaks the confirmation (with the alarm's
    /// spoken time) or the "no alarms" / failure fallback. SYNCHRONOUS
    /// (disabling needs no permission round-trip), main-confined like
    /// the service. Same requirement-with-extension-default pattern as
    /// `requestAlarmSet` (the router holds the coordinator as a
    /// protocol reference).
    func requestAlarmOff() -> AlarmOffOutcome

    /// [ALARMS-TIMERS] (2026-09-08) Voice SNOOZE ("snooze", "snooze for
    /// 15 minutes", "स्नुज गर"): arms a ONE-SHOT re-wake notification
    /// `minutes` from now (parser default 10) for the most recently
    /// rung enabled alarm WITHOUT disturbing its daily repeat, and
    /// persists the snooze-until marker. Same synchronous
    /// outcome-returning contract as `requestAlarmOff`; the router
    /// speaks the honest "snoozed until <spoken time>" line on success.
    func requestAlarmSnooze(minutes: Int) -> AlarmSnoozeOutcome
    /// [MORNING-BRIEFING] (2026-09-07) Voice-OS shell v1: fires the
    /// proactive morning briefing ("read me my briefing"). The briefing
    /// speaks itself through the shell's speak queue (once per calendar
    /// day) and renders its own outcome card — the router adds no speech
    /// and no card of its own, exactly like a topic pre-answer that has
    /// already spoken.
    func fireMorningBriefing()

    /// [NEWS-READER] (2026-09-08) Voice-OS news digest ("read me the
    /// news"). The `NewsReader` announces its localized "checking" line,
    /// fetches every effective source and then speaks the composed digest
    /// itself through the shell's speak queue, with its own outcome card
    /// — the router adds no speech and no card of its own, exactly like
    /// the briefing stage. On-demand: no once-per-wake-window budget.
    func fireNewsReader()
}

/// [INTENT-TOOLS] (2026-09-07) Tool-capability default. The default keeps
/// every conformer that does not explicitly opt in (all mocks/doubles
/// across the app and the test target) on the fully deterministic path —
/// only a coordinator that explicitly returns true yields weather to the
/// live-web interpreter. [LOCAL-TOOLS] (2026-09-07) `isOnDeviceStack` rides
/// the same pattern: the default false leaves every existing conformer on
/// its exact pre-tool behavior; only `AppCoordinator` (and a scripted mock
/// under test) opt in.
extension VoiceCommandCoordinating {
    var canAnswerLiveQuestionsFromWeb: Bool { false }
    var isOnDeviceStack: Bool { false }
    // [DIRECTIONS] (2026-09-07) Navigation defaults — see the requirement
    // docs above. Every member is inert: no candidates, nothing pending,
    // a silent requestNavigation/requestNavigationDisambiguation. Only a
    // coordinator that explicitly opts in (AppCoordinator, and a scripted
    // mock under test) makes the directions stage do anything.
    var navigationCandidates: [DirectionsCandidate] { [] }
    var isAwaitingNavigationDisambiguation: Bool { false }
    func requestNavigation(to target: DirectionsRoute.PlaceTarget) {}
    func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? { nil }
    // [ALARMS-TIMERS] (2026-09-07) Alarm/timer defaults — see the
    // requirement docs above. Inert: a conformer that does not opt in
    // (mocks/doubles) reports .failed, and the router stage speaks the
    // honest "couldn't set it" fallback for its utterance. Only a
    // coordinator that explicitly implements the members (AppCoordinator,
    // and a scripted mock under test) makes the stage do anything.
    func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome { .failed }
    func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome { .failed }
    // [ALARMS-TIMERS] (2026-09-08) OFF/SNOOZE defaults — see the
    // requirement docs above. Inert: a conformer that does not opt in
    // (mocks/doubles) reports .noAlarm, and the router stage speaks the
    // honest "no alarms" line. Only a coordinator that explicitly
    // implements the members (AppCoordinator, and the scripted mock
    // under test) makes the stage do anything.
    func requestAlarmOff() -> AlarmOffOutcome { .noAlarm }
    func requestAlarmSnooze(minutes: Int) -> AlarmSnoozeOutcome { .noAlarm }
    // [MORNING-BRIEFING] (2026-09-07) Inert default — a conformer that
    // does not opt in (every mock/double across app and test target)
    // never fires a briefing, so the deterministic ladder stage falls
    // through to the interpreter/keyword remainder exactly as before.
    func fireMorningBriefing() {}
    // [NEWS-READER] (2026-09-08) Inert default — a conformer that does
    // not opt in (every mock/double across app and test target) never
    // fires a news digest, so the deterministic ladder stage falls
    // through to the interpreter/keyword remainder exactly as before.
    func fireNewsReader() {}
}

/// Turns a raw transcript into a coordinator call and a spoken reply.
///
/// Routing order:
///  1. LLM interpreter (`CommandInterpreter`), if available and confident.
///  2. Keyword-matching fallback for a small, safety-critical vocabulary.
///  3. "I didn't understand" — spoken back (localized).
///
/// Keeping the keyword layer around after the LLM lands is deliberate:
///  - it's the safety net if the LLM is warming up, unavailable, times out,
///    or the device is low on memory,
///  - it handles the tiny set of utterances we never want to depend on an
///    LLM being warm for ("emergency", explicit medication acks).
///
/// All fixed strings are catalog keys resolved against the coordinator's
/// active locale (spec §3.2); only LLM-generated replies are raw text.
final class CommandRouter {

    enum RoutingResult: Equatable {
        case acknowledgedMedication
        case blockedSensitiveAction
        case emergencyTriggered
        case callConfirmed
        case contactSearchRequested
        case navigationRequested
        case unrecognised(transcript: String)
    }

    private weak var coordinator: VoiceCommandCoordinating?
    private let observabilityBus: ObservabilityBus
    private let speaker: Speaker?
    private let interpreter: CommandInterpreter
    /// [TURN-TIMING] Turn-scoped stage tracer (nil = timing off — tests
    /// and any construction site that does not opt in).
    private let turnTracer: VoiceTurnLatencyTracer?

    /// [REST-DIP-FIX] (2026-09-08) Turn-scoped "async reply pending"
    /// token. Set while `route()` has handed the turn to an ASYNC
    /// dispatch whose reply speech is still outstanding — today that is
    /// the LLM interpreter round-trip: `interpreter.interpret` fires and
    /// its completion (IntentRouter: local brain / cloud preparse / cloud
    /// escalation) lands on an arbitrary queue seconds later, committing
    /// the reply (or the abstention re-prompt) only then.
    ///
    /// VoicePipeline reads the token right after `route()` returns: while
    /// it is set the pipeline DEFERS its return to `.idle` (see
    /// `VoicePipeline.holdIdleForTurnReply`), so the UI session never
    /// drops to rest between "understanding" and the reply this same turn
    /// is about to produce — the reported rest dip. When route()'s reply
    /// was committed synchronously the token is already clear at return
    /// and the pipeline behaves exactly as before.
    ///
    /// The token is cleared — and `onTurnReplyResolved` fired — at the
    /// END of the async dispatch's completion, AFTER the reply speech was
    /// committed (or definitively declined), so on the main queue the
    /// reply's speech-start hop always precedes the pipeline's deferred
    /// idle hop. A dispatch that never completes leaves the token set;
    /// the pipeline's safety timeout then falls back to today's behavior.
    private(set) var isTurnReplyPending = false
    /// Fired once when `isTurnReplyPending` clears. The pipeline sets
    /// this in its init; nil when the router is exercised standalone.
    var onTurnReplyResolved: (() -> Void)?

    /// Marks the turn's reply as still outstanding (async dispatch) —
    /// the completion of that dispatch clears it again.
    private func markTurnReplyPending() {
        isTurnReplyPending = true
    }

    /// Resolves the turn: the async dispatch has committed its reply (or
    /// decided there is none) — release the pipeline's deferred idle.
    private func resolveTurnReplyPending() {
        guard isTurnReplyPending else { return }
        isTurnReplyPending = false
        onTurnReplyResolved?()
    }

    /// Optional — `.plugin` dispatch needs both: the registry to resolve
    /// pluginAction names, and the client to build each plugin's
    /// `PluginExecutionContext`. Nil preserves pre-plugin behavior
    /// (plugin intents resolve to the "unavailable" message).
    private let pluginRegistry: PluginRegistry?
    private let geminiClient: GeminiClient?

    // [LOCAL-TOOLS] (2026-09-07) Local-tool seams. Every one defaults to
    // dormant, so pre-existing router construction sites (AppCoordinator
    // aside) and every existing router test keep compiling and behaving
    // exactly as before: nil search config / transports / fetcher factory
    // means the tools can never fire.
    private let searchConfigStore: SearchConfigStore?
    /// Location seam for the weather tool — a FACTORY, because
    /// `LocationFetcher` is strictly one request per instance (its
    /// delegate + self-retention live exactly one request). The router
    /// asks the factory for a fresh fetcher per weather question.
    private let locationFetcherFactory: (() -> LocationFetching)?
    private let weatherTransport: LocalToolTransport?
    private let searchTransport: LocalToolTransport?
    private let searchQuotaDefaults: UserDefaults

    // [YOUTUBE] (2026-09-08) YouTube tool seams — every one defaults to
    // dormant (nil), exactly like the search-tool seams above, so
    // pre-existing router construction sites and every existing router
    // test keep compiling and behaving as before: without a config
    // store the keyed lookup can never fire, and without an opener the
    // stage speaks the honest unavailable line and opens nothing. Only
    // `AppCoordinator` (and scripted test routers) arm the seams.
    private let youtubeConfigStore: YouTubeConfigStore?
    private let youtubeTransport: LocalToolTransport?
    private let youtubeLinkOpener: CallLinkOpening?

    /// [TOOL-DEBUG-LOG] (2026-09-07) Encrypted on-device debug log of
    /// every local-tool (weather/search) request + outcome — the store
    /// behind Settings → Tool requests. Nil = dormant (pre-existing
    /// construction sites and legacy tests behave exactly as before);
    /// `AppCoordinator` injects its store. See `logToolRequest`.
    private let localToolLogStore: LocalToolLogStore?

    init(coordinator: VoiceCommandCoordinating,
         observabilityBus: ObservabilityBus,
         speaker: Speaker? = nil,
         interpreter: CommandInterpreter = NullCommandInterpreter(),
         pluginRegistry: PluginRegistry? = nil,
         geminiClient: GeminiClient? = nil,
         searchConfigStore: SearchConfigStore? = nil,
         locationFetcherFactory: (() -> LocationFetching)? = nil,
         weatherTransport: LocalToolTransport? = nil,
         searchTransport: LocalToolTransport? = nil,
         searchQuotaDefaults: UserDefaults = .standard,
         localToolLogStore: LocalToolLogStore? = nil,
         youtubeConfigStore: YouTubeConfigStore? = nil,
         youtubeTransport: LocalToolTransport? = nil,
         youtubeLinkOpener: CallLinkOpening? = nil,
         turnTracer: VoiceTurnLatencyTracer? = nil) {
        self.coordinator = coordinator
        self.observabilityBus = observabilityBus
        self.speaker = speaker
        self.interpreter = interpreter
        self.turnTracer = turnTracer
        self.pluginRegistry = pluginRegistry
        self.geminiClient = geminiClient
        self.searchConfigStore = searchConfigStore
        self.locationFetcherFactory = locationFetcherFactory
        self.weatherTransport = weatherTransport
        self.searchTransport = searchTransport
        self.searchQuotaDefaults = searchQuotaDefaults
        self.localToolLogStore = localToolLogStore
        self.youtubeConfigStore = youtubeConfigStore
        self.youtubeTransport = youtubeTransport
        self.youtubeLinkOpener = youtubeLinkOpener
    }

    @discardableResult
    func route(transcript raw: String) -> RoutingResult {
        coordinator?.recordTranscript(raw)

        // Whisper hallucination guard: a repetition loop, low-entropy
        // spam, or absurd length means the STT decoded noise as text.
        // Speak a re-prompt and skip routing so we don't feed garbage
        // into the LLM or the sensitive-action keywords.
        if case .reject(let reason) = TranscriptSanityGuard.check(raw) {
            observabilityBus.emit(ObservabilityEvent(
                component: "command_router",
                eventType: "gibberish_rejected",
                durationMs: nil,
                outcome: "rejected",
                errorCode: reason.rawValue,
                metadata: [:]
            ))
            speak(key: "router.reprompt")
            return .unrecognised(transcript: raw)
        }

        // Emergency outranks even an outstanding confirmation: "मद्दत"
        // said during a yes/no challenge is an emergency, not an answer
        // (constitution: never blocked, by anything, ever).
        //
        // [NEWS-READER][NOISE-FILTER] (2026-09-08) Interior whitespace is
        // canonicalized here, not just trimmed: the STT joins per-segment
        // text with single spaces while each segment's text carries its
        // own leading/trailing spaces (WhisperKit segment decode — pinned
        // rev ea872ffd), so multi-segment utterances arrive with interior
        // whitespace runs ("read  me  the   news") — visually clear, but a
        // raw substring match against a single-spaced phrase misses and
        // the utterance falls through to the "didn't understand"
        // re-prompt (device report 2026-09-08). The phrase lists are all
        // single-spaced, so canonicalizing can only turn misses into the
        // correct matches.
        let preText = raw
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if Self.emergencyPhrases.contains(where: { Self.containsPhrase($0, in: preText) }) {
            emit(eventType: "command_emergency_keyword", outcome: "success")
            handleEmergency()
            return .emergencyTriggered
        }

        // Confirmation-follow-up path: if a challenge is outstanding,
        // treat this transcript as the user's yes/no response, not a new
        // command. Runs the dementia-aware `acknowledgeWithConfirmation`
        // path with the double-dose check.
        if coordinator?.isAwaitingConfirmation == true {
            // Rephrase-as-question follow-up: the outstanding challenge
            // is a mid-band interpretation stated as a yes/no. Yes →
            // dispatch the pended command as if freshly accepted; no →
            // discard + re-prompt.
            if coordinator?.pendingRephraseCommand != nil {
                if Self.isYesResponse(raw) {
                    if let taken = coordinator?.takePendingRephraseCommand() {
                        emit(eventType: "rephrase_confirmed", outcome: "success")
                        // Cache learning keys the ORIGINAL utterance, not
                        // the "हो" that confirmed it.
                        pendingTranscript = taken.sourceTranscript
                        dispatchInterpreted(taken.command)
                        pendingTranscript = nil
                    }
                    return .unrecognised(transcript: raw)
                }
                _ = coordinator?.takePendingRephraseCommand()
                emit(eventType: "rephrase_discarded", outcome: "info")
                speak(key: "router.rephrase.discard")
                return .unrecognised(transcript: raw)
            }
            // Call-confirmation correction protocol (spec §7.2): a
            // no-with-amendment ("होइन, फोन नै गर") is a slot override,
            // not a rejection — checked BEFORE the plain yes/no parse,
            // which would otherwise swallow the amendment ("होइन" ⊂ the
            // utterance) and cancel instead of re-planning.
            if coordinator?.isAwaitingCallConfirmation == true,
               coordinator?.handleCallConfirmationOverride(raw) == true {
                emit(eventType: "call_confirmation_override", outcome: "info")
                return .unrecognised(transcript: raw)
            }
            // Call confirmations speak their own contextual response
            // (AppCoordinator.handleConfirmationResponse) — the generic
            // "confirmationYes"/"confirmationNo" catalog text below is
            // medication-flavored and would be wrong here. The
            // [DIRECTIONS] (2026-09-07) navigation ambiguity walk rides
            // the same exemption: the coordinator speaks each candidate
            // question (or the honest `directions.cancelled` line) as it
            // walks the pending list, and a yes that resolves the walk
            // reports `.navigationRequested`, never a medication ack.
            let isCallConfirmation = coordinator?.isAwaitingCallConfirmation == true
            let isNavigationDisambiguation = coordinator?.isAwaitingNavigationDisambiguation == true
            if Self.isYesResponse(raw) {
                coordinator?.handleConfirmationResponse(.yes)
                emit(eventType: "confirmation_yes", outcome: "success")
                if !isCallConfirmation && !isNavigationDisambiguation {
                    speak(key: "router.confirmationYes")
                }
                if isCallConfirmation { return .callConfirmed }
                return isNavigationDisambiguation ? .navigationRequested : .acknowledgedMedication
            }
            if Self.isNoResponse(raw) {
                coordinator?.handleConfirmationResponse(.no)
                emit(eventType: "confirmation_no", outcome: "success")
                if !isCallConfirmation && !isNavigationDisambiguation {
                    speak(key: "router.confirmationNo")
                }
                return .unrecognised(transcript: raw)
            }
            // Ambiguous response — re-prompt.
            emit(eventType: "confirmation_ambiguous", outcome: "info")
            speak(key: "router.confirmationAmbiguous")
            return .unrecognised(transcript: raw)
        }

        // Deterministic safety net FIRST (spec 2026-09-05 §4 routing
        // ladder): emergency and explicit med-ack never wait on — and
        // never depend on the correctness of — ANY model. Live testing
        // (2026-09-04) showed the LLM itself can misclassify a distress
        // utterance as health_query, so "the LLM got a confident answer"
        // is not sufficient reason to skip this net; it runs first,
        // always. The REMAINDER of the keyword layer (sensitive-call
        // blocking, generic unrecognised) still runs AFTER the LLM as
        // its fallback — only the safety-critical vocabulary moved.
        if let safetyResult = routeSafetyNet(raw) {
            return safetyResult
        }

        // Voice-driven CONTACT SEARCH (voice-contact-search, 2026-09-07):
        // "मैयाको फोन नम्बर खोज" / "maiya ko phone khoja" / "contact
        // search <name>" opens the Phone screen with the extracted name
        // already searching — zero-touch hands-free. Same deterministic
        // pattern as `TopicPreAnswer`: no model, no IntentPrompt tokens
        // (the prompt budget is pinned by IntentPromptTests).
        //
        // Placement: AFTER the safety net + confirmation flow (emergency /
        // med-ack / yes-no utterances win exactly as before) and BEFORE
        // the topic table + interpreter, so a greeting-prefixed search is
        // a search, never small talk. The decision type carries its own
        // direct-call veto ("फोन नम्बर लगाऊ" is a CALL intent — golden
        // corpus), so the sensitive-call path below can never be shadowed.
        // Nothing is spoken here: the Call leaf announces the outcome
        // once results have actually rendered.
        if case .openPhone(let query) = VoiceContactSearchRoute.decide(transcript: raw) {
            coordinator?.requestContactSearch(query: query)
            emit(eventType: "contact_search_command", outcome: "success")
            return .contactSearchRequested
        }

        // Voice-driven DIRECTIONS (directions task, 2026-09-07): "मलाई
        // घर लैजाऊ" (take me home), "मैयाको घर लैजाऊ" (take me to
        // Maiya's home), "अस्पताल लैजाऊ" (take me to the hospital)
        // starts navigation to the default home, a saved place, or a
        // relative with an address. Same deterministic pattern as the
        // contact-search stage above: no model, no IntentPrompt tokens
        // (the prompt budget is pinned by IntentPromptTests).
        //
        // Placement: AFTER the safety net + confirmation flow + contact
        // search — emergency / med-ack / yes-no / phone-search utterances
        // win exactly as before, and a directions marker can never shadow
        // them — and BEFORE the topic table, so a transport verb can
        // never be answered as small talk. The decision type's own vetoes
        // keep call talk ("फोन लैजाऊ" = carry the phone), medication
        // markers ("दवाई लैजाऊ" = take the medicine) and third-person
        // transport ("छोरालाई स्कुल लैजाऊ") off this stage entirely.
        //
        // The stage only DECIDES and hands off: candidates come from
        // `navigationCandidates` (the coordinator's merged saved places +
        // address-carrying relatives), and the coordinator owns every
        // spoken line — execution speech, the no-home fallback, the
        // map-surface chain, and the ambiguity walk.
        switch DirectionsRoute.decide(transcript: raw,
                                      candidates: coordinator?.navigationCandidates ?? []) {
        case .navigate(let target):
            coordinator?.requestNavigation(to: target)
            emit(eventType: "directions_command", outcome: "success")
            return .navigationRequested
        case .ambiguous(let targets):
            // Several candidates scored within the margin — ask, never
            // guess a place. The returned question is the first
            // candidate's yes/no prompt ("के … लैजाने?"); the user's
            // answer comes back through the confirmation path widened by
            // `isAwaitingNavigationDisambiguation`. A nil return means
            // the coordinator could not pend: end the turn without
            // speech rather than route a directions utterance onward.
            if let question = coordinator?.requestNavigationDisambiguation(targets: targets) {
                emit(eventType: "directions_disambiguation", outcome: "info")
                speak(text: question)
            }
            return .navigationRequested
        case .unknownPlace:
            // Honest fallback: a place-name query matched no saved place
            // and no address-carrying relative. Visible card + speech,
            // exactly like the other fallback lines (the live-caption
            // pill is gone by now, so spoken-only would vanish).
            emit(eventType: "directions_command", outcome: "unknown_place")
            speakWithVisibleOutcome(key: "directions.placeNotFound")
            return .unrecognised(transcript: raw)
        case .notDirections:
            break   // not directions business — continue the ladder
        }

        // [ALARMS-TIMERS] (2026-09-07) Deterministic voice ALARMS + TIMERS
        // stage: "set an alarm for 6 am", "wake me up at 7:30", "बिहान ६
        // बजे उठाउनुहोस्", "set a timer for 5 minutes", "टाइमर ५ मिनेट".
        // Marker-gated parsing (`AlarmTimerCommandParser`) — the same
        // pre-route pattern as the contact-search / directions stages:
        // no model, no IntentPrompt tokens (the prompt budget is pinned
        // by IntentPromptTests), so an alarm/timer command can never
        // depend on interpreter availability or confidence.
        //
        // Placement: AFTER the safety net + confirmation flow + contact
        // search + directions — emergency / med-ack / yes-no / search /
        // navigation utterances win exactly as before — and BEFORE the
        // topic table, so a greeting- or weather-prefixed alarm command
        // is a command, never small talk ("नमस्ते, ५ मिनेटको टाइमर लगाऊ"
        // must set a timer, not get a greeting). The parser vetoes
        // questions ("when is my alarm?", "कति बजेको अलार्म?"),
        // cancellations ("cancel the timer"), third-person wake requests
        // ("wake my grandson", "छोरालाई उठाउनुहोस्") and countdown
        // phrasings ("alarm in 5 minutes" — a countdown is a TIMER,
        // which parses FIRST below). Anything vetoed or unparseable
        // falls through this stage unchanged.
        //
        // The stage only PARSES and hands off: the coordinator owns the
        // permission round-trip (point-of-use requestAuthorization), the
        // persistence and the arming, and RETURNS the outcome so this
        // stage speaks the honest line — the confirmation only once the
        // item is stored + armed, the denial fallback when notifications
        // are off.
        if let timer = AlarmTimerCommandParser.parseTimer(raw) {
            handleTimerStartCommand(durationSeconds: timer.durationSeconds,
                                    label: timer.label)
            return .unrecognised(transcript: raw)
        }
        if let alarm = AlarmTimerCommandParser.parseAlarm(raw) {
            handleAlarmSetCommand(at: alarm.time, label: alarm.label)
            return .unrecognised(transcript: raw)
        }
        // [ALARMS-TIMERS] (2026-09-08) OFF + SNOOZE branches — checked
        // AFTER the set parses (a set command wins first) and BEFORE the
        // briefing stage + topic table. Only the sanctioned shapes parse
        // (see `AlarmTimerCommandParser`): time-qualified cancellations
        // ("cancel the 6 am alarm" — the off branch must not guess which
        // alarm) and timer-worded snoozes fall through unchanged. The
        // stage only PARSES and hands off; the coordinator resolves the
        // target (the most recently rung enabled alarm) and returns the
        // honest outcome this stage speaks. SYNCHRONOUS — no permission
        // round-trip, so the reply is committed inside `route()` itself.
        if AlarmTimerCommandParser.parseAlarmOff(raw) {
            handleAlarmOffCommand()
            return .unrecognised(transcript: raw)
        }
        if let snoozeMinutes = AlarmTimerCommandParser.parseAlarmSnooze(raw) {
            handleAlarmSnoozeCommand(minutes: snoozeMinutes)
            return .unrecognised(transcript: raw)
        }

        // [MORNING-BRIEFING] (2026-09-07) Voice-OS shell v1: "read me my
        // briefing" — a deterministic pre-answer stage like the topic
        // table below: after the safety net + confirmation flow +
        // directions, before any model. `fireMorningBriefing()` composes
        // and speaks the briefing through the shell's speak queue (once
        // per calendar day, its own card) — the router adds NO speech and
        // NO visible outcome of its own, so this stage ends the turn with
        // the same `.unrecognised(transcript:)` the topic/calculator
        // stages return once they have already spoken.
        if Self.briefingPhrases.contains(where: { Self.containsPhrase($0, in: preText) }) {
            coordinator?.fireMorningBriefing()
            emit(eventType: "morning_briefing_command", outcome: "success")
            return .unrecognised(transcript: raw)
        }

        // [NEWS-READER] (2026-09-08) Voice-OS news digest: "read me the
        // news" / "what's the news" / "समाचार सुनाऊ" / "खबर सुनाऊ" — a
        // deterministic pre-answer stage like the briefing stage above:
        // after the safety net + confirmation flow + contact search +
        // directions + alarms/timers + briefing, before any model. No
        // interpreter involvement, no IntentPrompt tokens (the prompt
        // budget is pinned by IntentPromptTests) — the digest can never
        // depend on interpreter availability or confidence, and can never
        // be misclassified into a topic answer.
        //
        // Placement: AFTER the briefing stage (a briefing utterance can
        // never be swallowed by the news stage) and BEFORE the topic
        // table (a greeting-prefixed news request — "नमस्ते, खबर सुनाऊ" —
        // is a digest, never small talk).
        //
        // Vetoes (same discipline as the briefing phrase list):
        //  - full-phrase containment only — the bare word "news" /
        //    "समाचार" is never matched, so an utterance that merely
        //    mentions news ("news from my son about school") can never
        //    hijack the stage;
        //  - imperative/question FORMS only ("सुनाऊ", "read me", "what's")
        //    — a noun phrase ("today's news", "समाचार") never matches.
        //
        // The stage only DECIDES and hands off: the coordinator owns the
        // reader (`fireNewsReader()`), and the reader owns every spoken
        // line — the checking announcement, the digest, and the honest
        // failure lines — with its own outcome card, so this stage ends
        // the turn with the same `.unrecognised(transcript:)` the
        // topic/calculator stages return once they have already spoken.
        if Self.newsPhrases.contains(where: { Self.containsPhrase($0, in: preText) }) {
            coordinator?.fireNewsReader()
            emit(eventType: "news_reader_command", outcome: "success")
            return .unrecognised(transcript: raw)
        }

        // [YOUTUBE] (2026-09-08) Deterministic voice YOUTUBE stage:
        // "play bhajan on youtube", "youtube news", "search youtube for
        // old songs", "युट्युबमा गीत चलाऊ", "युट्युबमा रामायण खोज".
        // Marker-gated parsing (`YouTubeRoute`) — the same pre-route
        // pattern as the contact-search / directions / alarms-timers
        // stages: no model, no IntentPrompt tokens (the prompt budget
        // is pinned by IntentPromptTests), so a YouTube request can
        // never depend on interpreter availability or confidence. A
        // bare "play" with no YouTube word never fires (`YouTubeRoute`
        // vetoes it), so pre-existing play/music talk falls through
        // unchanged.
        //
        // Placement: AFTER the safety net + confirmation flow + contact
        // search + directions + alarms/timers + morning briefing —
        // emergency / med-ack / yes-no / phone-search / navigation /
        // alarm utterances win exactly as before — and BEFORE the topic
        // table, so a greeting-prefixed request ("नमस्ते, युट्युबमा
        // भजन चलाऊ") is a command, never small talk.
        //
        // The stage only DECIDES and executes the tool: with an API key
        // configured it fetches the top result and opens the watch link
        // (https fallback when the app is absent), without one it opens
        // the SEARCH deeplink (the accepted search-only MVP); every
        // failure speaks the honest localized fallback (`fireYouTubePlay`).
        if case .play(let query) = YouTubeRoute.decide(transcript: raw) {
            fireYouTubePlay(query: query)
            return .unrecognised(transcript: raw)
        }

        // [NO-GIBBERISH] Deterministic TOPIC PRE-ANSWERS (2026-09-07): the
        // most common Q&A topics — weather, time, date, greetings — are
        // answered from a pre-written, honest table (`TopicPreAnswer`)
        // BEFORE any model is consulted, so "भोलिको मौसम कस्तो छ?" ALWAYS
        // gets a sensible non-gibberish reply and never depends on what a
        // 1B model happened to sample that day. Runs regardless of
        // interpreter availability (works while the brain downloads too).
        // It sits AFTER the safety net + confirmation flow, so emergency /
        // med-ack / yes-no utterances win as they always have, and it
        // self-excludes call-ish utterances (below) so the sensitive-call
        // block can never be shadowed by a topic answer.
        if let topic = TopicPreAnswer.match(transcript: raw),
           !Self.sensitiveCallPhrases.contains(where: { Self.containsPhrase($0, in: preText) }) {
            // [WEATHER-ROUTING] (2026-09-07) Weather routing matrix —
            // which stack answers a WEATHER question:
            //
            //   · Gemini stack with the cloud brain live
            //     (`canAnswerLiveQuestionsFromWeb` — cloud enabled AND
            //     cloud brain available, mirroring the router's own
            //     escalation guard): the topic is NOT intercepted here —
            //     the weather question falls through to the
            //     search-grounded interpreter below, which answers from
            //     live web data. Intercepting with a dead answer would be
            //     wrong on the one stack that CAN answer.
            //   · On-device stack (`isOnDeviceStack`): the live
            //     `WeatherTool` path (`fireLocalWeatherLookup`) — a named
            //     place in the question is geocoded and answered for that
            //     place, otherwise the current device location is used;
            //     every live reply is hedged as forecast data
            //     (`weather.replySource`).
            //   · Neither (no key, cloud brain down/downloading, or any
            //     other stack): the honest static
            //     `topic.weather.unavailable` line below — never a
            //     fabricated forecast.
            //
            // Time/date/greeting topics are unchanged: local facts, not
            // web lookups, deterministic on every stack. The whole table
            // runs BEFORE the interpreter/search stages, so a weather
            // question can never reach the generic web-search fallback
            // (Arncliffe report: stale snippet spoken as fact).
            let liveWeb = coordinator?.canAnswerLiveQuestionsFromWeb ?? false
            if topic == .weather && liveWeb {
                // Fall through to the interpreter below.
            } else if topic == .weather && (coordinator?.isOnDeviceStack ?? false) {
                // [LOCAL-TOOLS] (2026-09-07) On the ON-DEVICE stack a
                // weather question deserves the live open-meteo reading,
                // not the deterministic "unavailable" line (see
                // `fireLocalWeatherLookup` for the named-place /
                // device-location flow). Any failure falls back to the
                // EXISTING static `topic.weather.unavailable` answer —
                // never a fabricated number, never a web snippet. The
                // Gemini stack never reaches here (liveWeb already
                // yielded to its grounded interpreter).
                fireLocalWeatherLookup(transcript: raw)
                return .unrecognised(transcript: raw)
            } else {
                let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
                let text = TopicPreAnswer.reply(for: topic, locale: locale, now: clock())
                observabilityBus.emit(ObservabilityEvent(
                    component: "command_router",
                    eventType: "topic_pre_answer",
                    durationMs: nil,
                    outcome: "success",
                    errorCode: nil,
                    metadata: ["topic": topic.rawValue]
                ))
                coordinator?.noteGenericReply(text)
                speak(text: text, locale: locale)
                return .unrecognised(transcript: raw)
            }
        }

        // [INTENT-TOOLS] (2026-09-07) Deterministic CALCULATOR — see
        // `CalculatorTool` for the full contract. This stage is the same
        // pre-route pattern as TopicPreAnswer: after the safety net and
        // topic answers, before any interpreter, on BOTH stacks, default
        // on. The tool decides (nil → route on; computed/divisionByZero →
        // answered here, the interpreter is never consulted for provable
        // arithmetic).
        if let decision = CalculatorTool.decide(raw) {
            let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
            switch decision {
            case .computed(let calculation):
                observabilityBus.emit(ObservabilityEvent(
                    component: "command_router",
                    eventType: "intent_tool_calculator",
                    durationMs: nil,
                    outcome: "success",
                    errorCode: nil,
                    metadata: [:]
                ))
                let text = CalculatorTool.reply(for: calculation, locale: locale)
                coordinator?.noteGenericReply(text)
                speak(text: text, locale: locale)
            case .divisionByZero:
                // Honest error — the utterance WAS arithmetic but has no
                // numeric answer; visible + spoken (elderly UX: an error
                // spoken-only vanishes with the caption pill).
                observabilityBus.emit(ObservabilityEvent(
                    component: "command_router",
                    eventType: "intent_tool_calculator",
                    durationMs: nil,
                    outcome: "error",
                    errorCode: "division_by_zero",
                    metadata: [:]
                ))
                speakWithVisibleOutcome(key: "calculator.error.divByZero")
            }
            return .unrecognised(transcript: raw)
        }

        // Fast path — the LLM interpreter. Falls through to keyword when
        // the interpreter is unavailable or not confident.
        if interpreter.isAvailable {
            let context = InterpreterContext(
                pendingMedications: [],
                userLanguageHint: coordinator?.activeLocale.languageCode ?? "en"
            )
            // [REST-DIP-FIX] (2026-09-08) The interpreter round-trip is
            // ASYNC: this route returns before the reply exists, and the
            // pipeline would drop the session to rest in between (the
            // reported dip). Mark the turn pending so VoicePipeline holds
            // its return to idle until the completion below resolves the
            // token — AFTER the reply speech was committed.
            markTurnReplyPending()
            // [TURN-TIMING] The LLM round-trip starts here — on-device
            // llama.cpp or the cloud interpreter (whose collapsed call
            // may have resolved from the ASR preparse slot, making this
            // span ~0 ms — both are honest).
            turnTracer?.mark("llm_start")
            interpreter.interpret(transcript: raw, context: context) { [weak self] command in
                guard let self else { return }
                // [TURN-TIMING] The model answered (or abstained).
                self.turnTracer?.mark("llm_done")
                if let command = command {
                    // REPHRASE band (spec §4, decision #6): a mid-band
                    // tier-`free` command becomes a yes/no question rather
                    // than an immediate dispatch. Tier-`confirm` actions
                    // are unaffected — their executor confirmation
                    // already verifies aloud. `neverGated` never reaches
                    // here (safety net ran first).
                    if command.confidence < 0.7,
                       ConfirmationTier.tier(for: command.action) == .free,
                       self.coordinator?.pendingRephraseCommand == nil {
                        self.coordinator?.startRephraseConfirmation(command, sourceTranscript: raw)
                        self.emit(eventType: "rephrase_question_started", outcome: "info")
                    } else {
                        self.pendingTranscript = raw
                        self.dispatchInterpreted(command)
                        self.pendingTranscript = nil
                    }
                } else {
                    _ = self.routeKeywordRemainder(raw)
                }
                // The async dispatch has committed its reply (spoken /
                // queued / declined) — the turn is no longer pending.
                // This runs AFTER the commit, so the reply's speech-start
                // hop is enqueued before the pipeline's deferred idle hop.
                self.resolveTurnReplyPending()
                // [TURN-TIMING] Dispatch resolved — the tracer finalizes
                // now or once the reply speech finishes.
                self.turnTracer?.endTurn()
            }
            // We can't return a synchronous result once the LLM path fires;
            // report the transcript as "handled asynchronously".
            emit(eventType: "command_dispatched_to_llm", outcome: "info")
            return .unrecognised(transcript: raw)
        }

        return routeKeywordRemainder(raw)
    }

    // MARK: - [ALARMS-TIMERS] Alarm + timer command handlers

    /// Hands an alarm command to the coordinator — ASYNC because the
    /// notification permission is requested at point of use — then speaks
    /// the outcome-dependent line: the localized confirmation with the
    /// resolved time only on `.scheduled`, the honest denial / capacity /
    /// failure fallback otherwise. `noteGenericReply` is used for the
    /// dynamic confirmation (the live-caption pill is gone by the time
    /// the permission round-trip returns, so spoken-only would vanish);
    /// the fallbacks ride `speakWithVisibleOutcome`. Observability is
    /// emitted at resolution (component "alarms_timers"), never before.
    private func handleAlarmSetCommand(at time: Date, label: String?) {
        guard coordinator != nil else {
            speakWithVisibleOutcome(key: "alarms.setFailed")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let timeText = formattedTime(
            Calendar.current.dateComponents([.hour, .minute], from: time),
            locale: locale
        )
        // [REGRESSION-AUDIT] (2026-09-10) The permission round-trip is an
        // ASYNC dispatch — mark the turn reply-pending exactly like the
        // LLM path so the pipeline holds idle until the reply commits
        // (without this the pipeline resumed wake listening while the
        // notification dialog was still up, and the reply speech could
        // collide with a new capture). Broken since the alarms stage
        // landed (3b6c9a9) — see testAlarmRoutingSurvivesTimingHooks.
        markTurnReplyPending()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.coordinator?.requestAlarmSet(at: time, label: label)
                ?? .failed
            switch outcome {
            case .scheduled:
                self.emitAlarmTimers(eventType: "alarm_set", outcome: "success")
                let text = L10n.fmt("alarms.set", locale: locale, timeText)
                self.coordinator?.noteGenericReply(text)
                self.speak(text: text, locale: locale)
            case .permissionDenied:
                self.emitAlarmTimers(eventType: "alarm_set", outcome: "permission_denied")
                self.speakWithVisibleOutcome(key: "alarms.permissionDenied")
            case .atCapacity:
                self.emitAlarmTimers(eventType: "alarm_set", outcome: "at_capacity")
                self.speakWithVisibleOutcome(key: "alarms.capacity")
            case .failed:
                self.emitAlarmTimers(eventType: "alarm_set", outcome: "failed")
                self.speakWithVisibleOutcome(key: "alarms.setFailed")
            }
            // [REGRESSION-AUDIT] Resolve AFTER the commit (speech-start
            // hop precedes the pipeline's deferred idle hop) and finalize
            // the turn tracer, mirroring the LLM dispatch completion.
            self.resolveTurnReplyPending()
            self.turnTracer?.endTurn()
        }
    }

    /// Same contract as `handleAlarmSetCommand` for countdown timers; the
    /// confirmation embeds the localized duration ("Timer started for
    /// 5 minutes.") via `AlarmTimerCommandParser.durationText`.
    private func handleTimerStartCommand(durationSeconds: Int, label: String?) {
        guard coordinator != nil else {
            speakWithVisibleOutcome(key: "timers.setFailed")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        // [REGRESSION-AUDIT] (2026-09-10) Same reply-pending hold as the
        // alarm set path — see handleAlarmSetCommand.
        markTurnReplyPending()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.coordinator?.requestTimerStart(
                durationSeconds: durationSeconds, label: label
            ) ?? .failed
            switch outcome {
            case .scheduled:
                self.emitAlarmTimers(eventType: "timer_started", outcome: "success")
                let durationText = AlarmTimerCommandParser.durationText(
                    seconds: durationSeconds, locale: locale
                )
                let text = L10n.fmt("timers.started", locale: locale, durationText)
                self.coordinator?.noteGenericReply(text)
                self.speak(text: text, locale: locale)
            case .permissionDenied:
                self.emitAlarmTimers(eventType: "timer_started", outcome: "permission_denied")
                self.speakWithVisibleOutcome(key: "timers.permissionDenied")
            case .atCapacity:
                self.emitAlarmTimers(eventType: "timer_started", outcome: "at_capacity")
                self.speakWithVisibleOutcome(key: "timers.capacity")
            case .failed:
                self.emitAlarmTimers(eventType: "timer_started", outcome: "failed")
                self.speakWithVisibleOutcome(key: "timers.setFailed")
            }
            // [REGRESSION-AUDIT] Resolve after the commit + finalize the
            // tracer, mirroring the alarm set path.
            self.resolveTurnReplyPending()
            self.turnTracer?.endTurn()
        }
    }

    /// Voice alarm OFF handler — same contract as the set handlers but
    /// SYNCHRONOUS (no permission round-trip): the coordinator resolves
    /// the most recently rung enabled alarm, disables it and returns the
    /// outcome this handler speaks. `.disabled` confirms with the
    /// alarm's SPOKEN time, `.noAlarm` speaks the honest "no alarms"
    /// line, `.failed` the honest fallback. Observability is emitted at
    /// resolution (component "alarms_timers"), never before.
    private func handleAlarmOffCommand() {
        guard coordinator != nil else {
            speakWithVisibleOutcome(key: "alarms.offFailed")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        switch coordinator?.requestAlarmOff() ?? .noAlarm {
        case .disabled(let time):
            emitAlarmTimers(eventType: "alarm_off", outcome: "success")
            let timeText = formattedTime(
                Calendar.current.dateComponents([.hour, .minute], from: time),
                locale: locale
            )
            let text = L10n.fmt("alarms.off", locale: locale, timeText)
            coordinator?.noteGenericReply(text)
            speak(text: text, locale: locale)
        case .noAlarm:
            emitAlarmTimers(eventType: "alarm_off", outcome: "no_alarm")
            speakWithVisibleOutcome(key: "alarms.none")
        case .failed:
            emitAlarmTimers(eventType: "alarm_off", outcome: "failed")
            speakWithVisibleOutcome(key: "alarms.offFailed")
        }
    }

    /// Voice SNOOZE handler — same synchronous contract; the success
    /// confirmation embeds the re-wake instant as a SPOKEN time
    /// ("Snoozed until 6:15 am.") via the shared `SpokenTime` helper.
    private func handleAlarmSnoozeCommand(minutes: Int) {
        guard coordinator != nil else {
            speakWithVisibleOutcome(key: "alarms.snoozeFailed")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        switch coordinator?.requestAlarmSnooze(minutes: minutes) ?? .noAlarm {
        case .snoozed(let until):
            emitAlarmTimers(eventType: "alarm_snoozed", outcome: "success")
            let timeText = SpokenTime.string(from: until, locale: locale)
            let text = L10n.fmt("alarms.snoozed", locale: locale, timeText)
            coordinator?.noteGenericReply(text)
            speak(text: text, locale: locale)
        case .noAlarm:
            emitAlarmTimers(eventType: "alarm_snoozed", outcome: "no_alarm")
            speakWithVisibleOutcome(key: "alarms.none")
        case .failed:
            emitAlarmTimers(eventType: "alarm_snoozed", outcome: "failed")
            speakWithVisibleOutcome(key: "alarms.snoozeFailed")
        }
    }

    /// Observability for the alarms/timers feature — component
    /// "alarms_timers" (the feature's own bus name, not the router's).
    private func emitAlarmTimers(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "alarms_timers",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }
    /// [MORNING-BRIEFING] (2026-09-07) Imperative phrasings that request
    /// the proactive morning briefing — English, नेपाली, and romanized
    /// Nepali, matched against the lowercased transcript like every other
    /// phrase list. Imperative forms ONLY: a bare "briefing" / "मेरो
    /// ब्रीफिङ" is never matched here, so a reminder-set or other
    /// utterance that merely mentions the word can never hijack the
    /// briefing's once-per-calendar-day budget (the confirmation-flow and
    /// interpreter stages already ran before this stage, so an answered
    /// yes/no or a confident command always wins).
    private static let briefingPhrases = [
        "read me my briefing", "read my briefing", "tell me my briefing",
        "मेरो ब्रीफिङ सुनाऊ", "ब्रीफिङ सुनाऊ",
        "मेरो बिहानको सारांश सुनाऊ", "बिहानको सारांश सुनाऊ",
        "mero briefing sunau", "bihanko sarsang sunau"
    ]

    /// [NEWS-READER] (2026-09-08) Request phrasings for the news digest —
    /// English, नेपाली, and romanized Nepali, matched against the
    /// lowercased transcript like every other phrase list. Full phrases
    /// only (see the stage's veto notes): the bare word "news" /
    /// "समाचार" is deliberately absent, so a mention can never fire the
    /// digest. STT spacing varies, so all spellings ship: "what's" /
    /// "whats" / "what is".
    private static let newsPhrases = [
        "read me the news", "read the news", "tell me the news",
        "what's the news", "whats the news", "what is the news",
        "समाचार सुनाऊ", "समाचार सुनाउनुहोस्", "समाचार पढ",
        "खबर सुनाऊ", "खबर सुनाउनुहोस्", "खबर पढ",
        "samachar sunau", "samachar sunaunuhos", "khabar sunau"
    ]

    // MARK: - Keyword fallback

    /// Substring matching for multi-word phrases — STT output varies in
    /// spacing and inflection, so phrases need containment matching. Never
    /// use this for single words (see `containsToken`).
    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        text.contains(phrase)
    }

    /// Whole-token matching for single words. Substring matching on short
    /// tokens is dangerous: Nepali "खाए" sits inside "नखाए" (not eaten) and
    /// "भयो" inside "भएन" (didn't happen) — a containment match turns a
    /// refusal into a medication acknowledgement. Tokens are split on
    /// whitespace and punctuation.
    private static func containsToken(_ token: String, in text: String) -> Bool {
        text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .contains { $0 == token }
    }

    /// Checked BEFORE anything else in `routeKeyword` — and independent of
    /// whether the LLM path is available at all — because this is the one
    /// gap the constitution calls out by name: "Emergency calling logic...
    /// must not be blocked by the on-device LLM being busy or
    /// unavailable." Live testing against the real Gemini API (2026-09-04)
    /// found the LLM itself can misclassify a distress utterance as
    /// `health_query` ("मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ" — help, my
    /// kidney hurts — came back `health_query`, not `emergency`) — this
    /// deterministic net is the backstop for exactly that failure mode,
    /// not just for "LLM unavailable." Deliberately broad/token-based: a
    /// false positive here costs one extra spoken reassurance + local
    /// notification (see `handleEmergency`); a false negative costs a
    /// genuine emergency going unanswered. That asymmetry is why this
    /// errs toward over-triggering.
    private static let emergencyPhrases = [
        "help", "emergency", "i fell", "fell down", "chest pain",
        "can't breathe", "cant breathe",
        "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें",
        "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो"
    ]

    /// Call-ish vocabulary shared by the post-LLM block
    /// (`routeKeywordRemainder`) and the [NO-GIBBERISH] pre-answer guard:
    /// an utterance that both names a topic word AND reads call-ish
    /// ("मौसम बताउने मान्छेलाई फोन गर") must stay on the interpreter/
    /// block path — a deterministic topic answer would shadow the call
    /// intent. Hoisted from `routeKeywordRemainder` (2026-09-07) so the
    /// pre-answer stage checks the SAME list that blocks.
    private static let sensitiveCallPhrases = [
        "call", "phone", "facetime", "messenger", "whatsapp",
        "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
    ]

    /// The safety-critical slice of the keyword layer, runnable on its
    /// own AHEAD of the LLM (spec §4 ladder: keyword net first, always).
    /// Returns nil when nothing safety-shaped matched, so the caller can
    /// proceed to the interpreter; the remaining keyword behavior
    /// (sensitive-call block, unrecognised re-prompt) stays in
    /// `routeKeywordRemainder` as the post-LLM fallback.
    @discardableResult
    private func routeSafetyNet(_ raw: String) -> RoutingResult? {
        let text = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.emergencyPhrases.contains(where: { Self.containsPhrase($0, in: text) }) {
            emit(eventType: "command_emergency_keyword", outcome: "success")
            handleEmergency()
            return .emergencyTriggered
        }

        // Guard first: explicit negations must never fall through to the
        // ack list, because refusal words contain ack words as substrings
        // ("नखाए" ⊃ "खाए", "भएन" ⊃ "भयो").
        let denialPhrases = [
            "i didn't", "i did not", "not yet", "haven't", "havent",
            "औषधि खाएको छैन", "औषधी खाएको छैन", "खाएको छैन",
            "नखाए", "नखाएको", "लिएको छैन", "भएन", "छैन"
        ]
        if denialPhrases.contains(where: { Self.containsPhrase($0, in: text) }) {
            emit(eventType: "command_ack_denied_keyword", outcome: "info")
            speak(key: "router.ackDenied")
            return .unrecognised(transcript: raw)
        }

        let ackPhrases = [
            "i took", "i've taken", "ive taken", "took my medication",
            "took my medicine", "taken my medication", "taken my medicine",
            "yes i took it",
            "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
            "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
            "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
            "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें"
        ]
        let ackTokens = ["done", "taken", "took", "ate",
                         "खाएँ", "खाए", "भयो"]
        if ackPhrases.contains(where: { Self.containsPhrase($0, in: text) })
            || ackTokens.contains(where: { Self.containsToken($0, in: text) }) {
            handleMedicationAcknowledgement()
            return .acknowledgedMedication
        }
        return nil
    }

    /// Post-LLM keyword fallback — everything in the keyword layer that
    /// is NOT safety-critical: the blunt sensitive-call block (no entity
    /// extraction available, so any call-ish phrase is blocked rather
    /// than acted on) and the unrecognised handling. The unrecognised
    /// branch speaks honestly against `coordinator.brainReadiness`
    /// (2026-09-06): the generic "I didn't understand" re-prompt is only
    /// truthful while an interpreter actually listened — when the chain
    /// is empty because the brain model is downloading or needs setup,
    /// the user hears THAT (spec §7 no dead ends), not a lie that blames
    /// their pronunciation.
    @discardableResult
    private func routeKeywordRemainder(_ raw: String) -> RoutingResult {
        let text = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.sensitiveCallPhrases.contains(where: { Self.containsPhrase($0, in: text) }) {
            emit(eventType: "command_sensitive_blocked_auth_unavailable", outcome: "blocked")
            // Visible outcome, not just spoken — the live-caption pill is
            // gone by now, so without a card the user's transcript and the
            // refusal both vanish from the screen (field report 2026-09-05).
            speakWithVisibleOutcome(key: "router.sensitiveBlocked")
            return .blockedSensitiveAction
        }

        emit(eventType: "command_unrecognised", outcome: "info")
        // No interpreter heard this utterance — or one did and
        // abstained. Only `.available` makes the generic re-prompt
        // honest; the two no-brain states say what is actually
        // happening (first-run model download / setup needed). Both
        // no-brain messages are also VISIBLE (live-caption card via the
        // coordinator), since the captions are a mobility aid, not just
        // hearing assistance.
        switch coordinator?.brainReadiness ?? .available {
        case .available:
            // [LOCAL-TOOLS] (2026-09-07) Web-search hook: this is the
            // post-interpreter ABSTENTION point (an interpreter listened
            // and did not understand — or did not exist), and the generic
            // re-prompt below is what an abstained utterance normally
            // gets. When the utterance is question-shaped AND a search
            // credential pair is configured, the search tool answers
            // instead — the generic re-prompt remains the fallback for
            // everything the tool declines (not question-shaped, not
            // configured, quota-capped, failed or empty results). The
            // `fireWebSearchIfDue` cap path itself ends by speaking the
            // generic re-prompt, so a capped day sounds exactly as
            // honest as an unanswered one.
            if !fireWebSearchIfDue(raw) {
                speak(key: "router.reprompt")
            }
        case .downloadingBrain:
            speakWithVisibleOutcome(key: "router.brainDownloading")
        case .needsSetup:
            speakWithVisibleOutcome(key: "router.brainNeedsSetup")
        }
        return .unrecognised(transcript: raw)
    }

    // MARK: - [LOCAL-TOOLS] Live weather + web search (on-device stack)

    /// Timeout for the search-tool round-trip — same budget as
    /// `WeatherTool.fetchTimeoutSeconds` (the router builds the search
    /// request itself; only the weather tool owns its URLRequest).
    private static let searchFetchTimeoutSeconds: TimeInterval = 8

    /// [LOCAL-TOOLS] (2026-09-07) On-device live-weather path — called
    /// from the topic pre-answer stage when `.weather` matched and the
    /// stack is on-device (see the routing matrix there). Announces
    /// "weather.checking", then answers the question that was ASKED:
    ///
    ///   1. A named place in the utterance ("is it raining in Arncliffe",
    ///      "काठमाडौंको मौसम कस्तो छ?") is geocoded through open-meteo's
    ///      free geocoding API (same transport seam as the forecast) and
    ///      the forecast is read for THAT point. [WEATHER-ROUTING]
    ///      (2026-09-07) This is the direct fix for the Arncliffe
    ///      report: a question about a place must answer for that place,
    ///      never for wherever the device happens to be.
    ///   2. Any geocode failure (transport error, nothing found,
    ///      malformed payload) falls back to the DEVICE location
    ///      (point-of-use permission) — an honest answer about the
    ///      device's place beats silence.
    ///   3. No named place → device location directly.
    ///
    /// Every remaining failure (no transport, no fetcher factory,
    /// location denied/unavailable/timed out, forecast transport failure,
    /// malformed forecast payload) delivers the EXISTING static
    /// `topic.weather.unavailable` answer with a `local_tools` `weather`
    /// `fail` event — the deterministic no-data line is unchanged, and a
    /// wrong or fabricated temperature is impossible. Live replies are
    /// carded + spoken wrapped in the `weather.replySource` hedge (see
    /// `deliverLiveWeather`) — forecast data is never presented as
    /// unmediated ground truth.
    private func fireLocalWeatherLookup(transcript raw: String) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        // Announce first — the user hears the lookup start before the
        // (possibly multi-second) geocode/location + fetch round-trip.
        speak(key: "weather.checking")

        // [TOOL-DEBUG-LOG] (2026-09-07) Request capture BEFORE the round-
        // trip: the RAW utterance is the logged query (place extraction
        // below is the tool's own parsing — the log keeps what the user
        // actually asked) and the stopwatch starts here so `durationMs`
        // spans the whole lookup on every completion path.
        let query = raw
        let attemptStartedAt = Date()

        Task { [weak self] in
            guard let self else { return }
            guard let transport = self.weatherTransport else {
                await MainActor.run {
                    self.deliverWeatherFallback(locale: locale, query: query,
                                                startedAt: attemptStartedAt)
                }
                return
            }

            // Step 1 — a named place answers for that place. Any geocode
            // failure falls through to the device fix below. The place is
            // extracted ONCE up front so the device path below can tell
            // "answered for a place that was asked but not geocoded"
            // (log outcome "fallback") apart from "no place was named"
            // (log outcome "ok") without re-parsing the utterance.
            let namedPlace = WeatherTool.placeName(in: raw)
            if let askedPlace = namedPlace {
                do {
                    let place = try await WeatherTool.fetchGeocode(name: askedPlace,
                                                                   transport: transport)
                    let conditions = try await WeatherTool.fetchCurrent(
                        latitude: place.latitude, longitude: place.longitude, transport: transport)
                    await MainActor.run {
                        self.deliverLiveWeather(conditions, placeName: place.name, locale: locale,
                                                query: query, outcome: "ok",
                                                startedAt: attemptStartedAt)
                    }
                    return
                } catch {
                    // Fall through — an honest answer about the device's
                    // place beats silence.
                }
            }

            // Step 2 — device location. Create + start the fetcher on the
            // main actor: CLLocationManager delivers delegate callbacks
            // on the runloop of the thread that created it, so it must be
            // born on main. (MainActor.run's body is synchronous, so the
            // request is started from an inner @MainActor task and its
            // exactly-once completion is bridged back through a
            // continuation.)
            let fixResult: Result<LocationFix, LocationFetchFailure>? = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let fetcher = self.locationFetcherFactory?() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    fetcher.requestCurrentLocation { result in
                        continuation.resume(returning: result)
                    }
                }
            }
            guard case .success(let fix)? = fixResult else {
                await MainActor.run {
                    self.deliverWeatherFallback(locale: locale, query: query,
                                                startedAt: attemptStartedAt)
                }
                return
            }
            do {
                let conditions = try await WeatherTool.fetchCurrent(latitude: fix.latitude,
                                                                    longitude: fix.longitude,
                                                                    transport: transport)
                await MainActor.run {
                    self.deliverLiveWeather(conditions, placeName: fix.placeName, locale: locale,
                                            query: query,
                                            outcome: namedPlace == nil ? "ok" : "fallback",
                                            startedAt: attemptStartedAt)
                }
            } catch {
                await MainActor.run {
                    self.deliverWeatherFallback(locale: locale, query: query,
                                                startedAt: attemptStartedAt)
                }
            }
        }
    }

    /// [WEATHER-ROUTING] (2026-09-07) Live-conditions delivery — the
    /// single point where a real open-meteo reading reaches the user:
    /// the localized conditions sentence (`WeatherTool.reply`) is WRAPPED
    /// in the `weather.replySource` hedge ("According to the weather
    /// service, …") so a live reading is presented as forecast data,
    /// never as unmediated ground truth. The bare sentence stays the
    /// tool's own contract (WeatherToolTests pin it directly); the router
    /// applies the hedge here, once, for every delivery path (geocoded
    /// named place and device location alike).
    private func deliverLiveWeather(_ conditions: WeatherTool.CurrentConditions,
                                    placeName: String?,
                                    locale: Locale,
                                    query: String,
                                    outcome: String,
                                    startedAt: Date) {
        emitLocalTool(eventType: "weather", outcome: "ok")
        let conditionsText = WeatherTool.reply(for: conditions, placeName: placeName, locale: locale)
        let text = L10n.fmt("weather.replySource", locale: locale, conditionsText)
        coordinator?.noteGenericReply(text)
        speak(text: text, locale: locale)
        // [TOOL-DEBUG-LOG] (2026-09-07) The bus event stays "ok" on BOTH
        // live deliveries (a live reading reached the user — the local-
        // tools tests pin that); the DEBUG LOG's `outcome` is finer: the
        // caller passes "fallback" when the named place failed to geocode
        // and the device reading answered in its place.
        logToolRequest(kind: .weather, query: query, response: text, outcome: outcome,
                       statusCode: nil, durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// The tool's failure delivery — the unchanged deterministic weather
    /// answer. Mirrors the pre-tool static block exactly (same text via
    /// `TopicPreAnswer.reply(for: .weather)`, same carding + speak path);
    /// the observability event differs deliberately: `topic_pre_answer`
    /// is replaced by `local_tools`/`weather`/`fail` so a fallback that
    /// followed a tool attempt is distinguishable from one that never
    /// had live data to try.
    private func deliverWeatherFallback(locale: Locale, query: String, startedAt: Date) {
        emitLocalTool(eventType: "weather", outcome: "fail")
        let text = TopicPreAnswer.reply(for: .weather, locale: locale)
        coordinator?.noteGenericReply(text)
        speak(text: text, locale: locale)
        // [TOOL-DEBUG-LOG] (2026-09-07) Failure delivery → one "fail"
        // entry carrying the honest no-data line the user actually heard.
        logToolRequest(kind: .weather, query: query, response: text, outcome: "fail",
                       statusCode: nil, durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// [LOCAL-TOOLS] (2026-09-07) The web-search hook — see the
    /// `.available` call site. Returns true when the hook TOOK the turn
    /// (announced something — the caller must NOT speak the generic
    /// re-prompt); false when the utterance is not search business and
    /// the caller speaks the re-prompt as before.
    ///
    /// Firing contract (all must hold):
    ///  1. Deterministic-topic veto below (defense in depth).
    ///  2. On-device stack (Gemini answers natively — never here).
    ///  3. `SearchConfigStore.isConfigured` — search is family opt-in.
    ///  4. `SearchTool.isQuestionShaped` — statements and noise never
    ///     leave the device.
    ///  5. Quota remains — otherwise the cap line + the generic re-prompt
    ///     are spoken instead (the user hears WHY nothing was searched).
    ///
    /// The utterance never produced an intent/topic/tool by construction:
    /// this hook runs only at the routeKeywordRemainder abstention point.
    private func fireWebSearchIfDue(_ raw: String) -> Bool {
        // [WEATHER-ROUTING] (2026-09-07) Deterministic-topic veto: a
        // weather question must NEVER be answered from a web snippet
        // (Arncliffe report — a stale snippet spoken as fact). The topic
        // pre-answer stage above already intercepts every matched
        // utterance before the interpreter, so a topic utterance cannot
        // reach this hook TODAY — the veto is defense in depth against
        // future reordering of the routing ladder, and it costs one
        // cheap table match per abstention. Any matched topic (weather,
        // time, date, greeting) is vetoed: all of them have a
        // deterministic answer upstream that search must never bypass.
        guard TopicPreAnswer.match(transcript: raw) == nil else {
            return false
        }
        guard coordinator?.isOnDeviceStack == true,
              let config = searchConfigStore, config.isConfigured,
              let apiKey = config.apiKey,
              let searchEngineID = config.searchEngineID,
              SearchTool.isQuestionShaped(raw) else {
            return false
        }
        // [TOOL-DEBUG-LOG] (2026-09-07) The hook is taking the turn —
        // snapshot the request text + stopwatch BEFORE the quota check
        // and the network round-trip, so the cap path and every delivery
        // path below record the same original query and an honest
        // duration. Guard failures above never reach here — a declined
        // utterance is not a search attempt and logs nothing (matching
        // the `local_tools` event gating).
        let query = raw
        let attemptStartedAt = Date()
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let quotaDefaults = searchQuotaDefaults
        let remaining = SearchQuota.remaining(
            today: Date(),
            count: SearchQuota.readCount(defaults: quotaDefaults),
            limit: SearchQuota.dailyLimit,
            defaults: quotaDefaults
        )
        guard remaining > 0 else {
            // Cap path: the cap notice is VISIBLE (the live-caption pill
            // is long gone by now) and both lines are spoken as one
            // uninterrupted sequence — the generic re-prompt follows the
            // reason, exactly as an unanswered day would sound.
            emitLocalTool(eventType: "search", outcome: "cap")
            let capText = L10n.str("search.capReached", locale: locale)
            coordinator?.noteGenericReply(capText)
            speakSequentially([capText, L10n.str("router.reprompt", locale: locale)],
                              locale: locale)
            logToolRequest(kind: .search, query: query, response: capText, outcome: "cap",
                           statusCode: nil,
                           durationMs: Self.elapsedMilliseconds(since: attemptStartedAt))
            return true
        }
        // Attempt-based accounting: the count ticks at FIRE time (an
        // honest "we tried N times today"), before the network round-trip.
        speak(key: "search.looking")
        _ = SearchQuota.increment(defaults: quotaDefaults)
        Task { [weak self] in
            guard let self else { return }
            guard let transport = self.searchTransport else {
                await MainActor.run {
                    self.deliverSearchFallback(locale: locale, query: query,
                                               startedAt: attemptStartedAt)
                }
                return
            }
            var request = URLRequest(url: SearchTool.requestURL(query: raw,
                                                                apiKey: apiKey,
                                                                searchEngineId: searchEngineID))
            request.timeoutInterval = Self.searchFetchTimeoutSeconds
            do {
                let (data, response) = try await transport.fetchData(for: request)
                // [TOOL-DEBUG-LOG] (2026-09-07) The status code is captured
                // here, before the delivery hop — a non-200 that falls
                // back still records the code it got (nil only when the
                // transport threw before any HTTP response).
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let httpOK = statusCode == 200
                let summary = httpOK
                    ? SearchTool.summaryReply(for: SearchTool.parseSearchJSON(data: data),
                                              locale: locale)
                    : nil
                guard let summary else {
                    await MainActor.run {
                        self.deliverSearchFallback(locale: locale, query: query,
                                                   startedAt: attemptStartedAt,
                                                   statusCode: statusCode)
                    }
                    return
                }
                await MainActor.run {
                    self.emitLocalTool(eventType: "search", outcome: "ok")
                    self.coordinator?.noteGenericReply(summary)
                    self.speak(text: summary, locale: locale)
                    self.logToolRequest(kind: .search, query: query, response: summary,
                                        outcome: "ok", statusCode: statusCode,
                                        durationMs: Self.elapsedMilliseconds(since: attemptStartedAt))
                }
            } catch {
                await MainActor.run {
                    self.deliverSearchFallback(locale: locale, query: query,
                                               startedAt: attemptStartedAt)
                }
            }
        }
        return true
    }

    /// Failure/empty delivery for the search tool — the SAME generic
    /// re-prompt the abstention point would have spoken, plus a
    /// `local_tools` `search` `fail` event. Never a fabricated answer,
    /// never a dead end.
    private func deliverSearchFallback(locale: Locale, query: String,
                                       startedAt: Date, statusCode: Int? = nil) {
        emitLocalTool(eventType: "search", outcome: "fail")
        speak(key: "router.reprompt")
        // [TOOL-DEBUG-LOG] (2026-09-07) Failure/empty delivery → one
        // "fail" entry carrying the honest re-prompt line the user heard
        // (and the HTTP status when a non-200 response caused it).
        let reprompt = L10n.str("router.reprompt", locale: locale)
        logToolRequest(kind: .search, query: query, response: reprompt, outcome: "fail",
                       statusCode: statusCode,
                       durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    // MARK: - [YOUTUBE] Voice YouTube search/play (youtube-plugin, 2026-09-08)

    /// The YouTube stage's execution (see the stage comment in `route`).
    /// Called only after `YouTubeRoute.decide` matched with an extracted
    /// query. Two honest paths:
    ///
    ///   · API key configured: announce `youtube.looking`, fetch the TOP
    ///     video from the YouTube Data API v3 (`LocalToolTransport` seam,
    ///     8 s timeout — the weather/search budget), open
    ///     `youtube://watch` (https fallback when the app is absent via
    ///     the `CallLinkOpening` seam), and speak the title-bearing
    ///     confirmation. The title goes through the SPOKEN path ONLY: no
    ///     visible card, never into the observability bus or the debug
    ///     log (the log entry for the success path carries the query +
    ///     outcome, an EMPTY response by design — see `logToolRequest`).
    ///   · No key: open the SEARCH deeplink directly
    ///     (`youtube://www.youtube.com/results` → https fallback) and
    ///     speak `youtube.openingSearch` — the user accepted
    ///     search-only as the MVP, so this is the whole feature, not a
    ///     degraded mode.
    ///
    ///   Every failure (no transport, no opener, network error, non-200
    ///   quota/rate-limit, empty results, malformed payload) speaks an
    ///   honest localized fallback — `youtube.notFound` for an empty
    ///   result set, `youtube.unavailable` otherwise — never a
    ///   fabricated title, never a dead end.
    private func fireYouTubePlay(query: String) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let attemptStartedAt = Date()

        // Keyless path — no network at all; the deeplink IS the
        // feature. Synchronous: the confirmation is committed before
        // this turn returns.
        guard let apiKey = youtubeConfigStore?.apiKey else {
            guard let opener = youtubeLinkOpener else {
                deliverYouTubeFailure(locale: locale, query: query,
                                      fallbackKey: "youtube.unavailable",
                                      statusCode: nil, startedAt: attemptStartedAt)
                return
            }
            let outcome = YouTubeTool.openSearch(query: query, opener: opener)
            emitYouTube(eventType: "youtube_search",
                        outcome: outcome == .openedApp ? "opened_app" : "opened_web")
            let text = L10n.fmt("youtube.openingSearch", locale: locale, query)
            speak(text: text, locale: locale)
            // [TOOL-DEBUG-LOG] The spoken line embeds the query (the
            // user's own words — already logged raw by the search tool's
            // convention); response stays EMPTY on the ok path so the
            // encrypted store never gains text the design keeps to
            // speech.
            logToolRequest(kind: .youtube, query: query, response: "", outcome: "ok",
                           statusCode: nil,
                           durationMs: Self.elapsedMilliseconds(since: attemptStartedAt))
            return
        }

        // Keyed path — async Data API round-trip.
        speak(key: "youtube.looking")
        Task { [weak self] in
            guard let self else { return }
            guard let transport = self.youtubeTransport else {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               fallbackKey: "youtube.unavailable",
                                               statusCode: nil, startedAt: attemptStartedAt)
                }
                return
            }
            do {
                let top = try await YouTubeTool.fetchTopResult(query: query,
                                                               apiKey: apiKey,
                                                               transport: transport)
                await MainActor.run {
                    guard let opener = self.youtubeLinkOpener else {
                        self.deliverYouTubeFailure(locale: locale, query: query,
                                                   fallbackKey: "youtube.unavailable",
                                                   statusCode: nil, startedAt: attemptStartedAt)
                        return
                    }
                    let outcome = YouTubeTool.openWatch(videoID: top.videoID, opener: opener)
                    self.emitYouTube(eventType: "youtube_play",
                                     outcome: outcome == .openedApp ? "opened_app" : "opened_web")
                    let text = L10n.fmt("youtube.playing", locale: locale, top.title)
                    // Spoken path ONLY: the title-bearing confirmation
                    // is never carded and never logged (the design's
                    // "SPOKEN path only (no logs)" rule). The debug-log
                    // entry below records the attempt with an EMPTY
                    // response for exactly that reason.
                    self.speak(text: text, locale: locale)
                    self.logToolRequest(kind: .youtube, query: query, response: "",
                                        outcome: "ok", statusCode: 200,
                                        durationMs: Self.elapsedMilliseconds(since: attemptStartedAt))
                }
            } catch YouTubeTool.FetchError.noResults {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               fallbackKey: "youtube.notFound",
                                               statusCode: 200, startedAt: attemptStartedAt)
                }
            } catch YouTubeTool.FetchError.invalidResponse(let statusCode) {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               fallbackKey: "youtube.unavailable",
                                               statusCode: statusCode, startedAt: attemptStartedAt)
                }
            } catch {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               fallbackKey: "youtube.unavailable",
                                               statusCode: nil, startedAt: attemptStartedAt)
                }
            }
        }
    }

    /// Failure delivery for the YouTube stage — the honest localized
    /// fallback line (`youtube.notFound` / `youtube.unavailable`), a
    /// `youtube` component `fail` event, and one "fail" debug-log entry
    /// carrying the line the user actually heard (never a title).
    private func deliverYouTubeFailure(locale: Locale, query: String,
                                       fallbackKey: String,
                                       statusCode: Int?, startedAt: Date) {
        emitYouTube(eventType: "youtube", outcome: "fail")
        speakWithVisibleOutcome(key: fallbackKey)
        let line = L10n.str(fallbackKey, locale: locale)
        logToolRequest(kind: .youtube, query: query, response: line, outcome: "fail",
                       statusCode: statusCode,
                       durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// [YOUTUBE] (2026-09-08) `youtube` observability events — one per
    /// YouTube turn. Component `youtube`, eventType
    /// `youtube_search`/`youtube_play`/`youtube`, outcome
    /// `opened_app`/`opened_web`/`fail`. No metadata keys are attached,
    /// so nothing user-identifying (the query, the video ID, the title)
    /// ever reaches the bus.
    private func emitYouTube(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "youtube",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }

    // MARK: - [TOOL-DEBUG-LOG] Local-tool request log

    /// [TOOL-DEBUG-LOG] (2026-09-07) One debug-log entry per local-tool
    /// request (weather, search or youtube) — the helper behind every
    /// hook point in the [LOCAL-TOOLS] section above and the [YOUTUBE]
    /// stage. `query` was snapshotted BEFORE the request went out; this
    /// call adds the outcome + what the app answered on the completion
    /// path:
    ///
    ///   · ok — a live answer was delivered: the weather conditions
    ///     sentence, the search summary, or the YouTube confirmation
    ///     (the spoken text). YouTube's ok entries carry an EMPTY
    ///     response by design — the title-bearing confirmation is
    ///     spoken-only and never recorded anywhere ([YOUTUBE]
    ///     2026-09-08),
    ///   · fallback — weather only: the NAMED place failed to resolve
    ///     (geocode error/empty) and the live DEVICE reading answered
    ///     instead — still a live reading, but for the wrong place,
    ///   · cap — search only: quota exhausted before any request; the cap
    ///     line is the response,
    ///   · fail — no live answer: the honest static weather no-data line,
    ///     the generic search re-prompt, or the YouTube fallback line
    ///     (never a title) was delivered.
    ///
    /// Scope note: the Gemini grounding path ([INTENT-TOOLS] — the cloud
    /// stack's search-grounded interpreter) is deliberately OUT of scope.
    /// These hooks sit in the LOCAL-tools stages, which only the
    /// on-device stack reaches; cloud-stack answers never pass through
    /// them, so nothing from Gemini is logged here.
    ///
    /// Privacy (C9): the entry carries raw user text but goes straight to
    /// the encrypted on-device store — it never reaches the observability
    /// bus (PII-free by policy) and never a console log. Nil store
    /// (dormant default) = no-op, exactly the pre-tool behavior.
    private func logToolRequest(kind: LocalToolLogEntry.Kind, query: String, response: String,
                                outcome: String, statusCode: Int?, durationMs: Int?) {
        guard let localToolLogStore else { return }
        localToolLogStore.record(LocalToolLogEntry(
            kind: kind, query: query, response: response, outcome: outcome,
            statusCode: statusCode, durationMs: durationMs
        ))
    }

    /// Whole-millisecond wall-clock span between the attempt start
    /// (snapshotted before the round-trip) and a completion point —
    /// `durationMs` for the tool log. Clamped at zero so a sub-millisecond
    /// turn (the cap path) never records a negative duration.
    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// Speaks several already-resolved lines as ONE uninterrupted
    /// sequence. The speaker cancels in-flight speech at the start of
    /// each `speak(_:)` call, so naive back-to-back `speak(key:)` calls
    /// would cut each other off — multi-line outcomes (the search cap
    /// notice followed by the re-prompt) must await each line inside a
    /// single task. Carding: each line is transcripted
    /// (`noteAssistantSpoke`); the caller cards the outcome itself
    /// (`noteGenericReply`) before calling, when a visible card is due.
    private func speakSequentially(_ lines: [String], locale: Locale) {
        guard let speaker, !lines.isEmpty else { return }
        for line in lines {
            coordinator?.noteAssistantSpoke(line)
        }
        coordinator?.noteSpeakingStarted()
        // [TURN-TIMING] Same speak bookends as `speak(text:)` — one
        // queued entry for the whole sequence.
        turnTracer?.noteSpeakQueued()
        Task {
            for line in lines {
                await speaker.speak(line, locale: locale)
            }
            self.turnTracer?.noteSpeakFinished()
            coordinator?.noteSpeakingEnded()
        }
    }

    /// [LOCAL-TOOLS] (2026-09-07) `local_tools` observability events —
    /// one per local-tool turn. Component `local_tools`, eventType
    /// `weather`/`search`, outcome `ok`/`cap`/`fail` (weather has no cap:
    /// it is rate-limited by the user's own asking, and open-meteo needs
    /// no key). No metadata keys are attached, so nothing user-identifying
    /// (the query, the coordinates) ever reaches the bus.
    private func emitLocalTool(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "local_tools",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }

    // MARK: - LLM dispatch

    /// The raw transcript currently being dispatched through an
    /// interpreted command — set by the async interpret completion and
    /// cleared after dispatch, so handlers (e.g. `handleCall`) can thread
    /// it to the coordinator for cache learning. Single in-flight
    /// interpretation at a time (VoicePipeline serialises utterances).
    private var pendingTranscript: String?

    /// [NO-GIBBERISH] (2026-09-07) Clock seam for the deterministic
    /// time/date pre-answers (`TopicPreAnswer` reads the current time from
    /// this) — injectable so router tests can pin the exact spoken
    /// sentence without depending on the wall clock.
    var clock: () -> Date = { Date() }

    private func dispatchInterpreted(_ command: InterpretedCommand) {
        switch command.action {
        case .ackMed:
            // [NO-GIBBERISH] (2026-09-07) The model's ack text is flavor
            // over a deterministic outcome — gate it: a rejected override
            // (nil) falls back to the baseline confirmation the
            // no-override path already speaks (router.confirmationYes),
            // and emits `llama_response_rejected_sanity`. The raw text
            // never reaches the speaker.
            handleMedicationAcknowledgement(replyOverride: sanitisedModelReply(command.reply))
        case .emergency:
            emit(eventType: "command_emergency", outcome: "success")
            handleEmergency()
        case .call:
            handleCall(command)
        case .setReminder:
            handleSetReminder(command)
        case .healthQuery:
            // First-class stub intent — honest "not yet" (spec §5.1).
            emit(eventType: "command_health_query_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.healthNotAvailable")
        case .music:
            // First-class stub intent (spec §5.1).
            emit(eventType: "command_music_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.musicStub")
        case .sendMessage:
            handleSendMessage(command)
        case .guide:
            handleGuide(command)
        case .createCalendarEvent, .suggestVideo:
            // Honest not-yet stubs (spec §7.3): the executors for these
            // land with the calendar/video phases — never pretend an
            // event was created or a video queued.
            emit(eventType: "command_v2_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.featureNotYet")
        case .query:
            emit(eventType: "command_llm_query", outcome: "info")
            deliverModelReply(command.reply)
        case .none:
            emit(eventType: "command_llm_no_action", outcome: "info")
            deliverModelReply(command.reply)
        case .plugin:
            handlePluginCommand(command)
        }
    }

    /// [NO-GIBBERISH] (2026-09-07) Gated delivery for model-text Q&A
    /// replies (.query/.none): the text is carded + spoken ONLY when it
    /// passes `ReplySanityGate`; a rejection speaks and cards the honest
    /// localized fallback instead (`router.modelReplyUnclear`). The raw
    /// text never reaches the speaker or the visible card either way, and
    /// every rejection is observable
    /// (`llama_response_rejected_sanity`, reason in errorCode).
    private func deliverModelReply(_ text: String) {
        if let safe = sanitisedModelReply(text) {
            coordinator?.noteGenericReply(safe)
            speak(text: safe)
        } else {
            speakWithVisibleOutcome(key: "router.modelReplyUnclear")
        }
    }

    /// [NO-GIBBERISH] (2026-09-07) Sanity-gates model-generated text
    /// about to be spoken/shown. Returns the text when it is safe to
    /// deliver; nil when it must NOT be delivered (the caller speaks an
    /// honest fallback). Every rejection emits
    /// `llama_response_rejected_sanity` with the reason as errorCode —
    /// rejected model text is observable and never reaches a human ear.
    private func sanitisedModelReply(_ text: String) -> String? {
        if let reason = ReplySanityGate.rejectionReason(text) {
            observabilityBus.emit(ObservabilityEvent(
                component: "command_router",
                eventType: "llama_response_rejected_sanity",
                durationMs: nil,
                outcome: "rejected",
                errorCode: reason.rawValue,
                metadata: [:]
            ))
            return nil
        }
        return text
    }

    /// `set_reminder`: parse the spoken time expression, create the
    /// reminder via scheduler storage, and confirm with the time spoken
    /// back (spec §5.1, §5.2).
    private func handleSetReminder(_ command: InterpretedCommand) {
        guard let timeString = command.time,
              let time = NepaliTimeParser.parse(timeString) else {
            emit(eventType: "command_set_reminder_no_time", outcome: "info")
            speak(key: "router.reminderNoTime")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let title = command.medication ?? L10n.str("reminder.defaultTitle", locale: locale)
        coordinator?.addVoiceReminder(title: title, time: time)
        emit(eventType: "command_set_reminder", outcome: "success")
        let spokenTime = formattedTime(time, locale: locale)
        speak(text: L10n.fmt("router.reminderSet", locale: locale, spokenTime))
    }

    /// Safety path with NO auth gate (spec §5.1, constitution: emergency
    /// must never be blocked by auth or a busy/unavailable LLM) — shared
    /// by both the deterministic keyword path (`routeKeyword`) and the
    /// LLM-interpreted path (`dispatchInterpreted`) so they produce
    /// identical behavior. Today: spoken ack + local notification — the
    /// broker relay and a real emergency-call module don't exist yet.
    private func handleEmergency() {
        postLocalizedNotification(titleKey: "notif.emergencyAck.title",
                                  bodyKey: "notif.emergencyAck.body")
        speak(key: "router.emergencyAck")
    }

    /// `call` (trial wiring, LLM-interpreted path only — the deterministic
    /// keyword layer keeps blocking ANY call-ish phrase unconditionally
    /// since it has no entity extraction to identify a real target; see
    /// `routeKeyword`'s `sensitiveCallPhrases`, unchanged). Only a
    /// specifically-resolved contact gets dialed for real.
    private func handleCall(_ command: InterpretedCommand) {
        guard let prompt = coordinator?.requestCallConfirmation(
            contactQuery: command.contact, callType: command.callType, requestedApp: command.requestedApp,
            sourceTranscript: pendingTranscript, sourceCommand: command
        ) else {
            // Distinguish WHY it failed instead of one generic "blocked"
            // message: a name was extracted but didn't match anyone in
            // family contacts (fixable by the user — add the contact) is
            // a different situation from no name being understood at all
            // (fixable by re-phrasing), and neither should sound like a
            // permissions/auth problem, since neither is one.
            if let contact = command.contact, !contact.isEmpty {
                emit(eventType: "command_call_contact_not_found", outcome: "blocked")
                speak(text: L10n.fmt("router.call.contactNotFound", locale: coordinator?.activeLocale ?? Locale(identifier: "ne-NP"), contact))
            } else {
                emit(eventType: "command_sensitive_blocked_auth_unavailable", outcome: "blocked")
                speakWithVisibleOutcome(key: "router.sensitiveBlocked")
            }
            return
        }
        emit(eventType: "command_call_confirmation_requested", outcome: "success")
        speak(text: prompt)
    }

    /// `send_message`. Never claims the message was SENT — only that a
    /// surface is ready, since the user still has to tap Send (native
    /// sheet, or inside WhatsApp for the deep link — v2 §4.3). The
    /// coordinator speaks for the deep-link/fallback outcomes (it alone
    /// knows which surface appeared); the router keeps speaking the
    /// model's ack for the shipped native-compose path.
    private func handleSendMessage(_ command: InterpretedCommand) {
        guard let body = command.message, !body.isEmpty else {
            emit(eventType: "command_message_unresolved", outcome: "blocked")
            speak(key: "router.messageContactNotFound")
            return
        }
        switch coordinator?.composeMessage(toContactNamed: command.contact,
                                           body: body,
                                           requestedApp: command.requestedApp) {
        case .nativeComposePresented:
            emit(eventType: "command_message_composing", outcome: "success")
            // [NO-GIBBERISH] (2026-09-07) The model's ack is spoken only
            // when it passes the sanity gate; a rejected ack is NOT
            // replaced by a spoken fallback here because the compose
            // sheet itself is the real, visible outcome — but the
            // rejection is still observable
            // (`llama_response_rejected_sanity`).
            if sanitisedModelReply(command.reply) != nil {
                speak(text: command.reply)
            }
        case .whatsAppChatOpened:
            emit(eventType: "command_message_whatsapp_opened", outcome: "success")
        case .fellBackToNativeCompose:
            emit(eventType: "command_message_whatsapp_fallback_sms", outcome: "info")
        case .copiedTextOnly:
            emit(eventType: "command_message_whatsapp_copied", outcome: "info")
        case .contactNotFound, .none:
            emit(eventType: "command_message_unresolved", outcome: "blocked")
            speak(key: "router.messageContactNotFound")
        }
    }

    /// `.plugin` intent (plugin architecture, 2026-09-05). Resolves the
    /// pluginAction through the registry — core never knows plugin
    /// action names statically — and dispatches to the plugin's
    /// `handle`. Result delivery mirrors every other action's: generic
    /// outcome card + spoken text, plus an optional presented view.
    private func handlePluginCommand(_ command: InterpretedCommand) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        guard let registry = pluginRegistry,
              let geminiClient = geminiClient,
              let actionName = command.pluginAction,
              let plugin = registry.plugin(handling: actionName, locale: locale) else {
            emit(eventType: "command_plugin_unresolved", outcome: "blocked")
            speak(key: "router.pluginUnavailable")
            return
        }
        emit(eventType: "command_plugin_dispatched", outcome: "success")
        let pluginCommand = PluginCommand(
            actionName: actionName,
            transcript: "",
            entities: command.pluginEntities ?? [:],
            confidence: command.confidence
        )
        let execContext = PluginExecutionContext(
            locale: locale,
            geminiClient: geminiClient,
            observabilityBus: observabilityBus
        )
        Task { [weak self] in
            guard let self else { return }
            let result = await plugin.handle(pluginCommand, context: execContext)
            let view = plugin.presentationView(for: result)
            await MainActor.run {
                self.coordinator?.noteGenericReply(result.spokenText)
                if let view {
                    self.coordinator?.presentPluginView(view)
                }
                self.speak(text: result.spokenText)
            }
        }
    }

    /// `guide` intent (spec §5 Guide class): steps are READ ALOUD to the
    /// human, never executed on-device. Defers to the appliance plugin
    /// when it can serve the topic (2026-09-05 integration #4 — the
    /// plugin owns appliance UX: photo + grounding overlay, manuals);
    /// the understand call's steps remain the fallback until the plugin
    /// matures past its skeleton, so appliance questions work TODAY and
    /// upgrade automatically when the plugin lands.
    private func handleGuide(_ command: InterpretedCommand) {
        emit(eventType: "command_guide", outcome: "info")
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let sourceTranscript = pendingTranscript ?? ""
        guard let registry = pluginRegistry,
              let geminiClient,
              let topic = command.topic, !topic.isEmpty,
              let plugin = registry.plugin(handling: "appliance.identify", locale: locale) else {
            speakGuideSteps(command)
            return
        }
        let pluginCommand = PluginCommand(actionName: "appliance.identify",
                                          transcript: sourceTranscript,
                                          entities: ["appliance": topic],
                                          confidence: command.confidence)
        let execContext = PluginExecutionContext(locale: locale,
                                                 geminiClient: geminiClient,
                                                 observabilityBus: observabilityBus)
        Task { [weak self] in
            guard let self else { return }
            let result = await plugin.handle(pluginCommand, context: execContext)
            await MainActor.run {
                if case .failed = result {
                    // Plugin not ready (skeleton) — steps are the honest
                    // answer today.
                    self.speakGuideSteps(command)
                    return
                }
                self.coordinator?.noteGenericReply(result.spokenText)
                if let view = plugin.presentationView(for: result) {
                    self.coordinator?.presentPluginView(view)
                }
                self.speak(text: result.spokenText)
            }
        }
    }

    private func speakGuideSteps(_ command: InterpretedCommand) {
        // [NO-GIBBERISH] (2026-09-07) Guide text is model-generated and
        // read aloud — gate it exactly like every other model speech:
        // rejected text is replaced by the honest fallback, never spoken.
        if let steps = command.steps, !steps.isEmpty {
            let spoken = steps.joined(separator: ". ")
            if let safe = sanitisedModelReply(spoken) {
                coordinator?.noteGenericReply(safe)
                speak(text: safe)
            } else {
                speakWithVisibleOutcome(key: "router.modelReplyUnclear")
            }
        } else if let safe = sanitisedModelReply(command.reply) {
            coordinator?.noteGenericReply(safe)
            speak(text: safe)
        } else {
            speakWithVisibleOutcome(key: "router.modelReplyUnclear")
        }
    }

    /// Spoken-form time for alarm/reminder confirmations (spoken-time
    /// task, 2026-09-08): the old `.shortened` clock text made the TTS
    /// read "१३:००"/"13:00" as digits ("thirteen hundred") instead of
    /// "1 pm" / "दिउँसो १ बजे". All speech-bound lines share
    /// `SpokenTime`; UI display formatting is untouched.
    private func formattedTime(_ components: DateComponents, locale: Locale) -> String {
        SpokenTime.string(hour: components.hour ?? 0,
                          minute: components.minute ?? 0,
                          locale: locale)
    }

    private func handleMedicationAcknowledgement(replyOverride: String? = nil) {
        guard let coordinator = coordinator,
              let oldest = coordinator.oldestPendingReminderEntryId() else {
            postLocalizedNotification(titleKey: "notif.nothingToAcknowledge.title",
                                      bodyKey: "notif.nothingToAcknowledge.body")
            emit(eventType: "command_ack_no_pending", outcome: "info")
            speak(key: "router.noPendingReminder")
            return
        }

        // Dementia flow: issue the FR-D01 challenge before recording the
        // dose. The user's yes/no on the next transcript runs through
        // `handleConfirmationResponse`, which triggers the FR-D03
        // double-dose check. Falls back to baseline ack only if the
        // challenge cannot be issued (no pending reminder, etc).
        if let prompt = coordinator.startVoiceAckConfirmation(for: oldest) {
            emit(eventType: "command_ack_challenge_issued", outcome: "success")
            postLocalizedNotification(titleKey: "notif.confirmingDose.title",
                                      body: prompt)
            speak(text: prompt)
            return
        }

        coordinator.handleMedicationAcknowledgement(entryId: oldest)
        emit(eventType: "command_ack_medication_baseline", outcome: "success")
        postLocalizedNotification(titleKey: "notif.medicationAcknowledged.title",
                                  bodyKey: "notif.medicationAcknowledged.body")
        if let replyOverride {
            speak(text: replyOverride)
        } else {
            speak(key: "router.confirmationYes")
        }
    }

    /// Whole-token match — the ONLY safe way to match "हो" (yes), because
    /// "होइन" (no) and "होइनन्" contain it as a substring. Checking no-before-
    /// yes at the call site is not sufficient on its own: an utterance like
    /// "हो… होइन" (yes… no — user correcting themselves mid-sentence) contains
    /// both, and token matching alone can't order intent. So: any negation
    /// token present at all → treated as a no (conservative, safe direction
    /// for medication confirmation).
    private static func isYesResponse(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoResponse(t) { return false }
        let phrases = ["yes", "yeah", "yep", "yup", "correct",
                       "हो", "हजुर"]   // Nepali: ho, hajur
        return phrases.contains(where: { containsToken($0, in: t) })
    }

    private static func isNoResponse(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = ["no", "nope", "wrong",
                       "छैन", "होइन", "होइनन्"]   // Nepali: chhaina, hoina, hoinan
        return phrases.contains(where: { containsToken($0, in: t) })
    }

    // MARK: - Speech (localized — spec §3.2)

    /// Speaks a catalog key resolved in the coordinator's active locale.
    private func speak(key: String) {
        guard let speaker else { return }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let text = L10n.str(key, locale: locale)
        guard !text.isEmpty else { return }
        speak(text: text, locale: locale)
    }

    /// Same as `speak(key:)` but also surfaces the resolved text as a
    /// visible outcome card — for stub replies (health/music) that would
    /// otherwise be spoken-only, same rationale as `noteGenericReply`.
    private func speakWithVisibleOutcome(key: String) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let text = L10n.str(key, locale: locale)
        guard !text.isEmpty else { return }
        coordinator?.noteGenericReply(text)
        speak(text: text, locale: locale)
    }

    /// Speaks dynamic text (LLM-generated replies, scheduler challenge
    /// prompts) — no catalog lookup, already in the right language.
    private func speak(text: String, locale: Locale? = nil) {
        #if DEBUG
        print("[command_router][DEBUG] speak() called, speaker=\(speaker != nil), text=\"\(text)\"")
        #endif
        guard let speaker, !text.isEmpty else {
            #if DEBUG
            print("[command_router][DEBUG] speak() BAILED — speaker nil or text empty")
            #endif
            return
        }
        let locale = locale ?? coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        coordinator?.noteAssistantSpoke(text)
        coordinator?.noteSpeakingStarted()
        // [TURN-TIMING] The reply utterance is handed to the speaker.
        turnTracer?.noteSpeakQueued()
        Task {
            await speaker.speak(text, locale: locale)
            #if DEBUG
            print("[command_router][DEBUG] speaker.speak() returned (finished or cancelled)")
            #endif
            // [TURN-TIMING] Reply speech finished — the last one
            // finalizes the turn.
            self.turnTracer?.noteSpeakFinished()
            coordinator?.noteSpeakingEnded()
        }
    }

    // MARK: - Notifications (localized, no raw transcripts — C9)

    private func postLocalizedNotification(titleKey: String,
                                           bodyKey: String? = nil,
                                           body: String? = nil) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let content = UNMutableNotificationContent()
        content.title = L10n.str(titleKey, locale: locale)
        if let bodyKey {
            content.body = L10n.str(bodyKey, locale: locale)
        } else if let body {
            content.body = body
        }
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func emit(eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }
}
