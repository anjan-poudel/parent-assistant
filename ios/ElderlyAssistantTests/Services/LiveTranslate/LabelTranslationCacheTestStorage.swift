import Foundation
@testable import ElderlyAssistant

/// The storage the cache tests drive: a byte-level double conforming to BOTH
/// `EncryptedLocalStorage` and `RawEncryptedStorage`.
///
/// It exists because the two questions the cache has to answer are different
/// ones: "what does the protocol return" (a value, or a failure) and "what is
/// actually on the channel" (bytes, or nothing). A double that could only
/// answer the first would make an absent payload and an unreadable one
/// indistinguishable to the test — which is exactly the distinction the
/// self-healing path turns on.
///
/// Deliberately NOT a stand-in for the real store's protection: the shipped
/// `EncryptedFileStorage` is exercised against a real directory in
/// `LabelTranslationCacheTests`' on-disk check.
final class LabelTranslationCacheTestStorage: EncryptedLocalStorage, RawEncryptedStorage {

    private(set) var raw: [String: Data] = [:]
    private(set) var readCount = 0
    private(set) var deleteCount = 0
    private(set) var writtenKeys: [String] = []
    /// Every write, in order, per key — the touch-coalescing bound is a
    /// statement about this.
    private(set) var writeCountByKey: [String: Int] = [:]

    /// When true every write reports a failure, so the "a write failure never
    /// breaks the feature" path is reachable.
    var failsWrites = false
    /// When true every read reports a failure, whatever the bytes say.
    var failsReads = false
    /// When true every delete reports a failure **and leaves the bytes in
    /// place** — the store that could not remove the record (T-014/AM-4).
    var failsDeletes = false
    /// When true a delete reports success and keeps the bytes. Deliberately
    /// separate from `failsDeletes`: this is the store whose delete *lies*,
    /// which is the case a read-back verification exists to catch.
    var keepsBytesAfterDelete = false

    var writeCount: Int { writtenKeys.count }

    func writeCount(forKey key: String) -> Int { writeCountByKey[key] ?? 0 }

    func setRaw(_ data: Data, forKey key: String) {
        raw[key] = data
    }

    func bytes(forKey key: String) -> Data? { raw[key] }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writtenKeys.append(key)
        writeCountByKey[key, default: 0] += 1
        guard !failsWrites else { return .failure(.encryptedWriteFailed) }
        do {
            raw[key] = try JSONEncoder().encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        readCount += 1
        guard !failsReads else { return .failure(.encryptedReadFailed) }
        guard let data = raw[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        deleteCount += 1
        guard !failsDeletes else { return .failure(.encryptedWriteFailed) }
        guard !keepsBytesAfterDelete else { return .success(()) }
        raw.removeValue(forKey: key)
        return .success(())
    }

    // MARK: - RawEncryptedStorage

    func readRawData(key: String) -> Data? { raw[key] }

    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
        writtenKeys.append(key)
        writeCountByKey[key, default: 0] += 1
        guard !failsWrites else { return .failure(.encryptedWriteFailed) }
        raw[key] = data
        return .success(())
    }
}
