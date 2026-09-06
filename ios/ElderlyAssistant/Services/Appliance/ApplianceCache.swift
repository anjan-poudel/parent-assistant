import Foundation
import UIKit

/// Local cache for appliance guidance (design §4.3, eviction policy from
/// the addendum §12.3). Keyed two ways:
///
///  - **photo hash** (SHA-256 of the resized JPEG bytes): mostly pays off
///    within one capture session or on byte-identical retakes.
///  - **brand+model** ("brand|model", lowercased, trimmed): the key that
///    generalizes across re-photographs of the same appliance — but only
///    when Gemini identified both fields, which won't always happen
///    (worn labels, generic remotes). Known v2.0 gap, design §11 item 5.
///
/// 2026-09-06 (local-cache-manuals): both keys are now **question-aware**.
/// An entry's guidance answers ONE request question ("set the clock" vs
/// "defrost" on the same appliance are different guides), so a key match
/// additionally requires the request question to equal the entry's — nil
/// ("general how-to-use") matches nil only. Serving an entry across
/// different questions would fabricate an answer the elder didn't ask
/// for; a photo re-asked with a new question is a NEW request.
///
/// Each entry also persists a DOWNSCALED copy of the photo (~256px long
/// edge JPEG) so a saved manual re-renders its step-card result UI with
/// zero network. The JPEG lives as its own Data-Protection-Complete file
/// (constitution §Security), NOT inside the storage blob — the
/// keychain-backed `EncryptedLocalStorage` is not sized for photo
/// payloads. The whole entry set stays under ONE storage key because the
/// storage protocol has no key enumeration; LRU eviction needs the full
/// list anyway, and evicting/deleteing an entry removes its image file
/// with it (no orphan accumulation beyond the bounded 40).
final class ApplianceCache {

    struct Entry: Codable, Equatable {
        /// Stable per-entry identity — deletion and the manuals library
        /// need a handle that survives re-encoding.
        let id: UUID
        let guidance: ApplianceGuidance
        /// SHA-256 of the (resized) JPEG bytes — always present.
        let photoHash: String
        /// Normalized "brand|model" — only when identity carried both.
        let brandModelKey: String?
        /// The request question this guidance answers (raw, trimmed;
        /// nil = general how-to-use). Key comparisons normalize.
        let question: String?
        var lastAccessedAt: Date
        let createdAt: Date
        /// Thumbnail JPEG file name ("<id>.jpg"); nil when the entry was
        /// stored without an image (legacy v1 entries, image-write
        /// failure). Entries without one can still dedupe by key but
        /// cannot render the step-card result UI from cache, so they are
        /// not listed in the manuals library.
        let imageFileName: String?

        init(id: UUID = UUID(), guidance: ApplianceGuidance, photoHash: String,
             brandModelKey: String?, question: String?, lastAccessedAt: Date,
             createdAt: Date, imageFileName: String?) {
            self.id = id
            self.guidance = guidance
            self.photoHash = photoHash
            self.brandModelKey = brandModelKey
            self.question = question
            self.lastAccessedAt = lastAccessedAt
            self.createdAt = createdAt
            self.imageFileName = imageFileName
        }

        /// Tolerant decode: v1 entries (before 2026-09-06) lack
        /// `id`/`question`/`imageFileName`. They still dedupe by key with
        /// a synthesized id and a nil question; they just have no image
        /// and match general requests only.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            guidance = try c.decode(ApplianceGuidance.self, forKey: .guidance)
            photoHash = try c.decode(String.self, forKey: .photoHash)
            brandModelKey = try? c.decodeIfPresent(String.self, forKey: .brandModelKey)
            question = try? c.decodeIfPresent(String.self, forKey: .question)
            lastAccessedAt = try c.decode(Date.self, forKey: .lastAccessedAt)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            imageFileName = try? c.decodeIfPresent(String.self, forKey: .imageFileName)
        }
    }

    /// What a lookup returns: the entry plus whether it's past
    /// `staleAfter`. Stale entries are STILL served (stale-while-
    /// revalidate, not stale-while-block — §4.3: never blank a working
    /// cache entry the elder is actively relying on); the flag exists for
    /// observability and any future background re-check.
    struct Hit: Equatable {
        let entry: Entry
        let stale: Bool
    }

    /// 40 entries: generous headroom over "a household owns a handful of
    /// appliances" (§4.3) without needing a second eviction policy.
    static let maxEntries = 40
    /// 180 days — a staleness HINT, not a hard expiry (see `Hit.stale`).
    static let staleAfter: TimeInterval = 180 * 24 * 3600

    private let storage: EncryptedLocalStorage
    private let storageKey = "plugin.appliance_helper.cache.v1"
    /// Where thumbnail JPEGs go; nil = the app's Application Support
    /// directory (lazily resolved). Tests inject a temp directory.
    private let thumbnailDirectory: URL?
    /// Injectable clock for tests.
    private let now: () -> Date

    init(storage: EncryptedLocalStorage,
         thumbnailDirectory: URL? = nil,
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.thumbnailDirectory = thumbnailDirectory
        self.now = now
    }

    // MARK: - Question normalization

    /// Key-side normalization of a request question. nil, blank, and
    /// whitespace-only are all "general how-to-use" (nil). Case is
    /// folded and internal whitespace collapsed so "DEFROST   mode" and
    /// "defrost mode" compare equal. Deliberately NOT more than that: no
    /// stemming or synonym folding — two phrasings of the same need are
    /// two different requests, and answering one with the other's guide
    /// would be a fabricated hit.
    static func normalizeQuestion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Raw-side store normalization: keep the user's own wording for
    /// display (manuals show the question), just trimmed to nil when
    /// blank so nil and "" can't describe the same slot differently.
    static func trimmedQuestion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func questionsMatch(_ entryQuestion: String?, _ requestQuestion: String?) -> Bool {
        normalizeQuestion(entryQuestion) == normalizeQuestion(requestQuestion)
    }

    // MARK: - Persistence

    /// All persisted entries, most-recently-accessed first. Storage
    /// failures read as "empty cache" — a cache must never break the
    /// feature it accelerates.
    private func loadEntries() -> [Entry] {
        guard case .success(let entries) = storage.read(key: storageKey, type: [Entry].self) else {
            return []
        }
        return entries.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private func persist(_ entries: [Entry]) {
        _ = storage.write(key: storageKey, value: entries)
    }

    /// Entries sorted most-recently-SAVED first — the manuals library's
    /// ordering (2026-09-06). Sorted by `createdAt`, NOT `lastAccessed`:
    /// re-opening an older manual must not reshuffle the "saved manuals,
    /// most recent first" list the elder learns to read.
    func allEntries() -> [Entry] {
        loadEntries().sorted { $0.createdAt > $1.createdAt }
    }

    /// Test/observability surface: number of persisted entries.
    var count: Int { loadEntries().count }

    // MARK: - Lookups

    /// Exact-photo duplicate detection: the SAME photo bytes AND the SAME
    /// question were already answered.
    func lookup(photoHash: String, question: String? = nil) -> Hit? {
        lookup { $0.photoHash == photoHash && Self.questionsMatch($0.question, question) }
    }

    /// Identity+question duplicate detection: a previous request for this
    /// brand+model answered this same question (a re-photograph of the
    /// same physical appliance, or a second unit of the same model).
    func lookup(brandModelKey: String, question: String? = nil) -> Hit? {
        lookup { $0.brandModelKey == brandModelKey && Self.questionsMatch($0.question, question) }
    }

    /// Manuals-library open: by stable entry id.
    func lookup(entryID: UUID) -> Hit? {
        lookup { $0.id == entryID }
    }

    /// Shared lookup: finds the most-recently-accessed matching entry,
    /// touches its LRU timestamp (persisted), and reports staleness.
    private func lookup(matching predicate: (Entry) -> Bool) -> Hit? {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: predicate) else { return nil }
        entries[index].lastAccessedAt = now()
        persist(entries)
        let entry = entries[index]
        return Hit(entry: entry, stale: now().timeIntervalSince(entry.createdAt) > Self.staleAfter)
    }

    // MARK: - Store

    /// Stores `guidance` under its photo-hash key (always) and its
    /// brand+model key (when identity has both fields). An entry is one
    /// answered REQUEST — photo bytes + question — so a re-store with the
    /// same photo hash and question replaces the earlier answer (e.g.
    /// the grounded retry tier produced a better one), while the same
    /// photo asked a different question coexists as its own entry.
    /// `imageJPEG` is the downscaled copy kept for cache-only re-render
    /// of the result UI; when it fails to write, the entry still caches
    /// (minus the thumbnail) — storage must never break the feature.
    func store(_ guidance: ApplianceGuidance, photoHash: String,
               question: String? = nil, imageJPEG: Data? = nil) {
        var entries = loadEntries()
        let normalizedQuestion = Self.normalizeQuestion(question)
        var imageFilesToRemove: [String] = []

        // Pair-keyed replace; collect the replaced entry's image file so
        // it is deleted once the new entry (new id, new file) is in.
        entries.removeAll { entry in
            let sameRequest = entry.photoHash == photoHash
                && Self.normalizeQuestion(entry.question) == normalizedQuestion
            if sameRequest, let fileName = entry.imageFileName {
                imageFilesToRemove.append(fileName)
            }
            return sameRequest
        }

        let id = UUID()
        let fileName = Self.imageFileName(for: id)
        let wroteImage = imageJPEG.map { thumbnailStore.write(fileName: fileName, jpeg: $0) } ?? false

        entries.append(Entry(id: id,
                             guidance: guidance,
                             photoHash: photoHash,
                             brandModelKey: guidance.identity.brandModelKey,
                             question: Self.trimmedQuestion(question),
                             lastAccessedAt: now(),
                             createdAt: now(),
                             imageFileName: wroteImage ? fileName : nil))

        // LRU eviction when over capacity (addendum §12.3): never evict a
        // webSearchGrounded entry purely on LRU while any on-device-
        // knowledge entry exists to evict first — a grounded answer cost a
        // real search and is more likely model-specific/correct. Evicted
        // entries take their image files with them.
        while entries.count > Self.maxEntries {
            let evictionPool = entries.filter {
                $0.guidance.knowledgeSource == .onDeviceModelKnowledge
            }
            let pool = evictionPool.isEmpty ? entries : evictionPool
            guard let victim = pool.min(by: { $0.lastAccessedAt < $1.lastAccessedAt }),
                  let victimIndex = entries.firstIndex(where: { $0.id == victim.id }) else {
                break
            }
            if let fileName = victim.imageFileName {
                imageFilesToRemove.append(fileName)
            }
            entries.remove(at: victimIndex)
        }

        for fileName in imageFilesToRemove {
            thumbnailStore.delete(fileName: fileName)
        }
        persist(entries)
    }

    // MARK: - Per-entry operations (manuals library)

    /// Removes one entry (and its image file). Returns false when no such
    /// entry exists — the library treats that as already-gone.
    @discardableResult
    func delete(entryID: UUID) -> Bool {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        if let fileName = entries[index].imageFileName {
            thumbnailStore.delete(fileName: fileName)
        }
        entries.remove(at: index)
        persist(entries)
        return true
    }

    /// The stored downscaled JPEG for an entry, for cache-only rendering.
    func imageJPEG(entryID: UUID) -> Data? {
        thumbnailStore.read(fileName: Self.imageFileName(for: entryID))
    }

    private static func imageFileName(for id: UUID) -> String {
        id.uuidString + ".jpg"
    }

    // MARK: - Thumbnail files

    private lazy var thumbnailStore: ThumbnailFileStore = {
        let directory = thumbnailDirectory ?? ThumbnailFileStore.defaultDirectory()
        return ThumbnailFileStore(directory: directory)
    }()
}

/// One JPEG file per cache entry ("<entry id>.jpg") in a dedicated
/// directory. Files are written with the iOS Data Protection Complete
/// class (constitution §Security's "encrypted app storage" bar for
/// on-device data, same class the keychain store claims) and live in
/// Application Support — durable, not purgeable like Caches, because
/// manuals must survive system storage pressure.
private struct ThumbnailFileStore {
    let directory: URL

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ApplianceCacheThumbnails", isDirectory: true)
    }

    func fileURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    @discardableResult
    func write(fileName: String, jpeg: Data) -> Bool {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        do {
            try jpeg.write(to: fileURL(fileName: fileName),
                           options: [.completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    func read(fileName: String) -> Data? {
        try? Data(contentsOf: fileURL(fileName: fileName))
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(fileName: fileName))
    }
}
