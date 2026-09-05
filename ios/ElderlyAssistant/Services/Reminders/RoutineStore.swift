import Foundation

/// Persistence facade for the Reminders domain: routine entries, the
/// scheduler's generated occurrences, and the first-run seed flag. Wraps
/// `EncryptedLocalStorage` exactly like `FamilyContactStore` does for
/// contacts (Keychain, Data Protection Complete — constitution
/// §Security); `RoutineScheduler` owns scheduling decisions, this type
/// owns bytes.
final class RoutineStore {

    private static let entriesKey = "routine.entries"
    private static let occurrencesKey = "routine.occurrences"
    /// Bump the suffix if the seeded defaults ever change shape so
    /// existing installs re-seed exactly once.
    private static let seededKey = "routine.seeded_v1"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: - Entries

    func loadEntries() -> [RoutineEntry] {
        guard case .success(let entries) = storage.read(
            key: Self.entriesKey, type: [RoutineEntry].self
        ) else { return [] }
        return entries
    }

    @discardableResult
    func saveEntries(_ entries: [RoutineEntry]) -> Bool {
        switch storage.write(key: Self.entriesKey, value: entries) {
        case .success: return true
        case .failure: return false
        }
    }

    @discardableResult
    func add(_ entry: RoutineEntry) -> Bool {
        var entries = loadEntries()
        entries.append(entry)
        return saveEntries(entries)
    }

    @discardableResult
    func update(_ entry: RoutineEntry) -> Bool {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        entries[index] = entry
        return saveEntries(entries)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        var entries = loadEntries()
        entries.removeAll { $0.id == id }
        return saveEntries(entries)
    }

    // MARK: - Occurrences (written by RoutineScheduler, persisted BEFORE alarms arm)

    func loadOccurrences() -> [RoutineOccurrence] {
        guard case .success(let occurrences) = storage.read(
            key: Self.occurrencesKey, type: [RoutineOccurrence].self
        ) else { return [] }
        return occurrences
    }

    @discardableResult
    func saveOccurrences(_ occurrences: [RoutineOccurrence]) -> Bool {
        switch storage.write(key: Self.occurrencesKey, value: occurrences) {
        case .success: return true
        case .failure: return false
        }
    }

    // MARK: - Seeding (v2 §4.1/§9 Phase 1)

    /// First-run defaults for the routine categories. Idempotent: a
    /// `true` seed flag short-circuits, so user edits (deletions,
    /// disables, added times) are never clobbered by a later launch.
    /// Returns true when this call actually seeded.
    @discardableResult
    func seedDefaultsIfNeeded() -> Bool {
        if case .success(let seeded) = storage.read(key: Self.seededKey, type: Bool.self), seeded {
            return false
        }
        guard saveEntries(Self.defaultEntries()) else { return false }
        _ = storage.write(key: Self.seededKey, value: true)
        return true
    }

    /// The brief's daily-routine categories start ON (morning + afternoon
    /// exercise, meals, walk, bedtime — design-v2-gemini-flash-lite.md
    /// lines 12–21); the occasional ones (gym, reading, call-a-relative)
    /// start OFF for the family to enable in the Reminders leaf. The
    /// spec's guidance runs "all reminders … native calendar" but is
    /// silent on defaults; enabling only the explicitly-daily asks keeps
    /// first-launch noise to what the brief literally lists.
    ///
    /// `.medication` is deliberately NOT seeded: medication entries live
    /// in `MedicationScheduler` (safety-critical), and a parallel
    /// medication routine would double-prompt doses.
    static func defaultEntries() -> [RoutineEntry] {
        func time(_ hour: Int, _ minute: Int = 0) -> DateComponents {
            DateComponents(hour: hour, minute: minute)
        }
        return [
            // "morning yoga and exercise" + "afternoon and evening
            // exercise reminder" — ×2/day.
            RoutineEntry(category: .exercise,
                         scheduleTimes: [time(7), time(16)],
                         isEnabled: true),
            // "meals and eating reminder".
            RoutineEntry(category: .meal,
                         scheduleTimes: [time(8), time(13), time(19)],
                         isEnabled: true),
            // "walk reminders".
            RoutineEntry(category: .walk,
                         scheduleTimes: [time(17, 30)],
                         isEnabled: true),
            // "bed time reminder".
            RoutineEntry(category: .bedtime,
                         scheduleTimes: [time(21, 30)],
                         isEnabled: true),
            // "gym reminders" — weekdays Mon/Wed/Fri, off by default.
            RoutineEntry(category: .gym,
                         scheduleTimes: [time(9)],
                         frequency: .weekly,
                         weekdays: [2, 4, 6],
                         isEnabled: false),
            // "book reading reminder", off by default.
            RoutineEntry(category: .reading,
                         scheduleTimes: [time(20, 15)],
                         isEnabled: false),
            // "reminder to make phone calls to relatives" — Sunday
            // evening, off by default.
            RoutineEntry(category: .callRelative,
                         scheduleTimes: [time(18)],
                         frequency: .weekly,
                         weekdays: [1],
                         isEnabled: false),
        ]
    }
}
