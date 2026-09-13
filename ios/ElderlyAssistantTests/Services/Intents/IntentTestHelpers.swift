import Foundation
import SwiftUI
@testable import ElderlyAssistant

/// Shared in-memory `EncryptedLocalStorage` for intent-layer tests — the
/// real implementation is Keychain-backed and untestable without a device
/// context. (Sibling of the private double in FamilyContactStoreTests;
/// this one is internal so every Intents test file can use it.)
final class StubEncryptedStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}

/// Convenience builders so tests read at the intent level, not the
/// plumbing level.
func makeCommand(action: InterpretedCommand.Action,
                 contact: String? = nil,
                 confidence: Double = 0.9,
                 callType: String? = nil,
                 requestedApp: String? = nil,
                 reply: String = "ठीक छ",
                 time: String? = nil,
                 topic: String? = nil) -> InterpretedCommand {
    InterpretedCommand(action: action,
                       entryId: nil,
                       contact: contact,
                       time: time,
                       medication: nil,
                       message: nil,
                       callType: callType,
                       requestedApp: requestedApp,
                       topic: topic,
                       steps: nil,
                       confidence: confidence,
                       reply: reply)
}

/// A scripted `CommandInterpreter` — returns `nextResult`, records what
/// it was asked.
final class StubCommandInterpreter: CommandInterpreter {
    var nextResult: InterpretedCommand?
    var available: Bool
    private(set) var callCount = 0
    private(set) var lastTranscript: String?

    init(available: Bool = true, result: InterpretedCommand? = nil) {
        self.available = available
        self.nextResult = result
    }

    var isAvailable: Bool { available }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        callCount += 1
        lastTranscript = transcript
        DispatchQueue.main.async { completion(self.nextResult) }
    }
}

/// Minimal `ObservabilityBus` sink — events are asserted on nowhere, but
/// the components require one.
final class NullObservabilityBus: ObservabilityBus {
    func emit(_ event: ObservabilityEvent) {}
}

/// Observability bus that records event types — the observable signal for
/// routing decisions whose side effects (speech, notifications) are
/// no-ops under a nil speaker in tests. [LAT-M3] `events` additionally
/// records the FULL events (including metadata), so the
/// `interpreter_selected` reason/interpreter pairs can be asserted.
final class RecordingObservabilityBus: ObservabilityBus {
    private(set) var eventTypes: [String] = []
    private(set) var events: [ObservabilityEvent] = []
    func emit(_ event: ObservabilityEvent) {
        eventTypes.append(event.eventType)
        events.append(event)
    }
    func contains(_ eventType: String) -> Bool { eventTypes.contains(eventType) }
    func events(named eventType: String) -> [ObservabilityEvent] {
        events.filter { $0.eventType == eventType }
    }
}

/// Minimal `VoiceCommandCoordinating` — every method a no-op with
/// recording, except the few the safety-net tests script explicitly.
final class StubCoordinator: VoiceCommandCoordinating {
    var manualAwaitingConfirmation = false
    var isAwaitingConfirmation: Bool {
        manualAwaitingConfirmation || rephrasePended != nil
    }
    /// Defaults to `.available` so tests that don't script the brain
    /// state keep the router's historical behavior (generic re-prompt);
    /// the availability-matrix tests set it explicitly.
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale = Locale(identifier: "ne-NP")

    var pendingEntryId: UUID?
    var challengePrompt: String? = "औषधि खानुभयो?"
    private(set) var challengeIssuedFor: UUID?
    private(set) var genericReplies: [String] = []

    func recordTranscript(_ text: String) {}
    func oldestPendingReminderEntryId() -> UUID? { pendingEntryId }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? {
        challengeIssuedFor = entryId
        return challengePrompt
    }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) {}
    func noteGenericReply(_ text: String) { genericReplies.append(text) }
    func addVoiceReminder(title: String, time: DateComponents) {}
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? {
        nil
    }
    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
    var composeMessageOutcome: MessageComposeOutcome = .contactNotFound
    private(set) var composeMessageRequests: [(contact: String?, body: String, requestedApp: String?)] = []
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome {
        composeMessageRequests.append((name, body, requestedApp))
        return composeMessageOutcome
    }
    func presentPluginView(_ view: AnyView) {}

    /// voice-contact-search (2026-09-07): recorder for the keyword
    /// pre-route's coordinator call.
    private(set) var contactSearchRequests: [String?] = []
    func requestContactSearch(query: String?) {
        contactSearchRequests.append(query)
    }

    var pendingRephraseCommand: InterpretedCommand? { rephrasePended?.command }
    private(set) var rephrasePended: (command: InterpretedCommand, sourceTranscript: String?)?
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? {
        let taken = rephrasePended
        rephrasePended = nil
        return taken
    }

    /// [CALENDAR-EVENTS] (2026-09-13) Recorder for the real
    /// `create_calendar_event` executor. The router validates and
    /// RESOLVES the start instant, then hands (title, startDate) over —
    /// so these two fields are what the tests assert on, and the
    /// returned prompt is what the router must speak verbatim.
    /// `nil` models the "cannot write right now" coordinator (denied
    /// access), which must reach the router's honest unavailable line.
    var calendarEventPrompt: String? = "पात्रोमा राखूँ?"
    private(set) var calendarEventRequests: [(title: String, startDate: Date)] = []
    func requestCalendarEventConfirmation(title: String, startDate: Date) -> String? {
        calendarEventRequests.append((title, startDate))
        return calendarEventPrompt
    }

    /// [CALENDAR-EVENTS] (2026-09-13) Router-side gate for the yes/no
    /// exemption — true only when a test is deliberately standing in for
    /// a coordinator with an event pended.
    var isAwaitingCalendarEventConfirmation = false
}

// MARK: - Caregiver notify settings (test seam)

extension CaregiverNotifySettings {
    /// Settings backed by a THROWAWAY `UserDefaults` suite — isolated
    /// from the process-wide standard defaults and from every other test
    /// (a shared suite would leak a flipped toggle across tests, which is
    /// exactly the kind of order-dependence the settings' persistence
    /// makes possible).
    static func isolated(medication: Bool = false,
                         routine: Bool = false,
                         calendar: Bool = false) -> CaregiverNotifySettings {
        let suiteName = "caregiverNotify.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        let settings = CaregiverNotifySettings(defaults: suite)
        settings.medicationReminders = medication
        settings.routineReminders = routine
        settings.calendarEvents = calendar
        return settings
    }
}
