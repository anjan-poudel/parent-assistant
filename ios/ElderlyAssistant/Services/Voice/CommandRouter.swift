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

    // [MULTI-TURN] (2026-10-10, C-MTC-05 §12.1) The dialogue-frame
    // surface the router's pre-ladder interception needs. The coordinator
    // owns the single `DialogueManager`, the answer window and the state
    // machine hop (T-136); the router only reads the live frame, arms a
    // frame, notes an invalid attempt, resolves through the one funnel
    // and prepares the answer text. Each member is a REQUIREMENT with an
    // inert extension default below (the established pattern — the
    // router holds its coordinator as a protocol reference, so an
    // extension-only member would bind statically and AppCoordinator's
    // implementation could never be reached).

    /// The live dialogue frame, nil when absent OR expired (the
    /// coordinator drops an expired frame on read — the interception's
    /// half-open-window guarantee, design-l2 §8). Main-queue read; the
    /// router calls it once per turn.
    var activeDialogueFrame: DialogueFrame? { get }

    /// Arms the frame AND opens the answer window (state machine hop), in
    /// that order (design-l2 §21 step 3). false = a window is already
    /// open (confirmation or frame) or the draft cannot resolve; the
    /// caller then takes its non-probe fallback path (never a dead end).
    func startDialogueFrame(_ frame: DialogueFrame) -> Bool

    /// Invalid-answer accounting: attempts += 1, deadline restamped,
    /// window timer refreshed (L2-D6). Returns the updated attempt count.
    /// Silent — the router emits the event.
    @discardableResult func noteDialogueAttempt() -> Int

    /// The single resolution funnel: clear the frame, cancel the timer,
    /// close the window through legal edges, emit `dialogue_frame_resolved`
    /// for the resolutions the coordinator owns (timeout, emergency,
    /// supersession — design-l2 §26's component split). Idempotent.
    func resolveDialogueFrame(_ resolution: DialogueFrameResolution)

    /// Emergency/supersession clear — `resolveDialogueFrame` with a
    /// reason the caller states (L2-D16): the §12.3 emergency side-effect
    /// and the session-transition supersession both travel here.
    func clearDialogueFrame(reason: DialogueFrameResolution)

    /// The answer text through the exact seam every turn uses: sanitise
    /// (.quarantine) then the shared input seam (L2-D14). Never the
    /// model. The router's fallback when unimplemented is the plain
    /// `.quarantine` sanitise — the same text the default below returns.
    func prepareDialogueAnswerText(_ raw: String) -> String

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

    /// [CALENDAR-EVENTS] (2026-09-13) True while a
    /// `create_calendar_event` confirmation is outstanding. Widens the
    /// router's confirmation path exactly like
    /// `isAwaitingCallConfirmation`: the yes/no on the next transcript
    /// goes to `handleConfirmationResponse` (which pends/writes the
    /// event), and the medication-flavored generic "yes/no" speech is
    /// skipped — the coordinator speaks the event itself ("…added to
    /// your calendar"), and a plain "yes" is not a dose acknowledgement.
    /// Requirement-with-extension-default pattern like the navigation
    /// surface above (the router holds the coordinator as a protocol
    /// reference).
    var isAwaitingCalendarEventConfirmation: Bool { get }

    /// [APP-LAUNCHER] (2026-09-16) True while a `launcher.open` app launch
    /// is pended for the elder's yes/no (design D3: confirm-first before
    /// every external launch). Widens the router's confirmation path
    /// exactly like `isAwaitingCalendarEventConfirmation`: the yes/no on
    /// the next transcript goes to `handleConfirmationResponse` (which
    /// launches or cancels) and the medication-flavored generic yes/no
    /// speech is skipped — the coordinator speaks "Opening X" or the
    /// honest cancellation itself, and a plain "yes" is not a dose
    /// acknowledgement. Requirement-with-extension-default pattern like
    /// the members above (the router holds the coordinator as a protocol
    /// reference, so an extension-only member would bind statically and
    /// AppCoordinator's implementation could never be reached).
    var isAwaitingAppLaunchConfirmation: Bool { get }

    /// [APP-LAUNCHER] (2026-09-16) The app-launch confirmation seam the
    /// `app_launcher` plugin calls (and the deterministic keyword stage may
    /// call once it exists): pends a catalog app for the elder's spoken
    /// yes/no and RETURNS the line to speak. The coordinator owns the
    /// pending state, the 45 s window and the execution — the caller only
    /// speaks what it is handed, exactly like
    /// `requestCalendarEventConfirmation`. A launch that can only fail is
    /// never pended: the returned line is then the honest not-installed
    /// message (or, when the entry has a web fallback, a question that
    /// discloses the swap). Same requirement-with-extension-default
    /// pattern as the members above.
    func requestAppLaunch(appID: String, confidence: Double?) -> String

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

    /// [HOME-TIMER-CHIP] (2026-09-11) Voice timer CANCEL ("cancel the
    /// timer", "stop the timer", "टाइमर बन्द गर", "टाइमर रोक"):
    /// cancels the NEAREST running timer (soonest deadline) through the
    /// existing cancel path — persist removal, cancel the pending
    /// notification and, when system-managed, the AlarmKit timer — and
    /// returns the honest outcome so the router speaks the confirmation
    /// ("Timer cancelled." / "टाइमर बन्द भयो।") or the "no timers
    /// running" / failure fallback. SYNCHRONOUS (cancellation needs no
    /// permission round-trip), main-confined like the service. Same
    /// requirement-with-extension-default pattern as `requestAlarmOff`.
    func requestTimerCancel() -> TimerCancelOutcome

    /// [ALARMKIT-ALARMS] (2026-09-10) The honest denial line when an
    /// alarm-set hits a permission denial — backend-specific copy:
    /// AlarmKit authorization on iOS 26+ (`alarmAlarmKit.permissionDenied`),
    /// notification permission before (`alarms.permissionDenied`). Same
    /// requirement-with-extension-default pattern as the alarm members
    /// above: the router holds the coordinator as a protocol reference,
    /// so an extension-only member would bind statically and
    /// `AppCoordinator`'s backend-aware key could never be reached.
    var alarmPermissionDeniedKey: String { get }
    /// [CALENDAR-EVENTS] (2026-09-13) `create_calendar_event` intent —
    /// the real executor behind the router's confirmation prompt. The
    /// router has already parsed the time expression and resolved the
    /// start instant (`NepaliTimeParser` + `CalendarEventTimeResolver`);
    /// the coordinator pends the event, switches the session to
    /// awaiting-confirmation and RETURNS the localized yes/no prompt to
    /// speak (it owns the locale, the title and `SpokenTime`, so the
    /// spoken start time is always formatted the project-wide way). On
    /// yes it writes the event to the DEFAULT calendar and voices the
    /// honest created/failed outcome; on no it cancels silently.
    ///
    /// Returns nil when the calendar cannot be written at all right now
    /// (access denied/restricted, no calendar store) — the router then
    /// speaks `router.calendarEventCalendarUnavailable` rather than
    /// pretending the event was created or asking the elder to confirm
    /// something that can only fail.
    ///
    /// Same requirement-with-extension-default pattern as the alarm
    /// members above: the router holds the coordinator as a protocol
    /// reference, so an extension-only member would bind statically and
    /// `AppCoordinator`'s implementation could never be reached. The
    /// default nil keeps every existing conformer on the honest
    /// unavailable line.
    func requestCalendarEventConfirmation(title: String, startDate: Date) -> String?

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

    /// [FEEDS-FULL-ARTICLE] (2026-09-19) "read the full article" — the
    /// feeds feature's full-article reading (the item the feed is on, the
    /// source's own body). The COORDINATOR owns every spoken line: the
    /// article itself, the honest "this source shares only a summary"
    /// line, and the honest "there's nothing in your feed" line — the
    /// router adds no speech and no card of its own, exactly like the
    /// news and briefing stages. The reading marks the item read through
    /// the same completion seam the card's button uses.
    func readFullFeedArticle()

    /// [MED-PHOTO] (2026-09-17) The live medication schedule as the voice
    /// photo query sees it: the entries the `.medicationPhoto` keyword rule
    /// builds its vocabulary from (through
    /// `MedicationVoiceVocabulary.voiceKeys(for:)`) AND the entries a
    /// matched key resolves back to. One read serves both halves, which is
    /// what keeps the two derivations from drifting.
    ///
    /// Never a fixed table: a medicine the elder actually has is the only
    /// one that can be asked about, and one deleted between the read and
    /// the resolution simply stops resolving. Inert default ([]): with no
    /// entries the medication group is empty, an empty group can never
    /// satisfy a variant, and the rule can never fire — every conformer
    /// that does not opt in behaves exactly as it did before this member.
    /// Requirement-with-extension-default pattern like the surfaces above
    /// (the router holds the coordinator as a protocol reference, so an
    /// extension-only member would bind statically and `AppCoordinator`'s
    /// implementation could never be reached).
    var medicationVoiceEntries: [MedicationEntry] { get }

    /// [MED-PHOTO] (2026-09-17) The elder asked what a medicine looks
    /// like: presents `entryId`'s photo full screen and RETURNS the line
    /// to speak — the photo's caption, or the honest "no photo yet" line
    /// when the entry carries none. nil means "nothing to say" (the entry
    /// is gone). The caller only speaks what it is handed, exactly like
    /// the launch seam above; the coordinator owns the presentation, the
    /// caption and the honest fallback. Same
    /// requirement-with-extension-default pattern as the members above.
    func showMedicationPhoto(entryId: UUID) -> String?

    /// [PROFILE-INTERVIEW T-094] The profile-personalization read seam the
    /// interpreter contexts compose from (design-l2 §5.5): nil = "not
    /// wired" (tests, pre-onboarding, or wiring disabled), and the prompt's
    /// address-as clause composes to the byte-identical baseline. The
    /// router READS the seam each turn and passes only the guarded prompt
    /// term (`addressAsForPrompt`) into `InterpreterContext.addressAs` —
    /// the verbatim spoken term never crosses this boundary (ADR-09).
    /// Requirement-with-extension-default pattern like the tool surfaces
    /// above: `CommandRouter` holds its coordinator as
    /// `VoiceCommandCoordinating?`, so an extension-only member would bind
    /// statically and `AppCoordinator`'s stored property could never be
    /// reached (the exact failure mode the [INTENT-TOOLS] doc warns
    /// about).
    var profilePersonalization: ProfilePersonalizationReading? { get }
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
    // [CALENDAR-EVENTS] (2026-09-13) Inert default — a conformer that
    // does not opt in never has a calendar event pending, so the router's
    // confirmation path behaves exactly as it did before this member.
    var isAwaitingCalendarEventConfirmation: Bool { false }
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
    // [HOME-TIMER-CHIP] (2026-09-11) Inert default — a conformer that
    // does not opt in (mocks/doubles) reports .noActiveTimer, and the
    // router stage speaks the honest "no timers running" line. Only a
    // coordinator that explicitly implements the member
    // (AppCoordinator, and the scripted mock under test) cancels
    // anything.
    func requestTimerCancel() -> TimerCancelOutcome { .noActiveTimer }
    // [ALARMKIT-ALARMS] (2026-09-10) Inert default — a conformer that
    // does not opt in (every mock/double) keeps the historical
    // notification-permission denial line. `AppCoordinator` overrides it
    // with the backend-aware key.
    var alarmPermissionDeniedKey: String { "alarms.permissionDenied" }
    // [CALENDAR-EVENTS] (2026-09-13) Inert default — a conformer that
    // does not opt in (every mock/double) cannot write a calendar event,
    // so the router speaks the honest "calendar unavailable" line
    // instead of a confirmation prompt. Only a coordinator that
    // explicitly implements the member (AppCoordinator, and the
    // scripted mock under test) creates anything.
    func requestCalendarEventConfirmation(title: String, startDate: Date) -> String? { nil }
    // [APP-LAUNCHER] (2026-09-16) Inert defaults — a conformer that does
    // not opt in (every mock/double) never pends an app launch, so the
    // router's confirmation path behaves exactly as it did before this
    // member, and the plugin's seam answers the honest "not available"
    // line instead of pretending a launch was pended. Only a coordinator
    // that explicitly implements the members (AppCoordinator, and the
    // scripted mock under test) launches anything.
    var isAwaitingAppLaunchConfirmation: Bool { false }
    func requestAppLaunch(appID: String, confidence: Double?) -> String {
        L10n.str("router.pluginUnavailable", locale: activeLocale)
    }
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
    // [FEEDS-FULL-ARTICLE] (2026-09-19) Inert default — a conformer that
    // does not opt in (every mock/double across app and test target)
    // reads nothing, exactly like `fireNewsReader()` above. The stage
    // still consumes the utterance (the phrasing is unambiguous), so a
    // non-opted-in coordinator answers with silence rather than letting
    // the request fall into the interpreter as small talk.
    func readFullFeedArticle() {}
    // [MED-PHOTO] (2026-09-17) Inert defaults — a conformer that does not
    // opt in has no medications to ask about (`[]` leaves the rule's
    // group empty, so the rule can never fire) and presents nothing. Only
    // a coordinator that explicitly implements the members
    // (AppCoordinator, and the scripted mock under test) shows a photo.
    var medicationVoiceEntries: [MedicationEntry] { [] }
    func showMedicationPhoto(entryId: UUID) -> String? { nil }
    // [PROFILE-INTERVIEW T-094] Inert default — a conformer that does not
    // opt in (every mock/double) has no personalization seam, so the
    // prompt composes exactly as it did before the feature and every
    // pre-feature expectation (pinned digests, byte-identity tests) holds.
    var profilePersonalization: ProfilePersonalizationReading? { nil }
    // [MULTI-TURN] (2026-10-10, C-MTC-05 §12.1) Inert dialogue defaults —
    // a conformer that does not opt in (every mock/double) has no frame,
    // no window and no accounting: the interception block never fires
    // (nil frame), a degenerate trigger's arm cannot succeed and falls
    // back to the pre-feature request, and every pre-feature expectation
    // holds. Only a coordinator that explicitly implements the members
    // (T-136's AppCoordinator, and a scripted mock under test) opens
    // frames. `prepareDialogueAnswerText`'s default is the same
    // `.quarantine` sanitise the router's nil-coordinator fallback uses,
    // so an un-opted-in conformer still never hands the classifier raw,
    // unclamped text.
    var activeDialogueFrame: DialogueFrame? { nil }
    func startDialogueFrame(_ frame: DialogueFrame) -> Bool { false }
    @discardableResult func noteDialogueAttempt() -> Int { 0 }
    func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {}
    func clearDialogueFrame(reason: DialogueFrameResolution) {}
    func prepareDialogueAnswerText(_ raw: String) -> String {
        InputSanitiser.sanitise(raw, level: .quarantine)
    }
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
        /// [CALENDAR-EVENTS] (2026-09-13) A `create_calendar_event`
        /// confirmation was answered YES — the coordinator has taken the
        /// pended event and is writing it. Reports the calendar outcome
        /// (not a medication acknowledgement), which is why it is its own
        /// case rather than riding `.acknowledgedMedication`.
        case calendarEventConfirmed
        /// [APP-LAUNCHER] (2026-09-16) A `launcher.open` confirmation was
        /// answered YES — the coordinator has taken the pended app and
        /// launched it (or, for the camera entry, switched to the in-app
        /// capture). Its own case for the same reason
        /// `.calendarEventConfirmed` has one: the outcome is a launch, not
        /// a medication acknowledgement, and reporting
        /// `.acknowledgedMedication` would make the router's result a lie.
        case appLaunchConfirmed
        case unrecognised(transcript: String)
    }

    private weak var coordinator: VoiceCommandCoordinating?
    private let observabilityBus: ObservabilityBus
    private let speaker: Speaker?
    /// [VOICE-ACK] Serial FIFO lane for interactive reply speech — built
    /// lazily on the first speak so tests and call sites that never speak
    /// pay nothing. See `ReplySpeakLane` for the ordering contract.
    private var speakLane: ReplySpeakLane?
    private let interpreter: CommandInterpreter
    /// [TURN-TIMING] Turn-scoped stage tracer (nil = timing off — tests
    /// and any construction site that does not opt in).
    private let turnTracer: VoiceTurnLatencyTracer?
    /// [LAT-M2] The ack fast lane: plays the pre-synthesized ack WAV
    /// directly instead of routing the ack through TTS synthesis. Nil
    /// (the default) = dormant — `speakPreAck` behaves byte-identically
    /// to the pre-fast-lane path (synthesis through the lane, no extra
    /// events), so every pre-existing construction site and test keeps
    /// its behavior.
    private let preAckPlayer: PreAckPlaying?

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

    // [SPOTIFY] (2026-10-07) Music-path seams (T-116, C-SP-06 §13/§28) —
    // every one defaults to dormant (nil), exactly like the YouTube
    // seams above, so pre-existing router construction sites and every
    // existing router test keep compiling and behaving as before
    // (NFR-SP-012): without a session the turn reads as not linked (the
    // honest unlinked treatment), without a transport no Spotify request
    // can be built, and without an opener nothing is ever opened. Only
    // `AppCoordinator` (T-119) and scripted test routers arm the seams.
    private let spotifyAccountSession: SpotifyAccountSession?
    private let spotifyTransport: LocalToolTransport?
    private let spotifyLinkOpener: CallLinkOpening?

    /// [TOOL-DEBUG-LOG] (2026-09-07) Encrypted on-device debug log of
    /// every local-tool (weather/search) request + outcome — the store
    /// behind Settings → Tool requests. Nil = dormant (pre-existing
    /// construction sites and legacy tests behave exactly as before);
    /// `AppCoordinator` injects its store. See `logToolRequest`.
    private let localToolLogStore: LocalToolLogStore?

    /// [CHAT] Stage 1 of the conversational-augmentation plan
    /// (2026-09-23): the CHAT shape's confidence floor — applied here,
    /// where every other "this model answer is not good enough to speak"
    /// decision already lives (`ReplySanityGate`, `router.modelReplyUnclear`).
    ///
    /// The value comes from the brain's own config
    /// (`LlamaCommandInterpreter.Config.chatConfidenceFloor`) so the two
    /// cannot drift: the interpreter stops applying the command threshold
    /// to chat turns and THIS layer decides what a sub-floor chat decode
    /// means. Below the floor the model's text is not spoken at all — the
    /// honest line is (`router.chatLowConfidence`), and the turn is
    /// observable as `chatLowConfidence`. At or above it the reply is
    /// spoken through the same sanity gate a `query` answer passes.
    private let chatConfidenceFloor: Double

    init(coordinator: VoiceCommandCoordinating,
         observabilityBus: ObservabilityBus,
         speaker: Speaker? = nil,
         interpreter: CommandInterpreter = NullCommandInterpreter(),
         // [CHAT] The chat shape's floor — defaults to the brain's own
         // (`LlamaCommandInterpreter.Config.default.chatConfidenceFloor`,
         // currently 0.6) so an unconfigured router and the brain it
         // drives agree; a test can inject any value.
         chatConfidenceFloor: Double = LlamaCommandInterpreter.Config.default.chatConfidenceFloor,
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
         spotifyAccountSession: SpotifyAccountSession? = nil,
         spotifyTransport: LocalToolTransport? = nil,
         spotifyLinkOpener: CallLinkOpening? = nil,
         preAckPlayer: PreAckPlaying? = nil,
         turnTracer: VoiceTurnLatencyTracer? = nil) {
        self.coordinator = coordinator
        self.observabilityBus = observabilityBus
        self.speaker = speaker
        self.interpreter = interpreter
        self.chatConfidenceFloor = chatConfidenceFloor
        self.turnTracer = turnTracer
        self.preAckPlayer = preAckPlayer
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
        self.spotifyAccountSession = spotifyAccountSession
        self.spotifyTransport = spotifyTransport
        self.spotifyLinkOpener = spotifyLinkOpener
        // [LAT-M2] A fast-lane ack's playback settled (finished, decode
        // error, or cancelled) — the same per-utterance speak
        // bookkeeping the lane's tail fires for synthesized utterances.
        preAckPlayer?.onPlaybackFinished = { [weak self] in
            self?.turnTracer?.noteSpeakFinished()
            self?.coordinator?.noteSpeakingEnded()
        }
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
            // [MULTI-TURN] (2026-10-10, C-MTC-05 §12.3) Emergency outranks
            // any live dialogue frame: drop it (the coordinator emits the
            // `.emergency` resolution event itself — §26's component
            // split). POST-dispatch and side-effect only: it contributes
            // no condition, delay or gate to the emergency path (L1
            // ADR-MTC-02; a test pins dispatch with the clear forced to a
            // no-op).
            coordinator?.clearDialogueFrame(reason: .emergency)
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
                        dispatchInterpreted(taken.command, raw: raw)
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
            // [CALENDAR-EVENTS] (2026-09-13) Calendar-event confirmations
            // speak their own outcome too (the coordinator speaks the
            // written event or stays silent on a no) — the generic
            // catalog yes/no is medication-flavored and would claim a
            // dose was recorded.
            let isCalendarEventConfirmation =
                coordinator?.isAwaitingCalendarEventConfirmation == true
            // [APP-LAUNCHER] (2026-09-16) An app-launch confirmation speaks
            // its own "Opening X" / honest cancellation too — the generic
            // catalog yes/no is medication-flavored and would claim a dose
            // was recorded for a plain "हो" answered to "क्यामेरा खोल्ने हो?".
            let isAppLaunchConfirmation =
                coordinator?.isAwaitingAppLaunchConfirmation == true
            let speaksItsOwnYesNo = isCallConfirmation || isNavigationDisambiguation
                || isCalendarEventConfirmation || isAppLaunchConfirmation
            // [APP-LAUNCHER F3] A dose acknowledgement is never a yes/no
            // answer to an app-launch question. The safety net that owns
            // this vocabulary runs BELOW this block, so without this the
            // launch window turned "औषधि खाएँ" into an ambiguous answer to
            // "क्यामेरा खोल्ने हो?" — and the dose went unrecorded, while
            // the comment on the safety net still promised it "runs first,
            // always". Only the launch branch is scoped this way: the
            // call/navigation/calendar prompts have no such collision, and
            // "होइन" must keep cancelling the launch question (a denial is
            // not an acknowledgement — `isExplicitMedicationAcknowledgement`
            // excludes it).
            if isAppLaunchConfirmation, Self.isExplicitMedicationAcknowledgement(raw) {
                emit(eventType: "confirmation_medication_ack", outcome: "success")
                handleMedicationAcknowledgement()
                return .acknowledgedMedication
            }
            if Self.isYesResponse(raw) {
                coordinator?.handleConfirmationResponse(.yes)
                emit(eventType: "confirmation_yes", outcome: "success")
                if !speaksItsOwnYesNo {
                    speak(key: "router.confirmationYes")
                }
                if isCallConfirmation { return .callConfirmed }
                if isCalendarEventConfirmation { return .calendarEventConfirmed }
                if isAppLaunchConfirmation { return .appLaunchConfirmed }
                return isNavigationDisambiguation ? .navigationRequested : .acknowledgedMedication
            }
            if Self.isNoResponse(raw) {
                coordinator?.handleConfirmationResponse(.no)
                emit(eventType: "confirmation_no", outcome: "success")
                if !speaksItsOwnYesNo {
                    speak(key: "router.confirmationNo")
                }
                return .unrecognised(transcript: raw)
            }
            // Ambiguous response — re-prompt.
            emit(eventType: "confirmation_ambiguous", outcome: "info")
            speak(key: "router.confirmationAmbiguous")
            return .unrecognised(transcript: raw)
        }

        // [MULTI-TURN] (2026-10-10, C-MTC-05 §12.2) Dialogue-frame
        // interception. Runs after the confirmation hook (whose body is
        // untouched — a pending confirmation outranks a live frame) and
        // before the safety net; consumes an answer, re-probes, or falls
        // through to the ladder unchanged. Every state mutation goes
        // through the coordinator hooks; this block never speaks a
        // model-generated line and never writes to the console (V-2).
        //
        // Classification is the pure `DialogueAnswerPath.classify`; the
        // live medication vocabulary is computed here exactly as the
        // keyword stage computes it (one source, no drift) so B6's
        // medication-photo reading is live at this call site (W2 review
        // F-1 — the §12.2 snippet's erratum). Consumed arms (escape,
        // cancel, answer, candidate, exhaustion) return BEFORE the
        // interpreter and the transcript cache (FR-MTC-017); `.bargeIn`
        // resolves and deliberately falls through so the ladder executes
        // the strong command exactly once with its normal tiers
        // (L2-D18); `.expired` falls through as a fresh command.
        if let frame = coordinator?.activeDialogueFrame {
            let prepared = coordinator?.prepareDialogueAnswerText(raw)
                ?? InputSanitiser.sanitise(raw, level: .quarantine)
            let medicationNames = (coordinator?.medicationVoiceEntries ?? []).flatMap {
                MedicationVoiceVocabulary.voiceKeys(for: $0)
            }
            let classification = DialogueAnswerPath.classify(
                raw: raw,
                prepared: prepared,
                frame: frame,
                catalog: dialogueCatalog,
                locale: coordinator?.activeLocale ?? Locale(identifier: "ne-NP"),
                now: Date(),
                medicationNames: medicationNames
            )
            switch classification {
            case .expired:
                // The window closed before this utterance — it is a
                // fresh command; the ladder below handles it unaltered.
                break
            case .escape:
                coordinator?.resolveDialogueFrame(.escaped)
                emitDialogueFrameResolved(.escaped)
                speak(key: "dialogue.escape")
                return .unrecognised(transcript: raw)
            case .cancel:
                coordinator?.resolveDialogueFrame(.cancelled)
                emitDialogueFrameResolved(.cancelled)
                speak(key: "dialogue.cancelled")
                return .unrecognised(transcript: raw)
            case .bargeIn:
                // Resolve and fall through: the ladder below executes
                // the strong command exactly once with its normal tiers
                // (L1 ADR-MTC-05; the `.bargedIn` resolution has already
                // cleared the frame and closed the window).
                coordinator?.resolveDialogueFrame(.bargedIn)
                emitDialogueFrameResolved(.bargedIn)
            case .candidatePick(let index, let capture):
                // The spoken position is 1-based; the executor addresses
                // 0-based (design §12.2).
                return executeDialogueCandidate(index - 1, capture: capture,
                                                queryOverride: nil,
                                                frame: frame, raw: raw)
            case .answer(let merge):
                return executeDialogueAnswer(merge, frame: frame, raw: raw)
            case .freeFormForCandidate(let index, let value):
                // Already 0-based (design §12.2) — consumed directly.
                return executeDialogueCandidate(index, capture: .freeText,
                                                queryOverride: value,
                                                frame: frame, raw: raw)
            case .invalid(let reason):
                let attempts = coordinator?.noteDialogueAttempt()
                    ?? DialogueConfig.maxProbes
                // C-3 (review-l2 F-3): the `reason` metadata is built by
                // direct `ObservabilityEvent` construction — the
                // two-argument `emit` helper hardcodes empty metadata and
                // would silently drop the reason vocabulary.
                observabilityBus.emit(ObservabilityEvent(
                    component: "command_router",
                    eventType: "dialogue_answer",
                    durationMs: nil,
                    outcome: "invalid",
                    errorCode: nil,
                    metadata: ["reason": reason.rawValue]
                ))
                // Attempt budget (FR-MTC-007/§24): one re-probe after the
                // first invalid answer, then the honest close. The
                // manager's count has already taken this attempt
                // (`noteAttempt` restamps the deadline, L2-D6); a count
                // within the budget speaks the retry probe — the frame
                // copy carries the fresh ordinal so the probe event's
                // `attempt` metadata is the probe's own number.
                //
                // §12.2's pinned comparison (`attempts < maxProbes`) is
                // an erratum: `noteAttempt` returns the post-increment
                // count (>= 2 on the first invalid answer), so `<` makes
                // the retry branch unreachable and contradicts the
                // task-file Gherkin ("attempt one … re-probes with the
                // retry variant") and §24's "one honest re-probe, then
                // the honest exhausted line".
                if attempts <= DialogueConfig.maxProbes {
                    var reprobe = frame
                    reprobe.attempts = attempts
                    speakDialogueProbe(frame: reprobe, retry: true)
                } else {
                    return resolveDialogueExhaustion(frame: frame, raw: raw)
                }
                return .unrecognised(transcript: raw)
            }
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
            // [VOICE-ACK] Navigation starts the map-surface chain (a beat
            // before the coordinator's execution speech) — ack first.
            speakPreAck()
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
        // cancellations ("cancel the timer") and third-person wake
        // requests ("wake my grandson", "छोरालाई उठाउनुहोस्"); countdown
        // phrasings ("alarm in 5 minutes", "पांच मिनुटको अलार्म लगाऊ")
        // are TIMERs and the timer parse claims them FIRST below
        // (2026-09-10 doctrine extension). Anything vetoed or
        // unparseable falls through this stage unchanged.
        //
        // The stage only PARSES and hands off: the coordinator owns the
        // permission round-trip (point-of-use requestAuthorization), the
        // persistence and the arming, and RETURNS the outcome so this
        // stage speaks the honest line — the confirmation only once the
        // item is stored + armed, the denial fallback when notifications
        // are off.
        // [NUMBER-WORDS] the active locale selects the number-word
        // lexicon the parsers normalize with (coordinator, as everywhere
        // else in this file; the persisted app language as the fallback).
        let stageLocale = coordinator?.activeLocale ?? AppLanguage.persisted().locale
        if let timer = AlarmTimerCommandParser.parseTimer(raw, locale: stageLocale) {
            handleTimerStartCommand(durationSeconds: timer.durationSeconds,
                                    label: timer.label)
            return .unrecognised(transcript: raw)
        }
        if let alarm = AlarmTimerCommandParser.parseAlarm(raw, locale: stageLocale) {
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
        if AlarmTimerCommandParser.parseAlarmOff(raw, locale: stageLocale) {
            handleAlarmOffCommand()
            return .unrecognised(transcript: raw)
        }
        if let snoozeMinutes = AlarmTimerCommandParser.parseAlarmSnooze(raw, locale: stageLocale) {
            handleAlarmSnoozeCommand(minutes: snoozeMinutes)
            return .unrecognised(transcript: raw)
        }
        // [HOME-TIMER-CHIP] (2026-09-11) Timer CANCEL branch — checked
        // after the set + off + snooze parses (a set command wins first)
        // and before the briefing stage + topic table. Only the
        // sanctioned shapes parse (see
        // `AlarmTimerCommandParser.parseTimerCancel`); duration- or
        // clock-qualified cancellations ("cancel the 5 minute timer")
        // fall through unchanged — the cancel branch must not guess
        // which timer. The stage only PARSES and hands off; the
        // coordinator cancels the NEAREST active timer and returns the
        // honest outcome this stage speaks. SYNCHRONOUS — no permission
        // round-trip, so the reply is committed inside `route()` itself.
        if AlarmTimerCommandParser.parseTimerCancel(raw, locale: stageLocale) {
            handleTimerCancelCommand()
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
            // [VOICE-ACK] The digest is composed then spoken line by line
            // — ack before the composition work.
            speakPreAck()
            coordinator?.fireMorningBriefing()
            emit(eventType: "morning_briefing_command", outcome: "success")
            return .unrecognised(transcript: raw)
        }

        // [FEEDS-FULL-ARTICLE] (2026-09-19) Deterministic voice stage for
        // the feeds feature's full-article reading: "read the full
        // article", "पूरा समाचार पढ", "पूरा लेख पढ्नुहोस्" — the elder
        // heard a summary (or saw a card) and wants the whole story.
        //
        // Placement is LOAD-BEARING: this stage must run BEFORE the news
        // digest stage, because the Nepali phrasing of a full-article
        // request CONTAINS a news phrase ("समाचार पढ" ⊂ "पूरा समाचार
        // पढ"). Without this stage first, the digest stage would swallow
        // the utterance and the elder would hear headlines instead of the
        // article. After the briefing stage (a briefing request can never
        // be read as a full-article request) and before every model —
        // no interpreter involvement, no IntentPrompt tokens.
        //
        // Vetoes, the same discipline as the news list: full-phrase
        // containment only (the bare word "article" never matches), so an
        // utterance that merely mentions an article cannot hijack the
        // stage. The stage DECIDES and hands off — the coordinator owns
        // every spoken line (the article, the honest "only a summary"
        // line, the honest "nothing in your feed" line), so this ends the
        // turn with the same `.unrecognised(transcript:)` the neighbouring
        // stages return once they have already spoken.
        if Self.fullArticlePhrases.contains(where: { Self.containsPhrase($0, in: preText) }) {
            // [VOICE-ACK] The reading is composed then spoken — ack first.
            speakPreAck()
            coordinator?.readFullFeedArticle()
            emit(eventType: "feed_full_article_command", outcome: "success")
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
            // [VOICE-ACK] The digest fetches + composes before speech —
            // ack first, the reader owns every line after.
            speakPreAck()
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

        // [INTENT-KEYWORDS] (2026-09-11) Relaxed keyword co-occurrence
        // stage: the strict stages above validated FORM (full phrases,
        // enumerated verb families, marker adjacency). When they all
        // declined, resolve intent from keyword CO-OCCURRENCE instead —
        // the small `KeywordIntentRule` table of SAFE domains only
        // (news digest, YouTube play, a named app launch): every
        // required keyword group must co-occur anywhere in the
        // utterance, no grammar validation.
        //
        // Placement: AFTER every strict deterministic stage (safety net
        // + confirmation flow + contact search + directions +
        // alarms/timers + briefing + strict news + strict YouTube) and
        // BEFORE the topic table + interpreter — an emergency / med-ack
        // / yes-no / alarm-timer utterance can never reach this stage,
        // and a keyword-resolved request is never answered as small
        // talk. Rule order inside the table mirrors the strict ladder
        // (news before YouTube), so a both-sets utterance resolves as
        // the strict ordering would.
        //
        // The table only widens the GATE — execution stays the strict
        // stage's: news hands off to the reader exactly like the strict
        // stage (ack first, the reader owns every line), YouTube still
        // requires a survivable non-marker query from `YouTubeRoute`'s
        // extraction and fires the same honest play/search path, and an
        // app launch hands its catalog id to the SAME coordinator seam
        // the `launcher.open` plugin calls (the coordinator owns the
        // confirmation question and the launch). Every relaxed claim is
        // observable: `intent_keyword_match` (domain, matched keys —
        // fixed rule vocabulary, never user text).
        // [MED-PHOTO] (2026-09-17) The medication vocabulary the table's
        // last rule matches against — read from the coordinator's live
        // schedule (never a fixed table), and read ONCE here so the rule's
        // group and this stage's resolution below work from the same
        // snapshot.
        let medicationVoiceEntries = coordinator?.medicationVoiceEntries ?? []
        let medicationNames = medicationVoiceEntries.flatMap {
            MedicationVoiceVocabulary.voiceKeys(for: $0)
        }
        if let relaxed = KeywordIntentRule.match(transcript: preText,
                                                 medicationNames: medicationNames) {
            switch relaxed.domain {
            case .news:
                emitIntentKeywordMatch(relaxed)
                // [VOICE-ACK] Same hand-off as the strict news stage —
                // ack first, the reader owns every line after.
                speakPreAck()
                coordinator?.fireNewsReader()
                emit(eventType: "news_reader_command", outcome: "success")
                return .unrecognised(transcript: raw)
            case .youtube:
                guard let query = YouTubeRoute.extractQuery(from: preText) else { break }
                emitIntentKeywordMatch(relaxed)
                fireYouTubePlay(query: query)
                return .unrecognised(transcript: raw)
            case .music:
                // [SPOTIFY] (2026-10-07) T-116: the real music path — the
                // ladder's deterministic intake (FR-SP-015). The extractor
                // resolves the search query from the same
                // pre-canonicalized text the rule matched (zero prompt
                // tokens, no interpreter round-trip); a transcript the
                // extractor canonicalizes empty falls back to the whole
                // utterance so the turn always has a query. Terminal for
                // the turn, exactly like the YouTube arm above.
                emitIntentKeywordMatch(relaxed)
                fireMusicRequest(query: KeywordIntentRule.musicQuery(from: preText) ?? preText)
                return .unrecognised(transcript: raw)
            case .appLaunch:
                // [APP-LAUNCHER] (2026-09-16) The launcher's voice fast
                // path ("क्यामेरा खोल", "open WhatsApp", "फोटो खिच्न") —
                // the highest-frequency launches without the encoder
                // round-trip. The rule already resolved the utterance to
                // a CATALOG id, which is the `app` entity the
                // `launcher.open` plugin hands to `requestAppLaunch`:
                // this stage calls that same seam, so the one launch
                // executor, the pending state, the 45 s window and the
                // confirmation question (design D3) are byte-for-byte the
                // plugin path's — and a deterministic stage stays free of
                // the plugin-dispatch machinery (registry + cloud client
                // + an async hop) it would otherwise need.
                //
                // The returned line is the coordinator's: the
                // confirmation question when the launch can still
                // succeed, or the honest not-installed line when it
                // cannot (nothing is pended in that case). The keyword
                // path never inspects or recomposes it — exactly like
                // the news/YouTube hand-offs above, where the
                // coordinator/DOMAIN owners keep every spoken line.
                guard let appID = relaxed.appID else { break }
                emitIntentKeywordMatch(relaxed)
                if let line = coordinator?.requestAppLaunch(appID: appID, confidence: nil) {
                    // Carded like the plugin path's reply (see
                    // `handlePluginCommand` above), so the question the
                    // elder answers stays visible whichever path
                    // resolved it.
                    coordinator?.noteGenericReply(line)
                    speak(text: line)
                }
                return .unrecognised(transcript: raw)
            case .festivalDate:
                // [FESTIVAL-DATE] (2026-09-17) Deterministic festival
                // date answers ("दशैँ कहिले हो") — resolved from the
                // festival catalog for the CURRENT Bikram Sambat year,
                // so the answer never depends on encoder availability,
                // band policy or model calibration. An unresolvable date
                // (no panchang table, no astronomy fallback) says so
                // honestly rather than guessing a day.
                guard let festivalID = relaxed.festivalID,
                      let festival = NepaliFestivalCatalog.all.first(where: { $0.id == festivalID }),
                      let bsYear = BikramSambat.bsDate(from: clock())?.year,
                      let resolved = festival.resolvedDate(inBSYear: bsYear),
                      let gregorian = BikramSambat.adDate(from: resolved.bsDate) else {
                    emit(eventType: "festival_date_unknown", outcome: "info")
                    speak(key: "festival.dateUnknown")
                    return .unrecognised(transcript: raw)
                }
                emitIntentKeywordMatch(relaxed)
                let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
                let spokenName = locale.identifier.hasPrefix("ne")
                    ? festival.nameNepali : festival.nameEnglish
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateStyle = .long
                formatter.timeStyle = .none
                emit(eventType: "festival_date_answered", outcome: "success")
                speak(text: L10n.fmt("festival.fallsOn", locale: locale,
                                     spokenName, formatter.string(from: gregorian)))
                return .unrecognised(transcript: raw)
            case .medicationPhoto:
                // [MED-PHOTO] (2026-09-17) "रक्तचापको औषधि कस्तो छ?" — the
                // elder asks what one of their OWN medicines looks like.
                // The rule resolved the utterance to a vocabulary key out
                // of the live schedule; this stage turns that key back into
                // the entry (or entries) carrying it and hands the one to
                // show to the coordinator's seam. No model, no band, no
                // calibration — a photo question the household can answer
                // with a photo is answered with the photo.
                //
                // Every spoken line stays the coordinator's or the
                // catalog's: the names line for the multi-match case is
                // the one exception, composed here from the entries the
                // vocabulary already resolved (the same shape the festival
                // stage's line has), and carded like the launch seam's
                // replies so it survives the full-screen cover.
                guard let key = relaxed.medicationName,
                      let coordinator else { break }
                emitIntentKeywordMatch(relaxed)
                let matches = medicationVoiceEntries.filter {
                    MedicationVoiceVocabulary.voiceKeys(for: $0).contains(key)
                }
                guard let firstMatch = matches.first else {
                    // The key resolved against this same read and names
                    // nothing any more (an entry deleted in the pause
                    // between): the honest "no photo yet" line, carded —
                    // never a silent dead end.
                    speakWithVisibleOutcome(key: "meds.photoMissing")
                    return .unrecognised(transcript: raw)
                }
                if matches.count > 1 {
                    // Several medicines answer to the same word: name them
                    // first, then show the first one that actually has a
                    // photo. Never a guess at which one was meant.
                    let names = matches.map(\.medicationName).joined(separator: ", ")
                    let line = L10n.fmt("meds.photoMultiple",
                                        locale: coordinator.activeLocale, names)
                    coordinator.noteGenericReply(line)
                    speak(text: line)
                }
                let target = matches.first { !$0.visualAids.isEmpty } ?? firstMatch
                if let line = coordinator.showMedicationPhoto(entryId: target.id) {
                    // Carded exactly like the launch seam's line: the
                    // honest no-photo line has no other surface once the
                    // turn ends.
                    coordinator.noteGenericReply(line)
                    speak(text: line)
                }
                return .unrecognised(transcript: raw)
            }
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
            // [PROFILE-INTERVIEW T-094] Compose the guarded address-as term
            // through the coordinator's read seam (design-l2 §5.5). The
            // seam is nil-safe end to end: no coordinator, no seam, or an
            // absent/unreadable profile all yield nil here and the prompt
            // stays byte-identical to the pre-feature baseline.
            let context = InterpreterContext(
                pendingMedications: [],
                userLanguageHint: coordinator?.activeLocale.languageCode ?? "en",
                addressAs: coordinator?.profilePersonalization?.addressAsForPrompt
            )
            // [REST-DIP-FIX] (2026-09-08) The interpreter round-trip is
            // ASYNC: this route returns before the reply exists, and the
            // pipeline would drop the session to rest in between (the
            // reported dip). Mark the turn pending so VoicePipeline holds
            // its return to idle until the completion below resolves the
            // token — AFTER the reply speech was committed.
            markTurnReplyPending()
            // [VOICE-ACK] The LLM round-trip is the longest wait — the
            // pre-ack tells the user the request was heard BEFORE the
            // model is consulted.
            speakPreAck()
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
                    //
                    // [CHAT-CONFIDENCE-FLOOR] …and a CHAT turn is never
                    // rephrased. There is no interpretation for the user
                    // to confirm — "did you mean…?" about small talk is
                    // nonsense — and the chat shape already has its own
                    // low-confidence outcome (the honest line below
                    // `chatConfidenceFloor`, the reply above it). Without
                    // this exclusion a chat reply in [floor, 0.7) would be
                    // swapped for a confirmation question, which is
                    // exactly what the floor exists to avoid.
                    if command.action != .chat,
                       command.confidence < 0.7,
                       ConfirmationTier.tier(for: command.action) == .free,
                       self.coordinator?.pendingRephraseCommand == nil {
                        self.coordinator?.startRephraseConfirmation(command, sourceTranscript: raw)
                        self.emit(eventType: "rephrase_question_started", outcome: "info")
                    } else {
                        self.pendingTranscript = raw
                        self.dispatchInterpreted(command, raw: raw)
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

    /// [INTENT-KEYWORDS] (2026-09-11) Observability for a fired relaxed
    /// rule — `intent_keyword_match` carries the claimed domain and the
    /// matched keyword keys (fixed vocabulary from the rule table,
    /// never user text) so every relaxed claim is auditable, exactly
    /// like the other router events.
    private func emitIntentKeywordMatch(_ match: KeywordIntentRule.Match) {
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: "intent_keyword_match",
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: [
                "domain": match.domain.rawValue,
                "matched_keys": match.matchedKeys.joined(separator: ",")
            ]
        ))
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
        // [VOICE-ACK] Arming takes a permission round-trip + persistence —
        // ack before the wait, the confirmation follows through the lane.
        speakPreAck()
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
                // [ALARMKIT-ALARMS] Backend-specific honest copy: the
                // AlarmKit permission line on iOS 26+, the notification
                // line before.
                self.speakWithVisibleOutcome(
                    key: self.coordinator?.alarmPermissionDeniedKey ?? "alarms.permissionDenied")
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
        // [VOICE-ACK] Same arming round-trip as alarm set — ack first.
        speakPreAck()
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

    /// [HOME-TIMER-CHIP] (2026-09-11) Voice timer CANCEL handler — same
    /// synchronous contract as the OFF handler: the coordinator cancels
    /// the NEAREST active timer and returns the outcome this handler
    /// speaks. `.cancelled` confirms ("Timer cancelled." / "टाइमर बन्द
    /// भयो।"), `.noActiveTimer` speaks the honest "no timers running"
    /// line, `.failed` the honest fallback. Observability is emitted at
    /// resolution (component "alarms_timers", event "timer_cancel"),
    /// never before.
    private func handleTimerCancelCommand() {
        guard coordinator != nil else {
            speakWithVisibleOutcome(key: "timers.cancelFailed")
            return
        }
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        switch coordinator?.requestTimerCancel() ?? .noActiveTimer {
        case .cancelled:
            emitAlarmTimers(eventType: "timer_cancel", outcome: "success")
            let text = L10n.str("timers.cancelled", locale: locale)
            coordinator?.noteGenericReply(text)
            speak(text: text, locale: locale)
        case .noActiveTimer:
            emitAlarmTimers(eventType: "timer_cancel", outcome: "no_active_timer")
            speakWithVisibleOutcome(key: "timers.none")
        case .failed:
            emitAlarmTimers(eventType: "timer_cancel", outcome: "failed")
            speakWithVisibleOutcome(key: "timers.cancelFailed")
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

    /// [FEEDS-FULL-ARTICLE] (2026-09-19) Full-phrase forms for the feeds
    /// feature's "read the FULL article" command. Both shipped languages
    /// plus the romanized Nepali STT output, exactly like the news and
    /// briefing tables. Every entry names the WHOLE story ("full",
    /// "whole", "entire", "पूरा") — a bare "read the article" is
    /// deliberately absent, because that is a request the summary read
    /// already satisfies and the stage must not claim more than the
    /// elder asked for.
    ///
    /// The Nepali entries OVERLAP the news table by construction
    /// ("समाचार पढ" is inside "पूरा समाचार पढ") — the stage order in
    /// `routeKeyword` is what resolves the overlap, and it is pinned by
    /// `FullArticleStageRoutingTests`.
    private static let fullArticlePhrases = [
        "read the full article", "read the full story",
        "read the whole article", "read the entire article",
        "read full article", "read me the full article",
        "पूरा समाचार पढ", "पूरा समाचार पढ्नुहोस्", "पूरा समाचार सुनाऊ",
        "पूरा खबर पढ", "पूरा खबर सुनाऊ", "पूरा लेख पढ",
        "पूरा लेख पढ्नुहोस्", "पूरा समाचार सुनाउनुहोस्",
        "pura samachar pad", "pura samachar sunau", "pura lekh pad"
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
    /// (`routeKeywordRemainder` `:1973-1980`) and the [NO-GIBBERISH]
    /// pre-answer guard (`:1360`): an utterance that both names a topic
    /// word AND reads call-ish ("मौसम बताउने मान्छेलाई फोन गर") must stay
    /// on the interpreter/block path — a deterministic topic answer
    /// would shadow the call intent. Hoisted from `routeKeywordRemainder`
    /// (2026-09-07) so the pre-answer stage checks the SAME list that
    /// blocks.
    ///
    /// [MTC L2-D2] (2026-10-10) `sensitiveCallPhrases` `:1869`: widened
    /// `private` → `internal` so the dialogue barge-in predicate
    /// (design-l2 §6 B2) consumes this exact list instead of forking a
    /// second vocabulary — the same extraction reason as
    /// `isExplicitMedicationAcknowledgement` `:1913`. The answer path
    /// evaluates it with `containsPhrase` semantics (`:1826` —
    /// `text.contains(phrase)`) over lowercased text and falls through
    /// to the ladder, where `:1973-1980` blocks with
    /// `router.sensitiveBlocked` unchanged. Visibility only: no call
    /// site moves and no predicate changes.
    static let sensitiveCallPhrases = [
        "call", "phone", "facetime", "messenger", "whatsapp",
        "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
    ]

    /// Explicit refusal vocabulary — "not yet", "I didn't take it", "औषधि
    /// खाएको छैन". Guarded BEFORE the ack list everywhere it is used, because
    /// refusal words contain ack words as substrings ("नखाए" ⊃ "खाए",
    /// "भएन" ⊃ "भयो").
    static let medicationDenialPhrases = [
        "i didn't", "i did not", "not yet", "haven't", "havent",
        "औषधि खाएको छैन", "औषधी खाएको छैन", "खाएको छैन",
        "नखाए", "नखाएको", "लिएको छैन", "भएन", "छैन"
    ]

    /// The POSITIVE half of the medication-ack vocabulary: "I took my
    /// medication" and its Nepali spellings, as phrases and as the single
    /// tokens that carry the meaning on their own.
    static let medicationAckPhrases = [
        "i took", "i've taken", "ive taken", "took my medication",
        "took my medicine", "taken my medication", "taken my medicine",
        "yes i took it",
        "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
        "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
        "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
        "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें"
    ]
    static let medicationAckTokens = ["done", "taken", "took", "ate",
                                      "खाएँ", "खाए", "भयो"]

    /// [APP-LAUNCHER F3] Is this transcript an EXPLICIT dose
    /// acknowledgement?
    ///
    /// Extracted from `routeSafetyNet` because the safety net is not the
    /// only path that has to recognise it. While a confirmation window is
    /// open the follow-up block above intercepts every utterance as a
    /// yes/no — including an app-launch question, which made "औषधि खाएँ"
    /// parse as an ambiguous answer to "क्यामेरा खोल्ने हो?" and the dose
    /// go unrecorded. A dose acknowledgement is never a yes/no answer to
    /// another question, so the follow-up path asks this first.
    ///
    /// Denials are excluded here too: the guard order lives with the
    /// vocabulary instead of at one call site, so no caller can wire the
    /// list up without it.
    static func isExplicitMedicationAcknowledgement(_ raw: String) -> Bool {
        let text = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if medicationDenialPhrases.contains(where: { containsPhrase($0, in: text) }) {
            return false
        }
        return medicationAckPhrases.contains(where: { containsPhrase($0, in: text) })
            || medicationAckTokens.contains(where: { containsToken($0, in: text) })
    }

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
        // ack list (see `medicationDenialPhrases`).
        if Self.medicationDenialPhrases.contains(where: { Self.containsPhrase($0, in: text) }) {
            emit(eventType: "command_ack_denied_keyword", outcome: "info")
            speak(key: "router.ackDenied")
            return .unrecognised(transcript: raw)
        }

        if Self.isExplicitMedicationAcknowledgement(raw) {
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
                // [GEMINI-SOLIDIFY] (2026-09-18) Chain honesty: when the
                // whole ladder bottomed out AND the cloud leg failed for
                // a real reason, the generic "I didn't understand"
                // re-prompt would be a lie about what happened — the user
                // hears the failure CLASS's honest line instead (never
                // silence, never a false apology). The report is
                // read-and-cleared here, so it can never leak into a
                // later turn.
                if let reporting = interpreter as? CloudFailureReporting,
                   let failureClass = reporting.lastCloudFailureClass {
                    reporting.clearCloudFailure()
                    speakWithVisibleOutcome(
                        text: failureClass.spokenLine(
                            locale: coordinator?.activeLocale
                                ?? Locale(identifier: "ne-NP")))
                } else {
                    speak(key: "router.reprompt")
                }
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
    /// [TOMORROW-WEATHER] (2026-09-13) The DAY the question asks about is
    /// resolved once, up front (`NepaliTimeParser.relativeDayOffset`) and
    /// threaded into whichever fetch runs: 1 (भोलि/tomorrow) or 2
    /// (पर्सि/the day after) reads that day's `daily` forecast and the
    /// reply names the day; 0 (आज/today or no day word) keeps the live
    /// `current` reading exactly as before. Pre-fix the day was dropped
    /// here and the tool had no way to express it, so a tomorrow question
    /// was answered with today's weather.
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
        // The asked day — the ONE resolution point (see the doc above).
        let dayOffset = NepaliTimeParser.relativeDayOffset(in: raw) ?? 0
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
                    let sentence = try await self.liveWeatherSentence(
                        latitude: place.latitude, longitude: place.longitude,
                        dayOffset: dayOffset, placeName: place.name, locale: locale,
                        transport: transport)
                    await MainActor.run {
                        self.deliverLiveWeather(sentence: sentence, locale: locale,
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
                let sentence = try await self.liveWeatherSentence(
                    latitude: fix.latitude, longitude: fix.longitude,
                    dayOffset: dayOffset, placeName: fix.placeName, locale: locale,
                    transport: transport)
                await MainActor.run {
                    self.deliverLiveWeather(sentence: sentence, locale: locale,
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

    /// [TOMORROW-WEATHER] (2026-09-13) Fetches the reading for the asked
    /// DAY at one point and renders the tool's bare sentence for it — the
    /// fetch every weather delivery shares (geocoded place and device
    /// location alike), so the day rule lives in exactly one place:
    ///
    ///   · `dayOffset` 0 (आज / no day word) → live CURRENT conditions,
    ///     the historical reading and reply shape, unchanged;
    ///   · `dayOffset` ≥ 1 (भोलि/पर्सि) → that day's `daily` forecast,
    ///     whose reply names the day it was read for.
    ///
    /// Throws on any failure of the underlying fetch — the caller takes
    /// the honest no-data line (never a fabricated reading).
    private func liveWeatherSentence(latitude: Double,
                                     longitude: Double,
                                     dayOffset: Int,
                                     placeName: String?,
                                     locale: Locale,
                                     transport: LocalToolTransport) async throws -> String {
        if dayOffset > 0 {
            let forecast = try await WeatherTool.fetchDailyForecast(
                latitude: latitude, longitude: longitude,
                dayOffset: dayOffset, transport: transport)
            return WeatherTool.reply(for: forecast, placeName: placeName, locale: locale)
        }
        let conditions = try await WeatherTool.fetchCurrent(
            latitude: latitude, longitude: longitude, transport: transport)
        return WeatherTool.reply(for: conditions, placeName: placeName, locale: locale)
    }

    /// [WEATHER-ROUTING] (2026-09-07) Live-weather delivery — the
    /// single point where a real open-meteo reading reaches the user:
    /// the localized sentence (`WeatherTool.reply`, built by
    /// `liveWeatherSentence`) is WRAPPED in the `weather.replySource`
    /// hedge ("According to the weather service, …") so a live reading is
    /// presented as forecast data, never as unmediated ground truth. The
    /// bare sentence stays the tool's own contract (WeatherToolTests pin
    /// it directly); the router applies the hedge here, once, for every
    /// delivery path (geocoded named place and device location, today's
    /// reading and a future day's forecast alike).
    private func deliverLiveWeather(sentence: String,
                                    locale: Locale,
                                    query: String,
                                    outcome: String,
                                    startedAt: Date) {
        emitLocalTool(eventType: "weather", outcome: "ok")
        let text = L10n.fmt("weather.replySource", locale: locale, sentence)
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

    /// [T-114][M-1] Log projection for the reusable YouTube helpers
    /// (`fireYouTubePlay` / `deliverYouTubeFailure`).
    ///
    /// Explicit-YouTube turns keep the shipped behavior — `.explicit` is
    /// the default, so every pre-existing call site is untouched and the
    /// query is logged verbatim (the FR-SP-005 baseline). Music turns
    /// that fall back to YouTube (the §13 fallback rows) pass
    /// `.queryFree`: there the music query is the sensitive value and
    /// must never reach the tool log (NFR-SP-002 / security finding
    /// M-1). The projection changes the LOGGED query only — routing,
    /// speech and network behavior are identical for both cases.
    enum YouTubeLogProjection {
        case explicit
        case queryFree

        /// The `query` value the tool log records for a helper call.
        func loggedQuery(_ query: String) -> String {
            switch self {
            case .explicit: return query
            case .queryFree: return ""
            }
        }
    }

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
    ///     outcome, an EMPTY response by design — see `logToolRequest`;
    ///     music-turn callers pass `.queryFree`, which blanks the logged
    ///     query — [T-114][M-1]).
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
    private func fireYouTubePlay(query: String,
                                 logProjection: YouTubeLogProjection = .explicit) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        // [VOICE-ACK] The lookup/deeplink open takes a beat — ack before
        // the attempt, the outcome line follows through the lane.
        speakPreAck(locale: locale)
        let attemptStartedAt = Date()

        // Keyless path — no network at all; the deeplink IS the
        // feature. Synchronous: the confirmation is committed before
        // this turn returns.
        guard let apiKey = youtubeConfigStore?.apiKey else {
            guard let opener = youtubeLinkOpener else {
                deliverYouTubeFailure(locale: locale, query: query,
                                      logProjection: logProjection,
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
            logToolRequest(kind: .youtube, query: logProjection.loggedQuery(query),
                           response: "", outcome: "ok",
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
                                               logProjection: logProjection,
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
                                                   logProjection: logProjection,
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
                    self.logToolRequest(kind: .youtube, query: logProjection.loggedQuery(query),
                                        response: "",
                                        outcome: "ok", statusCode: 200,
                                        durationMs: Self.elapsedMilliseconds(since: attemptStartedAt))
                }
            } catch YouTubeTool.FetchError.noResults {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               logProjection: logProjection,
                                               fallbackKey: "youtube.notFound",
                                               statusCode: 200, startedAt: attemptStartedAt)
                }
            } catch YouTubeTool.FetchError.invalidResponse(let statusCode) {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               logProjection: logProjection,
                                               fallbackKey: "youtube.unavailable",
                                               statusCode: statusCode, startedAt: attemptStartedAt)
                }
            } catch {
                await MainActor.run {
                    self.deliverYouTubeFailure(locale: locale, query: query,
                                               logProjection: logProjection,
                                               fallbackKey: "youtube.unavailable",
                                               statusCode: nil, startedAt: attemptStartedAt)
                }
            }
        }
    }

    /// Failure delivery for the YouTube stage — the honest localized
    /// fallback line (`youtube.notFound` / `youtube.unavailable`), a
    /// `youtube` component `fail` event, and one "fail" debug-log entry
    /// carrying the line the user actually heard (never a title; the
    /// logged query follows `logProjection` — blanked on music turns,
    /// [T-114][M-1]).
    private func deliverYouTubeFailure(locale: Locale, query: String,
                                       logProjection: YouTubeLogProjection = .explicit,
                                       fallbackKey: String,
                                       statusCode: Int?, startedAt: Date) {
        emitYouTube(eventType: "youtube", outcome: "fail")
        speakWithVisibleOutcome(key: fallbackKey)
        let line = L10n.str(fallbackKey, locale: locale)
        logToolRequest(kind: .youtube, query: logProjection.loggedQuery(query),
                       response: line, outcome: "fail",
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

    // MARK: - [SPOTIFY] Music path (T-116, C-SP-06 §13/§28)

    /// [SPOTIFY] (2026-10-07) What one music turn resolves to — the
    /// selection step's total output (§28). Pure data: the enum carries
    /// at most the validated track the search resolved — never a token,
    /// a status or provider text.
    enum MusicOutcome: Equatable {
        /// Premium-capable and a usable track: attempt remote playback.
        case spotifyRemote(SpotifyTool.TrackResult)
        /// Hand the validated track to the app through the deep link
        /// (free/unknown tier — L2-D14 — and never a remote attempt).
        case spotifyDeepLink(SpotifyTool.TrackResult)
        /// Unlinked account with no YouTube leg: hand the query to the
        /// app's own search (`spotify:search:`).
        case spotifySearchHandoff
        /// The YouTube fallback owns the turn (`fireYouTubePlay`
        /// verbatim, ADR-SP-06).
        case youtube
        /// An honest static line: `spotify.notFound` / `unavailable` /
        /// `notLinked` / `appMissing`.
        case honestLine(String)
    }

    /// §28's ordered conditions, total over every state the router can
    /// reach, and the one place the 12-row matrix's selection logic
    /// lives (pure — pinned data-driven by `CommandRouterMusicTests`).
    ///
    /// Order note: the design lists the unlinked condition last among
    /// the *qualified* conditions (remote-capable / deep-link-capable /
    /// search-failure are all stated for a linked account); as an
    /// evaluation order the unlinked test must come first, because an
    /// unlinked turn never runs a search and every later condition
    /// presumes the linked state. `linked+transport missing` and the
    /// defensive `search == nil` arm both take the row-7 shape exactly
    /// as §28 states.
    static func selectMusicOutcome(spotifyLinked: Bool,
                                   spotifyTransportPresent: Bool,
                                   search: Result<SpotifyTool.TrackResult, SpotifyTool.FetchError>?,
                                   product: SpotifyAccountSession.Product,
                                   deepLinkCapable: Bool,
                                   youtubeServeable: Bool,
                                   spotifySearchOpenerPresent: Bool) -> MusicOutcome {
        guard spotifyLinked else {
            if youtubeServeable { return .youtube }
            if spotifySearchOpenerPresent { return .spotifySearchHandoff }
            return .honestLine("spotify.notLinked")
        }
        guard spotifyTransportPresent else {
            // §28: "linked+transport missing → the row-7 branch".
            return youtubeServeable ? .youtube : .honestLine("spotify.unavailable")
        }
        guard let search else {
            // Reached only through the row-11 token path (a search never
            // ran): the same search-failure treatment.
            return youtubeServeable ? .youtube : .honestLine("spotify.unavailable")
        }
        switch search {
        case .success(let track):
            if product == .premium { return .spotifyRemote(track) }
            if deepLinkCapable { return .spotifyDeepLink(track) }
            // Usable track but not remote-capable and the app cannot
            // open it: row 4's "not capable" leg.
            return youtubeServeable ? .youtube : .honestLine("spotify.appMissing")
        case .failure(.noResults):
            return youtubeServeable ? .youtube : .honestLine("spotify.notFound")
        case .failure:
            return youtubeServeable ? .youtube : .honestLine("spotify.unavailable")
        }
    }

    /// §13's `youtubeAskable`, the selection's `youtubeServeable` — the
    /// YouTube leg's own outcome decides success (ADR-SP-06).
    private var musicYouTubeServeable: Bool {
        youtubeConfigStore?.apiKey != nil || youtubeLinkOpener != nil
    }

    /// L2-R1: the concurrent YouTube leg runs only when the YouTube path
    /// is KEYED (there is a fetch to join). The keyless path is askable
    /// but is never pre-opened — its "search" is its outcome.
    private var musicYouTubeKeyed: Bool {
        youtubeConfigStore?.apiKey != nil && youtubeTransport != nil
    }

    /// The music path's entry (routes from the ladder's `case .music:`
    /// and from the interpreted `.music` action). Sync main-thread entry
    /// exactly like `fireYouTubePlay`: locale resolution, the pre-ack,
    /// then the attempt on a Task; every delivery hop returns to the
    /// main actor before speaking, emitting or logging.
    private func fireMusicRequest(query: String) {
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        // [VOICE-ACK] The token/search/play round-trips take a beat —
        // ack before the attempt, the outcome line follows through the
        // lane (parity with `fireYouTubePlay`).
        speakPreAck(locale: locale)
        let attemptStartedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            await self.runMusicTurn(query: query, locale: locale, startedAt: attemptStartedAt)
        }
    }

    // MARK: - [MTC] Dialogue frame (multi-turn conversation, design-l2 §12)

    // [MULTI-TURN] (2026-10-10, C-MTC-05 §12.5) The dialogue frame's
    // router-side helpers: the degenerate trigger, probe speech, the
    // did-you-mean compositions and the execution arms. Every spoken line
    // is composed from `dialogue.*` keys (never the model); every event
    // is closed-vocabulary and content-free (NFR-MTC-004); no arm here
    // consults the interpreter or the transcript cache (FR-MTC-017),
    // except the `executeDialogueAnswer`/`executeDialogueDefault` merge
    // tail, which re-enters the pending command's OWN dispatch (a music
    // command — terminal, cache-free).

    /// The degenerate music query's intake — the
    /// `dialogue_degenerate_query` event's closed `intake` metadata
    /// (design-l2 §23/§26): which of the three trigger sites requested
    /// the probe. Never content.
    private enum DialogueDegenerateIntake: String {
        case ladder
        case interpreted
        case candidate
    }

    /// The one cached catalog load (design-l2 §12.6): loaded lazily on
    /// first use (main thread, inside a turn) and then immutable. A
    /// missing or malformed resource degrades to nil — the free-text-only
    /// probe path (E3), never a fabricated option.
    private lazy var dialogueCatalog: DialogueOptionCatalog? = {
        try? DialogueOptionCatalog.load()
    }()

    /// The slot-fill draft for one degenerate music query (§12.5): the
    /// candidates are the catalog group the query claims (none when
    /// nothing claims it — the free-text-only probe), the default is the
    /// extracted degenerate query itself (the any-option fallback), and
    /// `activeCommand` carries the pending interpreted command the answer
    /// merges into (L2-D13) — nil on the keyword/candidate intakes.
    private func dialogueSlotFillDraft(query: KeywordIntentRule.MusicQueryExtraction,
                                       raw: String,
                                       activeCommand: InterpretedCommand?) -> DialogueFrame {
        let catalog = dialogueCatalog
        let candidates: [DialogueCandidate]
        if let group = query.query.flatMap({ catalog?.groupForMusicQuery($0) }),
           let catalog {
            candidates = DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog)
        } else {
            candidates = []
        }
        return DialogueFrame.slotFill(candidates: candidates,
                                      defaultQuery: query.query,
                                      domain: .music,
                                      activeCommand: activeCommand,
                                      sourceTranscript: raw)
    }

    /// The one degenerate trigger helper (§12.5/§23), shared by both
    /// ladder intakes and by candidate execution: a NON-degenerate
    /// extraction fires the music request exactly as the pre-feature
    /// expression did (`query ?? raw` — `musicQuery` is the thin wrapper
    /// over the outcome extractor, so the ladder intake is byte-identical
    /// to the shipped line). A degenerate one emits
    /// `dialogue_degenerate_query {intake}`, arms the slot-fill frame
    /// through the coordinator and speaks the first probe.
    ///
    /// `activeCommand` carries the arrived interpreted command on the
    /// interpreted intake (nil elsewhere) — the §12.5 pinned signature
    /// gained this additive, defaulted parameter because the pinned
    /// three-argument shape had no way to deliver it (§12.5's prose
    /// requires it: "the interpreted intake passes the arrived `command`
    /// as `activeCommand`").
    ///
    /// Fallbacks, all non-probe (never a dead end): an arm that cannot
    /// open a window (defensive — a live frame is intercepted before any
    /// trigger can run; also the no-coordinator case) falls back to
    /// today's exact blind request.
    private func fireMusicRequestOrProbe(query: KeywordIntentRule.MusicQueryExtraction,
                                         raw: String,
                                         intake: DialogueDegenerateIntake,
                                         activeCommand: InterpretedCommand? = nil) {
        guard query.isDegenerate else {
            fireMusicRequest(query: query.query ?? raw)
            return
        }
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: "dialogue_degenerate_query",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["intake": intake.rawValue]
        ))
        let draft = dialogueSlotFillDraft(query: query, raw: raw,
                                          activeCommand: activeCommand)
        if coordinator?.startDialogueFrame(draft) == true {
            speakDialogueProbe(frame: draft, retry: false)
        } else {
            fireMusicRequest(query: query.query ?? raw)
        }
    }

    /// Speaks one probe (§12.5): composed by `DialogueProbeComposer` from
    /// `dialogue.*` keys and catalog labels only (FR-MTC-016 — the model
    /// is never consulted), announced as `dialogue_probe_spoken` with the
    /// closed metadata (probe kind, the probe's own ordinal, the offered
    /// option count), then spoken through the normal reply surface so the
    /// assistant-bubble/speech bookkeeping matches every other reply.
    /// `errorCode: "catalogUnavailable"` marks the degraded slot-fill
    /// probe (no catalog — the free-text-only composition, E3); a
    /// candidateChoice probe never reads the catalog and is never
    /// degraded. The `locale` parameter is additive/defaulted for
    /// `speakDialogueDidYouMean`'s pinned signature — call sites inside a
    /// turn pass nothing and read the coordinator's locale.
    private func speakDialogueProbe(frame: DialogueFrame, retry: Bool,
                                    locale: Locale? = nil) {
        let locale = locale ?? coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let degraded = frame.probeKind == .slotFill && dialogueCatalog == nil
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: "dialogue_probe_spoken",
            durationMs: nil,
            outcome: degraded ? "degraded" : "success",
            errorCode: degraded ? "catalogUnavailable" : nil,
            metadata: [
                "probe_kind": frame.probeKind.rawValue,
                "attempt": String(frame.attempts),
                "option_count": String(dialogueProbeOptionCount(for: frame))
            ]
        ))
        speak(text: DialogueProbeComposer.probeText(for: frame, catalog: dialogueCatalog,
                                                    retry: retry, locale: locale),
              locale: locale)
    }

    /// The probe event's `option_count` (§26: 0…4): the capped
    /// option/candidate count the probe actually offers. slotFill: the
    /// group's options, 0 when no group claims the pending query (the
    /// free-text-only probe offers no addressable options); the
    /// any-option label is deliberately not counted (it is not a catalog
    /// option, §11). candidateChoice: the capped candidate count.
    private func dialogueProbeOptionCount(for frame: DialogueFrame) -> Int {
        switch frame.probeKind {
        case .slotFill:
            guard let query = frame.defaultQuery,
                  let group = dialogueCatalog?.groupForMusicQuery(query) else { return 0 }
            return min(group.options.count, DialogueConfig.maxSlotOptions)
        case .candidateChoice:
            return min(frame.candidates.count, DialogueConfig.maxCandidates)
        }
    }

    /// Speaks the did-you-mean probe for a candidate list (§12.5; the
    /// rephrase-discard helper, §12.4 edit 5): composed through the same
    /// `DialogueProbeComposer` candidateChoice path (and emitting the same
    /// `dialogue_probe_spoken` event) as the frame's own first probe — the
    /// honest "I didn't understand." lead joined with the capped candidate
    /// labels, in the caller's locale. The caller owns arming the frame it
    /// built from the same candidates; this helper only speaks, so an
    /// unanswerable probe is structurally impossible (no frame, no
    /// call — the caller's zero-candidate branch keeps its shipped line).
    private func speakDialogueDidYouMean(_ candidates: [DialogueCandidate], locale: Locale) {
        let draft = DialogueFrame.candidateChoice(candidates: candidates,
                                                  sourceTranscript: "")
        speakDialogueProbe(frame: draft, retry: false, locale: locale)
    }

    /// The keyword-remainder reprompt upgrade (§12.5; §12.4 edit 6, T-134's
    /// call site): with at least one near-match candidate the honest
    /// `dialogue.retry`-prefixed candidateChoice probe is spoken and its
    /// frame armed; with zero candidates — or a window that cannot open
    /// (defensive; also the no-coordinator case) — the shipped
    /// `router.reprompt` line stands byte-identically (NFR-MTC-012).
    private func speakDialogueDidYouMeanOrReprompt(_ raw: String) {
        let candidates = DialogueCandidateBuilder.build(for: raw,
                                                        excludingDomain: nil,
                                                        rephraseHypothesis: nil)
        guard !candidates.isEmpty, let coordinator else {
            speak(key: "router.reprompt")
            return
        }
        let draft = DialogueFrame.candidateChoice(candidates: candidates,
                                                  sourceTranscript: raw)
        guard coordinator.startDialogueFrame(draft) else {
            speak(key: "router.reprompt")
            return
        }
        speakDialogueProbe(frame: draft, retry: true, locale: coordinator.activeLocale)
    }

    /// Executes a resolved music-slot answer (§12.5, FR-MTC-006):
    /// resolution first (the funnel clears the frame and closes the
    /// window), the two events, then the merge executes through the
    /// pending command's own dispatch. Terminal for the turn — a consumed
    /// answer never reaches the interpreter or the transcript cache
    /// (FR-MTC-017).
    private func executeDialogueAnswer(_ merge: DialogueMerge,
                                       frame: DialogueFrame,
                                       raw: String) -> RoutingResult {
        coordinator?.resolveDialogueFrame(.answered(merge))
        emitDialogueAnswer(capture: merge.capture, source: merge.source)
        emitDialogueFrameResolved(.answered(merge))
        dispatchDialogueMusicValue(merge.value, frame: frame, raw: raw)
        return .unrecognised(transcript: raw)
    }

    /// The shared execution tail of the two music-value paths
    /// (`executeDialogueAnswer`, `executeDialogueDefault`): a pending
    /// interpreted music command merges the value into its `message` and
    /// re-enters its own dispatch (every other field copied verbatim —
    /// T-131's `merging`; the `.music` arm is terminal and cache-free);
    /// a ladder frame fires the shipped music request directly. The
    /// value is the user's own words or a catalog query — never model
    /// text (the merge is deterministic, FR-MTC-006).
    private func dispatchDialogueMusicValue(_ value: String,
                                            frame: DialogueFrame,
                                            raw: String) {
        if let active = frame.activeCommand, active.action == .music {
            dispatchInterpreted(active.merging(message: value), raw: raw)
        } else {
            fireMusicRequest(query: value)
        }
    }

    /// Executes one candidate pick (§12.5) through the ladder arm that
    /// owns the domain — "as if it had been understood" (ADR-MTC-07) —
    /// resolution first, events after, then that arm's own seam. `index`
    /// is 0-based (candidatePick's spoken position was decremented by the
    /// interception block; the free-form claim arrives 0-based); a
    /// non-nil `queryOverride` is the free-form claim's extracted value
    /// (`.answered(capture: .freeText, source: .candidate)`), a nil one is
    /// an enumerated pick (`.candidateSelected`).
    ///
    /// M-5 (security-design-review; the task's executor-bounds row): the
    /// index is validated against the frame's candidate list BEFORE any
    /// addressing. classify is total, so a hostile index cannot arrive
    /// through `route()` — this guard exists so the executor is total too:
    /// a crafted out-of-range index refuses with the honest exhausted
    /// close (nothing addressed, nothing executed), never an out-of-range
    /// read and never a crash. `internal` (not file-private) so the M-5
    /// test can drive the hostile index directly; the interception block
    /// is the only production caller.
    @discardableResult
    func executeDialogueCandidate(_ index: Int,
                                  capture: CaptureForm,
                                  queryOverride: String?,
                                  frame: DialogueFrame,
                                  raw: String) -> RoutingResult {
        guard frame.candidates.indices.contains(index) else {
            coordinator?.resolveDialogueFrame(.exhausted)
            emitDialogueFrameResolved(.exhausted)
            speak(key: "dialogue.exhausted")
            return .unrecognised(transcript: raw)
        }
        let candidate = frame.candidates[index]
        if let value = queryOverride {
            let merge = DialogueMerge(value: value, capture: capture, source: .candidate)
            coordinator?.resolveDialogueFrame(.answered(merge))
            emitDialogueAnswer(capture: capture, source: .candidate)
            emitDialogueFrameResolved(.answered(merge))
        } else {
            coordinator?.resolveDialogueFrame(.candidateSelected(index: index))
            emitDialogueAnswer(capture: capture, source: .candidate)
            emitDialogueFrameResolved(.candidateSelected(index: index))
        }
        switch candidate.domain {
        case .news:
            // C-2 (review-l2 F-2): the REAL relaxed news arm's hand-off
            // (`:1210-1217`) mirrored — ack first, the reader owns every
            // line from here; the strict stage (`:1131-1138`) is the same
            // triplet. The relaxed stage's `intent_keyword_match`
            // provenance event is stage-specific and deliberately not
            // borrowed (no keyword rule fired here).
            speakPreAck()
            coordinator?.fireNewsReader()
            emit(eventType: "news_reader_command", outcome: "success")
        case .youtube:
            // The strict YouTube stage's execution (`:1218-1221`): the
            // builder guarantees an executable query for a youtube
            // candidate (its executable-query rule); the guard is
            // defensive totality.
            guard let query = queryOverride ?? candidate.query else { break }
            fireYouTubePlay(query: query)
        case .music:
            // A real query fires the shipped music arm; a degenerate
            // pick chains a fresh slot-fill frame sequentially (§23's
            // candidate intake).
            fireMusicRequestOrProbe(
                query: KeywordIntentRule.musicQueryOutcome(
                    from: queryOverride ?? candidate.query ?? raw),
                raw: raw,
                intake: .candidate)
        case .appLaunch:
            // The relaxed app-launch arm's hand-off (`:1256-1264`): the
            // returned line is the coordinator's (the confirmation
            // question or the honest not-installed line); the caller only
            // speaks what it is handed.
            guard let appID = candidate.appID else { break }
            if let line = coordinator?.requestAppLaunch(appID: appID, confidence: nil) {
                coordinator?.noteGenericReply(line)
                speak(text: line)
            }
        default:
            // Not a framable domain — `DialogueCandidateBuilder` never
            // produces these (defensive totality).
            break
        }
        return .unrecognised(transcript: raw)
    }

    /// The attempt-cap close (§24; FR-MTC-007): a candidateChoice frame
    /// closes honestly — `.exhausted`, the `dialogue.exhausted` line,
    /// nothing executed (R3: executing an unasked candidate is the trap
    /// FR-MTC-004/FR-MTC-010 forbid); a slotFill frame executes its
    /// pending default instead (`.defaultExecuted`).
    private func resolveDialogueExhaustion(frame: DialogueFrame, raw: String) -> RoutingResult {
        switch frame.probeKind {
        case .candidateChoice:
            coordinator?.resolveDialogueFrame(.exhausted)
            emitDialogueFrameResolved(.exhausted)
            speak(key: "dialogue.exhausted")
            return .unrecognised(transcript: raw)
        case .slotFill:
            return executeDialogueDefault(frame: frame, raw: raw)
        }
    }

    /// The slotFill exhaustion default (§12.5/§24): resolve
    /// `.defaultExecuted`, the two events, then the same dispatch an
    /// answered frame uses, with the pending degenerate query as the
    /// value (or the opening transcript when even that is absent —
    /// `arm` guarantees one of the two exists for a live frame).
    private func executeDialogueDefault(frame: DialogueFrame, raw: String) -> RoutingResult {
        let value = frame.defaultQuery ?? frame.sourceTranscript
        let merge = DialogueMerge(value: value, capture: .optionName, source: .defaultQuery)
        coordinator?.resolveDialogueFrame(.defaultExecuted)
        emitDialogueAnswer(capture: merge.capture, source: merge.source)
        emitDialogueFrameResolved(.defaultExecuted)
        dispatchDialogueMusicValue(value, frame: frame, raw: raw)
        return .unrecognised(transcript: raw)
    }

    /// `dialogue_answer` for a consumed answer (§26): the closed
    /// capture-form / merge-source vocabulary, count/enum only — never
    /// the answer text, never the merged value.
    private func emitDialogueAnswer(capture: CaptureForm, source: MergeSource) {
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: "dialogue_answer",
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: [
                "capture_form": capture.rawValue,
                "merge_source": source.rawValue
            ]
        ))
    }

    /// `dialogue_frame_resolved` for the TURN-TIME resolutions the router
    /// itself initiates (§26's component split: `command_router` for
    /// answered/defaultExecuted/candidateSelected/exhausted/cancelled/
    /// escaped/bargedIn; the coordinator's funnel emits the ones it owns
    /// — timeout, emergency, supersession — with its own component). The
    /// outcome rides both the event's outcome field and the `outcome`
    /// metadata key §26 pins; the vocabulary is the closed ten-case enum,
    /// mapped in one place.
    private func emitDialogueFrameResolved(_ resolution: DialogueFrameResolution) {
        let outcome: String
        switch resolution {
        case .answered: outcome = "answered"
        case .defaultExecuted: outcome = "defaultExecuted"
        case .candidateSelected: outcome = "candidateSelected"
        case .exhausted: outcome = "exhausted"
        case .cancelled: outcome = "cancelled"
        case .escaped: outcome = "escaped"
        case .bargedIn: outcome = "bargedIn"
        case .timedOut: outcome = "timedOut"
        case .superseded: outcome = "superseded"
        case .emergency: outcome = "emergency"
        }
        observabilityBus.emit(ObservabilityEvent(
            component: "command_router",
            eventType: "dialogue_frame_resolved",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: ["outcome": outcome]
        ))
    }

    /// One music turn, state machine B (§10) through to execution. The
    /// turn writes at most one `.spotify` tool-log entry and speaks
    /// exactly one outcome line (plus the pre-ack) on every branch.
    @MainActor
    private func runMusicTurn(query: String, locale: Locale, startedAt: Date) async {
        let linked = spotifyAccountSession?.isLinked ?? false
        let product = spotifyAccountSession?.product ?? .unknown
        let transport = spotifyTransport
        let youtubeServeable = musicYouTubeServeable
        let searchOpenerPresent = spotifyLinkOpener != nil
        let youtubePrefetch: (apiKey: String, transport: LocalToolTransport)? = {
            guard musicYouTubeKeyed,
                  let apiKey = youtubeConfigStore?.apiKey,
                  let youtubeTransport else { return nil }
            return (apiKey, youtubeTransport)
        }()

        var effectiveLinked = linked
        // A linked account's turn always writes the turn entry (the
        // matrix's linked rows 1–7 and row 11); the unlinked treatment
        // writes one only when its own search hand-off attempts a link.
        var entryRequired = linked
        var token: String?
        var search: Result<SpotifyTool.TrackResult, SpotifyTool.FetchError>?
        var searchStatus: Int?

        if linked, let transport {
            let tokenResult = await spotifyAccountSession?.validAccessToken()
            switch tokenResult {
            case .success(let value):
                token = value
                let found = await performMusicSearch(query: query, token: value,
                                                     transport: transport,
                                                     youtubePrefetch: youtubePrefetch)
                search = found.result
                searchStatus = found.statusCode
                // §28's `spotify_search` vocabulary — emitted uniformly
                // whenever a search actually ran (the matrix rows that
                // list it read as highlights of the rows' distinctive
                // events, not an exhaustive log; "emit the event pair" in
                // the turn flow presumes it on every searched turn).
                switch found.result {
                case .success:
                    emitSpotify(eventType: "spotify_search", outcome: "usable",
                                durationMs: nil, errorCode: nil)
                case .failure(.noResults):
                    emitSpotify(eventType: "spotify_search", outcome: "empty",
                                durationMs: nil, errorCode: nil)
                case .failure:
                    emitSpotify(eventType: "spotify_search", outcome: "failed",
                                durationMs: nil, errorCode: nil)
                }
            case .failure(.revoked):
                // Row 10: the session wiped itself on the provider's
                // `invalid_grant` (its `spotify_unlink` revoked event is
                // the session's to emit). The turn is an unlinked turn;
                // none of its own attempts happened.
                effectiveLinked = false
                entryRequired = false
            case .failure, .none:
                // Row 11: the record was kept (transport / refresh /
                // store failure) — the search-failure shape. The matrix
                // mandates the `.spotify` fail entry for this row even
                // though no search ran; there is no HTTP status.
                await executeMusicTurn(Self.selectMusicOutcome(spotifyLinked: true,
                                                               spotifyTransportPresent: true,
                                                               search: nil,
                                                               product: product,
                                                               deepLinkCapable: false,
                                                               youtubeServeable: youtubeServeable,
                                                               spotifySearchOpenerPresent: searchOpenerPresent),
                                       query: query, locale: locale, startedAt: startedAt,
                                       token: nil, transport: nil, searchStatus: nil,
                                       entryRequired: true)
                return
            }
        }
        // (linked && transport == nil falls straight to the selection:
        // §28 names the row-7 branch for it; §10B's askability wording
        // would say unlinked — §28's ordered conditions win, recorded in
        // the task notes.)

        // §13's `spotifyDeepLinkCapable`: the opener seam exists AND the
        // platform probe accepts the resolved track URI. Probed only
        // where it can matter (the non-premium branch); premium selection
        // never consults it.
        var deepLinkCapable = false
        if effectiveLinked, product != .premium,
           case .success(let track)? = search,
           let uri = SpotifyTool.trackURI(id: track.id),
           let opener = spotifyLinkOpener {
            deepLinkCapable = opener.canOpenURL(uri)
        }

        let outcome = Self.selectMusicOutcome(spotifyLinked: effectiveLinked,
                                              spotifyTransportPresent: transport != nil,
                                              search: search,
                                              product: product,
                                              deepLinkCapable: deepLinkCapable,
                                              youtubeServeable: youtubeServeable,
                                              spotifySearchOpenerPresent: searchOpenerPresent)
        await executeMusicTurn(outcome, query: query, locale: locale, startedAt: startedAt,
                               token: token, transport: transport, searchStatus: searchStatus,
                               entryRequired: entryRequired)
    }

    /// The Spotify search phase with the §13 row-1 concurrency: when the
    /// YouTube path is keyed, both fetches are fired together and joined
    /// (NFR-SP-001: bounded by the larger provider budget, never the
    /// sum). Returns the search verdict plus the HTTP status the turn
    /// should record (the matrix's `statusCode` conventions: 200 for a
    /// 2xx search, the failure status when the provider answered one).
    private func performMusicSearch(query: String, token: String,
                                    transport: LocalToolTransport,
                                    youtubePrefetch: (apiKey: String, transport: LocalToolTransport)?)
        async -> (result: Result<SpotifyTool.TrackResult, SpotifyTool.FetchError>, statusCode: Int?) {
        let fetched: Result<SpotifyTool.TrackResult, SpotifyTool.FetchError>
        if let youtubePrefetch {
            async let spotifyLeg = fetchSpotifyResult(query: query, token: token,
                                                      transport: transport)
            async let youtubeLeg: Void = prefetchYouTubeLeg(query: query,
                                                            apiKey: youtubePrefetch.apiKey,
                                                            transport: youtubePrefetch.transport)
            let (spotifyResult, _) = await (spotifyLeg, youtubeLeg)
            fetched = spotifyResult
        } else {
            fetched = await fetchSpotifyResult(query: query, token: token, transport: transport)
        }
        switch fetched {
        case .success:
            return (fetched, 200)
        case .failure(.noResults):
            // 2xx with zero tracks (row 6's status convention).
            return (fetched, 200)
        case .failure(.invalidResponse(let statusCode)):
            return (fetched, statusCode)
        case .failure:
            return (fetched, nil)
        }
    }

    /// One Spotify search attempt, classified into the tool's closed
    /// error vocabulary — exactly one request (the tool owns that
    /// discipline).
    private func fetchSpotifyResult(query: String, token: String,
                                    transport: LocalToolTransport) async
        -> Result<SpotifyTool.TrackResult, SpotifyTool.FetchError> {
        do {
            let track = try await SpotifyTool.fetchTopTrack(query: query,
                                                            accessToken: token,
                                                            transport: transport)
            return .success(track)
        } catch let error as SpotifyTool.FetchError {
            return .failure(error)
        } catch {
            // `fetchTopTrack` only throws `FetchError`; anything else is
            // a transport anomaly (row 7).
            return .failure(.transportUnavailable)
        }
    }

    /// L2-R1: the concurrent YouTube leg runs only on the keyed fetch
    /// path, and its result is never consumed — when Spotify cannot
    /// serve, the turn falls back through `fireYouTubePlay` verbatim
    /// (ADR-SP-06), so the pre-fetched page can never change what is
    /// opened or spoken. Errors are swallowed; the fallback's own call
    /// owns every failure line. The keyless path is NOT pre-opened.
    private func prefetchYouTubeLeg(query: String, apiKey: String,
                                    transport: LocalToolTransport) async {
        _ = try? await YouTubeTool.fetchTopResult(query: query, apiKey: apiKey,
                                                  transport: transport)
    }

    /// Executes the selection's outcome. Every branch reaches exactly
    /// one spoken outcome line (plus the pre-ack) before returning.
    @MainActor
    private func executeMusicTurn(_ outcome: MusicOutcome, query: String, locale: Locale,
                                  startedAt: Date, token: String?,
                                  transport: LocalToolTransport?, searchStatus: Int?,
                                  entryRequired: Bool) async {
        switch outcome {
        case .spotifyRemote(let track):
            guard let token, let transport else {
                // Defensive: the selection yields remote only with a
                // token and transport in hand. The honest terminal beats
                // a crash.
                deliverMusicLine(locale: locale, key: "spotify.appMissing",
                                 statusCode: searchStatus, outcome: "app_missing",
                                 startedAt: startedAt)
                return
            }
            await executeRemoteMusicPlay(track: track, query: query, token: token,
                                         transport: transport, locale: locale,
                                         startedAt: startedAt, searchStatus: searchStatus)
        case .spotifyDeepLink(let track):
            executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                                 playStatus: nil, playFailed: false,
                                 searchStatus: searchStatus)
        case .spotifySearchHandoff:
            executeMusicSearchHandoff(query: query, locale: locale, startedAt: startedAt)
        case .youtube:
            deliverYouTubeFallback(query: query, locale: locale, startedAt: startedAt,
                                   statusCode: searchStatus, writeEntry: entryRequired)
        case .honestLine(let key):
            if entryRequired {
                deliverMusicLine(locale: locale, key: key, statusCode: searchStatus,
                                 outcome: Self.musicFallbackOutcome(forKey: key),
                                 startedAt: startedAt)
            } else {
                // Rows 9/10/12: nothing was attempted — the fallback
                // event and the honest line, no tool-log entry (the
                // matrix rows' "none").
                emitSpotify(eventType: "spotify_fallback",
                            outcome: Self.musicFallbackOutcome(forKey: key),
                            durationMs: nil, errorCode: nil)
                speakWithVisibleOutcome(key: key)
            }
        }
    }

    /// The remote-play leg (rows 1/2, §10B): one attempt; a 401 triggers
    /// exactly one forced token acquisition and one retry; a second 401
    /// wipes through the session (`markRevoked` — §26 names this
    /// "the router's second-401 path") and takes the unlinked treatment
    /// (row 10). Every other failure falls to the deep link (row 2) —
    /// never to a second play attempt.
    @MainActor
    private func executeRemoteMusicPlay(track: SpotifyTool.TrackResult, query: String,
                                        token: String, transport: LocalToolTransport,
                                        locale: Locale, startedAt: Date,
                                        searchStatus: Int?) async {
        guard let uri = SpotifyTool.trackURI(id: track.id) else {
            // Defensive: a validated `TrackResult` always builds a URI;
            // if it ever did not, the honest app-absent terminal is the
            // answer.
            deliverMusicLine(locale: locale, key: "spotify.appMissing",
                             statusCode: searchStatus, outcome: "app_missing",
                             startedAt: startedAt)
            return
        }

        var failure: SpotifyTool.PlayError
        do {
            try await SpotifyTool.playTrack(uri: uri, accessToken: token, transport: transport)
            deliverRemoteMusicSuccess(track: track, locale: locale, startedAt: startedAt)
            return
        } catch let error as SpotifyTool.PlayError {
            failure = error
        } catch {
            // `playTrack` only throws `PlayError`; anything else is a
            // transport anomaly (row 2's network leg).
            failure = .transportUnavailable
        }
        emitSpotify(eventType: "spotify_play", outcome: Self.spotifyPlayOutcome(failure),
                    durationMs: nil, errorCode: nil)

        if case .unauthorized = failure {
            guard let session = spotifyAccountSession else {
                executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                                     playStatus: Self.spotifyPlayStatus(failure),
                                     playFailed: true, searchStatus: searchStatus)
                return
            }
            switch await session.validAccessToken() {
            case .success(let refreshedToken):
                do {
                    try await SpotifyTool.playTrack(uri: uri, accessToken: refreshedToken,
                                                    transport: transport)
                    deliverRemoteMusicSuccess(track: track, locale: locale,
                                              startedAt: startedAt)
                    return
                } catch let retryError as SpotifyTool.PlayError {
                    emitSpotify(eventType: "spotify_play",
                                outcome: Self.spotifyPlayOutcome(retryError),
                                durationMs: nil, errorCode: nil)
                    if case .unauthorized = retryError {
                        // §10B: the second 401 is the provider's
                        // definitive rejection — wipe (the session emits
                        // `spotify_unlink` revoked) and take the unlinked
                        // treatment.
                        _ = await session.markRevoked()
                        await deliverUnlinkedMusicTreatment(query: query, locale: locale,
                                                            startedAt: startedAt)
                        return
                    }
                    executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                                         playStatus: Self.spotifyPlayStatus(retryError),
                                         playFailed: true, searchStatus: searchStatus)
                    return
                } catch {
                    emitSpotify(eventType: "spotify_play", outcome: "network_failed",
                                durationMs: nil, errorCode: nil)
                    executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                                         playStatus: nil, playFailed: true,
                                         searchStatus: searchStatus)
                    return
                }
            case .failure(.revoked):
                // The refresh itself was rejected: the session already
                // wiped (and emitted) — the turn is unlinked (row 10).
                await deliverUnlinkedMusicTreatment(query: query, locale: locale,
                                                    startedAt: startedAt)
                return
            case .failure:
                // No new token could be obtained honestly (transport /
                // refresh / store failure): no second play attempt is
                // possible — the deep link replaces it (row 2's shape),
                // never a futile retry with a rejected token.
                executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                                     playStatus: Self.spotifyPlayStatus(failure),
                                     playFailed: true, searchStatus: searchStatus)
                return
            }
        }

        executeMusicDeepLink(track: track, locale: locale, startedAt: startedAt,
                             playStatus: Self.spotifyPlayStatus(failure),
                             playFailed: true, searchStatus: searchStatus)
    }

    /// Row 1's success delivery: the honest confirmation with the
    /// provider's track name — SPOKEN ONLY (never carded, never logged,
    /// never an event field; NFR-SP-002) — and the turn's `ok` entry
    /// (204, empty query/response by the §21 contract).
    private func deliverRemoteMusicSuccess(track: SpotifyTool.TrackResult, locale: Locale,
                                           startedAt: Date) {
        emitSpotify(eventType: "spotify_play", outcome: "ok", durationMs: nil, errorCode: nil)
        speak(text: L10n.fmt("spotify.playing", locale: locale, track.title), locale: locale)
        logToolRequest(kind: .spotify, query: "", response: "", outcome: "ok",
                       statusCode: 204,
                       durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// The deep-link leg (rows 2/3/4/5): probe and open `spotify:track:`
    /// through the opener seam. `playFailed` marks a fallback that
    /// followed a failed remote attempt — its verdict (row 2's `fail`)
    /// and status survive into the entry; a clean free-tier hand-off is
    /// row 3's `ok`/nil. A not-opened attempt is row 5's terminal: the
    /// deeplink event is the turn's last observable, no chaining, and
    /// the honest line is the entry's response.
    @MainActor
    private func executeMusicDeepLink(track: SpotifyTool.TrackResult, locale: Locale,
                                      startedAt: Date, playStatus: Int?, playFailed: Bool,
                                      searchStatus: Int?) {
        guard let uri = SpotifyTool.trackURI(id: track.id) else {
            deliverMusicLine(locale: locale, key: "spotify.appMissing",
                             statusCode: playStatus ?? searchStatus,
                             outcome: "app_missing", startedAt: startedAt)
            return
        }
        guard let opener = spotifyLinkOpener else {
            // No opener seam: nothing can be attempted (no deeplink
            // event — the vocabulary counts attempts), the honest
            // terminal is the entry's response.
            emitSpotify(eventType: "spotify_fallback", outcome: "app_missing",
                        durationMs: nil, errorCode: nil)
            speakWithVisibleOutcome(key: "spotify.appMissing")
            logToolRequest(kind: .spotify, query: "",
                           response: L10n.str("spotify.appMissing", locale: locale),
                           outcome: "fail",
                           statusCode: playStatus ?? searchStatus,
                           durationMs: Self.elapsedMilliseconds(since: startedAt))
            return
        }
        switch SpotifyTool.open(uri, opener: opener) {
        case .opened:
            emitSpotify(eventType: "spotify_deeplink", outcome: "opened",
                        durationMs: nil, errorCode: nil)
            // Hand-off line: spoken only — the app itself shows what
            // happens next (the `youtube.openingSearch` precedent).
            speak(text: L10n.str("spotify.openApp", locale: locale), locale: locale)
            logToolRequest(kind: .spotify, query: "", response: "",
                           outcome: playFailed ? "fail" : "ok",
                           statusCode: playFailed ? playStatus : nil,
                           durationMs: Self.elapsedMilliseconds(since: startedAt))
        case .notOpened:
            emitSpotify(eventType: "spotify_deeplink", outcome: "not_opened",
                        durationMs: nil, errorCode: nil)
            speakWithVisibleOutcome(key: "spotify.appMissing")
            logToolRequest(kind: .spotify, query: "",
                           response: L10n.str("spotify.appMissing", locale: locale),
                           outcome: "fail",
                           statusCode: playFailed ? playStatus : searchStatus,
                           durationMs: Self.elapsedMilliseconds(since: startedAt))
        }
    }

    /// Row 8's search hand-off: unlinked, no YouTube leg, an opener
    /// present — hand the query to the app's own search. An opened
    /// hand-off is `ok` with no HTTP status (§21); a not-opened attempt
    /// is the terminal not-linked line (its deeplink event marks it; no
    /// fallback event — same no-chaining shape as row 5).
    @MainActor
    private func executeMusicSearchHandoff(query: String, locale: Locale, startedAt: Date) {
        guard let opener = spotifyLinkOpener, let uri = SpotifyTool.searchURI(query: query) else {
            // Defensive: the selection offers the hand-off only with the
            // opener seam present; an unbuildable URI (empty/over-cap)
            // degrades to the same honest line — no attempt, no entry.
            emitSpotify(eventType: "spotify_fallback", outcome: "not_linked",
                        durationMs: nil, errorCode: nil)
            speakWithVisibleOutcome(key: "spotify.notLinked")
            return
        }
        switch SpotifyTool.open(uri, opener: opener) {
        case .opened:
            emitSpotify(eventType: "spotify_deeplink", outcome: "opened",
                        durationMs: nil, errorCode: nil)
            speak(text: L10n.str("spotify.openSearch", locale: locale), locale: locale)
            logToolRequest(kind: .spotify, query: "", response: "", outcome: "ok",
                           statusCode: nil,
                           durationMs: Self.elapsedMilliseconds(since: startedAt))
        case .notOpened:
            emitSpotify(eventType: "spotify_deeplink", outcome: "not_opened",
                        durationMs: nil, errorCode: nil)
            speakWithVisibleOutcome(key: "spotify.notLinked")
            logToolRequest(kind: .spotify, query: "",
                           response: L10n.str("spotify.notLinked", locale: locale),
                           outcome: "fail", statusCode: nil,
                           durationMs: Self.elapsedMilliseconds(since: startedAt))
        }
    }

    /// The unlinked treatment rows 8/10/12 share: YouTube where it can
    /// serve, else the search hand-off where an opener exists, else the
    /// honest not-linked line. No `.spotify` entry of its own — only the
    /// hand-off leg's attempt writes one (row 8's "only if a Spotify
    /// attempt happened").
    @MainActor
    private func deliverUnlinkedMusicTreatment(query: String, locale: Locale,
                                               startedAt: Date) async {
        let outcome = Self.selectMusicOutcome(spotifyLinked: false,
                                              spotifyTransportPresent: false,
                                              search: nil,
                                              product: .unknown,
                                              deepLinkCapable: false,
                                              youtubeServeable: musicYouTubeServeable,
                                              spotifySearchOpenerPresent: spotifyLinkOpener != nil)
        await executeMusicTurn(outcome, query: query, locale: locale, startedAt: startedAt,
                               token: nil, transport: nil, searchStatus: nil,
                               entryRequired: false)
    }

    /// §13's fallback contract: the `spotify_fallback` marker first, the
    /// YouTube helper VERBATIM (ADR-SP-06 — the query-free projection
    /// keeps the music query out of the tool log; [T-114][M-1]), then
    /// the turn's own `.spotify` fail entry when a Spotify attempt
    /// happened.
    private func deliverYouTubeFallback(query: String, locale: Locale, startedAt: Date,
                                        statusCode: Int?, writeEntry: Bool) {
        emitSpotify(eventType: "spotify_fallback", outcome: "youtube",
                    durationMs: nil, errorCode: nil)
        fireYouTubePlay(query: query, logProjection: .queryFree)
        guard writeEntry else { return }
        logToolRequest(kind: .spotify, query: "", response: "", outcome: "fail",
                       statusCode: statusCode,
                       durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// The static-line delivery (§28's signature): the fallback event
    /// with the key's closed outcome, the localized line made visible
    /// (the honest lines are cards, the `deliverYouTubeFailure`
    /// precedent), and the turn's `.spotify` fail entry carrying the
    /// exact line the user heard — never a query, title, id or token.
    private func deliverMusicLine(locale: Locale, key: String, statusCode: Int?,
                                  outcome: String, startedAt: Date) {
        emitSpotify(eventType: "spotify_fallback", outcome: outcome,
                    durationMs: nil, errorCode: nil)
        speakWithVisibleOutcome(key: key)
        logToolRequest(kind: .spotify, query: "",
                       response: L10n.str(key, locale: locale), outcome: "fail",
                       statusCode: statusCode,
                       durationMs: Self.elapsedMilliseconds(since: startedAt))
    }

    /// §28's closed event vocabulary, component `spotify`, `metadata: [:]`
    /// on every event — no query, title, id or token can reach the bus.
    private func emitSpotify(eventType: String, outcome: String,
                             durationMs: Int?, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "spotify",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }

    /// `PlayError` → §28's closed `spotify_play` outcome set.
    private static func spotifyPlayOutcome(_ error: SpotifyTool.PlayError) -> String {
        switch error {
        case .premiumRequired: return "premium_required"
        case .restricted: return "restricted"
        case .noActiveDevice: return "no_active_device"
        case .unauthorized: return "unauthorized"
        case .invalidResponse, .timedOut, .transportUnavailable, .invalidURI:
            return "network_failed"
        }
    }

    /// `PlayError` → the HTTP status the turn's entry records (the
    /// matrix's 403/404/nil pair plus the general "from the last HTTP
    /// response when one exists"); timeouts and transport failures carry
    /// no status.
    private static func spotifyPlayStatus(_ error: SpotifyTool.PlayError) -> Int? {
        switch error {
        case .premiumRequired, .restricted: return 403
        case .noActiveDevice: return 404
        case .unauthorized: return 401
        case .invalidResponse(let statusCode): return statusCode
        case .timedOut, .transportUnavailable, .invalidURI: return nil
        }
    }

    /// Honest-line L10n key → §28's closed `spotify_fallback` outcome
    /// set.
    private static func musicFallbackOutcome(forKey key: String) -> String {
        switch key {
        case "spotify.notFound": return "not_found"
        case "spotify.unavailable": return "unavailable"
        case "spotify.notLinked": return "not_linked"
        case "spotify.appMissing": return "app_missing"
        default: return "unavailable"
        }
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

    private func dispatchInterpreted(_ command: InterpretedCommand, raw: String) {
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
            handleSetReminder(command, raw: raw)
        case .healthQuery:
            // First-class stub intent — honest "not yet" (spec §5.1).
            emit(eventType: "command_health_query_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.healthNotAvailable")
        case .music:
            // [SPOTIFY] (2026-10-07) T-116: the model-resolved music
            // intent routes to the same music path the ladder stage
            // uses. The stub dies here — `command_music_stub` and
            // `router.musicStub` have no reachable emission left
            // (ADR-SP-11 keeps the catalog key, unreachable).
            //
            // The frozen 12-action grammar carries no query slot for
            // this action, so the §13 order
            // (`interpretedQuery ?? musicQuery ?? transcript`) reads
            // against this repo's `InterpretedCommand` shape: the
            // command's free-text `message` entity is the model's query
            // when it set one, else the deterministic extractor, else
            // the raw transcript.
            let modelQuery = command.message?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let interpretedQuery = (modelQuery?.isEmpty == false) ? modelQuery : nil
            fireMusicRequest(query: interpretedQuery
                ?? KeywordIntentRule.musicQuery(from: raw)
                ?? raw)
        case .sendMessage:
            handleSendMessage(command)
        case .guide:
            handleGuide(command)
        case .createCalendarEvent:
            // [CALENDAR-EVENTS] (2026-09-13) Real executor — splits off
            // the stub this action shared with `suggest_video`.
            handleCreateCalendarEvent(command, raw: raw)
        case .suggestVideo:
            // Honest not-yet stub (spec §7.3): the video executor lands
            // with the video phase — never pretend a video was queued.
            emit(eventType: "command_v2_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.featureNotYet")
        case .query:
            emit(eventType: "command_llm_query", outcome: "info")
            deliverModelReply(command.reply)
        case .chat:
            // [CHAT] Stage 1 of the conversational-augmentation plan
            // (2026-09-23): a free-text conversational reply — a greeting,
            // thanks, a farewell, small talk. It rides the SAME
            // spoken-answer surface a `query` answer uses, through the
            // same sanity gate (`deliverModelReply` → `sanitisedModelReply`
            // → `speakWithVisibleOutcome` on rejection), so chat text gets
            // exactly the sanitisation and abuse-gate every model answer
            // gets.
            //
            // Nothing executes here, and the wiring is what makes that
            // structural rather than a promise: the chat decode carries no
            // slots (`LlamaGrammar.chatJSONSchema`), the intent cache
            // refuses the action (`IntentCommandCache.isCacheable`), and
            // the tier is free (`ConfirmationTier`). The event is distinct
            // from `command_llm_query` so the field can tell a chat turn
            // from an answered question.
            //
            // [CHAT-CONFIDENCE-FLOOR] The decoded object's own
            // `confidence`, checked BEFORE a word of the model's text can
            // be spoken: below the floor (see `chatConfidenceFloor`) the
            // brain has told us it is guessing, and a guess spoken in the
            // assistant's voice is worse than an admitted gap — so the
            // honest line is spoken instead, the model's text never
            // reaches the speaker or the card, and the turn is observable
            // (`chatLowConfidence`, with both numbers in metadata). At or
            // above the floor the reply is delivered exactly like a
            // `query` answer, sanity gate included.
            guard command.confidence >= chatConfidenceFloor else {
                observabilityBus.emit(ObservabilityEvent(
                    component: "command_router",
                    eventType: "chatLowConfidence",
                    durationMs: nil,
                    outcome: "info",
                    errorCode: nil,
                    metadata: ["confidence": String(format: "%.2f", command.confidence),
                               "floor": String(format: "%.2f", chatConfidenceFloor)]))
                speakWithVisibleOutcome(key: "router.chatLowConfidence")
                return
            }
            emit(eventType: "command_llm_chat", outcome: "info")
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
    private func handleSetReminder(_ command: InterpretedCommand, raw: String) {
        // [SLOT-PROVENANCE] (2026-09-17) A time the transcript never
        // contained is an invention (the "दशैँ कहिले हो" → fabricated
        // १०:३० case). Treat it as missing and ask — the elder's real
        // answer costs one extra line, a hallucinated reminder costs
        // their trust.
        guard TimeSlotProvenance.timeSlotIsDefensible(raw: raw, time: command.time) else {
            emit(eventType: "command_set_reminder_time_fabricated", outcome: "info")
            speak(key: "router.reminderNoTime")
            return
        }
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

    /// [CALENDAR-EVENTS] (2026-09-13) `create_calendar_event` — replaces
    /// the stub this action shared with `suggest_video`.
    ///
    /// Deliberately NOT a write here: like every other `.confirm`-tier
    /// action, the router only validates, resolves and asks. The
    /// coordinator pends the event, speaks the question, and performs
    /// the write on yes — so a misheard title or time costs one "होइन"
    /// instead of a wrong entry in the family's shared calendar.
    ///
    /// Three honest dead ends, each with its own line — never one
    /// generic failure, because they are fixed three different ways
    /// (say the subject / say the time / grant calendar access):
    ///  - no subject: the model extracted no `topic`. Confirming a
    ///    nameless event would write a blank block into the calendar;
    ///  - no usable time: no time expression, or one the parser could
    ///    not resolve. A bare future-less time is NOT a dead end —
    ///    `CalendarEventTimeResolver` rolls it to tomorrow;
    ///  - no writer: the coordinator refused (access denied/restricted).
    ///    Checked BEFORE the prompt, so the elder is never asked to
    ///    confirm an action that can only fail.
    ///
    /// The `clock()` seam (not `Date()`) feeds "now", so the
    /// bare-time-rolls-to-tomorrow decision is deterministic under test.
    private func handleCreateCalendarEvent(_ command: InterpretedCommand, raw: String) {
        guard let topic = command.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty else {
            emit(eventType: "command_calendar_event_no_title", outcome: "info")
            speak(key: "router.calendarEventNoTitle")
            return
        }

        // [SLOT-PROVENANCE] Same fabrication guard as set_reminder: a
        // calendar event time the transcript never contained is an
        // invention — ask for the time instead of writing it.
        guard TimeSlotProvenance.timeSlotIsDefensible(raw: raw, time: command.time) else {
            emit(eventType: "command_calendar_event_time_fabricated", outcome: "info")
            speak(key: "router.calendarEventNoTime")
            return
        }

        guard let timeString = command.time,
              let parsed = NepaliTimeParser.parse(timeString),
              let startDate = CalendarEventTimeResolver.resolveEventDate(
                  from: parsed,
                  now: clock(),
                  calendar: Calendar.current
              ) else {
            emit(eventType: "command_calendar_event_no_time", outcome: "info")
            speak(key: "router.calendarEventNoTime")
            return
        }

        guard let prompt = coordinator?.requestCalendarEventConfirmation(
            title: topic, startDate: startDate
        ) else {
            emit(eventType: "command_calendar_event_unavailable", outcome: "info")
            speak(key: "router.calendarEventCalendarUnavailable")
            return
        }
        emit(eventType: "command_calendar_event_confirmation_requested", outcome: "success")
        speak(text: prompt)
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
        let pluginCommand = makePluginCommand(actionName: actionName,
                                              entities: command.pluginEntities ?? [:],
                                              confidence: command.confidence)
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
    /// the understand call's steps remain the honest fallback when the
    /// plugin cannot serve (no registry/client, or `handle` fails).
    private func handleGuide(_ command: InterpretedCommand) {
        emit(eventType: "command_guide", outcome: "info")
        let locale = coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        guard let registry = pluginRegistry,
              let geminiClient,
              let topic = command.topic, !topic.isEmpty,
              let plugin = registry.plugin(handling: "appliance.identify", locale: locale) else {
            speakGuideSteps(command)
            return
        }
        let pluginCommand = makePluginCommand(actionName: "appliance.identify",
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
                    // The plugin could not serve (e.g. unconfigured
                    // client) — the understand call's steps are the
                    // honest fallback.
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

    /// Single `PluginCommand` construction point for every dispatch
    /// path (plugin contract, T-042). The transcript is the SANITISED
    /// utterance — `InputSanitiser.sanitise(_:level: .quarantine)`, the
    /// same policy the three interpreters apply before any prompt — so
    /// the normal `.plugin` path and the guide-deferral path hand
    /// plugins identical field semantics. Never the raw text and never
    /// an unconditional "": empty only when no voice utterance is in
    /// flight (screen-initiated callers such as
    /// `AppCoordinator.nepaliCalendarAnswer` build their own command).
    /// The raw transcript is deliberately NOT logged here (NFR-016).
    private func makePluginCommand(actionName: String,
                                   entities: [String: String],
                                   confidence: Double) -> PluginCommand {
        PluginCommand(actionName: actionName,
                      transcript: InputSanitiser.sanitise(pendingTranscript ?? "",
                                                          level: .quarantine),
                      entities: entities,
                      confidence: confidence)
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
        speakWithVisibleOutcome(text: L10n.str(key, locale: locale), locale: locale)
    }

    /// The text variant — for already-resolved dynamic lines (e.g. the
    /// [GEMINI-SOLIDIFY] cloud-failure-class lines), same visible-outcome
    /// contract as the key variant.
    private func speakWithVisibleOutcome(text: String, locale: Locale? = nil) {
        guard !text.isEmpty else { return }
        coordinator?.noteGenericReply(text)
        speak(text: text, locale: locale)
    }

    /// Speaks dynamic text (LLM-generated replies, scheduler challenge
    /// prompts) — no catalog lookup, already in the right language.
    /// [VOICE-ACK] Commits through the serial `ReplySpeakLane`, so a
    /// pre-acknowledgment and a later result reply drain in commit order.
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
        let lane = speakLane ?? {
            let newLane = ReplySpeakLane(speaker: speaker)
            speakLane = newLane
            return newLane
        }()
        coordinator?.noteAssistantSpoke(text)
        coordinator?.noteSpeakingStarted()
        // [TURN-TIMING] The reply utterance is handed to the speaker.
        turnTracer?.noteSpeakQueued()
        Task {
            // [VOICE-ACK] Await THIS utterance's turn in the lane — the
            // speak-finished marks below keep their exact per-utterance
            // semantics (they fire when this speech ends, not when a
            // later queued utterance does).
            await lane.enqueue(text, locale: locale)
            #if DEBUG
            print("[command_router][DEBUG] speaker.speak() returned (finished or cancelled)")
            #endif
            // [TURN-TIMING] Reply speech finished — the last one
            // finalizes the turn.
            self.turnTracer?.noteSpeakFinished()
            coordinator?.noteSpeakingEnded()
        }
    }

    /// [VOICE-ACK] Speaks the next rotating pre-acknowledgment variant
    /// ("एक छिन…" / "one moment…") for a stage whose reply will take a
    /// beat — the LLM round-trip, alarm/timer arming, YouTube, briefing,
    /// news, navigation. Committed BEFORE the slow work starts so the
    /// lane plays it ahead of the result. Instant-answer stages
    /// (greetings, time/date/weather pre-answers, calculator) and
    /// confirmation challenges never call this — they already speak
    /// immediately. Empty catalog text is a silent no-op (same guard as
    /// `speak(key:)`).
    ///
    /// [LAT-M2] Ack fast lane: when the pre-synthesized cache is warm
    /// the ack plays the cached WAV directly — the ack is the one
    /// utterance whose start latency the user feels, so it must not pay
    /// synthesis (target: `router_done → speak_queued` ≤ 200 ms).
    /// Wording, variant rotation, and stage selection are UNCHANGED —
    /// only the audio path differs. The ack keeps its full speak
    /// bookkeeping (assistant-spoke note, speaking state, turn-tracer
    /// speak marks — the finished side arrives from the player's
    /// `onPlaybackFinished`). A miss falls back to the pre-task
    /// synthesis path with an honest `ack_cache_miss` event; with no
    /// player installed (nil seam — tests, dormant wiring) the legacy
    /// path runs byte-identically, no events.
    private var preAckCounter = 0
    private func speakPreAck(locale: Locale? = nil) {
        let locale = locale ?? coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let variant = preAckCounter % 3 + 1
        preAckCounter += 1
        let key = "voiceAck.moment\(variant)"
        let text = L10n.str(key, locale: locale)
        guard !text.isEmpty else { return }
        if let preAckPlayer,
           preAckPlayer.playCachedAck(variant: variant, locale: locale) {
            // [LAT-M2] Cache hit — the WAV is already handed to the
            // player (no synthesis, no lane wait). Same synchronous
            // notes, in the same order, as `speak(text:)` commits.
            coordinator?.noteAssistantSpoke(text)
            coordinator?.noteSpeakingStarted()
            turnTracer?.noteSpeakQueued()
            return
        }
        if preAckPlayer != nil {
            // [LAT-M2] Honest miss: the cache wasn't ready (never built
            // for this locale/voice, evicted, or the player failed) —
            // the existing synthesis path speaks the ack.
            emit(eventType: "ack_cache_miss", outcome: "miss")
        }
        speak(text: text, locale: locale)
    }

    /// [CLOUD-CASCADE] Speaks the cloud cascade's HOLD CUE — the line the
    /// user hears when the large local brain's answer was below the
    /// configured threshold and the turn is about to go to the online
    /// brain ("One moment — this is taking a little longer…" /
    /// "एक छिन — अलि बढी समय लाग्दैछ…").
    ///
    /// Wired to `IntentRouter`'s cascade tier as its `holdCue` seam and
    /// invoked from inside the router's escalation, BEFORE the cloud call
    /// is made, so the cue is committed to the reply lane ahead of the
    /// answer the cloud will produce (the same lane ordering the pre-ack
    /// relies on). Empty catalog text is a silent no-op — same guard as
    /// `speakPreAck`/`speak(key:)` — so a locale without the string never
    /// speaks the raw key.
    ///
    /// Deliberately NOT routed through the ack fast lane's cached WAVs:
    /// that cache holds the rotating "one moment…" pre-acks, and a cue
    /// whose wording is its own would have to be built into it to belong
    /// there. Its synthesis cost is paid while the cloud round trip is
    /// already in flight, so it cannot delay the answer.
    func speakCloudCascadeHoldCue(locale: Locale? = nil) {
        let locale = locale ?? coordinator?.activeLocale ?? Locale(identifier: "ne-NP")
        let text = L10n.str("cloudCascade.holdCue", locale: locale)
        guard !text.isEmpty else { return }
        emit(eventType: "cloud_cascade_hold_cue", outcome: "spoken")
        speak(text: text, locale: locale)
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
