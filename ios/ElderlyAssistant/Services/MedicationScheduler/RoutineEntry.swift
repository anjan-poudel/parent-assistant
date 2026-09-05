import Foundation

// MARK: - Unified routine/reminder model (v2 design §4.1, 2026-09-06)
//
// Fully ADDITIVE generalization of the medication-only reminder system:
// `MedicationEntry` and the entire `MedicationScheduler` safety-critical
// path (ack/escalation/re-fire, 100% coverage) are byte-for-byte
// untouched. A routine IS a `MedicationEntry` under the hood (its
// `medicationName` carries the routine title — the same pattern the
// voice `set_reminder` flow already uses) plus a category tag stored
// alongside, so the same scheduler/escalation engine drives all nine
// brief categories with zero new safety surface.

enum RoutineCategory: String, Codable, CaseIterable, Identifiable {
    case medication
    case exercise
    case meal
    case walk
    case gym
    case bedtime
    case reading
    case callRelative
    case custom

    var id: String { rawValue }

    /// Catalog key for the localized display name.
    var labelKey: String { "routine.category.\(rawValue)" }

    /// SF Symbol for list surfaces (Reminders/Settings).
    var systemImage: String {
        switch self {
        case .medication: return "pills.fill"
        case .exercise: return "figure.yoga"
        case .meal: return "fork.knife"
        case .walk: return "figure.walk"
        case .gym: return "dumbbell.fill"
        case .bedtime: return "bed.double.fill"
        case .reading: return "book.fill"
        case .callRelative: return "phone.fill"
        case .custom: return "star.fill"
        }
    }
}

/// Category tag for one schedule entry, keyed by the entry's UUID.
/// Entries with no tag are `.medication` (the pre-generalization
/// universe — nothing about existing data changes meaning).
struct RoutineTag: Codable, Equatable {
    let entryId: UUID
    let category: RoutineCategory
}

/// Owns the entryId → category mapping, persisted in the same
/// `EncryptedLocalStorage` the scheduler already uses. Deliberately
/// separate from `MedicationScheduler` so the safety-critical class
/// gains no new responsibilities.
final class RoutineTagStore {

    private let storage: EncryptedLocalStorage
    private let storageKey = "routine.tags"

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    func category(for entryId: UUID) -> RoutineCategory {
        loadAll().first { $0.entryId == entryId }?.category ?? .medication
    }

    func setCategory(_ category: RoutineCategory, for entryId: UUID) {
        var all = loadAll()
        all.removeAll { $0.entryId == entryId }
        all.append(RoutineTag(entryId: entryId, category: category))
        _ = storage.write(key: storageKey, value: all)
    }

    func removeCategory(for entryId: UUID) {
        var all = loadAll()
        all.removeAll { $0.entryId == entryId }
        _ = storage.write(key: storageKey, value: all)
    }

    /// Drops tags whose entries no longer exist (called after schedule
    /// edits so the tag store can't accumulate orphans).
    func prune(keepingEntryIds: Set<UUID>) {
        var all = loadAll()
        all.removeAll { !keepingEntryIds.contains($0.entryId) }
        _ = storage.write(key: storageKey, value: all)
    }

    private func loadAll() -> [RoutineTag] {
        guard case .success(let tags) = storage.read(key: storageKey, type: [RoutineTag].self) else {
            return []
        }
        return tags
    }
}
