import CryptoKit
import Foundation
import UIKit

/// The three instruction kinds the feature authors (design L2 §3.4, §4.1).
///
/// This enum is the *validated* vocabulary used by `InstructionPayload`; the
/// stored wire model deliberately keeps the raw `String` so an unknown kind
/// survives a round trip verbatim (NFR-RIE-006). The raw values are the
/// locked persisted vocabulary — `"text"` is the exact stored kind
/// (must-carry B-2).
enum InstructionKind: String, CaseIterable, Codable, Equatable {
    case text
    case image
    case video

    /// The only way a raw kind reaches an event field: known raw values pass
    /// through, anything else becomes `"unknown"` so a decoded payload can
    /// never write arbitrary bytes into a log or an event (closed
    /// vocabulary, design §3.1 rule 8).
    static func reportable(_ raw: String) -> String {
        InstructionKind(rawValue: raw)?.rawValue ?? "unknown"
    }
}

/// One instruction attached to a routine entry or a free-form event
/// (FR-RIE-001…003; design L2 §3.4, §4.1).
///
/// This is the *stored* shape and it is deliberately tolerant: `kind` is a
/// raw `String` (unknown values round-trip verbatim), every other field is
/// optional, and no field decode can throw. The owner decodes this with
/// `try? decodeIfPresent(...) ?? nil`, so a malformed instruction value costs
/// the instruction — never the routine entry or the extras row (design
/// §4.6).
struct Instruction: Codable, Equatable {
    /// Raw stored kind. Known values are `"text"`, `"image"` and `"video"`;
    /// anything else is preserved verbatim and displays as unsupported.
    var kind: String

    /// The instruction's words, meaningful for `"text"` only.
    var text: String?

    /// Optional one-line caption under image/video media.
    var caption: String?

    /// Bare file name inside the owner's store — never a path. The decoder
    /// deliberately does not sanitise (the model is not the security
    /// boundary); the video store and the image loaders apply
    /// `InstructionFilename.isPlain` before any URL is built (design §3.5).
    var filename: String?

    /// Decoded/encoded only, for forward tolerance. v1 never authors it and
    /// no UI acts on it (design §1.4, §4.1).
    var url: String?

    init(kind: String, text: String? = nil, caption: String? = nil,
         filename: String? = nil, url: String? = nil) {
        self.kind = kind
        self.text = text
        self.caption = caption
        self.filename = filename
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case caption
        case filename
        case url
    }

    /// Tolerant decode (design §4.6): the keyed container ignores unknown
    /// fields, and each known field's failure becomes `nil` rather than a
    /// decode error. A missing or wrong-typed `kind` becomes the empty
    /// string, whose `isPresent` is `false` — never a decode failure.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
        caption = (try? container.decodeIfPresent(String.self, forKey: .caption)) ?? nil
        filename = (try? container.decodeIfPresent(String.self, forKey: .filename)) ?? nil
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
    }

    /// Nil fields are omitted, so a stored instruction carries only what it
    /// means and a nil value adds no key (design §4.1).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(url, forKey: .url)
    }

    /// The validated kind, or `nil` for an unknown raw value.
    var knownKind: InstructionKind? { InstructionKind(rawValue: kind) }

    /// IF-1: the single definition of "this instruction renders something"
    /// (design §3.4.1). The card, the notification-arming path and the
    /// fired-screen gate all read this value; no second definition exists.
    ///
    /// - `"text"`: present iff the trimmed text is non-empty.
    /// - `"image"` / `"video"`: present iff a bare filename is stored.
    /// - unknown kind: present when any renderable field is non-empty — the
    ///   forward-tolerance rule, so a future link-only instruction shows the
    ///   plain unsupported note instead of vanishing silently.
    /// - anything else (blank kind): `false`.
    var isPresent: Bool {
        switch kind {
        case InstructionKind.text.rawValue:
            return trimmedText != nil
        case InstructionKind.image.rawValue, InstructionKind.video.rawValue:
            return !(filename ?? "").isEmpty
        case "":
            return false
        default:
            return trimmedText != nil
                || trimmedCaption != nil
                || !(filename ?? "").isEmpty
                || !(url ?? "").isEmpty
        }
    }

    /// The stored text trimmed of surrounding whitespace; `nil` when blank.
    var trimmedText: String? { trimmedOrNil(text) }

    /// The stored caption trimmed of surrounding whitespace; `nil` when
    /// blank.
    var trimmedCaption: String? { trimmedOrNil(caption) }
}

/// The authoring shape of one instruction (design L2 §3.4, §4.2).
///
/// Unlike `Instruction`, the kind is the validated enum: a write can never
/// author an unknown kind. `instruction` normalises the fields the chosen
/// kind cannot carry, so a text instruction can never smuggle a filename and
/// a media instruction can never carry stray text.
struct InstructionPayload: Equatable {
    let kind: InstructionKind
    let text: String?
    let caption: String?
    /// `nil` means "media not committed yet" (transient, draft only).
    let filename: String?

    init(kind: InstructionKind, text: String? = nil,
         caption: String? = nil, filename: String? = nil) {
        self.kind = kind
        self.text = text
        self.caption = caption
        self.filename = filename
    }

    /// The wire value this payload authors (design §4.2 table): text keeps
    /// only trimmed text, media keeps only a trimmed caption and filename,
    /// and `url` is always nil because v1 never authors one.
    var instruction: Instruction {
        switch kind {
        case .text:
            return Instruction(kind: kind.rawValue,
                               text: trimmedOrNil(text),
                               caption: nil,
                               filename: nil,
                               url: nil)
        case .image, .video:
            return Instruction(kind: kind.rawValue,
                               text: nil,
                               caption: trimmedOrNil(caption),
                               filename: filename,
                               url: nil)
        }
    }
}

/// The editor's write intent (design L2 §4.2). `remove` is explicit — there
/// is no "empty text means delete" shape.
enum InstructionWrite: Equatable {
    case set(InstructionPayload)
    case remove
}

/// Media the owner has picked but the store has not committed yet (design
/// L2 §3.4, R-7). The bytes travel beside the write, never inside the
/// payload: an event has no id before it is created, so no store filename
/// can exist at handoff time.
///
/// Equatable as design P-7 requires: accepted videos compare by their stored
/// values (draft id, metadata, timestamps), never by reading their bytes.
enum InstructionPendingMedia: Equatable {
    case image(UIImage)
    case video(AcceptedInstructionVideo)
}

/// The editor → host handoff (design L2 §3.4, R-7): the resolved write plus
/// the pending bytes its host must commit before the write can be persisted.
struct InstructionCommit: Equatable {
    let write: InstructionWrite
    let pendingMedia: InstructionPendingMedia?
}

/// The editor's whole state for one instruction (design L2 §3.4, §4.2).
///
/// A draft is a pure value: every mutation replaces its parts and no method
/// reads a store, a file or a locale. `resolvedWrite` is the only answer a
/// host may act on. It is nil while loading, after a failed load, before the
/// first edit, after `revert()`, and for a media write that has neither a
/// stored filename nor pending bytes of its own kind (T-003 acceptance).
struct InstructionDraft: Equatable {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var loadState: LoadState
    private(set) var hasChanges: Bool
    private(set) var write: InstructionWrite?
    private(set) var pendingMedia: InstructionPendingMedia?
    /// The editable values for the chosen kind. Nil until a kind is chosen,
    /// including for an original whose raw kind this build does not know.
    private(set) var payload: InstructionPayload?
    private(set) var original: Instruction?

    /// Internal so the suite can pin every row of the §4.2 truth table —
    /// notably "changed but authored nothing", which no public mutation can
    /// reach. Production uses the three factories below and the mutations.
    init(loadState: LoadState, hasChanges: Bool = false,
         write: InstructionWrite? = nil,
         pendingMedia: InstructionPendingMedia? = nil,
         payload: InstructionPayload? = nil,
         original: Instruction? = nil) {
        self.loadState = loadState
        self.hasChanges = hasChanges
        self.write = write
        self.pendingMedia = pendingMedia
        self.payload = payload
        self.original = original
    }

    static func loading() -> InstructionDraft {
        InstructionDraft(loadState: .loading)
    }

    /// A loaded draft seeds its editable payload from the stored instruction
    /// (design §4.2), so an existing caption or filename survives the first
    /// edit. An unknown raw kind cannot be authored and starts with no kind
    /// chosen.
    static func loaded(instruction: Instruction?) -> InstructionDraft {
        InstructionDraft(loadState: .loaded,
                         payload: seededPayload(from: instruction),
                         original: instruction)
    }

    static func failed() -> InstructionDraft {
        InstructionDraft(loadState: .failed)
    }

    // MARK: - Resolution (IF-2)

    /// The §4.2 truth table, plus the T-003 media-resolution guard: a
    /// `.set` media payload resolves only when it carries a stored filename
    /// or pending bytes of the same kind. `.remove` always resolves to
    /// `.remove`; it is never rewritten as an empty text set.
    var resolvedWrite: InstructionWrite? {
        guard loadState == .loaded, hasChanges, let write else { return nil }
        switch write {
        case .remove:
            return .remove
        case .set(let payload):
            guard isResolved(payload) else { return nil }
            return .set(payload)
        }
    }

    /// The write and the bytes the host must commit first. Pending media is
    /// carried only for a `.set` whose payload kind matches the media's kind,
    /// so a text write can never smuggle an image (design §4.2). Nil whenever
    /// `resolvedWrite` is nil.
    var resolvedCommit: InstructionCommit? {
        guard let resolvedWrite else { return nil }
        guard let pendingMedia,
              case .set(let payload) = resolvedWrite,
              pendingMediaMatches(pendingMedia, kind: payload.kind) else {
            return InstructionCommit(write: resolvedWrite, pendingMedia: nil)
        }
        return InstructionCommit(write: resolvedWrite, pendingMedia: pendingMedia)
    }

    // MARK: - Mutations

    /// Changes the authoring kind and clears every field the new kind cannot
    /// carry (design §4.2). Pending bytes survive only when their own kind is
    /// still selected — an image can never ride on a video write.
    mutating func chooseKind(_ kind: InstructionKind) {
        guard loadState == .loaded else { return }
        if let payload, payload.kind == kind { return }
        let current = payload
        let updated: InstructionPayload
        switch kind {
        case .text:
            updated = InstructionPayload(kind: .text,
                                         text: current?.kind == .text ? current?.text : nil)
        case .image, .video:
            let keepsMediaFields = current?.kind == .image || current?.kind == .video
            updated = InstructionPayload(kind: kind,
                                         caption: keepsMediaFields ? current?.caption : nil,
                                         filename: keepsMediaFields ? current?.filename : nil)
        }
        payload = updated
        if let pendingMedia, !pendingMediaMatches(pendingMedia, kind: kind) {
            self.pendingMedia = nil
        }
        write = .set(updated)
        hasChanges = true
    }

    /// Sets the instruction's words. Applies to a text draft, or to a fresh
    /// draft with no kind chosen yet; it never silently converts a chosen
    /// image/video draft into text (the editor calls `chooseKind` first).
    mutating func setText(_ text: String) {
        guard loadState == .loaded else { return }
        if let payload, payload.kind != .text { return }
        let updated = InstructionPayload(kind: .text, text: text)
        payload = updated
        pendingMedia = nil
        write = .set(updated)
        hasChanges = true
    }

    /// Caption-only edit of image/video media (design §4.2): the stored
    /// filename and pending bytes are kept, so a caption edit copies no
    /// media. A text draft has no caption and ignores this.
    mutating func setCaption(_ caption: String) {
        guard loadState == .loaded, let payload else { return }
        guard payload.kind == .image || payload.kind == .video else { return }
        let updated = InstructionPayload(kind: payload.kind,
                                         caption: caption,
                                         filename: payload.filename)
        self.payload = updated
        write = .set(updated)
        hasChanges = true
    }

    /// Selects media that already has a stored filename. The kind comes from
    /// the chosen image/video draft, because both carry the same fields; a
    /// text or unfinished draft ignores this.
    mutating func setExistingMedia(filename: String, caption: String?) {
        guard loadState == .loaded, let payload else { return }
        guard payload.kind == .image || payload.kind == .video else { return }
        let updated = InstructionPayload(kind: payload.kind,
                                         caption: caption,
                                         filename: filename)
        self.payload = updated
        pendingMedia = nil
        write = .set(updated)
        hasChanges = true
    }

    /// Selects newly picked image bytes. The payload deliberately carries no
    /// filename: the store mints it at commit, so a replaced instruction can
    /// never keep a stale name.
    mutating func setPendingImage(_ image: UIImage, caption: String?) {
        guard loadState == .loaded else { return }
        let updated = InstructionPayload(kind: .image, caption: caption)
        payload = updated
        pendingMedia = .image(image)
        write = .set(updated)
        hasChanges = true
    }

    /// Selects a validated video that is still staged (the store's `_pending`
    /// area owns the bytes until the host commits them).
    mutating func setPendingVideo(_ video: AcceptedInstructionVideo, caption: String?) {
        guard loadState == .loaded else { return }
        let updated = InstructionPayload(kind: .video, caption: caption)
        payload = updated
        pendingMedia = .video(video)
        write = .set(updated)
        hasChanges = true
    }

    /// Removal is its own write. There is no "empty text means delete" shape
    /// (design §4.2; T-003 scenario 2).
    mutating func removeInstruction() {
        guard loadState == .loaded else { return }
        write = .remove
        pendingMedia = nil
        hasChanges = true
    }

    /// Restores the instruction the draft loaded and clears the change flag.
    mutating func revert() {
        guard loadState == .loaded else { return }
        hasChanges = false
        write = nil
        pendingMedia = nil
        payload = Self.seededPayload(from: original)
    }

    // MARK: - Helpers

    /// Text always resolves; media resolves only with its own bytes.
    private func isResolved(_ payload: InstructionPayload) -> Bool {
        switch payload.kind {
        case .text:
            return true
        case .image, .video:
            if let filename = payload.filename, !filename.isEmpty { return true }
            guard let pendingMedia else { return false }
            return pendingMediaMatches(pendingMedia, kind: payload.kind)
        }
    }

    private func pendingMediaMatches(_ media: InstructionPendingMedia,
                                     kind: InstructionKind) -> Bool {
        switch media {
        case .image:
            return kind == .image
        case .video:
            return kind == .video
        }
    }

    private static func seededPayload(from instruction: Instruction?) -> InstructionPayload? {
        guard let instruction, let kind = instruction.knownKind else { return nil }
        switch kind {
        case .text:
            return InstructionPayload(kind: .text, text: instruction.text)
        case .image, .video:
            return InstructionPayload(kind: kind,
                                      caption: instruction.caption,
                                      filename: instruction.filename)
        }
    }
}

/// The two store roots (design L2 §3.4, §4.3). Each is a directory under
/// Application Support; the raw value is the on-disk directory name.
enum InstructionRoot: String, CaseIterable, Equatable {
    case routines = "InstructionVideos"
    case events = "EventInstructionVideos"
}

/// The single owner of an instruction (design L2 §3.4, §4.3).
///
/// A routine owner is identified by its entry id; an event owner by its
/// opaque EventKit identifier. The event id is never used as a directory
/// name — it is hashed first — so an identifier containing path
/// metacharacters cannot escape the root.
enum InstructionOwner: Hashable, Equatable {
    case routine(UUID)
    case event(String)

    var root: InstructionRoot {
        switch self {
        case .routine:
            return .routines
        case .event:
            return .events
        }
    }

    /// The owner's directory name. Routine owners use the uppercase UUID
    /// string (the `VisualAidStore` convention); event owners use the
    /// digest below.
    var directoryName: String {
        switch self {
        case .routine(let entryId):
            return entryId.uuidString
        case .event(let eventId):
            return Self.eventDirectoryName(for: eventId)
        }
    }

    /// `ev-` plus the first 32 lowercase hex characters (128 bits) of the
    /// SHA-256 of the UTF-8 event identifier (design §4.3). Stable,
    /// filename-safe and one-way: the event id never lands on disk as a
    /// name.
    static func eventDirectoryName(for eventId: String) -> String {
        let digest = SHA256.hash(data: Data(eventId.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "ev-" + hex
    }
}

/// The rounded-duration arithmetic the 180-second cap is judged by (design
/// L2 §3.4, §5.2 step 3).
///
/// The cap is inclusive in *rounded whole seconds*: exactly 180 s is
/// accepted, 180.2 s rounds to 180 and is accepted, and 180.5 s rounds to
/// 181 and is refused.
enum InstructionVideoDuration {
    /// Whole seconds, rounded to nearest with halves away from zero.
    /// Non-finite or unrepresentably large input returns `Int.max`, which
    /// exceeds every configured limit; the probe maps a non-finite duration
    /// to `.unreadableSource` before this is consulted.
    static func roundedSeconds(_ seconds: Double) -> Int {
        let rounded = seconds.rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite else { return Int.max }
        if rounded <= 0 { return 0 }
        if rounded >= Double(Int.max) { return Int.max }
        return Int(rounded)
    }

    /// `true` when the rounded duration is strictly greater than `limit`.
    /// Non-finite input cannot be judged and is treated as exceeding.
    static func exceedsLimit(_ seconds: Double, limit: TimeInterval) -> Bool {
        guard seconds.isFinite else { return true }
        return Double(roundedSeconds(seconds)) > limit
    }
}

/// Trim surrounding whitespace and collapse a blank string to `nil`.
private func trimmedOrNil(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
