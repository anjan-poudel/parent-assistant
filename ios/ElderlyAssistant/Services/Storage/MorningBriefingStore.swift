import Foundation

/// The persisted copy of one morning-briefing composition (briefing
/// persistence task, 2026-09-08) — what `fire()` stored the day it spoke,
/// so the user can view (and re-hear) it later in the day.
///
/// Stored encrypted via `EncryptedLocalStorage` (Keychain, Data Protection
/// Complete — constitution §Security), exactly like `FamilyContactStore` /
/// `SavedPlaceStore`: the composed text embeds medication names, event
/// titles and routine titles, so plaintext UserDefaults is NOT acceptable.
struct StoredBriefing: Codable, Equatable {
    /// The calendar-day start this briefing belongs to (absolute
    /// instant). "Is this today's briefing?" is a day-membership check
    /// (`Calendar.isDate(_:inSameDayAs:)`), never instant equality — a
    /// stored day-start read back in a different timezone still belongs
    /// to its day.
    let dayStart: Date
    /// The locale identifier the text was composed in (e.g. "ne-NP",
    /// "en-US") — recorded so a later viewer knows the text's language
    /// without parsing it. The stored text is NEVER re-localized.
    let localeIdentifier: String
    /// The composed briefing, multi-line, exactly the text that was
    /// enqueued and spoken by `fire()`.
    let text: String

    /// The widget's glanceable one-liner: the first non-empty stored
    /// line AFTER the fixed greeting + date header (lines 0 and 1 are
    /// always the greeting and "Today is …" line, which would duplicate
    /// the Home top bar), so the capsule shows actual day content
    /// ("Your routines today: …" or, when nothing is scheduled,
    /// "You have nothing scheduled today"). Falls back to the first
    /// non-empty line for a briefing shorter than the header — never
    /// empty for any store payload (the composition always has ≥ 4
    /// lines; the fallback is defensive only).
    var previewLine: String {
        let lines = text.components(separatedBy: .newlines)
        let content = lines.dropFirst(2)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return content
            ?? lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? ""
    }
}

/// Single-slot persistence for the day's morning briefing (briefing
/// persistence task, 2026-09-08) — a `SavedPlaceStore`-style store over
/// `EncryptedLocalStorage`.
///
/// Slot semantics: writing always REPLACES. `fire()` composes at most
/// once per calendar day, and the app keeps only the current day's
/// briefing ("persistent for the day"), so the replacement of the
/// previous day's entry on the next fire IS the pruning — there is no
/// history and deliberately no read API that returns a stale day.
final class MorningBriefingStore {

    private static let storageKey = "morningBriefing.current"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored briefing, whatever day it belongs to — nil only when
    /// nothing has ever been stored (or the payload failed to decrypt).
    func load() -> StoredBriefing? {
        guard case .success(let briefing) = storage.read(
            key: Self.storageKey, type: StoredBriefing.self
        ) else { return nil }
        return briefing
    }

    /// Replaces the slot with `briefing` (a fresh day's composition
    /// overwrites whatever was there, pruning stale entries). False on
    /// storage failure — the caller still speaks; persistence is
    /// best-effort, never a reason to silence a briefing.
    @discardableResult
    func save(_ briefing: StoredBriefing) -> Bool {
        switch storage.write(key: Self.storageKey, value: briefing) {
        case .success: return true
        case .failure: return false
        }
    }

    /// Today's briefing, or nil when the stored entry belongs to a
    /// different calendar day (a previous day's briefing is not "today's
    /// briefing" — the widget/leaf presence must vanish at midnight,
    /// before the new day's composition exists).
    func todaysBriefing(now: Date, calendar: Calendar = .current) -> StoredBriefing? {
        guard let briefing = load(),
              calendar.isDate(briefing.dayStart, inSameDayAs: now) else {
            return nil
        }
        return briefing
    }
}
