import Foundation

// MARK: - Feed read state (feeds readaloud task, 2026-09-19)

/// Which feed items the elder has HEARD — the persisted half of
/// "mark as read when read aloud".
///
/// Only a reading marks an item read (the card's Read-aloud / Read-full-
/// article actions and the "read the full article" voice command, all
/// through the speaker's completion seam). Scrolling past or tapping
/// Translate does not: the read flag means "this was read to me", and a
/// weaker trigger would make the unread badge claim something untrue.
///
/// The ids are feed-item ids (guid/link/title + source name — see
/// `FeedItem.id`), so they survive a refresh while the source keeps
/// publishing the same item. Feed ITEMS themselves are still never
/// persisted (they are transient third-party content); the read flag is
/// the elder's own datum, and only that is stored.
struct FeedReadState: Codable, Equatable {
    /// Read item ids, OLDEST FIRST — the array order is the trim order
    /// (`maxTrackedIDs` drops from the front), so it is part of the
    /// format, not an accident of the Set.
    var readIDs: [String] = []

    static let empty = FeedReadState()
}

/// Encrypted persistence for the feed read state — constitution
/// §Security: what the elder has read is the elder's datum, stored in
/// `EncryptedLocalStorage` (Keychain, Data Protection Complete) exactly
/// like `FeedSettingsStore`'s configuration. Plaintext UserDefaults is
/// not the bar this app holds its other stores to.
///
/// Bounded on purpose: a feed produces new item ids every day, so an
/// unbounded set would grow forever. `maxTrackedIDs` keeps the most
/// recent ids and drops the oldest — for the badge's purpose (which of
/// the items on screen you have heard) a very old id is not worth the
/// unbounded growth, and the honest failure mode of a dropped id is a
/// badge that says "new" once more.
///
/// No content is ever logged or observed from here: the store's only
/// observable side effect is a `Result` the caller already handles.
final class FeedReadStateStore {

    static let storageKey = "feeds.read.v1"

    /// How many read ids are remembered, most recent first. Sized well
    /// above what one launch's feed can show (the composer caps the feed
    /// at 100 items), so the badge is right for anything on screen.
    static let maxTrackedIDs = 500

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored state; an absent or unreadable payload reads as EMPTY
    /// (nothing has been read yet) — never as a failure the feed would
    /// have to render, and never as "everything is read".
    func load() -> FeedReadState {
        guard case .success(let state) = storage.read(key: Self.storageKey,
                                                     type: FeedReadState.self) else {
            return .empty
        }
        return state
    }

    /// Marks `id` read and persists. Returns the new state, so the caller
    /// can publish it without a second read. Idempotent: an id already in
    /// the state is a no-op (and does not re-write the payload).
    @discardableResult
    func markRead(id: String) -> FeedReadState {
        var state = load()
        guard !id.isEmpty, !state.readIDs.contains(id) else { return state }
        state.readIDs.append(id)
        if state.readIDs.count > Self.maxTrackedIDs {
            state.readIDs.removeFirst(state.readIDs.count - Self.maxTrackedIDs)
        }
        return save(state)
    }

    /// Clears `id`'s read flag — the elder's "I want to hear that again
    /// as new" is not a shipped affordance today, but the state has the
    /// operation so a future one cannot be implemented by rewriting the
    /// payload by hand. Idempotent like `markRead`.
    @discardableResult
    func markUnread(id: String) -> FeedReadState {
        var state = load()
        guard state.readIDs.contains(id) else { return state }
        state.readIDs.removeAll { $0 == id }
        return save(state)
    }

    /// A write that fails still returns the state the caller asked for:
    /// the badge is honest for THIS launch, and the next successful write
    /// re-persists whatever exists (the `FeedSettingsStore` seed-write
    /// policy).
    private func save(_ state: FeedReadState) -> FeedReadState {
        _ = storage.write(key: Self.storageKey, value: state)
        return state
    }
}
