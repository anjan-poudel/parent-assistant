import Foundation

/// One call or message the ASSISTANT initiated (call-history task,
/// 2026-09-06) — plus ONE anonymous exception, the unanswered-call event
/// (missed-calls task, 2026-09-07).
///
/// The app logs ONLY what it itself did through the channel vocabulary
/// below — never the system call log and never other apps' messages (iOS
/// platform wall: no API exposes another app's call/message history to an
/// app, and the app must never fake knowing one). A row is a fact about a
/// channel the user asked the assistant to open, not about the person on
/// the other end. The single exception is `Channel.unanswered`: live-call
/// detection (CXCallObserver) observed a call END without ever
/// connecting, and the row records that presence-only fact — no name, no
/// number, no identity (iOS masks all three for calls that involve other
/// apps; see the channel's docs). Nothing else from the observer is ever
/// stored.
struct AppActivityEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date

    /// What the assistant did on the channel.
    enum Kind: String, Codable {
        /// A genuine call was opened (phone dialer, FaceTime) — or, for
        /// Messenger, the chat/thread a call request resolves to. The app
        /// never claims an actual Messenger "call": no documented scheme
        /// can start one, so the honest record is the thread that opened.
        /// Also the kind of an unanswered-call row (`.channel ==
        /// .unanswered`) — a call event that came to the USER rather than
        /// one the assistant opened.
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
        /// ANONYMOUS unanswered call (missed-calls task, 2026-09-07):
        /// live-call detection saw a call end without ever connecting —
        /// a missed or declined incoming call, or an attempted outgoing
        /// call nobody picked up (iOS reports these indistinguishably).
        /// iOS masks the identity AND the number of calls that involve
        /// other apps, so this row normally stores an EMPTY
        /// `contactName` and EMPTY `phone` — there is no name to store,
        /// no number to look up, and no address-book match possible. The
        /// UI renders the localized "Unanswered call" label
        /// (`history.unanswered`) instead of a stored locale string, and
        /// the row's action opens the Phone app (Recents is one tab
        /// away) — the only surface where the caller's identity
        /// genuinely lives.
        ///
        /// ONE attributed exception (call-tracking task, 2026-09-13): the
        /// app's own opens are matched to the unanswered event by time
        /// (`OpenedCallAttributor`), so a row for a call the APP placed
        /// that was never picked up carries the contact the app itself
        /// dialed. The mask argument does not apply there — the app
        /// already knew who it called, and the observer's ended-
        /// unconnected event is the outcome of that dial. Nothing else
        /// is ever filled in: an unattributed event stays anonymous.
        case unanswered
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
/// 2026-09-06) — the Recent activity leaf's store. Also holds the one
/// exception described on `AppActivityEntry` — the unanswered-call row
/// (missed-calls task, 2026-09-07), appended by the coordinator when
/// live-call detection observes a call ending without ever connecting;
/// anonymous unless the app itself placed the call that went unanswered
/// (call-tracking task, 2026-09-13).
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

    /// How long a missed call stays "the last missed call" on the Home
    /// activity tile (call-tracking task, 2026-09-13): a sliding day.
    /// Long enough that a call missed last evening is still there in the
    /// morning, short enough that yesterday's news never reads as
    /// current — the same staleness rule the Home briefing panel holds
    /// (it hides after its day, `TodayBriefingWidget`).
    static let missedCallWindow: TimeInterval = 24 * 60 * 60

    /// The newest missed call within `window` of `now`, or nil — the Home
    /// tile's lookup (call-tracking task, 2026-09-13). Reads the SAME
    /// entries the Recent-activity leaf renders (`entries()`, newest
    /// first); a missed call is a row on `Channel.unanswered`, whether
    /// anonymous or attributed to a call the app placed.
    ///
    /// Pure past-relative like `HistoryTimeFormat`: `now` is injected and
    /// the clock is never read here, so the tests pin it. Future-stamped
    /// rows are not excluded (the app records with `Date()`; a backwards
    /// clock step must not blank the tile) — the newest row still wins.
    func lastMissedCall(now: Date = Date(),
                        within window: TimeInterval = AppActivityLog.missedCallWindow) -> AppActivityEntry? {
        Self.lastMissedCall(in: entries(), now: now, within: window)
    }

    /// The pure form of the lookup above — any ordering in, newest missed
    /// call within the window out.
    static func lastMissedCall(in entries: [AppActivityEntry],
                               now: Date,
                               within window: TimeInterval = AppActivityLog.missedCallWindow) -> AppActivityEntry? {
        let cutoff = now.addingTimeInterval(-window)
        return entries
            .filter { $0.channel == .unanswered && $0.timestamp >= cutoff }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Keeps only the newest `maxEntries`, dropping the oldest (the same
    /// direction the append trim drops from — a payload that somehow
    /// exceeds the cap on disk loads trimmed, never a crash).
    private static func pruned(_ entries: [AppActivityEntry]) -> [AppActivityEntry] {
        guard entries.count > maxEntries else { return entries }
        return Array(entries.suffix(maxEntries))
    }
}
