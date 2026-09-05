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
                 reply: String = "ठीक छ") -> InterpretedCommand {
    InterpretedCommand(action: action,
                       entryId: nil,
                       contact: contact,
                       time: nil,
                       medication: nil,
                       message: nil,
                       callType: callType,
                       requestedApp: requestedApp,
                       topic: nil,
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
/// no-ops under a nil speaker in tests.
final class RecordingObservabilityBus: ObservabilityBus {
    private(set) var eventTypes: [String] = []
    func emit(_ event: ObservabilityEvent) { eventTypes.append(event.eventType) }
    func contains(_ eventType: String) -> Bool { eventTypes.contains(eventType) }
}

/// Minimal `VoiceCommandCoordinating` — every method a no-op with
/// recording, except the few the safety-net tests script explicitly.
final class StubCoordinator: VoiceCommandCoordinating {
    var isAwaitingConfirmation = false
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
    func composeMessage(toContactNamed name: String?, body: String) -> Bool { false }
    func presentPluginView(_ view: AnyView) {}
}
