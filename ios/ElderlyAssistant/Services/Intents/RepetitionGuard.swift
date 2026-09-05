import Foundation

/// Dementia-loop guard (spec 2026-09-05 §7.2): the same action confirmed
/// against the same target again within a short window gets a gentle
/// re-confirm ("भर्खरै माइयालाई फोन गर्नुभएको थियो। फेरि गर्ने?") instead
/// of blind-firing — repeated commands are a common dementia pattern, and
/// six FaceTime calls to the same person in ten minutes is a bad outcome
/// for BOTH ends of the call.
///
/// Deliberately NOT a blocker: the user may genuinely want to call back.
/// The guard only hardens the confirmation prompt; the yes/no still
/// decides.
final class RepetitionGuard {

    struct Record: Codable, Equatable {
        let actionKey: String
        let targetId: String
        let confirmedAt: Date
    }

    private static let storageKey = "intents.recentConfirmedActions"
    private static let maxRecords = 50

    private let storage: EncryptedLocalStorage
    private let windowSeconds: TimeInterval

    init(storage: EncryptedLocalStorage, windowSeconds: TimeInterval = 600) {
        self.storage = storage
        self.windowSeconds = windowSeconds
    }

    /// True when this action+target was already confirmed within the
    /// window — the caller strengthens its confirmation prompt.
    func isRepeat(actionKey: String, targetId: String, at date: Date = Date()) -> Bool {
        loadAll().contains {
            $0.actionKey == actionKey
                && $0.targetId == targetId
                && date.timeIntervalSince($0.confirmedAt) < windowSeconds
                && date >= $0.confirmedAt
        }
    }

    func record(actionKey: String, targetId: String, at date: Date = Date()) {
        var all = loadAll()
        all.append(Record(actionKey: actionKey, targetId: targetId, confirmedAt: date))
        if all.count > Self.maxRecords {
            all.sort { $0.confirmedAt > $1.confirmedAt }
            all = Array(all.prefix(Self.maxRecords))
        }
        _ = writeAll(all)
    }

    private func loadAll() -> [Record] {
        guard case .success(let records) = storage.read(
            key: Self.storageKey, type: [Record].self
        ) else { return [] }
        return records
    }

    private func writeAll(_ records: [Record]) -> Bool {
        switch storage.write(key: Self.storageKey, value: records) {
        case .success: return true
        case .failure: return false
        }
    }
}
