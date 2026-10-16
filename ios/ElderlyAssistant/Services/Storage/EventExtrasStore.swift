import Foundation

// MARK: - Free-form event side-index (rich-events task, 2026-09-17)

/// What the app remembers about a free-form event that EventKit cannot
/// hold itself.
///
/// A free-form event IS a native `EKEvent` in the default calendar
/// (design §1 decision 4, "approach A"): the title, the time, the
/// recurrence and the address all live in the event, where the Calendar
/// app and the family can see and edit them. This type exists for the
/// ONE field the platform has no place for — an attached photo.
/// `EKEvent` has no attachment API at all, and writing a file path into
/// `notes` would put machine text in front of the family in the
/// Calendar app; so the photo lives here, beside the event, keyed by the
/// event's `eventIdentifier`.
///
/// Presence in this map is ALSO the app's "this is one of our free-form
/// events" marker: the Events list shows exactly these, the form edits
/// exactly these, and the Google reconcile walks exactly these. An
/// event with no photo is still tracked (with `photoFilename == nil`),
/// which is why the payload is a struct and not a bare filename — the
/// distinction between "tracked, no photo" and "not ours" has to be
/// expressible.
struct EventExtras: Codable, Equatable {
    /// `<uuid>.jpg` — a bare file name under the event photo store's
    /// directory, exactly the split `FamilyContact.photoFilename` uses.
    /// Never a path, never image bytes: the encrypted payload stays
    /// small and the JPEG keeps its own file protection.
    var photoFilename: String?

    init(photoFilename: String? = nil) {
        self.photoFilename = photoFilename
    }

    /// Tolerant decode in the house style (`LocalGoogleEventMappingStore`,
    /// `RoutineEntry.visualAids`): a payload written before a field
    /// existed must not throw `keyNotFound` and take the whole index
    /// with it. An unreadable index costs the list, which is worse than
    /// a missing photo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photoFilename = try container.decodeIfPresent(String.self,
                                                      forKey: .photoFilename)
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

    /// The whole index. Empty when nothing is tracked yet or the payload
    /// could not be read — an unreadable payload reads as "no free-form
    /// events", which is the same state a fresh install is in and costs
    /// nothing but an empty list.
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

    var photoFilename: (String) -> String? {
        { [all] eventId in all[eventId]?.photoFilename }
    }

    /// Marks `eventId` as one of ours, keeping any photo already
    /// recorded. Idempotent, so the form's save path can call it on
    /// every save without special-casing the first.
    @discardableResult
    func track(eventId: String) -> Bool {
        setExtras(extras(forEventId: eventId) ?? EventExtras(), forEventId: eventId)
    }

    /// Records (or clears, with nil) the event's photo file name. Also
    /// tracks the event — an extras row with a photo but no tracking
    /// would be a contradiction.
    @discardableResult
    func setPhotoFilename(_ filename: String?, forEventId eventId: String) -> Bool {
        setExtras(EventExtras(photoFilename: filename), forEventId: eventId)
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
    /// Returns the extras it dropped so the CALLER can delete the photo
    /// FILE: this store owns the index, the photo store owns the bytes,
    /// and the same split `FamilyContactStore`/`ContactPhotoStore` use
    /// keeps each one's cleanup honest. nil when the event was not
    /// tracked (nothing to clean up).
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
