import Foundation
import Security

/// EncryptedLocalStorage backed by the iOS Keychain, with the
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` accessibility class
/// (Data Protection class Complete for keychain items). Items are:
///
///  - encrypted at rest by the Secure Enclave-derived class key,
///  - available only while the device is unlocked,
///  - not migrated to a new device via iCloud/iTunes backup.
///
/// Values are round-tripped through `JSONEncoder`/`JSONDecoder`, so any
/// `Codable` payload works. Constitution §Security requires Data Protection
/// Complete for encrypted app storage — this file is that implementation.
final class KeychainEncryptedStorage: EncryptedLocalStorage {

    private let service: String
    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(service: String = "com.elderlyassistant.storage",
         accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            return .failure(.encryptedWriteFailed)
        }

        var query = baseQuery(for: key)
        // Try update first; on ENOENT, add.
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return .success(())
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess ? .success(()) : .failure(.encryptedWriteFailed)
        default:
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            return .failure(.encryptedReadFailed)
        }
        do {
            let value = try decoder.decode(type, from: data)
            return .success(value)
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        // Deleting a missing item is not an error.
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(())
        }
        return .failure(.encryptedWriteFailed)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Bind to this device; do not sync via iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
