import Foundation

// MARK: - Free-form event side-index (rich-events task, 2026-09-17)

/// What the app remembers about a free-form event that EventKit cannot
/// hold itself.
///
/// A free-form event IS a native `EKEvent` in the default calendar
/// (design §1 decision 4, "approach A"): the title, the time, the
/// recurrence and the address all live in the event, where the Calendar
/// app and the family can see and edit them. This type exists for the
/// fields the platform has no place for — an attached photo and, since
/// the reminders/instructions feature, at most one instruction.
/// `EKEvent` has no attachment API at all, and writing a file path into
/// `notes` would put machine text in front of the family in the
/// Calendar app; so both live here, beside the event, keyed by the
/// event's `eventIdentifier`.
///
/// Presence in this map is ALSO the app's "this is one of our free-form
/// events" marker: the Events list shows exactly these, the form edits
/// exactly these, and the Google reconcile walks exactly these. An
/// event with no photo is still tracked (with `photoFilename == nil`),
/// which is why the payload is a struct and not a bare filename — the
/// distinction between "tracked, no photo" and "not ours" has to be
/// expressible.
///
/// **Never rebuild this value from one field.** Every writer mutates the
/// existing row and sets only its own field (design §4.5, P-4): a
/// wholesale `EventExtras(photoFilename:)` rebuild is the bug class
/// R-11 records — it silently erases every field it does not name, and
/// the erase is invisible until the family changes a photo and loses an
/// instruction.
struct EventExtras: Codable, Equatable {
    /// `<uuid>.jpg` — a bare file name under the event photo store's
    /// directory, exactly the split `FamilyContact.photoFilename` uses.
    /// Never a path, never image bytes: the encrypted payload stays
    /// small and the JPEG keeps its own file protection.
    var photoFilename: String?

    /// Zero or one instruction for this event (FR-RIE-001, design L2
    /// §2.12, §4.5). The kind's media file lives in the instruction
    /// video store; this row carries only the wire model.
    var instruction: Instruction? = nil

    init(photoFilename: String? = nil, instruction: Instruction? = nil) {
        self.photoFilename = photoFilename
        self.instruction = instruction
    }

    /// Tolerant decode in the house style (`LocalGoogleEventMappingStore`,
    /// `RoutineEntry.visualAids`): a payload written before a field
    /// existed must not throw `keyNotFound` and take the whole index
    /// with it. An unreadable index costs the list, which is worse than
    /// a missing photo.
    ///
    /// The instruction is wrapped in `try?` (design §4.6, IF-26): a
    /// malformed nested value — `"instruction": "oops"`, or any object
    /// this build cannot decode — costs the INSTRUCTION, never the row.
    /// A missing key and an explicit `null` both decode to nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photoFilename = try container.decodeIfPresent(String.self,
                                                      forKey: .photoFilename)
        instruction = try? container.decodeIfPresent(Instruction.self,
                                                     forKey: .instruction)
    }
}

/// Persistent `native event id → EventExtras` index for free-form events
/// (design §2, "EventExtrasStore (encrypted, EncryptedLocalStorage)
/// side-index").
///
/// Storage is the ENCRYPTED store, not `UserDefaults`, and the
/// difference from `ExternalEventLinkStore` is the reason: that map
/// links a routine slot to an opaque calendar handle and carries no
/// information about the household, while a photo file name here
/// belongs to an event whose title is a doctor's appointment — the same
/// reasoning that put the Google share ledger in encrypted storage.
///
/// Both halves live in ONE payload (`EncryptedLocalStorage` has no key
/// enumeration, so an index spread over per-event keys would be
/// unfindable after a relaunch — the rule `FamilyContactStore` and the
/// share queue follow).
final class EventExtrasStore {

    /// The whole index under one key.
    private static let storageKey = "eventExtras.byEventId"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The legacy tolerant read: the whole index, and `[:]` when nothing
    /// is tracked yet or the payload could not be read. That collapse is
    /// intentional for list callers — an unreadable payload reads as "no
    /// free-form events", the same state a fresh install is in — but it
    /// must NEVER build a live set: a sweep fed by `all` would see an
    /// empty set during a transient read failure. `snapshot()` (IF-27)
    /// is the strict read for that job (design §5.9, §11.3 K).
    var all: [String: EventExtras] {
        guard case .success(let stored) = storage.read(
            key: Self.storageKey, type: [String: EventExtras].self
        ) else { return [:] }
        return stored
    }

    /// Every tracked native event id — the Events list's fetch set and
    /// the Google reconcile's walk set, in one place so the two can
    /// never disagree about what "our events" means.
    var eventIds: Set<String> { Set(all.keys) }

    var count: Int { all.count }
    var isEmpty: Bool { all.isEmpty }

    func extras(forEventId eventId: String) -> EventExtras? { all[eventId] }

    /// IF-27. The strict read the instruction orphan sweep needs: `nil`
    /// on ANY `storage.read` failure, and the decoded index otherwise —
    /// including an empty dictionary when the payload is readable but
    /// carries no rows.
    ///
    /// `EncryptedLocalStorage` reports a missing key as a read failure,
    /// so a first run or an absent key also yields nil. That is the safe
    /// direction, and the whole point of the distinction (P-6): an
    /// unreadable index means "unknown" and skips the events root of the
    /// sweep, while a readable empty index means "no event instructions"
    /// and may collect. `all` and `eventIds` keep their empty-on-failure
    /// convenience and are never used to build a live set (design §5.9,
    /// §11.3 K).
    func snapshot() -> [String: EventExtras]? {
        guard case .success(let stored) = storage.read(
            key: Self.storageKey, type: [String: EventExtras].self
        ) else { return nil }
        return stored
    }

    var photoFilename: (String) -> String? {
        { [all] eventId in all[eventId]?.photoFilename }
    }

    /// Marks `eventId` as one of ours, keeping every field already
    /// recorded (photo and instruction). Idempotent, so the form's save
    /// path can call it on every save without special-casing the first.
    @discardableResult
    func track(eventId: String) -> Bool {
        setExtras(extras(forEventId: eventId) ?? EventExtras(), forEventId: eventId)
    }

    /// Records (or clears, with nil) the event's photo file name. Also
    /// tracks the event — an extras row with a photo but no tracking
    /// would be a contradiction.
    ///
    /// Mutates the row already on disk instead of rebuilding it (P-4,
    /// design §4.5): the shipping wholesale `EventExtras(photoFilename:)`
    /// construction erased every field it did not name, so a photo edit
    /// would have silently dropped the event's instruction. Setting only
    /// `photoFilename` on the existing row is the whole fix; it also
    /// protects any field added later (R-11).
    @discardableResult
    func setPhotoFilename(_ filename: String?, forEventId eventId: String) -> Bool {
        var next = all
        var extras = next[eventId] ?? EventExtras()
        extras.photoFilename = filename
        next[eventId] = extras
        return write(next)
    }

    /// IF-26. Records (or clears, with nil) the event's instruction,
    /// keeping the photo the row already carries.
    ///
    /// **OI-1 — a deliberate, recorded exception to the typed-error
    /// rule.** This returns the store's shipping `Bool` convention rather
    /// than `Result`; the free-form event service (IF-24) translates
    /// `false` to `InstructionWriteError.persistenceFailed` before any
    /// caller sees it, so the explicit-error-type contract is satisfied
    /// at the boundary that matters (design §1.3, §3.1, IF-26; m-2).
    ///
    /// A MISSING row is `false` AND writes nothing. `setInstruction` does
    /// not upsert: the service resolves the event owner first, so "no row
    /// here" means the event is no longer ours, and resurrecting it with
    /// a bare instruction row would recreate a deleted event's side
    /// index (T-014 scenario 4). A failed read of the index yields the
    /// same `false` and leaves the payload untouched.
    @discardableResult
    func setInstruction(_ instruction: Instruction?, forEventId eventId: String) -> Bool {
        var next = all
        guard var extras = next[eventId] else { return false }
        extras.instruction = instruction
        next[eventId] = extras
        return write(next)
    }

    @discardableResult
    func setExtras(_ extras: EventExtras, forEventId eventId: String) -> Bool {
        var next = all
        next[eventId] = extras
        return write(next)
    }

    /// Forgets the event entirely — the delete path, and the reconcile's
    /// response to an event the family deleted in the Calendar app.
    ///
    /// Returns the extras it dropped so the CALLER can delete the media
    /// FILES (the photo and the instruction's video): this store owns the
    /// index, the photo and video stores own the bytes, and the same
    /// split `FamilyContactStore`/`ContactPhotoStore` use keeps each
    /// one's cleanup honest. This store never deletes a file itself; the
    /// event service transaction (T-015) and the orphan sweep (T-025)
    /// own that work. nil when the event was not tracked (nothing to
    /// clean up).
    @discardableResult
    func remove(eventId: String) -> EventExtras? {
        var next = all
        guard let dropped = next.removeValue(forKey: eventId) else { return nil }
        _ = write(next)
        return dropped
    }

    private func write(_ next: [String: EventExtras]) -> Bool {
        if case .success = storage.write(key: Self.storageKey, value: next) {
            return true
        }
        return false
    }
}
