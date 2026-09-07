import Foundation

/// One call or message the ASSISTANT initiated (call-history task,
/// 2026-09-06).
///
/// The app logs ONLY what it itself did through the channel vocabulary
/// below — never the system call log and never other apps' messages (iOS
/// platform wall: no API exposes another app's call/message history to an
/// app, and the app must never fake knowing one). A row is a fact about a
/// channel the user asked the assistant to open, not about the person on
/// the other end. Live-call detection (CXCallObserver) is deliberately
/// NOT recorded here either — the observer reveals presence only, no
/// identity, and nothing from it may be stored.
struct AppActivityEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date

    /// What the assistant did on the channel.
    enum Kind: String, Codable {
        /// A genuine call was opened (phone dialer, FaceTime) — or, for
        /// Messenger, the chat/thread a call request resolves to. The app
        /// never claims an actual Messenger "call": no documented scheme
        /// can start one, so the honest record is the thread that opened.
        case call
        /// A chat/message surface was opened or a message drafted.
        case message
    }

    /// Which surface the assistant opened.
    enum Channel: String, Codable {
        case phone            // GSM dialer (tel:)
        case faceTimeVideo
        case faceTimeAudio
        case whatsapp         // wa.me / whatsapp:// chat open (WhatsApp
                              // calls have no deep link — a "call"
                              // request is always a chat open and is
                              // recorded as `.message`, never claimed as
                              // a call)
        case messenger
        case sms              // native Messages compose sheet
    }

    let kind: Kind
    let channel: Channel
    var contactName: String
    /// The number stored with the row. Empty for Messenger rows opened
    /// from a handle (the messenger API carries no phone number).
    var phone: String
    /// Set for Messenger rows — the handle is what re-opening needs.
    var messengerHandle: String?
    /// Drafted/ready message text, when the assistant pre-filled any
    /// (SMS drafts and WhatsApp text). Nil otherwise.
    var body: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind,
         channel: Channel, contactName: String, phone: String,
         messengerHandle: String? = nil, body: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.channel = channel
        self.contactName = contactName
        self.phone = phone
        self.messengerHandle = messengerHandle
        self.body = body
    }
}

/// The assistant's own call/message history (call-history task,
/// 2026-09-06) — the Recent activity leaf's store.
///
/// Append-only in spirit (rows are never edited or deleted by the app),
/// newest-first on read, capped at `maxEntries` by dropping the OLDEST
/// rows. One JSON array under `storageKey`, written through
/// `EncryptedLocalStorage` (Keychain, Data Protection Complete —
/// constitution §Security), following the `ChatHistoryStore` house
/// pattern: lazy load guarded by `didLoadFromDisk`, write-through on
/// append, missing/corrupt payloads read as empty (never a crash) and
/// recover on the next write.
///
/// Thread confinement: main queue by contract — every call site is a
/// coordinator method on the main queue (same rule as ChatHistoryStore
/// and CallRecencyStore).
final class AppActivityLog {

    static let maxEntries = 100
    static let storageKey = "app.activity.log"

    private let storage: EncryptedLocalStorage
    private var all: [AppActivityEntry] = []
    private var didLoadFromDisk = false

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    private func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        // Missing key or corrupt payload → empty history, never a crash
        // (the same tolerance every other store in the app has).
        guard case .success(let stored) = storage.read(
            key: Self.storageKey, type: [AppActivityEntry].self
        ) else { return }
        all = Self.pruned(stored)
    }

    /// Appends `entry` and persists immediately (write-through).
    func append(_ entry: AppActivityEntry) {
        loadFromDiskIfNeeded()
        all.append(entry)
        all = Self.pruned(all)
        _ = storage.write(key: Self.storageKey, value: all)
    }

    /// All entries, newest first.
    func entries() -> [AppActivityEntry] {
        loadFromDiskIfNeeded()
        return all.reversed()
    }

    /// Keeps only the newest `maxEntries`, dropping the oldest (the same
    /// direction the append trim drops from — a payload that somehow
    /// exceeds the cap on disk loads trimmed, never a crash).
    private static func pruned(_ entries: [AppActivityEntry]) -> [AppActivityEntry] {
        guard entries.count > maxEntries else { return entries }
        return Array(entries.suffix(maxEntries))
    }
}
