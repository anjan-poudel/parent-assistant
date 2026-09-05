import Foundation
import UserNotifications

protocol VoiceCommandCoordinating: AnyObject {
    var isAwaitingConfirmation: Bool { get }
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

    /// Call-confirmation correction hook (spec §7.2 correction protocol).
    /// While a call confirmation is outstanding, the router hands each
    /// response utterance here FIRST: an utterance carrying a method
    /// override ("होइन, फोन नै गर") rebuilds the pending call and
    /// re-confirms. Returns true when it handled the utterance; false
    /// means "not an override — run the normal yes/no flow".
    func handleCallConfirmationOverride(_ utterance: String) -> Bool

    /// `send_message` intent (trial wiring). iOS never lets a third-party
    /// app send SMS silently — `MFMessageComposeViewController` always
    /// requires the user's own tap on Send — so this resolves the contact
    /// and presents the native compose sheet pre-filled with `body`.
    /// Returns false when no contact can be resolved.
    func composeMessage(toContactNamed name: String?, body: String) -> Bool
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
        case unrecognised(transcript: String)
    }

    private weak var coordinator: VoiceCommandCoordinating?
    private let observabilityBus: ObservabilityBus
    private let speaker: Speaker?
    private let interpreter: CommandInterpreter

    init(coordinator: VoiceCommandCoordinating,
         observabilityBus: ObservabilityBus,
         speaker: Speaker? = nil,
         interpreter: CommandInterpreter = NullCommandInterpreter()) {
        self.coordinator = coordinator
        self.observabilityBus = observabilityBus
        self.speaker = speaker
        self.interpreter = interpreter
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
        let preText = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            // medication-flavored and would be wrong here.
            let isCallConfirmation = coordinator?.isAwaitingCallConfirmation == true
            if Self.isYesResponse(raw) {
                coordinator?.handleConfirmationResponse(.yes)
                emit(eventType: "confirmation_yes", outcome: "success")
                if !isCallConfirmation {
                    speak(key: "router.confirmationYes")
                }
                return isCallConfirmation ? .callConfirmed : .acknowledgedMedication
            }
            if Self.isNoResponse(raw) {
                coordinator?.handleConfirmationResponse(.no)
                emit(eventType: "confirmation_no", outcome: "success")
                if !isCallConfirmation {
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

        // Fast path — the LLM interpreter. Falls through to keyword when
        // the interpreter is unavailable or not confident.
        if interpreter.isAvailable {
            let context = InterpreterContext(
                pendingMedications: [],
                userLanguageHint: coordinator?.activeLocale.languageCode ?? "en"
            )
            interpreter.interpret(transcript: raw, context: context) { [weak self] command in
                if let command = command {
                    self?.pendingTranscript = raw
                    self?.dispatchInterpreted(command)
                    self?.pendingTranscript = nil
                } else {
                    _ = self?.routeKeywordRemainder(raw)
                }
            }
            // We can't return a synchronous result once the LLM path fires;
            // report the transcript as "handled asynchronously".
            emit(eventType: "command_dispatched_to_llm", outcome: "info")
            return .unrecognised(transcript: raw)
        }

        return routeKeywordRemainder(raw)
    }

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
    /// than acted on) and the generic unrecognised re-prompt.
    @discardableResult
    private func routeKeywordRemainder(_ raw: String) -> RoutingResult {
        let text = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sensitiveCallPhrases = [
            "call", "phone", "facetime", "messenger", "whatsapp",
            "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
        ]
        if sensitiveCallPhrases.contains(where: { Self.containsPhrase($0, in: text) }) {
            emit(eventType: "command_sensitive_blocked_auth_unavailable", outcome: "blocked")
            speak(key: "router.sensitiveBlocked")
            return .blockedSensitiveAction
        }

        emit(eventType: "command_unrecognised", outcome: "info")
        speak(key: "router.reprompt")
        return .unrecognised(transcript: raw)
    }

    // MARK: - LLM dispatch

    /// The raw transcript currently being dispatched through an
    /// interpreted command — set by the async interpret completion and
    /// cleared after dispatch, so handlers (e.g. `handleCall`) can thread
    /// it to the coordinator for cache learning. Single in-flight
    /// interpretation at a time (VoicePipeline serialises utterances).
    private var pendingTranscript: String?

    private func dispatchInterpreted(_ command: InterpretedCommand) {
        switch command.action {
        case .ackMed:
            handleMedicationAcknowledgement(replyOverride: command.reply)
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
            // Guide class (spec §5): steps are READ ALOUD to the human,
            // never executed. Cloud-only today (appliance/TV questions
            // need the vision helper anyway) — spoken steps when present,
            // else the model's reply.
            emit(eventType: "command_guide", outcome: "info")
            if let steps = command.steps, !steps.isEmpty {
                let spoken = steps.joined(separator: ". ")
                coordinator?.noteGenericReply(spoken)
                speak(text: spoken)
            } else {
                coordinator?.noteGenericReply(command.reply)
                speak(text: command.reply)
            }
        case .createCalendarEvent, .suggestVideo:
            // Honest not-yet stubs (spec §7.3): the executors for these
            // land with the calendar/video phases — never pretend an
            // event was created or a video queued.
            emit(eventType: "command_v2_stub", outcome: "info")
            speakWithVisibleOutcome(key: "router.featureNotYet")
        case .query:
            emit(eventType: "command_llm_query", outcome: "info")
            coordinator?.noteGenericReply(command.reply)
            speak(text: command.reply)
        case .none:
            emit(eventType: "command_llm_no_action", outcome: "info")
            coordinator?.noteGenericReply(command.reply)
            speak(text: command.reply)
        }
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
                speak(key: "router.sensitiveBlocked")
            }
            return
        }
        emit(eventType: "command_call_confirmation_requested", outcome: "success")
        speak(text: prompt)
    }

    /// `send_message` (trial wiring). Never claims the message was SENT —
    /// only that it's ready, since the user still has to tap Send on the
    /// native compose sheet.
    private func handleSendMessage(_ command: InterpretedCommand) {
        guard let body = command.message, !body.isEmpty,
              coordinator?.composeMessage(toContactNamed: command.contact, body: body) == true else {
            emit(eventType: "command_message_unresolved", outcome: "blocked")
            speak(key: "router.messageContactNotFound")
            return
        }
        emit(eventType: "command_message_composing", outcome: "success")
        speak(text: command.reply)
    }

    private func formattedTime(_ components: DateComponents, locale: Locale) -> String {
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return "" }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(locale))
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
        Task {
            await speaker.speak(text, locale: locale)
            #if DEBUG
            print("[command_router][DEBUG] speaker.speak() returned (finished or cancelled)")
            #endif
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
