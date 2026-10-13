import Contacts
import CryptoKit
import Foundation

// MARK: - Verified link snapshots (family-contacts-unify T-149, design-l2 §1.3)

/// Published snapshot of VERIFIED links (design-l1 §6.2, design-l2 §1.3).
/// `.empty` ⇒ unlinked semantics — today's behavior exactly.
///
/// Every consumer reads ONLY this value: the search pass's link dedupe, the
/// coordinator's identity/face resolution, the missed-call name resolution.
/// A stored `SystemContactLink` is a CLAIM; a link in this snapshot is a
/// proven one (the record still exists and still owns the fingerprinted
/// number). An unverified stored link never appears here — stale links
/// degrade to unlinked, they are never presented (FR-FCU-006).
struct VerifiedLinksSnapshot: Equatable {
    /// Family contact id → its verified link. At most one entry per family
    /// contact (the model stores one optional link), and — by construction —
    /// at most one family contact per record identifier: a duplicate stored
    /// claim loses at verification (§1.3).
    var links: [UUID: SystemContactLink]

    /// Record identifier → that record's CURRENT normalized numbers, for the
    /// VERIFIED links only (design-l1 §6.3). This is the link-aware half of
    /// number reach: a missed call from the person's book number resolves to
    /// the FAMILY contact the record is linked to (FR-FCU-004's "the number
    /// of either side resolves to the one family contact").
    var linkedRecordNumbers: [String: [String]]

    /// Bumps once per COMPLETED pass (one published snapshot per pass). It
    /// orders PUBLICATION — a consumer drops a snapshot whose generation is
    /// not newer than the one it holds — it does NOT order inputs (input
    /// freshness is the drain's latest-roster capture, §4.2).
    var generation: UInt64

    static let empty = VerifiedLinksSnapshot(links: [:],
                                             linkedRecordNumbers: [:],
                                             generation: 0)

    /// The family contact id whose verified link points at `identifier`, or
    /// nil. Unique by design (§1.3): duplicate stored claims were dropped at
    /// verification, so a snapshot built by the service cannot hold two links
    /// to one identifier. The defensive `min` tiebreak keeps the answer
    /// deterministic even for a hand-built snapshot that violated that.
    func familyID(forIdentifier identifier: String) -> UUID? {
        links.filter { $0.value.identifier == identifier }
             .keys
             .min { $0.uuidString < $1.uuidString }
    }

    /// The family contact id whose linked record carries a number matching
    /// `phone`, or nil — `MissedCallContactResolver.matches` (the trailing-
    /// digit rule, floor 8) reused UNCHANGED, exactly as the dialable-number
    /// path uses it. Only VERIFIED links are consulted: an unverified link is
    /// absent, so a changed number can never resolve to the wrong person.
    func familyID(matchingRecordNumber phone: String) -> UUID? {
        // Sorted identifiers make the answer deterministic when two linked
        // records share a number (allowed: two relatives can have one landline).
        for identifier in linkedRecordNumbers.keys.sorted() {
            guard let numbers = linkedRecordNumbers[identifier],
                  numbers.contains(where: { MissedCallContactResolver.matches(phone, $0) })
            else { continue }
            if let familyID = familyID(forIdentifier: identifier) { return familyID }
        }
        return nil
    }
}

// MARK: - Platform seams

/// The narrow platform seam the link service reads the address book through
/// (design-l2 §1.3). `CNContactStore` is neither constructible nor fakeable in
/// unit tests, so the whole read path crosses THIS protocol and every test
/// scripts it.
protocol SystemContactReading: AnyObject {
    /// The CURRENT authorization state — re-read per use; access can change
    /// while the app is foregrounded (the user edits it in iOS Settings).
    func currentAccess() -> ContactsAccess

    /// Records matching `identifiers`, under the CURRENT access. A withheld
    /// record is simply absent (iOS 18 limited access grants a SUBSET), and a
    /// store-level failure throws (the caller degrades; nothing is invented).
    func contacts(identifiers: [String], keysToFetch: [CNKeyDescriptor]) throws -> [CNContact]
}

/// The surface the coordinator consumes (T-156): verified links, system photo
/// bytes, cache invalidation. Implemented by `SystemContactLinkService`.
protocol SystemContactLinkReading: AnyObject {
    /// Verify every stored link in `contacts` and publish a snapshot.
    func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot

    /// The system record's photo bytes, or nil when absent/unreadable/not
    /// readable. The CALLER owns the verified-link precondition (§10.1): this
    /// method answers "what bytes does record X hold", not "is X still linked".
    func photoImageData(forIdentifier identifier: String) async -> Data?

    /// One record's cached bytes, or the whole cache (nil = all).
    ///
    /// `async` — design-l2 §0 deviation 1: an actor method cannot satisfy a
    /// synchronous protocol requirement while touching actor state, so the
    /// marker is technically required for
    /// `SystemContactLinkService: SystemContactLinkReading`. Every call site
    /// already awaits the actor (design-l2 §4.5).
    func invalidate(identifier: String?) async
}

// MARK: - The service

/// Verifies stored `SystemContactLink`s against the live address book and
/// serves the system-contact photo bytes (design-l2 §1.3, §4.2, §4.3).
///
/// Isolation (design-l2 §4.1): an `actor`. Every piece of its state — the
/// drain flags, the published snapshot, the photo cache — is actor-isolated,
/// so the actor is the only mutator and concurrent callers await serialized
/// access. Pure number matching is delegated to
/// `MissedCallContactResolver.matches`; nothing here re-implements it.
///
/// This file writes NOTHING to the console (NFR-FCU-002, §5.2 — the release
/// log-safety gate's rule 3 covers it): every diagnostic is an
/// `ObservabilityBus` event with the closed vocabulary
/// (`contacts_link` / `refresh_completed`, outcome `ok`/`degraded`, error
/// code `fetch_failed`) and allow-listed metadata keys only. No name, number,
/// identifier or photo byte ever enters an event field.
///
/// No network, ever (NFR-FCU-003): all state is local address-book state.
actor SystemContactLinkService: SystemContactLinkReading {

    // MARK: Photo cache constants (design-l2 §4.3 — all named, no literals)

    /// ≈ 12 linked contacts × 2 sweep generations: one refresh's worth of
    /// records plus room for a stale sweep, so a foreground invalidation does
    /// not evict the very entries it is about to re-read.
    static let photoCacheCountLimit = 24

    /// 16 MiB of RAW photo bytes (`cost` = `data.count`), on top of the
    /// existing downsampled-image budget — full-size bytes only, never
    /// decoded images.
    static let photoCacheTotalCostLimit = 16 * 1024 * 1024

    /// Hex characters of the sha256 cache-key prefix. The key is a HASH by
    /// construction: it is the only cache-internal value that could reach a
    /// log or a memory dump, and no identifier may ever be one (§5.2).
    static let photoKeyHashPrefixLength = 16

    /// Keys for the ONE batched verification fetch (§1.3): the record handle
    /// and its numbers — nothing else. Never names, emails or photos: a
    /// verification must read the minimum the fingerprint needs.
    private static let verificationKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey,
        CNContactPhoneNumbersKey,
    ] as [CNKeyDescriptor]

    /// Keys for one cache-aside photo read (§4.3): the handle and the
    /// full-size image bytes only (data minimisation — a photo read has no
    /// business pulling the person's name or numbers).
    private static let photoKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey,
        CNContactImageDataKey,
    ] as [CNKeyDescriptor]

    private static let component = "contacts_link"
    private static let refreshEvent = "refresh_completed"

    // MARK: Dependencies

    private let reader: SystemContactReading
    private let observabilityBus: ObservabilityBus?

    // MARK: Drain state (§4.2 — actor-isolated)

    /// True for the WHOLE drain (first pass and every follow-up), so a trigger
    /// arriving during any pass takes the coalesced path instead of starting a
    /// second drain.
    private var refreshInFlight = false

    /// The LATEST coalesced roster request — overwritten, never merged and
    /// never the first one seen. The drain's follow-up pass runs with this.
    private var pendingContacts: [FamilyContact]? = nil

    private var lastSnapshot: VerifiedLinksSnapshot = .empty

    /// The publication counter behind `lastSnapshot.generation`. One bump per
    /// completed pass; never bumped by a degraded pass.
    private var generation: UInt64 = 0

    // MARK: Photo cache (§4.3 — inside the actor; the actor is the only mutator)

    private let photoCache: NSCache<NSString, NSData>

    init(reader: SystemContactReading = AddressBookDirectory(),
         observabilityBus: ObservabilityBus? = nil) {
        self.reader = reader
        self.observabilityBus = observabilityBus
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = Self.photoCacheCountLimit
        cache.totalCostLimit = Self.photoCacheTotalCostLimit
        self.photoCache = cache
    }

    // MARK: - Verification (§1.3, §4.2)

    /// Verifies the stored links of `contacts` and returns the published
    /// snapshot.
    ///
    /// Single-flight drain with a latest-roster capture (§4.2):
    ///  - fast path (no drain running): this call runs the passes itself and
    ///    returns the snapshot as of ITS last pass;
    ///  - coalesced path (a drain is in flight): the roster overwrites
    ///    `pendingContacts` and the call returns the snapshot published so far
    ///    — an early return a consumer drops with its generation guard;
    ///  - every accepted call either runs a pass or leaves a pending roster the
    ///    drain consumes as a follow-up pass: no trigger is dropped, so a link
    ///    created mid-refresh is verified by that refresh, not by the next
    ///    external trigger.
    func refresh(contacts: [FamilyContact]) async -> VerifiedLinksSnapshot {
        guard !refreshInFlight else {
            pendingContacts = contacts
            return lastSnapshot
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        var next: [FamilyContact]? = contacts
        while let batch = next {
            next = nil
            runVerificationPass(batch)
            // The drain's capture window (§4.2): without a suspension point
            // here, actor isolation would make the WHOLE drain atomic relative
            // to other `refresh` calls, `pendingContacts` could never be
            // written, and the coalesced path would be dead code. Yielding
            // lets a trigger that arrived during this pass take that path, so
            // its roster becomes the follow-up pass's batch (the latest
            // captured roster), while the in-flight flag stays set for the
            // whole drain.
            await Task.yield()
            next = pendingContacts
            pendingContacts = nil
        }
        return lastSnapshot
    }

    /// One §1.3 verification pass over `contacts`.
    ///
    /// Publishes a snapshot on success (generation +1); leaves the previously
    /// published snapshot untouched — and the generation unbumped — on a fetch
    /// failure or unreadable access (FR-FCU-006: stale serves, no empty flap).
    /// The pass derives its snapshot from THIS batch alone, so a roster that
    /// dropped a contact also drops that contact's verified link.
    private func runVerificationPass(_ contacts: [FamilyContact]) {
        let start = Date()

        // Roster order preserved: the first claim of an identifier wins (§1.3).
        // The model-level contract is re-checked here — an empty identifier or
        // numberKey is "no linkable record", never a link target (§3.5/§3.4).
        var stored: [(id: UUID, link: SystemContactLink)] = []
        for contact in contacts {
            guard let link = contact.systemContact,
                  !link.identifier.isEmpty, !link.numberKey.isEmpty else { continue }
            stored.append((contact.id, link))
        }

        // Nothing to verify ⇒ no store call at all. The pass still publishes:
        // a roster claiming no links IS the empty snapshot — an older
        // snapshot's links must not outlive the roster that claimed them.
        guard !stored.isEmpty else {
            publish(links: [:], linkedRecordNumbers: [:], since: start)
            return
        }

        // Access is re-read per pass. Not readable (.denied/.notDetermined):
        // NO store call, snapshot unchanged — the degraded state is reported
        // and the next trigger (mutation/foreground/access change) re-runs it.
        // No retries, no backoff (L1 §13.4).
        guard reader.currentAccess().allowsReading else {
            emit(outcome: "degraded", errorCode: nil, since: start)
            return
        }

        // ONE batched fetch — never a loop per link. ≤ 12 identifiers, the
        // curated roster's cap (`FamilyContactStore.maxContacts`).
        let identifiers = stored.map { $0.link.identifier }
        let records: [CNContact]
        do {
            records = try reader.contacts(identifiers: identifiers,
                                          keysToFetch: Self.verificationKeys)
        } catch {
            // A read failure mid-drain retains the previous snapshot unchanged
            // (stale serves; no empty-snapshot flap) and does NOT bump the
            // generation.
            emit(outcome: "degraded", errorCode: "fetch_failed", since: start)
            return
        }

        var recordsByIdentifier: [String: CNContact] = [:]
        for record in records where recordsByIdentifier[record.identifier] == nil {
            recordsByIdentifier[record.identifier] = record
        }

        var links: [UUID: SystemContactLink] = [:]
        var linkedRecordNumbers: [String: [String]] = [:]
        var claimed: Set<String> = []
        for entry in stored {
            // Duplicate identifier claims (possible only from a corrupt
            // payload — the coordinator refuses to persist one, L1 §6.1): the
            // FIRST claim in roster order owns the identifier, every later
            // duplicate stays unverified even if its own fingerprint would
            // have matched.
            guard claimed.insert(entry.link.identifier).inserted else { continue }

            // The record must still exist: deleted, or withheld under limited
            // access (a withheld record is simply absent) — either way the
            // link is stale, never presented, never a crash.
            guard let record = recordsByIdentifier[entry.link.identifier] else { continue }

            // Current normalized numbers (ASCII digits — the only vocabulary a
            // dialable number is built from). Verified iff one of them is the
            // same dialable number as the stored fingerprint: number ADDED or
            // kept → verified; number changed → stale.
            let currentNumbers = record.phoneNumbers
                .map { ContactNumberKey.normalized($0.value.stringValue) }
                .filter { !$0.isEmpty }
            guard currentNumbers.contains(where: {
                MissedCallContactResolver.matches(entry.link.numberKey, $0)
            }) else { continue }

            links[entry.id] = entry.link
            linkedRecordNumbers[entry.link.identifier] = currentNumbers
        }

        publish(links: links, linkedRecordNumbers: linkedRecordNumbers, since: start)
    }

    // MARK: - Photo bytes (§4.3)

    /// The system record's photo bytes, cache-aside: a hit is served without
    /// touching the store (the counted case a foreground sweep cares about);
    /// a miss costs ONE fetch for ONE identifier — never a loop over the
    /// roster.
    ///
    /// nil means absent (the record has no full-size image), unreadable (a
    /// store failure — the caller degrades to the app-local photo or the
    /// initials avatar) or not readable (access denied/undetermined: no store
    /// call at all). A nil result is NOT cached: an absent photo is re-checked
    /// on the next ask rather than remembered as absent forever.
    func photoImageData(forIdentifier identifier: String) async -> Data? {
        let key = Self.photoCacheKey(for: identifier) as NSString
        if let cached = photoCache.object(forKey: key) {
            return cached as Data
        }
        guard reader.currentAccess().allowsReading else { return nil }
        let records: [CNContact]
        do {
            records = try reader.contacts(identifiers: [identifier],
                                          keysToFetch: Self.photoKeys)
        } catch {
            return nil
        }
        guard let record = records.first(where: { $0.identifier == identifier }),
              let data = record.imageData else { return nil }
        // cost = raw bytes; NSCache evicts on cost, count and memory pressure
        // (design-l2 §4.3 — default policy, no custom eviction).
        photoCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// One record's cached bytes, or the whole cache (nil = all).
    ///
    /// Wholesale invalidation is the foreground hook's job (§4.5): after the
    /// user has been in Contacts.app, the app cannot know whether a photo was
    /// edited externally. Per-identifier invalidation follows our own
    /// successful `writePhoto`/`clearPhoto` (§4.4).
    func invalidate(identifier: String?) async {
        guard let identifier else {
            photoCache.removeAllObjects()
            return
        }
        photoCache.removeObject(forKey: Self.photoCacheKey(for: identifier) as NSString)
    }

    /// The photo cache's key for one record: the first
    /// `photoKeyHashPrefixLength` hex characters of `sha256(identifier)`.
    /// A HASH by construction, never the identifier itself (§4.3, §5.2).
    static func photoCacheKey(for identifier: String) -> String {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(photoKeyHashPrefixLength))
    }

    // MARK: - Publication and observability

    /// Publish a successful pass: one generation bump, one snapshot, one
    /// `ok` event. The only place `lastSnapshot`/`generation` change.
    private func publish(links: [UUID: SystemContactLink],
                         linkedRecordNumbers: [String: [String]],
                         since start: Date) {
        generation += 1
        lastSnapshot = VerifiedLinksSnapshot(links: links,
                                            linkedRecordNumbers: linkedRecordNumbers,
                                            generation: generation)
        emit(outcome: "ok", errorCode: nil, since: start)
    }

    /// The closed `contacts_link` vocabulary (§5.2): component, eventType,
    /// outcome ok/degraded, error code nil/fetch_failed, and the single
    /// allow-listed count — never an identifier, number, name or hash of one.
    /// `entry_count` is the verified-link count that STANDS after this pass
    /// (the newly published one on a success, the unchanged published one on
    /// a degraded pass) — the number a monitor can act on.
    private func emit(outcome: String, errorCode: String?, since start: Date) {
        observabilityBus?.emit(ObservabilityEvent(
            component: Self.component,
            eventType: Self.refreshEvent,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            outcome: outcome,
            errorCode: errorCode,
            metadata: ["entry_count": String(lastSnapshot.links.count)]
        ))
    }
}
