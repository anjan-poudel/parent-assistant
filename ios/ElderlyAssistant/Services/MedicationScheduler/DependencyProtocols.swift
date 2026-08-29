import Foundation

// MARK: - Protocol stubs for dependencies (T-002, T-004)

enum StorageError: Error {
    case encryptedWriteFailed
    case encryptedReadFailed
}

enum SafetyError: Error {
    case healthPermissionRevoked
    case emergencyCallFailed(reason: String)
    case reminderPersistenceFailed
    case familyNotificationFailed(reason: String)
}

protocol EncryptedLocalStorage {
    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError>
    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError>
    func delete(key: String) -> Result<Void, StorageError>
}

protocol ObservabilityBus {
    func emit(_ event: ObservabilityEvent)
}

struct ObservabilityEvent {
    let component: String
    let eventType: String
    let durationMs: Int?
    let outcome: String
    let errorCode: String?
    let metadata: [String: String]
}
