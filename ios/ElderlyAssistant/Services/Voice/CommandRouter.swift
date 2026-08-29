import Foundation
import UserNotifications

protocol VoiceCommandCoordinating: AnyObject {
    var isAwaitingConfirmation: Bool { get }

    func recordTranscript(_ text: String)
    func oldestPendingReminderEntryId() -> UUID?
    func handleMedicationAcknowledgement(entryId: UUID)
    func startVoiceAckConfirmation(for entryId: UUID) -> String?
    func handleConfirmationResponse(_ response: ConfirmationResponse)
}

/// Turns a raw transcript into a coordinator call and a spoken reply.
///
/// Routing order:
///  1. LLM interpreter (`CommandInterpreter`), if available and confident.
///  2. Keyword-matching fallback for a small, safety-critical vocabulary.
///  3. "I didn't understand" — spoken back, plus a debug notification.
///
/// Keeping the keyword layer around after the LLM lands is deliberate:
///  - it's the safety net if the LLM is warming up, unavailable, or the
///    device is low on memory,
///  - it handles the tiny set of utterances we never want to depend on an
///    LLM being warm for ("emergency", explicit medication acks).
final class CommandRouter {

    enum RoutingResult: Equatable {
        case acknowledgedMedication
        case blockedSensitiveAction
        case unrecognised(transcript: String)
    }

    private weak var coordinator: VoiceCommandCoordinating?
    private let observabilityBus: ObservabilityBus
    private let speaker: Speaker?
    private let interpreter: CommandInterpreter
    var replyLocale: Locale

    init(coordinator: VoiceCommandCoordinating,
         observabilityBus: ObservabilityBus,
         speaker: Speaker? = nil,
         interpreter: CommandInterpreter = NullCommandInterpreter(),
         replyLocale: Locale = Locale(identifier: "ne-NP")) {
        self.coordinator = coordinator
        self.observabilityBus = observabilityBus
        self.speaker = speaker
        self.interpreter = interpreter
        self.replyLocale = replyLocale
    }

    @discardableResult
    func route(transcript raw: String) -> RoutingResult {
        coordinator?.recordTranscript(raw)

        // Confirmation-follow-up path: if a challenge is outstanding,
        // treat this transcript as the user's yes/no response, not a new
        // command. Runs the dementia-aware `acknowledgeWithConfirmation`
        // path with the double-dose check.
        if coordinator?.isAwaitingConfirmation == true {
            if Self.isYesResponse(raw) {
                coordinator?.handleConfirmationResponse(.yes)
                emit(eventType: "confirmation_yes", outcome: "success")
                speak("Okay, marked as taken.")
                return .acknowledgedMedication
            }
            if Self.isNoResponse(raw) {
                coordinator?.handleConfirmationResponse(.no)
                emit(eventType: "confirmation_no", outcome: "success")
                speak("Understood. I'll remind you again shortly.")
                return .unrecognised(transcript: raw)
            }
            // Ambiguous response — re-prompt.
            emit(eventType: "confirmation_ambiguous", outcome: "info")
            speak("Please answer with yes or no.")
            return .unrecognised(transcript: raw)
        }

        // Fast path — the LLM interpreter. Falls through to keyword when
        // the interpreter is unavailable or not confident.
        if interpreter.isAvailable {
            let context = InterpreterContext(
                pendingMedications: [],
                userLanguageHint: replyLocale.languageCode ?? "en"
            )
            interpreter.interpret(transcript: raw, context: context) { [weak self] command in
                if let command = command {
                    self?.dispatchInterpreted(command)
                } else {
                    _ = self?.routeKeyword(raw)
                }
            }
            // We can't return a synchronous result once the LLM path fires;
            // report the transcript as "handled asynchronously".
            emit(eventType: "command_dispatched_to_llm", outcome: "info")
            return .unrecognised(transcript: raw)
        }

        return routeKeyword(raw)
    }

    // MARK: - Keyword fallback

    @discardableResult
    private func routeKeyword(_ raw: String) -> RoutingResult {
        let text = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ackPhrases = [
            "i took", "i've taken", "ive taken", "took my medication",
            "took my medicine", "taken my medication", "taken my medicine",
            "done", "yes i took it",
            "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
            "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
            "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
            "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें",
            "खाएँ", "खाए", "भयो"
        ]
        if ackPhrases.contains(where: { text.contains($0) }) {
            handleMedicationAcknowledgement()
            return .acknowledgedMedication
        }

        let sensitiveCallPhrases = [
            "call", "phone", "facetime", "messenger", "whatsapp",
            "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
        ]
        if sensitiveCallPhrases.contains(where: { text.contains($0) }) {
            emit(eventType: "command_sensitive_blocked_auth_unavailable", outcome: "blocked")
            speak("माफ गर्नुहोस्, अहिले फोन वा सन्देश पठाउने सुविधा सुरक्षित प्रमाणीकरण तयार नभएसम्म बन्द छ।")
            return .blockedSensitiveAction
        }

        emit(eventType: "command_unrecognised", outcome: "info")
        postDebugNotification(title: "Heard command", body: "I heard: \(raw)")
        speak("माफ गर्नुहोस्, मैले बुझिनँ। कृपया फेरि भन्नुहोस्।")
        return .unrecognised(transcript: raw)
    }

    // MARK: - LLM dispatch

    private func dispatchInterpreted(_ command: InterpretedCommand) {
        switch command.action {
        case .ackMed:
            handleMedicationAcknowledgement(replyOverride: command.reply)
        case .call:
            emit(eventType: "command_sensitive_blocked_auth_unavailable", outcome: "blocked")
            speak("माफ गर्नुहोस्, अहिले फोन वा सन्देश पठाउने सुविधा सुरक्षित प्रमाणीकरण तयार नभएसम्म बन्द छ।")
        case .query:
            emit(eventType: "command_llm_query", outcome: "info")
            speak(command.reply)
        case .none:
            emit(eventType: "command_llm_no_action", outcome: "info")
            speak(command.reply)
        }
    }

    private func handleMedicationAcknowledgement(replyOverride: String? = nil) {
        guard let coordinator = coordinator,
              let oldest = coordinator.oldestPendingReminderEntryId() else {
            postDebugNotification(
                title: "Nothing to acknowledge",
                body: "There are no medication reminders waiting."
            )
            emit(eventType: "command_ack_no_pending", outcome: "info")
            speak("अहिले पर्खिरहेको औषधिको सम्झना छैन।")
            return
        }

        // Dementia flow: issue the FR-D01 challenge before recording the
        // dose. The user's yes/no on the next transcript runs through
        // `handleConfirmationResponse`, which triggers the FR-D03
        // double-dose check. Falls back to baseline ack only if the
        // challenge cannot be issued (no pending reminder, etc).
        if let prompt = coordinator.startVoiceAckConfirmation(for: oldest) {
            emit(eventType: "command_ack_challenge_issued", outcome: "success")
            postDebugNotification(title: "Confirming dose", body: prompt)
            speak(prompt)
            return
        }

        coordinator.handleMedicationAcknowledgement(entryId: oldest)
        emit(eventType: "command_ack_medication_baseline", outcome: "success")
        postDebugNotification(
            title: "Medication acknowledged",
            body: "Marked as taken (baseline path — no challenge available)."
        )
        speak(replyOverride ?? "ठीक छ, औषधि लिएको भनेर राखेँ।")
    }

    private static func isYesResponse(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = ["yes", "yeah", "yep", "yup", "correct", "right",
                       "हो", "हजुर"]   // Nepali: ho, hajur
        return phrases.contains(where: { t.contains($0) })
    }

    private static func isNoResponse(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = ["no", "nope", "not", "wrong",
                       "छैन", "होइन"]   // Nepali: chhaina, hoina
        return phrases.contains(where: { t.contains($0) })
    }

    // MARK: - Helpers

    private func speak(_ text: String) {
        guard let speaker = speaker, !text.isEmpty else { return }
        let locale = replyLocale
        Task { await speaker.speak(text, locale: locale) }
    }

    private func postDebugNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
